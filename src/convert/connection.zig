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

pub fn buildNodeMap(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
) !std.StringHashMapUnmanaged(u32) {
    assert(index.conn_node_container.count() > 0);

    const conn_nodes = model.getObjectsByType("ConnectivityNode");

    var node_map: std.StringHashMapUnmanaged(u32) = .empty;
    try node_map.ensureTotalCapacity(gpa, @intCast(conn_nodes.len));

    var voltage_level_counters: std.StringHashMapUnmanaged(u32) = .empty;
    defer voltage_level_counters.deinit(gpa);
    try voltage_level_counters.ensureTotalCapacity(gpa, @intCast(model.getObjectsByType("VoltageLevel").len));

    for (conn_nodes) |conn_node| {
        const container_id = index.conn_node_container.get(conn_node.id) orelse continue;
        const container = model.getObjectById(container_id) orelse continue;
        if (!std.mem.eql(u8, container.type_name, "VoltageLevel")) continue;

        const repr_voltage_level_id = cim_index.find_voltage_level(&index.voltage_level_merge, container_id);
        const gop = voltage_level_counters.getOrPutAssumeCapacity(repr_voltage_level_id);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        const node_num = gop.value_ptr.*;
        gop.value_ptr.* += 1;

        node_map.putAssumeCapacity(conn_node.id, node_num);
    }

    assert(node_map.count() <= conn_nodes.len);

    return node_map;
}
