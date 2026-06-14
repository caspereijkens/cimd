//! Shared semantic diff engine for `cimd diff`.
//!
//! Objects are matched by mRID within each CIM type; matched objects are then
//! compared as multisets of (name, value) child statements, so XML attribute
//! order, whitespace, and element order are ignored while repeated same-name
//! children (e.g. multiple Terminal references) each count individually.
//!
//! This module only detects changes. Rendering lives with the output formats:
//! the patch/json/summary reports in diff.zig and the IEC 61970-552
//! difference model in eqdiff.zig. Both feed off the same engine, so every
//! output format agrees on *what* changed and differs only in how it is
//! written.

const std = @import("std");
const assert = std.debug.assert;

const EQ = @import("cgmes/eq.zig").EQ;
const tag_index = @import("cgmes/tag_index.zig");
const cim_types = @import("cgmes/cim_types.zig");

// ── Statements ────────────────────────────────────────────────────────────────

/// One child element of a CIM object.
pub const Statement = struct {
    /// Tag name with namespace prefix stripped — the comparison key.
    name: []const u8,
    /// Text content for property elements, rdf:resource for references —
    /// the comparison value.
    value: []const u8,
    /// Part of the match key alongside name and value: the CIM schema fixes
    /// each property's kind, so a flip between <cim:X>#_A</cim:X> and
    /// <cim:X rdf:resource="#_A"/> is a real change even when name and value
    /// coincide lexically.
    kind: Kind,
    /// The complete element slice, for renderers that copy it verbatim.
    raw: []const u8,

    pub const Kind = enum {
        /// Literal text content (including empty, in either syntax).
        property,
        /// Carries an rdf:resource attribute.
        reference,
    };
};

/// Walk the child elements of an object in document order. Skips comments,
/// processing instructions, and malformed tags, mirroring the tolerance of
/// CimObjectView.getAllProperties/getAllReferences.
pub const StatementIterator = struct {
    xml: []const u8,
    boundaries: []const tag_index.TagBoundary,
    next_idx: u32,
    end_idx: u32,

    pub fn init(view: tag_index.CimObjectView) StatementIterator {
        return .{
            .xml = view.xml,
            .boundaries = view.boundaries,
            .next_idx = view.object_tag_idx + 1,
            .end_idx = view.closing_tag_idx,
        };
    }

    pub fn next(self: *StatementIterator) ?Statement {
        while (self.next_idx < self.end_idx) {
            const i = self.next_idx;
            const tag = self.boundaries[i];
            self.next_idx += 1;

            switch (self.xml[tag.start + 1]) {
                '/', '!', '?' => continue, // closing tag, comment, or PI
                else => {},
            }
            const name = tag_index.extract_tag_type(self.xml, tag.start) catch continue;

            // Self-closing: a reference when it carries rdf:resource. The
            // kind follows the attribute, not the syntax — a self-closing
            // element without rdf:resource is an empty literal, equivalent
            // to <name></name>.
            if (self.xml[tag.end - 1] == '/') {
                const resource = tag_index.extract_rdf_resource_within(self.xml, tag.start, tag.end) catch null;
                return .{
                    .name = name,
                    .value = resource orelse "",
                    .kind = if (resource != null) .reference else .property,
                    .raw = self.xml[tag.start .. tag.end + 1],
                };
            }

            // Expanded element, closed by the next boundary. CIM properties
            // never nest — the same assumption getAllProperties makes when
            // slicing content up to the following tag. As above, the kind
            // follows the rdf:resource attribute, not the element form:
            // <name rdf:resource="#_A"></name> is the expanded serialization
            // of the self-closing reference, not a literal.
            const closing = self.boundaries[i + 1];
            self.next_idx = i + 2;
            const resource = tag_index.extract_rdf_resource_within(self.xml, tag.start, tag.end) catch null;
            return .{
                .name = name,
                .value = resource orelse self.xml[tag.end + 1 .. closing.start],
                .kind = if (resource != null) .reference else .property,
                .raw = self.xml[tag.start .. closing.end + 1],
            };
        }
        return null;
    }
};

// ── Statement comparison ──────────────────────────────────────────────────────

/// The statements an object gained (forward) and lost (reverse) between the
/// two models. Borrowed slices into the model XML; only the lists are owned.
pub const ChangeSet = struct {
    forward: std.ArrayList(Statement),
    reverse: std.ArrayList(Statement),

    pub fn any(self: *const ChangeSet) bool {
        return self.forward.items.len > 0 or self.reverse.items.len > 0;
    }

    pub fn deinit(self: *ChangeSet, gpa: std.mem.Allocator) void {
        self.forward.deinit(gpa);
        self.reverse.deinit(gpa);
    }
};

/// Compare two views of the same object as multisets of (name, value)
/// statements. Repeated child elements each count individually — keying by
/// name alone would silently drop all but the last occurrence. Both result
/// lists are sorted by name for deterministic output.
pub fn change_set(
    gpa: std.mem.Allocator,
    view1: tag_index.CimObjectView,
    view2: tag_index.CimObjectView,
) !ChangeSet {
    var statements1: std.ArrayList(Statement) = .empty;
    defer statements1.deinit(gpa);
    var it1 = StatementIterator.init(view1);
    while (it1.next()) |statement| try statements1.append(gpa, statement);

    var changes: ChangeSet = .{ .forward = .empty, .reverse = .empty };
    errdefer changes.deinit(gpa);

    const matched = try gpa.alloc(bool, statements1.items.len);
    defer gpa.free(matched);
    @memset(matched, false);

    // Bounded by the object's child count squared — objects are small.
    var it2 = StatementIterator.init(view2);
    outer: while (it2.next()) |new_statement| {
        for (statements1.items, matched) |old_statement, *was_matched| {
            if (!was_matched.* and
                old_statement.kind == new_statement.kind and
                std.mem.eql(u8, old_statement.name, new_statement.name) and
                std.mem.eql(u8, old_statement.value, new_statement.value))
            {
                was_matched.* = true;
                continue :outer;
            }
        }
        try changes.forward.append(gpa, new_statement);
    }
    for (statements1.items, matched) |old_statement, was_matched| {
        if (!was_matched) try changes.reverse.append(gpa, old_statement);
    }

    // Document order of the children is per-side; sort for stable output.
    sort_by_name(changes.forward.items);
    sort_by_name(changes.reverse.items);
    return changes;
}

fn sort_by_name(statements: []Statement) void {
    // Stable: repeated same-named statements keep their document order.
    std.sort.insertion(Statement, statements, {}, struct {
        fn lessThan(_: void, a: Statement, b: Statement) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
}

/// ChangeSet for two views of the same object, or null when they are
/// semantically identical. Fast path: byte-identical XML is semantically
/// identical — most objects in two versions of the same grid model are
/// untouched (and exporters keep formatting stable), so a single memcmp
/// skips the statement walk for the overwhelming majority of matched objects.
pub fn object_changes(
    gpa: std.mem.Allocator,
    view1: tag_index.CimObjectView,
    view2: tag_index.CimObjectView,
) !?ChangeSet {
    if (std.mem.eql(u8, view1.raw_xml(), view2.raw_xml())) return null;
    var changes = try change_set(gpa, view1, view2);
    if (!changes.any()) {
        changes.deinit(gpa);
        return null;
    }
    return changes;
}

// ── Per-type matching ─────────────────────────────────────────────────────────

pub const TypeStats = struct {
    type_name: []const u8,
    added: u32,
    removed: u32,
    changed: u32,

    pub fn any(self: TypeStats) bool {
        return self.added > 0 or self.removed > 0 or self.changed > 0;
    }
};

/// CIM type equality is the boundary between a matched object and a typed
/// remove+add replacement. Keep the rule shared by bulk and single-mRID diff.
fn same_cim_type(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Return the counterpart only when it has the same mRID and CIM type.
/// Missing or retyped objects both fall through to bulk remove/add handling.
fn same_type_counterpart(
    model: *EQ,
    id: []const u8,
    type_name: []const u8,
) ?tag_index.CimObjectView {
    const other = model.getObjectById(id) orelse return null;
    if (!same_cim_type(other.type_name, type_name)) return null;
    return other;
}

/// Match one type's objects by mRID across the two models and report every
/// difference to `emitter`, which must provide:
///   added(view)               — object only in model2
///   removed(view)             — object only in model1
///   changed(view1, view2, *const ChangeSet) — object in both, statements differ
/// The ChangeSet is owned by this function and valid only during the call.
pub fn match_type(
    gpa: std.mem.Allocator,
    model1: *EQ,
    model2: *EQ,
    type_name: []const u8,
    emitter: anytype,
) !TypeStats {
    var stats = TypeStats{ .type_name = type_name, .added = 0, .removed = 0, .changed = 0 };

    const objects1 = model1.get_objects_by_type(type_name);
    const objects2 = model2.get_objects_by_type(type_name);

    for (objects1) |obj1| {
        if (same_type_counterpart(model2, obj1.id, type_name)) |other| {
            const view1 = model1.view(obj1);
            if (try object_changes(gpa, view1, other)) |changes_owned| {
                var changes = changes_owned;
                defer changes.deinit(gpa);
                try emitter.changed(view1, other, &changes);
                stats.changed += 1;
            }
            continue;
        }
        try emitter.removed(model1.view(obj1));
        stats.removed += 1;
    }

    for (objects2) |obj2| {
        if (same_type_counterpart(model1, obj2.id, type_name) != null) continue;
        try emitter.added(model2.view(obj2));
        stats.added += 1;
    }
    return stats;
}

/// Alphabetically sorted union of the type names present in either model.
/// Sorting fixes the output order: hash-map iteration order would shuffle
/// types between runs of different inputs, which breaks diff-of-diffs
/// workflows. Caller owns the returned slice (names are borrowed).
pub fn type_name_union(
    gpa: std.mem.Allocator,
    model1: *const EQ,
    model2: *const EQ,
) ![][]const u8 {
    const types1 = try model1.sorted_type_counts(gpa);
    defer gpa.free(types1);
    const types2 = try model2.sorted_type_counts(gpa);
    defer gpa.free(types2);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, types1.len + types2.len);

    var i: usize = 0;
    var j: usize = 0;
    while (i < types1.len and j < types2.len) {
        switch (std.mem.order(u8, types1[i].type_name, types2[j].type_name)) {
            .lt => {
                out.appendAssumeCapacity(types1[i].type_name);
                i += 1;
            },
            .gt => {
                out.appendAssumeCapacity(types2[j].type_name);
                j += 1;
            },
            .eq => {
                out.appendAssumeCapacity(types1[i].type_name);
                i += 1;
                j += 1;
            },
        }
    }
    while (i < types1.len) : (i += 1) out.appendAssumeCapacity(types1[i].type_name);
    while (j < types2.len) : (j += 1) out.appendAssumeCapacity(types2[j].type_name);

    return out.toOwnedSlice(gpa);
}

// ── Single-object matching ────────────────────────────────────────────────────

/// Result of a single-mRID diff, returned to main.zig so it can emit errors
/// via print.zig without the diff modules calling process.exit directly.
pub const SingleDiffStatus = union(enum) {
    /// mRID does not exist in either model.
    not_found,
    /// mRID exists but its type does not match the expected --type filter.
    /// Carries the actual type name found in the model.
    type_mismatch: []const u8,
    /// Diff completed normally. True = had diffs, false = identical.
    diff: bool,
};

/// How a single mRID relates across the two models — the shared decision
/// logic behind both single-object output modes.
pub const SingleMatch = union(enum) {
    not_found,
    /// Found, but its type does not match the filter; carries the actual type.
    type_mismatch: []const u8,
    /// Only in model2.
    added: tag_index.CimObjectView,
    /// Only in model1.
    removed: tag_index.CimObjectView,
    /// Same mRID, different CIM type: a replacement, not a property change.
    /// Renderers report the old object as removed and the new one as added —
    /// a child-statement delta cannot retype an object.
    replaced: struct { old: tag_index.CimObjectView, new: tag_index.CimObjectView },
    /// Same type in both models; statements may still differ.
    matched: struct { old: tag_index.CimObjectView, new: tag_index.CimObjectView },
};

/// Classify `mrid` across the two models. O(1) lookups via id_to_index.
/// If `type_filter` is set the object's type is verified in whichever
/// model(s) it is found.
pub fn match_single(
    model1: *EQ,
    model2: *EQ,
    mrid: []const u8,
    type_filter: ?[]const u8,
) SingleMatch {
    const v1 = model1.getObjectById(mrid);
    const v2 = model2.getObjectById(mrid);

    if (v1 == null and v2 == null) return .not_found;

    if (v1) |v| if (!cim_types.matches_filter(v.type_name, type_filter)) return .{ .type_mismatch = v.type_name };
    if (v2) |v| if (!cim_types.matches_filter(v.type_name, type_filter)) return .{ .type_mismatch = v.type_name };

    if (v1 == null) return .{ .added = v2.? };
    if (v2 == null) return .{ .removed = v1.? };
    if (!same_cim_type(v1.?.type_name, v2.?.type_name)) {
        return .{ .replaced = .{ .old = v1.?, .new = v2.? } };
    }
    return .{ .matched = .{ .old = v1.?, .new = v2.? } };
}

// ── FullModel ─────────────────────────────────────────────────────────────────

/// The exchange-metadata header object, when the model has one.
pub fn full_model(model: *const EQ) ?tag_index.CimObjectView {
    const objects = model.get_objects_by_type("FullModel");
    if (objects.len == 0) return null;
    return model.view(objects[0]);
}

/// Semantic comparison of the two FullModel headers: differing presence, id,
/// or statement multiset all count as a difference.
pub fn full_models_differ(gpa: std.mem.Allocator, model1: *const EQ, model2: *const EQ) !bool {
    const fm1 = full_model(model1) orelse return full_model(model2) != null;
    const fm2 = full_model(model2) orelse return true;

    if (!std.mem.eql(u8, fm1.id, fm2.id)) return true;
    if (std.mem.eql(u8, fm1.raw_xml(), fm2.raw_xml())) return false;

    var changes = try change_set(gpa, fm1, fm2);
    defer changes.deinit(gpa);
    return changes.any();
}
