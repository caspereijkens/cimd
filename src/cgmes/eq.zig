const std = @import("std");
const tag_index = @import("tag_index.zig");
pub const CimObject = tag_index.CimObject;
const TagBoundary = tag_index.TagBoundary;
const cgmes_ids = @import("ids.zig");
const cim_types = @import("cim_types.zig");

const assert = std.debug.assert;

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
    };

    /// Takes ownership of `xml`: on success the model owns it (freed by deinit),
    /// on error it is freed before returning. Callers never need to clean up `xml`.
    pub fn init(gpa: std.mem.Allocator, xml: []const u8) !EQ {
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
            if (seen.found_existing) return error.DuplicateId;
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
        // Pairs with the duplicate-id rejection at line 53: every object must
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

    /// Result of resolving a (prefix, optional type) pair to a single object.
    /// The `matches` slice contains every object whose mRID starts with the prefix
    /// (in storage order). The caller owns it and must call `deinit`.
    /// `outcome` tells the caller what to do with `matches`.
    pub const PrefixResolution = struct {
        matches: []const CimObject,
        outcome: Outcome,

        pub const Outcome = union(enum) {
            /// Zero objects match the prefix.
            none,
            /// Exactly one object remains after optional type narrowing. The
            /// payload indexes into `matches`.
            unique: usize,
            /// Exactly one prefix match exists, but its type differs from the
            /// requested `type_filter`. The payload indexes into `matches`.
            type_mismatch: usize,
            /// Multiple prefix matches exist and none are of the requested type.
            none_of_type,
            /// Multiple prefix matches exist and no type filter was given.
            ambiguous_any,
            /// Multiple prefix matches of the requested type remain after narrowing.
            ambiguous_of_type,
        };

        pub fn deinit(self: PrefixResolution, gpa: std.mem.Allocator) void {
            gpa.free(self.matches);
        }
    };

    /// Resolve a prefix (optionally narrowed by `type_filter`) to a single object.
    /// See `PrefixResolution` for the possible outcomes.
    pub fn resolve_by_prefix(
        self: EQ,
        gpa: std.mem.Allocator,
        id_prefix: []const u8,
        type_filter: ?[]const u8,
    ) !PrefixResolution {
        const matches = try self.get_object_by_id_prefix(gpa, id_prefix);
        errdefer gpa.free(matches);

        if (matches.len == 0) return .{ .matches = matches, .outcome = .none };

        if (matches.len == 1) {
            if (type_filter) |t| {
                if (!std.mem.eql(u8, matches[0].type_name, t))
                    return .{ .matches = matches, .outcome = .{ .type_mismatch = 0 } };
            }
            return .{ .matches = matches, .outcome = .{ .unique = 0 } };
        }

        if (type_filter) |t| {
            var hits: usize = 0;
            var hit_idx: usize = 0;
            for (matches, 0..) |m, i| {
                if (std.mem.eql(u8, m.type_name, t)) {
                    hits += 1;
                    hit_idx = i;
                }
            }
            if (hits == 0) return .{ .matches = matches, .outcome = .none_of_type };
            if (hits == 1) return .{ .matches = matches, .outcome = .{ .unique = hit_idx } };
            return .{ .matches = matches, .outcome = .ambiguous_of_type };
        }

        return .{ .matches = matches, .outcome = .ambiguous_any };
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

    pub fn getTypeCounts(self: EQ, gpa: std.mem.Allocator) !std.StringHashMap(u32) {
        var result = std.StringHashMap(u32).init(gpa);
        errdefer result.deinit();
        var it = self.type_index.iterator();
        while (it.next()) |entry| {
            const type_name = entry.key_ptr.*;
            const count: u32 = entry.value_ptr.*.len;
            try result.put(type_name, count);
        }
        return result;
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

        std.mem.sort(TypeCount, out, {}, struct {
            fn lessThan(_: void, a: TypeCount, b: TypeCount) bool {
                return std.mem.order(u8, a.type_name, b.type_name) == .lt;
            }
        }.lessThan);

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
        if (about.len > 0) return about;
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

const RESOLVE_TEST_XML =
    \\<rdf:RDF>
    \\  <cim:BaseVoltage rdf:ID="_abc111">
    \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\  <cim:BaseVoltage rdf:ID="_abc222">
    \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\  <cim:Substation rdf:ID="_abc333">
    \\    <cim:IdentifiedObject.name>SS-A</cim:IdentifiedObject.name>
    \\  </cim:Substation>
    \\  <cim:Substation rdf:ID="_xyz999">
    \\    <cim:IdentifiedObject.name>SS-X</cim:IdentifiedObject.name>
    \\  </cim:Substation>
    \\</rdf:RDF>
;

test "resolve_by_prefix: unique match, no type filter" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, RESOLVE_TEST_XML));
    defer model.deinit(gpa);

    const r = try model.resolve_by_prefix(gpa, "xyz", null);
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), r.matches.len);
    switch (r.outcome) {
        .unique => |idx| try std.testing.expectEqualStrings("_xyz999", r.matches[idx].id),
        else => return error.TestExpectedUnique,
    }
}

test "resolve_by_prefix: unique match with matching type" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, RESOLVE_TEST_XML));
    defer model.deinit(gpa);

    const r = try model.resolve_by_prefix(gpa, "xyz", "Substation");
    defer r.deinit(gpa);
    switch (r.outcome) {
        .unique => |idx| try std.testing.expectEqualStrings("_xyz999", r.matches[idx].id),
        else => return error.TestExpectedUnique,
    }
}

test "resolve_by_prefix: single match, wrong type" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, RESOLVE_TEST_XML));
    defer model.deinit(gpa);

    const r = try model.resolve_by_prefix(gpa, "xyz", "BaseVoltage");
    defer r.deinit(gpa);
    switch (r.outcome) {
        .type_mismatch => |idx| try std.testing.expectEqualStrings("Substation", r.matches[idx].type_name),
        else => return error.TestExpectedTypeMismatch,
    }
}

test "resolve_by_prefix: no prefix matches" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, RESOLVE_TEST_XML));
    defer model.deinit(gpa);

    const r = try model.resolve_by_prefix(gpa, "nope", null);
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), r.matches.len);
    try std.testing.expect(r.outcome == .none);
}

test "resolve_by_prefix: ambiguous prefix without type filter" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, RESOLVE_TEST_XML));
    defer model.deinit(gpa);

    const r = try model.resolve_by_prefix(gpa, "abc", null);
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), r.matches.len);
    try std.testing.expect(r.outcome == .ambiguous_any);
}

test "resolve_by_prefix: ambiguous prefix narrowed to unique by type" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, RESOLVE_TEST_XML));
    defer model.deinit(gpa);

    const r = try model.resolve_by_prefix(gpa, "abc", "Substation");
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), r.matches.len);
    switch (r.outcome) {
        .unique => |idx| {
            try std.testing.expectEqualStrings("_abc333", r.matches[idx].id);
            try std.testing.expectEqualStrings("Substation", r.matches[idx].type_name);
        },
        else => return error.TestExpectedUnique,
    }
}

test "resolve_by_prefix: ambiguous prefix with no objects of the given type" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, RESOLVE_TEST_XML));
    defer model.deinit(gpa);

    const r = try model.resolve_by_prefix(gpa, "abc", "Terminal");
    defer r.deinit(gpa);
    try std.testing.expect(r.outcome == .none_of_type);
}

test "resolve_by_prefix: ambiguous prefix with multiple of the given type" {
    const gpa = std.testing.allocator;
    var model = try EQ.init(gpa, try gpa.dupe(u8, RESOLVE_TEST_XML));
    defer model.deinit(gpa);

    const r = try model.resolve_by_prefix(gpa, "abc", "BaseVoltage");
    defer r.deinit(gpa);
    try std.testing.expect(r.outcome == .ambiguous_of_type);
}
