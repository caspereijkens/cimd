//! Test aggregation for the library.
//!
//! Deliberately not in cim.zig: that file is imported by every consumer, and a
//! comptime test list there compiles the library's whole test suite into each
//! of them -- the application ran all 700-odd twice. Keeping the list here means
//! the public API carries API and nothing else, and a build step that wants the
//! library's tests references this file.

comptime {
    _ = @import("test_boundary.zig");
    _ = @import("test_document.zig");
    _ = @import("test_ids.zig");
    _ = @import("test_uri.zig");
    _ = @import("test_tag_index.zig");
    _ = @import("test_xml_scan.zig");
    _ = @import("test_child_table.zig");
    _ = @import("test_diff.zig");
    _ = @import("test_eqdiff.zig");
    _ = @import("cim_types.zig");
    _ = @import("parse.zig");
    _ = @import("refs.zig");
    _ = @import("reference_index.zig");
    _ = @import("writer.zig");
    _ = @import("cgmes/profile.zig");
    _ = @import("cgmes/overlay.zig");
}
