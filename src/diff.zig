//! Semantic diff between two CIM models.
//!
//! Objects are matched by mRID across both models. Properties and references
//! are then compared field-by-field so that XML attribute order or whitespace
//! differences are ignored.
//!
//! Text output is modelled after `git diff` (grouped by CIM type, +/- lines).
//! JSON output is NDJSON: one object per change, suitable for piping to jq.
//!
//! Exit-code contract (enforced by main.zig, not here):
//!   0  identical
//!   1  differences found
//!   2  usage error

const std = @import("std");
const assert = std.debug.assert;
const cim_model = @import("cim_model.zig");
const tag_index = @import("tag_index.zig");

// ── Public types ──────────────────────────────────────────────────────────────

pub const DiffOptions = struct {
    /// When set, only objects of this CIM type are compared.
    type_filter: ?[]const u8 = null,
    /// Emit NDJSON instead of human-readable text.
    json: bool = false,
    /// Print only per-type counts; skip per-property detail.
    summary: bool = false,
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
    model1: *cim_model.CimModel,
    model2: *cim_model.CimModel,
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

    var type_set = std.StringHashMapUnmanaged(void){};
    defer type_set.deinit(gpa);

    var it1 = type_counts1.keyIterator();
    while (it1.next()) |key| try type_set.put(gpa, key.*, {});
    var it2 = type_counts2.keyIterator();
    while (it2.next()) |key| try type_set.put(gpa, key.*, {});

    if (!options.json and !options.summary) {
        try writer.print("--- {s}\n+++ {s}\n", .{ path1, path2 });
    }

    var it = type_set.keyIterator();
    while (it.next()) |type_name_ptr| {
        const type_name = type_name_ptr.*;
        if (options.type_filter) |f| {
            if (!std.mem.eql(u8, type_name, f)) continue;
        }
        const stats = try diff_type(gpa, model1, model2, type_name, options, writer);
        if (stats.any()) {
            had_diffs = true;
            if (options.summary) {
                try writer.print("{s}  +{d} -{d} ~{d}\n", .{
                    type_name, stats.added, stats.removed, stats.changed,
                });
            }
        }
    }

    return had_diffs;
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
    model1: *cim_model.CimModel,
    model2: *cim_model.CimModel,
    mrid: []const u8,
    path1: []const u8,
    path2: []const u8,
    options: DiffOptions,
    writer: anytype,
) !SingleDiffStatus {
    assert(options.summary == false or options.json == false);

    const v1 = model1.getObjectById(mrid);
    const v2 = model2.getObjectById(mrid);

    if (v1 == null and v2 == null) return .not_found;

    // Type verification: check whichever model has the object.
    if (options.type_filter) |expected| {
        if (v1) |v| if (!std.mem.eql(u8, v.type_name, expected)) return .{ .type_mismatch = v.type_name };
        if (v2) |v| if (!std.mem.eql(u8, v.type_name, expected)) return .{ .type_mismatch = v.type_name };
    }

    const type_name = if (v1) |v| v.type_name else v2.?.type_name;

    if (!options.json and !options.summary) {
        try writer.print("--- {s}\n+++ {s}\n", .{ path1, path2 });
    }

    // Object only in model2 — added.
    if (v1 == null) {
        if (options.summary) {
            try writer.print("{s}  +1 -0 ~0\n", .{type_name});
        } else if (options.json) {
            try writer.print("{{\"type\":\"{s}\",\"mrid\":\"{s}\",\"status\":\"added\"}}\n", .{ type_name, mrid });
        } else {
            const name = (try v2.?.getProperty("IdentifiedObject.name")) orelse "";
            try writer.print("+ {s}  \"{s}\"\n", .{ mrid, name });
        }
        return .{ .diff = true };
    }

    // Object only in model1 — removed.
    if (v2 == null) {
        if (options.summary) {
            try writer.print("{s}  +0 -1 ~0\n", .{type_name});
        } else if (options.json) {
            try writer.print("{{\"type\":\"{s}\",\"mrid\":\"{s}\",\"status\":\"removed\"}}\n", .{ type_name, mrid });
        } else {
            const name = (try v1.?.getProperty("IdentifiedObject.name")) orelse "";
            try writer.print("- {s}  \"{s}\"\n", .{ mrid, name });
        }
        return .{ .diff = true };
    }

    // Object in both models — compare.
    const changed = try diff_object(gpa, type_name, mrid, v1.?, v2.?, options, writer);
    if (changed and options.summary) {
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
    model1: *cim_model.CimModel,
    model2: *cim_model.CimModel,
    type_name: []const u8,
    options: DiffOptions,
    writer: anytype,
) !TypeStats {
    if (options.json or options.summary) {
        return diff_type_core(gpa, model1, model2, type_name, options, writer);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const buf_writer = buf.writer(gpa);
    const stats = try diff_type_core(gpa, model1, model2, type_name, options, buf_writer);
    if (stats.any()) {
        try writer.print("\n@@ {s} @@\n", .{type_name});
        try writer.writeAll(buf.items);
    }
    return stats;
}

fn diff_type_core(
    gpa: std.mem.Allocator,
    model1: *cim_model.CimModel,
    model2: *cim_model.CimModel,
    type_name: []const u8,
    options: DiffOptions,
    writer: anytype,
) !TypeStats {
    var stats = TypeStats{ .type_name = type_name, .added = 0, .removed = 0, .changed = 0 };

    const objects1 = model1.get_objects_by_type(type_name);
    const objects2 = model2.get_objects_by_type(type_name);

    var map = std.StringHashMap(u32).init(gpa);
    defer map.deinit();
    for (objects2, 0..) |obj2, idx| try map.put(obj2.id, @intCast(idx));

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
            if (!options.summary) {
                const name = (try model1.view(obj1).getProperty("IdentifiedObject.name")) orelse "";
                if (options.json) {
                    try writer.print("{{\"type\":\"{s}\",\"mrid\":\"{s}\",\"status\":\"removed\"}}\n", .{ type_name, obj1.id });
                } else {
                    try writer.print("- {s}  \"{s}\"\n", .{ obj1.id, name });
                }
            }
        }
    }

    for (objects2, matched) |obj2, was_matched| {
        if (!was_matched) {
            stats.added += 1;
            if (!options.summary) {
                const name = (try model2.view(obj2).getProperty("IdentifiedObject.name")) orelse "";
                if (options.json) {
                    try writer.print("{{\"type\":\"{s}\",\"mrid\":\"{s}\",\"status\":\"added\"}}\n", .{ type_name, obj2.id });
                } else {
                    try writer.print("+ {s}  \"{s}\"\n", .{ obj2.id, name });
                }
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
    var props1 = try view1.getAllProperties(gpa);
    defer props1.deinit();
    var props2 = try view2.getAllProperties(gpa);
    defer props2.deinit();
    var refs1 = try view1.getAllReferences(gpa);
    defer refs1.deinit();
    var refs2 = try view2.getAllReferences(gpa);
    defer refs2.deinit();

    if (!compare_maps(props1, props2) and !compare_maps(refs1, refs2)) return false;

    if (!options.summary) {
        if (options.json) {
            try writer.print("{{\"type\":\"{s}\",\"mrid\":\"{s}\",\"status\":\"changed\",\"changes\":[", .{ type_name, mrid });
            var first = true;
            first = try emit_field_diff_json(props1, props2, writer, first);
            _ = try emit_field_diff_json(refs1, refs2, writer, first);
            try writer.print("]}}\n", .{});
        } else {
            const name = props1.get("IdentifiedObject.name") orelse props2.get("IdentifiedObject.name") orelse "";
            try writer.print("~ {s}  \"{s}\"\n", .{ mrid, name });
            try emit_field_diff_text(props1, props2, writer);
            try emit_field_diff_text(refs1, refs2, writer);
        }
    }

    return true;
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
                try writer.print("{{\"property\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\"}}", .{ key, val1, val2 });
                first = false;
            }
        } else {
            if (!first) try writer.writeByte(',');
            try writer.print("{{\"property\":\"{s}\",\"from\":\"{s}\",\"to\":null}}", .{ key, val1 });
            first = false;
        }
    }
    var it2 = map2.iterator();
    while (it2.next()) |entry| {
        if (!map1.contains(entry.key_ptr.*)) {
            if (!first) try writer.writeByte(',');
            try writer.print("{{\"property\":\"{s}\",\"from\":null,\"to\":\"{s}\"}}", .{ entry.key_ptr.*, entry.value_ptr.* });
            first = false;
        }
    }
    return first;
}
