//! QoCDC grid-model rules and their shared execution data.
//!
//! Applicable object rules share one child walk per object through `Slots`.
//! Rules that need other objects opt into reference resolution; relational
//! rules harvest compact columns for a later array-only pass.

const std = @import("std");
const assert = std.debug.assert;

const cim = @import("../cim/cim.zig");
const catalog = @import("catalog.zig");
const data = @import("reference_data.zig");
const report_mod = @import("report.zig");

const cim_types = cim.cim_types;
const parse = cim.parse;

pub const Rule = catalog.Rule;
pub const rule_count = catalog.rule_count;
pub const RuleMask = catalog.RuleMask;
pub const message = catalog.message;

// ── property slots ────────────────────────────────────────────────────────

/// Every child name any table entry reads. One enum so a slot index is a
/// small comptime constant and one object walk can fill values for every
/// active rule at once.
pub const Prop = enum(u8) {
    io_name,
    io_short_name,
    io_description,
    io_eic,
    bp_from_iso,
    bp_to_iso,
    bp_from_name,
    bp_to_name,
    bp_from_name_tso,
    bp_to_name_tso,
    bv_nominal_voltage,
    lrc_exponent_model,
    lrc_p_voltage_exp,
    lrc_q_voltage_exp,
    lrc_p_z,
    lrc_p_i,
    lrc_p_p,
    lrc_q_z,
    lrc_q_i,
    lrc_q_p,
    es_voltage_magnitude,
    es_voltage_angle,
    svc_capacitive,
    svc_inductive,
    gu_nominal_p,
    gu_rated_s,
    sm_type,
    rm_generating_unit,
    rotating_machine_rated_s,
    power_transformer_end_rated_s,
    sm_min_q,
    sm_max_q,
    sm_initial_reactive_capability_curve,
    meas_type,
    meas_unit,
    eq_container,
    cn_container,
    term_conn_node,
    acdc_seq_num,
    term_conducting_equipment,
    dcterm_dc_conducting_equipment,
    te_terminal,
    pte_power_transformer,
    mc_first,
    mc_second,
    ce_base_voltage,
    meas_terminal,
    meas_psr,
    vl_base_voltage,
    bay_voltage_level,
    shunt_compensator_voltage_sensitivity,
    control_area_type,
    tie_flow_control_area,
    operational_limit_set_terminal,
    regulating_control_mode,
    regulating_control_terminal,
    regulating_control_enabled,
    regulating_cond_eq_control,
    tap_changer_control,
    tap_changer_control_enabled,
    phase_tap_changer_transformer_end,
    ratio_tap_changer_transformer_end,
    ac_line_segment_resistance,
    linear_shunt_compensator_conductance,
    shunt_compensator_normal_sections,
    shunt_compensator_maximum_sections,
    svc_slope,
    curve_data_curve,
    curve_data_y1value,
    curve_data_y2value,
    curve_data_xvalue,
    generating_unit_operating_power_min,
    generating_unit_operating_power_max,
    terminal_phase_code,
};

pub const prop_count = @typeInfo(Prop).@"enum".fields.len;

pub fn prop_name(prop: Prop) []const u8 {
    return switch (prop) {
        .io_name => "IdentifiedObject.name",
        .io_short_name => "IdentifiedObject.shortName",
        .io_description => "IdentifiedObject.description",
        .io_eic => "IdentifiedObject.energyIdentCodeEic",
        .bp_from_iso => "BoundaryPoint.fromEndIsoCode",
        .bp_to_iso => "BoundaryPoint.toEndIsoCode",
        .bp_from_name => "BoundaryPoint.fromEndName",
        .bp_to_name => "BoundaryPoint.toEndName",
        .bp_from_name_tso => "BoundaryPoint.fromEndNameTso",
        .bp_to_name_tso => "BoundaryPoint.toEndNameTso",
        .bv_nominal_voltage => "BaseVoltage.nominalVoltage",
        .lrc_exponent_model => "LoadResponseCharacteristic.exponentModel",
        .lrc_p_voltage_exp => "LoadResponseCharacteristic.pVoltageExponent",
        .lrc_q_voltage_exp => "LoadResponseCharacteristic.qVoltageExponent",
        .lrc_p_z => "LoadResponseCharacteristic.pConstantImpedance",
        .lrc_p_i => "LoadResponseCharacteristic.pConstantCurrent",
        .lrc_p_p => "LoadResponseCharacteristic.pConstantPower",
        .lrc_q_z => "LoadResponseCharacteristic.qConstantImpedance",
        .lrc_q_i => "LoadResponseCharacteristic.qConstantCurrent",
        .lrc_q_p => "LoadResponseCharacteristic.qConstantPower",
        .es_voltage_magnitude => "EnergySource.voltageMagnitude",
        .es_voltage_angle => "EnergySource.voltageAngle",
        .svc_capacitive => "StaticVarCompensator.capacitiveRating",
        .svc_inductive => "StaticVarCompensator.inductiveRating",
        .gu_nominal_p => "GeneratingUnit.nominalP",
        .gu_rated_s => "GeneratingUnit.ratedS",
        .sm_type => "SynchronousMachine.type",
        .rm_generating_unit => "RotatingMachine.GeneratingUnit",
        .rotating_machine_rated_s => "RotatingMachine.ratedS",
        .sm_min_q => "SynchronousMachine.minQ",
        .sm_max_q => "SynchronousMachine.maxQ",
        .sm_initial_reactive_capability_curve => "SynchronousMachine.InitialReactiveCapabilityCurve",
        .meas_type => "Measurement.measurementType",
        .meas_unit => "Measurement.unitSymbol",
        .eq_container => "Equipment.EquipmentContainer",
        .cn_container => "ConnectivityNode.ConnectivityNodeContainer",
        .term_conn_node => "Terminal.ConnectivityNode",
        .acdc_seq_num => "ACDCTerminal.sequenceNumber",
        .term_conducting_equipment => "Terminal.ConductingEquipment",
        .dcterm_dc_conducting_equipment => "DCTerminal.DCConductingEquipment",
        .te_terminal => "TransformerEnd.Terminal",
        .pte_power_transformer => "PowerTransformerEnd.PowerTransformer",
        .power_transformer_end_rated_s => "PowerTransformerEnd.ratedS",
        .mc_first => "MutualCoupling.First_Terminal",
        .mc_second => "MutualCoupling.Second_Terminal",
        .ce_base_voltage => "ConductingEquipment.BaseVoltage",
        .meas_terminal => "Measurement.Terminal",
        .meas_psr => "Measurement.PowerSystemResource",
        .vl_base_voltage => "VoltageLevel.BaseVoltage",
        .bay_voltage_level => "Bay.VoltageLevel",
        .shunt_compensator_voltage_sensitivity => "ShuntCompensator.voltageSensitivity",
        .control_area_type => "ControlArea.type",
        .tie_flow_control_area => "TieFlow.ControlArea",
        .operational_limit_set_terminal => "OperationalLimitSet.Terminal",
        .regulating_control_mode => "RegulatingControl.mode",
        .regulating_control_terminal => "RegulatingControl.Terminal",
        .regulating_control_enabled => "RegulatingControl.enabled",
        .regulating_cond_eq_control => "RegulatingCondEq.RegulatingControl",
        .tap_changer_control => "TapChanger.TapChangerControl",
        .tap_changer_control_enabled => "TapChanger.controlEnabled",
        .phase_tap_changer_transformer_end => "PhaseTapChanger.TransformerEnd",
        .ratio_tap_changer_transformer_end => "RatioTapChanger.TransformerEnd",
        .ac_line_segment_resistance => "ACLineSegment.r",
        .linear_shunt_compensator_conductance => "LinearShuntCompensator.gPerSection",
        .shunt_compensator_normal_sections => "ShuntCompensator.normalSections",
        .shunt_compensator_maximum_sections => "ShuntCompensator.maximumSections",
        .svc_slope => "StaticVarCompensator.slope",
        .curve_data_curve => "CurveData.Curve",
        .curve_data_y1value => "CurveData.y1value",
        .curve_data_y2value => "CurveData.y2value",
        .curve_data_xvalue => "CurveData.xvalue",
        .generating_unit_operating_power_min => "GeneratingUnit.minOperatingP",
        .generating_unit_operating_power_max => "GeneratingUnit.maxOperatingP",
        .terminal_phase_code => "Terminal.phases",
    };
}

// ── the traits column ─────────────────────────────────────────────────────

/// Per-object class memberships, computed once per type name and `@memset`
/// over the type's contiguous index range. Containment rules test their
/// container's traits with one AND instead of resolving `is_a` per object;
/// the relational passes test their row targets the same way.
pub const TargetTraits = packed struct(u32) {
    // Container classes (containment rules + CEBaseVoltage):
    substation: bool = false,
    voltage_level: bool = false,
    bay: bool = false,
    line: bool = false,
    dc_converter_unit: bool = false,
    // Relational-rule class memberships:
    terminal: bool = false, // is_a Terminal
    ac_line_segment: bool = false,
    power_transformer: bool = false,
    equipment: bool = false,
    /// The TerminalCount1 target set: 9 listed classes plus strict
    /// subclasses of Connector.
    count1: bool = false,
    /// The TerminalCount2 target set: 7 listed classes plus strict
    /// subclasses of DCSwitch.
    count2: bool = false,
    equivalent_branch: bool = false,
    /// is_a ConductingEquipment or DCConductingEquipment (TerminalSeqNumOrder).
    ce_or_dcce: bool = false,
    reactive_capability_curve: bool = false,
    conducting_equipment: bool = false,
    busbar_section: bool = false,
    power_transformer_end: bool = false,
    /// The PhaseCodeGround target set, including GroundDisconnector because
    /// both of its terminals must be neutral terminals.
    phase_code_ground: bool = false,
    _pad: u14 = 0,

    pub fn intersects(self: TargetTraits, allowed: TargetTraits) bool {
        return @as(u32, @bitCast(self)) & @as(u32, @bitCast(allowed)) != 0;
    }
};

/// Traits of one class name. Called once per type group; every test inside
/// is a comptime-resolved TypeId bit test.
pub fn compute_traits(type_name: []const u8) TargetTraits {
    const tid = cim_types.type_id(type_name);
    const is_a = struct {
        fn of(actual: ?cim_types.TypeId, name: []const u8, comptime target: []const u8) bool {
            return matches_is_a(actual, name, target);
        }
    }.of;
    const count1_targets = [_][]const u8{
        "RegulatingCondEq", "EnergyConsumer", "EquivalentInjection", "EquivalentShunt",
        "EnergySource",     "Ground",         "DCBusbar",            "DCShunt",
        "DCGround",
    };
    const count2_targets = [_][]const u8{
        "Conductor",     "Switch",         "SeriesCompensator", "EquivalentBranch",
        "DCLineSegment", "DCSeriesDevice", "DCChopper",
    };

    var count1 = false;
    inline for (count1_targets) |target| count1 = count1 or is_a(tid, type_name, target);
    // Strict subclasses of Connector: the class itself is excluded.
    count1 = count1 or (is_a(tid, type_name, "Connector") and !std.mem.eql(u8, type_name, "Connector"));

    var count2 = false;
    inline for (count2_targets) |target| count2 = count2 or is_a(tid, type_name, target);
    count2 = count2 or (is_a(tid, type_name, "DCSwitch") and !std.mem.eql(u8, type_name, "DCSwitch"));

    return .{
        .substation = is_a(tid, type_name, "Substation"),
        .voltage_level = is_a(tid, type_name, "VoltageLevel"),
        .bay = is_a(tid, type_name, "Bay"),
        .line = is_a(tid, type_name, "Line"),
        .dc_converter_unit = is_a(tid, type_name, "DCConverterUnit"),
        .terminal = is_a(tid, type_name, "Terminal"),
        .ac_line_segment = is_a(tid, type_name, "ACLineSegment"),
        .power_transformer = is_a(tid, type_name, "PowerTransformer"),
        .equipment = is_a(tid, type_name, "Equipment"),
        .count1 = count1,
        .count2 = count2,
        .equivalent_branch = is_a(tid, type_name, "EquivalentBranch"),
        .ce_or_dcce = is_a(tid, type_name, "ConductingEquipment") or
            is_a(tid, type_name, "DCConductingEquipment"),
        .reactive_capability_curve = is_a(tid, type_name, "ReactiveCapabilityCurve"),
        .conducting_equipment = is_a(tid, type_name, "ConductingEquipment"),
        .busbar_section = is_a(tid, type_name, "BusbarSection"),
        .power_transformer_end = is_a(tid, type_name, "PowerTransformerEnd"),
        .phase_code_ground = is_a(tid, type_name, "PetersenCoil") or
            is_a(tid, type_name, "Ground") or
            is_a(tid, type_name, "GroundingImpedance") or
            is_a(tid, type_name, "GroundDisconnector"),
    };
}

/// The lookup channels a predicate reads a slot through. They deliberately
/// select different occurrences, mirroring the CimObject query trio:
/// `text` = first expanded non-self-closing literal (`property()`), `ref` =
/// first readable rdf:resource (`reference()`, malformed poisons the
/// channel), `declared` = any occurrence at all (`declares_child`).
pub const Channels = packed struct(u3) {
    text: bool = false,
    ref: bool = false,
    declared: bool = false,
};

pub const Need = struct { prop: Prop, channels: Channels };

pub const RefState = union(enum) { absent, value: []const u8, malformed };

pub const Slot = struct {
    declared: bool = false,
    /// First expanded `.property` occurrence's raw text.
    text: ?[]const u8 = null,
    /// First `.reference` occurrence, or `.malformed` when the first
    /// name-match carried an unreadable rdf:resource.
    reference: RefState = .absent,
};

pub const Slots = [prop_count]Slot;

/// Whether every channel `channels` asks for has its first match. A channel
/// that never matches cannot settle -- the walk then runs to the object's
/// last child, exactly like the batched `properties()` primitive.
pub fn slot_settled(slot: Slot, channels: Channels) bool {
    if (channels.text and slot.text == null) return false;
    if (channels.ref and slot.reference == .absent) return false;
    if (channels.declared and !slot.declared) return false;
    return true;
}

fn slot_of(slots: *const Slots, prop: Prop) *const Slot {
    return &slots[@intFromEnum(prop)];
}

/// Text value as `property()` would answer it.
pub fn prop_text(slots: *const Slots, prop: Prop) ?[]const u8 {
    return slot_of(slots, prop).text;
}

/// Reference as `reference()` would answer it; `.malformed` is what the
/// query's `error.MalformedTag` becomes.
pub fn prop_ref(slots: *const Slots, prop: Prop) RefState {
    return slot_of(slots, prop).reference;
}

/// Whether the child was declared at all, whatever its serialization.
pub fn prop_declared(slots: *const Slots, prop: Prop) bool {
    return slot_of(slots, prop).declared;
}

// ── harvested columns ─────────────────────────────────────────────────────

/// Sentinel object index: "no target" (unresolvable or never set).
pub const none_index: u32 = std.math.maxInt(u32);

/// Sequence-number encodings in `TerminalRow.seq`.
pub const seq_absent: u32 = std.math.maxInt(u32);
pub const seq_invalid: u32 = std.math.maxInt(u32) - 1;

/// The CIM PhaseCode value space plus parser states that cannot be represented
/// by a PhaseCode URI. Keeping every known value distinct lets later rules
/// reuse the harvested Terminal row without walking its properties again.
pub const PhaseCode = enum(u8) {
    absent,
    invalid,
    A,
    AB,
    ABC,
    ABCN,
    ABN,
    AC,
    ACN,
    AN,
    B,
    BC,
    BCN,
    BN,
    C,
    CN,
    N,
    X,
    XN,
    XY,
    XYN,
    none,
    s1,
    s12,
    s12N,
    s1N,
    s2,
    s2N,
};

const phase_codes = std.StaticStringMap(PhaseCode).initComptime(.{
    .{ "PhaseCode.A", .A },
    .{ "PhaseCode.AB", .AB },
    .{ "PhaseCode.ABC", .ABC },
    .{ "PhaseCode.ABCN", .ABCN },
    .{ "PhaseCode.ABN", .ABN },
    .{ "PhaseCode.AC", .AC },
    .{ "PhaseCode.ACN", .ACN },
    .{ "PhaseCode.AN", .AN },
    .{ "PhaseCode.B", .B },
    .{ "PhaseCode.BC", .BC },
    .{ "PhaseCode.BCN", .BCN },
    .{ "PhaseCode.BN", .BN },
    .{ "PhaseCode.C", .C },
    .{ "PhaseCode.CN", .CN },
    .{ "PhaseCode.N", .N },
    .{ "PhaseCode.X", .X },
    .{ "PhaseCode.XN", .XN },
    .{ "PhaseCode.XY", .XY },
    .{ "PhaseCode.XYN", .XYN },
    .{ "PhaseCode.none", .none },
    .{ "PhaseCode.s1", .s1 },
    .{ "PhaseCode.s12", .s12 },
    .{ "PhaseCode.s12N", .s12N },
    .{ "PhaseCode.s1N", .s1N },
    .{ "PhaseCode.s2", .s2 },
    .{ "PhaseCode.s2N", .s2N },
});

fn parse_phase_code(reference: RefState, declared: bool) PhaseCode {
    return switch (reference) {
        .absent => if (declared) .invalid else .absent,
        .malformed => .invalid,
        .value => |value| phase_codes.get(cim.uri.fragment_or_self(value)) orelse .invalid,
    };
}

test "parse_phase_code preserves every CIM PhaseCode value" {
    const fields = @typeInfo(PhaseCode).@"enum".fields;
    inline for (fields[2..]) |field| {
        const expected: PhaseCode = @enumFromInt(field.value);
        const reference = "#PhaseCode." ++ field.name;
        try std.testing.expectEqual(expected, parse_phase_code(.{ .value = reference }, true));
    }
    try std.testing.expectEqual(
        PhaseCode.ABCN,
        parse_phase_code(.{ .value = "http://iec.ch/TC57/CIM100#PhaseCode.ABCN" }, true),
    );
    try std.testing.expectEqual(PhaseCode.absent, parse_phase_code(.absent, false));
    try std.testing.expectEqual(PhaseCode.invalid, parse_phase_code(.absent, true));
    try std.testing.expectEqual(PhaseCode.invalid, parse_phase_code(.malformed, true));
    try std.testing.expectEqual(
        PhaseCode.invalid,
        parse_phase_code(.{ .value = "#PhaseCode.unknown" }, true),
    );
}

pub const TerminalRow = struct {
    terminal_index: u32,
    /// Resolved equipment target; rows are only appended when it resolves.
    equipment_index: u32,
    seq: u32,
    phase: PhaseCode,
    flags: packed struct(u8) {
        /// The terminal's class is exactly "Terminal" (the TerminalCount and
        /// TerminalSeqNum rules filter on the exact class, qocdc's original
        /// reverse-reference filter).
        exact_terminal: bool,
        /// The association was Terminal.ConductingEquipment (vs the DC one).
        via_terminal_ce: bool,
        _pad: u6 = 0,
    },
};

pub const McRow = struct {
    object_index: u32,
    /// Resolved terminal targets, `none_index` when absent, malformed, or
    /// dangling. Each resolvable end marks its line as coupled regardless of
    /// the other end -- TerminalSeqNum's gate must see a line as coupled even
    /// when the MutualCoupling fails another MCFirstSecond condition.
    first: u32,
    second: u32,
    /// Either reference was absent, malformed, or dangling: an MCFirstSecond
    /// violation; the pair checks are skipped.
    incomplete: bool,
};

pub const PtEndRow = struct {
    object_index: u32,
    terminal_index: u32,
    transformer_index: u32,
};

pub const TapChangerKind = enum(u8) { phase, ratio };

/// A tap changer whose TransformerEnd association resolves to a
/// PowerTransformerEnd. The two enabled flags are joined in Phase B because
/// the referenced RegulatingControl may occur anywhere in document order.
pub const TapChangerRow = struct {
    end_index: u32,
    control_index: u32,
    kind: TapChangerKind,
    control_enabled: bool,
};

pub const MeasurementRow = struct {
    object_index: u32,
    terminal_index: u32,
    psr_index: u32,
};

/// The four RegulatingControl modes admitted by this QoCDC rule. `invalid`
/// covers both the four explicitly prohibited enumeration members and an
/// unknown or unreadable provided value; an absent optional association is
/// represented by `null` in `ControlRow`.
pub const ControlMode = enum(u8) {
    invalid,
    active_power,
    voltage,
    reactive_power,
    power_factor,
};

/// Kinds of equipment whose forward control association resolves to a given
/// RegulatingControl. Multiple objects may share a control, so Phase A ORs
/// these flags and Phase B requires the mode to satisfy every represented
/// kind.
pub const ControlEquipmentKinds = packed struct(u8) {
    phase_tap_changer: bool = false,
    ratio_tap_changer: bool = false,
    synchronous_machine: bool = false,
    shunt_compensator: bool = false,
    static_var_compensator: bool = false,
    _pad: u3 = 0,
};

pub const ControlRow = struct {
    object_index: u32,
    terminal_index: u32,
    mode: ?ControlMode,
    /// False means the optional association is absent. True with
    /// `terminal_index == none_index` means it was provided but unusable.
    terminal_declared: bool,
};

/// Whether one provided mode is compatible with every controlling-equipment
/// kind sharing the control and with a BusbarSection control point.
pub fn control_mode_compatible(
    mode_optional: ?ControlMode,
    kinds: ControlEquipmentKinds,
    controls_busbar: bool,
) bool {
    const mode = mode_optional orelse return true;
    if (mode == .invalid) return false;
    if (controls_busbar and mode != .voltage) return false;
    if (kinds.phase_tap_changer and mode != .active_power) return false;
    if (kinds.ratio_tap_changer and
        mode != .voltage and mode != .reactive_power and mode != .power_factor)
    {
        return false;
    }
    if ((kinds.synchronous_machine or kinds.shunt_compensator) and
        mode != .voltage and mode != .reactive_power and mode != .power_factor)
    {
        return false;
    }
    if (kinds.static_var_compensator and
        mode != .voltage and mode != .reactive_power)
    {
        return false;
    }
    return true;
}

pub const CeBvRow = struct {
    object_index: u32,
    /// The equipment's declared BaseVoltage id, hash-stripped. Kept as a
    /// STRING: the rule compares ids, and an EQ file legitimately references
    /// BaseVoltages defined elsewhere (the boundary set) -- resolving via the
    /// index would turn a dangling-but-consistent pair into a violation.
    base_voltage_id: ?[]const u8,
    /// Resolved Equipment.EquipmentContainer, or `none_index`.
    container_index: u32,
};

/// A VoltageLevel's declared BaseVoltage. Rows are appended in object-index
/// order (the type range is contiguous), so lookup is a binary search.
pub const VlRow = struct {
    object_index: u32,
    base_voltage_id: ?[]const u8,
};

/// A Bay's resolved VoltageLevel. Same ordering guarantee as `VlRow`.
pub const BayRow = struct {
    object_index: u32,
    voltage_level_index: u32,
};

/// A CurveData point whose two y values compare equal. Phase B emits the row
/// only when no other point has disqualified its referenced curve.
pub const CurveEqualRow = struct {
    object_index: u32,
    curve_index: u32,
};

/// Parsed CurveData.xvalue. Unusable values remain in the point count but
/// make every machine using the curve fail either RCC x-value rule.
pub const CurveXValue = union(enum) {
    unusable,
    value: f64,
};

pub const CurveXPointRow = struct {
    curve_index: u32,
    x: CurveXValue,
};

/// Constraint selected by SynchronousMachine.type.
pub const RccXRequirement = enum(u8) {
    invalid,
    condenser,
    generator,
    motor,
    generator_or_motor,
};

pub const MachineCurveRow = struct {
    object_index: u32,
    curve_index: u32,
    requirement: RccXRequirement,
};

pub const MachineCurveUnitRow = struct {
    object_index: u32,
    curve_index: u32,
    generating_unit_index: u32,
};

pub const OperatingPowerBounds = union(enum) {
    unusable,
    value: struct { min: f64, max: f64 },
};

pub const GeneratingUnitBoundsRow = struct {
    object_index: u32,
    bounds: OperatingPowerBounds,
};

/// One derived row per curve. Phase B builds it once so machines sharing a
/// curve do not repeatedly scan the same CurveData points.
pub const CurveXSummaryRow = struct {
    curve_index: u32,
    point_count: u32 = 0,
    nonnegative_count: u32 = 0,
    nonpositive_count: u32 = 0,
    zero_count: u32 = 0,
    min_x: f64 = std.math.inf(f64),
    max_x: f64 = -std.math.inf(f64),
    unusable: bool = false,

    pub fn add(self: *CurveXSummaryRow, x: CurveXValue) void {
        self.point_count +|= 1;
        switch (x) {
            .unusable => self.unusable = true,
            .value => |value| {
                assert(std.math.isFinite(value));
                self.min_x = @min(self.min_x, value);
                self.max_x = @max(self.max_x, value);
                if (value < 0) {
                    self.nonpositive_count +|= 1;
                } else if (value == 0) {
                    self.nonnegative_count +|= 1;
                    self.nonpositive_count +|= 1;
                    self.zero_count +|= 1;
                } else {
                    self.nonnegative_count +|= 1;
                }
            },
        }
    }
};

/// Whether one curve summary satisfies a machine type.
pub fn rcc_x_requirement_satisfied(
    requirement: RccXRequirement,
    summary_optional: ?CurveXSummaryRow,
) bool {
    const summary = summary_optional orelse return false;
    if (summary.unusable) return false;
    return switch (requirement) {
        .invalid => false,
        .condenser => summary.point_count == 1 and summary.zero_count == 1,
        .generator => summary.nonnegative_count >= 2,
        .motor => summary.nonpositive_count >= 2,
        .generator_or_motor => summary.point_count >= 3 and
            summary.nonnegative_count >= 1 and summary.nonpositive_count >= 1,
    };
}

/// RCCXValues3 is vacuously satisfied when a curve has no points; point
/// cardinality belongs to RCCXValues2. Otherwise every point must be usable
/// and the curve extrema must fall inside the generating-unit bounds.
pub fn rcc_x_bounds_satisfied(
    bounds: OperatingPowerBounds,
    summary_optional: ?CurveXSummaryRow,
) bool {
    const summary = summary_optional orelse return true;
    assert(summary.point_count > 0);
    if (summary.unusable) return false;
    const limits = switch (bounds) {
        .unusable => return false,
        .value => |value| value,
    };
    return summary.min_x >= limits.min and summary.max_x <= limits.max;
}

/// Side tables filled during the fused sweep and consumed by the engine's
/// Phase B. Everything is keyed by u32 object index; the string-keyed
/// ReverseRefIndex is never built.
pub const Columns = struct {
    /// Dense: terminal object index -> resolved equipment index or none.
    terminal_equipment: []u32,
    /// Dense: equipment index -> count of exact-Terminal referrers via
    /// Terminal.ConductingEquipment (saturating; any count > 2 violates both
    /// count rules identically).
    terminal_count: []u8,
    /// Dense bitset: terminal indexes counted above (exact Terminal, via
    /// Terminal.ConductingEquipment, equipment resolved) -- the edges that
    /// qualify a line as coupled.
    terminal_exact_ce: std.DynamicBitSetUnmanaged,
    /// Dense bitset: equipment touched by a MutualCoupling end (Phase B1).
    coupled: std.DynamicBitSetUnmanaged,
    terminals: std.ArrayList(TerminalRow),
    mutual_couplings: std.ArrayList(McRow),
    pt_ends: std.ArrayList(PtEndRow),
    tap_changers: std.ArrayList(TapChangerRow),
    /// Dense bitset of RegulatingControl objects whose enabled property is
    /// exactly true. TapChanger rows resolve their control against it later.
    regulating_controls_enabled: std.DynamicBitSetUnmanaged,
    measurements: std.ArrayList(MeasurementRow),
    ce_bv: std.ArrayList(CeBvRow),
    vl_rows: std.ArrayList(VlRow),
    bay_rows: std.ArrayList(BayRow),
    interchange_control_areas: std.ArrayList(u32),
    tie_flow_control_areas: std.DynamicBitSetUnmanaged,
    controls: std.ArrayList(ControlRow),
    /// Dense: control object index -> kinds of referring controlling
    /// equipment, populated from the associations on that equipment.
    control_equipment_kinds: []ControlEquipmentKinds,

    curve_equal_points: std.ArrayList(CurveEqualRow),
    /// Curve indexes with a strict inequality or an unusable y value.
    curve_all_equal_disqualified: std.DynamicBitSetUnmanaged,
    curve_x_points: std.ArrayList(CurveXPointRow),
    machine_curves: std.ArrayList(MachineCurveRow),
    machine_curve_units: std.ArrayList(MachineCurveUnitRow),
    generating_unit_bounds: std.ArrayList(GeneratingUnitBoundsRow),

    pub fn init(gpa: std.mem.Allocator, object_count: u32) error{OutOfMemory}!Columns {
        const terminal_equipment = try gpa.alloc(u32, object_count);
        errdefer gpa.free(terminal_equipment);
        @memset(terminal_equipment, none_index);
        const terminal_count = try gpa.alloc(u8, object_count);
        errdefer gpa.free(terminal_count);
        @memset(terminal_count, 0);
        var terminal_exact_ce = try std.DynamicBitSetUnmanaged.initEmpty(gpa, object_count);
        errdefer terminal_exact_ce.deinit(gpa);
        var coupled = try std.DynamicBitSetUnmanaged.initEmpty(gpa, object_count);
        errdefer coupled.deinit(gpa);
        var tie_flow_control_areas = try std.DynamicBitSetUnmanaged.initEmpty(gpa, object_count);
        errdefer tie_flow_control_areas.deinit(gpa);
        var regulating_controls_enabled = try std.DynamicBitSetUnmanaged.initEmpty(gpa, object_count);
        errdefer regulating_controls_enabled.deinit(gpa);
        const control_equipment_kinds = try gpa.alloc(ControlEquipmentKinds, object_count);
        errdefer gpa.free(control_equipment_kinds);
        @memset(control_equipment_kinds, .{});
        var curve_all_equal_disqualified = try std.DynamicBitSetUnmanaged.initEmpty(gpa, object_count);
        errdefer curve_all_equal_disqualified.deinit(gpa);
        return .{
            .terminal_equipment = terminal_equipment,
            .terminal_count = terminal_count,
            .terminal_exact_ce = terminal_exact_ce,
            .coupled = coupled,
            .terminals = .empty,
            .mutual_couplings = .empty,
            .pt_ends = .empty,
            .tap_changers = .empty,
            .regulating_controls_enabled = regulating_controls_enabled,
            .measurements = .empty,
            .ce_bv = .empty,
            .vl_rows = .empty,
            .bay_rows = .empty,
            .interchange_control_areas = .empty,
            .tie_flow_control_areas = tie_flow_control_areas,
            .controls = .empty,
            .control_equipment_kinds = control_equipment_kinds,
            .curve_equal_points = .empty,
            .curve_all_equal_disqualified = curve_all_equal_disqualified,
            .curve_x_points = .empty,
            .machine_curves = .empty,
            .machine_curve_units = .empty,
            .generating_unit_bounds = .empty,
        };
    }

    pub fn deinit(self: *Columns, gpa: std.mem.Allocator) void {
        gpa.free(self.terminal_equipment);
        gpa.free(self.terminal_count);
        self.terminal_exact_ce.deinit(gpa);
        self.coupled.deinit(gpa);
        self.terminals.deinit(gpa);
        self.mutual_couplings.deinit(gpa);
        self.pt_ends.deinit(gpa);
        self.tap_changers.deinit(gpa);
        self.regulating_controls_enabled.deinit(gpa);
        self.measurements.deinit(gpa);
        self.ce_bv.deinit(gpa);
        self.vl_rows.deinit(gpa);
        self.bay_rows.deinit(gpa);
        self.interchange_control_areas.deinit(gpa);
        self.tie_flow_control_areas.deinit(gpa);
        self.controls.deinit(gpa);
        gpa.free(self.control_equipment_kinds);
        self.curve_equal_points.deinit(gpa);
        self.curve_all_equal_disqualified.deinit(gpa);
        self.curve_x_points.deinit(gpa);
        self.machine_curves.deinit(gpa);
        self.machine_curve_units.deinit(gpa);
        self.generating_unit_bounds.deinit(gpa);
    }
};

/// The rules whose verdicts need harvested columns (and so the traits column
/// and reference resolution too).
pub const relational_rules = [_]Rule{
    .TerminalCount1,        .TerminalCount2, .TerminalSeqNum,           .TerminalSeqNumOrder,
    .PTTerminalConsistency, .MCFirstSecond,  .MeasTerminal,             .TooManyTapChangers,
    .CEBaseVoltage,         .CATieFlow,      .ControlModeCompatibility, .RCCYValues,
    .RCCXValues2,           .RCCXValues3,    .PhaseCodeGround,
};

// ── the object-rule table ─────────────────────────────────────────────────

/// Class scope of a table entry, evaluated once per type group.
pub const TypeFilter = union(enum) {
    /// Every object.
    all,
    /// Every object except subtypes of `is_a_not` entries and exact
    /// `names_not` class names.
    all_except: struct { is_a_not: []const []const u8, names_not: []const []const u8 },
    /// One exact class name; also reaches classes unknown to cim_types.
    exact: []const u8,
    /// Subtypes (inclusive) of any listed class.
    is_a_any: []const []const u8,
    /// Subtypes of any `any` entry, minus subtypes of any `except` entry.
    is_a_any_except: struct { any: []const []const u8, except: []const []const u8 },
    /// Strict subtypes: `is_a` the class but not the class itself.
    strict_subclass: []const u8,
};

/// Profile gate of a table entry, evaluated once per run from the resolved
/// header. An unresolved header enables only `.always` entries.
pub const Gate = enum { always, eqbd, eq, eq_operations };

/// Engine state a predicate reads: the filled slots plus per-run and
/// per-group context. Owned by the engine; predicates only read slots and
/// emit violations.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    report: *report_mod.Report,
    model: *const cim.CimDocument,
    slots: *const Slots,
    /// CGMES version from the resolved header; null accepts either version's
    /// value space (the header was unresolved or did not declare one).
    version: ?cim.profile.Version = null,
    group_type_name: []const u8 = "",
    group_tid: ?cim_types.TypeId = null,
    /// MeasUnit's class-specific CGMES 3.0 unit set, resolved per group.
    group_v3_units: ?*const data.ExactStringSet = null,
    /// Per-object traits column; set when a rule with `needs_resolution` is
    /// active this run.
    traits: ?[]const TargetTraits = null,
    /// Reference resolution; set alongside `traits`.
    ref_index: ?*const cim.ReferenceIndex = null,
    /// Harvest sinks; set when any relational rule is requested.
    columns: ?*Columns = null,
    /// Index of the object under inspection in the document's object array;
    /// maintained by the engine's sweep.
    object_index: u32 = 0,

    pub fn emit(
        self: *Ctx,
        rule: Rule,
        obj: cim.CimObject,
        detail: []const u8,
    ) error{OutOfMemory}!void {
        try self.report.add(self.gpa, .{
            .rule = rule,
            .offset = obj.xml_offset(),
            .object_id = obj.id(),
            .detail = detail,
        });
    }
};

pub const ObjectRule = struct {
    rule: Rule,
    filter: TypeFilter,
    gate: Gate = .always,
    /// Whether the predicate consults `ctx.version` (forces header
    /// classification without gating on its outcome).
    uses_version: bool = false,
    /// Extra per-group predicate, run after the type filter matches; may
    /// stash per-group state on the ctx.
    group_gate: ?*const fn (ctx: *Ctx) bool = null,
    /// Whether the predicate resolves references against the traits column
    /// (the engine builds `ctx.traits`/`ctx.ref_index` when any such rule is
    /// requested).
    needs_resolution: bool = false,
    needs: []const Need,
    check: *const fn (ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void,
};

const text_only: Channels = .{ .text = true };
const declared_only: Channels = .{ .declared = true };

pub const object_rules = [_]ObjectRule{
    // NameLength: required non-empty name of at most IO_NAME_LENGTH chars for
    // everything but ACDCTerminal subtypes and the listed nameless classes.
    .{
        .rule = .NameLength,
        .filter = .{ .all_except = .{
            .is_a_not = &.{"ACDCTerminal"},
            .names_not = &data.nameless_type_names,
        } },
        .needs = &.{.{ .prop = .io_name, .channels = text_only }},
        .check = &check_name_length,
    },
    .{
        .rule = .ShortNameLength,
        .filter = .all,
        .needs = &.{.{ .prop = .io_short_name, .channels = text_only }},
        .check = &check_short_name_length,
    },
    .{
        .rule = .EICLength,
        .filter = .all,
        .needs = &.{.{ .prop = .io_eic, .channels = text_only }},
        .check = &check_eic_length,
    },
    .{
        .rule = .DescriptionLength,
        .filter = .all,
        .needs = &.{.{ .prop = .io_description, .channels = text_only }},
        .check = &check_description_length,
    },
    // BoundaryPoint rules: EQBD documents only.
    .{
        .rule = .CNFromEndIsoCode,
        .filter = .{ .exact = "BoundaryPoint" },
        .gate = .eqbd,
        .needs = &.{.{ .prop = .bp_from_iso, .channels = text_only }},
        .check = &check_bp_from_iso,
    },
    .{
        .rule = .CNToEndIsoCode,
        .filter = .{ .exact = "BoundaryPoint" },
        .gate = .eqbd,
        .needs = &.{.{ .prop = .bp_to_iso, .channels = text_only }},
        .check = &check_bp_to_iso,
    },
    .{
        .rule = .CNFromEndNameLength,
        .filter = .{ .exact = "BoundaryPoint" },
        .gate = .eqbd,
        .needs = &.{.{ .prop = .bp_from_name, .channels = text_only }},
        .check = &check_bp_from_name,
    },
    .{
        .rule = .CNToEndNameLength,
        .filter = .{ .exact = "BoundaryPoint" },
        .gate = .eqbd,
        .needs = &.{.{ .prop = .bp_to_name, .channels = text_only }},
        .check = &check_bp_to_name,
    },
    .{
        .rule = .CNFromEndNameTsoLength,
        .filter = .{ .exact = "BoundaryPoint" },
        .gate = .eqbd,
        .needs = &.{.{ .prop = .bp_from_name_tso, .channels = text_only }},
        .check = &check_bp_from_name_tso,
    },
    .{
        .rule = .CNToEndNameTsoLength,
        .filter = .{ .exact = "BoundaryPoint" },
        .gate = .eqbd,
        .needs = &.{.{ .prop = .bp_to_name_tso, .channels = text_only }},
        .check = &check_bp_to_name_tso,
    },
    .{
        .rule = .NominalVoltage,
        .filter = .{ .exact = "BaseVoltage" },
        .needs = &.{.{ .prop = .bv_nominal_voltage, .channels = text_only }},
        .check = &check_nominal_voltage,
    },
    // The three LoadResponseCharacteristic rules share slots; the union costs
    // nothing, the walk is one either way.
    .{
        .rule = .LRCExponentModel,
        .filter = .{ .exact = "LoadResponseCharacteristic" },
        .needs = &.{
            .{ .prop = .lrc_exponent_model, .channels = text_only },
            .{ .prop = .lrc_p_voltage_exp, .channels = text_only },
            .{ .prop = .lrc_q_voltage_exp, .channels = text_only },
        },
        .check = &check_lrc_exponent_model,
    },
    .{
        .rule = .LCRCoefficientModel,
        .filter = .{ .exact = "LoadResponseCharacteristic" },
        .needs = &lrc_coefficient_needs,
        .check = &check_lrc_coefficient_model,
    },
    .{
        .rule = .LCRCoefficientParameters,
        .filter = .{ .exact = "LoadResponseCharacteristic" },
        .needs = &lrc_coefficient_needs,
        .check = &check_lrc_coefficient_parameters,
    },
    .{
        .rule = .EnergySourceVoltage,
        .filter = .{ .exact = "EnergySource" },
        .needs = &.{
            .{ .prop = .es_voltage_magnitude, .channels = declared_only },
            .{ .prop = .es_voltage_angle, .channels = declared_only },
        },
        .check = &check_energy_source_voltage,
    },
    .{
        .rule = .SVCRatings,
        .filter = .{ .exact = "StaticVarCompensator" },
        .needs = &.{
            .{ .prop = .svc_capacitive, .channels = text_only },
            .{ .prop = .svc_inductive, .channels = text_only },
        },
        .check = &check_svc_ratings,
    },
    .{
        .rule = .GeneratingUnitNominalP,
        .filter = .{ .is_a_any = &.{"GeneratingUnit"} },
        .needs = &.{
            .{ .prop = .gu_nominal_p, .channels = text_only },
            .{ .prop = .gu_rated_s, .channels = text_only },
        },
        .check = &check_generating_unit_nominal_p,
    },
    .{
        .rule = .SMQLimits2,
        .filter = .{ .is_a_any = &.{"SynchronousMachine"} },
        .needs_resolution = true,
        .needs = &.{
            .{ .prop = .sm_min_q, .channels = text_only },
            .{ .prop = .sm_max_q, .channels = text_only },
            .{ .prop = .sm_initial_reactive_capability_curve, .channels = .{ .ref = true } },
        },
        .check = &check_synchronous_machine_limits,
    },
    .{
        .rule = .SynchronousCondenser,
        .filter = .{ .is_a_any = &.{"SynchronousMachine"} },
        .needs = &.{
            .{ .prop = .sm_type, .channels = .{ .ref = true } },
            .{ .prop = .rm_generating_unit, .channels = declared_only },
        },
        .check = &check_synchronous_condenser,
    },
    rated_apparent_power_rule(.{ .is_a_any = &.{"RotatingMachine"} }, .rotating_machine_rated_s),
    rated_apparent_power_rule(.{ .is_a_any = &.{"PowerTransformerEnd"} }, .power_transformer_end_rated_s),
    .{
        .rule = .MeasType,
        .filter = .{ .is_a_any = &.{"Measurement"} },
        .uses_version = true,
        .needs = &.{.{ .prop = .meas_type, .channels = .{ .text = true, .declared = true } }},
        .check = &check_measurement_type,
    },
    .{
        .rule = .MeasUnit,
        .filter = .{ .is_a_any = &.{"Measurement"} },
        .uses_version = true,
        .group_gate = &meas_unit_group_gate,
        .needs = &.{.{ .prop = .meas_unit, .channels = .{ .ref = true, .declared = true } }},
        .check = &check_measurement_unit,
    },
    .{
        .rule = .ShuntCompensatorSensitivity,
        .filter = .{ .is_a_any = &.{"ShuntCompensator"} },
        .needs = &.{.{
            .prop = .shunt_compensator_voltage_sensitivity,
            .channels = .{ .text = true, .declared = true },
        }},
        .check = &check_shunt_compensator_sensitivity,
    },
    .{
        .rule = .CATieFlow,
        .filter = .{ .is_a_any = &.{"ControlArea"} },
        .needs = &.{.{ .prop = .control_area_type, .channels = .{ .ref = true } }},
        .check = &harvest_interchange_control_area,
    },
    .{
        .rule = .OperationalLimitSetAtTerminal,
        .filter = .{ .is_a_any = &.{"OperationalLimitSet"} },
        .needs_resolution = true,
        .needs = &.{.{ .prop = .operational_limit_set_terminal, .channels = .{ .ref = true } }},
        .check = &check_operational_limit_set_terminal,
    },
    .{
        .rule = .ControlModeCompatibility,
        .filter = .{ .is_a_any = &.{"RegulatingControl"} },
        .needs_resolution = true,
        .needs = &.{
            .{ .prop = .regulating_control_mode, .channels = .{ .ref = true, .declared = true } },
            .{ .prop = .regulating_control_terminal, .channels = .{ .ref = true, .declared = true } },
        },
        .check = &harvest_regulating_control,
    },
    .{
        .rule = .ACLineSegmentR,
        .filter = .{ .is_a_any = &.{"ACLineSegment"} },
        .needs = &.{.{ .prop = .ac_line_segment_resistance, .channels = .{ .text = true, .declared = true } }},
        .check = &check_ac_line_segment_resistance,
    },
    .{
        .rule = .LinearShuntCompensatorG,
        .filter = .{ .is_a_any = &.{"LinearShuntCompensator"} },
        .needs = &.{.{ .prop = .linear_shunt_compensator_conductance, .channels = .{ .text = true, .declared = true } }},
        .check = &check_linear_shunt_compensator_conductance,
    },
    .{
        .rule = .ShuntCompensatorSections,
        .filter = .{ .is_a_any = &.{"ShuntCompensator"} },
        .needs = &.{
            .{ .prop = .shunt_compensator_normal_sections, .channels = .{ .text = true, .declared = true } },
            .{ .prop = .shunt_compensator_maximum_sections, .channels = .{ .text = true, .declared = true } },
        },
        .check = &check_shunt_compensator_sections,
    },
    .{
        .rule = .SVCSlope,
        .filter = .{ .exact = "StaticVarCompensator" },
        .needs = &.{.{ .prop = .svc_slope, .channels = .{ .text = true, .declared = true } }},
        .check = &check_svc_slope,
    },
    .{
        .rule = .RCCYValues,
        .filter = .{ .exact = "CurveData" },
        .needs_resolution = true,
        .needs = &.{
            .{ .prop = .curve_data_curve, .channels = .{ .ref = true } },
            .{ .prop = .curve_data_y1value, .channels = .{ .text = true, .declared = true } },
            .{ .prop = .curve_data_y2value, .channels = .{ .text = true, .declared = true } },
        },
        .check = &check_curve_data_y_values,
    },
    .{
        .rule = .RCCXValues2,
        .filter = .{ .is_a_any = &.{"SynchronousMachine"} },
        .needs_resolution = true,
        .needs = &.{
            .{ .prop = .sm_initial_reactive_capability_curve, .channels = .{ .ref = true } },
            .{ .prop = .sm_type, .channels = .{ .ref = true } },
        },
        .check = &harvest_synchronous_machine_curve,
    },
    .{
        .rule = .RCCXValues3,
        .filter = .{ .is_a_any = &.{"SynchronousMachine"} },
        .needs_resolution = true,
        .needs = &.{
            .{ .prop = .sm_initial_reactive_capability_curve, .channels = .{ .ref = true } },
            .{ .prop = .rm_generating_unit, .channels = .{ .ref = true } },
        },
        .check = &harvest_synchronous_machine_curve_unit,
    },
    .{
        .rule = .RCCXValues3,
        .filter = .{ .is_a_any = &.{"GeneratingUnit"} },
        .needs = &.{
            .{ .prop = .generating_unit_operating_power_min, .channels = .{ .text = true } },
            .{ .prop = .generating_unit_operating_power_max, .channels = .{ .text = true } },
        },
        .check = &harvest_generating_unit_bounds,
    },
    // Containment: the referenced container must exist and carry one of the
    // allowed traits. `required = false` tolerates an absent reference only;
    // a dangling or wrong-typed one always violates.
    containment_rule(.GenerationContainment, .{ .is_a_any = &.{ "HydroPump", "GeneratingUnit" } }, .always, .eq_container, .{ .substation = true }, true),
    containment_rule(.PTContainment, .{ .is_a_any = &.{"PowerTransformer"} }, .always, .eq_container, .{ .substation = true, .dc_converter_unit = true }, true),
    containment_rule(.SwitchContainment, .{ .is_a_any = &.{"Switch"} }, .always, .eq_container, .{ .voltage_level = true, .bay = true, .dc_converter_unit = true }, true),
    containment_rule(.SCContainment, .{ .is_a_any = &.{"SeriesCompensator"} }, .always, .eq_container, .{ .line = true, .voltage_level = true, .dc_converter_unit = true }, false),
    containment_rule(.InjectionContainment, .{ .is_a_any = &.{
        "EnergyConsumer",  "RotatingMachine",          "ShuntCompensator",     "EnergySource",
        "EquivalentShunt", "ExternalNetworkInjection", "StaticVarCompensator",
    } }, .always, .eq_container, .{ .voltage_level = true }, true),
    containment_rule(.BusbarSectionContainment, .{ .is_a_any = &.{"BusbarSection"} }, .always, .eq_container, .{ .voltage_level = true }, true),
    containment_rule(.EFCContainment, .{ .is_a_any = &.{ "EarthFaultCompensator", "Ground" } }, .always, .eq_container, .{ .voltage_level = true, .bay = true }, true),
    containment_rule(.ACDCConvContainment, .{ .is_a_any = &.{ "CsConverter", "VsConverter" } }, .always, .eq_container, .{ .dc_converter_unit = true }, true),
    containment_rule(.DCEQContainment, .{ .is_a_any = &.{
        "DCSeriesDevice", "DCShunt",  "DCBusbar",  "DCGround",
        "DCChopper",      "DCSwitch", "DCBreaker", "DCDisconnector",
    } }, .always, .eq_container, .{ .dc_converter_unit = true }, true),
    // ConnectivityNode containment is profile-dependent: EQ allows
    // VoltageLevel/Bay/Line, EQBD only Line. SSH/SV/TP carry no rule.
    containment_rule(.CNContainment, .{ .is_a_any = &.{"ConnectivityNode"} }, .eq, .cn_container, .{ .voltage_level = true, .bay = true, .line = true }, true),
    containment_rule(.CNContainment, .{ .is_a_any = &.{"ConnectivityNode"} }, .eqbd, .cn_container, .{ .line = true }, true),
    .{
        .rule = .CNRequiredInEQOperations,
        .filter = .{ .is_a_any = &.{"Terminal"} },
        .gate = .eq_operations,
        .needs = &.{.{ .prop = .term_conn_node, .channels = .{ .ref = true } }},
        .check = &check_conn_node_in_eq_operations,
    },
    // Relational rules whose Phase-A side resolves references and harvests
    // rows; the verdicts that need other objects' data land in Phase B.
    .{
        .rule = .CEBaseVoltage,
        .filter = .{ .is_a_any_except = .{
            .any = &.{"ConductingEquipment"},
            .except = &.{ "ACLineSegment", "SeriesCompensator", "EquivalentBranch", "PowerTransformer", "ACDCConverter" },
        } },
        .needs_resolution = true,
        .needs = &.{
            .{ .prop = .ce_base_voltage, .channels = .{ .ref = true } },
            .{ .prop = .eq_container, .channels = .{ .ref = true } },
        },
        .check = &harvest_ce_base_voltage,
    },
    .{
        .rule = .PTTerminalConsistency,
        .filter = .{ .exact = "PowerTransformerEnd" },
        .needs_resolution = true,
        .needs = &.{
            .{ .prop = .te_terminal, .channels = .{ .ref = true } },
            .{ .prop = .pte_power_transformer, .channels = .{ .ref = true } },
        },
        .check = &check_pt_end,
    },
    .{
        .rule = .MeasTerminal,
        .filter = .{ .is_a_any = &.{"Measurement"} },
        .needs_resolution = true,
        .needs = &.{
            .{ .prop = .meas_type, .channels = .{ .text = true } },
            .{ .prop = .meas_terminal, .channels = .{ .ref = true } },
            .{ .prop = .meas_psr, .channels = .{ .ref = true } },
        },
        .check = &check_measurement_terminal,
    },
};

/// Pure harvesters: no diagnostics of their own, enabled when any dependent
/// rule is requested. This is the dependency-closure half of the RuleMask
/// contract -- a TerminalSeqNum-only run still collects MutualCoupling rows,
/// but B1 will not emit MCFirstSecond for them.
pub const Harvester = struct {
    /// Enabled when any of these requested rules is enabled.
    rules: []const Rule,
    filter: TypeFilter,
    needs: []const Need,
    harvest: *const fn (ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void,
};

pub const harvesters = [_]Harvester{
    .{
        .rules = &.{
            .TerminalCount1,        .TerminalCount2, .TerminalSeqNum, .TerminalSeqNumOrder,
            .PTTerminalConsistency, .MCFirstSecond,  .MeasTerminal,   .ControlModeCompatibility,
            .PhaseCodeGround,
        },
        .filter = .{ .is_a_any = &.{"ACDCTerminal"} },
        .needs = &.{
            .{ .prop = .term_conducting_equipment, .channels = .{ .ref = true } },
            .{ .prop = .dcterm_dc_conducting_equipment, .channels = .{ .ref = true } },
            .{ .prop = .acdc_seq_num, .channels = .{ .text = true } },
            .{ .prop = .terminal_phase_code, .channels = .{ .ref = true } },
        },
        .harvest = &harvest_terminal,
    },
    .{
        .rules = &.{ .MCFirstSecond, .TerminalSeqNum },
        .filter = .{ .is_a_any = &.{"MutualCoupling"} },
        .needs = &.{
            .{ .prop = .mc_first, .channels = .{ .ref = true } },
            .{ .prop = .mc_second, .channels = .{ .ref = true } },
        },
        .harvest = &harvest_mutual_coupling,
    },
    .{
        .rules = &.{.CEBaseVoltage},
        .filter = .{ .exact = "VoltageLevel" },
        .needs = &.{.{ .prop = .vl_base_voltage, .channels = .{ .ref = true } }},
        .harvest = &harvest_voltage_level,
    },
    .{
        .rules = &.{.CEBaseVoltage},
        .filter = .{ .exact = "Bay" },
        .needs = &.{.{ .prop = .bay_voltage_level, .channels = .{ .ref = true } }},
        .harvest = &harvest_bay,
    },
    .{
        .rules = &.{.CATieFlow},
        .filter = .{ .is_a_any = &.{"TieFlow"} },
        .needs = &.{.{ .prop = .tie_flow_control_area, .channels = .{ .ref = true } }},
        .harvest = &harvest_tie_flow_control_area,
    },
    .{
        .rules = &.{.ControlModeCompatibility},
        .filter = .{ .is_a_any = &.{ "PhaseTapChanger", "RatioTapChanger" } },
        .needs = &.{.{ .prop = .tap_changer_control, .channels = .{ .ref = true } }},
        .harvest = &harvest_tap_changer_control_source,
    },
    .{
        .rules = &.{.TooManyTapChangers},
        .filter = .{ .is_a_any = &.{"PhaseTapChanger"} },
        .needs = &.{
            .{ .prop = .phase_tap_changer_transformer_end, .channels = .{ .ref = true } },
            .{ .prop = .tap_changer_control, .channels = .{ .ref = true } },
            .{ .prop = .tap_changer_control_enabled, .channels = .{ .text = true } },
        },
        .harvest = &harvest_phase_tap_changer,
    },
    .{
        .rules = &.{.TooManyTapChangers},
        .filter = .{ .is_a_any = &.{"RatioTapChanger"} },
        .needs = &.{
            .{ .prop = .ratio_tap_changer_transformer_end, .channels = .{ .ref = true } },
            .{ .prop = .tap_changer_control, .channels = .{ .ref = true } },
            .{ .prop = .tap_changer_control_enabled, .channels = .{ .text = true } },
        },
        .harvest = &harvest_ratio_tap_changer,
    },
    .{
        .rules = &.{.TooManyTapChangers},
        .filter = .{ .is_a_any = &.{"RegulatingControl"} },
        .needs = &.{.{ .prop = .regulating_control_enabled, .channels = .{ .text = true } }},
        .harvest = &harvest_regulating_control_enabled,
    },
    .{
        .rules = &.{.ControlModeCompatibility},
        .filter = .{ .is_a_any = &.{
            "SynchronousMachine", "ShuntCompensator", "StaticVarCompensator",
        } },
        .needs = &.{.{ .prop = .regulating_cond_eq_control, .channels = .{ .ref = true } }},
        .harvest = &harvest_regulating_equipment_control_source,
    },
    .{
        .rules = &.{ .RCCXValues2, .RCCXValues3 },
        .filter = .{ .exact = "CurveData" },
        .needs = &.{
            .{ .prop = .curve_data_curve, .channels = .{ .ref = true } },
            .{ .prop = .curve_data_xvalue, .channels = .{ .text = true } },
        },
        .harvest = &harvest_curve_data_x_value,
    },
};

/// Resolve a slot's reference channel to an object index; `none_index` for
/// absent, malformed, or dangling.
fn resolve_ref(ctx: *const Ctx, prop: Prop) u32 {
    const reference = switch (prop_ref(ctx.slots, prop)) {
        .value => |value| value,
        .absent, .malformed => return none_index,
    };
    return ctx.ref_index.?.object_index_by_reference(reference) orelse none_index;
}

fn harvest_terminal(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    const columns = ctx.columns.?;

    var via_terminal_ce = true;
    var equipment = resolve_ref(ctx, .term_conducting_equipment);
    if (equipment == none_index and prop_ref(ctx.slots, .term_conducting_equipment) == .absent) {
        equipment = resolve_ref(ctx, .dcterm_dc_conducting_equipment);
        via_terminal_ce = false;
    }
    if (equipment == none_index) return; // no resolvable equipment: no edge exists

    const terminal_index = ctx.object_index;
    columns.terminal_equipment[terminal_index] = equipment;

    const seq: u32 = blk: {
        const text = prop_text(ctx.slots, .acdc_seq_num) orelse break :blk seq_absent;
        const value = parse.int_req(u32, text) catch break :blk seq_invalid;
        break :blk if (value >= seq_invalid) seq_invalid else value;
    };

    const exact_terminal = std.mem.eql(u8, ctx.group_type_name, "Terminal");
    if (exact_terminal and via_terminal_ce) {
        columns.terminal_count[equipment] +|= 1;
        columns.terminal_exact_ce.set(terminal_index);
    }

    const phase = parse_phase_code(
        prop_ref(ctx.slots, .terminal_phase_code),
        prop_declared(ctx.slots, .terminal_phase_code),
    );

    try columns.terminals.append(ctx.gpa, .{
        .terminal_index = terminal_index,
        .equipment_index = equipment,
        .seq = seq,
        .phase = phase,
        .flags = .{ .exact_terminal = exact_terminal, .via_terminal_ce = via_terminal_ce },
    });
}

fn harvest_mutual_coupling(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    const columns = ctx.columns.?;
    const first = resolve_ref(ctx, .mc_first);
    const second = resolve_ref(ctx, .mc_second);
    try columns.mutual_couplings.append(ctx.gpa, .{
        .object_index = ctx.object_index,
        .first = first,
        .second = second,
        .incomplete = first == none_index or second == none_index,
    });
}

fn harvest_voltage_level(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    const base_voltage_id: ?[]const u8 = switch (prop_ref(ctx.slots, .vl_base_voltage)) {
        .value => |reference| cim.ids.strip_hash(reference),
        .absent, .malformed => null,
    };
    try ctx.columns.?.vl_rows.append(ctx.gpa, .{
        .object_index = ctx.object_index,
        .base_voltage_id = base_voltage_id,
    });
}

fn harvest_bay(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    try ctx.columns.?.bay_rows.append(ctx.gpa, .{
        .object_index = ctx.object_index,
        .voltage_level_index = resolve_ref(ctx, .bay_voltage_level),
    });
}

fn harvest_tie_flow_control_area(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    const control_area = resolve_ref(ctx, .tie_flow_control_area);
    if (control_area != none_index) ctx.columns.?.tie_flow_control_areas.set(control_area);
}

fn harvest_tap_changer_control_source(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    const control = resolve_ref(ctx, .tap_changer_control);
    if (control == none_index) return;

    const kinds = &ctx.columns.?.control_equipment_kinds[control];
    if (matches_is_a(ctx.group_tid, ctx.group_type_name, "PhaseTapChanger")) {
        kinds.phase_tap_changer = true;
    }
    if (matches_is_a(ctx.group_tid, ctx.group_type_name, "RatioTapChanger")) {
        kinds.ratio_tap_changer = true;
    }
}

fn harvest_phase_tap_changer(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    return harvest_tap_changer(ctx, .phase, .phase_tap_changer_transformer_end);
}

fn harvest_ratio_tap_changer(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    return harvest_tap_changer(ctx, .ratio, .ratio_tap_changer_transformer_end);
}

fn harvest_tap_changer(
    ctx: *Ctx,
    kind: TapChangerKind,
    end_prop: Prop,
) error{OutOfMemory}!void {
    const end = resolve_ref(ctx, end_prop);
    if (end == none_index) return;
    if (!ctx.traits.?[end].power_transformer_end) return;

    try ctx.columns.?.tap_changers.append(ctx.gpa, .{
        .end_index = end,
        .control_index = resolve_ref(ctx, .tap_changer_control),
        .kind = kind,
        .control_enabled = parse.flag(prop_text(ctx.slots, .tap_changer_control_enabled)),
    });
}

fn harvest_regulating_control_enabled(
    ctx: *Ctx,
    obj: cim.CimObject,
) error{OutOfMemory}!void {
    _ = obj;
    if (parse.flag(prop_text(ctx.slots, .regulating_control_enabled))) {
        ctx.columns.?.regulating_controls_enabled.set(ctx.object_index);
    }
}

fn harvest_regulating_equipment_control_source(
    ctx: *Ctx,
    obj: cim.CimObject,
) error{OutOfMemory}!void {
    _ = obj;
    const control = resolve_ref(ctx, .regulating_cond_eq_control);
    if (control == none_index) return;

    const kinds = &ctx.columns.?.control_equipment_kinds[control];
    if (matches_is_a(ctx.group_tid, ctx.group_type_name, "SynchronousMachine")) {
        kinds.synchronous_machine = true;
    }
    if (matches_is_a(ctx.group_tid, ctx.group_type_name, "ShuntCompensator")) {
        kinds.shunt_compensator = true;
    }
    if (matches_is_a(ctx.group_tid, ctx.group_type_name, "StaticVarCompensator")) {
        kinds.static_var_compensator = true;
    }
}

fn harvest_ce_base_voltage(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    // A malformed BaseVoltage reference reads as absent, matching the
    // pre-redesign `reference(...) catch null`.
    const base_voltage_id: ?[]const u8 = switch (prop_ref(ctx.slots, .ce_base_voltage)) {
        .value => |reference| cim.ids.strip_hash(reference),
        .absent, .malformed => null,
    };
    try ctx.columns.?.ce_bv.append(ctx.gpa, .{
        .object_index = ctx.object_index,
        .base_voltage_id = base_voltage_id,
        .container_index = resolve_ref(ctx, .eq_container),
    });
}

fn check_pt_end(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    // Missing, malformed, or dangling references are the violation here;
    // only fully resolved rows reach Phase B's consistency verdict.
    const terminal = resolve_ref(ctx, .te_terminal);
    if (terminal == none_index) return ctx.emit(.PTTerminalConsistency, obj, "");
    const transformer = resolve_ref(ctx, .pte_power_transformer);
    if (transformer == none_index) return ctx.emit(.PTTerminalConsistency, obj, "");
    try ctx.columns.?.pt_ends.append(ctx.gpa, .{
        .object_index = ctx.object_index,
        .terminal_index = terminal,
        .transformer_index = transformer,
    });
}

fn check_measurement_terminal(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    // TapPosition and SwitchPosition measurements do not exchange the
    // Terminal association: skipped before harvesting.
    if (parse.non_blank(prop_text(ctx.slots, .meas_type))) |measurement_type| {
        if (std.mem.eql(u8, measurement_type, "TapPosition") or
            std.mem.eql(u8, measurement_type, "SwitchPosition")) return;
    }
    const terminal = resolve_ref(ctx, .meas_terminal);
    if (terminal == none_index) return ctx.emit(.MeasTerminal, obj, "");
    const psr = resolve_ref(ctx, .meas_psr);
    if (psr == none_index) return ctx.emit(.MeasTerminal, obj, "");
    try ctx.columns.?.measurements.append(ctx.gpa, .{
        .object_index = ctx.object_index,
        .terminal_index = terminal,
        .psr_index = psr,
    });
}

comptime {
    assert(object_rules.len <= 64); // the engine's active set is a u64
    assert(harvesters.len <= 16); // the engine's active harvester set is a u16
}

/// A containment table entry: the object's `prop` reference must resolve to
/// an object whose traits intersect `allowed`. Mirrors the pre-redesign
/// `validate_containment` (ParseFailed/Missing/WrongContainer all collapse to
/// the rule): a malformed reference violates; an absent one violates iff
/// `required`; a dangling target or a container outside `allowed` always
/// violates.
fn containment_rule(
    comptime rule: Rule,
    comptime filter: TypeFilter,
    comptime gate: Gate,
    comptime prop: Prop,
    comptime allowed: TargetTraits,
    comptime required: bool,
) ObjectRule {
    return .{
        .rule = rule,
        .filter = filter,
        .gate = gate,
        .needs_resolution = true,
        .needs = &.{.{ .prop = prop, .channels = .{ .ref = true } }},
        .check = &struct {
            fn check(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
                switch (prop_ref(ctx.slots, prop)) {
                    .malformed => try ctx.emit(rule, obj, ""),
                    .absent => if (required) try ctx.emit(rule, obj, ""),
                    .value => |reference| {
                        const index = ctx.ref_index.?.object_index_by_reference(reference) orelse
                            return ctx.emit(rule, obj, reference);
                        if (!ctx.traits.?[index].intersects(allowed)) {
                            try ctx.emit(rule, obj, reference);
                        }
                    },
                }
            }
        }.check,
    };
}

fn check_conn_node_in_eq_operations(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    // A ConnectivityNode serialized as element text reads as absent here, and
    // is a violation: the association is required to be readable, not merely
    // to be mentioned.
    switch (prop_ref(ctx.slots, .term_conn_node)) {
        .malformed, .absent => try ctx.emit(.CNRequiredInEQOperations, obj, ""),
        .value => |reference| {
            if (parse.non_blank(reference) == null) {
                try ctx.emit(.CNRequiredInEQOperations, obj, "");
            }
        },
    }
}

const lrc_coefficient_needs = [_]Need{
    .{ .prop = .lrc_exponent_model, .channels = text_only },
    .{ .prop = .lrc_p_z, .channels = text_only },
    .{ .prop = .lrc_p_i, .channels = text_only },
    .{ .prop = .lrc_p_p, .channels = text_only },
    .{ .prop = .lrc_q_z, .channels = text_only },
    .{ .prop = .lrc_q_i, .channels = text_only },
    .{ .prop = .lrc_q_p, .channels = text_only },
};

/// Whether the group's type matches `target`, subtypes included. Resolves
/// `target` to a TypeId at comptime so the runtime test is one bit test;
/// classes outside the CIM hierarchy degrade to string equality on both
/// sides, matching `cim_types.is_a`.
fn matches_is_a(tid: ?cim_types.TypeId, type_name: []const u8, comptime target: []const u8) bool {
    if (comptime cim_types.type_id(target)) |target_id| {
        if (tid) |actual| return cim_types.is_a_id(actual, target_id);
    }
    return std.mem.eql(u8, type_name, target);
}

/// Evaluate a comptime filter against a runtime type group.
pub fn filter_matches(comptime filter: TypeFilter, tid: ?cim_types.TypeId, type_name: []const u8) bool {
    switch (filter) {
        .all => return true,
        .all_except => |except| {
            inline for (except.is_a_not) |target| {
                if (matches_is_a(tid, type_name, target)) return false;
            }
            inline for (except.names_not) |name| {
                if (std.mem.eql(u8, type_name, name)) return false;
            }
            return true;
        },
        .exact => |name| return std.mem.eql(u8, type_name, name),
        .is_a_any => |targets| {
            inline for (targets) |target| {
                if (matches_is_a(tid, type_name, target)) return true;
            }
            return false;
        },
        .is_a_any_except => |spec| {
            inline for (spec.except) |target| {
                if (matches_is_a(tid, type_name, target)) return false;
            }
            inline for (spec.any) |target| {
                if (matches_is_a(tid, type_name, target)) return true;
            }
            return false;
        },
        .strict_subclass => |target| {
            return matches_is_a(tid, type_name, target) and !std.mem.eql(u8, type_name, target);
        },
    }
}

// ── per-object predicates ─────────────────────────────────────────────────
//
// One violation per object per rule: a predicate emits at most once and
// returns. Detail is the offending value when there is one, "" for
// missing-required findings.

fn check_name_length(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const name = prop_text(ctx.slots, .io_name) orelse
        return ctx.emit(.NameLength, obj, "");
    if (name.len == 0 or name.len > data.name_chars_max) {
        try ctx.emit(.NameLength, obj, name);
    }
}

fn check_short_name_length(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const short_name = prop_text(ctx.slots, .io_short_name) orelse return;
    if (short_name.len > data.short_name_chars_max) {
        try ctx.emit(.ShortNameLength, obj, short_name);
    }
}

fn check_eic_length(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const code = prop_text(ctx.slots, .io_eic) orelse return;
    if (code.len != data.eic_chars_max) {
        try ctx.emit(.EICLength, obj, code);
    }
}

fn check_description_length(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const description = prop_text(ctx.slots, .io_description) orelse return;
    if (description.len > data.description_chars_max) {
        try ctx.emit(.DescriptionLength, obj, description);
    }
}

/// Shared body of the boundary-point ISO-code rules: the property is
/// required and must be a known country code.
fn check_bp_iso(ctx: *Ctx, obj: cim.CimObject, rule: Rule, prop: Prop) error{OutOfMemory}!void {
    const code = prop_text(ctx.slots, prop) orelse return ctx.emit(rule, obj, "");
    if (data.iso_country_codes.get(code) == null) try ctx.emit(rule, obj, code);
}

/// Shared body of the boundary-point name rules: the property is required
/// and limited to IO_NAME_LENGTH characters.
fn check_bp_name(ctx: *Ctx, obj: cim.CimObject, rule: Rule, prop: Prop) error{OutOfMemory}!void {
    const value = prop_text(ctx.slots, prop) orelse return ctx.emit(rule, obj, "");
    if (value.len > data.name_chars_max) try ctx.emit(rule, obj, value);
}

fn check_bp_from_iso(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    return check_bp_iso(ctx, obj, .CNFromEndIsoCode, .bp_from_iso);
}
fn check_bp_to_iso(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    return check_bp_iso(ctx, obj, .CNToEndIsoCode, .bp_to_iso);
}
fn check_bp_from_name(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    return check_bp_name(ctx, obj, .CNFromEndNameLength, .bp_from_name);
}
fn check_bp_to_name(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    return check_bp_name(ctx, obj, .CNToEndNameLength, .bp_to_name);
}
fn check_bp_from_name_tso(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    return check_bp_name(ctx, obj, .CNFromEndNameTsoLength, .bp_from_name_tso);
}
fn check_bp_to_name_tso(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    return check_bp_name(ctx, obj, .CNToEndNameTsoLength, .bp_to_name_tso);
}

fn check_nominal_voltage(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const text = prop_text(ctx.slots, .bv_nominal_voltage) orelse
        return ctx.emit(.NominalVoltage, obj, "");
    const nominal_voltage = std.fmt.parseFloat(f64, text) catch
        return ctx.emit(.NominalVoltage, obj, text);
    if (nominal_voltage <= 0) try ctx.emit(.NominalVoltage, obj, text);
}

fn check_lrc_exponent_model(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    if (!parse.flag(prop_text(ctx.slots, .lrc_exponent_model))) return;

    const exponents = [_]Prop{ .lrc_p_voltage_exp, .lrc_q_voltage_exp };
    for (exponents) |prop| {
        const text = prop_text(ctx.slots, prop) orelse
            return ctx.emit(.LRCExponentModel, obj, "");
        const exponent = parse.float_req(text) catch
            return ctx.emit(.LRCExponentModel, obj, text);
        if (exponent < 0 or exponent > 2) return ctx.emit(.LRCExponentModel, obj, text);
    }
}

const lrc_coefficient_props = [_]Prop{
    .lrc_p_z, .lrc_p_i, .lrc_p_p,
    .lrc_q_z, .lrc_q_i, .lrc_q_p,
};

/// Whether the object uses the ZIP coefficient model (exponentModel is the
/// literal "false"); the coefficient rules only apply then.
fn lrc_uses_coefficient_model(slots: *const Slots) bool {
    const exponent_model = parse.non_blank(prop_text(slots, .lrc_exponent_model)) orelse
        return false;
    return std.mem.eql(u8, exponent_model, "false");
}

fn check_lrc_coefficient_model(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    if (!lrc_uses_coefficient_model(ctx.slots)) return;
    for (lrc_coefficient_props) |prop| {
        if (parse.non_blank(prop_text(ctx.slots, prop)) == null) {
            return ctx.emit(.LCRCoefficientModel, obj, "");
        }
    }
}

fn check_lrc_coefficient_parameters(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    if (!lrc_uses_coefficient_model(ctx.slots)) return;

    var coefficients: [6]f64 = undefined;
    for (lrc_coefficient_props, &coefficients) |prop, *coefficient| {
        const text = prop_text(ctx.slots, prop) orelse
            return ctx.emit(.LCRCoefficientParameters, obj, "");
        coefficient.* = parse.float_req(text) catch
            return ctx.emit(.LCRCoefficientParameters, obj, text);
    }
    const p_sum = coefficients[0] + coefficients[1] + coefficients[2];
    const q_sum = coefficients[3] + coefficients[4] + coefficients[5];
    if (!coefficient_sum_equals_one(p_sum) or !coefficient_sum_equals_one(q_sum)) {
        try ctx.emit(.LCRCoefficientParameters, obj, "");
    }
}

fn coefficient_sum_equals_one(sum: f64) bool {
    const difference = @abs(sum - 1.0);
    return difference < @abs(sum) * data.numeric_tolerance_factor or
        difference < data.numeric_tolerance_factor;
}

fn check_energy_source_voltage(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    if (prop_declared(ctx.slots, .es_voltage_magnitude) or
        prop_declared(ctx.slots, .es_voltage_angle))
    {
        try ctx.emit(.EnergySourceVoltage, obj, "");
    }
}

fn check_svc_ratings(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const capacitive_text = prop_text(ctx.slots, .svc_capacitive) orelse
        return ctx.emit(.SVCRatings, obj, "");
    const capacitive = parse.float_req(capacitive_text) catch
        return ctx.emit(.SVCRatings, obj, capacitive_text);
    if (capacitive <= 0) return ctx.emit(.SVCRatings, obj, capacitive_text);

    const inductive_text = prop_text(ctx.slots, .svc_inductive) orelse
        return ctx.emit(.SVCRatings, obj, "");
    const inductive = parse.float_req(inductive_text) catch
        return ctx.emit(.SVCRatings, obj, inductive_text);
    if (inductive >= 0) return ctx.emit(.SVCRatings, obj, inductive_text);
}

fn check_generating_unit_nominal_p(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const nominal_text = prop_text(ctx.slots, .gu_nominal_p) orelse return;
    const nominal_power = std.fmt.parseFloat(f64, nominal_text) catch
        return ctx.emit(.GeneratingUnitNominalP, obj, nominal_text);
    if (!std.math.isFinite(nominal_power) or nominal_power <= 0) {
        return ctx.emit(.GeneratingUnitNominalP, obj, nominal_text);
    }

    const rated_text = prop_text(ctx.slots, .gu_rated_s) orelse return;
    const rated_power = std.fmt.parseFloat(f64, rated_text) catch
        return ctx.emit(.GeneratingUnitNominalP, obj, rated_text);
    if (!std.math.isFinite(rated_power) or nominal_power > rated_power) {
        return ctx.emit(.GeneratingUnitNominalP, obj, nominal_text);
    }
}

/// SMQLimits2: a SynchronousMachine needs both scalar reactive-power limits,
/// or a forward association that resolves to a ReactiveCapabilityCurve.
fn check_synchronous_machine_limits(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const has_limits = parse.non_blank(prop_text(ctx.slots, .sm_min_q)) != null and
        parse.non_blank(prop_text(ctx.slots, .sm_max_q)) != null;
    if (has_limits) return;

    const reference = switch (prop_ref(ctx.slots, .sm_initial_reactive_capability_curve)) {
        .value => |value| value,
        .absent, .malformed => return ctx.emit(.SMQLimits2, obj, ""),
    };
    const curve = ctx.ref_index.?.object_index_by_reference(reference) orelse
        return ctx.emit(.SMQLimits2, obj, reference);
    if (!ctx.traits.?[curve].reactive_capability_curve) {
        try ctx.emit(.SMQLimits2, obj, reference);
    }
}

fn check_synchronous_condenser(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const type_reference = switch (prop_ref(ctx.slots, .sm_type)) {
        .value => |value| value,
        .absent, .malformed => return,
    };
    const machine_type = cim.uri.fragment_or_self(type_reference);
    if (!std.mem.eql(u8, machine_type, "SynchronousMachineKind.condenser")) return;
    if (prop_declared(ctx.slots, .rm_generating_unit)) {
        try ctx.emit(.SynchronousCondenser, obj, "");
    }
}

fn rated_apparent_power_rule(comptime filter: TypeFilter, comptime prop: Prop) ObjectRule {
    return .{
        .rule = .RatedS,
        .filter = filter,
        .needs = &.{.{ .prop = prop, .channels = text_only }},
        .check = &struct {
            fn check(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
                const text = prop_text(ctx.slots, prop) orelse
                    return ctx.emit(.RatedS, obj, "");
                const apparent_power_rating = parse.float_req(text) catch
                    return ctx.emit(.RatedS, obj, text);
                if (apparent_power_rating <= 0) try ctx.emit(.RatedS, obj, text);
            }
        }.check,
    };
}

fn check_shunt_compensator_sensitivity(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    if (!prop_declared(ctx.slots, .shunt_compensator_voltage_sensitivity)) return;
    const text = prop_text(ctx.slots, .shunt_compensator_voltage_sensitivity) orelse
        return ctx.emit(.ShuntCompensatorSensitivity, obj, "");
    const voltage_sensitivity = parse.float_req(text) catch
        return ctx.emit(.ShuntCompensatorSensitivity, obj, text);
    if (voltage_sensitivity <= 0) try ctx.emit(.ShuntCompensatorSensitivity, obj, text);
}

fn harvest_interchange_control_area(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    const reference = switch (prop_ref(ctx.slots, .control_area_type)) {
        .value => |value| value,
        .absent, .malformed => return,
    };
    const control_area_type = cim.uri.fragment_or_self(reference);
    if (!std.mem.eql(u8, control_area_type, "ControlAreaTypeKind.Interchange")) return;
    try ctx.columns.?.interchange_control_areas.append(ctx.gpa, ctx.object_index);
}

fn check_operational_limit_set_terminal(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const terminal = resolve_ref(ctx, .operational_limit_set_terminal);
    if (terminal == none_index) {
        return ctx.emit(.OperationalLimitSetAtTerminal, obj, "");
    }
    if (!ctx.traits.?[terminal].terminal) {
        try ctx.emit(.OperationalLimitSetAtTerminal, obj, "");
    }
}

fn check_ac_line_segment_resistance(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    if (!prop_declared(ctx.slots, .ac_line_segment_resistance)) return;
    const text = prop_text(ctx.slots, .ac_line_segment_resistance) orelse
        return ctx.emit(.ACLineSegmentR, obj, "");
    const resistance = parse.float_req(text) catch
        return ctx.emit(.ACLineSegmentR, obj, text);
    if (resistance < 0) try ctx.emit(.ACLineSegmentR, obj, text);
}

fn check_linear_shunt_compensator_conductance(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    if (!prop_declared(ctx.slots, .linear_shunt_compensator_conductance)) return;
    const text = prop_text(ctx.slots, .linear_shunt_compensator_conductance) orelse
        return ctx.emit(.LinearShuntCompensatorG, obj, "");
    const conductance = parse.float_req(text) catch
        return ctx.emit(.LinearShuntCompensatorG, obj, text);
    if (conductance < 0) try ctx.emit(.LinearShuntCompensatorG, obj, text);
}

fn check_shunt_compensator_sections(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    if (!prop_declared(ctx.slots, .shunt_compensator_normal_sections)) return;
    const text_normal = prop_text(ctx.slots, .shunt_compensator_normal_sections) orelse
        return ctx.emit(.ShuntCompensatorSections, obj, "");
    const sections_normal = parse.int_req(u32, text_normal) catch
        return ctx.emit(.ShuntCompensatorSections, obj, text_normal);

    if (!prop_declared(ctx.slots, .shunt_compensator_maximum_sections)) return;
    const text_max = prop_text(ctx.slots, .shunt_compensator_maximum_sections) orelse
        return ctx.emit(.ShuntCompensatorSections, obj, "");
    const sections_max = parse.int_req(u32, text_max) catch
        return ctx.emit(.ShuntCompensatorSections, obj, text_max);
    if (sections_normal > sections_max) {
        try ctx.emit(.ShuntCompensatorSections, obj, text_normal);
    }
}

fn check_svc_slope(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    if (!prop_declared(ctx.slots, .svc_slope)) return;
    const text = prop_text(ctx.slots, .svc_slope) orelse
        return ctx.emit(.SVCSlope, obj, "");
    const slope = parse.float_req(text) catch
        return ctx.emit(.SVCSlope, obj, text);
    if (slope < 0) try ctx.emit(.SVCSlope, obj, text);
}

fn check_curve_data_y_values(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const curve = resolve_ref(ctx, .curve_data_curve);
    if (curve == none_index) return;
    if (!ctx.traits.?[curve].reactive_capability_curve) return;

    const columns = ctx.columns.?;
    if (!prop_declared(ctx.slots, .curve_data_y1value)) {
        columns.curve_all_equal_disqualified.set(curve);
        return;
    }
    const text_y1 = prop_text(ctx.slots, .curve_data_y1value) orelse {
        columns.curve_all_equal_disqualified.set(curve);
        return ctx.emit(.RCCYValues, obj, "");
    };
    const y1 = parse.float_req(text_y1) catch {
        columns.curve_all_equal_disqualified.set(curve);
        return ctx.emit(.RCCYValues, obj, text_y1);
    };
    if (!prop_declared(ctx.slots, .curve_data_y2value)) {
        columns.curve_all_equal_disqualified.set(curve);
        return;
    }
    const text_y2 = prop_text(ctx.slots, .curve_data_y2value) orelse {
        columns.curve_all_equal_disqualified.set(curve);
        return ctx.emit(.RCCYValues, obj, "");
    };
    const y2 = parse.float_req(text_y2) catch {
        columns.curve_all_equal_disqualified.set(curve);
        return ctx.emit(.RCCYValues, obj, text_y2);
    };

    if (y2 < y1) {
        columns.curve_all_equal_disqualified.set(curve);
        try ctx.emit(.RCCYValues, obj, text_y2);
    } else if (y2 > y1) {
        columns.curve_all_equal_disqualified.set(curve);
    } else {
        try columns.curve_equal_points.append(ctx.gpa, .{
            .object_index = ctx.object_index,
            .curve_index = curve,
        });
    }
}

fn harvest_curve_data_x_value(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    const curve = resolve_ref(ctx, .curve_data_curve);
    if (curve == none_index) return;
    if (!ctx.traits.?[curve].reactive_capability_curve) return;

    const x: CurveXValue = blk: {
        const text = prop_text(ctx.slots, .curve_data_xvalue) orelse
            break :blk .unusable;
        const value = parse.float_req(text) catch
            break :blk .unusable;
        break :blk .{ .value = value };
    };
    try ctx.columns.?.curve_x_points.append(ctx.gpa, .{
        .curve_index = curve,
        .x = x,
    });
}

fn harvest_synchronous_machine_curve(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    const curve = resolve_ref(ctx, .sm_initial_reactive_capability_curve);
    if (curve == none_index) return;
    if (!ctx.traits.?[curve].reactive_capability_curve) return;

    const requirement = rcc_x_requirement(prop_ref(ctx.slots, .sm_type));
    try ctx.columns.?.machine_curves.append(ctx.gpa, .{
        .object_index = ctx.object_index,
        .curve_index = curve,
        .requirement = requirement,
    });
}

fn harvest_synchronous_machine_curve_unit(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    const curve = resolve_ref(ctx, .sm_initial_reactive_capability_curve);
    if (curve == none_index) return;
    if (!ctx.traits.?[curve].reactive_capability_curve) return;

    const generating_unit = resolve_ref(ctx, .rm_generating_unit);
    if (generating_unit == none_index) return;
    try ctx.columns.?.machine_curve_units.append(ctx.gpa, .{
        .object_index = ctx.object_index,
        .curve_index = curve,
        .generating_unit_index = generating_unit,
    });
}

fn harvest_generating_unit_bounds(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    const bounds: OperatingPowerBounds = bounds: {
        const min_text = prop_text(ctx.slots, .generating_unit_operating_power_min) orelse
            break :bounds .unusable;
        const min = parse.float_req(min_text) catch break :bounds .unusable;
        const max_text = prop_text(ctx.slots, .generating_unit_operating_power_max) orelse
            break :bounds .unusable;
        const max = parse.float_req(max_text) catch break :bounds .unusable;
        break :bounds .{ .value = .{ .min = min, .max = max } };
    };
    try ctx.columns.?.generating_unit_bounds.append(ctx.gpa, .{
        .object_index = ctx.object_index,
        .bounds = bounds,
    });
}

fn rcc_x_requirement(type_reference: RefState) RccXRequirement {
    const reference = switch (type_reference) {
        .value => |value| value,
        .absent, .malformed => return .invalid,
    };
    const machine_type = cim.uri.fragment_or_self(reference);
    if (std.mem.eql(u8, machine_type, "SynchronousMachineKind.condenser")) return .condenser;
    if (std.mem.eql(u8, machine_type, "SynchronousMachineKind.generator") or
        std.mem.eql(u8, machine_type, "SynchronousMachineKind.generatorOrCondenser"))
    {
        return .generator;
    }
    if (std.mem.eql(u8, machine_type, "SynchronousMachineKind.motor") or
        std.mem.eql(u8, machine_type, "SynchronousMachineKind.motorOrCondenser"))
    {
        return .motor;
    }
    if (std.mem.eql(u8, machine_type, "SynchronousMachineKind.generatorOrMotor") or
        std.mem.eql(u8, machine_type, "SynchronousMachineKind.generatorOrCondenserOrMotor"))
    {
        return .generator_or_motor;
    }
    return .invalid;
}

fn harvest_regulating_control(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    _ = obj;
    const mode: ?ControlMode = switch (prop_ref(ctx.slots, .regulating_control_mode)) {
        .malformed => .invalid,
        .absent => if (prop_declared(ctx.slots, .regulating_control_mode)) .invalid else null,
        .value => |reference| blk: {
            const value = cim.uri.fragment_or_self(reference);
            if (std.mem.eql(u8, value, "RegulatingControlModeKind.activePower")) {
                break :blk .active_power;
            }
            if (std.mem.eql(u8, value, "RegulatingControlModeKind.voltage")) break :blk .voltage;
            if (std.mem.eql(u8, value, "RegulatingControlModeKind.reactivePower")) {
                break :blk .reactive_power;
            }
            if (std.mem.eql(u8, value, "RegulatingControlModeKind.powerFactor")) {
                break :blk .power_factor;
            }
            break :blk .invalid;
        },
    };
    try ctx.columns.?.controls.append(ctx.gpa, .{
        .object_index = ctx.object_index,
        .terminal_index = resolve_ref(ctx, .regulating_control_terminal),
        .mode = mode,
        .terminal_declared = prop_declared(ctx.slots, .regulating_control_terminal),
    });
}

/// Whether a measurement type is allowed under the version the header
/// declared. A null version means the header was unresolved or its profile
/// URIs disagreed, so neither list can be the authority and a value valid
/// under either one is accepted.
pub fn measurement_type_allowed(measurement_type: []const u8, version: ?cim.profile.Version) bool {
    const version_known = version orelse
        return data.allowed_measurement_types_v2_4_15.get(measurement_type) != null or
            data.allowed_measurement_types_v3_0.get(measurement_type) != null;
    return switch (version_known) {
        .v2_4_15 => data.allowed_measurement_types_v2_4_15.get(measurement_type) != null,
        .v3_0 => data.allowed_measurement_types_v3_0.get(measurement_type) != null,
    };
}

/// The class-specific IEC 61970-452 unit set for a CGMES v3.0 measurement.
/// The referenced constraints do not define a unit list for Measurement or
/// StringMeasurement themselves.
pub fn measurement_unit_set_v3_0(type_name: []const u8) ?*const data.ExactStringSet {
    if (cim_types.is_a(type_name, "Analog")) return &data.allowed_analog_measurement_units_v3_0;
    if (cim_types.is_a(type_name, "Accumulator")) return &data.allowed_accumulator_measurement_units_v3_0;
    if (cim_types.is_a(type_name, "Discrete")) return &data.allowed_discrete_measurement_units_v3_0;
    return null;
}

/// Whether a unit is allowed under the version the header declared. A null
/// version accepts a unit allowed by either applicable version, matching the
/// treatment of version-specific measurement types above.
pub fn measurement_unit_allowed(
    unit: []const u8,
    version: ?cim.profile.Version,
    v3_units: ?*const data.ExactStringSet,
) bool {
    const allowed_in_v2_4_15 = data.allowed_measurement_units_v2_4_15.get(unit) != null;
    const allowed_in_v3_0 = if (v3_units) |units| units.get(unit) != null else false;
    if (version) |known| return switch (known) {
        .v2_4_15 => allowed_in_v2_4_15,
        .v3_0 => allowed_in_v3_0,
    };

    return allowed_in_v2_4_15 or allowed_in_v3_0;
}

fn check_measurement_type(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const raw = prop_text(ctx.slots, .meas_type) orelse {
        // A `<...measurementType/>` is an empty literal rather than an absent
        // property; reading it as absent would accept in one serialization
        // what the paired form fails on.
        if (prop_declared(ctx.slots, .meas_type)) try ctx.emit(.MeasType, obj, "");
        return;
    };
    const measurement_type = parse.non_blank(raw) orelse
        return ctx.emit(.MeasType, obj, raw);
    if (!measurement_type_allowed(measurement_type, ctx.version)) {
        try ctx.emit(.MeasType, obj, measurement_type);
    }
}

/// A v3.0 (or possibly-v3.0) model is constrained by MeasUnit only for the
/// concrete classes to which IEC 61970-452 attaches a unit list.
fn meas_unit_group_gate(ctx: *Ctx) bool {
    ctx.group_v3_units = measurement_unit_set_v3_0(ctx.group_type_name);
    return !(ctx.version != .v2_4_15 and ctx.group_v3_units == null);
}

fn check_measurement_unit(ctx: *Ctx, obj: cim.CimObject) error{OutOfMemory}!void {
    const reference = switch (prop_ref(ctx.slots, .meas_unit)) {
        .malformed => return ctx.emit(.MeasUnit, obj, ""),
        .absent => {
            // A unitSymbol serialized as element text is a declared
            // association this rule cannot read.
            if (prop_declared(ctx.slots, .meas_unit)) try ctx.emit(.MeasUnit, obj, "");
            return;
        },
        .value => |value| value,
    };
    const unit = cim.uri.fragment_or_self(reference);
    if (unit.len == 0) return ctx.emit(.MeasUnit, obj, reference);
    if (!measurement_unit_allowed(unit, ctx.version, ctx.group_v3_units)) {
        try ctx.emit(.MeasUnit, obj, unit);
    }
}
