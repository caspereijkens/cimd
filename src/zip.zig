const std = @import("std");

// returns true if 'file' starts with PK34.
pub fn isZipFile(file: std.fs.File) !bool {
    var magic: [4]u8 = undefined;
    const bytes_read = try file.pread(&magic, 0); // pread does not advance offset

    if (bytes_read < 4) return false;

    return std.mem.eql(u8, &magic, &std.zip.local_file_header_sig);
}

// Modified ZIP extraction function from the std lib.
// This function first checks if the file was already extracted.
pub fn extract(gpa: std.mem.Allocator, dest: std.fs.Dir, fr: *std.fs.File.Reader, options: std.zip.ExtractOptions) !std.ArrayList([]const u8) {
    var extracted_files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (extracted_files.items) |filename| {
            gpa.free(filename);
        }
        extracted_files.deinit(gpa);
    }

    var iter = try std.zip.Iterator.init(fr);
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (try iter.next()) |entry| {
        // Read the filename first (before extracting)
        const filename = filename_buf[0..entry.filename_len];
        {
            try fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
            try fr.interface.readSliceAll(filename);
        }

        // Normalize backslashes if needed
        if (options.allow_backslashes) {
            std.mem.replaceScalar(u8, filename, '\\', '/');
        }

        // Check if we should extract this file
        const should_extract = blk: {
            const stat = dest.statFile(filename) catch |err| {
                if (err == error.FileNotFound) break :blk true; // File doesn't exist, extract
                return err; // Other errors should be propagated
            };

            // Directories always end in '/' - if it exists, skip
            if (filename[filename.len - 1] == '/') break :blk false;

            // Check if size matches
            if (stat.size != entry.uncompressed_size) break :blk true; // Size mismatch, re-extract

            break :blk false; // File exists with correct size, skip
        };

        // Add the filename to the list of extracted files.
        const filename_path = try std.fmt.allocPrint(gpa, ".cimd/{s}", .{filename});
        errdefer gpa.free(filename_path);
        try extracted_files.append(gpa, filename_path);

        if (!should_extract) {
            std.debug.print("Skipping already extracted: {s}\n", .{filename});
            continue;
        }

        // File doesn't exist or needs re-extraction, now using the std lib extraction method.
        try entry.extract(fr, options, &filename_buf, dest);
    }

    return extracted_files;
}

test "isZipFile" {
    // Happy flow
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    var file = try tmpdir.dir.createFile("temp", .{ .read = true });
    defer file.close();

    var bytes = [_]u8{ 'P', 'K', 3, 4, 'Z', 'Z', 'Z' };
    _ = try file.pwrite(&bytes, 0);

    try std.testing.expect(try isZipFile(file));

    // Unhappy flow 1: file too short
    try file.setEndPos(3); // this truncates the file.
    try std.testing.expect(!(try isZipFile(file)));

    // Unhappy flow 2: no local file header signature
    bytes = [_]u8{ 'Z', 'Z', 'Z', 'Z', 'Z', 'Z', 'Z' };
    _ = try file.pwrite(&bytes, 0);

    try std.testing.expect(!(try isZipFile(file)));
}

