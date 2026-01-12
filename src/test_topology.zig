const std = @import("std");
const topology = @import("topology.zig");
const cim_model = @import("cim_model.zig");

const TopologyResolver = topology.TopologyResolver;
const TopologyMode = topology.TopologyMode;
const CimModel = cim_model.CimModel;

test "TopologyResolver.init - EQ model only, no_topology mode" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#Load1"/>
        \\  </cim:Terminal>
        \\  <cim:EnergyConsumer rdf:ID="Load1"/>
        \\</rdf:RDF>
    ;

    var eq_model = try CimModel.init(gpa, eq_xml);
    defer eq_model.deinit(gpa);

    var resolver = try TopologyResolver.init(gpa, &eq_model, null);
    defer resolver.deinit();

    // Should detect no_topology mode (no TP model provided)
    try std.testing.expectEqual(TopologyMode.no_topology, resolver.mode);

    // Should have one terminal mapped to equipment
    try std.testing.expectEqual(@as(usize, 1), resolver.terminal_to_equipment.count());

    // Should have one equipment with terminals
    try std.testing.expectEqual(@as(usize, 1), resolver.equipment_terminals.count());

    // Should have zero topology connections (no TP model)
    try std.testing.expectEqual(@as(usize, 0), resolver.terminal_to_node.count());

    // getEquipmentBus should return null (no topology)
    const terminals = resolver.getEquipmentTerminals("Load1");
    try std.testing.expect(terminals != null);
    try std.testing.expectEqual(@as(usize, 1), terminals.?.len);
    try std.testing.expectEqual(@as(u32, 1), terminals.?[0].sequence);
    try std.testing.expect(terminals.?[0].node_id == null);
}
