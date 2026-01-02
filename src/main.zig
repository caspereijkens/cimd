const std = @import("std");
const cimd = @import("cimd");

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    try cimd.bufferedPrint();
}
