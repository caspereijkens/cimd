const std = @import("std");
const EQ = @import("cgmes/eq.zig").EQ;
const TP = @import("cgmes/tp.zig").TP;
const SSH = @import("cgmes/ssh.zig").SSH;
const tag_index = @import("cgmes/tag_index.zig");
const ids = @import("cgmes/ids.zig");
const cim_types = @import("cgmes/cim_types.zig");

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

    /// Full reverse index over every referrer's merged (EQ+TP+SSH) references,
    /// so an overlay retarget moves the edge rather than duplicating it. browse
    /// reuses this; one-shot refs uses collect_referrers_for_target instead.
    pub fn build_with_overlays(
        gpa: std.mem.Allocator,
        model: *const EQ,
        tp_opt: ?TP,
        ssh_opt: ?SSH,
    ) !ReverseRefIndex {
        var index: ReverseRefIndex = .empty;
        errdefer index.deinit(gpa);

        const sink: EdgeSink = .{ .index = &index };
        try iterate_merged_edges(gpa, model, tp_opt, ssh_opt, sink);

        // Postcondition pairs with emit_merged_edges' per-edge invariants:
        // every key is a non-empty target id, and every bucket holds at least
        // one edge (an empty bucket would mean we leaked an allocation without a
        // corresponding append).
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
        // Pair with build_with_overlays's invariant: every bucket holds at least
        // one edge — an empty hit signals index corruption.
        assert(list.items.len > 0);
        return list.items;
    }
};

/// Routes each discovered edge into the full index, or filters it to one target.
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

/// View over a TP-added (rdf:ID) object, mirroring EQ.view.
fn tp_object_view(tp: TP, obj: tag_index.CimObject) tag_index.CimObjectView {
    return .{
        .xml = tp.xml,
        .boundaries = tp.boundaries,
        .object_tag_idx = obj.object_tag_idx,
        .closing_tag_idx = obj.closing_tag_idx,
        .id = obj.id,
        .type_name = obj.type_name,
    };
}

/// Precedence order for overlay references: SSH shadows TP shadows EQ.
const Layer = enum { ssh, tp, eq };

/// The child-tag span of one object (or patch), as (xml, boundaries, range).
const RefRange = struct {
    xml: []const u8,
    boundaries: []const tag_index.TagBoundary,
    open_idx: u32,
    close_idx: u32,
};

/// Streams (reference_name, raw_resource) for each rdf:resource child tag in a
/// range, tolerating comments/PIs and malformed tags. Unlike a name→value map,
/// it preserves repeated same-name tags, so multi-valued associations keep
/// every reverse edge.
const ReferenceTagIterator = struct {
    range: RefRange,
    i: u32,

    const Entry = struct { name: []const u8, resource: []const u8 };

    fn init(range: RefRange) ReferenceTagIterator {
        assert(range.close_idx >= range.open_idx);
        return .{ .range = range, .i = range.open_idx + 1 };
    }

    fn next(self: *ReferenceTagIterator) ?Entry {
        const xml = self.range.xml;
        while (self.i < self.range.close_idx) {
            const tag = self.range.boundaries[self.i];
            self.i += 1;
            if (xml[tag.start + 1] == '/') continue;
            // A comment (<!--) or PI (<?) carrying rdf:resource="#_A" is not a
            // reference; skip it as getAllProperties does.
            if (xml[tag.start + 1] == '!' or xml[tag.start + 1] == '?') continue;
            const resource = (tag_index.extract_rdf_resource(xml, tag.start) catch continue) orelse continue;
            const name = tag_index.extract_tag_type(xml, tag.start) catch continue;
            return .{ .name = name, .resource = resource };
        }
        return null;
    }
};

/// Emit one reverse edge per *effective* reference of `base` after TP/SSH
/// overlay. The streaming, precedence-aware twin of the merge `get` displays:
/// a reference name an overlay defines shadows the same name in lower layers,
/// but every repeated tag within the owning layer still emits its own edge.
fn emit_merged_edges(
    gpa: std.mem.Allocator,
    sink: EdgeSink,
    base: tag_index.CimObjectView,
    tp_opt: ?TP,
    ssh_opt: ?SSH,
) !void {
    assert(base.id.len > 0);
    assert(base.type_name.len > 0);

    const eq_range: RefRange = .{
        .xml = base.xml,
        .boundaries = base.boundaries,
        .open_idx = base.object_tag_idx,
        .close_idx = base.closing_tag_idx,
    };

    // No overlay files at all: stream EQ directly, skipping even the mRID scan
    // a patch lookup would need. The common `cimd refs` path, kept at plain
    // reverse-scan cost.
    if (tp_opt == null and ssh_opt == null) {
        try stream_edges(gpa, sink, eq_range, base.id, base.type_name, null, .eq);
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

    // No overlay touches this object: stream EQ directly, no allocation — the
    // cost of a plain reverse scan, which is the common path.
    if (tp_range == null and ssh_range == null) {
        try stream_edges(gpa, sink, eq_range, base.id, base.type_name, null, .eq);
        return;
    }

    // Resolve which layer owns each reference name (highest precedence wins),
    // then let each layer emit only the names it owns.
    var owner: std.StringHashMapUnmanaged(Layer) = .empty;
    defer owner.deinit(gpa);
    if (ssh_range) |r| try record_owners(gpa, &owner, .ssh, r);
    if (tp_range) |r| try record_owners(gpa, &owner, .tp, r);
    try record_owners(gpa, &owner, .eq, eq_range);

    if (ssh_range) |r| try stream_edges(gpa, sink, r, base.id, base.type_name, &owner, .ssh);
    if (tp_range) |r| try stream_edges(gpa, sink, r, base.id, base.type_name, &owner, .tp);
    try stream_edges(gpa, sink, eq_range, base.id, base.type_name, &owner, .eq);
}

/// Claim `layer` as owner of each reference name in `range` unless a
/// higher-precedence layer already did (callers record SSH→TP→EQ).
fn record_owners(
    gpa: std.mem.Allocator,
    owner: *std.StringHashMapUnmanaged(Layer),
    layer: Layer,
    range: RefRange,
) !void {
    var it = ReferenceTagIterator.init(range);
    while (it.next()) |ref| {
        const gop = try owner.getOrPut(gpa, ref.name);
        if (!gop.found_existing) gop.value_ptr.* = layer;
    }
}

/// Emit a reverse edge per rdf:resource tag in `range`. When `owner` is given,
/// skip names a higher-precedence layer owns — the shadowing that keeps `refs`
/// in step with `get` without collapsing multi-valued tags.
fn stream_edges(
    gpa: std.mem.Allocator,
    sink: EdgeSink,
    range: RefRange,
    referrer_id: []const u8,
    referrer_type: []const u8,
    owner: ?*const std.StringHashMapUnmanaged(Layer),
    layer: Layer,
) !void {
    var it = ReferenceTagIterator.init(range);
    while (it.next()) |ref| {
        if (owner) |o| if (o.get(ref.name).? != layer) continue;
        const target = ids.strip_hash(ref.resource);
        if (target.len == 0) continue;
        try sink.emit(gpa, target, .{
            .referrer_id = referrer_id,
            .referrer_type = referrer_type,
            .reference_name = ref.name,
        });
    }
}

/// Shared spine of the full index and the target scan: hand every referrer's
/// effective edge to `sink`. Keeps the two paths from disagreeing.
fn iterate_merged_edges(
    gpa: std.mem.Allocator,
    model: *const EQ,
    tp_opt: ?TP,
    ssh_opt: ?SSH,
    sink: EdgeSink,
) !void {
    for (model.objects) |obj| {
        try emit_merged_edges(gpa, sink, model.view(obj), tp_opt, ssh_opt);
    }
    // TP-added objects are referrers too; TP can't patch itself, so overlay = SSH.
    if (tp_opt) |tp| for (tp.new_objects) |obj| {
        try emit_merged_edges(gpa, sink, tp_object_view(tp, obj), null, ssh_opt);
    };
}

/// Effective reverse edges pointing at `target_id`, without building the whole
/// index. Caller owns the slice (strings borrow the XML); unsorted, so pass it
/// through `filter_referrers`.
pub fn collect_referrers_for_target(
    gpa: std.mem.Allocator,
    model: *const EQ,
    tp_opt: ?TP,
    ssh_opt: ?SSH,
    target_id: []const u8,
) ![]ReverseRef {
    assert(target_id.len > 0);
    var out: std.ArrayListUnmanaged(ReverseRef) = .empty;
    errdefer out.deinit(gpa);
    const sink: EdgeSink = .{ .target = .{ .id = target_id, .out = &out } };
    try iterate_merged_edges(gpa, model, tp_opt, ssh_opt, sink);
    return out.toOwnedSlice(gpa);
}

/// Look up a CIM object by exact id across the primary model and (when
/// present) TP's new objects. Returns null if neither contains the id.
/// EQ takes precedence; the command layer collision-checks before calling.
pub fn resolve_object(
    model: *const EQ,
    tp_opt: ?TP,
    id: []const u8,
) ?tag_index.CimObjectView {
    if (model.getObjectById(id)) |view| {
        // Round-trip pair: the EQ index must hand us back the same id.
        assert(std.mem.eql(u8, view.id, id));
        return view;
    }
    if (tp_opt) |tp| {
        if (tp.get_object_by_id(id)) |view| {
            assert(std.mem.eql(u8, view.id, id));
            return view;
        }
    }
    return null;
}

/// Exact resolution honoring the underscore-optional full-id convenience: the
/// literal id first, then — for an id typed without its leading `_` — the
/// rdf:ID form, so `A` resolves the stored `_A` (cf. ids.id_prefix_matches).
/// Allocates only on the rare retry; the view's id slices the model, not `buf`.
pub fn resolve_object_normalized(
    gpa: std.mem.Allocator,
    model: *const EQ,
    tp_opt: ?TP,
    id: []const u8,
) !?tag_index.CimObjectView {
    if (resolve_object(model, tp_opt, id)) |view| return view;
    if (id.len > 0 and id[0] != '_') {
        const prefixed = try ids.with_leading_underscore(gpa, id);
        defer gpa.free(prefixed);
        return resolve_object(model, tp_opt, prefixed);
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
) ![]const tag_index.CimObject {
    const eq_matches = try model.get_object_by_id_prefix(gpa, mrid_prefix);
    // No TP: the EQ slice is already owned and complete — no second alloc needed.
    const tp = tp_opt orelse return eq_matches;
    defer gpa.free(eq_matches);

    const tp_matches = try tp.get_object_by_id_prefix(gpa, mrid_prefix);
    defer gpa.free(tp_matches);

    const out = try gpa.alloc(tag_index.CimObject, eq_matches.len + tp_matches.len);
    @memcpy(out[0..eq_matches.len], eq_matches);
    @memcpy(out[eq_matches.len..], tp_matches);
    // Downstream consumers (lookup, display, mrid stripping) all require a
    // non-empty id; any empty here means an upstream parser admitted garbage.
    for (out) |obj| {
        assert(obj.id.len > 0);
        assert(obj.type_name.len > 0);
    }
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
        if (!cim_types.matches_filter(ref.referrer_type, type_filter)) continue;
        try selected.append(gpa, ref);
    }

    const lessThan = struct {
        fn lessThan(_: void, a: ReverseRef, b: ReverseRef) bool {
            const type_order = std.mem.order(u8, a.referrer_type, b.referrer_type);
            if (type_order != .eq) return type_order == .lt;
            const id_order = std.mem.order(u8, a.referrer_id, b.referrer_id);
            if (id_order != .eq) return id_order == .lt;
            return std.mem.order(u8, a.reference_name, b.reference_name) == .lt;
        }
    }.lessThan;
    std.mem.sort(ReverseRef, selected.items, {}, lessThan);

    const out = try selected.toOwnedSlice(gpa);
    // Postcondition pairs with the filter loop above: every retained row must
    // still satisfy the type filter.
    if (type_filter != null) for (out) |ref| {
        assert(cim_types.matches_filter(ref.referrer_type, type_filter));
    };
    // Postcondition pairs with std.mem.sort above.
    if (out.len > 1) for (out[1..], 1..) |ref, i| assert(!lessThan({}, ref, out[i - 1]));
    return out;
}

/// Render the human-readable text form: one line per referrer formatted as
/// `<referrer_id> | <referrer_type> | <reference_name>`. Caller flushes.
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
        // Pair with collect_refs_from_range's preconditions: a row reaching
        // the renderer with empty fields would point at an indexer regression.
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

/// Render the JSON form: `{"id":..,"type":..,"referrers":[{"id":..,"type":..,"reference":..}]}`.
/// Python/jq consumers key off this schema — changing field names is a breaking
/// change for downstream scripts. Test "writes JSON envelope" pins the shape.
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
        // Pair with collect_refs_from_range's preconditions: empty fields here
        // would point at an indexer regression rather than a renderer bug.
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

test "ReverseRefIndex keeps every edge of a multi-valued reference" {
    const gpa = std.testing.allocator;
    // Two child tags share the reference name Foo.Bar. A name->value map would
    // collapse them to one edge; the streaming scan keeps both targets.
    const xml =
        \\<rdf:RDF>
        \\  <cim:Foo rdf:ID="_F1">
        \\    <cim:Foo.Bar rdf:resource="#_A"/>
        \\    <cim:Foo.Bar rdf:resource="#_B"/>
        \\  </cim:Foo>
        \\</rdf:RDF>
    ;
    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
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
    var model = try EQ.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);
    var tp = try TP.init(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);

    var index = try ReverseRefIndex.build_with_overlays(gpa, &model, tp, null);
    defer index.deinit(gpa);

    // TP retargets the reference: the new target gains the edge, the shadowed
    // EQ target keeps none.
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
    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    // The target scan must see _A even though Foo.Bar also points at _B.
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
    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    var index = try ReverseRefIndex.build(gpa, &model);
    defer index.deinit(gpa);

    // The commented-out reference must not produce an edge to _A.
    try std.testing.expectEqual(@as(usize, 0), index.lookup("_A").len);
    try std.testing.expectEqual(@as(usize, 1), index.lookup("_B").len);
}

test "resolve_object_normalized handles ids longer than any stack buffer" {
    const gpa = std.testing.allocator;
    const long = "a" ** 400;
    const xml = try std.fmt.allocPrint(gpa, "<rdf:RDF><cim:Substation rdf:ID=\"_{s}\"/></rdf:RDF>", .{long});
    defer gpa.free(xml);
    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const expected = try std.fmt.allocPrint(gpa, "_{s}", .{long});
    defer gpa.free(expected);
    const hit = try resolve_object_normalized(gpa, &model, null, long) orelse return error.NotFound;
    try std.testing.expectEqualStrings(expected, hit.id);
}

test "resolve_object_normalized resolves a full id typed without its leading underscore" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\</rdf:RDF>
    ;
    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    // Literal hit when the underscore is present.
    const exact = try resolve_object_normalized(gpa, &model, null, "_SS1") orelse return error.NotFound;
    try std.testing.expectEqualStrings("_SS1", exact.id);

    // Underscore-optional convenience: "SS1" resolves the stored "_SS1".
    const convenient = try resolve_object_normalized(gpa, &model, null, "SS1") orelse return error.NotFound;
    try std.testing.expectEqualStrings("_SS1", convenient.id);

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
    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    // Literal "A" is authoritative; the "_A" retry must not shadow it.
    const hit = try resolve_object_normalized(gpa, &model, null, "A") orelse return error.NotFound;
    try std.testing.expectEqualStrings("A", hit.id);
    try std.testing.expectEqualStrings("Substation", hit.type_name);
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
