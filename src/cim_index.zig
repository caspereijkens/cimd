const std = @import("std");
const iidm = @import("iidm.zig");
const tag_index = @import("tag_index.zig");
const utils = @import("utils.zig");
const cim_model = @import("cim_model.zig");

const assert = std.debug.assert;

const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

const switch_types = [_][]const u8{ "Breaker", "Disconnector", "LoadBreakSwitch" };

pub const CimObject = tag_index.CimObject;
const CimModel = cim_model.CimModel;

pub const TerminalInfo = struct {
    id: []const u8,
    conn_node_id: ?[]const u8, // null if terminal has no ConnectivityNode.
    sequence: u32,
};

pub const LimitTypeInfo = struct {
    is_infinite: bool, // true -> PATL, false -> TATL.
    acceptable_duration: ?[]const u8, // only meaningful when not infinite.
};

pub const VoltageLimitInfo = struct {
    high_value: ?f64,
    low_value: ?f64,
};

pub const BusbarSectionEntry = struct {
    conn_node_id: []const u8,
    mrid: []const u8,
};

pub const CimIndex = struct {
    // Terminal lookups (one entry per Terminal)
    terminal_equipment: std.StringHashMapUnmanaged([]const u8),
    terminal_conn_node: std.StringHashMapUnmanaged([]const u8),
    terminal_sequence: std.StringHashMapUnmanaged(u32),

    // Equipment → its terminals, in sequence order (one list per equipment)
    equipment_terminals: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(TerminalInfo)),

    // ConnectivityNode → container ID (VoltageLevel or ACLineSegment raw ID)
    conn_node_container: std.StringHashMapUnmanaged([]const u8),

    // ConnectivityNode → BusbarSection mRID (only populated for ConnectivityNodes that have a BusbarSection directly attached)
    conn_node_to_busbar_section: std.StringHashMapUnmanaged([]const u8),

    // ConnectivityNode → nearest BusbarSection mRID reachable via switches (pre-computed BFS, covers all switch-adjacent ConnectivityNodes)
    conn_node_reachable_busbar_section: std.StringHashMapUnmanaged([]const u8),

    // BusbarSection entries in ConnectivityNode XML parse order (used during BFS pre-computation)
    busbar_section_in_parse_order: std.ArrayListUnmanaged(BusbarSectionEntry),

    // VoltageLevel merge: stub VoltageLevel raw ID → representative VoltageLevel raw ID
    voltage_level_merge: std.StringHashMapUnmanaged([]const u8),

    // Substation merge: representative sub raw ID → list of merged-in sub raw IDs
    substation_merge: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),

    // Operational limit types: type raw ID → info
    limit_types: std.StringHashMapUnmanaged(LimitTypeInfo),

    // Terminal ID → list of OperationalLimitSet objects at that terminal
    terminal_limit_sets: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObject)),

    // Limit set mRID → list of CurrentLimit objects in that set
    current_limits_by_set: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObject)),

    // VoltageLevel raw ID → voltage limits
    voltage_level_limits: std.StringHashMapUnmanaged(VoltageLimitInfo),

    // Reactive capability curve raw ID → list of curve points
    curve_points: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(iidm.ReactiveCapabilityCurvePoint)),

    // BaseVoltage mRIDs from the EQBD boundary file
    boundary_base_voltage_ids: std.StringHashMapUnmanaged(void),


    pub fn build(
        gpa: std.mem.Allocator,
        model: *const CimModel,
        boundary_base_voltage_ids: std.StringHashMapUnmanaged(void),
    ) !CimIndex {
        var index = create_empty_cim_index();
        errdefer index.deinit(gpa);

        try build_limit_types(gpa, model, &index);
        try build_terminals(gpa, model, &index);
        try build_connectivity(gpa, model, &index);
        try build_operational_limits(gpa, model, &index);

        try build_curve_points(gpa, model, &index);
        try build_voltage_level_merge(gpa, model, &index);
        try build_substation_merge(gpa, model, &index);
        try build_branch_first_search_pre_computation(gpa, model, &index);
        try build_voltage_limits(gpa, model, &index);
        index.boundary_base_voltage_ids = boundary_base_voltage_ids;
        return index;
    }

    pub fn deinit(self: *CimIndex, gpa: std.mem.Allocator) void {
        self.terminal_equipment.deinit(gpa);
        self.terminal_conn_node.deinit(gpa);
        self.terminal_sequence.deinit(gpa);

        {
            var it = self.equipment_terminals.valueIterator();
            while (it.next()) |list| {
                list.deinit(gpa);
            }
            self.equipment_terminals.deinit(gpa);
        }

        self.conn_node_container.deinit(gpa);
        self.conn_node_to_busbar_section.deinit(gpa);
        self.conn_node_reachable_busbar_section.deinit(gpa);
        self.busbar_section_in_parse_order.deinit(gpa);
        self.voltage_level_merge.deinit(gpa);

        {
            var it = self.substation_merge.valueIterator();
            while (it.next()) |list| {
                list.deinit(gpa);
            }
            self.substation_merge.deinit(gpa);
        }

        self.limit_types.deinit(gpa);

        {
            var it = self.terminal_limit_sets.valueIterator();
            while (it.next()) |list| {
                list.deinit(gpa);
            }
            self.terminal_limit_sets.deinit(gpa);
        }

        {
            var it = self.current_limits_by_set.valueIterator();
            while (it.next()) |list| {
                list.deinit(gpa);
            }
            self.current_limits_by_set.deinit(gpa);
        }

        self.voltage_level_limits.deinit(gpa);

        {
            var it = self.curve_points.valueIterator();
            while (it.next()) |list| {
                list.deinit(gpa);
            }
            self.curve_points.deinit(gpa);
        }

        self.boundary_base_voltage_ids.deinit(gpa);
    }
};

fn create_empty_cim_index() CimIndex {
    return CimIndex{
        .terminal_equipment = .empty,
        .terminal_conn_node = .empty,
        .terminal_sequence = .empty,
        .equipment_terminals = .empty,
        .conn_node_container = .empty,
        .conn_node_to_busbar_section = .empty,
        .conn_node_reachable_busbar_section = .empty,
        .busbar_section_in_parse_order = .empty,
        .voltage_level_merge = .empty,
        .substation_merge = .empty,
        .limit_types = .empty,
        .terminal_limit_sets = .empty,
        .current_limits_by_set = .empty,
        .voltage_level_limits = .empty,
        .curve_points = .empty,
        .boundary_base_voltage_ids = .empty,
    };
}

fn build_limit_types(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.limit_types.count() == 0);
    const objects = model.getObjectsByType("OperationalLimitType");
    try index.limit_types.ensureTotalCapacity(gpa, @intCast(objects.len));
    for (objects) |obj| {
        const is_inf = try obj.getProperty("OperationalLimitType.isInfiniteDuration") orelse "false";
        const duration = try obj.getProperty("OperationalLimitType.acceptableDuration");
        index.limit_types.putAssumeCapacity(obj.id, .{
            .is_infinite = std.mem.eql(u8, is_inf, "true"),
            .acceptable_duration = duration,
        });
    }
    assert(index.limit_types.count() == objects.len);
}

fn build_terminals(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.terminal_equipment.count() == 0);

    const objects = model.getObjectsByType("Terminal");

    try index.terminal_equipment.ensureTotalCapacity(gpa, @intCast(objects.len));
    try index.terminal_conn_node.ensureTotalCapacity(gpa, @intCast(objects.len));
    try index.terminal_sequence.ensureTotalCapacity(gpa, @intCast(objects.len));
    try index.equipment_terminals.ensureTotalCapacity(gpa, @intCast(objects.len));

    for (objects) |obj| {
        const conn_node_ref = try obj.getReference("Terminal.ConnectivityNode");
        const conn_node_id: ?[]const u8 = if (conn_node_ref) |ref| strip_hash(ref) else null;
        if (conn_node_id) |id| {
            index.terminal_conn_node.putAssumeCapacity(obj.id, id);
        }

        const sequence_str = try obj.getProperty("ACDCTerminal.sequenceNumber") orelse "1";
        const sequence = try std.fmt.parseInt(u32, sequence_str, 10);
        index.terminal_sequence.putAssumeCapacity(obj.id, sequence);

        const equipment_ref = try obj.getReference("Terminal.ConductingEquipment") orelse return error.MalFormedXML;
        const equipment_id = strip_hash(equipment_ref);
        assert(equipment_id.len > 0);
        index.terminal_equipment.putAssumeCapacity(obj.id, equipment_id);
        const gop = index.equipment_terminals.getOrPutAssumeCapacity(equipment_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(gpa, .{
            .id = obj.id,
            .conn_node_id = conn_node_id,
            .sequence = sequence,
        });
    }

    // Sort each equipment's terminal list by sequenceNumber so that items[0] = seq 1,
    // items[1] = seq 2, etc. Terminals arrive in XML parse order which can be reversed.
    // Single-terminal equipment (loads, generators, shunts) is skipped — no-op sort.
    var sort_it = index.equipment_terminals.valueIterator();
    while (sort_it.next()) |list| {
        if (list.items.len > 1) std.mem.sort(TerminalInfo, list.items, {}, struct {
            fn lt(_: void, a: TerminalInfo, b: TerminalInfo) bool {
                return a.sequence < b.sequence;
            }
        }.lt);
    }

    assert(index.terminal_equipment.count() == objects.len);
    assert(index.terminal_sequence.count() == objects.len);
    assert(index.terminal_conn_node.count() <= objects.len);
}

fn build_connectivity(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.terminal_equipment.count() > 0);
    assert(index.conn_node_container.count() == 0);
    assert(index.busbar_section_in_parse_order.items.len == 0);

    const busbar_sections = model.getObjectsByType("BusbarSection");
    try index.conn_node_to_busbar_section.ensureTotalCapacity(gpa, @intCast(busbar_sections.len));

    for (busbar_sections) |busbar_section| {
        const terminals = index.equipment_terminals.get(busbar_section.id) orelse continue;
        if (terminals.items.len != 1) {
            // TODO add log message
            continue;
        }
        const conn_node_id = index.terminal_conn_node.get(terminals.items[0].id) orelse continue;

        const busbar_section_mrid = try busbar_section.getProperty("IdentifiedObject.mRID") orelse strip_underscore(busbar_section.id);
        index.conn_node_to_busbar_section.putAssumeCapacity(conn_node_id, busbar_section_mrid);
    }

    const conn_nodes = model.getObjectsByType("ConnectivityNode");

    try index.conn_node_container.ensureTotalCapacity(gpa, @intCast(conn_nodes.len));
    try index.busbar_section_in_parse_order.ensureTotalCapacity(gpa, busbar_sections.len);

    for (conn_nodes) |conn_node| {
        const container_ref = try conn_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
        var container_id = strip_hash(container_ref);
        // Bay is not a valid equipment-placement container — resolve to the parent VoltageLevel.
        if (model.getObjectById(container_id)) |container_obj| {
            if (std.mem.eql(u8, container_obj.type_name, "Bay")) {
                if (try container_obj.getReference("Bay.VoltageLevel")) |voltage_level_ref| {
                    container_id = strip_hash(voltage_level_ref);
                }
            }
        }
        index.conn_node_container.putAssumeCapacity(conn_node.id, container_id);

        const busbar_section_id = index.conn_node_to_busbar_section.get(conn_node.id) orelse continue;
        index.busbar_section_in_parse_order.appendAssumeCapacity(.{
            .conn_node_id = conn_node.id,
            .mrid = busbar_section_id,
        });
    }

    assert(index.conn_node_container.count() == conn_nodes.len);
    assert(index.busbar_section_in_parse_order.items.len <= busbar_sections.len);
}

fn build_operational_limits(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.terminal_limit_sets.count() == 0);
    assert(index.current_limits_by_set.count() == 0);

    const op_lim_sets = model.getObjectsByType("OperationalLimitSet");
    try index.terminal_limit_sets.ensureTotalCapacity(gpa, @intCast(op_lim_sets.len));

    for (op_lim_sets) |op_lim_set| {
        const terminal_ref = try op_lim_set.getReference("OperationalLimitSet.Terminal") orelse continue;
        const terminal_id = strip_hash(terminal_ref);
        const gop = index.terminal_limit_sets.getOrPutAssumeCapacity(terminal_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(gpa, op_lim_set);
    }

    const current_lims = model.getObjectsByType("CurrentLimit");
    try index.current_limits_by_set.ensureTotalCapacity(gpa, @intCast(current_lims.len));

    for (current_lims) |current_lim| {
        const op_lim_set_ref = try current_lim.getReference("OperationalLimit.OperationalLimitSet") orelse continue;
        const op_lim_set_id = strip_hash(op_lim_set_ref);
        const gop = index.current_limits_by_set.getOrPutAssumeCapacity(op_lim_set_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(gpa, current_lim);
    }

    assert(index.terminal_limit_sets.count() <= op_lim_sets.len);
    assert(index.current_limits_by_set.count() <= current_lims.len);
}

fn build_curve_points(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.curve_points.count() == 0);
    const curve_datas = model.getObjectsByType("CurveData");
    try index.curve_points.ensureTotalCapacity(gpa, @intCast(curve_datas.len));

    for (curve_datas) |curve_data| {
        const curve_ref = try curve_data.getReference("CurveData.Curve") orelse return error.MalformedXML;
        const curve_id = strip_hash(curve_ref);

        const x_val = try curve_data.getProperty("CurveData.xvalue") orelse "0.0";
        const y1_val = try curve_data.getProperty("CurveData.y1value") orelse "0.0";
        const y2_val = try curve_data.getProperty("CurveData.y2value") orelse "0.0";

        const x = try std.fmt.parseFloat(f64, x_val);
        const y1 = try std.fmt.parseFloat(f64, y1_val);
        const y2 = try std.fmt.parseFloat(f64, y2_val);

        const gop = index.curve_points.getOrPutAssumeCapacity(curve_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(gpa, .{
            .p = x,
            .min_q = y1,
            .max_q = y2,
        });
    }
    assert(curve_datas.len == 0 or index.curve_points.count() > 0);
}

pub fn find_voltage_level(parent: *const std.StringHashMapUnmanaged([]const u8), id: []const u8) []const u8 {
    var current = id;
    while (true) {
        const p = parent.get(current) orelse return current;
        current = p;
    }
}

test "find_voltage_level: id not in map returns itself" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("unknown", find_voltage_level(&parent, "unknown"));
}

test "find_voltage_level: one level deep" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.put(std.testing.allocator, "stub", "rep");

    try std.testing.expectEqualStrings("rep", find_voltage_level(&parent, "stub"));
    try std.testing.expectEqualStrings("rep", find_voltage_level(&parent, "rep"));
}

test "find_voltage_level: two levels deep" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.put(std.testing.allocator, "a", "b");
    try parent.put(std.testing.allocator, "b", "c");

    try std.testing.expectEqualStrings("c", find_voltage_level(&parent, "a"));
    try std.testing.expectEqualStrings("c", find_voltage_level(&parent, "b"));
    try std.testing.expectEqualStrings("c", find_voltage_level(&parent, "c"));
}

test "find_voltage_level: chain of four" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.put(std.testing.allocator, "a", "b");
    try parent.put(std.testing.allocator, "b", "c");
    try parent.put(std.testing.allocator, "c", "d");

    try std.testing.expectEqualStrings("d", find_voltage_level(&parent, "a"));
    try std.testing.expectEqualStrings("d", find_voltage_level(&parent, "b"));
    try std.testing.expectEqualStrings("d", find_voltage_level(&parent, "c"));
    try std.testing.expectEqualStrings("d", find_voltage_level(&parent, "d"));
}

test "find_voltage_level: two independent components" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.put(std.testing.allocator, "a", "b");
    try parent.put(std.testing.allocator, "x", "y");

    try std.testing.expectEqualStrings("b", find_voltage_level(&parent, "a"));
    try std.testing.expectEqualStrings("y", find_voltage_level(&parent, "x"));
}

fn union_voltage_levels(
    model: *const cim_model.CimModel,
    parent: *std.StringHashMapUnmanaged([]const u8),
    id_a: []const u8,
    id_b: []const u8,
) !void {
    const root_a = find_voltage_level(parent, id_a);
    const root_b = find_voltage_level(parent, id_b);
    if (std.mem.eql(u8, root_a, root_b)) return;

    const voltage_level_a = model.getObjectById(root_a) orelse return;
    const voltage_level_b = model.getObjectById(root_b) orelse return;
    const mrid_a = try voltage_level_a.getProperty("IdentifiedObject.mRID") orelse
        strip_underscore(root_a);
    const mrid_b = try voltage_level_b.getProperty("IdentifiedObject.mRID") orelse
        strip_underscore(root_b);

    // stub points to representative; representative has the smaller mRID
    if (std.mem.lessThan(u8, mrid_a, mrid_b)) {
        parent.putAssumeCapacity(root_b, root_a);
    } else {
        parent.putAssumeCapacity(root_a, root_b);
    }
}

fn union_conn_nodes(
    parent: *std.StringHashMapUnmanaged([]const u8),
    conn_node0: []const u8,
    conn_node1: []const u8,
) void {
    const root0 = find_voltage_level(parent, conn_node0);
    const root1 = find_voltage_level(parent, conn_node1);
    if (std.mem.eql(u8, root0, root1)) return;
    parent.putAssumeCapacity(root0, root1);
}

test "union_conn_nodes: two nodes share root after union" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 1);

    union_conn_nodes(&parent, "conn_node1", "conn_node2");

    try std.testing.expectEqualStrings(
        find_voltage_level(&parent, "conn_node1"),
        find_voltage_level(&parent, "conn_node2"),
    );
}

test "union_conn_nodes: idempotent when already same component" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 2);

    union_conn_nodes(&parent, "conn_node1", "conn_node2");
    const count = parent.count();
    union_conn_nodes(&parent, "conn_node1", "conn_node2");

    try std.testing.expectEqual(count, parent.count());
}

test "union_conn_nodes: transitive — three nodes share root" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 2);

    union_conn_nodes(&parent, "a", "b");
    union_conn_nodes(&parent, "b", "c");

    const root_a = find_voltage_level(&parent, "a");
    const root_b = find_voltage_level(&parent, "b");
    const root_c = find_voltage_level(&parent, "c");
    try std.testing.expectEqualStrings(root_a, root_b);
    try std.testing.expectEqualStrings(root_b, root_c);
}

test "union_conn_nodes: independent clusters do not interfere" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 2);

    union_conn_nodes(&parent, "a", "b");
    union_conn_nodes(&parent, "x", "y");

    const root_ab = find_voltage_level(&parent, "a");
    const root_xy = find_voltage_level(&parent, "x");
    try std.testing.expectEqualStrings(root_ab, find_voltage_level(&parent, "b"));
    try std.testing.expectEqualStrings(root_xy, find_voltage_level(&parent, "y"));
    try std.testing.expect(!std.mem.eql(u8, root_ab, root_xy));
}

pub fn get_switch_slices(model: *const CimModel) [switch_types.len][]const CimObject {
    var slices: [switch_types.len][]const CimObject = undefined;
    for (switch_types, 0..) |t, i| slices[i] = model.getObjectsByType(t);
    return slices;
}

fn get_switch_count(slices: [switch_types.len][]const CimObject) usize {
    var count: usize = 0;
    for (slices) |s| count += s.len;
    return count;
}

test "get_switch_count: all empty slices returns zero" {
    const slices = [switch_types.len][]const CimObject{ &.{}, &.{}, &.{} };
    try std.testing.expectEqual(@as(usize, 0), get_switch_count(slices));
}

test "get_switch_count: one non-empty slice" {
    var objs: [3]CimObject = undefined;
    const slices = [switch_types.len][]const CimObject{ &objs, &.{}, &.{} };
    try std.testing.expectEqual(@as(usize, 3), get_switch_count(slices));
}

test "get_switch_count: all non-empty slices summed" {
    var a: [2]CimObject = undefined;
    var b: [5]CimObject = undefined;
    var c: [1]CimObject = undefined;
    const slices = [switch_types.len][]const CimObject{ &a, &b, &c };
    try std.testing.expectEqual(@as(usize, 8), get_switch_count(slices));
}

test "get_switch_count: mixed empty and non-empty" {
    var objs: [4]CimObject = undefined;
    const slices = [switch_types.len][]const CimObject{ &.{}, &objs, &.{} };
    try std.testing.expectEqual(@as(usize, 4), get_switch_count(slices));
}

fn process_switch_type(
    model: *const cim_model.CimModel,
    index: *const CimIndex,
    switches: []const CimObject,
    parent: *std.StringHashMapUnmanaged([]const u8),
) !void {
    for (switches) |sw| {
        const terminals = index.equipment_terminals.get(sw.id) orelse continue;
        if (terminals.items.len != 2) continue;

        const conn_node0 = index.terminal_conn_node.get(terminals.items[0].id) orelse continue;
        const conn_node1 = index.terminal_conn_node.get(terminals.items[1].id) orelse continue;

        const container0 = index.conn_node_container.get(conn_node0) orelse continue;
        const container1 = index.conn_node_container.get(conn_node1) orelse continue;
        if (std.mem.eql(u8, container0, container1)) continue;

        const obj0 = model.getObjectById(container0) orelse continue;
        const obj1 = model.getObjectById(container1) orelse continue;
        if (!std.mem.eql(u8, obj0.type_name, "VoltageLevel")) continue;
        if (!std.mem.eql(u8, obj1.type_name, "VoltageLevel")) continue;

        try union_voltage_levels(model, parent, container0, container1);
    }
}

fn build_voltage_level_merge(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.voltage_level_merge.count() == 0);

    const voltage_levels = model.getObjectsByType("VoltageLevel");
    const switch_slices = get_switch_slices(model);

    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    try parent.ensureTotalCapacity(gpa, @intCast(get_switch_count(switch_slices)));
    defer parent.deinit(gpa);

    for (switch_slices) |slice| try process_switch_type(model, index, slice, &parent);

    // flatten: stubs → representatives
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

/// Union-Find path compression (iterative).
fn find(parent: *const std.StringHashMapUnmanaged([]const u8), x: []const u8) []const u8 {
    var cur = x;
    while (true) {
        const p = parent.get(cur) orelse return cur;
        if (std.mem.eql(u8, p, cur)) return cur;
        cur = p;
    }
}

/// Union two substation raw IDs. The one with the smaller stripped mRID becomes the root.
fn union_substations(
    gpa: std.mem.Allocator,
    parent: *std.StringHashMapUnmanaged([]const u8),
    substation_a_id: []const u8,
    substation_b_id: []const u8,
) !void {
    const root_a = find(parent, substation_a_id);
    const root_b = find(parent, substation_b_id);
    if (std.mem.eql(u8, root_a, root_b)) return;
    // Keep the substation with the smaller mRID as the root (representative).
    if (std.mem.lessThan(u8, strip_underscore(root_a), strip_underscore(root_b))) {
        try parent.put(gpa, root_b, root_a);
    } else {
        try parent.put(gpa, root_a, root_b);
    }
}

/// Helper: given a ConnectivityNode ID, return its VoltageLevel object (or null).
fn conn_node_to_voltage_level(model: *const cim_model.CimModel, index: *const CimIndex, conn_node_id: []const u8) ?*const cim_model.CimObject {
    const container_id = index.conn_node_container.get(conn_node_id) orelse return null;
    const obj = model.getObjectById(container_id) orelse return null;
    if (!std.mem.eql(u8, obj.type_name, "VoltageLevel")) return null;
    return obj;
}

/// Build substation_merge using Union-Find over substations.
/// Substations are merged when connected by:
///   1. Cross-substation switches (detected via voltage_level_merge_map).
///   2. Cross-substation PowerTransformers (ends in different substations).
/// The representative substation has the lexicographically smallest mRID.
fn build_substation_merge(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.substation_merge.count() == 0);
    assert(index.conn_node_container.count() > 0);

    const substations = model.getObjectsByType("Substation");

    // Initialize Union-Find: each substation is its own root.
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(gpa);
    try parent.ensureTotalCapacity(gpa, @intCast(substations.len));
    for (substations) |substation| parent.putAssumeCapacity(substation.id, substation.id);

    // 1. Union substations connected by cross-substation switches (via voltage_level_merge_map).
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

    // 2. Union substations connected by cross-substation PowerTransformers.
    for (model.getObjectsByType("PowerTransformer")) |transformer| {
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

    // Flatten Union-Find: for each non-root substation, add it to its canonical's list.
    try index.substation_merge.ensureTotalCapacity(gpa, @intCast(substations.len));
    for (substations) |substation| {
        const canonical = find(&parent, substation.id);
        if (std.mem.eql(u8, canonical, substation.id)) continue; // sub is already a root
        const gop = index.substation_merge.getOrPutAssumeCapacity(canonical);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        // Avoid duplicates (can arise from multiple VL-level connections between same two subs).
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

/// Resolving a RegulatingControl terminal requires finding the nearest BusbarSection
/// reachable from a given ConnectivityNode by traversing switches. Doing this at
/// conversion time would require a BFS heap allocation per generator — O(n) per call.
///
/// This pass eliminates that cost entirely by pre-computing the answer for every
/// switch-connected CN once, up front. The result is stored in
/// `conn_node_reachable_busbar_section`: a flat map of CN raw ID → BBS mRID.
///
/// Algorithm:
///   1. Union-find over CNs: for each switch, union its two terminal CNs into one cluster.
///   2. For each cluster, the representative BBS is the first entry in
///      `busbar_section_in_parse_order` whose CN belongs to that cluster (parse order
///      matches PyPowSyBl's tie-breaking behaviour).
///   3. Every CN in a cluster that has a BBS gets mapped to that BBS mRID.
///
/// At conversion time, resolveRegulatingTerminal becomes two O(1) map lookups:
/// first `conn_node_to_busbar_section` (direct), then `conn_node_reachable_busbar_section`
/// (via switches). No allocation, no traversal.
fn build_branch_first_search_pre_computation(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.conn_node_reachable_busbar_section.count() == 0);
    assert(index.conn_node_container.count() > 0);

    const conn_nodes = model.getObjectsByType("ConnectivityNode");
    const switch_slices = get_switch_slices(model);

    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    try parent.ensureTotalCapacity(gpa, @intCast(get_switch_count(switch_slices) * 2));
    defer parent.deinit(gpa);

    for (switch_slices) |slice| {
        for (slice) |sw| {
            const terminals = index.equipment_terminals.get(sw.id) orelse continue;
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

fn build_voltage_limits(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.voltage_level_limits.count() == 0);

    const voltage_limits = model.getObjectsByType("VoltageLimit");
    try index.voltage_level_limits.ensureTotalCapacity(gpa, @intCast(voltage_limits.len));

    for (voltage_limits) |voltage_limit| {
        const limit_set_ref = try voltage_limit.getReference("OperationalLimit.OperationalLimitSet") orelse continue;
        const limit_set = model.getObjectById(strip_hash(limit_set_ref)) orelse continue;
        const terminal_ref = try limit_set.getReference("OperationalLimitSet.Terminal") orelse continue;

        const conn_node_id = index.terminal_conn_node.get(strip_hash(terminal_ref)) orelse continue;
        const container_id = index.conn_node_container.get(conn_node_id) orelse continue;
        const container = model.getObjectById(container_id) orelse continue;

        if (!std.mem.eql(u8, container.type_name, "VoltageLevel")) continue;

        const limit_type_ref = try voltage_limit.getReference("OperationalLimit.OperationalLimitType") orelse continue;
        const limit_type = model.getObjectById(strip_hash(limit_type_ref)) orelse continue;
        const direction = try limit_type.getReference("OperationalLimitType.direction") orelse continue;

        const value_str = try voltage_limit.getProperty("VoltageLimit.normalValue") orelse continue;
        const value = try std.fmt.parseFloat(f64, value_str);

        const gop = index.voltage_level_limits.getOrPutAssumeCapacity(container_id);
        if (!gop.found_existing) gop.value_ptr.* = .{ .high_value = null, .low_value = null };

        if (std.mem.endsWith(u8, direction, "high")) {
            gop.value_ptr.high_value = value;
        } else {
            gop.value_ptr.low_value = value;
        }
    }
    assert(index.voltage_level_limits.count() <= voltage_limits.len);
}
