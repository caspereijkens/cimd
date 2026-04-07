//! Parse and validate command-line arguments for the cimd binary.
//!
//! Everything that can be validated without reading the data file must be validated here.
//! Caller must additionally assert validity of arguments as a defense in depth.
//!
//! Exit codes:
//!   0  success
//!   1  not found (requested mRID / resource does not exist)
//!   2  usage error (bad flags, missing args, unknown subcommand)

const std = @import("std");
const assert = std.debug.assert;
const print = @import("print.zig");

pub const ansi_green = "\x1b[92m";
pub const ansi_default = "\x1b[0m";
pub const ansi_yellow = "\x1b[33m";

// ── Help strings ─────────────────────────────────────────────────────────────

const help_main =
    \\Usage: cimd <command> [options]
    \\
    \\A high-performance CGMES file parser and analysis tool.
    \\
    \\Commands:
    \\  eq         Operate on an EQ (Equipment) profile
    \\  version    Print version information
    \\
    \\Use 'cimd <command> --help' for more information about a command.
    \\
;

const help_eq =
    \\Usage: cimd eq <subcommand> <file> [options]
    \\
    \\Operate on a CGMES EQ (Equipment) profile.
    \\
    \\Subcommands:
    \\  convert    Convert EQ profile to JIIDM JSON
    \\  browse     Interactively browse equipment objects
    \\  get        Fetch a single object by mRID (JSON output)
    \\  types      List all CIM types present in the file
    \\
    \\Use 'cimd eq <subcommand> --help' for more information.
    \\
;

const help_eq_convert =
    \\Usage: cimd eq convert <file> [options]
    \\
    \\Convert a CGMES EQ profile to JIIDM JSON format.
    \\Output is written to stdout unless --output is given.
    \\
    \\Arguments:
    \\  <file>            EQ profile (XML or ZIP)
    \\
    \\Options:
    \\  --eqbd <file>     EQBD boundary profile (XML or ZIP)
    \\  --output <file>   Write output to file instead of stdout
    \\
    \\Examples:
    \\  cimd eq convert data/eq.zip
    \\  cimd eq convert data/eq.zip --eqbd eqbd.zip
    \\  cimd eq convert data/eq.zip --output network.json
    \\
;

const help_eq_browse =
    \\Usage: cimd eq browse <file> <mrid> [options]
    \\
    \\Interactively browse equipment objects by following rdf:resource references.
    \\
    \\Arguments:
    \\  <file>    EQ profile (XML or ZIP)
    \\  <mrid>    mRID of the object to start browsing from
    \\
    \\Options:
    \\  --eqbd <file>     EQBD boundary profile (XML or ZIP)
    \\
    \\Examples:
    \\  cimd eq browse data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221
    \\
;

const help_eq_get =
    \\Usage: cimd eq get <file> [<mrid>] [options]
    \\
    \\Fetch a CIM object by mRID, or list all objects of a given type.
    \\At least one of <mrid> or --type must be provided.
    \\Exits 0 on success, 1 if the mRID is not found.
    \\
    \\Arguments:
    \\  <file>    EQ profile (XML or ZIP)
    \\  <mrid>    mRID of the object to fetch (optional if --type is given)
    \\
    \\Options:
    \\  --eqbd <file>          EQBD boundary profile (XML or ZIP)
    \\  --type <type>          Filter by CIM type (e.g. PowerTransformer)
    \\                         Without <mrid>: list all objects of this type
    \\                         With <mrid>: verify the object is of this type
    \\  --fields <f1,f2,...>   Properties to include in list output (list mode only)
    \\                         Default: IdentifiedObject.name
    \\  --count                Print only the count of matching objects (list mode only)
    \\  --json                 Output as JSON
    \\
    \\Examples:
    \\  cimd eq get data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221
    \\  cimd eq get data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221 --json
    \\  cimd eq get data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221 --type PowerTransformer
    \\  cimd eq get data/eq.zip --type PowerTransformer --json
    \\  cimd eq get data/eq.zip --type PowerTransformer --count
    \\  cimd eq get data/eq.zip --type VoltageLevel --fields IdentifiedObject.name,VoltageLevel.nominalVoltage
    \\
;

const help_eq_types =
    \\Usage: cimd eq types <file> [options]
    \\
    \\List all CIM types present in the EQ profile with object counts.
    \\
    \\Arguments:
    \\  <file>            EQ profile (XML or ZIP)
    \\
    \\Options:
    \\  --eqbd <file>     EQBD boundary profile (XML or ZIP)
    \\  --json            Output as JSON array of {type, count} objects
    \\
    \\Examples:
    \\  cimd eq types data/eq.zip
    \\  cimd eq types data/eq.zip --json
    \\
;

const help_version =
    \\Usage: cimd version [options]
    \\
    \\Print version and build information.
    \\
    \\Options:
    \\  --verbose    Show detailed build information
    \\  --json       Output as JSON
    \\
    \\Examples:
    \\  cimd version
    \\  cimd version --json
    \\
;

// ── Command types ─────────────────────────────────────────────────────────────

pub const Command = union(enum) {
    eq: Eq,
    version: Version,

    pub const Eq = union(enum) {
        convert: Convert,
        browse: Browse,
        get: Get,
        types: Types,

        pub const Convert = struct {
            eq_path: []const u8,
            eqbd_path: ?[]const u8,
            output_path: ?[]const u8,
        };

        pub const Browse = struct {
            eq_path: []const u8,
            eqbd_path: ?[]const u8,
            mrid: []const u8,
        };

        pub const Get = struct {
            eq_path: []const u8,
            eqbd_path: ?[]const u8,
            mrid: ?[]const u8,
            type_filter: ?[]const u8,
            fields: ?[]const u8,
            count: bool,
            json: bool,
        };

        pub const Types = struct {
            eq_path: []const u8,
            eqbd_path: ?[]const u8,
            json: bool,
        };
    };

    pub const Version = struct {
        verbose: bool,
        json: bool,
    };
};

// ── Top-level dispatcher ──────────────────────────────────────────────────────

/// Parse the command-line arguments passed to the cimd binary.
/// Exits with code 2 on any usage error.
pub fn parse_args(args: *std.process.ArgIterator) Command {
    assert(args.skip()); // skip executable name

    const command_name = args.next() orelse
        print.stderr("subcommand required\n\n" ++ help_main, .{});

    if (eql(command_name, "-h") or eql(command_name, "--help")) {
        write_stdout(help_main);
        std.process.exit(0);
    }

    if (eql(command_name, "eq")) return parse_eq(args);
    if (eql(command_name, "version")) return parse_version(args);

    print.stderr("unknown command '{s}'\n\n" ++ help_main, .{command_name});
}

// ── eq ────────────────────────────────────────────────────────────────────────

fn parse_eq(args: *std.process.ArgIterator) Command {
    const sub = args.next() orelse
        print.stderr("eq: subcommand required\n\n" ++ help_eq, .{});

    if (eql(sub, "-h") or eql(sub, "--help")) {
        write_stdout(help_eq);
        std.process.exit(0);
    }

    if (eql(sub, "convert")) return parse_eq_convert(args);
    if (eql(sub, "browse")) return parse_eq_browse(args);
    if (eql(sub, "get")) return parse_eq_get(args);
    if (eql(sub, "types")) return parse_eq_types(args);

    print.stderr("eq: unknown subcommand '{s}'\n\n" ++ help_eq, .{sub});
}

fn parse_eq_convert(args: *std.process.ArgIterator) Command {
    var eq_path: ?[]const u8 = null;
    var eqbd_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (eql(arg, "-h") or eql(arg, "--help")) {
            write_stdout(help_eq_convert);
            std.process.exit(0);
        }
        if (eql(arg, "--eqbd")) {
            eqbd_path = args.next() orelse
                print.stderr("eq convert: --eqbd requires a file path", .{});
        } else if (eql(arg, "--output")) {
            output_path = args.next() orelse
                print.stderr("eq convert: --output requires a file path", .{});
        } else if (is_flag(arg)) {
            print.stderr("eq convert: unknown option '{s}'", .{arg});
        } else {
            if (eq_path != null) print.stderr("eq convert: unexpected argument '{s}'", .{arg});
            validate_path(arg, "eq convert");
            validate_cgmes_extension(arg, "eq convert");
            eq_path = arg;
        }
    }

    if (eq_path == null) print.stderr("eq convert: <file> is required", .{});

    return .{ .eq = .{ .convert = .{
        .eq_path = eq_path.?,
        .eqbd_path = eqbd_path,
        .output_path = output_path,
    } } };
}

fn parse_eq_browse(args: *std.process.ArgIterator) Command {
    var eq_path: ?[]const u8 = null;
    var eqbd_path: ?[]const u8 = null;
    var mrid: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (eql(arg, "-h") or eql(arg, "--help")) {
            write_stdout(help_eq_browse);
            std.process.exit(0);
        }
        if (eql(arg, "--eqbd")) {
            eqbd_path = args.next() orelse
                print.stderr("eq browse: --eqbd requires a file path", .{});
        } else if (is_flag(arg)) {
            print.stderr("eq browse: unknown option '{s}'", .{arg});
        } else if (eq_path == null) {
            validate_path(arg, "eq browse");
            validate_cgmes_extension(arg, "eq browse");
            eq_path = arg;
        } else if (mrid == null) {
            mrid = arg;
        } else {
            print.stderr("eq browse: unexpected argument '{s}'", .{arg});
        }
    }

    if (eq_path == null) print.stderr("eq browse: <file> is required", .{});
    if (mrid == null) print.stderr("eq browse: <mrid> is required", .{});

    return .{ .eq = .{ .browse = .{
        .eq_path = eq_path.?,
        .eqbd_path = eqbd_path,
        .mrid = mrid.?,
    } } };
}

fn parse_eq_get(args: *std.process.ArgIterator) Command {
    var eq_path: ?[]const u8 = null;
    var eqbd_path: ?[]const u8 = null;
    var mrid: ?[]const u8 = null;
    var type_filter: ?[]const u8 = null;
    var fields: ?[]const u8 = null;
    var count = false;
    var json = false;

    while (args.next()) |arg| {
        if (eql(arg, "-h") or eql(arg, "--help")) {
            write_stdout(help_eq_get);
            std.process.exit(0);
        }
        if (eql(arg, "--eqbd")) {
            eqbd_path = args.next() orelse
                print.stderr("eq get: --eqbd requires a file path", .{});
        } else if (eql(arg, "--type")) {
            type_filter = args.next() orelse
                print.stderr("eq get: --type requires a CIM type name", .{});
        } else if (eql(arg, "--fields")) {
            fields = args.next() orelse
                print.stderr("eq get: --fields requires a comma-separated list of property names", .{});
        } else if (eql(arg, "--count")) {
            count = true;
        } else if (eql(arg, "--json")) {
            json = true;
        } else if (is_flag(arg)) {
            print.stderr("eq get: unknown option '{s}'", .{arg});
        } else if (eq_path == null) {
            validate_path(arg, "eq get");
            validate_cgmes_extension(arg, "eq get");
            eq_path = arg;
        } else if (mrid == null) {
            mrid = arg;
        } else {
            print.stderr("eq get: unexpected argument '{s}'", .{arg});
        }
    }

    if (eq_path == null) print.stderr("eq get: <file> is required", .{});
    if (mrid == null and type_filter == null) print.stderr("eq get: <mrid> or --type is required", .{});

    return .{ .eq = .{ .get = .{
        .eq_path = eq_path.?,
        .eqbd_path = eqbd_path,
        .mrid = mrid,
        .type_filter = type_filter,
        .fields = fields,
        .count = count,
        .json = json,
    } } };
}

fn parse_eq_types(args: *std.process.ArgIterator) Command {
    var eq_path: ?[]const u8 = null;
    var eqbd_path: ?[]const u8 = null;
    var json = false;

    while (args.next()) |arg| {
        if (eql(arg, "-h") or eql(arg, "--help")) {
            write_stdout(help_eq_types);
            std.process.exit(0);
        }
        if (eql(arg, "--eqbd")) {
            eqbd_path = args.next() orelse
                print.stderr("eq types: --eqbd requires a file path", .{});
        } else if (eql(arg, "--json")) {
            json = true;
        } else if (is_flag(arg)) {
            print.stderr("eq types: unknown option '{s}'", .{arg});
        } else {
            if (eq_path != null) print.stderr("eq types: unexpected argument '{s}'", .{arg});
            validate_path(arg, "eq types");
            validate_cgmes_extension(arg, "eq types");
            eq_path = arg;
        }
    }

    if (eq_path == null) print.stderr("eq types: <file> is required", .{});

    return .{ .eq = .{ .types = .{
        .eq_path = eq_path.?,
        .eqbd_path = eqbd_path,
        .json = json,
    } } };
}

// ── version ───────────────────────────────────────────────────────────────────

fn parse_version(args: *std.process.ArgIterator) Command {
    var verbose = false;
    var json = false;

    while (args.next()) |arg| {
        if (eql(arg, "-h") or eql(arg, "--help")) {
            write_stdout(help_version);
            std.process.exit(0);
        }
        if (eql(arg, "--verbose")) {
            verbose = true;
        } else if (eql(arg, "--json")) {
            json = true;
        } else {
            print.stderr("version: unknown option '{s}'", .{arg});
        }
    }

    return .{ .version = .{ .verbose = verbose, .json = json } };
}

// ── Helpers ───────────────────────────────────────────────────────────────────

inline fn eql(a: []const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

inline fn is_flag(arg: []const u8) bool {
    return arg.len > 0 and arg[0] == '-';
}

fn write_stdout(text: []const u8) void {
    _ = std.fs.File.stdout().write(text) catch std.process.exit(2);
}

fn validate_path(path: []const u8, comptime context: []const u8) void {
    if (path.len == 0) print.stderr(context ++ ": path cannot be empty", .{});
    if (path.len > std.fs.max_path_bytes) {
        print.stderr(context ++ ": path too long ({d} bytes, max {d})", .{
            path.len, std.fs.max_path_bytes,
        });
    }
}

fn validate_cgmes_extension(path: []const u8, comptime context: []const u8) void {
    if (path.len < 4) print.stderr(context ++ ": file must be .xml or .zip (got '{s}')", .{path});
    const ext = std.fs.path.extension(path);
    if (!std.ascii.eqlIgnoreCase(ext, ".xml") and !std.ascii.eqlIgnoreCase(ext, ".zip")) {
        print.stderr(context ++ ": file must be .xml or .zip (got '{s}')", .{path});
    }
}
