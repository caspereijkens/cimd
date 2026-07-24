const std = @import("std");
const Model = @import("cim/cim.zig").CimDocument;
const parse_filename = @import("qocdc.zig").parse_filename;
const validate = @import("qocdc.zig");
const check_filename_consistency = validate.check_filename_consistency;
const check_effective_datetime = validate.check_effective_datetime;
const validate_sourcing_actor = validate.validate_sourcing_actor;
const validate_cgm_region = validate.validate_cgm_region;
const validate_business_process = validate.validate_business_process;
const validate_model_part = validate.validate_model_part;
const validate_file_version = validate.validate_file_version;

fn append_u16_le(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..], value, .little);
    try out.appendSlice(gpa, bytes[0..]);
}

fn append_u32_le(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..], value, .little);
    try out.appendSlice(gpa, bytes[0..]);
}

fn append_local_header(out: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8) !u32 {
    return append_local_header_sized(out, gpa, name, 0, 0);
}

fn append_local_header_sized(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    name: []const u8,
    size: u32,
    crc: u32,
) !u32 {
    std.debug.assert(name.len <= std.math.maxInt(u16));

    const offset: u32 = @intCast(out.items.len);
    try out.appendSlice(gpa, &std.zip.local_file_header_sig);
    try append_u16_le(out, gpa, 20); // version needed
    try append_u16_le(out, gpa, 0); // flags
    try append_u16_le(out, gpa, 0); // compression: stored
    try append_u16_le(out, gpa, 0); // mod time
    try append_u16_le(out, gpa, 0); // mod date
    try append_u32_le(out, gpa, crc);
    try append_u32_le(out, gpa, size); // compressed size
    try append_u32_le(out, gpa, size); // uncompressed size
    try append_u16_le(out, gpa, @intCast(name.len));
    try append_u16_le(out, gpa, 0); // extra field length
    try out.appendSlice(gpa, name);
    return offset;
}

fn append_central_header(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    name: []const u8,
    local_header_offset: u32,
) !void {
    return append_central_header_sized(out, gpa, name, local_header_offset, 0, 0);
}

fn append_central_header_sized(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    name: []const u8,
    local_header_offset: u32,
    size: u32,
    crc: u32,
) !void {
    std.debug.assert(name.len <= std.math.maxInt(u16));

    try out.appendSlice(gpa, &std.zip.central_file_header_sig);
    try append_u16_le(out, gpa, 20); // version made by
    try append_u16_le(out, gpa, 20); // version needed
    try append_u16_le(out, gpa, 0); // flags
    try append_u16_le(out, gpa, 0); // compression: stored
    try append_u16_le(out, gpa, 0); // mod time
    try append_u16_le(out, gpa, 0); // mod date
    try append_u32_le(out, gpa, crc);
    try append_u32_le(out, gpa, size); // compressed size
    try append_u32_le(out, gpa, size); // uncompressed size
    try append_u16_le(out, gpa, @intCast(name.len));
    try append_u16_le(out, gpa, 0); // extra field length
    try append_u16_le(out, gpa, 0); // file comment length
    try append_u16_le(out, gpa, 0); // disk number start
    try append_u16_le(out, gpa, 0); // internal file attributes
    try append_u32_le(out, gpa, 0); // external file attributes
    try append_u32_le(out, gpa, local_header_offset);
    try out.appendSlice(gpa, name);
}

fn create_test_zip_with_file(
    io: std.Io,
    dir: std.Io.Dir,
    zip_name: []const u8,
    entry_name: []const u8,
    contents: []const u8,
    out_path: []u8,
) ![]const u8 {
    std.debug.assert(contents.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var zip_bytes: std.ArrayList(u8) = .empty;
    defer zip_bytes.deinit(gpa);

    const size: u32 = @intCast(contents.len);
    const crc = std.hash.Crc32.hash(contents);
    const local_offset = try append_local_header_sized(&zip_bytes, gpa, entry_name, size, crc);
    try zip_bytes.appendSlice(gpa, contents);
    const central_directory_offset: u32 = @intCast(zip_bytes.items.len);
    try append_central_header_sized(&zip_bytes, gpa, entry_name, local_offset, size, crc);
    const central_directory_size: u32 = @intCast(zip_bytes.items.len - central_directory_offset);

    try zip_bytes.appendSlice(gpa, &std.zip.end_record_sig);
    try append_u16_le(&zip_bytes, gpa, 0);
    try append_u16_le(&zip_bytes, gpa, 0);
    try append_u16_le(&zip_bytes, gpa, 1);
    try append_u16_le(&zip_bytes, gpa, 1);
    try append_u32_le(&zip_bytes, gpa, central_directory_size);
    try append_u32_le(&zip_bytes, gpa, central_directory_offset);
    try append_u16_le(&zip_bytes, gpa, 0);

    var file = try dir.createFile(io, zip_name, .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, zip_bytes.items);

    const path_len = try file.realPath(io, out_path);
    return out_path[0..path_len];
}

fn create_test_zip(
    io: std.Io,
    dir: std.Io.Dir,
    zip_name: []const u8,
    entry_names: []const []const u8,
    out_path: []u8,
) ![]const u8 {
    std.debug.assert(entry_names.len > 0);
    std.debug.assert(entry_names.len <= 8);

    const gpa = std.testing.allocator;
    var zip_bytes: std.ArrayList(u8) = .empty;
    defer zip_bytes.deinit(gpa);

    var local_header_offsets: [8]u32 = undefined;
    for (entry_names, 0..) |entry_name, index| {
        local_header_offsets[index] = try append_local_header(&zip_bytes, gpa, entry_name);
    }

    const central_directory_offset_usize = zip_bytes.items.len;
    const central_directory_offset: u32 = @intCast(central_directory_offset_usize);
    for (entry_names, 0..) |entry_name, index| {
        try append_central_header(&zip_bytes, gpa, entry_name, local_header_offsets[index]);
    }
    const central_directory_size: u32 = @intCast(zip_bytes.items.len - central_directory_offset_usize);
    const entry_count: u16 = @intCast(entry_names.len);

    try zip_bytes.appendSlice(gpa, &std.zip.end_record_sig);
    try append_u16_le(&zip_bytes, gpa, 0); // disk number
    try append_u16_le(&zip_bytes, gpa, 0); // central directory disk
    try append_u16_le(&zip_bytes, gpa, entry_count);
    try append_u16_le(&zip_bytes, gpa, entry_count);
    try append_u32_le(&zip_bytes, gpa, central_directory_size);
    try append_u32_le(&zip_bytes, gpa, central_directory_offset);
    try append_u16_le(&zip_bytes, gpa, 0); // comment length

    var file = try dir.createFile(io, zip_name, .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, zip_bytes.items);

    const path_len = try file.realPath(io, out_path);
    return out_path[0..path_len];
}

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

    const io = std.testing.io;
    const filename = "my_filename.zip";
    var out_buffer: [1024]u8 = undefined;
    const file_path = try create_test_zip(io, tmpdir.dir, filename, &.{"my_filename.xml"}, &out_buffer);

    try check_filename_consistency(io, file_path);
}

test "FileNameConsistency rejects zip containers with multiple files" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const io = std.testing.io;
    const filename = "my_filename.zip";
    var out_buffer: [1024]u8 = undefined;
    const file_path = try create_test_zip(
        io,
        tmpdir.dir,
        filename,
        &.{ "my_filename.xml", "other.xml" },
        &out_buffer,
    );

    try std.testing.expectError(error.FileNameConsistency, check_filename_consistency(io, file_path));
}

test "FileNameConsistency rejects a plain file as not a ZIP archive" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const io = std.testing.io;
    var file = try tmpdir.dir.createFile(io, "model.xml", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "<rdf:RDF/>");

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try file.realPath(io, &path_buffer);
    try std.testing.expectError(
        error.NotZipArchive,
        check_filename_consistency(io, path_buffer[0..path_len]),
    );
}

test "EffectiveDateTime" {
    const correct_filename_template1: []const u8 = "20260603T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try check_effective_datetime(filename1);

    const leap_day: []const u8 = "20240229T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename_leap_day = try parse_filename(leap_day);
    try check_effective_datetime(filename_leap_day);

    const filename_template_incorrect1: []const u8 = "2026060ET1325Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename2 = try parse_filename(filename_template_incorrect1);
    try std.testing.expectError(error.EffectiveDateTime, check_effective_datetime(filename2));

    const filename_template_incorrect2: []const u8 = "20260603T132540Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename3 = try parse_filename(filename_template_incorrect2);
    try std.testing.expectError(error.EffectiveDateTime, check_effective_datetime(filename3));

    const filename_template_incorrect3: []const u8 = "20260603Z1325T_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename4 = try parse_filename(filename_template_incorrect3);
    try std.testing.expectError(error.EffectiveDateTime, check_effective_datetime(filename4));

    const filename_template_incorrect4: []const u8 = "20261303T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename5 = try parse_filename(filename_template_incorrect4);
    try std.testing.expectError(error.EffectiveDateTime, check_effective_datetime(filename5));

    const filename_template_incorrect5: []const u8 = "20230229T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename6 = try parse_filename(filename_template_incorrect5);
    try std.testing.expectError(error.EffectiveDateTime, check_effective_datetime(filename6));

    const filename_template_incorrect6: []const u8 = "20260603T2460Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename7 = try parse_filename(filename_template_incorrect6);
    try std.testing.expectError(error.EffectiveDateTime, check_effective_datetime(filename7));
}

test "SourcingActor" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_businessProcess_TTN_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try validate_sourcing_actor(filename1);

    const correct_filename_template2: []const u8 = "effectiveDateTime_businessProcess_BALTIC-EU_modelPart_fileVersion";
    const filename2 = try parse_filename(correct_filename_template2);
    try validate_sourcing_actor(filename2);

    const correct_filename_template_case: []const u8 = "effectiveDateTime_businessProcess_baltic-eu-ttn_modelPart_fileVersion";
    const filename_case = try parse_filename(correct_filename_template_case);
    try validate_sourcing_actor(filename_case);

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

    const incorrect_filename_template5: []const u8 = "effectiveDateTime_businessProcess_doesnotexist-EU_modelPart_fileVersion";
    const filename8 = try parse_filename(incorrect_filename_template5);
    try std.testing.expectError(error.SourcingActor, validate_sourcing_actor(filename8));
}

test "CGMRegion" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingRSC-EU_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try validate_cgm_region(filename1);

    const correct_filename_template2: []const u8 = "effectiveDateTime_businessProcess_baltic-eu-ttn_modelPart_fileVersion";
    const filename_case = try parse_filename(correct_filename_template2);
    try validate_cgm_region(filename_case);

    const incorrect_filename_template1: []const u8 = "effectiveDateTime_businessProcess_EU-sourcingRSC_modelPart_fileVersion";
    const filename2 = try parse_filename(incorrect_filename_template1);
    try std.testing.expectError(error.CGMRegion, validate_cgm_region(filename2));
}

test "BusinessProcess" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_1D_TTN_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try validate_business_process(filename1);

    const correct_filename_template2: []const u8 = "effectiveDateTime_1d_TTN_modelPart_fileVersion";
    const filename_case = try parse_filename(correct_filename_template2);
    try validate_business_process(filename_case);

    const incorrect_filename_template1: []const u8 = "effectiveDateTime_8D_TTN_modelPart_fileVersion";
    const filename2 = try parse_filename(incorrect_filename_template1);
    try std.testing.expectError(error.BusinessProcess, validate_business_process(filename2));
}

test "ModelPartType" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_EQ_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try validate_model_part(filename1);

    const correct_filename_template2: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_eq_fileVersion";
    const filename_case = try parse_filename(correct_filename_template2);
    try validate_model_part(filename_case);

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

    const incorrect_filename_template3: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_modelPart_000";
    const filename4 = try parse_filename(incorrect_filename_template3);
    try std.testing.expectError(error.FileVersion, validate_file_version(filename4));
}

test "validate accepts zip paths with valid fileVersion" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const io = std.testing.io;
    const stem = "20260603T1325Z_1D_TTN_EQ_001";
    const xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:test-equipment">
        \\    <md:Model.profile>http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0</md:Model.profile>
        \\  </md:FullModel>
        \\</rdf:RDF>
    ;
    var out_buffer: [1024]u8 = undefined;
    const file_path = try create_test_zip_with_file(
        io,
        tmpdir.dir,
        stem ++ ".zip",
        stem ++ ".xml",
        xml,
        &out_buffer,
    );

    try validate.validate(io, std.testing.allocator, file_path);
}

test "validate_filename rejects invalid fileVersion from zip path" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const io = std.testing.io;
    const stem = "20260603T1325Z_1D_TTN_EQ_000";
    var out_buffer: [1024]u8 = undefined;
    const file_path = try create_test_zip(io, tmpdir.dir, stem ++ ".zip", &.{stem ++ ".xml"}, &out_buffer);

    try std.testing.expectError(error.FileVersion, validate.validate_filename(file_path));
}

fn run_ce_base_voltage(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);
    return validate.validate_conducting_equipment_base_voltage(model);
}

test "CEBaseVoltage accepts a direct BaseVoltage association" {
    try run_ce_base_voltage(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BRK1">
        \\    <cim:ConductingEquipment.BaseVoltage rdf:resource="#_BV1"/>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    );
}

test "CEBaseVoltage accepts VoltageLevel containment" {
    try run_ce_base_voltage(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BRK1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_VL1"/>
        \\  </cim:Breaker>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_BV1"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    );
}

test "CEBaseVoltage rejects missing association and containment" {
    try std.testing.expectError(error.CEBaseVoltage, run_ce_base_voltage(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BRK1">
        \\    <cim:IdentifiedObject.name>orphan</cim:IdentifiedObject.name>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    ));
}

test "CEBaseVoltage rejects containment outside a VoltageLevel or Bay" {
    try std.testing.expectError(error.CEBaseVoltage, run_ce_base_voltage(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BRK1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_LINE1"/>
        \\  </cim:Breaker>
        \\  <cim:Line rdf:ID="_LINE1">
        \\    <cim:IdentifiedObject.name>L1</cim:IdentifiedObject.name>
        \\  </cim:Line>
        \\</rdf:RDF>
    ));
}

test "CEBaseVoltage compares equipment and VoltageLevel associations" {
    try run_ce_base_voltage(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BRK1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_VL1"/>
        \\    <cim:ConductingEquipment.BaseVoltage rdf:resource="#_BV1"/>
        \\  </cim:Breaker>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_BV1"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    );

    try std.testing.expectError(error.CEBaseVoltage, run_ce_base_voltage(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BRK1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_VL1"/>
        \\    <cim:ConductingEquipment.BaseVoltage rdf:resource="#_BV1"/>
        \\  </cim:Breaker>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_BV2"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ));
}

test "CEBaseVoltage resolves Bay containment through its VoltageLevel" {
    try run_ce_base_voltage(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BRK1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_BAY1"/>
        \\    <cim:ConductingEquipment.BaseVoltage rdf:resource="#_BV1"/>
        \\  </cim:Breaker>
        \\  <cim:Bay rdf:ID="_BAY1">
        \\    <cim:Bay.VoltageLevel rdf:resource="#_VL1"/>
        \\  </cim:Bay>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_BV1"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    );

    try std.testing.expectError(error.CEBaseVoltage, run_ce_base_voltage(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BRK1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_BAY1"/>
        \\    <cim:ConductingEquipment.BaseVoltage rdf:resource="#_BV1"/>
        \\  </cim:Breaker>
        \\  <cim:Bay rdf:ID="_BAY1">
        \\    <cim:Bay.VoltageLevel rdf:resource="#_VL1"/>
        \\  </cim:Bay>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_BV2"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ));
}

test "CEBaseVoltage accepts Bay containment without a BaseVoltage" {
    try run_ce_base_voltage(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BRK1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_BAY1"/>
        \\  </cim:Breaker>
        \\  <cim:Bay rdf:ID="_BAY1">
        \\    <cim:Bay.VoltageLevel rdf:resource="#_VL1"/>
        \\  </cim:Bay>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:IdentifiedObject.name>VL1</cim:IdentifiedObject.name>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    );
}

test "CEBaseVoltage skips exempt converter and transformer classes" {
    try run_ce_base_voltage(
        \\<rdf:RDF>
        \\  <cim:VsConverter rdf:ID="_VSC1">
        \\    <cim:IdentifiedObject.name>VSC1</cim:IdentifiedObject.name>
        \\  </cim:VsConverter>
        \\  <cim:PowerTransformer rdf:ID="_PT1">
        \\    <cim:IdentifiedObject.name>PT1</cim:IdentifiedObject.name>
        \\  </cim:PowerTransformer>
        \\</rdf:RDF>
    );
}
