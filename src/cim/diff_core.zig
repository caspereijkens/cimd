//! Shared semantic diff engine for `cimd diff`.
//!
//! Objects are matched by mRID within each CIM type; matched objects are then
//! compared as multisets of (name, value) child statements, so XML attribute
//! order, whitespace, and element order are ignored while repeated same-name
//! children (e.g. multiple Terminal references) each count individually.
//!
//! Matching is on the mRID exactly as the document spells it. `#_SW1` and
//! `#SW1` are different keys and pair with nothing, so a file that drops the
//! leading underscore reads as every object removed and re-added. That is a
//! deliberate difference from the SSH/TP overlay loaders, which do strip it:
//! an overlay must bind its patches onto an existing document and has no
//! choice, whereas a diff is reporting on the files as written, and two files
//! spelling their identifiers differently *have* differed. The failure is
//! loud rather than silent, which is the right way round -- normalizing here
//! would hide a real change in identifier convention behind a clean diff.
//! Applies to every profile alike; it is not specific to any of them.
//!
//! This module only detects changes. Rendering lives with the output formats:
//! the patch/json/summary reports in diff.zig and the IEC 61970-552
//! difference model in eqdiff.zig. Both feed off the same engine, so every
//! output format agrees on *what* changed and differs only in how it is
//! written.

const std = @import("std");
const assert = std.debug.assert;

const CimDocument = @import("document.zig").CimDocument;
const tag_index = @import("tag_index.zig");
const cim_types = @import("cim_types.zig");

// ── Statements ─────────────────────────────────────────────────────────────────

/// A statement *is* a child element: this walk started here and moved into
/// `tag_index` as the one child walk the whole codebase shares, so diff and
/// every other consumer now agree on what a child is by construction rather
/// than by four independently maintained skip loops. `kind` is part of the
/// match key alongside name and value -- the CIM schema fixes each property's
/// kind, so a flip between `<cim:X>#_A</cim:X>` and
/// `<cim:X rdf:resource="#_A"/>` is a real change even when the two coincide
/// lexically. `self_closing` is deliberately *not* compared: `<cim:X/>` and
/// `<cim:X></cim:X>` are the same empty literal.
pub const Statement = tag_index.Child;
pub const StatementIterator = tag_index.ChildIterator;

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
/// statements. Repeated child elements each count individually -- keying by
/// name alone would silently drop all but the last occurrence. Both result
/// lists are sorted by name for deterministic output.
pub fn change_set(
    gpa: std.mem.Allocator,
    view1: tag_index.CimObject,
    view2: tag_index.CimObject,
) !ChangeSet {
    var statements1: std.ArrayList(Statement) = .empty;
    defer statements1.deinit(gpa);
    var it1 = view1.children();
    while (it1.next()) |statement| try statements1.append(gpa, statement);

    var changes: ChangeSet = .{ .forward = .empty, .reverse = .empty };
    errdefer changes.deinit(gpa);

    const matched = try gpa.alloc(bool, statements1.items.len);
    defer gpa.free(matched);
    @memset(matched, false);

    // Bounded by the object's child count squared -- objects are small.
    var it2 = view2.children();
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
        fn less_than(_: void, a: Statement, b: Statement) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less_than);
}

/// ChangeSet for two views of the same object, or null when they are
/// semantically identical. Fast path: byte-identical XML is semantically
/// identical -- most objects in two versions of the same grid model are
/// untouched (and exporters keep formatting stable), so a single memcmp
/// skips the statement walk for the overwhelming majority of matched objects.
pub fn object_changes(
    gpa: std.mem.Allocator,
    view1: tag_index.CimObject,
    view2: tag_index.CimObject,
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
    model: *CimDocument,
    id: []const u8,
    type_name: []const u8,
) ?tag_index.CimObject {
    const other = model.object_by_id(id) orelse return null;
    if (!same_cim_type(other.type_name(), type_name)) return null;
    return other;
}

/// Match one type's objects by mRID across the two models and report every
/// difference to `emitter`, which must provide:
///   added(view)               -- object only in model2
///   removed(view)             -- object only in model1
///   changed(view1, view2, *const ChangeSet) -- object in both, statements differ
/// The ChangeSet is owned by this function and valid only during the call.
pub fn match_type(
    gpa: std.mem.Allocator,
    model1: *CimDocument,
    model2: *CimDocument,
    type_name: []const u8,
    emitter: anytype,
) !TypeStats {
    var stats = TypeStats{ .type_name = type_name, .added = 0, .removed = 0, .changed = 0 };

    const objects1 = model1.objects_by_type(type_name);
    const objects2 = model2.objects_by_type(type_name);

    for (objects1) |obj1| {
        if (same_type_counterpart(model2, obj1.id(), type_name)) |other| {
            const view1 = obj1;
            if (try object_changes(gpa, view1, other)) |changes_owned| {
                var changes = changes_owned;
                defer changes.deinit(gpa);
                try emitter.changed(view1, other, &changes);
                stats.changed += 1;
            }
            continue;
        }
        try emitter.removed(obj1);
        stats.removed += 1;
    }

    for (objects2) |obj2| {
        if (same_type_counterpart(model1, obj2.id(), type_name) != null) continue;
        try emitter.added(obj2);
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
    model1: *const CimDocument,
    model2: *const CimDocument,
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

/// How a single mRID relates across the two models -- the shared decision
/// logic behind both single-object output modes.
pub const SingleMatch = union(enum) {
    not_found,
    /// Found, but its type does not match the filter; carries the actual type.
    type_mismatch: []const u8,
    /// Only in model2.
    added: tag_index.CimObject,
    /// Only in model1.
    removed: tag_index.CimObject,
    /// Same mRID, different CIM type: a replacement, not a property change.
    /// Renderers report the old object as removed and the new one as added --
    /// a child-statement delta cannot retype an object.
    replaced: struct { old: tag_index.CimObject, new: tag_index.CimObject },
    /// Same type in both models; statements may still differ.
    matched: struct { old: tag_index.CimObject, new: tag_index.CimObject },
};

/// Classify `mrid` across the two models. O(1) lookups via id_to_index.
/// If `type_filter` is set the object's type is verified in whichever
/// model(s) it is found.
pub fn match_single(
    model1: *CimDocument,
    model2: *CimDocument,
    mrid: []const u8,
    type_filter: ?[]const u8,
) SingleMatch {
    const v1 = model1.object_by_id(mrid);
    const v2 = model2.object_by_id(mrid);

    if (v1 == null and v2 == null) return .not_found;

    if (v1) |v| if (!cim_types.matches_filter(v.type_name(), type_filter)) return .{ .type_mismatch = v.type_name() };
    if (v2) |v| if (!cim_types.matches_filter(v.type_name(), type_filter)) return .{ .type_mismatch = v.type_name() };

    if (v1 == null) return .{ .added = v2.? };
    if (v2 == null) return .{ .removed = v1.? };
    if (!same_cim_type(v1.?.type_name(), v2.?.type_name())) {
        return .{ .replaced = .{ .old = v1.?, .new = v2.? } };
    }
    return .{ .matched = .{ .old = v1.?, .new = v2.? } };
}

// ── FullModel ─────────────────────────────────────────────────────────────────

/// The exchange-metadata header object, when the model has one.
pub fn full_model(model: *const CimDocument) ?tag_index.CimObject {
    const objects = model.objects_by_type("FullModel");
    if (objects.len == 0) return null;
    return objects[0];
}

/// Semantic comparison of the two FullModel headers: differing presence, id,
/// or statement multiset all count as a difference.
pub fn full_models_differ(gpa: std.mem.Allocator, model1: *const CimDocument, model2: *const CimDocument) !bool {
    const fm1 = full_model(model1) orelse return full_model(model2) != null;
    const fm2 = full_model(model2) orelse return true;

    if (!std.mem.eql(u8, fm1.id(), fm2.id())) return true;
    if (std.mem.eql(u8, fm1.raw_xml(), fm2.raw_xml())) return false;

    var changes = try change_set(gpa, fm1, fm2);
    defer changes.deinit(gpa);
    return changes.any();
}
