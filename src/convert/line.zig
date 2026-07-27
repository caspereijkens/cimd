const std = @import("std");
const cim = @import("../cim/cim.zig");
const iidm = @import("../iidm/model.zig");
const cross_ref = @import("../topology/cross_ref.zig");
const utils = cim.ids;
const placement_mod = @import("placement.zig");
const resolve = @import("../topology/resolve.zig");
const parse = cim.parse;

const assert = std.debug.assert;

const CimDocument = cim.CimDocument;
const CrossRef = cross_ref.CrossRef;
const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;
const NodeMap = resolve.NodeMap;
const TerminalPlacer = placement_mod.TerminalPlacer;

/// Resolved placement for one line terminal.
const LinePlacement = struct {
    voltage_level_id: []const u8,
    node: u32,
    bus: ?[]const u8 = null,
};

/// Resolves placement for one line terminal.
/// Regular terminals: delegates to TerminalPlacer.
/// Boundary terminals (node-breaker only): looks up terminal_node_map for the assigned node.
/// Returns null if the terminal cannot be placed (line should be skipped).
fn resolve_line_terminal(
    terminal: cross_ref.TerminalInfo,
    placer: TerminalPlacer,
    boundary_conn_node_voltage_level_map: *const std.StringHashMapUnmanaged(u32),
    terminal_node_map: *const std.StringHashMapUnmanaged(u32),
    network: *const iidm.Network,
) !?LinePlacement {
    assert(terminal.id.len > 0);

    // Regular placement via placer.
    if (try placer.resolve_terminal(terminal.id, terminal.conn_node_id, terminal.ordinal)) |placement| {
        return .{
            .voltage_level_id = placement.voltage_level.id,
            .node = placement.node,
            .bus = placement.bus,
        };
    }

    // Boundary placement (node-breaker only): unique node per terminal, pre-assigned.
    const conn_node_id = terminal.conn_node_id orelse return null;
    const fictitious_voltage_level_index = boundary_conn_node_voltage_level_map.get(conn_node_id) orelse return null;
    const node = terminal_node_map.get(terminal.id) orelse return null;
    return .{
        .voltage_level_id = network.fictitious_voltage_levels.items[fictitious_voltage_level_index].id,
        .node = node,
    };
}

/// One ACLineSegment or SeriesCompensator's data, ready to become an IIDM Line.
/// `g`/`b` are the per-side shunt admittance: an ACLineSegment splits its charging
/// gch/bch evenly across both ends, while a SeriesCompensator has none (both 0).
const LineSegment = struct {
    object: cim.CimObject,
    mrid: []const u8,
    name: ?[]const u8,
    r: f64,
    x: f64,
    g: f64,
    b: f64,
    original_class: []const u8,
};

/// Convert one 2-terminal segment to an IIDM Line and append it to the network.
/// pypowsybl emits both ACLineSegments and SeriesCompensators as Lines; they differ
/// only in electrical data and originalClass (captured in `segment`), so the terminal
/// placement, CGMES.Terminal1/2 aliases, and per-terminal operational limits are shared
/// here. Does nothing when the segment lacks exactly two placeable terminals.
fn append_line_segment(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    network: *iidm.Network,
    placer: TerminalPlacer,
    boundary_conn_node_voltage_level_map: *const std.StringHashMapUnmanaged(u32),
    terminal_node_map: *const std.StringHashMapUnmanaged(u32),
    segment: LineSegment,
) !void {
    const index = placer.index;

    const terminals = index.equipment_terminals.get(segment.object.id) orelse return;
    if (terminals.items.len != 2) return;

    const placement_1 = try resolve_line_terminal(
        terminals.items[0],
        placer,
        boundary_conn_node_voltage_level_map,
        terminal_node_map,
        network,
    ) orelse return;
    const placement_2 = try resolve_line_terminal(
        terminals.items[1],
        placer,
        boundary_conn_node_voltage_level_map,
        terminal_node_map,
        network,
    ) orelse return;

    // aliases: CGMES.Terminal1 and CGMES.Terminal2, always in sequence order.
    var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
    errdefer aliases.deinit(gpa);
    try aliases.ensureTotalCapacity(gpa, 2);
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal1" }, .content = strip_underscore(terminals.items[0].id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal2" }, .content = strip_underscore(terminals.items[1].id) });

    // properties: CGMES.originalClass
    var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
    errdefer properties.deinit(gpa);
    try properties.ensureTotalCapacity(gpa, 1);
    properties.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = segment.original_class });

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
        .id = segment.mrid,
        .name = segment.name,
        .r = segment.r,
        .x = segment.x,
        .g1 = segment.g,
        .g2 = segment.g,
        .b1 = segment.b,
        .b2 = segment.b,
        .voltage_level1_id = placement_1.voltage_level_id,
        .node1 = placement_1.node,
        .bus1 = placement_1.bus,
        .connectable_bus1 = placement_1.bus,
        .voltage_level2_id = placement_2.voltage_level_id,
        .node2 = placement_2.node,
        .bus2 = placement_2.bus,
        .connectable_bus2 = placement_2.bus,
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

pub fn convert_lines(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    network: *iidm.Network,
    placer: TerminalPlacer,
    ssh_opt: ?cim.Overlay,
) !void {
    const index = placer.index;
    const voltage_level_map = placer.voltage_level_map;
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
    for ([_][]const cim.CimObject{ lines, series_compensators }) |segment_slice| {
        for (segment_slice) |segment| {
            const segment_view = model.view(segment);
            const terminals = index.equipment_terminals.get(segment.id) orelse continue;
            for (terminals.items) |terminal| {
                const conn_node_id = terminal.conn_node_id orelse continue;
                const container_id = index.conn_node_container.get(conn_node_id) orelse continue;
                const representative_id = resolve.find_root(&placer.topology.voltage_level_merge, container_id);
                if (voltage_level_map.contains(representative_id)) continue;
                // Boundary ConnectivityNode: container is not a VoltageLevel.

                const boundary_conn_node_entry = try boundary_conn_node_info.getOrPut(gpa, conn_node_id);
                if (!boundary_conn_node_entry.found_existing) {
                    // First encounter: collect metadata from this segment's view.
                    const conn_node_object = model.getObjectById(conn_node_id).?;
                    const conn_node_mrid = try conn_node_object.mrid();
                    const container_object_opt = model.getObjectById(container_id);
                    const container_mrid: []const u8 = blk: {
                        if (container_object_opt) |container_object| {
                            if (parse.non_blank(try container_object.getProperty("IdentifiedObject.mRID"))) |container_mrid_value| break :blk container_mrid_value;
                        }
                        break :blk strip_underscore(container_id);
                    };
                    const conn_node_name: ?[]const u8 = blk: {
                        const container_object = container_object_opt orelse break :blk null;
                        break :blk parse.non_blank(try container_object.getProperty("IdentifiedObject.name"));
                    };
                    var nominal_voltage: ?f64 = null;
                    if (try segment_view.getReference("ConductingEquipment.BaseVoltage")) |base_voltage_ref| {
                        const base_voltage_id = strip_hash(base_voltage_ref);
                        if (model.getObjectById(base_voltage_id)) |base_voltage_object| {
                            nominal_voltage = parse.float_opt(try base_voltage_object.getProperty("BaseVoltage.nominalVoltage"));
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
        const mrid = try equivalent_injection_view.mrid();

        const equivalent_injection_terminals = index.equipment_terminals.get(equivalent_injection.id) orelse continue;
        if (equivalent_injection_terminals.items.len == 0) continue;
        const terminal = equivalent_injection_terminals.items[0];
        const conn_node_id = terminal.conn_node_id orelse continue;

        const fictitious_voltage_level_index = boundary_conn_node_voltage_level_map.get(conn_node_id) orelse continue;
        const fictitious_voltage_level = &network.fictitious_voltage_levels.items[fictitious_voltage_level_index];

        var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
        errdefer aliases.deinit(gpa);
        try aliases.ensureTotalCapacity(gpa, 1);
        aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal1" }, .content = strip_underscore(terminal.id) });

        var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer properties.deinit(gpa);
        try properties.ensureTotalCapacity(gpa, 2);
        properties.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = "EquivalentInjection" });
        properties.appendAssumeCapacity(.{ .name = "CGMES.regulationCapability", .value = "false" });

        // SSH EquivalentInjection.p/q -- load convention (negative = injecting) → negate for targetP/Q.
        const target_p: ?f64 = if (ssh_opt) |ssh|
            if (try ssh.getProperty(mrid, "EquivalentInjection.p")) |v|
                -parse.float_or(v, 0.0)
            else
                null
        else
            null;
        const target_q: ?f64 = if (ssh_opt) |ssh|
            if (try ssh.getProperty(mrid, "EquivalentInjection.q")) |v|
                -parse.float_or(v, 0.0)
            else
                null
        else
            null;

        const float_max = std.math.floatMax(f64);
        try fictitious_voltage_level.generators.append(gpa, .{
            .id = mrid,
            .name = "BoundaryInjectionEq",
            .energy_source = .other,
            .min_p = -float_max,
            .max_p = float_max,
            .rated_s = null,
            .target_p = target_p,
            .target_q = target_q,
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
        const props = try line_view.getProperties(.{
            "IdentifiedObject.name",
            "ACLineSegment.r",
            "ACLineSegment.x",
            "ACLineSegment.gch",
            "ACLineSegment.bch",
        });
        // ACLineSegment shunt admittance (gch/bch) is split evenly across both ends.
        try append_line_segment(gpa, model, network, placer, &boundary_conn_node_voltage_level_map, &terminal_node_map, .{
            .object = line,
            .mrid = try line_view.mrid(),
            .name = parse.non_blank(props[0]),
            .r = try parse.float_strict(props[1], 0.0),
            .x = try parse.float_strict(props[2], 0.0),
            .g = (try parse.float_strict(props[3], 0.0)) / 2.0,
            .b = (try parse.float_strict(props[4], 0.0)) / 2.0,
            .original_class = "ACLineSegment",
        });
    }

    // ---- Convert SeriesCompensators (pypowsybl treats them as IIDM Lines) ----
    // SeriesCompensator has r/x but no shunt admittance (charging conductance/susceptance = 0.0).
    for (series_compensators) |series_compensator| {
        const series_compensator_view = model.view(series_compensator);
        const props = try series_compensator_view.getProperties(.{
            "IdentifiedObject.name",
            "SeriesCompensator.r",
            "SeriesCompensator.x",
        });
        try append_line_segment(gpa, model, network, placer, &boundary_conn_node_voltage_level_map, &terminal_node_map, .{
            .object = series_compensator,
            .mrid = try series_compensator_view.mrid(),
            .name = parse.non_blank(props[0]),
            .r = try parse.float_strict(props[1], 0.0),
            .x = try parse.float_strict(props[2], 0.0),
            .g = 0.0,
            .b = 0.0,
            .original_class = "SeriesCompensator",
        });
    }
}
