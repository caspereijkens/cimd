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

/// VL id and node for a single line terminal.
const LinePlacement = struct {
    voltage_level_id: []const u8,
    node: u32,
};

/// Resolves placement for one line terminal.
/// Regular terminals: looks up voltage_level_map and node_map.
/// Boundary terminals: uses the pre-built boundary maps.
///   Node 0 if this is the first ACLineSegment to use this boundary CN (XML order).
///   Node 1 if it is the second+ (the IC {0,1} in the fictitious VL bridges them).
/// Returns null if the terminal cannot be placed (line should be skipped).
fn resolve_line_terminal(
    t: cim_index.TerminalInfo,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
    boundary_conn_node_voltage_level_map: *const std.StringHashMapUnmanaged(u32),
    boundary_conn_node_first_terminal: *const std.StringHashMapUnmanaged([]const u8),
    network: *const iidm.Network,
) ?LinePlacement {
    assert(t.id.len > 0);
    const conn_node_id = t.conn_node_id orelse return null;

    // Regular placement via VoltageLevel map
    if (placement_mod.resolve_terminal_placement(t.id, conn_node_id, index, voltage_level_map, node_map)) |p| {
        return .{ .voltage_level_id = p.voltage_level.id, .node = p.node };
    }

    // Boundary placement via fictitious VL map.
    // Node 0 for the first ACLineSegment to encounter this boundary CN (XML order).
    // Node 1 for subsequent ACLineSegments (IC {0,1} bridges node 0 and node 1).
    const fict_voltage_level_idx = boundary_conn_node_voltage_level_map.get(conn_node_id) orelse return null;
    const first_terminal_id = boundary_conn_node_first_terminal.get(conn_node_id) orelse return null;
    const node: u32 = if (std.mem.eql(u8, t.id, first_terminal_id)) 0 else 1;
    return .{
        .voltage_level_id = network.fictitious_voltage_levels.items[fict_voltage_level_idx].id,
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
    const lines = model.getObjectsByType("ACLineSegment");
    const series_compensators = model.getObjectsByType("SeriesCompensator");
    assert(lines.len == 0 or index.equipment_terminals.count() > 0);

    // ---- Fictitious VLs for boundary ConnectivityNodes ----
    // A boundary CN has a container that is not a VoltageLevel (typically a Line
    // EquipmentContainer for cross-border tie lines). PyPowSyBl creates a
    // FictitiousVoltageLevel with id "<CN_mRID>_VL" and one IC {0,1}.
    //
    // Node assignment mirrors PyPowSyBl's Phase 2 logic:
    //   - First ACLineSegment (XML order) on this CN → terminal at node 0.
    //   - Second+ ACLineSegment → terminal at node 1 (IC {0,1} bridges them).
    //
    // Maps built here:
    //   boundary_conn_node_voltage_level_map:         CN raw_id → index in network.fictitious_voltage_levels
    //   boundary_conn_node_first_terminal: CN raw_id → terminal ID of the first-seen terminal (node 0)
    var boundary_conn_node_voltage_level_map: std.StringHashMapUnmanaged(u32) = .empty;
    defer boundary_conn_node_voltage_level_map.deinit(gpa);

    var boundary_conn_node_first_terminal: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer boundary_conn_node_first_terminal.deinit(gpa);

    // Single pass: create one FictitiousVoltageLevel per unique boundary CN.
    // Previously two passes (count then create); merged by using dynamic
    // allocation for the intermediate boundary maps. The FVL list and maps
    // grow lazily — boundary CNs are at most ~345, so at most ~9 reallocations.
    // The first segment (ACLineSegment or SeriesCompensator, in XML order) that
    // encounters a boundary CN creates the FVL and records itself as the
    // "first terminal" (→ node 0). The FVL always has IC {node1=0, node2=1}.
    for ([_][]const cim_model.CimObject{ lines, series_compensators }) |seg_slice| {
        for (seg_slice) |line| {
            const terminals = index.equipment_terminals.get(line.id) orelse continue;
            for (terminals.items) |t| {
                const conn_node_id = t.conn_node_id orelse continue;
                if (boundary_conn_node_voltage_level_map.contains(conn_node_id)) continue;
                const container_id = index.conn_node_container.get(conn_node_id) orelse continue;
                const repr_id = cim_index.find_voltage_level(&index.voltage_level_merge, container_id);
                if (voltage_level_map.contains(repr_id)) continue;
                // Any CN whose container is not a VoltageLevel is a boundary CN.

                const conn_node_obj = model.getObjectById(conn_node_id).?;
                const conn_node_mrid = try conn_node_obj.getProperty("IdentifiedObject.mRID") orelse strip_underscore(conn_node_id);

                // PyPowSyBl uses the Line container's name as the FVL name (not the CN name).
                const container_obj_opt = model.getObjectById(container_id);
                const container_mrid = blk: {
                    if (container_obj_opt) |container_obj| {
                        if (try container_obj.getProperty("IdentifiedObject.mRID")) |m| break :blk m;
                    }
                    break :blk strip_underscore(container_id);
                };
                const conn_node_name: ?[]const u8 = blk: {
                    const co = container_obj_opt orelse break :blk null;
                    break :blk try co.getProperty("IdentifiedObject.name");
                };

                // nominalV from the ACLineSegment's BaseVoltage (not the Line container's)
                var nominal_v: ?f64 = null;
                if (try line.getReference("ConductingEquipment.BaseVoltage")) |bv_ref| {
                    const bv_id = strip_hash(bv_ref);
                    if (model.getObjectById(bv_id)) |bv_obj| {
                        if (try bv_obj.getProperty("BaseVoltage.nominalVoltage")) |nv_str| {
                            nominal_v = std.fmt.parseFloat(f64, std.mem.trim(u8, nv_str, " \t\r\n")) catch null;
                        }
                    }
                }

                // id is always heap-allocated; freed by FictitiousVoltageLevel.deinit
                const fict_voltage_level_id = try std.fmt.allocPrint(gpa, "{s}_VL", .{conn_node_mrid});

                var internal_connections: std.ArrayListUnmanaged(iidm.InternalConnection) = .empty;
                try internal_connections.ensureTotalCapacity(gpa, 1);
                internal_connections.appendAssumeCapacity(.{ .node1 = 0, .node2 = 1 });

                const fict_voltage_level_idx: u32 = @intCast(network.fictitious_voltage_levels.items.len);
                try network.fictitious_voltage_levels.append(gpa, .{
                    .id = fict_voltage_level_id,
                    .name = conn_node_name,
                    .nominal_v = nominal_v,
                    .line_container_id = container_mrid,
                    .internal_connections = internal_connections,
                });
                try boundary_conn_node_voltage_level_map.put(gpa, conn_node_id, fict_voltage_level_idx);
                try boundary_conn_node_first_terminal.put(gpa, conn_node_id, t.id); // this terminal → node 0
            }
        }
    }

    // ---- Convert ACLineSegments ----
    try network.lines.ensureTotalCapacity(gpa, lines.len + series_compensators.len);
    assert(network.lines.capacity >= lines.len + series_compensators.len);

    for (lines) |line| {
        const mrid = try line.getProperty("IdentifiedObject.mRID") orelse strip_underscore(line.id);
        const name = try line.getProperty("IdentifiedObject.name");

        const r = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.r") orelse "0.0");
        const x = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.x") orelse "0.0");
        const gch = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.gch") orelse "0.0");
        const bch = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.bch") orelse "0.0");

        const terminals = index.equipment_terminals.get(line.id) orelse continue;
        if (terminals.items.len != 2) continue;

        const p1 = resolve_line_terminal(
            terminals.items[0],
            index,
            voltage_level_map,
            node_map,
            &boundary_conn_node_voltage_level_map,
            &boundary_conn_node_first_terminal,
            network,
        ) orelse continue;
        const p2 = resolve_line_terminal(
            terminals.items[1],
            index,
            voltage_level_map,
            node_map,
            &boundary_conn_node_voltage_level_map,
            &boundary_conn_node_first_terminal,
            network,
        ) orelse continue;

        // aliases: CGMES.Terminal1 and CGMES.Terminal2, always in sequence order.
        var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
        errdefer aliases.deinit(gpa);
        try aliases.ensureTotalCapacity(gpa, 2);
        aliases.appendAssumeCapacity(.{ .type = "CGMES.Terminal1", .content = strip_underscore(terminals.items[0].id) });
        aliases.appendAssumeCapacity(.{ .type = "CGMES.Terminal2", .content = strip_underscore(terminals.items[1].id) });

        // properties: CGMES.originalClass
        var props: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer props.deinit(gpa);
        try props.ensureTotalCapacity(gpa, 1);
        props.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = "ACLineSegment" });

        // operational limits groups for each terminal
        var olg1 = try placement_mod.build_op_lims(gpa, index, terminals.items[0].id);
        errdefer {
            for (olg1.items) |*g| g.deinit(gpa);
            olg1.deinit(gpa);
        }
        var olg2 = try placement_mod.build_op_lims(gpa, index, terminals.items[1].id);
        errdefer {
            for (olg2.items) |*g| g.deinit(gpa);
            olg2.deinit(gpa);
        }

        const sel1: ?[]const u8 = if (olg1.items.len > 0) olg1.items[0].id else null;
        const sel2: ?[]const u8 = if (olg2.items.len > 0) olg2.items[0].id else null;

        network.lines.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .r = r,
            .x = x,
            .g1 = gch / 2.0,
            .g2 = gch / 2.0,
            .b1 = bch / 2.0,
            .b2 = bch / 2.0,
            .voltage_level1_id = p1.voltage_level_id,
            .node1 = p1.node,
            .voltage_level2_id = p2.voltage_level_id,
            .node2 = p2.node,
            .selected_op_lims_group1_id = sel1,
            .selected_op_lims_group2_id = sel2,
            .aliases = aliases,
            .properties = props,
            .op_lims_groups1 = olg1,
            .op_lims_groups2 = olg2,
        });
        aliases = .empty;
        props = .empty;
        olg1 = .empty;
        olg2 = .empty;
    }

    // ---- Convert SeriesCompensators (pypow treats them as IIDM Lines) ----
    // SeriesCompensator has r/x but no shunt admittance (gch/bch = 0.0).
    for (series_compensators) |sc| {
        const mrid = try sc.getProperty("IdentifiedObject.mRID") orelse strip_underscore(sc.id);
        const name = try sc.getProperty("IdentifiedObject.name");

        const r = try std.fmt.parseFloat(f64, try sc.getProperty("SeriesCompensator.r") orelse "0.0");
        const x = try std.fmt.parseFloat(f64, try sc.getProperty("SeriesCompensator.x") orelse "0.0");

        const terminals = index.equipment_terminals.get(sc.id) orelse continue;
        if (terminals.items.len != 2) continue;

        const p1 = resolve_line_terminal(
            terminals.items[0],
            index,
            voltage_level_map,
            node_map,
            &boundary_conn_node_voltage_level_map,
            &boundary_conn_node_first_terminal,
            network,
        ) orelse continue;
        const p2 = resolve_line_terminal(
            terminals.items[1],
            index,
            voltage_level_map,
            node_map,
            &boundary_conn_node_voltage_level_map,
            &boundary_conn_node_first_terminal,
            network,
        ) orelse continue;

        // aliases: CGMES.Terminal1 and CGMES.Terminal2, always in sequence order.
        var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
        errdefer aliases.deinit(gpa);
        try aliases.ensureTotalCapacity(gpa, 2);
        aliases.appendAssumeCapacity(.{ .type = "CGMES.Terminal1", .content = strip_underscore(terminals.items[0].id) });
        aliases.appendAssumeCapacity(.{ .type = "CGMES.Terminal2", .content = strip_underscore(terminals.items[1].id) });

        // properties: CGMES.originalClass
        var props: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer props.deinit(gpa);
        try props.ensureTotalCapacity(gpa, 1);
        props.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = "SeriesCompensator" });

        // operational limits groups for each terminal
        var olg1 = try placement_mod.build_op_lims(gpa, index, terminals.items[0].id);
        errdefer {
            for (olg1.items) |*g| g.deinit(gpa);
            olg1.deinit(gpa);
        }
        var olg2 = try placement_mod.build_op_lims(gpa, index, terminals.items[1].id);
        errdefer {
            for (olg2.items) |*g| g.deinit(gpa);
            olg2.deinit(gpa);
        }

        const sel1: ?[]const u8 = if (olg1.items.len > 0) olg1.items[0].id else null;
        const sel2: ?[]const u8 = if (olg2.items.len > 0) olg2.items[0].id else null;

        network.lines.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .r = r,
            .x = x,
            .g1 = 0.0,
            .g2 = 0.0,
            .b1 = 0.0,
            .b2 = 0.0,
            .voltage_level1_id = p1.voltage_level_id,
            .node1 = p1.node,
            .voltage_level2_id = p2.voltage_level_id,
            .node2 = p2.node,
            .selected_op_lims_group1_id = sel1,
            .selected_op_lims_group2_id = sel2,
            .aliases = aliases,
            .properties = props,
            .op_lims_groups1 = olg1,
            .op_lims_groups2 = olg2,
        });
        aliases = .empty;
        props = .empty;
        olg1 = .empty;
        olg2 = .empty;
    }
}
