const std = @import("std");
const iidm = @import("../iidm.zig");
const cim_model = @import("../cim_model.zig");
const cim_index = @import("../cim_index.zig");
const utils = @import("../utils.zig");
const placement_mod = @import("placement.zig");
const connection_mod = @import("connection.zig");

const assert = std.debug.assert;

const CimModel = cim_model.CimModel;
const CimIndex = cim_index.CimIndex;
const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;
const NodeMap = connection_mod.NodeMap;

/// VoltageLevel id and node for a single line terminal.
const LinePlacement = struct {
    voltage_level_id: []const u8,
    node: u32,
};

/// Resolves placement for one line terminal.
/// Regular terminals: looks up voltage_level_map and node_map.
/// Boundary terminals: looks up terminal_node_map for the assigned node.
/// Returns null if the terminal cannot be placed (line should be skipped).
fn resolve_line_terminal(
    terminal: cim_index.TerminalInfo,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
    boundary_conn_node_voltage_level_map: *const std.StringHashMapUnmanaged(u32),
    terminal_node_map: *const std.StringHashMapUnmanaged(u32),
    network: *const iidm.Network,
) ?LinePlacement {
    assert(terminal.id.len > 0);
    const conn_node_id = terminal.conn_node_id orelse return null;

    // Regular placement via VoltageLevel map.
    if (placement_mod.resolve_terminal_placement(terminal.id, conn_node_id, index, voltage_level_map, node_map)) |placement| {
        return .{ .voltage_level_id = placement.voltage_level.id, .node = placement.node };
    }

    // Boundary placement: unique node per terminal, pre-assigned in terminal_node_map.
    const fictitious_voltage_level_index = boundary_conn_node_voltage_level_map.get(conn_node_id) orelse return null;
    const node = terminal_node_map.get(terminal.id) orelse return null;
    return .{
        .voltage_level_id = network.fictitious_voltage_levels.items[fictitious_voltage_level_index].id,
        .node = node,
    };
}

pub fn convert_lines(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    network: *iidm.Network,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
) !void {
    const lines = model.get_objects_by_type("ACLineSegment");
    const series_compensators = model.get_objects_by_type("SeriesCompensator");
    assert(lines.len == 0 or index.equipment_terminals.count() > 0);

    // ---- Fictitious VLs for boundary ConnectivityNodes ----
    //
    // A boundary ConnectivityNode has a container that is not a VoltageLevel (typically a Line
    // EquipmentContainer for cross-border tie lines). PyPowSyBl creates a
    // FictitiousVoltageLevel with id "<ConnectivityNode_mRID>_VL".
    //
    // Multiple ACLineSegments may share the same boundary ConnectivityNode. Each gets a unique
    // node in the fictitious VL. Node 0 is a hub; lines connect to nodes 1, 2, ...
    // Internal connections: {0,1}, {0,2}, ..., {0,N} where N = terminal count.
    //
    // Implementation: two passes.
    //   Pass 1: scan all line/SC terminals, collect terminal IDs per boundary ConnectivityNode.
    //   Pass 2: create fictitious VLs with correct IC count, build terminal→node map.

    // Per-ConnectivityNode info collected in pass 1.
    const BoundaryConnectivityNodeInfo = struct {
        conn_node_mrid: []const u8,
        container_mrid: []const u8,
        conn_node_name: ?[]const u8,
        nominal_voltage: ?f64,
        terminal_ids: std.ArrayListUnmanaged([]const u8),
    };

    var boundary_conn_node_info: std.StringHashMapUnmanaged(BoundaryConnectivityNodeInfo) = .empty;
    defer {
        var it = boundary_conn_node_info.valueIterator();
        while (it.next()) |info| info.terminal_ids.deinit(gpa);
        boundary_conn_node_info.deinit(gpa);
    }

    // Pass 1: collect boundary ConnectivityNode terminals in XML encounter order.
    for ([_][]const cim_model.CimObject{ lines, series_compensators }) |segment_slice| {
        for (segment_slice) |segment| {
            const segment_view = model.view(segment);
            const terminals = index.equipment_terminals.get(segment.id) orelse continue;
            for (terminals.items) |terminal| {
                const conn_node_id = terminal.conn_node_id orelse continue;
                const container_id = index.conn_node_container.get(conn_node_id) orelse continue;
                const representative_id = cim_index.find_voltage_level(&index.voltage_level_merge, container_id);
                if (voltage_level_map.contains(representative_id)) continue;
                // Boundary ConnectivityNode: container is not a VoltageLevel.

                const boundary_conn_node_entry = try boundary_conn_node_info.getOrPut(gpa, conn_node_id);
                if (!boundary_conn_node_entry.found_existing) {
                    // First encounter: collect metadata from this segment's view.
                    const conn_node_object = model.getObjectById(conn_node_id).?;
                    const conn_node_mrid = try conn_node_object.getProperty("IdentifiedObject.mRID") orelse strip_underscore(conn_node_id);
                    const container_object_opt = model.getObjectById(container_id);
                    const container_mrid: []const u8 = blk: {
                        if (container_object_opt) |container_object| {
                            if (try container_object.getProperty("IdentifiedObject.mRID")) |container_mrid_value| break :blk container_mrid_value;
                        }
                        break :blk strip_underscore(container_id);
                    };
                    const conn_node_name: ?[]const u8 = blk: {
                        const container_object = container_object_opt orelse break :blk null;
                        break :blk try container_object.getProperty("IdentifiedObject.name");
                    };
                    var nominal_voltage: ?f64 = null;
                    if (try segment_view.getReference("ConductingEquipment.BaseVoltage")) |base_voltage_ref| {
                        const base_voltage_id = strip_hash(base_voltage_ref);
                        if (model.getObjectById(base_voltage_id)) |base_voltage_object| {
                            if (try base_voltage_object.getProperty("BaseVoltage.nominalVoltage")) |nominal_voltage_str| {
                                nominal_voltage = std.fmt.parseFloat(f64, std.mem.trim(u8, nominal_voltage_str, " \t\r\n")) catch null;
                            }
                        }
                    }
                    boundary_conn_node_entry.value_ptr.* = .{
                        .conn_node_mrid = conn_node_mrid,
                        .container_mrid = container_mrid,
                        .conn_node_name = conn_node_name,
                        .nominal_voltage = nominal_voltage,
                        .terminal_ids = .empty,
                    };
                }

                // Append this terminal ID if not already present (one entry per unique terminal).
                const terminal_id = terminal.id;
                const already = for (boundary_conn_node_entry.value_ptr.terminal_ids.items) |existing| {
                    if (std.mem.eql(u8, existing, terminal_id)) break true;
                } else false;
                if (!already) try boundary_conn_node_entry.value_ptr.terminal_ids.append(gpa, terminal_id);
            }
        }
    }

    // Pass 2: create fictitious VLs + terminal→node map.
    var boundary_conn_node_voltage_level_map: std.StringHashMapUnmanaged(u32) = .empty;
    defer boundary_conn_node_voltage_level_map.deinit(gpa);
    var terminal_node_map: std.StringHashMapUnmanaged(u32) = .empty;
    defer terminal_node_map.deinit(gpa);

    var connectivity_node_iterator = boundary_conn_node_info.iterator();
    while (connectivity_node_iterator.next()) |connectivity_node_entry| {
        const conn_node_id = connectivity_node_entry.key_ptr.*;
        const info = connectivity_node_entry.value_ptr;
        const terminal_count = info.terminal_ids.items.len;
        assert(terminal_count > 0);

        // id is heap-allocated; freed by FictitiousVoltageLevel.deinit.
        const fictitious_voltage_level_id = try std.fmt.allocPrint(gpa, "{s}_VL", .{info.conn_node_mrid});

        // One IC per terminal: {0,1}, {0,2}, ..., {0,terminal_count}.
        var internal_connections: std.ArrayListUnmanaged(iidm.InternalConnection) = .empty;
        try internal_connections.ensureTotalCapacity(gpa, terminal_count);
        for (0..terminal_count) |i| {
            internal_connections.appendAssumeCapacity(.{ .node1 = 0, .node2 = @intCast(i + 1) });
        }

        const fictitious_voltage_level_index: u32 = @intCast(network.fictitious_voltage_levels.items.len);
        try network.fictitious_voltage_levels.append(gpa, .{
            .id = fictitious_voltage_level_id,
            .name = info.conn_node_name,
            .nominal_voltage = info.nominal_voltage,
            .line_container_id = info.container_mrid,
            .internal_connections = internal_connections,
        });
        try boundary_conn_node_voltage_level_map.put(gpa, conn_node_id, fictitious_voltage_level_index);

        // Assign nodes 1, 2, 3, ... to each terminal in encounter order.
        for (info.terminal_ids.items, 1..) |terminal_id, node| {
            try terminal_node_map.put(gpa, terminal_id, @intCast(node));
        }
    }

    // ---- Convert EquivalentInjections → generators in fictitious VLs ----
    // EquivalentInjections are boundary injections from the EQBD. Each is placed
    // at node 0 (the hub) of the fictitious VL for its boundary ConnectivityNode.
    // pypowsybl always names them "BoundaryInjectionEq" and uses ±Double.MAX_VALUE
    // for minP/maxP and minQ/maxQ (unconstrained boundary injection).
    const equivalent_injections = model.get_objects_by_type("EquivalentInjection");
    for (equivalent_injections) |equivalent_injection| {
        const equivalent_injection_view = model.view(equivalent_injection);
        const mrid = try equivalent_injection_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(equivalent_injection.id);

        const equivalent_injection_terminals = index.equipment_terminals.get(equivalent_injection.id) orelse continue;
        if (equivalent_injection_terminals.items.len == 0) continue;
        const terminal = equivalent_injection_terminals.items[0];
        const conn_node_id = terminal.conn_node_id orelse continue;

        const fictitious_voltage_level_index = boundary_conn_node_voltage_level_map.get(conn_node_id) orelse continue;
        const fictitious_voltage_level = &network.fictitious_voltage_levels.items[fictitious_voltage_level_index];

        var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
        errdefer aliases.deinit(gpa);
        try aliases.ensureTotalCapacity(gpa, 1);
        aliases.appendAssumeCapacity(.{ .type = "CGMES.Terminal1", .content = strip_underscore(terminal.id) });

        var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer properties.deinit(gpa);
        try properties.ensureTotalCapacity(gpa, 2);
        properties.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = "EquivalentInjection" });
        properties.appendAssumeCapacity(.{ .name = "CGMES.regulationCapability", .value = "false" });

        const float_max = std.math.floatMax(f64);
        try fictitious_voltage_level.generators.append(gpa, .{
            .id = mrid,
            .name = "BoundaryInjectionEq",
            .energy_source = .other,
            .min_p = -float_max,
            .max_p = float_max,
            .rated_s = null,
            .voltage_regulator_on = false,
            .node = 0,
            .reactive_capability_curve_points = .empty,
            .min_max_reactive_limits = .{ .min_q = -float_max, .max_q = float_max },
            .aliases = aliases,
            .properties = properties,
        });
        aliases = .empty;
        properties = .empty;
    }

    // ---- Convert ACLineSegments ----
    try network.lines.ensureTotalCapacity(gpa, lines.len + series_compensators.len);
    assert(network.lines.capacity >= lines.len + series_compensators.len);

    for (lines) |line| {
        const line_view = model.view(line);
        const mrid = try line_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(line.id);
        const name = try line_view.getProperty("IdentifiedObject.name");

        const r = try std.fmt.parseFloat(f64, try line_view.getProperty("ACLineSegment.r") orelse "0.0");
        const x = try std.fmt.parseFloat(f64, try line_view.getProperty("ACLineSegment.x") orelse "0.0");
        const charging_conductance = try std.fmt.parseFloat(f64, try line_view.getProperty("ACLineSegment.gch") orelse "0.0");
        const charging_susceptance = try std.fmt.parseFloat(f64, try line_view.getProperty("ACLineSegment.bch") orelse "0.0");

        const terminals = index.equipment_terminals.get(line.id) orelse continue;
        if (terminals.items.len != 2) continue;

        const placement_1 = resolve_line_terminal(
            terminals.items[0],
            index,
            voltage_level_map,
            node_map,
            &boundary_conn_node_voltage_level_map,
            &terminal_node_map,
            network,
        ) orelse continue;
        const placement_2 = resolve_line_terminal(
            terminals.items[1],
            index,
            voltage_level_map,
            node_map,
            &boundary_conn_node_voltage_level_map,
            &terminal_node_map,
            network,
        ) orelse continue;

        // aliases: CGMES.Terminal1 and CGMES.Terminal2, always in sequence order.
        var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
        errdefer aliases.deinit(gpa);
        try aliases.ensureTotalCapacity(gpa, 2);
        aliases.appendAssumeCapacity(.{ .type = "CGMES.Terminal1", .content = strip_underscore(terminals.items[0].id) });
        aliases.appendAssumeCapacity(.{ .type = "CGMES.Terminal2", .content = strip_underscore(terminals.items[1].id) });

        // properties: CGMES.originalClass
        var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer properties.deinit(gpa);
        try properties.ensureTotalCapacity(gpa, 1);
        properties.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = "ACLineSegment" });

        // operational limits groups for each terminal
        var op_lims_groups_1 = try placement_mod.build_op_lims(gpa, model, index, terminals.items[0].id);
        errdefer {
            for (op_lims_groups_1.items) |*group| group.deinit(gpa);
            op_lims_groups_1.deinit(gpa);
        }
        var op_lims_groups_2 = try placement_mod.build_op_lims(gpa, model, index, terminals.items[1].id);
        errdefer {
            for (op_lims_groups_2.items) |*group| group.deinit(gpa);
            op_lims_groups_2.deinit(gpa);
        }

        const selected_op_lims_group_id_1: ?[]const u8 = if (op_lims_groups_1.items.len > 0) op_lims_groups_1.items[0].id else null;
        const selected_op_lims_group_id_2: ?[]const u8 = if (op_lims_groups_2.items.len > 0) op_lims_groups_2.items[0].id else null;

        network.lines.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .r = r,
            .x = x,
            .g1 = charging_conductance / 2.0,
            .g2 = charging_conductance / 2.0,
            .b1 = charging_susceptance / 2.0,
            .b2 = charging_susceptance / 2.0,
            .voltage_level1_id = placement_1.voltage_level_id,
            .node1 = placement_1.node,
            .voltage_level2_id = placement_2.voltage_level_id,
            .node2 = placement_2.node,
            .selected_op_lims_group1_id = selected_op_lims_group_id_1,
            .selected_op_lims_group2_id = selected_op_lims_group_id_2,
            .aliases = aliases,
            .properties = properties,
            .op_lims_groups1 = op_lims_groups_1,
            .op_lims_groups2 = op_lims_groups_2,
        });
        aliases = .empty;
        properties = .empty;
        op_lims_groups_1 = .empty;
        op_lims_groups_2 = .empty;
    }

    // ---- Convert SeriesCompensators (pypowsybl treats them as IIDM Lines) ----
    // SeriesCompensator has r/x but no shunt admittance (charging conductance/susceptance = 0.0).
    for (series_compensators) |series_compensator| {
        const series_compensator_view = model.view(series_compensator);
        const mrid = try series_compensator_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(series_compensator.id);
        const name = try series_compensator_view.getProperty("IdentifiedObject.name");

        const r = try std.fmt.parseFloat(f64, try series_compensator_view.getProperty("SeriesCompensator.r") orelse "0.0");
        const x = try std.fmt.parseFloat(f64, try series_compensator_view.getProperty("SeriesCompensator.x") orelse "0.0");

        const terminals = index.equipment_terminals.get(series_compensator.id) orelse continue;
        if (terminals.items.len != 2) continue;

        const placement_1 = resolve_line_terminal(
            terminals.items[0],
            index,
            voltage_level_map,
            node_map,
            &boundary_conn_node_voltage_level_map,
            &terminal_node_map,
            network,
        ) orelse continue;
        const placement_2 = resolve_line_terminal(
            terminals.items[1],
            index,
            voltage_level_map,
            node_map,
            &boundary_conn_node_voltage_level_map,
            &terminal_node_map,
            network,
        ) orelse continue;

        // aliases: CGMES.Terminal1 and CGMES.Terminal2, always in sequence order.
        var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
        errdefer aliases.deinit(gpa);
        try aliases.ensureTotalCapacity(gpa, 2);
        aliases.appendAssumeCapacity(.{ .type = "CGMES.Terminal1", .content = strip_underscore(terminals.items[0].id) });
        aliases.appendAssumeCapacity(.{ .type = "CGMES.Terminal2", .content = strip_underscore(terminals.items[1].id) });

        // properties: CGMES.originalClass
        var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer properties.deinit(gpa);
        try properties.ensureTotalCapacity(gpa, 1);
        properties.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = "SeriesCompensator" });

        // operational limits groups for each terminal
        var op_lims_groups_1 = try placement_mod.build_op_lims(gpa, model, index, terminals.items[0].id);
        errdefer {
            for (op_lims_groups_1.items) |*group| group.deinit(gpa);
            op_lims_groups_1.deinit(gpa);
        }
        var op_lims_groups_2 = try placement_mod.build_op_lims(gpa, model, index, terminals.items[1].id);
        errdefer {
            for (op_lims_groups_2.items) |*group| group.deinit(gpa);
            op_lims_groups_2.deinit(gpa);
        }

        const selected_op_lims_group_id_1: ?[]const u8 = if (op_lims_groups_1.items.len > 0) op_lims_groups_1.items[0].id else null;
        const selected_op_lims_group_id_2: ?[]const u8 = if (op_lims_groups_2.items.len > 0) op_lims_groups_2.items[0].id else null;

        network.lines.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .r = r,
            .x = x,
            .g1 = 0.0,
            .g2 = 0.0,
            .b1 = 0.0,
            .b2 = 0.0,
            .voltage_level1_id = placement_1.voltage_level_id,
            .node1 = placement_1.node,
            .voltage_level2_id = placement_2.voltage_level_id,
            .node2 = placement_2.node,
            .selected_op_lims_group1_id = selected_op_lims_group_id_1,
            .selected_op_lims_group2_id = selected_op_lims_group_id_2,
            .aliases = aliases,
            .properties = properties,
            .op_lims_groups1 = op_lims_groups_1,
            .op_lims_groups2 = op_lims_groups_2,
        });
        aliases = .empty;
        properties = .empty;
        op_lims_groups_1 = .empty;
        op_lims_groups_2 = .empty;
    }
}
