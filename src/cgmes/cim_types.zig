const std = @import("std");

const ParentEdge = struct {
    child: []const u8,
    parent: []const u8,
};

// Static CIM class ancestry used for user-facing type filters.
//
// Generated from: official CGMES 3.0 / IEC CIM100 RDFS class hierarchy
// (source path supplied to scripts/generate-cim-type-table.py).
// Kept as parent edges so it can be regenerated from an RDFS file with:
//   scripts/generate-cim-type-table.py <CIM-schema.rdfs>
//
// The checked-in table is intentionally a cimd-relevant subset. Add missing
// classes by regenerating from the source RDFS rather than hand-expanding
// transitive ancestors.
const parent_edges = [_]ParentEdge{
    .{ .child = "PowerSystemResource", .parent = "IdentifiedObject" },
    .{ .child = "ACDCTerminal", .parent = "IdentifiedObject" },
    .{ .child = "BaseVoltage", .parent = "IdentifiedObject" },
    .{ .child = "Curve", .parent = "IdentifiedObject" },
    .{ .child = "CurveData", .parent = "IdentifiedObject" },
    .{ .child = "GeographicalRegion", .parent = "IdentifiedObject" },
    .{ .child = "OperationalLimit", .parent = "IdentifiedObject" },
    .{ .child = "OperationalLimitSet", .parent = "IdentifiedObject" },
    .{ .child = "OperationalLimitType", .parent = "IdentifiedObject" },
    .{ .child = "ReportingGroup", .parent = "IdentifiedObject" },
    .{ .child = "SubGeographicalRegion", .parent = "IdentifiedObject" },
    .{ .child = "TapChangerControl", .parent = "IdentifiedObject" },
    .{ .child = "TopologicalIsland", .parent = "IdentifiedObject" },
    .{ .child = "TopologicalNode", .parent = "IdentifiedObject" },

    .{ .child = "ConnectivityNodeContainer", .parent = "PowerSystemResource" },
    .{ .child = "ControlArea", .parent = "PowerSystemResource" },
    .{ .child = "Equipment", .parent = "PowerSystemResource" },
    .{ .child = "FossilFuel", .parent = "PowerSystemResource" },
    .{ .child = "LoadArea", .parent = "PowerSystemResource" },
    .{ .child = "LoadGroup", .parent = "PowerSystemResource" },
    .{ .child = "LoadResponseCharacteristic", .parent = "PowerSystemResource" },
    .{ .child = "Measurement", .parent = "PowerSystemResource" },
    .{ .child = "PSRType", .parent = "PowerSystemResource" },
    .{ .child = "RegulatingControl", .parent = "PowerSystemResource" },
    .{ .child = "SubLoadArea", .parent = "PowerSystemResource" },
    .{ .child = "TapChanger", .parent = "PowerSystemResource" },
    .{ .child = "TieFlow", .parent = "PowerSystemResource" },

    .{ .child = "EquipmentContainer", .parent = "ConnectivityNodeContainer" },
    .{ .child = "Bay", .parent = "EquipmentContainer" },
    .{ .child = "DCEquipmentContainer", .parent = "EquipmentContainer" },
    .{ .child = "Line", .parent = "EquipmentContainer" },
    .{ .child = "Substation", .parent = "EquipmentContainer" },
    .{ .child = "VoltageLevel", .parent = "EquipmentContainer" },
    .{ .child = "DCLine", .parent = "DCEquipmentContainer" },

    .{ .child = "AuxiliaryEquipment", .parent = "Equipment" },
    .{ .child = "ConductingEquipment", .parent = "Equipment" },
    .{ .child = "EarthFaultCompensator", .parent = "Equipment" },
    .{ .child = "GeneratingUnit", .parent = "Equipment" },
    .{ .child = "EquivalentEquipment", .parent = "ConductingEquipment" },
    .{ .child = "ExternalNetworkInjection", .parent = "RegulatingCondEq" },
    .{ .child = "Ground", .parent = "ConductingEquipment" },
    .{ .child = "PetersenCoil", .parent = "EarthFaultCompensator" },
    .{ .child = "PowerElectronicsConnection", .parent = "ConductingEquipment" },
    .{ .child = "PowerTransformer", .parent = "ConductingEquipment" },
    .{ .child = "RegulatingCondEq", .parent = "ConductingEquipment" },
    .{ .child = "SeriesCompensator", .parent = "ConductingEquipment" },

    .{ .child = "Conductor", .parent = "ConductingEquipment" },
    .{ .child = "ACLineSegment", .parent = "Conductor" },
    .{ .child = "DCLineSegment", .parent = "Conductor" },

    .{ .child = "Connector", .parent = "ConductingEquipment" },
    .{ .child = "BusbarSection", .parent = "Connector" },
    .{ .child = "Junction", .parent = "Connector" },

    .{ .child = "EnergyConnection", .parent = "ConductingEquipment" },
    .{ .child = "EnergyConsumer", .parent = "EnergyConnection" },
    .{ .child = "EnergySource", .parent = "EnergyConnection" },
    .{ .child = "ConformLoad", .parent = "EnergyConsumer" },
    .{ .child = "NonConformLoad", .parent = "EnergyConsumer" },
    .{ .child = "StationSupply", .parent = "EnergyConsumer" },

    .{ .child = "RotatingMachine", .parent = "RegulatingCondEq" },
    .{ .child = "AsynchronousMachine", .parent = "RotatingMachine" },
    .{ .child = "SynchronousMachine", .parent = "RotatingMachine" },

    .{ .child = "ShuntCompensator", .parent = "RegulatingCondEq" },
    .{ .child = "LinearShuntCompensator", .parent = "ShuntCompensator" },
    .{ .child = "NonlinearShuntCompensator", .parent = "ShuntCompensator" },
    .{ .child = "StaticVarCompensator", .parent = "RegulatingCondEq" },

    .{ .child = "Switch", .parent = "ConductingEquipment" },
    .{ .child = "Breaker", .parent = "ProtectedSwitch" },
    .{ .child = "Disconnector", .parent = "Switch" },
    .{ .child = "Fuse", .parent = "Switch" },
    .{ .child = "GroundDisconnector", .parent = "Switch" },
    .{ .child = "Jumper", .parent = "Switch" },
    .{ .child = "LoadBreakSwitch", .parent = "ProtectedSwitch" },
    .{ .child = "ProtectedSwitch", .parent = "Switch" },
    .{ .child = "Recloser", .parent = "ProtectedSwitch" },
    .{ .child = "Sectionaliser", .parent = "Switch" },

    .{ .child = "EquivalentBranch", .parent = "EquivalentEquipment" },
    .{ .child = "EquivalentInjection", .parent = "EquivalentEquipment" },
    .{ .child = "EquivalentShunt", .parent = "EquivalentEquipment" },

    .{ .child = "Terminal", .parent = "ACDCTerminal" },
    .{ .child = "DCBaseTerminal", .parent = "ACDCTerminal" },
    .{ .child = "ACDCConverterDCTerminal", .parent = "DCBaseTerminal" },
    .{ .child = "DCTerminal", .parent = "DCBaseTerminal" },

    .{ .child = "ActivePowerLimit", .parent = "OperationalLimit" },
    .{ .child = "ApparentPowerLimit", .parent = "OperationalLimit" },
    .{ .child = "CurrentLimit", .parent = "OperationalLimit" },
    .{ .child = "VoltageLimit", .parent = "OperationalLimit" },

    .{ .child = "BatteryUnit", .parent = "PowerElectronicsUnit" },
    .{ .child = "PhotoVoltaicUnit", .parent = "PowerElectronicsUnit" },
    .{ .child = "PowerElectronicsUnit", .parent = "Equipment" },
    .{ .child = "SolarGeneratingUnit", .parent = "GeneratingUnit" },
    .{ .child = "ThermalGeneratingUnit", .parent = "GeneratingUnit" },
    .{ .child = "WindGeneratingUnit", .parent = "GeneratingUnit" },

    .{ .child = "PhaseTapChanger", .parent = "TapChanger" },
    .{ .child = "PhaseTapChangerAsymmetrical", .parent = "PhaseTapChangerNonLinear" },
    .{ .child = "PhaseTapChangerLinear", .parent = "PhaseTapChanger" },
    .{ .child = "PhaseTapChangerNonLinear", .parent = "PhaseTapChanger" },
    .{ .child = "PhaseTapChangerSymmetrical", .parent = "PhaseTapChangerNonLinear" },
    .{ .child = "PhaseTapChangerTabular", .parent = "PhaseTapChanger" },
    .{ .child = "RatioTapChanger", .parent = "TapChanger" },

    .{ .child = "SvInjection", .parent = "StateVariable" },
    .{ .child = "SvPowerFlow", .parent = "StateVariable" },
    .{ .child = "SvShuntCompensatorSections", .parent = "StateVariable" },
    .{ .child = "SvStatus", .parent = "StateVariable" },
    .{ .child = "SvTapStep", .parent = "StateVariable" },
    .{ .child = "SvVoltage", .parent = "StateVariable" },
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
// every type has at most one parent and this is a linear walk — no recursion.
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
}

test "is_a matches equipment containers" {
    try std.testing.expect(is_a("Line", "EquipmentContainer"));
}

test "is_a chains GeneratingUnit through Equipment" {
    try std.testing.expect(is_a("GeneratingUnit", "Equipment"));
    try std.testing.expect(is_a("SolarGeneratingUnit", "Equipment"));
    try std.testing.expect(is_a("ThermalGeneratingUnit", "PowerSystemResource"));
}

test "is_a returns false for unknown types" {
    try std.testing.expect(!is_a("ACLineSegment", "NotARealType"));
    try std.testing.expect(!is_a("AlsoNotReal", "Equipment"));
}
