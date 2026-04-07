const std = @import("std");
const cli = @import("cli.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const print = @import("print.zig");
const zip = @import("zip.zig");
const cim_model = @import("cim_model.zig");
const converter = @import("converter.zig");
const browse = @import("browse.zig");

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();

    const gpa = arena_instance.allocator();

    var arg_iterator = try std.process.argsWithAllocator(gpa);
    defer arg_iterator.deinit();

    const command = cli.parse_args(&arg_iterator);

    switch (command) {
        .eq => |eq| switch (eq) {
            .convert => |c| try command_eq_convert(gpa, c.eq_path, c.eqbd_path, c.output_path),
            .browse => |c| try command_eq_browse(gpa, c.eq_path, c.eqbd_path, c.entry_id),
            .get => |c| try command_eq_get(gpa, c.eq_path, c.eqbd_path, c.mrid, c.type_filter),
            .types => |c| try command_eq_types(gpa, c.eq_path, c.eqbd_path, c.json),
        },
        .version => |v| try command_version(v.verbose, v.json),
    }
}

fn command_version(verbose: bool, json: bool) !void {
    const version_string = build_options.version;

    if (json) {
        if (verbose) {
            try print.stdout(
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
            try print.stdout("{{\"version\":\"{s}\"}}\n", .{version_string});
        }
        return;
    }

    try print.stdout("cimd {s}\n", .{version_string});

    if (verbose) {
        try print.stdout("\nBuild Information:\n", .{});
        try print.stdout("  Version:       {s}\n", .{version_string});
        try print.stdout("  Zig Version:   {s}\n", .{builtin.zig_version_string});
        try print.stdout("  Target:        {s}-{s}\n", .{
            @tagName(builtin.cpu.arch),
            @tagName(builtin.os.tag),
        });
        try print.stdout("  Optimize:      {s}\n", .{@tagName(builtin.mode)});
    }
}

fn command_eq_convert(gpa: std.mem.Allocator, eq_path: []const u8, eqbd_path: ?[]const u8, output_path: ?[]const u8) !void {
    var xml = try read_path(gpa, eq_path);

    if (eqbd_path) |path| {
        const eqbd_xml = try read_path(gpa, path);
        const merged = try std.mem.concat(gpa, u8, &[_][]const u8{ xml, eqbd_xml });
        xml = merged;
    }

    var model = try cim_model.CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    var network = try converter.convert(gpa, &model);
    defer network.deinit(gpa);

    var total_voltage_levels: usize = 0;
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
            total_busbar_sections += voltage_level.node_breaker_topology.busbar_sections.items.len;
            total_switches += voltage_level.node_breaker_topology.switches.items.len;
            total_loads += voltage_level.loads.items.len;
            total_shunts += voltage_level.shunts.items.len;
            total_svcs += voltage_level.static_var_compensators.items.len;
            total_generators += voltage_level.generators.items.len;
        }
    }
    try print.stdout("Substations: {d}\n", .{network.substations.items.len});
    try print.stdout("VoltageLevels: {d}\n", .{total_voltage_levels});
    try print.stdout("BusbarSections: {d}\n", .{total_busbar_sections});
    try print.stdout("Switches: {d}\n", .{total_switches});
    try print.stdout("Loads: {d}\n", .{total_loads});
    try print.stdout("Shunts: {d}\n", .{total_shunts});
    try print.stdout("StaticVarCompensators: {d}\n", .{total_svcs});
    try print.stdout("Generators: {d}\n", .{total_generators});
    try print.stdout("2-winding transformers: {d}\n", .{total_2w});
    try print.stdout("3-winding transformers: {d}\n", .{total_3w});
    try print.stdout("Lines: {d}\n", .{network.lines.items.len});

    const cwd = std.fs.cwd();
    const output_file = if (output_path) |path|
        try cwd.createFile(path, .{})
    else
        std.fs.File.stdout();
    defer if (output_path != null) output_file.close();

    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.fs.File.Writer.init(output_file, &write_buffer);
    try std.json.Stringify.value(network, .{}, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
}

fn command_eq_browse(gpa: std.mem.Allocator, eq_path: []const u8, eqbd_path: ?[]const u8, entry_id: []const u8) !void {
    var xml = try read_path(gpa, eq_path);

    if (eqbd_path) |path| {
        const eqbd_xml = try read_path(gpa, path);
        xml = try std.mem.concat(gpa, u8, &.{ xml, eqbd_xml });
    }

    var model = try cim_model.CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    try browse.browse(gpa, &model, xml, entry_id);
}

fn command_eq_get(gpa: std.mem.Allocator, eq_path: []const u8, eqbd_path: ?[]const u8, mrid: []const u8, type_filter: ?[]const u8) !void {
    _ = gpa;
    _ = eq_path;
    _ = eqbd_path;
    _ = mrid;
    _ = type_filter;
    print.stderr("eq get: not yet implemented", .{});
}

fn command_eq_types(gpa: std.mem.Allocator, eq_path: []const u8, eqbd_path: ?[]const u8, json: bool) !void {
    var xml = try read_path(gpa, eq_path);

    if (eqbd_path) |path| {
        const eqbd_xml = try read_path(gpa, path);
        xml = try std.mem.concat(gpa, u8, &.{ xml, eqbd_xml });
    }

    var model = try cim_model.CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    if (json) {
        try print.display_object_inventory_json(gpa, model);
    } else {
        try print.display_object_inventory(gpa, model);
    }
}

// ── Shared helpers ────────────────────────────────────────────────────────────

fn read_path(gpa: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const cwd = std.fs.cwd();
    const file = try cwd.openFile(file_path, .{});
    defer file.close();

    if (try zip.is_zip_file(file)) {
        var zip_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(&zip_buffer);
        var extracted_files = try zip.extract_to_memory(gpa, &file_reader, .{});
        const data = extracted_files.items[0].data;
        gpa.free(extracted_files.items[0].filename);
        for (extracted_files.items[1..]) |f| f.deinit(gpa);
        extracted_files.deinit(gpa);
        return data;
    } else {
        return try read_file_to_memory(gpa, file);
    }
}

pub fn read_file_to_memory(gpa: std.mem.Allocator, file: std.fs.File) ![]u8 {
    const file_size = try file.getEndPos();
    if (file_size > std.math.maxInt(u32)) return error.FileTooLarge;
    return try file.readToEndAlloc(gpa, file_size);
}
