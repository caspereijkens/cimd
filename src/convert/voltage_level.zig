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
fn resolve_nominal_voltageoltage(model: *const CimModel, voltage_level: CimObject) !?f64 {
    const base_voltage_ref = try voltage_level.getReference("VoltageLevel.BaseVoltage") orelse return null;
    const base_voltage = model.getObjectById(strip_hash(base_voltage_ref)) orelse return null;
    const nominal_voltageoltage_str = try base_voltage.getProperty("BaseVoltage.nominalVoltage") orelse return null;
    return try std.fmt.parseFloat(f64, nominal_voltageoltage_str);
}

// Append one IIDM VoltageLevel to the Network. Assumes capacity has been pre-allocated.
// Records the voltage_level's index (and all its stub IDs) into substation_id_map.
// `repr_to_stub_mrids`: representative raw VL ID → list of absorbed stub mRIDs (for aliases).
fn append_voltage_level(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    voltage_level: CimObject,
    network: *iidm.Network,
    substation_id_map: *std.StringHashMapUnmanaged(usize),
    repr_to_stub_mrids: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
) !void {
    assert(std.mem.eql(u8, voltage_level.type_name, "VoltageLevel"));

    const mrid = try voltage_level.getProperty("IdentifiedObject.mRID") orelse strip_underscore(voltage_level.id);
    assert(mrid.len > 0);
    const name = try voltage_level.getProperty("IdentifiedObject.name");
    const nominal_voltageoltage = try resolve_nominal_voltageoltage(model, voltage_level);
    const limits = index.voltage_level_limits.get(voltage_level.id);

    // Build MergedVoltageLevel aliases for any stub VLs absorbed into this one.
    var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
    if (repr_to_stub_mrids.get(voltage_level.id)) |stubs| {
        assert(stubs.items.len > 0);
        try aliases.ensureTotalCapacity(gpa, stubs.items.len);
        for (stubs.items, 1..) |stub_mrid, n| {
            const alias_type = try std.fmt.allocPrint(gpa, "MergedVoltageLevel{d}", .{n});
            aliases.appendAssumeCapacity(.{ .type = alias_type, .content = stub_mrid });
        }
    }

    const substation_ref = try voltage_level.getReference("VoltageLevel.Substation") orelse return;
    const substation_idx = substation_id_map.get(strip_hash(substation_ref)) orelse return;
    network.substations.items[substation_idx].voltage_levels.appendAssumeCapacity(.{
        .id = mrid,
        .name = name,
        .nominal_voltageoltage = nominal_voltageoltage,
        .low_voltage_limit = if (limits) |lim| lim.low_value else null,
        .high_voltage_limit = if (limits) |lim| lim.high_value else null,
        .aliases = aliases,
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

    const voltage_levels = model.get_objects_by_type("VoltageLevel");

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

    // Build inverted VL merge map: representative raw ID → list of stub mRIDs.
    var repr_to_stub_mrids: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    defer {
        var it2 = repr_to_stub_mrids.valueIterator();
        while (it2.next()) |list| list.deinit(gpa);
        repr_to_stub_mrids.deinit(gpa);
    }
    {
        var it = index.voltage_level_merge.iterator();
        while (it.next()) |entry| {
            const stub_id = entry.key_ptr.*;
            const repr_id = entry.value_ptr.*;
            const stub_obj = model.getObjectById(stub_id) orelse continue;
            const stub_mrid = try stub_obj.getProperty("IdentifiedObject.mRID") orelse strip_underscore(stub_id);
            const gop = try repr_to_stub_mrids.getOrPut(gpa, repr_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(gpa, stub_mrid);
        }
    }

    // Second, create VoltageLevel objects.
    for (voltage_levels) |voltage_level| {
        if (index.voltage_level_merge.contains(voltage_level.id)) continue;
        try append_voltage_level(gpa, model, index, voltage_level, network, substation_id_map, &repr_to_stub_mrids);
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

    const voltage_levels = model.get_objects_by_type("VoltageLevel");
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
