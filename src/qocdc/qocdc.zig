//! QoCDC v4.1.4 validation over a parsed CIM document.
//!
//! The single entry point of the qocdc library directory. Library rules match
//! src/cim/cim.zig, enforced by test_boundary.zig:
//!
//!  1. Imports stay inside this directory, with exactly one exception: the
//!     CIM library facade (`src/cim/cim.zig`). That is the one package
//!     dependency the eventual split-off repository will declare.
//!  2. No file, network, or process I/O; no `std.process.exit`. Callers
//!     supply the bytes and the writer, and decide the exit code.
//!  3. Application code imports this file and nothing else from the
//!     directory.
//!
//! Validation collects every violation into a `Report` instead of stopping at
//! the first: filename rules via `validate_filename`, grid-model rules via
//! `validate_model`, rendering via `write_report`.

const std = @import("std");
const cim = @import("../cim/cim.zig");

const catalog = @import("catalog.zig");
const report_mod = @import("report.zig");
const filename_mod = @import("filename.zig");

pub const Rule = catalog.Rule;
pub const rule_count = catalog.rule_count;
pub const RuleMask = catalog.RuleMask;
pub const message = catalog.message;

pub const Report = report_mod.Report;
pub const Violation = report_mod.Violation;
pub const no_offset = report_mod.no_offset;
pub const rendered_per_rule_max = report_mod.rendered_per_rule_max;
pub const stored_total_max = report_mod.stored_total_max;

pub const Filename = filename_mod.Filename;
pub const parse_filename = filename_mod.parse_filename;

/// Filename-stem rules. `zip_entry_stem` is the stem of the ZIP container's
/// single entry when the caller read one (FileNameConsistency); null skips
/// that check. Slices must outlive the report.
pub const validate_filename = filename_mod.validate;

/// All grid-model rules over a parsed document, header classification
/// included. One fused pass; collects every violation. The model must
/// outlive the report.
pub const validate_model = @import("engine.zig").validate_model;

/// Grid-model rules restricted to a request -- the focused-test entry point.
/// Dependencies of a requested rule run internally but never emit
/// diagnostics outside the request.
pub const validate_model_rules = @import("engine.zig").validate_model_rules;

/// FileNameConsistency alone, for callers that already parsed the stems.
pub const check_filename_consistency = filename_mod.check_consistency;

/// Render the collected report; returns the exact violation total for the
/// caller's exit-code decision. `model` may be null only when every stored
/// violation is offsetless (filename-only validation).
pub const write_report = report_mod.write_report;
