const std = @import("std");
const assert = std.debug.assert;
const cli = @import("cli.zig");
const cim_model = @import("cim_model.zig");
const CimTp = @import("cim_tp.zig").CimTp;
const CimSsh = @import("cim_ssh.zig").CimSsh;
const tag_index = @import("tag_index.zig");
const print = @import("print.zig");
const extract_rdf_resource = tag_index.extract_rdf_resource;
const extract_rdf_id = tag_index.extract_rdf_id;
const strip_hash = @import("utils.zig").strip_hash;
const strip_underscore = @import("utils.zig").strip_underscore;

const Nav = union(enum) { stay, back, quit, follow: []const u8 };

/// Interactively browse CIM objects by following rdf:resource references.
/// `model` is the primary CIM file (typically EQ, possibly with concatenated EQBD).
/// `tp_opt` / `ssh_opt`, when present, overlay their patches inline below the
/// primary object and contribute references to the navigation list. TP also
/// contributes new first-class objects (e.g. TopologicalNodes) that become
/// navigable by mRID.
pub fn browse(
    io: std.Io,
    gpa: std.mem.Allocator,
    model: *const cim_model.CimModel,
    tp_opt: ?CimTp,
    ssh_opt: ?CimSsh,
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

        const object = resolve_object(model, tp_opt, id) orelse
            print.not_found(io, "{s}", .{id});

        screen.clearRetainingCapacity();
        ref_list.clearRetainingCapacity();

        const writer = &screen.writer;
        var counter: u32 = 1;

        // Primary object XML (EQ, EQBD, or TP new-object).
        counter = try render_fragment(writer, gpa, object_xml_slice(object), counter, &ref_list);

        // TP patch, if any — adds Terminal.TopologicalNode and similar references.
        if (tp_opt) |tp| {
            const stripped = strip_underscore(object.id);
            if (tp.find_patch(stripped)) |patch| {
                try writer.writeAll("\n\n--- TP ---");
                const patch_xml = tp.xml[tp.boundaries[patch.patch_tag_idx].start .. tp.boundaries[patch.closing_tag_idx].end + 1];
                counter = try render_fragment(writer, gpa, patch_xml, counter, &ref_list);
            }
        }

        // SSH patch, if any.
        if (ssh_opt) |ssh| {
            const stripped = strip_underscore(object.id);
            if (ssh.find_patch(stripped)) |patch| {
                try writer.writeAll("\n\n--- SSH ---");
                const patch_xml = ssh.xml[ssh.boundaries[patch.patch_tag_idx].start .. ssh.boundaries[patch.closing_tag_idx].end + 1];
                counter = try render_fragment(writer, gpa, patch_xml, counter, &ref_list);
            }
        }

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

/// Look up an object by id in the primary model first, then in TP's new objects.
/// TP and primary are already collision-checked at the command layer.
fn resolve_object(
    model: *const cim_model.CimModel,
    tp_opt: ?CimTp,
    id: []const u8,
) ?tag_index.CimObjectView {
    if (model.getObjectById(id)) |view| return view;
    if (tp_opt) |tp| {
        if (tp.get_object_by_id(id)) |view| return view;
    }
    return null;
}

/// Slice out the XML fragment spanning an object's opening tag through its closing tag.
/// Works for views regardless of their backing buffer (EQ, TP, SSH).
fn object_xml_slice(view: tag_index.CimObjectView) []const u8 {
    const open = view.boundaries[view.object_tag_idx].start;
    const close = view.boundaries[view.closing_tag_idx].end + 1;
    assert(close > open);
    return view.xml[open..close];
}

/// Render one XML fragment into `writer`, continuing reference numbering from `start_counter`.
/// Returns the new counter value (1-based, pointing past the last rendered reference).
fn render_fragment(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    fragment_xml: []const u8,
    start_counter: u32,
    ref_list: *std.ArrayList([]const u8),
) !u32 {
    assert(fragment_xml.len > 0);
    assert(start_counter >= 1);

    var it = std.mem.splitScalar(u8, fragment_xml, '\n');
    var counter = start_counter;
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
