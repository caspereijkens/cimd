//! Violation collection and report rendering.
//!
//! Collection is exhaustive up to a hard memory bound: every violation is
//! stored (never per-rule capped at add time), per-rule totals stay exact
//! beyond the bound. Rendering partitions offsetless findings first, stable-
//! sorts the rest in document order, and truncates per rule -- so the shown
//! examples are the true first N in the document whenever the bound holds.

const std = @import("std");
const assert = std.debug.assert;

const cim = @import("../cim/cim.zig");
const catalog = @import("catalog.zig");

pub const Rule = catalog.Rule;
pub const rule_count = catalog.rule_count;
pub const Severity = catalog.Severity;

/// Finding counts split by severity -- what a caller keys its exit code on.
pub const Totals = struct {
    errors: u64 = 0,
    warnings: u64 = 0,
    infos: u64 = 0,

    pub fn total(self: Totals) u64 {
        return self.errors + self.warnings + self.infos;
    }
};

/// Caller-supplied terminal styling for severity words. Keeping the escape
/// sequences out of this library lets the application decide whether its
/// destination supports color without importing application code here.
pub const SeverityColors = struct {
    @"error": []const u8,
    warning: []const u8,
    info: []const u8,
    reset: []const u8,

    pub const plain: SeverityColors = .{
        .@"error" = "",
        .warning = "",
        .info = "",
        .reset = "",
    };

    fn assert_valid(self: SeverityColors) void {
        if (self.@"error".len > 0) assert(self.reset.len > 0);
        if (self.warning.len > 0) assert(self.reset.len > 0);
        if (self.info.len > 0) assert(self.reset.len > 0);
    }

    fn start(self: SeverityColors, severity: Severity) []const u8 {
        return switch (severity) {
            .@"error" => self.@"error",
            .warning => self.warning,
            .info => self.info,
        };
    }
};

/// Offset value of a finding with no document location (filename and header
/// rules).
pub const no_offset: u32 = std.math.maxInt(u32);

pub const Violation = struct {
    /// The rule that found this. Severity is not stored: it is fixed per rule
    /// (`catalog.severity`), so carrying it here would cost a byte on every
    /// one of up to `stored_total_max` findings to repeat a constant.
    rule: Rule,
    /// Byte offset of the offending object's opening '<' in the document
    /// (`CimObject.xml_offset`), or `no_offset`. Line numbers are a
    /// presentation concern, resolved lazily at report time.
    offset: u32,
    /// The offending object's RDF identifier (`obj.id()`), borrowed from the
    /// document; "" for filename and header findings.
    object_id: []const u8,
    /// The offending value (property text, filename fragment), borrowed;
    /// "" when the finding has no single datum (a missing property, a
    /// cardinality mismatch, an aggregate sum).
    detail: []const u8,
};

/// Rendered examples per rule. A render-time limit: totals are never capped.
pub const rendered_per_rule_max: u32 = 100;

/// Hard bound on stored violations across all rules (~40 MB of Violation).
/// Past it, collection keeps counting but stops storing.
pub const stored_total_max: u32 = 1 << 20;

pub const Report = struct {
    /// Every violation in emission order, up to `stored_total_max`.
    violations: std.ArrayList(Violation),
    /// Exact per-rule totals, maintained past the storage bound.
    totals: [rule_count]u32,
    /// Whether `stored_total_max` was hit and violations went unstored.
    truncated: bool,

    pub const empty: Report = .{
        .violations = .empty,
        .totals = @splat(0),
        .truncated = false,
    };

    pub fn deinit(self: *Report, gpa: std.mem.Allocator) void {
        self.violations.deinit(gpa);
    }

    pub fn add(self: *Report, gpa: std.mem.Allocator, violation: Violation) error{OutOfMemory}!void {
        self.totals[@intFromEnum(violation.rule)] +|= 1;
        if (self.violations.items.len >= stored_total_max) {
            self.truncated = true;
            return;
        }
        try self.violations.append(gpa, violation);
    }

    /// Exact total across all rules.
    pub fn total(self: *const Report) u64 {
        var sum: u64 = 0;
        for (self.totals) |rule_total| sum += rule_total;
        return sum;
    }

    pub fn any(self: *const Report) bool {
        return self.total() > 0;
    }

    /// Exact count for one rule.
    pub fn count(self: *const Report, rule: Rule) u32 {
        return self.totals[@intFromEnum(rule)];
    }

    /// Exact totals per severity, folded from the per-rule totals in one
    /// pass. Exact past the storage bound, since `totals` is.
    pub fn by_severity(self: *const Report) Totals {
        var result: Totals = .{};
        for (self.totals, 0..) |rule_total, index| {
            const rule: Rule = @enumFromInt(index);
            switch (catalog.severity(rule)) {
                .@"error" => result.errors += rule_total,
                .warning => result.warnings += rule_total,
                .info => result.infos += rule_total,
            }
        }
        return result;
    }
};

/// Render the report: one line per shown violation, per-rule suppression
/// lines, a global-truncation notice, and a summary. Deterministic:
/// offsetless findings first in emission order, then document order
/// (stable-sorted by offset, then rule; emission order breaks ties).
/// Returns the exact per-severity totals for the caller's exit-code decision.
///
/// Every per-rule line carries the rule's severity right after the `qocdc:`
/// prefix, so `qocdc: error:` and `qocdc: <severity>: <Rule>:` are both grep
/// keys. Ordering is severity-blind on purpose: document order is what makes
/// a report diffable between runs.
///
/// `model` supplies the bytes for line-number resolution; it may be null only
/// when every stored violation is offsetless (filename-only validation).
/// `colors` styles only severity words; `.plain` preserves the byte-for-byte
/// text format for redirected output and library users.
pub fn write_report(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    model: ?*const cim.CimDocument,
    report: *const Report,
    colors: SeverityColors,
) !Totals {
    colors.assert_valid();
    const items = report.violations.items;

    // Transient sort index; `report` itself stays const.
    const order = try gpa.alloc(u32, items.len);
    defer gpa.free(order);
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    // Partition: offsetless first, keeping emission order, then by document
    // position. `no_offset` is maxInt, so a plain (offset != no_offset,
    // offset, rule) key would sort offsetless findings last -- the explicit
    // bool key puts them first instead. Stable sort: emission order is the
    // final tie-breaker without storing a sequence number.
    std.sort.block(u32, order, items, struct {
        fn less_than(violations: []const Violation, a: u32, b: u32) bool {
            const va = violations[a];
            const vb = violations[b];
            const a_placed = va.offset != no_offset;
            const b_placed = vb.offset != no_offset;
            if (a_placed != b_placed) return b_placed;
            if (va.offset != vb.offset) return va.offset < vb.offset;
            return @intFromEnum(va.rule) < @intFromEnum(vb.rule);
        }
    }.less_than);

    // Newline index, built lazily: reports on clean documents and
    // filename-only runs never touch the source bytes.
    var newlines: ?std.ArrayList(u32) = null;
    defer if (newlines) |*lines| lines.deinit(gpa);

    var shown: [rule_count]u32 = @splat(0);
    for (order) |index| {
        const violation = items[index];
        const rule_index = @intFromEnum(violation.rule);
        if (shown[rule_index] >= rendered_per_rule_max) continue;
        shown[rule_index] += 1;

        try write_rule_prefix(w, violation.rule, colors);
        if (violation.offset != no_offset) {
            const document = model.?;
            if (newlines == null) {
                newlines = try cim.xml_scan.find_byte_simd(gpa, document.source(), '\n');
            }
            try write_escaped(w, violation.object_id);
            try w.print(" line {d}: ", .{line_of(newlines.?.items, violation.offset)});
        }
        try w.print("{s}", .{catalog.message(violation.rule)});
        if (violation.detail.len > 0) {
            try w.writeAll(" ['");
            try write_escaped(w, violation.detail);
            try w.writeAll("']");
        }
        try w.writeByte('\n');
    }

    // Suppression accounting, in rule order. `totals > shown` covers both the
    // per-rule render cap and findings the storage bound dropped.
    var rules_hit: u32 = 0;
    for (report.totals, shown, 0..) |rule_total, rule_shown, rule_index| {
        if (rule_total == 0) continue;
        rules_hit += 1;
        if (rule_total == rule_shown) continue;
        const rule: Rule = @enumFromInt(rule_index);
        try write_rule_prefix(w, rule, colors);
        if (rule_shown == 0) {
            try w.print("{d} violations counted, none retained (collection limit reached)\n", .{
                rule_total,
            });
        } else {
            try w.print("{d} further violations suppressed ({d} shown, {d} total)\n", .{
                rule_total - rule_shown, rule_shown, rule_total,
            });
        }
    }
    if (report.truncated) {
        try w.print("qocdc: collection limit reached after {d} violations; totals remain exact\n", .{
            stored_total_max,
        });
    }

    const totals = report.by_severity();
    const violation_total = totals.total();
    assert(violation_total == report.total());
    if (violation_total > 0) {
        try w.print("qocdc: {d} violations across {d} rules ({d} errors, {d} warnings, {d} info)\n", .{
            violation_total, rules_hit, totals.errors, totals.warnings, totals.infos,
        });
    }
    return totals;
}

fn write_rule_prefix(w: *std.Io.Writer, rule: Rule, colors: SeverityColors) !void {
    try w.writeAll("qocdc: ");
    const level = catalog.severity(rule);
    try write_severity_text(w, level, @tagName(level), colors);
    try w.print(": {s}: ", .{@tagName(rule)});
}

fn write_severity_text(
    w: *std.Io.Writer,
    severity: Severity,
    text: []const u8,
    colors: SeverityColors,
) !void {
    assert(text.len > 0);
    const start = colors.start(severity);
    try w.writeAll(start);
    try w.writeAll(text);
    if (start.len > 0) try w.writeAll(colors.reset);
}

/// Write `text` with control characters and quote-delimiters escaped, so a
/// property value containing a newline cannot break the one-line-per-violation
/// contract. Byte-at-a-time over violation details only; messages are
/// single-line literals and never pass through here.
fn write_escaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '\\' => try w.writeAll("\\\\"),
            '\'' => try w.writeAll("\\'"),
            else => try w.writeByte(byte),
        }
    }
}

/// 1-based line of a byte offset: the number of newlines strictly before it,
/// plus one.
fn line_of(newlines: []const u32, offset: u32) u64 {
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
    return @as(u64, @intCast(low)) + 1;
}

// ── tests ─────────────────────────────────────────────────────────────────

const test_gpa = std.testing.allocator;

test "Report counts exactly and stores in emission order" {
    var report: Report = .empty;
    defer report.deinit(test_gpa);
    try report.add(test_gpa, .{ .rule = .NameLength, .offset = 10, .object_id = "_a", .detail = "" });
    try report.add(test_gpa, .{ .rule = .FileVersion, .offset = no_offset, .object_id = "", .detail = "0a1" });
    try report.add(test_gpa, .{ .rule = .NameLength, .offset = 5, .object_id = "_b", .detail = "x" });

    try std.testing.expectEqual(@as(u32, 2), report.count(.NameLength));
    try std.testing.expectEqual(@as(u32, 1), report.count(.FileVersion));
    try std.testing.expectEqual(@as(u64, 3), report.total());
    try std.testing.expect(report.any());
    try std.testing.expectEqualStrings("_a", report.violations.items[0].object_id);
}

test "write_report orders offsetless first then by document position" {
    var report: Report = .empty;
    defer report.deinit(test_gpa);
    try report.add(test_gpa, .{ .rule = .NameLength, .offset = 40, .object_id = "_late", .detail = "" });
    try report.add(test_gpa, .{ .rule = .FileVersion, .offset = no_offset, .object_id = "", .detail = "0a1" });
    try report.add(test_gpa, .{ .rule = .ShortNameLength, .offset = 8, .object_id = "_early", .detail = "toolongname13" });

    var model = try cim.CimDocument.init(
        test_gpa,
        try test_gpa.dupe(u8, "<rdf:RDF>\n<cim:A rdf:ID=\"_early\">\n</cim:A>\n</rdf:RDF>\n"),
    );
    defer model.deinit(test_gpa);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const totals = try write_report(test_gpa, &writer, &model, &report, .plain);
    try std.testing.expectEqual(@as(u64, 3), totals.total());

    const out = writer.buffered();
    const first = std.mem.indexOf(u8, out, "FileVersion").?;
    const second = std.mem.indexOf(u8, out, "ShortNameLength").?;
    const third = std.mem.indexOf(u8, out, "NameLength").?;
    try std.testing.expect(first < second and second < third);
    try std.testing.expect(std.mem.indexOf(u8, out, "3 violations across 3 rules") != null);
}

test "write_escaped keeps a violation on one line" {
    var report: Report = .empty;
    defer report.deinit(test_gpa);
    try report.add(test_gpa, .{
        .rule = .FileVersion,
        .offset = no_offset,
        .object_id = "",
        .detail = "a\nb\t'c'\\d",
    });

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    _ = try write_report(test_gpa, &writer, null, &report, .plain);
    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "['a\\nb\\t\\'c\\'\\\\d']") != null);
    // Exactly two lines: the violation and the summary.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
}

test "write_report renders nothing for a clean report" {
    var report: Report = .empty;
    defer report.deinit(test_gpa);
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const totals = try write_report(test_gpa, &writer, null, &report, .plain);
    try std.testing.expectEqual(@as(u64, 0), totals.total());
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "by_severity partitions the per-rule totals exactly" {
    var report: Report = .empty;
    defer report.deinit(test_gpa);
    try report.add(test_gpa, .{ .rule = .NameLength, .offset = 10, .object_id = "_a", .detail = "" });
    try report.add(test_gpa, .{ .rule = .NameLength, .offset = 20, .object_id = "_b", .detail = "" });
    try report.add(test_gpa, .{ .rule = .FileVersion, .offset = no_offset, .object_id = "", .detail = "0a1" });

    const totals = report.by_severity();
    try std.testing.expectEqual(report.total(), totals.total());
    // Severity-blind: whatever the assignment, the three buckets hold every
    // finding and nothing else.
    try std.testing.expectEqual(@as(u64, 3), totals.total());
}

test "write_report colors a rule severity and leaves the summary plain" {
    var report: Report = .empty;
    defer report.deinit(test_gpa);
    try report.add(test_gpa, .{ .rule = .FileVersion, .offset = no_offset, .object_id = "", .detail = "0a1" });

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const colors: SeverityColors = .{
        .@"error" = "<red>",
        .warning = "<yellow>",
        .info = "<cyan>",
        .reset = "<reset>",
    };
    const totals = try write_report(test_gpa, &writer, null, &report, colors);

    const out = writer.buffered();
    const level = catalog.severity(.FileVersion);
    var expected_prefix_buffer: [96]u8 = undefined;
    const expected_prefix = try std.fmt.bufPrint(
        &expected_prefix_buffer,
        "qocdc: {s}{s}{s}: FileVersion: ",
        .{ colors.start(level), @tagName(level), colors.reset },
    );
    try std.testing.expect(std.mem.indexOf(u8, out, expected_prefix) != null);

    var expected_summary_buffer: [128]u8 = undefined;
    const expected_summary = try std.fmt.bufPrint(
        &expected_summary_buffer,
        "qocdc: 1 violations across 1 rules ({d} errors, {d} warnings, {d} info)",
        .{ totals.errors, totals.warnings, totals.infos },
    );
    try std.testing.expect(std.mem.indexOf(u8, out, expected_summary) != null);
    try std.testing.expectEqual(@as(u64, 1), totals.total());
}
