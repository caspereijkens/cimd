const std = @import("std");
const cim = @import("../cim/cim.zig");
const iidm = @import("../iidm/model.zig");
const CimDocument = cim.CimDocument;
const cross_ref = @import("../topology/cross_ref.zig");
const utils = cim.ids;
const resolve = @import("../topology/resolve.zig");
const substation_conv = @import("substation.zig");
const parse = cim.parse;

const assert = std.debug.assert;
const Topology = resolve.Topology;
const SubstationIndex = substation_conv.SubstationIndex;

const CimObject = cim.CimObject;
const CrossRef = cross_ref.CrossRef;
const strip_hash = utils.strip_hash;

// Resolve the nominal voltage for a VoltageLevel.
// VoltageLevel.BaseVoltage -> BaseVoltage.nominalVoltage -> parseFloat.
fn resolve_nominal_voltageoltage(model: *const CimDocument, voltage_level: CimObject) !?f64 {
    const base_voltage_ref = try voltage_level.reference("VoltageLevel.BaseVoltage") orelse return null;
    const base_voltage = model.object_by_id(strip_hash(base_voltage_ref)) orelse return null;
    const nominal_voltageoltage_str = try base_voltage.property("BaseVoltage.nominalVoltage") orelse return null;
    return try parse.float_req(nominal_voltageoltage_str);
}

// Append one IIDM VoltageLevel to the Network. Assumes capacity has been pre-allocated.
// Records the voltage_level's index (and all its stub IDs) into substation_id_map.
// `repr_to_stub_mrids`: representative raw VL ID → list of absorbed stub mRIDs (for aliases).
fn append_voltage_level(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    index: *const CrossRef,
    voltage_level: CimObject,
    network: *iidm.Network,
    substation_id_map: *std.StringHashMapUnmanaged(SubstationIndex),
    repr_to_stub_mrids: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
) !void {
    assert(std.mem.eql(u8, voltage_level.type_name(), "VoltageLevel"));

    const mrid = try voltage_level.mrid();
    assert(mrid.len > 0);
    const name = parse.non_blank(try voltage_level.property("IdentifiedObject.name"));
    const nominal_voltageoltage = try resolve_nominal_voltageoltage(model, voltage_level);
    const limits = index.voltage_level_limits.get(voltage_level.id());

    // Build MergedVoltageLevel aliases for any stub VLs absorbed into this one.
    var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
    var ownership_transferred = false;
    defer if (!ownership_transferred) aliases.deinit(gpa);
    if (repr_to_stub_mrids.get(voltage_level.id())) |stubs| {
        assert(stubs.items.len > 0);
        try aliases.ensureTotalCapacity(gpa, stubs.items.len);
        for (stubs.items, 1..) |stub_mrid, n| {
            aliases.appendAssumeCapacity(.{ .type_info = .{ .merged_voltage_level = @intCast(n) }, .content = stub_mrid });
        }
    }

    var properties = try build_voltage_limit_properties(gpa, limits);
    defer if (!ownership_transferred) deinit_properties(gpa, &properties);

    const substation_ref = try voltage_level.reference("VoltageLevel.Substation") orelse return;
    const substation_idx = substation_id_map.get(strip_hash(substation_ref)) orelse return;
    network.substations.items[@intCast(substation_idx)].voltage_levels.appendAssumeCapacity(.{
        .id = mrid,
        .name = name,
        .nominal_voltageoltage = nominal_voltageoltage,
        .low_voltage_limit = if (limits) |lim| lim.low_value else null,
        .high_voltage_limit = if (limits) |lim| lim.high_value else null,
        .aliases = aliases,
        .properties = properties,
        .node_breaker_topology = .{ .busbar_sections = .empty, .switches = .empty, .internal_connections = .empty },
        .generators = .empty,
        .loads = .empty,
        .shunts = .empty,
        .static_var_compensators = .empty,
        .vs_converter_stations = .empty,
        .lcc_converter_stations = .empty,
    });
    ownership_transferred = true;
}

fn deinit_properties(gpa: std.mem.Allocator, properties: *std.ArrayListUnmanaged(iidm.Property)) void {
    for (properties.items) |property| if (property.owned_value) gpa.free(property.value);
    properties.deinit(gpa);
}

// Build the CGMES voltage-limit properties for one VoltageLevel.
// pypowsybl emits normalValue and OperationalLimit (semicolon-joined mRIDs) for each side
// that has a limit. Property values are heap-allocated and flagged owned.
fn build_voltage_limit_properties(
    gpa: std.mem.Allocator,
    limits_opt: ?cross_ref.VoltageLimitInfo,
) !std.ArrayListUnmanaged(iidm.Property) {
    var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
    errdefer deinit_properties(gpa, &properties);

    const has_high = if (limits_opt) |lim| lim.high_mrids.items.len > 0 else false;
    const has_low = if (limits_opt) |lim| lim.low_mrids.items.len > 0 else false;

    const max_entries: usize =
        @as(usize, if (has_high) 2 else 0) +
        @as(usize, if (has_low) 2 else 0);
    try properties.ensureTotalCapacity(gpa, max_entries);

    if (has_high) {
        const limits = limits_opt.?;
        const normal_value = try iidm.format_float(gpa, limits.high_value orelse unreachable);
        properties.appendAssumeCapacity(.{
            .name = "CGMES.normalValue_highVoltageLimit",
            .value = normal_value,
            .owned_value = true,
        });
        const joined = try std.mem.join(gpa, ";", limits.high_mrids.items);
        properties.appendAssumeCapacity(.{
            .name = "CGMES.OperationalLimit_highVoltageLimit",
            .value = joined,
            .owned_value = true,
        });
    }
    if (has_low) {
        const limits = limits_opt.?;
        const normal_value = try iidm.format_float(gpa, limits.low_value orelse unreachable);
        properties.appendAssumeCapacity(.{
            .name = "CGMES.normalValue_lowVoltageLimit",
            .value = normal_value,
            .owned_value = true,
        });
        const joined = try std.mem.join(gpa, ";", limits.low_mrids.items);
        properties.appendAssumeCapacity(.{
            .name = "CGMES.OperationalLimit_lowVoltageLimit",
            .value = joined,
            .owned_value = true,
        });
    }
    return properties;
}

pub fn convert_voltage_levels(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    index: *const CrossRef,
    topology: *const Topology,
    network: *iidm.Network,
    substation_id_map: *std.StringHashMapUnmanaged(SubstationIndex),
) !void {
    assert(network.substations.items.len > 0);

    const voltage_levels = model.objects_by_type("VoltageLevel");

    // First, count non-stub VLs per substation for pre-allocation.
    const voltage_level_counts = try gpa.alloc(usize, network.substations.items.len);
    defer gpa.free(voltage_level_counts);
    @memset(voltage_level_counts, 0);

    for (voltage_levels) |voltage_level| {
        if (topology.voltage_level_merge.contains(voltage_level.id())) continue;
        const substation_ref = try voltage_level.reference("VoltageLevel.Substation") orelse continue;
        const substation_idx = substation_id_map.get(strip_hash(substation_ref)) orelse continue;
        voltage_level_counts[@intCast(substation_idx)] += 1;
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
        var it = topology.voltage_level_merge.iterator();
        while (it.next()) |entry| {
            const stub_id = entry.key_ptr.*;
            const repr_id = entry.value_ptr.*;
            const stub_obj = model.object_by_id(stub_id) orelse continue;
            const stub_mrid = try stub_obj.mrid();
            const gop = try repr_to_stub_mrids.getOrPut(gpa, repr_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(gpa, stub_mrid);
        }
    }

    // Second, create VoltageLevel objects.
    for (voltage_levels) |voltage_level| {
        if (topology.voltage_level_merge.contains(voltage_level.id())) continue;
        try append_voltage_level(gpa, model, index, voltage_level, network, substation_id_map, &repr_to_stub_mrids);
    }
}

pub fn build_voltage_level_map(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    topology: *const Topology,
    network: *iidm.Network,
    substation_id_map: *const std.StringHashMapUnmanaged(SubstationIndex),
    substation_map: *std.StringHashMapUnmanaged(*iidm.Substation),
) !std.StringHashMapUnmanaged(*iidm.VoltageLevel) {
    assert(network.substations.items.len > 0);

    // Pointer-stability contract: the maps built here hand out interior pointers
    // into network.substations and into each substation's voltage_levels backing
    // array. convert_substations and convert_voltage_levels must have fully
    // populated both before this runs; nothing afterwards may append to them, or
    // the next reallocation would dangle every pointer. (Equipment converters
    // only append to the *inner* arrays -- loads, switches, … -- which is safe.)
    // We snapshot the substations backing pointer and assert it is unchanged on
    // exit, so a future edit that appends here fails loudly instead of silently.
    const substations_ptr = network.substations.items.ptr;

    const voltage_levels = model.objects_by_type("VoltageLevel");
    const representative_count = voltage_levels.len - topology.voltage_level_merge.count();

    var voltage_level_map: std.StringHashMapUnmanaged(*iidm.VoltageLevel) = .empty;
    try voltage_level_map.ensureTotalCapacity(gpa, @intCast(representative_count));

    try substation_map.ensureTotalCapacity(gpa, @intCast(representative_count));

    const voltage_level_counters = try gpa.alloc(usize, network.substations.items.len);
    defer gpa.free(voltage_level_counters);
    @memset(voltage_level_counters, 0);

    for (voltage_levels) |voltage_level| {
        if (topology.voltage_level_merge.contains(voltage_level.id())) continue;
        const substation_ref = try voltage_level.reference("VoltageLevel.Substation") orelse continue;
        const substation_idx = substation_id_map.get(strip_hash(substation_ref)) orelse continue;
        const substation_item_idx: usize = @intCast(substation_idx);
        substation_map.putAssumeCapacity(voltage_level.id(), &network.substations.items[substation_item_idx]);

        const voltage_level_idx = voltage_level_counters[substation_item_idx];
        voltage_level_counters[substation_item_idx] += 1;
        voltage_level_map.putAssumeCapacity(voltage_level.id(), &network.substations.items[substation_item_idx].voltage_levels.items[voltage_level_idx]);
    }

    // Pairs with the snapshot above: building the maps must not have grown
    // network.substations (which would invalidate the pointers just stored).
    assert(network.substations.items.ptr == substations_ptr);

    return voltage_level_map;
}
