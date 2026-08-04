//! Filename-rule tests, ported from the pre-redesign suite: same fixtures
//! and intents, asserted against the collected report instead of a first
//! error. ZIP handling moved to the application, so FileNameConsistency is
//! tested over stems here and end-to-end in test_cli.zig.

const std = @import("std");

const qocdc = @import("qocdc.zig");
const filename_mod = @import("filename.zig");

const parse_filename = qocdc.parse_filename;
const gpa = std.testing.allocator;

fn run(stem: []const u8, zip_entry_stem: ?[]const u8) !qocdc.Report {
    var report: qocdc.Report = .empty;
    errdefer report.deinit(gpa);
    try qocdc.validate_filename(&report, gpa, stem, zip_entry_stem);
    return report;
}

fn expect_only(report: *const qocdc.Report, rule: qocdc.Rule, count: u32) !void {
    try std.testing.expectEqual(count, report.count(rule));
    try std.testing.expectEqual(@as(u64, count), report.total());
}

fn expect_clean(report: *const qocdc.Report) !void {
    try std.testing.expectEqual(@as(u64, 0), report.total());
}

test "FileNameMD" {
    // Used for EQ (also correct_filename_template2), SSH, TP and SV.
    const filename1 = try parse_filename("effectiveDateTime_businessProcess_sourcingTSO_modelPart_fileVersion");
    try std.testing.expectEqualStrings(filename1.business_process.?, "businessProcess");

    // Used for EQ (also correct_filename_template1), EQBD and TPBD.
    const filename2 = try parse_filename("effectiveDateTime__sourcingTSO_modelPart_fileVersion");
    try std.testing.expectEqual(filename2.business_process, null);

    // Some variations of sourcingActor
    const filename3 = try parse_filename("effectiveDateTime__sourcingRSC-cgmRegion_modelPart_fileVersion");
    try std.testing.expectEqualStrings(filename3.sourcing_actor, "sourcingRSC-cgmRegion");

    const filename4 = try parse_filename("effectiveDateTime__sourcingRSC-cgmRegion-sourcingTSO_modelPart_fileVersion");
    try std.testing.expectEqualStrings(filename4.sourcing_actor, "sourcingRSC-cgmRegion-sourcingTSO");

    // Unhappy cases
    try std.testing.expectError(error.FileNameMD, parse_filename("____"));
    try std.testing.expectError(error.FileNameMD, parse_filename("effectiveDateTime_sourcingTSO_modelPart_fileVersion"));
    try std.testing.expectError(error.FileNameMD, parse_filename("effectiveDateTime_sourcingTSO__fileVersion"));
    // sourcingActor is at most three '-'-separated fields.
    try std.testing.expectError(error.FileNameMD, parse_filename("effectiveDateTime__a-b-c-d_modelPart_fileVersion"));
}

test "FileNameMD: an unparseable stem reports once and skips per-field rules" {
    var report = try run("not-a-valid-stem", null);
    defer report.deinit(gpa);
    try expect_only(&report, .FileNameMD, 1);
    try std.testing.expectEqualStrings("not-a-valid-stem", report.violations.items[0].detail);
}

test "FileNameConsistency compares stems and reports the entry stem" {
    var clean = try run("20260603T1325Z_1D_TTN_EQ_001", "20260603T1325Z_1D_TTN_EQ_001");
    defer clean.deinit(gpa);
    try expect_clean(&clean);

    var mismatched: qocdc.Report = .empty;
    defer mismatched.deinit(gpa);
    try qocdc.check_filename_consistency(&mismatched, gpa, "20260603T1325Z_1D_TTN_EQ_001", "other_name");
    try expect_only(&mismatched, .FileNameConsistency, 1);
    try std.testing.expectEqualStrings("other_name", mismatched.violations.items[0].detail);
}

test "EffectiveDateTime" {
    const accept = [_][]const u8{
        "20260603T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion",
        // Leap day.
        "20240229T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion",
    };
    for (accept) |stem| {
        try filename_mod.check_effective_datetime(try parse_filename(stem));
    }

    const reject = [_][]const u8{
        "2026060ET1325Z_businessProcess_sourcingTSO_modelPart_fileVersion", // non-digit
        "20260603T132540Z_businessProcess_sourcingTSO_modelPart_fileVersion", // seconds
        "20260603Z1325T_businessProcess_sourcingTSO_modelPart_fileVersion", // swapped designators
        "20261303T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion", // month 13
        "20230229T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion", // non-leap Feb 29
        "20260603T2460Z_businessProcess_sourcingTSO_modelPart_fileVersion", // minute 60
    };
    for (reject) |stem| {
        try std.testing.expectError(
            error.EffectiveDateTime,
            filename_mod.check_effective_datetime(try parse_filename(stem)),
        );
    }
}

test "SourcingActor" {
    const accept = [_][]const u8{
        "effectiveDateTime_businessProcess_TTN_modelPart_fileVersion",
        "effectiveDateTime_businessProcess_BALTIC-EU_modelPart_fileVersion",
        // Case-insensitive per QoCDC.
        "effectiveDateTime_businessProcess_baltic-eu-ttn_modelPart_fileVersion",
        "effectiveDateTime_businessProcess_BALTIC-cgmRegion-TTN_modelPart_fileVersion",
    };
    for (accept) |stem| {
        try filename_mod.check_sourcing_actor(try parse_filename(stem));
    }

    const reject = [_][]const u8{
        "effectiveDateTime_businessProcess_doesnotexist_modelPart_fileVersion",
        "effectiveDateTime_businessProcess_TTN2electricboogaloo_modelPart_fileVersion",
        "effectiveDateTime_businessProcess_BALTIC-cgmRegion-doesnotexist_modelPart_fileVersion",
        "effectiveDateTime_businessProcess_doesnotexit-cgmRegion-TTN_modelPart_fileVersion",
        "effectiveDateTime_businessProcess_doesnotexist-EU_modelPart_fileVersion",
    };
    for (reject) |stem| {
        try std.testing.expectError(
            error.SourcingActor,
            filename_mod.check_sourcing_actor(try parse_filename(stem)),
        );
    }
}

test "CGMRegion" {
    try filename_mod.check_cgm_region(try parse_filename(
        "effectiveDateTime_businessProcess_sourcingRSC-EU_modelPart_fileVersion",
    ));
    try filename_mod.check_cgm_region(try parse_filename(
        "effectiveDateTime_businessProcess_baltic-eu-ttn_modelPart_fileVersion",
    ));
    try std.testing.expectError(error.CGMRegion, filename_mod.check_cgm_region(try parse_filename(
        "effectiveDateTime_businessProcess_EU-sourcingRSC_modelPart_fileVersion",
    )));
}

test "BusinessProcess" {
    try filename_mod.check_business_process(try parse_filename(
        "effectiveDateTime_1D_TTN_modelPart_fileVersion",
    ));
    // Case-insensitive per QoCDC.
    try filename_mod.check_business_process(try parse_filename(
        "effectiveDateTime_1d_TTN_modelPart_fileVersion",
    ));
    try std.testing.expectError(error.BusinessProcess, filename_mod.check_business_process(try parse_filename(
        "effectiveDateTime_8D_TTN_modelPart_fileVersion",
    )));
}

test "ModelPartType" {
    try filename_mod.check_model_part(try parse_filename(
        "effectiveDateTime_businessProcess_sourcingProcess_EQ_fileVersion",
    ));
    // Case-insensitive per QoCDC.
    try filename_mod.check_model_part(try parse_filename(
        "effectiveDateTime_businessProcess_sourcingProcess_eq_fileVersion",
    ));
    try std.testing.expectError(error.ModelPartType, filename_mod.check_model_part(try parse_filename(
        "effectiveDateTime_businessProcess_sourcingProcess_CO_fileVersion",
    )));
}

test "FileVersionType" {
    try filename_mod.check_file_version(try parse_filename(
        "effectiveDateTime_businessProcess_sourcingProcess_modelPart_003",
    ));
    const reject = [_][]const u8{
        "effectiveDateTime_businessProcess_sourcingProcess_modelPart_1000",
        "effectiveDateTime_businessProcess_sourcingProcess_modelPart_abc",
        "effectiveDateTime_businessProcess_sourcingProcess_modelPart_000",
    };
    for (reject) |stem| {
        try std.testing.expectError(
            error.FileVersion,
            filename_mod.check_file_version(try parse_filename(stem)),
        );
    }
}

test "validate_filename accepts a fully valid stem" {
    var report = try run("20260603T1325Z_1D_TTN_EQ_001", "20260603T1325Z_1D_TTN_EQ_001");
    defer report.deinit(gpa);
    try expect_clean(&report);
}

test "validate_filename collects every failing rule in one run" {
    // Bad datetime, unknown actor, unknown model part, bad version -- all in
    // one stem; the old pipeline stopped at the first.
    var report = try run("20261303T1325Z_zz_NOPE_XX_000", null);
    defer report.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), report.count(.EffectiveDateTime));
    try std.testing.expectEqual(@as(u32, 1), report.count(.SourcingActor));
    try std.testing.expectEqual(@as(u32, 1), report.count(.BusinessProcess));
    try std.testing.expectEqual(@as(u32, 1), report.count(.ModelPartType));
    try std.testing.expectEqual(@as(u32, 1), report.count(.FileVersion));
    try std.testing.expectEqual(@as(u64, 5), report.total());
}

test "validate_filename reports the offending fragment as detail" {
    var report = try run("20260603T1325Z_1D_TTN_EQ_000", null);
    defer report.deinit(gpa);
    try expect_only(&report, .FileVersion, 1);
    const violation = report.violations.items[0];
    try std.testing.expectEqualStrings("000", violation.detail);
    try std.testing.expectEqual(qocdc.no_offset, violation.offset);
}
