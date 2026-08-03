const std = @import("std");
const cim = @import("cim/cim.zig");
const Model = cim.CimDocument;
const ReverseRefIndex = cim.ReverseRefIndex;
const parse_filename = @import("qocdc.zig").parse_filename;
const qocdc = @import("qocdc.zig");

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

    try qocdc.validate_filename_consistency(io, file_path);
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

    try std.testing.expectError(error.FileNameConsistency, qocdc.validate_filename_consistency(io, file_path));
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
        qocdc.validate_filename_consistency(io, path_buffer[0..path_len]),
    );
}

test "EffectiveDateTime" {
    const correct_filename_template1: []const u8 = "20260603T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try qocdc.check_effective_datetime(filename1);

    const leap_day: []const u8 = "20240229T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename_leap_day = try parse_filename(leap_day);
    try qocdc.check_effective_datetime(filename_leap_day);

    const filename_template_incorrect1: []const u8 = "2026060ET1325Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename2 = try parse_filename(filename_template_incorrect1);
    try std.testing.expectError(error.EffectiveDateTime, qocdc.check_effective_datetime(filename2));

    const filename_template_incorrect2: []const u8 = "20260603T132540Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename3 = try parse_filename(filename_template_incorrect2);
    try std.testing.expectError(error.EffectiveDateTime, qocdc.check_effective_datetime(filename3));

    const filename_template_incorrect3: []const u8 = "20260603Z1325T_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename4 = try parse_filename(filename_template_incorrect3);
    try std.testing.expectError(error.EffectiveDateTime, qocdc.check_effective_datetime(filename4));

    const filename_template_incorrect4: []const u8 = "20261303T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename5 = try parse_filename(filename_template_incorrect4);
    try std.testing.expectError(error.EffectiveDateTime, qocdc.check_effective_datetime(filename5));

    const filename_template_incorrect5: []const u8 = "20230229T1325Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename6 = try parse_filename(filename_template_incorrect5);
    try std.testing.expectError(error.EffectiveDateTime, qocdc.check_effective_datetime(filename6));

    const filename_template_incorrect6: []const u8 = "20260603T2460Z_businessProcess_sourcingTSO_modelPart_fileVersion";
    const filename7 = try parse_filename(filename_template_incorrect6);
    try std.testing.expectError(error.EffectiveDateTime, qocdc.check_effective_datetime(filename7));
}

test "SourcingActor" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_businessProcess_TTN_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try qocdc.validate_sourcing_actor(filename1);

    const correct_filename_template2: []const u8 = "effectiveDateTime_businessProcess_BALTIC-EU_modelPart_fileVersion";
    const filename2 = try parse_filename(correct_filename_template2);
    try qocdc.validate_sourcing_actor(filename2);

    const correct_filename_template_case: []const u8 = "effectiveDateTime_businessProcess_baltic-eu-ttn_modelPart_fileVersion";
    const filename_case = try parse_filename(correct_filename_template_case);
    try qocdc.validate_sourcing_actor(filename_case);

    const incorrect_filename_template: []const u8 = "effectiveDateTime_businessProcess_doesnotexist_modelPart_fileVersion";
    const filename3 = try parse_filename(incorrect_filename_template);
    try std.testing.expectError(error.SourcingActor, qocdc.validate_sourcing_actor(filename3));

    const incorrect_filename_template1: []const u8 = "effectiveDateTime_businessProcess_TTN2electricboogaloo_modelPart_fileVersion";
    const filename4 = try parse_filename(incorrect_filename_template1);
    try std.testing.expectError(error.SourcingActor, qocdc.validate_sourcing_actor(filename4));

    const correct_filename_template3: []const u8 = "effectiveDateTime_businessProcess_BALTIC-cgmRegion-TTN_modelPart_fileVersion";
    const filename5 = try parse_filename(correct_filename_template3);
    try qocdc.validate_sourcing_actor(filename5);

    const incorrect_filename_template2: []const u8 = "effectiveDateTime_businessProcess_BALTIC-cgmRegion-doesnotexist_modelPart_fileVersion";
    const filename6 = try parse_filename(incorrect_filename_template2);
    try std.testing.expectError(error.SourcingActor, qocdc.validate_sourcing_actor(filename6));

    const incorrect_filename_template4: []const u8 = "effectiveDateTime_businessProcess_doesnotexit-cgmRegion-TTN_modelPart_fileVersion";
    const filename7 = try parse_filename(incorrect_filename_template4);
    try std.testing.expectError(error.SourcingActor, qocdc.validate_sourcing_actor(filename7));

    const incorrect_filename_template5: []const u8 = "effectiveDateTime_businessProcess_doesnotexist-EU_modelPart_fileVersion";
    const filename8 = try parse_filename(incorrect_filename_template5);
    try std.testing.expectError(error.SourcingActor, qocdc.validate_sourcing_actor(filename8));
}

test "CGMRegion" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingRSC-EU_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try qocdc.validate_cgm_region(filename1);

    const correct_filename_template2: []const u8 = "effectiveDateTime_businessProcess_baltic-eu-ttn_modelPart_fileVersion";
    const filename_case = try parse_filename(correct_filename_template2);
    try qocdc.validate_cgm_region(filename_case);

    const incorrect_filename_template1: []const u8 = "effectiveDateTime_businessProcess_EU-sourcingRSC_modelPart_fileVersion";
    const filename2 = try parse_filename(incorrect_filename_template1);
    try std.testing.expectError(error.CGMRegion, qocdc.validate_cgm_region(filename2));
}

test "BusinessProcess" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_1D_TTN_modelPart_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try qocdc.validate_business_process(filename1);

    const correct_filename_template2: []const u8 = "effectiveDateTime_1d_TTN_modelPart_fileVersion";
    const filename_case = try parse_filename(correct_filename_template2);
    try qocdc.validate_business_process(filename_case);

    const incorrect_filename_template1: []const u8 = "effectiveDateTime_8D_TTN_modelPart_fileVersion";
    const filename2 = try parse_filename(incorrect_filename_template1);
    try std.testing.expectError(error.BusinessProcess, qocdc.validate_business_process(filename2));
}

test "ModelPartType" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_EQ_fileVersion";
    const filename1 = try parse_filename(correct_filename_template1);
    try qocdc.validate_model_part(filename1);

    const correct_filename_template2: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_eq_fileVersion";
    const filename_case = try parse_filename(correct_filename_template2);
    try qocdc.validate_model_part(filename_case);

    const incorrect_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_CO_fileVersion";
    const filename2 = try parse_filename(incorrect_filename_template1);
    try std.testing.expectError(error.ModelPartType, qocdc.validate_model_part(filename2));
}

test "FileVersionType" {
    const correct_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_modelPart_003";
    const filename1 = try parse_filename(correct_filename_template1);
    try qocdc.validate_file_version(filename1);

    const incorrect_filename_template1: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_modelPart_1000";
    const filename2 = try parse_filename(incorrect_filename_template1);
    try std.testing.expectError(error.FileVersion, qocdc.validate_file_version(filename2));

    const incorrect_filename_template2: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_modelPart_abc";
    const filename3 = try parse_filename(incorrect_filename_template2);
    try std.testing.expectError(error.FileVersion, qocdc.validate_file_version(filename3));

    const incorrect_filename_template3: []const u8 = "effectiveDateTime_businessProcess_sourcingProcess_modelPart_000";
    const filename4 = try parse_filename(incorrect_filename_template3);
    try std.testing.expectError(error.FileVersion, qocdc.validate_file_version(filename4));
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

    try qocdc.validate(io, std.testing.allocator, file_path);
}

test "validate_filename rejects invalid fileVersion from zip path" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const io = std.testing.io;
    const stem = "20260603T1325Z_1D_TTN_EQ_000";
    var out_buffer: [1024]u8 = undefined;
    const file_path = try create_test_zip(io, tmpdir.dir, stem ++ ".zip", &.{stem ++ ".xml"}, &out_buffer);

    try std.testing.expectError(error.FileVersion, qocdc.validate_filename(file_path));
}

fn run_ce_base_voltage(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);
    return qocdc.validate_conducting_equipment_base_voltage(model);
}

fn run_terminal_count1(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    var reverse_ref_index = try ReverseRefIndex.build(gpa, &model);
    defer reverse_ref_index.deinit(gpa);

    return qocdc.validate_terminal_count1(model, &reverse_ref_index);
}

fn run_terminal_count2(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    var reverse_ref_index = try ReverseRefIndex.build(gpa, &model);
    defer reverse_ref_index.deinit(gpa);

    return qocdc.validate_terminal_count2(model, &reverse_ref_index);
}

fn run_terminal_seq_num(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    var reverse_ref_index = try ReverseRefIndex.build(gpa, &model);
    defer reverse_ref_index.deinit(gpa);

    return qocdc.validate_terminal_seq_num(model, &reverse_ref_index);
}

fn run_terminal_seq_num_order(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    var reverse_ref_index = try ReverseRefIndex.build(gpa, &model);
    defer reverse_ref_index.deinit(gpa);

    return qocdc.validate_terminal_seq_num_order(gpa, model, &reverse_ref_index);
}

fn run_power_transformer_terminal_consistency(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    return qocdc.validate_power_transformer_terminal_consistency(model);
}

fn run_mutual_coupling_order(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    return qocdc.validate_mutual_coupling_order(model);
}

fn run_load_response_characteristic_exponent_model(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    return qocdc.validate_load_response_characteristic_exponent_model(model);
}

fn run_load_response_characteristic_exponent_values(
    p_voltage_exponent: []const u8,
    q_voltage_exponent: []const u8,
) !void {
    const gpa = std.testing.allocator;
    const xml = try std.fmt.allocPrint(
        gpa,
        "<rdf:RDF><cim:LoadResponseCharacteristic rdf:ID=\"_LRC1\">" ++
            "<cim:LoadResponseCharacteristic.exponentModel>true</cim:LoadResponseCharacteristic.exponentModel>" ++
            "<cim:LoadResponseCharacteristic.pVoltageExponent>{s}</cim:LoadResponseCharacteristic.pVoltageExponent>" ++
            "<cim:LoadResponseCharacteristic.qVoltageExponent>{s}</cim:LoadResponseCharacteristic.qVoltageExponent>" ++
            "</cim:LoadResponseCharacteristic></rdf:RDF>",
        .{ p_voltage_exponent, q_voltage_exponent },
    );
    defer gpa.free(xml);

    return run_load_response_characteristic_exponent_model(xml);
}

fn run_load_response_characteristic_coefficient_model(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    return qocdc.validate_load_response_characteristic_coefficient_model(model);
}

fn load_response_characteristic_coefficients_xml(
    gpa: std.mem.Allocator,
    coefficients: [6]?[]const u8,
) ![]u8 {
    const coefficient_names = [_][]const u8{
        "LoadResponseCharacteristic.pConstantImpedance",
        "LoadResponseCharacteristic.pConstantCurrent",
        "LoadResponseCharacteristic.pConstantPower",
        "LoadResponseCharacteristic.qConstantImpedance",
        "LoadResponseCharacteristic.qConstantCurrent",
        "LoadResponseCharacteristic.qConstantPower",
    };
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(gpa);

    try xml.appendSlice(
        gpa,
        "<rdf:RDF><cim:LoadResponseCharacteristic rdf:ID=\"_LRC1\">" ++
            "<cim:LoadResponseCharacteristic.exponentModel>false</cim:LoadResponseCharacteristic.exponentModel>",
    );
    for (coefficient_names, coefficients) |name, coefficient| {
        const value = coefficient orelse continue;
        const property = try std.fmt.allocPrint(gpa, "<cim:{s}>{s}</cim:{s}>", .{ name, value, name });
        defer gpa.free(property);
        try xml.appendSlice(gpa, property);
    }
    try xml.appendSlice(gpa, "</cim:LoadResponseCharacteristic></rdf:RDF>");
    return xml.toOwnedSlice(gpa);
}

fn run_load_response_characteristic_coefficients(coefficients: [6]?[]const u8) !void {
    const gpa = std.testing.allocator;
    const xml = try load_response_characteristic_coefficients_xml(gpa, coefficients);
    defer gpa.free(xml);

    return run_load_response_characteristic_coefficient_model(xml);
}

fn run_load_response_characteristic_coefficient_parameters(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    return qocdc.validate_load_response_characteristic_coefficient_parameters(model);
}

fn run_load_response_characteristic_coefficient_parameter_values(
    coefficients: [6]?[]const u8,
) !void {
    const gpa = std.testing.allocator;
    const xml = try load_response_characteristic_coefficients_xml(gpa, coefficients);
    defer gpa.free(xml);

    return run_load_response_characteristic_coefficient_parameters(xml);
}

fn run_measurement_terminal(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    return qocdc.validate_measurement_terminal(model);
}

fn run_measurement_type(xml: []const u8, version: ?cim.profile.Version) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    return qocdc.validate_measurement_type(model, version);
}

fn run_measurement_type_value(measurement_type: []const u8, version: ?cim.profile.Version) !void {
    const gpa = std.testing.allocator;
    const xml = try std.fmt.allocPrint(
        gpa,
        "<rdf:RDF><cim:Measurement rdf:ID=\"_M1\">" ++
            "<cim:Measurement.measurementType>{s}</cim:Measurement.measurementType>" ++
            "</cim:Measurement></rdf:RDF>",
        .{measurement_type},
    );
    defer gpa.free(xml);

    return run_measurement_type(xml, version);
}

fn run_measurement_unit(xml: []const u8, version: ?cim.profile.Version) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    return qocdc.validate_measurement_unit(model, version);
}

fn run_measurement_unit_reference(unit_reference: []const u8) !void {
    return run_measurement_unit_type_reference(
        "Measurement",
        unit_reference,
        .v2_4_15,
    );
}

fn run_measurement_unit_type_reference(
    type_name: []const u8,
    unit_reference: []const u8,
    version: ?cim.profile.Version,
) !void {
    const gpa = std.testing.allocator;
    const xml = try std.fmt.allocPrint(
        gpa,
        "<rdf:RDF><cim:{s} rdf:ID=\"_M1\">" ++
            "<cim:Measurement.unitSymbol rdf:resource=\"{s}\"/>" ++
            "</cim:{s}></rdf:RDF>",
        .{ type_name, unit_reference, type_name },
    );
    defer gpa.free(xml);

    return run_measurement_unit(xml, version);
}

fn run_conn_node_in_eq_operations(xml: []const u8) !void {
    const gpa = std.testing.allocator;
    var model = try Model.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const header = try cim.profile.classify(gpa, model.xml);
    return qocdc.validate_conn_node_in_eq_operations(model, header);
}

fn run_conn_node_in_profile(profile_uri: []const u8, body: []const u8) !void {
    const gpa = std.testing.allocator;
    const xml = try std.fmt.allocPrint(
        gpa,
        "<rdf:RDF><md:FullModel rdf:about=\"urn:uuid:test\">" ++
            "<md:Model.profile>{s}</md:Model.profile>" ++
            "</md:FullModel>{s}</rdf:RDF>",
        .{ profile_uri, body },
    );
    defer gpa.free(xml);

    return run_conn_node_in_eq_operations(xml);
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

test "TerminalCount1 accepts exactly one Terminal among other reference types" {
    try run_terminal_count1(
        \\<rdf:RDF>
        \\  <cim:EnergyConsumer rdf:ID="_EC1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_EC1"/>
        \\  </cim:Terminal>
        \\  <cim:RegulatingControl rdf:ID="_RC1">
        \\    <cim:RegulatingControl.RegulatingCondEq rdf:resource="#_EC1"/>
        \\  </cim:RegulatingControl>
        \\</rdf:RDF>
    );
}

test "TerminalCount1 rejects constrained equipment without a Terminal" {
    const constrained_types = [_][]const u8{
        "RegulatingCondEq",
        "SynchronousMachine",
        "EnergyConsumer",
        "ConformLoad",
        "EquivalentInjection",
        "EquivalentShunt",
        "Junction",
        "EnergySource",
        "Ground",
        "DCBusbar",
        "DCShunt",
        "DCGround",
    };

    const gpa = std.testing.allocator;
    for (constrained_types) |type_name| {
        const xml = try std.fmt.allocPrint(
            gpa,
            "<rdf:RDF><cim:{s} rdf:ID=\"_EQ1\"/></rdf:RDF>",
            .{type_name},
        );
        defer gpa.free(xml);

        try std.testing.expectError(error.TerminalCount1, run_terminal_count1(xml));
    }
}

test "TerminalCount1 rejects multiple Terminal references" {
    try std.testing.expectError(error.TerminalCount1, run_terminal_count1(
        \\<rdf:RDF>
        \\  <cim:EnergyConsumer rdf:ID="_EC1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_EC1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_EC1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));
}

test "TerminalCount1 counts repeated associations from one Terminal once" {
    try run_terminal_count1(
        \\<rdf:RDF>
        \\  <cim:EnergyConsumer rdf:ID="_EC1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_EC1"/>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_EC1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalCount1 ignores other references from a Terminal" {
    try std.testing.expectError(error.TerminalCount1, run_terminal_count1(
        \\<rdf:RDF>
        \\  <cim:EnergyConsumer rdf:ID="_EC1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#_EC1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));
}

test "TerminalCount1 ignores equipment outside its scope" {
    try run_terminal_count1(
        \\<rdf:RDF>
        \\  <cim:Connector rdf:ID="_CON1"/>
        \\  <cim:Breaker rdf:ID="_BRK1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRK1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRK1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalCount2 accepts exactly two Terminals among other references" {
    try run_terminal_count2(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T3">
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\  <cim:RegulatingControl rdf:ID="_RC1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:RegulatingControl>
        \\</rdf:RDF>
    );
}

test "TerminalCount2 rejects fewer or more than two Terminals" {
    try std.testing.expectError(error.TerminalCount2, run_terminal_count2(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));

    try std.testing.expectError(error.TerminalCount2, run_terminal_count2(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T3">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));
}

test "TerminalCount2 counts distinct Terminal instances" {
    try std.testing.expectError(error.TerminalCount2, run_terminal_count2(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));

    try run_terminal_count2(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalCount2 covers every listed type and known subclass" {
    const constrained_types = [_][]const u8{
        "Conductor",
        "ACLineSegment",
        "Switch",
        "Cut",
        "ProtectedSwitch",
        "Breaker",
        "DisconnectingCircuitBreaker",
        "Disconnector",
        "Fuse",
        "GroundDisconnector",
        "Jumper",
        "LoadBreakSwitch",
        "SeriesCompensator",
        "EquivalentBranch",
        "DCLineSegment",
        "DCSeriesDevice",
        "DCChopper",
        "DCBreaker",
        "DCDisconnector",
    };

    const gpa = std.testing.allocator;
    for (constrained_types) |type_name| {
        const xml = try std.fmt.allocPrint(
            gpa,
            "<rdf:RDF><cim:{s} rdf:ID=\"_EQ1\"/></rdf:RDF>",
            .{type_name},
        );
        defer gpa.free(xml);

        try std.testing.expectError(error.TerminalCount2, run_terminal_count2(xml));
    }
}

test "TerminalCount2 ignores equipment outside its scope" {
    try run_terminal_count2(
        \\<rdf:RDF>
        \\  <cim:ConductingEquipment rdf:ID="_CE1"/>
        \\  <cim:Connector rdf:ID="_CON1"/>
        \\  <cim:BusbarSection rdf:ID="_BBS1"/>
        \\  <cim:Junction rdf:ID="_J1"/>
        \\  <cim:DCSwitch rdf:ID="_DCS1"/>
        \\  <cim:DCBusbar rdf:ID="_DCB1"/>
        \\  <cim:DCGround rdf:ID="_DCG1"/>
        \\  <cim:DCShunt rdf:ID="_DCSH1"/>
        \\  <cim:PowerTransformer rdf:ID="_PT1"/>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNum accepts an uncoupled ACLineSegment without sequence numbers" {
    try run_terminal_seq_num(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNum requires sequence numbers for EquivalentBranch terminals" {
    try std.testing.expectError(error.TerminalSeqNum, run_terminal_seq_num(
        \\<rdf:RDF>
        \\  <cim:EquivalentBranch rdf:ID="_BRANCH1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRANCH1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));
}

test "TerminalSeqNum accepts whitespace around a valid integer" {
    try run_terminal_seq_num(
        \\<rdf:RDF>
        \\  <cim:EquivalentBranch rdf:ID="_BRANCH1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRANCH1"/>
        \\    <cim:ACDCTerminal.sequenceNumber> 1 </cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNum rejects a non-integer sequence number" {
    try std.testing.expectError(error.TerminalSeqNum, run_terminal_seq_num(
        \\<rdf:RDF>
        \\  <cim:EquivalentBranch rdf:ID="_BRANCH1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRANCH1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>first</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));
}

test "TerminalSeqNum ignores non-equipment references from a Terminal" {
    try run_terminal_seq_num(
        \\<rdf:RDF>
        \\  <cim:EquivalentBranch rdf:ID="_BRANCH1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#_BRANCH1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNum requires sequence numbers for mutually coupled AC lines" {
    try std.testing.expectError(error.TerminalSeqNum, run_terminal_seq_num(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE1"/>
        \\  <cim:ACLineSegment rdf:ID="_LINE2"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE2"/>
        \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.First_Terminal rdf:resource="#_T1"/>
        \\    <cim:MutualCoupling.Second_Terminal rdf:resource="#_T2"/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    ));
}

test "TerminalSeqNum accepts mutually coupled AC lines with sequence numbers" {
    try run_terminal_seq_num(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE1"/>
        \\  <cim:ACLineSegment rdf:ID="_LINE2"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>
        \\      1
        \\    </cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE2"/>
        \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.First_Terminal rdf:resource="#_T1"/>
        \\    <cim:MutualCoupling.Second_Terminal rdf:resource="#_T2"/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNumOrder accepts equipment without sequence numbers" {
    try run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNumOrder accepts a single sequence number one" {
    try run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNumOrder accepts contiguous numbers independent of document order" {
    try run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:PowerTransformer rdf:ID="_PT1"/>
        \\  <cim:Terminal rdf:ID="_T3">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_PT1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>3</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_PT1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_PT1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNumOrder accepts whitespace around numbers" {
    try run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>
        \\      1
        \\    </cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber> 2 </cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNumOrder allows unnumbered siblings" {
    try run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNumOrder rejects numbering that does not start at one" {
    try std.testing.expectError(error.TerminalSeqNumOrder, run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));
}

test "TerminalSeqNumOrder rejects zero" {
    try std.testing.expectError(error.TerminalSeqNumOrder, run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>0</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));
}

test "TerminalSeqNumOrder rejects a gap" {
    try std.testing.expectError(error.TerminalSeqNumOrder, run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:PowerTransformer rdf:ID="_PT1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_PT1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T3">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_PT1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>3</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));
}

test "TerminalSeqNumOrder rejects duplicate sequence numbers" {
    try std.testing.expectError(error.TerminalSeqNumOrder, run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));
}

test "TerminalSeqNumOrder rejects an invalid integer" {
    try std.testing.expectError(error.TerminalSeqNumOrder, run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>first</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));
}

test "TerminalSeqNumOrder rejects a blank sequence number" {
    try std.testing.expectError(error.TerminalSeqNumOrder, run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber> </cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ));
}

test "TerminalSeqNumOrder ignores unrelated Terminal references" {
    try run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_REAL">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_UNRELATED">
        \\    <cim:Terminal.ConnectivityNode rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>9</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNumOrder counts a repeated equipment association once" {
    try run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNumOrder validates each equipment independently" {
    try run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Breaker rdf:ID="_BR2"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR2"/>
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNumOrder validates DCTerminal associations" {
    try run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:DCLineSegment rdf:ID="_DC1"/>
        \\  <cim:DCTerminal rdf:ID="_DT2">
        \\    <cim:DCTerminal.DCConductingEquipment rdf:resource="#_DC1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:DCTerminal>
        \\  <cim:DCTerminal rdf:ID="_DT1">
        \\    <cim:DCTerminal.DCConductingEquipment rdf:resource="#_DC1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:DCTerminal>
        \\</rdf:RDF>
    );
}

test "TerminalSeqNumOrder rejects invalid DCTerminal ordering" {
    try std.testing.expectError(error.TerminalSeqNumOrder, run_terminal_seq_num_order(
        \\<rdf:RDF>
        \\  <cim:DCLineSegment rdf:ID="_DC1"/>
        \\  <cim:DCTerminal rdf:ID="_DT1">
        \\    <cim:DCTerminal.DCConductingEquipment rdf:resource="#_DC1"/>
        \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
        \\  </cim:DCTerminal>
        \\</rdf:RDF>
    ));
}

test "TerminalSeqNumOrder has no arbitrary terminal-count limit" {
    const gpa = std.testing.allocator;
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(gpa);

    try xml.appendSlice(gpa, "<rdf:RDF><cim:PowerTransformer rdf:ID=\"_PT1\"/>");
    for (1..102) |sequence_number| {
        const terminal = try std.fmt.allocPrint(
            gpa,
            "<cim:Terminal rdf:ID=\"_T{d}\">" ++
                "<cim:Terminal.ConductingEquipment rdf:resource=\"#_PT1\"/>" ++
                "<cim:ACDCTerminal.sequenceNumber>{d}</cim:ACDCTerminal.sequenceNumber>" ++
                "</cim:Terminal>",
            .{ sequence_number, sequence_number },
        );
        defer gpa.free(terminal);
        try xml.appendSlice(gpa, terminal);
    }
    try xml.appendSlice(gpa, "</rdf:RDF>");

    try run_terminal_seq_num_order(xml.items);
}

test "PTTerminalConsistency accepts a terminal assigned to its power transformer" {
    try run_power_transformer_terminal_consistency(
        \\<rdf:RDF>
        \\  <cim:PowerTransformer rdf:ID="_PT1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_PT1"/>
        \\  </cim:Terminal>
        \\  <cim:PowerTransformerEnd rdf:ID="_E1">
        \\    <cim:TransformerEnd.Terminal rdf:resource="#_T1"/>
        \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#_PT1"/>
        \\  </cim:PowerTransformerEnd>
        \\</rdf:RDF>
    );
}

test "PTTerminalConsistency ignores documents without power transformer ends" {
    try run_power_transformer_terminal_consistency(
        \\<rdf:RDF>
        \\  <cim:PowerTransformer rdf:ID="_PT1"/>
        \\  <cim:TransformerEnd rdf:ID="_E1"/>
        \\</rdf:RDF>
    );
}

test "PTTerminalConsistency rejects a terminal assigned to another transformer" {
    try std.testing.expectError(
        error.PTTerminalConsistency,
        run_power_transformer_terminal_consistency(
            \\<rdf:RDF>
            \\  <cim:PowerTransformer rdf:ID="_PT1"/>
            \\  <cim:PowerTransformer rdf:ID="_PT2"/>
            \\  <cim:Terminal rdf:ID="_T0">
            \\    <cim:Terminal.ConductingEquipment rdf:resource="#_PT1"/>
            \\  </cim:Terminal>
            \\  <cim:Terminal rdf:ID="_T1">
            \\    <cim:Terminal.ConductingEquipment rdf:resource="#_PT2"/>
            \\  </cim:Terminal>
            \\  <cim:PowerTransformerEnd rdf:ID="_E0">
            \\    <cim:TransformerEnd.Terminal rdf:resource="#_T0"/>
            \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#_PT1"/>
            \\  </cim:PowerTransformerEnd>
            \\  <cim:PowerTransformerEnd rdf:ID="_E1">
            \\    <cim:TransformerEnd.Terminal rdf:resource="#_T1"/>
            \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#_PT1"/>
            \\  </cim:PowerTransformerEnd>
            \\</rdf:RDF>
        ),
    );
}

test "PTTerminalConsistency rejects matching references to non-transformer equipment" {
    try std.testing.expectError(
        error.PTTerminalConsistency,
        run_power_transformer_terminal_consistency(
            \\<rdf:RDF>
            \\  <cim:Breaker rdf:ID="_BR1"/>
            \\  <cim:Terminal rdf:ID="_T1">
            \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
            \\  </cim:Terminal>
            \\  <cim:PowerTransformerEnd rdf:ID="_E1">
            \\    <cim:TransformerEnd.Terminal rdf:resource="#_T1"/>
            \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#_BR1"/>
            \\  </cim:PowerTransformerEnd>
            \\</rdf:RDF>
        ),
    );
}

test "PTTerminalConsistency rejects missing required associations" {
    try std.testing.expectError(
        error.PTTerminalConsistency,
        run_power_transformer_terminal_consistency(
            \\<rdf:RDF>
            \\  <cim:PowerTransformer rdf:ID="_PT1"/>
            \\  <cim:PowerTransformerEnd rdf:ID="_E1">
            \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#_PT1"/>
            \\  </cim:PowerTransformerEnd>
            \\</rdf:RDF>
        ),
    );
    try std.testing.expectError(
        error.PTTerminalConsistency,
        run_power_transformer_terminal_consistency(
            \\<rdf:RDF>
            \\  <cim:PowerTransformer rdf:ID="_PT1"/>
            \\  <cim:Terminal rdf:ID="_T1"/>
            \\  <cim:PowerTransformerEnd rdf:ID="_E1">
            \\    <cim:TransformerEnd.Terminal rdf:resource="#_T1"/>
            \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#_PT1"/>
            \\  </cim:PowerTransformerEnd>
            \\</rdf:RDF>
        ),
    );
    try std.testing.expectError(
        error.PTTerminalConsistency,
        run_power_transformer_terminal_consistency(
            \\<rdf:RDF>
            \\  <cim:PowerTransformer rdf:ID="_PT1"/>
            \\  <cim:Terminal rdf:ID="_T1">
            \\    <cim:Terminal.ConductingEquipment rdf:resource="#_PT1"/>
            \\  </cim:Terminal>
            \\  <cim:PowerTransformerEnd rdf:ID="_E1">
            \\    <cim:TransformerEnd.Terminal rdf:resource="#_T1"/>
            \\  </cim:PowerTransformerEnd>
            \\</rdf:RDF>
        ),
    );
}

test "PTTerminalConsistency rejects dangling terminal and equipment references" {
    try std.testing.expectError(
        error.PTTerminalConsistency,
        run_power_transformer_terminal_consistency(
            \\<rdf:RDF>
            \\  <cim:PowerTransformer rdf:ID="_PT1"/>
            \\  <cim:PowerTransformerEnd rdf:ID="_E1">
            \\    <cim:TransformerEnd.Terminal rdf:resource="#_MISSING"/>
            \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#_PT1"/>
            \\  </cim:PowerTransformerEnd>
            \\</rdf:RDF>
        ),
    );
    try std.testing.expectError(
        error.PTTerminalConsistency,
        run_power_transformer_terminal_consistency(
            \\<rdf:RDF>
            \\  <cim:Terminal rdf:ID="_T1">
            \\    <cim:Terminal.ConductingEquipment rdf:resource="#_MISSING"/>
            \\  </cim:Terminal>
            \\  <cim:PowerTransformerEnd rdf:ID="_E1">
            \\    <cim:TransformerEnd.Terminal rdf:resource="#_T1"/>
            \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#_MISSING"/>
            \\  </cim:PowerTransformerEnd>
            \\</rdf:RDF>
        ),
    );
}

test "PTTerminalConsistency rejects malformed reference attributes" {
    try std.testing.expectError(
        error.PTTerminalConsistency,
        run_power_transformer_terminal_consistency(
            \\<rdf:RDF>
            \\  <cim:PowerTransformerEnd rdf:ID="_E1">
            \\    <cim:TransformerEnd.Terminal rdf:resource="#_T1/>
            \\  </cim:PowerTransformerEnd>
            \\</rdf:RDF>
        ),
    );
    try std.testing.expectError(
        error.PTTerminalConsistency,
        run_power_transformer_terminal_consistency(
            \\<rdf:RDF>
            \\  <cim:Terminal rdf:ID="_T1">
            \\    <cim:Terminal.ConductingEquipment rdf:resource="#_PT1/>
            \\  </cim:Terminal>
            \\  <cim:PowerTransformerEnd rdf:ID="_E1">
            \\    <cim:TransformerEnd.Terminal rdf:resource="#_T1"/>
            \\  </cim:PowerTransformerEnd>
            \\</rdf:RDF>
        ),
    );
    try std.testing.expectError(
        error.PTTerminalConsistency,
        run_power_transformer_terminal_consistency(
            \\<rdf:RDF>
            \\  <cim:PowerTransformer rdf:ID="_PT1"/>
            \\  <cim:Terminal rdf:ID="_T1">
            \\    <cim:Terminal.ConductingEquipment rdf:resource="#_PT1"/>
            \\  </cim:Terminal>
            \\  <cim:PowerTransformerEnd rdf:ID="_E1">
            \\    <cim:TransformerEnd.Terminal rdf:resource="#_T1"/>
            \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#_PT1/>
            \\  </cim:PowerTransformerEnd>
            \\</rdf:RDF>
        ),
    );
}

test "MCFirstSecond accepts terminals on different AC line segments" {
    try run_mutual_coupling_order(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE1"/>
        \\  <cim:ACLineSegment rdf:ID="_LINE2"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE2"/>
        \\  </cim:Terminal>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.First_Terminal rdf:resource="#_T1"/>
        \\    <cim:MutualCoupling.Second_Terminal rdf:resource="#_T2"/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    );
}

test "MCFirstSecond ignores documents without mutual couplings" {
    try run_mutual_coupling_order(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
}

test "MCFirstSecond rejects a first terminal on non-line equipment" {
    try std.testing.expectError(error.MCFirstSecond, run_mutual_coupling_order(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BREAKER"/>
        \\  <cim:ACLineSegment rdf:ID="_LINE"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BREAKER"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE"/>
        \\  </cim:Terminal>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.First_Terminal rdf:resource="#_T1"/>
        \\    <cim:MutualCoupling.Second_Terminal rdf:resource="#_T2"/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    ));
}

test "MCFirstSecond rejects a second terminal on non-line equipment" {
    try std.testing.expectError(error.MCFirstSecond, run_mutual_coupling_order(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE"/>
        \\  <cim:Breaker rdf:ID="_BREAKER"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BREAKER"/>
        \\  </cim:Terminal>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.First_Terminal rdf:resource="#_T1"/>
        \\    <cim:MutualCoupling.Second_Terminal rdf:resource="#_T2"/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    ));
}

test "MCFirstSecond rejects different terminals on the same AC line segment" {
    try std.testing.expectError(error.MCFirstSecond, run_mutual_coupling_order(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE"/>
        \\  </cim:Terminal>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.First_Terminal rdf:resource="#_T1"/>
        \\    <cim:MutualCoupling.Second_Terminal rdf:resource="#_T2"/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    ));
}

test "MCFirstSecond rejects endpoints that are not terminals" {
    try std.testing.expectError(error.MCFirstSecond, run_mutual_coupling_order(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE1"/>
        \\  <cim:ACLineSegment rdf:ID="_LINE2"/>
        \\  <cim:Breaker rdf:ID="_NOT_TERMINAL1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Breaker>
        \\  <cim:Breaker rdf:ID="_NOT_TERMINAL2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE2"/>
        \\  </cim:Breaker>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.First_Terminal rdf:resource="#_NOT_TERMINAL1"/>
        \\    <cim:MutualCoupling.Second_Terminal rdf:resource="#_NOT_TERMINAL2"/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    ));
}

test "MCFirstSecond rejects missing endpoint associations" {
    try std.testing.expectError(error.MCFirstSecond, run_mutual_coupling_order(
        \\<rdf:RDF>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.Second_Terminal rdf:resource="#_T2"/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    ));
    try std.testing.expectError(error.MCFirstSecond, run_mutual_coupling_order(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_LINE1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1"/>
        \\  </cim:Terminal>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.First_Terminal rdf:resource="#_T1"/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    ));
}

test "MCFirstSecond rejects dangling endpoint and equipment references" {
    try std.testing.expectError(error.MCFirstSecond, run_mutual_coupling_order(
        \\<rdf:RDF>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.First_Terminal rdf:resource="#_MISSING"/>
        \\    <cim:MutualCoupling.Second_Terminal rdf:resource="#_MISSING_TOO"/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    ));
    try std.testing.expectError(error.MCFirstSecond, run_mutual_coupling_order(
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_MISSING1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_T2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_MISSING2"/>
        \\  </cim:Terminal>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.First_Terminal rdf:resource="#_T1"/>
        \\    <cim:MutualCoupling.Second_Terminal rdf:resource="#_T2"/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    ));
}

test "MCFirstSecond rejects malformed reference attributes" {
    try std.testing.expectError(error.MCFirstSecond, run_mutual_coupling_order(
        \\<rdf:RDF>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.First_Terminal rdf:resource="#_T1/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    ));
    try std.testing.expectError(error.MCFirstSecond, run_mutual_coupling_order(
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LINE1/>
        \\  </cim:Terminal>
        \\  <cim:MutualCoupling rdf:ID="_MC1">
        \\    <cim:MutualCoupling.First_Terminal rdf:resource="#_T1"/>
        \\    <cim:MutualCoupling.Second_Terminal rdf:resource="#_T2"/>
        \\  </cim:MutualCoupling>
        \\</rdf:RDF>
    ));
}

test "LRCExponentModel accepts inclusive exponent bounds" {
    try run_load_response_characteristic_exponent_values("0", "2");
}

test "LRCExponentModel accepts finite values with surrounding whitespace" {
    try run_load_response_characteristic_exponent_model(
        \\<rdf:RDF>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_LRC1">
        \\    <cim:LoadResponseCharacteristic.exponentModel>
        \\      true
        \\    </cim:LoadResponseCharacteristic.exponentModel>
        \\    <cim:LoadResponseCharacteristic.pVoltageExponent> 0.5 </cim:LoadResponseCharacteristic.pVoltageExponent>
        \\    <cim:LoadResponseCharacteristic.qVoltageExponent> 1e0 </cim:LoadResponseCharacteristic.qVoltageExponent>
        \\  </cim:LoadResponseCharacteristic>
        \\</rdf:RDF>
    );
}

test "LRCExponentModel ignores objects whose exponent model is not true" {
    try run_load_response_characteristic_exponent_model(
        \\<rdf:RDF>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_FALSE">
        \\    <cim:LoadResponseCharacteristic.exponentModel>false</cim:LoadResponseCharacteristic.exponentModel>
        \\    <cim:LoadResponseCharacteristic.pVoltageExponent>invalid</cim:LoadResponseCharacteristic.pVoltageExponent>
        \\  </cim:LoadResponseCharacteristic>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_ABSENT">
        \\    <cim:LoadResponseCharacteristic.pVoltageExponent>-1</cim:LoadResponseCharacteristic.pVoltageExponent>
        \\    <cim:LoadResponseCharacteristic.qVoltageExponent>3</cim:LoadResponseCharacteristic.qVoltageExponent>
        \\  </cim:LoadResponseCharacteristic>
        \\</rdf:RDF>
    );
}

test "LRCExponentModel ignores frequency exponents and coefficient properties" {
    try run_load_response_characteristic_exponent_model(
        \\<rdf:RDF>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_LRC1">
        \\    <cim:LoadResponseCharacteristic.exponentModel>true</cim:LoadResponseCharacteristic.exponentModel>
        \\    <cim:LoadResponseCharacteristic.pVoltageExponent>1</cim:LoadResponseCharacteristic.pVoltageExponent>
        \\    <cim:LoadResponseCharacteristic.qVoltageExponent>1</cim:LoadResponseCharacteristic.qVoltageExponent>
        \\    <cim:LoadResponseCharacteristic.pFrequencyExponent>invalid</cim:LoadResponseCharacteristic.pFrequencyExponent>
        \\    <cim:LoadResponseCharacteristic.qFrequencyExponent>-100</cim:LoadResponseCharacteristic.qFrequencyExponent>
        \\    <cim:LoadResponseCharacteristic.pConstantPower>invalid</cim:LoadResponseCharacteristic.pConstantPower>
        \\  </cim:LoadResponseCharacteristic>
        \\</rdf:RDF>
    );
}

test "LRCExponentModel rejects missing voltage exponents" {
    try std.testing.expectError(error.LRCExponentModel, run_load_response_characteristic_exponent_model(
        \\<rdf:RDF>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_LRC1">
        \\    <cim:LoadResponseCharacteristic.exponentModel>true</cim:LoadResponseCharacteristic.exponentModel>
        \\    <cim:LoadResponseCharacteristic.qVoltageExponent>1</cim:LoadResponseCharacteristic.qVoltageExponent>
        \\  </cim:LoadResponseCharacteristic>
        \\</rdf:RDF>
    ));
    try std.testing.expectError(error.LRCExponentModel, run_load_response_characteristic_exponent_model(
        \\<rdf:RDF>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_LRC1">
        \\    <cim:LoadResponseCharacteristic.exponentModel>true</cim:LoadResponseCharacteristic.exponentModel>
        \\    <cim:LoadResponseCharacteristic.pVoltageExponent>1</cim:LoadResponseCharacteristic.pVoltageExponent>
        \\  </cim:LoadResponseCharacteristic>
        \\</rdf:RDF>
    ));
}

test "LRCExponentModel rejects exponents outside the inclusive range" {
    try std.testing.expectError(
        error.LRCExponentModel,
        run_load_response_characteristic_exponent_values("-0.01", "1"),
    );
    try std.testing.expectError(
        error.LRCExponentModel,
        run_load_response_characteristic_exponent_values("1", "-0.01"),
    );
    try std.testing.expectError(
        error.LRCExponentModel,
        run_load_response_characteristic_exponent_values("2.01", "1"),
    );
    try std.testing.expectError(
        error.LRCExponentModel,
        run_load_response_characteristic_exponent_values("1", "2.01"),
    );
}

test "LRCExponentModel rejects invalid and non-finite exponents" {
    try std.testing.expectError(
        error.LRCExponentModel,
        run_load_response_characteristic_exponent_values("invalid", "1"),
    );
    try std.testing.expectError(
        error.LRCExponentModel,
        run_load_response_characteristic_exponent_values("1", " "),
    );
    try std.testing.expectError(
        error.LRCExponentModel,
        run_load_response_characteristic_exponent_values("nan", "1"),
    );
    try std.testing.expectError(
        error.LRCExponentModel,
        run_load_response_characteristic_exponent_values("1", "inf"),
    );
}

test "LRCExponentModel validates every load response characteristic" {
    try std.testing.expectError(error.LRCExponentModel, run_load_response_characteristic_exponent_model(
        \\<rdf:RDF>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_VALID">
        \\    <cim:LoadResponseCharacteristic.exponentModel>true</cim:LoadResponseCharacteristic.exponentModel>
        \\    <cim:LoadResponseCharacteristic.pVoltageExponent>1</cim:LoadResponseCharacteristic.pVoltageExponent>
        \\    <cim:LoadResponseCharacteristic.qVoltageExponent>1</cim:LoadResponseCharacteristic.qVoltageExponent>
        \\  </cim:LoadResponseCharacteristic>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_INVALID">
        \\    <cim:LoadResponseCharacteristic.exponentModel>true</cim:LoadResponseCharacteristic.exponentModel>
        \\    <cim:LoadResponseCharacteristic.pVoltageExponent>1</cim:LoadResponseCharacteristic.pVoltageExponent>
        \\    <cim:LoadResponseCharacteristic.qVoltageExponent>3</cim:LoadResponseCharacteristic.qVoltageExponent>
        \\  </cim:LoadResponseCharacteristic>
        \\</rdf:RDF>
    ));
}

test "LCRCoefficientModel accepts all six ZIP coefficients" {
    try run_load_response_characteristic_coefficients(.{
        "0.1",
        "0.2",
        "0.7",
        "0.3",
        "0.2",
        "0.5",
    });
}

test "LCRCoefficientModel accepts surrounding whitespace" {
    try run_load_response_characteristic_coefficient_model(
        \\<rdf:RDF>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_LRC1">
        \\    <cim:LoadResponseCharacteristic.exponentModel> false </cim:LoadResponseCharacteristic.exponentModel>
        \\    <cim:LoadResponseCharacteristic.pConstantImpedance> 0.1 </cim:LoadResponseCharacteristic.pConstantImpedance>
        \\    <cim:LoadResponseCharacteristic.pConstantCurrent> 0.2 </cim:LoadResponseCharacteristic.pConstantCurrent>
        \\    <cim:LoadResponseCharacteristic.pConstantPower> 0.7 </cim:LoadResponseCharacteristic.pConstantPower>
        \\    <cim:LoadResponseCharacteristic.qConstantImpedance> 0.3 </cim:LoadResponseCharacteristic.qConstantImpedance>
        \\    <cim:LoadResponseCharacteristic.qConstantCurrent> 0.2 </cim:LoadResponseCharacteristic.qConstantCurrent>
        \\    <cim:LoadResponseCharacteristic.qConstantPower> 0.5 </cim:LoadResponseCharacteristic.qConstantPower>
        \\  </cim:LoadResponseCharacteristic>
        \\</rdf:RDF>
    );
}

test "LCRCoefficientModel ignores objects whose exponent model is not false" {
    try run_load_response_characteristic_coefficient_model(
        \\<rdf:RDF>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_TRUE">
        \\    <cim:LoadResponseCharacteristic.exponentModel>true</cim:LoadResponseCharacteristic.exponentModel>
        \\  </cim:LoadResponseCharacteristic>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_ABSENT"/>
        \\</rdf:RDF>
    );
}

test "LCRCoefficientModel ignores exponential-model attributes" {
    try run_load_response_characteristic_coefficient_model(
        \\<rdf:RDF>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_LRC1">
        \\    <cim:LoadResponseCharacteristic.exponentModel>false</cim:LoadResponseCharacteristic.exponentModel>
        \\    <cim:LoadResponseCharacteristic.pVoltageExponent>invalid</cim:LoadResponseCharacteristic.pVoltageExponent>
        \\    <cim:LoadResponseCharacteristic.qVoltageExponent>-100</cim:LoadResponseCharacteristic.qVoltageExponent>
        \\    <cim:LoadResponseCharacteristic.pConstantImpedance>0.1</cim:LoadResponseCharacteristic.pConstantImpedance>
        \\    <cim:LoadResponseCharacteristic.pConstantCurrent>0.2</cim:LoadResponseCharacteristic.pConstantCurrent>
        \\    <cim:LoadResponseCharacteristic.pConstantPower>0.7</cim:LoadResponseCharacteristic.pConstantPower>
        \\    <cim:LoadResponseCharacteristic.qConstantImpedance>0.3</cim:LoadResponseCharacteristic.qConstantImpedance>
        \\    <cim:LoadResponseCharacteristic.qConstantCurrent>0.2</cim:LoadResponseCharacteristic.qConstantCurrent>
        \\    <cim:LoadResponseCharacteristic.qConstantPower>0.5</cim:LoadResponseCharacteristic.qConstantPower>
        \\  </cim:LoadResponseCharacteristic>
        \\</rdf:RDF>
    );
}

test "LCRCoefficientModel rejects each missing ZIP coefficient" {
    for (0..6) |missing_index| {
        var coefficients: [6]?[]const u8 = .{
            "0.1",
            "0.2",
            "0.7",
            "0.3",
            "0.2",
            "0.5",
        };
        coefficients[missing_index] = null;
        try std.testing.expectError(
            error.LCRCoefficientModel,
            run_load_response_characteristic_coefficients(coefficients),
        );
    }
}

test "LCRCoefficientModel rejects a blank ZIP coefficient" {
    try std.testing.expectError(
        error.LCRCoefficientModel,
        run_load_response_characteristic_coefficients(.{
            "0.1",
            "0.2",
            " ",
            "0.3",
            "0.2",
            "0.5",
        }),
    );
}

test "LCRCoefficientParameters accepts active and reactive sums of one" {
    try run_load_response_characteristic_coefficient_parameter_values(.{
        "0.1",
        "0.2",
        "0.7",
        "0.3",
        "0.2",
        "0.5",
    });
}

test "LCRCoefficientParameters applies NUMERIC_TOLERANCE" {
    try run_load_response_characteristic_coefficient_parameter_values(.{
        "0.1",
        "0.2",
        "0.7004",
        "0.3",
        "0.2",
        "0.4996",
    });
}

test "LCRCoefficientParameters rejects an invalid active-power sum" {
    try std.testing.expectError(
        error.LCRCoefficientParameters,
        run_load_response_characteristic_coefficient_parameter_values(.{
            "0.1",
            "0.2",
            "0.7006",
            "0.3",
            "0.2",
            "0.5",
        }),
    );
}

test "LCRCoefficientParameters rejects an invalid reactive-power sum" {
    try std.testing.expectError(
        error.LCRCoefficientParameters,
        run_load_response_characteristic_coefficient_parameter_values(.{
            "0.1",
            "0.2",
            "0.7",
            "0.3",
            "0.2",
            "0.4994",
        }),
    );
}

test "LCRCoefficientParameters rejects missing and invalid coefficients" {
    try std.testing.expectError(
        error.LCRCoefficientParameters,
        run_load_response_characteristic_coefficient_parameter_values(.{
            null,
            "0.2",
            "0.8",
            "0.3",
            "0.2",
            "0.5",
        }),
    );
    try std.testing.expectError(
        error.LCRCoefficientParameters,
        run_load_response_characteristic_coefficient_parameter_values(.{
            "0.1",
            " ",
            "0.9",
            "0.3",
            "0.2",
            "0.5",
        }),
    );
    try std.testing.expectError(
        error.LCRCoefficientParameters,
        run_load_response_characteristic_coefficient_parameter_values(.{
            "invalid",
            "0.2",
            "0.8",
            "0.3",
            "0.2",
            "0.5",
        }),
    );
    try std.testing.expectError(
        error.LCRCoefficientParameters,
        run_load_response_characteristic_coefficient_parameter_values(.{
            "0.1",
            "0.2",
            "0.7",
            "0.3",
            "inf",
            "0.7",
        }),
    );
}

test "LCRCoefficientParameters ignores objects whose exponent model is not false" {
    try run_load_response_characteristic_coefficient_parameters(
        \\<rdf:RDF>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_TRUE">
        \\    <cim:LoadResponseCharacteristic.exponentModel>true</cim:LoadResponseCharacteristic.exponentModel>
        \\  </cim:LoadResponseCharacteristic>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_ABSENT"/>
        \\</rdf:RDF>
    );
}

test "MeasTerminal accepts a measurement terminal on the referenced equipment" {
    try run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\  </cim:Terminal>
        \\  <cim:Analog rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>ThreePhasePower</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_T1"/>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="#_BR1"/>
        \\  </cim:Analog>
        \\</rdf:RDF>
    );
}

test "MeasTerminal compares resolved equipment identifiers" {
    try run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\  </cim:Terminal>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>LineCurrent</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_T1"/>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="_BR1"/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    );
}

test "MeasTerminal validates a measurement whose type is absent" {
    try run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\  </cim:Terminal>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.Terminal rdf:resource="#_T1"/>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="#_BR1"/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    );
}

test "MeasTerminal exempts tap and switch position measurements" {
    try run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Discrete rdf:ID="_TAP">
        \\    <cim:Measurement.measurementType>
        \\      TapPosition
        \\    </cim:Measurement.measurementType>
        \\  </cim:Discrete>
        \\  <cim:Discrete rdf:ID="_SWITCH">
        \\    <cim:Measurement.measurementType>SwitchPosition</cim:Measurement.measurementType>
        \\  </cim:Discrete>
        \\</rdf:RDF>
    );
}

test "MeasTerminal rejects a terminal on different equipment" {
    try std.testing.expectError(error.MeasTerminal, run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Breaker rdf:ID="_BR2"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\  </cim:Terminal>
        \\  <cim:Analog rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>ThreePhasePower</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_T1"/>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="#_BR2"/>
        \\  </cim:Analog>
        \\</rdf:RDF>
    ));
}

test "MeasTerminal rejects targets that are not equipment terminals" {
    try std.testing.expectError(error.MeasTerminal, run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Breaker rdf:ID="_NOT_TERMINAL">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\  </cim:Breaker>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>LineCurrent</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_NOT_TERMINAL"/>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="#_BR1"/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    ));
    try std.testing.expectError(error.MeasTerminal, run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:ConnectivityNode rdf:ID="_CN1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_CN1"/>
        \\  </cim:Terminal>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>LineCurrent</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_T1"/>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="#_CN1"/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    ));
}

test "MeasTerminal rejects missing required associations" {
    try std.testing.expectError(error.MeasTerminal, run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>LineCurrent</cim:Measurement.measurementType>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="#_BR1"/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    ));
    try std.testing.expectError(error.MeasTerminal, run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1"/>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>LineCurrent</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_T1"/>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="#_BR1"/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    ));
    try std.testing.expectError(error.MeasTerminal, run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\  </cim:Terminal>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>LineCurrent</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_T1"/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    ));
}

test "MeasTerminal rejects dangling references" {
    try std.testing.expectError(error.MeasTerminal, run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>LineCurrent</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_MISSING"/>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="#_MISSING_TOO"/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    ));
    try std.testing.expectError(error.MeasTerminal, run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_MISSING"/>
        \\  </cim:Terminal>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>LineCurrent</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_T1"/>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="#_MISSING"/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    ));
    try std.testing.expectError(error.MeasTerminal, run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\  </cim:Terminal>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>LineCurrent</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_T1"/>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="#_MISSING"/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    ));
}

test "MeasTerminal rejects malformed reference attributes" {
    try std.testing.expectError(error.MeasTerminal, run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>LineCurrent</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_T1/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    ));
    try std.testing.expectError(error.MeasTerminal, run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1/>
        \\  </cim:Terminal>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>LineCurrent</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_T1"/>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="#_BR1"/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    ));
    try std.testing.expectError(error.MeasTerminal, run_measurement_terminal(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_BR1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BR1"/>
        \\  </cim:Terminal>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType>LineCurrent</cim:Measurement.measurementType>
        \\    <cim:Measurement.Terminal rdf:resource="#_T1"/>
        \\    <cim:Measurement.PowerSystemResource rdf:resource="#_BR1/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    ));
}

test "MeasType accepts every measurement type allowed in both versions" {
    const allowed_types = [_][]const u8{
        "ThreePhasePower",
        "ThreePhaseActivePower",
        "ThreePhaseReactivePower",
        "LineCurrent",
        "PhaseVoltage",
        "Angle",
        "TapPosition",
        "SwitchPosition",
    };
    for (allowed_types) |measurement_type| {
        try run_measurement_type_value(measurement_type, .v2_4_15);
        try run_measurement_type_value(measurement_type, .v3_0);
        try run_measurement_type_value(measurement_type, null);
    }
}

test "MeasType applies the voltage type of the declared version" {
    try run_measurement_type_value("LineToLineVoltage", .v2_4_15);
    try run_measurement_type_value("Voltage", .v3_0);
    try std.testing.expectError(
        error.MeasType,
        run_measurement_type_value("Voltage", .v2_4_15),
    );
    try std.testing.expectError(
        error.MeasType,
        run_measurement_type_value("LineToLineVoltage", .v3_0),
    );
}

test "MeasType accepts either voltage type when the header declares no version" {
    try run_measurement_type_value("LineToLineVoltage", null);
    try run_measurement_type_value("Voltage", null);
    try std.testing.expectError(error.MeasType, run_measurement_type_value("Power", null));
}

test "MeasType accepts subclasses and surrounding whitespace" {
    try run_measurement_type(
        \\<rdf:RDF>
        \\  <cim:Analog rdf:ID="_ANALOG">
        \\    <cim:Measurement.measurementType>
        \\      ThreePhasePower
        \\    </cim:Measurement.measurementType>
        \\  </cim:Analog>
        \\  <cim:Accumulator rdf:ID="_ACCUMULATOR">
        \\    <cim:Measurement.measurementType>Angle</cim:Measurement.measurementType>
        \\  </cim:Accumulator>
        \\  <cim:Discrete rdf:ID="_DISCRETE">
        \\    <cim:Measurement.measurementType>SwitchPosition</cim:Measurement.measurementType>
        \\  </cim:Discrete>
        \\</rdf:RDF>
    , .v2_4_15);
}

test "MeasType rejects unknown, incorrectly cased, and blank values" {
    try std.testing.expectError(error.MeasType, run_measurement_type_value("Power", .v2_4_15));
    try std.testing.expectError(error.MeasType, run_measurement_type_value("threephasepower", .v2_4_15));
    try std.testing.expectError(error.MeasType, run_measurement_type_value("   ", .v2_4_15));
}

test "MeasType rejects an empty value in either serialization" {
    try std.testing.expectError(error.MeasType, run_measurement_type(
        \\<rdf:RDF>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    , .v2_4_15));
    try std.testing.expectError(error.MeasType, run_measurement_type(
        \\<rdf:RDF>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.measurementType></cim:Measurement.measurementType>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    , .v2_4_15));
}

test "MeasType ignores absent values and non-measurement objects" {
    try run_measurement_type(
        \\<rdf:RDF>
        \\  <cim:Measurement rdf:ID="_MISSING"/>
        \\  <cim:Breaker rdf:ID="_UNRELATED">
        \\    <cim:Measurement.measurementType>invalid</cim:Measurement.measurementType>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    , .v2_4_15);
}

test "MeasUnit accepts every CGMES 2.4.15 unit-symbol reference" {
    const allowed_units = [_][]const u8{
        "http://iec.ch/TC57/CIM100#UnitSymbol.V",
        "http://iec.ch/TC57/CIM100#UnitSymbol.A",
        "http://iec.ch/TC57/CIM100#UnitSymbol.W",
        "http://iec.ch/TC57/CIM100#UnitSymbol.VA",
        "http://iec.ch/TC57/CIM100#UnitSymbol.VAr",
        "http://iec.ch/TC57/CIM100#UnitSymbol.deg",
        "http://iec.ch/TC57/CIM100#UnitSymbol.Hz",
        "http://iec.ch/TC57/CIM100#UnitSymbol.none",
    };
    for (allowed_units) |unit_reference| try run_measurement_unit_reference(unit_reference);
}

test "MeasUnit accepts local and legacy-namespace references" {
    try run_measurement_unit_reference("#UnitSymbol.V");
    try run_measurement_unit_reference("http://iec.ch/TC57/2013/CIM-schema-cim16#UnitSymbol.VAr");
}

test "MeasUnit rejects unknown, incorrectly cased, and blank references" {
    try std.testing.expectError(
        error.MeasUnit,
        run_measurement_unit_reference("http://iec.ch/TC57/CIM100#UnitSymbol.ohm"),
    );
    try std.testing.expectError(
        error.MeasUnit,
        run_measurement_unit_reference("http://iec.ch/TC57/CIM100#UnitSymbol.var"),
    );
    try std.testing.expectError(error.MeasUnit, run_measurement_unit_reference(""));
}

test "MeasUnit accepts measurement subclasses and ignores absent values" {
    try run_measurement_unit(
        \\<rdf:RDF>
        \\  <cim:Analog rdf:ID="_ANALOG">
        \\    <cim:Measurement.unitSymbol rdf:resource="#UnitSymbol.V"/>
        \\  </cim:Analog>
        \\  <cim:Accumulator rdf:ID="_ACCUMULATOR">
        \\    <cim:Measurement.unitSymbol rdf:resource="#UnitSymbol.none"/>
        \\  </cim:Accumulator>
        \\  <cim:Discrete rdf:ID="_MISSING"/>
        \\  <cim:Breaker rdf:ID="_UNRELATED">
        \\    <cim:Measurement.unitSymbol rdf:resource="#UnitSymbol.invalid"/>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    , .v2_4_15);
}

test "MeasUnit rejects malformed reference attributes" {
    try std.testing.expectError(error.MeasUnit, run_measurement_unit(
        \\<rdf:RDF>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.unitSymbol rdf:resource="#UnitSymbol.V/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    , .v2_4_15));
    try std.testing.expectError(error.MeasUnit, run_measurement_unit(
        \\<rdf:RDF>
        \\  <cim:Analog rdf:ID="_M1">
        \\    <cim:Measurement.unitSymbol rdf:resource="#UnitSymbol.V/>
        \\  </cim:Analog>
        \\</rdf:RDF>
    , .v3_0));
}

test "MeasUnit rejects a unitSymbol declared without a readable reference" {
    try std.testing.expectError(error.MeasUnit, run_measurement_unit(
        \\<rdf:RDF>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.unitSymbol>UnitSymbol.V</cim:Measurement.unitSymbol>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    , .v2_4_15));
    try std.testing.expectError(error.MeasUnit, run_measurement_unit(
        \\<rdf:RDF>
        \\  <cim:Measurement rdf:ID="_M1">
        \\    <cim:Measurement.unitSymbol/>
        \\  </cim:Measurement>
        \\</rdf:RDF>
    , .v2_4_15));
    try std.testing.expectError(error.MeasUnit, run_measurement_unit(
        \\<rdf:RDF>
        \\  <cim:Accumulator rdf:ID="_M1">
        \\    <cim:Measurement.unitSymbol>UnitSymbol.Wh</cim:Measurement.unitSymbol>
        \\  </cim:Accumulator>
        \\</rdf:RDF>
    , .v3_0));
}

test "MeasUnit accepts every class-specific CGMES 3.0 unit" {
    const cases = [_]struct {
        type_name: []const u8,
        units: []const []const u8,
    }{
        .{ .type_name = "Analog", .units = &.{
            "UnitSymbol.W",
            "UnitSymbol.deg",
            "UnitSymbol.VA",
            "UnitSymbol.A",
            "UnitSymbol.VAr",
            "UnitSymbol.V",
            "UnitSymbol.Hz",
        } },
        .{ .type_name = "Accumulator", .units = &.{
            "UnitSymbol.VAh",
            "UnitSymbol.VArh",
            "UnitSymbol.Wh",
        } },
        .{ .type_name = "Discrete", .units = &.{"UnitSymbol.none"} },
    };

    for (cases) |case| {
        for (case.units) |unit| {
            try run_measurement_unit_type_reference(case.type_name, unit, .v3_0);
        }
    }
}

test "MeasUnit rejects CGMES 3.0 units belonging to another measurement class" {
    const cases = [_]struct {
        type_name: []const u8,
        unit: []const u8,
    }{
        .{ .type_name = "Analog", .unit = "UnitSymbol.Wh" },
        .{ .type_name = "Analog", .unit = "UnitSymbol.none" },
        .{ .type_name = "Accumulator", .unit = "UnitSymbol.V" },
        .{ .type_name = "Discrete", .unit = "UnitSymbol.W" },
    };

    for (cases) |case| {
        try std.testing.expectError(
            error.MeasUnit,
            run_measurement_unit_type_reference(case.type_name, case.unit, .v3_0),
        );
    }
}

test "MeasUnit leaves unconstrained CGMES 3.0 measurement classes alone" {
    try run_measurement_unit_type_reference("Measurement", "UnitSymbol.ohm", .v3_0);
    try run_measurement_unit_type_reference("StringMeasurement", "UnitSymbol.ohm", .v3_0);
}

test "MeasUnit accepts either applicable list when the version is unresolved" {
    try run_measurement_unit_type_reference("Accumulator", "UnitSymbol.V", null);
    try run_measurement_unit_type_reference("Accumulator", "UnitSymbol.Wh", null);
    try std.testing.expectError(
        error.MeasUnit,
        run_measurement_unit_type_reference("Accumulator", "UnitSymbol.ohm", null),
    );

    // A direct Measurement may belong to v3.0, whose 452 constraint does not
    // supply a class-specific unit list for it.
    try run_measurement_unit_type_reference("Measurement", "UnitSymbol.ohm", null);
}

test "CNRequiredInEQOperations accepts valid references in applicable profiles" {
    const applicable_profiles = [_][]const u8{
        "http://entsoe.eu/CIM/EquipmentOperation/3/1",
        "http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0",
        "http://iec.ch/TC57/ns/CIM/Operation-EU/3.0",
        "http://iec.ch/TC57/ns/CIM/ShortCircuit-EU/3.0",
    };
    for (applicable_profiles) |profile_uri| {
        try run_conn_node_in_profile(
            profile_uri,
            "<cim:Terminal rdf:ID=\"_T1\">" ++
                "<cim:Terminal.ConnectivityNode rdf:resource=\"#_CN1\"/>" ++
                "</cim:Terminal>" ++
                "<cim:Terminal rdf:ID=\"_T2\">" ++
                "<cim:Terminal.ConnectivityNode rdf:resource=\"urn:uuid:cn2\"/>" ++
                "</cim:Terminal>",
        );
    }
}

test "CNRequiredInEQOperations rejects a missing reference in every applicable profile" {
    const applicable_profiles = [_][]const u8{
        "http://entsoe.eu/CIM/EquipmentOperation/3/1",
        "http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0",
        "http://iec.ch/TC57/ns/CIM/Operation-EU/3.0",
        "http://iec.ch/TC57/ns/CIM/ShortCircuit-EU/3.0",
    };
    for (applicable_profiles) |profile_uri| {
        try std.testing.expectError(
            error.CNRequiredInEQOperations,
            run_conn_node_in_profile(profile_uri, "<cim:Terminal rdf:ID=\"_T1\"/>"),
        );
    }
}

test "CNRequiredInEQOperations skips non-operation v2 and non-equipment v3 profiles" {
    const skipped_profiles = [_][]const u8{
        "http://entsoe.eu/CIM/EquipmentCore/3/1",
        "http://entsoe.eu/CIM/EquipmentShortCircuit/3/1",
        "http://iec.ch/TC57/ns/CIM/Topology-EU/3.0",
    };
    for (skipped_profiles) |profile_uri| {
        try run_conn_node_in_profile(profile_uri, "<cim:Terminal rdf:ID=\"_T1\"/>");
    }
}

test "CNRequiredInEQOperations rejects empty and malformed references" {
    const operation_profile = "http://entsoe.eu/CIM/EquipmentOperation/3/1";
    try std.testing.expectError(
        error.CNRequiredInEQOperations,
        run_conn_node_in_profile(
            operation_profile,
            "<cim:Terminal rdf:ID=\"_T1\">" ++
                "<cim:Terminal.ConnectivityNode rdf:resource=\"\"/>" ++
                "</cim:Terminal>",
        ),
    );
    try std.testing.expectError(
        error.CNRequiredInEQOperations,
        run_conn_node_in_profile(
            operation_profile,
            "<cim:Terminal rdf:ID=\"_T1\">" ++
                "<cim:Terminal.ConnectivityNode rdf:resource=\"   \"/>" ++
                "</cim:Terminal>",
        ),
    );
    try std.testing.expectError(
        error.CNRequiredInEQOperations,
        run_conn_node_in_profile(
            operation_profile,
            "<cim:Terminal rdf:ID=\"_T1\">" ++
                "<cim:Terminal.ConnectivityNode rdf:resource=\"#_CN1/>" ++
                "</cim:Terminal>",
        ),
    );
}

test "CNRequiredInEQOperations checks every Terminal and ignores other types" {
    const operation_profile = "http://entsoe.eu/CIM/EquipmentOperation/3/1";
    try std.testing.expectError(
        error.CNRequiredInEQOperations,
        run_conn_node_in_profile(
            operation_profile,
            "<cim:Terminal rdf:ID=\"_VALID\">" ++
                "<cim:Terminal.ConnectivityNode rdf:resource=\"#_CN1\"/>" ++
                "</cim:Terminal>" ++
                "<cim:Terminal rdf:ID=\"_MISSING\"/>",
        ),
    );

    try run_conn_node_in_profile(
        operation_profile,
        "<cim:ACDCTerminal rdf:ID=\"_ACDC\"/>" ++
            "<cim:DCTerminal rdf:ID=\"_DC\"/>" ++
            "<cim:Breaker rdf:ID=\"_BREAKER\">" ++
            "<cim:Terminal.ConnectivityNode rdf:resource=\"\"/>" ++
            "</cim:Breaker>",
    );
}
