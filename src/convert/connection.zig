const std = @import("std");
const iidm = @import("../iidm.zig");
const cim_model = @import("../cim_model.zig");
const cim_index = @import("../cim_index.zig");
const utils = @import("../utils.zig");
const CimSsh = @import("../cim_ssh.zig").CimSsh;

const assert = std.debug.assert;

const CimModel = cim_model.CimModel;
const CimIndex = cim_index.CimIndex;
const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

pub const switch_type_names = [_][]const u8{ "Breaker", "Disconnector", "LoadBreakSwitch" };

fn is_switch_type(type_name: []const u8) bool {
    for (switch_type_names) |sw| {
        if (std.mem.eql(u8, type_name, sw)) return true;
    }
    return false;
}

/// Maps terminal raw ID → IIDM node number within its VoltageLevel.
/// All equipment (busbar sections, switches, generators, loads, etc.) looks up its
/// terminal here to find its node number. BusbarSection and switch terminals map
/// to the CN node. All other non-BusbarSection, non-switch terminals get a dedicated
/// node with an internal connection back to the CN node.
pub const NodeMap = std.StringHashMapUnmanaged(u32);

/// Result of build_node_map. Bundles the node map with two auxiliary maps that are
/// computed for free as side effects of the Phase 1 and Phase 2 passes, so that
/// convert_fictitious_switches does not need to rebuild them from scratch.
pub const NodeMapResult = struct {
    node_map: NodeMap,
    /// Set of ConnectivityNode IDs that have at least one switch terminal attached.
    /// Built as a side effect of Phase 1 (switch terminal iteration).
    cn_has_switch: std.StringHashMapUnmanaged(void),
    /// Count of non-BusbarSection / non-switch terminals per ConnectivityNode,
    /// restricted to phase2_equipment_types that have a valid VL container.
    /// Built as a side effect of Phase 2 (equipment terminal iteration).
    cn_other_count: std.StringHashMapUnmanaged(u32),

    pub fn deinit(self: *NodeMapResult, gpa: std.mem.Allocator) void {
        self.node_map.deinit(gpa);
        self.cn_has_switch.deinit(gpa);
        self.cn_other_count.deinit(gpa);
    }
};

/// Equipment type processing order for Phase 2 node allocation.
/// Matches PyPowSyBl's CGMES importer processing sequence.
/// BusbarSections and switch types are excluded (handled in Phase 1).
pub const phase2_equipment_types = [_][]const u8{
    "ACLineSegment",
    "PowerTransformer",
    "SynchronousMachine",
    "EnergyConsumer",
    "ConformLoad",
    "NonConformLoad",
    "LinearShuntCompensator",
    "StaticVarCompensator",
    "SeriesCompensator",
};


/// Build the terminal → node map and populate internalConnections on all VLs.
///
/// Two-phase algorithm matching PyPowSyBl's NodeContainerMapping:
///
/// Phase 1 — assign CN base nodes in ConnectivityNode XML parse order.
///   Every CN in a valid VoltageLevel receives a sequential base node (0, 1, 2, …).
///   BusbarSection and switch terminals are mapped to their CN base node (no IC).
///
/// Phase 2 — assign terminal nodes by equipment processing order.
///   Non-BusbarSection, non-switch terminals are assigned in equipment-type processing order
///   (ACLineSegment → PowerTransformer → SynchronousMachine → EnergyConsumer → …).
///   Within each type, equipment is in XML parse order; within each equipment,
///   terminals are in ascending sequence order.
///
///   Dedicated node rules:
///     • CN has BusbarSection → always dedicated node + IC(conn_node, terminal_node).
///     • CN has 3+ non-BusbarSection non-switch terminals → same: all get dedicated node + IC.
///     • First non-BusbarSection non-switch terminal on an ordinary CN → CN base node (no IC).
///     • All subsequent terminals on that CN → dedicated node + IC.
pub fn build_node_map(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    ssh_opt: ?CimSsh,
) !NodeMapResult {
    assert(index.conn_node_container.count() > 0);

    const conn_nodes = model.get_objects_by_type("ConnectivityNode");

    // Pre-scan: count non-BusbarSection non-switch terminals per CN for IC pre-allocation.
    var conn_node_other_count: std.StringHashMapUnmanaged(u32) = .empty;
    defer conn_node_other_count.deinit(gpa);
    try conn_node_other_count.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    for (model.get_objects_by_type("Terminal")) |terminal| {
        const conn_node_id = index.terminal_conn_node.get(terminal.id) orelse continue;
        const equipment_id = index.terminal_equipment.get(terminal.id) orelse continue;
        const equipment = model.getObjectById(equipment_id) orelse continue;
        if (is_switch_type(equipment.type_name)) continue;
        if (std.mem.eql(u8, equipment.type_name, "BusbarSection")) continue;
        const gop = conn_node_other_count.getOrPutAssumeCapacity(conn_node_id);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    // Combined pass: build CN→repr_voltage_level cache, count ICs, assign base nodes.
    var conn_node_repr_voltage_level: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer conn_node_repr_voltage_level.deinit(gpa);
    try conn_node_repr_voltage_level.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    var conn_node_base_nodes: std.StringHashMapUnmanaged(u32) = .empty;
    defer conn_node_base_nodes.deinit(gpa);
    try conn_node_base_nodes.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    var voltage_level_counters: std.StringHashMapUnmanaged(u32) = .empty;
    defer voltage_level_counters.deinit(gpa);
    try voltage_level_counters.ensureTotalCapacity(gpa, @intCast(voltage_level_map.count()));

    var internal_connection_counts: std.StringHashMapUnmanaged(usize) = .empty;
    defer internal_connection_counts.deinit(gpa);
    try internal_connection_counts.ensureTotalCapacity(gpa, @intCast(voltage_level_map.count()));

    for (conn_nodes) |conn_node| {
        const container_id = index.conn_node_container.get(conn_node.id) orelse continue;
        const repr_voltage_level_id = cim_index.find_voltage_level(&index.voltage_level_merge, container_id);
        if (voltage_level_map.get(repr_voltage_level_id) == null) continue;

        conn_node_repr_voltage_level.putAssumeCapacity(conn_node.id, repr_voltage_level_id);

        const other_count = conn_node_other_count.get(conn_node.id) orelse 0;
        const has_busbar_section = index.conn_node_to_busbar_section.contains(conn_node.id);
        const internal_connections_for_conn_node: usize = if (has_busbar_section or other_count >= 3) other_count else if (other_count > 0) other_count - 1 else 0;
        if (internal_connections_for_conn_node > 0) {
            const internal_connection_gop = internal_connection_counts.getOrPutAssumeCapacity(repr_voltage_level_id);
            if (!internal_connection_gop.found_existing) internal_connection_gop.value_ptr.* = 0;
            internal_connection_gop.value_ptr.* += internal_connections_for_conn_node;
        }

        // Base node assignment: sequential counter per repr VL, CN XML parse order.
        const voltage_level_gop = voltage_level_counters.getOrPutAssumeCapacity(repr_voltage_level_id);
        if (!voltage_level_gop.found_existing) voltage_level_gop.value_ptr.* = 0;
        const base_node = voltage_level_gop.value_ptr.*;
        voltage_level_gop.value_ptr.* += 1;
        conn_node_base_nodes.putAssumeCapacity(conn_node.id, base_node);
    }

    {
        var it = internal_connection_counts.iterator();
        while (it.next()) |entry| {
            const voltage_level = voltage_level_map.get(entry.key_ptr.*) orelse continue;
            try voltage_level.node_breaker_topology.internal_connections.ensureTotalCapacity(gpa, entry.value_ptr.*);
        }
    }

    // Phase 1: assign BusbarSection and switch terminals to their CN base node.
    // cn_has_switch is built as a free side effect of the switch terminal loop below.
    var cn_has_switch: std.StringHashMapUnmanaged(void) = .empty;
    errdefer cn_has_switch.deinit(gpa);
    try cn_has_switch.ensureTotalCapacity(gpa, @intCast(index.terminal_conn_node.count()));

    // cn_other_count is built as a free side effect of the Phase 2 terminal loop below.
    var cn_other_count: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer cn_other_count.deinit(gpa);
    try cn_other_count.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    var node_map: NodeMap = .empty;
    errdefer node_map.deinit(gpa);
    try node_map.ensureTotalCapacity(gpa, @intCast(index.terminal_conn_node.count()));

    for (model.get_objects_by_type("BusbarSection")) |busbar_section| {
        const terminals = index.equipment_terminals.get(busbar_section.id) orelse continue;
        for (terminals.items) |t| {
            const base_node = conn_node_base_nodes.get(t.conn_node_id orelse continue) orelse continue;
            node_map.putAssumeCapacity(t.id, base_node);
        }
    }
    for (switch_type_names) |sw_type| {
        for (model.get_objects_by_type(sw_type)) |sw| {
            const terminals = index.equipment_terminals.get(sw.id) orelse continue;
            for (terminals.items) |t| {
                const conn_node_id = t.conn_node_id orelse continue;
                const base_node = conn_node_base_nodes.get(conn_node_id) orelse continue;
                node_map.putAssumeCapacity(t.id, base_node);
                cn_has_switch.putAssumeCapacity(conn_node_id, {});
            }
        }
    }

    // Phase 2: assign dedicated terminal nodes in equipment processing order.
    // Matches PyPowSyBl's per-equipment-type iteration.
    // Within each equipment: terminals in ascending seq order.
    // ACLineSegment is last so shared CNs give CN base to other equipment first.
    //
    // Pre-seeding rule: CNs with 3+ non-BusbarSection non-switch terminals are pre-seeded
    // as "already seen", so ALL their Phase 2 terminals get dedicated nodes and
    // the CN base node remains unoccupied. Matches PyPowSyBl behaviour.
    var conn_node_first_seen: std.StringHashMapUnmanaged(void) = .empty;
    defer conn_node_first_seen.deinit(gpa);
    try conn_node_first_seen.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    {
        var it = conn_node_other_count.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* >= 3) {
                conn_node_first_seen.putAssumeCapacity(entry.key_ptr.*, {});
            }
        }
    }

    for (phase2_equipment_types) |equipment_type| {
        for (model.get_objects_by_type(equipment_type)) |equip| {
            const terminals = index.equipment_terminals.get(equip.id) orelse continue;
            for (terminals.items) |t| {
                const conn_node_id = t.conn_node_id orelse continue;
                const conn_node = conn_node_base_nodes.get(conn_node_id) orelse continue;
                // Side effect: count phase2 terminals per CN for convert_fictitious_switches.
                // conn_node lookup above already filters to CNs with a valid VL container,
                // matching the index.conn_node_container check in the original standalone pass.
                {
                    const gop = cn_other_count.getOrPutAssumeCapacity(conn_node_id);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
                const repr_voltage_level_id = conn_node_repr_voltage_level.get(conn_node_id) orelse continue;
                const voltage_level = voltage_level_map.get(repr_voltage_level_id) orelse continue;
                const voltage_level_ctr = voltage_level_counters.getPtr(repr_voltage_level_id) orelse continue;
                const has_busbar_section = index.conn_node_to_busbar_section.contains(conn_node_id);

                // SSH-disconnected terminals get a dedicated node but no IC.
                // convert_fictitious_switches creates the fictitious switch instead.
                const ssh_disconnected = is_ssh_terminal_disconnected(ssh_opt, t.id);

                if (has_busbar_section or conn_node_first_seen.contains(conn_node_id)) {
                    const terminal_node = voltage_level_ctr.*;
                    voltage_level_ctr.* += 1;
                    node_map.putAssumeCapacity(t.id, terminal_node);
                    if (!ssh_disconnected) {
                        voltage_level.node_breaker_topology.internal_connections.appendAssumeCapacity(.{
                            .node1 = conn_node,
                            .node2 = terminal_node,
                        });
                    }
                } else if (ssh_disconnected) {
                    // SSH-disconnected on first visit: allocate dedicated node, don't take
                    // the "first seen" slot so an SSH-connected co-terminal can use the CN node.
                    const terminal_node = voltage_level_ctr.*;
                    voltage_level_ctr.* += 1;
                    node_map.putAssumeCapacity(t.id, terminal_node);
                } else {
                    node_map.putAssumeCapacity(t.id, conn_node);
                    conn_node_first_seen.putAssumeCapacity(conn_node_id, {});
                }
            }
        }
    }

    assert(node_map.count() <= index.terminal_conn_node.count());

    return .{
        .node_map = node_map,
        .cn_has_switch = cn_has_switch,
        .cn_other_count = cn_other_count,
    };
}

/// Returns true if the terminal is marked as disconnected in SSH
/// (ACDCTerminal.connected = "false"). The terminal raw rdf:ID is used
/// to look up the SSH patch; strip_underscore converts it to the mRID key.
pub fn is_ssh_terminal_disconnected(ssh_opt: ?CimSsh, terminal_id: []const u8) bool {
    assert(terminal_id.len > 0);
    const ssh = ssh_opt orelse return false;
    const mrid = strip_underscore(terminal_id);
    const connected = ssh.getProperty(mrid, "ACDCTerminal.connected") catch return false;
    const val = connected orelse return false;
    return std.mem.eql(u8, val, "false");
}
