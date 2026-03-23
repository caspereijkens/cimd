const std = @import("std");
const iidm = @import("../iidm.zig");
const cim_index = @import("../cim_index.zig");

const assert = std.debug.assert;
const CimIndex = cim_index.CimIndex;

pub const Placement = struct {
    repr_voltage_level_id: []const u8,
    voltage_level: *iidm.VoltageLevel,
    node: u32,
};

/// Resolve VoltageLevel and node for a ConnectivityNode.
/// Returns null if the CN has no container, no matching VL, or no node assignment.
/// Boundary CNs (container = ACLineSegment, not in voltage_level_map) return null.
pub fn resolve_conn_node_placement(
    conn_node_id: []const u8,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const std.StringHashMapUnmanaged(u32),
) ?Placement {
    assert(conn_node_id.len > 0);
    const container_id = index.conn_node_container.get(conn_node_id) orelse return null;
    const repr_voltage_level_id = cim_index.find_voltage_level(&index.voltage_level_merge, container_id);
    const voltage_level = voltage_level_map.get(repr_voltage_level_id) orelse return null;
    const node = node_map.get(conn_node_id) orelse return null;
    return .{ .repr_voltage_level_id = repr_voltage_level_id, .voltage_level = voltage_level, .node = node };
}
