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

fn readPath(gpa: std.mem.Allocator, file_path: []const u8) ![]const u8 {
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
    var total_timer = std.time.Timer.start() catch unreachable;

    var stage_timer = std.time.Timer.start() catch unreachable;
    var xml = try readPath(gpa, input_path);

    if (eqbd_path) |path| {
        const eqbd_xml = try readPath(gpa, path);
        defer gpa.free(eqbd_xml);

        const merged = try std.mem.concat(gpa, u8, &[_][]const u8{ xml, eqbd_xml });
        gpa.free(xml);

        xml = merged;
    }
    defer gpa.free(xml);
    if (verbose) printTiming("Read files", stage_timer.read());

    stage_timer.reset();
    var model = try cim_model.CimModel.init(gpa, xml);
    defer model.deinit(gpa);
    if (verbose) printTiming("Build model", stage_timer.read());

    stage_timer.reset();
    var topo = try topology.TopologyResolver.init(gpa, &model);
    defer topo.deinit();
    if (verbose) printTiming("Build topology", stage_timer.read());

    stage_timer.reset();
    var conv = converter.Converter.init(gpa, &model, &topo, verbose);
    var network = try conv.convert();
    defer network.deinit(gpa);
    if (verbose) printTiming("Convert", stage_timer.read());

    // Create output file or use stdout
    const cwd = std.fs.cwd();

    const output_file = if (output_path) |path|
        try cwd.createFile(path, .{})
    else
        std.fs.File.stdout();
    defer if (output_path != null) output_file.close();

    // Create File.Writer with buffer, then use its .interface
    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.fs.File.Writer.init(output_file, &write_buffer);

    stage_timer.reset();
    try std.json.Stringify.value(network, .{}, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
    if (verbose) printTiming("JSON serialize", stage_timer.read());

    if (verbose) printTiming("Total", total_timer.read());
}

fn printTiming(label: []const u8, nanoseconds: u64) void {
    const milliseconds = @as(f64, @floatFromInt(nanoseconds)) / 1_000_000.0;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[verbose] {s}: {d:.1} ms\n", .{ label, milliseconds }) catch return;
    _ = std.fs.File.stderr().write(msg) catch {};
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
