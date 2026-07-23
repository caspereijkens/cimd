//! Writer-error handling the library needs on its own.
//!
//! Everything in this directory renders into a caller-supplied
//! `*std.Io.Writer` and must not know where that writer goes. This one helper
//! is the exception it does need: when the library buffers into its own
//! `Allocating` writer, a write failure is not an output failure and must not
//! be reported as one. It lives here rather than in io/print.zig so the
//! library has no dependency on the CLI's output layer -- io/print.zig
//! re-exports it for CLI callers.

const std = @import("std");

/// Reinterpret `error.WriteFailed` from an `Allocating` writer as
/// `error.OutOfMemory`. An `std.Io.Writer.Allocating` only fails a write when
/// it cannot grow its backing allocation, so `WriteFailed` there unambiguously
/// means the allocator was exhausted. Call this at the boundary where the
/// concrete `Allocating` writer is still in scope; higher layers only see
/// `OutOfMemory`.
pub fn allocating_writer_result(
    allocating: *std.Io.Writer.Allocating,
    result: anytype,
) (@typeInfo(@TypeOf(result)).error_union.error_set || error{OutOfMemory})!@typeInfo(@TypeOf(result)).error_union.payload {
    // Intentional type witness: only an Allocating writer makes WriteFailed
    // unambiguously mean allocation failure. Keep this parameter even though
    // the generic result cannot be tied to it by Zig's type system.
    _ = allocating;
    return result catch |err| {
        if (err == error.WriteFailed) return error.OutOfMemory;
        return err;
    };
}

test "allocating writer failure is out of memory" {
    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    const failed: anyerror!void = error.WriteFailed;
    try std.testing.expectError(error.OutOfMemory, allocating_writer_result(&allocating, failed));
}
