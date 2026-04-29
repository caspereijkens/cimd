const std = @import("std");
const assert = std.debug.assert;
const cli = @import("../cli.zig");
const cim_model = @import("../cgmes/eq.zig");
const CimTp = @import("../cgmes/tp.zig").CimTp;
const CimSsh = @import("../cgmes/ssh.zig").CimSsh;
const tag_index = @import("../cgmes/tag_index.zig");
const print = @import("../io/print.zig");
const extract_rdf_resource = tag_index.extract_rdf_resource;
const extract_rdf_id = tag_index.extract_rdf_id;
const strip_hash = @import("../cgmes/ids.zig").strip_hash;
const strip_underscore = @import("../cgmes/ids.zig").strip_underscore;

const Nav = union(enum) { stay, back, quit, follow: []const u8, show_back_refs };

const Mode = enum { regular, back_refs };

/// Reverse-reference index: target raw id (e.g. "_CN42") → list of raw ids of
/// objects that mention it via rdf:resource. Built once when entering browse;
/// answers "what points at me?" in O(1) for any object.
const BackRefIndex = struct {
    map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),

    pub const empty: BackRefIndex = .{ .map = .empty };

    pub fn deinit(self: *BackRefIndex, gpa: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        self.map.deinit(gpa);
    }

    pub fn lookup(self: *const BackRefIndex, target_id: []const u8) []const []const u8 {
        const list = self.map.get(target_id) orelse return &.{};
        return list.items;
    }
};

/// Walk every CIM object (EQ, TP new objects, TP patches, SSH patches) and
/// register each rdf:resource it carries under that target's bucket.
fn build_back_ref_index(
    gpa: std.mem.Allocator,
    model: *const cim_model.CimModel,
    tp_opt: ?CimTp,
    ssh_opt: ?CimSsh,
) !BackRefIndex {
    var index: BackRefIndex = .empty;
    errdefer index.deinit(gpa);

    for (model.objects) |obj| {
        try collect_refs_from_range(gpa, &index, model.xml, model.boundaries, obj.object_tag_idx, obj.closing_tag_idx, obj.id);
    }

    if (tp_opt) |tp| {
        for (tp.new_objects) |obj| {
            try collect_refs_from_range(gpa, &index, tp.xml, tp.boundaries, obj.object_tag_idx, obj.closing_tag_idx, obj.id);
        }
        for (tp.patches) |patch| {
            const referrer_id = referrer_from_patch_tag(tp.xml, tp.boundaries[patch.patch_tag_idx].start) orelse continue;
            try collect_refs_from_range(gpa, &index, tp.xml, tp.boundaries, patch.patch_tag_idx, patch.closing_tag_idx, referrer_id);
        }
    }

    if (ssh_opt) |ssh| {
        for (ssh.patches) |patch| {
            const referrer_id = referrer_from_patch_tag(ssh.xml, ssh.boundaries[patch.patch_tag_idx].start) orelse continue;
            try collect_refs_from_range(gpa, &index, ssh.xml, ssh.boundaries, patch.patch_tag_idx, patch.closing_tag_idx, referrer_id);
        }
    }
    return index;
}

fn collect_refs_from_range(
    gpa: std.mem.Allocator,
    index: *BackRefIndex,
    xml: []const u8,
    boundaries: []const tag_index.TagBoundary,
    open_idx: u32,
    close_idx: u32,
    referrer_id: []const u8,
) !void {
    assert(referrer_id.len > 0);
    assert(close_idx >= open_idx);
    if (close_idx <= open_idx + 1) return;
    for (boundaries[open_idx + 1 .. close_idx]) |tag| {
        if (xml[tag.start + 1] == '/') continue;
        const ref = (tag_index.extract_rdf_resource(xml, tag.start) catch continue) orelse continue;
        const target = strip_hash(ref);
        if (target.len == 0) continue;
        const gop = try index.map.getOrPut(gpa, target);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, referrer_id);
    }
}

/// Patch tags carry rdf:about="#_<mrid>"; strip the '#' to get the raw id
/// that matches the EQ object's rdf:ID.
fn referrer_from_patch_tag(xml: []const u8, tag_start: u32) ?[]const u8 {
    const about = tag_index.extract_rdf_about(xml, tag_start) catch return null;
    const stripped = strip_hash(about);
    if (stripped.len == 0) return null;
    return stripped;
}

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
    var screen: std.Io.Writer.Allocating = .init(gpa);
    defer screen.deinit();
    var ref_list: std.ArrayList([]const u8) = .empty;
    defer ref_list.deinit(gpa);

    var back_refs = try build_back_ref_index(gpa, model, tp_opt, ssh_opt);
    defer back_refs.deinit(gpa);

    var id = mrid;
    var mode: Mode = .regular;
    while (true) blk: {
        assert(trace_ids.items.len == trace_types.items.len);

        const object = resolve_object(model, tp_opt, id) orelse
            print.not_found(io, "{s}", .{id});

        screen.clearRetainingCapacity();
        ref_list.clearRetainingCapacity();

        const writer = &screen.writer;
        var counter: u32 = 1;
        const referrers = back_refs.lookup(id);

        switch (mode) {
            .regular => {
                // Primary object XML (EQ, EQBD, or TP new-object).
                counter = try render_fragment(writer, gpa, tag_slice(object.xml, object.boundaries, object.object_tag_idx, object.closing_tag_idx), counter, &ref_list);

                // TP patch, if any — adds Terminal.TopologicalNode and similar references.
                if (tp_opt) |tp| {
                    const stripped = strip_underscore(object.id);
                    if (tp.find_patch(stripped)) |patch| {
                        try writer.writeAll("\n\n--- TP ---");
                        const patch_xml = tag_slice(tp.xml, tp.boundaries, patch.patch_tag_idx, patch.closing_tag_idx);
                        counter = try render_fragment(writer, gpa, patch_xml, counter, &ref_list);
                    }
                }

                // SSH patch, if any.
                if (ssh_opt) |ssh| {
                    const stripped = strip_underscore(object.id);
                    if (ssh.find_patch(stripped)) |patch| {
                        try writer.writeAll("\n\n--- SSH ---");
                        const patch_xml = tag_slice(ssh.xml, ssh.boundaries, patch.patch_tag_idx, patch.closing_tag_idx);
                        counter = try render_fragment(writer, gpa, patch_xml, counter, &ref_list);
                    }
                }
            },
            .back_refs => {
                counter = try render_back_refs(writer, gpa, model, tp_opt, object, referrers, &ref_list);
            },
        }

        const has_back = trace_ids.items.len > 0 or mode == .back_refs;
        try render_footer(writer, trace_types.items, object.type_name, counter, has_back, mode, referrers.len);
        try std.Io.File.stdout().writeStreamingAll(io, screen.written());

        var input_buffer: [64]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(io, &input_buffer);
        const input = stdin.interface.takeDelimiterExclusive('\n') catch continue;
        if (input.len == 0) continue;

        switch (try handle_input(io, input, counter, has_back, ref_list.items, mode, referrers.len)) {
            .stay => continue,
            .back => {
                if (mode == .back_refs) {
                    mode = .regular;
                    break :blk;
                }
                id = trace_ids.pop() orelse unreachable;
                _ = trace_types.pop();
                break :blk;
            },
            .quit => break,
            .follow => |new_id| {
                try trace_ids.append(gpa, id);
                try trace_types.append(gpa, object.type_name);
                id = new_id;
                mode = .regular;
            },
            .show_back_refs => {
                mode = .back_refs;
                break :blk;
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

/// Slice out the XML fragment spanning an opening tag through its closing tag,
/// extended backwards to the start of the line so original indentation is preserved.
/// Used for primary objects (EQ/EQBD/TP new) and for TP/SSH patches.
fn tag_slice(
    xml: []const u8,
    boundaries: []const tag_index.TagBoundary,
    open_idx: u32,
    close_idx: u32,
) []const u8 {
    const tag_start = boundaries[open_idx].start;
    const close = boundaries[close_idx].end + 1;
    const line_start = if (std.mem.lastIndexOfScalar(u8, xml[0..tag_start], '\n')) |nl| nl + 1 else 0;
    assert(close > line_start);
    return xml[line_start..close];
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
        // Text-content continuation lines (from elements with embedded newlines) carry no tag;
        // print verbatim so the XML stays readable instead of tripping tag extraction.
        if (std.mem.indexOfScalar(u8, line, '<') == null) {
            try writer.print("\n|     |  {s}", .{line});
            continue;
        }
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
    mode: Mode,
    referrer_count: usize,
) !void {
    assert(counter >= 1);
    assert(type_name.len > 0);
    try writer.writeAll("\n\n");
    for (trace_types) |past_type| try writer.print("{s} -> ", .{past_type});
    try writer.print("{s}", .{type_name});
    if (mode == .back_refs) try writer.writeAll(" (referrers)");
    try writer.writeAll("\n\n");
    for (1..counter) |n| try writer.print(" [{d}]", .{n});
    if (has_back) try writer.writeAll("  [b]ack");
    if (mode == .regular and referrer_count > 0) try writer.print("  [r]eferrers ({d})", .{referrer_count});
    try writer.writeAll("  [q]uit\n\n");
}

/// Render the back-references view: every object that mentions the current
/// object via rdf:resource. Capped at 9 entries; over the cap shows a
/// short message instead so the user narrows their query.
fn render_back_refs(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    model: *const cim_model.CimModel,
    tp_opt: ?CimTp,
    target: tag_index.CimObjectView,
    referrers: []const []const u8,
    ref_list: *std.ArrayList([]const u8),
) !u32 {
    assert(target.type_name.len > 0);
    try writer.print("\nReferences to {s} ", .{target.type_name});
    try writer.writeAll(cli.ansi_yellow);
    try writer.writeAll(strip_underscore(target.id));
    try writer.writeAll(cli.ansi_default);
    if (referrers.len == 0) {
        try writer.writeAll("\n\n  (no referrers)");
        return 1;
    }
    if (referrers.len > 9) {
        try writer.print("\n\n  Too many referrers ({d}) — narrow your search.", .{referrers.len});
        return 1;
    }
    try writer.writeAll("\n");
    var counter: u32 = 1;
    for (referrers) |raw_id| {
        const view = resolve_object(model, tp_opt, raw_id) orelse continue;
        try writer.print("\n|  {d}  |  {s} ", .{ counter, view.type_name });
        try writer.writeAll(cli.ansi_yellow);
        try writer.writeAll(strip_underscore(view.id));
        try writer.writeAll(cli.ansi_default);
        try ref_list.append(gpa, raw_id);
        counter += 1;
    }
    assert(ref_list.items.len == counter - 1);
    return counter;
}

/// Parses a single line of user input and returns the navigation action.
/// Writes error/hint messages directly to stdout for invalid input.
fn handle_input(
    io: std.Io,
    input: []const u8,
    counter: u32,
    has_back: bool,
    ref_list: []const []const u8,
    mode: Mode,
    referrer_count: usize,
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
        'r' => {
            if (mode == .back_refs) return .stay;
            if (referrer_count == 0) {
                try std.Io.File.stdout().writeStreamingAll(io, "No referrers.\n\n");
                return .stay;
            }
            return .show_back_refs;
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
