const std = @import("std");
const utils = @import("../cgmes/ids.zig");
const eq = @import("../cgmes/eq.zig");
const cim_index = @import("cross_ref.zig");
const tag_index = @import("../cgmes/tag_index.zig");
const cim_ssh = @import("../cgmes/ssh.zig");

const assert = std.debug.assert;

const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

const EQ = eq.EQ;
const SSH = cim_ssh.SSH;
const CimIndex = cim_index.CimIndex;
const CimObjectView = tag_index.CimObjectView;
const CimObject = tag_index.CimObject;

const IdMap = std.StringHashMapUnmanaged([]const u8);
const CountMap = std.StringHashMapUnmanaged(u32);
const SetMap = std.StringHashMapUnmanaged(void);

pub const switch_types = [_][]const u8{ "Breaker", "Disconnector", "LoadBreakSwitch" };

pub const Topology = struct {
    voltage_level_merge: IdMap,
    substation_merge: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    conn_node_reachable_busbar_section: IdMap,

    pub fn empty() Topology {
        return .{
            .conn_node_reachable_busbar_section = .empty,
            .voltage_level_merge = .empty,
            .substation_merge = .empty,
        };
    }

    pub fn build(gpa: std.mem.Allocator, model: *const EQ, index: *const CimIndex) !Topology {
        var topology = Topology.empty();
        errdefer topology.deinit(gpa);

        try build_voltage_level_merge(gpa, model, index, &topology);
        try build_substation_merge(gpa, model, index, &topology);
        try build_reachable_busbar_section_index(gpa, model, index, &topology);

        return topology;
    }

    pub fn build_for_topological_nodes(gpa: std.mem.Allocator, model: *const EQ, index: *const CimIndex) !Topology {
        var topology = Topology.empty();
        errdefer topology.deinit(gpa);

        try build_voltage_level_merge(gpa, model, index, &topology);

        return topology;
    }

    pub fn deinit(self: *Topology, gpa: std.mem.Allocator) void {
        self.voltage_level_merge.deinit(gpa);
        var it = self.substation_merge.valueIterator();
        while (it.next()) |list| {
            list.deinit(gpa);
        }
        self.substation_merge.deinit(gpa);
        self.conn_node_reachable_busbar_section.deinit(gpa);
    }
};

pub const TopologicalNode = struct {
    mrid: []const u8,
    name: []const u8,
    base_voltage: []const u8,
    conn_node_container: []const u8,

    pub fn jsonStringify(self: TopologicalNode, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("mrid");
        try jws.write(self.mrid);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("baseVoltage");
        try jws.write(self.base_voltage);
        try jws.objectField("voltageLevel");
        try jws.write(self.conn_node_container);
        try jws.endObject();
    }
};

/// Maps terminal raw ID → IIDM node number within its VoltageLevel.
/// All equipment (busbar sections, switches, generators, loads, etc.) looks up its
/// terminal here to find its node number. BusbarSection and switch terminals map
/// to the CN node. All other non-BusbarSection, non-switch terminals get a dedicated
/// node with an internal connection back to the CN node.
pub const NodeMap = std.StringHashMapUnmanaged(u32);

pub fn is_switch_type(type_name: []const u8) bool {
    for (switch_types) |switch_type| {
        if (std.mem.eql(u8, type_name, switch_type)) return true;
    }
    return false;
}

pub fn get_switch_type_slices(model: *const EQ) [switch_types.len][]const CimObject {
    var switch_type_slices: [switch_types.len][]const CimObject = undefined;
    for (switch_types, 0..) |t, i| switch_type_slices[i] = model.get_objects_by_type(t);
    return switch_type_slices;
}

pub fn get_switch_count(slices: [switch_types.len][]const CimObject) usize {
    var count: usize = 0;
    for (slices) |s| count += s.len;
    return count;
}

/// Walks parent links to the union-find root. Used for VL, substation, and CN roots.
pub fn find_root(parent: *const IdMap, id: []const u8) []const u8 {
    var current = id;
    while (true) {
        const p = parent.get(current) orelse return current;
        if (std.mem.eql(u8, p, current)) return current;
        current = p;
    }
}

// Smallest mRID wins as representative — PyPowSyBl's tie-breaking rule.
// Required for byte-identical JIIDM output.
pub fn union_voltage_levels(
    model: *const EQ,
    parent: *IdMap,
    voltage_level_id_a: []const u8,
    voltage_level_id_b: []const u8,
) !void {
    const root_a = find_root(parent, voltage_level_id_a);
    const root_b = find_root(parent, voltage_level_id_b);
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

// Smallest stripped id wins as representative — PyPowSyBl tie-breaking. Used
// for CN and substation unions, where the mRID is `strip_underscore(rdf:ID)`.
pub fn union_smallest_id_wins(parent: *IdMap, id_a: []const u8, id_b: []const u8) void {
    const root_a = find_root(parent, id_a);
    const root_b = find_root(parent, id_b);
    if (std.mem.eql(u8, root_a, root_b)) return;
    if (std.mem.lessThan(u8, strip_underscore(root_a), strip_underscore(root_b))) {
        parent.putAssumeCapacity(root_b, root_a);
    } else {
        parent.putAssumeCapacity(root_a, root_b);
    }
}

// A switch with terminals in two different CIM VoltageLevels means those
// VLs are electrically one region. PyPowSyBl collapses them; this map
// records each stub VL's representative so callers can normalize VL refs.
pub fn build_voltage_level_merge(gpa: std.mem.Allocator, model: *const eq.EQ, index: *const CimIndex, topology: *Topology) !void {
    assert(topology.voltage_level_merge.count() == 0);

    const voltage_levels = model.get_objects_by_type("VoltageLevel");
    const switch_slices = get_switch_type_slices(model);

    var parent: IdMap = .empty;
    defer parent.deinit(gpa);
    try parent.ensureTotalCapacity(gpa, @intCast(get_switch_count(switch_slices)));

    for (switch_slices) |slice| try cim_index.process_switch_type(model, index, slice, &parent);

    try topology.voltage_level_merge.ensureTotalCapacity(gpa, @intCast(voltage_levels.len));
    for (voltage_levels) |voltage_level| {
        const root = find_root(&parent, voltage_level.id);
        if (!std.mem.eql(u8, root, voltage_level.id)) {
            topology.voltage_level_merge.putAssumeCapacity(voltage_level.id, root);
        }
    }

    assert(topology.voltage_level_merge.count() <= voltage_levels.len);
    // idempotency: no representative is itself a stub
    var it = topology.voltage_level_merge.iterator();
    while (it.next()) |entry| {
        assert(topology.voltage_level_merge.get(entry.value_ptr.*) == null);
    }
}

// Substations merge transitively: when their VLs merge (cross-VL switches),
// or when a PowerTransformer spans two substations. Mirrors PyPowSyBl.
pub fn build_substation_merge(gpa: std.mem.Allocator, model: *const eq.EQ, index: *const CimIndex, topology: *Topology) !void {
    assert(topology.substation_merge.count() == 0);
    assert(index.conn_node_container.count() > 0);

    const substations = model.get_objects_by_type("Substation");

    var parent: IdMap = .empty;
    defer parent.deinit(gpa);
    try parent.ensureTotalCapacity(gpa, @intCast(substations.len));
    for (substations) |substation| parent.putAssumeCapacity(substation.id, substation.id);

    // Pass 1: merged VLs drag their substations together.
    var voltage_level_it = topology.voltage_level_merge.iterator();
    while (voltage_level_it.next()) |entry| {
        const stub_voltage_level = model.getObjectById(entry.key_ptr.*) orelse continue;
        const repr_voltage_level = model.getObjectById(entry.value_ptr.*) orelse continue;
        const stub_substation_ref = try stub_voltage_level.getReference("VoltageLevel.Substation") orelse continue;
        const repr_substation_ref = try repr_voltage_level.getReference("VoltageLevel.Substation") orelse continue;
        const stub_substation_id = strip_hash(stub_substation_ref);
        const repr_substation_id = strip_hash(repr_substation_ref);
        if (!std.mem.eql(u8, stub_substation_id, repr_substation_id)) {
            union_smallest_id_wins(&parent, stub_substation_id, repr_substation_id);
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
                    union_smallest_id_wins(&parent, first, substation_id);
                }
            } else {
                first_substation_id = substation_id;
            }
        }
    }

    try topology.substation_merge.ensureTotalCapacity(gpa, @intCast(substations.len));
    for (substations) |substation| {
        const canonical = find_root(&parent, substation.id);
        if (std.mem.eql(u8, canonical, substation.id)) continue;
        const gop = topology.substation_merge.getOrPutAssumeCapacity(canonical);
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

    assert(topology.substation_merge.count() <= substations.len);
}

fn conn_node_to_voltage_level(model: *const eq.EQ, index: *const CimIndex, conn_node_id: []const u8) ?CimObjectView {
    const container_id = index.conn_node_container.get(conn_node_id) orelse return null;
    const obj = model.getObjectById(container_id) orelse return null;
    if (!std.mem.eql(u8, obj.type_name, "VoltageLevel")) return null;
    return obj;
}

/// RegulatingControl resolution needs to find a BBS reachable through switches,
/// and doing the graph walk at query time would be quadratic. We pre-compute once.
pub fn build_reachable_busbar_section_index(gpa: std.mem.Allocator, model: *const eq.EQ, index: *const CimIndex, topology: *Topology) !void {
    assert(topology.conn_node_reachable_busbar_section.count() == 0);
    assert(index.conn_node_container.count() > 0);

    const conn_nodes = model.get_objects_by_type("ConnectivityNode");
    const switch_slices = get_switch_type_slices(model);

    var parent: IdMap = .empty;
    defer parent.deinit(gpa);
    try parent.ensureTotalCapacity(gpa, @intCast(conn_nodes.len));

    for (conn_nodes) |conn_node| {
        parent.putAssumeCapacity(conn_node.id, conn_node.id);
    }

    for (switch_slices) |switches| {
        for (switches) |@"switch"| {
            const terminals = index.equipment_terminals.get(@"switch".id) orelse continue;
            if (terminals.items.len != 2) continue;
            const conn_node0 = index.terminal_conn_node.get(terminals.items[0].id) orelse continue;
            const conn_node1 = index.terminal_conn_node.get(terminals.items[1].id) orelse continue;
            if (!parent.contains(conn_node0)) continue;
            if (!parent.contains(conn_node1)) continue;
            union_smallest_id_wins(&parent, conn_node0, conn_node1);
        }
    }

    var cluster_to_busbar_section: IdMap = .empty;
    defer cluster_to_busbar_section.deinit(gpa);
    try cluster_to_busbar_section.ensureTotalCapacity(gpa, @intCast(index.busbar_section_in_parse_order.items.len));

    for (index.busbar_section_in_parse_order.items) |entry| {
        const root = find_root(&parent, entry.conn_node_id);
        if (!cluster_to_busbar_section.contains(root)) {
            cluster_to_busbar_section.putAssumeCapacity(root, entry.mrid);
        }
    }

    try topology.conn_node_reachable_busbar_section.ensureTotalCapacity(gpa, @intCast(conn_nodes.len));

    for (conn_nodes) |conn_node| {
        const root = find_root(&parent, conn_node.id);
        const busbar_section_mrid = cluster_to_busbar_section.get(root) orelse continue;
        topology.conn_node_reachable_busbar_section.putAssumeCapacity(conn_node.id, busbar_section_mrid);
    }

    assert(topology.conn_node_reachable_busbar_section.count() <= conn_nodes.len);
}

/// Result of build_node_map. Bundles the node map with auxiliary maps consumed by
/// later passes (convert_fictitious_switches, populate_internal_connections).
pub const NodeMapResult = struct {
    node_map: NodeMap,
    /// Set of ConnectivityNode IDs that have at least one switch terminal attached.
    /// Built as a side effect of Phase 1 (switch terminal iteration).
    conn_node_has_switch: SetMap,
    /// Count of non-BusbarSection / non-switch terminals per ConnectivityNode,
    /// restricted to phase2_equipment_types that have a valid VL container.
    /// Built as a side effect of Phase 2 (equipment terminal iteration).
    conn_node_other_count: CountMap,
    /// CN raw ID → CN's base node within its representative VoltageLevel.
    /// Needed by populate_internal_connections to detect which Phase 2 terminals
    /// landed on the CN base node (no IC) vs. a dedicated node (IC unless SSH-disconnected).
    conn_node_base_nodes: CountMap,

    pub fn deinit(self: *NodeMapResult, gpa: std.mem.Allocator) void {
        self.node_map.deinit(gpa);
        self.conn_node_has_switch.deinit(gpa);
        self.conn_node_other_count.deinit(gpa);
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

fn is_busbar_section_type(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "BusbarSection");
}

fn is_node_map_base_equipment_type(type_name: []const u8) bool {
    return is_switch_type(type_name) or is_busbar_section_type(type_name);
}

fn increment_count(counts: *CountMap, id: []const u8) void {
    const gop = counts.getOrPutAssumeCapacity(id);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
}

fn count_non_switch_non_busbar_terminals(gpa: std.mem.Allocator, model: *const EQ, index: *const CimIndex) !CountMap {
    var counts: CountMap = .empty;
    errdefer counts.deinit(gpa);
    try counts.ensureTotalCapacity(gpa, @intCast(index.terminal_conn_node.count()));

    for (model.get_objects_by_type("Terminal")) |terminal| {
        const conn_node_id = index.terminal_conn_node.get(terminal.id) orelse continue;
        const equipment_id = index.terminal_equipment.get(terminal.id) orelse continue;
        const equipment = model.getObjectById(equipment_id) orelse continue;
        if (is_node_map_base_equipment_type(equipment.type_name)) continue;
        increment_count(&counts, conn_node_id);
    }

    return counts;
}

fn assign_base_nodes(
    model: *const EQ,
    index: *const CimIndex,
    topology: *const Topology,
    voltage_levels: *const SetMap,
    conn_node_base_nodes: *CountMap,
    conn_node_repr_voltage_level: *IdMap,
    voltage_level_counters: *CountMap,
) void {
    // Base node assignment: sequential counter per representative VL, CN XML parse order.
    for (model.get_objects_by_type("ConnectivityNode")) |conn_node| {
        const container_id = index.conn_node_container.get(conn_node.id) orelse continue;
        const repr_voltage_level_id = find_root(&topology.voltage_level_merge, container_id);
        if (!voltage_levels.contains(repr_voltage_level_id)) continue;

        conn_node_repr_voltage_level.putAssumeCapacity(conn_node.id, repr_voltage_level_id);

        const voltage_level_gop = voltage_level_counters.getOrPutAssumeCapacity(repr_voltage_level_id);
        if (!voltage_level_gop.found_existing) voltage_level_gop.value_ptr.* = 0;
        const base_node = voltage_level_gop.value_ptr.*;
        voltage_level_gop.value_ptr.* += 1;
        conn_node_base_nodes.putAssumeCapacity(conn_node.id, base_node);
    }
}

fn map_busbar_section_terminals(
    model: *const EQ,
    index: *const CimIndex,
    conn_node_base_nodes: *const CountMap,
    node_map: *NodeMap,
) void {
    for (model.get_objects_by_type("BusbarSection")) |busbar_section| {
        const terminals = index.equipment_terminals.get(busbar_section.id) orelse continue;
        for (terminals.items) |terminal| {
            const base_node = conn_node_base_nodes.get(terminal.conn_node_id orelse continue) orelse continue;
            node_map.putAssumeCapacity(terminal.id, base_node);
        }
    }
}

fn map_switch_terminals(
    model: *const EQ,
    index: *const CimIndex,
    conn_node_base_nodes: *const CountMap,
    node_map: *NodeMap,
    conn_node_has_switch: *SetMap,
) void {
    for (switch_types) |switch_type| {
        for (model.get_objects_by_type(switch_type)) |@"switch"| {
            const terminals = index.equipment_terminals.get(@"switch".id) orelse continue;
            for (terminals.items) |terminal| {
                const conn_node_id = terminal.conn_node_id orelse continue;
                const base_node = conn_node_base_nodes.get(conn_node_id) orelse continue;
                node_map.putAssumeCapacity(terminal.id, base_node);
                conn_node_has_switch.putAssumeCapacity(conn_node_id, {});
            }
        }
    }
}

fn seed_conn_nodes_with_many_terminals(total_other_count: *const CountMap, conn_node_first_seen: *SetMap) void {
    var it = total_other_count.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* >= 3) {
            conn_node_first_seen.putAssumeCapacity(entry.key_ptr.*, {});
        }
    }
}

fn map_phase2_equipment_terminals(
    model: *const EQ,
    index: *const CimIndex,
    ssh_opt: ?SSH,
    conn_node_base_nodes: *const CountMap,
    conn_node_repr_voltage_level: *const IdMap,
    voltage_level_counters: *CountMap,
    node_map: *NodeMap,
    conn_node_other_count: *CountMap,
    conn_node_first_seen: *SetMap,
) void {
    // Phase 2: per-equipment-type iteration in PyPowSyBl's order. Within each
    // equipment, terminals are already sorted by ascending sequence number.
    for (phase2_equipment_types) |equipment_type| {
        for (model.get_objects_by_type(equipment_type)) |equip| {
            const terminals = index.equipment_terminals.get(equip.id) orelse continue;
            for (terminals.items) |terminal| {
                const conn_node_id = terminal.conn_node_id orelse continue;
                const base_node = conn_node_base_nodes.get(conn_node_id) orelse continue;
                increment_count(conn_node_other_count, conn_node_id);

                const repr_voltage_level_id = conn_node_repr_voltage_level.get(conn_node_id) orelse continue;
                const voltage_level_ctr = voltage_level_counters.getPtr(repr_voltage_level_id) orelse continue;
                const has_busbar_section = index.conn_node_to_busbar_section.contains(conn_node_id);
                // SSH-disconnected on first visit must not claim the CN base — an
                // SSH-connected co-terminal needs that slot. Always allocate dedicated.
                const ssh_disconnected = is_ssh_terminal_disconnected(ssh_opt, terminal.id);

                if (has_busbar_section or conn_node_first_seen.contains(conn_node_id) or ssh_disconnected) {
                    const terminal_node = voltage_level_ctr.*;
                    voltage_level_ctr.* += 1;
                    node_map.putAssumeCapacity(terminal.id, terminal_node);
                } else {
                    node_map.putAssumeCapacity(terminal.id, base_node);
                    conn_node_first_seen.putAssumeCapacity(conn_node_id, {});
                }
            }
        }
    }
}

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
    model: *const EQ,
    index: *const CimIndex,
    topology: *const Topology,
    voltage_levels: *const SetMap,
    ssh_opt: ?SSH,
) !NodeMapResult {
    assert(index.conn_node_container.count() > 0);

    // Counts non-BBS, non-switch terminals per CN. Used only to pre-seed
    // conn_node_first_seen for CNs with 3+ Phase 2 terminals.
    var conn_node_total_other_count = try count_non_switch_non_busbar_terminals(gpa, model, index);
    defer conn_node_total_other_count.deinit(gpa);

    var conn_node_base_nodes: CountMap = .empty;
    errdefer conn_node_base_nodes.deinit(gpa);
    try conn_node_base_nodes.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    var conn_node_repr_voltage_level: IdMap = .empty;
    defer conn_node_repr_voltage_level.deinit(gpa);
    try conn_node_repr_voltage_level.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    var voltage_level_counters: CountMap = .empty;
    defer voltage_level_counters.deinit(gpa);
    try voltage_level_counters.ensureTotalCapacity(gpa, @intCast(voltage_levels.count()));

    assign_base_nodes(
        model,
        index,
        topology,
        voltage_levels,
        &conn_node_base_nodes,
        &conn_node_repr_voltage_level,
        &voltage_level_counters,
    );

    var conn_node_has_switch: SetMap = .empty;
    errdefer conn_node_has_switch.deinit(gpa);
    try conn_node_has_switch.ensureTotalCapacity(gpa, @intCast(index.terminal_conn_node.count()));

    var conn_node_other_count: CountMap = .empty;
    errdefer conn_node_other_count.deinit(gpa);
    try conn_node_other_count.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    var node_map: NodeMap = .empty;
    errdefer node_map.deinit(gpa);
    try node_map.ensureTotalCapacity(gpa, @intCast(index.terminal_conn_node.count()));

    // Phase 1: BusbarSection and switch terminals → CN base node.
    map_busbar_section_terminals(model, index, &conn_node_base_nodes, &node_map);
    map_switch_terminals(model, index, &conn_node_base_nodes, &node_map, &conn_node_has_switch);

    // CNs with 3+ Phase 2 terminals are pre-seeded as "already seen" so ALL their
    // Phase 2 terminals get dedicated nodes — matches PyPowSyBl's behaviour.
    var conn_node_first_seen: SetMap = .empty;
    defer conn_node_first_seen.deinit(gpa);
    try conn_node_first_seen.ensureTotalCapacity(gpa, @intCast(index.conn_node_container.count()));

    seed_conn_nodes_with_many_terminals(&conn_node_total_other_count, &conn_node_first_seen);
    map_phase2_equipment_terminals(
        model,
        index,
        ssh_opt,
        &conn_node_base_nodes,
        &conn_node_repr_voltage_level,
        &voltage_level_counters,
        &node_map,
        &conn_node_other_count,
        &conn_node_first_seen,
    );

    assert(node_map.count() <= index.terminal_conn_node.count());

    return .{
        .node_map = node_map,
        .conn_node_has_switch = conn_node_has_switch,
        .conn_node_other_count = conn_node_other_count,
        .conn_node_base_nodes = conn_node_base_nodes,
    };
}

/// Returns true if the terminal is marked as disconnected in SSH
/// (ACDCTerminal.connected = "false"). The terminal raw rdf:ID is used
/// to look up the SSH patch; strip_underscore converts it to the mRID key.
pub fn is_ssh_terminal_disconnected(ssh_opt: ?SSH, terminal_id: []const u8) bool {
    assert(terminal_id.len > 0);
    const ssh = ssh_opt orelse return false;
    const mrid = strip_underscore(terminal_id);
    const connected = ssh.getProperty(mrid, "ACDCTerminal.connected") catch return false;
    const val = connected orelse return false;
    return std.mem.eql(u8, val, "false");
}

pub fn is_switch_closed(ssh: *const SSH, switch_id: []const u8) !bool {
    assert(switch_id.len > 0);
    // SSH patches are keyed by mRID; switch_id is the raw rdf:ID with leading underscore.
    const mrid = strip_underscore(switch_id);
    const patch = ssh.find_patch(mrid) orelse return true;
    const open_str = try ssh.getPropertyFromPatch(patch, "Switch.open") orelse "false";
    return std.mem.eql(u8, open_str, "false");
}

fn union_closed_switch_conn_nodes(
    model: *const EQ,
    index: *const CimIndex,
    ssh_opt: ?*const SSH,
    parent: *IdMap,
) !void {
    for (switch_types) |switch_type| {
        for (model.get_objects_by_type(switch_type)) |@"switch"| {
            const terminals = index.equipment_terminals.get(@"switch".id) orelse continue;
            if (terminals.items.len != 2) continue;

            const conn_node0 = index.terminal_conn_node.get(terminals.items[0].id) orelse continue;
            const conn_node1 = index.terminal_conn_node.get(terminals.items[1].id) orelse continue;
            // A CN may be absent from `parent` if the EQ references a CN object that doesn't
            // exist (malformed input, or partial profile). Skip rather than insert a phantom root.
            if (!parent.contains(conn_node0)) continue;
            if (!parent.contains(conn_node1)) continue;

            // Retained closed switches become SwitchBranches in the IIDM bus-branch view —
            // each end stays its own TopologicalNode, so do not union across them.
            const retained_str = try model.view(@"switch").getProperty("Switch.retained") orelse "false";
            if (std.mem.eql(u8, retained_str, "true")) continue;

            // default behavior is closed.
            const closed = if (ssh_opt) |s| try is_switch_closed(s, @"switch".id) else true;
            if (!closed) continue;

            union_smallest_id_wins(parent, conn_node0, conn_node1);
        }
    }
}

fn get_base_voltage_mrid(model: *const EQ, voltage_level: CimObjectView) ![]const u8 {
    const base_voltage_ref = try voltage_level.getReference("VoltageLevel.BaseVoltage") orelse "";
    if (base_voltage_ref.len == 0) return "";

    const base_voltage_id = strip_hash(base_voltage_ref);
    const base_voltage = model.getObjectById(base_voltage_id) orelse return "";
    // TODO prefix a hash.
    return try base_voltage.getProperty("IdentifiedObject.mRID") orelse strip_underscore(base_voltage_id);
}

fn append_topological_node(
    model: *const EQ,
    index: *const CimIndex,
    topology: *const Topology,
    conn_node_id: []const u8,
    nodes: *std.ArrayListUnmanaged(TopologicalNode),
) !void {
    const conn_node = model.getObjectById(conn_node_id) orelse return;

    // Boundary CNs (container = ACLineSegment) have no VL — skip for now.
    const container_id = index.conn_node_container.get(conn_node.id) orelse return;
    const repr_voltage_level_id = find_root(&topology.voltage_level_merge, container_id);
    const voltage_level = model.getObjectById(repr_voltage_level_id) orelse return;
    // Check if container was indeed VoltageLevel.
    if (!std.mem.eql(u8, voltage_level.type_name, "VoltageLevel")) return;

    const mrid = try conn_node.getProperty("IdentifiedObject.mRID") orelse strip_underscore(conn_node.id);
    const name = try conn_node.getProperty("IdentifiedObject.name") orelse "";
    const base_voltage_mrid = try get_base_voltage_mrid(model, voltage_level);
    const voltage_level_mrid = try voltage_level.getProperty("IdentifiedObject.mRID") orelse
        strip_underscore(repr_voltage_level_id);

    nodes.appendAssumeCapacity(.{
        .mrid = mrid,
        .name = name,
        .base_voltage = base_voltage_mrid,
        .conn_node_container = voltage_level_mrid,
    });
}

/// Build TopologicalNodes: connected components of ConnectivityNodes joined by
/// *closed* switches (SSH-aware). Each component becomes one TN, identified by
/// the smallest CN mRID in the component (PyPowSyBl tie-breaking).
///
/// Boundary CNs (container = ACLineSegment, not VoltageLevel) are skipped here
/// — TP emission for boundary nodes is a separate concern.
pub fn build_topological_nodes(
    gpa: std.mem.Allocator,
    model: *const EQ,
    index: *const CimIndex,
    topology: *const Topology,
    ssh_opt: ?*const SSH,
) !std.ArrayListUnmanaged(TopologicalNode) {
    assert(index.conn_node_container.count() > 0);
    var conn_node_to_root = try build_conn_node_root_map(gpa, model, index, ssh_opt);
    defer conn_node_to_root.deinit(gpa);

    // With smallest-id-wins union, each root IS the representative CN.
    // After unions, a CN is a root iff conn_node_to_root[id] == id (self-loop).
    var nodes: std.ArrayListUnmanaged(TopologicalNode) = .empty;
    errdefer nodes.deinit(gpa);
    try nodes.ensureTotalCapacity(gpa, conn_node_to_root.size);

    var it = conn_node_to_root.iterator();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, entry.value_ptr.*)) continue;
        try append_topological_node(model, index, topology, entry.key_ptr.*, &nodes);
    }

    assert(nodes.items.len <= conn_node_to_root.size);
    return nodes;
}

pub fn build_conn_node_root_map(gpa: std.mem.Allocator, model: *const EQ, index: *const CimIndex, ssh_opt: ?*const SSH) !IdMap {
    const conn_nodes = model.get_objects_by_type("ConnectivityNode");

    // Union-find: each CN starts as its own root.
    var conn_node_to_root: IdMap = .empty;
    errdefer conn_node_to_root.deinit(gpa);
    try conn_node_to_root.ensureTotalCapacity(gpa, @intCast(conn_nodes.len));

    for (conn_nodes) |conn_node| conn_node_to_root.putAssumeCapacity(conn_node.id, conn_node.id);

    try union_closed_switch_conn_nodes(model, index, ssh_opt, &conn_node_to_root);

    // Path compression: every value is now the true root, so callers can read
    // value_ptr.* directly instead of walking parent chains.
    var it = conn_node_to_root.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.* = find_root(&conn_node_to_root, entry.key_ptr.*);
    }

    return conn_node_to_root;
}
