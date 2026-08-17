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

// ── Type ids and ancestor masks ───────────────────────────────────────────────
//
// Precomputing transitive ancestor masks makes id-based ancestry a bit test and
// proves the generated hierarchy is acyclic at compile time.

/// Opaque because ids may change when `parent_edges` is regenerated.
pub const TypeId = enum(u16) { _ };

const type_count: u16 = count_distinct_names();
const type_names: [type_count][]const u8 = collect_distinct_names();

const TypeSet = std.bit_set.IntegerBitSet(type_count);

// One past the last valid id, so the sentinel cannot collide with a class.
const no_parent: u16 = type_count;
const parent_ids: [type_count]u16 = build_parent_ids();

const ancestor_masks: [type_count]TypeSet = build_ancestor_masks();

const name_to_id = std.StaticStringMap(TypeId).initComptime(blk: {
    var pairs: [type_count]struct { []const u8, TypeId } = undefined;
    for (type_names, 0..) |name, index| pairs[index] = .{ name, @enumFromInt(index) };
    break :blk pairs;
});

/// Unknown classes return null so vendor extensions remain unrelated leaves
/// without requiring per-document interning.
pub fn type_id(type_name: []const u8) ?TypeId {
    return name_to_id.get(type_name);
}

/// Whether `actual` is `requested` or one of its subtypes. One bit test.
pub fn is_a_id(actual: TypeId, requested: TypeId) bool {
    return ancestor_masks[@intFromEnum(actual)].isSet(@intFromEnum(requested));
}

pub fn is_a(actual_type: []const u8, requested_type: []const u8) bool {
    // Preserve fast exact matches and let unknown extension classes match
    // themselves without entering the known-type tables.
    if (std.mem.eql(u8, actual_type, requested_type)) return true;

    if (type_id(actual_type)) |actual| {
        if (type_id(requested_type)) |requested| return is_a_id(actual, requested);
    }
    // Extension classes have no known ancestry.
    return false;
}

pub fn matches_filter(actual_type: []const u8, type_filter: ?[]const u8) bool {
    const requested = type_filter orelse return true;
    return is_a(actual_type, requested);
}

fn count_distinct_names() u16 {
    @setEvalBranchQuota(500_000);
    var seen: [parent_edges.len * 2][]const u8 = undefined;
    var count: u16 = 0;
    for (parent_edges) |edge| {
        for ([_][]const u8{ edge.child, edge.parent }) |name| {
            if (index_of_name(seen[0..count], name) == null) {
                seen[count] = name;
                count += 1;
            }
        }
    }
    return count;
}

fn collect_distinct_names() [type_count][]const u8 {
    @setEvalBranchQuota(500_000);
    var names: [type_count][]const u8 = undefined;
    var count: u16 = 0;
    for (parent_edges) |edge| {
        for ([_][]const u8{ edge.child, edge.parent }) |name| {
            if (index_of_name(names[0..count], name) == null) {
                names[count] = name;
                count += 1;
            }
        }
    }
    return names;
}

fn build_parent_ids() [type_count]u16 {
    @setEvalBranchQuota(500_000);
    var parents: [type_count]u16 = @splat(no_parent);
    for (parent_edges) |edge| {
        const child = index_of_name(&type_names, edge.child).?;
        const parent = index_of_name(&type_names, edge.parent).?;
        if (parents[child] != no_parent) {
            @compileError("parent_edges gives '" ++ edge.child ++ "' more than one parent");
        }
        if (child == parent) @compileError("parent_edges makes '" ++ edge.child ++ "' its own parent");
        parents[child] = parent;
    }
    return parents;
}

// Resolve the closure at comptime so a cycle fails the build instead of
// requiring a defensive runtime walk bound.
fn build_ancestor_masks() [type_count]TypeSet {
    @setEvalBranchQuota(500_000);
    var masks: [type_count]TypeSet = @splat(TypeSet.initEmpty());
    var resolved: [type_count]bool = @splat(false);
    var chain: [type_count]u16 = undefined;

    for (0..type_count) |start| {
        var length: u16 = 0;
        var current: u16 = @intCast(start);
        while (!resolved[current]) {
            if (length == type_count) {
                @compileError("parent_edges is cyclic, reachable from '" ++ type_names[start] ++ "'");
            }
            chain[length] = current;
            length += 1;
            if (parent_ids[current] == no_parent) break;
            current = parent_ids[current];
        }
        while (length > 0) {
            length -= 1;
            const class = chain[length];
            const parent = parent_ids[class];
            var mask = if (parent == no_parent) TypeSet.initEmpty() else masks[parent];
            mask.set(class);
            masks[class] = mask;
            resolved[class] = true;
        }
    }
    return masks;
}

fn index_of_name(names: []const []const u8, name: []const u8) ?u16 {
    for (names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) return @intCast(index);
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

test "is_a treats an extension class as its own unrelated leaf" {
    // Unknown extensions must still support exact-type filters.
    try std.testing.expect(type_id("VendorSpecialThing") == null);
    try std.testing.expect(is_a("VendorSpecialThing", "VendorSpecialThing"));
    try std.testing.expect(!is_a("VendorSpecialThing", "IdentifiedObject"));
    try std.testing.expect(!is_a("IdentifiedObject", "VendorSpecialThing"));
}

test "type_id resolves every class named in parent_edges" {
    for (parent_edges) |edge| {
        try std.testing.expect(type_id(edge.child) != null);
        try std.testing.expect(type_id(edge.parent) != null);
    }
}

// Compare every pair to catch mistakes in the generated closure.
test "ancestor masks agree with a parent-chain walk on all class pairs" {
    for (type_names) |actual| {
        for (type_names) |requested| {
            const expected = std.mem.eql(u8, actual, requested) or
                walks_to(actual, requested);
            try std.testing.expectEqual(expected, is_a(actual, requested));
        }
    }
}

// Keep the reference walk bounded independently of the acyclicity proof it
// tests.
fn walks_to(actual_type: []const u8, requested_type: []const u8) bool {
    var current = actual_type;
    for (0..parent_edges.len) |_| {
        const child_id = type_id(current) orelse return false;
        const parent_id = parent_ids[@intFromEnum(child_id)];
        if (parent_id == no_parent) return false;
        const parent = type_names[parent_id];
        if (std.mem.eql(u8, parent, requested_type)) return true;
        current = parent;
    }
    return false;
}

test "every class is in its own ancestor mask" {
    for (type_names, 0..) |_, index| {
        const id: TypeId = @enumFromInt(index);
        try std.testing.expect(is_a_id(id, id));
    }
}

test "a class's mask contains its parent's" {
    for (parent_ids, 0..) |parent, child| {
        if (parent == no_parent) continue;
        const child_mask = ancestor_masks[child];
        const parent_mask = ancestor_masks[parent];
        try std.testing.expectEqual(parent_mask.mask, child_mask.mask & parent_mask.mask);
    }
}

test "matches_filter with no filter matches everything" {
    try std.testing.expect(matches_filter("Breaker", null));
    try std.testing.expect(matches_filter("VendorSpecialThing", null));
}
