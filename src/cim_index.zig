const std = @import("std");
const iidm = @import("iidm.zig");
const tag_index = @import("tag_index.zig");
const utils = @import("utils.zig");
const cim_model = @import("cim_model.zig");
const topology_mod = @import("topology.zig");
const Topology = topology_mod.Topology;

const assert = std.debug.assert;

const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

const CimObject = tag_index.CimObject;
const CimObjectView = tag_index.CimObjectView;

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
    // Most-restrictive values (high = min, low = max) used for IIDM
    // VoltageLevel.highVoltageLimit / lowVoltageLimit.
    high_value: ?f64,
    low_value: ?f64,
    // Raw strings for the most-restrictive values, preserved so JIIDM
    // properties match the CGMES source byte-for-byte (e.g. "121.0", "11.025").
    high_value_str: ?[]const u8,
    low_value_str: ?[]const u8,
    // All VoltageLimit mRIDs contributing to this VL, in XML parse order, per side.
    // Emitted as semicolon-joined CGMES.OperationalLimit_highVoltageLimit / lowVoltageLimit properties.
    high_mrids: std.ArrayListUnmanaged([]const u8),
    low_mrids: std.ArrayListUnmanaged([]const u8),
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

    // BusbarSection entries in ConnectivityNode XML parse order (used during BFS pre-computation)
    busbar_section_in_parse_order: std.ArrayListUnmanaged(BusbarSectionEntry),

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
        index.boundary_base_voltage_ids = boundary_base_voltage_ids;
        return index;
    }

    pub fn build_for_topology(
        gpa: std.mem.Allocator,
        model: *const CimModel,
        boundary_base_voltage_ids: std.StringHashMapUnmanaged(void),
    ) !CimIndex {
        var index = create_empty_cim_index();
        errdefer index.deinit(gpa);

        try build_terminals(gpa, model, &index);
        try build_connectivity(gpa, model, &index);

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
        self.busbar_section_in_parse_order.deinit(gpa);

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

        {
            var it = self.voltage_level_limits.valueIterator();
            while (it.next()) |info| {
                info.high_mrids.deinit(gpa);
                info.low_mrids.deinit(gpa);
            }
            self.voltage_level_limits.deinit(gpa);
        }

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
        .busbar_section_in_parse_order = .empty,
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
    const objects = model.get_objects_by_type("OperationalLimitType");
    try index.limit_types.ensureTotalCapacity(gpa, @intCast(objects.len));
    for (objects) |obj| {
        const view = model.view(obj);
        const is_inf = try view.getProperty("OperationalLimitType.isInfiniteDuration") orelse "false";
        const duration = try view.getProperty("OperationalLimitType.acceptableDuration");
        index.limit_types.putAssumeCapacity(obj.id, .{
            .is_infinite = std.mem.eql(u8, is_inf, "true"),
            .acceptable_duration = duration,
        });
    }
    assert(index.limit_types.count() == objects.len);
}

fn build_terminals(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    assert(index.terminal_equipment.count() == 0);

    const objects = model.get_objects_by_type("Terminal");

    try index.terminal_equipment.ensureTotalCapacity(gpa, @intCast(objects.len));
    try index.terminal_conn_node.ensureTotalCapacity(gpa, @intCast(objects.len));
    try index.terminal_sequence.ensureTotalCapacity(gpa, @intCast(objects.len));
    try index.equipment_terminals.ensureTotalCapacity(gpa, @intCast(objects.len));

    for (objects) |obj| {
        const view = model.view(obj);
        const conn_node_ref = try view.getReference("Terminal.ConnectivityNode");
        const conn_node_id: ?[]const u8 = if (conn_node_ref) |ref| strip_hash(ref) else null;
        if (conn_node_id) |id| {
            index.terminal_conn_node.putAssumeCapacity(obj.id, id);
        }

        const sequence_str = try view.getProperty("ACDCTerminal.sequenceNumber") orelse "1";
        const sequence = try std.fmt.parseInt(u32, sequence_str, 10);
        index.terminal_sequence.putAssumeCapacity(obj.id, sequence);

        const equipment_ref = try view.getReference("Terminal.ConductingEquipment") orelse return error.MalFormedXML;
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

    const busbar_sections = model.get_objects_by_type("BusbarSection");
    try index.conn_node_to_busbar_section.ensureTotalCapacity(gpa, @intCast(busbar_sections.len));

    for (busbar_sections) |busbar_section| {
        const terminals = index.equipment_terminals.get(busbar_section.id) orelse continue;
        if (terminals.items.len != 1) {
            // TODO add log message
            continue;
        }
        const conn_node_id = index.terminal_conn_node.get(terminals.items[0].id) orelse continue;

        const busbar_section_mrid = try model.view(busbar_section).getProperty("IdentifiedObject.mRID") orelse strip_underscore(busbar_section.id);
        index.conn_node_to_busbar_section.putAssumeCapacity(conn_node_id, busbar_section_mrid);
    }

    const conn_nodes = model.get_objects_by_type("ConnectivityNode");

    try index.conn_node_container.ensureTotalCapacity(gpa, @intCast(conn_nodes.len));
    try index.busbar_section_in_parse_order.ensureTotalCapacity(gpa, busbar_sections.len);

    for (conn_nodes) |conn_node| {
        const container_ref = try model.view(conn_node).getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
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

    const op_lim_sets = model.get_objects_by_type("OperationalLimitSet");
    try index.terminal_limit_sets.ensureTotalCapacity(gpa, @intCast(op_lim_sets.len));

    for (op_lim_sets) |op_lim_set| {
        const terminal_ref = try model.view(op_lim_set).getReference("OperationalLimitSet.Terminal") orelse continue;
        const terminal_id = strip_hash(terminal_ref);
        const gop = index.terminal_limit_sets.getOrPutAssumeCapacity(terminal_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(gpa, op_lim_set);
    }

    const current_lims = model.get_objects_by_type("CurrentLimit");
    try index.current_limits_by_set.ensureTotalCapacity(gpa, @intCast(current_lims.len));

    for (current_lims) |current_lim| {
        const op_lim_set_ref = try model.view(current_lim).getReference("OperationalLimit.OperationalLimitSet") orelse continue;
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
    const curve_datas = model.get_objects_by_type("CurveData");
    try index.curve_points.ensureTotalCapacity(gpa, @intCast(curve_datas.len));

    for (curve_datas) |curve_data| {
        const view = model.view(curve_data);
        const curve_ref = try view.getReference("CurveData.Curve") orelse return error.MalformedXML;
        const curve_id = strip_hash(curve_ref);

        const x_val = try view.getProperty("CurveData.xvalue") orelse "0.0";
        const y1_val = try view.getProperty("CurveData.y1value") orelse "0.0";
        const y2_val = try view.getProperty("CurveData.y2value") orelse "0.0";

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

// For each switch object, look up its two Terminals.
// Then get the ConnectivityNode of both Terminals.
// Then get the ConnectivityNodeContainer of both ConnectivityNodes.
// Then if the two CN Containers are different, we union their VoltageLevels.
// VoltageLevel union basically puts the VoltageLevel with the lower mRID as the parent.
pub fn process_switch_type(
    model: *const cim_model.CimModel,
    index: *const CimIndex,
    switches: []const CimObject,
    parent: *std.StringHashMapUnmanaged([]const u8),
) !void {
    for (switches) |@"switch"| {
        const terminals = index.equipment_terminals.get(@"switch".id) orelse continue;
        if (terminals.items.len != 2) continue; // TODO log a warning?

        const conn_node0 = index.terminal_conn_node.get(terminals.items[0].id) orelse continue;
        const conn_node1 = index.terminal_conn_node.get(terminals.items[1].id) orelse continue;

        const container0 = index.conn_node_container.get(conn_node0) orelse continue;
        const container1 = index.conn_node_container.get(conn_node1) orelse continue;
        if (std.mem.eql(u8, container0, container1)) continue;

        const obj0 = model.getObjectById(container0) orelse continue;
        const obj1 = model.getObjectById(container1) orelse continue;
        if (!std.mem.eql(u8, obj0.type_name, "VoltageLevel")) continue;
        if (!std.mem.eql(u8, obj1.type_name, "VoltageLevel")) continue;

        try topology_mod.union_voltage_levels(model, parent, container0, container1);
    }
}

pub fn build_voltage_limits(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex, topology: *const Topology) !void {
    assert(index.voltage_level_limits.count() == 0);

    const voltage_limits = model.get_objects_by_type("VoltageLimit");
    try index.voltage_level_limits.ensureTotalCapacity(gpa, @intCast(voltage_limits.len));

    for (voltage_limits) |voltage_limit| {
        const voltage_limit_view = model.view(voltage_limit);
        const limit_set_ref = try voltage_limit_view.getReference("OperationalLimit.OperationalLimitSet") orelse continue;
        const limit_set = model.getObjectById(strip_hash(limit_set_ref)) orelse continue;
        const terminal_ref = try limit_set.getReference("OperationalLimitSet.Terminal") orelse continue;

        const terminal_id = strip_hash(terminal_ref);
        const conn_node_id = index.terminal_conn_node.get(terminal_id) orelse continue;
        // Resolve container via CN, falling back to terminal equipment's EquipmentContainer
        // when the CN has no ConnectivityNode element (only referenced in Terminal elements).
        const raw_container_id: []const u8 = if (index.conn_node_container.get(conn_node_id)) |id| id else blk: {
            const terminal = model.getObjectById(terminal_id) orelse continue;
            const eq_ref = try terminal.getReference("Terminal.ConductingEquipment") orelse continue;
            const eq = model.getObjectById(strip_hash(eq_ref)) orelse continue;
            const ec_ref = try eq.getReference("Equipment.EquipmentContainer") orelse continue;
            break :blk strip_hash(ec_ref);
        };
        // Apply VL merge so limits are keyed by the representative VL.
        const container_id = topology_mod.find_root(&topology.voltage_level_merge, raw_container_id);
        const container = model.getObjectById(container_id) orelse continue;

        if (!std.mem.eql(u8, container.type_name, "VoltageLevel")) continue;

        const limit_type_ref = try voltage_limit_view.getReference("OperationalLimit.OperationalLimitType") orelse continue;
        const limit_type = model.getObjectById(strip_hash(limit_type_ref)) orelse continue;
        const direction = try limit_type.getReference("OperationalLimitType.direction") orelse continue;

        const value_str = try voltage_limit_view.getProperty("VoltageLimit.normalValue") orelse continue;
        const value = try std.fmt.parseFloat(f64, value_str);

        const gop = index.voltage_level_limits.getOrPutAssumeCapacity(container_id);
        if (!gop.found_existing) gop.value_ptr.* = .{
            .high_value = null,
            .low_value = null,
            .high_value_str = null,
            .low_value_str = null,
            .high_mrids = .empty,
            .low_mrids = .empty,
        };

        const voltage_limit_mrid = try voltage_limit_view.getProperty("IdentifiedObject.mRID") orelse
            utils.strip_underscore(voltage_limit_view.id);

        if (std.mem.endsWith(u8, direction, "high")) {
            try gop.value_ptr.high_mrids.append(gpa, voltage_limit_mrid);
            // Most restrictive high limit is the minimum.
            if (gop.value_ptr.high_value == null or value < gop.value_ptr.high_value.?) {
                gop.value_ptr.high_value = value;
                gop.value_ptr.high_value_str = value_str;
            }
        } else {
            try gop.value_ptr.low_mrids.append(gpa, voltage_limit_mrid);
            // Most restrictive low limit is the maximum.
            if (gop.value_ptr.low_value == null or value > gop.value_ptr.low_value.?) {
                gop.value_ptr.low_value = value;
                gop.value_ptr.low_value_str = value_str;
            }
        }
    }
    assert(index.voltage_level_limits.count() <= voltage_limits.len);
}
