const std = @import("std");
const iidm = @import("../iidm.zig");
const cim_model = @import("../cim_model.zig");
const cim_index = @import("../cim_index.zig");
const tag_index = @import("../tag_index.zig");
const utils = @import("../utils.zig");

const placement_mod = @import("placement.zig");
const connection_mod = @import("connection.zig");

const assert = std.debug.assert;
const get_switch_slices = cim_index.get_switch_slices;

const CimModel = cim_model.CimModel;
const CimObject = tag_index.CimObject;
const CimSsh = @import("../cim_ssh.zig").CimSsh;
const CimMergedView = @import("../cim_ssh.zig").CimMergedView;
const CimIndex = cim_index.CimIndex;
const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;
const Placement = placement_mod.Placement;
const resolve_terminal_placement = placement_mod.resolve_terminal_placement;
const NodeMap = connection_mod.NodeMap;

const VoltageLevelEquipmentCounts = struct {
    busbar_sections: usize = 0,
    switches: usize = 0,
    generators: usize = 0,
    loads: usize = 0,
    shunts: usize = 0,
    static_var_compensators: usize = 0,
};

/// Resolve the representative VoltageLevel raw ID for a given equipment object.
/// Returns null if the equipment has no terminals, no CN, or no container.
/// Used only by count_equipment_for_type, which doesn't have the voltage_level_map.
fn resolve_repr_voltage_level_id(
    index: *const CimIndex,
    equipment_id: []const u8,
) ?[]const u8 {
    const terminals = index.equipment_terminals.get(equipment_id) orelse return null;
    const conn_node_id = terminals.items[0].conn_node_id orelse return null;
    const container_id = index.conn_node_container.get(conn_node_id) orelse return null;
    return cim_index.find_voltage_level(&index.voltage_level_merge, container_id);
}

/// Resolve VoltageLevel and node for a single-terminal equipment object.
/// Returns null if any step in the chain fails.
fn resolve_equipment_placement(
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
    equipment_id: []const u8,
) ?Placement {
    const terminals = index.equipment_terminals.get(equipment_id) orelse return null;
    const term = terminals.items[0];
    const conn_node_id = term.conn_node_id orelse return null;
    return resolve_terminal_placement(term.id, conn_node_id, index, voltage_level_map, node_map);
}

/// Count all objects of a given CIM type and increment the named field in the
/// per-VL counts map. Uses comptime field name so the compiler resolves the
/// field access at compile time with no runtime overhead.
fn count_equipment_for_type(
    model: *const CimModel,
    index: *const CimIndex,
    comptime cim_type: []const u8,
    comptime field_name: []const u8,
    equipment_counts: *std.StringHashMapUnmanaged(VoltageLevelEquipmentCounts),
) void {
    for (model.get_objects_by_type(cim_type)) |obj| {
        const repr_voltage_level_id = resolve_repr_voltage_level_id(index, obj.id) orelse continue;
        const gop = equipment_counts.getOrPutAssumeCapacity(repr_voltage_level_id);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        @field(gop.value_ptr.*, field_name) += 1;
    }
}

/// Count all equipment per VoltageLevel in one pass, then pre-allocate all
/// equipment arrays. Call this before any convertX function.
pub fn pre_allocate_equipment(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
) !void {
    assert(voltage_level_map.count() > 0);

    var equipment_counts: std.StringHashMapUnmanaged(VoltageLevelEquipmentCounts) = .empty;
    defer equipment_counts.deinit(gpa);
    try equipment_counts.ensureTotalCapacity(gpa, @intCast(voltage_level_map.count()));

    count_equipment_for_type(model, index, "BusbarSection", "busbar_sections", &equipment_counts);
    count_equipment_for_type(model, index, "Breaker", "switches", &equipment_counts);
    count_equipment_for_type(model, index, "Disconnector", "switches", &equipment_counts);
    count_equipment_for_type(model, index, "LoadBreakSwitch", "switches", &equipment_counts);
    count_equipment_for_type(model, index, "EnergyConsumer", "loads", &equipment_counts);
    count_equipment_for_type(model, index, "ConformLoad", "loads", &equipment_counts);
    count_equipment_for_type(model, index, "NonConformLoad", "loads", &equipment_counts);
    count_equipment_for_type(model, index, "LinearShuntCompensator", "shunts", &equipment_counts);
    count_equipment_for_type(model, index, "StaticVarCompensator", "static_var_compensators", &equipment_counts);
    count_equipment_for_type(model, index, "SynchronousMachine", "generators", &equipment_counts);

    var it = equipment_counts.iterator();
    while (it.next()) |entry| {
        const voltage_level = voltage_level_map.get(entry.key_ptr.*) orelse continue;
        const counts = entry.value_ptr.*;
        try voltage_level.node_breaker_topology.busbar_sections.ensureTotalCapacity(gpa, counts.busbar_sections);
        try voltage_level.node_breaker_topology.switches.ensureTotalCapacity(gpa, counts.switches);
        try voltage_level.generators.ensureTotalCapacity(gpa, counts.generators);
        try voltage_level.loads.ensureTotalCapacity(gpa, counts.loads);
        try voltage_level.shunts.ensureTotalCapacity(gpa, counts.shunts);
        try voltage_level.static_var_compensators.ensureTotalCapacity(gpa, counts.static_var_compensators);
    }

    assert(equipment_counts.count() <= voltage_level_map.count());
}

pub fn convert_busbar_sections(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
) !void {
    const busbar_sections = model.get_objects_by_type("BusbarSection");

    for (busbar_sections) |busbar_section| {
        const placement = resolve_equipment_placement(index, voltage_level_map, node_map, busbar_section.id) orelse continue;
        const voltage_level = placement.voltage_level;
        const node = placement.node;

        const busbar_section_view = model.view(busbar_section);
        const mrid = try busbar_section_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(busbar_section.id);
        const name = try busbar_section_view.getProperty("IdentifiedObject.name");

        // alias: CGMES.Terminal1 = terminal mRID
        var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
        errdefer aliases.deinit(gpa);
        if (index.equipment_terminals.get(busbar_section.id)) |terminals| {
            if (terminals.items.len > 0) {
                const t_view = model.getObjectById(terminals.items[0].id) orelse continue;
                const t_mrid = try t_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(terminals.items[0].id);
                try aliases.ensureTotalCapacity(gpa, 1);
                aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal1" }, .content = t_mrid });
            }
        }

        voltage_level.node_breaker_topology.busbar_sections.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .node = node,
            .aliases = aliases,
        });
        aliases = .empty; // ownership transferred
    }
}

pub fn convert_switches(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
    ssh_opt: ?CimSsh,
) !void {
    const switch_slices = get_switch_slices(model);

    for (switch_slices) |switch_slice| {
        for (switch_slice) |sw| {
            const terminals = index.equipment_terminals.get(sw.id) orelse continue;

            if (terminals.items.len < 2) continue;

            const node0 = node_map.get(terminals.items[0].id) orelse continue;
            const node1 = node_map.get(terminals.items[1].id) orelse continue;

            const conn_node0_id = terminals.items[0].conn_node_id orelse continue;
            const container0_id = index.conn_node_container.get(conn_node0_id) orelse continue;

            const repr_voltage_level_id = cim_index.find_voltage_level(&index.voltage_level_merge, container0_id);
            const voltage_level = voltage_level_map.get(repr_voltage_level_id) orelse continue;

            const eq_view = model.view(sw);
            const mrid_raw = try eq_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(sw.id);
            const mrid = try gpa.dupe(u8, mrid_raw);
            errdefer gpa.free(mrid);
            const view = CimMergedView.init(eq_view, mrid, ssh_opt);
            const name = try view.getProperty("IdentifiedObject.name");

            // Switch.open and Switch.retained are SSH attributes — EQ does not carry open state.
            const open_str = try view.getProperty("Switch.open") orelse "false";
            const open = std.mem.eql(u8, open_str, "true");
            const retained_str = try view.getProperty("Switch.retained") orelse "false";
            const retained = std.mem.eql(u8, retained_str, "true");

            const kind = iidm.SwitchKind.from_cim_type(sw.type_name);

            // aliases: CGMES.Terminal1 and CGMES.Terminal2 (terminals are in sequence order)
            var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
            errdefer aliases.deinit(gpa);
            {
                const t1_view = model.getObjectById(terminals.items[0].id) orelse continue;
                const t1_mrid = try t1_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(terminals.items[0].id);
                const t2_view = model.getObjectById(terminals.items[1].id) orelse continue;
                const t2_mrid = try t2_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(terminals.items[1].id);
                try aliases.ensureTotalCapacity(gpa, 2);
                aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal1" }, .content = t1_mrid });
                aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal2" }, .content = t2_mrid });
            }

            // properties: CGMES.originalClass and CGMES.normalOpen (EQ design-time attributes)
            var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
            errdefer properties.deinit(gpa);
            {
                const normal_open_str = try eq_view.getProperty("Switch.normalOpen") orelse "false";
                try properties.ensureTotalCapacity(gpa, 2);
                properties.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = sw.type_name });
                properties.appendAssumeCapacity(.{ .name = "CGMES.normalOpen", .value = normal_open_str });
            }

            voltage_level.node_breaker_topology.switches.appendAssumeCapacity(.{
                .id = mrid,
                .name = name,
                .kind = kind,
                .retained = retained,
                .open = open,
                .node1 = node0,
                .node2 = node1,
                .aliases = aliases,
                .properties = properties,
            });
            aliases = .empty; // ownership transferred
            properties = .empty; // ownership transferred
        }
    }
}

/// Create fictitious open breakers for terminals whose ConnectivityNode has no
/// switch connectivity, no BusbarSection, and is the sole non-switch/non-BBS
/// terminal on that CN.  PyPowSyBl synthesises these to represent "disconnected"
/// terminals in node-breaker topology.
/// cn_has_switch and cn_other_count are pre-computed by build_node_map as side effects
/// of its Phase 1 and Phase 2 passes respectively.  Accepting them here avoids two extra
/// full passes over all terminal data that would otherwise duplicate build_node_map's work.
pub fn convert_fictitious_switches(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const connection_mod.NodeMap,
    cn_has_switch: *const std.StringHashMapUnmanaged(void),
    cn_other_count: *const std.StringHashMapUnmanaged(u32),
    ssh_opt: ?CimSsh,
) !void {
    assert(voltage_level_map.count() > 0);

    // PyPowSyBl creates fictitious switches for:
    // 1. SSH-disconnected terminals (any equipment type — ACDCTerminal.connected=false in SSH).
    // 2. Structurally isolated injection terminals (SM/LSC/SVC on a CN with no switch and
    //    exactly one non-BBS/non-switch terminal) — these represent equipment not connected
    //    via any switch in the node-breaker topology.
    //
    // Loads (EnergyConsumer, ConformLoad, NonConformLoad) never receive fictitious switches.
    for (connection_mod.phase2_equipment_types) |eq_type| {
        const is_injection = std.mem.eql(u8, eq_type, "SynchronousMachine") or
            std.mem.eql(u8, eq_type, "LinearShuntCompensator") or
            std.mem.eql(u8, eq_type, "StaticVarCompensator");

        for (model.get_objects_by_type(eq_type)) |equip| {
            const terminals = index.equipment_terminals.get(equip.id) orelse continue;
            for (terminals.items) |t| {
                const cn_id = t.conn_node_id orelse continue;

                const ssh_disconnected = connection_mod.is_ssh_terminal_disconnected(ssh_opt, t.id);
                if (ssh_disconnected) {
                    // SSH-disconnected: always create fictitious regardless of type or CN topology.
                    // No-switch check is skipped — pypow creates fictitious even when the
                    // CN has switch connectivity if the terminal is marked disconnected.
                } else {
                    // Not SSH-disconnected: structural isolation check for injection types only.
                    if (!is_injection) continue;
                    if (cn_has_switch.contains(cn_id)) continue;
                    // BBS-CN terminals always get ICs in build_node_map — no fictitious needed.
                    // Non-BBS-CN: fictitious only when this is the sole non-switch/non-BBS terminal.
                    const cn_has_bbs = index.conn_node_to_busbar_section.contains(cn_id);
                    if (cn_has_bbs) continue;
                    const other_count = cn_other_count.get(cn_id) orelse 0;
                    if (other_count != 1) continue;
                }

                // Resolve to a representative VL.
                const container_id = index.conn_node_container.get(cn_id) orelse continue;
                const repr_id = cim_index.find_voltage_level(&index.voltage_level_merge, container_id);
                const voltage_level = voltage_level_map.get(repr_id) orelse continue;

                // Get terminal mRID for the switch id/name.
                const t_view = model.getObjectById(t.id) orelse continue;
                const t_mrid = try t_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(t.id);

                const terminal_node = node_map.get(t.id) orelse 0;
                const isolated_node = terminal_node +% 1; // value stripped by diff; just needs to differ

                var props: std.ArrayListUnmanaged(iidm.Property) = .empty;
                errdefer props.deinit(gpa);
                try props.ensureTotalCapacity(gpa, 2);
                props.appendAssumeCapacity(.{ .name = "CGMES.Terminal", .value = t_mrid });
                props.appendAssumeCapacity(.{ .name = "CGMES.isCreatedForDisconnectedTerminal", .value = "true" });

                const sw_id = try std.fmt.allocPrint(gpa, "{s}_SW_fict", .{t_mrid});

                try voltage_level.node_breaker_topology.switches.append(gpa, .{
                    .id = sw_id,
                    .name = t_mrid,
                    .fictitious = true,
                    .kind = .breaker,
                    .retained = false,
                    .open = true,
                    .node1 = terminal_node,
                    .node2 = isolated_node,
                    .aliases = .empty,
                    .properties = props,
                });
                props = .empty; // ownership transferred
            }
        }
    }
}

pub fn convert_loads(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
    ssh_opt: ?CimSsh,
) !void {
    const energy_consumers = model.get_objects_by_type("EnergyConsumer");
    const conform_loads = model.get_objects_by_type("ConformLoad");
    const non_conform_loads = model.get_objects_by_type("NonConformLoad");

    try convert_load_type(gpa, model, index, voltage_level_map, node_map, ssh_opt, energy_consumers, false);
    try convert_load_type(gpa, model, index, voltage_level_map, node_map, ssh_opt, conform_loads, false);
    // NonConformLoad: all power is fixed by definition — p0/q0 go into fixed, variable = 0.
    try convert_load_type(gpa, model, index, voltage_level_map, node_map, ssh_opt, non_conform_loads, true);
}

fn convert_load_type(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
    ssh_opt: ?CimSsh,
    loads: []const CimObject,
    non_conform: bool,
) !void {
    for (loads) |load| {
        const eq_view = model.view(load);
        const placement = resolve_equipment_placement(index, voltage_level_map, node_map, load.id) orelse continue;
        const voltage_level = placement.voltage_level;
        const node = placement.node;

        const mrid = try eq_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(load.id);
        const view = CimMergedView.init(eq_view, mrid, ssh_opt);
        const name = try view.getProperty("IdentifiedObject.name");

        // alias: CGMES.Terminal1 = terminal mRID
        var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
        errdefer aliases.deinit(gpa);
        if (index.equipment_terminals.get(load.id)) |terminals| {
            if (terminals.items.len > 0) {
                const t_mrid = strip_underscore(terminals.items[0].id);
                try aliases.ensureTotalCapacity(gpa, 1);
                aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal1" }, .content = t_mrid });
            }
        }

        // properties: CGMES.pFixed, CGMES.originalClass, CGMES.qFixed
        var props: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer props.deinit(gpa);
        try props.ensureTotalCapacity(gpa, 3);
        props.appendAssumeCapacity(.{ .name = "CGMES.pFixed", .value = "0.0" });
        props.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = load.type_name });
        props.appendAssumeCapacity(.{ .name = "CGMES.qFixed", .value = "0.0" });

        // Load response characteristic → exponentialModel or zipModel.
        var exp_model: ?iidm.ExponentialModel = null;
        var zip_model: ?iidm.ZipModel = null;
        if (try view.getReference("EnergyConsumer.LoadResponse")) |lr_ref| {
            if (model.getObjectById(strip_hash(lr_ref))) |lrc| {
                const exp_str = try lrc.getProperty("LoadResponseCharacteristic.exponentModel") orelse "false";
                if (std.mem.eql(u8, exp_str, "true")) {
                    const np_str = try lrc.getProperty("LoadResponseCharacteristic.pVoltageExponent") orelse "0";
                    const nq_str = try lrc.getProperty("LoadResponseCharacteristic.qVoltageExponent") orelse "0";
                    exp_model = .{
                        .np = std.fmt.parseFloat(f64, np_str) catch 0.0,
                        .nq = std.fmt.parseFloat(f64, nq_str) catch 0.0,
                    };
                } else {
                    const c0p = std.fmt.parseFloat(f64, try lrc.getProperty("LoadResponseCharacteristic.pConstantPower") orelse "0") catch 0.0;
                    const c1p = std.fmt.parseFloat(f64, try lrc.getProperty("LoadResponseCharacteristic.pConstantCurrent") orelse "0") catch 0.0;
                    const c2p = std.fmt.parseFloat(f64, try lrc.getProperty("LoadResponseCharacteristic.pConstantImpedance") orelse "0") catch 0.0;
                    const c0q = std.fmt.parseFloat(f64, try lrc.getProperty("LoadResponseCharacteristic.qConstantPower") orelse "0") catch 0.0;
                    const c1q = std.fmt.parseFloat(f64, try lrc.getProperty("LoadResponseCharacteristic.qConstantCurrent") orelse "0") catch 0.0;
                    const c2q = std.fmt.parseFloat(f64, try lrc.getProperty("LoadResponseCharacteristic.qConstantImpedance") orelse "0") catch 0.0;
                    zip_model = .{ .c0p = c0p, .c1p = c1p, .c2p = c2p, .c0q = c0q, .c1q = c1q, .c2q = c2q };
                }
            }
        }

        // SSH EnergyConsumer.p/q are in load convention (positive = consuming) — matches IIDM p0/q0.
        const p0: f64 = if (try view.getProperty("EnergyConsumer.p")) |v|
            std.fmt.parseFloat(f64, v) catch 0.0
        else
            0.0;
        const q0: f64 = if (try view.getProperty("EnergyConsumer.q")) |v|
            std.fmt.parseFloat(f64, v) catch 0.0
        else
            0.0;

        // detail extension fixed/variable split:
        // NonConformLoad — all power is fixed by definition (does not vary with load group).
        // ConformLoad / EnergyConsumer — fixed = pfixed (EQ), variable = p0 - pfixed.
        const fixed_active_power: f64 = if (non_conform)
            p0
        else if (try view.getProperty("EnergyConsumer.pfixed")) |v|
            std.fmt.parseFloat(f64, v) catch 0.0
        else
            0.0;
        const fixed_reactive_power: f64 = if (non_conform)
            q0
        else if (try view.getProperty("EnergyConsumer.qfixed")) |v|
            std.fmt.parseFloat(f64, v) catch 0.0
        else
            0.0;

        assert(mrid.len > 0);
        voltage_level.loads.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .load_type = .other,
            .p0 = p0,
            .q0 = q0,
            .fixed_active_power = fixed_active_power,
            .fixed_reactive_power = fixed_reactive_power,
            .node = node,
            .exponential_model = exp_model,
            .zip_model = zip_model,
            .aliases = aliases,
            .properties = props,
        });
        aliases = .empty; // ownership transferred
        props = .empty; // ownership transferred
    }
}

pub fn convert_shunts(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
    ssh_opt: ?CimSsh,
) !void {
    const shunts = model.get_objects_by_type("LinearShuntCompensator");
    assert(shunts.len == 0 or voltage_level_map.count() > 0);

    for (shunts) |shunt| {
        const eq_view = model.view(shunt);
        const placement = resolve_equipment_placement(index, voltage_level_map, node_map, shunt.id) orelse continue;
        const voltage_level = placement.voltage_level;
        const node = placement.node;

        const mrid = try eq_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(shunt.id);
        const view = CimMergedView.init(eq_view, mrid, ssh_opt);
        const name = try view.getProperty("IdentifiedObject.name");

        // ShuntCompensator.sections (current in-service sections) is an SSH attribute.
        // ShuntCompensator.maximumSections and electrical data are EQ attributes.
        const sections_str = try view.getProperty("ShuntCompensator.sections") orelse "0";
        const section_count: u32 = @intCast(try std.fmt.parseInt(i64, sections_str, 10));

        const max_sections_str = try view.getProperty("ShuntCompensator.maximumSections") orelse "0";
        const max_section_count: u32 = @intCast(try std.fmt.parseInt(i64, max_sections_str, 10));

        const b_per_section_str = try view.getProperty("LinearShuntCompensator.bPerSection") orelse "0.0";
        const b_per_section = try std.fmt.parseFloat(f64, b_per_section_str);

        const g_per_section_str = try view.getProperty("LinearShuntCompensator.gPerSection") orelse "0.0";
        const g_per_section = try std.fmt.parseFloat(f64, g_per_section_str);

        const control_enabled_str = try view.getProperty("RegulatingCondEq.controlEnabled") orelse "false";
        const voltage_regulator_on = std.mem.eql(u8, control_enabled_str, "true");

        // RegulatingControl: resolve RC mRID for targetV, targetDeadband (SSH), regulatingTerminal, and properties.
        var target_v: ?f64 = null;
        var target_deadband: ?f64 = null;
        var rc_mrid: ?[]const u8 = null;
        var regulating_terminal: ?[]const u8 = null;
        if (try eq_view.getReference("RegulatingCondEq.RegulatingControl")) |rc_ref| {
            const rc_id = strip_hash(rc_ref);
            if (model.getObjectById(rc_id)) |rc_view| {
                rc_mrid = try rc_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(rc_id);
                // Resolve regulatingTerminal: RC.Terminal → CN → reachable BBS mRID.
                // Skip if RC terminal is on the shunt itself (local regulation → null).
                if (try rc_view.getReference("RegulatingControl.Terminal")) |rt_ref| {
                    const rt_id = strip_hash(rt_ref);
                    const rt_equipment = index.terminal_equipment.get(rt_id) orelse "";
                    const is_local = std.mem.eql(u8, rt_equipment, shunt.id);
                    if (!is_local) {
                        if (index.terminal_conn_node.get(rt_id)) |conn_node_id| {
                            regulating_terminal = index.conn_node_reachable_busbar_section.get(conn_node_id);
                        }
                    }
                }
            }
            if (rc_mrid) |rm| {
                if (ssh_opt) |ssh| {
                    if (try ssh.getProperty(rm, "RegulatingControl.targetValue")) |v|
                        target_v = std.fmt.parseFloat(f64, v) catch null;
                    if (try ssh.getProperty(rm, "RegulatingControl.targetDeadband")) |v|
                        target_deadband = std.fmt.parseFloat(f64, v) catch null;
                }
            }
        }

        // normalSections: EQ attribute, emitted as CGMES.normalSections property.
        const normal_sections_str = try eq_view.getProperty("ShuntCompensator.normalSections");

        var props: std.ArrayListUnmanaged(iidm.Property) = .empty;
        const prop_count: usize = (if (rc_mrid != null) @as(usize, 1) else 0) +
            (if (normal_sections_str != null) @as(usize, 1) else 0);
        if (prop_count > 0) {
            try props.ensureTotalCapacity(gpa, prop_count);
            if (rc_mrid) |rm| props.appendAssumeCapacity(.{ .name = "CGMES.RegulatingControl", .value = rm });
            if (normal_sections_str) |ns| props.appendAssumeCapacity(.{ .name = "CGMES.normalSections", .value = ns });
        }

        assert(mrid.len > 0);
        voltage_level.shunts.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .section_count = section_count,
            .voltage_regulator_on = voltage_regulator_on,
            .target_v = target_v,
            .target_deadband = target_deadband,
            .regulating_terminal = regulating_terminal,
            .node = node,
            .shunt_linear_model = .{
                .b_per_section = b_per_section,
                .g_per_section = g_per_section,
                .max_section_count = max_section_count,
            },
            .aliases = .empty,
            .properties = props,
        });
    }
}

pub fn convert_static_var_compensators(
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
    ssh_opt: ?CimSsh,
) !void {
    const static_var_compensators = model.get_objects_by_type("StaticVarCompensator");
    assert(static_var_compensators.len == 0 or voltage_level_map.count() > 0);

    for (static_var_compensators) |static_var_compensator| {
        const eq_view = model.view(static_var_compensator);
        const placement = resolve_equipment_placement(index, voltage_level_map, node_map, static_var_compensator.id) orelse continue;
        const voltage_level = placement.voltage_level;
        const node = placement.node;

        const mrid = try eq_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(static_var_compensator.id);
        const view = CimMergedView.init(eq_view, mrid, ssh_opt);
        const name = try view.getProperty("IdentifiedObject.name");

        const b_min_str = try view.getProperty("StaticVarCompensator.bMin") orelse "0.0";
        const b_min = try std.fmt.parseFloat(f64, b_min_str);

        const b_max_str = try view.getProperty("StaticVarCompensator.bMax") orelse "0.0";
        const b_max = try std.fmt.parseFloat(f64, b_max_str);

        const control_enabled_str = try view.getProperty("RegulatingCondEq.controlEnabled") orelse "false";
        const regulating = std.mem.eql(u8, control_enabled_str, "true");

        const regulation_mode_ref = try view.getReference("StaticVarCompensator.regulationMode");
        const regulation_mode: iidm.SvcRegulationMode = blk: {
            const ref = regulation_mode_ref orelse break :blk .off;
            if (std.mem.endsWith(u8, ref, "voltage")) break :blk .voltage;
            if (std.mem.endsWith(u8, ref, "reactivePower")) break :blk .reactive_power;
            break :blk .off;
        };

        assert(mrid.len > 0);
        voltage_level.static_var_compensators.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .b_min = b_min,
            .b_max = b_max,
            .regulation_mode = regulation_mode,
            .regulating = regulating,
            .node = node,
            .aliases = .empty,
            .properties = .empty,
        });
    }
}

fn energy_source_from_cim_type(type_name: []const u8) iidm.EnergySource {
    if (std.mem.eql(u8, type_name, "HydroGeneratingUnit")) return .hydro;
    if (std.mem.eql(u8, type_name, "ThermalGeneratingUnit")) return .thermal;
    if (std.mem.eql(u8, type_name, "WindGeneratingUnit")) return .wind;
    if (std.mem.eql(u8, type_name, "SolarGeneratingUnit")) return .solar;
    if (std.mem.eql(u8, type_name, "NuclearGeneratingUnit")) return .nuclear;
    return .other;
}

pub fn convert_generators(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
    ssh_opt: ?CimSsh,
) !void {
    const machines = model.get_objects_by_type("SynchronousMachine");
    assert(machines.len == 0 or voltage_level_map.count() > 0);

    // Build ThermalGeneratingUnit ID → fuel type fragment map from FossilFuel objects.
    // FossilFuel.ThermalGeneratingUnit → unit raw ID; FossilFuel.fossilFuelType → enum URL.
    var fuel_type_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer fuel_type_map.deinit(gpa);
    {
        const fossil_fuels = model.get_objects_by_type("FossilFuel");
        try fuel_type_map.ensureTotalCapacity(gpa, @intCast(fossil_fuels.len));
        for (fossil_fuels) |fossil_fuel| {
            const fossil_fuel_view = model.view(fossil_fuel);
            const unit_ref = try fossil_fuel_view.getReference("FossilFuel.ThermalGeneratingUnit") orelse continue;
            const unit_id = strip_hash(unit_ref);
            const ft_ref = try fossil_fuel_view.getReference("FossilFuel.fossilFuelType") orelse continue;
            // Extract enum fragment part after last '#', then after last '.'.
            const h = std.mem.lastIndexOfScalar(u8, ft_ref, '#') orelse continue;
            const frag = ft_ref[h + 1 ..];
            const dot = std.mem.lastIndexOfScalar(u8, frag, '.') orelse continue;
            const ft_frag = frag[dot + 1 ..];
            fuel_type_map.putAssumeCapacity(unit_id, ft_frag);
        }
    }

    for (machines) |machine| {
        const placement = resolve_equipment_placement(index, voltage_level_map, node_map, machine.id) orelse continue;
        const voltage_level = placement.voltage_level;
        const node = placement.node;

        // Resolve mRID first (needed for merged view lookup), then build merged view.
        // All subsequent attribute reads go through view — SSH values shadow EQ values.
        const eq_view = model.view(machine);
        const mrid = try eq_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(machine.id);
        const view = CimMergedView.init(eq_view, mrid, ssh_opt);

        const name = try view.getProperty("IdentifiedObject.name");

        const rated_s: ?f64 = blk: {
            const s = try view.getProperty("RotatingMachine.ratedS") orelse break :blk null;
            break :blk try std.fmt.parseFloat(f64, s);
        };

        const control_enabled_str = try view.getProperty("RegulatingCondEq.controlEnabled") orelse "false";
        const voltage_regulator_on = std.mem.eql(u8, control_enabled_str, "true");

        // isCondenser is a capability flag from EQ (can this machine act as a condenser?).
        // It is true if EQ SynchronousMachine.type contains "condenser" (either "condenser"
        // or "generatorOrCondenser"). SSH operatingMode does not affect this flag.
        const type_ref = try eq_view.getReference("SynchronousMachine.type") orelse "";
        const is_condenser = std.mem.indexOf(u8, type_ref, "ondenser") != null;
        // Extract "kind value" from a CIM enum URL: part after the last '.' in the fragment.
        // e.g. "http://...#SynchronousMachineKind.generatorOrCondenser" → "generatorOrCondenser"
        const type_fragment: ?[]const u8 = blk: {
            const h = std.mem.lastIndexOfScalar(u8, type_ref, '#') orelse break :blk null;
            const frag = type_ref[h + 1 ..];
            const dot = std.mem.lastIndexOfScalar(u8, frag, '.') orelse break :blk frag;
            break :blk frag[dot + 1 ..];
        };

        // Resolve GeneratingUnit for min_p, max_p, energy source, GeneratingUnit mRID, wind type,
        // and SSH normalPF (used for activePowerControl extension).
        var min_p: ?f64 = null;
        var max_p: ?f64 = null;
        var energy_source: iidm.EnergySource = .other;
        var unit_mrid: ?[]const u8 = null;
        var wind_unit_type: ?[]const u8 = null;
        var fuel_type: ?[]const u8 = null;
        var participation_factor: ?f64 = null;
        if (try view.getReference("RotatingMachine.GeneratingUnit")) |unit_ref| {
            const unit_id = strip_hash(unit_ref);
            if (model.getObjectById(unit_id)) |unit| {
                energy_source = energy_source_from_cim_type(unit.type_name);
                if (try unit.getProperty("GeneratingUnit.minOperatingP")) |v|
                    min_p = try std.fmt.parseFloat(f64, v);
                if (try unit.getProperty("GeneratingUnit.maxOperatingP")) |v|
                    max_p = try std.fmt.parseFloat(f64, v);
                unit_mrid = try unit.getProperty("IdentifiedObject.mRID") orelse strip_underscore(unit_id);
                // WindGeneratingUnit: extract windGenUnitType kind value.
                if (std.mem.eql(u8, unit.type_name, "WindGeneratingUnit")) {
                    if (try unit.getReference("WindGeneratingUnit.windGenUnitType")) |wt_ref| {
                        const wt_frag = blk: {
                            const h = std.mem.lastIndexOfScalar(u8, wt_ref, '#') orelse break :blk wt_ref;
                            const frag = wt_ref[h + 1 ..];
                            const dot = std.mem.lastIndexOfScalar(u8, frag, '.') orelse break :blk frag;
                            break :blk frag[dot + 1 ..];
                        };
                        wind_unit_type = wt_frag;
                    }
                }
                // ThermalGeneratingUnit: look up fuel type from FossilFuel inverse map.
                fuel_type = fuel_type_map.get(unit_id);
                // SSH GeneratingUnit.normalPF → activePowerControl participationFactor.
                if (ssh_opt) |ssh| {
                    const gu_mrid = unit_mrid orelse strip_underscore(unit_id);
                    if (try ssh.getProperty(gu_mrid, "GeneratingUnit.normalPF")) |v|
                        participation_factor = std.fmt.parseFloat(f64, v) catch null;
                }
            }
        }

        // Resolve reactive capability curve or min/max Q limits.
        var curve_points: std.ArrayListUnmanaged(iidm.ReactiveCapabilityCurvePoint) = .empty;
        var min_max_reactive_limits: ?iidm.MinMaxReactiveLimits = null;

        if (try view.getReference("SynchronousMachine.InitialReactiveCapabilityCurve")) |curve_ref| {
            if (index.curve_points.get(strip_hash(curve_ref))) |points| {
                try curve_points.appendSlice(gpa, points.items);
            }
        }

        if (curve_points.items.len == 0) {
            const min_q: ?f64 = if (try view.getProperty("SynchronousMachine.minQ")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                null;
            const max_q: ?f64 = if (try view.getProperty("SynchronousMachine.maxQ")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                null;
            if (min_q != null and max_q != null) {
                min_max_reactive_limits = .{ .min_q = min_q.?, .max_q = max_q.? };
            }
        }

        // Resolve regulatingTerminal, CGMES.RegulatingControl mRID, CGMES.mode, and targetV.
        var regulating_terminal: ?[]const u8 = null;
        var rc_mrid: ?[]const u8 = null;
        var rc_mode_lower: ?[]u8 = null;
        var target_v: ?f64 = null;
        if (try view.getReference("RegulatingCondEq.RegulatingControl")) |rc_ref| {
            const rc_id = strip_hash(rc_ref);
            if (model.getObjectById(rc_id)) |rc| {
                rc_mrid = try rc.getProperty("IdentifiedObject.mRID") orelse strip_underscore(rc_id);
                // SSH RegulatingControl.targetValue → IIDM targetV.
                if (rc_mrid) |rm| {
                    if (ssh_opt) |ssh| {
                        if (try ssh.getProperty(rm, "RegulatingControl.targetValue")) |v|
                            target_v = std.fmt.parseFloat(f64, v) catch null;
                    }
                }
                // CGMES.mode: full URL of RegulatingControl.mode, lowercased.
                if (try rc.getReference("RegulatingControl.mode")) |mode_ref| {
                    rc_mode_lower = try gpa.alloc(u8, mode_ref.len);
                    _ = std.ascii.lowerString(rc_mode_lower.?, mode_ref);
                }
                if (try rc.getReference("RegulatingControl.Terminal")) |rt_ref| {
                    const rt_id = strip_hash(rt_ref);
                    const rt_eq = index.terminal_equipment.get(rt_id) orelse "";
                    // If RC terminal is on this machine → local regulation (null).
                    if (!std.mem.eql(u8, rt_eq, machine.id)) {
                        const rt_conn_node = index.terminal_conn_node.get(rt_id);
                        if (rt_conn_node) |conn_node_id| {
                            regulating_terminal = index.conn_node_reachable_busbar_section.get(conn_node_id);
                        }
                    }
                }
            }
        }
        // alias: CGMES.Terminal1 = terminal mRID
        var gen_aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
        errdefer gen_aliases.deinit(gpa);
        if (index.equipment_terminals.get(machine.id)) |terminals| {
            if (terminals.items.len > 0) {
                const t_mrid = strip_underscore(terminals.items[0].id);
                try gen_aliases.ensureTotalCapacity(gpa, 1);
                gen_aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal1" }, .content = t_mrid });
            }
        }

        // properties in pypow order:
        //   fuelType, synchronousMachineType, mode, originalClass, GeneratingUnit,
        //   RegulatingControl, windGenUnitType
        var gen_props: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer gen_props.deinit(gpa);
        try gen_props.ensureTotalCapacity(gpa, 7);
        if (fuel_type) |ft| gen_props.appendAssumeCapacity(.{ .name = "CGMES.fuelType", .value = ft });
        if (type_fragment) |tf| gen_props.appendAssumeCapacity(.{ .name = "CGMES.synchronousMachineType", .value = tf });
        if (rc_mode_lower) |ml| gen_props.appendAssumeCapacity(.{ .name = "CGMES.mode", .value = ml, .owned_value = true });
        gen_props.appendAssumeCapacity(.{ .name = "CGMES.originalClass", .value = "SynchronousMachine" });
        if (unit_mrid) |um| gen_props.appendAssumeCapacity(.{ .name = "CGMES.GeneratingUnit", .value = um });
        if (rc_mrid) |rm| gen_props.appendAssumeCapacity(.{ .name = "CGMES.RegulatingControl", .value = rm });
        if (wind_unit_type) |wt| gen_props.appendAssumeCapacity(.{ .name = "CGMES.windGenUnitType", .value = wt });

        // SSH RotatingMachine.p/q are in load convention (negative = generating).
        // IIDM targetP/targetQ use generator convention (positive = generating) → negate.
        const target_p: ?f64 = if (try view.getProperty("RotatingMachine.p")) |v|
            -(try std.fmt.parseFloat(f64, v))
        else
            null;
        const target_q: ?f64 = if (try view.getProperty("RotatingMachine.q")) |v|
            -(try std.fmt.parseFloat(f64, v))
        else
            null;

        const q_percent: ?f64 = blk: {
            const v = try view.getProperty("SynchronousMachine.qPercent") orelse break :blk null;
            break :blk std.fmt.parseFloat(f64, std.mem.trim(u8, v, " \t\r\n")) catch null;
        };

        assert(mrid.len > 0);
        voltage_level.generators.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .energy_source = energy_source,
            .min_p = min_p,
            .max_p = max_p,
            .rated_s = rated_s,
            .target_p = target_p,
            .target_q = target_q,
            .is_condenser = is_condenser,
            .voltage_regulator_on = voltage_regulator_on,
            .target_v = target_v,
            .node = node,
            .reactive_capability_curve_points = curve_points,
            .min_max_reactive_limits = min_max_reactive_limits,
            .regulating_terminal = regulating_terminal,
            .participation_factor = participation_factor,
            .q_percent = q_percent,
            .aliases = gen_aliases,
            .properties = gen_props,
        });
        gen_aliases = .empty; // ownership transferred
        gen_props = .empty; // ownership transferred
    }
}

test "energy_source_from_cim_type: all known types map correctly" {
    const iidm_mod = @import("../iidm.zig");
    try std.testing.expectEqual(iidm_mod.EnergySource.hydro, energy_source_from_cim_type("HydroGeneratingUnit"));
    try std.testing.expectEqual(iidm_mod.EnergySource.thermal, energy_source_from_cim_type("ThermalGeneratingUnit"));
    try std.testing.expectEqual(iidm_mod.EnergySource.wind, energy_source_from_cim_type("WindGeneratingUnit"));
    try std.testing.expectEqual(iidm_mod.EnergySource.solar, energy_source_from_cim_type("SolarGeneratingUnit"));
    try std.testing.expectEqual(iidm_mod.EnergySource.nuclear, energy_source_from_cim_type("NuclearGeneratingUnit"));
    try std.testing.expectEqual(iidm_mod.EnergySource.other, energy_source_from_cim_type("UnknownGeneratingUnit"));
    try std.testing.expectEqual(iidm_mod.EnergySource.other, energy_source_from_cim_type(""));
}
