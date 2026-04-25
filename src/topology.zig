const std = @import("std");
const utils = @import("utils.zig");
const cim_model = @import("cim_model.zig");
const cim_index = @import("cim_index.zig");
const tag_index = @import("tag_index.zig");

const assert = std.debug.assert;

const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

const CimModel = cim_model.CimModel;
const CimIndex = cim_index.CimIndex;
const CimObjectView = tag_index.CimObjectView;
const CimObject = tag_index.CimObject;

pub const switch_types = [_][]const u8{ "Breaker", "Disconnector", "LoadBreakSwitch" };

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
