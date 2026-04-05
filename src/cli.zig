//! Parse and validate command-line arguments for the cimd binary.
//!
//! Everything that can be validated without reading the data file must be validated here.
//! Caller must additionally assert validity of arguments as a defense in depth.

const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const print = @import("print.zig");

const help_index =
    \\Usage: cimd index <file> [<file>...]
    \\
    \\Index and parse one or more CGMES files (XML or ZIP). Provide multiple files
    \\separated by spaces. Files are parsed individually, cached separately, then merged.
    \\
    \\Examples:
    \\  cimd index data/eq.xml
    \\  cimd index data/eq.xml data/ssh.xml data/tp.xml
    \\  cimd index data/model.zip
    \\
;

const help_convert =
    \\Usage: cimd convert <input> [--output <file>] [--verbose]
    \\
    \\Convert a CGMES file to IIDM JSON format.
    \\
    \\Arguments:
    \\  <input>           EQ profile file to convert (XML or ZIP)
    \\
    \\Options:
    \\  --eqbd <file>     EQBD profile file if needed (XML or ZIP)
    \\  --output <file>   Write output to file (default: stdout)
    \\  --verbose         Print pipeline timing breakdown to stderr
    \\
    \\Examples:
    \\  cimd convert data/eq.zip
    \\  cimd convert data/eq.zip --eqbd eqbd.zip
    \\  cimd convert data/eq.xml --output network.json
    \\  cimd convert data/eq.zip --verbose
    \\
;

const help_browse =
    \\Usage: cimd browse <input> --id <rdf id> [--eqbd <file>]
    \\
    \\Look up an equipment object by its id and browse its references.
    \\
    \\Arguments:
    \\  <input>           EQ profile file to convert (XML or ZIP)
    \\
    \\Options:
    \\  --eqbd <file>     EQBD profile file if needed (XML or ZIP)
    \\  --id <rdf id>     RDF ID of object to entry browsing
    \\
    \\Examples:
    \\  cimd browse data/eq.zip --id _be60a3cf-fed6-d11c-c15f-42ac6cc4e221
    \\
;

const help_version =
    \\Usage: cimd version [--verbose]
    \\
    \\Print version and build information.
    \\
    \\Options:
    \\  --verbose    Show detailed build information
    \\
    \\Examples:
    \\  cimd version
    \\  cimd version --verbose
    \\
;

const help_main =
    \\Usage: cimd <command> [options]
    \\
    \\A high-performance CGMES file parser and analysis tool.
    \\
    \\Commands:
    \\  index      Index and parse CGMES files
    \\  convert    Convert EQ profile to JIIDM format
    \\  version    Print version information
    \\
    \\Use 'cimd <command> --help' for more information about a command.
    \\
;

pub const Command = union(enum) {
    pub const Index = struct {
        paths: []const []const u8,
    };

    pub const Convert = struct {
        eq_path: []const u8,
        eqbd_path: ?[]const u8,
        output_path: ?[]const u8,
        verbose: bool,
    };

    pub const Browse = struct {
        eq_path: []const u8,
        eqbd_path: ?[]const u8,
        entry_id: []const u8,
    };

    pub const Version = struct {
        verbose: bool,
    };

    index: Index,
    convert: Convert,
    browse: Browse,
    version: Version,
};

/// Parse the command line arguments passed to the `cimd` binary.
/// Exits the program with a non-zero exit code if an error is found.
pub fn parse_args(args_iterator: *std.process.ArgIterator) Command {
    assert(args_iterator.skip()); // Skip executable name

    const command_name = args_iterator.next() orelse print.stderr(
        "subcommand required, expected 'index', 'convert', 'browse' or 'version'\nTry '--help' for more information.",
        .{},
    );

    if (std.mem.eql(u8, command_name, "-h") or std.mem.eql(u8, command_name, "--help")) {
        _ = std.fs.File.stdout().write(help_main) catch std.process.exit(1);
        std.process.exit(0);
    }

    if (std.mem.eql(u8, command_name, "index")) {
        return parse_index_command(args_iterator);
    } else if (std.mem.eql(u8, command_name, "convert")) {
        return parse_convert_command(args_iterator);
    } else if (std.mem.eql(u8, command_name, "browse")) {
        return parse_browse_command(args_iterator);
    } else if (std.mem.eql(u8, command_name, "version")) {
        return parse_version_command(args_iterator);
    } else {
        print.stderr("unknown subcommand: '{s}'", .{command_name});
    }
}

fn parse_index_command(args_iterator: *std.process.ArgIterator) Command {
    var paths_list: std.ArrayList([]const u8) = .empty;

    while (args_iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = std.fs.File.stdout().write(help_index) catch std.process.exit(1);
            std.process.exit(0);
        }

        if (arg.len > 0 and arg[0] == '-') {
            print.stderr("index: unknown option '{s}'", .{arg});
        }

        // Validate the file path
        validate_path(arg, "index <path>");
        validate_cgmes_file_extension(arg, "index <path>");

        paths_list.append(std.heap.page_allocator, arg) catch print.stderr("failed to allocate paths array", .{});
    }

    if (paths_list.items.len == 0) {
        print.stderr("index: at least one file path is required", .{});
    }

    return .{ .index = .{ .paths = paths_list.items } };
}

fn parse_convert_command(args_iterator: *std.process.ArgIterator) Command {
    var eq_path: ?[]const u8 = null;
    var eqbd_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var verbose = false;

    while (args_iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = std.fs.File.stdout().write(help_convert) catch std.process.exit(1);
            std.process.exit(0);
        }

        if (std.mem.eql(u8, arg, "--output")) {
            output_path = args_iterator.next() orelse
                print.stderr("convert: --output requires a file path", .{});
        } else if (std.mem.eql(u8, arg, "--eqbd")) {
            eqbd_path = args_iterator.next() orelse
                print.stderr("convert: --eqbd requires a file path", .{});
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            print.stderr("convert: unknown option '{s}'", .{arg});
        } else {
            if (eq_path != null) {
                print.stderr("convert: unexpected argument '{s}'", .{arg});
            }
            validate_path(arg, "convert <input>");
            validate_cgmes_file_extension(arg, "convert <input>");
            eq_path = arg;
        }
    }

    if (eq_path == null) {
        print.stderr("convert: missing required argument <input>", .{});
    }

    return .{ .convert = .{ .eq_path = eq_path.?, .eqbd_path = eqbd_path, .output_path = output_path, .verbose = verbose } };
}

fn parse_browse_command(args_iterator: *std.process.ArgIterator) Command {
    var eq_path: ?[]const u8 = null;
    var eqbd_path: ?[]const u8 = null;
    var entry_id: ?[]const u8 = null;

    while (args_iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = std.fs.File.stdout().write(help_browse) catch std.process.exit(1);
            std.process.exit(0);
        }

        if (std.mem.eql(u8, arg, "--id")) {
            entry_id = args_iterator.next() orelse
                print.stderr("browse: --id requires an object id", .{});
        } else if (std.mem.eql(u8, arg, "--eqbd")) {
            eqbd_path = args_iterator.next() orelse
                print.stderr("browse: --eqbd requires a file path", .{});
        } else if (arg.len > 0 and arg[0] == '-') {
            print.stderr("browse: unknown option '{s}'", .{arg});
        } else {
            if (eq_path != null) {
                print.stderr("browse: unexpected argument '{s}'", .{arg});
            }
            validate_path(arg, "browse <input>");
            validate_cgmes_file_extension(arg, "browse <input>");
            eq_path = arg;
        }
    }

    if (eq_path == null) {
        print.stderr("browse: missing required argument <input>", .{});
    }

    if (entry_id == null) {
        print.stderr("browse: missing required argument --id", .{});
    }

    return .{ .browse = .{ .eq_path = eq_path.?, .eqbd_path = eqbd_path, .entry_id = entry_id.? } };
}

fn parse_version_command(args_iterator: *std.process.ArgIterator) Command {
    var verbose = false;

    while (args_iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = std.fs.File.stdout().write(help_version) catch std.process.exit(1);
            std.process.exit(0);
        }

        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else {
            print.stderr("version: unknown option '{s}'", .{arg});
        }
    }

    return .{ .version = .{ .verbose = verbose } };
}

fn validate_path(path: []const u8, comptime context: []const u8) void {
    if (path.len == 0) {
        print.stderr(context ++ ": path cannot be empty", .{});
    }
    if (path.len > std.fs.max_path_bytes) {
        print.stderr(context ++ ": path is too long ({d} bytes), maximum is {d} bytes", .{
            path.len,
            std.fs.max_path_bytes,
        });
    }
}

fn validate_cgmes_file_extension(path: []const u8, comptime context: []const u8) void {
    // Check if file ends with .xml or .zip (case insensitive)
    if (path.len < 4) {
        print.stderr(context ++ ": file must be .xml or .zip (got: '{s}')", .{path});
    }

    const ext = std.fs.path.extension(path);
    const is_xml = std.ascii.eqlIgnoreCase(ext, ".xml");
    const is_zip = std.ascii.eqlIgnoreCase(ext, ".zip");

    if (!is_xml and !is_zip) {
        print.stderr(context ++
            \\: file must be .xml or .zip (got: '{s}')
            \\
            \\CGMES files are typically:
            \\  - Raw XML files (*.xml)
            \\  - ZIP archives containing XML files (*.zip)
            \\
            \\If you have a different file format, convert it first.
        , .{path});
    }
}

fn validate_zip_file_extension(path: []const u8, comptime context: []const u8) void {
    // Check if file ends with .zip (case insensitive)
    if (path.len < 4) {
        print.stderr(context ++ ": file must be .zip (got: '{s}')", .{path});
    }

    const ext = std.fs.path.extension(path);
    const is_zip = std.ascii.eqlIgnoreCase(ext, ".zip");

    if (!is_zip) {
        print.stderr(context ++
            \\: file must be .zip (got: '{s}')
            \\
            \\If you have a different file format, convert it first.
        , .{path});
    }
}
