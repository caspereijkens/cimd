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
        .mc_first => "MutualCoupling.First_Terminal",
        .mc_second => "MutualCoupling.Second_Terminal",
        .ce_base_voltage => "ConductingEquipment.BaseVoltage",
        .meas_terminal => "Measurement.Terminal",
        .meas_psr => "Measurement.PowerSystemResource",
        .vl_base_voltage => "VoltageLevel.BaseVoltage",
        .bay_voltage_level => "Bay.VoltageLevel",
    };
}

// ── the traits column ─────────────────────────────────────────────────────

/// Per-object class memberships, computed once per type name and `@memset`
/// over the type's contiguous index range. Containment rules test their
/// container's traits with one AND instead of resolving `is_a` per object;
/// the relational passes test their row targets the same way.
pub const TargetTraits = packed struct(u16) {
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
    _pad: u2 = 0,

    pub fn intersects(self: TargetTraits, allowed: TargetTraits) bool {
        return @as(u16, @bitCast(self)) & @as(u16, @bitCast(allowed)) != 0;
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
        "EnergySource",     "Ground",         "DCBusbar",           "DCShunt",
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

pub const TerminalRow = struct {
    terminal_index: u32,
    /// Resolved equipment target; rows are only appended when it resolves.
    equipment_index: u32,
    seq: u32,
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

pub const MeasurementRow = struct {
    object_index: u32,
    terminal_index: u32,
    psr_index: u32,
};

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
    measurements: std.ArrayList(MeasurementRow),
    ce_bv: std.ArrayList(CeBvRow),
    vl_rows: std.ArrayList(VlRow),
    bay_rows: std.ArrayList(BayRow),

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
        return .{
            .terminal_equipment = terminal_equipment,
            .terminal_count = terminal_count,
            .terminal_exact_ce = terminal_exact_ce,
            .coupled = coupled,
            .terminals = .empty,
            .mutual_couplings = .empty,
            .pt_ends = .empty,
            .measurements = .empty,
            .ce_bv = .empty,
            .vl_rows = .empty,
            .bay_rows = .empty,
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
        self.measurements.deinit(gpa);
        self.ce_bv.deinit(gpa);
        self.vl_rows.deinit(gpa);
        self.bay_rows.deinit(gpa);
    }
};

/// The rules whose verdicts need harvested columns (and so the traits column
/// and reference resolution too).
pub const relational_rules = [_]Rule{
    .TerminalCount1,       .TerminalCount2, .TerminalSeqNum, .TerminalSeqNumOrder,
    .PTTerminalConsistency, .MCFirstSecond,  .MeasTerminal,   .CEBaseVoltage,
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
        "DCSeriesDevice", "DCShunt",   "DCBusbar",       "DCGround",
        "DCChopper",      "DCSwitch",  "DCBreaker",      "DCDisconnector",
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
            .PTTerminalConsistency, .MCFirstSecond,  .MeasTerminal,
        },
        .filter = .{ .is_a_any = &.{"ACDCTerminal"} },
        .needs = &.{
            .{ .prop = .term_conducting_equipment, .channels = .{ .ref = true } },
            .{ .prop = .dcterm_dc_conducting_equipment, .channels = .{ .ref = true } },
            .{ .prop = .acdc_seq_num, .channels = .{ .text = true } },
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
    try columns.terminals.append(ctx.gpa, .{
        .terminal_index = terminal_index,
        .equipment_index = equipment,
        .seq = seq,
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
