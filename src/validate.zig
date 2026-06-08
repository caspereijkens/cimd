const std = @import("std");
const print = @import("io/print.zig");
const zip = @import("io/zip.zig");

const assert = std.debug.assert;

// QoCDC §5.3 Rules' Constants.
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
// const io_name_chars_max: u32 = 32; // IO_NAME_LENGTH
// const io_description_chars_max: u32 = 256; // IO_DESCRIPTION_LENGTH
// const eic_chars_max: u32 = 16; // EIC_LENGTH
// const short_name_chars_max: u32 = 12; // SHORT_NAME_LENGTH
// const boundary_bv_diff_factor_max: f64 = 0.1; // BOUNDARY_BV_MAX_DIFF
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
const allowed_sourcing_tsos = std.StaticStringMap(void).initComptime(.{
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
const allowed_sourcing_cgm_regions = std.StaticStringMap(void).initComptime(.{
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
const allowed_sourcing_rscs = std.StaticStringMap(void).initComptime(.{
    .{ "BALTIC", {} },
    .{ "CORESO", {} },
    .{ "TSCNET", {} },
    .{ "SCC", {} },
    .{ "NORDIC", {} },
    .{ "SEleNeCC", {} },
});

const allowed_business_processes = std.StaticStringMap(void).initComptime(.{
    .{ "RT", {} },
    .{ "TY", {} },
    .{ "YR", {} },
    .{ "MO", {} },
    .{ "WK", {} },
    .{ "2D", {} },
    .{ "1D", {} },
    .{ "ID", {} },
    .{ "1", {} },
    .{ "2", {} },
    .{ "3", {} },
    .{ "4", {} },
    .{ "5", {} },
    .{ "6", {} },
    .{ "7", {} },
    .{ "8", {} },
    .{ "9", {} },
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
    .{ "3D", {} },
    .{ "4D", {} },
    .{ "5D", {} },
    .{ "6D", {} },
    .{ "7D", {} },
});

const allowed_model_parts = std.StaticStringMap(void).initComptime(.{
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

pub fn check_filename_consistency(io: std.Io, file_path: []const u8) !void {
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
            try print.stderr_info(io, "XML instance file name '{s}' is different from zip container file name '{s}'.\n", .{ filename, zip_filename });
            return error.FileNameConsistency;
        }
    } else {
        try print.stderr_info(io, "file '{s}' is not contained in a single zip.", .{file_path});
        return error.FileNameConsistency;
    }
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

    var iter = std.mem.tokenizeAny(u8, date_time, "TZ");
    const date = iter.next() orelse return error.EffectiveDateTime;
    if (date.len != 8) {
        return error.EffectiveDateTime;
    }
    const time = iter.next() orelse return error.EffectiveDateTime;
    if (time.len != 4) {
        return error.EffectiveDateTime;
    }

    _ = std.fmt.parseInt(u32, date, 10) catch {
        return error.EffectiveDateTime;
    };
    _ = std.fmt.parseInt(u32, time[0..4], 10) catch {
        return error.EffectiveDateTime;
    };
}

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
    if (business_process_opt) |business_process| {
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
/// represented by three numeric characters ranging from 000 to 999, i.e. the
/// first positive integer is 001 and the last 999. Leading zeros are allowed.
pub fn validate_file_version(filename: Filename) !void {
    if (filename.file_version.len != 3) return error.FileVersion;
    const file_version = std.fmt.parseInt(u16, filename.file_version, 10) catch return error.FileVersion;
    if (file_version > 999) {
        return error.FileVersion;
    }
    return;
}

pub fn validate(io: std.Io, file_path: []const u8) !void {
    const filename = std.fs.path.basename(file_path);
    const filename_parsed = parse_filename(filename) catch |e| {
        try print.stderr_info(io, "The structure of the filename '{s}' does not match the rules.\n", .{filename});
        return e;
    };

    check_filename_consistency(io, file_path) catch |e| {
        try print.stderr_info(io, "XML instance file name is different from zip container file name '{s}'.", .{filename});
        return e;
    };

    check_effective_datetime(filename_parsed) catch |e| {
        try print.stderr_info(io, "EffectiveDateTime '{s}' in file name is invalid.", .{filename_parsed.effective_date_time});
        return e;
    };

    validate_sourcing_actor(filename_parsed) catch |e| {
        try print.stderr_info(io, "sourcingRSC or/and sourcingTSO parts '{s}' of the file name has/have value(s) that are not included in the QoCDC Reference Data document.", .{filename_parsed.sourcing_actor});
        return e;
    };

    validate_cgm_region(filename_parsed) catch |e| {
        try print.stderr_info(io, "cgmRegion part '{s}' of the file name has value that is not included in the QoCDC Reference Data document.", .{filename_parsed.sourcing_actor});
        return e;
    };

    validate_business_process(filename_parsed) catch |e| {
        if (filename_parsed.business_process) |business_process| {
            try print.stderr_info(io, "Unknown business process '{s}'.", .{business_process});
        }
        return e;
    };

    validate_model_part(filename_parsed) catch |e| {
        try print.stderr_info(io, "Unknown modelPart type '{s}' in the filename.", .{filename_parsed.model_part});
        return e;
    };
}
