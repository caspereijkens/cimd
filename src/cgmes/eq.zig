const std = @import("std");
const tag_index = @import("tag_index.zig");
pub const CimObject = tag_index.CimObject;
const TagBoundary = tag_index.TagBoundary;
const cgmes_ids = @import("ids.zig");
const cim_types = @import("cim_types.zig");

const assert = std.debug.assert;
pub const Diagnostics = @import("diagnostics.zig").Diagnostics;

pub const EQ = struct {
    objects: []CimObject,
    id_to_index: std.StringHashMap(u32),
    type_index: std.StringHashMap(TypeRange),

    xml: []const u8,
    boundaries: []TagBoundary,

    const TypeRange = struct { start: u32, len: u32 };
    pub const TypeCount = struct {
        type_name: []const u8,
        count: u32,

        /// Alphabetical by type name. The single ordering shared by every
        /// type-count display (the `types` command, the get-ambiguity
        /// breakdown, and its JSON envelope), so they can't sort differently.
        pub fn less_than(_: void, a: TypeCount, b: TypeCount) bool {
            return std.mem.order(u8, a.type_name, b.type_name) == .lt;
        }
    };

    /// Takes ownership of `xml`: on success the model owns it (freed by deinit),
    /// on error it is freed before returning. Callers never need to clean up `xml`.
    pub fn init(gpa: std.mem.Allocator, xml: []const u8) !EQ {
        return initWithDiagnostics(gpa, xml, null);
    }

    pub fn initWithDiagnostics(gpa: std.mem.Allocator, xml: []const u8, diagnostics: ?*Diagnostics) !EQ {
        errdefer gpa.free(xml);
        if (xml.len == 0) return error.EmptyInput;

        var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
        errdefer boundaries.deinit(gpa);

        var objects: std.ArrayList(tag_index.CimObject) = .empty;
        errdefer objects.deinit(gpa);

        var id_to_index = std.StringHashMap(u32).init(gpa);
        errdefer id_to_index.deinit();

        const closing_for = try tag_index.build_closing_index(gpa, xml, boundaries.items);
        defer gpa.free(closing_for);

        // Pass 1: collect objects and count per type.
        var type_counts = std.StringHashMap(u32).init(gpa);
        defer type_counts.deinit();
        var seen_ids = std.StringHashMap(void).init(gpa);
        defer seen_ids.deinit();
        try seen_ids.ensureTotalCapacity(@intCast(boundaries.items.len));

        var i: usize = 0;
        while (i < boundaries.items.len) : (i += 1) {
            const tag = boundaries.items[i];
            const id = extract_object_id_from_tag(xml, tag) orelse continue;
            const seen = seen_ids.getOrPutAssumeCapacity(id);
            if (seen.found_existing) {
                if (diagnostics) |d| d.record_duplicate_id(xml, id, tag.start);
                return error.DuplicateId;
            }
            seen.value_ptr.* = {};

            const object = try tag_index.CimObject.init(
                xml,
                boundaries.items,
                @intCast(i),
                closing_for[i],
                id,
            );
            try objects.append(gpa, object);
            const entry = try type_counts.getOrPut(object.type_name);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;

            // CGMES/RDF objects are top-level; child tags are properties.
            i = closing_for[i];
        }

        // Pass 2: compute write cursors (prefix sums) and populate type_index.
        const sorted_objects = try gpa.alloc(CimObject, objects.items.len);
        errdefer gpa.free(sorted_objects);

        var type_index = std.StringHashMap(TypeRange).init(gpa);
        errdefer type_index.deinit();

        // write_cursors maps type_name → next write position within sorted_objects.
        var write_cursors = std.StringHashMap(u32).init(gpa);
        defer write_cursors.deinit();
        try write_cursors.ensureTotalCapacity(type_counts.count());
        try type_index.ensureTotalCapacity(type_counts.count());

        var pos: u32 = 0;
        var count_it = type_counts.iterator();
        while (count_it.next()) |entry| {
            write_cursors.putAssumeCapacity(entry.key_ptr.*, pos);
            type_index.putAssumeCapacity(entry.key_ptr.*, .{ .start = pos, .len = entry.value_ptr.* });
            pos += entry.value_ptr.*;
        }
        // Prefix sums must cover the full object set; pairs with pass 3's writes.
        assert(pos == @as(u32, @intCast(sorted_objects.len)));

        // Pass 3: fill sorted_objects using write cursors.
        for (objects.items) |obj| {
            const cursor = write_cursors.getPtr(obj.type_name).?;
            sorted_objects[cursor.*] = obj;
            cursor.* += 1;
        }

        // Every cursor must now sit at the end of its type's range — otherwise
        // pass 1 and pass 3 disagreed on how many objects each type holds.
        var cursor_it = write_cursors.iterator();
        while (cursor_it.next()) |entry| {
            const range = type_index.get(entry.key_ptr.*).?;
            assert(entry.value_ptr.* == range.start + range.len);
        }

        // Free original objects ArrayList (copied into sorted_objects).
        objects.deinit(gpa);
        objects = .empty;

        // Build id_to_index from sorted positions.
        try id_to_index.ensureTotalCapacity(@intCast(sorted_objects.len));
        for (sorted_objects, 0..) |obj, index| {
            assert(obj.id.len > 0);
            id_to_index.putAssumeCapacity(obj.id, @intCast(index));
        }
        // Pairs with the duplicate-id rejection at the seen_ids check: every object must
        // have produced exactly one id_to_index entry.
        assert(id_to_index.count() == sorted_objects.len);

        return .{
            .objects = sorted_objects,
            .id_to_index = id_to_index,
            .type_index = type_index,
            .xml = xml,
            .boundaries = try boundaries.toOwnedSlice(gpa),
        };
    }

    pub fn deinit(self: *EQ, gpa: std.mem.Allocator) void {
        self.type_index.deinit();
        self.id_to_index.deinit();
        gpa.free(self.objects);
        gpa.free(self.boundaries);
        gpa.free(self.xml);
    }

    /// Bind a stored CimObject to this model's XML context for property access.
    pub fn view(self: EQ, obj: CimObject) tag_index.CimObjectView {
        // Catch the cross-EQ mix-up: passing a CimObject that was indexed against
        // a different model's boundaries would otherwise slice into the wrong XML.
        assert(obj.object_tag_idx < self.boundaries.len);
        assert(obj.closing_tag_idx < self.boundaries.len);
        assert(obj.closing_tag_idx >= obj.object_tag_idx);
        assert(obj.id.len > 0);
        return .{
            .xml = self.xml,
            .boundaries = self.boundaries,
            .object_tag_idx = obj.object_tag_idx,
            .closing_tag_idx = obj.closing_tag_idx,
            .id = obj.id,
            .type_name = obj.type_name,
        };
    }

    pub fn getObjectById(self: EQ, id: []const u8) ?tag_index.CimObjectView {
        const idx = self.id_to_index.get(id) orelse return null;
        const result = self.view(self.objects[idx]);
        // Pair with the index lookup: the stored object's id must round-trip.
        assert(std.mem.eql(u8, result.id, id));
        return result;
    }

    /// Returns objects whose mRID starts with `id_prefix`, in storage order
    /// (grouped by type). The caller owns the returned slice. Matching follows
    /// `ids.id_prefix_matches`: literal startsWith (so FullModel `urn:uuid:...`
    /// ids resolve) plus a leading-underscore convenience for the rdf:ID form.
    pub fn get_object_by_id_prefix(
        self: EQ,
        gpa: std.mem.Allocator,
        id_prefix: []const u8,
    ) ![]const tag_index.CimObject {
        var matches: std.ArrayList(CimObject) = .empty;
        errdefer matches.deinit(gpa);
        for (self.objects) |obj| {
            if (cgmes_ids.id_prefix_matches(obj.id, id_prefix)) try matches.append(gpa, obj);
        }
        const out = try matches.toOwnedSlice(gpa);
        // Postcondition pairs with the filter loop: a regression in the prefix
        // check would let foreign ids leak through.
        for (out) |m| assert(cgmes_ids.id_prefix_matches(m.id, id_prefix));
        return out;
    }

    pub fn get_objects_by_type(self: EQ, type_name: []const u8) []const CimObject {
        const range = self.type_index.get(type_name) orelse return &[_]CimObject{};
        return self.objects[range.start .. range.start + range.len];
    }

    /// Count objects matching `requested_type`, including CIM subtypes.
    /// Uses the compact type index, so count-mode does not scan every object.
    pub fn count_objects_by_type_filter(self: EQ, requested_type: []const u8) usize {
        var count: usize = 0;
        var it = self.type_index.iterator();
        while (it.next()) |entry| {
            if (cim_types.matches_filter(entry.key_ptr.*, requested_type)) {
                count += entry.value_ptr.*.len;
            }
        }
        assert(count <= self.objects.len);
        return count;
    }

    /// Return objects matching `requested_type`, including CIM subtypes.
    /// Caller owns the returned slice. Output order follows `self.objects`.
    pub fn collect_objects_by_type_filter(
        self: EQ,
        gpa: std.mem.Allocator,
        requested_type: []const u8,
    ) ![]CimObject {
        const count = self.count_objects_by_type_filter(requested_type);
        const out = try gpa.alloc(CimObject, count);
        errdefer gpa.free(out);

        var i: usize = 0;
        for (self.objects) |obj| {
            if (!cim_types.matches_filter(obj.type_name, requested_type)) continue;
            assert(i < out.len);
            out[i] = obj;
            i += 1;
        }
        assert(i == out.len);
        for (out) |obj| assert(cim_types.matches_filter(obj.type_name, requested_type));
        return out;
    }

    /// Return a heap-allocated, alphabetically sorted type-count list.
    /// Caller owns the returned slice and must free it with gpa.free().
    pub fn sorted_type_counts(self: EQ, gpa: std.mem.Allocator) ![]TypeCount {
        const n = self.type_index.count();
        const out = try gpa.alloc(TypeCount, n);
        errdefer gpa.free(out);

        var i: usize = 0;
        var it = self.type_index.iterator();
        while (it.next()) |entry| {
            out[i] = .{
                .type_name = entry.key_ptr.*,
                .count = entry.value_ptr.*.len,
            };
            i += 1;
        }
        assert(i == n);

        std.mem.sort(TypeCount, out, {}, TypeCount.less_than);

        return out;
    }
};

fn extract_attribute_from_tag(xml: []const u8, tag: TagBoundary, comptime pattern: []const u8) ?[]const u8 {
    const tag_content = xml[tag.start..tag.end];
    const pattern_offset = std.mem.indexOf(u8, tag_content, pattern) orelse return null;
    const value_start = tag.start + pattern_offset + pattern.len;
    const value_end = std.mem.indexOfScalarPos(u8, xml, value_start, '"') orelse return null;
    if (value_end >= tag.end) return null;
    return xml[value_start..value_end];
}

/// Extract the identifier that makes a tag a CIM object. Prefer a non-empty
/// rdf:ID, but keep inventory-style commands tolerant by falling back to
/// rdf:about when rdf:ID is absent, empty, or malformed.
fn extract_object_id_from_tag(xml: []const u8, tag: TagBoundary) ?[]const u8 {
    if (tag.start + 1 >= tag.end) return null;
    switch (xml[tag.start + 1]) {
        '/', '!', '?' => return null,
        else => {},
    }

    if (extract_attribute_from_tag(xml, tag, "rdf:ID=\"")) |id| {
        if (id.len > 0) return id;
    }

    if (extract_attribute_from_tag(xml, tag, "rdf:about=\"")) |about| {
        if (about.len > 0) {
            const local_id = cgmes_ids.strip_hash(about);
            return if (local_id.len > 0) local_id else about;
        }
    }

    return null;
}

test "EQ.init rejects duplicate RDF identifiers" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_DUP">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="_DUP">
        \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    ;

    try std.testing.expectError(error.DuplicateId, EQ.init(gpa, try gpa.dupe(u8, xml)));
}

test "EQ diagnostics record duplicate RDF identifier" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_DUP"/>
        \\  <cim:BaseVoltage rdf:ID="_DUP"/>
        \\</rdf:RDF>
    ;
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(
        error.DuplicateId,
        EQ.initWithDiagnostics(gpa, try gpa.dupe(u8, xml), &diagnostics),
    );
    try std.testing.expectEqualStrings("_DUP", diagnostics.duplicate_id());
    try std.testing.expectEqual(@as(u64, 3), diagnostics.duplicate_line);
    try std.testing.expect(!diagnostics.duplicate_id_truncated);
}

test "EQ inventory retains identifiers that conversion cannot use" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_"/>
        \\  <cim:Substation rdf:ID="__"/>
        \\</rdf:RDF>
    ;
    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);
    try std.testing.expect(model.getObjectById("_") != null);
    try std.testing.expect(model.getObjectById("__") != null);
}

test "EQ inventory ignores identifier-looking text in comments" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <!-- placeholder rdf:ID="_" to be filled in later -->
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\</rdf:RDF>
    ;
    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);
    try std.testing.expect(model.getObjectById("_SS1") != null);
}

test "EQ normalizes local rdf:about identifiers for lookup and mRID resolution" {
    const gpa = std.testing.allocator;
    const xml = "<rdf:RDF><cim:Substation rdf:about=\"#_SSX\"/></rdf:RDF>";
    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const view = model.getObjectById("_SSX") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("SSX", try view.mrid());
    const matches = try model.get_object_by_id_prefix(gpa, "SSX");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
}

test "EQ rejects rdf:ID and local rdf:about spellings of the same identifier" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:about="#_SS1"/>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\</rdf:RDF>
    ;
    try std.testing.expectError(error.DuplicateId, EQ.init(gpa, try gpa.dupe(u8, xml)));
}

const PREFIX_TEST_XML =
    \\<rdf:RDF>
    \\  <cim:BaseVoltage rdf:ID="_abc123">
    \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\  <cim:BaseVoltage rdf:ID="_abc456">
    \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\  <cim:BaseVoltage rdf:ID="_xyz789">
    \\    <cim:BaseVoltage.nominalVoltage>400</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\</rdf:RDF>
;

test "get_object_by_id_prefix returns a unique match" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, PREFIX_TEST_XML));
    defer model.deinit(gpa);

    const matches = try model.get_object_by_id_prefix(gpa, "xyz");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("_xyz789", matches[0].id);
}

test "get_object_by_id_prefix returns all ambiguous matches" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, PREFIX_TEST_XML));
    defer model.deinit(gpa);

    const matches = try model.get_object_by_id_prefix(gpa, "abc");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);

    var seen_123 = false;
    var seen_456 = false;
    for (matches) |m| {
        if (std.mem.eql(u8, m.id, "_abc123")) seen_123 = true;
        if (std.mem.eql(u8, m.id, "_abc456")) seen_456 = true;
    }
    try std.testing.expect(seen_123 and seen_456);
}

test "get_object_by_id_prefix returns empty slice on no match" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, PREFIX_TEST_XML));
    defer model.deinit(gpa);

    const matches = try model.get_object_by_id_prefix(gpa, "nope");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "get_object_by_id_prefix accepts prefix with explicit underscore" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, PREFIX_TEST_XML));
    defer model.deinit(gpa);

    const matches = try model.get_object_by_id_prefix(gpa, "_xyz");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("_xyz789", matches[0].id);
}

test "get_object_by_id_prefix matches full mRID" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, PREFIX_TEST_XML));
    defer model.deinit(gpa);

    const matches = try model.get_object_by_id_prefix(gpa, "_abc123");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("_abc123", matches[0].id);
}
