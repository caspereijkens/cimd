const std = @import("std");
const assert = std.debug.assert;
const cli = @import("cli.zig");
const cim_model = @import("cim_model.zig");
const print = @import("print.zig");
const extract_rdf_resource = @import("tag_index.zig").extract_rdf_resource;
const extract_rdf_id = @import("tag_index.zig").extract_rdf_id;
const strip_hash = @import("utils.zig").strip_hash;

/// Interactively browse CIM objects by following rdf:resource references.
/// `xml` must be the same backing slice used to build `model`.
/// `entry_id` is the rdf:ID (without leading `_`) of the first object to display.
pub fn browse(
    gpa: std.mem.Allocator,
    model: *const cim_model.CimModel,
    xml: []const u8,
    entry_id: []const u8,
) !void {
    var trace_ids: std.ArrayList([]const u8) = .empty;
    defer trace_ids.deinit(gpa);
    var trace_types: std.ArrayList([]const u8) = .empty;
    defer trace_types.deinit(gpa);

    // Both reused across iterations — backing memory is retained, no per-iteration allocation.
    var screen_buf: std.ArrayList(u8) = .empty;
    defer screen_buf.deinit(gpa);
    var ref_list: std.ArrayList([]const u8) = .empty;
    defer ref_list.deinit(gpa);

    var id = entry_id;

    while (true) blk: {
        assert(trace_ids.items.len == trace_types.items.len);

        const object = model.getObjectById(id) orelse {
            print.not_found("{s}", .{id});
        };
        const opening_tag = object.boundaries[object.object_tag_idx];
        const closing_tag = object.boundaries[object.closing_tag_idx];
        const object_xml = xml[opening_tag.start .. closing_tag.end + 1];

        screen_buf.clearRetainingCapacity();
        ref_list.clearRetainingCapacity();
        const w = screen_buf.writer(gpa);

        var it = std.mem.splitScalar(u8, object_xml, '\n');
        var counter: u32 = 1;
        while (it.next()) |line| {
            if (extract_rdf_id(line, 0) catch null != null) {
                try w.writeAll("\n|     |  ");
                try append_colored_id_line(gpa, line, &screen_buf);
                continue;
            }
            const rdf_resource = try extract_rdf_resource(line, 0);
            if (rdf_resource) |val| {
                try w.print("\n|  {d}  |  ", .{counter});
                try append_colored_ref_line(gpa, line, &screen_buf);
                try ref_list.append(gpa, strip_hash(val));
                counter += 1;
            } else {
                try w.print("\n|     |  {s}", .{line});
            }
        }

        try w.writeAll("\n\n");
        for (trace_types.items) |past_type| try w.print("{s} -> ", .{past_type});
        try w.print("{s}\n\n", .{object.type_name});

        const has_refs = counter > 1;
        const has_back = trace_ids.items.len > 0;

        for (1..counter) |n| try w.print(" [{d}]", .{n});
        if (has_back) try w.writeAll("  [b]ack");
        try w.writeAll("  [q]uit\n\n");

        _ = try std.fs.File.stdout().write(screen_buf.items);

        var io_buf: [64]u8 = undefined;
        var stdin = std.fs.File.stdin().reader(&io_buf);
        const input = try stdin.interface.takeDelimiterExclusive('\n');

        if (input.len == 0) continue;
        switch (input[0]) {
            'b' => {
                if (!has_back) {
                    _ = try std.fs.File.stdout().write("Already at root — [q]uit to exit.\n\n");
                    continue;
                }
                id = trace_ids.pop() orelse unreachable;
                _ = trace_types.pop();
                break :blk;
            },
            'q' => break,
            else => {
                if (!has_refs) {
                    if (has_back) {
                        _ = try std.fs.File.stdout().write("No references — [b]ack or [q]uit\n\n");
                    } else {
                        _ = try std.fs.File.stdout().write("No references — [q]uit to exit\n\n");
                    }
                    continue;
                }
                const n = std.fmt.parseInt(u32, input, 10) catch {
                    if (has_back) {
                        try print.stdout("Invalid input — pick 1-{d}, [b]ack or [q]uit\n", .{counter - 1});
                    } else {
                        try print.stdout("Invalid input — pick 1-{d} or [q]uit\n", .{counter - 1});
                    }
                    continue;
                };
                if (n == 0 or n > ref_list.items.len) {
                    if (has_back) {
                        try print.stdout("Pick 1-{d}, [b]ack or [q]uit\n", .{counter - 1});
                    } else {
                        try print.stdout("Pick 1-{d} or [q]uit\n", .{counter - 1});
                    }
                    continue;
                }
                try trace_ids.append(gpa, id);
                try trace_types.append(gpa, object.type_name);
                id = ref_list.items[n - 1];
            },
        }
    }
}

/// Append `line` to `buf` with the CIM type suffix (after `:`) colored yellow.
/// Used for the object's own opening tag, which carries rdf:ID.
/// Falls back to the plain line if the expected pattern is absent.
fn append_colored_id_line(gpa: std.mem.Allocator, line: []const u8, buf: *std.ArrayList(u8)) !void {
    assert(line.len > 0);
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
        try buf.appendSlice(gpa, line);
        return;
    };
    const rdf_marker = std.mem.indexOf(u8, line, " rdf:ID=\"") orelse {
        try buf.appendSlice(gpa, line);
        return;
    };
    try buf.appendSlice(gpa, line[0 .. colon + 1]);
    try buf.appendSlice(gpa, cli.ansi_yellow);
    try buf.appendSlice(gpa, line[colon + 1 .. rdf_marker]);
    try buf.appendSlice(gpa, cli.ansi_default);
    try buf.appendSlice(gpa, line[rdf_marker..]);
}

/// Append `line` to `buf` with the attribute name (after `.`) colored green.
/// Used for reference lines that carry rdf:resource.
/// Falls back to the plain line if the expected pattern is absent.
fn append_colored_ref_line(gpa: std.mem.Allocator, line: []const u8, buf: *std.ArrayList(u8)) !void {
    assert(line.len > 0);
    const dot = std.mem.indexOfScalar(u8, line, '.') orelse {
        try buf.appendSlice(gpa, line);
        return;
    };
    const rdf_marker = std.mem.indexOf(u8, line, " rdf:") orelse {
        try buf.appendSlice(gpa, line);
        return;
    };
    try buf.appendSlice(gpa, line[0 .. dot + 1]);
    try buf.appendSlice(gpa, cli.ansi_green);
    try buf.appendSlice(gpa, line[dot + 1 .. rdf_marker]);
    try buf.appendSlice(gpa, cli.ansi_default);
    try buf.appendSlice(gpa, line[rdf_marker..]);
}
