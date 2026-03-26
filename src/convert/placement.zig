const std = @import("std");
const iidm = @import("../iidm.zig");
const cim_index = @import("../cim_index.zig");
const cim_model = @import("../cim_model.zig");
const utils = @import("../utils.zig");
const connection = @import("connection.zig");

const strip_underscore = utils.strip_underscore;
const strip_hash = utils.strip_hash;

const assert = std.debug.assert;
const CimIndex = cim_index.CimIndex;

pub const Placement = struct {
    repr_voltage_level_id: []const u8,
    voltage_level: *iidm.VoltageLevel,
    node: u32,
};

/// Resolve VoltageLevel and node for a terminal.
/// Looks up the terminal's CN to find the VL, and the terminal ID to find the node.
/// Returns null if the CN has no container, no matching VL, or no node assignment.
/// Boundary CN endpoints (container = ACLineSegment, not in voltage_level_map) return null.
pub fn resolve_terminal_placement(
    terminal_id: []const u8,
    conn_node_id: []const u8,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const connection.NodeMap,
) ?Placement {
    assert(terminal_id.len > 0);
    assert(conn_node_id.len > 0);
    const container_id = index.conn_node_container.get(conn_node_id) orelse return null;
    const repr_voltage_level_id = cim_index.find_voltage_level(&index.voltage_level_merge, container_id);
    const voltage_level = voltage_level_map.get(repr_voltage_level_id) orelse return null;
    const node = node_map.get(terminal_id) orelse return null;
    return .{ .repr_voltage_level_id = repr_voltage_level_id, .voltage_level = voltage_level, .node = node };
}

/// Build OperationalLimitsGroup list for one terminal from the CimIndex.
/// Caller owns the returned list and must deinit it.
/// Group properties format matches PyPowSyBl's CGMES extension:
///   CGMES.normalValue_CurrentLimit_patl, CGMES.OperationalLimitSetName,
///   CGMES.OperationalLimitSetRdfID, CGMES.OperationalLimit_CurrentLimit_patl.
pub fn build_op_lims(
    gpa: std.mem.Allocator,
    index: *const CimIndex,
    terminal_id: []const u8,
) !std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) {
    assert(terminal_id.len > 0);
    var groups: std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) = .empty;

    const limit_sets = index.terminal_limit_sets.get(terminal_id) orelse return groups;
    try groups.ensureTotalCapacity(gpa, limit_sets.items.len);

    for (limit_sets.items) |set| {
        const set_mrid = try set.getProperty("IdentifiedObject.mRID") orelse strip_underscore(set.id);
        const set_name = try set.getProperty("IdentifiedObject.name") orelse set_mrid;

        var patl_value_str: ?[]const u8 = null;
        var patl_cl_mrid: ?[]const u8 = null;

        if (index.current_limits_by_set.get(set.id)) |cls| {
            for (cls.items) |cl| {
                const type_ref = try cl.getReference("OperationalLimit.OperationalLimitType") orelse continue;
                const type_id = strip_hash(type_ref);
                const type_info = index.limit_types.get(type_id) orelse continue;
                if (!type_info.is_infinite) continue; // skip TATLs for now (none in dataset)

                patl_value_str = try cl.getProperty("CurrentLimit.value") orelse
                    try cl.getProperty("CurrentLimit.normalValue");
                patl_cl_mrid = try cl.getProperty("IdentifiedObject.mRID") orelse strip_underscore(cl.id);
            }
        }

        var props: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer props.deinit(gpa);
        try props.ensureTotalCapacity(gpa, 4);
        if (patl_value_str) |pv| {
            const formatted_pv = try iidm.format_float_str(gpa, std.mem.trim(u8, pv, " \t\r\n"));
            props.appendAssumeCapacity(.{ .name = "CGMES.normalValue_CurrentLimit_patl", .value = formatted_pv });
        }
        props.appendAssumeCapacity(.{ .name = "CGMES.OperationalLimitSetName", .value = set_name });
        props.appendAssumeCapacity(.{ .name = "CGMES.OperationalLimitSetRdfID", .value = set_mrid });
        if (patl_cl_mrid) |pm| props.appendAssumeCapacity(.{ .name = "CGMES.OperationalLimit_CurrentLimit_patl", .value = pm });

        const current_limits: ?iidm.CurrentLimits = if (patl_value_str) |pv| blk: {
            const value = std.fmt.parseFloat(f64, std.mem.trim(u8, pv, " \t\r\n")) catch break :blk null;
            break :blk .{ .permanent_limit = value };
        } else null;

        groups.appendAssumeCapacity(.{
            .id = set_mrid,
            .properties = props,
            .current_limits = current_limits,
        });
        props = .empty; // ownership transferred
    }

    return groups;
}
