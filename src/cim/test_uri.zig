const std = @import("std");
const uri = @import("uri.zig");

test "fragment extracts local and absolute URI fragments" {
    try std.testing.expectEqualStrings("UnitSymbol.V", uri.fragment("#UnitSymbol.V").?);
    try std.testing.expectEqualStrings(
        "UnitSymbol.VAr",
        uri.fragment("http://iec.ch/TC57/CIM100#UnitSymbol.VAr").?,
    );
}

test "fragment uses the last marker and preserves an empty fragment" {
    try std.testing.expectEqualStrings("value", uri.fragment("urn:example#kind#value").?);
    try std.testing.expectEqualStrings("", uri.fragment("urn:example#").?);
}

test "fragment reports a missing marker" {
    try std.testing.expect(uri.fragment("UnitSymbol.V") == null);
    try std.testing.expect(uri.fragment("") == null);
}

test "fragment_or_self accepts compact and qualified values" {
    try std.testing.expectEqualStrings("UnitSymbol.V", uri.fragment_or_self("UnitSymbol.V"));
    try std.testing.expectEqualStrings("UnitSymbol.V", uri.fragment_or_self("#UnitSymbol.V"));
    try std.testing.expectEqualStrings(
        "UnitSymbol.V",
        uri.fragment_or_self("http://iec.ch/TC57/CIM100#UnitSymbol.V"),
    );
    try std.testing.expectEqualStrings("", uri.fragment_or_self(""));
}
