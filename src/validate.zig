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

const Filename = struct {
    effective_date_time: []const u8,
    business_process: ?[]const u8,
    sourcing_actor: []const u8,
    model_part: []const u8,
    file_version: []const u8,
};

test "FileNameMD" {
    // Used for EQ (also correct_filename_template2), SSH, TP and SV.
    const correct_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try std.testing.expectEqualStrings(filename1.business_process.?, "businessProcess");

    // Used for EQ(also correct_filename_template1), EQBD and TPBD.
    const correct_filename_template2: []const u8 = "effectiveDateTime__sourcingTSO_modelPart_fileVersion";
    const filename2 = try parse_filename(correct_filename_template2);
    try std.testing.expectEqual(filename2.business_process, null);

    // Some variations of sourcingActor
    const correct_filename_template3: []const u8 = "effectiveDateTime__sourcingRSC-cgmRegion_modelPart_fileVersion";
    const filename3 = try parse_filename(correct_filename_template3);
    try std.testing.expectEqualStrings(filename3.sourcing_actor, "sourcingRSC-cgmRegion");

    const correct_filename_template4: []const u8 = "effectiveDateTime__sourcingRSC-cgmRegion-sourcingTSO_modelPart_fileVersion";
    const filename4 = try parse_filename(correct_filename_template4);
    try std.testing.expectEqualStrings(filename4.sourcing_actor, "sourcingRSC-cgmRegion-sourcingTSO");

    // Unhappy cases
    const empty_filename: []const u8 = "____";
    try std.testing.expectError(error.FileNameMD, parse_filename(empty_filename));

    const missing_underscore: []const u8 = "effectiveDateTime_sourcingTSO_modelPart_fileVersion";
    try std.testing.expectError(error.FileNameMD, parse_filename(missing_underscore));

    const empty_model_part: []const u8 = "effectiveDateTime_sourcingTSO__fileVersion";
    try std.testing.expectError(error.FileNameMD, parse_filename(empty_model_part));
}

fn parse_filename(filename: []const u8) !Filename {
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

fn check_filename_consistency(io: std.Io, file_path: []const u8) !void {
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
            std.debug.print("XML instance file name '{s}' is different from zip container file name '{s}'.\n", .{ filename, zip_filename });
            return error.FileNameConsistency;
        }
    } else {
        try print.stderr_info(io, "file '{s}' is not contained in a single zip.", .{file_path});
        return error.FileNameConsistency;
    }
}

pub fn validate(io: std.Io, file_path: []const u8) !void {
    const filename = std.fs.path.basename(file_path);
    _ = parse_filename(filename) catch {
        try print.stderr_info(io, "The structure of the filename '{s}' does not match the rules.\n", .{filename});
        return error.FileNameMD;
    };

    check_filename_consistency(io, file_path) catch |err| switch (err) {
        error.FileNameConsistency => {
            try print.stderr_info(io, "XML instance file name is different from zip container file name.", .{});
        },
        else => return err,
    };
}
