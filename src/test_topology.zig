const std = @import("std");
const topology = @import("topology.zig");
const cim_model = @import("cim_model.zig");

const TopologyResolver = topology.TopologyResolver;
const CimModel = cim_model.CimModel;

test "TopologyResolver.init - EQ model only" {
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

    var resolver = try TopologyResolver.init(gpa, &eq_model);
    defer resolver.deinit();

    // Should have one terminal mapped to equipment
    try std.testing.expectEqual(@as(usize, 1), resolver.terminal_to_equipment.count());

    // Should have one equipment with terminals
    try std.testing.expectEqual(@as(usize, 1), resolver.equipment_terminals.count());

    // Should have zero topology connections (no TP model)
    try std.testing.expectEqual(@as(usize, 0), resolver.terminal_to_node.count());

    // getEquipmentNode should return null (no topology)
    const terminals = resolver.getEquipmentTerminals("Load1");
    try std.testing.expect(terminals != null);
    try std.testing.expectEqual(@as(usize, 1), terminals.?.len);
    try std.testing.expectEqual(@as(u32, 1), terminals.?[0].sequence);
    try std.testing.expect(terminals.?[0].node_id == null);
}

test "TopologyResolver.init - missing ConductingEquipment reference fails fast" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;

    var eq_model = try CimModel.init(gpa, eq_xml);
    defer eq_model.deinit(gpa);

    // Should fail during init (Tiger Style - fail fast!)
    const result = TopologyResolver.init(gpa, &eq_model);
    try std.testing.expectError(error.MissingConductingEquipmentReference, result);
}

test "TopologyResolver.getEquipmentTerminals - two-winding transformer" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#TR1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="T2">
        \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#TR1"/>
        \\  </cim:Terminal>
        \\  <cim:PowerTransformer rdf:ID="TR1"/>
        \\</rdf:RDF>
    ;

    var eq_model = try CimModel.init(gpa, eq_xml);
    defer eq_model.deinit(gpa);

    var resolver = try TopologyResolver.init(gpa, &eq_model);
    defer resolver.deinit();

    // Should have 2 terminals for TR1
    const terminals = resolver.getEquipmentTerminals("TR1");
    try std.testing.expect(terminals != null);
    try std.testing.expectEqual(@as(usize, 2), terminals.?.len);

    // Verify both sequences exist (order not guaranteed)
    var has_seq1 = false;
    var has_seq2 = false;
    for (terminals.?) |term| {
        if (term.sequence == 1) has_seq1 = true;
        if (term.sequence == 2) has_seq2 = true;
    }
    try std.testing.expect(has_seq1 and has_seq2);
}

test "TopologyResolver.getEquipmentNode - node_breaker mode returns connectivity node" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:ConnectivityNode rdf:ID="CN1"/>
        \\  <cim:ConnectivityNode rdf:ID="CN2"/>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#Load1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="T2">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#Gen1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN2"/>
        \\  </cim:Terminal>
        \\  <cim:EnergyConsumer rdf:ID="Load1"/>
        \\  <cim:SynchronousMachine rdf:ID="Gen1"/>
        \\</rdf:RDF>
    ;

    var eq_model = try CimModel.init(gpa, eq_xml);
    defer eq_model.deinit(gpa);

    var resolver = try TopologyResolver.init(gpa, &eq_model);
    defer resolver.deinit();

    // These will FAIL with your current implementation
    const cn1 = resolver.getEquipmentNode("Load1", 1);
    try std.testing.expect(cn1 != null);
    try std.testing.expectEqualStrings("CN1", cn1.?);

    const cn2 = resolver.getEquipmentNode("Gen1", 1);
    try std.testing.expect(cn2 != null);
    try std.testing.expectEqualStrings("CN2", cn2.?);
}

test "TopologyResolver.getStats - includes node counts" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:ConnectivityNode rdf:ID="CN1"/>
        \\  <cim:ConnectivityNode rdf:ID="CN2"/>
        \\  <cim:ConnectivityNode rdf:ID="CN3"/>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#Load1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="T2">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#Load2"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN1"/>
        \\  </cim:Terminal>
        \\  <cim:EnergyConsumer rdf:ID="Load1"/>
        \\  <cim:EnergyConsumer rdf:ID="Load2"/>
        \\</rdf:RDF>
    ;

    var eq_model = try CimModel.init(gpa, eq_xml);
    defer eq_model.deinit(gpa);

    var resolver = try TopologyResolver.init(gpa, &eq_model);
    defer resolver.deinit();

    const stats = resolver.getStats();

    try std.testing.expectEqual(@as(usize, 2), stats.terminal_count);
    try std.testing.expectEqual(@as(usize, 2), stats.equipment_count);
    try std.testing.expectEqual(@as(usize, 2), stats.connected_terminals);
    // New: count of unique ConnectivityNodes referenced
    try std.testing.expectEqual(@as(usize, 1), stats.connected_nodes);
}

test "TopologyResolver.init - dangling ConnectivityNode reference fails" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#Load1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#NonExistent"/>
        \\  </cim:Terminal>
        \\  <cim:EnergyConsumer rdf:ID="Load1"/>
        \\</rdf:RDF>
    ;

    var eq_model = try CimModel.init(gpa, eq_xml);
    defer eq_model.deinit(gpa);

    const result = TopologyResolver.init(gpa, &eq_model);
    try std.testing.expectError(error.DanglingConnectivityNodeReference, result);
}

test "TopologyResolver.init - dangling ConductingEquipment reference fails" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:ConnectivityNode rdf:ID="CN1"/>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#NonExistentLoad"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;

    var eq_model = try CimModel.init(gpa, eq_xml);
    defer eq_model.deinit(gpa);

    const result = TopologyResolver.init(gpa, &eq_model);
    try std.testing.expectError(error.DanglingConductingEquipmentReference, result);
}
