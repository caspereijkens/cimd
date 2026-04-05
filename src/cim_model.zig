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

        var temp_type_index = std.StringHashMap(std.ArrayList(u32)).init(gpa);
        errdefer {
            var it = temp_type_index.valueIterator();
            while (it.next()) |list| list.deinit(gpa);
            temp_type_index.deinit();
        }

        for (boundaries.items, 0..) |tag, i| {
            // Try rdf:ID first, then fall back to rdf:about (for FullModel etc.)
            const id = tag_index.extract_rdf_id(xml, tag.start) catch |err| switch (err) {
                error.NoRdfId => tag_index.extract_rdf_about(xml, tag.start) catch continue,
                error.MalformedTag => continue,
            };
            if (id.len > 0) {
                const closing_tag: u32 = tag_index.find_closing_tag(xml, boundaries.items, @intCast(i)) catch |err| blk: {
                    // Handle self-closing tags by using the same index for open and close
                    if (err == error.SelfClosingTag) {
                        break :blk @intCast(i);
                    }
                    return err;
                };
                // Pass pre-computed id — avoids re-scanning the tag in CimObject.init.
                const object = try tag_index.CimObject.init(
                    xml,
                    boundaries.items,
                    @intCast(i),
                    closing_tag,
                    id,
                );
                try objects.append(gpa, object);
                const type_name = object.type_name;
                const object_idx: u32 = @intCast(objects.items.len - 1);
                const result = try temp_type_index.getOrPut(type_name);
                if (!result.found_existing) {
                    result.value_ptr.* = .empty;
                }
                try result.value_ptr.append(gpa, object_idx);
            }
        }

        // Convert boundaries to get final slice address
        const final_boundaries = try boundaries.toOwnedSlice(gpa);

        // Rearrange objects by type for zero-copy get_objects_by_type
        const sorted_objects = try gpa.alloc(CimObject, objects.items.len);
        errdefer gpa.free(sorted_objects);

        var type_index = std.StringHashMap(TypeRange).init(gpa);
        errdefer type_index.deinit();

        var write_pos: u32 = 0;
        var temp_it = temp_type_index.iterator();
        while (temp_it.next()) |entry| {
            const type_name = entry.key_ptr.*;
            const indices = entry.value_ptr.*;
            const start = write_pos;
            for (indices.items) |idx| {
                sorted_objects[write_pos] = objects.items[idx];
                sorted_objects[write_pos].boundaries = final_boundaries;
                write_pos += 1;
            }
            try type_index.put(type_name, .{ .start = start, .len = @intCast(indices.items.len) });
        }

        // Free temporary type index (inner ArrayLists + map)
        {
            var it = temp_type_index.valueIterator();
            while (it.next()) |list| list.deinit(gpa);
            temp_type_index.deinit();
        }
        // Reset so errdefer is a no-op
        temp_type_index = std.StringHashMap(std.ArrayList(u32)).init(gpa);
        temp_type_index.deinit();

        // Free original objects ArrayList (we copied into sorted_objects)
        objects.deinit(gpa);
        // Reset so errdefer is a no-op
        objects = .empty;

        // Rebuild id_to_index to point at sorted positions
        id_to_index.clearRetainingCapacity();
        for (sorted_objects, 0..) |obj, index| {
            try id_to_index.put(obj.id, @intCast(index));
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
