const std = @import("std");
const tag_index = @import("tag_index.zig");
pub const CimObject = tag_index.CimObject;
const TagBoundary = tag_index.TagBoundary;

pub const CimModel = struct {
    objects: []CimObject,
    id_to_index: std.StringHashMap(u32),
    type_index: std.StringHashMap(std.ArrayList(u32)),

    xml: []const u8,
    boundaries: []TagBoundary,

    pub fn init(gpa: std.mem.Allocator, xml: []const u8) !CimModel {
        var boundaries = try tag_index.findTagBoundaries(gpa, xml);
        errdefer boundaries.deinit(gpa);

        var objects: std.ArrayList(tag_index.CimObject) = .empty;
        errdefer objects.deinit(gpa);

        var id_to_index = std.StringHashMap(u32).init(gpa);
        errdefer id_to_index.deinit();

        var type_index = std.StringHashMap(std.ArrayList(u32)).init(gpa);
        errdefer {
            // Need to deinit all inner ArrayLists first!
            var it = type_index.valueIterator();
            while (it.next()) |list| list.deinit(gpa);
            type_index.deinit();
        }

        for (boundaries.items, 0..) |tag, i| {
            // Try rdf:ID first, then fall back to rdf:about (for FullModel etc.)
            const id = tag_index.extractRdfId(xml, tag.start) catch |err| switch (err) {
                error.NoRdfId => tag_index.extractRdfAbout(xml, tag.start) catch continue,
                error.MalformedTag => continue,
            };
            if (id.len > 0) {
                const closing_tag: u32 = tag_index.findClosingTag(xml, boundaries.items, @intCast(i)) catch |err| blk: {
                    // Handle self-closing tags by using the same index for open and close
                    if (err == error.SelfClosingTag) {
                        break :blk @intCast(i);
                    }
                    return err;
                };
                const object = try tag_index.CimObject.init(
                    xml,
                    boundaries.items,
                    @intCast(i),
                    closing_tag,
                );
                try objects.append(gpa, object);
                try id_to_index.put(id, @intCast(objects.items.len - 1));
                const type_name = object.type_name;
                const object_idx: u32 = @intCast(objects.items.len - 1);
                const result = try type_index.getOrPut(type_name);
                if (!result.found_existing) {
                    // First object of this type - create new ArrayList
                    result.value_ptr.* = .empty;
                }
                try result.value_ptr.append(gpa, object_idx);
            }
        }
        // Convert boundaries first to get final slice address
        const final_boundaries = try boundaries.toOwnedSlice(gpa);

        // Update all CimObjects to point to the final boundaries slice
        for (objects.items) |*obj| {
            obj.boundaries = final_boundaries;
        }

        return .{
            .objects = try objects.toOwnedSlice(gpa),
            .id_to_index = id_to_index,
            .type_index = type_index,
            .xml = xml,
            .boundaries = final_boundaries,
        };
    }

    pub fn deinit(self: *CimModel, gpa: std.mem.Allocator) void {
        // Free all inner ArrayLists in type_index
        var it = self.type_index.valueIterator();
        while (it.next()) |list| {
            list.deinit(gpa);
        }

        // Free the HashMaps
        self.type_index.deinit();
        self.id_to_index.deinit();

        // Free the slices
        gpa.free(self.objects);
        gpa.free(self.boundaries);
    }

    pub fn getObjectById(self: CimModel, id: []const u8) ?*const CimObject {
        const idx = self.id_to_index.get(id) orelse return null;
        return &self.objects[idx];
    }

    pub fn getObjectsByType(self: CimModel, gpa: std.mem.Allocator, type_name: []const u8) ![]const CimObject {
        const indices = self.type_index.get(type_name) orelse return &[_]CimObject{};

        const result = try gpa.alloc(CimObject, indices.items.len);

        for (indices.items, 0..) |idx, i| {
            result[i] = self.objects[idx];
        }

        return result;
    }

    pub fn getTypeCounts(self: CimModel, gpa: std.mem.Allocator) !std.StringHashMap(u32) {
        var result = std.StringHashMap(u32).init(gpa);
        errdefer result.deinit();
        var it = self.type_index.iterator();
        while (it.next()) |entry| {
            const type_name = entry.key_ptr.*;
            const count: u32 = @intCast(entry.value_ptr.*.items.len);
            try result.put(type_name, count);
        }
        return result;
    }
};
