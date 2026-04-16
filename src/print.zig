const std = @import("std");
const cim_model = @import("cim_model.zig");
const tag_index = @import("tag_index.zig");
const utils = @import("utils.zig");

/// Print a usage error to stderr and exit 2.
/// Use for invalid arguments, missing flags, bad input — anything the caller did wrong.
pub fn stderr(io: std.Io, comptime fmt_str: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: " ++ fmt_str ++ "\n", args) catch "error: (message too long)\n";
    _ = std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    std.process.exit(2);
}

/// Print a not-found message to stderr and exit 1.
/// Use when a requested resource (e.g. mRID) does not exist in the model.
pub fn not_found(io: std.Io, comptime fmt_str: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "not found: " ++ fmt_str ++ "\n", args) catch "not found: (message too long)\n";
    _ = std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    std.process.exit(1);
}

/// Write informational (non-error) output to stderr. Returns an error on write failure.
/// Use for diagnostic/progress output that should not pollute stdout data.
pub fn stderr_info(io: std.Io, comptime fmt_str: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, fmt_str, args);
    _ = try std.Io.File.stderr().writeStreamingAll(io, msg);
}

pub fn stdout(io: std.Io, comptime fmt_str: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, fmt_str, args);
    try std.Io.File.stdout().writeStreamingAll(io, msg);
}

pub fn display_object_inventory_json(io: std.Io, gpa: std.mem.Allocator, model: cim_model.CimModel) !void {
    var counts = try model.getTypeCounts(gpa);
    defer counts.deinit();

    var type_names: std.ArrayList([]const u8) = .empty;
    defer type_names.deinit(gpa);

    var it = counts.iterator();
    while (it.next()) |entry| try type_names.append(gpa, entry.key_ptr.*);

    std.mem.sort([]const u8, type_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    try stdout(io, "[", .{});
    for (type_names.items, 0..) |type_name, i| {
        const count = counts.get(type_name).?;
        if (i > 0) try stdout(io, ",", .{});
        try stdout(io, "{{\"type\":\"{s}\",\"count\":{d}}}", .{ type_name, count });
    }
    try stdout(io, "]\n", .{});
}

pub fn display_object_inventory(io: std.Io, gpa: std.mem.Allocator, model: cim_model.CimModel) !void {
    var counts = try model.getTypeCounts(gpa);
    defer counts.deinit();

    // Sort type names alphabetically for consistent output
    var type_names: std.ArrayList([]const u8) = .empty;
    defer type_names.deinit(gpa);

    var it = counts.iterator();
    while (it.next()) |entry| {
        try type_names.append(gpa, entry.key_ptr.*);
    }

    // Sort alphabetically
    std.mem.sort([]const u8, type_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // Display each type and count
    var total: usize = 0;
    for (type_names.items) |type_name| {
        const count = counts.get(type_name).?;
        try stdout(io, "{s}: {d} objects\n", .{ type_name, count });
        total += count;
    }

    try stdout(io, "Total: {d} objects\n\n", .{total});
}

pub fn display_object(io: std.Io, gpa: std.mem.Allocator, obj: tag_index.CimObjectView) !void {
    try stdout(io, "Type: {s}\n", .{obj.type_name});
    try stdout(io, "ID: {s}\n", .{obj.id});

    // Get all properties and references
    var props = try obj.getAllProperties(gpa);
    defer props.deinit();

    var refs = try obj.getAllReferences(gpa);
    defer refs.deinit();

    // Display properties if any
    if (props.count() > 0) {
        try stdout(io, "\nProperties:\n", .{});

        // Sort property names for consistent output
        var prop_names: std.ArrayList([]const u8) = .empty;
        defer prop_names.deinit(gpa);

        var prop_it = props.iterator();
        while (prop_it.next()) |entry| {
            try prop_names.append(gpa, entry.key_ptr.*);
        }

        std.mem.sort([]const u8, prop_names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (prop_names.items) |name| {
            const value = props.get(name).?;
            try stdout(io, "  {s}: {s}\n", .{ name, value });
        }
    }

    // Display references if any
    if (refs.count() > 0) {
        try stdout(io, "\nReferences:\n", .{});

        // Sort reference names for consistent output
        var ref_names: std.ArrayList([]const u8) = .empty;
        defer ref_names.deinit(gpa);

        var ref_it = refs.iterator();
        while (ref_it.next()) |entry| {
            try ref_names.append(gpa, entry.key_ptr.*);
        }

        std.mem.sort([]const u8, ref_names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (ref_names.items) |name| {
            const value = refs.get(name).?;
            try stdout(io, "  {s}: {s}\n", .{ name, value });
        }
    }

    try stdout(io, "\n", .{});
}

pub fn display_object_list(io: std.Io, gpa: std.mem.Allocator, model: *const cim_model.CimModel, objects: []const tag_index.CimObject) !void {
    for (objects, 1..) |obj, i| {
        try stdout(io, "[{d}] {s}\n", .{ i, obj.id });
        try display_object(gpa, model.view(obj));
    }
}

pub fn display_object_json(io: std.Io, gpa: std.mem.Allocator, obj: tag_index.CimObjectView) !void {
    var props = try obj.getAllProperties(gpa);
    defer props.deinit();
    var refs = try obj.getAllReferences(gpa);
    defer refs.deinit();

    try stdout(io, "{{\"id\":\"{s}\",\"type\":\"{s}\",\"properties\":{{", .{ obj.id, obj.type_name });
    var first = true;
    var prop_it = props.iterator();
    while (prop_it.next()) |entry| {
        if (!first) try stdout(io, ",", .{});
        try stdout(io, "\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
        first = false;
    }
    try stdout(io, "}},\"references\":{{", .{});
    first = true;
    var ref_it = refs.iterator();
    while (ref_it.next()) |entry| {
        if (!first) try stdout(io, ",", .{});
        try stdout(io, "\"{s}\":\"{s}\"", .{ entry.key_ptr.*, utils.strip_hash(entry.value_ptr.*) });
        first = false;
    }
    try stdout(io, "}}}}\n", .{});
}

pub fn display_object_list_json(io: std.Io, model: *const cim_model.CimModel, objects: []const tag_index.CimObject, fields: []const []const u8) !void {
    try stdout(io, "[", .{});
    for (objects, 0..) |obj, i| {
        if (i > 0) try stdout(io, ",", .{});
        const view = model.view(obj);
        try stdout(io, "{{\"id\":\"{s}\",\"type\":\"{s}\"", .{ obj.id, obj.type_name });
        if (fields.len == 0) {
            const name = try view.getProperty("IdentifiedObject.name") orelse "";
            try stdout(io, ",\"IdentifiedObject.name\":\"{s}\"", .{name});
        } else {
            for (fields) |field| {
                const val = try view.getProperty(field) orelse "";
                try stdout(io, ",\"{s}\":\"{s}\"", .{ field, val });
            }
        }
        try stdout(io, "}}", .{});
    }
    try stdout(io, "]\n", .{});
}
