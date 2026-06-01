//! By convention, root.zig is the root source file when making a library.
//!
//! Public surface for embedding cimd as a CIM-model library. Keep this list
//! curated: every export here is something a downstream caller can rely on.

// Model types — load a CGMES file and walk its contents.
pub const EQ = @import("cgmes/eq.zig").EQ;
pub const TP = @import("cgmes/tp.zig").TP;
pub const SSH = @import("cgmes/ssh.zig").SSH;
pub const CimObject = @import("cgmes/eq.zig").CimObject;
pub const CimObjectView = @import("cgmes/tag_index.zig").CimObjectView;
pub const cim_types = @import("cgmes/cim_types.zig");

// Overlay reads — EQ + TP + SSH merged with SSH > TP > EQ precedence.
pub const CimMergedView = @import("cgmes/ssh.zig").CimMergedView;

// Lookups across EQ + TP.
pub const resolve_object = @import("refs.zig").resolve_object;
pub const collect_target_candidates = @import("refs.zig").collect_target_candidates;

// Reverse-reference index.
pub const ReverseRef = @import("refs.zig").ReverseRef;
pub const ReverseRefIndex = @import("refs.zig").ReverseRefIndex;
pub const filter_referrers = @import("refs.zig").filter_referrers;

comptime {
    _ = @import("cgmes/test_tag_index.zig");
    _ = @import("test_diff.zig");
    _ = @import("test_browse.zig");
    _ = @import("cgmes/cim_types.zig");
    _ = @import("cgmes/test_eq.zig");
    _ = @import("cgmes/test_ids.zig");
    _ = @import("refs.zig");
    _ = @import("topology/test_resolve.zig");
    _ = @import("convert/test_conversion.zig");
    _ = @import("topology/cross_ref.zig");
    _ = @import("cgmes/ssh.zig");
    _ = @import("io/zip.zig");
    _ = @import("cgmes/tp.zig");
    _ = @import("convert/network.zig");
    _ = @import("convert/transformer.zig");
    _ = @import("convert/placement.zig");
    _ = @import("convert/equipment.zig");
    _ = @import("convert/line.zig");
    _ = @import("validate.zig");
}
