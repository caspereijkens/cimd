//! Trim-tolerant parsing of CIM property values.
//!
//! Property values are returned as the raw XML text between an element's tags.
//! When a CGMES file is pretty-printed, that text is wrapped in indentation
//! whitespace, e.g. `<cim:Switch.open>\n  true\n</cim:Switch.open>` yields
//! "\n  true\n". `std.fmt.parseFloat`/`parseInt` reject leading/trailing
//! whitespace (error.InvalidCharacter), and `std.mem.eql(x, "true")` silently
//! fails on it — so untrimmed parsing either aborts the whole conversion or
//! produces silently wrong values, depending on the call site.
//!
//! These helpers are the single source of truth for that whitespace contract:
//! every numeric/boolean property read in the convert pathway trims first.
//! Trimming a value that has no surrounding whitespace (the common single-line
//! CGMES case) is a no-op, so output for well-formed input is unchanged.

const std = @import("std");

/// Whitespace that wraps pretty-printed XML text content.
const whitespace = " \t\r\n";

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, whitespace);
}

/// Parse a required, present value (trimmed). Errors on invalid input.
/// Use when the caller has already unwrapped the optional and a malformed
/// value should fail loudly.
pub fn float_req(s: []const u8) !f64 {
    return std.fmt.parseFloat(f64, trimmed(s));
}

/// Parse a required, present integer of type `T` (trimmed, base 10).
pub fn int_req(comptime T: type, s: []const u8) !T {
    return std.fmt.parseInt(T, trimmed(s), 10);
}

/// Parse an optional float, swallowing errors: null on absent, blank, or invalid.
pub fn float_opt(s: ?[]const u8) ?f64 {
    const t = trimmed(s orelse return null);
    if (t.len == 0) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

/// Parse an optional integer of type `T`, swallowing errors:
/// null on absent, blank, or invalid.
pub fn int_opt(comptime T: type, s: ?[]const u8) ?T {
    const t = trimmed(s orelse return null);
    if (t.len == 0) return null;
    return std.fmt.parseInt(T, t, 10) catch null;
}

/// Parse an optional float, falling back to `default` on absent, blank, or invalid.
pub fn float_or(s: ?[]const u8, default: f64) f64 {
    return float_opt(s) orelse default;
}

/// Parse an optional integer of type `T`, falling back to `default`
/// on absent, blank, or invalid.
pub fn int_or(comptime T: type, s: ?[]const u8, default: T) T {
    return int_opt(T, s) orelse default;
}

/// Parse an optional float: `default` when absent or blank, but error on a
/// present-yet-invalid value. Mirrors the `(value orelse "default")` + `try`
/// idiom while tolerating whitespace and treating whitespace-only as absent.
pub fn float_strict(s: ?[]const u8, default: f64) !f64 {
    const t = trimmed(s orelse return default);
    if (t.len == 0) return default;
    return std.fmt.parseFloat(f64, t);
}

/// Integer counterpart to `float_strict`.
pub fn int_strict(comptime T: type, s: ?[]const u8, default: T) !T {
    const t = trimmed(s orelse return default);
    if (t.len == 0) return default;
    return std.fmt.parseInt(T, t, 10);
}

/// CIM boolean: trimmed content equals "true". Absent or blank is false.
pub fn flag(s: ?[]const u8) bool {
    return std.mem.eql(u8, trimmed(s orelse return false), "true");
}

const testing = std.testing;

test "flag: trims surrounding whitespace (pretty-printed XML)" {
    try testing.expect(flag("true"));
    try testing.expect(flag("\n  true\n  "));
    try testing.expect(!flag("false"));
    try testing.expect(!flag("  false  "));
    try testing.expect(!flag(null));
    try testing.expect(!flag("   "));
    // Only an exact (trimmed) "true" is truthy.
    try testing.expect(!flag("TRUE"));
    try testing.expect(!flag("true false"));
}

test "float_opt: whitespace, blank, invalid, absent" {
    try testing.expectEqual(@as(?f64, 123.0), float_opt("  123.0\n"));
    try testing.expectEqual(@as(?f64, null), float_opt(null));
    try testing.expectEqual(@as(?f64, null), float_opt("   "));
    try testing.expectEqual(@as(?f64, null), float_opt("not a number"));
}

test "float_or / int_or: defaults on absent, blank, invalid" {
    try testing.expectEqual(@as(f64, 0.0), float_or(null, 0.0));
    try testing.expectEqual(@as(f64, 0.0), float_or("  ", 0.0));
    try testing.expectEqual(@as(f64, 1.5), float_or(" 1.5 ", 0.0));
    try testing.expectEqual(@as(u32, 7), int_or(u32, null, 7));
    try testing.expectEqual(@as(u32, 7), int_or(u32, "junk", 7));
    try testing.expectEqual(@as(u32, 5), int_or(u32, "\n5\n", 7));
}

test "float_strict / int_strict: default on absent/blank, error on invalid" {
    try testing.expectEqual(@as(f64, 0.0), try float_strict(null, 0.0));
    try testing.expectEqual(@as(f64, 0.0), try float_strict("   ", 0.0));
    try testing.expectEqual(@as(f64, 2.5), try float_strict(" 2.5 ", 0.0));
    try testing.expectError(error.InvalidCharacter, float_strict("bad", 0.0));
    try testing.expectEqual(@as(u32, 1), try int_strict(u32, null, 1));
    try testing.expectEqual(@as(i32, -3), try int_strict(i32, " -3 ", 0));
    try testing.expectError(error.InvalidCharacter, int_strict(u32, "x", 0));
}

test "float_req / int_req: trimmed, error on invalid" {
    try testing.expectEqual(@as(f64, 9.0), try float_req(" 9.0 "));
    try testing.expectError(error.InvalidCharacter, float_req(" "));
    try testing.expectEqual(@as(i32, 42), try int_req(i32, "\t42\n"));
    try testing.expectError(error.InvalidCharacter, int_req(i32, "nope"));
}
