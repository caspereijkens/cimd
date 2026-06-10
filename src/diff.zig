//! Report renderers for the semantic diff between two CIM models.
//!
//! Change detection (mRID matching, statement multiset comparison) lives in
//! diff_core.zig; this module only renders its results in the report formats:
//! patch (modelled after `git diff`: grouped by CIM type, +/- lines), NDJSON
//! (one object per change, suitable for piping to jq), and summary (per-type
//! counts). The CLI's default output, the IEC 61970-552 difference model,
//! lives in eqdiff.zig and renders from the same engine.
//!
//! Exit-code contract (enforced by main.zig, not here):
//!   0  identical
//!   1  differences found
//!   2  usage error

const std = @import("std");

const EQ = @import("cgmes/eq.zig").EQ;
const tag_index = @import("cgmes/tag_index.zig");
const cim_types = @import("cgmes/cim_types.zig");
const core = @import("diff_core.zig");

pub const SingleDiffStatus = core.SingleDiffStatus;

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
    writer: *std.Io.Writer,
) !bool {
    var had_diffs = false;

    var type_counts1 = try model1.getTypeCounts(gpa);
    defer type_counts1.deinit();
    var type_counts2 = try model2.getTypeCounts(gpa);
    defer type_counts2.deinit();

    const type_names = try core.type_name_union(gpa, &type_counts1, &type_counts2);
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

/// In text mode, buffer all object lines so the @@ TypeName @@ header can be
/// prepended after we know whether this type has any diffs. In JSON/summary
/// mode write directly to the real writer — no header is needed.
fn diff_type(
    gpa: std.mem.Allocator,
    model1: *EQ,
    model2: *EQ,
    type_name: []const u8,
    options: DiffOptions,
    writer: *std.Io.Writer,
) !core.TypeStats {
    if (options.format != .patch) {
        const renderer = Renderer{ .format = options.format, .writer = writer };
        return core.match_type(gpa, model1, model2, type_name, &renderer);
    }
    var screen: std.Io.Writer.Allocating = .init(gpa);
    defer screen.deinit();
    const renderer = Renderer{ .format = .patch, .writer = &screen.writer };
    const stats = try core.match_type(gpa, model1, model2, type_name, &renderer);
    if (stats.any()) {
        try writer.print("\n@@ {s} @@\n", .{type_name});
        try writer.writeAll(screen.written());
    }
    return stats;
}

/// core.match_type emitter for the report formats.
const Renderer = struct {
    format: DiffOptions.Format,
    writer: *std.Io.Writer,

    pub fn added(self: *const Renderer, view: tag_index.CimObjectView) !void {
        switch (self.format) {
            .summary => {},
            .json => try emit_object_status_json(self.writer, view.type_name, view.id, "added"),
            .patch => {
                const name = (try view.getProperty("IdentifiedObject.name")) orelse "";
                try self.writer.print("+ {s}  \"{s}\"\n", .{ view.id, name });
            },
        }
    }

    pub fn removed(self: *const Renderer, view: tag_index.CimObjectView) !void {
        switch (self.format) {
            .summary => {},
            .json => try emit_object_status_json(self.writer, view.type_name, view.id, "removed"),
            .patch => {
                const name = (try view.getProperty("IdentifiedObject.name")) orelse "";
                try self.writer.print("- {s}  \"{s}\"\n", .{ view.id, name });
            },
        }
    }

    pub fn changed(
        self: *const Renderer,
        view1: tag_index.CimObjectView,
        view2: tag_index.CimObjectView,
        changes: *const core.ChangeSet,
    ) !void {
        try render_changed(self.writer, self.format, view1, view2, changes);
    }
};

// ── Single-mRID diff ──────────────────────────────────────────────────────────

/// Diff a single object identified by `mrid` across the two models, using
/// the same classification (core.match_single) and rendering as diff_models.
pub fn diff_single(
    gpa: std.mem.Allocator,
    model1: *EQ,
    model2: *EQ,
    mrid: []const u8,
    path1: []const u8,
    path2: []const u8,
    options: DiffOptions,
    writer: *std.Io.Writer,
) !SingleDiffStatus {
    const match = core.match_single(model1, model2, mrid, options.type_filter);
    switch (match) {
        .not_found => return .not_found,
        .type_mismatch => |actual| return .{ .type_mismatch = actual },
        else => {},
    }

    if (options.format == .patch) {
        try writer.print("--- {s}\n+++ {s}\n", .{ path1, path2 });
    }

    switch (match) {
        .not_found, .type_mismatch => unreachable,
        .added => |view| {
            switch (options.format) {
                .summary => try writer.print("{s}  +1 -0 ~0\n", .{view.type_name}),
                .json => try emit_object_status_json(writer, view.type_name, view.id, "added"),
                .patch => {
                    const name = (try view.getProperty("IdentifiedObject.name")) orelse "";
                    try writer.print("+ {s}  \"{s}\"\n", .{ view.id, name });
                },
            }
            return .{ .diff = true };
        },
        .removed => |view| {
            switch (options.format) {
                .summary => try writer.print("{s}  +0 -1 ~0\n", .{view.type_name}),
                .json => try emit_object_status_json(writer, view.type_name, view.id, "removed"),
                .patch => {
                    const name = (try view.getProperty("IdentifiedObject.name")) orelse "";
                    try writer.print("- {s}  \"{s}\"\n", .{ view.id, name });
                },
            }
            return .{ .diff = true };
        },
        .replaced => |r| {
            switch (options.format) {
                .summary => {
                    try writer.print("{s}  +0 -1 ~0\n", .{r.old.type_name});
                    try writer.print("{s}  +1 -0 ~0\n", .{r.new.type_name});
                },
                .json => {
                    try emit_object_status_json(writer, r.old.type_name, r.old.id, "removed");
                    try emit_object_status_json(writer, r.new.type_name, r.new.id, "added");
                },
                .patch => {
                    const name1 = (try r.old.getProperty("IdentifiedObject.name")) orelse "";
                    const name2 = (try r.new.getProperty("IdentifiedObject.name")) orelse "";
                    try writer.print("- {s}  \"{s}\"\n", .{ r.old.id, name1 });
                    try writer.print("+ {s}  \"{s}\"\n", .{ r.new.id, name2 });
                },
            }
            return .{ .diff = true };
        },
        .matched => |m| {
            var changes = (try core.object_changes(gpa, m.old, m.new)) orelse
                return .{ .diff = false };
            defer changes.deinit(gpa);
            try render_changed(writer, options.format, m.old, m.new, &changes);
            if (options.format == .summary) {
                try writer.print("{s}  +0 -0 ~1\n", .{m.old.type_name});
            }
            return .{ .diff = true };
        },
    }
}

// ── Changed-object rendering ──────────────────────────────────────────────────

/// One field-level change, paired from the ChangeSet's two sides: both values
/// present = changed, from-only = removed, to-only = added.
const FieldChange = struct {
    property: []const u8,
    from: ?[]const u8,
    to: ?[]const u8,
};

/// Pair the (name-sorted) reverse and forward statements of a ChangeSet into
/// from/to field changes. Repeated names pair up in document order; an
/// unbalanced repetition yields a from-only or to-only change.
const FieldChangeIterator = struct {
    reverse: []const core.Statement,
    forward: []const core.Statement,
    i: usize = 0,
    j: usize = 0,

    fn next(self: *FieldChangeIterator) ?FieldChange {
        const old: ?core.Statement = if (self.i < self.reverse.len) self.reverse[self.i] else null;
        const new: ?core.Statement = if (self.j < self.forward.len) self.forward[self.j] else null;

        if (old != null and new != null) {
            switch (std.mem.order(u8, old.?.name, new.?.name)) {
                .eq => {
                    self.i += 1;
                    self.j += 1;
                    return .{ .property = old.?.name, .from = old.?.value, .to = new.?.value };
                },
                .lt => {
                    self.i += 1;
                    return .{ .property = old.?.name, .from = old.?.value, .to = null };
                },
                .gt => {
                    self.j += 1;
                    return .{ .property = new.?.name, .from = null, .to = new.?.value };
                },
            }
        }
        if (old) |statement| {
            self.i += 1;
            return .{ .property = statement.name, .from = statement.value, .to = null };
        }
        if (new) |statement| {
            self.j += 1;
            return .{ .property = statement.name, .from = null, .to = statement.value };
        }
        return null;
    }
};

/// Render an object present in both models whose statements differ.
fn render_changed(
    writer: *std.Io.Writer,
    format: DiffOptions.Format,
    view1: tag_index.CimObjectView,
    view2: tag_index.CimObjectView,
    changes: *const core.ChangeSet,
) !void {
    switch (format) {
        .summary => {},
        .json => {
            try writer.writeByte('{');
            try emit_json_field(writer, "type", view1.type_name);
            try writer.writeByte(',');
            try emit_json_field(writer, "mrid", view1.id);
            try writer.writeAll(",\"status\":\"changed\",\"changes\":[");
            var it = FieldChangeIterator{ .reverse = changes.reverse.items, .forward = changes.forward.items };
            var first = true;
            while (it.next()) |change| {
                if (!first) try writer.writeByte(',');
                try emit_property_change_json(writer, change.property, change.from, change.to);
                first = false;
            }
            try writer.writeAll("]}\n");
        },
        .patch => {
            const name = (try view1.getProperty("IdentifiedObject.name")) orelse
                (try view2.getProperty("IdentifiedObject.name")) orelse "";
            try writer.print("~ {s}  \"{s}\"\n", .{ view1.id, name });
            var it = FieldChangeIterator{ .reverse = changes.reverse.items, .forward = changes.forward.items };
            while (it.next()) |change| {
                if (change.from) |value| try writer.print("  - {s}: \"{s}\"\n", .{ change.property, value });
                if (change.to) |value| try writer.print("  + {s}: \"{s}\"\n", .{ change.property, value });
            }
        },
    }
}

// ── JSON emission helpers ─────────────────────────────────────────────────────

/// Write `"key":"value"` with the value JSON-escaped. XML text content may
/// contain quotes, backslashes, or control bytes; emitting it raw would
/// corrupt the NDJSON stream. Keys are comptime literals and need no escaping.
fn emit_json_field(writer: *std.Io.Writer, comptime key: []const u8, value: []const u8) !void {
    try writer.writeAll("\"" ++ key ++ "\":");
    try std.json.Stringify.value(value, .{}, writer);
}

/// One NDJSON line for an added/removed object.
fn emit_object_status_json(
    writer: *std.Io.Writer,
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

/// One element of the "changes" array: {"property":..,"from":..,"to":..}.
/// All payloads are JSON-escaped; absent sides emit null.
fn emit_property_change_json(
    writer: *std.Io.Writer,
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
