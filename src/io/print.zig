const std = @import("std");
const cim = @import("../cim/cim.zig");
const CimDocument = cim.CimDocument;

const tag_index = cim.tag_index;
const utils = cim.ids;
const units = @import("../units.zig");

pub const size_limit_text_buffer_bytes = 160;

pub const exit_not_found = 1;
pub const exit_usage = 2;
pub const exit_differences = 3;
pub const exit_validation_failed = 4;
pub const exit_data_error = 65;
pub const exit_no_input = 66;
pub const exit_failure = 70;
pub const exit_system_error = 71;

pub const OutputError = error{
    BrokenPipe,
    OutputDiskQuota,
    OutputFileTooBig,
    OutputInputOutput,
    OutputNoSpaceLeft,
    OutputDeviceBusy,
    OutputAccessDenied,
    OutputPermissionDenied,
    OutputSystemResources,
    OutputNotOpenForWriting,
    OutputLockViolation,
    OutputWouldBlock,
    OutputNoDevice,
    OutputFileBusy,
    OutputCanceled,
    OutputUnexpected,
    OutputUnattributedWriteFailure,
};

/// Print a usage error to stderr and exit 2.
/// Use for invalid arguments, missing flags, and unknown commands.
pub fn stderr(io: std.Io, comptime fmt_str: []const u8, args: anytype) noreturn {
    exit_message(io, exit_usage, "error: ", fmt_str, args);
}

/// Print an invalid or unsupported-input error to stderr and exit 65.
pub fn data_error(io: std.Io, comptime fmt_str: []const u8, args: anytype) noreturn {
    exit_message(io, exit_data_error, "error: ", fmt_str, args);
}

/// Print an unavailable-input error to stderr and exit 66.
pub fn no_input(io: std.Io, comptime fmt_str: []const u8, args: anytype) noreturn {
    exit_message(io, exit_no_input, "error: ", fmt_str, args);
}

/// Print an operating-system or resource error to stderr and exit 71.
pub fn system_error(io: std.Io, comptime fmt_str: []const u8, args: anytype) noreturn {
    exit_message(io, exit_system_error, "error: ", fmt_str, args);
}

/// Print an error to stderr and exit with `code`.
pub fn exit_error(io: std.Io, code: u8, comptime fmt_str: []const u8, args: anytype) noreturn {
    exit_message(io, code, "error: ", fmt_str, args);
}

fn exit_message(
    io: std.Io,
    code: u8,
    comptime prefix: []const u8,
    comptime fmt_str: []const u8,
    args: anytype,
) noreturn {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, prefix ++ fmt_str ++ "\n", args) catch prefix ++ "(message too long)\n";
    _ = std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    std.process.exit(code);
}

/// Print a not-found message to stderr and exit 1.
/// Use when a requested resource (e.g. mRID) does not exist in the model.
pub fn not_found(io: std.Io, comptime fmt_str: []const u8, args: anytype) noreturn {
    exit_message(io, exit_not_found, "not found: ", fmt_str, args);
}

pub fn unexpected(io: std.Io, command_name: []const u8, err: anyerror) noreturn {
    exit_error(io, exit_failure, "{s}: unexpected failure: {t}", .{ command_name, err });
}

pub fn size_limit_text(buf: []u8, actual_bytes: ?u64, max_bytes: u64) []const u8 {
    var prefix_buf: [48]u8 = undefined;
    const prefix = if (actual_bytes) |actual|
        std.fmt.bufPrint(&prefix_buf, "{d} bytes; ", .{actual}) catch ""
    else
        "";
    var suffix_buf: [32]u8 = undefined;
    const suffix = if (max_bytes < units.mebibyte) "" else std.fmt.bufPrint(
        &suffix_buf,
        " (~{d} MiB)",
        .{std.math.divCeil(u64, max_bytes, units.mebibyte) catch unreachable},
    ) catch "";
    return std.fmt.bufPrint(
        buf,
        "{s}max supported size is {d} bytes{s}",
        .{ prefix, max_bytes, suffix },
    ) catch "(size details unavailable)";
}

pub fn size_limit_text_comptime(comptime max_bytes: u64) []const u8 {
    const text = comptime text: {
        var buf: [size_limit_text_buffer_bytes]u8 = undefined;
        break :text size_limit_text(&buf, null, max_bytes);
    };
    return std.fmt.comptimePrint("{s}", .{text});
}

/// Write informational (non-error) output to stderr. Returns an error on write failure.
/// Use for diagnostic/progress output that should not pollute stdout data.
pub fn stderr_info(io: std.Io, comptime fmt_str: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stderr(), io, &buffer);
    file_writer_result(&file_writer, file_writer.interface.print(fmt_str, args)) catch |err| switch (err) {
        error.BrokenPipe => return,
        else => return err,
    };
    flush_file_writer(&file_writer) catch |err| switch (err) {
        error.BrokenPipe => return,
        else => return err,
    };
}

pub fn stdout(io: std.Io, comptime fmt_str: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &buffer);
    try file_writer_result(&file_writer, file_writer.interface.print(fmt_str, args));
    try flush_file_writer(&file_writer);
}

/// Write raw bytes to stdout without going through fmt. Use for static text
/// (help strings, etc.) that may contain `{` or `}` which would otherwise be
/// misparsed as format placeholders.
pub fn write(io: std.Io, msg: []const u8) !void {
    std.Io.File.stdout().writeStreamingAll(io, msg) catch |err| switch (err) {
        error.BrokenPipe => return error.BrokenPipe,
        else => return classify_output_error(err),
    };
}

/// Recover the operating-system error hidden behind `error.WriteFailed` by a
/// buffered file writer. Call this at the boundary where the concrete
/// `File.Writer` is still available; higher layers only see the sentinel.
pub fn file_writer_result(
    file_writer: *std.Io.File.Writer,
    result: anytype,
) (@typeInfo(@TypeOf(result)).error_union.error_set || OutputError)!@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| {
        if (err == error.WriteFailed) {
            if (underlying_file_writer_error(file_writer)) |write_err| {
                return classify_output_error(write_err);
            }
            return error.OutputUnattributedWriteFailure;
        }
        return err;
    };
}

fn underlying_file_writer_error(file_writer: *const std.Io.File.Writer) ?anyerror {
    if (file_writer.err) |write_err| return write_err;
    if (file_writer.write_file_err) |write_err| return write_err;
    return null;
}

pub fn flush_file_writer(file_writer: *std.Io.File.Writer) OutputError!void {
    file_writer.flush() catch |err| return classify_output_error(err);
}

/// Re-exported from the library layer (cim/writer.zig), which needs it without
/// depending on this module. CLI callers keep reaching it through `print`.
pub const allocating_writer_result = cim.allocating_writer_result;

fn classify_output_error(err: anyerror) OutputError {
    return switch (err) {
        error.BrokenPipe => error.BrokenPipe,
        error.DiskQuota => error.OutputDiskQuota,
        error.FileTooBig => error.OutputFileTooBig,
        error.InputOutput => error.OutputInputOutput,
        error.NoSpaceLeft => error.OutputNoSpaceLeft,
        error.DeviceBusy => error.OutputDeviceBusy,
        error.AccessDenied => error.OutputAccessDenied,
        error.PermissionDenied => error.OutputPermissionDenied,
        error.SystemResources => error.OutputSystemResources,
        error.NotOpenForWriting => error.OutputNotOpenForWriting,
        error.LockViolation => error.OutputLockViolation,
        error.WouldBlock => error.OutputWouldBlock,
        error.NoDevice => error.OutputNoDevice,
        error.FileBusy => error.OutputFileBusy,
        error.Canceled => error.OutputCanceled,
        else => error.OutputUnexpected,
    };
}

pub fn is_output_system_error(err: anyerror) bool {
    return switch (err) {
        error.OutputDiskQuota,
        error.OutputFileTooBig,
        error.OutputInputOutput,
        error.OutputNoSpaceLeft,
        error.OutputDeviceBusy,
        error.OutputAccessDenied,
        error.OutputPermissionDenied,
        error.OutputSystemResources,
        error.OutputNotOpenForWriting,
        error.OutputLockViolation,
        error.OutputWouldBlock,
        error.OutputNoDevice,
        error.OutputFileBusy,
        error.OutputCanceled,
        error.OutputUnexpected,
        error.OutputUnattributedWriteFailure,
        => true,
        else => false,
    };
}

pub fn output_error_cause(err: anyerror) []const u8 {
    const name = @errorName(err);
    return if (std.mem.startsWith(u8, name, "Output")) name["Output".len..] else name;
}

test "file writer failures are classified by output origin" {
    var buffer: [1]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), std.testing.io, &buffer);

    file_writer.err = error.BrokenPipe;
    const broken_pipe: anyerror!void = error.WriteFailed;
    try std.testing.expectError(error.BrokenPipe, file_writer_result(&file_writer, broken_pipe));

    file_writer.err = error.NoSpaceLeft;
    const no_space_left: anyerror!void = error.WriteFailed;
    try std.testing.expectError(error.OutputNoSpaceLeft, file_writer_result(&file_writer, no_space_left));

    file_writer.err = null;
    const unattributed: anyerror!void = error.WriteFailed;
    try std.testing.expectError(
        error.OutputUnattributedWriteFailure,
        file_writer_result(&file_writer, unattributed),
    );
    try std.testing.expect(is_output_system_error(error.OutputNoSpaceLeft));
    try std.testing.expect(is_output_system_error(error.OutputUnattributedWriteFailure));
    try std.testing.expect(!is_output_system_error(error.BrokenPipe));
    try std.testing.expectEqualStrings("NoSpaceLeft", output_error_cause(error.OutputNoSpaceLeft));
}

pub fn write_object_inventory_json_value(w: *std.Io.Writer, counts: []const CimDocument.TypeCount) !void {
    try w.writeByte('[');
    for (counts, 0..) |entry, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"type\":");
        try std.json.Stringify.value(entry.type_name, .{}, w);
        try w.print(",\"count\":{d}}}", .{entry.count});
    }
    try w.writeByte(']');
}

pub fn write_object_inventory(w: *std.Io.Writer, counts: []const CimDocument.TypeCount) !void {
    var total: u64 = 0;
    for (counts) |entry| {
        try w.print("{s}: {d} objects\n", .{ entry.type_name, entry.count });
        total += entry.count;
    }
    try w.print("Total: {d} objects\n\n", .{total});
}

pub fn display_object_list_json(
    io: std.Io,
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    objects: []const tag_index.CimObject,
    fields: []const []const u8,
) !void {
    var write_buffer: [64 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &write_buffer);
    try file_writer_result(&file_writer, write_object_list_json(
        &file_writer.interface,
        gpa,
        model,
        objects,
        fields,
    ));
    try flush_file_writer(&file_writer);
}

fn write_object_list_json(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    objects: []const tag_index.CimObject,
    fields: []const []const u8,
) !void {
    try w.writeByte('[');
    for (objects, 0..) |obj, i| {
        if (i > 0) try w.writeByte(',');
        const view = model.view(obj);
        if (fields.len == 0) {
            // Full dump: same shape as single-object JSON. Lets callers do
            // joins and reference resolution in Python without re-fetching.
            try write_object_full_json(w, gpa, view);
        } else {
            // Projection mode: only id, type, and the requested fields.
            try w.writeAll("{\"id\":");
            try std.json.Stringify.value(obj.id, .{}, w);
            try w.writeAll(",\"type\":");
            try std.json.Stringify.value(obj.type_name, .{}, w);
            for (fields) |field| {
                // Fall back to a reference when the field isn't a text property;
                // strip the '#' so the value matches the references map shape.
                const val = if (try view.getProperty(field)) |p|
                    p
                else if (try view.getReference(field)) |r|
                    utils.strip_hash(r)
                else
                    "";
                try w.writeByte(',');
                try std.json.Stringify.value(field, .{}, w);
                try w.writeByte(':');
                try std.json.Stringify.value(val, .{}, w);
            }
            try w.writeByte('}');
        }
    }
    try w.writeAll("]\n");
}

fn write_object_full_json(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    obj: tag_index.CimObjectView,
) !void {
    var props = try obj.getAllProperties(gpa);
    defer props.deinit();
    var refs = try obj.getAllReferences(gpa);
    defer refs.deinit();

    try w.writeAll("{\"id\":");
    try std.json.Stringify.value(obj.id, .{}, w);
    try w.writeAll(",\"type\":");
    try std.json.Stringify.value(obj.type_name, .{}, w);

    try w.writeAll(",\"properties\":{");
    var first = true;
    var prop_it = props.iterator();
    while (prop_it.next()) |entry| {
        if (!first) try w.writeByte(',');
        try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
        try w.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
        first = false;
    }
    try w.writeAll("},\"references\":{");
    first = true;
    var ref_it = refs.iterator();
    while (ref_it.next()) |entry| {
        if (!first) try w.writeByte(',');
        try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
        try w.writeByte(':');
        try std.json.Stringify.value(utils.strip_hash(entry.value_ptr.*), .{}, w);
        first = false;
    }
    try w.writeAll("}}");
}

test "size_limit_text includes exact bytes and MiB" {
    var buf: [size_limit_text_buffer_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "5 bytes; max supported size is 4 bytes",
        size_limit_text(&buf, 5, 4),
    );
    try std.testing.expectEqualStrings(
        "max supported size is 4294967295 bytes (~4096 MiB)",
        size_limit_text(&buf, null, std.math.maxInt(u32)),
    );
    try std.testing.expectEqualStrings(
        size_limit_text(&buf, null, std.math.maxInt(u32)),
        size_limit_text_comptime(std.math.maxInt(u32)),
    );
}
