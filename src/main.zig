const std = @import("std");
const cim = @import("cim/cim.zig");
const cli = @import("cli.zig");
const print = @import("io/print.zig");
const builtin = @import("builtin");
const Overlay = cim.Overlay;
const io_read = @import("io/read.zig");
const read_path = io_read.read_path;
const zip = @import("io/zip.zig");
// `_mod` suffix: local `diagnostics` variables would shadow it.
const diagnostics_mod = cim.diagnostics;
const CimDocument = cim.CimDocument;
const CimObject = cim.CimObject;
const browse = @import("browse.zig");
const diff = cim.diff;
const eqdiff = cim.eqdiff;
const converter = @import("convert/network.zig");
const iidm = @import("iidm/model.zig");
const cross_ref = @import("topology/cross_ref.zig");
const resolve = @import("topology/resolve.zig");
const refs = cim.refs;
const ids = cim.ids;
const cim_types = cim.cim_types;
const CimMergedView = cim.CimMergedView;
const qocdc = @import("qocdc/qocdc.zig");
const validate = @import("validate.zig");
const model_set = @import("model_set.zig");
const rule_set = @import("shacl/rule_set.zig");
const RuleSet = rule_set.RuleSet;

const assert = std.debug.assert;

const build_options = @import("build_options");
const max_in_memory_input_bytes = io_read.max_in_memory_input_bytes;
const max_get_fields = 32;
const default_get_field = "IdentifiedObject.name";

const PrefixTarget = struct {
    id: []const u8,
    type_name: []const u8,
};

pub fn main(init: std.process.Init) !void {
    main_impl(init) catch |err| {
        if (is_broken_pipe(err)) return;
        if (print.is_output_system_error(err)) print.system_error(
            init.io,
            "cimd: output failed: {s}",
            .{print.output_error_cause(err)},
        );
        if (err == error.OutOfMemory) print.system_error(init.io, "cimd: not enough memory", .{});
        print.unexpected(init.io, "cimd", err);
    };
}

fn main_impl(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    const command = try cli.parse_args(io, &args);
    // After parsing, so the global output policies are known; before the
    // command, so no output is written against an unsettled policy.
    print.resolve_stats(io);
    print.resolve_color(io, init.environ_map);
    const name = @tagName(command);

    run_command(io, gpa, command) catch |err| {
        if (is_broken_pipe(err)) return;
        if (print.is_output_system_error(err)) print.system_error(
            io,
            "{s}: output failed: {s}",
            .{ name, print.output_error_cause(err) },
        );
        if (err == error.OutOfMemory) print.system_error(io, "{s}: not enough memory", .{name});
        print.unexpected(io, name, err);
    };
}

fn is_broken_pipe(err: anyerror) bool {
    return err == error.BrokenPipe;
}

test "only a broken pipe is a normal closed output" {
    try std.testing.expect(is_broken_pipe(error.BrokenPipe));
    try std.testing.expect(!is_broken_pipe(error.WriteFailed));
    try std.testing.expect(!is_broken_pipe(error.NoSpaceLeft));
}

fn run_command(io: std.Io, gpa: std.mem.Allocator, command: cli.Command) !void {
    switch (command) {
        .convert => |c| try command_convert(io, gpa, c),
        .browse => |c| try command_browse(io, gpa, c),
        .get => |c| try command_get(io, gpa, c),
        .refs => |c| try command_refs(io, gpa, c),
        .types => |c| try command_types(io, gpa, c),
        .diff => |c| try command_diff(io, gpa, c),
        .topology => |c| try command_topology(io, gpa, c),
        .validate => |c| try command_validate(io, gpa, c),
        .qocdc => |c| try command_qocdc(io, gpa, c),
        .version => |v| try command_version(io, v.verbose, v.json),
    }
}

fn command_convert(io: std.Io, parent_gpa: std.mem.Allocator, c: cli.Command.Convert) !void {
    var arena_instance = std.heap.ArenaAllocator.init(parent_gpa);
    defer arena_instance.deinit();
    const gpa = arena_instance.allocator();

    var inputs = try model_set.load_merged(io, gpa, "convert", c.model_inputs.slice(), .convert);
    defer inputs.deinit(gpa);
    const model = &inputs.model;
    const segments = inputs.segments[0..inputs.segments_count];
    const tp_opt: ?Overlay = if (inputs.tp) |loaded| loaded.overlay else null;
    const ssh_opt: ?Overlay = if (inputs.ssh) |loaded| loaded.overlay else null;
    const primary_path = inputs.primary_source.label();
    const tp_path: ?[]const u8 = if (inputs.tp) |loaded| loaded.source.label() else null;

    if (c.bus_branch and tp_opt == null) print.stderr(io, "convert: --bus-branch requires a TP part", .{});
    reject_tp_primary_mrid_collision(io, gpa, "convert", model, tp_opt, tp_path) catch |err|
        return model_operation_error(io, "convert", primary_path, err);

    var conversion_diagnostics: converter.ConversionDiagnostics = .{};
    const network = converter.convertWithDiagnostics(gpa, model, tp_opt, ssh_opt, c.bus_branch, &conversion_diagnostics) catch |err| switch (err) {
        error.MissingSubstations => invalid_model_structure(io, "convert", "Substation"),
        error.MissingVoltageLevels => invalid_model_structure(io, "convert", "VoltageLevel"),
        error.MissingTerminals => invalid_model_structure(io, "convert", "Terminal"),
        error.UnresolvedVoltageLevels => print.data_error(
            io,
            "convert: EQ profile '{s}' has a VoltageLevel whose Substation reference is missing or unresolved",
            .{primary_path},
        ),
        error.EmptyMrid, error.DuplicateMrid => conversion_id_error(io, segments, model, conversion_diagnostics, err),
        else => if (is_model_data_error(err))
            invalid_model_data(io, "convert", primary_path, err)
        else if (is_model_capacity_error(err))
            model_capacity_error(io, "convert", primary_path, err)
        else
            return err,
    };

    try print_conversion_summary(io, &network, tp_opt != null);

    const output = try open_output(io, "convert", c.output_path);
    defer output.deinit(io);

    var write_buffer: [64 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(output.file, io, &write_buffer);
    try print.file_writer_result(&file_writer, std.json.Stringify.value(network, .{}, &file_writer.interface));
    try print.file_writer_result(&file_writer, file_writer.interface.writeByte('\n'));
    try print.flush_file_writer(&file_writer);
}

fn print_conversion_summary(io: std.Io, network: *const iidm.Network, has_tp: bool) !void {
    var total_voltage_levels: u64 = 0;
    var total_buses: u64 = 0;
    var total_busbar_sections: u64 = 0;
    var total_switches: u64 = 0;
    var total_loads: u64 = 0;
    var total_shunts: u64 = 0;
    var total_svcs: u64 = 0;
    var total_generators: u64 = 0;
    var total_2w: u64 = 0;
    var total_3w: u64 = 0;
    for (network.substations.items) |substation| {
        total_voltage_levels += @intCast(substation.voltage_levels.items.len);
        total_2w += @intCast(substation.two_winding_transformers.items.len);
        total_3w += @intCast(substation.three_winding_transformers.items.len);
        for (substation.voltage_levels.items) |voltage_level| {
            total_buses += @intCast(voltage_level.bus_breaker_topology.buses.items.len);
            total_busbar_sections += @intCast(voltage_level.node_breaker_topology.busbar_sections.items.len);
            total_switches += @intCast(voltage_level.node_breaker_topology.switches.items.len);
            total_loads += @intCast(voltage_level.loads.items.len);
            total_shunts += @intCast(voltage_level.shunts.items.len);
            total_svcs += @intCast(voltage_level.static_var_compensators.items.len);
            total_generators += @intCast(voltage_level.generators.items.len);
        }
    }
    try print.stderr_info(io, "Substations: {d}\n", .{network.substations.items.len});
    try print.stderr_info(io, "VoltageLevels: {d}\n", .{total_voltage_levels});
    if (has_tp) try print.stderr_info(io, "Buses: {d}\n", .{total_buses});
    try print.stderr_info(io, "BusbarSections: {d}\n", .{total_busbar_sections});
    try print.stderr_info(io, "Switches: {d}\n", .{total_switches});
    try print.stderr_info(io, "Loads: {d}\n", .{total_loads});
    try print.stderr_info(io, "Shunts: {d}\n", .{total_shunts});
    try print.stderr_info(io, "StaticVarCompensators: {d}\n", .{total_svcs});
    try print.stderr_info(io, "Generators: {d}\n", .{total_generators});
    try print.stderr_info(io, "2-winding transformers: {d}\n", .{total_2w});
    try print.stderr_info(io, "3-winding transformers: {d}\n", .{total_3w});
    try print.stderr_info(io, "Lines: {d}\n", .{network.lines.items.len});
}

fn command_browse(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Browse) !void {
    var inputs = try model_set.load_merged(io, gpa, "browse", c.model_inputs.slice(), .query);
    defer inputs.deinit(gpa);
    const tp_opt: ?Overlay = if (inputs.tp) |loaded| loaded.overlay else null;
    const ssh_opt: ?Overlay = if (inputs.ssh) |loaded| loaded.overlay else null;
    const tp_path: ?[]const u8 = if (inputs.tp) |loaded| loaded.source.label() else null;
    const primary_path = inputs.primary_source.label();

    // Safety check: navigation addresses objects by raw RDF identifier.
    // Silent shadowing would make it impossible to tell which file an object
    // came from during navigation; fail loud instead.
    reject_tp_primary_id_collision(io, "browse", &inputs.model, tp_opt, tp_path);

    var browse_input_buffer: [64]u8 = undefined;
    var browse_stdin = std.Io.File.stdin().reader(io, &browse_input_buffer);
    var browse_output_buffer: [64 * 1024]u8 = undefined;
    var browse_stdout = std.Io.File.Writer.init(std.Io.File.stdout(), io, &browse_output_buffer);
    const interactive: browse.InteractiveIo = .{
        .input = &browse_stdin.interface,
        .output = &browse_stdout.interface,
    };

    const target_opt = print.file_writer_result(
        &browse_stdout,
        resolve_prefix(io, gpa, &inputs.model, tp_opt, c.mrid, null, false, interactive),
    ) catch |err| return model_operation_error(io, "browse", primary_path, err);
    const target = target_opt orelse {
        try print.flush_file_writer(&browse_stdout);
        return;
    };
    print.file_writer_result(
        &browse_stdout,
        browse.browse(io, gpa, interactive, &inputs.model, tp_opt, ssh_opt, target.id),
    ) catch |err| return model_operation_error(io, "browse", primary_path, err);
    try print.flush_file_writer(&browse_stdout);
}

fn command_get(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Get) !void {
    validate_get_args(io, c);

    var inputs = try model_set.load_merged(io, gpa, "get", c.model_inputs.slice(), .query);
    defer inputs.deinit(gpa);
    if (c.mrid == null and (inputs.tp != null or inputs.ssh != null)) {
        print.stderr(io, "get: list mode does not merge supplementary TP or SSH parts", .{});
    }
    const tp_opt: ?Overlay = if (inputs.tp) |loaded| loaded.overlay else null;
    const ssh_opt: ?Overlay = if (inputs.ssh) |loaded| loaded.overlay else null;
    const tp_path: ?[]const u8 = if (inputs.tp) |loaded| loaded.source.label() else null;
    const primary_path = inputs.primary_source.label();
    reject_tp_primary_id_collision(io, "get", &inputs.model, tp_opt, tp_path);

    if (c.mrid) |mrid_val| {
        const target = (resolve_prefix(io, gpa, &inputs.model, tp_opt, mrid_val, c.type_filter, c.json, null) catch |err|
            return model_operation_error(io, "get", primary_path, err)) orelse return;
        assert(target.id.len > 0);
        assert(target.type_name.len > 0);
        const object = refs.resolve_object(&inputs.model, tp_opt, target.id) orelse unreachable;
        // Pair the resolution: resolve_prefix already verified the id resolves;
        // the same lookup here must return the same identity.
        assert(std.mem.eql(u8, object.id(), target.id));
        assert(std.mem.eql(u8, object.type_name(), target.type_name));
        display_get_object(io, gpa, object, tp_opt, ssh_opt, c.json) catch |err|
            return model_operation_error(io, "get", primary_path, err);
        return;
    }

    assert(c.type_filter != null); // command_get_list's contract.
    command_get_list(io, gpa, &inputs.model, c) catch |err|
        return model_operation_error(io, "get", primary_path, err);
}

fn validate_get_args(io: std.Io, c: cli.Command.Get) void {
    assert(c.mrid != null or c.type_filter != null);
    if (c.mrid) |mrid| if (mrid.len == 0) print.stderr(io, "get: <mrid> must not be empty", .{});
    if (c.mrid != null and c.count) print.stderr(io, "get: --count requires --type without <mrid>", .{});
    if (c.mrid != null and c.fields != null) print.stderr(io, "get: --fields requires --type without <mrid>", .{});
    if (c.mrid == null) for (c.model_inputs.slice()) |input| switch (input.override orelse continue) {
        .tp => print.stderr(io, "get: --tp is not supported in list mode", .{}),
        .ssh => print.stderr(io, "get: --ssh is not supported in list mode", .{}),
        else => {},
    };
}

fn command_get_list(io: std.Io, gpa: std.mem.Allocator, model: *const CimDocument, c: cli.Command.Get) !void {
    assert(c.type_filter != null);
    assert(c.mrid == null);
    const type_name = c.type_filter.?;

    if (c.count) {
        const count = model.count_objects_by_type_filter(type_name);
        if (count == 0)
            print.not_found(io, "No objects of type '{s}' found. Run 'cimd types' to see available types.", .{type_name});
        if (c.json) {
            try print.stdout(io, "{{\"type\":\"{s}\",\"count\":{d}}}\n", .{ type_name, count });
        } else {
            try print.stdout(io, "{d}\n", .{count});
        }
        return;
    }

    const objects = try model.collect_objects_by_type_filter(gpa, type_name);
    defer gpa.free(objects);
    if (objects.len == 0)
        print.not_found(io, "No objects of type '{s}' found. Run 'cimd types' to see available types.", .{type_name});

    var fields_buf: [max_get_fields][]const u8 = undefined;
    var fields: std.ArrayList([]const u8) = .initBuffer(&fields_buf);
    parse_get_fields(io, c.fields, !c.json, &fields);
    if (c.json) {
        try print.display_object_list_json(io, gpa, objects, fields.items);
    } else {
        try display_get_list_text(io, objects, fields.items);
    }
}

fn parse_get_fields(
    io: std.Io,
    fields_opt: ?[]const u8,
    default_text_field: bool,
    fields: *std.ArrayList([]const u8),
) void {
    const fs = fields_opt orelse {
        if (default_text_field) fields.appendBounded(default_get_field) catch unreachable;
        return;
    };

    var it = std.mem.splitScalar(u8, fs, ',');
    while (it.next()) |f| {
        const name = std.mem.trim(u8, f, " ");
        // An empty entry (e.g. a doubled comma) would reach property("")'s assert.
        if (name.len == 0) print.stderr(io, "get: --fields: empty field name", .{});
        fields.appendBounded(name) catch
            print.stderr(io, "get: --fields: too many fields (max 32)", .{});
    }
}

fn display_get_list_text(
    io: std.Io,
    objects: []const CimObject,
    fields: []const []const u8,
) !void {
    var write_buffer: [64 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    try print.file_writer_result(
        &file_writer,
        write_get_list_text(&file_writer.interface, objects, fields),
    );
    try print.flush_file_writer(&file_writer);
}

fn write_get_list_text(
    w: *std.Io.Writer,
    objects: []const CimObject,
    fields: []const []const u8,
) !void {
    for (objects) |obj| {
        try w.print("{s}", .{obj.id()});
        for (fields) |field| {
            // Fall back to a reference when the field isn't a text property, so
            // rdf:resource fields show their target instead of a bare N/A.
            const val = (try obj.property(field)) orelse (try obj.reference(field)) orelse "N/A";
            try w.print(" | {s}", .{val});
        }
        try w.writeByte('\n');
    }
}

fn resolve_prefix(
    io: std.Io,
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    tp_opt: ?Overlay,
    mrid: []const u8,
    type_filter: ?[]const u8,
    json: bool,
    // Non-null for the interactive browse picker; null for one-shot commands.
    interactive: ?browse.InteractiveIo,
) !?PrefixTarget {
    // Exact-id fast path: the literal id is authoritative. The O(1) hit dodges
    // the false ambiguity a prefix scan raises when a full id prefixes a longer
    // one, and a wrong-typed exact hit stops here as a type_mismatch rather than
    // falling through to surface a prefix sibling of the requested type.
    if (try refs.resolve_object_normalized(gpa, model, tp_opt, mrid)) |object| {
        // Interactive picks take any exact hit; one-shot commands enforce --type.
        if (interactive != null or cim_types.matches_filter(object.type_name(), type_filter))
            return .{ .id = object.id(), .type_name = object.type_name() };
        const requested_type = type_filter.?;
        exit_not_found(
            io,
            json,
            .{ .@"error" = "type_mismatch", .prefix = mrid, .id = object.id(), .actual_type = object.type_name(), .requested_type = requested_type },
            "Object '{s}' is of type '{s}', not '{s}'",
            .{ mrid, object.type_name(), requested_type },
        );
    }

    const all_matches = try refs.collect_target_candidates(gpa, model, tp_opt, mrid);
    defer gpa.free(all_matches);

    var filtered_list: std.ArrayList(CimObject) = .empty;
    defer filtered_list.deinit(gpa);
    const filtered_matches: []const CimObject = if (type_filter == null) all_matches else blk: {
        for (all_matches) |m| {
            if (cim_types.matches_filter(m.type_name(), type_filter)) try filtered_list.append(gpa, m);
        }
        break :blk filtered_list.items;
    };

    if (filtered_matches.len == 0) {
        if (all_matches.len == 0) exit_not_found(
            io,
            json,
            .{ .@"error" = "not_found", .prefix = mrid },
            "No object found with id '{s}'",
            .{mrid},
        );
        const requested_type = type_filter.?;
        // A prefix that pinned exactly one object of the wrong type gets the
        // specific type_mismatch message rather than the generic none_of_type.
        if (all_matches.len == 1) {
            const m = all_matches[0];
            exit_not_found(
                io,
                json,
                .{ .@"error" = "type_mismatch", .prefix = mrid, .id = m.id(), .actual_type = m.type_name(), .requested_type = requested_type },
                "Object '{s}' is of type '{s}', not '{s}'",
                .{ mrid, m.type_name(), requested_type },
            );
        }
        exit_not_found(
            io,
            json,
            .{ .@"error" = "none_of_type", .prefix = mrid, .total = all_matches.len, .requested_type = requested_type },
            "Prefix '{s}' matched {d} objects but none of type '{s}'",
            .{ mrid, all_matches.len, requested_type },
        );
    }

    if (filtered_matches.len > 1) {
        if (interactive) |i| {
            const id = (try browse.pick_from_prefix(gpa, i, mrid, filtered_matches)) orelse return null;
            assert(id.len > 0);
            return .{ .id = id, .type_name = find_type_name(filtered_matches, id) orelse unreachable };
        }
        try render_target_ambiguity(io, gpa, mrid, filtered_matches, type_filter, json);
        return null;
    }

    // Down to the unique-match branch; the empty and ambiguous cases above
    // both returned. The remaining match must carry the identity downstream
    // expects to render.
    assert(filtered_matches.len == 1);
    assert(filtered_matches[0].id().len > 0);
    assert(filtered_matches[0].type_name().len > 0);
    return .{
        .id = filtered_matches[0].id(),
        .type_name = filtered_matches[0].type_name(),
    };
}

fn exit_not_found(
    io: std.Io,
    json: bool,
    json_value: anytype,
    comptime text_fmt: []const u8,
    text_args: anytype,
) noreturn {
    if (json) exit_json_error(io, json_value);
    print.not_found(io, text_fmt, text_args);
}

fn find_type_name(matches: []const CimObject, id: []const u8) ?[]const u8 {
    for (matches) |match| {
        if (std.mem.eql(u8, match.id(), id)) return match.type_name();
    }
    return null;
}

fn render_target_ambiguity(
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
        for (matches) |m| try print.stdout(io, "{s} | {s}\n", .{ m.id(), m.type_name() });
    } else if (matches.len > browse.group_threshold) {
        try render_type_breakdown(io, gpa, mrid, matches);
    } else {
        try print.stderr_info(io, "Ambiguous prefix '{s}' matched {d} objects:\n", .{ mrid, matches.len });
        for (matches) |m| try print.stdout(io, "{s} | {s}\n", .{ m.id(), m.type_name() });
    }
}

fn display_get_object(
    io: std.Io,
    gpa: std.mem.Allocator,
    object: cim.CimObject,
    tp_opt: ?Overlay,
    ssh_opt: ?Overlay,
    json: bool,
) !void {
    assert(object.id().len > 0);
    assert(object.type_name().len > 0);

    // A merged view with no TP/SSH overlay degenerates to the plain EQ view:
    // all_properties/all_references return the EQ maps unchanged and skip
    // every overlay allocation, so this single path serves both cases.
    const merged = CimMergedView.init(object, try object.mrid(), tp_opt, ssh_opt);
    var props = try merged.all_properties(gpa);
    defer props.deinit();
    var references = try merged.all_references(gpa);
    defer references.deinit();

    var write_buffer: [16 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    const w = &file_writer.interface;
    if (json) {
        try print.file_writer_result(
            &file_writer,
            write_object_maps_json(w, object.id(), object.type_name(), props, references),
        );
    } else {
        try print.file_writer_result(
            &file_writer,
            write_object_maps_text(w, gpa, object.id(), object.type_name(), props, references),
        );
    }
    try print.flush_file_writer(&file_writer);
}

fn write_object_maps_text(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    id: []const u8,
    type_name: []const u8,
    props: std.StringHashMap([]const u8),
    references: std.StringHashMap([]const u8),
) !void {
    try w.print("Type: {s}\n", .{type_name});
    try w.print("ID: {s}\n", .{id});
    try write_string_map_text(w, gpa, "Properties", props);
    try write_string_map_text(w, gpa, "References", references);
    try w.writeByte('\n');
}

fn write_string_map_text(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    title: []const u8,
    map: std.StringHashMap([]const u8),
) !void {
    if (map.count() == 0) return;
    try w.print("\n{s}:\n", .{title});

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = map.iterator();
    while (it.next()) |entry| try names.append(gpa, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, string_less_than);

    for (names.items) |name| {
        const value = map.get(name).?;
        try w.print("  {s}: {s}\n", .{ name, value });
    }
}

fn write_object_maps_json(
    w: *std.Io.Writer,
    id: []const u8,
    type_name: []const u8,
    props: std.StringHashMap([]const u8),
    references: std.StringHashMap([]const u8),
) !void {
    try w.writeAll("{\"id\":");
    try std.json.Stringify.value(id, .{}, w);
    try w.writeAll(",\"type\":");
    try std.json.Stringify.value(type_name, .{}, w);
    try w.writeAll(",\"properties\":{");
    try write_string_map_json(w, props, false);
    try w.writeAll("},\"references\":{");
    try write_string_map_json(w, references, true);
    try w.writeAll("}}\n");
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
    if (c.mrid.len == 0) print.stderr(io, "refs: <mrid> must not be empty", .{});

    var inputs = try model_set.load_merged(io, gpa, "refs", c.model_inputs.slice(), .query);
    defer inputs.deinit(gpa);
    const tp_opt: ?Overlay = if (inputs.tp) |loaded| loaded.overlay else null;
    const ssh_opt: ?Overlay = if (inputs.ssh) |loaded| loaded.overlay else null;
    const tp_path: ?[]const u8 = if (inputs.tp) |loaded| loaded.source.label() else null;
    const primary_path = inputs.primary_source.label();
    reject_tp_primary_id_collision(io, "refs", &inputs.model, tp_opt, tp_path);

    const target = (resolve_prefix(io, gpa, &inputs.model, tp_opt, c.mrid, c.target_type, c.json, null) catch |err|
        return model_operation_error(io, "refs", primary_path, err)) orelse return;
    // Pairs with resolve_prefix's final-branch invariants: a target without an
    // id/type would break the index lookup and the writer's preconditions.
    assert(target.id.len > 0);
    assert(target.type_name.len > 0);

    // One-shot refs needs only this target's edges; browse keeps the full index.
    const candidates = refs.collect_referrers_for_target(gpa, &inputs.model, tp_opt, ssh_opt, target.id) catch |err|
        return model_operation_error(io, "refs", primary_path, err);
    defer gpa.free(candidates);

    const referrers = try refs.filter_referrers(gpa, candidates, c.from_type);
    defer gpa.free(referrers);

    var write_buffer: [16 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    const w = &file_writer.interface;

    if (c.json) {
        try print.file_writer_result(
            &file_writer,
            refs.write_referrers_json(w, target.id, target.type_name, referrers),
        );
    } else {
        try print.file_writer_result(
            &file_writer,
            refs.write_referrers_text(w, target.id, referrers, c.from_type),
        );
    }
    try print.flush_file_writer(&file_writer);
}

fn reject_tp_primary_id_collision(
    io: std.Io,
    command_name: []const u8,
    model: *const CimDocument,
    tp_opt: ?Overlay,
    tp_path: ?[]const u8,
) void {
    if (tp_opt) |tp| if (refs.find_tp_primary_id_collision(model, tp)) |object| {
        const offset = tp.boundaries[object.object_tag_idx].start;
        const line = diagnostics_mod.line_number_at(tp.xml, offset);
        print.data_error(
            io,
            "{s}: RDF identifier collision: '{s}' is defined in both the primary file and TP profile '{s}' at line {d}",
            .{ command_name, object.id(), tp_path orelse "(unknown)", line },
        );
    };
}

fn reject_tp_primary_mrid_collision(
    io: std.Io,
    gpa: std.mem.Allocator,
    command_name: []const u8,
    model: *const CimDocument,
    tp_opt: ?Overlay,
    tp_path: ?[]const u8,
) !void {
    if (tp_opt) |tp| if (try refs.find_tp_primary_mrid_collision(gpa, model, tp)) |collision| {
        const offset = tp.boundaries[collision.object.object_tag_idx].start;
        const line = diagnostics_mod.line_number_at(tp.xml, offset);
        print.data_error(
            io,
            "{s}: mRID collision: '{s}' is defined in both the primary file and TP profile '{s}' at line {d}",
            .{ command_name, collision.mrid, tp_path orelse "(unknown)", line },
        );
    };
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
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), model.count_objects_by_type_filter("ConductingEquipment"));

    const objects = try model.collect_objects_by_type_filter(gpa, "ConductingEquipment");
    defer gpa.free(objects);

    try std.testing.expectEqual(@as(usize, 3), objects.len);
    var found_power_transformer = false;
    var found_line_segment = false;
    var found_machine = false;
    for (objects) |obj| {
        if (std.mem.eql(u8, obj.type_name(), "PowerTransformer")) found_power_transformer = true;
        if (std.mem.eql(u8, obj.type_name(), "ACLineSegment")) found_line_segment = true;
        if (std.mem.eql(u8, obj.type_name(), "SynchronousMachine")) found_machine = true;
    }
    try std.testing.expect(found_power_transformer);
    try std.testing.expect(found_line_segment);
    try std.testing.expect(found_machine);
}

test "write_object_maps_text renders sorted properties and raw references" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_L1">
        \\    <cim:IdentifiedObject.name>Line 1</cim:IdentifiedObject.name>
        \\    <cim:ACLineSegment.length>10</cim:ACLineSegment.length>
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_C1"/>
        \\  </cim:ACLineSegment>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);
    const view = model.object_by_id("_L1").?;
    var props = try view.all_properties(gpa);
    defer props.deinit();
    var references = try view.all_references(gpa);
    defer references.deinit();

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write_object_maps_text(&w, gpa, view.id(), view.type_name(), props, references);
    // Properties are sorted (length < name); references print raw (with '#').
    try std.testing.expectEqualStrings(
        "Type: ACLineSegment\n" ++
            "ID: _L1\n" ++
            "\nProperties:\n" ++
            "  ACLineSegment.length: 10\n" ++
            "  IdentifiedObject.name: Line 1\n" ++
            "\nReferences:\n" ++
            "  Equipment.EquipmentContainer: #_C1\n" ++
            "\n",
        w.buffered(),
    );
}

test "write_object_maps_json strips reference hash and pins the shape" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_L1">
        \\    <cim:IdentifiedObject.name>Line 1</cim:IdentifiedObject.name>
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_C1"/>
        \\  </cim:ACLineSegment>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);
    const view = model.object_by_id("_L1").?;
    var props = try view.all_properties(gpa);
    defer props.deinit();
    var references = try view.all_references(gpa);
    defer references.deinit();

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write_object_maps_json(&w, view.id(), view.type_name(), props, references);
    try std.testing.expectEqualStrings(
        "{\"id\":\"_L1\",\"type\":\"ACLineSegment\"," ++
            "\"properties\":{\"IdentifiedObject.name\":\"Line 1\"}," ++
            "\"references\":{\"Equipment.EquipmentContainer\":\"_C1\"}}\n",
        w.buffered(),
    );
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

/// The canonical (type_name, count) pair and its ordering live on CimDocument;
/// alias it
/// so the get-ambiguity breakdown sorts and renders identically to `cimd types`.
const TypeCount = CimDocument.TypeCount;

/// Aggregate `matches` into alphabetically-sorted (type_name, count) pairs.
/// Caller owns the returned slice. Shared by the ambiguity renderers so the
/// JSON and text breakdowns can't drift in how they group or order types.
fn sorted_type_counts_of(gpa: std.mem.Allocator, matches: []const CimObject) ![]TypeCount {
    var counts: std.StringHashMap(u32) = .init(gpa);
    defer counts.deinit();
    for (matches) |m| {
        const gop = try counts.getOrPut(m.type_name());
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    const out = try gpa.alloc(TypeCount, counts.count());
    errdefer gpa.free(out);
    var i: usize = 0;
    var it = counts.iterator();
    while (it.next()) |entry| : (i += 1)
        out[i] = .{ .type_name = entry.key_ptr.*, .count = entry.value_ptr.* };
    // Pairs with the alloc above: every counted type must have been written.
    assert(i == out.len);

    std.mem.sort(TypeCount, out, {}, TypeCount.less_than);
    return out;
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
    const types = try sorted_type_counts_of(gpa, matches);
    defer gpa.free(types);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    try print.file_writer_result(
        &file_writer,
        write_ambiguous_json(&file_writer.interface, prefix, matches, types),
    );
    try print.flush_file_writer(&file_writer);
}

fn write_ambiguous_json(
    w: *std.Io.Writer,
    prefix: []const u8,
    matches: []const CimObject,
    types: []const TypeCount,
) !void {
    try w.writeAll("{\"prefix\":");
    try std.json.Stringify.value(prefix, .{}, w);
    try w.print(",\"total\":{d},\"matches\":[", .{matches.len});
    for (matches, 0..) |m, j| {
        if (j > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try std.json.Stringify.value(m.id(), .{}, w);
        try w.writeAll(",\"type\":");
        try std.json.Stringify.value(m.type_name(), .{}, w);
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
}

/// Non-interactive type breakdown for `cimd get` when a prefix is too ambiguous
/// to list flat. Mirrors the grouped layout the browse picker uses.
fn render_type_breakdown(io: std.Io, gpa: std.mem.Allocator, prefix: []const u8, matches: []const CimObject) !void {
    const entries = try sorted_type_counts_of(gpa, matches);
    defer gpa.free(entries);

    var max_type_len: usize = 0;
    for (entries) |e| if (e.type_name.len > max_type_len) {
        max_type_len = e.type_name.len;
    };

    try print.stderr_info(
        io,
        "Ambiguous prefix '{s}' matched {d} objects across {d} types -- pass --type to drill in:\n",
        .{ prefix, matches.len, entries.len },
    );

    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    try print.file_writer_result(
        &file_writer,
        write_type_breakdown(&file_writer.interface, entries, max_type_len),
    );
    try print.flush_file_writer(&file_writer);
}

fn write_type_breakdown(w: *std.Io.Writer, entries: []const TypeCount, max_type_len: usize) !void {
    for (entries) |e| {
        try w.print("{[type]s: <[w]}  |  {[count]d}\n", .{
            .type = e.type_name,
            .w = max_type_len,
            .count = e.count,
        });
    }
}

fn command_types(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Types) !void {
    var documents = try model_set.plan_documents(io, gpa, "types", c.model_inputs.slice(), .never);
    defer documents.deinit(gpa);
    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &write_buffer);
    const w = &file_writer.interface;
    const multiple = documents.count() > 1;
    if (c.json and multiple) try print.file_writer_result(&file_writer, w.writeByte('['));
    var index: u32 = 0;
    while (index < documents.count()) : (index += 1) {
        var diagnostics: model_set.ParseDiagnostics = .{};
        var document = next_document(io, gpa, "types", &documents, &diagnostics);
        defer documents.release(gpa, &document);
        const counts = try document.model.sorted_type_counts(gpa);
        defer gpa.free(counts);
        if (!multiple) {
            if (c.json) {
                try print.file_writer_result(&file_writer, print.write_object_inventory_json_value(w, counts));
                try print.file_writer_result(&file_writer, w.writeByte('\n'));
            } else {
                try print.file_writer_result(&file_writer, print.write_object_inventory(w, counts));
            }
        } else if (c.json) {
            if (index > 0) try print.file_writer_result(&file_writer, w.writeByte(','));
            try print.file_writer_result(&file_writer, w.writeAll("{\"source\":"));
            try print.file_writer_result(&file_writer, std.json.Stringify.value(document.segments[0].name, .{}, w));
            try print.file_writer_result(&file_writer, w.writeAll(",\"types\":"));
            try print.file_writer_result(&file_writer, print.write_object_inventory_json_value(w, counts));
            try print.file_writer_result(&file_writer, w.writeByte('}'));
        } else {
            try print.file_writer_result(&file_writer, w.print("── {s} ──\n", .{document.segments[0].name}));
            try print.file_writer_result(&file_writer, print.write_object_inventory(w, counts));
        }
    }
    if (c.json and multiple) try print.file_writer_result(&file_writer, w.writeAll("]\n"));
    try print.flush_file_writer(&file_writer);
}

fn next_document(
    io: std.Io,
    gpa: std.mem.Allocator,
    command_name: []const u8,
    documents: *model_set.DocumentSet,
    diagnostics: *model_set.ParseDiagnostics,
) model_set.LoadedDocument {
    return (documents.next(gpa, diagnostics) catch |err|
        model_set.report_document_parse_error(io, command_name, err, diagnostics.*)) orelse unreachable;
}

fn command_diff(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Diff) !void {
    var models = try load_diff_models(io, gpa, c);
    defer models.deinit(gpa);
    const had_diffs = if (c.mrid != null)
        try write_diff_single(io, gpa, c, &models)
    else
        try write_diff_all(io, gpa, c, &models);
    if (had_diffs) std.process.exit(print.exit_differences);
}

const DiffModels = struct {
    left: model_set.MergedModelSet,
    right: model_set.MergedModelSet,

    fn deinit(self: *DiffModels, gpa: std.mem.Allocator) void {
        self.right.deinit(gpa);
        self.left.deinit(gpa);
    }
};

fn load_diff_models(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Diff) !DiffModels {
    var left_inputs: [2]model_set.Input = undefined;
    left_inputs[0] = c.sides[0];
    var left_count: u8 = 1;
    if (c.eqbd_path) |path| {
        left_inputs[1] = .{ .path = path, .override = .eqbd };
        left_count = 2;
    }
    var right_inputs: [2]model_set.Input = undefined;
    right_inputs[0] = c.sides[1];
    var right_count: u8 = 1;
    if (c.eqbd_path) |path| {
        right_inputs[1] = .{ .path = path, .override = .eqbd };
        right_count = 2;
    }
    var left = try model_set.load_merged(io, gpa, "diff", left_inputs[0..left_count], .diff_side);
    errdefer left.deinit(gpa);
    var right = try model_set.load_merged(io, gpa, "diff", right_inputs[0..right_count], .diff_side);
    errdefer right.deinit(gpa);
    reject_mixed_profiles(io, &left, &right);
    return .{ .left = left, .right = right };
}

/// Both sides must describe the same profile: mRIDs collide across profiles by
/// design (SSH patches carry the EQ object's mRID), so an EQ-vs-SSH diff would
/// report every shared object as a wholesale property rewrite rather than
/// failing.
///
/// A side whose header declares nothing is only accepted against another
/// declaring nothing. Pairing it with a declared side would mean guessing that
/// the silent one matches -- and a headerless fragment is exactly as likely to
/// be the EQ document those SSH mRIDs point at, which diffs to the same
/// meaningless wholesale rewrite. One kind flag settles it, so ask for one
/// rather than guess.
///
/// The comparison is on `Kind`, not on the declared profile URIs, and that is
/// deliberate. Kind is the family; several URIs map to one (EquipmentCore,
/// Operation and ShortCircuit are all `.eq`, in both the 2.4.15 and 3.0
/// spellings), and diffing within a family is exactly what users do: a
/// Core-only export against a Core+ShortCircuit one, or a 2.4.15 export
/// against its 3.0 successor. Requiring equal URI sets would reject both --
/// the first is 22 files against 4 in the reference corpus, the second 6 more
/// -- to catch Core-against-Operation, which occurs zero times there and which
/// announces itself anyway, since every object reports as rewritten. Kind is
/// the granularity that separates "different slice of the same model" from
/// "different model", and only the latter is the silent-wrong-answer case
/// this guard exists for.
fn reject_mixed_profiles(io: std.Io, left: *const model_set.MergedModelSet, right: *const model_set.MergedModelSet) void {
    if (left.primary_kind) |left_kind| {
        if (right.primary_kind) |right_kind| {
            if (left_kind == right_kind) return;
            print.data_error(io, "diff: '{s}' is {s} and '{s}' is {s}; both sides must be the same profile", .{
                left.primary_source.label(),
                @tagName(left_kind),
                right.primary_source.label(),
                @tagName(right_kind),
            });
        }
        require_routing(io, left.primary_source.label(), left_kind, right.primary_source.label());
    }
    // Left declares nothing: fine against a right that declares nothing too.
    if (right.primary_kind) |right_kind| {
        require_routing(io, right.primary_source.label(), right_kind, left.primary_source.label());
    }
}

fn require_routing(io: std.Io, declared_path: []const u8, kind: model_set.Kind, silent_path: []const u8) noreturn {
    // Every kind has a side-routing flag except eqbd, whose flag `diff` spends
    // on the shared boundary (cli.diff_side_flags). Naming it here would send
    // the user into a usage error, so say what can actually be done instead.
    if (kind == .eqbd) print.data_error(
        io,
        "diff: '{s}' is eqbd but '{s}' declares no profile; --eqbd names the shared " ++
            "boundary here, so a side cannot be routed as eqbd -- declare the profile in " ++
            "'{s}'s FullModel header instead",
        .{ declared_path, silent_path, silent_path },
    );
    print.data_error(
        io,
        "diff: '{s}' is {s} but '{s}' declares no profile; route it with --{s} so both sides are known",
        .{ declared_path, @tagName(kind), silent_path, @tagName(kind) },
    );
}

fn write_diff_single(
    io: std.Io,
    gpa: std.mem.Allocator,
    c: cli.Command.Diff,
    models: *DiffModels,
) !bool {
    const mrid = c.mrid.?;
    var buffered: std.Io.Writer.Allocating = .init(gpa);
    defer buffered.deinit();
    const status = switch (c.format) {
        .eqdiff => print.allocating_writer_result(&buffered, eqdiff.write_single(
            gpa,
            &models.left.model,
            &models.right.model,
            mrid,
            .{ .type_filter = c.type_filter },
            &buffered.writer,
        )) catch |err| switch (err) {
            error.ConflictingNamespaceBindings => conflicting_namespaces(io),
            else => return err,
        },
        .patch, .json, .summary => try print.allocating_writer_result(&buffered, diff.diff_single(
            gpa,
            &models.left.model,
            &models.right.model,
            mrid,
            models.left.primary_source.label(),
            models.right.primary_source.label(),
            diff_options(c),
            &buffered.writer,
        )),
    };
    const had_diffs = switch (status) {
        .not_found => print.not_found(io, "No object found with mRID '{s}' in either file", .{mrid}),
        .type_mismatch => |actual| print.stderr(
            io,
            "diff: object '{s}' is of type '{s}', not '{s}'",
            .{ mrid, actual, c.type_filter.? },
        ),
        .diff => |value| value,
    };
    var out_buffer: [64 * 1024]u8 = undefined;
    const output = try open_output(io, "diff", c.output_path);
    defer output.deinit(io);
    var writer = std.Io.File.Writer.init(output.file, io, &out_buffer);
    try print.file_writer_result(&writer, writer.interface.writeAll(buffered.written()));
    try print.flush_file_writer(&writer);
    return had_diffs;
}

fn write_diff_all(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Diff, models: *DiffModels) !bool {
    const output = try open_output(io, "diff", c.output_path);
    defer output.deinit(io);
    var out_buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.File.Writer.init(output.file, io, &out_buffer);
    const diff_result = switch (c.format) {
        .eqdiff => eqdiff.write_models(
            gpa,
            &models.left.model,
            &models.right.model,
            .{ .type_filter = c.type_filter },
            &writer.interface,
        ),
        .patch, .json, .summary => diff.diff_models(
            gpa,
            &models.left.model,
            &models.right.model,
            models.left.primary_source.label(),
            models.right.primary_source.label(),
            diff_options(c),
            &writer.interface,
        ),
    };
    const had_diffs = print.file_writer_result(&writer, diff_result) catch |err| switch (err) {
        error.ConflictingNamespaceBindings => conflicting_namespaces(io),
        else => return err,
    };
    try print.flush_file_writer(&writer);
    return had_diffs;
}

/// EQDIFF copies statements verbatim, so two inputs binding the same prefix
/// to different namespaces cannot be merged into one document scope. Real
/// EQ exports always agree per prefix; anything else is an unsupported input.
fn conflicting_namespaces(io: std.Io) noreturn {
    print.data_error(
        io,
        "diff: the inputs bind the same namespace prefix to different namespaces; " ++
            "EQDIFF output cannot represent this -- use --patch, --json, or --summary",
        .{},
    );
}

const Output = struct {
    file: std.Io.File,
    owned: bool,

    fn deinit(output: Output, io: std.Io) void {
        if (output.owned) output.file.close(io);
    }
};

const AtomicOutput = struct {
    output_file: std.Io.File,
    dir: std.Io.Dir,
    target_basename: []const u8,
    temp_name: [32]u8,
    temp_name_len: u8,
    owned: bool,
    file_open: bool,
    temp_exists: bool,
    close_dir: bool,

    const collision_retries_max = 8;

    fn open(io: std.Io, command_name: []const u8, output_path: ?[]const u8) !AtomicOutput {
        if (output_path) |path| if (!io_read.is_stdin(path)) {
            const dirname = std.fs.path.dirname(path);
            const dir = if (dirname) |name|
                std.Io.Dir.cwd().openDir(io, name, .{}) catch |err| switch (err) {
                    error.AccessDenied, error.PermissionDenied => print.system_error(io, "{s}: output directory for '{s}' cannot be opened: permission denied", .{ command_name, path }),
                    error.FileNotFound => print.system_error(io, "{s}: output path '{s}' has a missing parent directory", .{ command_name, path }),
                    error.NotDir => print.system_error(io, "{s}: output path '{s}' has a non-directory path component", .{ command_name, path }),
                    else => print.system_error(io, "{s}: failed to open output directory for '{s}': {t}", .{ command_name, path, err }),
                }
            else
                std.Io.Dir.cwd();
            const close_dir = dirname != null;
            errdefer if (close_dir) dir.close(io);

            var temp_name: [32]u8 = undefined;
            var attempt: u8 = 0;
            while (attempt < collision_retries_max) : (attempt += 1) {
                var nonce: u64 = undefined;
                io.random(std.mem.asBytes(&nonce));
                const name = std.fmt.bufPrint(&temp_name, ".cimd-{x}.tmp", .{nonce}) catch unreachable;
                const temp_file = dir.createFile(io, name, .{ .exclusive = true }) catch |err| switch (err) {
                    error.PathAlreadyExists, error.FileBusy, error.DeviceBusy => continue,
                    error.AccessDenied, error.PermissionDenied => print.system_error(io, "{s}: output file '{s}' cannot be written: permission denied", .{ command_name, path }),
                    error.NotDir => print.system_error(io, "{s}: output path '{s}' has a non-directory path component", .{ command_name, path }),
                    error.FileNotFound => print.system_error(io, "{s}: output path '{s}' has a missing parent directory", .{ command_name, path }),
                    error.NoSpaceLeft => print.system_error(io, "{s}: no space left while opening output file '{s}'", .{ command_name, path }),
                    else => print.system_error(io, "{s}: failed to open temporary output beside '{s}': {t}", .{ command_name, path, err }),
                };
                return .{
                    .output_file = temp_file,
                    .dir = dir,
                    .target_basename = std.fs.path.basename(path),
                    .temp_name = temp_name,
                    .temp_name_len = @intCast(name.len),
                    .owned = true,
                    .file_open = true,
                    .temp_exists = true,
                    .close_dir = close_dir,
                };
            }
            print.system_error(io, "{s}: could not create a unique temporary output beside '{s}' after {d} attempts", .{
                command_name, path, collision_retries_max,
            });
        };
        return .{
            .output_file = std.Io.File.stdout(),
            .dir = std.Io.Dir.cwd(),
            .target_basename = "",
            .temp_name = undefined,
            .temp_name_len = 0,
            .owned = false,
            .file_open = false,
            .temp_exists = false,
            .close_dir = false,
        };
    }

    fn file(self: *AtomicOutput) std.Io.File {
        return self.output_file;
    }

    fn commit(self: *AtomicOutput, io: std.Io) !void {
        if (!self.owned) return;
        assert(self.file_open and self.temp_exists);
        self.output_file.close(io);
        self.file_open = false;
        try self.dir.rename(self.temp_name[0..self.temp_name_len], self.dir, self.target_basename, io);
        self.temp_exists = false;
    }

    fn deinit(self: *AtomicOutput, io: std.Io) void {
        if (self.file_open) self.output_file.close(io);
        if (self.temp_exists) self.dir.deleteFile(io, self.temp_name[0..self.temp_name_len]) catch {};
        if (self.close_dir) self.dir.close(io);
        self.* = undefined;
    }
};

test "stdout output is borrowed" {
    const implicit = try open_output(std.testing.io, "test", null);
    try std.testing.expect(!implicit.owned);

    const explicit = try open_output(std.testing.io, "test", io_read.stdin_token);
    try std.testing.expect(!explicit.owned);
}

fn open_output(io: std.Io, command_name: []const u8, output_path: ?[]const u8) !Output {
    if (output_path) |path| {
        if (!io_read.is_stdin(path)) return .{
            .file = try create_output_file(io, command_name, path),
            .owned = true,
        };
    }
    return .{ .file = std.Io.File.stdout(), .owned = false };
}

fn create_output_file(io: std.Io, command_name: []const u8, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => print.system_error(io, "{s}: output file '{s}' cannot be written: permission denied", .{ command_name, path }),
        error.IsDir => print.system_error(io, "{s}: output path '{s}' is a directory, expected a file", .{ command_name, path }),
        error.NotDir => print.system_error(io, "{s}: output path '{s}' has a non-directory path component", .{ command_name, path }),
        error.FileNotFound => print.system_error(io, "{s}: output path '{s}' has a missing parent directory", .{ command_name, path }),
        error.FileTooBig => print.system_error(io, "{s}: output file '{s}' is too large", .{ command_name, path }),
        error.NoSpaceLeft => print.system_error(io, "{s}: no space left while opening output file '{s}'", .{ command_name, path }),
        else => print.system_error(io, "{s}: failed to open output file '{s}': {t}", .{ command_name, path, err }),
    };
}

/// Map the CLI's diff format to the report-mode options of diff.zig.
/// Only valid for the report formats; .eqdiff is dispatched to eqdiff.zig.
fn diff_options(c: cli.Command.Diff) diff.DiffOptions {
    return .{
        .type_filter = c.type_filter,
        .format = switch (c.format) {
            .patch => .patch,
            .json => .json,
            .summary => .summary,
            .eqdiff => unreachable,
        },
    };
}

fn command_topology(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Topology) !void {
    var inputs = try model_set.load_merged(io, gpa, "topology", c.model_inputs.slice(), .topology);
    defer inputs.deinit(gpa);
    const model = &inputs.model;
    const ssh_opt: ?Overlay = if (inputs.ssh) |loaded| loaded.overlay else null;
    const primary_path = inputs.primary_source.label();

    const boundary_ids: std.StringHashMapUnmanaged(void) = .empty;
    var index = cross_ref.CrossRef.build_for_topology(gpa, model, boundary_ids) catch |err| switch (err) {
        error.MissingTerminals => invalid_model_structure(io, "topology", "Terminal"),
        else => return model_operation_error(io, "topology", primary_path, err),
    };
    defer index.deinit(gpa);

    var topology = resolve.Topology.build_for_topological_nodes(gpa, model, &index) catch |err|
        return model_operation_error(io, "topology", primary_path, err);
    defer topology.deinit(gpa);

    const ssh_ptr: ?*const Overlay = if (ssh_opt) |*s| s else null;
    var nodes = resolve.build_topological_nodes(gpa, model, &index, &topology, ssh_ptr) catch |err|
        return model_operation_error(io, "topology", primary_path, err);
    defer nodes.deinit(gpa);

    try print.stderr_info(io, "TopologicalNodes: {d}\n", .{nodes.items.len});

    const output = try open_output(io, "topology", c.output_path);
    defer output.deinit(io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(output.file, io, &write_buffer);
    const w = &file_writer.interface;

    try print.file_writer_result(
        &file_writer,
        std.json.Stringify.value(.{ .topologicalNodes = nodes.items }, .{}, w),
    );
    try print.file_writer_result(&file_writer, w.writeByte('\n'));
    try print.flush_file_writer(&file_writer);
}

fn command_validate(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Validate) !void {
    // Rule sets load first: a bad rules file should not cost a model parse.
    var rule_sets: [cli.Command.Validate.rules_count_max]RuleSet = undefined;
    var rule_sets_count: usize = 0;
    defer for (rule_sets[0..rule_sets_count]) |*rules| rules.deinit(gpa);
    for (c.rules()) |path| {
        const bytes = try read_rules_path(io, gpa, path);
        var diagnostics: RuleSet.Diagnostics = .{};
        // QoCDC requires constant references in rule messages to reach
        // users as value and unit; NC messages contain none, so the table
        // costs nothing there.
        rule_sets[rule_sets_count] = RuleSet.load(
            gpa,
            bytes,
            path,
            &validate.qocdc_substitutions,
            &diagnostics,
        ) catch |err| rule_set_load_error(io, path, diagnostics.line, err);
        rule_sets_count += 1;
    }

    var documents = try model_set.plan_documents(io, gpa, "validate", c.model_inputs.slice(), .single_pair);
    defer documents.deinit(gpa);
    var output = try AtomicOutput.open(io, "validate", c.output_path);
    defer output.deinit(io);
    var write_buffer: [64 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(output.file(), io, &write_buffer);
    const totals = try write_validation_documents(
        io,
        gpa,
        c,
        rule_sets[0..rule_sets_count],
        &documents,
        &output,
        &file_writer,
    );
    try print.flush_file_writer(&file_writer);
    try output.commit(io);

    // Violations have a command-specific exit code; warnings and info findings
    // do not fail the run.
    if (totals.violations > 0) std.process.exit(print.exit_validation_failed);
}

const ValidationTotals = struct { violations: u64 = 0, truncated: u64 = 0 };

fn write_validation_documents(
    io: std.Io,
    gpa: std.mem.Allocator,
    c: cli.Command.Validate,
    rule_sets: []RuleSet,
    documents: *model_set.DocumentSet,
    output: *AtomicOutput,
    file_writer: *std.Io.File.Writer,
) !ValidationTotals {
    const multiple_documents = documents.count() > 1;
    if (multiple_documents) try print.file_writer_result(
        file_writer,
        file_writer.interface.writeAll("warning: parts validated independently; cross-part references are not resolved\n"),
    );

    var remaining_violations: u32 = validate.violations_count_max;
    var totals: ValidationTotals = .{};
    var document_index: u32 = 0;
    while (document_index < documents.count()) : (document_index += 1) {
        var parse_diagnostics: model_set.ParseDiagnostics = .{};
        var document = (documents.next(gpa, &parse_diagnostics) catch |err| {
            output.deinit(io);
            model_set.report_document_parse_error(io, "validate", err, parse_diagnostics);
        }) orelse unreachable;
        defer documents.release(gpa, &document);

        if (multiple_documents) try write_validation_heading(file_writer, document);

        var evaluations: [cli.Command.Validate.rules_count_max]validate.Evaluation = undefined;
        var entries: [cli.Command.Validate.rules_count_max]validate.ReportEntry = undefined;
        var evaluations_count: u32 = 0;
        defer for (evaluations[0..evaluations_count]) |*evaluation| evaluation.deinit(gpa);
        for (rule_sets, 0..) |*rules, i| {
            evaluations[i] = try validate.evaluate_with_limit(gpa, &document.model, rules, remaining_violations);
            evaluations_count += 1;
            remaining_violations -= @intCast(evaluations[i].violations.items.len);
            entries[i] = .{ .rules = rules, .evaluation = &evaluations[i] };
        }
        const document_totals = try print.file_writer_result(file_writer, validate.write_report(
            gpa,
            &file_writer.interface,
            &document.model,
            document.segments[0..document.segments_count],
            entries[0..evaluations_count],
            .{ .list_skipped = c.list_skipped, .write_truncation = !multiple_documents },
        ));
        totals.violations += document_totals.violations;
        totals.truncated += document_totals.truncated;
    }
    if (multiple_documents and totals.truncated > 0) try print.file_writer_result(
        file_writer,
        file_writer.interface.print("summary: {d} further violations truncated (global limit {d})\n", .{
            totals.truncated, validate.violations_count_max,
        }),
    );
    return totals;
}

fn write_validation_heading(file_writer: *std.Io.File.Writer, document: model_set.LoadedDocument) !void {
    try print.file_writer_result(file_writer, file_writer.interface.writeAll("\n── "));
    try print.file_writer_result(file_writer, file_writer.interface.writeAll(document.segments[0].name));
    if (document.segments_count == 2) {
        try print.file_writer_result(file_writer, file_writer.interface.writeAll(" + "));
        try print.file_writer_result(file_writer, file_writer.interface.writeAll(document.segments[1].name));
    }
    try print.file_writer_result(file_writer, file_writer.interface.writeAll(" ──\n"));
}

fn command_qocdc(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Qocdc) !void {
    const read_options: InputSpec = .{
        .command_name = "qocdc",
        .role = "input file",
        .path = c.eq_path,
        .extension = ".xml",
        .max_bytes = max_in_memory_input_bytes,
    };

    // QoCDC input is a ZIP container holding exactly one XML entry; the
    // container shape is an input error (immediate exit), while the entry
    // name's *content* feeds the FileNameConsistency rule below.
    var entry_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const entry_name = qocdc_zip_entry_name(io, c.eq_path, &entry_name_buffer) catch |err| switch (err) {
        error.NotZipArchive => print.data_error(io, "qocdc: input '{s}' is not a ZIP archive", .{c.eq_path}),
        error.ZipInsufficientBuffer => print.data_error(io, "qocdc: ZIP entry name exceeds the supported path length", .{}),
        error.WrongZipEntryCount => print.data_error(io, "qocdc: ZIP container '{s}' must hold exactly one file", .{c.eq_path}),
        else => input_read_error(io, read_options, err, null),
    };

    const xml = read_path(io, gpa, c.eq_path) catch |err| input_read_error(io, read_options, err, null);
    var model = CimDocument.init(gpa, xml) catch |err| input_read_error(io, read_options, err, null);
    defer model.deinit(gpa);

    var report: qocdc.Report = .empty;
    defer report.deinit(gpa);
    const stem = std.fs.path.stem(std.fs.path.basename(c.eq_path));
    try qocdc.validate_filename(&report, gpa, stem, std.fs.path.stem(entry_name));
    try qocdc.validate_model(&report, gpa, &model);

    var write_buffer: [16 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stderr(), io, &write_buffer);
    const colors: qocdc.SeverityColors = if (print.colors_enabled(.stderr))
        .{
            .@"error" = cli.ansi_bright_red,
            .warning = cli.ansi_bright_yellow,
            .info = cli.ansi_bright_cyan,
            .reset = cli.ansi_default,
        }
    else
        .plain;
    const totals = qocdc.write_report(gpa, &file_writer.interface, &model, &report, colors) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => print.system_error(io, "qocdc: failed to write the report: {t}", .{err}),
        };
    print.flush_file_writer(&file_writer) catch |err|
        print.system_error(io, "qocdc: failed to write the report: {t}", .{err});
    // Only error-severity findings fail the run; warnings and info are
    // reported and ignored, matching `command_validate`'s contract.
    if (totals.errors > 0) std.process.exit(print.exit_data_error);
}

/// The single entry name of the QoCDC ZIP container. Moved out of the qocdc
/// library: opening files is the application's job.
fn qocdc_zip_entry_name(io: std.Io, file_path: []const u8, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, file_path, .{});
    defer file.close(io);

    if (!try zip.is_zip_file(io, file)) return error.NotZipArchive;

    var zip_buffer: [512]u8 = undefined;
    var file_reader = file.reader(io, &zip_buffer);
    var iter = try std.zip.Iterator.init(&file_reader);

    const entry = try iter.next() orelse return error.WrongZipEntryCount;
    if (buffer.len < entry.filename_len) return error.ZipInsufficientBuffer;
    const entry_name = buffer[0..entry.filename_len];
    try file_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
    try file_reader.interface.readSliceAll(entry_name);

    if (try iter.next() != null) return error.WrongZipEntryCount;
    return entry_name;
}

fn invalid_model_structure(io: std.Io, command_name: []const u8, required_type: []const u8) noreturn {
    print.data_error(
        io,
        "{s}: EQ profile contains no {s} objects required by this command",
        .{ command_name, required_type },
    );
}

fn conversion_id_error(
    io: std.Io,
    segments: []const validate.DataSegment,
    model: *const CimDocument,
    diagnostics: converter.ConversionDiagnostics,
    err: anyerror,
) noreturn {
    const issue = diagnostics.id_issue orelse print.data_error(
        io,
        "convert: EQ profile '{s}' contains an invalid IIDM identifier",
        .{segments[0].name},
    );
    switch (issue.kind) {
        .empty => {
            assert(err == error.EmptyMrid);
            if (issue.offset) |offset| {
                const segment = validate.segment_of(segments, offset);
                const line = validate.segment_local_line(segment, diagnostics_mod.line_number_at(model.xml, offset));
                print.data_error(
                    io,
                    "convert: {s} '{s}': RDF identifier '{s}' resolves to an empty mRID at line {d}",
                    .{ segment_role(segment), segment.name, issue.raw_id, line },
                );
            }
            print.data_error(io, "convert: emitted IIDM object has an empty identifier", .{});
        },
        .duplicate => {
            assert(err == error.DuplicateMrid);
            if (issue.offset) |offset| {
                const segment = validate.segment_of(segments, offset);
                const line = validate.segment_local_line(segment, diagnostics_mod.line_number_at(model.xml, offset));
                print.data_error(
                    io,
                    "convert: {s} '{s}': duplicate resolved mRID '{s}' at line {d}",
                    .{ segment_role(segment), segment.name, issue.mrid, line },
                );
            }
            print.data_error(io, "convert: duplicate emitted IIDM identifier '{s}'", .{issue.mrid});
        },
    }
}

/// The primary EQ input starts at offset 0; any later segment is the EQBD
/// boundary profile concatenated after it.
fn segment_role(segment: validate.DataSegment) []const u8 {
    return if (segment.start == 0) "EQ profile" else "EQBD boundary profile";
}

fn is_model_data_error(err: anyerror) bool {
    return switch (err) {
        error.MalformedXML,
        error.MalformedTag,
        error.InvalidNumericValue,
        error.InvalidIntegerValue,
        error.InvalidTapStepRange,
        error.TapStepRangeTooLarge,
        error.EmptyMrid,
        error.DuplicateMrid,
        => true,
        else => false,
    };
}

fn is_model_capacity_error(err: anyerror) bool {
    return switch (err) {
        error.ForecastDistanceTooLarge,
        error.TooManyInternalConnections,
        error.TooManySubstations,
        error.TooManyTransformers,
        error.TooManyVoltageLevelEquipment,
        error.TooManyIidmObjects,
        error.NodeIdOverflow,
        => true,
        else => false,
    };
}

/// Route errors from model transformation stages into the CLI's data/capacity
/// taxonomy while preserving unrelated failures for the command-level handler.
fn model_operation_error(
    io: std.Io,
    command_name: []const u8,
    path: []const u8,
    err: anyerror,
) anyerror {
    if (is_model_data_error(err)) invalid_model_data(io, command_name, path, err);
    if (is_model_capacity_error(err)) model_capacity_error(io, command_name, path, err);
    return err;
}

test "model transformation errors distinguish bad data from fixed capacities" {
    try std.testing.expect(is_model_data_error(error.MalformedXML));
    try std.testing.expect(is_model_data_error(error.InvalidNumericValue));
    try std.testing.expect(is_model_data_error(error.DuplicateMrid));
    try std.testing.expect(!is_model_data_error(error.OutOfMemory));
    try std.testing.expect(!is_model_data_error(error.TooManySubstations));
    try std.testing.expect(is_model_capacity_error(error.TooManySubstations));
}

fn invalid_model_data(
    io: std.Io,
    command_name: []const u8,
    path: []const u8,
    err: anyerror,
) noreturn {
    print.data_error(
        io,
        "{s}: EQ profile '{s}' contains invalid model data: {t}",
        .{ command_name, path, err },
    );
}

fn model_capacity_error(
    io: std.Io,
    command_name: []const u8,
    path: []const u8,
    err: anyerror,
) noreturn {
    print.data_error(
        io,
        "{s}: EQ profile '{s}' exceeds a supported model capacity: {t}",
        .{ command_name, path, err },
    );
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

const InputSpec = struct {
    command_name: []const u8,
    role: []const u8,
    path: []const u8,
    extension: []const u8,
    max_bytes: u64,
};

const ParseSpec = struct {
    command_name: []const u8,
    role: []const u8,
    path: []const u8,
    secondary_path: ?[]const u8 = null,
};

fn rules_input(path: []const u8) InputSpec {
    return .{
        .command_name = "validate",
        .role = "SHACL rules file",
        .path = path,
        .extension = ".ttl",
        .max_bytes = rule_set.rules_bytes_max,
    };
}

/// SHACL rule bundles are zips of Turtle, not XML. A .zip rule bundle reuses
/// io/zip.zig exactly as data files do. The rules size limit applies before
/// the file is read or decompressed, not only at RuleSet.load.
fn read_rules_path(io: std.Io, gpa: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    return read_path_extension(io, gpa, rules_input(file_path));
}

fn read_path_extension(io: std.Io, gpa: std.mem.Allocator, spec: InputSpec) ![]const u8 {
    var diagnostics: io_read.Diagnostics = .{};
    return io_read.read_path_options(io, gpa, spec.path, .{
        .extension = spec.extension,
        .max_bytes = spec.max_bytes,
        .diagnostics = &diagnostics,
    }) catch |err| input_read_error(io, spec, err, diagnostics.actual_size);
}

fn input_read_error(io: std.Io, spec: InputSpec, err: anyerror, actual_size: ?u64) noreturn {
    switch (err) {
        error.FileTooLarge, error.StreamTooLong => input_too_large(io, spec, actual_size),
        error.FileNotFound => print.no_input(io, "{s}: {s} '{s}' was not found", .{ spec.command_name, spec.role, spec.path }),
        error.AccessDenied, error.PermissionDenied => print.no_input(io, "{s}: {s} '{s}' cannot be read: permission denied", .{ spec.command_name, spec.role, spec.path }),
        error.IsDir => print.no_input(io, "{s}: {s} '{s}' is a directory, expected a file", .{ spec.command_name, spec.role, spec.path }),
        error.NotDir => print.no_input(io, "{s}: {s} '{s}' has a non-directory path component", .{ spec.command_name, spec.role, spec.path }),
        error.FileTruncated, error.FileGrew => print.system_error(
            io,
            "{s}: {s} '{s}' changed size while it was being read",
            .{ spec.command_name, spec.role, spec.path },
        ),
        error.ZipArchiveHasNoMatchingFiles => print.data_error(
            io,
            "{s}: {s} '{s}': ZIP archive contains no {s} file",
            .{ spec.command_name, spec.role, spec.path, spec.extension },
        ),
        error.UnsupportedCompressionMethod => print.data_error(
            io,
            "{s}: {s} '{s}': ZIP entry uses an unsupported compression method (supported: store, deflate)",
            .{ spec.command_name, spec.role, spec.path },
        ),
        error.ZipBadFilename, error.ZipFilenameHasBackslash => print.data_error(
            io,
            "{s}: {s} '{s}': ZIP archive contains an unsafe entry name",
            .{ spec.command_name, spec.role, spec.path },
        ),
        error.ZipDecompressTruncated, error.EndOfStream => print.data_error(
            io,
            "{s}: {s} '{s}': ZIP archive is truncated",
            .{ spec.command_name, spec.role, spec.path },
        ),
        error.OutOfMemory => print.system_error(io, "{s}: not enough memory while reading {s} '{s}'", .{ spec.command_name, spec.role, spec.path }),
        else => {
            // Every remaining ZIP structural/parse/unsupported error (both std.zip
            // and our io/zip.zig name them "Zip...") means the input archive is
            // malformed or unsupported, not an OS failure -- classify as bad input.
            if (is_malformed_zip_error(err)) print.data_error(
                io,
                "{s}: {s} '{s}': ZIP archive is malformed or corrupt",
                .{ spec.command_name, spec.role, spec.path },
            );
            print.system_error(io, "{s}: failed to read {s} '{s}': {t}", .{ spec.command_name, spec.role, spec.path, err });
        },
    }
}

/// Whether `err` is a ZIP parser/structure error. Both std.zip and our
/// io/zip.zig prefix these "Zip...", so a malformed or unsupported archive is
/// bad user input (exit 65) rather than an operating-system failure (exit 71).
fn is_malformed_zip_error(err: anyerror) bool {
    return std.mem.startsWith(u8, @errorName(err), "Zip");
}

test "malformed ZIP parser errors classify as bad input" {
    try std.testing.expect(is_malformed_zip_error(error.ZipNoEndRecord));
    try std.testing.expect(is_malformed_zip_error(error.ZipTruncated));
    try std.testing.expect(is_malformed_zip_error(error.ZipInvalid));
    try std.testing.expect(is_malformed_zip_error(error.ZipBadFileOffset));
    try std.testing.expect(!is_malformed_zip_error(error.OutOfMemory));
    try std.testing.expect(!is_malformed_zip_error(error.FileNotFound));
}

fn input_too_large(io: std.Io, spec: InputSpec, actual_size: ?u64) noreturn {
    var limit_buf: [print.size_limit_text_buffer_bytes]u8 = undefined;
    const limit = print.size_limit_text(&limit_buf, actual_size, spec.max_bytes);
    print.data_error(io, "{s}: {s} '{s}' is too large ({s})", .{ spec.command_name, spec.role, spec.path, limit });
}

fn rule_set_load_error(io: std.Io, path: []const u8, line: u32, err: anyerror) noreturn {
    const spec: ParseSpec = .{
        .command_name = "validate",
        .role = "SHACL rules file",
        .path = path,
    };
    const actual_line = if (line == 0) 1 else line;
    switch (err) {
        error.RuleSetTooLarge => {
            var limit_buf: [print.size_limit_text_buffer_bytes]u8 = undefined;
            const limit = print.size_limit_text(&limit_buf, null, rule_set.rules_bytes_max);
            parse_error(io, spec, "rule set is too large ({s})", .{limit});
        },
        error.InvalidEscape => parse_error(io, spec, "invalid Turtle escape at line {d}", .{actual_line}),
        error.InvalidNumber => parse_error(io, spec, "invalid Turtle number at line {d}", .{actual_line}),
        error.InvalidDirective => parse_error(io, spec, "invalid Turtle directive at line {d}", .{actual_line}),
        error.TooManyTriples => parse_error(io, spec, "too many Turtle triples (max {d})", .{rule_set.triples_count_max}),
        error.TooManyShapes => parse_error(io, spec, "too many SHACL shapes (max {d})", .{rule_set.shapes_count_max}),
        error.TooManyConstraints => parse_error(io, spec, "too many SHACL constraints (max {d})", .{rule_set.constraints_count_max}),
        error.TooManyClosedPaths => parse_error(io, spec, "too many SHACL closed-shape paths (max {d})", .{rule_set.closed_paths_count_max}),
        error.TooManyListValues => parse_error(io, spec, "too many values in a SHACL list at line {d}", .{actual_line}),
        error.MalformedList => parse_error(io, spec, "malformed SHACL list at line {d}", .{actual_line}),
        error.MessageTooLong => parse_error(io, spec, "SHACL message at line {d} is too long (max {d} bytes)", .{
            actual_line,
            rule_set.message_bytes_max,
        }),
        error.OutOfMemory => system_parse_error(io, spec, "not enough memory while loading rules", .{}),
        else => parse_error(io, spec, "failed to load rules at line {d}: {t}", .{ actual_line, err }),
    }
}

fn parse_error(io: std.Io, spec: ParseSpec, comptime fmt_str: []const u8, args: anytype) noreturn {
    formatted_parse_error(io, print.exit_data_error, spec, fmt_str, args);
}

fn system_parse_error(io: std.Io, spec: ParseSpec, comptime fmt_str: []const u8, args: anytype) noreturn {
    formatted_parse_error(io, print.exit_system_error, spec, fmt_str, args);
}

fn formatted_parse_error(
    io: std.Io,
    exit_code: u8,
    spec: ParseSpec,
    comptime fmt_str: []const u8,
    args: anytype,
) noreturn {
    var detail_buf: [512]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, fmt_str, args) catch "(details unavailable)";
    if (spec.secondary_path) |secondary| {
        print.exit_error(io, exit_code, "{s}: {s} '{s}' + '{s}': {s}", .{
            spec.command_name,
            spec.role,
            spec.path,
            secondary,
            detail,
        });
    }
    print.exit_error(io, exit_code, "{s}: {s} '{s}': {s}", .{ spec.command_name, spec.role, spec.path, detail });
}
