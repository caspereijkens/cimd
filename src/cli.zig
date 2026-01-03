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
    \\To export data, use the 'info' command:
    \\  cimd info data/eq.xml --type=ACLineSegment --export=lines.csv
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
    \\  version    Print version information
    \\
    \\Use 'cimd <command> --help' for more information about a command.
    \\
;

pub const Command = union(enum) {
    pub const Index = struct {
        paths: []const []const u8,
    };

    pub const Version = struct {
        verbose: bool,
    };

    index: Index,
    version: Version,
};

/// Parse the command line arguments passed to the `cimd` binary.
/// Exits the program with a non-zero exit code if an error is found.
pub fn parse_args(args_iterator: *std.process.ArgIterator) Command {
    assert(args_iterator.skip()); // Skip executable name

    const command_name = args_iterator.next() orelse print.stderr(
        "subcommand required, expected 'index' or 'version'\nTry '--help' for more information.",
        .{},
    );

    if (std.mem.eql(u8, command_name, "-h") or std.mem.eql(u8, command_name, "--help")) {
        _ = std.fs.File.stdout().write(help_main) catch std.process.exit(1);
        std.process.exit(0);
    }

    if (std.mem.eql(u8, command_name, "index")) {
        return parse_index_command(args_iterator);
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
        validate_cgmes_file_extension(arg);

        paths_list.append(std.heap.page_allocator, arg) catch print.stderr("failed to allocate paths array", .{});
    }

    if (paths_list.items.len == 0) {
        print.stderr("index: at least one file path is required", .{});
    }

    return .{ .index = .{ .paths = paths_list.items } };
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

fn validate_cgmes_file_extension(path: []const u8) void {
    // Check if file ends with .xml or .zip (case insensitive)
    if (path.len < 4) {
        print.stderr("index: file must be .xml or .zip (got: '{s}')", .{path});
    }

    const ext = std.fs.path.extension(path);
    const is_xml = std.ascii.eqlIgnoreCase(ext, ".xml");
    const is_zip = std.ascii.eqlIgnoreCase(ext, ".zip");

    if (!is_xml and !is_zip) {
        print.stderr(
            \\index: file must be .xml or .zip (got: '{s}')
            \\
            \\CGMES files are typically:
            \\  - Raw XML files (*.xml)
            \\  - ZIP archives containing XML files (*.zip)
            \\
            \\If you have a different file format, convert it first.
        , .{path});
    }
}

