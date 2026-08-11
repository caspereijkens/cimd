//! The closed QoCDC v4.1.4 rule inventory and report messages.
//!
//! Adding a rule starts here: add its stable report tag to `Rule`, then add
//! its single-line diagnostic to `message`. Grid-model execution lives in
//! `rules.zig`.

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
    // Grid model: additional per-object checks.
    SMQLimits2,
    SynchronousCondenser,
    RatedS,
    ShuntCompensatorSensitivity,
    CATieFlow,
};

pub const rule_count = @typeInfo(Rule).@"enum".fields.len;

/// The requested diagnostics of an engine run. The engine internally derives
/// the harvest/pass dependency closure from this set; harvest work for a
/// dependency never emits diagnostics for rules outside the request.
pub const RuleMask = std.EnumSet(Rule);

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
        .SynchronousCondenser => "a synchronous condenser is associated with cim:GeneratingUnit.",
        .SMQLimits2 => "missing operating limits for a Synchronous Machine.",
        .RatedS => "cim:RotatingMachine.ratedS or cim:PowerTransformerEnd.ratedS " ++
            "is missing or is not a positive finite number.",
        .ShuntCompensatorSensitivity => "cim:ShuntCompensator.voltageSensitivity is provided " ++
            "but is not a positive finite number.",
        .CATieFlow => "an interchange cim:ControlArea has no referring cim:TieFlow instance",
    };
}

test "every rule message is a single line" {
    inline for (@typeInfo(Rule).@"enum".fields) |field| {
        const text = message(@field(Rule, field.name));
        try std.testing.expect(text.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
    }
}
