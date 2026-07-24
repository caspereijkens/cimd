const std = @import("std");

const ParentEdge = struct {
    child: []const u8,
    parent: []const u8,
};

// Static CIM class ancestry used for user-facing type filters.
//
// Generated from the official CGMES 3.0 / IEC CIM100 RDFS class hierarchy.
// Refresh the checked-in table from the current ENTSO-E profiles with:
//   scripts/fetch-cim-rdfs.sh
// Or generate the body directly from local profile files with:
//   zig build gen-cim-types -- <profile1.rdf> <profile2.rdf> ...
//
// The checked-in table is intentionally a cimd-relevant subset. Add missing
// classes by regenerating from the source RDFS rather than hand-expanding
// transitive ancestors.
const parent_edges = [_]ParentEdge{
    .{ .child = "ACDCConverter", .parent = "ConductingEquipment" },
    .{ .child = "ACDCConverterDCTerminal", .parent = "DCBaseTerminal" },
    .{ .child = "ACDCTerminal", .parent = "IdentifiedObject" },
    .{ .child = "ACLineSegment", .parent = "Conductor" },
    .{ .child = "Accumulator", .parent = "Measurement" },
    .{ .child = "AccumulatorLimit", .parent = "Limit" },
    .{ .child = "AccumulatorLimitSet", .parent = "LimitSet" },
    .{ .child = "AccumulatorReset", .parent = "Control" },
    .{ .child = "AccumulatorValue", .parent = "MeasurementValue" },
    .{ .child = "ActivePowerLimit", .parent = "OperationalLimit" },
    .{ .child = "Analog", .parent = "Measurement" },
    .{ .child = "AnalogControl", .parent = "Control" },
    .{ .child = "AnalogLimit", .parent = "Limit" },
    .{ .child = "AnalogLimitSet", .parent = "LimitSet" },
    .{ .child = "AnalogValue", .parent = "MeasurementValue" },
    .{ .child = "ApparentPowerLimit", .parent = "OperationalLimit" },
    .{ .child = "AsynchronousMachine", .parent = "RotatingMachine" },
    .{ .child = "AuxiliaryEquipment", .parent = "Equipment" },
    .{ .child = "BaseVoltage", .parent = "IdentifiedObject" },
    .{ .child = "BasicIntervalSchedule", .parent = "IdentifiedObject" },
    .{ .child = "BatteryUnit", .parent = "PowerElectronicsUnit" },
    .{ .child = "Bay", .parent = "EquipmentContainer" },
    .{ .child = "BoundaryPoint", .parent = "PowerSystemResource" },
    .{ .child = "Breaker", .parent = "ProtectedSwitch" },
    .{ .child = "BusNameMarker", .parent = "IdentifiedObject" },
    .{ .child = "BusbarSection", .parent = "Connector" },
    .{ .child = "CAESPlant", .parent = "PowerSystemResource" },
    .{ .child = "Clamp", .parent = "ConductingEquipment" },
    .{ .child = "CogenerationPlant", .parent = "PowerSystemResource" },
    .{ .child = "CombinedCyclePlant", .parent = "PowerSystemResource" },
    .{ .child = "Command", .parent = "Control" },
    .{ .child = "ConductingEquipment", .parent = "Equipment" },
    .{ .child = "Conductor", .parent = "ConductingEquipment" },
    .{ .child = "ConformLoad", .parent = "EnergyConsumer" },
    .{ .child = "ConformLoadGroup", .parent = "LoadGroup" },
    .{ .child = "ConformLoadSchedule", .parent = "SeasonDayTypeSchedule" },
    .{ .child = "ConnectivityNode", .parent = "IdentifiedObject" },
    .{ .child = "ConnectivityNodeContainer", .parent = "PowerSystemResource" },
    .{ .child = "Connector", .parent = "ConductingEquipment" },
    .{ .child = "Control", .parent = "IOPoint" },
    .{ .child = "ControlArea", .parent = "PowerSystemResource" },
    .{ .child = "ControlAreaGeneratingUnit", .parent = "IdentifiedObject" },
    .{ .child = "CsConverter", .parent = "ACDCConverter" },
    .{ .child = "CurrentLimit", .parent = "OperationalLimit" },
    .{ .child = "CurrentTransformer", .parent = "Sensor" },
    .{ .child = "Curve", .parent = "IdentifiedObject" },
    .{ .child = "Cut", .parent = "Switch" },
    .{ .child = "DCBaseTerminal", .parent = "ACDCTerminal" },
    .{ .child = "DCBreaker", .parent = "DCSwitch" },
    .{ .child = "DCBusbar", .parent = "DCConductingEquipment" },
    .{ .child = "DCChopper", .parent = "DCConductingEquipment" },
    .{ .child = "DCConductingEquipment", .parent = "Equipment" },
    .{ .child = "DCConverterUnit", .parent = "DCEquipmentContainer" },
    .{ .child = "DCDisconnector", .parent = "DCSwitch" },
    .{ .child = "DCEquipmentContainer", .parent = "EquipmentContainer" },
    .{ .child = "DCGround", .parent = "DCConductingEquipment" },
    .{ .child = "DCLine", .parent = "DCEquipmentContainer" },
    .{ .child = "DCLineSegment", .parent = "DCConductingEquipment" },
    .{ .child = "DCNode", .parent = "IdentifiedObject" },
    .{ .child = "DCSeriesDevice", .parent = "DCConductingEquipment" },
    .{ .child = "DCShunt", .parent = "DCConductingEquipment" },
    .{ .child = "DCSwitch", .parent = "DCConductingEquipment" },
    .{ .child = "DCTerminal", .parent = "DCBaseTerminal" },
    .{ .child = "DCTopologicalIsland", .parent = "IdentifiedObject" },
    .{ .child = "DCTopologicalNode", .parent = "IdentifiedObject" },
    .{ .child = "DayType", .parent = "IdentifiedObject" },
    .{ .child = "DisconnectingCircuitBreaker", .parent = "Breaker" },
    .{ .child = "Disconnector", .parent = "Switch" },
    .{ .child = "Discrete", .parent = "Measurement" },
    .{ .child = "DiscreteValue", .parent = "MeasurementValue" },
    .{ .child = "EarthFaultCompensator", .parent = "ConductingEquipment" },
    .{ .child = "EnergyArea", .parent = "IdentifiedObject" },
    .{ .child = "EnergyConnection", .parent = "ConductingEquipment" },
    .{ .child = "EnergyConsumer", .parent = "EnergyConnection" },
    .{ .child = "EnergySchedulingType", .parent = "IdentifiedObject" },
    .{ .child = "EnergySource", .parent = "EnergyConnection" },
    .{ .child = "Equipment", .parent = "PowerSystemResource" },
    .{ .child = "EquipmentContainer", .parent = "ConnectivityNodeContainer" },
    .{ .child = "EquivalentBranch", .parent = "EquivalentEquipment" },
    .{ .child = "EquivalentEquipment", .parent = "ConductingEquipment" },
    .{ .child = "EquivalentInjection", .parent = "EquivalentEquipment" },
    .{ .child = "EquivalentNetwork", .parent = "ConnectivityNodeContainer" },
    .{ .child = "EquivalentShunt", .parent = "EquivalentEquipment" },
    .{ .child = "ExternalNetworkInjection", .parent = "RegulatingCondEq" },
    .{ .child = "FaultIndicator", .parent = "AuxiliaryEquipment" },
    .{ .child = "FossilFuel", .parent = "IdentifiedObject" },
    .{ .child = "Fuse", .parent = "Switch" },
    .{ .child = "GeneratingUnit", .parent = "Equipment" },
    .{ .child = "GeographicalRegion", .parent = "IdentifiedObject" },
    .{ .child = "GrossToNetActivePowerCurve", .parent = "Curve" },
    .{ .child = "Ground", .parent = "ConductingEquipment" },
    .{ .child = "GroundDisconnector", .parent = "Switch" },
    .{ .child = "GroundingImpedance", .parent = "EarthFaultCompensator" },
    .{ .child = "HydroGeneratingUnit", .parent = "GeneratingUnit" },
    .{ .child = "HydroPowerPlant", .parent = "PowerSystemResource" },
    .{ .child = "HydroPump", .parent = "Equipment" },
    .{ .child = "IOPoint", .parent = "IdentifiedObject" },
    .{ .child = "Jumper", .parent = "Switch" },
    .{ .child = "Junction", .parent = "Connector" },
    .{ .child = "Limit", .parent = "IdentifiedObject" },
    .{ .child = "LimitSet", .parent = "IdentifiedObject" },
    .{ .child = "Line", .parent = "EquipmentContainer" },
    .{ .child = "LinearShuntCompensator", .parent = "ShuntCompensator" },
    .{ .child = "LoadArea", .parent = "EnergyArea" },
    .{ .child = "LoadBreakSwitch", .parent = "ProtectedSwitch" },
    .{ .child = "LoadGroup", .parent = "IdentifiedObject" },
    .{ .child = "LoadResponseCharacteristic", .parent = "IdentifiedObject" },
    .{ .child = "Measurement", .parent = "IdentifiedObject" },
    .{ .child = "MeasurementValue", .parent = "IOPoint" },
    .{ .child = "MeasurementValueQuality", .parent = "Quality61850" },
    .{ .child = "MeasurementValueSource", .parent = "IdentifiedObject" },
    .{ .child = "NonConformLoad", .parent = "EnergyConsumer" },
    .{ .child = "NonConformLoadGroup", .parent = "LoadGroup" },
    .{ .child = "NonConformLoadSchedule", .parent = "SeasonDayTypeSchedule" },
    .{ .child = "NonlinearShuntCompensator", .parent = "ShuntCompensator" },
    .{ .child = "NuclearGeneratingUnit", .parent = "GeneratingUnit" },
    .{ .child = "OperationalLimit", .parent = "IdentifiedObject" },
    .{ .child = "OperationalLimitSet", .parent = "IdentifiedObject" },
    .{ .child = "OperationalLimitType", .parent = "IdentifiedObject" },
    .{ .child = "PetersenCoil", .parent = "EarthFaultCompensator" },
    .{ .child = "PhaseTapChanger", .parent = "TapChanger" },
    .{ .child = "PhaseTapChangerAsymmetrical", .parent = "PhaseTapChangerNonLinear" },
    .{ .child = "PhaseTapChangerLinear", .parent = "PhaseTapChanger" },
    .{ .child = "PhaseTapChangerNonLinear", .parent = "PhaseTapChanger" },
    .{ .child = "PhaseTapChangerSymmetrical", .parent = "PhaseTapChangerNonLinear" },
    .{ .child = "PhaseTapChangerTable", .parent = "IdentifiedObject" },
    .{ .child = "PhaseTapChangerTablePoint", .parent = "TapChangerTablePoint" },
    .{ .child = "PhaseTapChangerTabular", .parent = "PhaseTapChanger" },
    .{ .child = "PhotoVoltaicUnit", .parent = "PowerElectronicsUnit" },
    .{ .child = "PostLineSensor", .parent = "Sensor" },
    .{ .child = "PotentialTransformer", .parent = "Sensor" },
    .{ .child = "PowerElectronicsConnection", .parent = "RegulatingCondEq" },
    .{ .child = "PowerElectronicsUnit", .parent = "Equipment" },
    .{ .child = "PowerElectronicsWindUnit", .parent = "PowerElectronicsUnit" },
    .{ .child = "PowerSystemResource", .parent = "IdentifiedObject" },
    .{ .child = "PowerTransformer", .parent = "ConductingEquipment" },
    .{ .child = "PowerTransformerEnd", .parent = "TransformerEnd" },
    .{ .child = "ProtectedSwitch", .parent = "Switch" },
    .{ .child = "RaiseLowerCommand", .parent = "AnalogControl" },
    .{ .child = "RatioTapChanger", .parent = "TapChanger" },
    .{ .child = "RatioTapChangerTable", .parent = "IdentifiedObject" },
    .{ .child = "RatioTapChangerTablePoint", .parent = "TapChangerTablePoint" },
    .{ .child = "ReactiveCapabilityCurve", .parent = "Curve" },
    .{ .child = "RegularIntervalSchedule", .parent = "BasicIntervalSchedule" },
    .{ .child = "RegulatingCondEq", .parent = "EnergyConnection" },
    .{ .child = "RegulatingControl", .parent = "PowerSystemResource" },
    .{ .child = "RegulationSchedule", .parent = "SeasonDayTypeSchedule" },
    .{ .child = "ReportingGroup", .parent = "IdentifiedObject" },
    .{ .child = "RotatingMachine", .parent = "RegulatingCondEq" },
    .{ .child = "Season", .parent = "IdentifiedObject" },
    .{ .child = "SeasonDayTypeSchedule", .parent = "RegularIntervalSchedule" },
    .{ .child = "Sensor", .parent = "AuxiliaryEquipment" },
    .{ .child = "SeriesCompensator", .parent = "ConductingEquipment" },
    .{ .child = "SetPoint", .parent = "AnalogControl" },
    .{ .child = "ShuntCompensator", .parent = "RegulatingCondEq" },
    .{ .child = "SolarGeneratingUnit", .parent = "GeneratingUnit" },
    .{ .child = "SolarPowerPlant", .parent = "PowerSystemResource" },
    .{ .child = "StaticVarCompensator", .parent = "RegulatingCondEq" },
    .{ .child = "StationSupply", .parent = "EnergyConsumer" },
    .{ .child = "StringMeasurement", .parent = "Measurement" },
    .{ .child = "StringMeasurementValue", .parent = "MeasurementValue" },
    .{ .child = "SubGeographicalRegion", .parent = "IdentifiedObject" },
    .{ .child = "SubLoadArea", .parent = "EnergyArea" },
    .{ .child = "Substation", .parent = "EquipmentContainer" },
    .{ .child = "SurgeArrester", .parent = "AuxiliaryEquipment" },
    .{ .child = "Switch", .parent = "ConductingEquipment" },
    .{ .child = "SwitchSchedule", .parent = "SeasonDayTypeSchedule" },
    .{ .child = "SynchronousMachine", .parent = "RotatingMachine" },
    .{ .child = "TapChanger", .parent = "PowerSystemResource" },
    .{ .child = "TapChangerControl", .parent = "RegulatingControl" },
    .{ .child = "TapSchedule", .parent = "SeasonDayTypeSchedule" },
    .{ .child = "Terminal", .parent = "ACDCTerminal" },
    .{ .child = "ThermalGeneratingUnit", .parent = "GeneratingUnit" },
    .{ .child = "TieFlow", .parent = "IdentifiedObject" },
    .{ .child = "TopologicalIsland", .parent = "IdentifiedObject" },
    .{ .child = "TopologicalNode", .parent = "IdentifiedObject" },
    .{ .child = "TransformerEnd", .parent = "IdentifiedObject" },
    .{ .child = "ValueAliasSet", .parent = "IdentifiedObject" },
    .{ .child = "ValueToAlias", .parent = "IdentifiedObject" },
    .{ .child = "VoltageLevel", .parent = "EquipmentContainer" },
    .{ .child = "VoltageLimit", .parent = "OperationalLimit" },
    .{ .child = "VsCapabilityCurve", .parent = "Curve" },
    .{ .child = "VsConverter", .parent = "ACDCConverter" },
    .{ .child = "WaveTrap", .parent = "AuxiliaryEquipment" },
    .{ .child = "WindGeneratingUnit", .parent = "GeneratingUnit" },
    .{ .child = "WindPowerPlant", .parent = "PowerSystemResource" },
};

pub fn is_a(actual_type: []const u8, requested_type: []const u8) bool {
    if (std.mem.eql(u8, actual_type, requested_type)) return true;
    return has_ancestor(actual_type, requested_type);
}

pub fn matches_filter(actual_type: []const u8, type_filter: ?[]const u8) bool {
    const requested = type_filter orelse return true;
    return is_a(actual_type, requested);
}

// Walk the single parent chain from `actual_type` upward, looking for
// `requested_type`. `parent_edges` is a tree (each child appears once), so
// every type has at most one parent and this is a linear walk -- no recursion.
// The loop is bounded by the edge count: a well-formed chain terminates via the
// `orelse return false` long before that, and the bound caps any malformed
// (cyclic) table at a finite number of steps.
//
// O(parent_edges * ancestry_depth). If this becomes hot for large library
// callers, precompute the requested type's subtype set once and test membership
// per object.
fn has_ancestor(actual_type: []const u8, requested_type: []const u8) bool {
    var current = actual_type;
    for (0..parent_edges.len) |_| {
        const parent = parent_of(current) orelse return false;
        if (std.mem.eql(u8, parent, requested_type)) return true;
        current = parent;
    }
    return false;
}

fn parent_of(child: []const u8) ?[]const u8 {
    for (parent_edges) |edge| {
        if (std.mem.eql(u8, edge.child, child)) return edge.parent;
    }
    return null;
}

test "is_a matches concrete type to itself" {
    try std.testing.expect(is_a("ACLineSegment", "ACLineSegment"));
}

test "is_a matches transitive ConductingEquipment subtypes" {
    try std.testing.expect(is_a("ACLineSegment", "ConductingEquipment"));
    try std.testing.expect(is_a("PowerTransformer", "ConductingEquipment"));
    try std.testing.expect(is_a("SynchronousMachine", "ConductingEquipment"));
    try std.testing.expect(is_a("ConformLoad", "ConductingEquipment"));
    try std.testing.expect(is_a("Breaker", "ConductingEquipment"));
    try std.testing.expect(is_a("VsConverter", "ConductingEquipment"));
}

test "is_a matches equipment containers" {
    try std.testing.expect(is_a("Line", "EquipmentContainer"));
}

test "is_a chains GeneratingUnit through Equipment" {
    try std.testing.expect(is_a("GeneratingUnit", "Equipment"));
    try std.testing.expect(is_a("HydroGeneratingUnit", "Equipment"));
    try std.testing.expect(is_a("NuclearGeneratingUnit", "PowerSystemResource"));
    try std.testing.expect(is_a("SolarGeneratingUnit", "Equipment"));
    try std.testing.expect(is_a("ThermalGeneratingUnit", "PowerSystemResource"));
}

test "is_a returns false for unknown types" {
    try std.testing.expect(!is_a("ACLineSegment", "NotARealType"));
    try std.testing.expect(!is_a("AlsoNotReal", "Equipment"));
}
