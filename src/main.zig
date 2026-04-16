const std = @import("std");
const cli = @import("cli.zig");
const print = @import("print.zig");
const builtin = @import("builtin");
const CimSsh = @import("cim_ssh.zig").CimSsh;
const zip = @import("zip.zig");
const cim_model = @import("cim_model.zig");
const browse = @import("browse.zig");
const diff = @import("diff.zig");
const converter = @import("converter.zig");

const assert = std.debug.assert;

const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    const command = try cli.parse_args(io, &args);

    switch (command) {
        .eq => |eq| switch (eq) {
            .convert => |c| try command_eq_convert(io, gpa, c.eq_path, c.eqbd_path, c.ssh_path, c.output_path),
            .browse => |c| try command_eq_browse(io, gpa, c.eq_path, c.eqbd_path, c.mrid),
            .get => |c| try command_eq_get(io, gpa, c.eq_path, c.eqbd_path, c.mrid, c.type_filter, c.fields, c.count, c.json),
            .types => |c| try command_eq_types(io, gpa, c.eq_path, c.eqbd_path, c.json),
            .diff => |c| try command_eq_diff(io, gpa, c),
        },
        .version => |v| try command_version(io, v.verbose, v.json),
    }
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

fn command_eq_convert(io: std.Io, gpa: std.mem.Allocator, eq_path: []const u8, eqbd_path: ?[]const u8, ssh_path: ?[]const u8, output_path: ?[]const u8) !void {
    var model = try load_model(io, gpa, eq_path, eqbd_path);
    defer model.deinit(gpa);

    var ssh_opt: ?CimSsh = if (ssh_path) |path| try load_ssh(io, gpa, path) else null;
    defer if (ssh_opt) |*ssh| ssh.deinit(gpa);

    var network = try converter.convert(gpa, &model, ssh_opt);
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
    try print.stderr_info(io, "Substations: {d}\n", .{network.substations.items.len});
    try print.stderr_info(io, "VoltageLevels: {d}\n", .{total_voltage_levels});
    try print.stderr_info(io, "BusbarSections: {d}\n", .{total_busbar_sections});
    try print.stderr_info(io, "Switches: {d}\n", .{total_switches});
    try print.stderr_info(io, "Loads: {d}\n", .{total_loads});
    try print.stderr_info(io, "Shunts: {d}\n", .{total_shunts});
    try print.stderr_info(io, "StaticVarCompensators: {d}\n", .{total_svcs});
    try print.stderr_info(io, "Generators: {d}\n", .{total_generators});
    try print.stderr_info(io, "2-winding transformers: {d}\n", .{total_2w});
    try print.stderr_info(io, "3-winding transformers: {d}\n", .{total_3w});
    try print.stderr_info(io, "Lines: {d}\n", .{network.lines.items.len});

    const cwd = std.Io.Dir.cwd();
    const output_file = if (output_path) |path|
        try cwd.createFile(io, path, .{})
    else
        std.Io.File.stdout();
    defer if (output_path != null) output_file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(output_file, io, &write_buffer);
    try std.json.Stringify.value(network, .{}, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
}

fn command_eq_browse(io: std.Io, gpa: std.mem.Allocator, eq_path: []const u8, eqbd_path: ?[]const u8, mrid: []const u8) !void {
    var model = try load_model(io, gpa, eq_path, eqbd_path);
    defer model.deinit(gpa);

    try browse.browse(io, gpa, &model, model.xml, mrid);
}

fn command_eq_get(io: std.Io, gpa: std.mem.Allocator, eq_path: []const u8, eqbd_path: ?[]const u8, mrid: ?[]const u8, type_filter: ?[]const u8, fields_str: ?[]const u8, count: bool, json: bool) !void {
    assert(mrid != null or type_filter != null);
    if (mrid != null and count) print.stderr(io, "eq get: --count requires --type without <mrid>", .{});
    if (mrid != null and fields_str != null) print.stderr(io, "eq get: --fields requires --type without <mrid>", .{});

    var model = try load_model(io, gpa, eq_path, eqbd_path);
    defer model.deinit(gpa);

    // Single-object mode
    if (mrid) |mrid_val| {
        const object = model.getObjectById(mrid_val) orelse
            print.not_found(io, "No object found with id '{s}'", .{mrid_val});

        if (type_filter) |type_name| {
            if (!std.mem.eql(u8, type_name, object.type_name))
                print.not_found(io, "Object '{s}' is of type '{s}', not '{s}'", .{ mrid_val, object.type_name, type_name });
        }

        if (json) {
            try print.display_object_json(io, gpa, object);
        } else {
            try print.display_object(io, gpa, object);
        }
        return;
    }

    // List mode
    const type_name = type_filter.?;
    const objects = model.get_objects_by_type(type_name);
    if (objects.len == 0)
        print.not_found(io, "No objects of type '{s}' found. Run 'cimd eq types' to see available types.", .{type_name});

    if (count) {
        if (json) {
            try print.stdout(io, "{{\"type\":\"{s}\",\"count\":{d}}}\n", .{ type_name, objects.len });
        } else {
            try print.stdout(io, "{d}\n", .{objects.len});
        }
        return;
    }

    // Parse --fields into a stack-allocated slice of names.
    var fields_buf: [32][]const u8 = undefined;
    var n_fields: usize = 0;
    if (fields_str) |fs| {
        var it = std.mem.splitScalar(u8, fs, ',');
        while (it.next()) |f| {
            if (n_fields == fields_buf.len) print.stderr(io, "eq get: --fields: too many fields (max 32)", .{});
            fields_buf[n_fields] = std.mem.trim(u8, f, " ");
            n_fields += 1;
        }
    }
    const fields = fields_buf[0..n_fields];

    if (json) {
        try print.display_object_list_json(io, &model, objects, fields);
    } else {
        for (objects) |obj| {
            const view = model.view(obj);
            try print.stdout(io, "{s}", .{obj.id});
            if (fields.len == 0) {
                const name = try view.getProperty("IdentifiedObject.name") orelse "N/A";
                try print.stdout(io, " | {s}", .{name});
            } else {
                for (fields) |field| {
                    const val = try view.getProperty(field) orelse "N/A";
                    try print.stdout(io, " | {s}", .{val});
                }
            }
            try print.stdout(io, "\n", .{});
        }
    }
}

fn command_eq_types(io: std.Io, gpa: std.mem.Allocator, eq_path: []const u8, eqbd_path: ?[]const u8, json: bool) !void {
    var model = try load_model(io, gpa, eq_path, eqbd_path);
    defer model.deinit(gpa);

    if (json) {
        try print.display_object_inventory_json(io, gpa, model);
    } else {
        try print.display_object_inventory(io, gpa, model);
    }
}

fn command_eq_diff(io: std.Io, gpa: std.mem.Allocator, c: cli.Command.Eq.Diff) !void {
    // Load both models independently. Each holds its own XML backing.
    var model1 = try load_model(io, gpa, c.eq_path1, c.eqbd_path);
    defer model1.deinit(gpa);

    var model2 = try load_model(io, gpa, c.eq_path2, c.eqbd_path);
    defer model2.deinit(gpa);

    const options = diff.DiffOptions{
        .type_filter = c.type_filter,
        .json = c.json,
        .summary = c.summary,
    };

    // Stream diff output to a buffered stdout writer.
    var out_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &out_buffer);

    const had_diffs = if (c.mrid) |mrid| blk: {
        const status = try diff.diff_single(
            gpa,
            &model1,
            &model2,
            mrid,
            c.eq_path1,
            c.eq_path2,
            options,
            &writer.interface,
        );
        break :blk switch (status) {
            .not_found => print.not_found(io, "No object found with mRID '{s}' in either file", .{mrid}),
            .type_mismatch => |actual| print.stderr(
                io,
                "eq diff: object '{s}' is of type '{s}', not '{s}'",
                .{ mrid, actual, c.type_filter.? },
            ),
            .diff => |d| d,
        };
    } else try diff.diff_models(
        gpa,
        &model1,
        &model2,
        c.eq_path1,
        c.eq_path2,
        options,
        &writer.interface,
    );

    try writer.interface.flush();

    // Exit 1 when differences exist so callers can branch on the exit code.
    if (had_diffs) std.process.exit(1);
}

fn load_model(io: std.Io, gpa: std.mem.Allocator, eq_path: []const u8, eqbd_path: ?[]const u8) !cim_model.CimModel {
    var xml = try read_path(io, gpa, eq_path);
    if (eqbd_path) |path| {
        const eqbd_xml = try read_path(io, gpa, path);
        const combined = try std.mem.concat(gpa, u8, &.{ xml, eqbd_xml });
        // Free both source buffers immediately: only the concatenated buffer is needed going forward.
        gpa.free(eqbd_xml);
        gpa.free(xml);
        xml = combined;
    }
    return cim_model.CimModel.init(gpa, xml);
}

fn load_ssh(io: std.Io, gpa: std.mem.Allocator, ssh_path: []const u8) !CimSsh {
    return CimSsh.init(gpa, try read_path(io, gpa, ssh_path));
}

fn read_path(io: std.Io, gpa: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, file_path, .{});
    defer file.close(io);

    if (try zip.is_zip_file(io, file)) {
        var zip_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(io, &zip_buffer);
        var extracted_files = try zip.extract_to_memory(gpa, &file_reader, .{});
        const data = extracted_files.items[0].data;
        gpa.free(extracted_files.items[0].filename);
        for (extracted_files.items[1..]) |f| f.deinit(gpa);
        extracted_files.deinit(gpa);
        return data;
    } else {
        return try read_file_to_memory(io, gpa, file);
    }
}

fn read_file_to_memory(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File) ![]u8 {
    const file_size = try file.length(io);
    if (file_size > std.math.maxInt(u32)) return error.FileTooLarge;

    var file_reader = file.reader(io, &.{});
    return try file_reader.interface.allocRemaining(gpa, .limited(file_size));
}
