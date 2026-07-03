//! ZIP extraction utilities for the cimd project
//!
//! ATTRIBUTION:
//! Large portions of this file are adapted from Zig's standard library (std/zip.zig).
//! The original std.zip implementation extracts to files on disk. This module has been
//! modified to extract ZIP archives directly into memory for in-memory processing.
//!
//! Key differences from std.zip:
//! - Added `extract_to_memory()` and `extract_entry_to_memory()` functions that decompress
//!   to memory buffers instead of files
//! - Removed ZIP64 support (files >4GB) to simplify code and match our u32 indexing limits
//! - Added `is_bad_filename()` helper (copied from std.zip internal)
//! - Simplified `parse_and_validate_local_header()` by removing ZIP64 extra field parsing
//!
//! Functions marked "adapted from std.zip" contain logic derived from the standard library.
//! Functions marked "custom implementation" are original to this project.
//!
//! See: https://codeberg.org/ziglang/zig/src/branch/master/lib/std/zip.zig

const std = @import("std");

// returns true if 'file' starts with PK34.
pub fn is_zip_file(io: std.Io, file: std.Io.File) !bool {
    var magic: [4]u8 = undefined;
    const bytes_read = try file.readPositional(io, &[_][]u8{&magic}, 0); // readPositional does not advance offset

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
fn is_bad_filename(filename: []const u8) bool {
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
fn parse_and_validate_local_header(
    entry: std.zip.Iterator.Entry,
    stream: *std.Io.File.Reader,
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
    if (local_header.last_modification_time != entry.last_modification_time)
        return error.ZipMismatchModTime;
    if (local_header.last_modification_date != entry.last_modification_date)
        return error.ZipMismatchModDate;
    if (@as(u16, @bitCast(local_header.flags)) != @as(u16, @bitCast(entry.flags)))
        return error.ZipMismatchFlags;
    if (local_header.crc32 != 0 and local_header.crc32 != entry.crc32)
        return error.ZipMismatchCrc32;
    if (local_header.filename_len != entry.filename_len)
        return error.ZipMismatchFilenameLen;

    // Return offset where compressed data starts (skip filename + extra fields)
    return @as(u64, local_header.filename_len) + @as(u64, local_header.extra_len);
}

fn read_entry_filename(
    entry: std.zip.Iterator.Entry,
    gpa: std.mem.Allocator,
    stream: *std.Io.File.Reader,
    options: std.zip.ExtractOptions,
) ![]u8 {
    const filename = try gpa.alloc(u8, entry.filename_len);
    errdefer gpa.free(filename);

    try stream.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
    try stream.interface.readSliceAll(filename);

    if (options.allow_backslashes) {
        std.mem.replaceScalar(u8, filename, '\\', '/');
    } else {
        if (std.mem.indexOfScalar(u8, filename, '\\')) |_|
            return error.ZipFilenameHasBackslash;
    }

    if (is_bad_filename(filename))
        return error.ZipBadFilename;

    return filename;
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
fn extract_entry_to_memory(
    entry: std.zip.Iterator.Entry,
    gpa: std.mem.Allocator,
    stream: *std.Io.File.Reader,
    options: std.zip.ExtractOptions,
) !ExtractedFile {
    const filename = try read_entry_filename(entry, gpa, stream, options);
    // No errdefer here: extract_entry_with_filename takes ownership of filename
    // and frees it on any error path via its own errdefer.
    return extract_entry_with_filename(entry, gpa, stream, filename);
}

/// Like extract_entry_to_memory but takes ownership of an already-read filename,
/// avoiding a second seek+read when the caller has already inspected the name.
fn extract_entry_with_filename(
    entry: std.zip.Iterator.Entry,
    gpa: std.mem.Allocator,
    stream: *std.Io.File.Reader,
    filename: []u8,
) !ExtractedFile {
    errdefer gpa.free(filename);

    // Validate compression method (only store and deflate supported)
    switch (entry.compression_method) {
        .store, .deflate => {},
        else => return error.UnsupportedCompressionMethod,
    }

    // Parse and validate local header
    const local_data_header_offset = try parse_and_validate_local_header(entry, stream);

    // Handle directory entries (end with '/')
    if (filename[filename.len - 1] == '/') {
        if (entry.uncompressed_size != 0)
            return error.ZipBadDirectorySize;

        // Directories have no data
        const data = try gpa.alloc(u8, 0);
        return .{
            .filename = filename,
            .data = data,
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
/// but calls our custom extract_entry_to_memory() instead of std.zip's file-based extraction.
///
/// Caller must call .deinit() on each file and the ArrayList
///
/// Example:
/// ```
/// var extracted = try extract_to_memory(gpa, &file_reader, .{});
/// defer {
///     for (extracted.items) |f| f.deinit(gpa);
///     extracted.deinit(gpa);
/// }
/// ```
pub fn extract_to_memory(
    gpa: std.mem.Allocator,
    stream: *std.Io.File.Reader,
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
        const extracted = try extract_entry_to_memory(entry, gpa, stream, options);
        try result.append(gpa, extracted);
    }

    return result;
}

pub const FirstFileOptions = struct {
    extract: std.zip.ExtractOptions = .{},
    /// Maximum uncompressed size allowed for the selected archive entry.
    max_uncompressed_bytes: u64 = std.math.maxInt(u32),
    /// Extension (with dot, matched case-insensitively) selecting the entry
    /// to extract: ".xml" for data files, ".ttl" for SHACL rule bundles.
    extension: []const u8 = ".xml",
};

/// Extract the first regular file with the selected extension (skipping
/// directory and other entries) from a ZIP archive.
/// Returns error.ZipArchiveHasNoMatchingFiles when no entry matches.
pub fn extract_first_file_to_memory(
    gpa: std.mem.Allocator,
    stream: *std.Io.File.Reader,
    options: FirstFileOptions,
) !ExtractedFile {
    var iter = try std.zip.Iterator.init(stream);

    while (try iter.next()) |entry| {
        const filename = try read_entry_filename(entry, gpa, stream, options.extract);
        // filename_owned tracks whether this scope still owns the filename so that
        // errdefer only fires for early-return errors (e.g. FileTooLarge), not
        // after ownership is transferred to extract_entry_with_filename.
        var filename_owned = true;
        errdefer if (filename_owned) gpa.free(filename);

        if (filename[filename.len - 1] == '/') {
            gpa.free(filename);
            filename_owned = false;
            continue;
        }

        const ext = std.fs.path.extension(filename);
        if (!std.ascii.eqlIgnoreCase(ext, options.extension)) {
            gpa.free(filename);
            filename_owned = false;
            continue;
        }

        if (entry.uncompressed_size > options.max_uncompressed_bytes) {
            return error.FileTooLarge; // errdefer fires here (filename_owned = true)
        }

        filename_owned = false; // ownership transfers to extract_entry_with_filename
        return try extract_entry_with_filename(entry, gpa, stream, filename);
    }

    return error.ZipArchiveHasNoMatchingFiles;
}

test "is_zip_file" {
    const io = std.testing.io;

    // Happy flow
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    var file = try tmpdir.dir.createFile(io, "temp", .{ .read = true });
    defer file.close(io);

    var bytes = [_]u8{ 'P', 'K', 3, 4, 'Z', 'Z', 'Z' };
    var buf: [1][]const u8 = .{&bytes};
    _ = try file.writePositional(io, &buf, 0);

    try std.testing.expect(try is_zip_file(io, file));

    // Unhappy flow 1: file too short
    try file.setLength(io, 3); // this truncates the file.
    try std.testing.expect(!(try is_zip_file(io, file)));

    // Unhappy flow 2: no local file header signature
    bytes = [_]u8{ 'Z', 'Z', 'Z', 'Z', 'Z', 'Z', 'Z' };
    buf = [1][]const u8{&bytes};
    _ = try file.writePositional(io, &buf, 0);

    try std.testing.expect(!(try is_zip_file(io, file)));
}
