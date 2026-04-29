//! By convention, root.zig is the root source file when making a library.
comptime {
    _ = @import("cgmes/test_tag_index.zig");
    _ = @import("test_diff.zig");
    _ = @import("cgmes/test_eq.zig");
    _ = @import("cgmes/test_ids.zig");
    _ = @import("test_topology.zig");
    _ = @import("test_validate_topology.zig");
    _ = @import("test_conversion.zig");
    _ = @import("cim_index.zig");
    _ = @import("cgmes/ssh.zig");
    _ = @import("cgmes/tp.zig");
    _ = @import("converter.zig");
    _ = @import("convert/transformer.zig");
    _ = @import("convert/placement.zig");
    _ = @import("convert/equipment.zig");
    _ = @import("convert/line.zig");
}
