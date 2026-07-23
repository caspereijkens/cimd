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

/// Returns true if `obj_id` is matched by `prefix` under cimd's prefix-matching
/// rules. Two forms are accepted: a literal startsWith (the only form that can
/// match FullModel `urn:uuid:...` ids carried in rdf:about), and -- as a
/// convenience for the common rdf:ID form -- a match against `_<prefix>` so
/// users may type `be60a3cf` instead of `_be60a3cf-...`. The convenience form
/// is skipped when `prefix` already starts with `_` to avoid double-prefix
/// surprises like searching for `__be60`.
pub fn id_prefix_matches(obj_id: []const u8, prefix: []const u8) bool {
    if (std.mem.startsWith(u8, obj_id, prefix)) return true;
    if (prefix.len > 0 and prefix[0] == '_') return false;
    if (obj_id.len == 0 or obj_id[0] != '_') return false;
    return std.mem.startsWith(u8, obj_id[1..], prefix);
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

test "id_prefix_matches: rdf:ID form with underscore convenience" {
    try std.testing.expect(id_prefix_matches("_be60a3cf-fed6", "be60"));
    try std.testing.expect(id_prefix_matches("_be60a3cf-fed6", "_be60"));
    try std.testing.expect(id_prefix_matches("_be60a3cf-fed6", "_be60a3cf-fed6"));
    try std.testing.expect(!id_prefix_matches("_be60a3cf-fed6", "ac90"));
}

test "id_prefix_matches: FullModel urn:uuid form via literal prefix" {
    const urn = "urn:uuid:484c5d95-2ef3-4bbb-84ff-56ff5023dcbe";
    try std.testing.expect(id_prefix_matches(urn, "urn"));
    try std.testing.expect(id_prefix_matches(urn, "urn:uuid:484c"));
    try std.testing.expect(id_prefix_matches(urn, urn));
    try std.testing.expect(!id_prefix_matches(urn, "uuid"));
}

test "id_prefix_matches: explicit underscore prefix never double-underscores" {
    // Searching for "_urn" must not silently match "urn:uuid:..." via the
    // convenience path -- the user opted into the literal form by typing `_`.
    try std.testing.expect(!id_prefix_matches("urn:uuid:abc", "_urn"));
}

test "id_prefix_matches: empty prefix matches everything" {
    try std.testing.expect(id_prefix_matches("_abc", ""));
    try std.testing.expect(id_prefix_matches("urn:uuid:abc", ""));
    try std.testing.expect(id_prefix_matches("", ""));
}

test "id_prefix_matches: empty id only matches empty prefix" {
    try std.testing.expect(!id_prefix_matches("", "abc"));
    try std.testing.expect(!id_prefix_matches("", "_abc"));
}
