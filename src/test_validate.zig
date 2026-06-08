const std = @import("std");
const parse_filename = @import("validate.zig").parse_filename;
const validate = @import("validate.zig");
const check_filename_consistency = validate.check_filename_consistency;
const check_effective_datetime = validate.check_effective_datetime;
const validate_sourcing_actor = validate.validate_sourcing_actor;
const validate_cgm_region = validate.validate_cgm_region;
const validate_business_process = validate.validate_business_process;
const validate_model_part = validate.validate_model_part;
const validate_file_version = validate.validate_file_version;

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

test "FileNameConsistency" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const empty_zip = [_]u8{
        // Local file header (30 + 15 = 45 bytes)
        0x50, 0x4B, 0x03, 0x04, // signature
        0x14, 0x00, // version needed
        0x00, 0x00, // flags
        0x00, 0x00, // compression: stored
        0x00, 0x00, // mod time
        0x00, 0x00, // mod date
        0x00, 0x00, 0x00, 0x00, // CRC-32
        0x00, 0x00, 0x00, 0x00, // compressed size
        0x00, 0x00, 0x00, 0x00, // uncompressed size
        0x0F, 0x00, // filename length = 15
        0x00, 0x00, // extra field length = 0
        'm',  'y',
        '_',  'f',
        'i',  'l',
        'e',  'n',
        'a',  'm',
        'e',  '.',
        'z',  'i',
        'p',

        // Central directory entry (46 + 15 = 61 bytes, starts at offset 45)
        0x50, 0x4B, 0x01, 0x02, // signature
        0x14, 0x00, // version made by
        0x14, 0x00, // version needed
        0x00, 0x00, // flags
        0x00, 0x00, // compression
        0x00, 0x00, // mod time
        0x00, 0x00, // mod date
        0x00, 0x00, 0x00, 0x00, // CRC-32
        0x00, 0x00, 0x00, 0x00, // compressed size
        0x00, 0x00, 0x00, 0x00, // uncompressed size
        0x0F, 0x00, // filename length = 15
        0x00, 0x00, // extra field length = 0
        0x00, 0x00, // file comment length = 0
        0x00, 0x00, // disk number start
        0x00, 0x00, // internal file attributes
        0x00, 0x00, 0x00, 0x00, // external file attributes
        0x00, 0x00, 0x00, 0x00, // offset of local header = 0
        'm',  'y',  '_',  'f',
        'i',  'l',  'e',  'n',
        'a',  'm',  'e',  '.',
        'z',  'i',  'p',

        // EOCD (starts at offset 106)
        0x50, 0x4B, 0x05, 0x06, // signature
        0x00, 0x00, // disk number
        0x00, 0x00, // disk with CD start
        0x01, 0x00, // entries this disk = 1
        0x01, 0x00, // total entries = 1
        0x3D, 0x00, 0x00, 0x00, // CD size = 61
        0x2D, 0x00, 0x00, 0x00, // CD offset = 45
        0x00, 0x00, // comment length = 0
    };

    const io = std.testing.io;
    const filename = "my_filename.zip";
    var out_buffer: [1024]u8 = undefined;
    var file = try tmpdir.dir.createFile(io, filename, .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, &empty_zip);

    const length = try file.realPath(io, &out_buffer);
    const file_path = out_buffer[0..length];

    try check_filename_consistency(io, file_path);
}

test "EffectiveDateTime" {
    const correct_filename_template1: []const u8 = "20260603T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try check_effective_datetime(filename1);

    const filename_template_incorrect1: []const u8 = "2026060ET1325Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename2 = try parse_filename(filename_template_incorrect1);
    try std.testing.expectError(error.EffectiveDateTime, check_effective_datetime(filename2));

    const filename_template_incorrect2: []const u8 = "20260603T132540Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename3 = try parse_filename(filename_template_incorrect2);
    try std.testing.expectError(error.EffectiveDateTime, check_effective_datetime(filename3));
}

test "SourcingActor" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_businessProcess_TTN_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try validate_sourcing_actor(filename1);

    const correct_filename_template2: []const u8 = "effectiveDateTime_businessProcess_sourcingRSC-cgmRegion_modelPart_fileVersion";
    const filename2 = try parse_filename(correct_filename_template2);
    try validate_sourcing_actor(filename2);

    const incorrect_filename_template: []const u8 = "effectiveDateTime_businessProcess_doesnotexist_modelPart_fileVersion";
    const filename3 = try parse_filename(incorrect_filename_template);
    try std.testing.expectError(error.SourcingActor, validate_sourcing_actor(filename3));

    const incorrect_filename_template1: []const u8 = "effectiveDateTime_businessProcess_TTN2electricboogaloo_modelPart_fileVersion";
    const filename4 = try parse_filename(incorrect_filename_template1);
    try std.testing.expectError(error.SourcingActor, validate_sourcing_actor(filename4));

    const correct_filename_template3: []const u8 = "effectiveDateTime_businessProcess_BALTIC-cgmRegion-TTN_modelPart_fileVersion";
    const filename5 = try parse_filename(correct_filename_template3);
    try validate_sourcing_actor(filename5);

    const incorrect_filename_template2: []const u8 = "effectiveDateTime_businessProcess_BALTIC-cgmRegion-doesnotexist_modelPart_fileVersion";
    const filename6 = try parse_filename(incorrect_filename_template2);
    try std.testing.expectError(error.SourcingActor, validate_sourcing_actor(filename6));

    const incorrect_filename_template4: []const u8 = "effectiveDateTime_businessProcess_doesnotexit-cgmRegion-TTN_modelPart_fileVersion";
    const filename7 = try parse_filename(incorrect_filename_template4);
    try std.testing.expectError(error.SourcingActor, validate_sourcing_actor(filename7));
}

test "CGMRegion" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingRSC-EU_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try validate_cgm_region(filename1);

    const incorrect_filename_template1: []const u8 = "effectiveDateTime_businessProcess_EU-sourcingRSC_modelPart_fileVersion";
    const filename2 = try parse_filename(incorrect_filename_template1);
    try std.testing.expectError(error.CGMRegion, validate_cgm_region(filename2));
}

test "BusinessProcess" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_1D_TTN_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try validate_business_process(filename1);

    const incorrect_filename_template1: []const u8 = "effectiveDateTime_8D_TTN_modelPart_fileVersion";
    const filename2 = try parse_filename(incorrect_filename_template1);
    try std.testing.expectError(error.BusinessProcess, validate_business_process(filename2));
}

test "ModelPartType" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_EQ_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try validate_model_part(filename1);

    const incorrect_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_CO_fileVersion";
    const filename2 = try parse_filename(incorrect_filename_template1);
    try std.testing.expectError(error.ModelPartType, validate_model_part(filename2));
}

test "FileVersionType" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_modelPart_003";
    const filename1 = try parse_filename(correct_filename_template1);
    try validate_file_version(filename1);

    const incorrect_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_modelPart_1000";
    const filename2 = try parse_filename(incorrect_filename_template1);
    try std.testing.expectError(error.FileVersion, validate_file_version(filename2));

    const incorrect_filename_template2: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_modelPart_abc";
    const filename3 = try parse_filename(incorrect_filename_template2);
    try std.testing.expectError(error.FileVersion, validate_file_version(filename3));
}
