const std = @import("std");
const cli = @import("cli.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const print = @import("print.zig");
const assert = std.debug.assert;
const zip = @import("zip.zig");

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();

    const gpa = arena_instance.allocator();

    var arg_iterator = try std.process.argsWithAllocator(gpa);
    defer arg_iterator.deinit();

    const command = cli.parse_args(&arg_iterator);

    switch (command) {
        .version => |_| try command_version(command.version.verbose),
        .index => |_| try command_index(gpa, command.index.paths),
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
    const dest = try cwd.openDir(".cimd", .{});
    var buffer: [4096]u8 = undefined;
    var extracted_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (extracted_paths.items) |filename| {
            gpa.free(filename);
        }
        extracted_paths.deinit(gpa);
    }

    for (paths) |path| {
        const file = try cwd.openFile(path, .{});
        if (try zip.isZipFile(file)) {
            var file_reader = file.reader(&buffer);
            var extracted_files = try zip.extract(gpa, dest, &file_reader, .{});
            defer {
                for (extracted_files.items) |filename| {
                    gpa.free(filename);
                }
                extracted_files.deinit(gpa);
            }
            for (extracted_files.items) |filename| {
                const filename_copy = try gpa.dupe(u8, filename); 
                try extracted_paths.append(gpa, filename_copy);
            }
        } else {
            try print.stdout("Normal file! Let's do something with it!\n", .{});
            try extracted_paths.append(gpa, path);
        }
    }

    for (extracted_paths.items) |filename| {
        try print.stdout("{s}\n", .{filename});
    }
}

fn command_not_implemented(comptime command_name: []const u8) !void {
    try print.stdout("Command '{s}' - to be implemented\n", .{command_name});
}
