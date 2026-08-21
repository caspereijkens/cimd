//! Model-set assembly between argv inputs and the model types: a primary
//! CimDocument plus the CGMES TP/SSH overlays. Extraction and header classification are eager; DocumentSet model
//! parsing is deliberately lazy.

const std = @import("std");
const cim = @import("cim/cim.zig");
const io_read = @import("io/read.zig");
const print = @import("io/print.zig");
const profile = cim.profile;
// `_mod` suffix: local `diagnostics` variables would shadow it.
const diagnostics_mod = cim.diagnostics;
const CimDocument = cim.CimDocument;
const Overlay = cim.Overlay;
const validate = @import("validate.zig");

const assert = std.debug.assert;

pub const Kind = profile.Kind;
pub const inputs_count_max = 8;
pub const parts_count_max = inputs_count_max * io_read.parts_per_input_max;
comptime {
    assert(parts_count_max == 128);
}

pub const Input = struct {
    path: []const u8,
    override: ?Kind = null,
};

pub const Purpose = enum { convert, topology, query, diff_side };
pub const BoundaryMerge = enum { never, single_pair };

pub const Source = struct {
    input_path: []const u8,
    zip_entry: ?[]const u8,
    owned_label: []u8,

    fn init(owned_label: []u8, input_path: []const u8) Source {
        assert(owned_label.len >= input_path.len);
        assert(std.mem.eql(u8, owned_label[0..input_path.len], input_path));
        const entry = if (owned_label.len == input_path.len)
            null
        else blk: {
            assert(owned_label[input_path.len] == '!');
            break :blk owned_label[input_path.len + 1 ..];
        };
        return .{ .input_path = owned_label[0..input_path.len], .zip_entry = entry, .owned_label = owned_label };
    }

    pub fn label(self: Source) []const u8 {
        return self.owned_label;
    }

    fn deinit(self: *Source, gpa: std.mem.Allocator) void {
        gpa.free(self.owned_label);
        self.* = undefined;
    }
};

pub const LoadedOverlay = struct { overlay: Overlay, source: Source };

pub const MergedModelSet = struct {
    model: CimDocument,
    segments: [2]validate.DataSegment,
    segments_count: u8,
    tp: ?LoadedOverlay,
    ssh: ?LoadedOverlay,
    primary_source: Source,
    boundary_source: ?Source,
    /// Profile the primary part declared (or was routed to), or null when it
    /// states none. `diff` uses it to reject comparing two different profiles;
    /// commands whose primary is EQ by construction can ignore it.
    primary_kind: ?Kind,

    pub fn deinit(self: *MergedModelSet, gpa: std.mem.Allocator) void {
        if (self.ssh) |*loaded| {
            loaded.overlay.deinit(gpa);
            loaded.source.deinit(gpa);
        }
        if (self.tp) |*loaded| {
            loaded.overlay.deinit(gpa);
            loaded.source.deinit(gpa);
        }
        self.model.deinit(gpa);
        if (self.boundary_source) |*source| source.deinit(gpa);
        self.primary_source.deinit(gpa);
    }
};

const HeaderState = union(enum) {
    header: profile.Header,
    no_full_model,
};

const PartRecord = struct {
    part: io_read.Part,
    header: HeaderState,
    route: ?Kind,
    input_index: u8,
    owned: bool = true,

    fn take(self: *PartRecord) io_read.Part {
        assert(self.owned);
        self.owned = false;
        return self.part;
    }

    fn deinit(self: *PartRecord, gpa: std.mem.Allocator) void {
        if (self.owned) self.part.deinit(gpa);
        self.owned = false;
    }
};

const Collected = struct {
    records: std.ArrayList(PartRecord),
    input_part_counts: [inputs_count_max]u8,

    fn deinit(self: *Collected, gpa: std.mem.Allocator) void {
        for (self.records.items) |*record| record.deinit(gpa);
        self.records.deinit(gpa);
    }
};

fn collect_parts(
    io: std.Io,
    gpa: std.mem.Allocator,
    command_name: []const u8,
    inputs: []const Input,
) !Collected {
    assert(inputs.len > 0);
    assert(inputs.len <= inputs_count_max);
    var result: Collected = .{ .records = .empty, .input_part_counts = @splat(0) };
    errdefer result.deinit(gpa);

    var total_bytes: u64 = 0;
    for (inputs, 0..) |input, input_index| {
        const remaining = io_read.max_in_memory_input_bytes - total_bytes;
        const parts = io_read.read_parts(io, gpa, input.path, remaining) catch |err|
            input_error(io, command_name, input.path, err);
        defer gpa.free(parts);
        errdefer for (parts) |part| part.deinit(gpa);
        validate_part_count(
            io,
            command_name,
            input,
            @intCast(result.records.items.len),
            @intCast(parts.len),
        );
        result.input_part_counts[input_index] = @intCast(parts.len);

        for (parts) |*part| {
            total_bytes += @intCast(part.xml.len);
            assert(total_bytes <= io_read.max_in_memory_input_bytes);
            const header = try classify_part(io, gpa, command_name, part.*);
            const route = route_part(io, command_name, input.override, part.name, header);
            try result.records.append(gpa, .{
                .part = part.*,
                .header = header,
                .route = route,
                .input_index = @intCast(input_index),
            });
            part.name = &.{};
            part.xml = &.{};
        }
    }
    assert(result.records.items.len <= parts_count_max);
    return result;
}

fn validate_part_count(
    io: std.Io,
    command_name: []const u8,
    input: Input,
    collected_count: u32,
    input_count: u32,
) void {
    if (input.override != null and input_count != 1) print.data_error(
        io,
        "{s}: explicitly-kinded input '{s}' contains {d} XML parts; exactly one is required",
        .{ command_name, input.path, input_count },
    );
    if (collected_count + input_count > parts_count_max) {
        print.data_error(io, "{s}: too many XML parts (max {d})", .{ command_name, parts_count_max });
    }
}

fn classify_part(
    io: std.Io,
    gpa: std.mem.Allocator,
    command_name: []const u8,
    part: io_read.Part,
) !HeaderState {
    return if (profile.classify(gpa, part.xml)) |value|
        .{ .header = value }
    else |err| switch (err) {
        error.NoFullModel => .no_full_model,
        error.AmbiguousHeader => print.data_error(
            io,
            "{s}: '{s}' has ambiguous FullModel profile metadata",
            .{ command_name, part.name },
        ),
        error.MalformedHeader => print.data_error(
            io,
            "{s}: '{s}' has malformed FullModel metadata",
            .{ command_name, part.name },
        ),
        else => return err,
    };
}

fn route_part(
    io: std.Io,
    command_name: []const u8,
    override: ?Kind,
    name: []const u8,
    header: HeaderState,
) ?Kind {
    const declared: ?Kind = switch (header) {
        .no_full_model => null,
        .header => |h| switch (h.profile) {
            .known => |kind| kind,
            .unknown, .absent => null,
        },
    };
    const explicit = override orelse return declared;
    if (declared) |kind| if (kind != explicit) print.data_error(
        io,
        "{s}: '{s}' declares {s}, contradicting --{s}",
        .{ command_name, name, @tagName(kind), @tagName(explicit) },
    );
    return explicit;
}

fn input_error(io: std.Io, command_name: []const u8, path: []const u8, err: anyerror) noreturn {
    switch (err) {
        error.FileNotFound => print.no_input(io, "{s}: input '{s}' was not found", .{ command_name, path }),
        error.AccessDenied, error.PermissionDenied => print.no_input(io, "{s}: input '{s}' cannot be read: permission denied", .{ command_name, path }),
        error.IsDir => print.no_input(io, "{s}: input '{s}' is a directory, expected a file", .{ command_name, path }),
        error.OutOfMemory => print.system_error(io, "{s}: not enough memory while reading '{s}'", .{ command_name, path }),
        error.FileTooLarge, error.StreamTooLong => print.data_error(io, "{s}: inputs exceed the {d}-byte XML limit", .{ command_name, io_read.max_in_memory_input_bytes }),
        error.ZipArchiveHasNoMatchingFiles => print.data_error(io, "{s}: ZIP input '{s}' contains no XML file", .{ command_name, path }),
        error.ZipTooManyEntries => print.data_error(io, "{s}: ZIP input '{s}' contains too many entries (max {d})", .{ command_name, path, io_read.zip_entries_scanned_max }),
        error.ZipTooManyMatchingFiles => print.data_error(io, "{s}: ZIP input '{s}' contains too many XML parts (max {d})", .{ command_name, path, io_read.parts_per_input_max }),
        error.ZipCrcMismatch => print.data_error(io, "{s}: ZIP input '{s}' contains an XML part with a CRC mismatch", .{ command_name, path }),
        error.ZipSizeMismatch, error.ZipDecompressTruncated, error.EndOfStream => print.data_error(io, "{s}: ZIP input '{s}' is truncated or has an invalid size claim", .{ command_name, path }),
        error.UnsupportedCompressionMethod => print.data_error(io, "{s}: ZIP input '{s}' uses an unsupported compression method", .{ command_name, path }),
        error.ZipBadFilename, error.ZipFilenameHasBackslash => print.data_error(io, "{s}: ZIP input '{s}' contains an unsafe entry name", .{ command_name, path }),
        else => print.data_error(io, "{s}: failed to read input '{s}': {t}", .{ command_name, path, err }),
    }
}

fn fallback_eligible(record: PartRecord) bool {
    return switch (record.header) {
        .no_full_model => true,
        .header => |header| header.profile == .absent,
    };
}

fn unknown_uri(record: PartRecord) ?[]const u8 {
    return switch (record.header) {
        .no_full_model => null,
        .header => |header| switch (header.profile) {
            .unknown => |uri| uri,
            else => null,
        },
    };
}

fn find_input_record(records: []const PartRecord, input_index: u8) ?u32 {
    for (records, 0..) |record, index| {
        if (record.input_index == input_index) return @intCast(index);
    }
    return null;
}

fn source_from_part(part: io_read.Part, input_path: []const u8) Source {
    return Source.init(part.name, input_path);
}

const MaterializedDocument = struct {
    xml: []u8,
    segments: [2]validate.DataSegment,
    segments_count: u8,
};

fn materialize_parts(
    gpa: std.mem.Allocator,
    first: *io_read.Part,
    second: ?*io_read.Part,
) !MaterializedDocument {
    assert(first.xml.len <= io_read.max_in_memory_input_bytes);
    var result = describe_parts(first.*, if (second) |part| part.* else null);
    if (second) |boundary| {
        const combined_len = @as(u64, @intCast(first.xml.len)) + @as(u64, @intCast(boundary.xml.len));
        if (combined_len > io_read.max_in_memory_input_bytes) return error.FileTooLarge;
        result.xml = try std.mem.concat(gpa, u8, &.{ first.xml, boundary.xml });
        assert(result.xml.len == combined_len);
        gpa.free(first.xml);
        gpa.free(boundary.xml);
        boundary.xml = &.{};
    } else {
        result.xml = first.xml;
    }
    first.xml = &.{};
    assert(result.xml.len <= io_read.max_in_memory_input_bytes);
    assert(first.xml.len == 0);
    return result;
}

fn describe_parts(first: io_read.Part, second: ?io_read.Part) MaterializedDocument {
    var result: MaterializedDocument = .{
        .xml = undefined,
        .segments = .{ .{ .name = first.name, .start = 0, .line_start = 1 }, undefined },
        .segments_count = 1,
    };
    if (second) |boundary| {
        result.segments[1] = .{
            .name = boundary.name,
            .start = @intCast(first.xml.len),
            .line_start = diagnostics_mod.line_number_at(first.xml, @intCast(first.xml.len)),
        };
        result.segments_count = 2;
    }
    return result;
}

pub const ParseDiagnostics = struct {
    model: diagnostics_mod.Diagnostics = .{},
    segments: [2]validate.DataSegment = undefined,
    segments_count: u8 = 0,
};

fn parse_eq(
    io: std.Io,
    gpa: std.mem.Allocator,
    command_name: []const u8,
    xml: []u8,
    segments: []const validate.DataSegment,
) CimDocument {
    var diagnostics: diagnostics_mod.Diagnostics = .{};
    return CimDocument.initWithDiagnostics(gpa, xml, &diagnostics) catch |err|
        report_parse_error(io, command_name, segments, err, diagnostics);
}

fn parse_overlay(
    io: std.Io,
    gpa: std.mem.Allocator,
    command_name: []const u8,
    part: io_read.Part,
    source: Source,
    policy: cim.IdPolicy,
) Overlay {
    var diagnostics: diagnostics_mod.Diagnostics = .{};
    const segments = [_]validate.DataSegment{.{ .name = source.label(), .start = 0, .line_start = 1 }};
    return Overlay.initWithDiagnostics(gpa, part.xml, policy, &diagnostics) catch |err|
        report_parse_error(io, command_name, &segments, err, diagnostics);
}

pub fn report_document_parse_error(
    io: std.Io,
    command_name: []const u8,
    err: anyerror,
    diagnostics: ParseDiagnostics,
) noreturn {
    assert(diagnostics.segments_count > 0);
    report_parse_error(
        io,
        command_name,
        diagnostics.segments[0..diagnostics.segments_count],
        err,
        diagnostics.model,
    );
}

fn report_parse_error(
    io: std.Io,
    command_name: []const u8,
    segments: []const validate.DataSegment,
    err: anyerror,
    diagnostics: diagnostics_mod.Diagnostics,
) noreturn {
    assert(segments.len > 0);
    assert(segments.len <= 2);
    if (err == error.DuplicateId and diagnostics.duplicate_id_recorded) {
        const segment = validate.segment_of(segments, diagnostics.duplicate_offset);
        const suffix = if (diagnostics.duplicate_id_truncated) "..." else "";
        print.data_error(io, "{s}: '{s}': duplicate RDF identifier '{s}{s}' at line {d}", .{
            command_name,
            segment.name,
            diagnostics.duplicate_id(),
            suffix,
            validate.segment_local_line(segment, diagnostics.duplicate_line),
        });
    }
    if (err == error.MalformedXML and diagnostics.malformed_xml_recorded) {
        const segment = validate.segment_of(segments, diagnostics.malformed_xml_offset);
        print.data_error(io, "{s}: '{s}': malformed XML at line {d}: tags are unbalanced or not well nested", .{
            command_name,
            segment.name,
            validate.segment_local_line(segment, diagnostics.malformed_xml_line),
        });
    }
    switch (err) {
        error.EmptyInput => parse_detail(io, command_name, segments, "input is empty", .{}),
        error.DuplicateId => parse_detail(io, command_name, segments, "duplicate RDF identifier", .{}),
        error.FileTooLarge, error.StreamTooLong => {
            var limit_buf: [print.size_limit_text_buffer_bytes]u8 = undefined;
            const limit = print.size_limit_text(&limit_buf, null, io_read.max_in_memory_input_bytes);
            parse_detail(io, command_name, segments, "input is too large ({s})", .{limit});
        },
        error.MalformedXML => parse_detail(
            io,
            command_name,
            segments,
            "malformed XML: tags are unbalanced or not well nested",
            .{},
        ),
        error.MalformedTag => parse_detail(io, command_name, segments, "malformed XML tag", .{}),
        error.OutOfMemory => system_parse_detail(io, command_name, segments, "not enough memory while parsing", .{}),
        else => parse_detail(io, command_name, segments, "failed to parse: {t}", .{err}),
    }
}

fn parse_detail(
    io: std.Io,
    command_name: []const u8,
    segments: []const validate.DataSegment,
    comptime format: []const u8,
    args: anytype,
) noreturn {
    formatted_parse_detail(io, print.exit_data_error, command_name, segments, format, args);
}

fn system_parse_detail(
    io: std.Io,
    command_name: []const u8,
    segments: []const validate.DataSegment,
    comptime format: []const u8,
    args: anytype,
) noreturn {
    formatted_parse_detail(io, print.exit_system_error, command_name, segments, format, args);
}

fn formatted_parse_detail(
    io: std.Io,
    exit_code: u8,
    command_name: []const u8,
    segments: []const validate.DataSegment,
    comptime format: []const u8,
    args: anytype,
) noreturn {
    var detail_buffer: [512]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buffer, format, args) catch "(details unavailable)";
    if (segments.len == 2) print.exit_error(io, exit_code, "{s}: '{s}' + '{s}': {s}", .{
        command_name,
        segments[0].name,
        segments[1].name,
        detail,
    });
    print.exit_error(io, exit_code, "{s}: '{s}': {s}", .{ command_name, segments[0].name, detail });
}

pub fn load_merged(
    io: std.Io,
    gpa: std.mem.Allocator,
    command_name: []const u8,
    inputs: []const Input,
    purpose: Purpose,
) !MergedModelSet {
    var collected = try collect_parts(io, gpa, command_name, inputs);
    defer collected.deinit(gpa);
    const records = collected.records.items;
    const slots = build_unique_slots(io, command_name, records);
    const primary = resolve_primary(io, command_name, inputs, &collected, slots, purpose);
    reject_unrouted_supplementaries(io, command_name, records, primary);
    return assemble_merged(io, gpa, command_name, inputs, &collected, slots, primary, purpose);
}

const Slots = [@typeInfo(Kind).@"enum".fields.len]?u32;

fn kind_requires_unique_slot(kind: Kind) bool {
    return switch (kind) {
        .eq, .eqbd, .ssh, .tp => true,
        .tpbd, .sv, .dl, .dy, .gl => false,
    };
}

test "only consumable overlay kinds require unique slots" {
    try std.testing.expect(kind_requires_unique_slot(.eq));
    try std.testing.expect(kind_requires_unique_slot(.eqbd));
    try std.testing.expect(kind_requires_unique_slot(.tp));
    try std.testing.expect(kind_requires_unique_slot(.ssh));
    try std.testing.expect(!kind_requires_unique_slot(.tpbd));
    try std.testing.expect(!kind_requires_unique_slot(.sv));
    try std.testing.expect(!kind_requires_unique_slot(.dl));
    try std.testing.expect(!kind_requires_unique_slot(.dy));
    try std.testing.expect(!kind_requires_unique_slot(.gl));
}

fn build_unique_slots(io: std.Io, command_name: []const u8, records: []const PartRecord) Slots {
    var slots: Slots = @splat(null);
    for (records, 0..) |record, raw_index| if (record.route) |kind| {
        if (!kind_requires_unique_slot(kind)) continue;
        const slot = @intFromEnum(kind);
        const index: u32 = @intCast(raw_index);
        if (slots[slot]) |previous| print.data_error(
            io,
            "{s}: duplicate {s} parts '{s}' and '{s}'",
            .{ command_name, @tagName(kind), records[previous].part.name, record.part.name },
        );
        slots[slot] = index;
    };
    return slots;
}

fn resolve_primary(
    io: std.Io,
    command_name: []const u8,
    inputs: []const Input,
    collected: *const Collected,
    slots: Slots,
    purpose: Purpose,
) u32 {
    const records = collected.records.items;
    var primary_index: ?u32 = null;
    switch (purpose) {
        .convert, .topology => {
            primary_index = slots[@intFromEnum(Kind.eq)];
            if (primary_index == null and inputs[0].override == null and collected.input_part_counts[0] == 1) {
                const candidate = find_input_record(records, 0).?;
                if (fallback_eligible(records[candidate])) primary_index = candidate;
            }
            if (primary_index == null) {
                for (records) |record| if (unknown_uri(record)) |uri| print.data_error(
                    io,
                    "{s}: unknown profile URI '{s}' in '{s}'; use --eq to route it explicitly",
                    .{ command_name, uri, record.part.name },
                );
                print.data_error(io, "{s}: an EQ part is required", .{command_name});
            }
        },
        // A diff side is one document compared against a document of the same
        // profile, and mRID matching plus statement comparison is profile-
        // agnostic: SSH-vs-SSH (switch states, setpoints) and TP-vs-TP are as
        // meaningful as EQ-vs-EQ. So a lone part is the primary whatever it
        // declares. A multi-part bundle still resolves to its EQ part, keeping
        // whole-set diffs on grid data rather than an arbitrary member.
        .diff_side => {
            if (collected.input_part_counts[0] == 1) {
                const candidate = find_input_record(records, 0).?;
                if (records[candidate].route != null or fallback_eligible(records[candidate])) {
                    primary_index = candidate;
                }
            } else {
                primary_index = slots[@intFromEnum(Kind.eq)];
            }
            if (primary_index == null) {
                for (records) |record| if (unknown_uri(record)) |uri| print.data_error(
                    io,
                    "{s}: unknown profile URI '{s}' in '{s}'; use a kind flag to route it explicitly",
                    .{ command_name, uri, record.part.name },
                );
                print.data_error(
                    io,
                    "{s}: side '{s}' has no EQ part; give a single-profile file or route one with a kind flag",
                    .{ command_name, inputs[0].path },
                );
            }
        },
        .query => {
            if (inputs[0].override == null) {
                if (collected.input_part_counts[0] == 1) {
                    primary_index = find_input_record(records, 0).?;
                } else {
                    primary_index = slots[@intFromEnum(Kind.eq)];
                    if (primary_index == null or records[primary_index.?].input_index != 0) {
                        print.data_error(io, "{s}: first bundle input contains no unique EQ primary", .{command_name});
                    }
                }
            } else {
                primary_index = slots[@intFromEnum(Kind.eq)];
                if (primary_index == null) print.data_error(io, "{s}: a positional input or --eq is required as the query primary", .{command_name});
            }
            if (slots[@intFromEnum(Kind.eq)]) |eq_index| if (eq_index != primary_index.?) {
                print.data_error(io, "{s}: '{s}' is a second plausible primary alongside '{s}'", .{
                    command_name, records[eq_index].part.name, records[primary_index.?].part.name,
                });
            };
        },
    }
    return primary_index.?;
}

fn reject_unrouted_supplementaries(
    io: std.Io,
    command_name: []const u8,
    records: []const PartRecord,
    primary: u32,
) void {
    for (records, 0..) |record, i| {
        if (i == primary or record.route != null) continue;
        if (unknown_uri(record)) |uri| print.data_error(io, "{s}: unknown profile URI '{s}' in supplementary part '{s}'", .{ command_name, uri, record.part.name });
        print.data_error(io, "{s}: supplementary part '{s}' has no recognized profile; use a kind flag", .{ command_name, record.part.name });
    }
}

const AssemblySelection = struct {
    eqbd: ?u32,
    tp: ?u32,
    ssh: ?u32,
    consume_tp: bool,
    consume_ssh: bool,
};

fn assemble_merged(
    io: std.Io,
    gpa: std.mem.Allocator,
    command_name: []const u8,
    inputs: []const Input,
    collected: *Collected,
    slots: Slots,
    primary: u32,
    purpose: Purpose,
) !MergedModelSet {
    const records = collected.records.items;
    const selection = assembly_selection(slots, primary, purpose);
    // `diff --eqbd` is a shared boundary for two EQ sides; no other profile has
    // one to resolve against, so merging it in would be nonsense rather than a
    // no-op. Mirrors the plan_documents wording in resolve_merge_target.
    if (purpose == .diff_side and selection.eqbd != null) {
        if (records[primary].route) |kind| if (kind != .eq) print.data_error(
            io,
            "{s}: cannot merge a boundary into {s} part '{s}'",
            .{ command_name, @tagName(kind), records[primary].part.name },
        );
    }
    try skip_unused(io, gpa, command_name, collected, primary, selection);

    var primary_part = collected.records.items[primary].take();
    var boundary_part: ?io_read.Part = if (selection.eqbd) |index|
        collected.records.items[index].take()
    else
        null;
    const materialized = materialize_parts(
        gpa,
        &primary_part,
        if (boundary_part) |*part| part else null,
    ) catch |err| {
        primary_part.deinit(gpa);
        if (boundary_part) |*part| part.deinit(gpa);
        switch (err) {
            error.OutOfMemory => print.system_error(io, "{s}: not enough memory to combine EQ and EQBD inputs", .{command_name}),
            error.FileTooLarge => print.data_error(io, "{s}: combined EQ/EQBD input is too large", .{command_name}),
        }
    };
    const primary_source = source_from_part(primary_part, inputs[records[primary].input_index].path);
    const boundary_source: ?Source = if (boundary_part) |part|
        source_from_part(part, inputs[records[selection.eqbd.?].input_index].path)
    else
        null;
    const model = parse_eq(
        io,
        gpa,
        command_name,
        materialized.xml,
        materialized.segments[0..materialized.segments_count],
    );
    var loaded_tp: ?LoadedOverlay = null;
    if (selection.consume_tp) if (selection.tp) |index| {
        const part = collected.records.items[index].take();
        const source = source_from_part(part, inputs[records[index].input_index].path);
        loaded_tp = .{
            .overlay = parse_overlay(io, gpa, command_name, part, source, .id_declares_object),
            .source = source,
        };
    };
    var loaded_ssh: ?LoadedOverlay = null;
    if (selection.consume_ssh) if (selection.ssh) |index| {
        const part = collected.records.items[index].take();
        const source = source_from_part(part, inputs[records[index].input_index].path);
        loaded_ssh = .{
            .overlay = parse_overlay(io, gpa, command_name, part, source, .id_names_patch),
            .source = source,
        };
    };

    if (purpose == .topology) assert(loaded_tp == null);
    if (purpose == .diff_side) assert(loaded_tp == null);
    if (purpose == .diff_side) assert(loaded_ssh == null);
    return .{
        .model = model,
        .segments = materialized.segments,
        .segments_count = materialized.segments_count,
        .tp = loaded_tp,
        .ssh = loaded_ssh,
        .primary_source = primary_source,
        .boundary_source = boundary_source,
        .primary_kind = records[primary].route,
    };
}

fn assembly_selection(slots: Slots, primary: u32, purpose: Purpose) AssemblySelection {
    var result: AssemblySelection = .{
        .eqbd = slots[@intFromEnum(Kind.eqbd)],
        .tp = slots[@intFromEnum(Kind.tp)],
        .ssh = slots[@intFromEnum(Kind.ssh)],
        .consume_tp = purpose == .convert or purpose == .query,
        .consume_ssh = purpose != .diff_side,
    };
    if (result.eqbd == primary) result.eqbd = null;
    if (result.tp == primary) result.tp = null;
    if (result.ssh == primary) result.ssh = null;
    return result;
}

fn skip_unused(
    io: std.Io,
    gpa: std.mem.Allocator,
    command_name: []const u8,
    collected: *Collected,
    primary: u32,
    selection: AssemblySelection,
) !void {
    var consumed: [parts_count_max]bool = @splat(false);
    consumed[primary] = true;
    if (selection.eqbd) |index| consumed[index] = true;
    if (selection.consume_tp) {
        if (selection.tp) |index| consumed[index] = true;
    }
    if (selection.consume_ssh) {
        if (selection.ssh) |index| consumed[index] = true;
    }
    for (collected.records.items, 0..) |record, index| {
        if (consumed[index]) continue;
        const kind = record.route orelse continue;
        try print.warn(io, "{s}: skipping {s} part '{s}' (not used by this command)\n", .{
            command_name, @tagName(kind), record.part.name,
        });
        collected.records.items[index].deinit(gpa);
    }
}

const PlanState = enum { pending, live, consumed };

const DocumentPlan = struct {
    first: io_read.Part,
    second: ?io_read.Part,
    state: PlanState = .pending,

    fn deinit(self: *DocumentPlan, gpa: std.mem.Allocator) void {
        assert(self.state != .live);
        gpa.free(self.first.name);
        if (self.state == .pending) gpa.free(self.first.xml);
        if (self.second) |second| {
            gpa.free(second.name);
            if (self.state == .pending) gpa.free(second.xml);
        }
        self.* = undefined;
    }
};

pub const LoadedDocument = struct {
    model: CimDocument,
    segments: [2]validate.DataSegment,
    segments_count: u8,
    plan_index: u32,
};

pub const DocumentSet = struct {
    plans: []DocumentPlan,
    next_index: u32 = 0,

    pub fn count(self: *const DocumentSet) u32 {
        return @intCast(self.plans.len);
    }

    pub fn next(
        self: *DocumentSet,
        gpa: std.mem.Allocator,
        diagnostics: *ParseDiagnostics,
    ) !?LoadedDocument {
        for (self.plans) |plan| assert(plan.state != .live);
        const plans_count: u32 = @intCast(self.plans.len);
        while (self.next_index < plans_count and self.plans[self.next_index].state == .consumed) {
            self.next_index += 1;
        }
        if (self.next_index == plans_count) return null;
        const index = self.next_index;
        var plan = &self.plans[index];
        assert(plan.state == .pending);

        diagnostics.* = .{};
        const description = describe_parts(plan.first, plan.second);
        diagnostics.segments = description.segments;
        diagnostics.segments_count = description.segments_count;
        const materialized = try materialize_parts(gpa, &plan.first, if (plan.second) |*part| part else null);

        // CimDocument.init owns `xml` from this point on, including its error paths.
        const model = CimDocument.initWithDiagnostics(gpa, materialized.xml, &diagnostics.model) catch |err| {
            plan.state = .consumed;
            self.next_index += 1;
            return err;
        };
        plan.state = .live;
        return .{
            .model = model,
            .segments = materialized.segments,
            .segments_count = materialized.segments_count,
            .plan_index = index,
        };
    }

    pub fn release(self: *DocumentSet, gpa: std.mem.Allocator, document: *LoadedDocument) void {
        assert(document.plan_index < self.plans.len);
        const plan = &self.plans[document.plan_index];
        assert(plan.state == .live);
        document.model.deinit(gpa);
        plan.state = .consumed;
        if (self.next_index == document.plan_index) self.next_index += 1;
        document.* = undefined;
    }

    pub fn deinit(self: *DocumentSet, gpa: std.mem.Allocator) void {
        for (self.plans) |plan| assert(plan.state != .live);
        for (self.plans) |*plan| plan.deinit(gpa);
        gpa.free(self.plans);
        self.* = undefined;
    }
};

pub fn plan_documents(
    io: std.Io,
    gpa: std.mem.Allocator,
    command_name: []const u8,
    inputs: []const Input,
    boundary_merge: BoundaryMerge,
) !DocumentSet {
    var collected = try collect_parts(io, gpa, command_name, inputs);
    defer collected.deinit(gpa);
    const pair = resolve_merge_pair(io, command_name, inputs, &collected, boundary_merge);
    return build_document_set(gpa, &collected, pair);
}

const MergePair = struct { eq: ?u32 = null, eqbd: ?u32 = null };

fn resolve_merge_pair(
    io: std.Io,
    command_name: []const u8,
    inputs: []const Input,
    collected: *const Collected,
    boundary_merge: BoundaryMerge,
) MergePair {
    if (boundary_merge == .never) return .{};
    const records = collected.records.items;
    var explicit_boundary: ?u32 = null;
    for (records, 0..) |record, raw_index| {
        if (inputs[record.input_index].override != .eqbd) continue;
        assert(explicit_boundary == null);
        explicit_boundary = @intCast(raw_index);
    }
    if (explicit_boundary) |eqbd| {
        return resolve_explicit_pair(io, command_name, inputs, collected, eqbd);
    }
    return resolve_auto_pair(io, command_name, records);
}

fn resolve_explicit_pair(
    io: std.Io,
    command_name: []const u8,
    inputs: []const Input,
    collected: *const Collected,
    eqbd: u32,
) MergePair {
    var target_input: ?u8 = null;
    for (inputs, 0..) |input, raw_index| if (input.override == null) {
        target_input = @intCast(raw_index);
        break;
    };
    if (target_input == null) for (inputs, 0..) |input, raw_index| if (input.override == .eq) {
        target_input = @intCast(raw_index);
        break;
    };
    if (target_input == null) print.data_error(
        io,
        "{s}: explicit --eqbd requires a positional merge target or --eq",
        .{command_name},
    );
    const input_index = target_input.?;
    const eq = resolve_merge_target(io, command_name, collected, input_index);
    return .{ .eq = eq, .eqbd = eqbd };
}

fn resolve_merge_target(
    io: std.Io,
    command_name: []const u8,
    collected: *const Collected,
    input_index: u8,
) u32 {
    const records = collected.records.items;
    if (collected.input_part_counts[input_index] == 1) {
        const index = find_input_record(records, input_index).?;
        const target = records[index];
        if (target.route) |kind| {
            if (kind != .eq) print.data_error(io, "{s}: cannot merge a boundary into {s} part '{s}'", .{ command_name, @tagName(kind), target.part.name });
        } else if (!fallback_eligible(target)) {
            print.data_error(io, "{s}: merge target '{s}' has an unknown profile; use --eq", .{ command_name, target.part.name });
        }
        return index;
    }
    var eq: ?u32 = null;
    for (records, 0..) |record, raw_index| {
        if (record.input_index != input_index or record.route != .eq) continue;
        if (eq != null) print.data_error(io, "{s}: merge target bundle has multiple EQ parts", .{command_name});
        eq = @intCast(raw_index);
    }
    return eq orelse print.data_error(io, "{s}: merge target bundle has no EQ part", .{command_name});
}

fn resolve_auto_pair(io: std.Io, command_name: []const u8, records: []const PartRecord) MergePair {
    var pair: MergePair = .{};
    var eq_count: u8 = 0;
    var eqbd_count: u8 = 0;
    for (records, 0..) |record, raw_index| {
        if (record.route == .eq) {
            eq_count += 1;
            pair.eq = @intCast(raw_index);
        } else if (record.route == .eqbd) {
            eqbd_count += 1;
            pair.eqbd = @intCast(raw_index);
        }
    }
    if ((eq_count > 1 and eqbd_count > 0) or (eqbd_count > 1 and eq_count > 0)) {
        print.data_error(io, "{s}: ambiguous EQ/EQBD pairing across documents", .{command_name});
    }
    if (eq_count != 1 or eqbd_count != 1) return .{};
    return pair;
}

fn build_document_set(gpa: std.mem.Allocator, collected: *Collected, pair: MergePair) !DocumentSet {
    const records_count: u32 = @intCast(collected.records.items.len);
    const plans_count = records_count - @as(u32, @intFromBool(pair.eqbd != null));
    const plans = try gpa.alloc(DocumentPlan, plans_count);
    errdefer gpa.free(plans);
    var plan_count: u32 = 0;
    errdefer for (plans[0..plan_count]) |*plan| plan.deinit(gpa);
    for (collected.records.items, 0..) |_, raw_index| {
        const index: u32 = @intCast(raw_index);
        if (pair.eqbd == index) continue;
        const first = collected.records.items[index].take();
        var second: ?io_read.Part = null;
        if (pair.eq == index) second = collected.records.items[pair.eqbd.?].take();
        plans[plan_count] = .{ .first = first, .second = second };
        plan_count += 1;
    }
    assert(plan_count == plans_count);
    return .{ .plans = plans };
}

test "DocumentSet parse failure transfers buffer ownership exactly once" {
    const gpa = std.testing.allocator;
    const plans = try gpa.alloc(DocumentPlan, 1);
    plans[0] = .{
        .first = .{
            .name = try gpa.dupe(u8, "bad.xml"),
            .xml = try gpa.dupe(u8, ""),
        },
        .second = null,
    };
    var set: DocumentSet = .{ .plans = plans };
    defer set.deinit(gpa);
    var diagnostics: ParseDiagnostics = .{};
    try std.testing.expectError(error.EmptyInput, set.next(gpa, &diagnostics));
    try std.testing.expectEqual(@as(u8, 1), diagnostics.segments_count);
    try std.testing.expectEqualStrings("bad.xml", diagnostics.segments[0].name);
}

test "DocumentSet releases a merged plan and cleans an unconsumed plan" {
    const gpa = std.testing.allocator;
    const plans = try gpa.alloc(DocumentPlan, 2);
    plans[0] = .{
        .first = .{
            .name = try gpa.dupe(u8, "eq.xml"),
            .xml = try gpa.dupe(u8, "<rdf:RDF></rdf:RDF>\n"),
        },
        .second = .{
            .name = try gpa.dupe(u8, "eqbd.xml"),
            .xml = try gpa.dupe(u8, "<rdf:RDF></rdf:RDF>"),
        },
    };
    plans[1] = .{
        .first = .{
            .name = try gpa.dupe(u8, "pending.xml"),
            .xml = try gpa.dupe(u8, "<rdf:RDF></rdf:RDF>"),
        },
        .second = null,
    };
    var set: DocumentSet = .{ .plans = plans };
    defer set.deinit(gpa);
    var diagnostics: ParseDiagnostics = .{};
    var document = (try set.next(gpa, &diagnostics)).?;
    try std.testing.expectEqual(@as(u8, 2), document.segments_count);
    try std.testing.expectEqualStrings("eqbd.xml", document.segments[1].name);
    set.release(gpa, &document);
}

test "DocumentSet concat failure preserves pending plan ownership" {
    const gpa = std.testing.allocator;
    const plans = try gpa.alloc(DocumentPlan, 1);
    plans[0] = .{
        .first = .{
            .name = try gpa.dupe(u8, "eq.xml"),
            .xml = try gpa.dupe(u8, "<rdf:RDF></rdf:RDF>\n"),
        },
        .second = .{
            .name = try gpa.dupe(u8, "eqbd.xml"),
            .xml = try gpa.dupe(u8, "<rdf:RDF></rdf:RDF>"),
        },
    };
    var set: DocumentSet = .{ .plans = plans };
    defer set.deinit(gpa);
    const first_xml = plans[0].first.xml.ptr;
    const second_xml = plans[0].second.?.xml.ptr;
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var diagnostics: ParseDiagnostics = .{};
    try std.testing.expectError(error.OutOfMemory, set.next(failing.allocator(), &diagnostics));
    try std.testing.expectEqual(PlanState.pending, plans[0].state);
    try std.testing.expectEqual(first_xml, plans[0].first.xml.ptr);
    try std.testing.expectEqual(second_xml, plans[0].second.?.xml.ptr);
    try std.testing.expectEqualStrings("eqbd.xml", diagnostics.segments[1].name);
}

test "materialize_parts derives boundary-local segment metadata" {
    const gpa = std.testing.allocator;
    const first_xml = "<rdf:RDF>\n<object/>\n</rdf:RDF>\n";
    var first: io_read.Part = .{
        .name = try gpa.dupe(u8, "eq.xml"),
        .xml = try gpa.dupe(u8, first_xml),
    };
    defer gpa.free(first.name);
    var second: io_read.Part = .{
        .name = try gpa.dupe(u8, "eqbd.xml"),
        .xml = try gpa.dupe(u8, "<rdf:RDF></rdf:RDF>"),
    };
    defer gpa.free(second.name);
    const materialized = try materialize_parts(gpa, &first, &second);
    defer gpa.free(materialized.xml);
    try std.testing.expectEqual(@as(u8, 2), materialized.segments_count);
    try std.testing.expectEqual(@as(u32, first_xml.len), materialized.segments[1].start);
    try std.testing.expectEqual(@as(u64, 4), materialized.segments[1].line_start);
    try std.testing.expectEqualStrings("eqbd.xml", materialized.segments[1].name);
}

test "DocumentSet duplicate diagnostics resolve to a boundary-local line" {
    const gpa = std.testing.allocator;
    const plans = try gpa.alloc(DocumentPlan, 1);
    plans[0] = .{
        .first = .{
            .name = try gpa.dupe(u8, "eq.xml"),
            .xml = try gpa.dupe(u8, "<rdf:RDF>\n</rdf:RDF>\n"),
        },
        .second = .{
            .name = try gpa.dupe(u8, "eqbd.xml"),
            .xml = try gpa.dupe(u8, "<rdf:RDF>\n<cim:X rdf:ID=\"_DUP\"/>\n" ++
                "<cim:X rdf:ID=\"_DUP\"/>\n</rdf:RDF>"),
        },
    };
    var set: DocumentSet = .{ .plans = plans };
    defer set.deinit(gpa);
    var diagnostics: ParseDiagnostics = .{};
    try std.testing.expectError(error.DuplicateId, set.next(gpa, &diagnostics));
    try std.testing.expect(diagnostics.model.duplicate_id_recorded);
    try std.testing.expectEqualStrings("_DUP", diagnostics.model.duplicate_id());
    const segment = validate.segment_of(
        diagnostics.segments[0..diagnostics.segments_count],
        diagnostics.model.duplicate_offset,
    );
    try std.testing.expectEqualStrings("eqbd.xml", segment.name);
    try std.testing.expectEqual(
        @as(u64, 3),
        validate.segment_local_line(segment, diagnostics.model.duplicate_line),
    );
}

test "DocumentSet malformed XML diagnostics resolve to a boundary-local line" {
    const gpa = std.testing.allocator;
    const plans = try gpa.alloc(DocumentPlan, 1);
    plans[0] = .{
        .first = .{
            .name = try gpa.dupe(u8, "eq.xml"),
            .xml = try gpa.dupe(u8, "<rdf:RDF>\n</rdf:RDF>\n"),
        },
        .second = .{
            .name = try gpa.dupe(u8, "eqbd.xml"),
            .xml = try gpa.dupe(u8, "<rdf:RDF>\n<cim:X>\n</cim:Y>\n</rdf:RDF>"),
        },
    };
    var set: DocumentSet = .{ .plans = plans };
    defer set.deinit(gpa);
    var diagnostics: ParseDiagnostics = .{};
    try std.testing.expectError(error.MalformedXML, set.next(gpa, &diagnostics));
    try std.testing.expect(diagnostics.model.malformed_xml_recorded);
    const segment = validate.segment_of(
        diagnostics.segments[0..diagnostics.segments_count],
        diagnostics.model.malformed_xml_offset,
    );
    try std.testing.expectEqualStrings("eqbd.xml", segment.name);
    try std.testing.expectEqual(
        @as(u64, 3),
        validate.segment_local_line(segment, diagnostics.model.malformed_xml_line),
    );
}
