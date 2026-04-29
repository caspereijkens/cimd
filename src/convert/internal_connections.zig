const std = @import("std");
const iidm = @import("../iidm/model.zig");
const eq = @import("../cgmes/eq.zig");
const cim_index = @import("../topology/cross_ref.zig");
const EQ = eq.EQ;
const CimIndex = cim_index.CimIndex;
const cim_ssh = @import("../cgmes/ssh.zig");
const SSH = cim_ssh.SSH;
const topology = @import("../topology/resolve.zig");
const Topology = topology.Topology;

/// Populate per-VoltageLevel internalConnections arrays from a built node map.
///
/// An IC is emitted iff a Phase 2 terminal landed on a dedicated node (terminal_node
/// != CN base_node) AND the terminal is not SSH-disconnected. SSH-disconnected
/// dedicated terminals are handled by convert_fictitious_switches instead.
///
/// Iteration order matches build_node_map's Phase 2, so insertion order into each
/// VL's internalConnections array is byte-identical to PyPowSyBl.
pub fn populate_internal_connections(
    gpa: std.mem.Allocator,
    model: *const EQ,
    index: *const CimIndex,
    topology_data: *const Topology,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    ssh_opt: ?SSH,
    nm_result: *const topology.NodeMapResult,
) !void {
    // Per-CN Phase 2 terminal count — same prediction the original code used to
    // pre-allocate IC capacity. Over-approximates by SSH-disconnected count, which
    // is fine for ensureTotalCapacity.
    var conn_node_other_count: std.StringHashMapUnmanaged(u32) = .empty;
    defer conn_node_other_count.deinit(gpa);
    try conn_node_other_count.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    for (model.get_objects_by_type("Terminal")) |terminal| {
        const conn_node_id = index.terminal_conn_node.get(terminal.id) orelse continue;
        const equipment_id = index.terminal_equipment.get(terminal.id) orelse continue;
        const equipment = model.getObjectById(equipment_id) orelse continue;
        if (topology.is_switch_type(equipment.type_name)) continue;
        if (std.mem.eql(u8, equipment.type_name, "BusbarSection")) continue;
        const gop = conn_node_other_count.getOrPutAssumeCapacity(conn_node_id);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var ic_counts: std.StringHashMapUnmanaged(usize) = .empty;
    defer ic_counts.deinit(gpa);
    try ic_counts.ensureTotalCapacity(gpa, @intCast(voltage_level_map.count()));

    for (model.get_objects_by_type("ConnectivityNode")) |conn_node| {
        const container_id = index.conn_node_container.get(conn_node.id) orelse continue;
        const repr_voltage_level_id = topology.find_root(&topology_data.voltage_level_merge, container_id);
        if (voltage_level_map.get(repr_voltage_level_id) == null) continue;

        const other_count = conn_node_other_count.get(conn_node.id) orelse 0;
        const has_busbar_section = index.conn_node_to_busbar_section.contains(conn_node.id);
        const ic_for_cn: usize = if (has_busbar_section or other_count >= 3) other_count else if (other_count > 0) other_count - 1 else 0;
        if (ic_for_cn > 0) {
            const gop = ic_counts.getOrPutAssumeCapacity(repr_voltage_level_id);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += ic_for_cn;
        }
    }

    var ic_it = ic_counts.iterator();
    while (ic_it.next()) |entry| {
        const voltage_level = voltage_level_map.get(entry.key_ptr.*) orelse continue;
        try voltage_level.node_breaker_topology.internal_connections.ensureTotalCapacity(gpa, entry.value_ptr.*);
    }

    for (topology.phase2_equipment_types) |equipment_type| {
        for (model.get_objects_by_type(equipment_type)) |equip| {
            const terminals = index.equipment_terminals.get(equip.id) orelse continue;
            for (terminals.items) |t| {
                const conn_node_id = t.conn_node_id orelse continue;
                const base_node = nm_result.conn_node_base_nodes.get(conn_node_id) orelse continue;
                const terminal_node = nm_result.node_map.get(t.id) orelse continue;
                if (terminal_node == base_node) continue;
                if (topology.is_ssh_terminal_disconnected(ssh_opt, t.id)) continue;

                const container_id = index.conn_node_container.get(conn_node_id) orelse continue;
                const repr_voltage_level_id = topology.find_root(&topology_data.voltage_level_merge, container_id);
                const voltage_level = voltage_level_map.get(repr_voltage_level_id) orelse continue;
                voltage_level.node_breaker_topology.internal_connections.appendAssumeCapacity(.{
                    .node1 = base_node,
                    .node2 = terminal_node,
                });
            }
        }
    }
}
