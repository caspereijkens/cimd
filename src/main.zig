const std = @import("std");
const cli = @import("cli.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const print = @import("print.zig");
const assert = std.debug.assert;
const zip = @import("zip.zig");
const cim_model = @import("cim_model.zig");
const converter = @import("converter.zig");

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
    _ = verbose;

    var xml = try read_path(gpa, input_path);

    if (eqbd_path) |path| {
        const eqbd_xml = try read_path(gpa, path);
        const merged = try std.mem.concat(gpa, u8, &[_][]const u8{ xml, eqbd_xml });
        xml = merged;
    }

    var model = try cim_model.CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    var network = try converter.convert(gpa, &model);
    defer network.deinit(gpa);

    var total_vls: usize = 0;
    var total_busbar_sections: usize = 0;
    var total_switches: usize = 0;
    var total_loads: usize = 0;
    var total_shunts: usize = 0;
    var total_svcs: usize = 0;
    var total_generators: usize = 0;
    var total_2w: usize = 0;
    var total_3w: usize = 0;
    for (network.substations.items) |sub| {
        total_vls += sub.voltage_levels.items.len;
        total_2w += sub.two_winding_transformers.items.len;
        total_3w += sub.three_winding_transformers.items.len;
        for (sub.voltage_levels.items) |vl| {
            total_busbar_sections += vl.node_breaker_topology.busbar_sections.items.len;
            total_switches += vl.node_breaker_topology.switches.items.len;
            total_loads += vl.loads.items.len;
            total_shunts += vl.shunts.items.len;
            total_svcs += vl.static_var_compensators.items.len;
            total_generators += vl.generators.items.len;
        }
    }
    std.debug.print("Substations: {d}\n", .{network.substations.items.len});
    std.debug.print("VoltageLevels: {d}\n", .{total_vls});
    std.debug.print("BusbarSections: {d}\n", .{total_busbar_sections});
    std.debug.print("Switches: {d}\n", .{total_switches});
    std.debug.print("Loads: {d}\n", .{total_loads});
    std.debug.print("Shunts: {d}\n", .{total_shunts});
    std.debug.print("StaticVarCompensators: {d}\n", .{total_svcs});
    std.debug.print("Generators: {d}\n", .{total_generators});
    std.debug.print("2-winding transformers: {d}\n", .{total_2w});
    std.debug.print("3-winding transformers: {d}\n", .{total_3w});
    std.debug.print("Lines: {d}\n", .{network.lines.items.len});

    const cwd = std.fs.cwd();
    const output_file = if (output_path) |path|
        try cwd.createFile(path, .{})
    else
        std.fs.File.stdout();
    defer if (output_path != null) output_file.close();

    var write_buffer: [8192]u8 = undefined;
    var file_writer = std.fs.File.Writer.init(output_file, &write_buffer);
    try std.json.Stringify.value(network, .{}, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
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
