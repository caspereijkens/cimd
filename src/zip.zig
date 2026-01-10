//! ZIP extraction utilities for the cimd project
//!
//! ATTRIBUTION:
//! Large portions of this file are adapted from Zig's standard library (std/zip.zig).
//! The original std.zip implementation extracts to files on disk. This module has been
//! modified to extract ZIP archives directly into memory for in-memory processing.
//!
//! Key differences from std.zip:
//! - Added `extractToMemory()` and `extractEntryToMemory()` functions that decompress
//!   to memory buffers instead of files
//! - Removed ZIP64 support (files >4GB) to simplify code and match our u32 indexing limits
//! - Added `isBadFilename()` helper (copied from std.zip internal)
//! - Simplified `parseAndValidateLocalHeader()` by removing ZIP64 extra field parsing
//!
//! Functions marked "adapted from std.zip" contain logic derived from the standard library.
//! Functions marked "custom implementation" are original to this project.
//!
//! See: https://codeberg.org/ziglang/zig/src/branch/master/lib/std/zip.zig

const std = @import("std");

// returns true if 'file' starts with PK34.
pub fn isZipFile(file: std.fs.File) !bool {
    var magic: [4]u8 = undefined;
    const bytes_read = try file.pread(&magic, 0); // pread does not advance offset

    if (bytes_read < 4) return false;

    return std.mem.eql(u8, &magic, &std.zip.local_file_header_sig);
}

/// Represents a file extracted from a ZIP archive into memory
/// Custom implementation for in-memory extraction
pub const ExtractedFile = struct {
    filename: []u8,
    data: []u8,

    pub fn deinit(self: ExtractedFile, gpa: std.mem.Allocator) void {
        gpa.free(self.filename);
        gpa.free(self.data);
    }
};

/// Helper to check if filename contains path traversal or other unsafe patterns
/// Copied from std.zip internal implementation
fn isBadFilename(filename: []const u8) bool {
    if (filename.len == 0 or filename[0] == '/')
        return true;

    var it = std.mem.splitScalar(u8, filename, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".."))
            return true;
    }

    return false;
}

/// Parse and validate the local file header for a ZIP entry
/// Returns the offset where the compressed data starts (relative to local header)
///
/// Adapted from std.zip.Iterator.Entry.extract() - simplified version without ZIP64 support.
/// Key changes:
/// - Rejects files larger than 4GB (our SIMD scanner uses u32 positions)
/// - Removed ZIP64 extra field parsing (significantly reduces complexity)
/// - Removed timestamp and CRC validation (kept only critical fields)
fn parseAndValidateLocalHeader(
    entry: std.zip.Iterator.Entry,
    stream: *std.fs.File.Reader,
) !u64 {
    // Reject files >4GB (our SIMD scanner uses u32 positions)
    if (entry.uncompressed_size > std.math.maxInt(u32)) {
        return error.FileTooLarge;
    }

    // Seek to and read the local file header
    try stream.seekTo(entry.file_offset);
    const local_header = stream.interface.takeStruct(std.zip.LocalFileHeader, .little) catch |err| switch (err) {
        error.ReadFailed => return stream.err.?,
        error.EndOfStream => return error.EndOfStream,
    };

    // Validate header signature
    if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig))
        return error.ZipBadFileOffset;

    // Validate critical fields match central directory
    if (local_header.version_needed_to_extract != entry.version_needed_to_extract)
        return error.ZipMismatchVersionNeeded;
    if (@as(u16, @bitCast(local_header.flags)) != @as(u16, @bitCast(entry.flags)))
        return error.ZipMismatchFlags;
    if (local_header.filename_len != entry.filename_len)
        return error.ZipMismatchFilenameLen;

    // Return offset where compressed data starts (skip filename + extra fields)
    return @as(u64, local_header.filename_len) + @as(u64, local_header.extra_len);
}

/// Extract a single ZIP entry into memory (instead of to disk)
/// Returns ExtractedFile with filename and decompressed data
///
/// Adapted from std.zip.Iterator.Entry.extract() - modified for in-memory extraction.
/// Key changes:
/// - Allocates buffer and reads decompressed data directly into memory
/// - Uses readSliceAll() to decompress into pre-allocated buffer
/// - Returns ExtractedFile struct instead of writing to filesystem
/// - The decompression logic (DEFLATE/STORE) is identical to std.zip
///
/// Caller must call .deinit() on the result to free memory
fn extractEntryToMemory(
    entry: std.zip.Iterator.Entry,
    gpa: std.mem.Allocator,
    stream: *std.fs.File.Reader,
    options: std.zip.ExtractOptions,
) !ExtractedFile {
    // Validate compression method (only store and deflate supported)
    switch (entry.compression_method) {
        .store, .deflate => {},
        else => return error.UnsupportedCompressionMethod,
    }

    // Read filename from central directory
    const filename = try gpa.alloc(u8, entry.filename_len);
    errdefer gpa.free(filename);
    {
        try stream.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try stream.interface.readSliceAll(filename);
    }

    // Parse and validate local header
    const local_data_header_offset = try parseAndValidateLocalHeader(entry, stream);

    // Normalize backslashes to forward slashes if allowed
    if (options.allow_backslashes) {
        std.mem.replaceScalar(u8, filename, '\\', '/');
    } else {
        if (std.mem.indexOfScalar(u8, filename, '\\')) |_|
            return error.ZipFilenameHasBackslash;
    }

    // Validate filename for security (no path traversal)
    if (isBadFilename(filename))
        return error.ZipBadFilename;

    // Handle directory entries (end with '/')
    if (filename[filename.len - 1] == '/') {
        if (entry.uncompressed_size != 0)
            return error.ZipBadDirectorySize;

        // Directories have no data
        return .{
            .filename = filename,
            .data = &[_]u8{},
        };
    }

    // Allocate buffer for decompressed data
    const data = try gpa.alloc(u8, entry.uncompressed_size);
    errdefer gpa.free(data);

    // Seek to the compressed data
    const local_data_file_offset: u64 =
        @as(u64, entry.file_offset) +
        @as(u64, @sizeOf(std.zip.LocalFileHeader)) +
        local_data_header_offset;
    try stream.seekTo(local_data_file_offset);

    // Decompress the data based on compression method
    switch (entry.compression_method) {
        .store => {
            // No compression - just copy bytes directly into buffer
            stream.interface.readSliceAll(data) catch |err| switch (err) {
                error.ReadFailed => return stream.err.?,
                error.EndOfStream => return error.ZipDecompressTruncated,
            };
        },
        .deflate => {
            // DEFLATE compression - decompress into buffer
            var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(&stream.interface, .raw, &flate_buffer);
            decompress.reader.readSliceAll(data) catch |err| switch (err) {
                error.ReadFailed => return decompress.err orelse stream.err.?,
                error.EndOfStream => return error.ZipDecompressTruncated,
            };
        },
        else => return error.UnsupportedCompressionMethod,
    }

    return .{
        .filename = filename,
        .data = data,
    };
}

/// Extract all files from a ZIP archive into memory
/// Returns ArrayList of ExtractedFile structs
///
/// Custom implementation for in-memory extraction.
/// Uses std.zip.Iterator (from std lib) for ZIP parsing,
/// but calls our custom extractEntryToMemory() instead of std.zip's file-based extraction.
///
/// Caller must call .deinit() on each file and the ArrayList
///
/// Example:
/// ```
/// var extracted = try extractToMemory(gpa, &file_reader, .{});
/// defer {
///     for (extracted.items) |f| f.deinit(gpa);
///     extracted.deinit(gpa);
/// }
/// ```
pub fn extractToMemory(
    gpa: std.mem.Allocator,
    stream: *std.fs.File.Reader,
    options: std.zip.ExtractOptions,
) !std.ArrayList(ExtractedFile) {
    var iter = try std.zip.Iterator.init(stream);

    var result: std.ArrayList(ExtractedFile) = .empty;
    errdefer {
        for (result.items) |file| {
            file.deinit(gpa);
        }
        result.deinit(gpa);
    }

    while (try iter.next()) |entry| {
        const extracted = try extractEntryToMemory(entry, gpa, stream, options);
        try result.append(gpa, extracted);
    }

    return result;
}

/// Extract ZIP archive to disk (file-based extraction with caching)
///
/// Adapted from std.zip.extract() with added optimization:
/// - Checks if files already exist before re-extracting
/// - Compares file sizes to determine if re-extraction needed
/// - Returns list of extracted file paths
///
/// For in-memory extraction, use extractToMemory() instead.
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
