const std = @import("std");
const cli = @import("cli.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const print = @import("print.zig");
const assert = std.debug.assert;
const zip = @import("zip.zig");
const tag_index = @import("tag_index.zig");
const cim_model = @import("cim_model.zig");
const topology = @import("topology.zig");
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
        .convert => |c| try command_convert(gpa, c.input_path, c.output_path),
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

fn command_convert(gpa: std.mem.Allocator, input_path: []const u8, output_path: ?[]const u8) !void {
    const cwd = std.fs.cwd();

    const file = try cwd.openFile(input_path, .{});
    defer file.close();

    var zip_buffer: [4096]u8 = undefined;
    const xml = if (try zip.isZipFile(file)) blk: {
        var file_reader = file.reader(&zip_buffer);
        const extracted_files = try zip.extractToMemory(gpa, &file_reader, .{});
        break :blk extracted_files.items[0].data;
    } else try readFileToMemory(gpa, file);
    defer gpa.free(xml);

    var model = try cim_model.CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    var topo = try topology.TopologyResolver.init(gpa, &model);
    defer topo.deinit();

    var conv = converter.Converter.init(gpa, &model, &topo);
    var network = try conv.convert();
    defer network.deinit(gpa);

    // Create output file or use stdout
    const output_file = if (output_path) |path|
        try cwd.createFile(path, .{})
    else
        std.fs.File.stdout();
    defer if (output_path != null) output_file.close();

    // Create File.Writer with buffer, then use its .interface
    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.fs.File.Writer.init(output_file, &write_buffer);

    try std.json.Stringify.value(network, .{}, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
}

fn command_not_implemented(comptime command_name: []const u8) !void {
    try print.stdout("Command '{s}' - to be implemented\n", .{command_name});
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
