//! Parse and validate command-line arguments for the cimd binary.
//!
//! Everything that can be validated without reading the data file must be validated here.
//! Caller must additionally assert validity of arguments as a defense in depth.
//!
//! Exit codes:
//!   0  success
//!   1  not found (requested mRID / resource does not exist)
//!   2  usage error (bad flags, missing args, unknown subcommand)
//!   3  differences found (`diff` only)
//!   4  validation violations found (`validate` only)
//!  65  invalid or unsupported input data
//!  66  input unavailable (missing, unreadable, or wrong path type)
//!  70  unexpected internal failure
//!  71  operating-system or resource failure

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const print = @import("io/print.zig");
const io_read = @import("io/read.zig");
const model_set = @import("model_set.zig");
const rule_set = @import("shacl/rule_set.zig");

pub const ansi_green = "\x1b[92m";
pub const ansi_default = "\x1b[0m";
pub const ansi_yellow = "\x1b[33m";

const path_separator = if (builtin.os.tag == .windows) "\\" else "/";

const help_failure_exit_codes =
    "\n  65  invalid or unsupported input data" ++
    "\n  66  input unavailable" ++
    "\n  70  unexpected internal failure" ++
    "\n  71  operating-system or resource failure\n";

const help_main = std.fmt.comptimePrint(
    \\Usage: cimd <command> [options]
    \\
    \\A high-performance CGMES file parser and analysis tool.
    \\
    \\Input limits:
    \\  XML data: {[xml_limit]s} total after unzip (up to 8 inputs,
    \\    16 XML parts per ZIP).
    \\  SHACL rule files: {[rules_limit]s} after unzip.
    \\  Non-interactive commands accept '-' as the primary data path to read
    \\  uncompressed XML from stdin.
    \\
    \\Commands:
    \\  convert    Convert an EQ profile to JIIDM JSON
    \\  browse     Interactively browse CIM objects (EQ/EQBD/TP/SSH merged view)
    \\  get        Fetch a single object or list by type from any CIM file
    \\  refs       List objects that reference a CIM object
    \\  types      List CIM types present in a CIM file
    \\  diff       Semantic diff between two CIM files of the same profile
    \\  topology   Generate TopologicalNodes from EQ (+SSH)
    \\  validate   Validate a CGMES file against a SHACL rule set
    \\  qocdc      Run Quality of CGMES Datasets and Calculations checks
    \\  version    Print version information
    \\
    \\Use 'cimd <command> --help' for more information about a command.
    \\
,
    .{
        .xml_limit = print.size_limit_text_comptime(io_read.max_in_memory_input_bytes),
        .rules_limit = print.size_limit_text_comptime(rule_set.rules_bytes_max),
    },
);

const help_convert = std.fmt.comptimePrint(
    \\Usage: cimd convert <file>... [options]
    \\
    \\Convert a CGMES EQ profile to JIIDM JSON format.
    \\Output is written to stdout unless --output is given.
    \\
    \\Arguments:
    \\  <file>...               CGMES parts or a bundle (XML or ZIP)
    \\
    \\Options:
    \\      --eq <file>         Explicitly route a headerless/unknown file as EQ
    \\  -b, --eqbd <file>       EQBD boundary profile (XML or ZIP)
    \\  -t, --tp <file>         TP topology profile (XML or ZIP)
    \\  -s, --ssh <file>        SSH steady-state hypothesis profile (XML or ZIP)
    \\  -o, --output <file>     Write output to file instead of stdout
    \\      --bus-branch        Emit one JIIDM bus per TopologicalNode
    \\                          Requires a TP part. Default is node-breaker even
    \\                          when TP is given (matches pypowsybl).
    \\
    \\Examples:
    \\  cimd convert data{[sep]s}eq.zip
    \\  cimd convert data{[sep]s}eq.zip --eqbd eqbd.zip
    \\  cimd convert data{[sep]s}eq.zip --eqbd eqbd.zip -s ssh.zip
    \\  cimd convert data{[sep]s}eq.zip -o network.json
    \\  cimd convert data{[sep]s}eq.zip --tp tp.zip --bus-branch
    \\
, .{ .sep = path_separator });

const help_browse = std.fmt.comptimePrint(
    \\Usage: cimd browse <file>... <mrid> [options]
    \\
    \\Interactively browse CIM objects by following rdf:resource references.
    \\When --tp or --ssh is passed, patches from those profiles are shown
    \\inline alongside the primary object, and new objects from TP (e.g.
    \\TopologicalNodes) become navigable by mRID.
    \\
    \\<mrid> may be a prefix of a full mRID; the leading underscore is optional.
    \\The prefix is matched against EQ objects and, when --tp is given,
    \\TP-added objects (e.g. TopologicalNodes). When a prefix matches more than
    \\one object, browse opens a picker menu -- flat list when few candidates,
    \\grouped by type when many.
    \\
    \\Arguments:
    \\  <file>    Primary CIM file (typically EQ; XML or ZIP); '-' is not
    \\            supported because browse reserves stdin for interaction
    \\  <mrid>    Full mRID or a prefix of one
    \\
    \\Options:
    \\      --eq <file>             Explicitly route a file as EQ
    \\  -b, --eqbd <file>           EQBD boundary profile (XML or ZIP)
    \\  -t, --tp <file>             TP topology profile (XML or ZIP)
    \\  -s, --ssh <file>            SSH profile (XML or ZIP)
    \\
    \\Examples:
    \\  cimd browse data{[sep]s}eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221
    \\  cimd browse data{[sep]s}eq.zip be60a3cf
    \\  cimd browse data{[sep]s}eq.zip _abc --tp tp.zip -s ssh.zip
    \\
, .{ .sep = path_separator });

const help_get = std.fmt.comptimePrint(
    \\Usage: cimd get <file>... [<mrid>] [options]
    \\
    \\Fetch a CIM object by mRID (or a prefix of one), or list all objects of a
    \\given type. Works on any CGMES file (EQ, EQBD, TP, SSH, ...).
    \\At least one of <mrid> or --type must be provided.
    \\Exits 0 on success, 1 if no object is found.
    \\
    \\Prefix lookup:
    \\  <mrid> may be any prefix of a full mRID. For the common rdf:ID form
    \\  a leading underscore is optional: "_be60" and "be60" are equivalent.
    \\  For FullModel-style ids carried in rdf:about (e.g. "urn:uuid:484c..."),
    \\  pass the prefix literally -- "urn", "urn:uuid:484c", etc. all work. When
    \\  a prefix matches multiple objects, cimd prints the candidates and exits
    \\  without selecting one. Large match lists show a per-type
    \\  breakdown instead. With --json, an envelope
    \\  `{{"prefix","total","matches","types"}}` is emitted regardless of match
    \\  count. Pass --type to narrow ambiguous prefixes to a single type.
    \\
    \\JSON errors:
    \\  With --json, the not-found / wrong-type paths emit a structured error
    \\  on stdout and exit 1 instead of printing to stderr:
    \\    {{"error":"not_found", "prefix":...}}
    \\    {{"error":"type_mismatch", "prefix":..., "id":..., ...}}
    \\    {{"error":"none_of_type", "prefix":..., "total":..., ...}}
    \\
    \\Arguments:
    \\  <file>    CGMES file (XML or ZIP)
    \\  <mrid>    Full mRID or a unique prefix (optional if --type is given)
    \\
    \\Options:
    \\      --eq <file>            Explicitly route a file as EQ
    \\  -t, --type <type>          Filter by CIM type (e.g. ConductingEquipment)
    \\                             Includes CIM subtypes
    \\                             Without <mrid>: list all objects of this type
    \\                             With <mrid>: verify its type or narrow an
    \\                             ambiguous prefix
    \\  -f, --fields <f1,f2,...>   Include properties in list output
    \\                             Text default: IdentifiedObject.name
    \\                             JSON default: full object
    \\  -c, --count                Print only the list-mode match count
    \\  -b, --eqbd <file>          EQBD boundary profile (XML or ZIP)
    \\      --tp <file>            TP profile (single-object mode only)
    \\      --ssh <file>           SSH profile (single-object mode only)
    \\  -j, --json                 Output as JSON. In list mode, each element is
    \\                             {{"id","type","properties","references"}}
    \\                             unless --fields narrows the projection.
    \\
    \\Examples:
    \\  cimd get data{[sep]s}eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221
    \\  cimd get data{[sep]s}eq.zip be60a3cf
    \\  cimd get data{[sep]s}eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221 -j
    \\  cimd get data{[sep]s}eq.zip be60 -t PowerTransformer
    \\  cimd get data{[sep]s}eq.zip _TN1 --tp tp.zip -j
    \\  cimd get data{[sep]s}eq.zip _switch --ssh ssh.zip -j
    \\  cimd get data{[sep]s}eq.zip -t PowerTransformer -j
    \\  cimd get data{[sep]s}eq.zip -t PowerTransformer -c
    \\  cimd get data{[sep]s}eq.zip -t VoltageLevel -f IdentifiedObject.name
    \\  cimd get data{[sep]s}tp.zip -t TopologicalNode -c
    \\
, .{ .sep = path_separator });

const help_refs = std.fmt.comptimePrint(
    \\Usage: cimd refs <file>... <mrid> [options]
    \\
    \\List reverse references to a CIM object: every object whose rdf:resource
    \\points at <mrid>, searched across the primary file plus any EQBD/TP/SSH
    \\inputs. The <mrid> argument may be a unique prefix; the leading
    \\underscore is optional.
    \\
    \\--type narrows the *target* (use it to disambiguate <mrid>). --from
    \\filters the *referrer set* (which kinds of objects point at the target).
    \\Both filters include subtypes from the CIM inheritance graph.
    \\
    \\Exits 0 on success (including zero referrers), 1 if <mrid> is not found.
    \\
    \\JSON errors:
    \\  With --json, the not-found path emits a structured error on stdout and
    \\  exits 1; an ambiguous prefix emits the standard ambiguity envelope on
    \\  stdout and exits 0:
    \\    {{"error":"not_found", "prefix":...}}
    \\    {{"prefix":..., "total":..., "matches":[...], "types":[...]}}
    \\
    \\Arguments:
    \\  <file>    CGMES file (XML or ZIP); typically EQ
    \\  <mrid>    Full mRID or a unique prefix
    \\
    \\Options:
    \\      --eq <file>       Explicitly route a file as EQ
    \\  -t, --type <type>     Narrow the target type
    \\      --from <type>     Only show referrers of this CIM type
    \\  -b, --eqbd <file>     EQBD boundary profile (XML or ZIP)
    \\      --tp <file>       TP topology profile (XML or ZIP)
    \\      --ssh <file>      SSH steady-state hypothesis profile (XML or ZIP)
    \\  -j, --json            Output {{"id","type","referrers":[...]}}
    \\
    \\Examples:
    \\  cimd refs data{[sep]s}eq.zip _line-mrid
    \\  cimd refs data{[sep]s}eq.zip _0 -t LinearShuntCompensator
    \\  cimd refs data{[sep]s}eq.zip line-prefix --from AssessedElement -j
    \\  cimd refs data{[sep]s}eq.zip _TN1 --tp tp.zip
    \\
, .{ .sep = path_separator });

const help_types = std.fmt.comptimePrint(
    \\Usage: cimd types <file>... [options]
    \\
    \\List all CIM types present in CGMES files with object counts.
    \\Every XML part in a ZIP bundle is inventoried.
    \\
    \\Arguments:
    \\  <file>...               CGMES files or bundles (XML or ZIP)
    \\
    \\Options:
    \\      --eq/--eqbd/--tp/--ssh <file>
    \\                           Explicit profile routing for one-part inputs
    \\  -j, --json              Output a JSON array of {{{{type, count}}}}
    \\
    \\Examples:
    \\  cimd types data{[sep]s}eq.zip
    \\  cimd types data{[sep]s}tp.zip -j
    \\
, .{ .sep = path_separator });

const help_diff =
    \\Usage: cimd diff <file1> <file2> [options]
    \\
    \\Compare two CGMES profiles semantically. Objects are matched by mRID
    \\across both files; properties are compared field-by-field. XML attribute
    \\order and whitespace differences are ignored.
    \\
    \\Both sides must be the same profile, and both must say so: if one file
    \\declares a profile and the other declares none, route the silent one with
    \\its kind flag. Any profile can be compared -- EQ, SSH (switch states,
    \\setpoints), TP, SV, DL, DY, GL -- though the result is only useful where
    \\mRIDs are stable between exports: SSH and TP patch existing EQ objects
    \\and diff cleanly, while SV objects are re-identified on every export and
    \\will read as wholly added and removed.
    \\
    \\By default an EQDIFF difference model (IEC 61970-552) is written to
    \\stdout (or --output): dm:forwardDifferences holds the statements to add
    \\going from <file1> to <file2>, dm:reverseDifferences the statements to
    \\remove. Output is deterministic -- the same inputs always produce a
    \\byte-identical file. Use --patch, --json, or --summary for a
    \\report-style view instead.
    \\
    \\Exit codes:
    \\  0  files are identical (no differences found)
    \\  1  requested mRID was not found
    \\  2  usage error
    \\  3  differences found
++ help_failure_exit_codes ++
    \\
    \\Arguments:
    \\  <file1>    First profile (XML or ZIP); a bundle resolves to its EQ part
    \\  <file2>    Second profile (XML or ZIP); same profile as <file1>
    \\
    \\Options:
    \\  -b, --eqbd <file>       EQBD boundary profile (EQ sides only; applied
    \\                          to both models)
    \\      --eq, --ssh, --tp, --tpbd, --sv, --dl, --dy, --gl <file>
    \\                          Supply a side explicitly as that profile, for
    \\                          parts whose header states none or names an
    \\                          unrecognized profile (up to twice). The choice
    \\                          only has to agree between the two sides, so a
    \\                          boundary file takes --eq here -- on diff,
    \\                          --eqbd names the shared boundary instead
    \\  -i, --mrid <id>         Diff a single object by mRID
    \\  -t, --type <name>       Restrict diff to a CIM type and its subtypes
    \\                          With --mrid: verify the object is of this type
    \\  -o, --output <file>     Write output to file instead of stdout
    \\  -p, --patch             Human-readable report modelled after `git diff`
    \\  -s, --summary           Print per-type change counts
    \\  -j, --json              Output as NDJSON (one object per change)
    \\                          Cannot be combined with --patch or --summary
    \\
    \\Examples:
    \\  cimd diff eq_v1.zip eq_v2.zip -o eqdiff.xml
    \\  cimd diff eq_v1.zip eq_v2.zip -p
    \\  cimd diff eq_v1.zip eq_v2.zip -i _abc123 -t PowerTransformer
    \\  cimd diff eq_v1.zip eq_v2.zip -t PowerTransformer
    \\  cimd diff eq_v1.zip eq_v2.zip -j | jq .
    \\  cimd diff eq_v1.zip eq_v2.zip -s
    \\  cimd diff ssh_v1.xml ssh_v2.xml -p -t Breaker
    \\
;

const help_topology = std.fmt.comptimePrint(
    \\Usage: cimd topology <file>... [options]
    \\
    \\Generate TopologicalNodes from an EQ profile and optional SSH. Each TN is
    \\a connected component of ConnectivityNodes joined by *closed* switches --
    \\equivalent to a CGMES TP profile's terminal→TopologicalNode mapping.
    \\Output is JSON on stdout.
    \\
    \\Without --ssh, all switches are treated as closed (electrical-equivalence
    \\snapshot ignoring switch state).
    \\
    \\Arguments:
    \\  <file>...               CGMES parts or a bundle (XML or ZIP)
    \\
    \\Options:
    \\      --eq <file>         Explicitly route a file as EQ
    \\  -b, --eqbd <file>       EQBD boundary profile (XML or ZIP)
    \\  -s, --ssh <file>        SSH steady-state hypothesis profile (XML or ZIP)
    \\  -o, --output <file>     Write output to file instead of stdout
    \\
    \\Examples:
    \\  cimd topology data{[sep]s}eq.zip -s ssh.zip
    \\  cimd topology data{[sep]s}eq.zip --eqbd eqbd.zip -s ssh.zip -o tn.json
    \\
, .{ .sep = path_separator });

const help_validate = std.fmt.comptimePrint(
    \\Usage: cimd validate <file>... --rules <ttl|zip> [options]
    \\
    \\Validate a CGMES instance file against a SHACL rule set (e.g. the
    \\ENTSO-E application-profile constraints). Any profile works -- EQ, SSH,
    \\TP, SV -- supply the rule sets published for that profile. Rule sets
    \\are external inputs: point --rules at any SHACL/Turtle file, or a zip
    \\containing one. Rules the engine cannot execute (sh:sparql above all)
    \\are counted and named in the report, never silently dropped.
    \\
    \\Every violation reports the data file name, the line number of the
    \\object, the rule code, and the rule's own message. Load errors in the
    \\rules file report file and line the same way.
    \\
    \\Exit codes:
    \\  0  no violations (warnings and info findings do not fail the run)
    \\  2  usage error
    \\  4  violations found
++ help_failure_exit_codes ++
    \\
    \\Arguments:
    \\  <file>...               CGMES files or bundles, any profile (XML or ZIP)
    \\
    \\Options:
    \\      --eq <file>         Explicit EQ merge target / profile routing
    \\      --tp <file>         Explicit TP profile routing
    \\      --ssh <file>        Explicit SSH profile routing
    \\  -r, --rules <file>      SHACL rule set, Turtle or zipped Turtle
    \\                          (repeatable, at most {[rules_max]d} per run)
    \\  -b, --eqbd <file>       EQBD boundary profile merged into the model
    \\                          before validation (XML or ZIP)
    \\  -o, --output <file>     Write the report to a file instead of stdout
    \\      --list-skipped      List every rule the engine cannot execute
    \\
    \\Examples:
    \\  cimd validate data{[sep]s}eq.zip -r rules{[sep]s}profile.ttl
    \\  cimd validate data{[sep]s}eq.zip -b eqbd.zip -r a.ttl -r b.ttl
    \\
, .{ .sep = path_separator, .rules_max = Command.Validate.rules_count_max });

const help_qocdc = std.fmt.comptimePrint(
    \\Usage: cimd qocdc <file>
    \\
    \\Validate a grid model against to the 'Quality of CGMES Datasets and
    \\Calculations'.
    \\
    \\Arguments:
    \\  <file>                  CGMES ZIP archive
    \\
    \\Examples:
    \\  cimd qocdc data{[sep]s}eq.zip
    \\
, .{ .sep = path_separator });

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
    refs: Refs,
    types: Types,
    diff: Diff,
    topology: Topology,
    validate: Validate,
    qocdc: Qocdc,
    version: Version,

    pub const Convert = struct {
        model_inputs: ModelInputs,
        output_path: ?[]const u8,
        bus_branch: bool,
    };

    pub const Browse = struct {
        model_inputs: ModelInputs,
        mrid: []const u8,
    };

    pub const Get = struct {
        model_inputs: ModelInputs,
        mrid: ?[]const u8,
        type_filter: ?[]const u8,
        fields: ?[]const u8,
        count: bool,
        json: bool,
    };

    pub const Refs = struct {
        model_inputs: ModelInputs,
        mrid: []const u8,
        target_type: ?[]const u8,
        from_type: ?[]const u8,
        json: bool,
    };

    pub const Types = struct {
        model_inputs: ModelInputs,
        json: bool,
    };

    pub const Diff = struct {
        sides: [2]model_set.Input,
        /// Applied to both models.
        eqbd_path: ?[]const u8,
        /// When set, diff only this one object.
        mrid: ?[]const u8,
        /// Restrict comparison to this CIM type.
        /// With mrid: verifies the object is of this type.
        type_filter: ?[]const u8,
        /// Write output to this file instead of stdout.
        output_path: ?[]const u8,
        /// Output format; flags are validated to be mutually exclusive.
        format: DiffFormat,
    };

    pub const DiffFormat = enum {
        /// IEC 61970-552 difference model XML (the default).
        eqdiff,
        /// Human-readable report modelled after `git diff` (--patch).
        patch,
        /// NDJSON, one object per change (--json).
        json,
        /// Per-type counts only (--summary).
        summary,
    };

    pub const Topology = struct {
        model_inputs: ModelInputs,
        output_path: ?[]const u8,
    };

    pub const Qocdc = struct {
        eq_path: []const u8,
    };

    pub const Validate = struct {
        model_inputs: ModelInputs,
        output_path: ?[]const u8,
        list_skipped: bool,
        rules_count: u32,
        rules_paths: [rules_count_max][]const u8,

        /// Publishers split rules per CGMES profile; one run may validate
        /// against several sets. The bound keeps the Command allocation-free.
        pub const rules_count_max = 16;

        pub fn rules(self: *const Validate) []const []const u8 {
            assert(self.rules_count <= rules_count_max);
            return self.rules_paths[0..self.rules_count];
        }
    };

    pub const Version = struct {
        verbose: bool,
        json: bool,
    };
};

pub const ModelInputs = struct {
    values: [model_set.inputs_count_max]model_set.Input,
    count: u8,

    pub fn slice(self: *const ModelInputs) []const model_set.Input {
        assert(self.count > 0 and self.count <= model_set.inputs_count_max);
        return self.values[0..self.count];
    }
};

/// Parse the command-line arguments passed to the cimd binary.
/// Exits with code 2 on any usage error.
pub fn parse_args(io: std.Io, args: *std.process.Args.Iterator) !Command {
    assert(args.skip()); // skip executable name

    const command_name = args.next() orelse
        print.stderr(io, "subcommand required\n\n" ++ help_main, .{});

    if (std.mem.eql(u8, command_name, "-h") or std.mem.eql(u8, command_name, "--help")) {
        try print.write(io, help_main);
        std.process.exit(0);
    }

    if (std.mem.eql(u8, command_name, "convert")) return parse_convert(io, args);
    if (std.mem.eql(u8, command_name, "browse")) return parse_browse(io, args);
    if (std.mem.eql(u8, command_name, "get")) return parse_get(io, args);
    if (std.mem.eql(u8, command_name, "refs")) return parse_refs(io, args);
    if (std.mem.eql(u8, command_name, "types")) return parse_types(io, args);
    if (std.mem.eql(u8, command_name, "diff")) return parse_diff(io, args);
    if (std.mem.eql(u8, command_name, "topology")) return parse_topology(io, args);
    if (std.mem.eql(u8, command_name, "validate")) return parse_validate(io, args);
    if (std.mem.eql(u8, command_name, "qocdc")) return parse_qocdc(io, args);
    if (std.mem.eql(u8, command_name, "version")) return parse_version(io, args);

    print.stderr(io, "unknown command '{s}'\n\n" ++ help_main, .{command_name});
}

const KindFlag = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    kind: model_set.Kind,
};

const kind_flags = [_]KindFlag{
    .{ .name = "--eq", .kind = .eq },
    .{ .name = "--eqbd", .alias = "-b", .kind = .eqbd },
    .{ .name = "--tp", .kind = .tp },
    .{ .name = "--ssh", .kind = .ssh },
};

const InputBuilder = struct {
    positionals: [model_set.inputs_count_max]model_set.Input = undefined,
    positional_count: u8 = 0,
    flagged: [kind_flags.len]model_set.Input = undefined,
    flagged_count: u8 = 0,
    seen_kind: [kind_flags.len]bool = @splat(false),
    stdin_seen: bool = false,

    fn add_positional(self: *InputBuilder, io: std.Io, comptime command_name: []const u8, path: []const u8) void {
        validate_path(io, path, command_name);
        validate_cgmes_extension(io, path, command_name);
        if (self.positional_count + self.flagged_count >= model_set.inputs_count_max) {
            print.stderr(io, command_name ++ ": too many model inputs (max {d})", .{model_set.inputs_count_max});
        }
        if (io_read.is_stdin(path)) {
            if (self.stdin_seen) print.stderr(io, command_name ++ ": '-' may be used for at most one input", .{});
            self.stdin_seen = true;
        }
        self.positionals[self.positional_count] = .{ .path = path };
        self.positional_count += 1;
    }

    fn add_flagged(
        self: *InputBuilder,
        io: std.Io,
        args: *std.process.Args.Iterator,
        comptime command_name: []const u8,
        comptime flag: []const u8,
        kind: model_set.Kind,
    ) void {
        const kind_index = kind_flag_index(kind);
        if (self.seen_kind[kind_index]) print.stderr(io, command_name ++ ": " ++ flag ++ " may be specified at most once", .{});
        if (self.positional_count + self.flagged_count >= model_set.inputs_count_max) {
            print.stderr(io, command_name ++ ": too many model inputs (max {d})", .{model_set.inputs_count_max});
        }
        const path = take_path_arg(io, args, command_name, flag);
        self.seen_kind[kind_index] = true;
        self.flagged[self.flagged_count] = .{ .path = path, .override = kind };
        self.flagged_count += 1;
    }

    fn kind_seen(self: *const InputBuilder, kind: model_set.Kind) bool {
        return self.seen_kind[kind_flag_index(kind)];
    }

    fn finish(self: *const InputBuilder, io: std.Io, comptime command_name: []const u8) ModelInputs {
        const count = self.positional_count + self.flagged_count;
        if (count == 0) print.stderr(io, command_name ++ ": at least one model input is required", .{});
        var result: ModelInputs = .{ .values = undefined, .count = count };
        @memcpy(result.values[0..self.positional_count], self.positionals[0..self.positional_count]);
        @memcpy(result.values[self.positional_count..count], self.flagged[0..self.flagged_count]);
        return result;
    }
};

fn parse_kind_flag(
    builder: *InputBuilder,
    io: std.Io,
    args: *std.process.Args.Iterator,
    comptime command_name: []const u8,
    arg: []const u8,
) bool {
    inline for (kind_flags) |flag| {
        const matches_name = std.mem.eql(u8, arg, flag.name);
        const matches_alias = if (flag.alias) |alias| std.mem.eql(u8, arg, alias) else false;
        if (matches_name or matches_alias) {
            builder.add_flagged(io, args, command_name, flag.name, flag.kind);
            return true;
        }
    }
    return false;
}

fn kind_flag_index(kind: model_set.Kind) u8 {
    for (kind_flags, 0..) |flag, index| {
        if (flag.kind == kind) return @intCast(index);
    }
    unreachable;
}

fn is_cgmes_operand(arg: []const u8) bool {
    if (io_read.is_stdin(arg)) return true;
    const extension = std.fs.path.extension(arg);
    return std.ascii.eqlIgnoreCase(extension, ".xml") or std.ascii.eqlIgnoreCase(extension, ".zip");
}

fn parse_convert(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const command_name = "convert";

    var inputs: InputBuilder = .{};
    var output_path: ?[]const u8 = null;
    var bus_branch: bool = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.write(io, help_convert);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-t")) {
            inputs.add_flagged(io, args, command_name, "--tp", .tp);
        } else if (std.mem.eql(u8, arg, "-s")) {
            inputs.add_flagged(io, args, command_name, "--ssh", .ssh);
        } else if (parse_kind_flag(&inputs, io, args, command_name, arg)) {
            continue;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = take_output_arg(io, args, command_name);
        } else if (std.mem.eql(u8, arg, "--bus-branch")) {
            bus_branch = true;
        } else if (is_flag(arg)) {
            print.stderr(io, command_name ++ ": unknown option '{s}'", .{arg});
        } else {
            inputs.add_positional(io, command_name, arg);
        }
    }

    return .{ .convert = .{
        .model_inputs = inputs.finish(io, command_name),
        .output_path = output_path,
        .bus_branch = bus_branch,
    } };
}

fn parse_browse(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const command_name = "browse";

    var inputs: InputBuilder = .{};
    var mrid: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.write(io, help_browse);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-t")) {
            inputs.add_flagged(io, args, command_name, "--tp", .tp);
        } else if (std.mem.eql(u8, arg, "-s")) {
            inputs.add_flagged(io, args, command_name, "--ssh", .ssh);
        } else if (parse_kind_flag(&inputs, io, args, command_name, arg)) {
            continue;
        } else if (is_flag(arg)) {
            print.stderr(io, command_name ++ ": unknown option '{s}'", .{arg});
        } else if (is_cgmes_operand(arg)) {
            inputs.add_positional(io, command_name, arg);
        } else if (mrid == null) {
            mrid = arg;
        } else {
            print.stderr(io, command_name ++ ": unexpected argument '{s}'", .{arg});
        }
    }

    if (mrid == null) print.stderr(io, command_name ++ ": <mrid> is required", .{});
    const model_inputs = inputs.finish(io, command_name);
    for (model_inputs.slice()) |input| if (io_read.is_stdin(input.path))
        print.stderr(io, command_name ++ ": '-' cannot be used as input because browse needs stdin for interaction", .{});

    return .{ .browse = .{
        .model_inputs = model_inputs,
        .mrid = mrid.?,
    } };
}

fn parse_get(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const command_name = "get";

    var inputs: InputBuilder = .{};
    var mrid: ?[]const u8 = null;
    var type_filter: ?[]const u8 = null;
    var fields: ?[]const u8 = null;
    var count = false;
    var json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.write(io, help_get);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type")) {
            type_filter = take_value_arg(io, args, command_name, "--type", "a CIM type name");
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--fields")) {
            fields = take_value_arg(io, args, command_name, "--fields", "a comma-separated list of property names");
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            count = true;
        } else if (parse_kind_flag(&inputs, io, args, command_name, arg)) {
            continue;
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (is_flag(arg)) {
            print.stderr(io, command_name ++ ": unknown option '{s}'", .{arg});
        } else if (is_cgmes_operand(arg)) {
            inputs.add_positional(io, command_name, arg);
        } else if (mrid == null) {
            mrid = arg;
        } else {
            print.stderr(io, command_name ++ ": unexpected argument '{s}'", .{arg});
        }
    }

    if (mrid == null and type_filter == null) print.stderr(io, command_name ++ ": <mrid> or --type is required", .{});
    if (count and mrid != null) print.stderr(io, command_name ++ ": --count takes no value; '{s}' was parsed as <mrid> (use --type without <mrid> for list mode)", .{mrid.?});

    return .{ .get = .{
        .model_inputs = inputs.finish(io, command_name),
        .mrid = mrid,
        .type_filter = type_filter,
        .fields = fields,
        .count = count,
        .json = json,
    } };
}

fn parse_refs(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const command_name = "refs";

    var inputs: InputBuilder = .{};
    var mrid: ?[]const u8 = null;
    var target_type: ?[]const u8 = null;
    var from_type: ?[]const u8 = null;
    var json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.write(io, help_refs);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type")) {
            target_type = take_value_arg(io, args, command_name, "--type", "a CIM type name");
        } else if (std.mem.eql(u8, arg, "--from")) {
            from_type = take_value_arg(io, args, command_name, "--from", "a CIM type name");
        } else if (parse_kind_flag(&inputs, io, args, command_name, arg)) {
            continue;
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (is_flag(arg)) {
            print.stderr(io, command_name ++ ": unknown option '{s}'", .{arg});
        } else if (is_cgmes_operand(arg)) {
            inputs.add_positional(io, command_name, arg);
        } else if (mrid == null) {
            mrid = arg;
        } else {
            print.stderr(io, command_name ++ ": unexpected argument '{s}'", .{arg});
        }
    }

    if (mrid == null) print.stderr(io, command_name ++ ": <mrid> is required", .{});

    return .{ .refs = .{
        .model_inputs = inputs.finish(io, command_name),
        .mrid = mrid.?,
        .target_type = target_type,
        .from_type = from_type,
        .json = json,
    } };
}

fn parse_types(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const command_name = "types";

    var inputs: InputBuilder = .{};
    var json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.write(io, help_types);
            std.process.exit(0);
        }
        if (parse_kind_flag(&inputs, io, args, command_name, arg)) {
            continue;
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (is_flag(arg)) {
            print.stderr(io, command_name ++ ": unknown option '{s}'", .{arg});
        } else {
            inputs.add_positional(io, command_name, arg);
        }
    }

    return .{ .types = .{
        .model_inputs = inputs.finish(io, command_name),
        .json = json,
    } };
}

fn parse_diff(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const command_name = "diff";

    var sides: [2]model_set.Input = undefined;
    var sides_count: u8 = 0;
    var eqbd_path: ?[]const u8 = null;
    var mrid: ?[]const u8 = null;
    var type_filter: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var patch = false;
    var summary = false;
    var json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.write(io, help_diff);
            std.process.exit(0);
        }
        if (parse_diff_side(io, args, arg, &sides, &sides_count)) {
            // Side routed by an explicit profile flag.
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--eqbd")) {
            if (eqbd_path != null) print.stderr(io, command_name ++ ": --eqbd may be specified at most once", .{});
            eqbd_path = take_path_arg(io, args, command_name, "--eqbd");
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--mrid")) {
            mrid = take_value_arg(io, args, command_name, "--mrid", "an mRID value");
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type")) {
            type_filter = take_value_arg(io, args, command_name, "--type", "a CIM type name");
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = take_output_arg(io, args, command_name);
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch")) {
            patch = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (is_flag(arg)) {
            print.stderr(io, command_name ++ ": unknown option '{s}'", .{arg});
        } else {
            if (sides_count >= sides.len) print.stderr(io, command_name ++ ": exactly two side operands are required", .{});
            validate_path(io, arg, command_name);
            validate_cgmes_extension(io, arg, command_name);
            sides[sides_count] = .{ .path = arg };
            sides_count += 1;
        }
    }

    const format = validate_diff_options(io, sides, sides_count, patch, summary, json);

    return .{ .diff = .{
        .sides = sides,
        .eqbd_path = eqbd_path,
        .mrid = mrid,
        .type_filter = type_filter,
        .output_path = output_path,
        .format = format,
    } };
}

/// Side-routing flags for `diff`: each names the profile a side operand should
/// be read as, for parts whose FullModel declares none (or none we recognize).
/// `--eqbd` is deliberately absent -- on `diff` that flag names the boundary
/// shared by both sides, not a side.
const diff_side_flags = [_]KindFlag{
    .{ .name = "--eq", .kind = .eq },
    .{ .name = "--ssh", .kind = .ssh },
    .{ .name = "--tp", .kind = .tp },
    .{ .name = "--tpbd", .kind = .tpbd },
    .{ .name = "--sv", .kind = .sv },
    .{ .name = "--dl", .kind = .dl },
    .{ .name = "--dy", .kind = .dy },
    .{ .name = "--gl", .kind = .gl },
};

/// Consume `arg` as a side-routing flag and its path, returning false when it
/// is not one. Sides fill in argv order, so a flagged side takes the position
/// it appears in: `diff a.xml --ssh b.xml` diffs a.xml (left) against b.xml.
fn parse_diff_side(
    io: std.Io,
    args: *std.process.Args.Iterator,
    arg: []const u8,
    sides: *[2]model_set.Input,
    sides_count: *u8,
) bool {
    inline for (diff_side_flags) |flag| {
        if (std.mem.eql(u8, arg, flag.name)) {
            if (sides_count.* >= sides.len) {
                print.stderr(io, "diff: exactly two side operands are required", .{});
            }
            sides[sides_count.*] = .{
                .path = take_path_arg(io, args, "diff", flag.name),
                .override = flag.kind,
            };
            sides_count.* += 1;
            return true;
        }
    }
    return false;
}

test "every profile kind but the boundary can route a diff side" {
    inline for (@typeInfo(model_set.Kind).@"enum".fields) |field| {
        const kind: model_set.Kind = @enumFromInt(field.value);
        var found = false;
        for (diff_side_flags) |flag| {
            if (flag.kind == kind) found = true;
        }
        try std.testing.expectEqual(kind != .eqbd, found);
    }
}

fn validate_diff_options(
    io: std.Io,
    sides: [2]model_set.Input,
    sides_count: u8,
    patch: bool,
    summary: bool,
    json: bool,
) Command.DiffFormat {
    if (sides_count != 2) print.stderr(io, "diff: exactly two side operands are required", .{});
    if (io_read.is_stdin(sides[0].path) and io_read.is_stdin(sides[1].path)) {
        print.stderr(io, "diff: '-' cannot be used for both <file1> and <file2>; stdin provides only one stream", .{});
    }
    const format_flags = @as(u8, @intFromBool(patch)) +
        @as(u8, @intFromBool(summary)) +
        @as(u8, @intFromBool(json));
    if (format_flags > 1) {
        print.stderr(io, "diff: --patch, --summary, and --json are mutually exclusive", .{});
    }
    return if (patch) .patch else if (summary) .summary else if (json) .json else .eqdiff;
}

fn parse_topology(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const command_name = "topology";

    var inputs: InputBuilder = .{};
    var output_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.write(io, help_topology);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-s")) {
            inputs.add_flagged(io, args, command_name, "--ssh", .ssh);
        } else if (parse_kind_flag(&inputs, io, args, command_name, arg)) {
            continue;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = take_output_arg(io, args, command_name);
        } else if (is_flag(arg)) {
            print.stderr(io, command_name ++ ": unknown option '{s}'", .{arg});
        } else {
            inputs.add_positional(io, command_name, arg);
        }
    }

    return .{ .topology = .{
        .model_inputs = inputs.finish(io, command_name),
        .output_path = output_path,
    } };
}

fn parse_validate(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const command_name = "validate";

    var inputs: InputBuilder = .{};
    var output_path: ?[]const u8 = null;
    var list_skipped = false;
    var rules_count: u32 = 0;
    var rules_paths: [Command.Validate.rules_count_max][]const u8 = undefined;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.write(io, help_validate);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--rules")) {
            const path = take_value_arg(
                io,
                args,
                command_name,
                "--rules",
                "a file path (prefix a leading '-' with './')",
            );
            validate_path(io, path, command_name);
            validate_rules_extension(io, path, command_name);
            if (rules_count >= Command.Validate.rules_count_max) {
                print.stderr(io, command_name ++ ": too many --rules (max {d})", .{
                    Command.Validate.rules_count_max,
                });
            }
            rules_paths[rules_count] = path;
            rules_count += 1;
        } else if (parse_kind_flag(&inputs, io, args, command_name, arg)) {
            continue;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = take_output_arg(io, args, command_name);
        } else if (std.mem.eql(u8, arg, "--list-skipped")) {
            list_skipped = true;
        } else if (is_flag(arg)) {
            print.stderr(io, command_name ++ ": unknown option '{s}'", .{arg});
        } else {
            inputs.add_positional(io, command_name, arg);
        }
    }

    if (rules_count == 0) print.stderr(io, command_name ++ ": at least one --rules <ttl|zip> is required", .{});
    if (inputs.positional_count == 0 and inputs.kind_seen(.eqbd) and !inputs.kind_seen(.eq)) {
        print.stderr(io, command_name ++ ": --eqbd without a positional merge target requires --eq", .{});
    }

    return .{ .validate = .{
        .model_inputs = inputs.finish(io, command_name),
        .output_path = output_path,
        .list_skipped = list_skipped,
        .rules_count = rules_count,
        .rules_paths = rules_paths,
    } };
}

fn parse_qocdc(io: std.Io, args: *std.process.Args.Iterator) !Command {
    const command_name = "qocdc";

    var eq_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.write(io, help_qocdc);
            std.process.exit(0);
        }
        if (is_flag(arg)) {
            print.stderr(io, command_name ++ ": unknown option '{s}'", .{arg});
        } else {
            if (eq_path != null) print.stderr(io, command_name ++ ": unexpected argument '{s}'", .{arg});
            validate_path(io, arg, command_name);
            if (io_read.is_stdin(arg)) {
                print.stderr(io, command_name ++ ": '-' is not supported; qocdc requires a ZIP file path", .{});
            }
            eq_path = arg;
        }
    }

    if (eq_path == null) print.stderr(io, command_name ++ ": <file> is required", .{});

    return .{ .qocdc = .{ .eq_path = eq_path.? } };
}
fn parse_version(io: std.Io, args: *std.process.Args.Iterator) !Command {
    var verbose = false;
    var json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try print.write(io, help_version);
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

/// Consume the next argument as a path value for a flag like --eqbd, validating it.
/// Exits with a usage error if the argument is missing or invalid.
fn take_path_arg(
    io: std.Io,
    args: *std.process.Args.Iterator,
    comptime command_name: []const u8,
    comptime flag: []const u8,
) []const u8 {
    const path = args.next() orelse
        print.stderr(io, command_name ++ ": " ++ flag ++ " requires a file path", .{});
    if (io_read.is_stdin(path)) {
        print.stderr(
            io,
            command_name ++ ": " ++ flag ++ " does not accept '-'; only the primary input can read stdin",
            .{},
        );
    }
    if (is_flag(path)) {
        print.stderr(
            io,
            command_name ++ ": " ++ flag ++ " path '{s}' starts with '-'; prefix it with './' if it is a filename",
            .{path},
        );
    }
    validate_path(io, path, command_name);
    validate_cgmes_extension(io, path, command_name);
    return path;
}

fn take_value_arg(
    io: std.Io,
    args: *std.process.Args.Iterator,
    comptime command_name: []const u8,
    comptime flag: []const u8,
    comptime description: []const u8,
) []const u8 {
    const value = args.next() orelse
        print.stderr(io, command_name ++ ": " ++ flag ++ " requires " ++ description, .{});
    if (value.len == 0 or value[0] == '-') {
        print.stderr(
            io,
            command_name ++ ": " ++ flag ++ " got option-like value '{s}', expected " ++ description,
            .{value},
        );
    }
    return value;
}

fn take_output_arg(
    io: std.Io,
    args: *std.process.Args.Iterator,
    comptime command_name: []const u8,
) []const u8 {
    const path = args.next() orelse
        print.stderr(io, command_name ++ ": --output requires a file path", .{});
    if (is_flag(path)) {
        print.stderr(
            io,
            command_name ++ ": --output path '{s}' starts with '-'; prefix it with './' if it is a filename",
            .{path},
        );
    }
    validate_path(io, path, command_name);
    return path;
}

inline fn is_flag(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

fn validate_path(io: std.Io, path: []const u8, comptime command_name: []const u8) void {
    if (path.len == 0) print.stderr(io, command_name ++ ": path cannot be empty", .{});
    if (path.len > std.fs.max_path_bytes) {
        print.stderr(io, command_name ++ ": path too long ({d} bytes, max {d})", .{
            path.len, std.fs.max_path_bytes,
        });
    }
}

fn validate_cgmes_extension(io: std.Io, path: []const u8, comptime command_name: []const u8) void {
    if (io_read.is_stdin(path)) return;
    if (path.len < 4) print.stderr(io, command_name ++ ": file must be .xml or .zip (got '{s}')", .{path});
    const ext = std.fs.path.extension(path);
    if (!std.ascii.eqlIgnoreCase(ext, ".xml") and !std.ascii.eqlIgnoreCase(ext, ".zip")) {
        print.stderr(io, command_name ++ ": file must be .xml or .zip (got '{s}')", .{path});
    }
}

test "bare stdin token is positional, not a flag" {
    try std.testing.expect(!is_flag(io_read.stdin_token));
    try std.testing.expect(is_flag("--json"));
}

fn validate_rules_extension(io: std.Io, path: []const u8, comptime command_name: []const u8) void {
    if (path.len < 4) print.stderr(io, command_name ++ ": rules file must be .ttl or .zip (got '{s}')", .{path});
    const ext = std.fs.path.extension(path);
    if (!std.ascii.eqlIgnoreCase(ext, ".ttl") and !std.ascii.eqlIgnoreCase(ext, ".zip")) {
        print.stderr(io, command_name ++ ": rules file must be .ttl or .zip (got '{s}')", .{path});
    }
}
