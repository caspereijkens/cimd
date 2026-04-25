const std = @import("std");
const utils = @import("utils.zig");
const cim_model = @import("cim_model.zig");
const cim_index = @import("cim_index.zig");
const tag_index = @import("tag_index.zig");
const iidm = @import("iidm.zig");
const cim_ssh = @import("cim_ssh.zig");

const assert = std.debug.assert;

const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

const CimModel = cim_model.CimModel;
const CimSsh = cim_ssh.CimSsh;
const CimIndex = cim_index.CimIndex;
const CimObjectView = tag_index.CimObjectView;
const CimObject = tag_index.CimObject;

pub const switch_types = [_][]const u8{ "Breaker", "Disconnector", "LoadBreakSwitch" };

/// Maps terminal raw ID → IIDM node number within its VoltageLevel.
/// All equipment (busbar sections, switches, generators, loads, etc.) looks up its
/// terminal here to find its node number. BusbarSection and switch terminals map
/// to the CN node. All other non-BusbarSection, non-switch terminals get a dedicated
/// node with an internal connection back to the CN node.
pub const NodeMap = std.StringHashMapUnmanaged(u32);

fn is_switch_type(type_name: []const u8) bool {
    for (switch_types) |switch_type| {
        if (std.mem.eql(u8, type_name, switch_type)) return true;
    }
    return false;
}

pub fn get_switch_type_slices(model: *const CimModel) [switch_types.len][]const CimObject {
    var switch_type_slices: [switch_types.len][]const CimObject = undefined;
    for (switch_types, 0..) |t, i| switch_type_slices[i] = model.get_objects_by_type(t);
    return switch_type_slices;
}

pub fn get_switch_count(slices: [switch_types.len][]const CimObject) usize {
    var count: usize = 0;
    for (slices) |s| count += s.len;
    return count;
}

pub fn find_voltage_level(parent: *const std.StringHashMapUnmanaged([]const u8), id: []const u8) []const u8 {
    var current = id;
    while (true) {
        const p = parent.get(current) orelse return current;
        current = p;
    }
}

// Smallest mRID wins as representative — PyPowSyBl's tie-breaking rule.
// Required for byte-identical JIIDM output.
pub fn union_voltage_levels(
    model: *const CimModel,
    parent: *std.StringHashMapUnmanaged([]const u8),
    voltage_level_id_a: []const u8,
    voltage_level_id_b: []const u8,
) !void {
    const root_a = find_voltage_level(parent, voltage_level_id_a);
    const root_b = find_voltage_level(parent, voltage_level_id_b);
    if (std.mem.eql(u8, root_a, root_b)) return;

    const voltage_level_a = model.getObjectById(root_a) orelse return;
    const voltage_level_b = model.getObjectById(root_b) orelse return;
    const mrid_a = try voltage_level_a.getProperty("IdentifiedObject.mRID") orelse
        strip_underscore(root_a);
    const mrid_b = try voltage_level_b.getProperty("IdentifiedObject.mRID") orelse
        strip_underscore(root_b);

    if (std.mem.lessThan(u8, mrid_a, mrid_b)) {
        parent.putAssumeCapacity(root_b, root_a);
    } else {
        parent.putAssumeCapacity(root_a, root_b);
    }
}

pub fn union_conn_nodes(
    parent: *std.StringHashMapUnmanaged([]const u8),
    id_a: []const u8,
    id_b: []const u8,
) void {
    const root_a = find_voltage_level(parent, id_a);
    const root_b = find_voltage_level(parent, id_b);
    if (std.mem.eql(u8, root_a, root_b)) return;
    parent.putAssumeCapacity(root_a, root_b);
}

// Smallest mRID wins, same reason as union_voltage_levels.
pub fn union_substations(
    gpa: std.mem.Allocator,
    parent: *std.StringHashMapUnmanaged([]const u8),
    id_a: []const u8,
    id_b: []const u8,
) !void {
    const root_a = find(parent, id_a);
    const root_b = find(parent, id_b);
    if (std.mem.eql(u8, root_a, root_b)) return;
    if (std.mem.lessThan(u8, strip_underscore(root_a), strip_underscore(root_b))) {
        try parent.put(gpa, root_b, root_a);
    } else {
        try parent.put(gpa, root_a, root_b);
    }
}

pub fn find(parent: *const std.StringHashMapUnmanaged([]const u8), x: []const u8) []const u8 {
    var cur = x;
    while (true) {
        const p = parent.get(cur) orelse return cur;
        if (std.mem.eql(u8, p, cur)) return cur;
        cur = p;
    }
}

// A switch with terminals in two different CIM VoltageLevels means those
// VLs are electrically one region. PyPowSyBl collapses them; this map
// records each stub VL's representative so callers can normalize VL refs.
pub fn build_voltage_level_merge(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.voltage_level_merge.count() == 0);

    const voltage_levels = model.get_objects_by_type("VoltageLevel");
    const switch_slices = get_switch_type_slices(model);

    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    try parent.ensureTotalCapacity(gpa, @intCast(get_switch_count(switch_slices)));
    defer parent.deinit(gpa);

    for (switch_slices) |slice| try cim_index.process_switch_type(model, index, slice, &parent);

    try index.voltage_level_merge.ensureTotalCapacity(gpa, @intCast(voltage_levels.len));
    for (voltage_levels) |voltage_level| {
        const root = find_voltage_level(&parent, voltage_level.id);
        if (!std.mem.eql(u8, root, voltage_level.id)) {
            index.voltage_level_merge.putAssumeCapacity(voltage_level.id, root);
        }
    }

    assert(index.voltage_level_merge.count() <= voltage_levels.len);
    // idempotency: no representative is itself a stub
    var it = index.voltage_level_merge.iterator();
    while (it.next()) |entry| {
        assert(index.voltage_level_merge.get(entry.value_ptr.*) == null);
    }
}

// Substations merge transitively: when their VLs merge (cross-VL switches),
// or when a PowerTransformer spans two substations. Mirrors PyPowSyBl.
pub fn build_substation_merge(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.substation_merge.count() == 0);
    assert(index.conn_node_container.count() > 0);

    const substations = model.get_objects_by_type("Substation");

    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(gpa);
    try parent.ensureTotalCapacity(gpa, @intCast(substations.len));
    for (substations) |substation| parent.putAssumeCapacity(substation.id, substation.id);

    // Pass 1: merged VLs drag their substations together.
    var voltage_level_it = index.voltage_level_merge.iterator();
    while (voltage_level_it.next()) |entry| {
        const stub_voltage_level = model.getObjectById(entry.key_ptr.*) orelse continue;
        const repr_voltage_level = model.getObjectById(entry.value_ptr.*) orelse continue;
        const stub_substation_ref = try stub_voltage_level.getReference("VoltageLevel.Substation") orelse continue;
        const repr_substation_ref = try repr_voltage_level.getReference("VoltageLevel.Substation") orelse continue;
        const stub_substation_id = strip_hash(stub_substation_ref);
        const repr_substation_id = strip_hash(repr_substation_ref);
        if (!std.mem.eql(u8, stub_substation_id, repr_substation_id)) {
            try union_substations(gpa, &parent, stub_substation_id, repr_substation_id);
        }
    }

    // Pass 2: PowerTransformers spanning two substations.
    for (model.get_objects_by_type("PowerTransformer")) |transformer| {
        const terminals = index.equipment_terminals.get(transformer.id) orelse continue;
        if (terminals.items.len < 2) continue;
        var first_substation_id: ?[]const u8 = null;
        for (terminals.items) |terminal| {
            const conn_node_id = terminal.conn_node_id orelse continue;
            const voltage_level_obj = conn_node_to_voltage_level(model, index, conn_node_id) orelse continue;
            const substation_ref = try voltage_level_obj.getReference("VoltageLevel.Substation") orelse continue;
            const substation_id = strip_hash(substation_ref);
            if (first_substation_id) |first| {
                if (!std.mem.eql(u8, first, substation_id)) {
                    try union_substations(gpa, &parent, first, substation_id);
                }
            } else {
                first_substation_id = substation_id;
            }
        }
    }

    try index.substation_merge.ensureTotalCapacity(gpa, @intCast(substations.len));
    for (substations) |substation| {
        const canonical = find(&parent, substation.id);
        if (std.mem.eql(u8, canonical, substation.id)) continue;
        const gop = index.substation_merge.getOrPutAssumeCapacity(canonical);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        // Multiple VL-level connections between the same two subs would
        // otherwise add the same stub twice.
        var already_present = false;
        for (gop.value_ptr.items) |existing| {
            if (std.mem.eql(u8, existing, substation.id)) {
                already_present = true;
                break;
            }
        }
        if (!already_present) try gop.value_ptr.append(gpa, substation.id);
    }

    assert(index.substation_merge.count() <= substations.len);
}

fn conn_node_to_voltage_level(model: *const cim_model.CimModel, index: *const CimIndex, conn_node_id: []const u8) ?CimObjectView {
    const container_id = index.conn_node_container.get(conn_node_id) orelse return null;
    const obj = model.getObjectById(container_id) orelse return null;
    if (!std.mem.eql(u8, obj.type_name, "VoltageLevel")) return null;
    return obj;
}

/// RegulatingControl resolution needs to find a BBS reachable through closed switches,
/// and doing the BFS at query time would be quadratic. We pre-compute once.
pub fn build_branch_first_search_pre_computation(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.conn_node_reachable_busbar_section.count() == 0);
    assert(index.conn_node_container.count() > 0);

    const conn_nodes = model.get_objects_by_type("ConnectivityNode");
    const switch_slices = get_switch_type_slices(model);

    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    try parent.ensureTotalCapacity(gpa, @intCast(get_switch_count(switch_slices) * 2));
    defer parent.deinit(gpa);

    for (switch_slices) |switches| {
        for (switches) |@"switch"| {
            const terminals = index.equipment_terminals.get(@"switch".id) orelse continue;
            if (terminals.items.len != 2) continue;
            const conn_node0 = index.terminal_conn_node.get(terminals.items[0].id) orelse continue;
            const conn_node1 = index.terminal_conn_node.get(terminals.items[1].id) orelse continue;
            union_conn_nodes(&parent, conn_node0, conn_node1);
        }
    }

    var cluster_to_busbar_section: std.StringHashMapUnmanaged([]const u8) = .empty;
    try cluster_to_busbar_section.ensureTotalCapacity(gpa, @intCast(index.busbar_section_in_parse_order.items.len));
    defer cluster_to_busbar_section.deinit(gpa);

    for (index.busbar_section_in_parse_order.items) |entry| {
        const root = find_voltage_level(&parent, entry.conn_node_id);
        if (!cluster_to_busbar_section.contains(root)) {
            cluster_to_busbar_section.putAssumeCapacity(root, entry.mrid);
        }
    }

    try index.conn_node_reachable_busbar_section.ensureTotalCapacity(gpa, @intCast(conn_nodes.len));

    var it = parent.keyIterator();
    while (it.next()) |conn_node_id| {
        const root = find_voltage_level(&parent, conn_node_id.*);
        const busbar_section_mrid = cluster_to_busbar_section.get(root) orelse continue;
        index.conn_node_reachable_busbar_section.putAssumeCapacity(conn_node_id.*, busbar_section_mrid);
    }

    assert(index.conn_node_reachable_busbar_section.count() <= conn_nodes.len);
}

/// Result of build_node_map. Bundles the node map with auxiliary maps consumed by
/// later passes (convert_fictitious_switches, populate_internal_connections).
pub const NodeMapResult = struct {
    node_map: NodeMap,
    /// Set of ConnectivityNode IDs that have at least one switch terminal attached.
    /// Built as a side effect of Phase 1 (switch terminal iteration).
    cn_has_switch: std.StringHashMapUnmanaged(void),
    /// Count of non-BusbarSection / non-switch terminals per ConnectivityNode,
    /// restricted to phase2_equipment_types that have a valid VL container.
    /// Built as a side effect of Phase 2 (equipment terminal iteration).
    cn_other_count: std.StringHashMapUnmanaged(u32),
    /// CN raw ID → CN's base node within its representative VoltageLevel.
    /// Needed by populate_internal_connections to detect which Phase 2 terminals
    /// landed on the CN base node (no IC) vs. a dedicated node (IC unless SSH-disconnected).
    conn_node_base_nodes: std.StringHashMapUnmanaged(u32),

    pub fn deinit(self: *NodeMapResult, gpa: std.mem.Allocator) void {
        self.node_map.deinit(gpa);
        self.cn_has_switch.deinit(gpa);
        self.cn_other_count.deinit(gpa);
        self.conn_node_base_nodes.deinit(gpa);
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

/// Build the terminal → node map, in PyPowSyBl's NodeContainerMapping shape.
///
/// Phase 1: BusbarSection and switch terminals map to their CN's base node (no IC).
/// Phase 2: other equipment terminals get a dedicated node, except the first non-SSH-
/// disconnected terminal on an ordinary CN, which takes the base node and leaves
/// successors to allocate dedicated ones. CNs with a BusbarSection or 3+ Phase 2
/// terminals are pre-seeded so all their Phase 2 terminals get dedicated nodes.
///
/// Internal-connection emission is split out into populate_internal_connections,
/// which derives the same dedicated-vs-base distinction from this function's output.
pub fn build_node_map(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    ssh_opt: ?CimSsh,
) !NodeMapResult {
    assert(index.conn_node_container.count() > 0);

    const conn_nodes = model.get_objects_by_type("ConnectivityNode");

    // Counts non-BBS, non-switch terminals per CN. Used only to pre-seed
    // conn_node_first_seen for CNs with 3+ Phase 2 terminals.
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

    var conn_node_base_nodes: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer conn_node_base_nodes.deinit(gpa);
    try conn_node_base_nodes.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    var conn_node_repr_voltage_level: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer conn_node_repr_voltage_level.deinit(gpa);
    try conn_node_repr_voltage_level.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    var voltage_level_counters: std.StringHashMapUnmanaged(u32) = .empty;
    defer voltage_level_counters.deinit(gpa);
    try voltage_level_counters.ensureTotalCapacity(gpa, @intCast(voltage_level_map.count()));

    // Base node assignment: sequential counter per representative VL, CN XML parse order.
    for (conn_nodes) |conn_node| {
        const container_id = index.conn_node_container.get(conn_node.id) orelse continue;
        const repr_voltage_level_id = find_voltage_level(&index.voltage_level_merge, container_id);
        if (voltage_level_map.get(repr_voltage_level_id) == null) continue;

        conn_node_repr_voltage_level.putAssumeCapacity(conn_node.id, repr_voltage_level_id);

        const voltage_level_gop = voltage_level_counters.getOrPutAssumeCapacity(repr_voltage_level_id);
        if (!voltage_level_gop.found_existing) voltage_level_gop.value_ptr.* = 0;
        const base_node = voltage_level_gop.value_ptr.*;
        voltage_level_gop.value_ptr.* += 1;
        conn_node_base_nodes.putAssumeCapacity(conn_node.id, base_node);
    }

    var cn_has_switch: std.StringHashMapUnmanaged(void) = .empty;
    errdefer cn_has_switch.deinit(gpa);
    try cn_has_switch.ensureTotalCapacity(gpa, @intCast(index.terminal_conn_node.count()));

    var cn_other_count: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer cn_other_count.deinit(gpa);
    try cn_other_count.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    var node_map: NodeMap = .empty;
    errdefer node_map.deinit(gpa);
    try node_map.ensureTotalCapacity(gpa, @intCast(index.terminal_conn_node.count()));

    // Phase 1: BusbarSection and switch terminals → CN base node.
    for (model.get_objects_by_type("BusbarSection")) |busbar_section| {
        const terminals = index.equipment_terminals.get(busbar_section.id) orelse continue;
        for (terminals.items) |terminal| {
            const base_node = conn_node_base_nodes.get(terminal.conn_node_id orelse continue) orelse continue;
            node_map.putAssumeCapacity(terminal.id, base_node);
        }
    }
    for (switch_types) |switch_type| {
        for (model.get_objects_by_type(switch_type)) |@"switch"| {
            const terminals = index.equipment_terminals.get(@"switch".id) orelse continue;
            for (terminals.items) |terminal| {
                const conn_node_id = terminal.conn_node_id orelse continue;
                const base_node = conn_node_base_nodes.get(conn_node_id) orelse continue;
                node_map.putAssumeCapacity(terminal.id, base_node);
                cn_has_switch.putAssumeCapacity(conn_node_id, {});
            }
        }
    }

    // CNs with 3+ Phase 2 terminals are pre-seeded as "already seen" so ALL their
    // Phase 2 terminals get dedicated nodes — matches PyPowSyBl's behaviour.
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

    // Phase 2: per-equipment-type iteration in PyPowSyBl's order. Within each
    // equipment, terminals in ascending sequence order. ACLineSegment is last so
    // shared CNs give the base node to other equipment first.
    for (phase2_equipment_types) |equipment_type| {
        for (model.get_objects_by_type(equipment_type)) |equip| {
            const terminals = index.equipment_terminals.get(equip.id) orelse continue;
            for (terminals.items) |t| {
                const conn_node_id = t.conn_node_id orelse continue;
                const base_node = conn_node_base_nodes.get(conn_node_id) orelse continue;
                {
                    const gop = cn_other_count.getOrPutAssumeCapacity(conn_node_id);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
                const repr_voltage_level_id = conn_node_repr_voltage_level.get(conn_node_id) orelse continue;
                const voltage_level_ctr = voltage_level_counters.getPtr(repr_voltage_level_id) orelse continue;
                const has_busbar_section = index.conn_node_to_busbar_section.contains(conn_node_id);
                // SSH-disconnected on first visit must not claim the CN base — an
                // SSH-connected co-terminal needs that slot. Always allocate dedicated.
                const ssh_disconnected = is_ssh_terminal_disconnected(ssh_opt, t.id);

                if (has_busbar_section or conn_node_first_seen.contains(conn_node_id) or ssh_disconnected) {
                    const terminal_node = voltage_level_ctr.*;
                    voltage_level_ctr.* += 1;
                    node_map.putAssumeCapacity(t.id, terminal_node);
                } else {
                    node_map.putAssumeCapacity(t.id, base_node);
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
        .conn_node_base_nodes = conn_node_base_nodes,
    };
}

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
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    ssh_opt: ?CimSsh,
    nm_result: *const NodeMapResult,
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
        if (is_switch_type(equipment.type_name)) continue;
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
        const repr_voltage_level_id = find_voltage_level(&index.voltage_level_merge, container_id);
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

    for (phase2_equipment_types) |equipment_type| {
        for (model.get_objects_by_type(equipment_type)) |equip| {
            const terminals = index.equipment_terminals.get(equip.id) orelse continue;
            for (terminals.items) |t| {
                const conn_node_id = t.conn_node_id orelse continue;
                const base_node = nm_result.conn_node_base_nodes.get(conn_node_id) orelse continue;
                const terminal_node = nm_result.node_map.get(t.id) orelse continue;
                if (terminal_node == base_node) continue;
                if (is_ssh_terminal_disconnected(ssh_opt, t.id)) continue;

                const container_id = index.conn_node_container.get(conn_node_id) orelse continue;
                const repr_voltage_level_id = find_voltage_level(&index.voltage_level_merge, container_id);
                const voltage_level = voltage_level_map.get(repr_voltage_level_id) orelse continue;
                voltage_level.node_breaker_topology.internal_connections.appendAssumeCapacity(.{
                    .node1 = base_node,
                    .node2 = terminal_node,
                });
            }
        }
    }
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
