const std = @import("std");
const iidm = @import("../iidm.zig");
const cim_model = @import("../cim_model.zig");
const cim_index = @import("../cim_index.zig");
const tag_index = @import("../tag_index.zig");
const utils = @import("../utils.zig");

const assert = std.debug.assert;

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
fn resolve_repr_voltage_level_id(
    index: *const CimIndex,
    equipment_id: []const u8,
) ?[]const u8 {
    const terminals = index.equipment_terminals.get(equipment_id) orelse return null;
    const conn_node_id = terminals.items[0].conn_node_id orelse return null;
    const container_id = index.conn_node_container.get(conn_node_id) orelse return null;
    return cim_index.find_voltage_level(&index.voltage_level_merge, container_id);
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
        const terminals = index.equipment_terminals.get(busbar_section.id) orelse continue;
        const conn_node_id = terminals.items[0].conn_node_id orelse continue;
        const container_id = index.conn_node_container.get(conn_node_id) orelse continue;
        const repr_voltage_level_id = cim_index.find_voltage_level(&index.voltage_level_merge, container_id);
        const voltage_level = voltage_level_map.get(repr_voltage_level_id) orelse continue;

        const mrid = try busbar_section.getProperty("IdentifiedObject.mRID") orelse strip_underscore(busbar_section.id);
        const name = try busbar_section.getProperty("IdentifiedObject.name");
        const node = node_map.get(conn_node_id) orelse continue;
        voltage_level.node_breaker_topology.busbar_sections.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .node = node,
            .aliases = .empty,
        });
    }
}
