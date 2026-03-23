const std = @import("std");
const iidm = @import("iidm.zig");
const cim_model = @import("cim_model.zig");
const cim_index = @import("cim_index.zig");
const substation_conv = @import("convert/substation.zig");
const voltage_level_conv = @import("convert/voltage_level.zig");
const connection_conv = @import("convert/connection.zig");
const equipment_conv = @import("convert/equipment.zig");
const transformer_conv = @import("convert/transformer.zig");
const line_conv = @import("convert/line.zig");

const assert = std.debug.assert;
const CimModel = cim_model.CimModel;

/// Convert a CimModel into an IIDM Network.
/// Caller owns the returned network and must call network.deinit(gpa).
pub fn convert(gpa: std.mem.Allocator, model: *const CimModel) !iidm.Network {
    assert(model.getObjectsByType("Substation").len > 0);

    const boundary_ids: std.StringHashMapUnmanaged(void) = .empty;
    var index = try cim_index.CimIndex.build(gpa, model, boundary_ids);
    defer index.deinit(gpa);

    var network = iidm.Network{
        .id = "unknown",
        .case_date = null,
        .substations = .empty,
        .lines = .empty,
        .hvdc_lines = .empty,
        .extensions = .empty,
    };
    errdefer network.deinit(gpa);

    var sub_id_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer sub_id_map.deinit(gpa);
    try substation_conv.convert_substations(gpa, model, &index, &network, &sub_id_map);

    try voltage_level_conv.convert_voltage_levels(gpa, model, &index, &network, &sub_id_map);

    var substation_map: std.StringHashMapUnmanaged(*iidm.Substation) = .empty;
    defer substation_map.deinit(gpa);
    var voltage_level_map = try voltage_level_conv.build_voltage_level_map(gpa, model, &index, &network, &sub_id_map, &substation_map);
    defer voltage_level_map.deinit(gpa);

    var node_map = try connection_conv.build_node_map(gpa, model, &index);
    defer node_map.deinit(gpa);

    try equipment_conv.pre_allocate_equipment(gpa, model, &index, &voltage_level_map);
    try equipment_conv.convert_busbar_sections(model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_switches(model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_loads(model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_shunts(model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_static_var_compensators(model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_generators(gpa, model, &index, &voltage_level_map, &node_map);
    try transformer_conv.convert_transformers(gpa, model, &index, &substation_map, &voltage_level_map, &node_map);
    try line_conv.convert_lines(gpa, model, &index, &network, &voltage_level_map, &node_map);

    assert(network.substations.items.len > 0);
    return network;
}
