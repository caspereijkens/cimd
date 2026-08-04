//! Test aggregation for the qocdc library.
//!
//! Mirrors src/cim/test_all.zig: kept out of qocdc.zig so consumers of the
//! API do not compile the test suite; the build's test step references this
//! file instead.

comptime {
    _ = @import("test_boundary.zig");
    _ = @import("test_filename.zig");
    _ = @import("test_qocdc.zig");
    _ = @import("rules.zig");
    _ = @import("report.zig");
}
