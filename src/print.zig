const std = @import("std");
const cim_model = @import("cim_model.zig");
const tag_index = @import("tag_index.zig");

/// Print a usage error to stderr and exit 2.
/// Use for invalid arguments, missing flags, bad input — anything the caller did wrong.
pub fn stderr(comptime fmt_str: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: " ++ fmt_str ++ "\n", args) catch "error: (message too long)\n";
    _ = std.fs.File.stderr().write(msg) catch {};
    std.process.exit(2);
}

/// Print a not-found message to stderr and exit 1.
/// Use when a requested resource (e.g. mRID) does not exist in the model.
pub fn not_found(comptime fmt_str: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "not found: " ++ fmt_str ++ "\n", args) catch "not found: (message too long)\n";
    _ = std.fs.File.stderr().write(msg) catch {};
    std.process.exit(1);
}

pub fn stdout(comptime fmt_str: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, fmt_str, args);
    _ = try std.fs.File.stdout().write(msg);
}

pub fn display_object_inventory_json(gpa: std.mem.Allocator, model: cim_model.CimModel) !void {
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

    try stdout("[", .{});
    for (type_names.items, 0..) |type_name, i| {
        const count = counts.get(type_name).?;
        if (i > 0) try stdout(",", .{});
        try stdout("{{\"type\":\"{s}\",\"count\":{d}}}", .{ type_name, count });
    }
    try stdout("]\n", .{});
}

pub fn display_object_inventory(gpa: std.mem.Allocator, model: cim_model.CimModel) !void {
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
        try stdout("{s}: {d} objects\n", .{ type_name, count });
        total += count;
    }

    try stdout("Total: {d} objects\n\n", .{total});
}

pub fn displayObject(gpa: std.mem.Allocator, obj: tag_index.CimObjectView) !void {
    try stdout("Type: {s}\n", .{obj.type_name});
    try stdout("ID: {s}\n", .{obj.id});

    // Get all properties and references
    var props = try obj.getAllProperties(gpa);
    defer props.deinit();

    var refs = try obj.getAllReferences(gpa);
    defer refs.deinit();

    // Display properties if any
    if (props.count() > 0) {
        try stdout("\nProperties:\n", .{});

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
            try stdout("  {s}: {s}\n", .{ name, value });
        }
    }

    // Display references if any
    if (refs.count() > 0) {
        try stdout("\nReferences:\n", .{});

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
            try stdout("  {s}: {s}\n", .{ name, value });
        }
    }

    try stdout("\n", .{});
}

pub fn display_object_list(gpa: std.mem.Allocator, model: *const cim_model.CimModel, objects: []const tag_index.CimObject) !void {
    for (objects, 1..) |obj, i| {
        try stdout("[{d}] {s}\n", .{ i, obj.id });
        try displayObject(gpa, model.view(obj));
    }
}
