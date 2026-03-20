const std = @import("std");
const iidm = @import("../iidm.zig");
const cim_model = @import("../cim_model.zig");
const cim_index = @import("../cim_index.zig");
const tag_index = @import("../tag_index.zig");
const utils = @import("../utils.zig");

const assert = std.debug.assert;
const get_switch_slices = cim_index.get_switch_slices;

const CimModel = cim_model.CimModel;
const CimObject = tag_index.CimObject;
const CimIndex = cim_index.CimIndex;
const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

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

const EquipmentPlacement = struct {
    voltage_level: *iidm.VoltageLevel,
    conn_node_id: []const u8,
};

/// Resolve the target VoltageLevel pointer and first ConnectivityNode ID for a
/// single-terminal equipment object. Returns null if any step in the chain fails.
fn resolve_equipment_placement(
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    equipment_id: []const u8,
) ?EquipmentPlacement {
    const terminals = index.equipment_terminals.get(equipment_id) orelse return null;
    const conn_node_id = terminals.items[0].conn_node_id orelse return null;
    const container_id = index.conn_node_container.get(conn_node_id) orelse return null;
    const repr_vl_id = cim_index.find_voltage_level(&index.voltage_level_merge, container_id);
    const voltage_level = voltage_level_map.get(repr_vl_id) orelse return null;
    return .{ .voltage_level = voltage_level, .conn_node_id = conn_node_id };
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
    for (model.getObjectsByType(cim_type)) |obj| {
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
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const std.StringHashMapUnmanaged(u32),
) !void {
    const busbar_sections = model.getObjectsByType("BusbarSection");

    for (busbar_sections) |busbar_section| {
        const placement = resolve_equipment_placement(index, voltage_level_map, busbar_section.id) orelse continue;
        const voltage_level = placement.voltage_level;
        const node = node_map.get(placement.conn_node_id) orelse continue;

        const mrid = try busbar_section.getProperty("IdentifiedObject.mRID") orelse strip_underscore(busbar_section.id);
        const name = try busbar_section.getProperty("IdentifiedObject.name");
        voltage_level.node_breaker_topology.busbar_sections.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .node = node,
            .aliases = .empty,
        });
    }
}

pub fn convert_switches(
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const std.StringHashMapUnmanaged(u32),
) !void {
    const switch_slices = get_switch_slices(model);

    for (switch_slices) |switch_slice| {
        for (switch_slice) |sw| {
            const terminals = index.equipment_terminals.get(sw.id) orelse continue;

            if (terminals.items.len < 2) continue;

            const conn_node0_id = terminals.items[0].conn_node_id orelse continue;
            const conn_node1_id = terminals.items[1].conn_node_id orelse continue;

            const node0 = node_map.get(conn_node0_id) orelse continue;
            const node1 = node_map.get(conn_node1_id) orelse continue;

            const container0_id = index.conn_node_container.get(conn_node0_id) orelse continue;

            const repr_voltage_level_id = cim_index.find_voltage_level(&index.voltage_level_merge, container0_id);
            const voltage_level = voltage_level_map.get(repr_voltage_level_id) orelse continue;

            const mrid = try sw.getProperty("IdentifiedObject.mRID") orelse strip_underscore(sw.id);
            const name = try sw.getProperty("IdentifiedObject.name");

            const open_str = try sw.getProperty("Switch.open") orelse "false";
            const open = std.mem.eql(u8, open_str, "true");
            const retained_str = try sw.getProperty("Switch.retained") orelse "false";
            const retained = std.mem.eql(u8, retained_str, "true");

            const kind = iidm.SwitchKind.from_cim_type(sw.type_name);

            voltage_level.node_breaker_topology.switches.appendAssumeCapacity(.{
                .id = mrid,
                .name = name,
                .kind = kind,
                .retained = retained,
                .open = open,
                .node1 = node0,
                .node2 = node1,
                .aliases = .empty,
                .properties = .empty,
            });
        }
    }
}

pub fn convert_loads(
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const std.StringHashMapUnmanaged(u32),
) !void {
    const energy_consumers = model.getObjectsByType("EnergyConsumer");
    const conform_loads = model.getObjectsByType("ConformLoad");
    const non_conform_loads = model.getObjectsByType("NonConformLoad");

    try convert_load_type(index, voltage_level_map, node_map, energy_consumers);
    try convert_load_type(index, voltage_level_map, node_map, conform_loads);
    try convert_load_type(index, voltage_level_map, node_map, non_conform_loads);
}

fn convert_load_type(
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const std.StringHashMapUnmanaged(u32),
    loads: []const CimObject,
) !void {
    for (loads) |load| {
        const placement = resolve_equipment_placement(index, voltage_level_map, load.id) orelse continue;
        const voltage_level = placement.voltage_level;
        const node = node_map.get(placement.conn_node_id) orelse continue;

        const mrid = try load.getProperty("IdentifiedObject.mRID") orelse strip_underscore(load.id);
        const name = try load.getProperty("IdentifiedObject.name");
        voltage_level.loads.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .load_type = .other,
            .node = node,
            .aliases = .empty,
            .properties = .empty,
        });
    }
}

pub fn convert_shunts(
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const std.StringHashMapUnmanaged(u32),
) !void {
    const shunts = model.getObjectsByType("LinearShuntCompensator");
    assert(shunts.len == 0 or voltage_level_map.count() > 0);

    for (shunts) |shunt| {
        const placement = resolve_equipment_placement(index, voltage_level_map, shunt.id) orelse continue;
        const voltage_level = placement.voltage_level;
        const node = node_map.get(placement.conn_node_id) orelse continue;

        const mrid = try shunt.getProperty("IdentifiedObject.mRID") orelse strip_underscore(shunt.id);
        const name = try shunt.getProperty("IdentifiedObject.name");

        const sections_str = try shunt.getProperty("ShuntCompensator.sections") orelse "0";
        const section_count: u32 = @intCast(try std.fmt.parseInt(i64, sections_str, 10));

        const max_sections_str = try shunt.getProperty("ShuntCompensator.maximumSections") orelse "0";
        const max_section_count: u32 = @intCast(try std.fmt.parseInt(i64, max_sections_str, 10));

        const b_per_section_str = try shunt.getProperty("LinearShuntCompensator.bPerSection") orelse "0.0";
        const b_per_section = try std.fmt.parseFloat(f64, b_per_section_str);

        const g_per_section_str = try shunt.getProperty("LinearShuntCompensator.gPerSection") orelse "0.0";
        const g_per_section = try std.fmt.parseFloat(f64, g_per_section_str);

        const control_enabled_str = try shunt.getProperty("RegulatingCondEq.controlEnabled") orelse "false";
        const voltage_regulator_on = std.mem.eql(u8, control_enabled_str, "true");

        assert(mrid.len > 0);
        voltage_level.shunts.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .section_count = section_count,
            .voltage_regulator_on = voltage_regulator_on,
            .node = node,
            .shunt_linear_model = .{
                .b_per_section = b_per_section,
                .g_per_section = g_per_section,
                .max_section_count = max_section_count,
            },
            .aliases = .empty,
            .properties = .empty,
        });
    }
}

pub fn convert_static_var_compensators(
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const std.StringHashMapUnmanaged(u32),
) !void {
    const static_var_compensators = model.getObjectsByType("StaticVarCompensator");
    assert(static_var_compensators.len == 0 or voltage_level_map.count() > 0);

    for (static_var_compensators) |static_var_compensator| {
        const placement = resolve_equipment_placement(index, voltage_level_map, static_var_compensator.id) orelse continue;
        const voltage_level = placement.voltage_level;
        const node = node_map.get(placement.conn_node_id) orelse continue;

        const mrid = try static_var_compensator.getProperty("IdentifiedObject.mRID") orelse strip_underscore(static_var_compensator.id);
        const name = try static_var_compensator.getProperty("IdentifiedObject.name");

        const b_min_str = try static_var_compensator.getProperty("StaticVarCompensator.bMin") orelse "0.0";
        const b_min = try std.fmt.parseFloat(f64, b_min_str);

        const b_max_str = try static_var_compensator.getProperty("StaticVarCompensator.bMax") orelse "0.0";
        const b_max = try std.fmt.parseFloat(f64, b_max_str);

        const control_enabled_str = try static_var_compensator.getProperty("RegulatingCondEq.controlEnabled") orelse "false";
        const regulating = std.mem.eql(u8, control_enabled_str, "true");

        const regulation_mode_ref = try static_var_compensator.getReference("StaticVarCompensator.regulationMode");
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
    node_map: *const std.StringHashMapUnmanaged(u32),
) !void {
    const machines = model.getObjectsByType("SynchronousMachine");
    assert(machines.len == 0 or voltage_level_map.count() > 0);

    for (machines) |machine| {
        const placement = resolve_equipment_placement(index, voltage_level_map, machine.id) orelse continue;
        const voltage_level = placement.voltage_level;
        const node = node_map.get(placement.conn_node_id) orelse continue;

        const mrid = try machine.getProperty("IdentifiedObject.mRID") orelse strip_underscore(machine.id);
        const name = try machine.getProperty("IdentifiedObject.name");

        const rated_s: ?f64 = blk: {
            const s = try machine.getProperty("RotatingMachine.ratedS") orelse break :blk null;
            break :blk try std.fmt.parseFloat(f64, s);
        };

        const control_enabled_str = try machine.getProperty("RegulatingCondEq.controlEnabled") orelse "false";
        const voltage_regulator_on = std.mem.eql(u8, control_enabled_str, "true");

        const type_str = try machine.getProperty("SynchronousMachine.type") orelse "";
        const is_condenser = std.mem.indexOf(u8, type_str, "condenser") != null;

        // Resolve GeneratingUnit for min_p, max_p, and energy source.
        var min_p: ?f64 = null;
        var max_p: ?f64 = null;
        var energy_source: iidm.EnergySource = .other;
        if (try machine.getReference("RotatingMachine.GeneratingUnit")) |unit_ref| {
            if (model.getObjectById(strip_hash(unit_ref))) |unit| {
                energy_source = energy_source_from_cim_type(unit.type_name);
                if (try unit.getProperty("GeneratingUnit.minOperatingP")) |v|
                    min_p = try std.fmt.parseFloat(f64, v);
                if (try unit.getProperty("GeneratingUnit.maxOperatingP")) |v|
                    max_p = try std.fmt.parseFloat(f64, v);
            }
        }

        // Resolve reactive capability curve or min/max Q limits.
        var curve_points: std.ArrayListUnmanaged(iidm.ReactiveCapabilityCurvePoint) = .empty;
        var min_max_reactive_limits: ?iidm.MinMaxReactiveLimits = null;

        if (try machine.getReference("SynchronousMachine.InitialReactiveCapabilityCurve")) |curve_ref| {
            if (index.curve_points.get(strip_hash(curve_ref))) |points| {
                try curve_points.appendSlice(gpa, points.items);
            }
        }

        if (curve_points.items.len == 0) {
            const min_q: ?f64 = if (try machine.getProperty("SynchronousMachine.minQ")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                null;
            const max_q: ?f64 = if (try machine.getProperty("SynchronousMachine.maxQ")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                null;
            if (min_q != null and max_q != null) {
                min_max_reactive_limits = .{ .min_q = min_q.?, .max_q = max_q.? };
            }
        }

        assert(mrid.len > 0);
        voltage_level.generators.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .energy_source = energy_source,
            .min_p = min_p,
            .max_p = max_p,
            .rated_s = rated_s,
            .is_condenser = is_condenser,
            .voltage_regulator_on = voltage_regulator_on,
            .node = node,
            .reactive_capability_curve_points = curve_points,
            .min_max_reactive_limits = min_max_reactive_limits,
            .aliases = .empty,
            .properties = .empty,
        });
    }
}
