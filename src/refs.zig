const std = @import("std");
const EQ = @import("cgmes/eq.zig").EQ;
const TP = @import("cgmes/tp.zig").TP;
const SSH = @import("cgmes/ssh.zig").SSH;
const tag_index = @import("cgmes/tag_index.zig");
const ids = @import("cgmes/ids.zig");

const assert = std.debug.assert;

/// One reverse reference edge: `referrer_id.reference_name -> target_id`.
pub const ReverseRef = struct {
    referrer_id: []const u8,
    referrer_type: []const u8,
    reference_name: []const u8,
};

/// Reverse-reference index: target raw id (e.g. "_CN42") -> referrer edges.
/// All slices point into the model/overlay XML buffers, so those inputs must
/// outlive the index.
pub const ReverseRefIndex = struct {
    map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(ReverseRef)),

    pub const empty: ReverseRefIndex = .{ .map = .empty };

    pub fn build(
        gpa: std.mem.Allocator,
        model: *const EQ,
    ) !ReverseRefIndex {
        return build_with_overlays(gpa, model, null, null);
    }

    pub fn build_with_overlays(
        gpa: std.mem.Allocator,
        model: *const EQ,
        tp_opt: ?TP,
        ssh_opt: ?SSH,
    ) !ReverseRefIndex {
        var index: ReverseRefIndex = .empty;
        errdefer index.deinit(gpa);

        for (model.objects) |obj| {
            try collect_refs_from_range(
                gpa,
                &index,
                model.xml,
                model.boundaries,
                obj.object_tag_idx,
                obj.closing_tag_idx,
                obj.id,
                obj.type_name,
            );
        }

        if (tp_opt) |tp| try index_tp(gpa, &index, tp);
        if (ssh_opt) |ssh| try index_ssh(gpa, &index, ssh);
        return index;
    }

    pub fn deinit(self: *ReverseRefIndex, gpa: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        self.map.deinit(gpa);
    }

    pub fn lookup(self: *const ReverseRefIndex, target_id: []const u8) []const ReverseRef {
        assert(target_id.len > 0);
        const list = self.map.get(target_id) orelse return &.{};
        return list.items;
    }
};

fn index_tp(
    gpa: std.mem.Allocator,
    index: *ReverseRefIndex,
    tp: TP,
) !void {
    for (tp.new_objects) |obj| {
        try collect_refs_from_range(
            gpa,
            index,
            tp.xml,
            tp.boundaries,
            obj.object_tag_idx,
            obj.closing_tag_idx,
            obj.id,
            obj.type_name,
        );
    }
    for (tp.patches) |patch| {
        const source = source_from_patch_tag(tp.xml, tp.boundaries[patch.patch_tag_idx].start) orelse continue;
        try collect_refs_from_range(
            gpa,
            index,
            tp.xml,
            tp.boundaries,
            patch.patch_tag_idx,
            patch.closing_tag_idx,
            source.id,
            source.type_name,
        );
    }
}

fn index_ssh(
    gpa: std.mem.Allocator,
    index: *ReverseRefIndex,
    ssh: SSH,
) !void {
    for (ssh.patches) |patch| {
        const source = source_from_patch_tag(ssh.xml, ssh.boundaries[patch.patch_tag_idx].start) orelse continue;
        try collect_refs_from_range(
            gpa,
            index,
            ssh.xml,
            ssh.boundaries,
            patch.patch_tag_idx,
            patch.closing_tag_idx,
            source.id,
            source.type_name,
        );
    }
}

fn collect_refs_from_range(
    gpa: std.mem.Allocator,
    index: *ReverseRefIndex,
    xml: []const u8,
    boundaries: []const tag_index.TagBoundary,
    open_idx: u32,
    close_idx: u32,
    referrer_id: []const u8,
    referrer_type: []const u8,
) !void {
    assert(referrer_id.len > 0);
    assert(referrer_type.len > 0);
    assert(close_idx >= open_idx);
    if (close_idx <= open_idx + 1) return;

    for (boundaries[open_idx + 1 .. close_idx]) |tag| {
        if (xml[tag.start + 1] == '/') continue;
        const ref = (tag_index.extract_rdf_resource(xml, tag.start) catch continue) orelse continue;
        const target = ids.strip_hash(ref);
        if (target.len == 0) continue;

        const reference_name = tag_index.extract_tag_type(xml, tag.start) catch continue;
        const gop = try index.map.getOrPut(gpa, target);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, .{
            .referrer_id = referrer_id,
            .referrer_type = referrer_type,
            .reference_name = reference_name,
        });
    }
}

const PatchSource = struct {
    id: []const u8,
    type_name: []const u8,
};

/// Patch tags carry rdf:about="#_<mrid>" for patches (the common path) or
/// rdf:ID="_<mrid>" for the rare TP/SSH file that uses the rdf:ID form on a
/// patched object; the latter doesn't fire today because TP new_objects are
/// indexed via the separate `new_objects` loop and SSH carries patches only,
/// but the dual lookup keeps us honest if the inputs vary.
fn source_from_patch_tag(xml: []const u8, tag_start: u32) ?PatchSource {
    const raw_id = blk: {
        if (tag_index.extract_rdf_about(xml, tag_start)) |about| {
            break :blk ids.strip_hash(about);
        } else |_| {}
        if (tag_index.extract_rdf_id(xml, tag_start)) |id| {
            break :blk id;
        } else |_| {}
        return null;
    };
    if (raw_id.len == 0) return null;

    const type_name = tag_index.extract_tag_type(xml, tag_start) catch return null;
    return .{ .id = raw_id, .type_name = type_name };
}

/// Look up a CIM object by exact id across the primary model and (when
/// present) TP's new objects. Returns null if neither contains the id.
/// EQ takes precedence; the command layer collision-checks before calling.
pub fn resolve_object(
    model: *const EQ,
    tp_opt: ?TP,
    id: []const u8,
) ?tag_index.CimObjectView {
    if (model.getObjectById(id)) |view| return view;
    if (tp_opt) |tp| {
        if (tp.get_object_by_id(id)) |view| return view;
    }
    return null;
}

/// Return the first TP-added object id that collides with the primary model, or
/// null if TP's new objects can be safely unioned with EQ/EQBD objects.
pub fn find_tp_primary_id_collision(model: *const EQ, tp: TP) ?[]const u8 {
    for (tp.new_objects) |obj| {
        if (model.getObjectById(obj.id) != null) return obj.id;
    }
    return null;
}

/// Collect all prefix matches for `mrid_prefix` across the primary model and
/// (when present) TP's new objects. Returns owned slice.
///
/// Without this union, `refs --tp eq _TN1` would not_found even though the
/// reverse index is overlay-aware — TP-added objects like TopologicalNodes
/// don't exist in EQ's tag index but must still be valid targets.
pub fn collect_target_candidates(
    gpa: std.mem.Allocator,
    model: *const EQ,
    tp_opt: ?TP,
    mrid_prefix: []const u8,
) ![]tag_index.CimObject {
    const eq_matches = try model.get_object_by_id_prefix(gpa, mrid_prefix);
    defer gpa.free(eq_matches);
    const tp_matches: []const tag_index.CimObject = if (tp_opt) |tp|
        try tp.get_object_by_id_prefix(gpa, mrid_prefix)
    else
        &.{};
    defer if (tp_opt != null) gpa.free(tp_matches);

    const out = try gpa.alloc(tag_index.CimObject, eq_matches.len + tp_matches.len);
    @memcpy(out[0..eq_matches.len], eq_matches);
    @memcpy(out[eq_matches.len..], tp_matches);
    return out;
}

/// Return a freshly-allocated, sorted slice of referrers filtered by
/// `type_filter`. Sort order is (referrer_type, referrer_id, reference_name).
/// Caller owns and must free the returned slice. The slice's strings still
/// borrow from the underlying XML buffers — the index/model must outlive it.
pub fn filter_referrers(
    gpa: std.mem.Allocator,
    referrers: []const ReverseRef,
    type_filter: ?[]const u8,
) ![]ReverseRef {
    var selected: std.ArrayList(ReverseRef) = .empty;
    errdefer selected.deinit(gpa);
    for (referrers) |ref| {
        if (type_filter) |t| {
            if (!std.mem.eql(u8, ref.referrer_type, t)) continue;
        }
        try selected.append(gpa, ref);
    }

    std.mem.sort(ReverseRef, selected.items, {}, struct {
        fn lessThan(_: void, a: ReverseRef, b: ReverseRef) bool {
            const type_order = std.mem.order(u8, a.referrer_type, b.referrer_type);
            if (type_order != .eq) return type_order == .lt;
            const id_order = std.mem.order(u8, a.referrer_id, b.referrer_id);
            if (id_order != .eq) return id_order == .lt;
            return std.mem.order(u8, a.reference_name, b.reference_name) == .lt;
        }
    }.lessThan);

    return selected.toOwnedSlice(gpa);
}

/// Render the human-readable text form: one line per referrer formatted as
/// `<referrer_id> | <referrer_type> | <reference_name>`. Caller flushes.
pub fn write_referrers_text(
    w: *std.Io.Writer,
    target_id: []const u8,
    referrers: []const ReverseRef,
    type_filter: ?[]const u8,
) !void {
    if (referrers.len == 0) {
        if (type_filter) |t| {
            try w.print("No referrers of type '{s}' for {s}\n", .{ t, target_id });
        } else {
            try w.print("No referrers for {s}\n", .{target_id});
        }
        return;
    }
    for (referrers) |ref| {
        try w.print("{s} | {s} | {s}\n", .{
            ref.referrer_id,
            ref.referrer_type,
            ref.reference_name,
        });
    }
}

/// Render the JSON form: `{"id":..,"type":..,"referrers":[{"id":..,"type":..,"reference":..}]}`.
/// Python/jq consumers key off this schema — changing field names is a breaking
/// change for downstream scripts. Test "writes JSON envelope" pins the shape.
pub fn write_referrers_json(
    w: *std.Io.Writer,
    target_id: []const u8,
    target_type: []const u8,
    referrers: []const ReverseRef,
) !void {
    try w.writeAll("{\"id\":");
    try std.json.Stringify.value(target_id, .{}, w);
    try w.writeAll(",\"type\":");
    try std.json.Stringify.value(target_type, .{}, w);
    try w.writeAll(",\"referrers\":[");
    for (referrers, 0..) |ref, i| {
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
    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
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
    var model = try EQ.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);
    var tp = try TP.init(gpa, try gpa.dupe(u8, tp_xml));
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
    var model = try EQ.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);
    var ssh = try SSH.init(gpa, try gpa.dupe(u8, ssh_xml));
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
    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    var index = try ReverseRefIndex.build(gpa, &model);
    defer index.deinit(gpa);

    const refs = index.lookup("_L1");
    try std.testing.expectEqual(@as(usize, 3), refs.len);
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

    // Parse round-trip: the output must be valid JSON with the exact schema
    // downstream Python scripts depend on. This is the contract: changing it
    // is a breaking change.
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
    var model = try EQ.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);
    var tp = try TP.init(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);

    // Without --tp the TP-added id is invisible.
    const no_tp = try collect_target_candidates(gpa, &model, null, "TN1");
    defer gpa.free(no_tp);
    try std.testing.expectEqual(@as(usize, 0), no_tp.len);

    // With --tp the prefix resolves to the TP TopologicalNode.
    const with_tp = try collect_target_candidates(gpa, &model, tp, "TN1");
    defer gpa.free(with_tp);
    try std.testing.expectEqual(@as(usize, 1), with_tp.len);
    try std.testing.expectEqualStrings("_TN1", with_tp[0].id);
    try std.testing.expectEqualStrings("TopologicalNode", with_tp[0].type_name);

    // The overlay-aware index then finds the patched Terminal as its referrer.
    var index = try ReverseRefIndex.build_with_overlays(gpa, &model, tp, null);
    defer index.deinit(gpa);
    const refs = index.lookup(with_tp[0].id);
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
    var model = try EQ.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);
    var tp = try TP.init(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);

    const matches = try collect_target_candidates(gpa, &model, tp, "X");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    // EQ matches come first by construction.
    try std.testing.expectEqualStrings("_X1", matches[0].id);
    try std.testing.expectEqualStrings("_X2", matches[1].id);
}

test "find_tp_primary_id_collision returns first TP-added duplicate id" {
    const gpa = std.testing.allocator;
    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_T1"/>
        \\</rdf:RDF>
    ;
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:TopologicalNode rdf:ID="_T1"/>
        \\</rdf:RDF>
    ;
    var model = try EQ.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);
    var tp = try TP.init(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);

    const collision = find_tp_primary_id_collision(&model, tp) orelse return error.TestExpectedCollision;
    try std.testing.expectEqualStrings("_T1", collision);
}
