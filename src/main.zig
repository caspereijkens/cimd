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

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();

    const gpa = arena_instance.allocator();

    var arg_iterator = try std.process.argsWithAllocator(gpa);
    defer arg_iterator.deinit();

    const command = cli.parse_args(&arg_iterator);

    switch (command) {
        .index => |_| try command_index(gpa, command.index.paths),
        .find => |_| try command_find(gpa, command.find.id, command.find.paths),
        .list => |_| try command_list(gpa, command.list.type_name, command.list.paths),
        .topology => |_| try command_topology(gpa, command.topology.eq_path, command.topology.tp_path),
        .extract => |_| try command_extract(gpa, command.extract.paths),
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

fn command_find(gpa: std.mem.Allocator, id: []const u8, paths: []const []const u8) !void {
    const cwd = std.fs.cwd();
    var buffer: [4096]u8 = undefined;

    for (paths) |path| {
        const file = try cwd.openFile(path, .{});
        defer file.close();

        if (try zip.isZipFile(file)) {
            // ZIP: search through extracted files
            var file_reader = file.reader(&buffer);
            var extracted_files = try zip.extractToMemory(gpa, &file_reader, .{});
            defer {
                for (extracted_files.items) |extracted_file| {
                    extracted_file.deinit(gpa);
                }
                extracted_files.deinit(gpa);
            }

            for (extracted_files.items) |extracted_file| {
                var model = try cim_model.CimModel.init(gpa, extracted_file.data);
                defer model.deinit(gpa);

                if (model.getObjectById(id)) |obj| {
                    try print.stdout("Found in: {s} (in {s})\n\n", .{ extracted_file.filename, path });
                    try print.displayObject(gpa, obj);
                    return; // Found it, we're done!
                }
            }
        } else {
            // Regular XML file
            const xml = try readFileToMemory(gpa, file);
            defer gpa.free(xml);

            var model = try cim_model.CimModel.init(gpa, xml);
            defer model.deinit(gpa);

            if (model.getObjectById(id)) |obj| {
                try print.stdout("Found in: {s}\n\n", .{path});
                try print.displayObject(gpa, obj);
                return; // Found it, we're done!
            }
        }
    }

    // Not found in any file
    try print.stdout("Object '{s}' not found in any of the provided files\n", .{id});
}

fn command_list(gpa: std.mem.Allocator, type_name: []const u8, paths: []const []const u8) !void {
    const cwd = std.fs.cwd();
    var buffer: [4096]u8 = undefined;

    var total_found: usize = 0;

    for (paths) |path| {
        const file = try cwd.openFile(path, .{});
        defer file.close();

        if (try zip.isZipFile(file)) {
            // ZIP: search through extracted files
            var file_reader = file.reader(&buffer);
            var extracted_files = try zip.extractToMemory(gpa, &file_reader, .{});
            defer {
                for (extracted_files.items) |extracted_file| {
                    extracted_file.deinit(gpa);
                }
                extracted_files.deinit(gpa);
            }

            for (extracted_files.items) |extracted_file| {
                var model = try cim_model.CimModel.init(gpa, extracted_file.data);
                defer model.deinit(gpa);

                const objects = try model.getObjectsByType(gpa, type_name);
                defer gpa.free(objects);

                if (objects.len > 0) {
                    try print.stdout("Found {d} {s} objects in {s} (in {s})\n\n", .{ objects.len, type_name, extracted_file.filename, path });
                    try print.displayObjectList(gpa, objects);
                    total_found += objects.len;
                }
            }
        } else {
            // Regular XML file
            const xml = try readFileToMemory(gpa, file);
            defer gpa.free(xml);

            var model = try cim_model.CimModel.init(gpa, xml);
            defer model.deinit(gpa);

            const objects = try model.getObjectsByType(gpa, type_name);
            defer gpa.free(objects);

            if (objects.len > 0) {
                try print.stdout("Found {d} {s} objects in {s}\n\n", .{ objects.len, type_name, path });
                try print.displayObjectList(gpa, objects);
                total_found += objects.len;
            }
        }
    }

    if (total_found == 0) {
        try print.stdout("No {s} objects found in any of the provided files\n", .{type_name});
    }
}

fn command_not_implemented(comptime command_name: []const u8) !void {
    try print.stdout("Command '{s}' - to be implemented\n", .{command_name});
}

fn command_topology(gpa: std.mem.Allocator, eq_path: []const u8, tp_path: ?[]const u8) !void {
    const cwd = std.fs.cwd();

    // Load EQ model (required)
    const eq_file = try cwd.openFile(eq_path, .{});
    defer eq_file.close();

    const eq_xml = try readFileToMemory(gpa, eq_file);
    defer gpa.free(eq_xml);

    var eq_model = try cim_model.CimModel.init(gpa, eq_xml);
    defer eq_model.deinit(gpa);

    // Load TP model (optional)
    var tp_model_opt: ?cim_model.CimModel = null;
    defer if (tp_model_opt) |*tp| tp.deinit(gpa);

    if (tp_path) |path| {
        const tp_file = try cwd.openFile(path, .{});
        defer tp_file.close();

        const tp_xml = try readFileToMemory(gpa, tp_file);
        defer gpa.free(tp_xml);

        tp_model_opt = try cim_model.CimModel.init(gpa, tp_xml);
    }

    // Create topology resolver
    var resolver = try topology.TopologyResolver.init(
        gpa,
        &eq_model,
        if (tp_model_opt) |*tp| tp else null,
    );
    defer resolver.deinit();

    // Display statistics
    const stats = resolver.getStats();

    try print.stdout("Topology Analysis:\n", .{});
    try print.stdout("  Mode:                 {s}\n", .{@tagName(stats.topology_mode)});
    try print.stdout("  Total Terminals:      {d}\n", .{stats.terminal_count});
    try print.stdout("  Equipment Count:      {d}\n", .{stats.equipment_count});
    try print.stdout("  Connected Terminals:  {d}\n", .{stats.connected_terminals});

    if (stats.topology_mode == .no_topology) {
        try print.stdout("\nNote: No topology information found. Terminal→equipment mappings available, but no bus connections.\n", .{});
        try print.stdout("      Include --tp <file> to load topology profile.\n", .{});
    }
}

fn command_extract(gpa: std.mem.Allocator, paths: []const []const u8) !void {
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
        defer file.close();
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
        }
    }
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
