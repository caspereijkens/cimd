const std = @import("std");
const iidm = @import("../iidm/model.zig");
const EQ = @import("../cgmes/eq.zig").EQ;
const TP = @import("../cgmes/tp.zig").TP;
const utils = @import("../cgmes/ids.zig");

const assert = std.debug.assert;


const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

/// Resolved placement of a TopologicalNode as an IIDM Bus.
pub const BusPlacement = struct {
    /// Bus id in IIDM (the TN's mRID, underscore-stripped).
    bus_id: []const u8,
    /// Target VL the bus belongs to.
    voltage_level: *iidm.VoltageLevel,
    /// The VL's IIDM id (for equipment's voltageLevelId field).
    voltage_level_id: []const u8,
    /// The VL's raw rdf:ID (with leading underscore); matches voltage_level_map keys.
    raw_voltage_level_id: []const u8,
};

/// Maps TopologicalNode raw rdf:ID (with leading underscore) → BusPlacement.
pub const BusMap = std.StringHashMapUnmanaged(BusPlacement);

/// Walk TP.new_objects, pick TopologicalNodes, emit one Bus per TN into its
/// container VL, and return a TN-id → BusPlacement lookup for equipment placement.
///
/// `voltage_level_map` keys are the primary model's raw VL rdf:ID; values are
/// pointers into `network.substations[*].voltage_levels`.
///
/// Caller owns the returned BusMap and must call .deinit(gpa).
pub fn convert_buses(
    gpa: std.mem.Allocator,
    tp: TP,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
) !BusMap {
    var bus_map: BusMap = .empty;
    errdefer bus_map.deinit(gpa);

    // Count TNs first so we can pre-size the map and each VL's bus array.
    var tn_count: usize = 0;
    for (tp.new_objects) |obj| {
        if (std.mem.eql(u8, obj.type_name, "TopologicalNode")) tn_count += 1;
    }
    try bus_map.ensureTotalCapacity(gpa, @intCast(tn_count));

    // Count per-VL so each VL gets exactly-sized bus storage (no over-alloc).
    var per_vl_counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer per_vl_counts.deinit(gpa);
    try per_vl_counts.ensureTotalCapacity(gpa, @intCast(voltage_level_map.count()));
    for (tp.new_objects) |obj| {
        if (!std.mem.eql(u8, obj.type_name, "TopologicalNode")) continue;
        const view = tp.get_object_by_id(obj.id) orelse continue;
        const container_ref = try view.getReference("TopologicalNode.ConnectivityNodeContainer") orelse continue;
        const container_id = strip_hash(container_ref);
        if (!voltage_level_map.contains(container_id)) continue;
        const gop = try per_vl_counts.getOrPut(gpa, container_id);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var vl_it = per_vl_counts.iterator();
    while (vl_it.next()) |entry| {
        const vl = voltage_level_map.get(entry.key_ptr.*) orelse unreachable;
        vl.topology_kind = .bus_breaker;
        try vl.bus_breaker_topology.buses.ensureTotalCapacity(gpa, entry.value_ptr.*);
    }

    // Emit buses and populate the TN → BusPlacement map.
    for (tp.new_objects) |obj| {
        if (!std.mem.eql(u8, obj.type_name, "TopologicalNode")) continue;
        const view = tp.get_object_by_id(obj.id) orelse continue;
        const container_ref = try view.getReference("TopologicalNode.ConnectivityNodeContainer") orelse continue;
        const container_id = strip_hash(container_ref);
        const vl = voltage_level_map.get(container_id) orelse continue;

        const mrid = try view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(obj.id);
        const name = try view.getProperty("IdentifiedObject.name");

        vl.bus_breaker_topology.buses.appendAssumeCapacity(.{ .id = mrid, .name = name });

        bus_map.putAssumeCapacityNoClobber(obj.id, .{
            .bus_id = mrid,
            .voltage_level = vl,
            .voltage_level_id = vl.id,
            .raw_voltage_level_id = container_id,
        });
    }

    return bus_map;
}

/// Resolve a Terminal's TopologicalNode via the TP patch layer, returning the
/// BusPlacement the terminal sits on. Returns null if the terminal has no
/// patch, no TopologicalNode reference, or the TN doesn't map to a known VL.
pub fn resolve_terminal_bus(
    tp: TP,
    bus_map: *const BusMap,
    terminal_mrid_stripped: []const u8,
) !?BusPlacement {
    assert(terminal_mrid_stripped.len > 0);
    const patch = tp.find_patch(terminal_mrid_stripped) orelse return null;
    const tn_ref = try tp.getReferenceFromPatch(patch, "Terminal.TopologicalNode") orelse return null;
    // rdf:resource is "#_TNID"; strip_hash leaves "_TNID" which matches bus_map keys.
    return bus_map.get(strip_hash(tn_ref));
}
