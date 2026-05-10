//! TP — loads a CGMES TP (Topology) profile as an overlay on top of an EQ model.
//!
//! A TP profile contains two structurally distinct kinds of tags:
//!   1. New first-class objects (identified by `rdf:ID`), typically `TopologicalNode`.
//!      These become navigable by mRID just like EQ objects.
//!   2. Patches on existing objects (identified by `rdf:about="#_..."`), typically
//!      `Terminal` and `ConnectivityNode`, adding a `.TopologicalNode` reference.
//!
//! TP keeps both indexed independently: `patches` is sorted by stripped mRID
//! (matching the `SSH` convention, so `CimMergedView` can fan out to both
//! overlays with the same key), and `new_objects` is indexed by raw rdf:ID
//! (matching the `EQ` convention, so `browse` can look them up the same
//! way the user types them).
//!
//! Construction is a single pre-count pass plus a single fill pass — no dynamic
//! growth post-init.

const std = @import("std");
const tag_index = @import("tag_index.zig");
const utils = @import("ids.zig");

const assert = std.debug.assert;

pub const CimObject = tag_index.CimObject;
const TagBoundary = tag_index.TagBoundary;

pub const TpPatch = struct {
    /// Stripped mRID (leading underscore removed). Matches SSH.SshPatch convention.
    mrid: []const u8,
    patch_tag_idx: u32,
    closing_tag_idx: u32,
};

pub const TP = struct {
    xml: []const u8,
    boundaries: []const TagBoundary,
    /// Sorted by mRID (stripped). Terminal / ConnectivityNode overlays.
    patches: []const TpPatch,
    /// First-class objects added by TP (TopologicalNode, ...). Id stored with leading underscore,
    /// matching EQ's rdf:ID convention.
    new_objects: []const CimObject,
    /// Maps raw rdf:ID → index into new_objects.
    id_to_object: std.StringHashMap(u32),

    /// Takes ownership of `xml`: on success the TP owns it (freed by deinit),
    /// on error it is freed before returning. Callers never need to clean up `xml`.
    pub fn init(gpa: std.mem.Allocator, xml: []const u8) !TP {
        errdefer gpa.free(xml);
        assert(xml.len > 0);

        var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
        errdefer boundaries.deinit(gpa);

        const closing_for = try tag_index.build_closing_index(gpa, xml, boundaries.items);
        defer gpa.free(closing_for);

        // Pass 1: count patches vs new objects so both arrays are pre-sized.
        var patch_count: usize = 0;
        var new_object_count: usize = 0;
        for (boundaries.items) |tag| {
            switch (classify_tag(xml, tag.start)) {
                .new_object => new_object_count += 1,
                .patch => patch_count += 1,
                .skip => {},
            }
        }

        const patches = try gpa.alloc(TpPatch, patch_count);
        errdefer gpa.free(patches);

        const new_objects = try gpa.alloc(CimObject, new_object_count);
        errdefer gpa.free(new_objects);

        var id_to_object = std.StringHashMap(u32).init(gpa);
        errdefer id_to_object.deinit();
        try id_to_object.ensureTotalCapacity(@intCast(new_object_count));

        // Pass 2: fill both arrays.
        var patch_cursor: usize = 0;
        var object_cursor: usize = 0;
        for (boundaries.items, 0..) |tag, tag_idx| {
            switch (classify_tag(xml, tag.start)) {
                .skip => {},
                .new_object => |raw_id| {
                    assert(object_cursor < new_object_count);
                    const gop = id_to_object.getOrPutAssumeCapacity(raw_id);
                    if (gop.found_existing) return error.DuplicateId;

                    const obj = try CimObject.init(
                        xml,
                        boundaries.items,
                        @intCast(tag_idx),
                        closing_for[tag_idx],
                        raw_id,
                    );
                    new_objects[object_cursor] = obj;
                    gop.value_ptr.* = @intCast(object_cursor);
                    object_cursor += 1;
                },
                .patch => |stripped_mrid| {
                    assert(patch_cursor < patch_count);
                    patches[patch_cursor] = .{
                        .mrid = stripped_mrid,
                        .patch_tag_idx = @intCast(tag_idx),
                        .closing_tag_idx = closing_for[tag_idx],
                    };
                    patch_cursor += 1;
                },
            }
        }
        assert(patch_cursor == patch_count);
        assert(object_cursor == new_object_count);
        assert(id_to_object.count() == new_object_count);

        std.mem.sort(TpPatch, patches, {}, patch_less_than);
        if (patches.len > 1) {
            for (patches[1..], 1..) |patch, i| {
                if (std.mem.eql(u8, patches[i - 1].mrid, patch.mrid)) return error.DuplicateId;
            }
        }

        return .{
            .xml = xml,
            .boundaries = try boundaries.toOwnedSlice(gpa),
            .patches = patches,
            .new_objects = new_objects,
            .id_to_object = id_to_object,
        };
    }

    pub fn deinit(self: *TP, gpa: std.mem.Allocator) void {
        self.id_to_object.deinit();
        gpa.free(self.new_objects);
        gpa.free(self.patches);
        gpa.free(self.boundaries);
        gpa.free(self.xml);
    }

    /// Look up the patch for an mRID (stripped, no leading underscore).
    /// Returns null if the object is not patched by the TP profile.
    pub fn find_patch(self: TP, mrid: []const u8) ?TpPatch {
        assert(mrid.len > 0);
        var lo: usize = 0;
        var hi: usize = self.patches.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.patches[mid].mrid, mrid)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return self.patches[mid],
            }
        }
        return null;
    }

    /// Read a text property from a patch returned by find_patch.
    pub fn getPropertyFromPatch(self: TP, patch: TpPatch, property_name: []const u8) !?[]const u8 {
        return tag_index.get_property_from_indices(
            self.xml,
            self.boundaries,
            patch.patch_tag_idx,
            patch.closing_tag_idx,
            property_name,
        );
    }

    /// Read an rdf:resource reference from a patch returned by find_patch.
    pub fn getReferenceFromPatch(self: TP, patch: TpPatch, reference_name: []const u8) !?[]const u8 {
        return tag_index.get_reference_from_indices(
            self.xml,
            self.boundaries,
            patch.patch_tag_idx,
            patch.closing_tag_idx,
            reference_name,
        );
    }

    /// Convenience wrapper for single-property lookups. For multiple properties
    /// on the same object, use find_patch + getPropertyFromPatch.
    pub fn getProperty(self: TP, mrid: []const u8, property_name: []const u8) !?[]const u8 {
        const patch = self.find_patch(mrid) orelse return null;
        return self.getPropertyFromPatch(patch, property_name);
    }

    /// Convenience wrapper for single-reference lookups.
    pub fn getReference(self: TP, mrid: []const u8, reference_name: []const u8) !?[]const u8 {
        const patch = self.find_patch(mrid) orelse return null;
        return self.getReferenceFromPatch(patch, reference_name);
    }

    /// Returns the TP-added objects whose mRID starts with `id_prefix`, in
    /// storage order. The caller owns the returned slice. The prefix is
    /// normalised by ensuring a leading `_`, so users may omit it.
    pub fn get_object_by_id_prefix(
        self: TP,
        gpa: std.mem.Allocator,
        id_prefix: []const u8,
    ) ![]const tag_index.CimObject {
        const needle = try utils.with_leading_underscore(gpa, id_prefix);
        defer gpa.free(needle);

        var matches: std.ArrayList(CimObject) = .empty;
        errdefer matches.deinit(gpa);
        for (self.new_objects) |obj| {
            if (std.mem.startsWith(u8, obj.id, needle)) try matches.append(gpa, obj);
        }
        return matches.toOwnedSlice(gpa);
    }

    /// Look up a new TP-added object by raw rdf:ID (with leading underscore).
    /// Used by browse to navigate into TopologicalNodes.
    pub fn get_object_by_id(self: TP, id: []const u8) ?tag_index.CimObjectView {
        const idx = self.id_to_object.get(id) orelse return null;
        const obj = self.new_objects[idx];
        return .{
            .xml = self.xml,
            .boundaries = self.boundaries,
            .object_tag_idx = obj.object_tag_idx,
            .closing_tag_idx = obj.closing_tag_idx,
            .id = obj.id,
            .type_name = obj.type_name,
        };
    }
};

const TagKind = union(enum) {
    /// Not a CIM object — metadata (FullModel), comment, rdf:RDF root, etc.
    skip,
    /// New first-class object carrying rdf:ID="_..."; payload is the raw id (with underscore).
    new_object: []const u8,
    /// Patch on an existing object via rdf:about="#_..."; payload is the stripped mRID.
    patch: []const u8,
};

/// Classify a tag based on whether it carries rdf:ID (new object) or rdf:about (patch).
/// The underscore check rules out metadata tags like `<md:FullModel rdf:about="urn:uuid:...">`.
fn classify_tag(xml: []const u8, tag_start: u32) TagKind {
    if (tag_index.extract_rdf_id(xml, tag_start)) |raw| {
        if (raw.len > 0 and raw[0] == '_') return .{ .new_object = raw };
    } else |_| {}

    if (tag_index.extract_rdf_about(xml, tag_start)) |raw| {
        if (raw.len > 1 and raw[0] == '#' and raw[1] == '_')
            return .{ .patch = utils.strip_underscore(utils.strip_hash(raw)) };
    } else |_| {}

    return .skip;
}

fn patch_less_than(_: void, a: TpPatch, b: TpPatch) bool {
    return std.mem.order(u8, a.mrid, b.mrid) == .lt;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "TP.init - classifies new objects and patches separately" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:TP1">
        \\    <md:Model.scenarioTime>2026-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
        \\  <cim:TopologicalNode rdf:ID="_TN1">
        \\    <cim:IdentifiedObject.mRID>TN1</cim:IdentifiedObject.mRID>
        \\    <cim:TopologicalNode.BaseVoltage rdf:resource="#_BV220"/>
        \\  </cim:TopologicalNode>
        \\  <cim:TopologicalNode rdf:ID="_TN2">
        \\    <cim:IdentifiedObject.mRID>TN2</cim:IdentifiedObject.mRID>
        \\  </cim:TopologicalNode>
        \\  <cim:Terminal rdf:about="#_T_LOAD1">
        \\    <cim:Terminal.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:Terminal>
        \\  <cim:ConnectivityNode rdf:about="#_CN_LOAD">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:ConnectivityNode>
        \\</rdf:RDF>
    ;
    var tp = try TP.init(gpa, try gpa.dupe(u8, xml));
    defer tp.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), tp.new_objects.len);
    try std.testing.expectEqual(@as(usize, 2), tp.patches.len);

    // Patches are sorted — the stripped mRIDs CN_LOAD < T_LOAD1 alphabetically.
    try std.testing.expectEqualStrings("CN_LOAD", tp.patches[0].mrid);
    try std.testing.expectEqualStrings("T_LOAD1", tp.patches[1].mrid);
}

test "TP.find_patch - returns patch for Terminal and resolves TopologicalNode reference" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:about="#_T_LOAD1">
        \\    <cim:Terminal.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    var tp = try TP.init(gpa, try gpa.dupe(u8, xml));
    defer tp.deinit(gpa);

    const patch = tp.find_patch("T_LOAD1") orelse return error.TestFailed;
    const tn_ref = try tp.getReferenceFromPatch(patch, "Terminal.TopologicalNode");
    try std.testing.expect(tn_ref != null);
    try std.testing.expectEqualStrings("#_TN1", tn_ref.?);

    // Absent mRID yields null.
    try std.testing.expectEqual(@as(?TpPatch, null), tp.find_patch("not_there"));
}

test "TP.get_object_by_id - returns TopologicalNode view by raw rdf:ID" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:TopologicalNode rdf:ID="_TN1">
        \\    <cim:IdentifiedObject.name>Bus 1</cim:IdentifiedObject.name>
        \\    <cim:TopologicalNode.BaseVoltage rdf:resource="#_BV220"/>
        \\  </cim:TopologicalNode>
        \\</rdf:RDF>
    ;
    var tp = try TP.init(gpa, try gpa.dupe(u8, xml));
    defer tp.deinit(gpa);

    const view = tp.get_object_by_id("_TN1") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("TopologicalNode", view.type_name);
    try std.testing.expectEqualStrings("_TN1", view.id);
    const name = try view.getProperty("IdentifiedObject.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("Bus 1", std.mem.trim(u8, name.?, " \t\r\n"));

    // Unknown id yields null.
    try std.testing.expectEqual(@as(?tag_index.CimObjectView, null), tp.get_object_by_id("_nope"));
}

test "TP.get_object_by_id_prefix - returns matches by prefix; leading _ optional" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:TopologicalNode rdf:ID="_TN_abc1"/>
        \\  <cim:TopologicalNode rdf:ID="_TN_abc2"/>
        \\  <cim:TopologicalNode rdf:ID="_TN_xyz"/>
        \\</rdf:RDF>
    ;
    var tp = try TP.init(gpa, try gpa.dupe(u8, xml));
    defer tp.deinit(gpa);

    const ambiguous = try tp.get_object_by_id_prefix(gpa, "TN_abc");
    defer gpa.free(ambiguous);
    try std.testing.expectEqual(@as(usize, 2), ambiguous.len);

    const unique = try tp.get_object_by_id_prefix(gpa, "_TN_xyz");
    defer gpa.free(unique);
    try std.testing.expectEqual(@as(usize, 1), unique.len);
    try std.testing.expectEqualStrings("_TN_xyz", unique[0].id);

    const none = try tp.get_object_by_id_prefix(gpa, "nope");
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "TP.init - skips metadata tags (FullModel, rdf:RDF)" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:SKIP_ME">
        \\    <md:Model.profile>TP</md:Model.profile>
        \\  </md:FullModel>
        \\</rdf:RDF>
    ;
    var tp = try TP.init(gpa, try gpa.dupe(u8, xml));
    defer tp.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), tp.new_objects.len);
    try std.testing.expectEqual(@as(usize, 0), tp.patches.len);
}

test "TP.init - rejects duplicate new object IDs" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:TopologicalNode rdf:ID="_TN1"/>
        \\  <cim:TopologicalNode rdf:ID="_TN1"/>
        \\</rdf:RDF>
    ;

    try std.testing.expectError(error.DuplicateId, TP.init(gpa, try gpa.dupe(u8, xml)));
}

test "TP.init - rejects duplicate patch mRIDs" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:about="#_T1"/>
        \\  <cim:Terminal rdf:about="#_T1"/>
        \\</rdf:RDF>
    ;

    try std.testing.expectError(error.DuplicateId, TP.init(gpa, try gpa.dupe(u8, xml)));
}
