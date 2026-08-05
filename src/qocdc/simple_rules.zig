//! The default authoring path for same-object grid-model rules.
//!
//! A simple rule filters one CIM type group and inspects only the object it is
//! handed. Its predicate returns `null` when the object is valid, or a detail
//! slice (often `""`) when it violates the rule. The engine owns iteration,
//! masking, profile gating, and report emission.
//!
//! Start new rules here. See `docs/ADDING_QOCDC_RULE.md` for the complete
//! recipe. The optimized slot and relational machinery in `rules.zig` is for
//! rules that benchmarks show need shared child scans, or whose verdict
//! depends on other objects.

const std = @import("std");
const assert = std.debug.assert;

const cim = @import("../cim/cim.zig");
const optimized = @import("rules.zig");

const Rule = optimized.Rule;

/// Read-only run information available to a simple predicate.
pub const Context = struct {
    /// Null when the model header could not identify a CGMES version.
    version: ?cim.profile.Version,
};

pub const Check = *const fn (context: Context, obj: cim.CimObject) ?[]const u8;

pub const SimpleRule = struct {
    rule: Rule,
    filter: optimized.TypeFilter,
    gate: optimized.Gate = .always,
    /// Set when `check` reads `Context.version`, so the engine classifies the
    /// header even though the rule is not profile-gated.
    uses_version: bool = false,
    check: Check,
};

/// The common registration form: `type_name` and all its CIM subtypes.
pub fn for_type(
    comptime rule: Rule,
    comptime type_name: []const u8,
    comptime check: Check,
) SimpleRule {
    return .{
        .rule = rule,
        .filter = .{ .is_a_any = &.{type_name} },
        .check = check,
    };
}

/// Registration for one exact CIM class, excluding subtypes.
pub fn for_exact_type(
    comptime rule: Rule,
    comptime type_name: []const u8,
    comptime check: Check,
) SimpleRule {
    return .{
        .rule = rule,
        .filter = .{ .exact = type_name },
        .check = check,
    };
}

/// The complete simple-rule registry. Adding an ordinary rule is one line
/// here plus its predicate below.
pub const entries = [_]SimpleRule{
    for_type(.SynchronousCondenser, "SynchronousMachine", check_synchronous_condenser),
};

/// SynchronousCondenser
///
/// A SynchronousMachine whose kind is exactly `condenser` must not declare a
/// RotatingMachine.GeneratingUnit association. `generatorOrCondenser` is a
/// different enum value and is deliberately accepted.
fn check_synchronous_condenser(_: Context, obj: cim.CimObject) ?[]const u8 {
    const type_reference = obj.reference("SynchronousMachine.type") catch return null;
    const machine_type = cim.uri.fragment_or_self(type_reference orelse return null);
    if (!std.mem.eql(u8, machine_type, "SynchronousMachineKind.condenser")) return null;
    if (!declares_child(obj, "RotatingMachine.GeneratingUnit")) return null;
    return "";
}

/// Whether an object contains a child of `name`, regardless of whether that
/// child is a readable reference, a literal, self-closing, or malformed.
fn declares_child(obj: cim.CimObject, name: []const u8) bool {
    var children = obj.children();
    while (children.next()) |child| {
        if (std.mem.eql(u8, child.name, name)) return true;
    }
    return false;
}

comptime {
    assert(entries.len <= 64); // the engine's active set is a u64
    // One rule must use one execution lane. A duplicate would emit twice and
    // make it unclear which implementation is authoritative.
    for (entries) |simple| {
        for (optimized.object_rules) |fused| {
            assert(simple.rule != fused.rule);
        }
    }
}
