//! Filename-level QoCDC rules (level 1), evaluated over the file-name stem.
//!
//! Pure string checks: the caller extracts the stem (and, for
//! FileNameConsistency, the ZIP entry's stem) -- opening files stays outside
//! the library. Every check runs and reports; nothing aborts the chain.

const std = @import("std");
const assert = std.debug.assert;

const data = @import("reference_data.zig");
const report_mod = @import("report.zig");

const Report = report_mod.Report;
const no_offset = report_mod.no_offset;

pub const Filename = struct {
    effective_date_time: []const u8,
    business_process: ?[]const u8,
    sourcing_actor: []const u8,
    model_part: []const u8,
    file_version: []const u8,
};

pub fn parse_filename(filename: []const u8) error{FileNameMD}!Filename {
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
    // sourcingActor is at most three '-'-separated fields per FileNameMD.
    // (The pre-redesign code counted '>' here -- a dead check, since a file
    // name never contains one; '-' is what the template separates on.)
    if (std.mem.countScalar(u8, sourcing_actor, '-') > 2) {
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

/// All filename rules over a stem. `zip_entry_stem` is the stem of the ZIP
/// archive's single entry when the caller read one (FileNameConsistency);
/// null skips that check. Both slices must outlive the report.
pub fn validate(
    report: *Report,
    gpa: std.mem.Allocator,
    stem: []const u8,
    zip_entry_stem: ?[]const u8,
) error{OutOfMemory}!void {
    if (zip_entry_stem) |entry_stem| try check_consistency(report, gpa, stem, entry_stem);

    const parsed = parse_filename(stem) catch {
        // Without the five fields none of the per-field rules can run.
        try add(report, gpa, .FileNameMD, stem);
        return;
    };
    if (check_effective_datetime(parsed)) |_| {} else |_| {
        try add(report, gpa, .EffectiveDateTime, parsed.effective_date_time);
    }
    if (check_sourcing_actor(parsed)) |_| {} else |_| {
        try add(report, gpa, .SourcingActor, parsed.sourcing_actor);
    }
    if (check_cgm_region(parsed)) |_| {} else |_| {
        try add(report, gpa, .CGMRegion, parsed.sourcing_actor);
    }
    if (check_business_process(parsed)) |_| {} else |_| {
        try add(report, gpa, .BusinessProcess, parsed.business_process orelse "");
    }
    if (check_model_part(parsed)) |_| {} else |_| {
        try add(report, gpa, .ModelPartType, parsed.model_part);
    }
    if (check_file_version(parsed)) |_| {} else |_| {
        try add(report, gpa, .FileVersion, parsed.file_version);
    }
}

/// FileNameConsistency: the XML entry inside the ZIP container carries the
/// same stem as the container itself.
pub fn check_consistency(
    report: *Report,
    gpa: std.mem.Allocator,
    zip_stem: []const u8,
    entry_stem: []const u8,
) error{OutOfMemory}!void {
    if (!std.mem.eql(u8, zip_stem, entry_stem)) {
        try add(report, gpa, .FileNameConsistency, entry_stem);
    }
}

fn add(
    report: *Report,
    gpa: std.mem.Allocator,
    rule: report_mod.Rule,
    detail: []const u8,
) error{OutOfMemory}!void {
    try report.add(gpa, .{ .rule = rule, .offset = no_offset, .object_id = "", .detail = detail });
}

fn is_digits(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

/// The 'effectiveDateTime' in the file name must be a valid datetime in minute
/// resolution in accordance with ISO 8601-2005, basic format with time
/// designator [T] between date and time and ending with UTC designator [Z]. For
/// example, 20180118T1130Z. Use of other date/time specifiers by characters
/// [:.-+YMDHSWP] is not allowed.
pub fn check_effective_datetime(filename: Filename) error{EffectiveDateTime}!void {
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

/// The sourcingActor, that appears in the cimxml file name, is composed as
/// described in rule FileNameMD. The choice on sourcingActor is made by the
/// responsible TSO and it is recorded in the QoCDC Reference Data document.
/// Once decided the sourcingActor should comply with the defined names in the
/// QoCDC Reference Data document. This rule checks if the values of the
/// following fields "sourcingRSC" and "sourcingTSO" from the sourcingActor
/// part of the file name is one of the allowed values in the QoCDC Reference
/// Data document. The rule does not check the field "cgmRegion".
pub fn check_sourcing_actor(filename: Filename) error{SourcingActor}!void {
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
            _ = data.allowed_sourcing_tsos.get(sourcing_tso) orelse return error.SourcingActor;
            return;
        },
        2 => {
            const sourcing_rsc = iter.next() orelse return error.SourcingActor;
            _ = data.allowed_sourcing_rscs.get(sourcing_rsc) orelse return error.SourcingActor;
            return;
        },
        3 => {
            const sourcing_rsc = iter.next() orelse return error.SourcingActor;
            _ = data.allowed_sourcing_rscs.get(sourcing_rsc) orelse return error.SourcingActor;
            _ = iter.next();
            const sourcing_tso = iter.next() orelse return error.SourcingActor;
            _ = data.allowed_sourcing_tsos.get(sourcing_tso) orelse return error.SourcingActor;
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
pub fn check_cgm_region(filename: Filename) error{CGMRegion}!void {
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
            _ = data.allowed_sourcing_cgm_regions.get(cgm_region) orelse return error.CGMRegion;
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
pub fn check_business_process(filename: Filename) error{BusinessProcess}!void {
    // TODO check profile part because:
    // - EQ shall use both template 1 and 2;
    // - SSH, TP and SV shall only use template 1;
    // - EQBD and TPBD shall only use template 2.
    if (filename.business_process) |business_process| {
        if (business_process.len != 2) {
            return error.BusinessProcess;
        }
        _ = data.allowed_business_processes.get(business_process) orelse return error.BusinessProcess;
    }
}

/// The 'modelPart' in the file name is restricted. Note that the profile
/// declarations in the file header are leading and shall be used as meta data
/// to request data. The allowed model part types are as follows: DL, DY, EQ,
/// EQBD, EQDIFF, GL, SSH, SV, TP, TPBD.
pub fn check_model_part(filename: Filename) error{ModelPartType}!void {
    _ = data.allowed_model_parts.get(filename.model_part) orelse return error.ModelPartType;
}

/// The 'fileVersion' in the file name must be positive integer value always
/// represented by three numeric characters ranging from 001 to 999. Leading
/// zeros are allowed.
pub fn check_file_version(filename: Filename) error{FileVersion}!void {
    if (filename.file_version.len != 3) return error.FileVersion;
    const file_version = std.fmt.parseInt(u16, filename.file_version, 10) catch return error.FileVersion;
    if (file_version == 0) {
        return error.FileVersion;
    }
    if (file_version > 999) {
        return error.FileVersion;
    }
}
