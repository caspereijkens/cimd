// TODO: probably better to have reporting-style approach of all the errors rather than raising a hard error and stoping the program. But that could be a safety toggle. Maybe a --passthrough option.
// TODO now CGMES 2.4.15 is skipped but probably nice to include this as it is small effort.
// TODO: make clearer which rule failed in logging.
// TODO: check this comment: CGMES v3.0 allows Line for Cut, Jumper, Fuse, GroundDisconnector and Disconnector.
// TODO: the official Error names are terrible, so probably I should not use them here.
// TODO probably add to the EQ model an Enum of all possible models. This can then be switched on here for instance.

const std = @import("std");
const cim = @import("cim/cim.zig");
const print = @import("io/print.zig");
const zip = @import("io/zip.zig");
const read_path = @import("io/read.zig").read_path;

const Model = cim.CimDocument;
const CimObject = cim.CimObject;
const cim_types = cim.cim_types;
const ids = cim.ids;
const parse = cim.parse;
const ReverseRef = cim.refs.ReverseRef;
const ReverseRefIndex = cim.refs.ReverseRefIndex;

const assert = std.debug.assert;

fn eql_ascii_ignore_case(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

const ReferenceStringSet = std.StaticStringMapWithEql(void, eql_ascii_ignore_case);

// QoCDC §5.3 Rules' Constants.
//
// const numeric_tolerance_factor: f64 = 0.0005; // NUMERIC_TOLERANCE
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
const name_chars_max: u32 = 128;
/// IO_DESCRIPTION_LENGTH
const description_chars_max: u32 = 256;
/// EIC_LENGTH
const eic_chars_max: u32 = 16;
/// SHORT_NAME_LENGTH
const short_name_chars_max: u32 = 12;
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
const allowed_sourcing_tsos = ReferenceStringSet.initComptime(.{
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
const allowed_sourcing_cgm_regions = ReferenceStringSet.initComptime(.{
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
const allowed_sourcing_rscs = ReferenceStringSet.initComptime(.{
    .{ "BALTIC", {} },
    .{ "CORESO", {} },
    .{ "TSCNET", {} },
    .{ "SCC", {} },
    .{ "NORDIC", {} },
    .{ "SEleNeCC", {} },
});

const allowed_business_processes = ReferenceStringSet.initComptime(.{
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

const allowed_model_parts = ReferenceStringSet.initComptime(.{
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

const nameless_types = ReferenceStringSet.initComptime(.{
    .{ "ACDCTerminal", {} },
    .{ "RatioTapChangerTablePoint", {} },
    .{ "FullModel", {} },
    .{ "PhaseTapChangerTablePoint", {} },
});

const iso_country_codes = ReferenceStringSet.initComptime(.{
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

const Filename = struct {
    effective_date_time: []const u8,
    business_process: ?[]const u8,
    sourcing_actor: []const u8,
    model_part: []const u8,
    file_version: []const u8,
};

pub fn parse_filename(filename: []const u8) !Filename {
    assert(filename.len > 0);

    if (std.mem.countScalar(u8, filename, '_') != 4) {
        return error.FileNameMD;
    }

    var it = std.mem.splitScalar(u8, filename, '_');

    const effective_date_time = it.next() orelse return error.FileNameMD;
    if (effective_date_time.len == 0) {
        return error.FileNameMD;
    }

    const business_process = it.next() orelse return error.FileNameMD;

    const sourcing_actor = it.next() orelse return error.FileNameMD;
    if (sourcing_actor.len == 0) {
        return error.FileNameMD;
    }
    if (std.mem.countScalar(u8, sourcing_actor, '>') > 2) {
        return error.FileNameMD;
    }

    const model_part = it.next() orelse return error.FileNameMD;
    if (model_part.len == 0) {
        return error.FileNameMD;
    }

    const file_version = it.next() orelse return error.FileNameMD;
    if (file_version.len == 0) {
        return error.FileNameMD;
    }

    return .{
        .effective_date_time = effective_date_time,
        .business_process = if (business_process.len == 0) null else business_process,
        .file_version = file_version,
        .model_part = model_part,
        .sourcing_actor = sourcing_actor,
    };
}

pub fn validate_filename_consistency(io: std.Io, file_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, file_path, .{});
    defer file.close(io);

    if (try zip.is_zip_file(io, file)) {
        var zip_buffer: [512]u8 = undefined;
        var file_reader = file.reader(io, &zip_buffer);
        var iter = try std.zip.Iterator.init(&file_reader);

        var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
        const entry = try iter.next() orelse return error.FileNameConsistency;
        if (filename_buf.len < entry.filename_len)
            return error.ZipInsufficientBuffer;
        const filename = filename_buf[0..entry.filename_len];
        {
            try file_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
            try file_reader.interface.readSliceAll(filename);
        }
        const zip_filename = std.fs.path.basename(file_path);
        if (!std.mem.eql(u8, std.fs.path.stem(zip_filename), std.fs.path.stem(filename))) {
            return error.FileNameConsistency;
        }
        if (try iter.next() != null) {
            return error.FileNameConsistency;
        }
    } else {
        return error.NotZipArchive;
    }
}

fn is_digits(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

// The 'effectiveDateTime' in the file name must be a valid datetime in minute
// resolution in accordance with ISO 8601-2005, basic format with time
// designator [T] between date and time and ending with UTC designator [Z]. For
// example, 20180118T1130Z. Use of other date/time specifiers by characters
// [:.-+YMDHSWP] is not allowed.
pub fn check_effective_datetime(filename: Filename) !void {
    const date_time = filename.effective_date_time;
    if (date_time.len != 14) {
        return error.EffectiveDateTime;
    }
    if (date_time[8] != 'T') {
        return error.EffectiveDateTime;
    }
    if (date_time[13] != 'Z') {
        return error.EffectiveDateTime;
    }
    if (!is_digits(date_time[0..8])) {
        return error.EffectiveDateTime;
    }
    if (!is_digits(date_time[9..13])) {
        return error.EffectiveDateTime;
    }

    const year = std.fmt.parseInt(u16, date_time[0..4], 10) catch return error.EffectiveDateTime;
    const month = std.fmt.parseInt(u8, date_time[4..6], 10) catch return error.EffectiveDateTime;
    const day = std.fmt.parseInt(u8, date_time[6..8], 10) catch return error.EffectiveDateTime;
    const hour = std.fmt.parseInt(u8, date_time[9..11], 10) catch return error.EffectiveDateTime;
    const minute = std.fmt.parseInt(u8, date_time[11..13], 10) catch return error.EffectiveDateTime;

    if (month < 1 or month > 12) {
        return error.EffectiveDateTime;
    }
    const month_enum: std.time.epoch.Month = @enumFromInt(month);
    const days_in_month: u8 = @intCast(std.time.epoch.getDaysInMonth(year, month_enum));
    if (day < 1 or day > days_in_month) {
        return error.EffectiveDateTime;
    }
    if (hour > 23) {
        return error.EffectiveDateTime;
    }
    if (minute > 59) {
        return error.EffectiveDateTime;
    }
}

pub const validate_effective_datetime = check_effective_datetime;

/// The sourcingActor, that appears in the cimxml file name, is composed as
/// described in rule FileNameMD. The choice on sourcingActor is made by the
/// responsible TSO and it is recorded in the QoCDC Reference Data document.
/// Once decided the sourcingActor should comply with the defined names in the
/// QoCDC Reference Data document. This rule checks if the values of the
/// following fields "sourcingRSC" and "sourcingTSO" from the sourcingActor
/// part of the file name is one of the allowed values in the QoCDC Reference
/// Data document. The rule does not check the field "cgmRegion".
pub fn validate_sourcing_actor(filename: Filename) !void {
    const sourcing_actor = filename.sourcing_actor;
    var iter = std.mem.splitScalar(u8, sourcing_actor, '-');

    var count: u32 = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    iter.reset();
    switch (count) {
        0 => return error.SourcingActor,
        1 => {
            const sourcing_tso = iter.next() orelse return error.SourcingActor;
            _ = allowed_sourcing_tsos.get(sourcing_tso) orelse return error.SourcingActor;
            return;
        },
        2 => {
            const sourcing_rsc = iter.next() orelse return error.SourcingActor;
            _ = allowed_sourcing_rscs.get(sourcing_rsc) orelse return error.SourcingActor;
            return;
        },
        3 => {
            const sourcing_rsc = iter.next() orelse return error.SourcingActor;
            _ = allowed_sourcing_rscs.get(sourcing_rsc) orelse return error.SourcingActor;
            _ = iter.next();
            const sourcing_tso = iter.next() orelse return error.SourcingActor;
            _ = allowed_sourcing_tsos.get(sourcing_tso) orelse return error.SourcingActor;
            return;
        },
        else => {
            return error.SourcingActor;
        },
    }
}

/// The sourcingActor, that appears in the cimxml file name, is composed as
/// described in rule FileNameMD. This rule checks if the value of the field
/// "cgmRegion" from the sourcingActor part of the file name is one of the
/// allowed values in the QoCDC Reference Data document. The rule does not
/// check the fields "sourcingRSC" and "sourcingTSO".
pub fn validate_cgm_region(filename: Filename) !void {
    const sourcing_actor = filename.sourcing_actor;
    var iter = std.mem.splitScalar(u8, sourcing_actor, '-');

    var count: u32 = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    iter.reset();
    switch (count) {
        0 => return error.CGMRegion,
        1 => {
            return;
        },
        2, 3 => {
            _ = iter.next();
            const cgm_region = iter.next() orelse return error.CGMRegion;
            _ = allowed_sourcing_cgm_regions.get(cgm_region) orelse return error.CGMRegion;
            return;
        },
        else => {
            return error.CGMRegion;
        },
    }
}

/// The 'businessProcess' in the file name is restricted according to a list in
/// the QoCDC Reference Data document. See also level 2 rule ModelDescription
/// where the BusinessProcess is required in the Model.description attribute.
pub fn validate_business_process(filename: Filename) !void {
    const business_process_opt = filename.business_process;

    // TODO check profile part because:
    // - EQ shall use both template 1 and 2;
    // - SSH, TP and SV shall only use template 1;
    // - EQBD and TPBD shall only use template 2.
    if (business_process_opt) |business_process| {
        if (business_process.len != 2) {
            std.log.err("BusinessProcess '{s}' must be a value of length 2.", .{business_process});
            return error.BusinessProcess;
        }
        _ = allowed_business_processes.get(business_process) orelse return error.BusinessProcess;
        return;
    }
    return;
}

/// The 'modelPart' in the file name is restricted. Note that the profile
/// declarations in the file header are leading and shall be used as meta data
/// to request data. The allowed model part types are as follows: DL, DY, EQ,
/// EQBD, EQDIFF, GL, SSH, SV, TP, TPBD.
pub fn validate_model_part(filename: Filename) !void {
    _ = allowed_model_parts.get(filename.model_part) orelse return error.ModelPartType;
    return;
}

/// The 'fileVersion' in the file name must be positive integer value always
/// represented by three numeric characters ranging from 001 to 999. Leading
/// zeros are allowed.
pub fn validate_file_version(filename: Filename) !void {
    if (filename.file_version.len != 3) return error.FileVersion;
    const file_version = std.fmt.parseInt(u16, filename.file_version, 10) catch return error.FileVersion;
    if (file_version == 0) {
        return error.FileVersion;
    }
    if (file_version > 999) {
        return error.FileVersion;
    }
    return;
}

// Level 3: Basic IGM/CGM Constraints

/// NameLength
///
/// In cases where cim:IdentifiedObject.name is a required attribute, it shall
/// not be empty string and shall not exceed IO_NAME_LENGTH characters for all
/// instances except for instances of subclasses of cim:ACDCTerminal where
/// cim:IdentifiedObject.name may be omitted. Note: This rule further restricts
/// IEC TS 61970-600-1:2017, IEC TS 61970-600-2:2017 where empty strings are
/// allowed in cim:IdentifiedObject.name.
pub fn validate_name_length(model: Model) !void {
    var groups = model.type_groups();
    while (groups.next()) |group| {
        if (cim_types.is_a(group.type_name, "ACDCTerminal")) continue;
        if (nameless_types.get(group.type_name) != null) continue;

        for (group.objects) |object_data| {
            const object = object_data;
            const name = try object.property("IdentifiedObject.name") orelse {
                std.log.err("{s}", .{object.id()});
                return error.NameLength;
            };
            if (name.len == 0 or name.len > name_chars_max) {
                std.log.err("Object {s} has an invalid name: {s}", .{ object.id(), name });
                return error.NameLength;
            }
        }
    }
}

/// ShortNameLength
///
/// In every model instance, the length of all instances of
/// entsoe:IdentifiedObject.shortName shall not exceed SHORT_NAME_LENGTH
/// characters.
pub fn validate_short_name_length(model: Model) !void {
    for (model.objects) |object_data| {
        const object = object_data;
        const short_name = object.property("IdentifiedObject.shortName") catch {
            std.log.err("Failed to parse short name of object '{s}'.", .{object.id()});
            return error.ShortNameLength;
        } orelse continue;
        if (short_name.len > short_name_chars_max) {
            std.log.err("Short name of object '{s}' too long: '{s}'", .{ object.id(), short_name });
            return error.ShortNameLength;
        }
    }
}

/// EICLength
///
/// In every model instance, the length of all instances of
/// entsoe:IdentifiedObject.energyIdentCodeEic must be exactly EIC_LENGTH
/// characters.
/// TODO this can be sped up by limiting type scope to skip elements that do not
/// have this.
pub fn validate_energy_ident_coding_length(model: Model) !void {
    for (model.objects) |object_data| {
        const object = object_data;
        const energy_ident_code = object.property("IdentifiedObject.energyIdentCodeEic") catch {
            std.log.err("Failed to parse energyIdentCodeEic of object '{s}'.", .{object.id()});
            return error.EICLength;
        } orelse continue;
        if (energy_ident_code.len != eic_chars_max) {
            std.log.err("EnergyIdentCodeEic of object '{s}' is not exactly {d} characters: '{s}'", .{ object.id(), eic_chars_max, energy_ident_code });
            return error.EICLength;
        }
    }
}

/// DescriptionLength
///
/// In every model instance, the length of all instances of
/// cim:IdentifiedObject.description shall not exceed IO_DESCRIPTION_LENGTH
/// characters.
/// NOTE: this only checks length, not the absence of a description.
pub fn validate_description_length(model: Model) !void {
    for (model.objects) |object_data| {
        const object = object_data;
        const description = object.property("IdentifiedObject.description") catch {
            std.log.err("Failed to parse description of object '{s}'.", .{object.id()});
            return error.DescriptionLength;
        } orelse continue;
        if (description.len > description_chars_max) {
            std.log.err("Description of object '{s}' too long: '{s}'", .{ object.id(), description });
            return error.DescriptionLength;
        }
    }
}

/// CNFromEndIsoCode
///
/// In an EQBD document attribute value entsoe:ConnectivityNode.fromEndIsoCode
/// must be from the country code list - field 'TsoCodeList' in the QoCDC
/// Reference Data document which is a subset of
/// https://www.iso.org/iso-3166-country-codes.html.
///
/// Comment: In CGMES v3.0 this applies to eu:BoundaryPoint and not
/// cim:ConnectivityNode
pub fn validate_boundary_node_country_code_from(model: Model) error{CNFromEndIsoCode}!void {
    validate_boundary_node_country_code(model, "BoundaryPoint.fromEndIsoCode") catch return error.CNFromEndIsoCode;
}

/// CNToEndIsoCode
///
/// In an EQBD document attribute value entsoe:ConnectivityNode.toEndIsoCode
/// must be from the country code list - field 'TsoCodeList' in the QoCDC
/// Reference Data document which is a subset of
/// https://www.iso.org/iso-3166-country-codes.html.
///
/// Comment: In CGMES v3.0 this applies to eu:BoundaryPoint and not
/// cim:ConnectivityNode
pub fn validate_boundary_node_country_code_to(model: Model) error{CNToEndIsoCode}!void {
    validate_boundary_node_country_code(model, "BoundaryPoint.toEndIsoCode") catch return error.CNToEndIsoCode;
}

/// CNFromEndNameLength
///
/// In every EQBD model instance, the length of all instances of
/// entsoe:ConnectivityNode.fromEndName shall not exceed IO_NAME_LENGTH
/// characters.
///
/// In CGMES v3.0 this applies to eu:BoundaryPoint and not
/// cim:ConnectivityNode.
pub fn validate_boundary_node_name_length_from(model: Model) error{CNFromEndNameLength}!void {
    validate_boundary_point_text_length(model, "BoundaryPoint.fromEndName", name_chars_max) catch return error.CNFromEndNameLength;
}

/// CNToEndNameLength
///
/// In every EQBD model instance, the length of all instances of
/// entsoe:ConnectivityNode.toEndName shall not exceed IO_NAME_LENGTH
/// characters.
///
/// In CGMES v3.0 this applies to eu:BoundaryPoint and not
/// cim:ConnectivityNode.
pub fn validate_boundary_node_name_length_to(model: Model) error{CNToEndNameLength}!void {
    validate_boundary_point_text_length(model, "BoundaryPoint.toEndName", name_chars_max) catch return error.CNToEndNameLength;
}

/// CNFromEndNameTsoLength
///
/// In every EQBD model instance, the length of all instances of
/// entsoe:ConnectivityNode.fromEndNameTso shall not exceed IO_NAME_LENGTH
/// characters.
///
/// In CGMES v3.0 this applies to eu:BoundaryPoint and not
/// cim:ConnectivityNode.
pub fn validate_boundary_node_tso_name_length_from(model: Model) error{CNFromEndNameTsoLength}!void {
    validate_boundary_point_text_length(model, "BoundaryPoint.fromEndNameTso", name_chars_max) catch return error.CNFromEndNameTsoLength;
}

/// CNToEndNameTsoLength
///
/// In every EQBD model instance, the length of all instances of
/// entsoe:ConnectivityNode.toEndNameTso shall not exceed IO_NAME_LENGTH
/// characters.
///
/// In CGMES v3.0 this applies to eu:BoundaryPoint and not
/// cim:ConnectivityNode.
pub fn validate_boundary_node_tso_name_length_to(model: Model) error{CNToEndNameTsoLength}!void {
    validate_boundary_point_text_length(model, "BoundaryPoint.toEndNameTso", name_chars_max) catch return error.CNToEndNameTsoLength;
}

/// GenerationContainment
///
/// For every instance of cim:HydroPump and cim:GeneratingUnit (and subclasses
/// thereof), the cim:Equipment.EquipmentContainer referred to, must be of type
/// cim:Substation. Missing containment is not allowed.
pub fn validate_generation_containment(model: Model) error{GenerationContainment}!void {
    validate_containment(
        model,
        &.{ "HydroPump", "GeneratingUnit" },
        &.{"Substation"},
        true,
        "Equipment.EquipmentContainer",
    ) catch return error.GenerationContainment;
}

/// PTContainment
///
/// For every instance of cim:PowerTransformer, the
/// cim:Equipment.EquipmentContainer referred to, must be of type
/// cim:Substation or of type cim:DCConverterUnit. Missing containment is not
/// allowed.
pub fn validate_power_transformer_containment(model: Model) error{PTContainment}!void {
    validate_containment(model, &.{"PowerTransformer"}, &.{ "Substation", "DCConverterUnit" }, true, "Equipment.EquipmentContainer") catch return error.PTContainment;
}

/// SwitchContainment
///
/// For every instance of Switch (and subclasses thereof), the
/// cim:Equipment.EquipmentContainer referred to, must be of type VoltageLevel,
/// of type Bay or of type DCConverterUnit. Missing containment is not allowed.
///
/// CGMES v3.0 allows Line for Cut, Jumper, Fuse, GroundDisconnector and
/// Disconnector.
pub fn validate_switch_containment(model: Model) error{SwitchContainment}!void {
    validate_containment(
        model,
        &.{"Switch"},
        &.{ "VoltageLevel", "Bay", "DCConverterUnit" },
        true,
        "Equipment.EquipmentContainer",
    ) catch return error.SwitchContainment;
}

/// SCContainment
///
/// For every instance of cim:SeriesCompensator, the
/// cim:Equipment.EquipmentContainer referred to, if provided, must be of type
/// cim:Line, of type cim:VoltageLevel or of type cim:DCConverterUnit.
///
/// CGMES v3.0 allows Line for Cut, Jumper, Fuse, GroundDisconnector and
/// Disconnector.
pub fn validate_series_compensator_containment(model: Model) error{SCContainment}!void {
    validate_containment(model, &.{"SeriesCompensator"}, &.{ "Line", "VoltageLevel", "DCConverterUnit" }, false, "Equipment.EquipmentContainer") catch return error.SCContainment;
}

/// InjectionContainment
///
/// For every instance of cim:EnergyConsumer subclasses, cim:RotatingMachine
/// subclasses, cim:ShuntCompensator subclasses, cim:EnergySource,
/// cim:EquivalentShunt, cim:ExternalNetworkInjection and
/// cim:StaticVarCompensator, the cim:Equipment.EquipmentContainer referred to,
/// must be of type cim:VoltageLevel. Missing containment is not allowed.
pub fn validate_injection_containment(model: Model) error{InjectionContainment}!void {
    validate_containment(
        model,
        &.{
            "EnergyConsumer",
            "RotatingMachine",
            "ShuntCompensator",
            "EnergySource",
            "EquivalentShunt",
            "ExternalNetworkInjection",
            "StaticVarCompensator",
        },
        &.{"VoltageLevel"},
        true,
        "Equipment.EquipmentContainer",
    ) catch return error.InjectionContainment;
}

/// BusbarSectionContainment
///
/// For every instance of cim:BusbarSection, the
/// cim:Equipment.EquipmentContainer referred to, must be of type
/// cim:VoltageLevel. Missing containment is not allowed.
pub fn validate_busbar_section_containment(model: Model) error{BusbarSectionContainment}!void {
    validate_containment(model, &.{"BusbarSection"}, &.{"VoltageLevel"}, true, "Equipment.EquipmentContainer") catch return error.BusbarSectionContainment;
}

/// EFCContainment
///
/// For every instance of cim:EarthFaultCompensator, its subclasses and
/// cim:Ground, the cim:Equipment.EquipmentContainer referred to, must be of
/// type cim:VoltageLevel. Missing containment is not allowed.
///
/// CGMES v3.0 also allows Bay.
pub fn validate_ground_containment(model: Model) error{EFCContainment}!void {
    validate_containment(
        model,
        &.{ "EarthFaultCompensator", "Ground" },
        &.{ "VoltageLevel", "Bay" },
        true,
        "Equipment.EquipmentContainer",
    ) catch return error.EFCContainment;
}

/// ACDCConvContainment
///
/// For every instance of cim:CsConverter and cim:VsConverter, the
/// cim:Equipment.EquipmentContainer referred to, must be of type
/// cim:DCConverterUnit. Missing containment is not allowed.
pub fn validate_acdc_converter_containment(model: Model) error{ACDCConvContainment}!void {
    validate_containment(model, &.{ "CsConverter", "VsConverter" }, &.{"DCConverterUnit"}, true, "Equipment.EquipmentContainer") catch return error.ACDCConvContainment;
}

/// DCEQContainment
///
/// For every instance of cim:DCSeriesDevice, cim:DCShunt, cim:DCBusbar,
/// cim:DCGround, cim:DCChopper, cim:DCSwitch, cim:DCBreaker and
/// cim:DCDisconnector, the cim:Equipment.EquipmentContainer referred to, must
/// be of type cim:DCConverterUnit. Missing containment is not allowed.
pub fn validate_dc_equipment_containment(model: Model) error{DCEQContainment}!void {
    validate_containment(model, &.{ "DCSeriesDevice", "DCShunt", "DCBusbar", "DCGround", "DCChopper", "DCSwitch", "DCBreaker", "DCDisconnector" }, &.{"DCConverterUnit"}, true, "Equipment.EquipmentContainer") catch return error.DCEQContainment;
}

/// CNContainment
///
/// For cim:ConnectivityNodes according to EQ, the
/// cim:ConnectivityNode.ConnectivityNodeContainer referred to, must be of type
/// cim:VoltageLevel, cim:Bay or cim:Line. For cim:ConnectivityNodes according
/// to EQBD, the cim:ConnectivityNode.ConnectivityNodeContainer referred to,
/// must be of type cim:Line. Missing containment is not allowed.
pub fn validate_conn_node_containment(model: Model, profile_part: cim.profile.Kind) error{CNContainment}!void {
    switch (profile_part) {
        .eq => validate_containment(model, &.{"ConnectivityNode"}, &.{ "VoltageLevel", "Bay", "Line" }, true, "ConnectivityNode.ConnectivityNodeContainer") catch
            return error.CNContainment,
        .eqbd => validate_containment(model, &.{"ConnectivityNode"}, &.{"Line"}, true, "ConnectivityNode.ConnectivityNodeContainer") catch return error.CNContainment,
        // SSH/SV/TP carry no ConnectivityNode containment rule — nothing to check.
        else => {},
    }
}

/// GeneratingUnitNominalP
///
/// The value of cim:GeneratingUnit.nominalP, if provided, shall be positive
/// and less or equal to cim:RotatingMachine.ratedS.
pub fn validate_nominal_power(model: Model) error{GeneratingUnitNominalP}!void {
    var groups = model.type_groups();
    while (groups.next()) |group| {
        if (!cim_types.is_a(group.type_name, "GeneratingUnit")) continue;

        for (group.objects) |object_data| {
            const object = object_data;

            const nominal_power_str = object.property("GeneratingUnit.nominalP") catch continue orelse continue;
            const nominal_power = std.fmt.parseFloat(f64, nominal_power_str) catch {
                std.log.err("Failed to parse nominal power '{s}' of object '{s}' into a floating value.", .{ nominal_power_str, object.id() });
                return error.GeneratingUnitNominalP;
            };
            if (!std.math.isFinite(nominal_power) or nominal_power <= 0) {
                std.log.err("Nominal power of object '{s}' must be a positive finite value: '{s}'.", .{ object.id(), nominal_power_str });
                return error.GeneratingUnitNominalP;
            }

            const apparent_power_str = object.property("GeneratingUnit.ratedS") catch continue orelse continue;
            const apparent_power = std.fmt.parseFloat(f64, apparent_power_str) catch {
                std.log.err("Failed to parse apparent power '{s}' of object '{s}'.", .{ apparent_power_str, object.id() });
                return error.GeneratingUnitNominalP;
            };
            if (!std.math.isFinite(apparent_power) or nominal_power > apparent_power) {
                std.log.err("GeneratingUnit.nominalP={d} exceeds ratedS={d} for object '{s}'.", .{ nominal_power, apparent_power, object.id() });
                return error.GeneratingUnitNominalP;
            }
        }
    }
}

/// CEBaseVoltage
///
/// All cim:ConductingEquipment except cim:ACLineSegment,
/// cim:SeriesCompensator, cim:EquivalentBranch, cim:PowerTransformer and
/// cim:ACDCConverter, must either have an association with cim:BaseVoltage or
/// be located within a cim:VoltageLevel or cim:Bay. The exception is because
/// rule BranchBaseVoltage validates similar conditions. If both
/// cim:ConductingEquipment.BaseVoltage and containment in a cim:VoltageLevel
/// or cim:Bay are provided, the association ends
/// cim:ConductingEquipment.BaseVoltage and cim:VoltageLevel.BaseVoltage shall
/// refer to the same cim:BaseVoltage.
pub fn validate_conducting_equipment_base_voltage(model: Model) error{CEBaseVoltage}!void {
    var groups = model.type_groups();
    while (groups.next()) |group| {
        if (!cim_types.is_a(group.type_name, "ConductingEquipment")) continue;
        if (matches_any_type(group.type_name, &.{
            "ACLineSegment",
            "SeriesCompensator",
            "EquivalentBranch",
            "PowerTransformer",
            "ACDCConverter",
        })) continue;

        for (group.objects) |object_data| {
            const object = object_data;
            const equipment_base_voltage: ?[]const u8 = if (object.reference("ConductingEquipment.BaseVoltage") catch null) |ref|
                ids.strip_hash(ref)
            else
                null;
            const containment = resolve_container_base_voltage(model, object);

            if (equipment_base_voltage == null and !containment.in_voltage_level_or_bay) {
                return error.CEBaseVoltage;
            }
            if (equipment_base_voltage) |equipment_voltage| {
                if (containment.base_voltage) |container_voltage| {
                    if (!std.mem.eql(u8, equipment_voltage, container_voltage)) {
                        return error.CEBaseVoltage;
                    }
                }
            }
        }
    }
}

/// NominalVoltage
///
/// For every instance of cim:BaseVoltage, the cim:BaseVoltage.nominalVoltage
/// value must be greater than zero.
pub fn validate_nominal_voltage(model: Model) error{NominalVoltage}!void {
    const base_voltages = model.objects_by_type("BaseVoltage");
    for (base_voltages) |base_voltage| {
        // base_voltage is already a stored object of this model; view it directly
        // instead of a redundant id_to_index lookup that can never miss.
        const object = base_voltage;
        const nominal_voltage_str = object.property("BaseVoltage.nominalVoltage") catch {
            std.log.err("Failed to parse nominal voltage for base voltage {s}", .{base_voltage.id()});
            return error.NominalVoltage;
        } orelse {
            std.log.err("No nominal voltage found for base voltage {s}", .{base_voltage.id()});
            return error.NominalVoltage;
        };
        const nominal_voltage = std.fmt.parseFloat(f64, nominal_voltage_str) catch {
            std.log.err("Failed to parse float from string: '{s}'", .{nominal_voltage_str});
            return error.NominalVoltage;
        };
        if (nominal_voltage <= 0) {
            std.log.err("Nominal voltage is negative: {d}", .{nominal_voltage});
            return error.NominalVoltage;
        }
    }
}

/// TerminalCount1
///
/// Every instance of cim:RegulatingCondEq and its subclasses,
/// cim:EnergyConsumer and its subclasses, cim:EquivalentInjection,
/// cim:EquivalentShunt, subclasses of cim:Connector, cim:EnergySource,
/// cim:Ground, cim:DCBusbar, cim:DCShunt, cim:DCGround shall only be referenced
/// via a single cim:Terminal instance.
pub fn validate_terminal_count1(model: Model, reverse_ref_index: *const ReverseRefIndex) error{TerminalCount1}!void {
    var groups = model.type_groups();
    while (groups.next()) |group| {
        if (!is_terminal_count1_type(group.type_name)) continue;

        for (group.objects) |object_data| {
            var terminal_id: ?[]const u8 = null;
            for (reverse_ref_index.lookup(object_data.id())) |reference| {
                if (!std.mem.eql(u8, reference.referrer_type, "Terminal")) continue;
                if (!std.mem.eql(u8, reference.reference_name, "Terminal.ConductingEquipment")) continue;

                if (terminal_id) |found_id| {
                    if (!std.mem.eql(u8, found_id, reference.referrer_id)) return error.TerminalCount1;
                } else {
                    terminal_id = reference.referrer_id;
                }
            }

            if (terminal_id == null) return error.TerminalCount1;
        }
    }
}

fn is_terminal_count1_type(type_name: []const u8) bool {
    if (matches_any_type(type_name, &.{
        "RegulatingCondEq",
        "EnergyConsumer",
        "EquivalentInjection",
        "EquivalentShunt",
        "EnergySource",
        "Ground",
        "DCBusbar",
        "DCShunt",
        "DCGround",
    })) return true;

    if (std.mem.eql(u8, type_name, "Connector")) return false;
    return cim_types.is_a(type_name, "Connector");
}

/// TerminalCount2
///
/// Every instance of cim:Conductor and its subclasses, cim:Switch and its
/// subclasses, cim:SeriesCompensator, cim:EquivalentBranch, cim:DCLineSegment,
/// cim:DCSeriesDevice, cim:DCChopper and subclasses of cim:DCSwitch, shall
/// only be referenced via exactly two cim:Terminal instances.
pub fn validate_terminal_count2(model: Model, reverse_ref_index: *const ReverseRefIndex) error{TerminalCount2}!void {
    var groups = model.type_groups();
    while (groups.next()) |group| {
        if (!is_terminal_count2_type(group.type_name)) continue;

        for (group.objects) |object_data| {
            var terminal_ids: [2][]const u8 = undefined;
            var terminals_found: u2 = 0;
            for (reverse_ref_index.lookup(object_data.id())) |reference| {
                if (!std.mem.eql(u8, reference.referrer_type, "Terminal")) continue;
                if (!std.mem.eql(u8, reference.reference_name, "Terminal.ConductingEquipment")) continue;

                var terminal_already_counted = false;
                for (terminal_ids[0..terminals_found]) |terminal_id| {
                    if (std.mem.eql(u8, terminal_id, reference.referrer_id)) {
                        terminal_already_counted = true;
                        break;
                    }
                }
                if (terminal_already_counted) continue;
                if (terminals_found == terminal_ids.len) return error.TerminalCount2;

                terminal_ids[terminals_found] = reference.referrer_id;
                terminals_found += 1;
            }

            if (terminals_found != 2) return error.TerminalCount2;
        }
    }
}

fn is_terminal_count2_type(type_name: []const u8) bool {
    if (matches_any_type(type_name, &.{
        "Conductor",
        "Switch",
        "SeriesCompensator",
        "EquivalentBranch",
        "DCLineSegment",
        "DCSeriesDevice",
        "DCChopper",
    })) return true;

    if (std.mem.eql(u8, type_name, "DCSwitch")) return false;
    return cim_types.is_a(type_name, "DCSwitch");
}

/// TerminalSeqNum
///
/// Every instance of cim:Terminal must have a cim:Terminal.sequenceNumber if
/// it belongs to a cim:EquivalentBranch or a cim:ACLineSegment with
/// cim:MutualCoupling.
pub fn validate_terminal_seq_num(model: Model, reverse_ref_index: *const ReverseRefIndex) error{TerminalSeqNum}!void {
    var groups = model.type_groups();
    while (groups.next()) |group| {
        const equivalent_branch = cim_types.is_a(group.type_name, "EquivalentBranch");
        const ac_line_segment = cim_types.is_a(group.type_name, "ACLineSegment");
        if (!equivalent_branch and !ac_line_segment) continue;

        for (group.objects) |object_data| {
            if (ac_line_segment and !has_mutual_coupling(object_data, reverse_ref_index)) continue;

            for (reverse_ref_index.lookup(object_data.id())) |reverse_ref| {
                if (!std.mem.eql(u8, reverse_ref.referrer_type, "Terminal")) continue;
                if (!std.mem.eql(u8, reverse_ref.reference_name, "Terminal.ConductingEquipment")) continue;

                const terminal = model.object_by_id(reverse_ref.referrer_id) orelse continue;
                const seq_num = terminal.property("ACDCTerminal.sequenceNumber") catch return error.TerminalSeqNum;
                _ = parse.int_req(u32, seq_num orelse return error.TerminalSeqNum) catch
                    return error.TerminalSeqNum;
            }
        }
    }
}

fn has_mutual_coupling(line: CimObject, reverse_ref_index: *const ReverseRefIndex) bool {
    for (reverse_ref_index.lookup(line.id())) |terminal_ref| {
        if (!std.mem.eql(u8, terminal_ref.referrer_type, "Terminal")) continue;
        if (!std.mem.eql(u8, terminal_ref.reference_name, "Terminal.ConductingEquipment")) continue;

        for (reverse_ref_index.lookup(terminal_ref.referrer_id)) |coupling_ref| {
            if (!cim_types.is_a(coupling_ref.referrer_type, "MutualCoupling")) continue;
            if (std.mem.eql(u8, coupling_ref.reference_name, "MutualCoupling.First_Terminal") or
                std.mem.eql(u8, coupling_ref.reference_name, "MutualCoupling.Second_Terminal"))
            {
                return true;
            }
        }
    }
    return false;
}

/// TerminalSeqNumOrder
///
/// In cases where cim:Terminal.sequenceNumber is provided for an instance of
/// cim:ConductingEquipment or cim:DCConductingEquipment, at least one
/// sequenceNumber shall equal to 1. The cim:Terminal.sequenceNumber of other
/// terminals of same cim:ConductingEquipment or cim:DCConductingEquipment
/// shall follow increasing order.
pub fn validate_terminal_seq_num_order(
    gpa: std.mem.Allocator,
    model: Model,
    reverse_ref_index: *const ReverseRefIndex,
) !void {
    var numbered_terminals: std.ArrayList(NumberedTerminal) = .empty;
    defer numbered_terminals.deinit(gpa);

    var groups = model.type_groups();
    while (groups.next()) |group| {
        const conducting_equipment = cim_types.is_a(group.type_name, "ConductingEquipment");
        const dc_conducting_equipment = cim_types.is_a(group.type_name, "DCConductingEquipment");
        if (!conducting_equipment and !dc_conducting_equipment) continue;

        for (group.objects) |object| {
            numbered_terminals.clearRetainingCapacity();

            for (reverse_ref_index.lookup(object.id())) |reverse_ref| {
                if (!terminal_equipment_reference(reverse_ref)) continue;

                const terminal_id = reverse_ref.referrer_id;
                if (terminal_numbered(numbered_terminals.items, terminal_id)) continue;

                const terminal = model.object_by_id(terminal_id) orelse continue;
                const sequence_number_text = terminal.property("ACDCTerminal.sequenceNumber") catch {
                    return error.TerminalSeqNumOrder;
                };
                const sequence_number = parse.int_req(u32, sequence_number_text orelse continue) catch
                    return error.TerminalSeqNumOrder;

                try numbered_terminals.append(gpa, .{
                    .id = terminal_id,
                    .sequence_number = sequence_number,
                });
            }

            std.mem.sort(NumberedTerminal, numbered_terminals.items, {}, NumberedTerminal.less_than);
            for (numbered_terminals.items, 1..) |numbered_terminal, expected| {
                if (numbered_terminal.sequence_number != expected)
                    return error.TerminalSeqNumOrder;
            }
        }
    }
}

const NumberedTerminal = struct {
    id: []const u8,
    sequence_number: u32,

    fn less_than(_: void, a: NumberedTerminal, b: NumberedTerminal) bool {
        return a.sequence_number < b.sequence_number;
    }
};

fn terminal_equipment_reference(reference: ReverseRef) bool {
    if (!cim_types.is_a(reference.referrer_type, "ACDCTerminal")) return false;
    return std.mem.eql(u8, reference.reference_name, "Terminal.ConductingEquipment") or
        std.mem.eql(u8, reference.reference_name, "DCTerminal.DCConductingEquipment");
}

fn terminal_numbered(numbered_terminals: []const NumberedTerminal, terminal_id: []const u8) bool {
    for (numbered_terminals) |numbered_terminal| {
        if (std.mem.eql(u8, numbered_terminal.id, terminal_id)) return true;
    }
    return false;
}

/// PTTerminalConsistency
///
/// For every instance of cim:PowerTransformerEnd, the cim:Terminal referenced
/// by the cim:TransformerEnd.Terminal association must be associated with the
/// cim:PowerTransformer instance, referenced via the
/// cim:PowerTransformerEnd.PowerTransformer association.
pub fn validate_power_transformer_terminal_consistency(
    model: Model,
) error{PTTerminalConsistency}!void {
    const power_transformer_ends = model.objects_by_type("PowerTransformerEnd");

    for (power_transformer_ends) |power_transformer_end| {
        const terminal_ref = (power_transformer_end.reference("TransformerEnd.Terminal") catch return error.PTTerminalConsistency) orelse return error.PTTerminalConsistency;

        const terminal = model.object_by_id(ids.strip_hash(terminal_ref)) orelse return error.PTTerminalConsistency;
        const conducting_equipment_ref = (terminal.reference("Terminal.ConductingEquipment") catch return error.PTTerminalConsistency) orelse return error.PTTerminalConsistency;

        const conducting_equipment = model.object_by_id(ids.strip_hash(conducting_equipment_ref)) orelse return error.PTTerminalConsistency;

        const power_transformer_ref = (power_transformer_end.reference("PowerTransformerEnd.PowerTransformer") catch return error.PTTerminalConsistency) orelse return error.PTTerminalConsistency;
        const power_transformer_id = ids.strip_hash(power_transformer_ref);

        if (!std.mem.eql(u8, conducting_equipment.id(), power_transformer_id)) {
            return error.PTTerminalConsistency;
        }

        if (!cim_types.is_a(conducting_equipment.type_name(), "PowerTransformer")) {
            return error.PTTerminalConsistency;
        }
    }
}

/// MCFirstSecond
///
/// The following shall conform for every instance of cim:MutualCoupling:
/// 1) Association end cim:MutualCoupling.First_Terminal shall refer to a
///    cim:Terminal of an cim:ACLineSegment.
/// 2) Association end cim:MutualCoupling.Second_Terminal shall refer to a
///    cim:Terminal of an cim:ACLineSegment.
/// 3) Association ends cim:MutualCoupling.First_Terminal and
///    cim:MutualCoupling.Second_Terminal shall refer to cim:Terminals of
///    different cim:ACLineSegments.
pub fn validate_mutual_coupling_order(
    model: Model,
) error{MCFirstSecond}!void {
    const mutual_couplings = model.objects_by_type("MutualCoupling");

    for (mutual_couplings) |mutual_coupling| {
        const terminal_refs = mutual_coupling.references(.{
            "MutualCoupling.First_Terminal",
            "MutualCoupling.Second_Terminal",
        }) catch return error.MCFirstSecond;
        const first_terminal_ref = terminal_refs[0] orelse return error.MCFirstSecond;
        const second_terminal_ref = terminal_refs[1] orelse return error.MCFirstSecond;

        const first_line_id = try mutual_coupling_line_id(model, first_terminal_ref);
        const second_line_id = try mutual_coupling_line_id(model, second_terminal_ref);
        if (std.mem.eql(u8, first_line_id, second_line_id)) return error.MCFirstSecond;
    }
}

fn mutual_coupling_line_id(
    model: Model,
    terminal_ref: []const u8,
) error{MCFirstSecond}![]const u8 {
    const terminal = model.object_by_id(ids.strip_hash(terminal_ref)) orelse
        return error.MCFirstSecond;
    if (!cim_types.is_a(terminal.type_name(), "Terminal")) return error.MCFirstSecond;

    const equipment_ref = (terminal.reference("Terminal.ConductingEquipment") catch
        return error.MCFirstSecond) orelse return error.MCFirstSecond;
    const equipment = model.object_by_id(ids.strip_hash(equipment_ref)) orelse
        return error.MCFirstSecond;
    if (!cim_types.is_a(equipment.type_name(), "ACLineSegment")) return error.MCFirstSecond;
    return equipment.id();
}

/// LRCExponentModel
///
/// For every instance of cim:LoadResponseCharacteristic where
/// cim:LoadResponseCharacteristic.exponentModel is true,
/// cim:LoadResponseCharacteristic.pVoltageExponent and
/// cim:LoadResponseCharacteristic.qVoltageExponent must be provided and be
/// greater than or equal to zero and less than or equal to two.
///
/// The attributes pFrequencyExponent and qFrequencyExponent are not used. The
/// attributes required for the coefficient load model covered by rule
/// LCRCoefficientModel are ignored and not validated when
/// cim:LoadResponseCharacteristic.exponentModel is true.
///
/// CGMES v3.0 does not include the limitations on the exponent values.
pub fn validate_load_response_characteristic_exponent_model(
    model: Model,
) error{LRCExponentModel}!void {
    const load_response_characteristics = model.objects_by_type("LoadResponseCharacteristic");
    for (load_response_characteristics) |load_response_characteristic| {
        const properties = load_response_characteristic.properties(.{
            "LoadResponseCharacteristic.exponentModel",
            "LoadResponseCharacteristic.pVoltageExponent",
            "LoadResponseCharacteristic.qVoltageExponent",
        }) catch return error.LRCExponentModel;

        if (!parse.flag(properties[0])) continue;

        const p_voltage_exponent = parse.float_req(properties[1] orelse
            return error.LRCExponentModel) catch return error.LRCExponentModel;
        if (p_voltage_exponent < 0 or p_voltage_exponent > 2) return error.LRCExponentModel;

        const q_voltage_exponent = parse.float_req(properties[2] orelse
            return error.LRCExponentModel) catch return error.LRCExponentModel;
        if (q_voltage_exponent < 0 or q_voltage_exponent > 2) return error.LRCExponentModel;
    }
}

const ContainerBaseVoltage = struct {
    /// True when the equipment is contained in a cim:VoltageLevel or cim:Bay
    /// (the containment that satisfies CEBaseVoltage's existence clause).
    in_voltage_level_or_bay: bool,
    /// The containing cim:VoltageLevel's cim:VoltageLevel.BaseVoltage, with the
    /// leading '#' stripped. Null when there is no VoltageLevel container (e.g.
    /// a Bay that declares no VoltageLevel) or that VoltageLevel declares no
    /// BaseVoltage.
    base_voltage: ?[]const u8,
};

/// Resolve an equipment's cim:Equipment.EquipmentContainer to the BaseVoltage of
/// its containing cim:VoltageLevel. A Bay container satisfies containment on its
/// own but carries no BaseVoltage, so we follow cim:Bay.VoltageLevel to the
/// parent VoltageLevel (mirroring topology/cross_ref.zig). Any container that is
/// neither a VoltageLevel nor a Bay does not satisfy the containment clause.
fn resolve_container_base_voltage(model: Model, object: CimObject) ContainerBaseVoltage {
    const none: ContainerBaseVoltage = .{ .in_voltage_level_or_bay = false, .base_voltage = null };

    const container_ref = (object.reference("Equipment.EquipmentContainer") catch return none) orelse return none;
    const container = model.object_by_id(ids.strip_hash(container_ref)) orelse return none;

    if (std.mem.eql(u8, container.type_name(), "VoltageLevel")) {
        return .{ .in_voltage_level_or_bay = true, .base_voltage = voltage_level_base_voltage(container) };
    }

    if (std.mem.eql(u8, container.type_name(), "Bay")) {
        const voltage_level_ref = (container.reference("Bay.VoltageLevel") catch null) orelse
            return .{ .in_voltage_level_or_bay = true, .base_voltage = null };
        const voltage_level = model.object_by_id(ids.strip_hash(voltage_level_ref)) orelse
            return .{ .in_voltage_level_or_bay = true, .base_voltage = null };
        if (!std.mem.eql(u8, voltage_level.type_name(), "VoltageLevel"))
            return .{ .in_voltage_level_or_bay = true, .base_voltage = null };
        return .{ .in_voltage_level_or_bay = true, .base_voltage = voltage_level_base_voltage(voltage_level) };
    }

    return none;
}

fn voltage_level_base_voltage(voltage_level: CimObject) ?[]const u8 {
    const ref = (voltage_level.reference("VoltageLevel.BaseVoltage") catch return null) orelse return null;
    return ids.strip_hash(ref);
}

fn validate_boundary_point_text_length(model: Model, comptime property: []const u8, max_len: usize) !void {
    const boundary_points = model.objects_by_type("BoundaryPoint");
    for (boundary_points) |boundary_point| {
        const object = boundary_point;
        const value = object.property(property) catch {
            std.log.err("Failed to parse " ++ property ++ " of object '{s}'.", .{boundary_point.id()});
            return error.ParseFailed;
        } orelse {
            std.log.err("Object '{s}':", .{object.id()});
            return error.Missing;
        };
        if (value.len > max_len) {
            std.log.err("Object {s} name too long: {s}", .{ boundary_point.id(), value });
            return error.TooLong;
        }
    }
}

fn validate_boundary_node_country_code(model: Model, comptime property: []const u8) !void {
    const boundary_points = model.objects_by_type("BoundaryPoint");
    for (boundary_points) |boundary_point| {
        const object = boundary_point;
        const iso_country_code = object.property(property) catch {
            std.log.err("Failed to parse " ++ property ++ " of object '{s}'.", .{boundary_point.id()});
            return error.ParseFailed;
        } orelse {
            std.log.err("Object '{s}':", .{object.id()});
            return error.Missing;
        };
        _ = iso_country_codes.get(iso_country_code) orelse {
            std.log.err("Object '{s}':", .{object.id()});
            return error.UnknownCountryCode;
        };
    }
}

pub fn validate_containment(
    model: Model,
    types: []const []const u8,
    container_types: []const []const u8,
    container_required: bool,
    reference: []const u8,
) !void {
    var groups = model.type_groups();
    while (groups.next()) |group| {
        if (!matches_any_type(group.type_name, types)) continue;

        for (group.objects) |object_data| {
            const object = object_data;
            const container_ref = object.reference(reference) catch {
                std.log.err("Failed to parse '{s}' of object '{s}'.", .{ reference, object.id() });
                return error.ParseFailed;
            } orelse {
                if (container_required) return error.Missing else continue;
            };
            const container = model.object_by_id(ids.strip_hash(container_ref)) orelse return error.Missing;
            if (!matches_any_type(container.type_name(), container_types)) return error.WrongContainer;
        }
    }
}

fn matches_any_type(actual_type: []const u8, requested_types: []const []const u8) bool {
    for (requested_types) |requested_type| {
        if (cim_types.is_a(actual_type, requested_type)) return true;
    }
    return false;
}

// PERF (structural, not yet done): every validator below makes its own pass over
// the model. The type-filtered ones now scan type_groups (cheap: one predicate per
// distinct type), but the ~9 containment checks plus the name/power/voltage/terminal
// checks still traverse the object set once each. If this pipeline is hot, the next
// lever is a single fused pass that dispatches all applicable rules per type group,
// trading the per-validator cache sweeps for one. Measure on real NC grids before
// taking it on -- it couples otherwise-independent rules and is a real refactor.
fn validate_grid_model_constraints(
    gpa: std.mem.Allocator,
    model: Model,
    profile_part: ?cim.profile.Kind,
    reverse_ref_index: *const ReverseRefIndex,
) !void {
    try validate_name_length(model);
    try validate_description_length(model);
    try validate_energy_ident_coding_length(model);
    try validate_short_name_length(model);

    const resolved_profile = profile_part orelse return error.TooManyProfileParts;
    if (resolved_profile == .eqbd) {
        try validate_boundary_node_country_code_from(model);
        try validate_boundary_node_country_code_to(model);
        try validate_boundary_node_name_length_from(model);
        try validate_boundary_node_name_length_to(model);
        try validate_boundary_node_tso_name_length_from(model);
        try validate_boundary_node_tso_name_length_to(model);
    }

    try validate_generation_containment(model);
    try validate_power_transformer_containment(model);
    try validate_switch_containment(model);
    try validate_series_compensator_containment(model);
    try validate_injection_containment(model);
    try validate_busbar_section_containment(model);
    try validate_ground_containment(model);
    try validate_acdc_converter_containment(model);
    try validate_dc_equipment_containment(model);
    try validate_conn_node_containment(model, resolved_profile);

    try validate_nominal_power(model);
    try validate_conducting_equipment_base_voltage(model);
    try validate_nominal_voltage(model);
    try validate_terminal_count1(model, reverse_ref_index);
    try validate_terminal_count2(model, reverse_ref_index);
    try validate_terminal_seq_num(model, reverse_ref_index);
    try validate_terminal_seq_num_order(gpa, model, reverse_ref_index);
    try validate_power_transformer_terminal_consistency(model);
    try validate_mutual_coupling_order(model);
    try validate_load_response_characteristic_exponent_model(model);
}

fn filename_stem_from_path(file_path: []const u8) []const u8 {
    const filename_with_extension = std.fs.path.basename(file_path);
    return std.fs.path.stem(filename_with_extension);
}

pub fn validate_filename(file_path: []const u8) !void {
    const filename = filename_stem_from_path(file_path);
    const filename_parsed = try parse_filename(filename);
    try validate_filename_parts(filename_parsed);
}

fn validate_filename_parts(filename: Filename) !void {
    try validate_effective_datetime(filename);
    try validate_sourcing_actor(filename);
    try validate_cgm_region(filename);
    try validate_business_process(filename);
    try validate_model_part(filename);
    try validate_file_version(filename);
}

pub fn validate(io: std.Io, gpa: std.mem.Allocator, file_path: []const u8) !void {
    const filename = filename_stem_from_path(file_path);
    validate_filename_consistency(io, file_path) catch |err| {
        switch (err) {
            error.FileNameConsistency => print.data_error(
                io,
                "qocdc: XML entry name differs from ZIP container name '{s}'",
                .{filename},
            ),
            error.NotZipArchive => print.data_error(
                io,
                "qocdc: input '{s}' is not a ZIP archive",
                .{file_path},
            ),
            error.ZipInsufficientBuffer => print.data_error(
                io,
                "qocdc: ZIP entry name exceeds the supported path length",
                .{},
            ),
            else => return err,
        }
    };

    const filename_parsed = parse_filename(filename) catch
        print.data_error(io, "qocdc: the structure of filename '{s}' does not match the rules", .{filename});

    validate_filename_parts(filename_parsed) catch |err| {
        switch (err) {
            error.EffectiveDateTime => print.data_error(
                io,
                "qocdc: EffectiveDateTime '{s}' in the filename is invalid",
                .{filename_parsed.effective_date_time},
            ),
            error.SourcingActor => print.data_error(
                io,
                "qocdc: sourcingRSC or sourcingTSO '{s}' is absent from the QoCDC reference data",
                .{filename_parsed.sourcing_actor},
            ),
            error.CGMRegion => print.data_error(
                io,
                "qocdc: cgmRegion in sourcing actor '{s}' is absent from the QoCDC reference data",
                .{filename_parsed.sourcing_actor},
            ),
            error.BusinessProcess => {
                if (filename_parsed.business_process) |business_process| {
                    print.data_error(io, "qocdc: unknown business process '{s}'", .{business_process});
                }
                unreachable;
            },
            error.ModelPartType => print.data_error(
                io,
                "qocdc: unknown modelPart type '{s}' in the filename",
                .{filename_parsed.model_part},
            ),
            error.FileVersion => print.data_error(
                io,
                "qocdc: invalid fileVersion '{s}' in the filename",
                .{filename_parsed.file_version},
            ),
        }
    };

    var model = try Model.init(gpa, try read_path(io, gpa, file_path));
    defer model.deinit(gpa);

    var reverse_ref_index = try ReverseRefIndex.build(gpa, &model);
    defer reverse_ref_index.deinit(gpa);

    // Reuse the router's header classifier rather than re-deriving the kind by
    // walking parsed FullModel objects. An unresolved profile (unknown URI,
    // absent, or a malformed/ambiguous header) becomes null, which
    // validate_grid_model_constraints reports as TooManyProfileParts.
    const profile_part: ?cim.profile.Kind = if (cim.profile.classify(gpa, model.xml)) |header|
        switch (header.profile) {
            .known => |kind| kind,
            .unknown, .absent => null,
        }
    else |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };

    validate_grid_model_constraints(gpa, model, profile_part, &reverse_ref_index) catch |err| {
        if (err == error.OutOfMemory) return err;
        print.data_error(io, "qocdc: {s}", .{grid_model_error_message(err)});
    };
}

fn grid_model_error_message(err: anyerror) []const u8 {
    return switch (err) {
        error.MalformedTag => "failed to parse a CIM property",
        error.NameLength => "an IdentifiedObject.name is missing, empty, or too long",
        error.DescriptionLength => "an IdentifiedObject.description is too long",
        error.EICLength => "an energyIdentCodeEic does not have exactly 16 characters",
        error.ShortNameLength => "an IdentifiedObject.shortName is too long",
        error.TooManyProfileParts => "expected exactly one recognized CGMES profile kind",
        error.CNFromEndIsoCode, error.CNToEndIsoCode => "a boundary-point country code is invalid",
        error.CNFromEndNameLength,
        error.CNToEndNameLength,
        error.CNFromEndNameTsoLength,
        error.CNToEndNameTsoLength,
        => "a boundary-point name is missing or too long",
        error.GenerationContainment => "a HydroPump or GeneratingUnit has invalid containment",
        error.PTContainment => "a PowerTransformer has invalid containment",
        error.SwitchContainment => "a Switch has invalid containment",
        error.SCContainment => "a SeriesCompensator has invalid containment",
        error.InjectionContainment => "a power injection has invalid containment",
        error.BusbarSectionContainment => "a BusbarSection has invalid containment",
        error.EFCContainment => "a Ground or EarthFaultCompensator has invalid containment",
        error.ACDCConvContainment => "an ACDCConverter has invalid containment",
        error.DCEQContainment => "a DC equipment object has invalid containment",
        error.CNContainment => "a ConnectivityNode has invalid containment",
        error.GeneratingUnitNominalP => "a GeneratingUnit nominalP value is invalid",
        error.CEBaseVoltage => "a ConductingEquipment BaseVoltage association is invalid",
        error.NominalVoltage => "a BaseVoltage nominalVoltage is not greater than zero",
        error.TerminalCount1 => "a single terminal equipment that is referenced by multiple terminals",
        error.TerminalCount2 => "a two terminal equipment that is not referenced by exactly two terminals.",
        error.TerminalSeqNum => "a cim:Terminal of either an cim:EquivalentBranch or a cim:ACLineSegment with cim:MutualCoupling that does not have a sequence number declared.",
        error.TerminalSeqNumOrder => "invalid sequenceNumber for a cim:Terminal.",
        error.PTTerminalConsistency => "assignment of PowerTransformer's terminals is not consistent.",
        error.MCFirstSecond =>
        \\one of the following occurs:
        \\1) cim:MutualCoupling.First_Terminal does not refer to a cim:Terminal of a cim:ACLineSegment,
        \\2) cim:MutualCoupling.Second_Terminal does not refer to a cim:Terminal of a cim:ACLineSegment,
        \\3) cim:MutualCoupling.First_Terminal and cim:MutualCoupling.Second_Terminal do not refer to cim:Terminals of different cim:ACLineSegments.
        ,
        error.LRCExponentModel => "Exponent of per unit voltage effecting real and reactive power is not specified but " ++
            "cim:LoadResponseCharacteristic.exponentModel is true.",
        else => @errorName(err),
    };
}

test "TerminalCount2 diagnostic describes the exact count requirement" {
    try std.testing.expectEqualStrings(
        "a two terminal equipment that is not referenced by exactly two terminals.",
        grid_model_error_message(error.TerminalCount2),
    );
}
