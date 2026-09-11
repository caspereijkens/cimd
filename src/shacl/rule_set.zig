const std = @import("std");
const assert = std.debug.assert;
const turtle = @import("turtle.zig");
const units = @import("../units.zig");

pub const rules_bytes_max = 64 * units.mebibyte;

pub const triples_count_max = 1 << 22;

pub const shapes_count_max = 65_536;

pub const constraints_count_max = 1 << 20;

pub const closed_paths_count_max = 1 << 20;

pub const message_bytes_max = 4096;

pub const substitutions_count_max = 256;

pub const RuleSet = struct {
    source: []const u8,
    strings: []const u8,
    source_name: []const u8,
    version: []const u8,

    shapes: []const Shape,
    class_targeted_count: u32,
    constraints: []const Constraint,
    in_values: []const []const u8,
    closed_paths: []const []const u8,

    class_index: std.StringHashMap(Range),
    unsupported: []const UnsupportedRule,

    pub const Range = struct { start: u32, len: u32 };

    pub const Shape = struct {
        name: []const u8,
        target: Target,
        constraints: Range,
        closed_paths: ?Range,
        message: []const u8,
        severity: Severity,
    };

    pub const Target = union(enum) {
        class: []const u8,
        node: []const u8,
        subjects_of: []const u8,
    };

    pub const Severity = enum(u8) { violation, warning, info };

    pub const Constraint = struct {
        path: []const u8,
        path_kind: PathKind,
        name: []const u8,
        message: []const u8,
        severity: Severity,
        check: Check,
    };

    pub const PathKind = enum(u8) {
        direct,
        own_type,
        ref_type,
        inverse,
    };

    pub const Check = union(enum) {
        min_count: u32,
        max_count: u32,
        datatype: Datatype,
        node_kind: NodeKind,
        min_inclusive: f64,
        max_inclusive: f64,
        min_exclusive: f64,
        max_exclusive: f64,
        in: Range,
        class: []const u8,
        has_value: []const u8,
        min_length: u32,
        max_length: u32,
    };

    pub const Datatype = enum(u8) {
        float,
        double,
        decimal,
        integer,
        boolean,
        string,
        date_time,
        date,
        time,
        duration,
        any_uri,
        g_month_day,
    };

    pub const NodeKind = enum(u8) { iri, literal };

    pub const UnsupportedRule = struct {
        name: []const u8,
        component: []const u8,
    };

    pub const LoadError = error{
        RuleSetTooLarge,
        TooManyTriples,
        TooManyShapes,
        TooManyConstraints,
        TooManyClosedPaths,
        TooManyListValues,
        MessageTooLong,
        MalformedList,
        OutOfMemory,
    } || turtle.Error;

    pub const Diagnostics = struct { line: u32 = 0 };

    pub const Substitution = struct { name: []const u8, value: []const u8 };

    pub fn load(
        gpa: std.mem.Allocator,
        source: []const u8,
        source_name: []const u8,
        substitutions: []const Substitution,
        diagnostics: ?*Diagnostics,
    ) LoadError!RuleSet {
        if (source.len > rules_bytes_max) return error.RuleSetTooLarge;
        assert(substitutions.len <= substitutions_count_max);
        for (substitutions) |substitution| {
            assert(substitution.name.len > 0); // an empty name matches everywhere
            assert(std.mem.indexOfScalar(u8, substitution.name, '\\') == null);
            assert(substitution.value.len <= message_bytes_max);
        }

        var table = try build_table(gpa, source, source_name, diagnostics);
        defer table.deinit(gpa);

        var counter = try Emitter.init(gpa, &table, substitutions, diagnostics);
        defer counter.deinit();
        try scan_all(&counter);
        try counter.check_limits();

        var filler = try Emitter.init(gpa, &table, substitutions, diagnostics);
        defer filler.deinit();
        errdefer filler.free_output();
        try filler.begin_fill(&counter);
        try scan_all(&filler);
        filler.assert_fill_complete(&counter);

        var version = find_version(&table);
        const strings = try finalize_strings(gpa, &filler.output, &version, substitutions);

        return .{
            .source = source,
            .strings = strings,
            .source_name = source_name,
            .version = version,
            .shapes = filler.output.shapes,
            .class_targeted_count = filler.class_total,
            .constraints = filler.output.constraints,
            .in_values = filler.output.in_values,
            .closed_paths = filler.output.closed_paths,
            .class_index = filler.take_class_index(),
            .unsupported = filler.output.unsupported,
        };
    }

    pub fn deinit(self: *RuleSet, gpa: std.mem.Allocator) void {
        self.class_index.deinit();
        gpa.free(self.unsupported);
        gpa.free(self.closed_paths);
        gpa.free(self.in_values);
        gpa.free(self.constraints);
        gpa.free(self.shapes);
        gpa.free(self.strings);
    }

    pub fn in_values_of(self: *const RuleSet, constraint: Constraint) []const []const u8 {
        const range = switch (constraint.check) {
            .in => |r| r,
            else => return &.{},
        };
        assert(range.start + range.len <= self.in_values.len);
        return self.in_values[range.start .. range.start + range.len];
    }

    pub fn closed_paths_of(self: *const RuleSet, shape: Shape) []const []const u8 {
        const range = shape.closed_paths orelse return &.{};
        assert(range.start + range.len <= self.closed_paths.len);
        return self.closed_paths[range.start .. range.start + range.len];
    }
};

const Predicate = enum(u8) {
    rdf_type,
    rdf_first,
    rdf_rest,
    owl_version_info,
    sh_property,
    sh_path,
    sh_inverse_path,
    sh_alternative_path,
    sh_target_class,
    sh_target_subjects_of,
    sh_target_node,
    sh_min_count,
    sh_max_count,
    sh_datatype,
    sh_node_kind,
    sh_class,
    sh_in,
    sh_closed,
    sh_ignored_properties,
    sh_min_inclusive,
    sh_max_inclusive,
    sh_min_exclusive,
    sh_max_exclusive,
    sh_has_value,
    sh_min_length,
    sh_max_length,
    sh_name,
    sh_message,
    sh_severity,
    sh_description,
    sh_order,
    sh_group,
    sh_deactivated,
    sh_unknown,
    other,

    fn is_value_component(p: Predicate) bool {
        return switch (p) {
            .sh_min_count,
            .sh_max_count,
            .sh_datatype,
            .sh_node_kind,
            .sh_class,
            .sh_in,
            .sh_min_inclusive,
            .sh_max_inclusive,
            .sh_min_exclusive,
            .sh_max_exclusive,
            .sh_has_value,
            .sh_min_length,
            .sh_max_length,
            => true,
            else => false,
        };
    }
};

const shacl_predicates = std.StaticStringMap(Predicate).initComptime(.{
    .{ "property", .sh_property },
    .{ "path", .sh_path },
    .{ "inversePath", .sh_inverse_path },
    .{ "alternativePath", .sh_alternative_path },
    .{ "targetClass", .sh_target_class },
    .{ "targetSubjectsOf", .sh_target_subjects_of },
    .{ "targetNode", .sh_target_node },
    .{ "minCount", .sh_min_count },
    .{ "maxCount", .sh_max_count },
    .{ "datatype", .sh_datatype },
    .{ "nodeKind", .sh_node_kind },
    .{ "class", .sh_class },
    .{ "in", .sh_in },
    .{ "closed", .sh_closed },
    .{ "ignoredProperties", .sh_ignored_properties },
    .{ "minInclusive", .sh_min_inclusive },
    .{ "maxInclusive", .sh_max_inclusive },
    .{ "minExclusive", .sh_min_exclusive },
    .{ "maxExclusive", .sh_max_exclusive },
    .{ "hasValue", .sh_has_value },
    .{ "minLength", .sh_min_length },
    .{ "maxLength", .sh_max_length },
    .{ "name", .sh_name },
    .{ "message", .sh_message },
    .{ "severity", .sh_severity },
    .{ "description", .sh_description },
    .{ "order", .sh_order },
    .{ "group", .sh_group },
    .{ "deactivated", .sh_deactivated },
});

const xsd_datatypes = std.StaticStringMap(RuleSet.Datatype).initComptime(.{
    .{ "float", .float },
    .{ "double", .double },
    .{ "decimal", .decimal },
    .{ "integer", .integer },
    .{ "boolean", .boolean },
    .{ "string", .string },
    .{ "dateTime", .date_time },
    .{ "date", .date },
    .{ "time", .time },
    .{ "duration", .duration },
    .{ "anyURI", .any_uri },
    .{ "gMonthDay", .g_month_day },
});

fn predicate_from_iri(iri: turtle.Iri) Predicate {
    if (std.mem.eql(u8, iri.namespace, turtle.shacl_namespace)) {
        return shacl_predicates.get(iri.local) orelse .sh_unknown;
    }
    if (std.mem.eql(u8, iri.namespace, turtle.rdf_namespace)) {
        if (std.mem.eql(u8, iri.local, "type")) return .rdf_type;
        if (std.mem.eql(u8, iri.local, "first")) return .rdf_first;
        if (std.mem.eql(u8, iri.local, "rest")) return .rdf_rest;
        return .other;
    }
    if (std.mem.eql(u8, iri.namespace, turtle.owl_namespace)) {
        if (std.mem.eql(u8, iri.local, "versionInfo")) return .owl_version_info;
        return .other;
    }
    return .other;
}

const Lit = struct { value: []const u8, kind: turtle.Literal.Kind };

const Object = union(enum) {
    node: u32,
    literal: Lit,
};

const Row = struct {
    subject: u32,
    predicate: Predicate,
    predicate_local: []const u8,
    object: Object,
    line: u32,
};

const NodeInfo = struct {
    namespace: []const u8,
    local: []const u8,
    kind: enum(u8) { iri, blank },
};

const TripleTable = struct {
    rows: []Row,
    subject_ranges: []RuleSet.Range,
    nodes: []NodeInfo,

    fn deinit(table: *TripleTable, gpa: std.mem.Allocator) void {
        gpa.free(table.rows);
        gpa.free(table.subject_ranges);
        gpa.free(table.nodes);
    }

    fn subject_rows(table: *const TripleTable, id: u32) []const Row {
        assert(id < table.subject_ranges.len);
        const range = table.subject_ranges[id];
        return table.rows[range.start .. range.start + range.len];
    }

    fn node_local(table: *const TripleTable, id: u32) []const u8 {
        assert(id < table.nodes.len);
        return table.nodes[id].local;
    }

    fn node_is_iri(table: *const TripleTable, id: u32) bool {
        return table.nodes[id].kind == .iri;
    }

    fn node_is(table: *const TripleTable, id: u32, namespace: []const u8, local: []const u8) bool {
        const node = table.nodes[id];
        if (node.kind != .iri) return false;
        if (!std.mem.eql(u8, node.namespace, namespace)) return false;
        return std.mem.eql(u8, node.local, local);
    }
};

const IriContext = struct {
    pub fn hash(_: IriContext, key: turtle.Iri) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.namespace);
        hasher.update(&[_]u8{0});
        hasher.update(key.local);
        return hasher.final();
    }
    pub fn eql(_: IriContext, a: turtle.Iri, b: turtle.Iri) bool {
        return a.eql(b);
    }
};

const IriIdMap = std.HashMap(turtle.Iri, u32, IriContext, std.hash_map.default_max_load_percentage);

const TableBuilder = struct {
    gpa: std.mem.Allocator,
    rows: std.ArrayList(Row),
    nodes: std.ArrayList(NodeInfo),
    iri_ids: IriIdMap,
    blank_ids: std.ArrayList(u32),

    fn intern_iri(b: *TableBuilder, iri: turtle.Iri) !u32 {
        const entry = try b.iri_ids.getOrPut(iri);
        if (entry.found_existing) return entry.value_ptr.*;
        const id: u32 = @intCast(b.nodes.items.len);
        try b.nodes.append(b.gpa, .{ .namespace = iri.namespace, .local = iri.local, .kind = .iri });
        entry.value_ptr.* = id;
        return id;
    }

    fn intern_blank(b: *TableBuilder, parser_id: u32) !u32 {
        if (parser_id < b.blank_ids.items.len) return b.blank_ids.items[parser_id];
        assert(parser_id == b.blank_ids.items.len);
        const id: u32 = @intCast(b.nodes.items.len);
        try b.nodes.append(b.gpa, .{ .namespace = "", .local = "", .kind = .blank });
        try b.blank_ids.append(b.gpa, id);
        return id;
    }

    fn intern_term(b: *TableBuilder, term: turtle.Term) !u32 {
        return switch (term) {
            .iri => |iri| b.intern_iri(iri),
            .blank => |parser_id| b.intern_blank(parser_id),
            .literal => unreachable, // subjects and interned objects only
        };
    }
};

fn build_table(
    gpa: std.mem.Allocator,
    source: []const u8,
    source_name: []const u8,
    diagnostics: ?*RuleSet.Diagnostics,
) RuleSet.LoadError!TripleTable {
    var builder: TableBuilder = .{
        .gpa = gpa,
        .rows = .empty,
        .nodes = .empty,
        .iri_ids = IriIdMap.init(gpa),
        .blank_ids = .empty,
    };
    defer builder.rows.deinit(gpa);
    defer builder.nodes.deinit(gpa);
    defer builder.iri_ids.deinit();
    defer builder.blank_ids.deinit(gpa);

    var parser = turtle.Turtle.init(source, source_name);
    while (true) {
        const triple_opt = parser.next() catch |err| {
            if (diagnostics) |d| d.line = parser.line;
            return err;
        };
        const triple = triple_opt orelse break;
        if (builder.rows.items.len >= triples_count_max) return error.TooManyTriples;

        const subject = try builder.intern_term(triple.subject);
        const object: Object = switch (triple.object) {
            .literal => |lit| .{ .literal = .{ .value = lit.value, .kind = lit.kind } },
            else => .{ .node = try builder.intern_term(triple.object) },
        };
        try builder.rows.append(gpa, .{
            .subject = subject,
            .predicate = predicate_from_iri(triple.predicate),
            .predicate_local = triple.predicate.local,
            .object = object,
            .line = triple.line,
        });
    }

    return sort_table(gpa, &builder);
}

fn sort_table(gpa: std.mem.Allocator, builder: *TableBuilder) !TripleTable {
    const nodes_count: u32 = @intCast(builder.nodes.items.len);
    const rows = builder.rows.items;

    const subject_ranges = try gpa.alloc(RuleSet.Range, nodes_count);
    errdefer gpa.free(subject_ranges);
    for (subject_ranges) |*range| range.* = .{ .start = 0, .len = 0 };
    for (rows) |row| subject_ranges[row.subject].len += 1;

    var pos: u32 = 0;
    const cursors = try gpa.alloc(u32, nodes_count);
    defer gpa.free(cursors);
    for (subject_ranges, cursors) |*range, *cursor| {
        range.start = pos;
        cursor.* = pos;
        pos += range.len;
    }
    assert(pos == rows.len);

    const sorted = try gpa.alloc(Row, rows.len);
    errdefer gpa.free(sorted);
    for (rows) |row| {
        sorted[cursors[row.subject]] = row;
        cursors[row.subject] += 1;
    }
    for (subject_ranges, cursors) |range, cursor| assert(cursor == range.start + range.len);

    return .{
        .rows = sorted,
        .subject_ranges = subject_ranges,
        .nodes = try builder.nodes.toOwnedSlice(gpa),
    };
}

fn find_version(table: *const TripleTable) []const u8 {
    var subject: u32 = 0;
    while (subject < table.nodes.len) : (subject += 1) {
        const rows = table.subject_rows(subject);
        var is_ontology = false;
        for (rows) |row| {
            if (row.predicate != .rdf_type) continue;
            if (row.object != .node) continue;
            if (table.node_is(row.object.node, turtle.owl_namespace, "Ontology")) is_ontology = true;
        }
        if (!is_ontology) continue;
        for (rows) |row| {
            if (row.predicate != .owl_version_info) continue;
            if (row.object != .literal) continue;
            return row.object.literal.value;
        }
    }
    return "";
}

const Emitter = struct {
    gpa: std.mem.Allocator,
    table: *const TripleTable,
    substitutions: []const RuleSet.Substitution,
    diagnostics: ?*RuleSet.Diagnostics,
    filling: bool,

    class_cursor_total: u32,
    tail_cursor: u32,
    constraints_cursor: u32,
    in_values_cursor: u32,
    closed_paths_cursor: u32,
    unsupported_cursor: u32,

    class_counts: std.StringHashMap(u32),
    class_index: std.StringHashMap(RuleSet.Range),
    class_total: u32,

    output: Output,

    unsupported_seen: []bool,

    scratch_classes: std.ArrayList([]const u8),
    scratch_closed: std.ArrayList([]const u8),
    scratch_values: std.ArrayList([]const u8),
    scratch_tail: std.ArrayList(RuleSet.Target),

    const Output = struct {
        shapes: []RuleSet.Shape = &.{},
        constraints: []RuleSet.Constraint = &.{},
        in_values: [][]const u8 = &.{},
        closed_paths: [][]const u8 = &.{},
        unsupported: []RuleSet.UnsupportedRule = &.{},
    };

    fn init(
        gpa: std.mem.Allocator,
        table: *const TripleTable,
        substitutions: []const RuleSet.Substitution,
        diagnostics: ?*RuleSet.Diagnostics,
    ) !Emitter {
        const seen = try gpa.alloc(bool, table.nodes.len);
        errdefer gpa.free(seen);
        @memset(seen, false);
        return .{
            .gpa = gpa,
            .table = table,
            .substitutions = substitutions,
            .diagnostics = diagnostics,
            .filling = false,
            .class_cursor_total = 0,
            .tail_cursor = 0,
            .constraints_cursor = 0,
            .in_values_cursor = 0,
            .closed_paths_cursor = 0,
            .unsupported_cursor = 0,
            .class_counts = std.StringHashMap(u32).init(gpa),
            .class_index = std.StringHashMap(RuleSet.Range).init(gpa),
            .class_total = 0,
            .output = .{},
            .unsupported_seen = seen,
            .scratch_classes = .empty,
            .scratch_closed = .empty,
            .scratch_values = .empty,
            .scratch_tail = .empty,
        };
    }

    fn deinit(e: *Emitter) void {
        e.scratch_tail.deinit(e.gpa);
        e.scratch_values.deinit(e.gpa);
        e.scratch_closed.deinit(e.gpa);
        e.scratch_classes.deinit(e.gpa);
        e.gpa.free(e.unsupported_seen);
        e.class_index.deinit();
        e.class_counts.deinit();
    }

    fn take_class_index(e: *Emitter) std.StringHashMap(RuleSet.Range) {
        const index = e.class_index;
        e.class_index = std.StringHashMap(RuleSet.Range).init(e.gpa);
        return index;
    }

    fn free_output(e: *Emitter) void {
        e.gpa.free(e.output.shapes);
        e.gpa.free(e.output.constraints);
        e.gpa.free(e.output.in_values);
        e.gpa.free(e.output.closed_paths);
        e.gpa.free(e.output.unsupported);
        e.output = .{};
    }

    fn check_limits(e: *const Emitter) RuleSet.LoadError!void {
        assert(!e.filling);
        const shapes_total = e.class_cursor_total + e.tail_cursor;
        if (shapes_total > shapes_count_max) return error.TooManyShapes;
        if (e.constraints_cursor > constraints_count_max) return error.TooManyConstraints;
        if (e.closed_paths_cursor > closed_paths_count_max) return error.TooManyClosedPaths;
    }

    fn begin_fill(e: *Emitter, counter: *const Emitter) !void {
        assert(!counter.filling);
        e.filling = true;
        e.class_total = counter.class_cursor_total;

        e.output.shapes = try e.gpa.alloc(RuleSet.Shape, counter.class_cursor_total + counter.tail_cursor);
        e.output.constraints = try e.gpa.alloc(RuleSet.Constraint, counter.constraints_cursor);
        e.output.in_values = try e.gpa.alloc([]const u8, counter.in_values_cursor);
        e.output.closed_paths = try e.gpa.alloc([]const u8, counter.closed_paths_cursor);
        e.output.unsupported = try e.gpa.alloc(RuleSet.UnsupportedRule, counter.unsupported_cursor);

        var pos: u32 = 0;
        var it = counter.class_counts.iterator();
        while (it.next()) |entry| {
            try e.class_counts.put(entry.key_ptr.*, pos);
            try e.class_index.put(entry.key_ptr.*, .{ .start = pos, .len = entry.value_ptr.* });
            pos += entry.value_ptr.*;
        }
        assert(pos == counter.class_cursor_total);
        e.tail_cursor = pos; // tail section starts after all class entries
    }

    fn assert_fill_complete(e: *const Emitter, counter: *const Emitter) void {
        assert(e.filling);
        assert(e.constraints_cursor == counter.constraints_cursor);
        assert(e.in_values_cursor == counter.in_values_cursor);
        assert(e.closed_paths_cursor == counter.closed_paths_cursor);
        assert(e.unsupported_cursor == counter.unsupported_cursor);
        assert(e.tail_cursor == counter.class_cursor_total + counter.tail_cursor);
        var it = e.class_index.iterator();
        while (it.next()) |entry| {
            const cursor = e.class_counts.get(entry.key_ptr.*).?;
            assert(cursor == entry.value_ptr.start + entry.value_ptr.len);
        }
    }

    fn fail_line(e: *Emitter, line: u32) void {
        if (e.diagnostics) |d| d.line = line;
    }

    fn emit_constraint(e: *Emitter, constraint: RuleSet.Constraint) !void {
        if (e.filling) {
            assert(e.constraints_cursor < e.output.constraints.len);
            e.output.constraints[e.constraints_cursor] = constraint;
        }
        e.constraints_cursor += 1;
    }

    fn emit_unsupported(e: *Emitter, name: []const u8, component: []const u8) !void {
        if (e.filling) {
            assert(e.unsupported_cursor < e.output.unsupported.len);
            e.output.unsupported[e.unsupported_cursor] = .{ .name = name, .component = component };
        }
        e.unsupported_cursor += 1;
    }

    fn emit_string_range(
        e: *Emitter,
        scratch: *std.ArrayList([]const u8),
        out: [][]const u8,
        cursor: *u32,
    ) RuleSet.Range {
        std.mem.sort([]const u8, scratch.items, {}, string_less_than);
        var unique: u32 = 0;
        for (scratch.items, 0..) |value, i| {
            if (i > 0 and std.mem.eql(u8, scratch.items[i - 1], value)) continue;
            scratch.items[unique] = value;
            unique += 1;
        }
        const start = cursor.*;
        if (e.filling) {
            assert(start + unique <= out.len);
            @memcpy(out[start .. start + unique], scratch.items[0..unique]);
        }
        cursor.* += unique;
        return .{ .start = start, .len = unique };
    }

    fn emit_shape(e: *Emitter, target: RuleSet.Target, shape: ShapeParts) !void {
        const entry = RuleSet.Shape{
            .name = shape.meta.name,
            .target = target,
            .constraints = shape.constraints,
            .closed_paths = shape.closed_paths,
            .message = shape.meta.message,
            .severity = shape.meta.severity,
        };
        switch (target) {
            .class => |class_local| {
                if (e.filling) {
                    const cursor = e.class_counts.getPtr(class_local).?;
                    assert(cursor.* < e.output.shapes.len);
                    e.output.shapes[cursor.*] = entry;
                    cursor.* += 1;
                } else {
                    const gop = try e.class_counts.getOrPut(class_local);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                    e.class_cursor_total += 1;
                }
            },
            .node, .subjects_of => {
                if (e.filling) {
                    assert(e.tail_cursor < e.output.shapes.len);
                    e.output.shapes[e.tail_cursor] = entry;
                }
                e.tail_cursor += 1;
            },
        }
    }
};

fn string_less_than(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const TransformTotals = struct {
    bytes: u64 = 0,
    strings: u32 = 0,
    in_values: u32 = 0,
};

fn finalize_strings(
    gpa: std.mem.Allocator,
    output: *Emitter.Output,
    version: *[]const u8,
    substitutions: []const RuleSet.Substitution,
) RuleSet.LoadError![]const u8 {
    const measured = try transform_pass(output, version, substitutions, null);
    if (measured.strings == 0) return "";
    if (measured.bytes > rules_bytes_max) return error.RuleSetTooLarge;

    const buffer = try gpa.alloc(u8, @intCast(measured.bytes));
    errdefer gpa.free(buffer);
    const filled = try transform_pass(output, version, substitutions, buffer);
    assert(filled.bytes == measured.bytes);
    assert(filled.strings == measured.strings);

    // Escape decoding can change lexical order required by binary search.
    if (measured.in_values > 0) sort_in_value_ranges(output);
    return buffer;
}

fn transform_pass(
    output: *Emitter.Output,
    version: *[]const u8,
    substitutions: []const RuleSet.Substitution,
    buffer: ?[]u8,
) RuleSet.LoadError!TransformTotals {
    assert(substitutions.len <= substitutions_count_max);
    var totals = TransformTotals{};
    for (output.shapes) |*shape| {
        try transform_field(&shape.name, &.{}, buffer, &totals);
        try transform_field(&shape.message, substitutions, buffer, &totals);
    }
    for (output.constraints) |*constraint| {
        try transform_field(&constraint.name, &.{}, buffer, &totals);
        try transform_field(&constraint.message, substitutions, buffer, &totals);
        switch (constraint.check) {
            .has_value => |*value| try transform_field(value, &.{}, buffer, &totals),
            else => {},
        }
    }
    const strings_before_in = totals.strings;
    for (output.in_values) |*value| try transform_field(value, &.{}, buffer, &totals);
    totals.in_values = totals.strings - strings_before_in;
    for (output.unsupported) |*rule| try transform_field(&rule.name, &.{}, buffer, &totals);
    try transform_field(version, &.{}, buffer, &totals);
    return totals;
}

fn transform_field(
    field: *[]const u8,
    substitutions: []const RuleSet.Substitution,
    buffer: ?[]u8,
    totals: *TransformTotals,
) RuleSet.LoadError!void {
    if (!string_needs_transform(field.*, substitutions)) return;
    if (buffer) |bytes| {
        assert(totals.bytes <= bytes.len);
        const start: u32 = @intCast(totals.bytes);
        const len = try transform_string(field.*, substitutions, bytes[start..]);
        field.* = bytes[start .. start + len];
        totals.bytes += len;
    } else {
        const len = try transform_string(field.*, substitutions, null);
        if (substitutions.len > 0) assert(len <= message_bytes_max);
        totals.bytes += len;
    }
    totals.strings += 1;
}

fn string_needs_transform(
    raw: []const u8,
    substitutions: []const RuleSet.Substitution,
) bool {
    if (std.mem.indexOfScalar(u8, raw, '\\') != null) return true;
    for (substitutions) |substitution| {
        if (std.mem.indexOf(u8, raw, substitution.name) != null) return true;
    }
    return false;
}

fn transform_string(
    raw: []const u8,
    substitutions: []const RuleSet.Substitution,
    out: ?[]u8,
) RuleSet.LoadError!u32 {
    assert(raw.len <= rules_bytes_max); // a slice of an already-checked source
    var len: u32 = 0;
    var i: u32 = 0;
    while (i < raw.len) {
        if (raw[i] == '\\') {
            const escape = turtle.decode_escape(raw, i);
            if (out) |o| @memcpy(o[len .. len + escape.written], escape.bytes[0..escape.written]);
            len += escape.written;
            i += escape.consumed;
        } else if (match_substitution(raw[i..], substitutions)) |substitution| {
            if (out) |o| @memcpy(o[len .. len + substitution.value.len], substitution.value);
            len += @intCast(substitution.value.len);
            i += @intCast(substitution.name.len);
        } else {
            if (out) |o| o[len] = raw[i];
            len += 1;
            i += 1;
        }
        if (len > rules_bytes_max) return error.RuleSetTooLarge;
    }
    return len;
}

fn match_substitution(
    rest: []const u8,
    substitutions: []const RuleSet.Substitution,
) ?RuleSet.Substitution {
    assert(rest.len > 0); // callers stop at raw.len
    for (substitutions) |substitution| {
        if (std.mem.startsWith(u8, rest, substitution.name)) return substitution;
    }
    return null;
}

fn sort_in_value_ranges(output: *Emitter.Output) void {
    for (output.constraints) |constraint| {
        const range = switch (constraint.check) {
            .in => |r| r,
            else => continue,
        };
        assert(range.start + range.len <= output.in_values.len);
        const values = output.in_values[range.start .. range.start + range.len];
        std.mem.sort([]const u8, values, {}, string_less_than);
    }
}

const ShapeMetadata = struct {
    name: []const u8,
    message: []const u8,
    severity: RuleSet.Severity,
};

fn check_message_length(e: *Emitter, row: Row) RuleSet.LoadError!void {
    assert(row.predicate == .sh_message);
    assert(row.object == .literal);
    const value = row.object.literal.value;
    if (value.len > message_bytes_max) {
        e.fail_line(row.line);
        return error.MessageTooLong;
    }
    if (!string_needs_transform(value, e.substitutions)) return;
    const expanded = transform_string(value, e.substitutions, null) catch |err| {
        e.fail_line(row.line);
        return err;
    };
    if (expanded > message_bytes_max) {
        e.fail_line(row.line);
        return error.MessageTooLong;
    }
}

const ShapeParts = struct {
    meta: ShapeMetadata,
    constraints: RuleSet.Range,
    closed_paths: ?RuleSet.Range,
};

fn scan_all(e: *Emitter) RuleSet.LoadError!void {
    @memset(e.unsupported_seen, false);
    var subject: u32 = 0;
    while (subject < e.table.nodes.len) : (subject += 1) {
        const rows = e.table.subject_rows(subject);
        if (rows.len == 0) continue;
        if (shape_deactivated(rows)) continue;
        if (!rows_have_target(rows)) {
            try report_unsupported_target(e, subject, rows);
            continue;
        }
        try scan_node_shape(e, subject, rows);
    }
}

fn report_unsupported_target(e: *Emitter, subject: u32, rows: []const Row) RuleSet.LoadError!void {
    for (rows) |row| {
        if (row.predicate != .sh_unknown) continue;
        // Unsupported targets must remain visible instead of becoming inert rules.
        if (!std.mem.eql(u8, row.predicate_local, "targetObjectsOf")) continue;
        const meta = try shape_metadata(e, rows, e.table.node_local(subject));
        try e.emit_unsupported(meta.name, row.predicate_local);
        return;
    }
}

fn rows_have_target(rows: []const Row) bool {
    for (rows) |row| {
        switch (row.predicate) {
            .sh_target_class, .sh_target_subjects_of, .sh_target_node => return true,
            else => {},
        }
    }
    return false;
}

fn shape_deactivated(rows: []const Row) bool {
    for (rows) |row| {
        if (row.predicate != .sh_deactivated) continue;
        if (row.object != .literal) continue;
        return std.mem.eql(u8, row.object.literal.value, "true");
    }
    return false;
}

fn scan_node_shape(e: *Emitter, subject: u32, rows: []const Row) RuleSet.LoadError!void {
    assert(rows_have_target(rows));
    const meta = try shape_metadata(e, rows, e.table.node_local(subject));
    const constraints_start = e.constraints_cursor;

    e.scratch_classes.clearRetainingCapacity();
    e.scratch_closed.clearRetainingCapacity();
    e.scratch_tail.clearRetainingCapacity();
    var closed = false;

    for (rows) |row| {
        switch (row.predicate) {
            .sh_property => try scan_property_shape(e, meta, row),
            .sh_closed => closed = literal_is_true(row.object),
            .sh_ignored_properties => try collect_ignored_properties(e, meta, row),
            .sh_target_class => try add_class_target(e, meta, row),
            .sh_target_subjects_of => try add_subjects_of_target(e, meta, row),
            .sh_target_node => try add_node_target(e, meta, row),
            .sh_unknown => try e.emit_unsupported(meta.name, row.predicate_local),
            else => {
                // Node-level value components have no corpus use or evaluator path.
                if (row.predicate.is_value_component()) {
                    try e.emit_unsupported(meta.name, row.predicate_local);
                }
            },
        }
    }

    const parts = ShapeParts{
        .meta = meta,
        .constraints = .{
            .start = constraints_start,
            .len = e.constraints_cursor - constraints_start,
        },
        .closed_paths = if (closed)
            e.emit_string_range(&e.scratch_closed, e.output.closed_paths, &e.closed_paths_cursor)
        else
            null,
    };
    for (e.scratch_classes.items) |class_local| {
        try e.emit_shape(.{ .class = class_local }, parts);
    }
    for (e.scratch_tail.items) |target| {
        try e.emit_shape(target, parts);
    }
}

fn add_class_target(e: *Emitter, meta: ShapeMetadata, row: Row) !void {
    if (row.object != .node) return e.emit_unsupported(meta.name, row.predicate_local);
    if (!e.table.node_is_iri(row.object.node)) {
        return e.emit_unsupported(meta.name, row.predicate_local);
    }
    const class_local = e.table.node_local(row.object.node);
    for (e.scratch_classes.items) |existing| {
        if (std.mem.eql(u8, existing, class_local)) return;
    }
    try e.scratch_classes.append(e.gpa, class_local);
}

fn add_subjects_of_target(e: *Emitter, meta: ShapeMetadata, row: Row) !void {
    if (row.object != .node) return e.emit_unsupported(meta.name, row.predicate_local);
    const node = row.object.node;
    if (!e.table.node_is_iri(node)) return e.emit_unsupported(meta.name, row.predicate_local);
    // The sentinel distinguishes the class-whitelist idiom from a CIM property.
    const property = if (e.table.node_is(node, turtle.rdf_namespace, "type"))
        "rdf:type"
    else
        e.table.node_local(node);
    try e.scratch_tail.append(e.gpa, .{ .subjects_of = property });
}

fn add_node_target(e: *Emitter, meta: ShapeMetadata, row: Row) !void {
    if (row.object != .node) return e.emit_unsupported(meta.name, row.predicate_local);
    if (!e.table.node_is_iri(row.object.node)) {
        return e.emit_unsupported(meta.name, row.predicate_local);
    }
    try e.scratch_tail.append(e.gpa, .{ .node = e.table.node_local(row.object.node) });
}

fn collect_ignored_properties(e: *Emitter, meta: ShapeMetadata, row: Row) RuleSet.LoadError!void {
    if (row.object != .node) return e.emit_unsupported(meta.name, row.predicate_local);
    e.scratch_values.clearRetainingCapacity();
    try collect_list(e, row, &e.scratch_values);
    for (e.scratch_values.items) |value| {
        if (std.mem.eql(u8, value, "rdf:type")) continue;
        try e.scratch_closed.append(e.gpa, value);
    }
}

fn scan_property_shape(e: *Emitter, node_meta: ShapeMetadata, row: Row) RuleSet.LoadError!void {
    if (row.object != .node) return e.emit_unsupported(node_meta.name, row.predicate_local);
    const subject = row.object.node;
    const rows = e.table.subject_rows(subject);
    const report = !e.unsupported_seen[subject];
    e.unsupported_seen[subject] = true;

    if (rows.len == 0) {
        if (report) try e.emit_unsupported(node_meta.name, row.predicate_local);
        return;
    }
    if (shape_deactivated(rows)) return;

    const fallback = property_fallback_name(e.table, subject, node_meta.name);
    const meta = try shape_metadata(e, rows, fallback);

    const path = resolve_path(e.table, rows) orelse {
        if (rows_have_component(rows)) {
            if (report) try e.emit_unsupported(meta.name, "path");
        }
        return;
    };
    if (path.kind == .direct) try e.scratch_closed.append(e.gpa, path.local);

    for (rows) |property_row| {
        try scan_component(e, meta, path, property_row, report);
    }
}

fn rows_have_component(rows: []const Row) bool {
    for (rows) |row| {
        if (row.predicate.is_value_component()) return true;
    }
    return false;
}

fn property_fallback_name(table: *const TripleTable, subject: u32, node_name: []const u8) []const u8 {
    const local = table.node_local(subject);
    if (table.node_is_iri(subject) and local.len > 0) return local;
    return node_name;
}

fn scan_component(
    e: *Emitter,
    meta: ShapeMetadata,
    path: ResolvedPath,
    row: Row,
    report: bool,
) RuleSet.LoadError!void {
    const check: ?RuleSet.Check = switch (row.predicate) {
        .sh_min_count => if (count_of(row.object)) |n| .{ .min_count = n } else null,
        .sh_max_count => if (count_of(row.object)) |n| .{ .max_count = n } else null,
        .sh_datatype => if (datatype_of(e.table, row.object)) |d| .{ .datatype = d } else null,
        .sh_node_kind => if (node_kind_of(e.table, row.object)) |k| .{ .node_kind = k } else null,
        .sh_class => if (class_of(e.table, row.object)) |c| .{ .class = c } else null,
        .sh_in => try in_check_of(e, row),
        .sh_min_inclusive => if (float_of(row.object)) |v| .{ .min_inclusive = v } else null,
        .sh_max_inclusive => if (float_of(row.object)) |v| .{ .max_inclusive = v } else null,
        .sh_min_exclusive => if (float_of(row.object)) |v| .{ .min_exclusive = v } else null,
        .sh_max_exclusive => if (float_of(row.object)) |v| .{ .max_exclusive = v } else null,
        .sh_has_value => if (value_of(e.table, row.object)) |v| .{ .has_value = v } else null,
        .sh_min_length => if (count_of(row.object)) |n| .{ .min_length = n } else null,
        .sh_max_length => if (count_of(row.object)) |n| .{ .max_length = n } else null,
        .sh_unknown => {
            if (report) try e.emit_unsupported(meta.name, row.predicate_local);
            return;
        },
        else => return,
    };
    const resolved_check = check orelse {
        if (report) try e.emit_unsupported(meta.name, row.predicate_local);
        return;
    };
    // Inverse traversal currently materializes counts, not values.
    if (path.kind == .inverse and
        resolved_check != .min_count and resolved_check != .max_count)
    {
        if (report) try e.emit_unsupported(meta.name, row.predicate_local);
        return;
    }
    try e.emit_constraint(.{
        .path = path.local,
        .path_kind = path.kind,
        .name = meta.name,
        .message = meta.message,
        .severity = meta.severity,
        .check = resolved_check,
    });
}

fn in_check_of(e: *Emitter, row: Row) RuleSet.LoadError!?RuleSet.Check {
    if (row.object != .node) return null;
    e.scratch_values.clearRetainingCapacity();
    collect_list(e, row, &e.scratch_values) catch |err| switch (err) {
        error.MalformedList => return null,
        else => return err,
    };
    const range = e.emit_string_range(&e.scratch_values, e.output.in_values, &e.in_values_cursor);
    return .{ .in = range };
}

fn collect_list(e: *Emitter, row: Row, out: *std.ArrayList([]const u8)) RuleSet.LoadError!void {
    assert(row.object == .node);
    var current = row.object.node;
    var steps: u32 = 0;
    while (!e.table.node_is(current, turtle.rdf_namespace, "nil")) {
        if (steps >= turtle.in_list_values_max) {
            e.fail_line(row.line);
            return error.TooManyListValues;
        }
        steps += 1;
        const rows = e.table.subject_rows(current);
        var first: ?Object = null;
        var rest: ?u32 = null;
        for (rows) |chain_row| {
            switch (chain_row.predicate) {
                .rdf_first => first = chain_row.object,
                .rdf_rest => if (chain_row.object == .node) {
                    rest = chain_row.object.node;
                },
                else => {},
            }
        }
        const element = first orelse {
            e.fail_line(row.line);
            return error.MalformedList;
        };
        const value: []const u8 = switch (element) {
            .literal => |lit| lit.value,
            .node => |id| blk: {
                if (!e.table.node_is_iri(id)) {
                    e.fail_line(row.line);
                    return error.MalformedList;
                }
                if (e.table.node_is(id, turtle.rdf_namespace, "type")) break :blk "rdf:type";
                break :blk e.table.node_local(id);
            },
        };
        try out.append(e.gpa, value);
        current = rest orelse {
            e.fail_line(row.line);
            return error.MalformedList;
        };
    }
}

fn shape_metadata(
    e: *Emitter,
    rows: []const Row,
    fallback_name: []const u8,
) RuleSet.LoadError!ShapeMetadata {
    var meta = ShapeMetadata{ .name = fallback_name, .message = "", .severity = .violation };
    var name_set = false;
    var message_set = false;
    for (rows) |row| {
        switch (row.predicate) {
            .sh_name => if (!name_set and row.object == .literal) {
                meta.name = row.object.literal.value;
                name_set = true;
            },
            .sh_message => if (!message_set and row.object == .literal) {
                try check_message_length(e, row);
                meta.message = row.object.literal.value;
                message_set = true;
            },
            .sh_severity => if (row.object == .node) {
                meta.severity = severity_of(e.table, row.object.node) orelse .violation;
            },
            else => {},
        }
    }
    return meta;
}

const ResolvedPath = struct { kind: RuleSet.PathKind, local: []const u8 };

fn resolve_path(table: *const TripleTable, rows: []const Row) ?ResolvedPath {
    const path_row = for (rows) |row| {
        if (row.predicate == .sh_path) break row;
    } else return null;
    if (path_row.object != .node) return null;
    const node = path_row.object.node;

    if (table.node_is_iri(node)) return resolve_iri_path(table, node);

    const path_rows = table.subject_rows(node);
    for (path_rows) |row| {
        switch (row.predicate) {
            .sh_inverse_path => return resolve_inverse_path(table, row),
            .sh_alternative_path => return resolve_alternative_path(table, row),
            .rdf_first => return resolve_sequence_path(table, node),
            else => {},
        }
    }
    return null;
}

fn resolve_iri_path(table: *const TripleTable, node: u32) ResolvedPath {
    assert(table.node_is_iri(node));
    if (table.node_is(node, turtle.rdf_namespace, "type")) {
        return .{ .kind = .own_type, .local = "rdf:type" };
    }
    return .{ .kind = .direct, .local = table.node_local(node) };
}

fn resolve_inverse_path(table: *const TripleTable, row: Row) ?ResolvedPath {
    if (row.object != .node) return null;
    const node = row.object.node;
    if (table.node_is_iri(node)) {
        if (table.node_is(node, turtle.rdf_namespace, "type")) return null;
        return .{ .kind = .inverse, .local = table.node_local(node) };
    }
    for (table.subject_rows(node)) |inner| {
        if (inner.predicate != .sh_alternative_path) continue;
        const collapsed = collapse_alternatives(table, inner) orelse return null;
        if (collapsed.kind != .direct) return null;
        return .{ .kind = .inverse, .local = collapsed.local };
    }
    return null;
}

fn resolve_alternative_path(table: *const TripleTable, row: Row) ?ResolvedPath {
    return collapse_alternatives(table, row);
}

fn collapse_alternatives(table: *const TripleTable, row: Row) ?ResolvedPath {
    if (row.object != .node) return null;
    var current = row.object.node;
    var collapsed: ?ResolvedPath = null;
    var steps: u32 = 0;
    while (!table.node_is(current, turtle.rdf_namespace, "nil")) {
        if (steps >= turtle.in_list_values_max) return null;
        steps += 1;
        var first: ?Object = null;
        var rest: ?u32 = null;
        for (table.subject_rows(current)) |chain_row| {
            switch (chain_row.predicate) {
                .rdf_first => first = chain_row.object,
                .rdf_rest => if (chain_row.object == .node) {
                    rest = chain_row.object.node;
                },
                else => {},
            }
        }
        const element = first orelse return null;
        const resolved = resolve_alternative_element(table, element) orelse return null;
        if (collapsed) |existing| {
            if (existing.kind != resolved.kind) return null;
            if (!std.mem.eql(u8, existing.local, resolved.local)) return null;
        } else {
            collapsed = resolved;
        }
        current = rest orelse return null;
    }
    return collapsed;
}

fn resolve_alternative_element(table: *const TripleTable, element: Object) ?ResolvedPath {
    if (element != .node) return null;
    const node = element.node;
    if (table.node_is_iri(node)) {
        if (table.node_is(node, turtle.rdf_namespace, "type")) return null;
        return .{ .kind = .direct, .local = table.node_local(node) };
    }
    for (table.subject_rows(node)) |row| {
        if (row.predicate != .sh_inverse_path) continue;
        if (row.object != .node) return null;
        const inner = row.object.node;
        if (!table.node_is_iri(inner)) return null;
        return .{ .kind = .inverse, .local = table.node_local(inner) };
    }
    return null;
}

fn resolve_sequence_path(table: *const TripleTable, head: u32) ?ResolvedPath {
    var elements: [2]Object = undefined;
    var count: u32 = 0;
    var current = head;
    while (!table.node_is(current, turtle.rdf_namespace, "nil")) {
        if (count >= 2) return null; // longer sequences are unsupported
        var first: ?Object = null;
        var rest: ?u32 = null;
        for (table.subject_rows(current)) |row| {
            switch (row.predicate) {
                .rdf_first => first = row.object,
                .rdf_rest => if (row.object == .node) {
                    rest = row.object.node;
                },
                else => {},
            }
        }
        elements[count] = first orelse return null;
        count += 1;
        current = rest orelse return null;
    }
    if (count != 2) return null;
    if (elements[0] != .node) return null;
    if (elements[1] != .node) return null;
    const property = elements[0].node;
    if (!table.node_is_iri(property)) return null;
    if (table.node_is(property, turtle.rdf_namespace, "type")) return null;
    if (!table.node_is(elements[1].node, turtle.rdf_namespace, "type")) return null;
    return .{ .kind = .ref_type, .local = table.node_local(property) };
}

fn literal_is_true(object: Object) bool {
    if (object != .literal) return false;
    return std.mem.eql(u8, object.literal.value, "true");
}

fn count_of(object: Object) ?u32 {
    if (object != .literal) return null;
    return std.fmt.parseInt(u32, object.literal.value, 10) catch null;
}

fn float_of(object: Object) ?f64 {
    if (object != .literal) return null;
    return std.fmt.parseFloat(f64, object.literal.value) catch null;
}

fn datatype_of(table: *const TripleTable, object: Object) ?RuleSet.Datatype {
    if (object != .node) return null;
    const node = table.nodes[object.node];
    if (node.kind != .iri) return null;
    if (!std.mem.eql(u8, node.namespace, turtle.xsd_namespace)) return null;
    return xsd_datatypes.get(node.local);
}

fn node_kind_of(table: *const TripleTable, object: Object) ?RuleSet.NodeKind {
    if (object != .node) return null;
    if (table.node_is(object.node, turtle.shacl_namespace, "IRI")) return .iri;
    if (table.node_is(object.node, turtle.shacl_namespace, "Literal")) return .literal;
    return null;
}

fn class_of(table: *const TripleTable, object: Object) ?[]const u8 {
    if (object != .node) return null;
    if (!table.node_is_iri(object.node)) return null;
    return table.node_local(object.node);
}

fn value_of(table: *const TripleTable, object: Object) ?[]const u8 {
    switch (object) {
        .literal => |lit| return lit.value,
        .node => |id| {
            if (!table.node_is_iri(id)) return null;
            return table.node_local(id);
        },
    }
}

fn severity_of(table: *const TripleTable, node: u32) ?RuleSet.Severity {
    if (table.node_is(node, turtle.shacl_namespace, "Violation")) return .violation;
    if (table.node_is(node, turtle.shacl_namespace, "Warning")) return .warning;
    if (table.node_is(node, turtle.shacl_namespace, "Info")) return .info;
    return null;
}
