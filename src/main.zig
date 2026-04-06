const std = @import("std");
const cli = @import("cli.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const print = @import("print.zig");
const assert = std.debug.assert;
const zip = @import("zip.zig");
const cim_model = @import("cim_model.zig");
const converter = @import("converter.zig");
const extract_rdf_resource = @import("tag_index.zig").extract_rdf_resource;
const extract_rdf_id = @import("tag_index.zig").extract_rdf_id;
const strip_hash = @import("utils.zig").strip_hash;

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
        var extracted_files = try zip.extract_to_memory(gpa, &file_reader, .{});
        // Take ownership of the first entry's data, then free everything else.
        const data = extracted_files.items[0].data;
        gpa.free(extracted_files.items[0].filename);
        for (extracted_files.items[1..]) |f| f.deinit(gpa);
        extracted_files.deinit(gpa);
        return data;
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
        xml = try std.mem.concat(gpa, u8, &.{ xml, eqbd_xml });
    }

    var model = try cim_model.CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    var trace_ids: std.ArrayList([]const u8) = .empty;
    defer trace_ids.deinit(gpa);
    var trace_types: std.ArrayList([]const u8) = .empty;
    defer trace_types.deinit(gpa);

    // Both reused across iterations — backing memory is retained, no per-iteration allocation.
    var screen_buf: std.ArrayList(u8) = .empty;
    defer screen_buf.deinit(gpa);
    var ref_list: std.ArrayList([]const u8) = .empty;
    defer ref_list.deinit(gpa);

    var id = entry_id;

    while (true) blk: {
        assert(trace_ids.items.len == trace_types.items.len);

        const object = model.getObjectById(id) orelse {
            print.stderr("The rdf ID {s} was not found in the model.", .{id});
            return error.RdfIdNotFound;
        };
        const opening_tag = object.boundaries[object.object_tag_idx];
        const closing_tag = object.boundaries[object.closing_tag_idx];
        const buffer = xml[opening_tag.start .. closing_tag.end + 1];

        screen_buf.clearRetainingCapacity();
        ref_list.clearRetainingCapacity();
        const w = screen_buf.writer(gpa);

        var it = std.mem.splitScalar(u8, buffer, '\n');
        var counter: u32 = 1;
        while (it.next()) |line| {
            if (extract_rdf_id(line, 0) catch null != null) {
                try w.writeAll("\n|     |  ");
                try append_colored_id_line(gpa, line, &screen_buf);
                continue;
            }
            const rdf_resource = try extract_rdf_resource(line, 0);
            if (rdf_resource) |val| {
                try w.print("\n|  {d}  |  ", .{counter});
                try append_colored_ref_line(gpa, line, &screen_buf);
                try ref_list.append(gpa, strip_hash(val));
                counter += 1;
            } else {
                try w.print("\n|     |  {s}", .{line});
            }
        }

        try w.writeAll("\n\n");
        for (trace_types.items) |past_type| try w.print("{s} -> ", .{past_type});
        try w.print("{s}\n\n", .{object.type_name});

        const has_refs = counter > 1;
        const has_back = trace_ids.items.len > 0;

        for (1..counter) |n| try w.print(" [{d}]", .{n});
        if (has_back) try w.writeAll("  [b]ack");
        try w.writeAll("  [q]uit\n\n");

        _ = try std.fs.File.stdout().write(screen_buf.items);

        var io_buf: [64]u8 = undefined;
        var stdin = std.fs.File.stdin().reader(&io_buf);
        const input = try stdin.interface.takeDelimiterExclusive('\n');

        if (input.len == 0) continue;
        switch (input[0]) {
            'b' => {
                if (!has_back) {
                    _ = try std.fs.File.stdout().write("Already at root — [q]uit to exit.\n\n");
                    continue;
                }
                id = trace_ids.pop() orelse unreachable;
                _ = trace_types.pop();
                break :blk;
            },
            'q' => break,
            else => {
                if (!has_refs) {
                    if (has_back) {
                        _ = try std.fs.File.stdout().write("No references — [b]ack or [q]uit\n\n");
                    } else {
                        _ = try std.fs.File.stdout().write("No references — [q]uit to exit\n\n");
                    }
                    continue;
                }
                const n = std.fmt.parseInt(u32, input, 10) catch {
                    if (has_back) {
                        try print.stdout("Invalid input — pick 1-{d}, [b]ack or [q]uit\n", .{counter - 1});
                    } else {
                        try print.stdout("Invalid input — pick 1-{d} or [q]uit\n", .{counter - 1});
                    }
                    continue;
                };
                if (n == 0 or n > ref_list.items.len) {
                    if (has_back) {
                        try print.stdout("Pick 1-{d}, [b]ack or [q]uit\n", .{counter - 1});
                    } else {
                        try print.stdout("Pick 1-{d} or [q]uit\n", .{counter - 1});
                    }
                    continue;
                }
                try trace_ids.append(gpa, id);
                try trace_types.append(gpa, object.type_name);
                id = ref_list.items[n - 1];
            },
        }
    }
}

/// Append `line` to `buf` with the CIM type suffix (after `:`) colored yellow.
/// Used for the object's own opening tag, which carries rdf:ID.
/// Falls back to the plain line if the expected pattern is absent.
fn append_colored_id_line(gpa: std.mem.Allocator, line: []const u8, buf: *std.ArrayList(u8)) !void {
    assert(line.len > 0);
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
        try buf.appendSlice(gpa, line);
        return;
    };
    const rdf_marker = std.mem.indexOf(u8, line, " rdf:ID=\"") orelse {
        try buf.appendSlice(gpa, line);
        return;
    };
    try buf.appendSlice(gpa, line[0 .. colon + 1]);
    try buf.appendSlice(gpa, cli.ansi_yellow);
    try buf.appendSlice(gpa, line[colon + 1 .. rdf_marker]);
    try buf.appendSlice(gpa, cli.ansi_default);
    try buf.appendSlice(gpa, line[rdf_marker..]);
}

/// Append `line` to `buf` with the attribute name (after `.`) colored green.
/// Used for reference lines that carry rdf:resource.
/// Falls back to the plain line if the expected pattern is absent.
fn append_colored_ref_line(gpa: std.mem.Allocator, line: []const u8, buf: *std.ArrayList(u8)) !void {
    assert(line.len > 0);
    const dot = std.mem.indexOfScalar(u8, line, '.') orelse {
        try buf.appendSlice(gpa, line);
        return;
    };
    const rdf_marker = std.mem.indexOf(u8, line, " rdf:") orelse {
        try buf.appendSlice(gpa, line);
        return;
    };
    try buf.appendSlice(gpa, line[0 .. dot + 1]);
    try buf.appendSlice(gpa, cli.ansi_green);
    try buf.appendSlice(gpa, line[dot + 1 .. rdf_marker]);
    try buf.appendSlice(gpa, cli.ansi_default);
    try buf.appendSlice(gpa, line[rdf_marker..]);
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
