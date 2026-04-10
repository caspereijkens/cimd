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
/// Boundary terminals: looks up terminal_node_map for the assigned node.
/// Returns null if the terminal cannot be placed (line should be skipped).
fn resolve_line_terminal(
    t: cim_index.TerminalInfo,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
    boundary_conn_node_vl_map: *const std.StringHashMapUnmanaged(u32),
    terminal_node_map: *const std.StringHashMapUnmanaged(u32),
    network: *const iidm.Network,
) ?LinePlacement {
    assert(t.id.len > 0);
    const conn_node_id = t.conn_node_id orelse return null;

    // Regular placement via VoltageLevel map.
    if (placement_mod.resolve_terminal_placement(t.id, conn_node_id, index, voltage_level_map, node_map)) |p| {
        return .{ .voltage_level_id = p.voltage_level.id, .node = p.node };
    }

    // Boundary placement: unique node per terminal, pre-assigned in terminal_node_map.
    const fict_vl_idx = boundary_conn_node_vl_map.get(conn_node_id) orelse return null;
    const node = terminal_node_map.get(t.id) orelse return null;
    return .{
        .voltage_level_id = network.fictitious_voltage_levels.items[fict_vl_idx].id,
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
    // A boundary CN has a container that is not a VoltageLevel (typically a Line
    // EquipmentContainer for cross-border tie lines). PyPowSyBl creates a
    // FictitiousVoltageLevel with id "<CN_mRID>_VL".
    //
    // Multiple ACLineSegments may share the same boundary CN. Each gets a unique
    // node in the fictitious VL. Node 0 is a hub; lines connect to nodes 1, 2, ...
    // Internal connections: {0,1}, {0,2}, ..., {0,N} where N = terminal count.
    //
    // Implementation: two passes.
    //   Pass 1: scan all line/SC terminals, collect terminal IDs per boundary CN.
    //   Pass 2: create fictitious VLs with correct IC count, build terminal→node map.

    // Per-CN info collected in pass 1.
    const BoundaryCNInfo = struct {
        conn_node_mrid: []const u8,
        container_mrid: []const u8,
        conn_node_name: ?[]const u8,
        nominal_voltage: ?f64,
        terminal_ids: std.ArrayListUnmanaged([]const u8),
    };

    var boundary_cn_info: std.StringHashMapUnmanaged(BoundaryCNInfo) = .empty;
    defer {
        var it = boundary_cn_info.valueIterator();
        while (it.next()) |info| info.terminal_ids.deinit(gpa);
        boundary_cn_info.deinit(gpa);
    }

    // Pass 1: collect boundary CN terminals in XML encounter order.
    for ([_][]const cim_model.CimObject{ lines, series_compensators }) |seg_slice| {
        for (seg_slice) |seg| {
            const seg_view = model.view(seg);
            const terminals = index.equipment_terminals.get(seg.id) orelse continue;
            for (terminals.items) |t| {
                const conn_node_id = t.conn_node_id orelse continue;
                const container_id = index.conn_node_container.get(conn_node_id) orelse continue;
                const repr_id = cim_index.find_voltage_level(&index.voltage_level_merge, container_id);
                if (voltage_level_map.contains(repr_id)) continue;
                // Boundary CN: container is not a VoltageLevel.

                const gop = try boundary_cn_info.getOrPut(gpa, conn_node_id);
                if (!gop.found_existing) {
                    // First encounter: collect metadata from this line's view.
                    const conn_node_obj = model.getObjectById(conn_node_id).?;
                    const conn_node_mrid = try conn_node_obj.getProperty("IdentifiedObject.mRID") orelse strip_underscore(conn_node_id);
                    const container_obj_opt = model.getObjectById(container_id);
                    const container_mrid: []const u8 = blk: {
                        if (container_obj_opt) |co| {
                            if (try co.getProperty("IdentifiedObject.mRID")) |m| break :blk m;
                        }
                        break :blk strip_underscore(container_id);
                    };
                    const conn_node_name: ?[]const u8 = blk: {
                        const co = container_obj_opt orelse break :blk null;
                        break :blk try co.getProperty("IdentifiedObject.name");
                    };
                    var nominal_voltage: ?f64 = null;
                    if (try seg_view.getReference("ConductingEquipment.BaseVoltage")) |bv_ref| {
                        const bv_id = strip_hash(bv_ref);
                        if (model.getObjectById(bv_id)) |bv_obj| {
                            if (try bv_obj.getProperty("BaseVoltage.nominalVoltage")) |nv_str| {
                                nominal_voltage = std.fmt.parseFloat(f64, std.mem.trim(u8, nv_str, " \t\r\n")) catch null;
                            }
                        }
                    }
                    gop.value_ptr.* = .{
                        .conn_node_mrid = conn_node_mrid,
                        .container_mrid = container_mrid,
                        .conn_node_name = conn_node_name,
                        .nominal_voltage = nominal_voltage,
                        .terminal_ids = .empty,
                    };
                }

                // Append this terminal ID if not already present (one entry per unique terminal).
                const term_id = t.id;
                const already = for (gop.value_ptr.terminal_ids.items) |existing| {
                    if (std.mem.eql(u8, existing, term_id)) break true;
                } else false;
                if (!already) try gop.value_ptr.terminal_ids.append(gpa, term_id);
            }
        }
    }

    // Pass 2: create fictitious VLs + terminal→node map.
    var boundary_conn_node_vl_map: std.StringHashMapUnmanaged(u32) = .empty;
    defer boundary_conn_node_vl_map.deinit(gpa);
    var terminal_node_map: std.StringHashMapUnmanaged(u32) = .empty;
    defer terminal_node_map.deinit(gpa);

    var cn_iter = boundary_cn_info.iterator();
    while (cn_iter.next()) |entry| {
        const conn_node_id = entry.key_ptr.*;
        const info = entry.value_ptr;
        const count = info.terminal_ids.items.len;
        assert(count > 0);

        // id is heap-allocated; freed by FictitiousVoltageLevel.deinit.
        const fict_vl_id = try std.fmt.allocPrint(gpa, "{s}_VL", .{info.conn_node_mrid});

        // One IC per terminal: {0,1}, {0,2}, ..., {0,count}.
        var ics: std.ArrayListUnmanaged(iidm.InternalConnection) = .empty;
        try ics.ensureTotalCapacity(gpa, count);
        for (0..count) |i| {
            ics.appendAssumeCapacity(.{ .node1 = 0, .node2 = @intCast(i + 1) });
        }

        const fict_vl_idx: u32 = @intCast(network.fictitious_voltage_levels.items.len);
        try network.fictitious_voltage_levels.append(gpa, .{
            .id = fict_vl_id,
            .name = info.conn_node_name,
            .nominal_voltage = info.nominal_voltage,
            .line_container_id = info.container_mrid,
            .internal_connections = ics,
        });
        try boundary_conn_node_vl_map.put(gpa, conn_node_id, fict_vl_idx);

        // Assign nodes 1, 2, 3, ... to each terminal in encounter order.
        for (info.terminal_ids.items, 1..) |term_id, node| {
            try terminal_node_map.put(gpa, term_id, @intCast(node));
        }
    }

    // ---- Convert EquivalentInjections → generators in fictitious VLs ----
    // EquivalentInjections are boundary injections from the EQBD. Each is placed
    // at node 0 (the hub) of the fictitious VL for its boundary CN.
    // pypowsybl always names them "BoundaryInjectionEq" and uses ±Double.MAX_VALUE
    // for minP/maxP and minQ/maxQ (unconstrained boundary injection).
    const equiv_injections = model.get_objects_by_type("EquivalentInjection");
    for (equiv_injections) |ei| {
        const ei_view = model.view(ei);
        const mrid = try ei_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(ei.id);

        const ei_terminals = index.equipment_terminals.get(ei.id) orelse continue;
        if (ei_terminals.items.len == 0) continue;
        const t = ei_terminals.items[0];
        const conn_node_id = t.conn_node_id orelse continue;

        const fict_vl_idx = boundary_conn_node_vl_map.get(conn_node_id) orelse continue;
        const fvl = &network.fictitious_voltage_levels.items[fict_vl_idx];

        var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
        errdefer aliases.deinit(gpa);
        try aliases.ensureTotalCapacity(gpa, 1);
        aliases.appendAssumeCapacity(.{ .type = "CGMES.Terminal1", .content = strip_underscore(t.id) });

        var props: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer props.deinit(gpa);
        try props.ensureTotalCapacity(gpa, 2);
        props.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = "EquivalentInjection" });
        props.appendAssumeCapacity(.{ .name = "CGMES.regulationCapability", .value = "false" });

        const max_val = std.math.floatMax(f64);
        try fvl.generators.append(gpa, .{
            .id = mrid,
            .name = "BoundaryInjectionEq",
            .energy_source = .other,
            .min_p = -max_val,
            .max_p = max_val,
            .rated_s = null,
            .voltage_regulator_on = false,
            .node = 0,
            .reactive_capability_curve_points = .empty,
            .min_max_reactive_limits = .{ .min_q = -max_val, .max_q = max_val },
            .aliases = aliases,
            .properties = props,
        });
        aliases = .empty;
        props = .empty;
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
        const gch = try std.fmt.parseFloat(f64, try line_view.getProperty("ACLineSegment.gch") orelse "0.0");
        const bch = try std.fmt.parseFloat(f64, try line_view.getProperty("ACLineSegment.bch") orelse "0.0");

        const terminals = index.equipment_terminals.get(line.id) orelse continue;
        if (terminals.items.len != 2) continue;

        const p1 = resolve_line_terminal(
            terminals.items[0],
            index,
            voltage_level_map,
            node_map,
            &boundary_conn_node_vl_map,
            &terminal_node_map,
            network,
        ) orelse continue;
        const p2 = resolve_line_terminal(
            terminals.items[1],
            index,
            voltage_level_map,
            node_map,
            &boundary_conn_node_vl_map,
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
        var props: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer props.deinit(gpa);
        try props.ensureTotalCapacity(gpa, 1);
        props.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = "ACLineSegment" });

        // operational limits groups for each terminal
        var olg1 = try placement_mod.build_op_lims(gpa, model, index, terminals.items[0].id);
        errdefer {
            for (olg1.items) |*g| g.deinit(gpa);
            olg1.deinit(gpa);
        }
        var olg2 = try placement_mod.build_op_lims(gpa, model, index, terminals.items[1].id);
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
        const series_compensator_view = model.view(sc);
        const mrid = try series_compensator_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(sc.id);
        const name = try series_compensator_view.getProperty("IdentifiedObject.name");

        const r = try std.fmt.parseFloat(f64, try series_compensator_view.getProperty("SeriesCompensator.r") orelse "0.0");
        const x = try std.fmt.parseFloat(f64, try series_compensator_view.getProperty("SeriesCompensator.x") orelse "0.0");

        const terminals = index.equipment_terminals.get(sc.id) orelse continue;
        if (terminals.items.len != 2) continue;

        const p1 = resolve_line_terminal(
            terminals.items[0],
            index,
            voltage_level_map,
            node_map,
            &boundary_conn_node_vl_map,
            &terminal_node_map,
            network,
        ) orelse continue;
        const p2 = resolve_line_terminal(
            terminals.items[1],
            index,
            voltage_level_map,
            node_map,
            &boundary_conn_node_vl_map,
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
        var props: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer props.deinit(gpa);
        try props.ensureTotalCapacity(gpa, 1);
        props.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = "SeriesCompensator" });

        // operational limits groups for each terminal
        var olg1 = try placement_mod.build_op_lims(gpa, model, index, terminals.items[0].id);
        errdefer {
            for (olg1.items) |*g| g.deinit(gpa);
            olg1.deinit(gpa);
        }
        var olg2 = try placement_mod.build_op_lims(gpa, model, index, terminals.items[1].id);
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
