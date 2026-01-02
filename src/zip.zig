const std = @import("std");

// A correctly structured Zip file starts with a local file header (see https://pkwaredownloads.blob.core.windows.net/pem/APPNOTE.txt "4.3.6 Overall .ZIP file format")
const local_file_header_sig = [4]u8{ 'P', 'K', 3, 4 };

//pub fn isZipFile(file_path: []const u8) !bool {
//    const file = try std.fs.cwd().openFile(file_path, .{});
//    defer file.close();
//
//    var magic: [4]u8 = undefined;
//    const bytes_read = try file.pread(&magic, 0);
//
//    if (bytes_read < 4) return false;
//
//    return std.mem.eql(u8, &magic, &local_file_header_sig); // PK\x03\x04
//}

pub fn isZipFile(file: std.fs.File) !bool {
    var magic: [4]u8 = undefined;
    const bytes_read = try file.pread(&magic, 0); // pread does not advance offset

    if (bytes_read < 4) return false;

    return std.mem.eql(u8, &magic, &local_file_header_sig);
}

test "isZipFile" {
    // Happy flow
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    var file = try tmpdir.dir.createFile("temp", .{.read=true});
    defer file.close();

    var bytes = [_]u8{'P', 'K', 3, 4, 'Z', 'Z', 'Z'};
    _ = try file.pwrite(&bytes, 0);

    try std.testing.expect(try isZipFile(file));

    // Unhappy flow 1: file too short
    try file.setEndPos(3);
    try std.testing.expect(!(try isZipFile(file)));

    // Unhappy flow 2: no local file header signature
    bytes = [_]u8{'Z', 'Z', 'Z', 'Z', 'Z', 'Z', 'Z'};
    _ = try file.pwrite(&bytes, 0);
    
    try std.testing.expect(!(try isZipFile(file)));
}
