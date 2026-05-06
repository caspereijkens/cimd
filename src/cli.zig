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
const print = @import("io/print.zig");

pub const ansi_green = "\x1b[92m";
pub const ansi_default = "\x1b[0m";
pub const ansi_yellow = "\x1b[33m";

const help_main =
    \\Usage: cimd <command> [options]
    \\
    \\A high-performance CGMES file parser and analysis tool.
    \\
    \\Commands:
    \\  convert    Convert an EQ profile to JIIDM JSON
    \\  browse     Interactively browse CIM objects (EQ/EQBD/TP/SSH merged view)
    \\  get        Fetch a single object or list by type from any CIM file
    \\  types      List CIM types present in a CIM file
    \\  diff       Semantic diff between two EQ profiles
    \\  topology   Generate TopologicalNodes from EQ (+SSH) — TP-equivalent output
    \\  version    Print version information
    \\
    \\Use 'cimd <command> --help' for more information about a command.
    \\
;

const help_convert =
    \\Usage: cimd convert <file> [options]
    \\
    \\Convert a CGMES EQ profile to JIIDM JSON format.
    \\Output is written to stdout unless --output is given.
    \\
    \\Arguments:
    \\  <file>                  EQ profile (XML or ZIP)
    \\
    \\Options:
    \\  -b, --boundary <file>   EQBD boundary profile (XML or ZIP)
    \\  -t, --topology <file>   TP topology profile (XML or ZIP)
    \\  -s, --ssh <file>        SSH steady-state hypothesis profile (XML or ZIP)
    \\  -o, --output <file>     Write output to file instead of stdout
    \\      --bus-branch        Emit bus-branch JIIDM (one bus per TopologicalNode).
    \\                          Requires --topology. Default is node-breaker even
    \\                          when TP is given (matches pypowsybl).
    \\
    \\Examples:
    \\  cimd convert data/eq.zip
    \\  cimd convert data/eq.zip -b eqbd.zip
    \\  cimd convert data/eq.zip -b eqbd.zip -s ssh.zip
    \\  cimd convert data/eq.zip -o network.json
    \\  cimd convert data/eq.zip -t tp.zip --bus-branch
    \\
;

const help_browse =
    \\Usage: cimd browse <file> <mrid> [options]
    \\
    \\Interactively browse CIM objects by following rdf:resource references.
    \\When --topology or --ssh is passed, patches from those profiles are shown
    \\inline alongside the primary object, and new objects from TP (e.g.
    \\TopologicalNodes) become navigable by mRID.
    \\
    \\Arguments:
    \\  <file>    Primary CIM file (typically EQ; XML or ZIP)
    \\  <mrid>    mRID of the object to start browsing from
    \\
    \\Options:
    \\  -b, --boundary <file>       EQBD boundary profile (XML or ZIP)
    \\  -t, --topology <file>       TP topology profile (XML or ZIP)
    \\  -s, --ssh <file>            SSH steady-state hypothesis profile (XML or ZIP)
    \\
    \\Examples:
    \\  cimd browse data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221
    \\  cimd browse data/eq.zip _abc -t tp.zip -s ssh.zip
    \\
;

const help_get =
    \\Usage: cimd get <file> [<mrid>] [options]
    \\
    \\Fetch a CIM object by mRID, or list all objects of a given type.
    \\Works on any CGMES file (EQ, EQBD, TP, SSH, ...).
    \\At least one of <mrid> or --type must be provided.
    \\Exits 0 on success, 1 if the mRID is not found.
    \\
    \\Arguments:
    \\  <file>    CGMES file (XML or ZIP)
    \\  <mrid>    mRID of the object to fetch (optional if --type is given)
    \\
    \\Options:
    \\  -t, --type <type>          Filter by CIM type (e.g. PowerTransformer)
    \\                             Without <mrid>: list all objects of this type
    \\                             With <mrid>: verify the object is of this type
    \\  -f, --fields <f1,f2,...>   Properties to include in list output (list mode only)
    \\                             Default: IdentifiedObject.name
    \\  -c, --count                Print only the count of matching objects (list mode only)
    \\  -j, --json                 Output as JSON
    \\
    \\Examples:
    \\  cimd get data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221
    \\  cimd get data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221 -j
    \\  cimd get data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221 -t PowerTransformer
    \\  cimd get data/eq.zip -t PowerTransformer -j
    \\  cimd get data/eq.zip -t PowerTransformer -c
    \\  cimd get data/eq.zip -t VoltageLevel -f IdentifiedObject.name,VoltageLevel.nominalVoltage
    \\  cimd get data/tp.zip -t TopologicalNode -c
    \\
;

const help_types =
    \\Usage: cimd types <file> [options]
    \\
    \\List all CIM types present in a CGMES file with object counts.
    \\Works on any CGMES file (EQ, EQBD, TP, SSH, ...).
    \\
    \\Arguments:
    \\  <file>                  CGMES file (XML or ZIP)
    \\
    \\Options:
    \\  -j, --json              Output as JSON array of {{type, count}} objects
    \\
    \\Examples:
    \\  cimd types data/eq.zip
    \\  cimd types data/tp.zip -j
    \\
;

const help_diff =
    \\Usage: cimd diff <file1> <file2> [options]
    \\
    \\Compare two CGMES EQ profiles semantically. Objects are matched by mRID
    \\across both files; properties are compared field-by-field. XML attribute
    \\order and whitespace differences are ignored.
    \\
    \\Exit codes:
    \\  0  files are identical (no differences found)
    \\  1  differences found
    \\  2  usage error
    \\
    \\Arguments:
    \\  <file1>    First EQ profile (XML or ZIP)
    \\  <file2>    Second EQ profile (XML or ZIP)
    \\
    \\Options:
    \\  -b, --boundary <file>   EQBD boundary profile (applied to both models)
    \\  -i, --mrid <id>         Diff a single object by mRID
    \\  -t, --type <name>       Restrict diff to a specific CIM type
    \\                          With --mrid: verify the object is of this type
    \\  -s, --summary           Print only per-type counts (added/removed/changed)
    \\  -j, --json              Output as NDJSON (one object per change)
    \\
    \\Examples:
    \\  cimd diff eq_v1.zip eq_v2.zip
    \\  cimd diff eq_v1.zip eq_v2.zip -i _abc123
    \\  cimd diff eq_v1.zip eq_v2.zip -i _abc123 -t PowerTransformer
    \\  cimd diff eq_v1.zip eq_v2.zip -t PowerTransformer
    \\  cimd diff eq_v1.zip eq_v2.zip -j | jq .
    \\  cimd diff eq_v1.zip eq_v2.zip -s
    \\
;

const help_topology =
    \\Usage: cimd topology <file> [options]
    \\
    \\Generate TopologicalNodes from an EQ profile (and optional SSH). Each TN is
    \\a connected component of ConnectivityNodes joined by *closed* switches —
    \\equivalent to a CGMES TP profile's terminal→TopologicalNode mapping.
    \\Output is JSON on stdout.
    \\
    \\Without --ssh, all switches are treated as closed (electrical-equivalence
    \\snapshot ignoring switch state).
    \\
    \\Arguments:
    \\  <file>                  EQ profile (XML or ZIP)
    \\
    \\Options:
    \\  -b, --boundary <file>   EQBD boundary profile (XML or ZIP)
    \\  -s, --ssh <file>        SSH steady-state hypothesis profile (XML or ZIP)
    \\  -o, --output <file>     Write output to file instead of stdout
    \\
    \\Examples:
    \\  cimd topology data/eq.zip -s ssh.zip
    \\  cimd topology data/eq.zip -b eqbd.zip -s ssh.zip -o tn.json
    \\
;

const help_version =
    \\Usage: cimd version [options]
    \\
    \\Print version and build information.
    \\
    \\Options:
    \\  -v, --verbose    Show detailed build information
    \\  -j, --json       Output as JSON
    \\
    \\Examples:
    \\  cimd version
    \\  cimd version -j
    \\
;

// ── Command types ─────────────────────────────────────────────────────────────

pub const Command = union(enum) {
    convert: Convert,
    browse: Browse,
    get: Get,
    types: Types,
    diff: Diff,
    topology: Topology,
    version: Version,

    pub const Convert = struct {
        eq_path: []const u8,
        eqbd_path: ?[]const u8,
        tp_path: ?[]const u8,
        ssh_path: ?[]const u8,
        output_path: ?[]const u8,
        bus_branch: bool,
    };

    pub const Browse = struct {
        file_path: []const u8,
        eqbd_path: ?[]const u8,
        tp_path: ?[]const u8,
        ssh_path: ?[]const u8,
        mrid: []const u8,
    };

    pub const Get = struct {
        file_path: []const u8,
        mrid: ?[]const u8,
        type_filter: ?[]const u8,
        fields: ?[]const u8,
        count: bool,
        json: bool,
    };

    pub const Types = struct {
        file_path: []const u8,
        json: bool,
    };

    pub const Diff = struct {
        file_path1: []const u8,
        file_path2: []const u8,
        /// Applied to both models.
        eqbd_path: ?[]const u8,
        /// When set, diff only this one object.
        mrid: ?[]const u8,
        /// Restrict comparison to this CIM type.
        /// With mrid: verifies the object is of this type.
        type_filter: ?[]const u8,
        /// Print only per-type counts, no per-property detail.
        summary: bool,
        /// Output as NDJSON instead of human-readable text.
        json: bool,
    };

    pub const Topology = struct {
        eq_path: []const u8,
        eqbd_path: ?[]const u8,
        ssh_path: ?[]const u8,
        output_path: ?[]const u8,
    };

    pub const Version = struct {
        verbose: bool,
        json: bool,
    };
};

/// Parse the command-line arguments passed to the cimd binary.
/// Exits with code 2 on any usage error.
pub fn parse_args(io: std.Io, args: *std.process.Args.Iterator) !Command {
    assert(args.skip()); // skip executable name

    const command_name = args.next() orelse
        print.stderr(io, "subcommand required\n\n" ++ help_main, .{});

    if (std.mem.eql(u8, command_name, "-h") or std.mem.eql(u8, command_name, "--help")) {
        try print.stdout(io, help_main, .{});
        std.process.exit(0);
    }

    if (std.mem.eql(u8, command_name, "convert")) return parse_convert(io, args);
    if (std.mem.eql(u8, command_name, "browse")) return parse_browse(io, args);
    if (std.mem.eql(u8, command_name, "get")) return parse_get(io, args);
    if (std.mem.eql(u8, command_name, "types")) return parse_types(io, args);
    if (std.mem.eql(u8, command_name, "diff")) return parse_diff(io, args);
    if (std.mem.eql(u8, command_name, "topology")) return parse_topology(io, args);
    if (std.mem.eql(u8, command_name, "version")) return parse_version(io, args);

    print.stderr(io, "unknown command '{s}'\n\n" ++ help_main, .{command_name});
}

fn parse_convert(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const context = "convert";

    var eq_path: ?[]const u8 = null;
    var eqbd_path: ?[]const u8 = null;
    var tp_path: ?[]const u8 = null;
    var ssh_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var bus_branch: bool = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.stdout(io, help_convert, .{});
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--boundary")) {
            eqbd_path = take_path_arg(io, args, context, "--boundary");
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--topology")) {
            tp_path = take_path_arg(io, args, context, "--topology");
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--ssh")) {
            ssh_path = take_path_arg(io, args, context, "--ssh");
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = args.next() orelse
                print.stderr(io, context ++ ": --output requires a file path", .{});
        } else if (std.mem.eql(u8, arg, "--bus-branch")) {
            bus_branch = true;
        } else if (is_flag(arg)) {
            print.stderr(io, context ++ ": unknown option '{s}'", .{arg});
        } else {
            if (eq_path != null) print.stderr(io, context ++ ": unexpected argument '{s}'", .{arg});
            validate_path(io, arg, context);
            validate_cgmes_extension(io, arg, context);
            eq_path = arg;
        }
    }

    if (eq_path == null) print.stderr(io, context ++ ": <file> is required", .{});
    if (bus_branch and tp_path == null)
        print.stderr(io, context ++ ": --bus-branch requires --topology", .{});

    return .{ .convert = .{
        .eq_path = eq_path.?,
        .eqbd_path = eqbd_path,
        .tp_path = tp_path,
        .ssh_path = ssh_path,
        .output_path = output_path,
        .bus_branch = bus_branch,
    } };
}

fn parse_browse(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const context = "browse";

    var file_path: ?[]const u8 = null;
    var eqbd_path: ?[]const u8 = null;
    var tp_path: ?[]const u8 = null;
    var ssh_path: ?[]const u8 = null;
    var mrid: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.stdout(io, help_browse, .{});
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--boundary")) {
            eqbd_path = take_path_arg(io, args, context, "--boundary");
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--topology")) {
            tp_path = take_path_arg(io, args, context, "--topology");
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--ssh")) {
            ssh_path = take_path_arg(io, args, context, "--ssh");
        } else if (is_flag(arg)) {
            print.stderr(io, context ++ ": unknown option '{s}'", .{arg});
        } else if (file_path == null) {
            validate_path(io, arg, context);
            validate_cgmes_extension(io, arg, context);
            file_path = arg;
        } else if (mrid == null) {
            mrid = arg;
        } else {
            print.stderr(io, context ++ ": unexpected argument '{s}'", .{arg});
        }
    }

    if (file_path == null) print.stderr(io, context ++ ": <file> is required", .{});
    if (mrid == null) print.stderr(io, context ++ ": <mrid> is required", .{});

    return .{ .browse = .{
        .file_path = file_path.?,
        .eqbd_path = eqbd_path,
        .tp_path = tp_path,
        .ssh_path = ssh_path,
        .mrid = mrid.?,
    } };
}

fn parse_get(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const context = "get";

    var file_path: ?[]const u8 = null;
    var mrid: ?[]const u8 = null;
    var type_filter: ?[]const u8 = null;
    var fields: ?[]const u8 = null;
    var count = false;
    var json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.stdout(io, help_get, .{});
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type")) {
            type_filter = args.next() orelse
                print.stderr(io, context ++ ": --type requires a CIM type name", .{});
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--fields")) {
            fields = args.next() orelse
                print.stderr(io, context ++ ": --fields requires a comma-separated list of property names", .{});
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            count = true;
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (is_flag(arg)) {
            print.stderr(io, context ++ ": unknown option '{s}'", .{arg});
        } else if (file_path == null) {
            validate_path(io, arg, context);
            validate_cgmes_extension(io, arg, context);
            file_path = arg;
        } else if (mrid == null) {
            mrid = arg;
        } else {
            print.stderr(io, context ++ ": unexpected argument '{s}'", .{arg});
        }
    }

    if (file_path == null) print.stderr(io, context ++ ": <file> is required", .{});
    if (mrid == null and type_filter == null) print.stderr(io, context ++ ": <mrid> or --type is required", .{});
    if (count and mrid != null) print.stderr(io, context ++ ": --count takes no value; '{s}' was parsed as <mrid> (use --type without <mrid> for list mode)", .{mrid.?});

    return .{ .get = .{
        .file_path = file_path.?,
        .mrid = mrid,
        .type_filter = type_filter,
        .fields = fields,
        .count = count,
        .json = json,
    } };
}

fn parse_types(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const context = "types";

    var file_path: ?[]const u8 = null;
    var json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.stdout(io, help_types, .{});
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (is_flag(arg)) {
            print.stderr(io, context ++ ": unknown option '{s}'", .{arg});
        } else {
            if (file_path != null) print.stderr(io, context ++ ": unexpected argument '{s}'", .{arg});
            validate_path(io, arg, context);
            validate_cgmes_extension(io, arg, context);
            file_path = arg;
        }
    }

    if (file_path == null) print.stderr(io, context ++ ": <file> is required", .{});

    return .{ .types = .{
        .file_path = file_path.?,
        .json = json,
    } };
}

fn parse_diff(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const context = "diff";

    var file_path1: ?[]const u8 = null;
    var file_path2: ?[]const u8 = null;
    var eqbd_path: ?[]const u8 = null;
    var mrid: ?[]const u8 = null;
    var type_filter: ?[]const u8 = null;
    var summary = false;
    var json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.stdout(io, help_diff, .{});
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--boundary")) {
            eqbd_path = take_path_arg(io, args, context, "--boundary");
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--mrid")) {
            mrid = args.next() orelse
                print.stderr(io, context ++ ": --mrid requires an mRID value", .{});
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type")) {
            type_filter = args.next() orelse
                print.stderr(io, context ++ ": --type requires a CIM type name", .{});
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (is_flag(arg)) {
            print.stderr(io, context ++ ": unknown option '{s}'", .{arg});
        } else if (file_path1 == null) {
            validate_path(io, arg, context);
            validate_cgmes_extension(io, arg, context);
            file_path1 = arg;
        } else if (file_path2 == null) {
            validate_path(io, arg, context);
            validate_cgmes_extension(io, arg, context);
            file_path2 = arg;
        } else {
            print.stderr(io, context ++ ": unexpected argument '{s}'", .{arg});
        }
    }

    if (file_path1 == null) print.stderr(io, context ++ ": <file1> is required", .{});
    if (file_path2 == null) print.stderr(io, context ++ ": <file2> is required", .{});

    return .{ .diff = .{
        .file_path1 = file_path1.?,
        .file_path2 = file_path2.?,
        .eqbd_path = eqbd_path,
        .mrid = mrid,
        .type_filter = type_filter,
        .summary = summary,
        .json = json,
    } };
}

fn parse_topology(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const context = "topology";

    var eq_path: ?[]const u8 = null;
    var eqbd_path: ?[]const u8 = null;
    var ssh_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.stdout(io, help_topology, .{});
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--boundary")) {
            eqbd_path = take_path_arg(io, args, context, "--boundary");
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--ssh")) {
            ssh_path = take_path_arg(io, args, context, "--ssh");
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = args.next() orelse
                print.stderr(io, context ++ ": --output requires a file path", .{});
        } else if (is_flag(arg)) {
            print.stderr(io, context ++ ": unknown option '{s}'", .{arg});
        } else {
            if (eq_path != null) print.stderr(io, context ++ ": unexpected argument '{s}'", .{arg});
            validate_path(io, arg, context);
            validate_cgmes_extension(io, arg, context);
            eq_path = arg;
        }
    }

    if (eq_path == null) print.stderr(io, context ++ ": <file> is required", .{});

    return .{ .topology = .{
        .eq_path = eq_path.?,
        .eqbd_path = eqbd_path,
        .ssh_path = ssh_path,
        .output_path = output_path,
    } };
}

fn parse_version(io: std.Io, args: *std.process.Args.Iterator) !Command {
    var verbose = false;
    var json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.stdout(io, help_version, .{});
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else {
            print.stderr(io, "version: unknown option '{s}'", .{arg});
        }
    }

    return .{ .version = .{ .verbose = verbose, .json = json } };
}

/// Consume the next argument as a path value for a flag like --boundary, validating it.
/// Exits with a usage error if the argument is missing or invalid.
fn take_path_arg(
    io: std.Io,
    args: *std.process.Args.Iterator,
    comptime context: []const u8,
    comptime flag: []const u8,
) []const u8 {
    const path = args.next() orelse
        print.stderr(io, context ++ ": " ++ flag ++ " requires a file path", .{});
    validate_path(io, path, context);
    validate_cgmes_extension(io, path, context);
    return path;
}

inline fn is_flag(arg: []const u8) bool {
    return arg.len > 0 and arg[0] == '-';
}

fn validate_path(io: std.Io, path: []const u8, comptime context: []const u8) void {
    if (path.len == 0) print.stderr(io, context ++ ": path cannot be empty", .{});
    if (path.len > std.fs.max_path_bytes) {
        print.stderr(io, context ++ ": path too long ({d} bytes, max {d})", .{
            path.len, std.fs.max_path_bytes,
        });
    }
}

fn validate_cgmes_extension(io: std.Io, path: []const u8, comptime context: []const u8) void {
    if (path.len < 4) print.stderr(io, context ++ ": file must be .xml or .zip (got '{s}')", .{path});
    const ext = std.fs.path.extension(path);
    if (!std.ascii.eqlIgnoreCase(ext, ".xml") and !std.ascii.eqlIgnoreCase(ext, ".zip")) {
        print.stderr(io, context ++ ": file must be .xml or .zip (got '{s}')", .{path});
    }
}
