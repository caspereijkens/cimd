const std = @import("std");
const converter = @import("converter.zig");
const cim_model = @import("cim_model.zig");
const topology = @import("topology.zig");

const Converter = converter.Converter;
const CimModel = cim_model.CimModel;
const TopologyResolver = topology.TopologyResolver;

test "Converter - converts Substation with name" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="Sub1">
        \\    <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;

    var model = try CimModel.init(gpa, eq_xml);
    defer model.deinit(gpa);

    var topo = try TopologyResolver.init(gpa, &model, null);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    var network = try conv.convert();
    defer network.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), network.substations.items.len);

    const sub = network.substations.items[0];
    try std.testing.expectEqualStrings("Sub1", sub.id);
    try std.testing.expectEqualStrings("North Station", sub.name.?);
}

test "Converter - converts VoltageLevel with nominal voltage" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="Sub1">
        \\    <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="VL1">
        \\    <cim:IdentifiedObject.name>110kV</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.Substation rdf:resource="#Sub1"/>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#BV1"/>
        \\  </cim:VoltageLevel>
        \\  <cim:BaseVoltage rdf:ID="BV1">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    ;

    var model = try CimModel.init(gpa, eq_xml);
    defer model.deinit(gpa);

    var topo = try TopologyResolver.init(gpa, &model, null);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    var network = try conv.convert();
    defer network.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), network.voltage_levels.items.len);

    const vl = network.voltage_levels.items[0];
    try std.testing.expectEqualStrings("VL1", vl.id);
    try std.testing.expectEqualStrings("110kV", vl.name.?);
    try std.testing.expectEqualStrings("Sub1", vl.substation_id);
    try std.testing.expectEqual(@as(f64, 110.0), vl.nominal_voltage.?);
}

test "Converter - converts EnergyConsumer to Load" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="Sub1">
        \\    <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="VL1">
        \\    <cim:IdentifiedObject.name>110kV</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.Substation rdf:resource="#Sub1"/>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#BV1"/>
        \\  </cim:VoltageLevel>
        \\  <cim:BaseVoltage rdf:ID="BV1">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:ConnectivityNode rdf:ID="CN1">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#VL1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:EnergyConsumer rdf:ID="Load1">
        \\    <cim:IdentifiedObject.name>City Load</cim:IdentifiedObject.name>
        \\    <cim:EnergyConsumer.p>100</cim:EnergyConsumer.p>
        \\    <cim:EnergyConsumer.q>50</cim:EnergyConsumer.q>
        \\  </cim:EnergyConsumer>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#Load1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;

    var model = try CimModel.init(gpa, eq_xml);
    defer model.deinit(gpa);

    var topo = try TopologyResolver.init(gpa, &model, null);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    var network = try conv.convert();
    defer network.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), network.loads.items.len);

    const load = network.loads.items[0];
    try std.testing.expectEqualStrings("Load1", load.id);
    try std.testing.expectEqualStrings("City Load", load.name.?);
    try std.testing.expectEqualStrings("VL1", load.voltage_level_id);
    try std.testing.expectEqualStrings("CN1", load.bus.?);
    try std.testing.expectEqual(@as(f64, 100.0), load.p0);
    try std.testing.expectEqual(@as(f64, 50.0), load.q0);
}

test "Converter - converts SynchronousMachine to Generator" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="Sub1">
        \\    <cim:IdentifiedObject.name>PowerPlant</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="VL1">
        \\    <cim:IdentifiedObject.name>20kV</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.Substation rdf:resource="#Sub1"/>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#BV1"/>
        \\  </cim:VoltageLevel>
        \\  <cim:BaseVoltage rdf:ID="BV1">
        \\    <cim:BaseVoltage.nominalVoltage>20</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:ConnectivityNode rdf:ID="CN1">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#VL1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:GeneratingUnit rdf:ID="GU1">
        \\    <cim:GeneratingUnit.minOperatingP>10</cim:GeneratingUnit.minOperatingP>
        \\    <cim:GeneratingUnit.maxOperatingP>200</cim:GeneratingUnit.maxOperatingP>
        \\    <cim:GeneratingUnit.initialP>150</cim:GeneratingUnit.initialP>
        \\  </cim:GeneratingUnit>
        \\  <cim:SynchronousMachine rdf:ID="Gen1">
        \\    <cim:IdentifiedObject.name>Main Generator</cim:IdentifiedObject.name>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#GU1"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#Gen1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;

    var model = try CimModel.init(gpa, eq_xml);
    defer model.deinit(gpa);

    var topo = try TopologyResolver.init(gpa, &model, null);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    var network = try conv.convert();
    defer network.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), network.generators.items.len);

    const gen = network.generators.items[0];
    try std.testing.expectEqualStrings("Gen1", gen.id);
    try std.testing.expectEqualStrings("Main Generator", gen.name.?);
    try std.testing.expectEqualStrings("VL1", gen.voltage_level_id);
    try std.testing.expectEqual(@as(f64, 10.0), gen.min_p.?);
    try std.testing.expectEqual(@as(f64, 200.0), gen.max_p.?);
    try std.testing.expectEqual(@as(f64, 150.0), gen.target_p);
}

test "Converter - converts ACLineSegment to Line" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="Sub1">
        \\    <cim:IdentifiedObject.name>Station A</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="Sub2">
        \\    <cim:IdentifiedObject.name>Station B</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="VL1">
        \\    <cim:IdentifiedObject.name>110kV</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.Substation rdf:resource="#Sub1"/>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#BV1"/>
        \\  </cim:VoltageLevel>
        \\  <cim:VoltageLevel rdf:ID="VL2">
        \\    <cim:IdentifiedObject.name>110kV</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.Substation rdf:resource="#Sub2"/>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#BV1"/>
        \\  </cim:VoltageLevel>
        \\  <cim:BaseVoltage rdf:ID="BV1">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:ConnectivityNode rdf:ID="CN1">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#VL1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ConnectivityNode rdf:ID="CN2">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#VL2"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ACLineSegment rdf:ID="Line1">
        \\    <cim:IdentifiedObject.name>Line A-B</cim:IdentifiedObject.name>
        \\    <cim:ACLineSegment.r>1.5</cim:ACLineSegment.r>
        \\    <cim:ACLineSegment.x>15.0</cim:ACLineSegment.x>
        \\    <cim:ACLineSegment.bch>0.0001</cim:ACLineSegment.bch>
        \\  </cim:ACLineSegment>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#Line1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="T2">
        \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#Line1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN2"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;

    var model = try CimModel.init(gpa, eq_xml);
    defer model.deinit(gpa);

    var topo = try TopologyResolver.init(gpa, &model, null);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    var network = try conv.convert();
    defer network.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), network.lines.items.len);

    const line = network.lines.items[0];
    try std.testing.expectEqualStrings("Line1", line.id);
    try std.testing.expectEqualStrings("Line A-B", line.name.?);
    try std.testing.expectEqualStrings("VL1", line.voltage_level_id1);
    try std.testing.expectEqualStrings("VL2", line.voltage_level_id2);
    try std.testing.expectEqualStrings("CN1", line.bus1.?);
    try std.testing.expectEqualStrings("CN2", line.bus2.?);
    try std.testing.expectEqual(@as(f64, 1.5), line.r);
    try std.testing.expectEqual(@as(f64, 15.0), line.x);
    try std.testing.expectEqual(@as(f64, 0.00005), line.b1); // half of bch
    try std.testing.expectEqual(@as(f64, 0.00005), line.b2);
}
