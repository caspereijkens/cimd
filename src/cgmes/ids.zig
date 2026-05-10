const std = @import("std");

pub fn strip_hash(id: []const u8) []const u8 {
    return if (id.len > 0 and id[0] == '#') id[1..] else id;
}

pub fn strip_underscore(id: []const u8) []const u8 {
    return if (id.len > 0 and id[0] == '_') id[1..] else id;
}

/// Returns an owned copy of `id` with a leading `_` ensured. Caller owns the result.
pub fn with_leading_underscore(gpa: std.mem.Allocator, id: []const u8) ![]u8 {
    if (id.len > 0 and id[0] == '_') return gpa.dupe(u8, id);
    return std.fmt.allocPrint(gpa, "_{s}", .{id});
}

test "with_leading_underscore preserves an already-prefixed id" {
    const gpa = std.testing.allocator;
    const out = try with_leading_underscore(gpa, "_abc");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("_abc", out);
}

test "with_leading_underscore prepends underscore when missing" {
    const gpa = std.testing.allocator;
    const out = try with_leading_underscore(gpa, "abc");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("_abc", out);
}

test "with_leading_underscore prepends underscore for empty input" {
    const gpa = std.testing.allocator;
    const out = try with_leading_underscore(gpa, "");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("_", out);
}

test "with_leading_underscore returns an independently-owned copy" {
    const gpa = std.testing.allocator;
    const input = "_abc";
    const out = try with_leading_underscore(gpa, input);
    defer gpa.free(out);
    try std.testing.expect(out.ptr != input.ptr);
}
