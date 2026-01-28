const std = @import("std");
const converter = @import("converter.zig");
const cim_model = @import("cim_model.zig");
const topology = @import("topology.zig");
const iidm = @import("iidm.zig");

const Converter = converter.Converter;
const CimModel = cim_model.CimModel;
const TopologyResolver = topology.TopologyResolver;
const SwitchKind = iidm.SwitchKind;

test "Converter - converts Substation with name" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:test">
        \\    <md:Model.scenarioTime>2009-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
        \\  <cim:Substation rdf:ID="Sub1">
        \\    <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;

    var model = try CimModel.init(gpa, eq_xml);
    defer model.deinit(gpa);

    var topo = try TopologyResolver.init(gpa, &model);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    defer conv.deinit();
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
        \\  <md:FullModel rdf:about="urn:uuid:test">
        \\    <md:Model.scenarioTime>2009-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
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

    var topo = try TopologyResolver.init(gpa, &model);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    defer conv.deinit();
    var network = try conv.convert();
    defer network.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), network.substations.items.len);
    try std.testing.expectEqual(@as(usize, 1), network.substations.items[0].voltage_levels.items.len);

    const vl = network.substations.items[0].voltage_levels.items[0];
    try std.testing.expectEqualStrings("VL1", vl.id);
    try std.testing.expectEqualStrings("110kV", vl.name.?);
    try std.testing.expectEqual(@as(f64, 110.0), vl.nominal_voltage.?);
}

test "Converter - converts EnergyConsumer to Load" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:test">
        \\    <md:Model.scenarioTime>2009-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
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

    var topo = try TopologyResolver.init(gpa, &model);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    defer conv.deinit();
    var network = try conv.convert();
    defer network.deinit(gpa);

    const vl = &network.substations.items[0].voltage_levels.items[0];
    try std.testing.expectEqual(@as(usize, 1), vl.loads.items.len);

    const load = vl.loads.items[0];
    try std.testing.expectEqualStrings("Load1", load.id);
    try std.testing.expectEqualStrings("City Load", load.name.?);
    try std.testing.expectEqual(0, load.node);
    try std.testing.expectEqual(@as(f64, 100.0), load.p0);
    try std.testing.expectEqual(@as(f64, 50.0), load.q0);
}

test "Converter - converts SynchronousMachine to Generator" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:test">
        \\    <md:Model.scenarioTime>2009-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
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
        \\  <cim:HydroGeneratingUnit rdf:ID="GU1">
        \\    <cim:GeneratingUnit.minOperatingP>10</cim:GeneratingUnit.minOperatingP>
        \\    <cim:GeneratingUnit.maxOperatingP>200</cim:GeneratingUnit.maxOperatingP>
        \\    <cim:GeneratingUnit.initialP>150</cim:GeneratingUnit.initialP>
        \\  </cim:HydroGeneratingUnit>
        \\  <cim:SynchronousMachine rdf:ID="Gen1">
        \\    <cim:IdentifiedObject.name>Main Generator</cim:IdentifiedObject.name>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#GU1"/>
        \\    <cim:RotatingMachine.ratedS>250.5</cim:RotatingMachine.ratedS>
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

    var topo = try TopologyResolver.init(gpa, &model);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    defer conv.deinit();
    var network = try conv.convert();
    defer network.deinit(gpa);

    const vl = &network.substations.items[0].voltage_levels.items[0];
    try std.testing.expectEqual(@as(usize, 1), vl.generators.items.len);

    const gen = vl.generators.items[0];
    try std.testing.expectEqualStrings("Gen1", gen.id);
    try std.testing.expectEqualStrings("Main Generator", gen.name.?);
    try std.testing.expectEqual(iidm.EnergySource.hydro, gen.energy_source);
    try std.testing.expectEqual(@as(f64, 10.0), gen.min_p.?);
    try std.testing.expectEqual(@as(f64, 200.0), gen.max_p.?);
    try std.testing.expectEqual(@as(f64, 250.5), gen.rated_s.?);
    try std.testing.expectEqual(false, gen.voltage_regulator_on);
    try std.testing.expectEqual(@as(f64, 150.0), gen.target_p);
    try std.testing.expectEqual(@as(usize, 0), gen.reactive_capability_curve_points.items.len);
}

test "Converter - converts SynchronousMachine with ReactiveCapabilityCurve" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:test">
        \\    <md:Model.scenarioTime>2009-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
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
        \\  <cim:ThermalGeneratingUnit rdf:ID="GU1">
        \\    <cim:GeneratingUnit.minOperatingP>0</cim:GeneratingUnit.minOperatingP>
        \\    <cim:GeneratingUnit.maxOperatingP>100</cim:GeneratingUnit.maxOperatingP>
        \\  </cim:ThermalGeneratingUnit>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="RCC1"/>
        \\  <cim:CurveData rdf:ID="CD1">
        \\    <cim:CurveData.Curve rdf:resource="#RCC1"/>
        \\    <cim:CurveData.xvalue>0</cim:CurveData.xvalue>
        \\    <cim:CurveData.y1value>-769.3</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>860.0</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="CD2">
        \\    <cim:CurveData.Curve rdf:resource="#RCC1"/>
        \\    <cim:CurveData.xvalue>100</cim:CurveData.xvalue>
        \\    <cim:CurveData.y1value>-864.55</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>946.25</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\  <cim:SynchronousMachine rdf:ID="Gen1">
        \\    <cim:IdentifiedObject.name>Thermal Gen</cim:IdentifiedObject.name>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#GU1"/>
        \\    <cim:RotatingMachine.ratedS>951.5</cim:RotatingMachine.ratedS>
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#RCC1"/>
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

    var topo = try TopologyResolver.init(gpa, &model);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    defer conv.deinit();
    var network = try conv.convert();
    defer network.deinit(gpa);

    const vl = &network.substations.items[0].voltage_levels.items[0];
    try std.testing.expectEqual(@as(usize, 1), vl.generators.items.len);

    const gen = vl.generators.items[0];
    try std.testing.expectEqualStrings("Gen1", gen.id);
    try std.testing.expectEqual(iidm.EnergySource.thermal, gen.energy_source);
    try std.testing.expectEqual(@as(f64, 951.5), gen.rated_s.?);

    // Reactive capability curve should have 2 points
    try std.testing.expectEqual(@as(usize, 2), gen.reactive_capability_curve_points.items.len);

    const pt0 = gen.reactive_capability_curve_points.items[0];
    try std.testing.expectEqual(@as(f64, 0.0), pt0.p);
    try std.testing.expectEqual(@as(f64, -769.3), pt0.min_q);
    try std.testing.expectEqual(@as(f64, 860.0), pt0.max_q);

    const pt1 = gen.reactive_capability_curve_points.items[1];
    try std.testing.expectEqual(@as(f64, 100.0), pt1.p);
    try std.testing.expectEqual(@as(f64, -864.55), pt1.min_q);
    try std.testing.expectEqual(@as(f64, 946.25), pt1.max_q);
}

test "Converter - converts ACLineSegment to Line" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:test">
        \\    <md:Model.scenarioTime>2009-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
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

    var topo = try TopologyResolver.init(gpa, &model);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    defer conv.deinit();
    var network = try conv.convert();
    defer network.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), network.lines.items.len);

    const line = network.lines.items[0];
    try std.testing.expectEqualStrings("Line1", line.id);
    try std.testing.expectEqualStrings("Line A-B", line.name.?);
    try std.testing.expectEqualStrings("CN1", line.node1.?);
    try std.testing.expectEqualStrings("CN2", line.node2.?);
    try std.testing.expectEqual(@as(f64, 1.5), line.r);
    try std.testing.expectEqual(@as(f64, 15.0), line.x);
    try std.testing.expectEqual(@as(f64, 0.00005), line.b1); // half of bch
    try std.testing.expectEqual(@as(f64, 0.00005), line.b2);
}

test "Converter - converts PowerTransformer to TwoWindingsTransformer" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:test">
        \\    <md:Model.scenarioTime>2009-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
        \\  <cim:Substation rdf:ID="Sub1">
        \\    <cim:IdentifiedObject.name>Station</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="VL1">
        \\    <cim:IdentifiedObject.name>110kV</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.Substation rdf:resource="#Sub1"/>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#BV1"/>
        \\  </cim:VoltageLevel>
        \\  <cim:VoltageLevel rdf:ID="VL2">
        \\    <cim:IdentifiedObject.name>20kV</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.Substation rdf:resource="#Sub1"/>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#BV2"/>
        \\  </cim:VoltageLevel>
        \\  <cim:BaseVoltage rdf:ID="BV1">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="BV2">
        \\    <cim:BaseVoltage.nominalVoltage>20</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:ConnectivityNode rdf:ID="CN1">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#VL1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ConnectivityNode rdf:ID="CN2">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#VL2"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:PowerTransformer rdf:ID="TR1">
        \\    <cim:IdentifiedObject.name>Main Transformer</cim:IdentifiedObject.name>
        \\  </cim:PowerTransformer>
        \\  <cim:PowerTransformerEnd rdf:ID="TR1_End1">
        \\    <cim:TransformerEnd.endNumber>1</cim:TransformerEnd.endNumber>
        \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#TR1"/>
        \\    <cim:PowerTransformerEnd.ratedU>110</cim:PowerTransformerEnd.ratedU>
        \\    <cim:PowerTransformerEnd.r>0.5</cim:PowerTransformerEnd.r>
        \\    <cim:PowerTransformerEnd.x>25</cim:PowerTransformerEnd.x>
        \\    <cim:PowerTransformerEnd.g>0</cim:PowerTransformerEnd.g>
        \\    <cim:PowerTransformerEnd.b>0</cim:PowerTransformerEnd.b>
        \\    <cim:TransformerEnd.Terminal rdf:resource="#T1"/>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:PowerTransformerEnd rdf:ID="TR1_End2">
        \\    <cim:TransformerEnd.endNumber>2</cim:TransformerEnd.endNumber>
        \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#TR1"/>
        \\    <cim:PowerTransformerEnd.ratedU>20</cim:PowerTransformerEnd.ratedU>
        \\    <cim:PowerTransformerEnd.r>0</cim:PowerTransformerEnd.r>
        \\    <cim:PowerTransformerEnd.x>0</cim:PowerTransformerEnd.x>
        \\    <cim:PowerTransformerEnd.g>0</cim:PowerTransformerEnd.g>
        \\    <cim:PowerTransformerEnd.b>0</cim:PowerTransformerEnd.b>
        \\    <cim:TransformerEnd.Terminal rdf:resource="#T2"/>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#TR1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="T2">
        \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#TR1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN2"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;

    var model = try CimModel.init(gpa, eq_xml);
    defer model.deinit(gpa);

    var topo = try TopologyResolver.init(gpa, &model);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    defer conv.deinit();
    var network = try conv.convert();
    defer network.deinit(gpa);

    const sub = &network.substations.items[0];
    try std.testing.expectEqual(@as(usize, 1), sub.two_winding_transformers.items.len);
    try std.testing.expectEqual(@as(usize, 0), sub.three_winding_transformers.items.len);

    const tr = sub.two_winding_transformers.items[0];
    try std.testing.expectEqualStrings("TR1", tr.id);
    try std.testing.expectEqualStrings("Main Transformer", tr.name.?);
    try std.testing.expectEqualStrings("VL1", tr.voltage_level_id1);
    try std.testing.expectEqual(@as(u32, 0), tr.node1);
    try std.testing.expectEqualStrings("VL2", tr.voltage_level_id2);
    try std.testing.expectEqual(@as(u32, 0), tr.node2);
    try std.testing.expectEqual(@as(f64, 110.0), tr.rated_u1);
    try std.testing.expectEqual(@as(f64, 20.0), tr.rated_u2);
    // IIDM convention: impedances referred to side 2, so r_iidm = r_cgmes * (ratedU2/ratedU1)²
    const ratio_sq = (20.0 / 110.0) * (20.0 / 110.0);
    try std.testing.expectApproxEqRel(@as(f64, 0.5 * ratio_sq), tr.r, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 25.0 * ratio_sq), tr.x, 1e-12);
}

test "Converter - converts PowerTransformer to ThreeWindingsTransformer" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:test">
        \\    <md:Model.scenarioTime>2009-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
        \\  <cim:Substation rdf:ID="Sub1">
        \\    <cim:IdentifiedObject.name>Station</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="VL1">
        \\    <cim:IdentifiedObject.name>220kV</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.Substation rdf:resource="#Sub1"/>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#BV1"/>
        \\  </cim:VoltageLevel>
        \\  <cim:VoltageLevel rdf:ID="VL2">
        \\    <cim:IdentifiedObject.name>110kV</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.Substation rdf:resource="#Sub1"/>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#BV2"/>
        \\  </cim:VoltageLevel>
        \\  <cim:VoltageLevel rdf:ID="VL3">
        \\    <cim:IdentifiedObject.name>20kV</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.Substation rdf:resource="#Sub1"/>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#BV3"/>
        \\  </cim:VoltageLevel>
        \\  <cim:BaseVoltage rdf:ID="BV1">
        \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="BV2">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="BV3">
        \\    <cim:BaseVoltage.nominalVoltage>20</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:ConnectivityNode rdf:ID="CN1">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#VL1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ConnectivityNode rdf:ID="CN2">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#VL2"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ConnectivityNode rdf:ID="CN3">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#VL3"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:PowerTransformer rdf:ID="TR3W">
        \\    <cim:IdentifiedObject.name>Three Winding Trafo</cim:IdentifiedObject.name>
        \\  </cim:PowerTransformer>
        \\  <cim:PowerTransformerEnd rdf:ID="TR3W_End1">
        \\    <cim:TransformerEnd.endNumber>1</cim:TransformerEnd.endNumber>
        \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#TR3W"/>
        \\    <cim:PowerTransformerEnd.ratedU>220</cim:PowerTransformerEnd.ratedU>
        \\    <cim:PowerTransformerEnd.r>0.1</cim:PowerTransformerEnd.r>
        \\    <cim:PowerTransformerEnd.x>10</cim:PowerTransformerEnd.x>
        \\    <cim:PowerTransformerEnd.g>0.001</cim:PowerTransformerEnd.g>
        \\    <cim:PowerTransformerEnd.b>0.002</cim:PowerTransformerEnd.b>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:PowerTransformerEnd rdf:ID="TR3W_End2">
        \\    <cim:TransformerEnd.endNumber>2</cim:TransformerEnd.endNumber>
        \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#TR3W"/>
        \\    <cim:PowerTransformerEnd.ratedU>110</cim:PowerTransformerEnd.ratedU>
        \\    <cim:PowerTransformerEnd.r>0.2</cim:PowerTransformerEnd.r>
        \\    <cim:PowerTransformerEnd.x>20</cim:PowerTransformerEnd.x>
        \\    <cim:PowerTransformerEnd.g>0</cim:PowerTransformerEnd.g>
        \\    <cim:PowerTransformerEnd.b>0</cim:PowerTransformerEnd.b>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:PowerTransformerEnd rdf:ID="TR3W_End3">
        \\    <cim:TransformerEnd.endNumber>3</cim:TransformerEnd.endNumber>
        \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#TR3W"/>
        \\    <cim:PowerTransformerEnd.ratedU>20</cim:PowerTransformerEnd.ratedU>
        \\    <cim:PowerTransformerEnd.r>0.3</cim:PowerTransformerEnd.r>
        \\    <cim:PowerTransformerEnd.x>30</cim:PowerTransformerEnd.x>
        \\    <cim:PowerTransformerEnd.g>0</cim:PowerTransformerEnd.g>
        \\    <cim:PowerTransformerEnd.b>0</cim:PowerTransformerEnd.b>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#TR3W"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="T2">
        \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#TR3W"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN2"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="T3">
        \\    <cim:ACDCTerminal.sequenceNumber>3</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#TR3W"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN3"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;

    var model = try CimModel.init(gpa, eq_xml);
    defer model.deinit(gpa);

    var topo = try TopologyResolver.init(gpa, &model);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    defer conv.deinit();
    var network = try conv.convert();
    defer network.deinit(gpa);

    const sub = &network.substations.items[0];
    try std.testing.expectEqual(@as(usize, 0), sub.two_winding_transformers.items.len);
    try std.testing.expectEqual(@as(usize, 1), sub.three_winding_transformers.items.len);

    const tr = sub.three_winding_transformers.items[0];
    try std.testing.expectEqualStrings("TR3W", tr.id);
    try std.testing.expectEqualStrings("Three Winding Trafo", tr.name.?);
    try std.testing.expectEqualStrings("CN1", tr.node1.?);
    try std.testing.expectEqualStrings("CN2", tr.node2.?);
    try std.testing.expectEqualStrings("CN3", tr.node3.?);
    try std.testing.expectEqual(@as(f64, 220.0), tr.rated_u1);
    try std.testing.expectEqual(@as(f64, 110.0), tr.rated_u2);
    try std.testing.expectEqual(@as(f64, 20.0), tr.rated_u3);
    try std.testing.expectEqual(@as(f64, 0.1), tr.r1);
    try std.testing.expectEqual(@as(f64, 0.2), tr.r2);
    try std.testing.expectEqual(@as(f64, 0.3), tr.r3);
    try std.testing.expectEqual(@as(f64, 10.0), tr.x1);
    try std.testing.expectEqual(@as(f64, 20.0), tr.x2);
    try std.testing.expectEqual(@as(f64, 30.0), tr.x3);
}

test "Converter - converts Breaker to Switch" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:test">
        \\    <md:Model.scenarioTime>2009-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
        \\  <cim:Substation rdf:ID="Sub1">
        \\    <cim:IdentifiedObject.name>Station</cim:IdentifiedObject.name>
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
        \\  <cim:ConnectivityNode rdf:ID="CN2">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#VL1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:Breaker rdf:ID="BRK1">
        \\    <cim:IdentifiedObject.name>Bus Coupler</cim:IdentifiedObject.name>
        \\    <cim:Switch.open>false</cim:Switch.open>
        \\  </cim:Breaker>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#BRK1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="T2">
        \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#BRK1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN2"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;

    var model = try CimModel.init(gpa, eq_xml);
    defer model.deinit(gpa);

    var topo = try TopologyResolver.init(gpa, &model);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    defer conv.deinit();
    var network = try conv.convert();
    defer network.deinit(gpa);

    const vl = &network.substations.items[0].voltage_levels.items[0];
    try std.testing.expectEqual(@as(usize, 1), vl.node_breaker_topology.switches.items.len);

    const sw = vl.node_breaker_topology.switches.items[0];
    try std.testing.expectEqualStrings("BRK1", sw.id);
    try std.testing.expectEqualStrings("Bus Coupler", sw.name.?);
    try std.testing.expectEqual(0, sw.node1);
    try std.testing.expectEqual(1, sw.node2);
    try std.testing.expectEqual(false, sw.open);
    try std.testing.expectEqual(SwitchKind.breaker, sw.kind);
}

test "converter uses mRID for substation id" {
    const xml =
        \\<?xml version="1.0"?>
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"xmlns:cim="http://iec.ch/TC57/CIM100#"xmlns:md="http://iec.ch/TC57/61970-552/ModelDescription/1#">
        \\<md:FullModel rdf:about="urn:uuid:test">
        \\  <md:Model.scenarioTime>2009-01-01T00:00:00Z</md:Model.scenarioTime>
        \\</md:FullModel>
        \\<cim:Substation rdf:ID="_S1">
        \\  <cim:IdentifiedObject.mRID>S1</cim:IdentifiedObject.mRID>
        \\  <cim:IdentifiedObject.name>Station 1</cim:IdentifiedObject.name>
        \\</cim:Substation>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, xml);
    defer model.deinit(gpa);
    var resolver = try TopologyResolver.init(gpa, &model);
    defer resolver.deinit();
    var conv = Converter.init(gpa, &model, &resolver);
    defer conv.deinit();

    var network = try conv.convert();
    defer network.deinit(gpa);

    // Should use mRID "S1", not rdf:ID "_S1"
    try std.testing.expectEqualStrings("S1", network.substations.items[0].id);
}

test "converter populates geographicalTags from SubGeographicalRegion" {
    const xml =
        \\<?xml version="1.0"?>
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"xmlns:cim="http://iec.ch/TC57/CIM100#"xmlns:md="http://iec.ch/TC57/61970-552/ModelDescription/1#">
        \\<md:FullModel rdf:about="urn:uuid:test">
        \\  <md:Model.scenarioTime>2009-01-01T00:00:00Z</md:Model.scenarioTime>
        \\</md:FullModel>
        \\<cim:SubGeographicalRegion rdf:ID="_region_SGR">
        \\  <cim:IdentifiedObject.name>default region</cim:IdentifiedObject.name>
        \\</cim:SubGeographicalRegion>
        \\<cim:Substation rdf:ID="_S1">
        \\  <cim:IdentifiedObject.mRID>S1</cim:IdentifiedObject.mRID>
        \\  <cim:IdentifiedObject.name>Station 1</cim:IdentifiedObject.name>
        \\  <cim:Substation.Region rdf:resource="#_region_SGR"/>
        \\</cim:Substation>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, xml);
    defer model.deinit(gpa);
    var resolver = try TopologyResolver.init(gpa, &model);
    defer resolver.deinit();
    var conv = Converter.init(gpa, &model, &resolver);
    defer conv.deinit();

    var network = try conv.convert();
    defer network.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), network.substations.items[0].geo_tags.items.len);
    try std.testing.expectEqualStrings("default region", network.substations.items[0].geo_tags.items[0]);
}

test "Converter - converts RatioTapChanger on TwoWindingsTransformer" {
    const gpa = std.testing.allocator;

    const eq_xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:test">
        \\    <md:Model.scenarioTime>2009-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
        \\  <cim:Substation rdf:ID="Sub1"/>
        \\  <cim:VoltageLevel rdf:ID="VL1">
        \\    <cim:VoltageLevel.Substation rdf:resource="#Sub1"/>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#BV1"/>
        \\  </cim:VoltageLevel>
        \\  <cim:VoltageLevel rdf:ID="VL2">
        \\    <cim:VoltageLevel.Substation rdf:resource="#Sub1"/>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#BV2"/>
        \\  </cim:VoltageLevel>
        \\  <cim:BaseVoltage rdf:ID="BV1">
        \\    <cim:BaseVoltage.nominalVoltage>225</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="BV2">
        \\    <cim:BaseVoltage.nominalVoltage>400</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:ConnectivityNode rdf:ID="CN1">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#VL1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ConnectivityNode rdf:ID="CN2">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#VL2"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:PowerTransformer rdf:ID="TR1">
        \\    <cim:IdentifiedObject.name>Tap Transformer</cim:IdentifiedObject.name>
        \\  </cim:PowerTransformer>
        \\  <cim:PowerTransformerEnd rdf:ID="TR1_End1">
        \\    <cim:TransformerEnd.endNumber>1</cim:TransformerEnd.endNumber>
        \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#TR1"/>
        \\    <cim:PowerTransformerEnd.ratedU>225</cim:PowerTransformerEnd.ratedU>
        \\    <cim:PowerTransformerEnd.ratedS>100</cim:PowerTransformerEnd.ratedS>
        \\    <cim:PowerTransformerEnd.r>2</cim:PowerTransformerEnd.r>
        \\    <cim:PowerTransformerEnd.x>14</cim:PowerTransformerEnd.x>
        \\    <cim:PowerTransformerEnd.g>0</cim:PowerTransformerEnd.g>
        \\    <cim:PowerTransformerEnd.b>0</cim:PowerTransformerEnd.b>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:PowerTransformerEnd rdf:ID="TR1_End2">
        \\    <cim:TransformerEnd.endNumber>2</cim:TransformerEnd.endNumber>
        \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#TR1"/>
        \\    <cim:PowerTransformerEnd.ratedU>400</cim:PowerTransformerEnd.ratedU>
        \\    <cim:PowerTransformerEnd.r>0</cim:PowerTransformerEnd.r>
        \\    <cim:PowerTransformerEnd.x>0</cim:PowerTransformerEnd.x>
        \\    <cim:PowerTransformerEnd.g>0</cim:PowerTransformerEnd.g>
        \\    <cim:PowerTransformerEnd.b>0</cim:PowerTransformerEnd.b>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:Terminal rdf:ID="T1">
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#TR1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="T2">
        \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#TR1"/>
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#CN2"/>
        \\  </cim:Terminal>
        \\  <cim:RatioTapChanger rdf:ID="RTC1">
        \\    <cim:RatioTapChanger.TransformerEnd rdf:resource="#TR1_End1"/>
        \\    <cim:TapChanger.lowStep>0</cim:TapChanger.lowStep>
        \\    <cim:TapChanger.highStep>2</cim:TapChanger.highStep>
        \\    <cim:TapChanger.neutralStep>1</cim:TapChanger.neutralStep>
        \\    <cim:TapChanger.normalStep>1</cim:TapChanger.normalStep>
        \\    <cim:TapChanger.ltcFlag>true</cim:TapChanger.ltcFlag>
        \\    <cim:RatioTapChanger.RatioTapChangerTable rdf:resource="#RTC1_Table"/>
        \\  </cim:RatioTapChanger>
        \\  <cim:RatioTapChangerTable rdf:ID="RTC1_Table"/>
        \\  <cim:RatioTapChangerTablePoint rdf:ID="RTC1_P0">
        \\    <cim:RatioTapChangerTablePoint.RatioTapChangerTable rdf:resource="#RTC1_Table"/>
        \\    <cim:TapChangerTablePoint.step>0</cim:TapChangerTablePoint.step>
        \\    <cim:TapChangerTablePoint.ratio>0.85</cim:TapChangerTablePoint.ratio>
        \\  </cim:RatioTapChangerTablePoint>
        \\  <cim:RatioTapChangerTablePoint rdf:ID="RTC1_P1">
        \\    <cim:RatioTapChangerTablePoint.RatioTapChangerTable rdf:resource="#RTC1_Table"/>
        \\    <cim:TapChangerTablePoint.step>1</cim:TapChangerTablePoint.step>
        \\    <cim:TapChangerTablePoint.ratio>1.0</cim:TapChangerTablePoint.ratio>
        \\  </cim:RatioTapChangerTablePoint>
        \\  <cim:RatioTapChangerTablePoint rdf:ID="RTC1_P2">
        \\    <cim:RatioTapChangerTablePoint.RatioTapChangerTable rdf:resource="#RTC1_Table"/>
        \\    <cim:TapChangerTablePoint.step>2</cim:TapChangerTablePoint.step>
        \\    <cim:TapChangerTablePoint.ratio>1.15</cim:TapChangerTablePoint.ratio>
        \\  </cim:RatioTapChangerTablePoint>
        \\</rdf:RDF>
    ;

    var model = try CimModel.init(gpa, eq_xml);
    defer model.deinit(gpa);

    var topo = try TopologyResolver.init(gpa, &model);
    defer topo.deinit();

    var conv = Converter.init(gpa, &model, &topo);
    defer conv.deinit();
    var network = try conv.convert();
    defer network.deinit(gpa);

    const sub = &network.substations.items[0];
    try std.testing.expectEqual(@as(usize, 1), sub.two_winding_transformers.items.len);

    const tr = sub.two_winding_transformers.items[0];
    try std.testing.expectEqualStrings("TR1", tr.id);

    // Check ratio tap changer
    try std.testing.expect(tr.ratio_tap_changer != null);
    const rtc = tr.ratio_tap_changer.?;
    try std.testing.expectEqual(@as(i32, 0), rtc.low_tap_position);
    try std.testing.expectEqual(@as(i32, 1), rtc.tap_position); // normalStep
    try std.testing.expectEqual(true, rtc.load_tap_changing_capabilities);
    try std.testing.expectEqual(false, rtc.regulating); // no SSH data

    // Check steps (should be 3: positions 0, 1, 2)
    try std.testing.expectEqual(@as(usize, 3), rtc.steps.items.len);

    // CGMES ratio is inverted for IIDM: rho = 1/cgmes_ratio
    try std.testing.expectApproxEqRel(@as(f64, 1.0 / 0.85), rtc.steps.items[0].rho, 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 1.0), rtc.steps.items[1].rho, 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 1.0 / 1.15), rtc.steps.items[2].rho, 1e-9);
}
