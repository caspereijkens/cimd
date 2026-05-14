const std = @import("std");
const cli = @import("cli.zig");
const print = @import("io/print.zig");
const builtin = @import("builtin");
const SSH = @import("cgmes/ssh.zig").SSH;
const TP = @import("cgmes/tp.zig").TP;
const zip = @import("io/zip.zig");
const EQ = @import("cgmes/eq.zig").EQ;
const CimObject = @import("cgmes/eq.zig").CimObject;
const browse = @import("browse.zig");
const diff = @import("diff.zig");
const converter = @import("convert/network.zig");
const cross_ref = @import("topology/cross_ref.zig");
const resolve = @import("topology/resolve.zig");
const refs_api = @import("refs.zig");
const tag_index = @import("cgmes/tag_index.zig");
const ids = @import("cgmes/ids.zig");
const cim_types = @import("cgmes/cim_types.zig");
const CimMergedView = @import("cgmes/ssh.zig").CimMergedView;

const assert = std.debug.assert;

const build_options = @import("build_options");
const max_in_memory_input_bytes = std.math.maxInt(u32);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    const command = try cli.parse_args(io, &args);

    switch (command) {
        .convert => |c| try command_convert(io, gpa, c),
        .browse => |c| try command_browse(io, gpa, c),
        .get => |c| try command_get(io, gpa, c),
        .refs => |c| try command_refs(io, gpa, c),
        .types => |c| try command_types(io, gpa, c),
        .diff => |c| try command_diff(io, gpa, c),
        .topology => |c| try command_topology(io, gpa, c),
        .version => |v| try command_version(io, v.verbose, v.json),
    }
}

fn command_convert(io: std.Io, parent_gpa: std.mem.Allocator, c: cli.Command.Convert) !void {
    var arena_instance = std.heap.ArenaAllocator.init(parent_gpa);
    defer arena_instance.deinit();
    const gpa = arena_instance.allocator();

    const model = try load_model(io, gpa, c.eq_path, c.eqbd_path);

    const tp_opt: ?TP = if (c.tp_path) |path| try load_tp(io, gpa, path) else null;

    const ssh_opt: ?SSH = if (c.ssh_path) |path| try load_ssh(io, gpa, path) else null;

    if (tp_opt) |tp| if (refs_api.find_tp_primary_id_collision(&model, tp)) |id| print.stderr(
        io,
        "convert: mRID collision: '{s}' is defined in both the primary file and the TP profile",
        .{id},
    );

    const network = try converter.convert(gpa, &model, tp_opt, ssh_opt, c.bus_branch);

    var total_voltage_levels: usize = 0;
    var total_buses: usize = 0;
    var total_busbar_sections: usize = 0;
    var total_switches: usize = 0;
    var total_loads: usize = 0;
    var total_shunts: usize = 0;
    var total_svcs: usize = 0;
    var total_generators: usize = 0;
    var total_2w: usize = 0;
    var total_3w: usize = 0;
    for (network.substations.items) |substation| {
        total_voltage_levels += substation.voltage_levels.items.len;
        total_2w += substation.two_winding_transformers.items.len;
        total_3w += substation.three_winding_transformers.items.len;
        for (substation.voltage_levels.items) |voltage_level| {
            total_buses += voltage_level.bus_breaker_topology.buses.items.len;
            total_busbar_sections += voltage_level.node_breaker_topology.busbar_sections.items.len;
            total_switches += voltage_level.node_breaker_topology.switches.items.len;
            total_loads += voltage_level.loads.items.len;
            total_shunts += voltage_level.shunts.items.len;
            total_svcs += voltage_level.static_var_compensators.items.len;
            total_generators += voltage_level.generators.items.len;
        }
    }
    try print.stderr_info(io, "Substations: {d}\n", .{network.substations.items.len});
    try print.stderr_info(io, "VoltageLevels: {d}\n", .{total_voltage_levels});
    if (tp_opt != null) try print.stderr_info(io, "Buses: {d}\n", .{total_buses});
    try print.stderr_info(io, "BusbarSections: {d}\n", .{total_busbar_sections});
    try print.stderr_info(io, "Switches: {d}\n", .{total_switches});
    try print.stderr_info(io, "Loads: {d}\n", .{total_loads});
    try print.stderr_info(io, "Shunts: {d}\n", .{total_shunts});
    try print.stderr_info(io, "StaticVarCompensators: {d}\n", .{total_svcs});
    try print.stderr_info(io, "Generators: {d}\n", .{total_generators});
    try print.stderr_info(io, "2-winding transformers: {d}\n", .{total_2w});
    try print.stderr_info(io, "3-winding transformers: {d}\n", .{total_3w});
    try print.stderr_info(io, "Lines: {d}\n", .{network.lines.items.len});

    const cwd = std.Io.Dir.cwd();
    const output_file = if (c.output_path) |path|
        try cwd.createFile(io, path, .{})
    else
        std.Io.File.stdout();
    defer if (c.output_path != null) output_file.close(io);

    var write_buffer: [64 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(output_file, io, &write_buffer);
    try std.json.Stringify.value(network, .{}, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
}

fn command_browse(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Browse) !void {
    var model = try load_model(io, gpa, c.file_path, c.eqbd_path);
    defer model.deinit(gpa);

    var tp_opt: ?TP = if (c.tp_path) |path| try load_tp(io, gpa, path) else null;
    defer if (tp_opt) |*tp| tp.deinit(gpa);

    var ssh_opt: ?SSH = if (c.ssh_path) |path| try load_ssh(io, gpa, path) else null;
    defer if (ssh_opt) |*ssh| ssh.deinit(gpa);

    // Safety check: TP's new objects must not collide with primary model IDs.
    // Silent shadowing would make it impossible to tell which file an object
    // came from during navigation; fail loud instead.
    if (tp_opt) |tp| if (refs_api.find_tp_primary_id_collision(&model, tp)) |id| print.stderr(
        io,
        "browse: mRID collision: '{s}' is defined in both the primary file and the TP profile",
        .{id},
    );

    var browse_input_buffer: [64]u8 = undefined;
    var browse_stdin = std.Io.File.stdin().reader(io, &browse_input_buffer);
    var browse_output_buffer: [64 * 1024]u8 = undefined;
    var browse_stdout = std.Io.File.Writer.init(std.Io.File.stdout(), io, &browse_output_buffer);
    defer browse_stdout.interface.flush() catch {};
    const interactive: browse.InteractiveIo = .{
        .input = &browse_stdin.interface,
        .output = &browse_stdout.interface,
    };

    const start_id: []const u8 = blk: {
        // Exact match first for full mRIDs (covers both EQ and TP-added ids).
        if (refs_api.resolve_object(&model, tp_opt, c.mrid) != null) break :blk c.mrid;

        const matches = try refs_api.collect_target_candidates(gpa, &model, tp_opt, c.mrid);
        defer gpa.free(matches);
        if (matches.len == 0) print.not_found(io, "No object found with id '{s}'", .{c.mrid});
        if (matches.len == 1) break :blk matches[0].id;
        break :blk try browse.pick_from_prefix(io, gpa, interactive, c.mrid, matches);
    };

    try browse.browse(io, gpa, interactive, &model, tp_opt, ssh_opt, start_id);
}

fn command_get(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Get) !void {
    assert(c.mrid != null or c.type_filter != null);
    if (c.mrid != null and c.count) print.stderr(io, "get: --count requires --type without <mrid>", .{});
    if (c.mrid != null and c.fields != null) print.stderr(io, "get: --fields requires --type without <mrid>", .{});
    if (c.mrid == null and c.tp_path != null) print.stderr(io, "get: --tp requires <mrid> (list mode does not merge TP objects yet)", .{});
    if (c.mrid == null and c.ssh_path != null) print.stderr(io, "get: --ssh requires <mrid> (list mode does not merge SSH patches yet)", .{});

    var model = try load_model(io, gpa, c.file_path, c.eqbd_path);
    defer model.deinit(gpa);

    var tp_opt: ?TP = if (c.tp_path) |path| try load_tp(io, gpa, path) else null;
    defer if (tp_opt) |*tp| tp.deinit(gpa);

    var ssh_opt: ?SSH = if (c.ssh_path) |path| try load_ssh(io, gpa, path) else null;
    defer if (ssh_opt) |*ssh| ssh.deinit(gpa);

    // Single-object mode
    if (c.mrid) |mrid_val| {
        const target = try resolve_get_target(io, gpa, &model, tp_opt, mrid_val, c.type_filter, c.json) orelse return;
        const object = refs_api.resolve_object(&model, tp_opt, target.id) orelse unreachable;
        try display_get_object(io, gpa, object, tp_opt, ssh_opt, c.json);
        return;
    }

    // List mode
    const type_name = c.type_filter.?;
    const objects = try collect_objects_by_type_filter(gpa, &model, type_name);
    defer gpa.free(objects);
    if (objects.len == 0)
        print.not_found(io, "No objects of type '{s}' found. Run 'cimd types' to see available types.", .{type_name});

    if (c.count) {
        if (c.json) {
            try print.stdout(io, "{{\"type\":\"{s}\",\"count\":{d}}}\n", .{ type_name, objects.len });
        } else {
            try print.stdout(io, "{d}\n", .{objects.len});
        }
        return;
    }

    // Parse --fields into a stack-allocated slice of names.
    var fields_buf: [32][]const u8 = undefined;
    var n_fields: usize = 0;
    if (c.fields) |fs| {
        var it = std.mem.splitScalar(u8, fs, ',');
        while (it.next()) |f| {
            if (n_fields == fields_buf.len) print.stderr(io, "get: --fields: too many fields (max 32)", .{});
            fields_buf[n_fields] = std.mem.trim(u8, f, " ");
            n_fields += 1;
        }
    }
    const fields = fields_buf[0..n_fields];

    if (c.json) {
        try print.display_object_list_json(io, gpa, &model, objects, fields);
    } else {
        for (objects) |obj| {
            const view = model.view(obj);
            try print.stdout(io, "{s}", .{obj.id});
            if (fields.len == 0) {
                const name = try view.getProperty("IdentifiedObject.name") orelse "N/A";
                try print.stdout(io, " | {s}", .{name});
            } else {
                for (fields) |field| {
                    const val = try view.getProperty(field) orelse "N/A";
                    try print.stdout(io, " | {s}", .{val});
                }
            }
            try print.stdout(io, "\n", .{});
        }
    }
}

fn resolve_get_target(
    io: std.Io,
    gpa: std.mem.Allocator,
    model: *const EQ,
    tp_opt: ?TP,
    mrid: []const u8,
    type_filter: ?[]const u8,
    json: bool,
) !?CimObject {
    const all_matches = try refs_api.collect_target_candidates(gpa, model, tp_opt, mrid);
    defer gpa.free(all_matches);

    var filtered: std.ArrayList(CimObject) = .empty;
    defer filtered.deinit(gpa);
    for (all_matches) |m| {
        if (cim_types.matches_filter(m.type_name, type_filter)) try filtered.append(gpa, m);
    }

    if (filtered.items.len == 0) {
        if (all_matches.len == 0) {
            if (json) exit_json_error(io, .{ .@"error" = "not_found", .prefix = mrid });
            print.not_found(io, "No object found with id '{s}'", .{mrid});
        }
        const requested_type = type_filter.?;
        if (all_matches.len == 1) {
            const m = all_matches[0];
            if (json) exit_json_error(io, .{
                .@"error" = "type_mismatch",
                .prefix = mrid,
                .id = m.id,
                .actual_type = m.type_name,
                .requested_type = requested_type,
            });
            print.not_found(io, "Object '{s}' is of type '{s}', not '{s}'", .{ mrid, m.type_name, requested_type });
        }
        if (json) exit_json_error(io, .{
            .@"error" = "none_of_type",
            .prefix = mrid,
            .total = all_matches.len,
            .requested_type = requested_type,
        });
        print.not_found(
            io,
            "Prefix '{s}' matched {d} objects but none of type '{s}'",
            .{ mrid, all_matches.len, requested_type },
        );
    }

    if (filtered.items.len > 1) {
        try render_get_ambiguity(io, gpa, mrid, filtered.items, type_filter, json);
        return null;
    }

    return filtered.items[0];
}

fn render_get_ambiguity(
    io: std.Io,
    gpa: std.mem.Allocator,
    mrid: []const u8,
    matches: []const CimObject,
    type_filter: ?[]const u8,
    json: bool,
) !void {
    if (json) {
        try render_ambiguous_json(io, gpa, mrid, matches);
    } else if (type_filter) |t| {
        try print.stderr_info(io, "Ambiguous prefix '{s}' matched {d} objects of type '{s}':\n", .{ mrid, matches.len, t });
        for (matches) |m| try print.stdout(io, "{s} | {s}\n", .{ m.id, m.type_name });
    } else if (matches.len > browse.group_threshold) {
        try render_type_breakdown(io, gpa, mrid, matches);
    } else {
        try print.stderr_info(io, "Ambiguous prefix '{s}' matched {d} objects:\n", .{ mrid, matches.len });
        for (matches) |m| try print.stdout(io, "{s} | {s}\n", .{ m.id, m.type_name });
    }
}

fn display_get_object(
    io: std.Io,
    gpa: std.mem.Allocator,
    object: tag_index.CimObjectView,
    tp_opt: ?TP,
    ssh_opt: ?SSH,
    json: bool,
) !void {
    if (tp_opt == null and ssh_opt == null) {
        if (json) {
            try print.display_object_json(io, gpa, object);
        } else {
            try print.display_object(io, gpa, object);
        }
        return;
    }

    const merged = CimMergedView.init(object, ids.strip_underscore(object.id), tp_opt, ssh_opt);
    var props = try merged.getAllProperties(gpa);
    defer props.deinit();
    var refs = try merged.getAllReferences(gpa);
    defer refs.deinit();

    if (json) {
        try display_get_object_json(io, object, props, refs);
    } else {
        try display_get_object_text(io, gpa, object, props, refs);
    }
}

fn display_get_object_text(
    io: std.Io,
    gpa: std.mem.Allocator,
    object: tag_index.CimObjectView,
    props: std.StringHashMap([]const u8),
    refs: std.StringHashMap([]const u8),
) !void {
    try print.stdout(io, "Type: {s}\n", .{object.type_name});
    try print.stdout(io, "ID: {s}\n", .{object.id});
    try display_string_map(io, gpa, "Properties", props);
    try display_string_map(io, gpa, "References", refs);
    try print.stdout(io, "\n", .{});
}

fn display_string_map(
    io: std.Io,
    gpa: std.mem.Allocator,
    title: []const u8,
    map: std.StringHashMap([]const u8),
) !void {
    if (map.count() == 0) return;
    try print.stdout(io, "\n{s}:\n", .{title});

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = map.iterator();
    while (it.next()) |entry| try names.append(gpa, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, string_less_than);

    for (names.items) |name| {
        const value = map.get(name).?;
        try print.stdout(io, "  {s}: {s}\n", .{ name, value });
    }
}

fn display_get_object_json(
    io: std.Io,
    object: tag_index.CimObjectView,
    props: std.StringHashMap([]const u8),
    refs: std.StringHashMap([]const u8),
) !void {
    var write_buffer: [16 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    const w = &file_writer.interface;

    try w.writeAll("{\"id\":");
    try std.json.Stringify.value(object.id, .{}, w);
    try w.writeAll(",\"type\":");
    try std.json.Stringify.value(object.type_name, .{}, w);
    try w.writeAll(",\"properties\":{");
    try write_string_map_json(w, props, false);
    try w.writeAll("},\"references\":{");
    try write_string_map_json(w, refs, true);
    try w.writeAll("}}\n");
    try w.flush();
}

fn write_string_map_json(
    w: *std.Io.Writer,
    map: std.StringHashMap([]const u8),
    strip_reference_hash: bool,
) !void {
    var first = true;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (!first) try w.writeByte(',');
        try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
        try w.writeByte(':');
        const value = if (strip_reference_hash) ids.strip_hash(entry.value_ptr.*) else entry.value_ptr.*;
        try std.json.Stringify.value(value, .{}, w);
        first = false;
    }
}

fn string_less_than(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn command_refs(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Refs) !void {
    var model = try load_model(io, gpa, c.file_path, c.eqbd_path);
    defer model.deinit(gpa);

    var tp_opt: ?TP = if (c.tp_path) |path| try load_tp(io, gpa, path) else null;
    defer if (tp_opt) |*tp| tp.deinit(gpa);

    var ssh_opt: ?SSH = if (c.ssh_path) |path| try load_ssh(io, gpa, path) else null;
    defer if (ssh_opt) |*ssh| ssh.deinit(gpa);

    const all_matches = try refs_api.collect_target_candidates(gpa, &model, tp_opt, c.mrid);
    defer gpa.free(all_matches);

    var filtered: std.ArrayList(CimObject) = .empty;
    defer filtered.deinit(gpa);
    for (all_matches) |m| {
        if (cim_types.matches_filter(m.type_name, c.target_type)) try filtered.append(gpa, m);
    }

    if (filtered.items.len == 0) {
        if (all_matches.len > 0 and c.target_type != null) {
            const t = c.target_type.?;
            if (c.json) exit_json_error(io, .{
                .@"error" = "none_of_type",
                .prefix = c.mrid,
                .total = all_matches.len,
                .requested_type = t,
            });
            print.not_found(
                io,
                "Prefix '{s}' matched {d} objects but none of type '{s}'",
                .{ c.mrid, all_matches.len, t },
            );
        }
        if (c.json) exit_json_error(io, .{ .@"error" = "not_found", .prefix = c.mrid });
        print.not_found(io, "No object found with id '{s}'", .{c.mrid});
    }

    if (filtered.items.len > 1) {
        if (c.json) {
            try render_ambiguous_json(io, gpa, c.mrid, filtered.items);
        } else if (c.target_type) |t| {
            try print.stderr_info(io, "Ambiguous prefix '{s}' matched {d} objects of type '{s}':\n", .{ c.mrid, filtered.items.len, t });
            for (filtered.items) |m| try print.stdout(io, "{s} | {s}\n", .{ m.id, m.type_name });
        } else if (filtered.items.len > browse.group_threshold) {
            try render_type_breakdown(io, gpa, c.mrid, filtered.items);
        } else {
            try print.stderr_info(io, "Ambiguous prefix '{s}' matched {d} objects:\n", .{ c.mrid, filtered.items.len });
            for (filtered.items) |m| try print.stdout(io, "{s} | {s}\n", .{ m.id, m.type_name });
        }
        return;
    }

    const target_id = filtered.items[0].id;
    const target_type_name = filtered.items[0].type_name;

    var index = try refs_api.ReverseRefIndex.build_with_overlays(gpa, &model, tp_opt, ssh_opt);
    defer index.deinit(gpa);

    const referrers = try refs_api.filter_referrers(gpa, index.lookup(target_id), c.from_type);
    defer gpa.free(referrers);

    var write_buffer: [16 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    const w = &file_writer.interface;

    if (c.json) {
        try refs_api.write_referrers_json(w, target_id, target_type_name, referrers);
    } else {
        try refs_api.write_referrers_text(w, target_id, referrers, c.from_type);
    }
    try w.flush();
}

fn collect_objects_by_type_filter(
    gpa: std.mem.Allocator,
    model: *const EQ,
    requested_type: []const u8,
) ![]CimObject {
    var matches: std.ArrayList(CimObject) = .empty;
    errdefer matches.deinit(gpa);
    for (model.objects) |obj| {
        if (cim_types.matches_filter(obj.type_name, requested_type)) try matches.append(gpa, obj);
    }
    return matches.toOwnedSlice(gpa);
}

test "get type filter collector includes CIM subtypes" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:PowerTransformer rdf:ID="_PT1"/>
        \\  <cim:ACLineSegment rdf:ID="_ACL1"/>
        \\  <cim:SynchronousMachine rdf:ID="_SM1"/>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\</rdf:RDF>
    ;
    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const objects = try collect_objects_by_type_filter(gpa, &model, "ConductingEquipment");
    defer gpa.free(objects);

    try std.testing.expectEqual(@as(usize, 3), objects.len);
    var found_power_transformer = false;
    var found_line_segment = false;
    var found_machine = false;
    for (objects) |obj| {
        if (std.mem.eql(u8, obj.type_name, "PowerTransformer")) found_power_transformer = true;
        if (std.mem.eql(u8, obj.type_name, "ACLineSegment")) found_line_segment = true;
        if (std.mem.eql(u8, obj.type_name, "SynchronousMachine")) found_machine = true;
    }
    try std.testing.expect(found_power_transformer);
    try std.testing.expect(found_line_segment);
    try std.testing.expect(found_machine);
}

/// Write `value` as JSON to stdout and exit 1. The exit code matches
/// `print.not_found`'s text-mode behavior so shell scripts can still detect
/// failure; tooling parses the JSON envelope on stdout to discriminate.
fn exit_json_error(io: std.Io, value: anytype) noreturn {
    var write_buffer: [1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    const w = &file_writer.interface;
    std.json.Stringify.value(value, .{}, w) catch {};
    w.writeByte('\n') catch {};
    w.flush() catch {};
    std.process.exit(1);
}

/// JSON envelope for ambiguous `cimd get` lookups. Always emits both the flat
/// match list and an alphabetically-sorted per-type breakdown so tooling can
/// pick whichever it needs without re-aggregating.
fn render_ambiguous_json(
    io: std.Io,
    gpa: std.mem.Allocator,
    prefix: []const u8,
    matches: []const CimObject,
) !void {
    var counts: std.StringHashMap(u32) = .init(gpa);
    defer counts.deinit();
    for (matches) |m| {
        const gop = try counts.getOrPut(m.type_name);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    const TypeCount = struct { type_name: []const u8, count: u32 };
    const types = try gpa.alloc(TypeCount, counts.count());
    defer gpa.free(types);
    var i: usize = 0;
    var it = counts.iterator();
    while (it.next()) |entry| : (i += 1)
        types[i] = .{ .type_name = entry.key_ptr.*, .count = entry.value_ptr.* };
    std.mem.sort(TypeCount, types, {}, struct {
        fn lt(_: void, a: TypeCount, b: TypeCount) bool {
            return std.mem.order(u8, a.type_name, b.type_name) == .lt;
        }
    }.lt);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    const w = &file_writer.interface;

    try w.writeAll("{\"prefix\":");
    try std.json.Stringify.value(prefix, .{}, w);
    try w.print(",\"total\":{d},\"matches\":[", .{matches.len});
    for (matches, 0..) |m, j| {
        if (j > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try std.json.Stringify.value(m.id, .{}, w);
        try w.writeAll(",\"type\":");
        try std.json.Stringify.value(m.type_name, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("],\"types\":[");
    for (types, 0..) |t, j| {
        if (j > 0) try w.writeByte(',');
        try w.writeAll("{\"type\":");
        try std.json.Stringify.value(t.type_name, .{}, w);
        try w.print(",\"count\":{d}}}", .{t.count});
    }
    try w.writeAll("]}\n");
    try w.flush();
}

/// Non-interactive type breakdown for `cimd get` when a prefix is too ambiguous
/// to list flat. Mirrors the grouped layout the browse picker uses.
fn render_type_breakdown(io: std.Io, gpa: std.mem.Allocator, prefix: []const u8, matches: []const CimObject) !void {
    const TypeCount = struct { type_name: []const u8, count: u32 };

    var counts: std.StringHashMap(u32) = .init(gpa);
    defer counts.deinit();
    for (matches) |m| {
        const gop = try counts.getOrPut(m.type_name);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    const entries = try gpa.alloc(TypeCount, counts.count());
    defer gpa.free(entries);
    var i: usize = 0;
    var it = counts.iterator();
    while (it.next()) |entry| : (i += 1)
        entries[i] = .{ .type_name = entry.key_ptr.*, .count = entry.value_ptr.* };
    std.mem.sort(TypeCount, entries, {}, struct {
        fn lt(_: void, a: TypeCount, b: TypeCount) bool {
            return std.mem.order(u8, a.type_name, b.type_name) == .lt;
        }
    }.lt);

    var max_type_len: usize = 0;
    for (entries) |e| if (e.type_name.len > max_type_len) {
        max_type_len = e.type_name.len;
    };

    try print.stderr_info(
        io,
        "Ambiguous prefix '{s}' matched {d} objects across {d} types — pass --type to drill in:\n",
        .{ prefix, matches.len, entries.len },
    );

    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    const w = &file_writer.interface;
    for (entries) |e| {
        try w.print("{[type]s: <[w]}  |  {[count]d}\n", .{
            .type = e.type_name,
            .w = max_type_len,
            .count = e.count,
        });
    }
    try w.flush();
}

fn command_types(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Types) !void {
    var model = try EQ.init(gpa, try read_path(io, gpa, c.file_path));
    defer model.deinit(gpa);

    if (c.json) {
        try print.display_object_inventory_json(io, gpa, model);
    } else {
        try print.display_object_inventory(io, gpa, model);
    }
}

fn command_diff(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Diff) !void {
    // Load both models independently. Each holds its own XML backing.
    var model1 = try load_model(io, gpa, c.file_path1, c.eqbd_path);
    defer model1.deinit(gpa);

    var model2 = try load_model(io, gpa, c.file_path2, c.eqbd_path);
    defer model2.deinit(gpa);

    const options = diff.DiffOptions{
        .type_filter = c.type_filter,
        .json = c.json,
        .summary = c.summary,
    };

    // Stream diff output to a buffered stdout writer.
    var out_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &out_buffer);

    const had_diffs = if (c.mrid) |mrid| blk: {
        const status = try diff.diff_single(
            gpa,
            &model1,
            &model2,
            mrid,
            c.file_path1,
            c.file_path2,
            options,
            &writer.interface,
        );
        break :blk switch (status) {
            .not_found => print.not_found(io, "No object found with mRID '{s}' in either file", .{mrid}),
            .type_mismatch => |actual| print.stderr(
                io,
                "diff: object '{s}' is of type '{s}', not '{s}'",
                .{ mrid, actual, c.type_filter.? },
            ),
            .diff => |d| d,
        };
    } else try diff.diff_models(
        gpa,
        &model1,
        &model2,
        c.file_path1,
        c.file_path2,
        options,
        &writer.interface,
    );

    try writer.interface.flush();

    // Exit 1 when differences exist so callers can branch on the exit code.
    if (had_diffs) std.process.exit(1);
}

fn command_topology(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Topology) !void {
    var model = try load_model(io, gpa, c.eq_path, c.eqbd_path);
    defer model.deinit(gpa);

    var ssh_opt: ?SSH = if (c.ssh_path) |path| try load_ssh(io, gpa, path) else null;
    defer if (ssh_opt) |*ssh| ssh.deinit(gpa);

    const boundary_ids: std.StringHashMapUnmanaged(void) = .empty;
    var index = try cross_ref.CrossRef.build_for_topology(gpa, &model, boundary_ids);
    defer index.deinit(gpa);

    var topology = try resolve.Topology.build_for_topological_nodes(gpa, &model, &index);
    defer topology.deinit(gpa);

    const ssh_ptr: ?*const SSH = if (ssh_opt) |*s| s else null;
    var nodes = try resolve.build_topological_nodes(gpa, &model, &index, &topology, ssh_ptr);
    defer nodes.deinit(gpa);

    try print.stderr_info(io, "TopologicalNodes: {d}\n", .{nodes.items.len});

    const cwd = std.Io.Dir.cwd();
    const output_file = if (c.output_path) |path|
        try cwd.createFile(io, path, .{})
    else
        std.Io.File.stdout();
    defer if (c.output_path != null) output_file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(output_file, io, &write_buffer);
    const w = &file_writer.interface;

    try std.json.Stringify.value(.{ .topologicalNodes = nodes.items }, .{}, w);
    try w.writeByte('\n');
    try w.flush();
}

fn command_version(io: std.Io, verbose: bool, json: bool) !void {
    const version_string = build_options.version;

    if (json) {
        if (verbose) {
            try print.stdout(io,
                \\{{"version":"{s}","zig":"{s}","target":"{s}-{s}","optimize":"{s}"}}
                \\
            , .{
                version_string,
                builtin.zig_version_string,
                @tagName(builtin.cpu.arch),
                @tagName(builtin.os.tag),
                @tagName(builtin.mode),
            });
        } else {
            try print.stdout(io, "{{\"version\":\"{s}\"}}\n", .{version_string});
        }
        return;
    }

    try print.stdout(io, "cimd {s}\n", .{version_string});

    if (verbose) {
        try print.stdout(io, "\nBuild Information:\n", .{});
        try print.stdout(io, "  Version:       {s}\n", .{version_string});
        try print.stdout(io, "  Zig Version:   {s}\n", .{builtin.zig_version_string});
        try print.stdout(io, "  Target:        {s}-{s}\n", .{
            @tagName(builtin.cpu.arch),
            @tagName(builtin.os.tag),
        });
        try print.stdout(io, "  Optimize:      {s}\n", .{@tagName(builtin.mode)});
    }
}

fn load_model(io: std.Io, gpa: std.mem.Allocator, eq_path: []const u8, eqbd_path: ?[]const u8) !EQ {
    // errdefer is scoped to the block so it frees only when read/concat fail.
    // Once we hand `xml` to init, init owns it (frees on its own error path).
    const xml = blk: {
        var x = try read_path(io, gpa, eq_path);
        errdefer gpa.free(x);

        if (eqbd_path) |path| {
            const eqbd_xml = try read_path(io, gpa, path);
            defer gpa.free(eqbd_xml);
            if (x.len > max_in_memory_input_bytes - eqbd_xml.len) return error.FileTooLarge;
            const combined = try std.mem.concat(gpa, u8, &.{ x, eqbd_xml });
            gpa.free(x);
            x = combined;
        }
        break :blk x;
    };
    return EQ.init(gpa, xml);
}

fn load_ssh(io: std.Io, gpa: std.mem.Allocator, ssh_path: []const u8) !SSH {
    return SSH.init(gpa, try read_path(io, gpa, ssh_path));
}

fn load_tp(io: std.Io, gpa: std.mem.Allocator, tp_path: []const u8) !TP {
    return TP.init(gpa, try read_path(io, gpa, tp_path));
}

fn read_path(io: std.Io, gpa: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, file_path, .{});
    defer file.close(io);

    if (try zip.is_zip_file(io, file)) {
        var zip_buffer: [256 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &zip_buffer);
        const extracted = try zip.extract_first_file_to_memory(gpa, &file_reader, .{
            .extract = .{},
            .max_uncompressed_bytes = max_in_memory_input_bytes,
        });
        const data = extracted.data;
        gpa.free(extracted.filename);
        return data;
    } else {
        return try read_file_to_memory(io, gpa, file);
    }
}

fn read_file_to_memory(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File) ![]u8 {
    const file_size = try file.length(io);
    if (file_size > max_in_memory_input_bytes) return error.FileTooLarge;

    var file_reader = file.reader(io, &.{});
    // +1 so the reader can observe EOF without tripping StreamTooLong on exact-size files.
    return try file_reader.interface.allocRemaining(gpa, .limited(file_size + 1));
}
