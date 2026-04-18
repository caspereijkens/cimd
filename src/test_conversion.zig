/// Integration tests for the conversion pipeline.
///
/// A single minimal EQ XML exercises all edge cases added in this branch.
/// Each test block runs the full converter.convert() pipeline and checks
/// one specific behaviour; re-parsing is cheap for a model this small.
const std = @import("std");
const converter = @import("converter.zig");
const CimModel = @import("cim_model.zig").CimModel;
const CimSsh = @import("cim_ssh.zig").CimSsh;

/// Minimal EQ model with enough objects to exercise every edge case.
/// Objects and their purpose:
///   FullModel        — scenarioTime 8 h after created → forecastDistance = 480 min
///   SS1/SS2          — two substations (SS2 only exists for VL2)
///   VL1/VL2          — voltage levels; LINE1 bridges them
///   BV220            — base voltage (220 kV)
///   CN_*             — one ConnectivityNode per equipment terminal
///   BusbarSection1             — busbar section so VL1 has a node-breaker topology
///   LOAD1            — load → gets a `detail` extension
///   SHUNT1           — shunt compensator (exercises section/bPerSection parsing)
///   SVC1             — static var compensator with regulationMode=voltage
///   THG1+FF1+GEN_TH  — thermal generator; FossilFuel → fuel type "coal"
///   HGU1+GEN_HY      — hydro generator; energy_source=.hydro
///   GEN_CO           — condenser (SynchronousMachine.type contains "condenser") + qPercent=50
///   RCC1+CD1+GEN_CU  — generator with ReactiveCapabilityCurve (should ignore minQ/maxQ)
///   LINE_CTR         — ACLineSegment used as ConnectivityNode container (boundary container)
///   CN_BNDRY         — boundary CN (container = LINE_CTR, not a VL)
///   LINE1            — normal line between VL1 and VL2; gch=4, bch=6
///   LINE_BNDRY       — line from VL1 to CN_BNDRY → creates fictitious VL
///   CA1+TF1          — ControlArea with one TieFlow boundary
const EQ_XML =
    \\<rdf:RDF>
    \\  <!-- Main EQ FullModel (index 0). scenarioTime 8h after created → forecastDistance = 480 min. -->
    \\  <md:FullModel rdf:about="_FM1">
    \\    <md:Model.scenarioTime>2026-01-01T09:00:00Z</md:Model.scenarioTime>
    \\    <md:Model.created>2026-01-01T01:00:00Z</md:Model.created>
    \\  </md:FullModel>
    \\  <!-- EQBD stub (index 1). The cgmesMetadataModels loop expects 2+ FullModels. -->
    \\  <md:FullModel rdf:about="_FM_EQBD">
    \\    <md:Model.scenarioTime>2026-01-01T09:00:00Z</md:Model.scenarioTime>
    \\    <md:Model.created>2026-01-01T01:00:00Z</md:Model.created>
    \\  </md:FullModel>
    \\
    \\  <cim:GeographicalRegion rdf:ID="_GR1">
    \\    <cim:IdentifiedObject.mRID>GR1</cim:IdentifiedObject.mRID>
    \\    <cim:IdentifiedObject.name>TestRegion</cim:IdentifiedObject.name>
    \\  </cim:GeographicalRegion>
    \\  <cim:SubGeographicalRegion rdf:ID="_SGR1">
    \\    <cim:IdentifiedObject.mRID>SGR1</cim:IdentifiedObject.mRID>
    \\    <cim:SubGeographicalRegion.Region rdf:resource="#_GR1"/>
    \\  </cim:SubGeographicalRegion>
    \\
    \\  <cim:Substation rdf:ID="_SS1">
    \\    <cim:IdentifiedObject.mRID>SS1</cim:IdentifiedObject.mRID>
    \\    <cim:Substation.Region rdf:resource="#_SGR1"/>
    \\  </cim:Substation>
    \\  <cim:Substation rdf:ID="_SS2">
    \\    <cim:IdentifiedObject.mRID>SS2</cim:IdentifiedObject.mRID>
    \\    <cim:Substation.Region rdf:resource="#_SGR1"/>
    \\  </cim:Substation>
    \\
    \\  <cim:BaseVoltage rdf:ID="_BV220">
    \\    <cim:IdentifiedObject.mRID>BV220</cim:IdentifiedObject.mRID>
    \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\
    \\  <cim:VoltageLevel rdf:ID="_VL1">
    \\    <cim:IdentifiedObject.mRID>VL1</cim:IdentifiedObject.mRID>
    \\    <cim:VoltageLevel.Substation rdf:resource="#_SS1"/>
    \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_BV220"/>
    \\  </cim:VoltageLevel>
    \\  <cim:VoltageLevel rdf:ID="_VL2">
    \\    <cim:IdentifiedObject.mRID>VL2</cim:IdentifiedObject.mRID>
    \\    <cim:VoltageLevel.Substation rdf:resource="#_SS2"/>
    \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_BV220"/>
    \\  </cim:VoltageLevel>
    \\
    \\  <!-- Boundary line container: an ACLineSegment whose ID is used as CN container -->
    \\  <cim:ACLineSegment rdf:ID="_LINE_CTR">
    \\    <cim:IdentifiedObject.mRID>LINE_CTR</cim:IdentifiedObject.mRID>
    \\  </cim:ACLineSegment>
    \\
    \\  <!-- ConnectivityNodes: one per equipment terminal group in VL1 -->
    \\  <cim:ConnectivityNode rdf:ID="_CN_BusbarSection">
    \\    <cim:IdentifiedObject.mRID>CN_BusbarSection</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:ConnectivityNode rdf:ID="_CN_LOAD">
    \\    <cim:IdentifiedObject.mRID>CN_LOAD</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:ConnectivityNode rdf:ID="_CN_SHUNT">
    \\    <cim:IdentifiedObject.mRID>CN_SHUNT</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:ConnectivityNode rdf:ID="_CN_SVC">
    \\    <cim:IdentifiedObject.mRID>CN_SVC</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:ConnectivityNode rdf:ID="_CN_GEN_TH">
    \\    <cim:IdentifiedObject.mRID>CN_GEN_TH</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:ConnectivityNode rdf:ID="_CN_GEN_HY">
    \\    <cim:IdentifiedObject.mRID>CN_GEN_HY</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:ConnectivityNode rdf:ID="_CN_GEN_CO">
    \\    <cim:IdentifiedObject.mRID>CN_GEN_CO</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:ConnectivityNode rdf:ID="_CN_GEN_CU">
    \\    <cim:IdentifiedObject.mRID>CN_GEN_CU</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <!-- VL2 side of LINE1 -->
    \\  <cim:ConnectivityNode rdf:ID="_CN_VL2">
    \\    <cim:IdentifiedObject.mRID>CN_VL2</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL2"/>
    \\  </cim:ConnectivityNode>
    \\  <!-- Boundary CN: container is LINE_CTR (not a VoltageLevel) -->
    \\  <cim:ConnectivityNode rdf:ID="_CN_BNDRY">
    \\    <cim:IdentifiedObject.mRID>CN_BNDRY</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_LINE_CTR"/>
    \\  </cim:ConnectivityNode>
    \\
    \\  <!-- BusbarSection in VL1 -->
    \\  <cim:BusbarSection rdf:ID="_BusbarSection1">
    \\    <cim:IdentifiedObject.mRID>BusbarSection1</cim:IdentifiedObject.mRID>
    \\  </cim:BusbarSection>
    \\  <cim:Terminal rdf:ID="_T_BusbarSection1">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BusbarSection1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_BusbarSection"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\
    \\  <!-- Load (gets a detail extension) -->
    \\  <cim:EnergyConsumer rdf:ID="_LOAD1">
    \\    <cim:IdentifiedObject.mRID>LOAD1</cim:IdentifiedObject.mRID>
    \\    <cim:IdentifiedObject.name>Load One</cim:IdentifiedObject.name>
    \\  </cim:EnergyConsumer>
    \\  <cim:Terminal rdf:ID="_T_LOAD1">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LOAD1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_LOAD"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\
    \\  <!-- LinearShuntCompensator -->
    \\  <cim:LinearShuntCompensator rdf:ID="_SHUNT1">
    \\    <cim:IdentifiedObject.mRID>SHUNT1</cim:IdentifiedObject.mRID>
    \\    <cim:ShuntCompensator.sections>2</cim:ShuntCompensator.sections>
    \\    <cim:ShuntCompensator.maximumSections>4</cim:ShuntCompensator.maximumSections>
    \\    <cim:LinearShuntCompensator.bPerSection>0.01</cim:LinearShuntCompensator.bPerSection>
    \\    <cim:LinearShuntCompensator.gPerSection>0.001</cim:LinearShuntCompensator.gPerSection>
    \\    <cim:RegulatingCondEq.controlEnabled>true</cim:RegulatingCondEq.controlEnabled>
    \\  </cim:LinearShuntCompensator>
    \\  <cim:Terminal rdf:ID="_T_SHUNT1">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_SHUNT1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_SHUNT"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\
    \\  <!-- StaticVarCompensator: voltage regulation mode -->
    \\  <cim:StaticVarCompensator rdf:ID="_SVC1">
    \\    <cim:IdentifiedObject.mRID>SVC1</cim:IdentifiedObject.mRID>
    \\    <cim:StaticVarCompensator.bMin>-0.05</cim:StaticVarCompensator.bMin>
    \\    <cim:StaticVarCompensator.bMax>0.05</cim:StaticVarCompensator.bMax>
    \\    <cim:StaticVarCompensator.regulationMode rdf:resource="#StaticVarCompensatorItesMode.voltage"/>
    \\    <cim:RegulatingCondEq.controlEnabled>true</cim:RegulatingCondEq.controlEnabled>
    \\  </cim:StaticVarCompensator>
    \\  <cim:Terminal rdf:ID="_T_SVC1">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_SVC1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_SVC"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\
    \\  <!-- ThermalGeneratingUnit + FossilFuel (coal) + SynchronousMachine -->
    \\  <cim:ThermalGeneratingUnit rdf:ID="_THG1">
    \\    <cim:IdentifiedObject.mRID>THG1</cim:IdentifiedObject.mRID>
    \\    <cim:GeneratingUnit.minOperatingP>50</cim:GeneratingUnit.minOperatingP>
    \\    <cim:GeneratingUnit.maxOperatingP>500</cim:GeneratingUnit.maxOperatingP>
    \\  </cim:ThermalGeneratingUnit>
    \\  <cim:FossilFuel rdf:ID="_FF1">
    \\    <cim:FossilFuel.ThermalGeneratingUnit rdf:resource="#_THG1"/>
    \\    <cim:FossilFuel.fossilFuelType rdf:resource="#FuelType.coal"/>
    \\  </cim:FossilFuel>
    \\  <cim:SynchronousMachine rdf:ID="_GEN_TH">
    \\    <cim:IdentifiedObject.mRID>GEN_TH</cim:IdentifiedObject.mRID>
    \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_THG1"/>
    \\    <cim:RotatingMachine.ratedS>600</cim:RotatingMachine.ratedS>
    \\    <cim:SynchronousMachine.minQ>-200</cim:SynchronousMachine.minQ>
    \\    <cim:SynchronousMachine.maxQ>200</cim:SynchronousMachine.maxQ>
    \\    <cim:RegulatingCondEq.controlEnabled>false</cim:RegulatingCondEq.controlEnabled>
    \\  </cim:SynchronousMachine>
    \\  <cim:Terminal rdf:ID="_T_GEN_TH">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_GEN_TH"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_GEN_TH"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\
    \\  <!-- HydroGeneratingUnit + SynchronousMachine -->
    \\  <cim:HydroGeneratingUnit rdf:ID="_HGU1">
    \\    <cim:IdentifiedObject.mRID>HGU1</cim:IdentifiedObject.mRID>
    \\  </cim:HydroGeneratingUnit>
    \\  <cim:SynchronousMachine rdf:ID="_GEN_HY">
    \\    <cim:IdentifiedObject.mRID>GEN_HY</cim:IdentifiedObject.mRID>
    \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_HGU1"/>
    \\  </cim:SynchronousMachine>
    \\  <cim:Terminal rdf:ID="_T_GEN_HY">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_GEN_HY"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_GEN_HY"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\
    \\  <!-- Condenser: SynchronousMachine.type is a rdf:resource enum containing "ondenser" -->
    \\  <cim:SynchronousMachine rdf:ID="_GEN_CO">
    \\    <cim:IdentifiedObject.mRID>GEN_CO</cim:IdentifiedObject.mRID>
    \\    <cim:SynchronousMachine.type rdf:resource="#SynchronousMachineKind.generatorOrCondenser"/>
    \\    <cim:SynchronousMachine.qPercent>50.0</cim:SynchronousMachine.qPercent>
    \\  </cim:SynchronousMachine>
    \\  <cim:Terminal rdf:ID="_T_GEN_CO">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_GEN_CO"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_GEN_CO"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\
    \\  <!-- ReactiveCapabilityCurve: GEN_CU should use curve, not its minQ/maxQ fallback -->
    \\  <cim:ReactiveCapabilityCurve rdf:ID="_RCC1">
    \\    <cim:IdentifiedObject.mRID>RCC1</cim:IdentifiedObject.mRID>
    \\  </cim:ReactiveCapabilityCurve>
    \\  <cim:CurveData rdf:ID="_CD1">
    \\    <cim:CurveData.Curve rdf:resource="#_RCC1"/>
    \\    <cim:CurveData.xvalue>100</cim:CurveData.xvalue>
    \\    <cim:CurveData.y1value>-150</cim:CurveData.y1value>
    \\    <cim:CurveData.y2value>250</cim:CurveData.y2value>
    \\  </cim:CurveData>
    \\  <cim:SynchronousMachine rdf:ID="_GEN_CU">
    \\    <cim:IdentifiedObject.mRID>GEN_CU</cim:IdentifiedObject.mRID>
    \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_RCC1"/>
    \\    <cim:SynchronousMachine.minQ>-999</cim:SynchronousMachine.minQ>
    \\    <cim:SynchronousMachine.maxQ>999</cim:SynchronousMachine.maxQ>
    \\  </cim:SynchronousMachine>
    \\  <cim:Terminal rdf:ID="_T_GEN_CU">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_GEN_CU"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_GEN_CU"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\
    \\  <!-- Normal ACLineSegment between VL1 (CN_LOAD) and VL2 (CN_VL2). gch=4, bch=6. -->
    \\  <cim:ACLineSegment rdf:ID="_LINE1">
    \\    <cim:IdentifiedObject.mRID>LINE1</cim:IdentifiedObject.mRID>
    \\    <cim:ACLineSegment.r>1.0</cim:ACLineSegment.r>
    \\    <cim:ACLineSegment.x>2.0</cim:ACLineSegment.x>
    \\    <cim:ACLineSegment.gch>4.0</cim:ACLineSegment.gch>
    \\    <cim:ACLineSegment.bch>6.0</cim:ACLineSegment.bch>
    \\  </cim:ACLineSegment>
    \\  <cim:Terminal rdf:ID="_T_LINE1_1">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_LOAD"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\  <cim:Terminal rdf:ID="_T_LINE1_2">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_VL2"/>
    \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\
    \\  <!-- Boundary ACLineSegment: terminal 2 → CN_BNDRY (container = LINE_CTR, not a VL) -->
    \\  <cim:ACLineSegment rdf:ID="_LINE_BNDRY">
    \\    <cim:IdentifiedObject.mRID>LINE_BNDRY</cim:IdentifiedObject.mRID>
    \\    <cim:ACLineSegment.r>0.5</cim:ACLineSegment.r>
    \\    <cim:ACLineSegment.x>1.0</cim:ACLineSegment.x>
    \\  </cim:ACLineSegment>
    \\  <cim:Terminal rdf:ID="_T_BNDRY_1">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE_BNDRY"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_BusbarSection"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\  <cim:Terminal rdf:ID="_T_BNDRY_2">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE_BNDRY"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_BNDRY"/>
    \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\
    \\  <!-- Breaker in VL1: CN_BusbarSection <-> CN_SW, normalOpen=true -->
    \\  <cim:ConnectivityNode rdf:ID="_CN_SW">
    \\    <cim:IdentifiedObject.mRID>CN_SW</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:Breaker rdf:ID="_BRK1">
    \\    <cim:IdentifiedObject.mRID>BRK1</cim:IdentifiedObject.mRID>
    \\    <cim:Switch.normalOpen>true</cim:Switch.normalOpen>
    \\  </cim:Breaker>
    \\  <cim:Terminal rdf:ID="_T_BRK1_1">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRK1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_BusbarSection"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\  <cim:Terminal rdf:ID="_T_BRK1_2">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRK1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_SW"/>
    \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\
    \\  <!-- ControlArea with one TieFlow boundary -->
    \\  <cim:ControlArea rdf:ID="_CA1">
    \\    <cim:IdentifiedObject.mRID>CA1</cim:IdentifiedObject.mRID>
    \\    <cim:IdentifiedObject.name>TestArea</cim:IdentifiedObject.name>
    \\    <cim:ControlArea.type rdf:resource="#ControlAreaTypeKind.Interchange"/>
    \\  </cim:ControlArea>
    \\  <cim:TieFlow rdf:ID="_TF1">
    \\    <cim:TieFlow.ControlArea rdf:resource="#_CA1"/>
    \\    <cim:TieFlow.Terminal rdf:resource="#_T_LINE1_1"/>
    \\  </cim:TieFlow>
    \\</rdf:RDF>
;

/// SSH overlay used by SSH-specific tests.
/// Covers three scenarios simultaneously (separate tests read the same parse):
///   - T_LOAD1 marked disconnected  → fictitious switch for an EnergyConsumer (non-injection)
///   - BRK1 open/retained state     → switch state from SSH, not EQ
///   - LOAD1 p/q values             → p0/q0 from SSH EnergyConsumer.p/q
/// SSH XML includes a FullModel with times distinct from EQ so case_date /
/// forecastDistance tests can verify the SSH values take precedence.
///   EQ:  scenarioTime=2026-01-01T09:00Z, created=2026-01-01T01:00Z → 480 min
///   SSH: scenarioTime=2026-01-02T15:00Z, created=2026-01-02T12:00Z → 180 min
const SSH_XML =
    \\<rdf:RDF>
    \\  <md:FullModel rdf:about="urn:uuid:SSH_FM1">
    \\    <md:Model.scenarioTime>2026-01-02T15:00:00Z</md:Model.scenarioTime>
    \\    <md:Model.created>2026-01-02T12:00:00Z</md:Model.created>
    \\    <md:Model.profile>http://iec.ch/TC57/ns/CIM/SteadyStateHypothesis-EU/3.0</md:Model.profile>
    \\    <md:Model.version>001</md:Model.version>
    \\  </md:FullModel>
    \\  <cim:ACDCTerminal rdf:about="#_T_LOAD1">
    \\    <cim:ACDCTerminal.connected>false</cim:ACDCTerminal.connected>
    \\  </cim:ACDCTerminal>
    \\  <cim:Breaker rdf:about="#_BRK1">
    \\    <cim:Switch.open>true</cim:Switch.open>
    \\    <cim:Switch.retained>false</cim:Switch.retained>
    \\  </cim:Breaker>
    \\  <cim:EnergyConsumer rdf:about="#_LOAD1">
    \\    <cim:EnergyConsumer.p>100.0</cim:EnergyConsumer.p>
    \\    <cim:EnergyConsumer.q>50.0</cim:EnergyConsumer.q>
    \\  </cim:EnergyConsumer>
    \\</rdf:RDF>
;

/// Find a generator by mRID across all VLs in all substations.
fn find_generator(network: anytype, mrid: []const u8) ?@TypeOf(network.substations.items[0].voltage_levels.items[0].generators.items[0]) {
    for (network.substations.items) |substation| {
        for (substation.voltage_levels.items) |voltage_level| {
            for (voltage_level.generators.items) |gen| {
                if (std.mem.eql(u8, gen.id, mrid)) return gen;
            }
        }
    }
    return null;
}

/// Find an extension by equipment ID.
fn find_extension(network: anytype, id: []const u8) ?@TypeOf(network.extensions.items[0]) {
    for (network.extensions.items) |ext| {
        if (std.mem.eql(u8, ext.id, id)) return ext;
    }
    return null;
}

/// Find a line by mRID.
fn find_line(network: anytype, mrid: []const u8) ?@TypeOf(network.lines.items[0]) {
    for (network.lines.items) |line| {
        if (std.mem.eql(u8, line.id, mrid)) return line;
    }
    return null;
}

/// Find a BusbarSection by mRID across all VLs in all substations.
fn find_busbar_section(network: anytype, mrid: []const u8) ?@TypeOf(network.substations.items[0].voltage_levels.items[0].node_breaker_topology.busbar_sections.items[0]) {
    for (network.substations.items) |substation| {
        for (substation.voltage_levels.items) |vl| {
            for (vl.node_breaker_topology.busbar_sections.items) |bbs| {
                if (std.mem.eql(u8, bbs.id, mrid)) return bbs;
            }
        }
    }
    return null;
}

/// Find a Switch by id across all VLs in all substations.
fn find_switch(network: anytype, id: []const u8) ?@TypeOf(network.substations.items[0].voltage_levels.items[0].node_breaker_topology.switches.items[0]) {
    for (network.substations.items) |substation| {
        for (substation.voltage_levels.items) |vl| {
            for (vl.node_breaker_topology.switches.items) |sw| {
                if (std.mem.eql(u8, sw.id, id)) return sw;
            }
        }
    }
    return null;
}

/// Find a Load by mRID across all VLs in all substations.
fn find_load(network: anytype, mrid: []const u8) ?@TypeOf(network.substations.items[0].voltage_levels.items[0].loads.items[0]) {
    for (network.substations.items) |substation| {
        for (substation.voltage_levels.items) |vl| {
            for (vl.loads.items) |load| {
                if (std.mem.eql(u8, load.id, mrid)) return load;
            }
        }
    }
    return null;
}

// ── forecastDistance ─────────────────────────────────────────────────────────

test "forecastDistance: scenarioTime 8h after created → 480 minutes" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    // 2026-01-01T09:00Z − 2026-01-01T01:00Z = 8h = 480 min
    try std.testing.expectEqual(@as(u32, 480), network.forecast_distance);
}

// ── Line gch/bch split ────────────────────────────────────────────────────────

test "line: gch and bch split equally across both sides" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const line = find_line(network, "LINE1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(f64, 1.0), line.r);
    try std.testing.expectEqual(@as(f64, 2.0), line.x);
    // gch=4.0 → g1=g2=2.0; bch=6.0 → b1=b2=3.0
    try std.testing.expectEqual(@as(f64, 2.0), line.g1);
    try std.testing.expectEqual(@as(f64, 2.0), line.g2);
    try std.testing.expectEqual(@as(f64, 3.0), line.b1);
    try std.testing.expectEqual(@as(f64, 3.0), line.b2);
}

// ── Boundary line / fictitious VL ─────────────────────────────────────────────

test "boundary line: creates a fictitious VL and LINE_BNDRY lands in it" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    // Exactly one boundary CN → exactly one fictitious VL.
    try std.testing.expectEqual(@as(usize, 1), network.fictitious_voltage_levels.items.len);

    // The fictitious VL id is "<CN_mRID>_VL".
    const fvoltage_level = network.fictitious_voltage_levels.items[0];
    try std.testing.expectEqualStrings("CN_BNDRY_VL", fvoltage_level.id);

    // LINE_BNDRY must appear in the output.
    const line = find_line(network, "LINE_BNDRY") orelse return error.TestFailed;

    // One side is in VL1; the other is in the fictitious VL.
    const has_fict_voltage_level_side = std.mem.eql(u8, line.voltage_level1_id, "CN_BNDRY_VL") or
        std.mem.eql(u8, line.voltage_level2_id, "CN_BNDRY_VL");
    try std.testing.expect(has_fict_voltage_level_side);
}

// ── Generator energy source ───────────────────────────────────────────────────

test "generator: energy_source derived from GeneratingUnit CIM type" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const gen_th = find_generator(network, "GEN_TH") orelse return error.TestFailed;
    try std.testing.expectEqual(.thermal, gen_th.energy_source);

    const gen_hy = find_generator(network, "GEN_HY") orelse return error.TestFailed;
    try std.testing.expectEqual(.hydro, gen_hy.energy_source);
}

test "generator: min_p and max_p read from GeneratingUnit" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const gen = find_generator(network, "GEN_TH") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(?f64, 50.0), gen.min_p);
    try std.testing.expectEqual(@as(?f64, 500.0), gen.max_p);
}

// ── Condenser detection ───────────────────────────────────────────────────────

test "generator: is_condenser true when SynchronousMachine.type contains condenser" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const condenser = find_generator(network, "GEN_CO") orelse return error.TestFailed;
    try std.testing.expect(condenser.is_condenser);

    // Non-condensers must not be flagged.
    const gen_th = find_generator(network, "GEN_TH") orelse return error.TestFailed;
    try std.testing.expect(!gen_th.is_condenser);
}

// ── Reactive limits: curve vs minQ/maxQ fallback ──────────────────────────────

test "generator: reactive capability curve takes precedence over minQ/maxQ" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const gen_cu = find_generator(network, "GEN_CU") orelse return error.TestFailed;
    // Has a curve → curve_points populated, min_max_reactive_limits must be null.
    try std.testing.expectEqual(@as(usize, 1), gen_cu.reactive_capability_curve_points.items.len);
    try std.testing.expect(gen_cu.min_max_reactive_limits == null);
    const pt = gen_cu.reactive_capability_curve_points.items[0];
    try std.testing.expectEqual(@as(f64, 100.0), pt.p);
    try std.testing.expectEqual(@as(f64, -150.0), pt.min_q);
    try std.testing.expectEqual(@as(f64, 250.0), pt.max_q);
}

test "generator: minQ/maxQ used as fallback when no curve" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const gen_th = find_generator(network, "GEN_TH") orelse return error.TestFailed;
    // No curve → min_max_reactive_limits populated from minQ/maxQ.
    try std.testing.expectEqual(@as(usize, 0), gen_th.reactive_capability_curve_points.items.len);
    const limits = gen_th.min_max_reactive_limits orelse return error.TestFailed;
    try std.testing.expectEqual(@as(f64, -200.0), limits.min_q);
    try std.testing.expectEqual(@as(f64, 200.0), limits.max_q);
}

// ── SVC regulation mode ───────────────────────────────────────────────────────

test "SVC: regulationMode voltage fragment → .voltage" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    for (network.substations.items) |substation| {
        for (substation.voltage_levels.items) |voltage_level| {
            for (voltage_level.static_var_compensators.items) |svc| {
                if (std.mem.eql(u8, svc.id, "SVC1")) {
                    try std.testing.expectEqual(.voltage, svc.regulation_mode);
                    try std.testing.expect(svc.regulating);
                    return;
                }
            }
        }
    }
    return error.TestFailed;
}

// ── detail extension ──────────────────────────────────────────────────────────

test "detail extension: every load gets fixedActivePower etc. all zero" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const ext = find_extension(network, "LOAD1") orelse return error.TestFailed;
    const detail = ext.detail orelse return error.TestFailed;
    try std.testing.expectEqual(@as(f64, 0.0), detail.fixed_active_power);
    try std.testing.expectEqual(@as(f64, 0.0), detail.fixed_reactive_power);
    try std.testing.expectEqual(@as(f64, 0.0), detail.variable_active_power);
    try std.testing.expectEqual(@as(f64, 0.0), detail.variable_reactive_power);

    // extension_versions must include "detail"
    var found_version = false;
    for (network.extension_versions.items) |ev| {
        if (std.mem.eql(u8, ev.extension_name, "detail")) {
            found_version = true;
            break;
        }
    }
    try std.testing.expect(found_version);
}

// ── coordinatedReactiveControl extension ──────────────────────────────────────

test "coordinatedReactiveControl: generator with qPercent gets extension" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const ext = find_extension(network, "GEN_CO") orelse return error.TestFailed;
    const crc = ext.coordinated_reactive_control orelse return error.TestFailed;
    try std.testing.expectEqual(@as(f64, 50.0), crc.q_percent);

    // GEN_TH has no qPercent → no coordinatedReactiveControl extension for it.
    if (find_extension(network, "GEN_TH")) |th_ext| {
        try std.testing.expect(th_ext.coordinated_reactive_control == null);
    }
}

// ── ControlArea / areas ───────────────────────────────────────────────────────

test "areas: ControlArea produces one area with TieFlow boundary" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), network.areas.items.len);
    const area = network.areas.items[0];
    try std.testing.expectEqualStrings("CA1", area.id);
    try std.testing.expectEqualStrings("TestArea", area.name);
    // TF1 references T_LINE1_1 whose equipment is LINE1
    try std.testing.expectEqual(@as(usize, 1), area.boundaries.items.len);
    try std.testing.expectEqualStrings("LINE1", area.boundaries.items[0].id);
    try std.testing.expectEqualStrings("ONE", area.boundaries.items[0].side);
}

// ── Shunt compensator fields ──────────────────────────────────────────────────

test "shunt: section count, bPerSection, voltage_regulator_on parsed correctly" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    for (network.substations.items) |substation| {
        for (substation.voltage_levels.items) |voltage_level| {
            for (voltage_level.shunts.items) |shunt| {
                if (std.mem.eql(u8, shunt.id, "SHUNT1")) {
                    try std.testing.expectEqual(@as(u32, 2), shunt.section_count);
                    try std.testing.expectEqual(@as(u32, 4), shunt.shunt_linear_model.max_section_count);
                    try std.testing.expectEqual(@as(f64, 0.01), shunt.shunt_linear_model.b_per_section);
                    try std.testing.expectEqual(@as(f64, 0.001), shunt.shunt_linear_model.g_per_section);
                    try std.testing.expect(shunt.voltage_regulator_on);
                    return;
                }
            }
        }
    }
    return error.TestFailed;
}

// ── Line aliases ───────────────────────────────────────────────────────────────

test "line: both terminal aliases present with correct types and content" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const line = find_line(network, "LINE1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), line.aliases.items.len);

    var found_t1 = false;
    var found_t2 = false;
    for (line.aliases.items) |alias| {
        const type_str = switch (alias.type_info) {
            .static_string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, type_str, "CGMES.Terminal1")) {
            try std.testing.expectEqualStrings("T_LINE1_1", alias.content);
            found_t1 = true;
        }
        if (std.mem.eql(u8, type_str, "CGMES.Terminal2")) {
            try std.testing.expectEqualStrings("T_LINE1_2", alias.content);
            found_t2 = true;
        }
    }
    try std.testing.expect(found_t1);
    try std.testing.expect(found_t2);
}

test "line: CGMES.originalClass property is ACLineSegment" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const line = find_line(network, "LINE1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), line.properties.items.len);
    try std.testing.expectEqualStrings("CGMES.originalClass", line.properties.items[0].name);
    try std.testing.expectEqualStrings("ACLineSegment", line.properties.items[0].value);
}

// ── BusbarSection alias ───────────────────────────────────────────────────────

test "busbar section: CGMES.Terminal1 alias contains terminal mRID" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const bbs = find_busbar_section(network, "BusbarSection1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), bbs.aliases.items.len);
    try std.testing.expectEqualStrings("CGMES.Terminal1", bbs.aliases.items[0].type_info.static_string);
    // T_BusbarSection1 has no IdentifiedObject.mRID → fallback is strip_underscore(rdf:ID)
    try std.testing.expectEqualStrings("T_BusbarSection1", bbs.aliases.items[0].content);
}

// ── Switch aliases and properties ─────────────────────────────────────────────

test "switch: CGMES.Terminal1 and CGMES.Terminal2 aliases contain terminal mRIDs" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const sw = find_switch(network, "BRK1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), sw.aliases.items.len);

    var found_t1 = false;
    var found_t2 = false;
    for (sw.aliases.items) |alias| {
        const type_str = switch (alias.type_info) {
            .static_string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, type_str, "CGMES.Terminal1")) {
            // seq=1 terminal is T_BRK1_1 (strip_underscore fallback)
            try std.testing.expectEqualStrings("T_BRK1_1", alias.content);
            found_t1 = true;
        }
        if (std.mem.eql(u8, type_str, "CGMES.Terminal2")) {
            try std.testing.expectEqualStrings("T_BRK1_2", alias.content);
            found_t2 = true;
        }
    }
    try std.testing.expect(found_t1);
    try std.testing.expect(found_t2);
}

test "switch: CGMES.originalClass and CGMES.normalOpen properties" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    const sw = find_switch(network, "BRK1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), sw.properties.items.len);

    var found_class = false;
    var found_normal_open = false;
    for (sw.properties.items) |prop| {
        if (std.mem.eql(u8, prop.name, "CGMES.originalClass")) {
            try std.testing.expectEqualStrings("Breaker", prop.value);
            found_class = true;
        }
        if (std.mem.eql(u8, prop.name, "CGMES.normalOpen")) {
            try std.testing.expectEqualStrings("true", prop.value);
            found_normal_open = true;
        }
    }
    try std.testing.expect(found_class);
    try std.testing.expect(found_normal_open);
}

// ── Fictitious switches ───────────────────────────────────────────────────────

test "fictitious switch: created for structurally isolated SynchronousMachine" {
    // GEN_TH is a SynchronousMachine on CN_GEN_TH which has no switch, no BusbarSection,
    // and exactly one non-switch/non-BBS terminal.  PyPowSyBl synthesises a fictitious
    // open Breaker for it so node-breaker topology stays connected.
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    // Fictitious switch id = "<terminal_mRID>_SW_fict"
    const sw = find_switch(network, "T_GEN_TH_SW_fict") orelse return error.TestFailed;
    try std.testing.expect(sw.fictitious);
    try std.testing.expect(sw.open);
    try std.testing.expectEqual(.breaker, sw.kind);

    // Must carry CGMES.isCreatedForDisconnectedTerminal=true
    var found_marker = false;
    for (sw.properties.items) |prop| {
        if (std.mem.eql(u8, prop.name, "CGMES.isCreatedForDisconnectedTerminal")) {
            try std.testing.expectEqualStrings("true", prop.value);
            found_marker = true;
        }
    }
    try std.testing.expect(found_marker);
}

test "fictitious switch: not created for EnergyConsumer without SSH" {
    // Loads are never given fictitious switches by the structural isolation check —
    // only SynchronousMachine / LinearShuntCompensator / StaticVarCompensator are.
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var network = try converter.convert(gpa, &model, null);
    defer network.deinit(gpa);

    // LOAD1's terminal mRID is T_LOAD1; fictitious switch would be T_LOAD1_SW_fict.
    try std.testing.expect(find_switch(network, "T_LOAD1_SW_fict") == null);
}

// ── SSH overlay: switch state ─────────────────────────────────────────────────

test "SSH: switch open and retained state come from SSH overlay" {
    // BRK1 in EQ has no Switch.open attribute (defaults false).
    // SSH marks it open=true, retained=false.
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var ssh = try CimSsh.init(gpa, try gpa.dupe(u8, SSH_XML));
    defer ssh.deinit(gpa);
    var network = try converter.convert(gpa, &model, ssh);
    defer network.deinit(gpa);

    const sw = find_switch(network, "BRK1") orelse return error.TestFailed;
    try std.testing.expect(sw.open);
    try std.testing.expect(!sw.retained);
}

// ── SSH overlay: load p0/q0 ───────────────────────────────────────────────────

test "SSH: load p0 and q0 read from EnergyConsumer.p and .q in SSH" {
    // Without SSH, LOAD1 has p0=0.0 and q0=0.0 (no EnergyConsumer.p/q in EQ).
    // SSH provides p=100.0 and q=50.0.
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var ssh = try CimSsh.init(gpa, try gpa.dupe(u8, SSH_XML));
    defer ssh.deinit(gpa);
    var network = try converter.convert(gpa, &model, ssh);
    defer network.deinit(gpa);

    const load = find_load(network, "LOAD1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(f64, 100.0), load.p0);
    try std.testing.expectEqual(@as(f64, 50.0), load.q0);
}

// ── SSH overlay: disconnected terminal → fictitious switch ───────────────────

test "SSH: disconnected terminal creates fictitious switch for any equipment type" {
    // LOAD1 (EnergyConsumer) would never get a fictitious switch from the structural
    // isolation check.  Marking its terminal as ACDCTerminal.connected=false in SSH
    // forces creation regardless of equipment type.
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var ssh = try CimSsh.init(gpa, try gpa.dupe(u8, SSH_XML));
    defer ssh.deinit(gpa);
    var network = try converter.convert(gpa, &model, ssh);
    defer network.deinit(gpa);

    const sw = find_switch(network, "T_LOAD1_SW_fict") orelse return error.TestFailed;
    try std.testing.expect(sw.fictitious);
    try std.testing.expect(sw.open);
    try std.testing.expectEqual(.breaker, sw.kind);

    var found_terminal_prop = false;
    for (sw.properties.items) |prop| {
        if (std.mem.eql(u8, prop.name, "CGMES.Terminal")) {
            // Terminal mRID is strip_underscore("_T_LOAD1") = "T_LOAD1"
            try std.testing.expectEqualStrings("T_LOAD1", prop.value);
            found_terminal_prop = true;
        }
    }
    try std.testing.expect(found_terminal_prop);
}

// ── SSH FullModel: case_date and forecastDistance patching ────────────────────

test "SSH: case_date comes from SSH scenarioTime, not EQ" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var ssh = try CimSsh.init(gpa, try gpa.dupe(u8, SSH_XML));
    defer ssh.deinit(gpa);
    var network = try converter.convert(gpa, &model, ssh);
    defer network.deinit(gpa);

    // SSH scenarioTime is 2026-01-02T15:00:00Z; EQ has 2026-01-01T09:00:00Z.
    const case_date = network.case_date orelse return error.TestFailed;
    try std.testing.expectEqualStrings(
        "2026-01-02T15:00:00Z",
        std.mem.trim(u8, case_date, " \t\r\n"),
    );
}

test "SSH: forecastDistance computed from SSH times, not EQ" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var ssh = try CimSsh.init(gpa, try gpa.dupe(u8, SSH_XML));
    defer ssh.deinit(gpa);
    var network = try converter.convert(gpa, &model, ssh);
    defer network.deinit(gpa);

    // SSH: 2026-01-02T15:00Z − 2026-01-02T12:00Z = 3 h = 180 min.
    // EQ alone gives 480 min — SSH must override both times.
    try std.testing.expectEqual(@as(u32, 180), network.forecast_distance);
}

// ── SSH FullModel: cgmesMetadataModels ────────────────────────────────────────

test "SSH: FullModel appears as MetadataModel with subset SSH after EQ entry" {
    const gpa = std.testing.allocator;
    var model = try CimModel.init(gpa, try gpa.dupe(u8, EQ_XML));
    defer model.deinit(gpa);
    var ssh = try CimSsh.init(gpa, try gpa.dupe(u8, SSH_XML));
    defer ssh.deinit(gpa);
    var network = try converter.convert(gpa, &model, ssh);
    defer network.deinit(gpa);

    const ext = find_extension(network, network.id) orelse return error.TestFailed;
    const meta = ext.cgmes_metadata_models orelse return error.TestFailed;

    // EQ has 2 FullModels (EQ + EQBD stub); SSH adds 1 → 3 total.
    try std.testing.expectEqual(@as(usize, 3), meta.models.items.len);

    // SSH FullModel is last (it depends on EQ, so EQ comes before it).
    const ssh_entry = meta.models.items[meta.models.items.len - 1];
    try std.testing.expectEqualStrings("urn:uuid:SSH_FM1", ssh_entry.id);
    try std.testing.expectEqualStrings("SSH", ssh_entry.subset);
    try std.testing.expectEqual(@as(u32, 1), ssh_entry.version);
    try std.testing.expectEqual(@as(usize, 1), ssh_entry.profiles.items.len);
    try std.testing.expectEqualStrings(
        "http://iec.ch/TC57/ns/CIM/SteadyStateHypothesis-EU/3.0",
        ssh_entry.profiles.items[0].content,
    );
}
