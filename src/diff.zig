//! Semantic diff between two CIM models.
//!
//! Objects are matched by mRID across both models. Properties and references
//! are then compared field-by-field so that XML attribute order or whitespace
//! differences are ignored.
//!
//! This module implements the report formats: patch (modelled after
//! `git diff`: grouped by CIM type, +/- lines), NDJSON (one object per
//! change, suitable for piping to jq), and summary (per-type counts).
//! The CLI's default output, the IEC 61970-552 difference model, lives in
//! eqdiff.zig and shares the matching semantics implemented here.
//!
//! Exit-code contract (enforced by main.zig, not here):
//!   0  identical
//!   1  differences found
//!   2  usage error

const std = @import("std");
const assert = std.debug.assert;
const EQ = @import("cgmes/eq.zig").EQ;

const tag_index = @import("cgmes/tag_index.zig");
const cim_types = @import("cgmes/cim_types.zig");

pub const DiffOptions = struct {
    /// When set, only objects of this CIM type are compared.
    type_filter: ?[]const u8 = null,
    /// Report format. The CLI's default output is the EQDIFF difference model
    /// (see eqdiff.zig); the report formats here are mutually exclusive by
    /// construction, so no flag-combination validation is needed downstream.
    format: Format = .patch,

    pub const Format = enum {
        /// Human-readable text modelled after `git diff`.
        patch,
        /// NDJSON: one object per change, suitable for piping to jq.
        json,
        /// Per-type counts only; no per-property detail.
        summary,
    };
};

/// Result of a single-mRID diff. Returned to main.zig so it can emit errors
/// via print.zig without diff.zig needing to call process.exit directly.
pub const SingleDiffStatus = union(enum) {
    /// mRID does not exist in either model.
    not_found,
    /// mRID exists but its type does not match the expected --type filter.
    /// Carries the actual type name found in the model.
    type_mismatch: []const u8,
    /// Diff completed normally. True = had diffs, false = identical.
    diff: bool,
};

pub const TypeStats = struct {
    type_name: []const u8,
    added: u32,
    removed: u32,
    changed: u32,

    fn any(self: TypeStats) bool {
        return self.added > 0 or self.removed > 0 or self.changed > 0;
    }
};

// ── Entry point ───────────────────────────────────────────────────────────────

/// Compare `model1` and `model2` and write the diff to `writer`.
/// Returns true when any differences were found (so main.zig can exit 1).
pub fn diff_models(
    gpa: std.mem.Allocator,
    model1: *EQ,
    model2: *EQ,
    path1: []const u8,
    path2: []const u8,
    options: DiffOptions,
    writer: anytype,
) !bool {
    var had_diffs = false;

    var type_counts1 = try model1.getTypeCounts(gpa);
    defer type_counts1.deinit();
    var type_counts2 = try model2.getTypeCounts(gpa);
    defer type_counts2.deinit();

    const type_names = try type_name_union(gpa, &type_counts1, &type_counts2);
    defer gpa.free(type_names);

    if (options.format == .patch) {
        try writer.print("--- {s}\n+++ {s}\n", .{ path1, path2 });
    }

    for (type_names) |type_name| {
        if (!cim_types.matches_filter(type_name, options.type_filter)) continue;
        const stats = try diff_type(gpa, model1, model2, type_name, options, writer);
        if (stats.any()) {
            had_diffs = true;
            if (options.format == .summary) {
                try writer.print("{s}  +{d} -{d} ~{d}\n", .{
                    type_name, stats.added, stats.removed, stats.changed,
                });
            }
        }
    }

    return had_diffs;
}

/// Alphabetically sorted union of the type names present in either model.
/// Sorting fixes the output order: hash-map iteration order would shuffle
/// types between runs of different inputs, which breaks diff-of-diffs
/// workflows. Caller owns the returned slice (names are borrowed).
pub fn type_name_union(
    gpa: std.mem.Allocator,
    type_counts1: *const std.StringHashMap(u32),
    type_counts2: *const std.StringHashMap(u32),
) ![][]const u8 {
    var type_set = std.StringHashMapUnmanaged(void){};
    defer type_set.deinit(gpa);

    var it1 = type_counts1.keyIterator();
    while (it1.next()) |key| try type_set.put(gpa, key.*, {});
    var it2 = type_counts2.keyIterator();
    while (it2.next()) |key| try type_set.put(gpa, key.*, {});

    const type_names = try gpa.alloc([]const u8, type_set.count());
    errdefer gpa.free(type_names);

    var i: usize = 0;
    var it = type_set.keyIterator();
    while (it.next()) |key| : (i += 1) type_names[i] = key.*;
    assert(i == type_names.len);

    std.mem.sort([]const u8, type_names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return type_names;
}

// ── Single-mRID diff ──────────────────────────────────────────────────────────

/// Diff a single object identified by `mrid` across the two models.
/// Bypasses the full type-union loop — O(1) lookups via id_to_index.
///
/// If `options.type_filter` is set the object's type is verified in whichever
/// model(s) it is found; a mismatch returns `.type_mismatch` so the caller
/// can emit a meaningful error.
pub fn diff_single(
    gpa: std.mem.Allocator,
    model1: *EQ,
    model2: *EQ,
    mrid: []const u8,
    path1: []const u8,
    path2: []const u8,
    options: DiffOptions,
    writer: anytype,
) !SingleDiffStatus {
    const v1 = model1.getObjectById(mrid);
    const v2 = model2.getObjectById(mrid);

    if (v1 == null and v2 == null) return .not_found;

    // Type verification: check whichever model has the object.
    if (v1) |v| if (!cim_types.matches_filter(v.type_name, options.type_filter)) return .{ .type_mismatch = v.type_name };
    if (v2) |v| if (!cim_types.matches_filter(v.type_name, options.type_filter)) return .{ .type_mismatch = v.type_name };

    const type_name = if (v1) |v| v.type_name else v2.?.type_name;

    if (options.format == .patch) {
        try writer.print("--- {s}\n+++ {s}\n", .{ path1, path2 });
    }

    // Object only in model2 — added.
    if (v1 == null) {
        switch (options.format) {
            .summary => try writer.print("{s}  +1 -0 ~0\n", .{type_name}),
            .json => try emit_object_status_json(writer, type_name, mrid, "added"),
            .patch => {
                const name = (try v2.?.getProperty("IdentifiedObject.name")) orelse "";
                try writer.print("+ {s}  \"{s}\"\n", .{ mrid, name });
            },
        }
        return .{ .diff = true };
    }

    // Object only in model1 — removed.
    if (v2 == null) {
        switch (options.format) {
            .summary => try writer.print("{s}  +0 -1 ~0\n", .{type_name}),
            .json => try emit_object_status_json(writer, type_name, mrid, "removed"),
            .patch => {
                const name = (try v1.?.getProperty("IdentifiedObject.name")) orelse "";
                try writer.print("- {s}  \"{s}\"\n", .{ mrid, name });
            },
        }
        return .{ .diff = true };
    }

    // Same mRID, different CIM type: a replacement, not a property change.
    // Mirrors diff_models, which matches within concrete types and reports
    // the object as removed from the old type and added to the new one.
    const type2 = v2.?.type_name;
    if (!std.mem.eql(u8, type_name, type2)) {
        switch (options.format) {
            .summary => {
                try writer.print("{s}  +0 -1 ~0\n", .{type_name});
                try writer.print("{s}  +1 -0 ~0\n", .{type2});
            },
            .json => {
                try emit_object_status_json(writer, type_name, mrid, "removed");
                try emit_object_status_json(writer, type2, mrid, "added");
            },
            .patch => {
                const name1 = (try v1.?.getProperty("IdentifiedObject.name")) orelse "";
                const name2 = (try v2.?.getProperty("IdentifiedObject.name")) orelse "";
                try writer.print("- {s}  \"{s}\"\n", .{ mrid, name1 });
                try writer.print("+ {s}  \"{s}\"\n", .{ mrid, name2 });
            },
        }
        return .{ .diff = true };
    }

    // Object in both models — compare.
    const changed = try diff_object(gpa, type_name, mrid, v1.?, v2.?, options, writer);
    if (changed and options.format == .summary) {
        try writer.print("{s}  +0 -0 ~1\n", .{type_name});
    }
    return .{ .diff = changed };
}

// ── Per-type comparison ───────────────────────────────────────────────────────

/// In text mode, buffer all object lines so the @@ TypeName @@ header can be
/// prepended after we know whether this type has any diffs. In JSON/summary
/// mode write directly to the real writer — no header is needed.
fn diff_type(
    gpa: std.mem.Allocator,
    model1: *EQ,
    model2: *EQ,
    type_name: []const u8,
    options: DiffOptions,
    writer: anytype,
) !TypeStats {
    if (options.format != .patch) {
        return diff_type_core(gpa, model1, model2, type_name, options, writer);
    }
    var screen: std.Io.Writer.Allocating = .init(gpa);
    defer screen.deinit();
    const screen_writer = &screen.writer;
    const stats = try diff_type_core(gpa, model1, model2, type_name, options, screen_writer);
    if (stats.any()) {
        try writer.print("\n@@ {s} @@\n", .{type_name});
        try writer.writeAll(screen.written());
    }
    return stats;
}

fn diff_type_core(
    gpa: std.mem.Allocator,
    model1: *EQ,
    model2: *EQ,
    type_name: []const u8,
    options: DiffOptions,
    writer: anytype,
) !TypeStats {
    var stats = TypeStats{ .type_name = type_name, .added = 0, .removed = 0, .changed = 0 };

    const objects1 = model1.get_objects_by_type(type_name);
    const objects2 = model2.get_objects_by_type(type_name);

    var map = std.StringHashMap(u32).init(gpa);
    defer map.deinit();
    try map.ensureTotalCapacity(@intCast(objects2.len));
    for (objects2, 0..) |obj2, idx| map.putAssumeCapacity(obj2.id, @intCast(idx));

    var matched = try gpa.alloc(bool, objects2.len);
    defer gpa.free(matched);
    @memset(matched, false);
    assert(matched.len == objects2.len);

    for (objects1) |obj1| {
        if (map.get(obj1.id)) |idx| {
            matched[idx] = true;
            const view1 = model1.view(obj1);
            const view2 = model2.view(objects2[idx]);
            if (try diff_object(gpa, type_name, obj1.id, view1, view2, options, writer)) {
                stats.changed += 1;
            }
        } else {
            stats.removed += 1;
            switch (options.format) {
                .summary => {},
                .json => try emit_object_status_json(writer, type_name, obj1.id, "removed"),
                .patch => {
                    const name = (try model1.view(obj1).getProperty("IdentifiedObject.name")) orelse "";
                    try writer.print("- {s}  \"{s}\"\n", .{ obj1.id, name });
                },
            }
        }
    }

    for (objects2, matched) |obj2, was_matched| {
        if (!was_matched) {
            stats.added += 1;
            switch (options.format) {
                .summary => {},
                .json => try emit_object_status_json(writer, type_name, obj2.id, "added"),
                .patch => {
                    const name = (try model2.view(obj2).getProperty("IdentifiedObject.name")) orelse "";
                    try writer.print("+ {s}  \"{s}\"\n", .{ obj2.id, name });
                },
            }
        }
    }

    return stats;
}

// ── Per-object property comparison ───────────────────────────────────────────

/// Diff properties and references of two views of the same mRID.
/// Emits output only when changes are found. Returns true if any field differed.
fn diff_object(
    gpa: std.mem.Allocator,
    type_name: []const u8,
    mrid: []const u8,
    view1: tag_index.CimObjectView,
    view2: tag_index.CimObjectView,
    options: DiffOptions,
    writer: anytype,
) !bool {
    // Fast path: byte-identical XML is semantically identical. Most objects in
    // two versions of the same grid model are untouched (and exporters keep
    // formatting stable), so this single memcmp skips building four hash maps
    // for the overwhelming majority of matched objects.
    if (std.mem.eql(u8, view1.raw_xml(), view2.raw_xml())) return false;

    var props1 = try view1.getAllProperties(gpa);
    defer props1.deinit();
    var props2 = try view2.getAllProperties(gpa);
    defer props2.deinit();
    var refs1 = try view1.getAllReferences(gpa);
    defer refs1.deinit();
    var refs2 = try view2.getAllReferences(gpa);
    defer refs2.deinit();

    if (!compare_maps(props1, props2) and !compare_maps(refs1, refs2)) return false;

    switch (options.format) {
        .summary => {},
        .json => {
            try writer.writeByte('{');
            try emit_json_field(writer, "type", type_name);
            try writer.writeByte(',');
            try emit_json_field(writer, "mrid", mrid);
            try writer.writeAll(",\"status\":\"changed\",\"changes\":[");
            var first = true;
            first = try emit_field_diff_json(props1, props2, writer, first);
            _ = try emit_field_diff_json(refs1, refs2, writer, first);
            try writer.writeAll("]}\n");
        },
        .patch => {
            const name = props1.get("IdentifiedObject.name") orelse props2.get("IdentifiedObject.name") orelse "";
            try writer.print("~ {s}  \"{s}\"\n", .{ mrid, name });
            try emit_field_diff_text(props1, props2, writer);
            try emit_field_diff_text(refs1, refs2, writer);
        },
    }

    return true;
}

// ── JSON emission helpers ─────────────────────────────────────────────────────

/// Write `"key":"value"` with the value JSON-escaped. XML text content may
/// contain quotes, backslashes, or control bytes; emitting it raw would
/// corrupt the NDJSON stream. Keys are comptime literals and need no escaping.
fn emit_json_field(writer: anytype, comptime key: []const u8, value: []const u8) !void {
    try writer.writeAll("\"" ++ key ++ "\":");
    try std.json.Stringify.value(value, .{}, writer);
}

/// One NDJSON line for an added/removed object.
fn emit_object_status_json(
    writer: anytype,
    type_name: []const u8,
    mrid: []const u8,
    comptime status: []const u8,
) !void {
    try writer.writeByte('{');
    try emit_json_field(writer, "type", type_name);
    try writer.writeByte(',');
    try emit_json_field(writer, "mrid", mrid);
    try writer.writeAll(",\"status\":\"" ++ status ++ "\"}\n");
}

// ── Map comparison helpers ────────────────────────────────────────────────────

/// Returns true if any key was added, removed, or changed between map1 and map2.
fn compare_maps(
    map1: std.StringHashMap([]const u8),
    map2: std.StringHashMap([]const u8),
) bool {
    var it = map1.iterator();
    while (it.next()) |entry| {
        if (map2.get(entry.key_ptr.*)) |val2| {
            if (!std.mem.eql(u8, entry.value_ptr.*, val2)) return true;
        } else {
            return true;
        }
    }
    var it2 = map2.iterator();
    while (it2.next()) |entry| {
        if (!map1.contains(entry.key_ptr.*)) return true;
    }
    return false;
}

fn emit_field_diff_text(
    map1: std.StringHashMap([]const u8),
    map2: std.StringHashMap([]const u8),
    writer: anytype,
) !void {
    var it = map1.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val1 = entry.value_ptr.*;
        if (map2.get(key)) |val2| {
            if (!std.mem.eql(u8, val1, val2)) {
                try writer.print("  - {s}: \"{s}\"\n", .{ key, val1 });
                try writer.print("  + {s}: \"{s}\"\n", .{ key, val2 });
            }
        } else {
            try writer.print("  - {s}: \"{s}\"\n", .{ key, val1 });
        }
    }
    var it2 = map2.iterator();
    while (it2.next()) |entry| {
        if (!map1.contains(entry.key_ptr.*)) {
            try writer.print("  + {s}: \"{s}\"\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
}

/// Emits changed fields as JSON objects. Returns updated `first` flag for
/// correct comma placement in the parent "changes" array.
fn emit_field_diff_json(
    map1: std.StringHashMap([]const u8),
    map2: std.StringHashMap([]const u8),
    writer: anytype,
    first_in: bool,
) !bool {
    var first = first_in;
    var it = map1.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val1 = entry.value_ptr.*;
        if (map2.get(key)) |val2| {
            if (!std.mem.eql(u8, val1, val2)) {
                if (!first) try writer.writeByte(',');
                try emit_property_change_json(writer, key, val1, val2);
                first = false;
            }
        } else {
            if (!first) try writer.writeByte(',');
            try emit_property_change_json(writer, key, val1, null);
            first = false;
        }
    }
    var it2 = map2.iterator();
    while (it2.next()) |entry| {
        if (!map1.contains(entry.key_ptr.*)) {
            if (!first) try writer.writeByte(',');
            try emit_property_change_json(writer, entry.key_ptr.*, null, entry.value_ptr.*);
            first = false;
        }
    }
    return first;
}

/// One element of the "changes" array: {"property":..,"from":..,"to":..}.
/// All payloads are JSON-escaped; absent sides emit null.
fn emit_property_change_json(
    writer: anytype,
    property: []const u8,
    from: ?[]const u8,
    to: ?[]const u8,
) !void {
    try writer.writeByte('{');
    try emit_json_field(writer, "property", property);
    try writer.writeAll(",\"from\":");
    if (from) |v| try std.json.Stringify.value(v, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"to\":");
    if (to) |v| try std.json.Stringify.value(v, .{}, writer) else try writer.writeAll("null");
    try writer.writeByte('}');
}
