//! By convention, root.zig is the root source file when making a library.
//!
//! Public surface for embedding cimd. Two layers, deliberately distinguished:
//! the CIM library under `src/cim/`, which is self-contained and destined to
//! become its own package, and the application pieces above it, which are not.
//! Keep this list curated: every export here is something a downstream caller
//! can rely on.

/// The CIM library: parse a CIM document and query, cross-reference, and
/// compare it. Works on any CIM profile, on documents using the conventional
/// `rdf:` prefix binding (see cim/document.zig for the exact contract). See
/// cim/cim.zig -- that file, not this one, is the API the library commits to,
/// and the only entry point into `src/cim/`.
pub const cim = @import("cim/cim.zig");

// Convenience re-exports of the names most callers reach for first. All of
// these are `cim.*`; nothing is defined here.
pub const CimDocument = cim.CimDocument;
pub const CimObject = cim.CimObject;
pub const CimObjectView = cim.CimObjectView;
pub const Overlay = cim.Overlay;
pub const IdPolicy = cim.IdPolicy;
pub const CimMergedView = cim.CimMergedView;
pub const cim_types = cim.cim_types;
pub const profile = cim.profile;
pub const refs = cim.refs;
pub const ReverseRef = cim.ReverseRef;
pub const ReverseRefIndex = cim.ReverseRefIndex;
pub const resolve_object = cim.resolve_object;
pub const collect_target_candidates = cim.collect_target_candidates;
pub const filter_referrers = cim.filter_referrers;
pub const diff = cim.diff;
pub const diff_core = cim.diff_core;
pub const eqdiff = cim.eqdiff;

// ── Application layer ─────────────────────────────────────────────────────────

/// Turns argv-shaped inputs into loaded models. Application code, not library
/// code: it reads files and reports bad input by printing a diagnostic and
/// calling `std.process.exit`, which an embedder cannot intercept. Use it only
/// if that is acceptable in your process.
pub const model_set = @import("model_set.zig");

comptime {
    _ = @import("cim/test_all.zig");
    _ = @import("model_set.zig");
    _ = @import("test_browse.zig");
    _ = @import("test_qocdc.zig");
    _ = @import("topology/test_resolve.zig");
    _ = @import("convert/test_conversion.zig");
    _ = @import("topology/cross_ref.zig");
    _ = @import("io/zip.zig");
    _ = @import("io/crc32.zig");
    _ = @import("convert/network.zig");
    _ = @import("convert/transformer.zig");
    _ = @import("convert/placement.zig");
    _ = @import("convert/equipment.zig");
    _ = @import("convert/line.zig");
    _ = @import("qocdc.zig");
    _ = @import("shacl/test_turtle.zig");
    _ = @import("shacl/test_rule_set.zig");
    _ = @import("test_validate.zig");
}
