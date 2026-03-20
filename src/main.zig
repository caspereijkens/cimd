const std = @import("std");
const cli = @import("cli.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const print = @import("print.zig");
const assert = std.debug.assert;
const zip = @import("zip.zig");
const cim_model = @import("cim_model.zig");
const cim_index = @import("cim_index.zig");
const iidm = @import("iidm.zig");
const substation_conv = @import("convert/substation.zig");
const voltage_level_conv = @import("convert/voltage_level.zig");
const connection_conv = @import("convert/connection.zig");
const equipment_conv = @import("convert/equipment.zig");

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();

    const gpa = arena_instance.allocator();

    var arg_iterator = try std.process.argsWithAllocator(gpa);
    defer arg_iterator.deinit();

    const command = cli.parse_args(&arg_iterator);

    switch (command) {
        .index => |_| try command_index(gpa, command.index.paths),
        .convert => |c| try command_convert(gpa, c.input_path, c.eqbd_path, c.output_path, c.verbose),
        .version => |_| try command_version(command.version.verbose),
    }
}

fn command_version(verbose: bool) !void {
    const version_string = build_options.version;
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

fn command_index(gpa: std.mem.Allocator, paths: []const []const u8) !void {
    const cwd = std.fs.cwd();
    var buffer: [4096]u8 = undefined;

    for (paths) |path| {
        const file = try cwd.openFile(path, .{});
        defer file.close();

        if (try zip.isZipFile(file)) {
            // ZIP file: extract to memory and process each contained file
            var file_reader = file.reader(&buffer);
            var extracted_files = try zip.extractToMemory(gpa, &file_reader, .{});
            defer {
                for (extracted_files.items) |extracted_file| {
                    extracted_file.deinit(gpa);
                }
                extracted_files.deinit(gpa);
            }

            for (extracted_files.items) |extracted_file| {
                try print.stdout("File: {s}\n", .{extracted_file.filename});

                var model = try cim_model.CimModel.init(gpa, extracted_file.data);
                defer model.deinit(gpa);

                try print.displayObjectInventory(gpa, model);
                try print.stdout("\n", .{});
            }
        } else {
            // Regular XML file: read to memory and process
            try print.stdout("File: {s}\n", .{path});

            const xml = try readFileToMemory(gpa, file);
            defer gpa.free(xml);

            var model = try cim_model.CimModel.init(gpa, xml);
            defer model.deinit(gpa);

            try print.displayObjectInventory(gpa, model);
        }
    }
}

fn read_path(gpa: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const cwd = std.fs.cwd();

    const file = try cwd.openFile(file_path, .{});
    defer file.close();

    if (try zip.isZipFile(file)) {
        var zip_buffer: [4096]u8 = undefined;
        var file_reader = file.reader(&zip_buffer);
        const extracted_files = try zip.extractToMemory(gpa, &file_reader, .{});
        return extracted_files.items[0].data;
    } else {
        return try readFileToMemory(gpa, file);
    }
}

fn command_convert(gpa: std.mem.Allocator, input_path: []const u8, eqbd_path: ?[]const u8, output_path: ?[]const u8, verbose: bool) !void {
    _ = output_path;
    _ = verbose;

    var xml = try read_path(gpa, input_path);

    if (eqbd_path) |path| {
        const eqbd_xml = try read_path(gpa, path);
        const merged = try std.mem.concat(gpa, u8, &[_][]const u8{ xml, eqbd_xml });
        xml = merged;
    }

    var model = try cim_model.CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    const boundary_ids: std.StringHashMapUnmanaged(void) = .empty;
    var index = try cim_index.CimIndex.build(gpa, &model, boundary_ids);
    defer index.deinit(gpa);

    var network = iidm.Network{
        .id = "test",
        .case_date = null,
        .substations = .empty,
        .lines = .empty,
        .hvdc_lines = .empty,
        .extensions = .empty,
    };
    defer network.deinit(gpa);

    var sub_id_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer sub_id_map.deinit(gpa);
    try substation_conv.convert_substations(gpa, &model, &index, &network, &sub_id_map);
    try print.stdout("Substations: {d}\n", .{network.substations.items.len});

    try voltage_level_conv.convert_voltage_levels(gpa, &model, &index, &network, &sub_id_map);
    var total_vls: usize = 0;
    for (network.substations.items) |sub| total_vls += sub.voltage_levels.items.len;
    try print.stdout("VoltageLevels: {d}\n", .{total_vls});

    var voltage_level_map = try voltage_level_conv.build_voltage_level_map(gpa, &model, &index, &network, &sub_id_map);
    defer voltage_level_map.deinit(gpa);

    var node_map = try connection_conv.build_node_map(gpa, &model, &index);
    defer node_map.deinit(gpa);
    try print.stdout("Nodes: {d}\n", .{node_map.count()});

    try equipment_conv.pre_allocate_equipment(gpa, &model, &index, &voltage_level_map);
    try equipment_conv.convert_busbar_sections(&model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_switches(&model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_loads(&model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_shunts(&model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_static_var_compensators(&model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_generators(gpa, &model, &index, &voltage_level_map, &node_map);

    var total_busbar_sections: usize = 0;
    var total_switches: usize = 0;
    var total_loads: usize = 0;
    var total_shunts: usize = 0;
    var total_svcs: usize = 0;
    var total_generators: usize = 0;
    for (network.substations.items) |sub| {
        for (sub.voltage_levels.items) |vl| {
            total_busbar_sections += vl.node_breaker_topology.busbar_sections.items.len;
            total_switches += vl.node_breaker_topology.switches.items.len;
            total_loads += vl.loads.items.len;
            total_shunts += vl.shunts.items.len;
            total_svcs += vl.static_var_compensators.items.len;
            total_generators += vl.generators.items.len;
        }
    }
    try print.stdout("BusbarSections: {d}\n", .{total_busbar_sections});
    try print.stdout("Switches: {d}\n", .{total_switches});
    try print.stdout("Loads: {d}\n", .{total_loads});
    try print.stdout("Shunts: {d}\n", .{total_shunts});
    try print.stdout("StaticVarCompensators: {d}\n", .{total_svcs});
    try print.stdout("Generators: {d}\n", .{total_generators});
}

/// Read file into memory (used for unzipped usecase)
pub fn readFileToMemory(
    gpa: std.mem.Allocator,
    file: std.fs.File,
) ![]u8 {
    const file_size = try file.getEndPos();

    // Reject files >4GB (matches our u32 indexing limit)
    if (file_size > std.math.maxInt(u32)) {
        return error.FileTooLarge;
    }

    return try file.readToEndAlloc(gpa, file_size);
}
