const std = @import("std");
const EQ = @import("../cgmes/eq.zig").EQ;

const tag_index = @import("../cgmes/tag_index.zig");
const utils = @import("../cgmes/ids.zig");

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

/// Write raw bytes to stdout without going through fmt. Use for static text
/// (help strings, etc.) that may contain `{` or `}` which would otherwise be
/// misparsed as format placeholders.
pub fn write(io: std.Io, msg: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, msg);
}

pub fn display_object_inventory_json(io: std.Io, gpa: std.mem.Allocator, model: EQ) !void {
    const counts = try model.sorted_type_counts(gpa);
    defer gpa.free(counts);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    const w = &file_writer.interface;

    try w.writeByte('[');
    for (counts, 0..) |entry, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"type\":");
        try std.json.Stringify.value(entry.type_name, .{}, w);
        try w.print(",\"count\":{d}}}", .{entry.count});
    }
    try w.writeAll("]\n");
    try w.flush();
}

pub fn display_object_inventory(io: std.Io, gpa: std.mem.Allocator, model: EQ) !void {
    const counts = try model.sorted_type_counts(gpa);
    defer gpa.free(counts);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    const w = &file_writer.interface;

    // Display each type and count
    var total: usize = 0;
    for (counts) |entry| {
        try w.print("{s}: {d} objects\n", .{ entry.type_name, entry.count });
        total += entry.count;
    }

    try w.print("Total: {d} objects\n\n", .{total});
    try w.flush();
}

pub fn display_object_list_json(
    io: std.Io,
    gpa: std.mem.Allocator,
    model: *const EQ,
    objects: []const tag_index.CimObject,
    fields: []const []const u8,
) !void {
    var write_buffer: [64 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    const w = &file_writer.interface;

    try w.writeByte('[');
    for (objects, 0..) |obj, i| {
        if (i > 0) try w.writeByte(',');
        const view = model.view(obj);
        if (fields.len == 0) {
            // Full dump: same shape as single-object JSON. Lets callers do
            // joins and reference resolution in Python without re-fetching.
            try write_object_full_json(w, gpa, view);
        } else {
            // Projection mode: only id, type, and the requested fields.
            try w.writeAll("{\"id\":");
            try std.json.Stringify.value(obj.id, .{}, w);
            try w.writeAll(",\"type\":");
            try std.json.Stringify.value(obj.type_name, .{}, w);
            for (fields) |field| {
                // Fall back to a reference when the field isn't a text property;
                // strip the '#' so the value matches the references map shape.
                const val = if (try view.getProperty(field)) |p|
                    p
                else if (try view.getReference(field)) |r|
                    utils.strip_hash(r)
                else
                    "";
                try w.writeByte(',');
                try std.json.Stringify.value(field, .{}, w);
                try w.writeByte(':');
                try std.json.Stringify.value(val, .{}, w);
            }
            try w.writeByte('}');
        }
    }
    try w.writeAll("]\n");
    try w.flush();
}

fn write_object_full_json(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    obj: tag_index.CimObjectView,
) !void {
    var props = try obj.getAllProperties(gpa);
    defer props.deinit();
    var refs = try obj.getAllReferences(gpa);
    defer refs.deinit();

    try w.writeAll("{\"id\":");
    try std.json.Stringify.value(obj.id, .{}, w);
    try w.writeAll(",\"type\":");
    try std.json.Stringify.value(obj.type_name, .{}, w);

    try w.writeAll(",\"properties\":{");
    var first = true;
    var prop_it = props.iterator();
    while (prop_it.next()) |entry| {
        if (!first) try w.writeByte(',');
        try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
        try w.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
        first = false;
    }
    try w.writeAll("},\"references\":{");
    first = true;
    var ref_it = refs.iterator();
    while (ref_it.next()) |entry| {
        if (!first) try w.writeByte(',');
        try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
        try w.writeByte(':');
        try std.json.Stringify.value(utils.strip_hash(entry.value_ptr.*), .{}, w);
        first = false;
    }
    try w.writeAll("}}");
}
