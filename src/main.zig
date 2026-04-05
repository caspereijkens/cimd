const std = @import("std");
const cli = @import("cli.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const print = @import("print.zig");
const assert = std.debug.assert;
const zip = @import("zip.zig");
const cim_model = @import("cim_model.zig");
const converter = @import("converter.zig");
const extract_rdf_id_resource = @import("tag_index.zig").extract_rdf_resource;
const strip_hash = @import("utils.zig").strip_hash;
const ansi_green = "\x1b[92m";
const ansi_default = "\x1b[0m";

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();

    const gpa = arena_instance.allocator();

    var arg_iterator = try std.process.argsWithAllocator(gpa);
    defer arg_iterator.deinit();

    const command = cli.parse_args(&arg_iterator);

    switch (command) {
        .index => |_| try command_index(gpa, command.index.paths),
        .convert => |c| try command_convert(gpa, c.eq_path, c.eqbd_path, c.output_path, c.verbose),
        .version => |_| try command_version(command.version.verbose),
        .browse => |c| try command_browse(gpa, c.eq_path, c.eqbd_path, c.entry_id),
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

        if (try zip.is_zip_file(file)) {
            // ZIP file: extract to memory and process each contained file
            var file_reader = file.reader(&buffer);
            var extracted_files = try zip.extract_to_memory(gpa, &file_reader, .{});
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

                try print.display_object_inventory(gpa, model);
                try print.stdout("\n", .{});
            }
        } else {
            // Regular XML file: read to memory and process
            try print.stdout("File: {s}\n", .{path});

            const xml = try read_file_to_memory(gpa, file);
            defer gpa.free(xml);

            var model = try cim_model.CimModel.init(gpa, xml);
            defer model.deinit(gpa);

            try print.display_object_inventory(gpa, model);
        }
    }
}

fn read_path(gpa: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const cwd = std.fs.cwd();

    const file = try cwd.openFile(file_path, .{});
    defer file.close();

    if (try zip.is_zip_file(file)) {
        var zip_buffer: [4096]u8 = undefined;
        var file_reader = file.reader(&zip_buffer);
        const extracted_files = try zip.extract_to_memory(gpa, &file_reader, .{});
        return extracted_files.items[0].data;
    } else {
        return try read_file_to_memory(gpa, file);
    }
}

fn command_convert(gpa: std.mem.Allocator, eq_path: []const u8, eqbd_path: ?[]const u8, output_path: ?[]const u8, verbose: bool) !void {
    _ = verbose;

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
    std.debug.print("Substations: {d}\n", .{network.substations.items.len});
    std.debug.print("VoltageLevels: {d}\n", .{total_voltage_levels});
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

fn command_browse(gpa: std.mem.Allocator, eq_path: []const u8, eqbd_path: ?[]const u8, entry_id: []const u8) !void {
    var xml = try read_path(gpa, eq_path);

    if (eqbd_path) |path| {
        const eqbd_xml = try read_path(gpa, path);
        const merged = try std.mem.concat(gpa, u8, &[_][]const u8{ xml, eqbd_xml });
        xml = merged;
    }

    var model = try cim_model.CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    var trace_ids: std.ArrayList([]const u8) = .empty;
    defer trace_ids.deinit(gpa);
    var trace_types: std.ArrayList([]const u8) = .empty;
    defer trace_types.deinit(gpa);

    // TODO: make this fuzzy so we don't have to fill in the exact id
    var id = entry_id;

    while (true) blk: {
        const object = model.getObjectById(id) orelse {
            print.stderr("The rdf ID {s} was not found in the model.", .{id});
            return error.RdfIdNotFound;
        };
        const opening_tag = object.boundaries[object.object_tag_idx];
        const closing_tag = object.boundaries[object.closing_tag_idx];
        const buffer = xml[opening_tag.start..closing_tag.end+1];
        
        // TODO: make this quit directly on q, so wait for q/b without pressing return.
        var it = std.mem.splitSequence(u8, buffer, "\n");
        var counter: u32 = 1;
        var ref_list: std.ArrayList([]const u8) = .empty;
        defer ref_list.deinit(gpa);
        while (it.next()) |line| {
            const rdf_id = try extract_rdf_id_resource(line, 0);
            if (rdf_id) |val| {
                const pos = std.mem.indexOfScalar(u8, line, '.');
                const ref_pos = std.mem.indexOf(u8, line, "rdf:") orelse continue;
                if (pos) |dot_pos| {
                    const line_fmt = try std.mem.concat(gpa, u8, &.{ line[0..dot_pos+1], ansi_green, line[dot_pos+1..ref_pos], ansi_default, line[ref_pos..] });
                    try print.stdout("\n|  {d}  |  {s}", .{counter, line_fmt});
                } else {
                    try print.stdout("\n|  {d}  |  {s}", .{counter, line});
                }
                try ref_list.append(gpa, strip_hash(val));
                counter += 1;
            } else {
                try print.stdout("\n|     |  {s}", .{line});
            }
        }
        try print.stdout("\n\n", .{});
        for (1..counter) |choice| {
            try print.stdout(" [{d}] ", .{choice});
        }
        try print.stdout(" [b]ack ", .{});
        try print.stdout(" [q]uit ", .{});
        try print.stdout("\n\n", .{});

        var io_buf: [64]u8 = undefined;
        var stdin = std.fs.File.stdin().reader(&io_buf);

        const input = try stdin.interface.takeDelimiterExclusive('\n');
        const choice = switch (input[0]) {
            'b' => {
                id = strip_hash(trace_ids.pop() orelse break);

                break :blk;
                // TODO: me must append the current choice to a stack so we can also navigate back by popping the stack.
            },
            'q' => break,
            else => try std.fmt.parseInt(u32, input, 10) - 1,
        };

        try trace_ids.append(gpa, id);
        try trace_types.append(gpa, object.type_name);
        id = ref_list.items[choice];
    }
}
/// Read file into memory (used for unzipped usecase)
pub fn read_file_to_memory(
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
