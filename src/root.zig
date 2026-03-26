//! By convention, root.zig is the root source file when making a library.
comptime {
    _ = @import("test_tag_index.zig");
    _ = @import("test_cim_model.zig");
    _ = @import("test_utils.zig");
    _ = @import("test_conversion.zig");
    _ = @import("cim_index.zig");
    _ = @import("converter.zig");
    _ = @import("convert/transformer.zig");
    _ = @import("convert/placement.zig");
    _ = @import("convert/equipment.zig");
    _ = @import("convert/line.zig");
}
