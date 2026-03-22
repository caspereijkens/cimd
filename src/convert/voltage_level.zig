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

// Resolve the nominal voltage for a VoltageLevel.
// VoltageLevel.BaseVoltage -> BaseVoltage.nominalVoltage -> parseFloat.
fn resolve_nominal_voltage(model: *const CimModel, voltage_level: CimObject) !?f64 {
    const base_voltage_ref = try voltage_level.getReference("VoltageLevel.BaseVoltage") orelse return null;
    const base_voltage = model.getObjectById(strip_hash(base_voltage_ref)) orelse return null;
    const nominal_voltage_str = try base_voltage.getProperty("BaseVoltage.nominalVoltage") orelse return null;
    return try std.fmt.parseFloat(f64, nominal_voltage_str);
}

// Append one IIDM VoltageLevel to the Network. Assumes capacity has been pre-allocated.
// Records the voltage_level's index (and all its stub IDs) into substation_id_map.
fn append_voltage_level(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level: CimObject,
    network: *iidm.Network,
    substation_id_map: *std.StringHashMapUnmanaged(usize),
) !void {
    assert(std.mem.eql(u8, voltage_level.type_name, "VoltageLevel"));

    _ = gpa;

    const mrid = try voltage_level.getProperty("IdentifiedObject.mRID") orelse strip_underscore(voltage_level.id);
    assert(mrid.len > 0);
    const name = try voltage_level.getProperty("IdentifiedObject.name");
    const nominal_voltage = try resolve_nominal_voltage(model, voltage_level);
    const limits = index.voltage_level_limits.get(voltage_level.id);

    const substation_ref = try voltage_level.getReference("VoltageLevel.Substation") orelse return;
    const substation_idx = substation_id_map.get(strip_hash(substation_ref)) orelse return;
    network.substations.items[substation_idx].voltage_levels.appendAssumeCapacity(.{
        .id = mrid,
        .name = name,
        .nominal_voltage = nominal_voltage,
        .low_voltage_limit = if (limits) |lim| lim.low_value else null,
        .high_voltage_limit = if (limits) |lim| lim.high_value else null,
        .aliases = .empty,
        .properties = .empty,
        .node_breaker_topology = .{ .busbar_sections = .empty, .switches = .empty, .internal_connections = .empty },
        .generators = .empty,
        .loads = .empty,
        .shunts = .empty,
        .static_var_compensators = .empty,
        .vs_converter_stations = .empty,
        .lcc_converter_stations = .empty,
    });
}

pub fn convert_voltage_levels(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    network: *iidm.Network,
    substation_id_map: *std.StringHashMapUnmanaged(usize),
) !void {
    assert(network.substations.items.len > 0);

    const voltage_levels = model.getObjectsByType("VoltageLevel");

    // First, count non-stub VLs per substation for pre-allocation.
    const voltage_level_counts = try gpa.alloc(usize, network.substations.items.len);
    defer gpa.free(voltage_level_counts);
    @memset(voltage_level_counts, 0);

    for (voltage_levels) |voltage_level| {
        if (index.voltage_level_merge.contains(voltage_level.id)) continue;
        const substation_ref = try voltage_level.getReference("VoltageLevel.Substation") orelse continue;
        const substation_idx = substation_id_map.get(strip_hash(substation_ref)) orelse continue;
        voltage_level_counts[substation_idx] += 1;
    }

    for (network.substations.items, voltage_level_counts) |*substation, count| {
        try substation.voltage_levels.ensureTotalCapacity(gpa, count);
    }

    // Second, create VoltageLevel objects.
    for (voltage_levels) |voltage_level| {
        if (index.voltage_level_merge.contains(voltage_level.id)) continue;
        try append_voltage_level(gpa, model, index, voltage_level, network, substation_id_map);
    }

    assert(voltage_levels.len - index.voltage_level_merge.count() == blk: {
        var total: usize = 0;
        for (network.substations.items) |substation| total += substation.voltage_levels.items.len;
        break :blk total;
    });
}

pub fn build_voltage_level_map(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    network: *iidm.Network,
    substation_id_map: *const std.StringHashMapUnmanaged(usize),
    substation_map: *std.StringHashMapUnmanaged(*iidm.Substation),
) !std.StringHashMapUnmanaged(*iidm.VoltageLevel) {
    assert(network.substations.items.len > 0);

    const voltage_levels = model.getObjectsByType("VoltageLevel");
    const representative_count = voltage_levels.len - index.voltage_level_merge.count();

    var voltage_level_map: std.StringHashMapUnmanaged(*iidm.VoltageLevel) = .empty;
    try voltage_level_map.ensureTotalCapacity(gpa, @intCast(representative_count));

    try substation_map.ensureTotalCapacity(gpa, @intCast(representative_count));

    const voltage_level_counters = try gpa.alloc(usize, network.substations.items.len);
    defer gpa.free(voltage_level_counters);
    @memset(voltage_level_counters, 0);

    for (voltage_levels) |voltage_level| {
        if (index.voltage_level_merge.contains(voltage_level.id)) continue;
        const substation_ref = try voltage_level.getReference("VoltageLevel.Substation") orelse continue;
        const substation_idx = substation_id_map.get(strip_hash(substation_ref)) orelse continue;
        substation_map.putAssumeCapacity(voltage_level.id, &network.substations.items[substation_idx]);

        const voltage_level_idx = voltage_level_counters[substation_idx];
        voltage_level_counters[substation_idx] += 1;
        voltage_level_map.putAssumeCapacity(voltage_level.id, &network.substations.items[substation_idx].voltage_levels.items[voltage_level_idx]);
    }

    assert(voltage_level_map.count() == representative_count);

    return voltage_level_map;
}
