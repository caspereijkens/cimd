//! The closed QoCDC v4.1.4 rule inventory, report messages, and severities.
//!
//! Adding a rule starts here: add its stable report tag to `Rule`, then add
//! its single-line diagnostic to `message` and its report severity to
//! `severity`. Grid-model execution lives in `rules.zig`.
//!
//! This is the only file where every rule appears exactly once. Filename
//! rules emit from `filename.zig`, `TooManyProfileParts` from the engine's
//! header phase, and the relational rules from phase B -- none of them have
//! an `object_rules` entry -- so a per-rule attribute belongs here and
//! nowhere else.

const std = @import("std");

pub const Rule = enum(u8) {
    // Filename (level 1), evaluated over the file-name stem.
    FileNameMD,
    FileNameConsistency,
    EffectiveDateTime,
    SourcingActor,
    CGMRegion,
    BusinessProcess,
    ModelPartType,
    FileVersion,
    // Header.
    TooManyProfileParts,
    // Grid model: flat per-object checks.
    NameLength,
    ShortNameLength,
    EICLength,
    DescriptionLength,
    // Grid model: boundary-point checks (EQBD documents).
    CNFromEndIsoCode,
    CNToEndIsoCode,
    CNFromEndNameLength,
    CNToEndNameLength,
    CNFromEndNameTsoLength,
    CNToEndNameTsoLength,
    // Grid model: per-object value checks.
    NominalVoltage,
    LRCExponentModel,
    LCRCoefficientModel,
    LCRCoefficientParameters,
    EnergySourceVoltage,
    SVCRatings,
    GeneratingUnitNominalP,
    MeasType,
    MeasUnit,
    CNRequiredInEQOperations,
    // Grid model: containment.
    GenerationContainment,
    PTContainment,
    SwitchContainment,
    SCContainment,
    InjectionContainment,
    BusbarSectionContainment,
    EFCContainment,
    ACDCConvContainment,
    DCEQContainment,
    CNContainment,
    // Grid model: relational (evaluated over harvested columns).
    CEBaseVoltage,
    TerminalCount1,
    TerminalCount2,
    TerminalSeqNum,
    TerminalSeqNumOrder,
    PTTerminalConsistency,
    MCFirstSecond,
    MeasTerminal,
    TooManyTapChangers,
    // Grid model: additional per-object checks.
    SMQLimits2,
    SynchronousCondenser,
    RatedS,
    ShuntCompensatorSensitivity,
    CATieFlow,
    OperationalLimitSetAtTerminal,
    ControlModeCompatibility,
    ACLineSegmentR,
    LinearShuntCompensatorG,
    ShuntCompensatorSections,
    SVCSlope,
    RCCYValues,
    RCCXValues2,
    RCCXValues3,
    PhaseCodeGround,
    PowerTransformerEndRatedU,
    SMQLimits1,
    SMPLimits,
    CurveXValues,
    RCCXValues4,
    RCandTCCcontrollingObjects,
    WindingConnectionAngle,
};

pub const rule_count = @typeInfo(Rule).@"enum".fields.len;

/// The requested diagnostics of an engine run. The engine internally derives
/// the harvest/pass dependency closure from this set; harvest work for a
/// dependency never emits diagnostics for rules outside the request.
pub const RuleMask = std.EnumSet(Rule);

/// How seriously a rule's findings report, declared most serious first:
/// `@intFromEnum` is the severity rank, so a threshold is one integer
/// comparison. `@tagName` is the word the report prints.
pub const Severity = enum(u8) {
    @"error",
    warning,
    info,

    /// Whether `self` is at least as serious as `floor`.
    pub fn at_least(self: Severity, floor: Severity) bool {
        return @intFromEnum(self) <= @intFromEnum(floor);
    }
};

/// The report severity of a rule. QoCDC assigns severity to the rule, not to
/// the individual finding, so a severity is never stored per violation and no
/// predicate decides one: the report derives it here at render time.
///
/// Rules retain the error verdict this validator had before severities existed
/// unless their v4.1.4 classification places them in the `.warning` or `.info`
/// arm below. The switch is exhaustive on purpose: a new rule without a
/// severity is a compile error, which is what makes "every rule has a
/// severity" a property of the build rather than of review.
pub fn severity(rule: Rule) Severity {
    return switch (rule) {
        // Filename (level 1).
        .FileNameMD,
        .FileNameConsistency,
        .EffectiveDateTime,
        .SourcingActor,
        .CGMRegion,
        .BusinessProcess,
        .ModelPartType,
        .FileVersion,
        // Header.
        .TooManyProfileParts,
        // Grid model: flat per-object checks.
        .NameLength,
        .ShortNameLength,
        .EICLength,
        .DescriptionLength,
        // Grid model: boundary-point checks.
        .CNFromEndIsoCode,
        .CNToEndIsoCode,
        .CNFromEndNameLength,
        .CNToEndNameLength,
        .CNFromEndNameTsoLength,
        .CNToEndNameTsoLength,
        // Grid model: per-object value checks.
        .NominalVoltage,
        .LRCExponentModel,
        .LCRCoefficientModel,
        .LCRCoefficientParameters,
        .EnergySourceVoltage,
        .SVCRatings,
        .GeneratingUnitNominalP,
        .MeasType,
        .MeasUnit,
        .CNRequiredInEQOperations,
        // Grid model: containment.
        .GenerationContainment,
        .PTContainment,
        .SwitchContainment,
        .SCContainment,
        .InjectionContainment,
        .BusbarSectionContainment,
        .EFCContainment,
        .ACDCConvContainment,
        .DCEQContainment,
        .CNContainment,
        // Grid model: relational.
        .CEBaseVoltage,
        .TerminalCount1,
        .TerminalCount2,
        .TerminalSeqNum,
        .TerminalSeqNumOrder,
        .PTTerminalConsistency,
        .MCFirstSecond,
        .MeasTerminal,
        .TooManyTapChangers,
        // Grid model: additional per-object checks.
        .SMQLimits2,
        .SynchronousCondenser,
        .RatedS,
        .ShuntCompensatorSensitivity,
        .CATieFlow,
        .OperationalLimitSetAtTerminal,
        .ControlModeCompatibility,
        .ACLineSegmentR,
        .LinearShuntCompensatorG,
        .ShuntCompensatorSections,
        .SVCSlope,
        .RCCYValues,
        .RCCXValues2,
        .RCCXValues3,
        .PhaseCodeGround,
        => .@"error",
        .PowerTransformerEndRatedU,
        .SMQLimits1,
        .SMPLimits,
        .CurveXValues,
        .RCCXValues4,
        // The corresponding CGMES v3 constraint is a violation; this QoCDC
        // catalog rule is intentionally reported as a warning.
        .RCandTCCcontrollingObjects,
        .WindingConnectionAngle,
        => .warning,
    };
}

/// The rules that report at `floor` or more seriously. The engine selects
/// work from a `RuleMask`, so a severity threshold drops a rule's slot fills
/// and child walks along with its output -- it is not a render-time filter.
pub fn mask_at_least(floor: Severity) RuleMask {
    var mask: RuleMask = .initEmpty();
    var index: u32 = 0;
    while (index < rule_count) : (index += 1) {
        const rule: Rule = @enumFromInt(index);
        if (severity(rule).at_least(floor)) mask.insert(rule);
    }
    return mask;
}

/// The single-line report text of a rule. One line per violation is part of
/// the output contract, so no message may contain a newline.
pub fn message(rule: Rule) []const u8 {
    return switch (rule) {
        .FileNameMD => "the structure of the filename does not match the rules",
        .FileNameConsistency => "XML entry name differs from the ZIP container name",
        .EffectiveDateTime => "EffectiveDateTime in the filename is invalid",
        .SourcingActor => "sourcingRSC or sourcingTSO is absent from the QoCDC reference data",
        .CGMRegion => "cgmRegion in sourcing actor is absent from the QoCDC reference data",
        .BusinessProcess => "unknown business process",
        .ModelPartType => "unknown modelPart type in the filename",
        .FileVersion => "invalid fileVersion in the filename",
        .TooManyProfileParts => "expected exactly one recognized CGMES profile kind",
        .NameLength => "an IdentifiedObject.name is missing, empty, or too long",
        .ShortNameLength => "an IdentifiedObject.shortName is too long",
        .EICLength => "an energyIdentCodeEic does not have exactly 16 characters",
        .DescriptionLength => "an IdentifiedObject.description is too long",
        .CNFromEndIsoCode, .CNToEndIsoCode => "a boundary-point country code is invalid",
        .CNFromEndNameLength,
        .CNToEndNameLength,
        .CNFromEndNameTsoLength,
        .CNToEndNameTsoLength,
        => "a boundary-point name is missing or too long",
        .NominalVoltage => "a BaseVoltage nominalVoltage is not greater than zero",
        .LRCExponentModel => "exponent of per unit voltage effecting real and reactive power " ++
            "is not specified but cim:LoadResponseCharacteristic.exponentModel is true",
        .LCRCoefficientModel => "coefficients for ZIP load model are not specified but " ++
            "cim:LoadResponseCharacteristic.exponentModel is false",
        .LCRCoefficientParameters => "the sum of coefficient parameters for a " ++
            "cim:LoadResponseCharacteristic does not equal 1",
        .EnergySourceVoltage => "cim:EnergySource.voltageMagnitude and/or " ++
            "cim:EnergySource.voltageAngle are present",
        .SVCRatings => "capacitive rating is not greater than zero and/or " ++
            "inductive rating is not lower than zero for a SVC",
        .GeneratingUnitNominalP => "a GeneratingUnit nominalP value is invalid",
        .MeasType => "invalid measurement type",
        .MeasUnit => "invalid measurement unit symbol",
        .CNRequiredInEQOperations => "the association end cim:Terminal.ConnectivityNode " ++
            "is not provided for a model that contains EQ Operation profile",
        .GenerationContainment => "a HydroPump or GeneratingUnit has invalid containment",
        .PTContainment => "a PowerTransformer has invalid containment",
        .SwitchContainment => "a Switch has invalid containment",
        .SCContainment => "a SeriesCompensator has invalid containment",
        .InjectionContainment => "a power injection has invalid containment",
        .BusbarSectionContainment => "a BusbarSection has invalid containment",
        .EFCContainment => "a Ground or EarthFaultCompensator has invalid containment",
        .ACDCConvContainment => "an ACDCConverter has invalid containment",
        .DCEQContainment => "a DC equipment object has invalid containment",
        .CNContainment => "a ConnectivityNode has invalid containment",
        .CEBaseVoltage => "a ConductingEquipment BaseVoltage association is invalid",
        .TerminalCount1 => "a single terminal equipment that is not referenced by " ++
            "exactly one terminal",
        .TerminalCount2 => "a two terminal equipment that is not referenced by " ++
            "exactly two terminals",
        .TerminalSeqNum => "a cim:Terminal of either a cim:EquivalentBranch or " ++
            "a cim:ACLineSegment " ++
            "with cim:MutualCoupling does not have a sequence number declared",
        .TerminalSeqNumOrder => "invalid sequenceNumber for a cim:Terminal",
        .PTTerminalConsistency => "assignment of a PowerTransformer's terminals is not consistent",
        .MCFirstSecond => "cim:MutualCoupling.First_Terminal and " ++
            "cim:MutualCoupling.Second_Terminal " ++
            "do not refer to cim:Terminals of two different cim:ACLineSegments",
        .MeasTerminal => "cim:Measurement.Terminal does not refer to a cim:Terminal of a " ++
            "cim:Equipment referenced by cim:Measurement.PowerSystemResource",
        .TooManyTapChangers => "More than allowed cim:TapChanger objects at a " ++
            "cim:PowerTransformerEnd or the two cim:TapChanger objects are regulating.",
        .SynchronousCondenser => "a synchronous condenser is associated with cim:GeneratingUnit",
        .SMQLimits2 => "missing operating limits for a Synchronous Machine",
        .RatedS => "cim:RotatingMachine.ratedS or cim:PowerTransformerEnd.ratedS " ++
            "is missing or is not a positive finite number.",
        .ShuntCompensatorSensitivity => "cim:ShuntCompensator.voltageSensitivity is provided " ++
            "but is not a positive finite number.",
        .CATieFlow => "an interchange cim:ControlArea has no referring cim:TieFlow instance",
        .OperationalLimitSetAtTerminal => "cim:OperationalLimitSet.Terminal is missing, " ++
            "unreadable, dangling, or does not refer to a cim:Terminal",
        .ControlModeCompatibility => "cim:TapChangerControl or cim:RegulatingControl with " ++
            "invalid cim:RegulatingControl.mode.",
        .ACLineSegmentR => "a provided cim:ACLineSegment.r is empty, unreadable, " ++
            "non-finite, or negative",
        .LinearShuntCompensatorG => "a provided " ++
            "cim:LinearShuntCompensator.gPerSection is empty, unreadable, " ++
            "non-finite, or negative",
        .ShuntCompensatorSections => "cim:ShuntCompensator.normalSections or " ++
            "cim:ShuntCompensator.maximumSections is empty, unreadable, or negative, " ++
            "or normalSections exceeds maximumSections",
        .SVCSlope => "a provided cim:StaticVarCompensator.slope is empty, " ++
            "unreadable, non-finite, or negative",
        .RCCYValues => "cim:CurveData.y2value is below cim:CurveData.y1value, " ++
            "or both values are equal at every point of a ReactiveCapabilityCurve",
        .RCCXValues2 => "a SynchronousMachine reactive capability curve has invalid " ++
            "CurveData x values for its machine type",
        .RCCXValues3 => "invalid reactive capability curve data for a cim:SynchronousMachine",
        .PhaseCodeGround => "Grounding equipment does not have phase code N",
        .PowerTransformerEndRatedU => "cim:PowerTransformerEnd.ratedU is not greater " ++
            "than zero",
        .SMQLimits1 => "cim:SynchronousMachine.maxQ is not greater than or equal to " ++
            "cim:SynchronousMachine.minQ",
        .SMPLimits => "The active power limit values do not match the " ++
            "cim:SynchronousMachine.type.",
        .CurveXValues => "Some points in the reactive capability curve have " ++
            "the same x value.",
        .RCCXValues4 => "Invalid reactive capability curve data for a " ++
            "cim:SynchronousMachine.",
        .RCandTCCcontrollingObjects => "cim:RegulatingControl or " ++
            "cim:TapChangerControl without controlling objects.",
        .WindingConnectionAngle => "cim:PhaseTapChangerAsymmetrical." ++
            "windingConnectionAngle value is not one of the defined values.",
    };
}

test "every rule message is a single line" {
    inline for (@typeInfo(Rule).@"enum".fields) |field| {
        const text = message(@field(Rule, field.name));
        try std.testing.expect(text.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
    }
}

test "every severity renders as one bare lowercase word" {
    // The report prints `@tagName(severity)` as a field of a single-line,
    // colon-separated record; a space or a capital would break both the
    // format and the grep key.
    for ([_]Severity{ .@"error", .warning, .info }) |level| {
        const word = @tagName(level);
        try std.testing.expect(word.len > 0);
        for (word) |byte| try std.testing.expect(std.ascii.isLower(byte));
    }
    try std.testing.expectEqualStrings("error", @tagName(Severity.@"error"));
}

test "severity rank orders most serious first" {
    try std.testing.expect(Severity.@"error".at_least(.@"error"));
    try std.testing.expect(Severity.@"error".at_least(.info));
    try std.testing.expect(!Severity.info.at_least(.warning));
    try std.testing.expect(Severity.warning.at_least(.warning));
}

test "mask_at_least selects exactly the rules at or above the floor" {
    for ([_]Severity{ .@"error", .warning, .info }) |floor| {
        const mask = mask_at_least(floor);
        var index: u32 = 0;
        while (index < rule_count) : (index += 1) {
            const rule: Rule = @enumFromInt(index);
            try std.testing.expectEqual(severity(rule).at_least(floor), mask.contains(rule));
        }
    }
    // The lowest floor admits the whole inventory, whatever the assignment is.
    try std.testing.expectEqual(rule_count, mask_at_least(.info).count());
}
