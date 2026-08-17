//! QoCDC reference data: the allowed-value sets and rule constants of
//! QoCDC v4.1.4 §5.3 and the QoCDC Reference Data v1.0 document.
//!
//! Two set flavours, deliberately distinct: `ReferenceStringSet` compares
//! case-insensitively per QoCDC ("comparison of the string shall not be case
//! sensitive"); `ExactStringSet` compares exactly (measurement enumeration
//! literals are case-sensitive CIM identifiers).

const std = @import("std");

fn eql_ascii_ignore_case(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub const ReferenceStringSet = std.StaticStringMapWithEql(void, eql_ascii_ignore_case);
pub const ExactStringSet = std.StaticStringMap(void);

// QoCDC §5.3 Rules' Constants.
//
pub const numeric_tolerance_factor: f64 = 0.0005; // NUMERIC_TOLERANCE
// const ssh_sv_active_power_diff_mw_max: f64 = 10; // SSH_SV_MAX_P_DIFF
// const ssh_sv_reactive_power_diff_mvar_max: f64 = 50; // SSH_SV_MAX_Q_DIFF
// const ssh_sv_active_power_diff_mw_total: f64 = 200; // SSH_SV_TOT_P_DIFF
// const ssh_sv_tap_diff_steps_max: u32 = 2; // SSH_SV_MAX_TAP_STEP_DIFF
// const ssh_sv_shunt_reactive_power_diff_mvar_max: f64 = 1; // SSH_SV_MAX_Q_SHUNT_DIFF
// const sv_injection_mva_max: f64 = 0.1; // SV_INJECTION_LIMIT (also MW/Mvar)
// const sv_injection_relaxed_mva_max: f64 = 0.5; // SV_INJECTION_RELAXED_LIMIT
// const eq_branch_reactance_ohm_min: f64 = 0.01; // EQ_BRANCH_X_LIMIT
// const eq_rated_value_factor_max: u32 = 10; // EQ_RATEDS_REASONABILITY_FACTOR
// const eq_deadband_factor_max: u32 = 2; // EQ_DB_REASONABILITY_FACTOR

/// IO_NAME_LENGTH original value 32, 128 per IEC 61970-600-1/-2:2021 for
/// CGMES 3.0.
pub const name_chars_max: u32 = 128;
/// IO_DESCRIPTION_LENGTH
pub const description_chars_max: u32 = 256;
/// EIC_LENGTH
pub const eic_chars_max: u32 = 16;
/// SHORT_NAME_LENGTH
pub const short_name_chars_max: u32 = 12;
// const boundary_base_voltage_diff_factor_max: f64 = 0.1; // BOUNDARY_BV_MAX_DIFF
// const patl_limit_diff_factor_max: f64 = 0.1; // PATL_LIMIT_VALUE_DIFF
// const interchange_imbalance_mw_warning: f64 = 50; // INTERCH_IMBALANCE_WARNING
// const interchange_imbalance_mw_error: f64 = 200; // INTERCH_IMBALANCE_ERROR
// const interchange_imbalance_mw_emf: u32 = 2; // INTERCH_IMBALANCE_EMF
// const substation_count_max: u32 = 30; // NUMBER_OF_SUBSTATIONS
// const reactive_power_mvar_threshold: f64 = 1500; // REACTIVE_POWER_THRESHOLD
// const imbalance_distribution_active_power_mw_threshold: f64 = 2; // THRESHOLD_ACTIVE_P_IMBALANCE_DISTR
// const zero_impedance_pu_max: f64 = 0.00001; // ZERO_IMPEDANCE_THRESHOLD

/// Transmission System Operators
/// Sourced from Common Information Model (CIM) and CIM based documents > Common
/// Grid Model Building Process > Other > QoCDC Reference Data v1.0 > tab 'Region'.
pub const allowed_sourcing_tsos = ReferenceStringSet.initComptime(.{
    .{ "ENTSOE", {} },
    .{ "DKW", {} },
    .{ "DKE", {} },
    .{ "SONI", {} },
    .{ "ELERING", {} },
    .{ "DK", {} },
    .{ "KOSTT", {} },
    .{ "OST", {} },
    .{ "APG", {} },
    .{ "NOSBIH", {} },
    .{ "ELIA", {} },
    .{ "ESO", {} },
    .{ "SWISSGRID", {} },
    .{ "CGES", {} },
    .{ "EMS", {} },
    .{ "CEPS", {} },
    .{ "D4", {} },
    .{ "TTG", {} },
    .{ "D7", {} },
    .{ "50hertz", {} },
    .{ "REE", {} },
    .{ "FI", {} },
    .{ "RTEFRANCE", {} },
    .{ "NG", {} },
    .{ "IPTO", {} },
    .{ "HOPS", {} },
    .{ "MAVIR", {} },
    .{ "EIRGRID", {} },
    .{ "TERNA", {} },
    .{ "LITGRID", {} },
    .{ "CREOS", {} },
    .{ "AST", {} },
    .{ "MEPSO", {} },
    .{ "TTN", {} },
    .{ "NO", {} },
    .{ "PSE", {} },
    .{ "REN", {} },
    .{ "TRANSELECTRICA", {} },
    .{ "SVK", {} },
    .{ "ELES", {} },
    .{ "SEPS", {} },
    .{ "TEIAS", {} },
    .{ "Ukrenergo", {} },
});

/// Common Grid Model Region
/// Sourced from Common Information Model (CIM) and CIM based documents > Common
/// Grid Model Building Process > Other > QoCDC Reference Data v1.0 > tab 'Region'.
pub const allowed_sourcing_cgm_regions = ReferenceStringSet.initComptime(.{
    .{ "MA", {} },
    .{ "IN", {} },
    .{ "NO", {} },
    .{ "UK", {} },
    .{ "BA", {} },
    .{ "CE", {} },
    .{ "EU", {} },
});

/// Regional Security Coordinators
/// Sourced from Common Information Model (CIM) and CIM based documents > Common
/// Grid Model Building Process > Other > QoCDC Reference Data v1.0 > tab 'MergingAgent'.
pub const allowed_sourcing_rscs = ReferenceStringSet.initComptime(.{
    .{ "BALTIC", {} },
    .{ "CORESO", {} },
    .{ "TSCNET", {} },
    .{ "SCC", {} },
    .{ "NORDIC", {} },
    .{ "SEleNeCC", {} },
});

pub const allowed_business_processes = ReferenceStringSet.initComptime(.{
    .{ "RT", {} },
    .{ "TY", {} }, //
    .{ "YR", {} }, // Year-ahead
    .{ "MO", {} }, // Month-ahead
    .{ "WK", {} }, // Week-ahead
    .{ "2D", {} }, // Two days-ahead
    .{ "1D", {} }, // Day-ahead
    .{ "ID", {} }, // Intra-day
    .{ "01", {} }, // N Hours ahead
    .{ "02", {} },
    .{ "03", {} },
    .{ "04", {} },
    .{ "05", {} },
    .{ "06", {} },
    .{ "07", {} },
    .{ "08", {} },
    .{ "09", {} },
    .{ "10", {} },
    .{ "11", {} },
    .{ "12", {} },
    .{ "13", {} },
    .{ "14", {} },
    .{ "15", {} },
    .{ "16", {} },
    .{ "17", {} },
    .{ "18", {} },
    .{ "19", {} },
    .{ "20", {} },
    .{ "21", {} },
    .{ "22", {} },
    .{ "23", {} },
    .{ "24", {} },
    .{ "25", {} },
    .{ "26", {} },
    .{ "27", {} },
    .{ "28", {} },
    .{ "29", {} },
    .{ "30", {} },
    .{ "31", {} },
    .{ "3D", {} }, // Three days-ahead
    .{ "4D", {} }, // Four days-ahead
    .{ "5D", {} }, // Five days-ahead
    .{ "6D", {} }, // Six days-ahead
    .{ "7D", {} }, // Seven days-ahead
});

pub const allowed_model_parts = ReferenceStringSet.initComptime(.{
    .{ "DL", {} },
    .{ "DY", {} },
    .{ "EQ", {} },
    .{ "EQBD", {} },
    .{ "EQDIFF", {} },
    .{ "GL", {} },
    .{ "SSH", {} },
    .{ "SV", {} },
    .{ "TP", {} },
    .{ "TPBD", {} },
});

/// Classes whose instances may omit IdentifiedObject.name under NameLength.
/// Matched by exact class name. (The pre-redesign code matched these
/// case-insensitively -- an accident of reusing ReferenceStringSet; CIM class
/// names are case-exact.)
pub const nameless_type_names = [_][]const u8{
    "ACDCTerminal",
    "RatioTapChangerTablePoint",
    "FullModel",
    "PhaseTapChangerTablePoint",
};

pub const iso_country_codes = ReferenceStringSet.initComptime(.{
    .{ "AD", {} },
    .{ "AL", {} },
    .{ "AM", {} },
    .{ "AT", {} },
    .{ "BA", {} },
    .{ "BE", {} },
    .{ "BG", {} },
    .{ "BY", {} },
    .{ "CH", {} },
    .{ "RS", {} },
    .{ "ME", {} },
    .{ "CY", {} },
    .{ "CZ", {} },
    .{ "DE", {} },
    .{ "DK", {} },
    .{ "EE", {} },
    .{ "ES", {} },
    .{ "FI", {} },
    .{ "FR", {} },
    .{ "GB", {} },
    .{ "GE", {} },
    .{ "GR", {} },
    .{ "HR", {} },
    .{ "HU", {} },
    .{ "IE", {} },
    .{ "IS", {} },
    .{ "IT", {} },
    .{ "LI", {} },
    .{ "LT", {} },
    .{ "LU", {} },
    .{ "LV", {} },
    .{ "MD", {} },
    .{ "MK", {} },
    .{ "MT", {} },
    .{ "NL", {} },
    .{ "NO", {} },
    .{ "PL", {} },
    .{ "PT", {} },
    .{ "RO", {} },
    .{ "RU", {} },
    .{ "SE", {} },
    .{ "SI", {} },
    .{ "SK", {} },
    .{ "SM", {} },
    .{ "TN", {} },
    .{ "TR", {} },
    .{ "UA", {} },
    .{ "KS", {} },
    // TODO these are extended by me to make the program run, unclear what to do with them.
    .{ "EG", {} }, // Egypt
    .{ "LY", {} }, // Libya
    .{ "MA", {} }, // Morocco
});

/// Measurement types, CGMES 2.4.15.
pub const allowed_measurement_types_v2_4_15 = ExactStringSet.initComptime(.{
    .{ "ThreePhasePower", {} },
    .{ "ThreePhaseActivePower", {} },
    .{ "ThreePhaseReactivePower", {} },
    .{ "LineCurrent", {} },
    .{ "PhaseVoltage", {} },
    .{ "LineToLineVoltage", {} },
    .{ "Angle", {} },
    .{ "TapPosition", {} },
    .{ "SwitchPosition", {} },
});

/// Measurement types, CGMES v3.0: LineToLineVoltage is changed to Voltage.
pub const allowed_measurement_types_v3_0 = ExactStringSet.initComptime(.{
    .{ "ThreePhasePower", {} },
    .{ "ThreePhaseActivePower", {} },
    .{ "ThreePhaseReactivePower", {} },
    .{ "LineCurrent", {} },
    .{ "PhaseVoltage", {} },
    .{ "Voltage", {} },
    .{ "Angle", {} },
    .{ "TapPosition", {} },
    .{ "SwitchPosition", {} },
});

/// Measurement units, CGMES 2.4.15.
pub const allowed_measurement_units_v2_4_15 = ExactStringSet.initComptime(.{
    .{ "UnitSymbol.V", {} },
    .{ "UnitSymbol.A", {} },
    .{ "UnitSymbol.W", {} },
    .{ "UnitSymbol.VA", {} },
    .{ "UnitSymbol.VAr", {} },
    .{ "UnitSymbol.deg", {} },
    .{ "UnitSymbol.Hz", {} },
    .{ "UnitSymbol.none", {} },
});

/// Measurement units for Analog, CGMES v3.0
/// (C:452:OP:Measurement.unitSymbol:analogValues).
pub const allowed_analog_measurement_units_v3_0 = ExactStringSet.initComptime(.{
    .{ "UnitSymbol.W", {} },
    .{ "UnitSymbol.deg", {} },
    .{ "UnitSymbol.VA", {} },
    .{ "UnitSymbol.A", {} },
    .{ "UnitSymbol.VAr", {} },
    .{ "UnitSymbol.V", {} },
    .{ "UnitSymbol.Hz", {} },
});

/// Measurement units for Accumulator, CGMES v3.0
/// (C:452:OP:Measurement.unitSymbol:accumulatorValues).
pub const allowed_accumulator_measurement_units_v3_0 = ExactStringSet.initComptime(.{
    .{ "UnitSymbol.VAh", {} },
    .{ "UnitSymbol.VArh", {} },
    .{ "UnitSymbol.Wh", {} },
});

/// Measurement units for Discrete, CGMES v3.0
/// (C:452:OP:Measurement.unitSymbol:discreteValues).
pub const allowed_discrete_measurement_units_v3_0 = ExactStringSet.initComptime(.{
    .{ "UnitSymbol.none", {} },
});
