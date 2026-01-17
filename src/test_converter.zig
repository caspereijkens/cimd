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
