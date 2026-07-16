const std = @import("std");
const assert = std.debug.assert;
const cli = @import("cli.zig");
const EQ = @import("cgmes/eq.zig").EQ;

const TP = @import("cgmes/tp.zig").TP;
const SSH = @import("cgmes/ssh.zig").SSH;
const tag_index = @import("cgmes/tag_index.zig");
const refs = @import("refs.zig");
const print = @import("io/print.zig");
const extract_rdf_resource = tag_index.extract_rdf_resource;
const extract_rdf_id = tag_index.extract_rdf_id;
const strip_hash = @import("cgmes/ids.zig").strip_hash;
const strip_underscore = @import("cgmes/ids.zig").strip_underscore;

/// Above this referrer/match count, list-style views switch to a type-grouped
/// summary instead of one row per item. Shared between back-refs and the
/// prefix picker so the interactive UX stays consistent, and also referenced
/// from `cimd get` so its non-interactive output uses the same cutoff.
pub const group_threshold: usize = 9;

/// One numbered choice on screen. The renderer pushes these as it draws;
/// `handle_input` then dispatches purely on the variant, so what each
/// number "means" is never inferred from sibling state.
const Selection = union(enum) {
    /// Navigate to a CIM object by raw id.
    follow: []const u8,
    /// Narrow the back-refs view to a single CIM type.
    filter: []const u8,
    /// In a grouped back-refs view, expand to every referrer.
    show_all,
};

const Mode = union(enum) {
    regular,
    back_refs: ListView,
};

/// How a groupable list (back-refs or the prefix picker) is currently shown.
/// The three variants are mutually exclusive by construction, so the "flat,
/// type-filtered, and show-all" states can never be encoded inconsistently.
const ListView = union(enum) {
    /// Default: grouped if over threshold, flat otherwise.
    auto,
    /// User chose "(All)" from the grouped view — show every item flat.
    all,
    /// User chose a type — show only items of that type.
    filtered: []const u8,

    /// The type to restrict a flat render to, or null to show everything.
    fn filter(self: ListView) ?[]const u8 {
        return switch (self) {
            .filtered => |t| t,
            else => null,
        };
    }
};

const Nav = union(enum) {
    stay,
    back,
    quit,
    follow: []const u8,
    show_back_refs,
    filter_type: []const u8,
    show_all_refs,
};

/// One step of the navigation history. Stored as a single struct (rather than
/// two parallel arrays) so the id and the type label can never drift apart.
const Breadcrumb = struct {
    id: []const u8,
    type_name: []const u8,
};

pub const InteractiveIo = struct {
    input: *std.Io.Reader,
    output: *std.Io.Writer,
};

fn take_input_line(input: *std.Io.Reader) ![]const u8 {
    const line = input.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return input.takeDelimiterExclusive('\n'),
        error.StreamTooLong => {
            _ = input.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                error.EndOfStream => return error.InputTooLong,
                else => return discard_err,
            };
            return error.InputTooLong;
        },
        else => return err,
    };
    return std.mem.trimEnd(u8, line, "\r\n");
}

fn report_input_too_long(output: *std.Io.Writer, picker: bool) !void {
    const message = if (picker)
        "Input too long — expected a number, [b]ack, or [q]uit.\n\n"
    else
        "Input too long — expected one menu command per line.\n\n";
    try output.writeAll(message);
    try output.flush();
}

test "overlong input feedback identifies the active prompt" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try report_input_too_long(&output.writer, true);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "expected a number") != null);
    output.clearRetainingCapacity();

    try report_input_too_long(&output.writer, false);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "one menu command") != null);
}

test "overlong input is drained through the next newline" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const io = std.testing.io;
    var file = try tmpdir.dir.createFile(io, "input.txt", .{ .read = true });
    defer file.close(io);
    var input_bytes: [203]u8 = undefined;
    @memset(input_bytes[0..200], 'x');
    input_bytes[200] = '\n';
    input_bytes[201] = 'q';
    input_bytes[202] = '\n';
    try file.writeStreamingAll(io, &input_bytes);

    var buffer: [64]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    try std.testing.expectError(error.InputTooLong, take_input_line(&file_reader.interface));
    try std.testing.expectEqualStrings("q", try take_input_line(&file_reader.interface));
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
    interactive: InteractiveIo,
    model: *const EQ,
    tp_opt: ?TP,
    ssh_opt: ?SSH,
    mrid: []const u8,
) !void {
    var trace: std.ArrayList(Breadcrumb) = .empty;
    defer trace.deinit(gpa);
    var screen: std.Io.Writer.Allocating = .init(gpa);
    defer screen.deinit();
    var selections: std.ArrayList(Selection) = .empty;
    defer selections.deinit(gpa);
    var back_refs = try refs.ReverseRefIndex.build_with_overlays(gpa, model, tp_opt, ssh_opt);
    defer back_refs.deinit(gpa);

    var id = mrid;
    var mode: Mode = .regular;
    while (true) {
        const object = resolve_object(model, tp_opt, id) orelse
            print.not_found(io, "{s}", .{id});

        screen.clearRetainingCapacity();
        selections.clearRetainingCapacity();

        const writer = &screen.writer;
        const referrers = back_refs.lookup(id);

        const counter: u32 = switch (mode) {
            .regular => try print.allocating_writer_result(&screen, render_regular(writer, gpa, tp_opt, ssh_opt, object, &selections)),
            .back_refs => |view| try print.allocating_writer_result(&screen, render_back_refs(writer, gpa, model, tp_opt, object, referrers, view, &selections)),
        };

        const has_back = trace.items.len > 0 or mode != .regular;
        try print.allocating_writer_result(&screen, render_footer(writer, trace.items, object.type_name, counter, has_back, mode, referrers.len));
        try interactive.output.writeAll(screen.written());
        try interactive.output.flush();

        const input = take_input_line(interactive.input) catch |err| switch (err) {
            error.EndOfStream => break,
            error.InputTooLong => {
                try report_input_too_long(interactive.output, false);
                continue;
            },
            else => return err,
        };
        if (input.len == 0) continue;

        const nav = try handle_input(interactive.output, input, counter, has_back, selections.items, mode, referrers.len);
        try interactive.output.flush();
        switch (nav) {
            .stay => {},
            .quit => break,
            .back => switch (mode) {
                .regular => id = (trace.pop() orelse unreachable).id,
                // Back from a drilled view returns to the grouped overview;
                // back from the overview returns to the regular object view.
                .back_refs => |view| switch (view) {
                    .auto => mode = .regular,
                    .all, .filtered => mode = .{ .back_refs = .auto },
                },
            },
            .follow => |new_id| {
                try trace.append(gpa, .{ .id = id, .type_name = object.type_name });
                id = new_id;
                mode = .regular;
            },
            .show_back_refs => mode = .{ .back_refs = .auto },
            .filter_type => |type_name| mode = .{ .back_refs = .{ .filtered = type_name } },
            .show_all_refs => mode = .{ .back_refs = .all },
        }
    }
}

/// Re-export so internal browse callers keep their short name. The primitive
/// itself lives in refs.zig next to the other EQ+TP lookup helpers.
pub const resolve_object = refs.resolve_object;

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

/// Render the primary object plus any TP/SSH patches inline.
fn render_regular(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    tp_opt: ?TP,
    ssh_opt: ?SSH,
    object: tag_index.CimObjectView,
    selections: *std.ArrayList(Selection),
) !u32 {
    var counter: u32 = 1;
    counter = try render_fragment(writer, gpa, tag_slice(object.xml, object.boundaries, object.object_tag_idx, object.closing_tag_idx), counter, selections);

    const overlay_key = try object.mrid();
    if (tp_opt) |tp| {
        if (tp.find_patch(overlay_key)) |patch| {
            try writer.writeAll("\n\n--- TP ---");
            const patch_xml = tag_slice(tp.xml, tp.boundaries, patch.patch_tag_idx, patch.closing_tag_idx);
            counter = try render_fragment(writer, gpa, patch_xml, counter, selections);
        }
    }
    if (ssh_opt) |ssh| {
        if (ssh.find_patch(overlay_key)) |patch| {
            try writer.writeAll("\n\n--- SSH ---");
            const patch_xml = tag_slice(ssh.xml, ssh.boundaries, patch.patch_tag_idx, patch.closing_tag_idx);
            counter = try render_fragment(writer, gpa, patch_xml, counter, selections);
        }
    }
    return counter;
}

/// Render one XML fragment into `writer`, continuing reference numbering from `start_counter`.
/// Returns the new counter value (1-based, pointing past the last rendered reference).
fn render_fragment(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    fragment_xml: []const u8,
    start_counter: u32,
    selections: *std.ArrayList(Selection),
) !u32 {
    assert(fragment_xml.len > 0);
    assert(start_counter >= 1);

    var it = std.mem.splitScalar(u8, fragment_xml, '\n');
    var counter = start_counter;
    while (it.next()) |line| {
        // Text-content continuation lines (from elements with embedded newlines) carry no tag;
        // print verbatim so the XML stays readable instead of tripping tag extraction.
        if (std.mem.indexOfScalar(u8, line, '<') == null) {
            try writer.print("\n|   |  {s}", .{line});
            continue;
        }
        if (extract_rdf_id(line, 0) catch null != null) {
            try writer.writeAll("\n|   |  ");
            try append_colored_id_line(writer, line);
            continue;
        }
        const rdf_resource = try extract_rdf_resource(line, 0);
        if (rdf_resource) |val| {
            try writer.print("\n| {d} |  ", .{counter});
            try append_colored_ref_line(writer, line);
            try selections.append(gpa, .{ .follow = strip_hash(val) });
            counter += 1;
        } else {
            try writer.print("\n|   |  {s}", .{line});
        }
    }
    assert(selections.items.len == counter - 1);
    return counter;
}

/// Writes the breadcrumb trail, type name, and keyboard hint line.
fn render_footer(
    writer: *std.Io.Writer,
    trace: []const Breadcrumb,
    type_name: []const u8,
    counter: u32,
    has_back: bool,
    mode: Mode,
    referrer_count: usize,
) !void {
    assert(counter >= 1);
    assert(type_name.len > 0);
    try writer.writeAll("\n\n");
    for (trace) |crumb| try writer.print("{s} -> ", .{crumb.type_name});
    try writer.print("{s}", .{type_name});
    switch (mode) {
        .regular => {},
        .back_refs => |v| switch (v) {
            .auto => try writer.writeAll(" (referrers)"),
            .all => try writer.writeAll(" (referrers, all)"),
            .filtered => |t| try writer.print(" (referrers: {s})", .{t}),
        },
    }
    try writer.writeAll("\n\n");
    if (counter > 2) {
        try writer.print(" [1-{d}]", .{counter - 1});
    } else if (counter == 2) {
        try writer.print(" [1]", .{});
    }
    if (has_back) try writer.writeAll("  [b]ack");
    if (mode == .regular and referrer_count > 0) try writer.print("  [r]eferrers ({d})", .{referrer_count});
    try writer.writeAll("  [q]uit\n\n");
}

/// Render the back-references view. Picks one of three layouts based on `view`
/// and the referrer count; each layout pushes a meaningful Selection per row.
fn render_back_refs(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    model: *const EQ,
    tp_opt: ?TP,
    target: tag_index.CimObjectView,
    referrers: []const refs.ReverseRef,
    view: ListView,
    selections: *std.ArrayList(Selection),
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

    const auto_groups = view == .auto and referrers.len > group_threshold;
    if (auto_groups) return render_back_refs_grouped(writer, gpa, model, tp_opt, referrers, selections);

    return render_back_refs_flat(writer, gpa, model, tp_opt, referrers, view.filter(), selections);
}

fn render_back_refs_flat(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    model: *const EQ,
    tp_opt: ?TP,
    referrers: []const refs.ReverseRef,
    filter_type: ?[]const u8,
    selections: *std.ArrayList(Selection),
) !u32 {
    var max_type_len: usize = 0;
    for (referrers) |ref| {
        _ = resolve_object(model, tp_opt, ref.referrer_id) orelse continue;
        if (max_type_len < ref.referrer_type.len) max_type_len = ref.referrer_type.len;
    }

    try writer.writeAll("\n");
    var counter: u32 = 1;
    for (referrers) |ref| {
        const v = resolve_object(model, tp_opt, ref.referrer_id) orelse continue;
        if (filter_type) |t| if (!std.mem.eql(u8, t, ref.referrer_type)) continue;
        try writer.print("\n| {[n]d: >[e]} |  {[type]s: <[w]}  |  {[c]s}", .{
            .n = counter,
            .e = std.math.log10_int(referrers.len) + 1,
            .type = ref.referrer_type,
            .w = max_type_len,
            .c = strip_underscore(v.id),
        });
        try selections.append(gpa, .{ .follow = ref.referrer_id });
        counter += 1;
    }
    assert(selections.items.len == counter - 1);
    return counter;
}

/// Group referrers by CIM type and offer each group as a drill-in choice,
/// plus a final "(All)" entry that expands every referrer flat.
fn render_back_refs_grouped(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    model: *const EQ,
    tp_opt: ?TP,
    referrers: []const refs.ReverseRef,
    selections: *std.ArrayList(Selection),
) !u32 {
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(gpa);

    var max_type_len: usize = 0;
    for (referrers) |ref| {
        _ = resolve_object(model, tp_opt, ref.referrer_id) orelse continue;
        const gop = try counts.getOrPut(gpa, ref.referrer_type);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (max_type_len < ref.referrer_type.len) max_type_len = ref.referrer_type.len;
    }

    try writer.print("\n\n  {d} referrers — pick a type to drill in:\n", .{referrers.len});
    var counter: u32 = 1;
    var it = counts.iterator();
    while (it.next()) |entry| {
        const is_only_type = entry.value_ptr.* == referrers.len;
        try writer.print("\n| {[n]d: >[e]} |  {[type]s: <[w]}  |  {[c]d: >[e]}{[suffix]s}", .{
            .n = counter,
            .e = std.math.log10_int(counts.size) + 1,
            .type = entry.key_ptr.*,
            .w = max_type_len,
            .c = entry.value_ptr.*,
            .suffix = if (is_only_type) " (All)" else "",
        });
        try selections.append(gpa, .{ .filter = entry.key_ptr.* });
        counter += 1;
    }
    if (counter > 2) {
        try writer.print("\n| {[n]d: >[e]} |  {[type]s: <[w]}  |  {[c]d: >[e]}", .{
            .n = counter,
            .e = std.math.log10_int(counts.size) + 1,
            .type = "(All)",
            .w = max_type_len,
            .c = referrers.len,
        });
        try selections.append(gpa, .show_all);
        counter += 1;
    }

    assert(selections.items.len == counter - 1);
    return counter;
}

/// Parses a single line of user input and returns the navigation action.
/// Writes error/hint messages directly to stdout for invalid input.
fn handle_input(
    output: *std.Io.Writer,
    input: []const u8,
    counter: u32,
    has_back: bool,
    selections: []const Selection,
    mode: Mode,
    referrer_count: usize,
) !Nav {
    assert(input.len > 0);
    assert(selections.len == counter - 1);
    const has_options = counter > 1;
    switch (input[0]) {
        'q' => return .quit,
        'b' => {
            if (!has_back) {
                try output.writeAll("Already at root — [q]uit to exit.\n\n");
                return .stay;
            }
            return .back;
        },
        'r' => {
            if (mode != .regular) return .stay;
            if (referrer_count == 0) {
                try output.writeAll("No referrers.\n\n");
                return .stay;
            }
            return .show_back_refs;
        },
        else => {
            if (!has_options) {
                const msg = if (has_back) "No options — [b]ack or [q]uit\n\n" else "No options — [q]uit to exit\n\n";
                try output.writeAll(msg);
                return .stay;
            }
            const n = std.fmt.parseInt(u32, input, 10) catch {
                const suffix = if (has_back) ", [b]ack or [q]uit\n" else " or [q]uit\n";
                try output.print("Invalid input — pick 1-{d}{s}", .{ counter - 1, suffix });
                return .stay;
            };
            if (n == 0 or n > selections.len) {
                const suffix = if (has_back) ", [b]ack or [q]uit\n" else " or [q]uit\n";
                try output.print("Pick 1-{d}{s}", .{ counter - 1, suffix });
                return .stay;
            }
            return switch (selections[n - 1]) {
                .follow => |new_id| .{ .follow = new_id },
                .filter => |type_name| .{ .filter_type = type_name },
                .show_all => .show_all_refs,
            };
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

/// Choice within the prefix-picker menu.
const PickSel = union(enum) {
    /// User selected this exact id; the picker returns it to the caller.
    pick: []const u8,
    /// User wants to drill into a type group from the grouped overview.
    drill: []const u8,
    /// User wants to expand the grouped overview to a flat list of every match.
    show_all,
};

/// Interactive picker shown when the user enters a prefix that matches more
/// than one object. Returns the chosen mRID (a slice into `model.xml` via the
/// CimObjects in `matches`). Returns null on `q` or end of input.
///
/// Layout follows the back-refs menu: grouped-by-type when over
/// `group_threshold` matches, flat list otherwise. `b` returns to the grouped
/// overview from a drilled or flat-all view.
pub fn pick_from_prefix(
    gpa: std.mem.Allocator,
    interactive: InteractiveIo,
    prefix: []const u8,
    matches: []const tag_index.CimObject,
) !?[]const u8 {
    assert(matches.len > 1);

    var screen: std.Io.Writer.Allocating = .init(gpa);
    defer screen.deinit();
    var selections: std.ArrayList(PickSel) = .empty;
    defer selections.deinit(gpa);

    var view: ListView = .auto;

    while (true) {
        screen.clearRetainingCapacity();
        selections.clearRetainingCapacity();
        const writer = &screen.writer;

        _ = try print.allocating_writer_result(&screen, render_prefix_screen(
            writer,
            gpa,
            prefix,
            matches,
            view,
            &selections,
        ));
        try interactive.output.writeAll(screen.written());
        try interactive.output.flush();

        const input = take_input_line(interactive.input) catch |err| switch (err) {
            error.EndOfStream => return null,
            error.InputTooLong => {
                try report_input_too_long(interactive.output, true);
                continue;
            },
            else => return err,
        };
        if (input.len == 0) continue;

        switch (input[0]) {
            'q' => return null,
            'b' => view = .auto,
            else => {
                const n = std.fmt.parseInt(u32, input, 10) catch continue;
                if (n == 0 or n > selections.items.len) continue;
                switch (selections.items[n - 1]) {
                    .pick => |id| return id,
                    .drill => |t| view = .{ .filtered = t },
                    .show_all => view = .all,
                }
            },
        }
    }
}

fn render_prefix_screen(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    prefix: []const u8,
    matches: []const tag_index.CimObject,
    view: ListView,
    selections: *std.ArrayList(PickSel),
) !u32 {
    const use_grouped = view == .auto and matches.len > group_threshold;
    const counter: u32 = if (use_grouped)
        try render_prefix_grouped(writer, gpa, prefix, matches, selections)
    else
        try render_prefix_flat(writer, gpa, prefix, matches, view.filter(), selections);

    const has_back = view != .auto;
    try writer.writeAll("\n\n");
    if (counter > 1) try writer.print(" [1-{d}]", .{counter - 1});
    if (has_back) try writer.writeAll("  [b]ack");
    try writer.writeAll("  [q]uit\n\n");
    return counter;
}

fn render_prefix_grouped(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    prefix: []const u8,
    matches: []const tag_index.CimObject,
    selections: *std.ArrayList(PickSel),
) !u32 {
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(gpa);

    var max_type_len: usize = 0;
    for (matches) |m| {
        const gop = try counts.getOrPut(gpa, m.type_name);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (max_type_len < m.type_name.len) max_type_len = m.type_name.len;
    }

    try writer.print("\n  '{s}' matched {d} objects — pick a type to drill in:\n", .{ prefix, matches.len });

    var counter: u32 = 1;
    const n_width = std.math.log10_int(counts.size + 1) + 1;
    var it = counts.iterator();
    while (it.next()) |entry| {
        try writer.print("\n| {[n]d: >[e]} |  {[type]s: <[w]}  |  {[c]d}", .{
            .n = counter,
            .e = n_width,
            .type = entry.key_ptr.*,
            .w = max_type_len,
            .c = entry.value_ptr.*,
        });
        try selections.append(gpa, .{ .drill = entry.key_ptr.* });
        counter += 1;
    }
    if (counter > 2) {
        try writer.print("\n| {[n]d: >[e]} |  {[type]s: <[w]}  |  {[c]d}", .{
            .n = counter,
            .e = n_width,
            .type = "(All)",
            .w = max_type_len,
            .c = matches.len,
        });
        try selections.append(gpa, .show_all);
        counter += 1;
    }
    return counter;
}

fn render_prefix_flat(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    prefix: []const u8,
    matches: []const tag_index.CimObject,
    filter_type: ?[]const u8,
    selections: *std.ArrayList(PickSel),
) !u32 {
    var shown: usize = 0;
    var max_type_len: usize = 0;
    for (matches) |m| {
        if (filter_type) |t| if (!std.mem.eql(u8, t, m.type_name)) continue;
        if (m.type_name.len > max_type_len) max_type_len = m.type_name.len;
        shown += 1;
    }

    if (filter_type) |t| {
        try writer.print("\n  '{s}' / {s}: {d} matches\n", .{ prefix, t, shown });
    } else {
        try writer.print("\n  '{s}' matched {d} objects:\n", .{ prefix, matches.len });
    }

    var counter: u32 = 1;
    const n_width = std.math.log10_int(shown + 1) + 1;
    for (matches) |m| {
        if (filter_type) |t| if (!std.mem.eql(u8, t, m.type_name)) continue;
        try writer.print("\n| {[n]d: >[e]} |  {[type]s: <[w]}  |  {[id]s}", .{
            .n = counter,
            .e = n_width,
            .type = m.type_name,
            .w = max_type_len,
            .id = m.id,
        });
        try selections.append(gpa, .{ .pick = m.id });
        counter += 1;
    }
    return counter;
}
