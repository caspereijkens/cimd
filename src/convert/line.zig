const std = @import("std");
const iidm = @import("../iidm.zig");
const cim_model = @import("../cim_model.zig");
const cim_index = @import("../cim_index.zig");
const utils = @import("../utils.zig");
const placement_mod = @import("placement.zig");

const assert = std.debug.assert;

const CimModel = cim_model.CimModel;
const CimIndex = cim_index.CimIndex;
const strip_underscore = utils.strip_underscore;

pub fn convert_lines(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    network: *iidm.Network,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const std.StringHashMapUnmanaged(u32),
) !void {
    const lines = model.getObjectsByType("ACLineSegment");
    assert(lines.len == 0 or index.equipment_terminals.count() > 0);

    try network.lines.ensureTotalCapacity(gpa, lines.len);
    assert(lines.len == 0 or network.lines.capacity >= lines.len);

    for (lines) |line| {
        const mrid = try line.getProperty("IdentifiedObject.mRID") orelse strip_underscore(line.id);
        const name = try line.getProperty("IdentifiedObject.name");

        const r = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.r") orelse "0.0");
        const x = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.x") orelse "0.0");
        const gch = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.gch") orelse "0.0");
        const bch = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.bch") orelse "0.0");

        const terminals = index.equipment_terminals.get(line.id) orelse continue;
        if (terminals.items.len != 2) continue;

        const conn_node1_id = terminals.items[0].conn_node_id orelse continue;
        const placement1 = placement_mod.resolve_conn_node_placement(conn_node1_id, index, voltage_level_map, node_map) orelse continue;

        const conn_node2_id = terminals.items[1].conn_node_id orelse continue;
        const placement2 = placement_mod.resolve_conn_node_placement(conn_node2_id, index, voltage_level_map, node_map) orelse continue;

        network.lines.appendAssumeCapacity(.{
            .id = mrid,
            .name = name,
            .r = r,
            .x = x,
            .g1 = gch / 2.0,
            .g2 = gch / 2.0,
            .b1 = bch / 2.0,
            .b2 = bch / 2.0,
            .voltage_level1_id = placement1.voltage_level.id,
            .node1 = placement1.node,
            .voltage_level2_id = placement2.voltage_level.id,
            .node2 = placement2.node,
            .aliases = .empty,
            .properties = .empty,
            .op_lims_groups1 = .empty,
            .op_lims_groups2 = .empty,
        });
    }

}
