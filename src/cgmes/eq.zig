const std = @import("std");
const tag_index = @import("tag_index.zig");
pub const CimObject = tag_index.CimObject;
const TagBoundary = tag_index.TagBoundary;

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

        // Pass 3: fill sorted_objects using write cursors.
        for (objects.items) |obj| {
            const cursor = write_cursors.getPtr(obj.type_name).?;
            sorted_objects[cursor.*] = obj;
            cursor.* += 1;
        }

        // Free original objects ArrayList (copied into sorted_objects).
        objects.deinit(gpa);
        objects = .empty;

        // Build id_to_index from sorted positions.
        try id_to_index.ensureTotalCapacity(@intCast(sorted_objects.len));
        for (sorted_objects, 0..) |obj, index| {
            id_to_index.putAssumeCapacity(obj.id, @intCast(index));
        }

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
        return self.view(self.objects[idx]);
    }

    pub fn get_objects_by_type(self: EQ, type_name: []const u8) []const CimObject {
        const range = self.type_index.get(type_name) orelse return &[_]CimObject{};
        return self.objects[range.start .. range.start + range.len];
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
