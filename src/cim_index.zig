const std = @import("std");
const iidm = @import("iidm.zig");
const tag_index = @import("tag_index.zig");
const utils = @import("utils.zig");
const cim_model = @import("cim_model.zig");

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
        //      try buildCurvePoints(gpa, model, &index);       // Pass 5
        //      try buildVlMerge(gpa, model, &index);           // Pass 6
        //      try buildSubstationMerge(gpa, model, &index);   // Pass 7
        //      try buildBfsPrecomputation(gpa, model, &index); // Pass 8
        //      try buildVoltageLimits(gpa, model, &index);     // Pass 9
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
}

fn build_terminals(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    const objects = model.getObjectsByType("Terminal");

    try index.terminal_equipment.ensureTotalCapacity(gpa, @intCast(objects.len));
    try index.terminal_conn_node.ensureTotalCapacity(gpa, @intCast(objects.len));
    try index.terminal_sequence.ensureTotalCapacity(gpa, @intCast(objects.len));
    try index.equipment_terminals.ensureTotalCapacity(gpa, @intCast(objects.len));

    for (objects) |obj| {
        const conn_node_ref = try obj.getReference("Terminal.ConnectivityNode");
        const conn_node_id: ?[]const u8 = if (conn_node_ref) |ref| utils.strip_hash(ref) else null;
        if (conn_node_id) |id| {
            index.terminal_conn_node.putAssumeCapacity(obj.id, id);
        }

        const sequence_str = try obj.getProperty("ACDCTerminal.sequenceNumber") orelse "1";
        const sequence = try std.fmt.parseInt(u32, sequence_str, 10);
        index.terminal_sequence.putAssumeCapacity(obj.id, sequence);

        const equipment_ref = try obj.getReference("Terminal.ConductingEquipment") orelse return error.MalFormedXML;
        const equipment_id = utils.strip_hash(equipment_ref);
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
}

fn build_connectivity(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    const busbar_sections = model.getObjectsByType("BusbarSection");
    try index.conn_node_to_busbar_section.ensureTotalCapacity(gpa, @intCast(busbar_sections.len));

    for (busbar_sections) |busbar_section| {
        const terminals = index.equipment_terminals.get(busbar_section.id) orelse continue;
        if (terminals.items.len != 1) {
            // TODO add log message
            continue;
        }
        const conn_node_id = index.terminal_conn_node.get(terminals.items[0].id) orelse continue;

        const busbar_section_mrid = try busbar_section.getProperty("IdentifiedObject.mRID") orelse utils.strip_underscore(busbar_section.id);
        index.conn_node_to_busbar_section.putAssumeCapacity(conn_node_id, busbar_section_mrid);
    }

    const conn_nodes = model.getObjectsByType("ConnectivityNode");

    try index.conn_node_container.ensureTotalCapacity(gpa, @intCast(conn_nodes.len));
    try index.busbar_section_in_parse_order.ensureTotalCapacity(gpa, busbar_sections.len);

    for (conn_nodes) |conn_node| {
        const container_ref = try conn_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
        index.conn_node_container.putAssumeCapacity(conn_node.id, utils.strip_hash(container_ref));

        const busbar_section_id = index.conn_node_to_busbar_section.get(conn_node.id) orelse continue;
        index.busbar_section_in_parse_order.appendAssumeCapacity(.{
            .conn_node_id = conn_node.id,
            .mrid = busbar_section_id,
        });
    }
}

fn build_operational_limits(gpa: std.mem.Allocator, model: *const cim_model.CimModel, index: *CimIndex) !void {
    const op_lim_sets = model.getObjectsByType("OperationalLimitSet");
    try index.terminal_limit_sets.ensureTotalCapacity(gpa, @intCast(op_lim_sets.len));

    for (op_lim_sets) |op_lim_set| {
        const terminal_ref = try op_lim_set.getReference("OperationalLimitSet.Terminal") orelse continue;
        const terminal_id = utils.strip_hash(terminal_ref);
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
        const op_lim_set_id = utils.strip_hash(op_lim_set_ref);
        const gop = index.current_limits_by_set.getOrPutAssumeCapacity(op_lim_set_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(gpa, current_lim);
    }
}
