const std = @import("std");
const assert = std.debug.assert;
const zip = @import("zip.zig");
const print = @import("print.zig");
const units = @import("../units.zig");

const file_read_chunk_bytes: u32 = 64 * units.mebibyte;

pub const max_in_memory_input_bytes = std.math.maxInt(u32);

pub const Options = struct {
    extension: []const u8 = ".xml",
    max_bytes: u64 = max_in_memory_input_bytes,
    diagnostics: ?*Diagnostics = null,
};

pub const Diagnostics = struct {
    actual_size: ?u64 = null,
};

pub const parts_per_input_max = 16;
pub const zip_entries_scanned_max = 1024;

pub const Part = struct {
    /// Owned diagnostic name: the path for XML, `path!entry.xml` for ZIP.
    name: []u8,
    xml: []u8,

    pub fn deinit(self: Part, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.xml);
    }
};

/// The path token that means "read the primary input from stdin", letting cimd
/// be composed in a pipeline (e.g. `unzip -p eq.zip | cimd types -`).
pub const stdin_token = "-";

pub fn is_stdin(file_path: []const u8) bool {
    return std.mem.eql(u8, file_path, stdin_token);
}

pub fn read_path(io: std.Io, gpa: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    return read_path_options(io, gpa, file_path, .{});
}

/// Read every XML document represented by one CLI input. ZIP entry order is
/// central-directory order and is retained for deterministic reporting.
pub fn read_parts(
    io: std.Io,
    gpa: std.mem.Allocator,
    file_path: []const u8,
    max_bytes: u64,
) ![]Part {
    assert(max_bytes <= max_in_memory_input_bytes);
    if (is_stdin(file_path)) {
        const xml = try read_stdin(io, gpa, .{ .max_bytes = max_bytes });
        errdefer gpa.free(xml);
        const name = try gpa.dupe(u8, file_path);
        const result = try gpa.alloc(Part, 1);
        result[0] = .{ .name = name, .xml = @constCast(xml) };
        return result;
    }

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, file_path, .{});
    defer file.close(io);

    if (!(try zip.is_zip_file(io, file))) {
        const xml = try read_file_to_memory_options(io, gpa, file, .{
            .max_bytes = max_bytes,
        });
        errdefer gpa.free(xml);
        const name = try gpa.dupe(u8, file_path);
        const result = try gpa.alloc(Part, 1);
        result[0] = .{ .name = name, .xml = xml };
        return result;
    }

    var zip_buffer: [256 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &zip_buffer);
    var extracted = try zip.extract_matching_files_to_memory(gpa, &file_reader, .{
        .extension = ".xml",
        .entries_scanned_max = zip_entries_scanned_max,
        .files_max = parts_per_input_max,
        .max_uncompressed_bytes = max_bytes,
    });
    defer extracted.deinit(gpa);
    errdefer for (extracted.items) |entry| entry.deinit(gpa);

    const result = try gpa.alloc(Part, extracted.items.len);
    errdefer gpa.free(result);
    var initialized: u32 = 0;
    errdefer for (result[0..initialized]) |part| part.deinit(gpa);
    for (extracted.items, 0..) |entry, i| {
        const name = try std.fmt.allocPrint(gpa, "{s}!{s}", .{ file_path, entry.filename });
        gpa.free(entry.filename);
        extracted.items[i].filename = &.{};
        result[i] = .{ .name = name, .xml = entry.data };
        extracted.items[i].data = &.{};
        initialized += 1;
    }
    return result;
}

pub fn read_path_options(
    io: std.Io,
    gpa: std.mem.Allocator,
    file_path: []const u8,
    options: Options,
) ![]const u8 {
    if (is_stdin(file_path)) return read_stdin(io, gpa, options);

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, file_path, .{});
    defer file.close(io);

    if (try zip.is_zip_file(io, file)) {
        var zip_buffer: [256 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &zip_buffer);
        var zip_diagnostics: zip.FirstFileDiagnostics = .{};
        const extracted = zip.extract_first_file_to_memory(gpa, &file_reader, .{
            .extract = .{},
            .max_uncompressed_bytes = options.max_bytes,
            .extension = options.extension,
            .diagnostics = &zip_diagnostics,
        }) catch |err| {
            if (options.diagnostics) |diagnostics| {
                diagnostics.actual_size = zip_diagnostics.selected_uncompressed_size;
            }
            return err;
        };
        const data = extracted.data;
        gpa.free(extracted.filename);
        return data;
    } else {
        return try read_file_to_memory_options(io, gpa, file, options);
    }
}

pub fn read_file_to_memory_options(
    io: std.Io,
    gpa: std.mem.Allocator,
    file: std.Io.File,
    options: Options,
) ![]u8 {
    assert(options.max_bytes <= max_in_memory_input_bytes);
    const file_size = try file.length(io);
    if (file_size > options.max_bytes) {
        if (options.diagnostics) |diagnostics| diagnostics.actual_size = file_size;
        return error.FileTooLarge;
    }

    const file_size_u32: u32 = @intCast(file_size);
    const data = try gpa.alloc(u8, file_size_u32);
    errdefer gpa.free(data);

    var file_reader = file.reader(io, &.{});
    read_all_in_chunks(&file_reader.interface, data, file_read_chunk_bytes) catch |err| switch (err) {
        error.EndOfStream => return error.FileTruncated,
        else => |e| return e,
    };
    return data;
}

fn read_all_in_chunks(reader: *std.Io.Reader, data: []u8, chunk_bytes: u32) !void {
    assert(chunk_bytes > 0);
    assert(chunk_bytes <= file_read_chunk_bytes);
    assert(data.len <= max_in_memory_input_bytes);

    const data_len: u32 = @intCast(data.len);
    var offset: u32 = 0;
    // readSliceAll loops until its slice is full, but its first readVec receives
    // the whole remaining slice. Bound that slice to keep each syscall below
    // Darwin's maxInt(i32) limit.
    while (offset < data_len) {
        const chunk_len = @min(chunk_bytes, data_len - offset);
        assert(chunk_len > 0);
        try reader.readSliceAll(data[offset..][0..chunk_len]);
        offset += chunk_len;
        assert(offset <= data_len);
    }
    assert(offset == data_len);

    var extra: [1]u8 = undefined;
    if (try reader.readSliceShort(&extra) != 0) return error.FileGrew;
}

/// Read all of stdin into memory. Unlike a file, stdin is a pipe: it has no
/// known length (so we read until EOF) and is not seekable. ZIP extraction
/// needs random access to the central directory at the end of the archive, so
/// a piped ZIP cannot be handled here; callers must pipe XML instead, e.g.
/// `unzip -p eq.zip | cimd types -`.
fn read_stdin(io: std.Io, gpa: std.mem.Allocator, options: Options) ![]const u8 {
    var stdin_reader = std.Io.File.stdin().reader(io, &.{});
    // +1 over the cap so an exact-cap stream still reaches EOF; the explicit
    // length check below rejects anything past the u32 offset limit.
    const data = try stdin_reader.interface.allocRemaining(gpa, .limited(options.max_bytes + 1));
    errdefer gpa.free(data);
    if (data.len > options.max_bytes) {
        if (options.diagnostics) |diagnostics| diagnostics.actual_size = data.len;
        return error.FileTooLarge;
    }
    if (std.mem.startsWith(u8, data, &std.zip.local_file_header_sig)) print.data_error(
        io,
        "stdin: reading a ZIP archive from stdin is not supported; pipe XML instead " ++
            "(e.g. `unzip -p eq.zip | cimd types -`)",
        .{},
    );
    return data;
}

test "read_all_in_chunks fills the destination with multiple reads" {
    const source = "0123456789";
    var reader = std.Io.Reader.fixed(source);
    var data: [source.len]u8 = undefined;

    try read_all_in_chunks(&reader, &data, 3);

    try std.testing.expectEqualStrings(source, &data);
}

test "read_all_in_chunks reports a short source" {
    var reader = std.Io.Reader.fixed("short");
    var data: [6]u8 = undefined;

    try std.testing.expectError(error.EndOfStream, read_all_in_chunks(&reader, &data, 3));
}

test "read_all_in_chunks reports a growing source" {
    var reader = std.Io.Reader.fixed("longer");
    var data: [5]u8 = undefined;

    try std.testing.expectError(error.FileGrew, read_all_in_chunks(&reader, &data, 3));
}
