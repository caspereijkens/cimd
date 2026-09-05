const std = @import("std");
const CimDocument = @import("document.zig").CimDocument;
const Overlay = @import("cgmes/overlay.zig").Overlay;
const tag_index = @import("tag_index.zig");
const xml_scan = @import("xml_scan.zig");
const ids = @import("ids.zig");
const cim_types = @import("cim_types.zig");

const assert = std.debug.assert;

pub const ReverseRef = struct {
    referrer_id: []const u8,
    referrer_type: []const u8,
    reference_name: []const u8,
};

/// Inputs must outlive the index because edges borrow their XML buffers.
pub const ReverseRefIndex = struct {
    map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(ReverseRef)),

    pub const empty: ReverseRefIndex = .{ .map = .empty };

    pub fn build(
        gpa: std.mem.Allocator,
        model: *const CimDocument,
    ) !ReverseRefIndex {
        return build_with_overlays(gpa, model, null, null);
    }

    pub fn build_with_overlays(
        gpa: std.mem.Allocator,
        model: *const CimDocument,
        tp_opt: ?Overlay,
        ssh_opt: ?Overlay,
    ) !ReverseRefIndex {
        var index: ReverseRefIndex = .empty;
        errdefer index.deinit(gpa);

        const sink: EdgeSink = .{ .index = &index };
        try iterate_merged_edges(gpa, model, tp_opt, ssh_opt, sink);

        var it = index.map.iterator();
        while (it.next()) |entry| {
            assert(entry.key_ptr.*.len > 0);
            assert(entry.value_ptr.*.items.len > 0);
        }
        return index;
    }

    pub fn deinit(self: *ReverseRefIndex, gpa: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        self.map.deinit(gpa);
    }

    pub fn lookup(self: *const ReverseRefIndex, target_id: []const u8) []const ReverseRef {
        const list = self.map.get(target_id) orelse return &.{};
        assert(list.items.len > 0);
        return list.items;
    }
};

const EdgeSink = union(enum) {
    index: *ReverseRefIndex,
    target: TargetCollector,

    const TargetCollector = struct {
        id: []const u8,
        out: *std.ArrayListUnmanaged(ReverseRef),
    };

    fn emit(self: EdgeSink, gpa: std.mem.Allocator, target: []const u8, ref: ReverseRef) !void {
        assert(target.len > 0);
        assert(ref.referrer_id.len > 0);
        assert(ref.referrer_type.len > 0);
        assert(ref.reference_name.len > 0);
        switch (self) {
            .index => |index| {
                const gop = try index.map.getOrPut(gpa, target);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(gpa, ref);
            },
            .target => |collector| {
                if (std.mem.eql(u8, target, collector.id)) try collector.out.append(gpa, ref);
            },
        }
    }
};

const Layer = enum { ssh, tp, eq };

const RefRange = struct {
    xml: []const u8,
    boundaries: []const xml_scan.TagBoundary,
    open_idx: u32,
    close_idx: u32,

    /// A name-to-value map would lose repeated tags from multi-valued associations.
    fn children(self: RefRange) tag_index.ChildIterator {
        return tag_index.ChildIterator.init_range(self.xml, self.boundaries, self.open_idx, self.close_idx);
    }
};

fn emit_merged_edges(
    gpa: std.mem.Allocator,
    sink: EdgeSink,
    base: tag_index.CimObject,
    tp_opt: ?Overlay,
    ssh_opt: ?Overlay,
) !void {
    assert(base.id().len > 0);
    assert(base.type_name().len > 0);

    const eq_range: RefRange = .{
        .xml = base.context.xml,
        .boundaries = base.context.boundaries,
        .open_idx = base.object_tag_idx,
        .close_idx = base.closing_tag_idx,
    };

    // Avoid scanning the mRID when no overlay lookup is needed.
    if (tp_opt == null and ssh_opt == null) {
        try stream_edges(gpa, sink, eq_range, base.id(), base.type_name(), null, .eq);
        return;
    }

    const mrid = try base.mrid();
    const tp_range: ?RefRange = if (tp_opt) |tp| if (tp.find_patch(mrid)) |p| .{
        .xml = tp.xml,
        .boundaries = tp.boundaries,
        .open_idx = p.patch_tag_idx,
        .close_idx = p.closing_tag_idx,
    } else null else null;
    const ssh_range: ?RefRange = if (ssh_opt) |s| if (s.find_patch(mrid)) |p| .{
        .xml = s.xml,
        .boundaries = s.boundaries,
        .open_idx = p.patch_tag_idx,
        .close_idx = p.closing_tag_idx,
    } else null else null;

    // Untouched objects need no ownership map allocation.
    if (tp_range == null and ssh_range == null) {
        try stream_edges(gpa, sink, eq_range, base.id(), base.type_name(), null, .eq);
        return;
    }

    // Track ownership by name so overlays shadow lower layers without losing repeated tags.
    var owner: std.StringHashMapUnmanaged(Layer) = .empty;
    defer owner.deinit(gpa);
    if (ssh_range) |r| try record_owners(gpa, &owner, .ssh, r);
    if (tp_range) |r| try record_owners(gpa, &owner, .tp, r);
    try record_owners(gpa, &owner, .eq, eq_range);

    if (ssh_range) |r| try stream_edges(gpa, sink, r, base.id(), base.type_name(), &owner, .ssh);
    if (tp_range) |r| try stream_edges(gpa, sink, r, base.id(), base.type_name(), &owner, .tp);
    try stream_edges(gpa, sink, eq_range, base.id(), base.type_name(), &owner, .eq);
}

fn record_owners(
    gpa: std.mem.Allocator,
    owner: *std.StringHashMapUnmanaged(Layer),
    layer: Layer,
    range: RefRange,
) !void {
    var it = range.children();
    while (it.next()) |child| {
        if (child.kind != .reference) continue;
        const gop = try owner.getOrPut(gpa, child.name);
        if (!gop.found_existing) gop.value_ptr.* = layer;
    }
}

fn stream_edges(
    gpa: std.mem.Allocator,
    sink: EdgeSink,
    range: RefRange,
    referrer_id: []const u8,
    referrer_type: []const u8,
    owner: ?*const std.StringHashMapUnmanaged(Layer),
    layer: Layer,
) !void {
    var it = range.children();
    while (it.next()) |child| {
        if (child.kind != .reference) continue;
        if (owner) |o| if (o.get(child.name).? != layer) continue;
        const target = ids.strip_hash(child.value);
        if (target.len == 0) continue;
        try sink.emit(gpa, target, .{
            .referrer_id = referrer_id,
            .referrer_type = referrer_type,
            .reference_name = child.name,
        });
    }
}

fn iterate_merged_edges(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    tp_opt: ?Overlay,
    ssh_opt: ?Overlay,
    sink: EdgeSink,
) !void {
    for (model.objects) |obj| {
        try emit_merged_edges(gpa, sink, obj, tp_opt, ssh_opt);
    }
    // TP cannot patch its own new objects; only SSH can overlay them.
    if (tp_opt) |tp| for (tp.new_objects) |obj| {
        try emit_merged_edges(gpa, sink, obj, null, ssh_opt);
    };
}

pub fn collect_referrers_for_target(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    tp_opt: ?Overlay,
    ssh_opt: ?Overlay,
    target_id: []const u8,
) ![]ReverseRef {
    assert(target_id.len > 0);
    var out: std.ArrayListUnmanaged(ReverseRef) = .empty;
    errdefer out.deinit(gpa);
    const sink: EdgeSink = .{ .target = .{ .id = target_id, .out = &out } };
    try iterate_merged_edges(gpa, model, tp_opt, ssh_opt, sink);
    return out.toOwnedSlice(gpa);
}

pub fn resolve_object(
    model: *const CimDocument,
    tp_opt: ?Overlay,
    id: []const u8,
) ?tag_index.CimObject {
    if (model.object_by_id(id)) |view| {
        assert(std.mem.eql(u8, view.id(), id));
        return view;
    }
    if (tp_opt) |tp| {
        if (tp.object_by_id(id)) |view| {
            assert(std.mem.eql(u8, view.id(), id));
            return view;
        }
    }
    return null;
}

pub fn resolve_object_normalized(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    tp_opt: ?Overlay,
    id: []const u8,
) !?tag_index.CimObject {
    if (resolve_object(model, tp_opt, id)) |view| return view;
    if (id.len > 0 and id[0] != '_') {
        const prefixed = try ids.with_leading_underscore(gpa, id);
        defer gpa.free(prefixed);
        return resolve_object(model, tp_opt, prefixed);
    }
    return null;
}

/// Reject collisions so EQ lookup cannot silently hide a TP-declared object.
pub fn find_tp_primary_id_collision(
    model: *const CimDocument,
    tp: Overlay,
) ?tag_index.CimObject {
    for (tp.new_objects) |obj| {
        if (model.object_by_id(obj.id()) != null) return obj;
    }
    return null;
}

/// TP-added objects must remain valid targets even though EQ has no entry for them.
pub fn collect_target_candidates(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    tp_opt: ?Overlay,
    mrid_prefix: []const u8,
) ![]const tag_index.CimObject {
    var matches: std.ArrayList(tag_index.CimObject) = .empty;
    errdefer matches.deinit(gpa);

    try append_target_candidates(gpa, &matches, model.objects, mrid_prefix);
    if (tp_opt) |tp| try append_target_candidates(gpa, &matches, tp.new_objects, mrid_prefix);

    const out = try matches.toOwnedSlice(gpa);
    for (out) |obj| {
        assert(obj.id().len > 0);
        assert(obj.type_name().len > 0);
    }
    return out;
}

fn append_target_candidates(
    gpa: std.mem.Allocator,
    matches: *std.ArrayList(tag_index.CimObject),
    objects: []const tag_index.CimObject,
    mrid_prefix: []const u8,
) !void {
    const start_len = matches.items.len;
    for (objects) |obj| {
        if (ids.id_prefix_matches(obj.id(), mrid_prefix)) try matches.append(gpa, obj);
    }
    for (matches.items[start_len..]) |obj| assert(ids.id_prefix_matches(obj.id(), mrid_prefix));
}

/// Strings borrow XML, so the caller frees only the returned slice.
pub fn filter_referrers(
    gpa: std.mem.Allocator,
    referrers: []const ReverseRef,
    type_filter: ?[]const u8,
) ![]ReverseRef {
    if (type_filter == null) {
        const out = try gpa.dupe(ReverseRef, referrers);
        sort_referrers(out);
        return out;
    }

    var count: usize = 0;
    for (referrers) |ref| {
        if (cim_types.matches_filter(ref.referrer_type, type_filter)) count += 1;
    }

    const out = try gpa.alloc(ReverseRef, count);
    errdefer gpa.free(out);
    var i: usize = 0;
    for (referrers) |ref| {
        if (!cim_types.matches_filter(ref.referrer_type, type_filter)) continue;
        assert(i < out.len);
        out[i] = ref;
        i += 1;
    }
    assert(i == out.len);

    for (out) |ref| assert(cim_types.matches_filter(ref.referrer_type, type_filter));
    sort_referrers(out);
    return out;
}

fn sort_referrers(referrers: []ReverseRef) void {
    std.mem.sort(ReverseRef, referrers, {}, reverse_ref_less_than);
    if (referrers.len > 1) for (referrers[1..], 1..) |ref, i| {
        assert(!reverse_ref_less_than({}, ref, referrers[i - 1]));
    };
}

fn reverse_ref_less_than(_: void, a: ReverseRef, b: ReverseRef) bool {
    const type_order = std.mem.order(u8, a.referrer_type, b.referrer_type);
    if (type_order != .eq) return type_order == .lt;
    const id_order = std.mem.order(u8, a.referrer_id, b.referrer_id);
    if (id_order != .eq) return id_order == .lt;
    return std.mem.order(u8, a.reference_name, b.reference_name) == .lt;
}

pub fn write_referrers_text(
    w: *std.Io.Writer,
    target_id: []const u8,
    referrers: []const ReverseRef,
    type_filter: ?[]const u8,
) !void {
    assert(target_id.len > 0);
    if (referrers.len == 0) {
        if (type_filter) |t| {
            try w.print("No referrers of type '{s}' for {s}\n", .{ t, target_id });
        } else {
            try w.print("No referrers for {s}\n", .{target_id});
        }
        return;
    }
    for (referrers) |ref| {
        assert(ref.referrer_id.len > 0);
        assert(ref.referrer_type.len > 0);
        assert(ref.reference_name.len > 0);
        try w.print("{s} | {s} | {s}\n", .{
            ref.referrer_id,
            ref.referrer_type,
            ref.reference_name,
        });
    }
}

pub fn write_referrers_json(
    w: *std.Io.Writer,
    target_id: []const u8,
    target_type: []const u8,
    referrers: []const ReverseRef,
) !void {
    assert(target_id.len > 0);
    assert(target_type.len > 0);
    try w.writeAll("{\"id\":");
    try std.json.Stringify.value(target_id, .{}, w);
    try w.writeAll(",\"type\":");
    try std.json.Stringify.value(target_type, .{}, w);
    try w.writeAll(",\"referrers\":[");
    for (referrers, 0..) |ref, i| {
        assert(ref.referrer_id.len > 0);
        assert(ref.referrer_type.len > 0);
        assert(ref.reference_name.len > 0);
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try std.json.Stringify.value(ref.referrer_id, .{}, w);
        try w.writeAll(",\"type\":");
        try std.json.Stringify.value(ref.referrer_type, .{}, w);
        try w.writeAll(",\"reference\":");
        try std.json.Stringify.value(ref.reference_name, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");
}

test "ReverseRefIndex.build indexes EQ referrers by target id" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:VoltageLevel.Substation rdf:resource="#_SS1"/>
        \\  </cim:VoltageLevel>
        \\  <cim:Bay rdf:ID="_BAY1">
        \\    <cim:Bay.VoltageLevel rdf:resource="#_VL1"/>
        \\  </cim:Bay>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    var index = try ReverseRefIndex.build(gpa, &model);
    defer index.deinit(gpa);

    const refs = index.lookup("_SS1");
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("_VL1", refs[0].referrer_id);
    try std.testing.expectEqualStrings("VoltageLevel", refs[0].referrer_type);
    try std.testing.expectEqualStrings("VoltageLevel.Substation", refs[0].reference_name);
}

test "ReverseRefIndex.build_with_overlays indexes TP patch referrers" {
    const gpa = std.testing.allocator;
    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_T1"/>
        \\  <cim:TopologicalNode rdf:ID="_TN1"/>
        \\</rdf:RDF>
    ;
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:about="#_T1">
        \\    <cim:Terminal.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);

    var index = try ReverseRefIndex.build_with_overlays(gpa, &model, tp, null);
    defer index.deinit(gpa);

    const refs = index.lookup("_TN1");
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("_T1", refs[0].referrer_id);
    try std.testing.expectEqualStrings("Terminal", refs[0].referrer_type);
    try std.testing.expectEqualStrings("Terminal.TopologicalNode", refs[0].reference_name);
}

test "ReverseRefIndex.build_with_overlays indexes SSH patch referrers" {
    const gpa = std.testing.allocator;
    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:ID="_SW1"/>
        \\  <cim:RegulatingControl rdf:ID="_RC1"/>
        \\</rdf:RDF>
    ;
    const ssh_xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:about="#_SW1">
        \\    <cim:Switch.open>false</cim:Switch.open>
        \\    <cim:RegulatingCondEq.RegulatingControl rdf:resource="#_RC1"/>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);
    var ssh = try Overlay.init_ssh(gpa, try gpa.dupe(u8, ssh_xml));
    defer ssh.deinit(gpa);

    var index = try ReverseRefIndex.build_with_overlays(gpa, &model, null, ssh);
    defer index.deinit(gpa);

    const refs = index.lookup("_RC1");
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("_SW1", refs[0].referrer_id);
    try std.testing.expectEqualStrings("Switch", refs[0].referrer_type);
    try std.testing.expectEqualStrings("RegulatingCondEq.RegulatingControl", refs[0].reference_name);
}

test "ReverseRefIndex collects multiple referrers per target (hub case)" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Line rdf:ID="_L1"/>
        \\  <cim:ACLineSegment rdf:ID="_A1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_L1"/>
        \\  </cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_A2">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_L1"/>
        \\  </cim:ACLineSegment>
        \\  <cim:Switch rdf:ID="_SW1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_L1"/>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    var index = try ReverseRefIndex.build(gpa, &model);
    defer index.deinit(gpa);

    const refs = index.lookup("_L1");
    try std.testing.expectEqual(@as(usize, 3), refs.len);
}

test "ReverseRefIndex keeps every edge of a multi-valued reference" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Foo rdf:ID="_F1">
        \\    <cim:Foo.Bar rdf:resource="#_A"/>
        \\    <cim:Foo.Bar rdf:resource="#_B"/>
        \\  </cim:Foo>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    var index = try ReverseRefIndex.build(gpa, &model);
    defer index.deinit(gpa);

    const to_a = index.lookup("_A");
    try std.testing.expectEqual(@as(usize, 1), to_a.len);
    try std.testing.expectEqualStrings("_F1", to_a[0].referrer_id);
    const to_b = index.lookup("_B");
    try std.testing.expectEqual(@as(usize, 1), to_b.len);
    try std.testing.expectEqualStrings("_F1", to_b[0].referrer_id);
}

test "ReverseRefIndex applies overlay precedence to a retargeted reference" {
    const gpa = std.testing.allocator;
    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_CE_eq"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:about="#_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_CE_tp"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);

    var index = try ReverseRefIndex.build_with_overlays(gpa, &model, tp, null);
    defer index.deinit(gpa);

    const to_tp = index.lookup("_CE_tp");
    try std.testing.expectEqual(@as(usize, 1), to_tp.len);
    try std.testing.expectEqualStrings("_T1", to_tp[0].referrer_id);
    try std.testing.expectEqual(@as(usize, 0), index.lookup("_CE_eq").len);
}

test "collect_referrers_for_target streams multi-valued references" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Foo rdf:ID="_F1">
        \\    <cim:Foo.Bar rdf:resource="#_A"/>
        \\    <cim:Foo.Bar rdf:resource="#_B"/>
        \\  </cim:Foo>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const referrers = try collect_referrers_for_target(gpa, &model, null, null, "_A");
    defer gpa.free(referrers);
    try std.testing.expectEqual(@as(usize, 1), referrers.len);
    try std.testing.expectEqualStrings("_F1", referrers[0].referrer_id);
}

test "ReverseRefIndex ignores rdf:resource inside a comment" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Foo rdf:ID="_F1">
        \\    <!-- <cim:Foo.Bar rdf:resource="#_A"/> -->
        \\    <cim:Foo.Bar rdf:resource="#_B"/>
        \\  </cim:Foo>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    var index = try ReverseRefIndex.build(gpa, &model);
    defer index.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), index.lookup("_A").len);
    try std.testing.expectEqual(@as(usize, 1), index.lookup("_B").len);
}

test "resolve_object_normalized handles ids longer than any stack buffer" {
    const gpa = std.testing.allocator;
    const long = "a" ** 400;
    const xml = try std.fmt.allocPrint(gpa, "<rdf:RDF><cim:Substation rdf:ID=\"_{s}\"/></rdf:RDF>", .{long});
    defer gpa.free(xml);
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const expected = try std.fmt.allocPrint(gpa, "_{s}", .{long});
    defer gpa.free(expected);
    const hit = try resolve_object_normalized(gpa, &model, null, long) orelse return error.NotFound;
    try std.testing.expectEqualStrings(expected, hit.id());
}

test "resolve_object_normalized resolves a full id typed without its leading underscore" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const exact = try resolve_object_normalized(gpa, &model, null, "_SS1") orelse return error.NotFound;
    try std.testing.expectEqualStrings("_SS1", exact.id());

    const convenient = try resolve_object_normalized(gpa, &model, null, "SS1") orelse return error.NotFound;
    try std.testing.expectEqualStrings("_SS1", convenient.id());

    try std.testing.expect(try resolve_object_normalized(gpa, &model, null, "SS9") == null);
}

test "resolve_object_normalized prefers an exact literal hit over the underscore retry" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="A"/>
        \\  <cim:VoltageLevel rdf:ID="_A"/>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const hit = try resolve_object_normalized(gpa, &model, null, "A") orelse return error.NotFound;
    try std.testing.expectEqualStrings("A", hit.id());
    try std.testing.expectEqualStrings("Substation", hit.type_name());
}

test "filter_referrers: no filter returns all, sorted by (type, id, ref)" {
    const gpa = std.testing.allocator;
    const input = [_]ReverseRef{
        .{ .referrer_id = "_b", .referrer_type = "Switch", .reference_name = "Equipment.EquipmentContainer" },
        .{ .referrer_id = "_a", .referrer_type = "ACLineSegment", .reference_name = "Equipment.EquipmentContainer" },
        .{ .referrer_id = "_a", .referrer_type = "Switch", .reference_name = "Equipment.EquipmentContainer" },
    };

    const out = try filter_referrers(gpa, &input, null);
    defer gpa.free(out);

    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("ACLineSegment", out[0].referrer_type);
    try std.testing.expectEqualStrings("_a", out[0].referrer_id);
    try std.testing.expectEqualStrings("Switch", out[1].referrer_type);
    try std.testing.expectEqualStrings("_a", out[1].referrer_id);
    try std.testing.expectEqualStrings("Switch", out[2].referrer_type);
    try std.testing.expectEqualStrings("_b", out[2].referrer_id);
}

test "filter_referrers: type filter narrows the set" {
    const gpa = std.testing.allocator;
    const input = [_]ReverseRef{
        .{ .referrer_id = "_a", .referrer_type = "ACLineSegment", .reference_name = "x" },
        .{ .referrer_id = "_b", .referrer_type = "Switch", .reference_name = "x" },
        .{ .referrer_id = "_c", .referrer_type = "ACLineSegment", .reference_name = "x" },
    };

    const out = try filter_referrers(gpa, &input, "ACLineSegment");
    defer gpa.free(out);

    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("_a", out[0].referrer_id);
    try std.testing.expectEqualStrings("_c", out[1].referrer_id);
}

test "filter_referrers: type filter includes subtypes" {
    const gpa = std.testing.allocator;
    const input = [_]ReverseRef{
        .{ .referrer_id = "_a", .referrer_type = "ACLineSegment", .reference_name = "x" },
        .{ .referrer_id = "_b", .referrer_type = "Breaker", .reference_name = "x" },
        .{ .referrer_id = "_c", .referrer_type = "Substation", .reference_name = "x" },
    };

    const out = try filter_referrers(gpa, &input, "ConductingEquipment");
    defer gpa.free(out);

    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("_a", out[0].referrer_id);
    try std.testing.expectEqualStrings("_b", out[1].referrer_id);
}

test "filter_referrers: empty input and empty result yield empty slice" {
    const gpa = std.testing.allocator;
    const empty = [_]ReverseRef{};
    const out1 = try filter_referrers(gpa, &empty, null);
    defer gpa.free(out1);
    try std.testing.expectEqual(@as(usize, 0), out1.len);

    const input = [_]ReverseRef{
        .{ .referrer_id = "_a", .referrer_type = "Switch", .reference_name = "x" },
    };
    const out2 = try filter_referrers(gpa, &input, "Bay");
    defer gpa.free(out2);
    try std.testing.expectEqual(@as(usize, 0), out2.len);
}

test "write_referrers_json: pins the wire format" {
    const refs = [_]ReverseRef{
        .{ .referrer_id = "_A1", .referrer_type = "ACLineSegment", .reference_name = "Equipment.EquipmentContainer" },
    };

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write_referrers_json(&w, "_L1", "Line", &refs);
    const out = w.buffered();

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("_L1", root.get("id").?.string);
    try std.testing.expectEqualStrings("Line", root.get("type").?.string);

    const arr = root.get("referrers").?.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    const entry = arr.items[0].object;
    try std.testing.expectEqualStrings("_A1", entry.get("id").?.string);
    try std.testing.expectEqualStrings("ACLineSegment", entry.get("type").?.string);
    try std.testing.expectEqualStrings("Equipment.EquipmentContainer", entry.get("reference").?.string);
}

test "write_referrers_json: escapes strings containing quotes" {
    const refs = [_]ReverseRef{
        .{ .referrer_id = "_quoted\"id", .referrer_type = "T", .reference_name = "R" },
    };
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write_referrers_json(&w, "_t", "Target", &refs);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "_quoted\"id",
        parsed.value.object.get("referrers").?.array.items[0].object.get("id").?.string,
    );
}

test "write_referrers_text: empty referrers prints sentinel" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write_referrers_text(&w, "_L1", &.{}, null);
    try std.testing.expectEqualStrings("No referrers for _L1\n", w.buffered());

    var buf2: [256]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try write_referrers_text(&w2, "_L1", &.{}, "Bay");
    try std.testing.expectEqualStrings("No referrers of type 'Bay' for _L1\n", w2.buffered());
}

test "write_referrers_text: pipe-delimited lines" {
    const refs = [_]ReverseRef{
        .{ .referrer_id = "_A1", .referrer_type = "ACLineSegment", .reference_name = "Equipment.EquipmentContainer" },
        .{ .referrer_id = "_SW1", .referrer_type = "Switch", .reference_name = "Equipment.EquipmentContainer" },
    };
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write_referrers_text(&w, "_L1", &refs, null);
    try std.testing.expectEqualStrings(
        "_A1 | ACLineSegment | Equipment.EquipmentContainer\n" ++
            "_SW1 | Switch | Equipment.EquipmentContainer\n",
        w.buffered(),
    );
}

test "collect_target_candidates: TP-only target resolves under --tp" {
    const gpa = std.testing.allocator;
    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_T1"/>
        \\</rdf:RDF>
    ;
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:TopologicalNode rdf:ID="_TN1"/>
        \\  <cim:Terminal rdf:about="#_T1">
        \\    <cim:Terminal.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);

    const no_tp = try collect_target_candidates(gpa, &model, null, "TN1");
    defer gpa.free(no_tp);
    try std.testing.expectEqual(@as(usize, 0), no_tp.len);

    const with_tp = try collect_target_candidates(gpa, &model, tp, "TN1");
    defer gpa.free(with_tp);
    try std.testing.expectEqual(@as(usize, 1), with_tp.len);
    try std.testing.expectEqualStrings("_TN1", with_tp[0].id());
    try std.testing.expectEqualStrings("TopologicalNode", with_tp[0].type_name());

    var index = try ReverseRefIndex.build_with_overlays(gpa, &model, tp, null);
    defer index.deinit(gpa);
    const refs = index.lookup(with_tp[0].id());
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("_T1", refs[0].referrer_id);
}

test "collect_target_candidates: EQ and TP matches both included" {
    const gpa = std.testing.allocator;
    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_X1"/>
        \\</rdf:RDF>
    ;
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:TopologicalNode rdf:ID="_X2"/>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);

    const matches = try collect_target_candidates(gpa, &model, tp, "X");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("_X1", matches[0].id());
    try std.testing.expectEqualStrings("_X2", matches[1].id());
}

test "find_tp_primary_id_collision compares raw RDF identifiers" {
    const gpa = std.testing.allocator;
    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:IdentifiedObject.mRID>EQ-MRID</cim:IdentifiedObject.mRID>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:TopologicalNode rdf:ID="_T1"/>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);

    const collision = find_tp_primary_id_collision(&model, tp) orelse return error.TestExpectedCollision;
    try std.testing.expectEqualStrings("_T1", collision.id());
}

test "find_tp_primary_id_collision allows distinct raw ids with equal mRIDs" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, "<rdf:RDF><cim:Terminal rdf:ID=\"_T1\"/></rdf:RDF>"));
    defer model.deinit(gpa);
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, "<rdf:RDF><cim:TopologicalNode rdf:ID=\"T1\"/></rdf:RDF>"));
    defer tp.deinit(gpa);

    try std.testing.expect(find_tp_primary_id_collision(&model, tp) == null);
}
