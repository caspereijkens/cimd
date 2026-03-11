const std = @import("std");
const utils = @import("utils.zig");

test "strip_hash: strips leading # from non-empty string" {
    try std.testing.expectEqualStrings("foo", utils.strip_hash("#foo"));
}

test "strip_hash: no-op when string has no leading #" {
    try std.testing.expectEqualStrings("foo", utils.strip_hash("foo"));
}

test "strip_hash: no-op on empty string" {
    try std.testing.expectEqualStrings("", utils.strip_hash(""));
}

test "strip_underscore: strips leading _ from non-empty string" {
    try std.testing.expectEqualStrings("foo", utils.strip_underscore("_foo"));
}

test "strip_underscore: no-op when string has no leading _" {
    try std.testing.expectEqualStrings("foo", utils.strip_underscore("foo"));
}

test "strip_underscore: no-op on empty string" {
    try std.testing.expectEqualStrings("", utils.strip_underscore(""));
}
