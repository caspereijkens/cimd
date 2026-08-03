//! URI helpers for CIM and RDF references.

const std = @import("std");

/// Return the portion after the last `#`, or null when `value` has no fragment
/// marker. The returned slice borrows from `value` and may be empty.
pub fn fragment(value: []const u8) ?[]const u8 {
    const hash_index = std.mem.lastIndexOfScalar(u8, value, '#') orelse return null;
    return value[hash_index + 1 ..];
}

/// Return the URI fragment when present, otherwise return `value` unchanged.
/// This accepts both full RDF enum URIs and compact names such as
/// `UnitSymbol.V`.
pub fn fragment_or_self(value: []const u8) []const u8 {
    return fragment(value) orelse value;
}
