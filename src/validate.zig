//! SHACL validation: evaluate a compiled RuleSet against a CGMES model and
//! report violations with file:line traceability.
//!
//! Evaluation is shape-major: for each shape, fetch the model's objects of
//! the target class via the existing type-range lookup and run the shape's
//! contiguous constraint range over them. Property lookups within one object
//! batch through a single child-tag scan; the closed-shape check rides the
//! same scan.
//!
//! Absent values follow standard SHACL semantics: every check except
//! min_count quantifies over values that exist, so a rule on an absent
//! optional attribute is not checked.

const std = @import("std");
const assert = std.debug.assert;
const EQ = @import("cgmes/eq.zig").EQ;
const CimObjectView = @import("cgmes/tag_index.zig").CimObjectView;
const tag_index = @import("cgmes/tag_index.zig");
const cim_types = @import("cgmes/cim_types.zig");
const rule_set_mod = @import("shacl/rule_set.zig");
const RuleSet = rule_set_mod.RuleSet;

/// Bounds report size; violations beyond it are counted as truncated,
/// never silently dropped.
pub const violations_count_max = 1 << 20;

/// QoCDC rule constants, as value-and-unit strings (transcribed from the
/// same table qocdc.zig documents). QoCDC requires reports to replace
/// constant references in rule messages with these values ("… is not >=
/// EQ_BRANCH_X_LIMIT" must reach the user as "… is not >= 0.01 Ohm"), so
/// `cimd validate` applies this table to every rule set at load time.
/// NC rule-set messages contain none of these names; there the table is
/// a measured no-op. No name is a prefix of another, so the first-match
/// expansion order cannot misfire.
pub const qocdc_substitutions = [_]RuleSet.Substitution{
    .{ .name = "NUMERIC_TOLERANCE", .value = "0.0005" },
    .{ .name = "SSH_SV_MAX_P_DIFF", .value = "10 MW" },
    .{ .name = "SSH_SV_MAX_Q_DIFF", .value = "50 Mvar" },
    .{ .name = "SSH_SV_TOT_P_DIFF", .value = "200 MW" },
    .{ .name = "SSH_SV_MAX_TAP_STEP_DIFF", .value = "2 steps" },
    .{ .name = "SSH_SV_MAX_Q_SHUNT_DIFF", .value = "1 Mvar" },
    .{ .name = "SV_INJECTION_LIMIT", .value = "0.1 MVA" },
    .{ .name = "SV_INJECTION_RELAXED_LIMIT", .value = "0.5 MVA" },
    .{ .name = "EQ_BRANCH_X_LIMIT", .value = "0.01 Ohm" },
    .{ .name = "EQ_RATEDS_REASONABILITY_FACTOR", .value = "10" },
    .{ .name = "EQ_DB_REASONABILITY_FACTOR", .value = "2" },
    .{ .name = "IO_NAME_LENGTH", .value = "32 characters" },
    .{ .name = "IO_DESCRIPTION_LENGTH", .value = "256 characters" },
    .{ .name = "EIC_LENGTH", .value = "16 characters" },
    .{ .name = "SHORT_NAME_LENGTH", .value = "12 characters" },
    .{ .name = "BOUNDARY_BV_MAX_DIFF", .value = "0.1" },
    .{ .name = "PATL_LIMIT_VALUE_DIFF", .value = "0.1" },
    .{ .name = "INTERCH_IMBALANCE_WARNING", .value = "50 MW" },
    .{ .name = "INTERCH_IMBALANCE_ERROR", .value = "200 MW" },
    .{ .name = "INTERCH_IMBALANCE_EMF", .value = "2 MW" },
    .{ .name = "NUMBER_OF_SUBSTATIONS", .value = "30" },
    .{ .name = "REACTIVE_POWER_THRESHOLD", .value = "1500 Mvar" },
    .{ .name = "THRESHOLD_ACTIVE_P_IMBALANCE_DISTR", .value = "2 MW" },
    .{ .name = "ZERO_IMPEDANCE_THRESHOLD", .value = "0.00001 pu" },
};

/// Marks a node-level (closed-shape) violation, which has no constraint.
pub const constraint_none = std.math.maxInt(u32);

/// Whitespace wrapping pretty-printed XML text content, the same contract
/// as cgmes/parse.zig, applied before every value comparison.
const whitespace = " \t\r\n";

pub const Violation = struct {
    /// Index into rules.shapes.
    shape: u32,
    /// Index into rules.constraints; constraint_none for closed-shape hits.
    constraint: u32,
    /// Byte offset of the focus object's opening '<' in the data XML.
    /// Line numbers are a presentation concern derived at report time.
    offset: u32,
    object_id: []const u8,
    /// The offending child tag (closed check) or value (value checks);
    /// "" when the check has no single offending datum (cardinality).
    detail: []const u8,
};

pub const Evaluation = struct {
    violations: std.ArrayList(Violation),
    /// Violations beyond violations_count_max: counted, not stored.
    truncated: u64,

    pub const empty: Evaluation = .{ .violations = .empty, .truncated = 0 };

    pub fn deinit(self: *Evaluation, gpa: std.mem.Allocator) void {
        self.violations.deinit(gpa);
    }
};

/// Run every shape of `rules` against `model`. The result borrows slices
/// from both, so they must outlive it.
pub fn evaluate(
    gpa: std.mem.Allocator,
    model: *const EQ,
    rules: *const RuleSet,
) !Evaluation {
    var evaluation: Evaluation = .empty;
    errdefer evaluation.deinit(gpa);

    var ids = try IdIndex.init(gpa, model);
    defer ids.deinit();

    // Inverse-path cardinality is the one model-wide piece: the referrer
    // counts are built in a single pass up front.
    var referrers = try ReferrerCounts.build(gpa, &ids, rules);
    defer referrers.deinit(gpa);

    var evaluator = Evaluator{
        .gpa = gpa,
        .model = model,
        .rules = rules,
        .evaluation = &evaluation,
        .ids = &ids,
        .referrers = &referrers,
        .counts = .empty,
        .staged = .empty,
    };
    defer evaluator.counts.deinit(gpa);
    defer evaluator.staged.deinit(gpa);

    for (rules.shapes, 0..) |shape, shape_index| {
        try evaluator.evaluate_shape(@intCast(shape_index), shape);
    }
    return evaluation;
}

/// Object lookup by the local (hash-stripped) form of an id. EQ stores ids
/// raw: the rdf:ID form ("_x") already equals the local form of a reference,
/// but flat rdf:about instance files (SSH, TP, SV) carry "#_x", which a
/// reference's local form would miss. The extra map is built only for ids
/// that need stripping; empty for rdf:ID documents.
const IdIndex = struct {
    model: *const EQ,
    /// strip_hash(id) → object index, only for '#'-prefixed ids.
    about: std.StringHashMap(u32),

    fn init(gpa: std.mem.Allocator, model: *const EQ) !IdIndex {
        assert(model.objects.len <= std.math.maxInt(u32));
        var about = std.StringHashMap(u32).init(gpa);
        errdefer about.deinit();
        var total: u32 = 0;
        for (model.objects) |obj| {
            if (obj.id[0] == '#') total += 1;
        }
        if (total > 0) {
            try about.ensureTotalCapacity(total);
            for (model.objects, 0..) |obj, index| {
                // EQ.init rejects duplicate raw ids, so keys are unique.
                if (obj.id[0] == '#') about.putAssumeCapacity(obj.id[1..], @intCast(index));
            }
        }
        assert(about.count() == total);
        return .{ .model = model, .about = about };
    }

    fn deinit(ids: *IdIndex) void {
        ids.about.deinit();
    }

    /// Object index for a reference's local form, or null when dangling.
    fn get(ids: *const IdIndex, local_id: []const u8) ?u32 {
        if (ids.model.id_to_index.get(local_id)) |index| return index;
        return ids.about.get(local_id);
    }

    fn type_name_of(ids: *const IdIndex, local_id: []const u8) ?[]const u8 {
        const index = ids.get(local_id) orelse return null;
        return ids.model.objects[index].type_name;
    }
};

/// A property occurrence, normalized for comparison: references compare by
/// the local name of their target IRI so namespace variants collapse, text
/// by its trimmed content.
const Value = struct {
    comparable: []const u8,
    kind: Kind,

    const Kind = enum(u8) { text, reference };
};

const Evaluator = struct {
    gpa: std.mem.Allocator,
    model: *const EQ,
    rules: *const RuleSet,
    evaluation: *Evaluation,
    ids: *const IdIndex,
    referrers: *const ReferrerCounts,
    /// Per-constraint occurrence counts, reset per object.
    counts: std.ArrayList(u32),
    /// Violations of the object under evaluation; committed only when the
    /// object matches the shape's target (subjects-of targets are only
    /// known to match after the scan).
    staged: std.ArrayList(Violation),

    fn constraints_of(ev: *const Evaluator, shape: RuleSet.Shape) []const RuleSet.Constraint {
        const range = shape.constraints;
        assert(range.start + range.len <= ev.rules.constraints.len);
        return ev.rules.constraints[range.start .. range.start + range.len];
    }

    fn evaluate_shape(ev: *Evaluator, shape_index: u32, shape: RuleSet.Shape) !void {
        const constraints = ev.constraints_of(shape);
        try ev.counts.resize(ev.gpa, constraints.len);
        switch (shape.target) {
            .class => |class_name| {
                // Subtype targeting: a shape on ConductingEquipment applies
                // to Breaker; same is_a walk as the type filters.
                var it = ev.model.type_index.iterator();
                while (it.next()) |entry| {
                    if (!cim_types.is_a(entry.key_ptr.*, class_name)) continue;
                    const range = entry.value_ptr.*;
                    for (range.start..range.start + range.len) |object_index| {
                        try ev.evaluate_object(shape_index, shape, constraints, @intCast(object_index));
                    }
                }
            },
            .node => |id| {
                // A node target that resolves to nothing is valid; corpus
                // node targets are synthetic SPARQL hooks.
                const index = ev.ids.get(id) orelse return;
                try ev.evaluate_object(shape_index, shape, constraints, index);
            },
            .subjects_of => {
                for (0..ev.model.objects.len) |object_index| {
                    try ev.evaluate_object(shape_index, shape, constraints, @intCast(object_index));
                }
            },
        }
    }

    fn evaluate_object(
        ev: *Evaluator,
        shape_index: u32,
        shape: RuleSet.Shape,
        constraints: []const RuleSet.Constraint,
        object_index: u32,
    ) !void {
        assert(ev.counts.items.len == constraints.len);
        assert(object_index < ev.model.objects.len);
        const view = ev.model.view(ev.model.objects[object_index]);
        ev.staged.clearRetainingCapacity();
        @memset(ev.counts.items, 0);

        var matched = switch (shape.target) {
            .class, .node => true,
            // "rdf:type" targets every object; a property target matches
            // once the scan sees that child tag.
            .subjects_of => |property| std.mem.eql(u8, property, "rdf:type"),
        };
        try ev.scan_children(shape_index, shape, constraints, view, &matched);

        for (constraints, 0..) |constraint, i| {
            // Violations carry the global index into rules.constraints.
            const global: u32 = shape.constraints.start + @as(u32, @intCast(i));
            // Own-type paths run once per object; the type always exists.
            if (constraint.path_kind == .own_type) {
                ev.counts.items[i] = 1;
                const value = Value{ .comparable = view.type_name, .kind = .reference };
                try ev.stage_value_check(shape_index, constraint, global, view, value);
            }
            // Cardinality over counted occurrences. Inverse paths count
            // model-wide referrers; the loader guarantees inverse
            // constraints carry cardinality checks only.
            const count = if (constraint.path_kind == .inverse)
                ev.referrers.get(constraint.path, object_index)
            else
                ev.counts.items[i];
            const violated = switch (constraint.check) {
                .min_count => |n| count < n,
                .max_count => |n| count > n,
                else => false,
            };
            if (violated) try ev.stage(shape_index, global, view, "");
        }
        if (matched) try ev.commit_staged();
    }

    /// One pass over the object's child tags: subjects-of matching, the
    /// closed-shape check, occurrence counting, and value checks all ride
    /// the same scan to amortize memory access.
    fn scan_children(
        ev: *Evaluator,
        shape_index: u32,
        shape: RuleSet.Shape,
        constraints: []const RuleSet.Constraint,
        view: CimObjectView,
        matched: *bool,
    ) !void {
        const xml = ev.model.xml;
        const allowed = ev.rules.closed_paths_of(shape);

        var i = view.object_tag_idx + 1;
        while (i < view.closing_tag_idx) : (i += 1) {
            const tag = ev.model.boundaries[i];
            if (xml[tag.start + 1] == '/') continue;
            if (xml[tag.start + 1] == '!' or xml[tag.start + 1] == '?') continue;
            const tag_type = tag_index.extract_tag_type(xml, tag.start) catch continue;

            if (shape.target == .subjects_of) {
                if (std.mem.eql(u8, tag_type, shape.target.subjects_of)) matched.* = true;
            }
            if (shape.closed_paths != null) {
                // Property-not-in-profile: every child tag must be in the
                // allowed set.
                if (!contains_sorted(allowed, tag_type)) {
                    try ev.stage(shape_index, constraint_none, view, tag_type);
                }
            }
            // The value is extracted at most once per child tag, and only
            // when some constraint actually needs it.
            var value: ?Value = null;
            for (constraints, 0..) |constraint, ci| {
                const on_this_tag = switch (constraint.path_kind) {
                    .direct, .ref_type => std.mem.eql(u8, constraint.path, tag_type),
                    .own_type, .inverse => false,
                };
                if (!on_this_tag) continue;
                if (value == null) value = ev.child_value(i);
                // Violations carry the global index into rules.constraints.
                const global: u32 = shape.constraints.start + @as(u32, @intCast(ci));
                switch (constraint.path_kind) {
                    .direct => {
                        ev.counts.items[ci] += 1;
                        try ev.stage_value_check(shape_index, constraint, global, view, value.?);
                    },
                    .ref_type => {
                        // Follow the reference; a value exists only when it
                        // resolves under SHACL path traversal semantics.
                        const type_name = ev.resolve_reference_type(value.?) orelse continue;
                        ev.counts.items[ci] += 1;
                        const type_value = Value{ .comparable = type_name, .kind = .reference };
                        try ev.stage_value_check(shape_index, constraint, global, view, type_value);
                    },
                    .own_type, .inverse => unreachable,
                }
            }
        }
    }

    /// The occurrence's value: rdf:resource references by target local
    /// name, text content trimmed. In CIM XML references are self-closing
    /// child tags; properties carry text up to their closing tag.
    fn child_value(ev: *const Evaluator, boundary_index: u32) Value {
        const xml = ev.model.xml;
        const tag = ev.model.boundaries[boundary_index];
        const reference = tag_index.extract_rdf_resource_within(xml, tag.start, tag.end) catch null;
        if (reference) |ref| {
            return .{ .comparable = reference_local(ref), .kind = .reference };
        }
        if (xml[tag.end - 1] == '/') return .{ .comparable = "", .kind = .text };
        assert(boundary_index + 1 < ev.model.boundaries.len);
        const content = xml[tag.end + 1 .. ev.model.boundaries[boundary_index + 1].start];
        return .{ .comparable = std.mem.trim(u8, content, whitespace), .kind = .text };
    }

    fn resolve_reference_type(ev: *const Evaluator, value: Value) ?[]const u8 {
        if (value.kind != .reference) return null;
        return ev.ids.type_name_of(value.comparable);
    }

    fn stage_value_check(
        ev: *Evaluator,
        shape_index: u32,
        constraint: RuleSet.Constraint,
        constraint_index: u32,
        view: CimObjectView,
        value: Value,
    ) !void {
        if (!value_violates(ev.rules, ev.ids, constraint, value)) return;
        try ev.stage(shape_index, constraint_index, view, value.comparable);
    }

    fn stage(
        ev: *Evaluator,
        shape_index: u32,
        constraint_index: u32,
        view: CimObjectView,
        detail: []const u8,
    ) !void {
        try ev.staged.append(ev.gpa, .{
            .shape = shape_index,
            .constraint = constraint_index,
            .offset = ev.model.boundaries[view.object_tag_idx].start,
            .object_id = view.id,
            .detail = detail,
        });
    }

    fn commit_staged(ev: *Evaluator) !void {
        for (ev.staged.items) |violation| {
            if (ev.evaluation.violations.items.len >= violations_count_max) {
                ev.evaluation.truncated += 1;
                continue;
            }
            try ev.evaluation.violations.append(ev.gpa, violation);
        }
    }
};

/// Model-wide referrer counts for inverse-path cardinality. Counting who
/// references *me* by scanning everyone else per focus object would be
/// quadratic; instead one linear pass over all objects bumps, for each
/// child tag matching an inverse-rule property, the count of the
/// reference's target. Property-major layout:
/// counts[property_index * object_count + target_object_index].
const ReferrerCounts = struct {
    /// Distinct paths of the rule set's inverse constraints, sorted for
    /// binary search.
    properties: []const []const u8,
    counts: []u32,
    object_count: u32,

    fn build(gpa: std.mem.Allocator, ids: *const IdIndex, rules: *const RuleSet) !ReferrerCounts {
        const model = ids.model;
        assert(model.objects.len <= std.math.maxInt(u32));
        const properties = try distinct_inverse_properties(gpa, rules);
        errdefer gpa.free(properties);
        const counts = try gpa.alloc(u32, properties.len * model.objects.len);
        @memset(counts, 0);
        var referrers = ReferrerCounts{
            .properties = properties,
            .counts = counts,
            .object_count = @intCast(model.objects.len),
        };
        // Rule sets without inverse constraints skip the model scan.
        if (properties.len > 0) referrers.count_referrers(ids);
        return referrers;
    }

    fn deinit(rc: *ReferrerCounts, gpa: std.mem.Allocator) void {
        gpa.free(rc.properties);
        gpa.free(rc.counts);
    }

    /// The one linear pass: every reference child tag whose type matches an
    /// inverse-rule property and whose target resolves within the model
    /// bumps that target's count. Dangling targets count nothing; no focus
    /// object will ever ask for them.
    fn count_referrers(rc: *ReferrerCounts, ids: *const IdIndex) void {
        const model = ids.model;
        assert(rc.properties.len > 0);
        assert(rc.counts.len == rc.properties.len * model.objects.len);
        const xml = model.xml;
        for (model.objects) |obj| {
            const view = model.view(obj);
            var i = view.object_tag_idx + 1;
            while (i < view.closing_tag_idx) : (i += 1) {
                const tag = model.boundaries[i];
                if (xml[tag.start + 1] == '/') continue;
                if (xml[tag.start + 1] == '!' or xml[tag.start + 1] == '?') continue;
                const tag_type = tag_index.extract_tag_type(xml, tag.start) catch continue;
                const property_index = index_sorted(rc.properties, tag_type) orelse continue;
                const reference =
                    tag_index.extract_rdf_resource_within(xml, tag.start, tag.end) catch null;
                const ref = reference orelse continue;
                const target = ids.get(reference_local(ref)) orelse continue;
                rc.counts[property_index * rc.object_count + target] += 1;
            }
        }
    }

    /// Referrer count of `object_index` over the inverse property `path`.
    fn get(rc: *const ReferrerCounts, path: []const u8, object_index: u32) u32 {
        assert(object_index < rc.object_count);
        // Built from the same constraints the caller iterates over; the
        // property is always present.
        const property_index = index_sorted(rc.properties, path).?;
        return rc.counts[property_index * rc.object_count + object_index];
    }
};

/// Distinct paths of the rule set's inverse constraints, sorted and deduped
/// after an exact-size count/fill pass.
fn distinct_inverse_properties(
    gpa: std.mem.Allocator,
    rules: *const RuleSet,
) ![]const []const u8 {
    var total: u32 = 0;
    for (rules.constraints) |constraint| {
        if (constraint.path_kind == .inverse) total += 1;
    }
    const scratch = try gpa.alloc([]const u8, total);
    defer gpa.free(scratch);
    var cursor: u32 = 0;
    for (rules.constraints) |constraint| {
        if (constraint.path_kind != .inverse) continue;
        scratch[cursor] = constraint.path;
        cursor += 1;
    }
    assert(cursor == total);
    std.mem.sort([]const u8, scratch, {}, string_less_than);
    var distinct: u32 = 0;
    for (scratch) |path| {
        if (distinct > 0 and std.mem.eql(u8, scratch[distinct - 1], path)) continue;
        scratch[distinct] = path;
        distinct += 1;
    }
    assert(distinct <= total);
    return gpa.dupe([]const u8, scratch[0..distinct]);
}

fn string_less_than(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// One value against one check: the exhaustive switch the loader compiled.
/// No rule syntax survives into the evaluator. min/max_count are handled by
/// counting, never per value.
fn value_violates(
    rules: *const RuleSet,
    ids: *const IdIndex,
    constraint: RuleSet.Constraint,
    value: Value,
) bool {
    switch (constraint.check) {
        .min_count, .max_count => return false,
        .node_kind => |kind| return switch (kind) {
            .iri => value.kind != .reference,
            .literal => value.kind != .text,
        },
        .datatype => |datatype| {
            if (value.kind != .text) return true; // a reference where a literal must be
            return !datatype_valid(datatype, value.comparable);
        },
        .class => |class_name| {
            // The reference must resolve to an instance of the class
            // (subtypes ok). A dangling reference has no type: violation.
            if (value.kind != .reference) return true;
            const type_name = ids.type_name_of(value.comparable) orelse return true;
            return !cim_types.is_a(type_name, class_name);
        },
        .in => return !contains_sorted(rules.in_values_of(constraint), value.comparable),
        .has_value => |expected| return !std.mem.eql(u8, expected, value.comparable),
        .min_length => |n| return value.comparable.len < n,
        .max_length => |n| return value.comparable.len > n,
        .min_inclusive => |bound| {
            const number = std.fmt.parseFloat(f64, value.comparable) catch return true;
            return !(number >= bound);
        },
        .max_inclusive => |bound| {
            const number = std.fmt.parseFloat(f64, value.comparable) catch return true;
            return !(number <= bound);
        },
        .min_exclusive => |bound| {
            const number = std.fmt.parseFloat(f64, value.comparable) catch return true;
            return !(number > bound);
        },
        .max_exclusive => |bound| {
            const number = std.fmt.parseFloat(f64, value.comparable) catch return true;
            return !(number < bound);
        },
    }
}

/// Local name of an rdf:resource value: "#_id" resolves within the
/// document, full IRIs (enum values, cross-document references) by their
/// fragment or last path segment.
fn reference_local(reference: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, reference, '#')) |index| return reference[index + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, reference, '/')) |index| return reference[index + 1 ..];
    return reference;
}

fn contains_sorted(values: []const []const u8, needle: []const u8) bool {
    return index_sorted(values, needle) != null;
}

fn index_sorted(values: []const []const u8, needle: []const u8) ?usize {
    var low: usize = 0;
    var high: usize = values.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, values[mid], needle)) {
            .lt => low = mid + 1,
            .eq => return mid,
            .gt => high = mid,
        }
    }
    return null;
}

// ── xsd datatype validation ───────────────────────────────────────────────
// Lexical-form checks, deliberately structural rather than calendrical
// (2025-02-31 passes): the rules assert serialization shape, and a full
// calendar validator would be outside this validator's scope. Values arrive
// trimmed.
//
// This is also a deliberate divergence from strict SHACL, where sh:datatype
// compares the literal's datatype IRI. CIM XML never carries rdf:datatype
// (types live in the profile RDFS), so under strict semantics every plain
// "true" would fail xsd:boolean; a reference validator run on a raw
// instance file flags every typed attribute. Checking the lexical form
// keeps the rule's intent without that noise.

fn datatype_valid(datatype: RuleSet.Datatype, text: []const u8) bool {
    return switch (datatype) {
        // Any text is a valid xsd:string / xsd:anyURI.
        .string, .any_uri => true,
        .float, .double => float_valid(text),
        .decimal => decimal_valid(text),
        .integer => integer_valid(text),
        .boolean => boolean_valid(text),
        .date_time => date_time_valid(text),
        .date => date_valid(text),
        .time => time_valid(text),
        .duration => duration_valid(text),
        .g_month_day => g_month_day_valid(text),
    };
}

fn float_valid(text: []const u8) bool {
    if (text.len == 0) return false;
    _ = std.fmt.parseFloat(f64, text) catch return false;
    return true;
}

/// xsd:decimal: digits with optional sign and point; no exponent, no
/// INF/NaN (both of which parseFloat would accept).
fn decimal_valid(text: []const u8) bool {
    if (text.len == 0) return false;
    var digits_count: u32 = 0;
    for (text, 0..) |c, i| {
        if (std.ascii.isDigit(c)) {
            digits_count += 1;
            continue;
        }
        if ((c == '+' or c == '-') and i == 0) continue;
        if (c == '.') continue;
        return false;
    }
    if (digits_count == 0) return false;
    _ = std.fmt.parseFloat(f64, text) catch return false;
    return true;
}

fn integer_valid(text: []const u8) bool {
    _ = std.fmt.parseInt(i64, text, 10) catch return false;
    return true;
}

fn boolean_valid(text: []const u8) bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return true;
    if (std.mem.eql(u8, text, "1")) return true;
    return std.mem.eql(u8, text, "0");
}

fn all_digits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn two_digits_max(text: []const u8, max: u8) bool {
    if (text.len != 2) return false;
    if (!all_digits(text)) return false;
    const value = std.fmt.parseInt(u8, text, 10) catch return false;
    return value <= max;
}

/// YYYY-MM-DD (exactly 10 bytes).
fn date_lexical(text: []const u8) bool {
    if (text.len != 10) return false;
    if (!all_digits(text[0..4])) return false;
    if (text[4] != '-') return false;
    if (!two_digits_max(text[5..7], 12)) return false;
    if (text[5] == '0' and text[6] == '0') return false;
    if (text[7] != '-') return false;
    if (!two_digits_max(text[8..10], 31)) return false;
    return !(text[8] == '0' and text[9] == '0');
}

/// "" | "Z" | (+|-)hh:mm with hh <= 14.
fn zone_valid(text: []const u8) bool {
    if (text.len == 0) return true;
    if (text.len == 1) return text[0] == 'Z';
    if (text.len != 6) return false;
    if (text[0] != '+' and text[0] != '-') return false;
    if (!two_digits_max(text[1..3], 14)) return false;
    if (text[3] != ':') return false;
    return two_digits_max(text[4..6], 59);
}

/// hh:mm:ss with optional .fraction, then an optional zone.
fn time_with_zone_valid(text: []const u8) bool {
    if (text.len < 8) return false;
    if (!two_digits_max(text[0..2], 23)) return false;
    if (text[2] != ':') return false;
    if (!two_digits_max(text[3..5], 59)) return false;
    if (text[5] != ':') return false;
    if (!two_digits_max(text[6..8], 59)) return false;
    var rest = text[8..];
    if (rest.len > 0 and rest[0] == '.') {
        var fraction_len: usize = 0;
        while (1 + fraction_len < rest.len and std.ascii.isDigit(rest[1 + fraction_len])) {
            fraction_len += 1;
        }
        if (fraction_len == 0) return false;
        rest = rest[1 + fraction_len ..];
    }
    return zone_valid(rest);
}

fn date_time_valid(text: []const u8) bool {
    if (text.len < 19) return false;
    if (!date_lexical(text[0..10])) return false;
    if (text[10] != 'T') return false;
    return time_with_zone_valid(text[11..]);
}

fn date_valid(text: []const u8) bool {
    if (text.len < 10) return false;
    if (!date_lexical(text[0..10])) return false;
    return zone_valid(text[10..]);
}

fn time_valid(text: []const u8) bool {
    return time_with_zone_valid(text);
}

/// --MM-DD with an optional zone.
fn g_month_day_valid(text: []const u8) bool {
    if (text.len < 7) return false;
    if (text[0] != '-' or text[1] != '-') return false;
    if (!two_digits_max(text[2..4], 12)) return false;
    if (text[2] == '0' and text[3] == '0') return false;
    if (text[4] != '-') return false;
    if (!two_digits_max(text[5..7], 31)) return false;
    if (text[5] == '0' and text[6] == '0') return false;
    return zone_valid(text[7..]);
}

/// ISO 8601 duration: -?P(nY)?(nM)?(nD)?(T(nH)?(nM)?(n(.n)?S)?)? with at
/// least one component.
fn duration_valid(text: []const u8) bool {
    var pos: usize = 0;
    if (pos < text.len and text[pos] == '-') pos += 1;
    if (pos >= text.len or text[pos] != 'P') return false;
    pos += 1;
    var components: u32 = 0;
    var in_time = false;
    while (pos < text.len) {
        if (text[pos] == 'T') {
            if (in_time) return false;
            in_time = true;
            pos += 1;
            continue;
        }
        var digits_len: usize = 0;
        while (pos + digits_len < text.len and std.ascii.isDigit(text[pos + digits_len])) {
            digits_len += 1;
        }
        if (digits_len == 0) return false;
        pos += digits_len;
        // Fractional values are only legal for seconds.
        if (pos < text.len and text[pos] == '.') {
            pos += 1;
            var fraction_len: usize = 0;
            while (pos + fraction_len < text.len and std.ascii.isDigit(text[pos + fraction_len])) {
                fraction_len += 1;
            }
            if (fraction_len == 0) return false;
            pos += fraction_len;
            if (pos >= text.len or text[pos] != 'S' or !in_time) return false;
        }
        if (pos >= text.len) return false;
        const unit = text[pos];
        const unit_ok = if (in_time)
            unit == 'H' or unit == 'M' or unit == 'S'
        else
            unit == 'Y' or unit == 'M' or unit == 'D';
        if (!unit_ok) return false;
        pos += 1;
        components += 1;
    }
    return components > 0;
}

// ── Reporting ────────────────────────────────────────────────────────────

/// A named region of the model's XML buffer: the primary file, plus the
/// EQBD appended by --eqbd. Violations report the file their offset falls
/// in, with the line number local to that file.
pub const DataSegment = struct {
    name: []const u8,
    start: u32,
};

pub const ReportEntry = struct {
    rules: *const RuleSet,
    evaluation: *const Evaluation,
};

pub const ReportOptions = struct {
    list_skipped: bool = false,
};

pub const Totals = struct {
    violations: u64 = 0,
    warnings: u64 = 0,
    infos: u64 = 0,
    truncated: u64 = 0,
};

/// Write the full validation report and return the severity totals the
/// caller keys the exit code on. Line numbers come from one newline scan of
/// XML already in memory, done only when violations exist.
pub fn write_report(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    model: *const EQ,
    segments: []const DataSegment,
    entries: []const ReportEntry,
    options: ReportOptions,
) !Totals {
    assert(segments.len > 0);
    assert(segments[0].start == 0);

    for (entries) |entry| {
        try write_rules_header(w, entry.rules, options.list_skipped);
    }

    var totals = Totals{};
    var newlines: ?std.ArrayList(u32) = null;
    defer if (newlines) |*lines| lines.deinit(gpa);

    for (entries) |entry| {
        totals.truncated += entry.evaluation.truncated;
        for (entry.evaluation.violations.items) |violation| {
            if (newlines == null) {
                newlines = try tag_index.find_byte_simd(gpa, model.xml, '\n');
            }
            try write_violation(w, entry.rules, segments, newlines.?.items, violation, &totals);
        }
    }

    try write_note(gpa, w, entries);
    try w.print("summary: {d} violations, {d} warnings, {d} info\n", .{
        totals.violations, totals.warnings, totals.infos,
    });
    if (totals.truncated > 0) {
        try w.print("summary: {d} further violations truncated (limit {d})\n", .{
            totals.truncated, violations_count_max,
        });
    }
    return totals;
}

fn write_rules_header(w: *std.Io.Writer, rules: *const RuleSet, list_skipped: bool) !void {
    try w.print("rules: {s}", .{rules.source_name});
    if (rules.version.len > 0) try w.print(" (version {s})", .{rules.version});
    try w.print(": {d} shapes", .{rules.shapes.len});
    if (rules.unsupported.len > 0) {
        try w.print(", {d} rules not checked", .{rules.unsupported.len});
    }
    try w.writeByte('\n');
    if (list_skipped) {
        for (rules.unsupported) |unsupported| {
            try w.print("skipped: {s} (sh:{s})\n", .{ unsupported.name, unsupported.component });
        }
    }
}

fn write_violation(
    w: *std.Io.Writer,
    rules: *const RuleSet,
    segments: []const DataSegment,
    newlines: []const u32,
    violation: Violation,
    totals: *Totals,
) !void {
    const shape = rules.shapes[violation.shape];
    const severity, const name, const message = if (violation.constraint == constraint_none)
        .{ shape.severity, shape.name, shape.message }
    else blk: {
        const constraint = rules.constraints[violation.constraint];
        break :blk .{ constraint.severity, constraint.name, constraint.message };
    };
    switch (severity) {
        .violation => totals.violations += 1,
        .warning => totals.warnings += 1,
        .info => totals.infos += 1,
    }

    const segment = segment_of(segments, violation.offset);
    const line = line_of(newlines, violation.offset) - line_of(newlines, segment.start) + 1;
    try w.print("{s}:{d}: {s}: {s}: ", .{
        segment.name, line, @tagName(severity), name,
    });
    if (message.len > 0) {
        try w.print("{s}", .{message});
    } else if (violation.constraint != constraint_none) {
        // Published corpus messages are always present; this fallback keeps
        // bare shape files readable.
        const constraint = rules.constraints[violation.constraint];
        try w.print("violates {s} on {s}", .{ @tagName(constraint.check), constraint.path });
    } else {
        try w.print("property is not allowed by the closed shape", .{});
    }
    if (violation.detail.len > 0) {
        try w.print(" [{s}]", .{violation.detail});
    }
    try w.print(" (object {s})\n", .{violation.object_id});
}

fn segment_of(segments: []const DataSegment, offset: u32) DataSegment {
    assert(segments.len > 0);
    var result = segments[0];
    for (segments[1..]) |segment| {
        if (segment.start <= offset) result = segment;
    }
    return result;
}

/// 1-based line of a byte offset: the number of newlines strictly before it,
/// plus one.
fn line_of(newlines: []const u32, offset: u32) u32 {
    var low: usize = 0;
    var high: usize = newlines.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (newlines[mid] < offset) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return @intCast(low + 1);
}

const ComponentCount = struct {
    component: []const u8,
    count: u32,

    /// Largest group first; ties alphabetical, so output is deterministic.
    fn less_than(_: void, a: ComponentCount, b: ComponentCount) bool {
        if (a.count != b.count) return a.count > b.count;
        return std.mem.order(u8, a.component, b.component) == .lt;
    }
};

/// Rules we do not run are as much a part of the output as the violations
/// we find.
fn write_note(gpa: std.mem.Allocator, w: *std.Io.Writer, entries: []const ReportEntry) !void {
    var total: u64 = 0;
    var components = std.StringHashMap(u32).init(gpa);
    defer components.deinit();
    for (entries) |entry| {
        total += entry.rules.unsupported.len;
        for (entry.rules.unsupported) |unsupported| {
            const gop = try components.getOrPut(unsupported.component);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }
    if (total == 0) return;

    const sorted = try gpa.alloc(ComponentCount, components.count());
    defer gpa.free(sorted);
    var i: usize = 0;
    var it = components.iterator();
    while (it.next()) |entry| : (i += 1) {
        sorted[i] = .{ .component = entry.key_ptr.*, .count = entry.value_ptr.* };
    }
    assert(i == sorted.len);
    std.mem.sort(ComponentCount, sorted, {}, ComponentCount.less_than);

    try w.print("note: {d} rules not checked (", .{total});
    for (sorted, 0..) |entry, index| {
        if (index > 0) try w.writeAll(", ");
        try w.print("{d} sh:{s}", .{ entry.count, entry.component });
    }
    try w.writeAll("); see --list-skipped\n");
}
