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
const assert = std.debug.assert;

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

fn read_entry_filename_into(
    entry: std.zip.Iterator.Entry,
    stream: *std.Io.File.Reader,
    options: std.zip.ExtractOptions,
    storage: []u8,
) ![]u8 {
    if (entry.filename_len == 0 or entry.filename_len > storage.len) return error.ZipBadFilename;
    const filename = storage[0..entry.filename_len];
    try stream.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
    try stream.interface.readSliceAll(filename);
    if (options.allow_backslashes) {
        std.mem.replaceScalar(u8, filename, '\\', '/');
    } else if (std.mem.indexOfScalar(u8, filename, '\\') != null) {
        return error.ZipFilenameHasBackslash;
    }
    if (is_bad_filename(filename)) return error.ZipBadFilename;
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

    try read_entry_data(entry, stream, local_data_header_offset, data);
    if (std.hash.Crc32.hash(data) != entry.crc32) return error.ZipCrcMismatch;

    return .{
        .filename = filename,
        .data = data,
    };
}

fn read_entry_data(
    entry: std.zip.Iterator.Entry,
    stream: *std.Io.File.Reader,
    local_data_header_offset: u64,
    data: []u8,
) !void {
    const data_offset = @as(u64, entry.file_offset) +
        @as(u64, @sizeOf(std.zip.LocalFileHeader)) +
        local_data_header_offset;
    try stream.seekTo(data_offset);
    var compressed_buffer: [4096]u8 = undefined;
    var compressed = stream.interface.limited(.limited(entry.compressed_size), &compressed_buffer);
    switch (entry.compression_method) {
        .store => {
            if (entry.compressed_size != entry.uncompressed_size) return error.ZipSizeMismatch;
            compressed.interface.readSliceAll(data) catch |err| switch (err) {
                error.ReadFailed => return stream.err.?,
                error.EndOfStream => return error.ZipDecompressTruncated,
            };
        },
        .deflate => {
            var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(&compressed.interface, .raw, &flate_buffer);
            decompress.reader.readSliceAll(data) catch |err| switch (err) {
                error.ReadFailed => return decompress.err orelse stream.err.?,
                error.EndOfStream => return error.ZipDecompressTruncated,
            };
            var extra: [1]u8 = undefined;
            const extra_len = decompress.reader.readSliceShort(&extra) catch |err| switch (err) {
                error.ReadFailed => return decompress.err orelse stream.err.?,
            };
            if (extra_len != 0) return error.ZipSizeMismatch;
        },
        else => return error.UnsupportedCompressionMethod,
    }
}

pub const MatchingFilesOptions = struct {
    extract: std.zip.ExtractOptions = .{},
    extension: []const u8 = ".xml",
    entries_scanned_max: u32 = 1024,
    files_max: u32 = 16,
    max_uncompressed_bytes: u64 = std.math.maxInt(u32),
};

/// Select every regular entry with `extension`. The central directory is
/// scanned and all count/size claims are checked before any result allocation;
/// only selected entries are then inflated.
pub fn extract_matching_files_to_memory(
    gpa: std.mem.Allocator,
    stream: *std.Io.File.Reader,
    options: MatchingFilesOptions,
) !std.ArrayList(ExtractedFile) {
    if (options.entries_scanned_max == 0 or options.files_max == 0) return error.InvalidLimit;

    var selected_entries: [16]std.zip.Iterator.Entry = undefined;
    if (options.files_max > selected_entries.len) return error.InvalidLimit;
    var selected_count: u32 = 0;
    var entries_scanned: u32 = 0;
    var total_uncompressed: u64 = 0;
    var filename_storage: [std.math.maxInt(u16)]u8 = undefined;

    var iter = try std.zip.Iterator.init(stream);
    while (try iter.next()) |entry| {
        if (entries_scanned >= options.entries_scanned_max) return error.ZipTooManyEntries;
        entries_scanned += 1;
        const filename = try read_entry_filename_into(entry, stream, options.extract, &filename_storage);
        if (filename[filename.len - 1] == '/') continue;
        if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(filename), options.extension)) continue;
        if (selected_count >= options.files_max) return error.ZipTooManyMatchingFiles;
        if (entry.uncompressed_size > std.math.maxInt(u32)) return error.FileTooLarge;
        if (entry.uncompressed_size > options.max_uncompressed_bytes -| total_uncompressed) {
            return error.FileTooLarge;
        }
        total_uncompressed += entry.uncompressed_size;
        selected_entries[selected_count] = entry;
        selected_count += 1;
    }
    if (selected_count == 0) return error.ZipArchiveHasNoMatchingFiles;

    var result: std.ArrayList(ExtractedFile) = .empty;
    errdefer {
        for (result.items) |file| file.deinit(gpa);
        result.deinit(gpa);
    }
    try result.ensureTotalCapacity(gpa, selected_count);
    for (selected_entries[0..selected_count]) |entry| {
        // Pass 1 deliberately used one bounded scratch buffer so every archive
        // limit was checked before allocation. Allocate each retained name now,
        // then hand it directly to the extraction helper that takes ownership.
        const filename = try read_entry_filename(entry, gpa, stream, options.extract);
        const extracted = try extract_entry_with_filename(entry, gpa, stream, filename);
        result.appendAssumeCapacity(extracted);
    }
    assert(result.items.len == selected_count);
    return result;
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
    diagnostics: ?*FirstFileDiagnostics = null,
};

pub const FirstFileDiagnostics = struct {
    selected_uncompressed_size: ?u64 = null,
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
            if (options.diagnostics) |diagnostics| {
                diagnostics.selected_uncompressed_size = entry.uncompressed_size;
            }
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

const TestZipEntry = struct { name: []const u8, data: []const u8 };

fn make_test_stored_zip(gpa: std.mem.Allocator, entries: []const TestZipEntry) ![]u8 {
    var archive: std.Io.Writer.Allocating = .init(gpa);
    errdefer archive.deinit();
    const w = &archive.writer;
    var offsets: [8]u32 = undefined;
    assert(entries.len <= offsets.len);

    for (entries, 0..) |entry, i| {
        offsets[i] = @intCast(archive.written().len);
        const crc = std.hash.Crc32.hash(entry.data);
        try w.writeInt(u32, 0x04034b50, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(entry.data.len), .little);
        try w.writeInt(u32, @intCast(entry.data.len), .little);
        try w.writeInt(u16, @intCast(entry.name.len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeAll(entry.name);
        try w.writeAll(entry.data);
    }

    const central_offset: u32 = @intCast(archive.written().len);
    for (entries, 0..) |entry, i| {
        const crc = std.hash.Crc32.hash(entry.data);
        try w.writeInt(u32, 0x02014b50, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(entry.data.len), .little);
        try w.writeInt(u32, @intCast(entry.data.len), .little);
        try w.writeInt(u16, @intCast(entry.name.len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, 0, .little);
        try w.writeInt(u32, offsets[i], .little);
        try w.writeAll(entry.name);
    }
    const central_size: u32 = @intCast(archive.written().len - central_offset);
    try w.writeInt(u32, 0x06054b50, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(entries.len), .little);
    try w.writeInt(u16, @intCast(entries.len), .little);
    try w.writeInt(u32, central_size, .little);
    try w.writeInt(u32, central_offset, .little);
    try w.writeInt(u16, 0, .little);
    return archive.toOwnedSlice();
}

test "matching extraction selects every XML entry and verifies CRC" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const entries = [_]TestZipEntry{
        .{ .name = "one.xml", .data = "<one/>" },
        .{ .name = "ignore.txt", .data = "not XML" },
        .{ .name = "TWO.XML", .data = "<two/>" },
    };
    const archive = try make_test_stored_zip(gpa, &entries);
    defer gpa.free(archive);

    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    var file = try tmpdir.dir.createFile(io, "parts.zip", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, archive);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    var extracted = try extract_matching_files_to_memory(gpa, &file_reader, .{});
    defer {
        for (extracted.items) |entry| entry.deinit(gpa);
        extracted.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 2), extracted.items.len);
    try std.testing.expectEqualStrings("one.xml", extracted.items[0].filename);
    try std.testing.expectEqualStrings("<one/>", extracted.items[0].data);
    try std.testing.expectEqualStrings("TWO.XML", extracted.items[1].filename);
    try std.testing.expectEqualStrings("<two/>", extracted.items[1].data);

    var corrupt = try gpa.dupe(u8, archive);
    defer gpa.free(corrupt);
    const data_offset = std.mem.indexOf(u8, corrupt, "<one/>") orelse unreachable;
    corrupt[data_offset + 1] = 'X';
    try file.setLength(io, 0);
    try file.writePositionalAll(io, corrupt, 0);
    var corrupt_reader = file.reader(io, &read_buffer);
    try std.testing.expectError(error.ZipCrcMismatch, extract_matching_files_to_memory(gpa, &corrupt_reader, .{}));
}
