const std = @import("std");
const tag_index = @import("tag_index.zig");
pub const CimObject = tag_index.CimObject;
const TagBoundary = tag_index.TagBoundary;

pub const CimModel = struct {
    objects: []CimObject,
    id_to_index: std.StringHashMap(u32),
    type_index: std.StringHashMap(TypeRange),

    xml: []const u8,
    boundaries: []TagBoundary,

    const TypeRange = struct { start: u32, len: u32 };

    pub fn init(gpa: std.mem.Allocator, xml: []const u8) !CimModel {
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

        for (boundaries.items, 0..) |tag, i| {
            // Try rdf:ID first, then fall back to rdf:about (for FullModel etc.)
            const id = tag_index.extract_rdf_id(xml, tag.start) catch |err| switch (err) {
                error.NoRdfId => tag_index.extract_rdf_about(xml, tag.start) catch continue,
                error.MalformedTag => continue,
            };
            if (id.len > 0) {
                // Pass pre-computed id — avoids re-scanning the tag in CimObject.init.
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
            }
        }

        // Convert boundaries to get final slice address.
        const final_boundaries = try boundaries.toOwnedSlice(gpa);

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
            sorted_objects[cursor.*].boundaries = final_boundaries;
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
            .boundaries = final_boundaries,
        };
    }

    pub fn deinit(self: *CimModel, gpa: std.mem.Allocator) void {
        self.type_index.deinit();
        self.id_to_index.deinit();
        gpa.free(self.objects);
        gpa.free(self.boundaries);
    }

    pub fn getObjectById(self: CimModel, id: []const u8) ?*const CimObject {
        const idx = self.id_to_index.get(id) orelse return null;
        return &self.objects[idx];
    }

    pub fn get_objects_by_type(self: CimModel, type_name: []const u8) []const CimObject {
        const range = self.type_index.get(type_name) orelse return &[_]CimObject{};
        return self.objects[range.start .. range.start + range.len];
    }

    pub fn getTypeCounts(self: CimModel, gpa: std.mem.Allocator) !std.StringHashMap(u32) {
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
};
