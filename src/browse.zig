const std = @import("std");
const assert = std.debug.assert;
const cli = @import("cli.zig");
const cim_model = @import("cim_model.zig");
const print = @import("print.zig");
const extract_rdf_resource = @import("tag_index.zig").extract_rdf_resource;
const extract_rdf_id = @import("tag_index.zig").extract_rdf_id;
const strip_hash = @import("utils.zig").strip_hash;

const Nav = union(enum) { stay, back, quit, follow: []const u8 };

/// Interactively browse CIM objects by following rdf:resource references.
/// `xml` must be the same backing slice used to build `model`.
/// `mrid` is the mRID of the first object to display.
pub fn browse(
    io: std.Io,
    gpa: std.mem.Allocator,
    model: *const cim_model.CimModel,
    xml: []const u8,
    mrid: []const u8,
) !void {
    var trace_ids: std.ArrayList([]const u8) = .empty;
    defer trace_ids.deinit(gpa);
    var trace_types: std.ArrayList([]const u8) = .empty;
    defer trace_types.deinit(gpa);
    // Both reused across iterations — backing memory is retained, no per-iteration allocation.
    var screen: std.Io.Writer.Allocating = .init(gpa);
    defer screen.deinit();
    var ref_list: std.ArrayList([]const u8) = .empty;
    defer ref_list.deinit(gpa);

    var id = mrid;
    while (true) blk: {
        assert(trace_ids.items.len == trace_types.items.len);

        const object = model.getObjectById(id) orelse print.not_found(io, "{s}", .{id});
        const object_xml = xml[object.boundaries[object.object_tag_idx].start .. object.boundaries[object.closing_tag_idx].end + 1];

        screen.clearRetainingCapacity();
        ref_list.clearRetainingCapacity();

        const writer = &screen.writer;
        const counter = try render_object_xml(writer, gpa, object_xml, &ref_list);
        try render_footer(writer, trace_types.items, object.type_name, counter, trace_ids.items.len > 0);
        try std.Io.File.stdout().writeStreamingAll(io, screen.written());

        var input_buffer: [64]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(io, &input_buffer);
        const input = stdin.interface.takeDelimiterExclusive('\n') catch continue;
        if (input.len == 0) continue;

        switch (try handle_input(io, input, counter, trace_ids.items.len > 0, ref_list.items)) {
            .stay => continue,
            .back => {
                id = trace_ids.pop() orelse unreachable;
                _ = trace_types.pop();
                break :blk;
            },
            .quit => break,
            .follow => |new_id| {
                try trace_ids.append(gpa, id);
                try trace_types.append(gpa, object.type_name);
                id = new_id;
            },
        }
    }
}

/// Iterates XML lines, renders each row into `writer`, populates `ref_list`.
/// Returns the number of navigable references found (1-based counter after last ref).
fn render_object_xml(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    object_xml: []const u8,
    ref_list: *std.ArrayList([]const u8),
) !u32 {
    assert(object_xml.len > 0);
    var it = std.mem.splitScalar(u8, object_xml, '\n');
    var counter: u32 = 1;
    while (it.next()) |line| {
        if (extract_rdf_id(line, 0) catch null != null) {
            try writer.writeAll("\n|     |  ");
            try append_colored_id_line(writer, line);
            continue;
        }
        const rdf_resource = try extract_rdf_resource(line, 0);
        if (rdf_resource) |val| {
            try writer.print("\n|  {d}  |  ", .{counter});
            try append_colored_ref_line(writer, line);
            try ref_list.append(gpa, strip_hash(val));
            counter += 1;
        } else {
            try writer.print("\n|     |  {s}", .{line});
        }
    }
    assert(ref_list.items.len == counter - 1);
    return counter;
}

/// Writes the breadcrumb trail, type name, and keyboard hint line.
fn render_footer(
    writer: *std.Io.Writer,
    trace_types: []const []const u8,
    type_name: []const u8,
    counter: u32,
    has_back: bool,
) !void {
    assert(counter >= 1);
    assert(type_name.len > 0);
    try writer.writeAll("\n\n");
    for (trace_types) |past_type| try writer.print("{s} -> ", .{past_type});
    try writer.print("{s}\n\n", .{type_name});
    for (1..counter) |n| try writer.print(" [{d}]", .{n});
    if (has_back) try writer.writeAll("  [b]ack");
    try writer.writeAll("  [q]uit\n\n");
}

/// Parses a single line of user input and returns the navigation action.
/// Writes error/hint messages directly to stdout for invalid input.
fn handle_input(
    io: std.Io,
    input: []const u8,
    counter: u32,
    has_back: bool,
    ref_list: []const []const u8,
) !Nav {
    assert(input.len > 0);
    assert(ref_list.len == counter - 1);
    const has_refs = counter > 1;
    switch (input[0]) {
        'q' => return .quit,
        'b' => {
            if (!has_back) {
                try std.Io.File.stdout().writeStreamingAll(io, "Already at root — [q]uit to exit.\n\n");
                return .stay;
            }
            return .back;
        },
        else => {
            if (!has_refs) {
                const msg = if (has_back) "No references — [b]ack or [q]uit\n\n" else "No references — [q]uit to exit\n\n";
                try std.Io.File.stdout().writeStreamingAll(io, msg);
                return .stay;
            }
            const n = std.fmt.parseInt(u32, input, 10) catch {
                const suffix = if (has_back) ", [b]ack or [q]uit\n" else " or [q]uit\n";
                try print.stdout(io, "Invalid input — pick 1-{d}{s}", .{ counter - 1, suffix });
                return .stay;
            };
            if (n == 0 or n > ref_list.len) {
                const suffix = if (has_back) ", [b]ack or [q]uit\n" else " or [q]uit\n";
                try print.stdout(io, "Pick 1-{d}{s}", .{ counter - 1, suffix });
                return .stay;
            }
            return .{ .follow = ref_list[n - 1] };
        },
    }
}

/// Write `line` to `w` with the CIM type suffix (after `:`) colored yellow.
/// Used for the object's own opening tag, which carries rdf:ID.
/// Falls back to the plain line if the expected pattern is absent.
fn append_colored_id_line(writer: *std.Io.Writer, line: []const u8) !void {
    assert(line.len > 0);
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
        try writer.writeAll(line);
        return;
    };
    const rdf_marker = std.mem.indexOf(u8, line, " rdf:ID=\"") orelse {
        try writer.writeAll(line);
        return;
    };
    try writer.writeAll(line[0 .. colon + 1]);
    try writer.writeAll(cli.ansi_yellow);
    try writer.writeAll(line[colon + 1 .. rdf_marker]);
    try writer.writeAll(cli.ansi_default);
    try writer.writeAll(line[rdf_marker..]);
}

/// Write `line` to `w` with the attribute name (after `.`) colored green.
/// Used for reference lines that carry rdf:resource.
/// Falls back to the plain line if the expected pattern is absent.
fn append_colored_ref_line(writer: *std.Io.Writer, line: []const u8) !void {
    assert(line.len > 0);
    const dot = std.mem.indexOfScalar(u8, line, '.') orelse {
        try writer.writeAll(line);
        return;
    };
    const rdf_marker = std.mem.indexOf(u8, line, " rdf:") orelse {
        try writer.writeAll(line);
        return;
    };
    try writer.writeAll(line[0 .. dot + 1]);
    try writer.writeAll(cli.ansi_green);
    try writer.writeAll(line[dot + 1 .. rdf_marker]);
    try writer.writeAll(cli.ansi_default);
    try writer.writeAll(line[rdf_marker..]);
}
