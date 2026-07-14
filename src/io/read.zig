const std = @import("std");
const zip = @import("zip.zig");
const print = @import("print.zig");
pub const max_in_memory_input_bytes = std.math.maxInt(u32);

pub const Options = struct {
    extension: []const u8 = ".xml",
    max_bytes: u64 = max_in_memory_input_bytes,
    diagnostics: ?*Diagnostics = null,
};

pub const Diagnostics = struct {
    actual_size: ?u64 = null,
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

pub fn read_file_to_memory(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File) ![]u8 {
    return read_file_to_memory_options(io, gpa, file, .{});
}

pub fn read_file_to_memory_options(
    io: std.Io,
    gpa: std.mem.Allocator,
    file: std.Io.File,
    options: Options,
) ![]u8 {
    const file_size = try file.length(io);
    if (file_size > options.max_bytes) {
        if (options.diagnostics) |diagnostics| diagnostics.actual_size = file_size;
        return error.FileTooLarge;
    }

    var file_reader = file.reader(io, &.{});
    // +1 so the reader can observe EOF without tripping StreamTooLong on exact-size files.
    return try file_reader.interface.allocRemaining(gpa, .limited(file_size + 1));
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
    if (std.mem.startsWith(u8, data, &std.zip.local_file_header_sig)) print.stderr(
        io,
        "stdin: reading a ZIP archive from stdin is not supported; pipe XML instead " ++
            "(e.g. `unzip -p eq.zip | cimd types -`)",
        .{},
    );
    return data;
}
