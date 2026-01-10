const std = @import("std");
const cim_model = @import("cim_model.zig");

/// Format and print an error message to stderr, then exit with an exit code of 1.
pub fn stderr(comptime fmt_str: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: " ++ fmt_str ++ "\n", args) catch "error: (message too long)\n";
    _ = std.fs.File.stderr().write(msg) catch {};
    std.process.exit(1);
}

pub fn stdout(comptime fmt_str: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, fmt_str, args);
    _ = try std.fs.File.stdout().write(msg);
}

pub fn displayObjectInventory(gpa: std.mem.Allocator, model: cim_model.CimModel) !void {
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
