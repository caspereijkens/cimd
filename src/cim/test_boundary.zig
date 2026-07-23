//! Enforces the library boundary described in cim.zig.
//!
//! These rules are the difference between "code that happens to sit in a
//! directory" and "a library that can be lifted out". Left to convention they
//! erode one convenient import at a time -- an `io/print.zig` here to format an
//! error, a `process.exit` there -- and the eventual split turns into a
//! refactor. Checked here, a violation fails the build the day it lands.
//!
//! The checks read the source files rather than inspecting the compiled graph:
//! an import that escapes the directory is a textual fact, and this way the
//! failure names the offending file and line.
//!
//! After the library moves to its own package, `library_root` becomes "src"
//! and everything else holds unchanged.

const std = @import("std");

const io = std.testing.io;

/// Repo-relative path to the library. Tests run with the project root as cwd.
const library_root = "src/cim";

/// Repo-relative path to all Zig sources, library and application alike.
const source_root = "src";

/// The library's public API. The application may import this and nothing else
/// from `library_root`; see the "application code imports only the library"
/// test below.
const facade = library_root ++ "/cim.zig";

/// Second entry point, for the build only: it references the library's test
/// files so `zig build test` runs them. Kept out of cim.zig deliberately --
/// every consumer imports the API, and a comptime test list there compiles the
/// whole suite into each of them.
const test_entry = library_root ++ "/test_all.zig";

const Scope = enum { library, application };

/// Run `check` over every .zig file in `scope`, with a repo-relative path.
fn walk_zig_files(
    gpa: std.mem.Allocator,
    scope: Scope,
    comptime check: fn (gpa: std.mem.Allocator, path: []const u8, source: []const u8) anyerror!void,
) !void {
    const root = switch (scope) {
        .library => library_root,
        .application => source_root,
    };
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var seen: u32 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, entry.path });
        defer gpa.free(full);
        // Walking the application means walking all of src/, library included.
        // Compare components: on Windows the walker yields "cim\\document.zig".
        if (scope == .application and contains_path("cim", entry.path)) continue;
        const source = try dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 22));
        defer gpa.free(source);
        try check(gpa, full, source);
        seen += 1;
    }
    // A miswired path would silently check nothing and pass.
    try std.testing.expect(seen >= 10);
}

fn walk_library_files(
    gpa: std.mem.Allocator,
    comptime check: fn (gpa: std.mem.Allocator, path: []const u8, source: []const u8) anyerror!void,
) !void {
    return walk_zig_files(gpa, .library, check);
}

/// Whether `path` is `root` itself or sits beneath it. Compares whole path
/// components: a plain prefix test would accept a sibling directory whose name
/// merely starts with the root's -- `src/cimd/foo.zig` "starts with" `src/cim`,
/// and an `../cimd/foo.zig` import would escape unnoticed.
///
/// Separator handling is `std.fs.path.isSep`, not a literal `/`: Windows is a
/// release target, where `std.fs.path.resolve` returns backslashes and
/// `Dir.walk` yields them too. Accepts a relative or resolved pair, as long as
/// both are the same kind.
fn contains_path(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return std.fs.path.isSep(path[root.len]);
}

test "contains_path compares whole components" {
    // '/' is a separator on every target cimd releases for, Windows included.
    try std.testing.expect(contains_path("/a/src/cim", "/a/src/cim"));
    try std.testing.expect(contains_path("/a/src/cim", "/a/src/cim/refs.zig"));
    try std.testing.expect(contains_path("/a/src/cim", "/a/src/cim/cgmes/tp.zig"));
    try std.testing.expect(!contains_path("/a/src/cim", "/a/src/cimd/foo.zig"));
    try std.testing.expect(!contains_path("/a/src/cim", "/a/src/cim-extra.zig"));
    try std.testing.expect(!contains_path("/a/src/cim", "/a/src/io/print.zig"));

    // ...and so is the host's own separator, which is what the walkers and
    // std.fs.path.resolve actually produce.
    const sep = [_]u8{std.fs.path.sep};
    try std.testing.expect(contains_path("/a/src/cim", "/a/src/cim" ++ sep ++ "refs.zig"));
    try std.testing.expect(contains_path("cim", "cim" ++ sep ++ "document.zig"));
    try std.testing.expect(!contains_path("cim", "cimd" ++ sep ++ "foo.zig"));
}

/// Named modules the library may depend on. Deliberately tiny: a named import
/// is a build-graph dependency the eventual package would have to declare in
/// its own build.zig.zon, so every addition is a decision, not a convenience.
const allowed_modules = [_][]const u8{"std"};

fn is_module_import(path: []const u8) bool {
    return !std.mem.endsWith(u8, path, ".zig");
}

/// Every import in `source`, as (line number, path) pairs. Named module
/// imports are included, not skipped -- a dependency on an external package
/// escapes the library just as surely as a relative path does. Feed it
/// comment-blanked source: prose in this file names the very syntax it scans
/// for.
const ImportIterator = struct {
    source: []const u8,
    offset: usize = 0,
    line: u32 = 1,

    const Import = struct { line: u32, path: []const u8 };

    fn next(self: *ImportIterator) ?Import {
        const needle = "@import(\"";
        while (std.mem.indexOfPos(u8, self.source, self.offset, needle)) |start| {
            const value_start = start + needle.len;
            const end = std.mem.indexOfScalarPos(u8, self.source, value_start, '"') orelse return null;
            const path = self.source[value_start..end];
            self.line += @intCast(std.mem.count(u8, self.source[self.offset..start], "\n"));
            self.offset = end + 1;
            return .{ .line = self.line, .path = path };
        }
        return null;
    }
};

/// A copy of `source` with comment text blanked out, so a rule cannot be
/// tripped by prose describing the construct it bans -- cim.zig's own
/// documentation names every one of them. Line numbers and offsets are
/// preserved so diagnostics still point at the right place. Lines that are
/// multiline string literals are left alone; they are data, not code.
fn blank_comments(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, source);
    var line_start: usize = 0;
    while (line_start < out.len) {
        const line_end = std.mem.indexOfScalarPos(u8, out, line_start, '\n') orelse out.len;
        const line = out[line_start..line_end];
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "\\\\")) {
            var in_string = false;
            var i: usize = 0;
            while (i < line.len) : (i += 1) {
                if (in_string) {
                    if (line[i] == '\\') i += 1 else if (line[i] == '"') in_string = false;
                } else if (line[i] == '"') {
                    in_string = true;
                } else if (line[i] == '/' and i + 1 < line.len and line[i + 1] == '/') {
                    @memset(line[i..], ' ');
                    break;
                }
            }
        }
        line_start = line_end + 1;
    }
    return out;
}

/// Fail if any of `needles` appears in library code. `path` is reported.
/// This file is exempt: it carries every banned construct as a string literal
/// in order to search for it.
fn reject_constructs(
    gpa: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    needles: []const []const u8,
    comptime advice: []const u8,
    err: anyerror,
) !void {
    if (std.mem.endsWith(u8, path, "test_boundary.zig")) return;
    const code = try blank_comments(gpa, source);
    defer gpa.free(code);
    for (needles) |needle| {
        const at = std.mem.indexOf(u8, code, needle) orelse continue;
        const line = 1 + std.mem.count(u8, code[0..at], "\n");
        std.debug.print("\n{s}:{d}: '{s}' in library code\n" ++ advice ++ "\n", .{ path, line, needle });
        return err;
    }
}

test "no import escapes the library directory" {
    try walk_library_files(std.testing.allocator, struct {
        fn check(gpa: std.mem.Allocator, path: []const u8, source: []const u8) anyerror!void {
            const dir = std.fs.path.dirname(path).?;
            const code = try blank_comments(gpa, source);
            defer gpa.free(code);
            var it: ImportIterator = .{ .source = code };
            while (it.next()) |import| {
                if (is_module_import(import.path)) {
                    for (allowed_modules) |allowed| {
                        if (std.mem.eql(u8, import.path, allowed)) break;
                    } else {
                        std.debug.print(
                            "\n{s}:{d}: import of module '{s}'\n" ++
                                "Only {s} may be imported by name; anything else is a package\n" ++
                                "dependency the library would have to carry when it is split out.\n",
                            .{ path, import.line, import.path, allowed_modules[0] },
                        );
                        return error.ImportEscapesLibrary;
                    }
                    continue;
                }
                const resolved = try std.fs.path.resolve(gpa, &.{ dir, import.path });
                defer gpa.free(resolved);
                const root = try std.fs.path.resolve(gpa, &.{library_root});
                defer gpa.free(root);
                if (contains_path(root, resolved)) continue;
                std.debug.print(
                    "\n{s}:{d}: import '{s}' escapes {s}\n" ++
                        "The library must not depend on the application around it.\n",
                    .{ path, import.line, import.path, library_root },
                );
                return error.ImportEscapesLibrary;
            }
        }
    }.check);
}

test "the library never terminates the process" {
    try walk_library_files(std.testing.allocator, struct {
        fn check(gpa: std.mem.Allocator, path: []const u8, source: []const u8) anyerror!void {
            // `abort` is intentionally allowed: it is what a failed assert
            // does, and an assert marks a bug in the library itself, not a
            // condition a caller could have handled.
            try reject_constructs(
                gpa,
                path,
                source,
                &.{ "std.process.exit", "std.posix.exit" },
                "Return an error instead; only the application decides to exit.",
                error.LibraryExitsProcess,
            );
        }
    }.check);
}

test "the library does no file or network I/O" {
    try walk_library_files(std.testing.allocator, struct {
        fn check(gpa: std.mem.Allocator, path: []const u8, source: []const u8) anyerror!void {
            try reject_constructs(
                gpa,
                path,
                source,
                &.{ "std.Io.File", "std.Io.Dir", "std.net" },
                "Callers supply the bytes and the writer; the library opens nothing.",
                error.LibraryPerformsIo,
            );
        }
    }.check);
}

test "application code imports only the library facade" {
    try walk_zig_files(std.testing.allocator, .application, struct {
        fn check(gpa: std.mem.Allocator, path: []const u8, source: []const u8) anyerror!void {
            const dir = std.fs.path.dirname(path).?;
            const root = try std.fs.path.resolve(gpa, &.{library_root});
            defer gpa.free(root);
            const allowed = [_][]const u8{ facade, test_entry };

            const code = try blank_comments(gpa, source);
            defer gpa.free(code);
            var it: ImportIterator = .{ .source = code };
            while (it.next()) |import| {
                if (is_module_import(import.path)) continue;
                const resolved = try std.fs.path.resolve(gpa, &.{ dir, import.path });
                defer gpa.free(resolved);
                if (!contains_path(root, resolved)) continue;

                var ok = false;
                for (allowed) |entry| {
                    const full = try std.fs.path.resolve(gpa, &.{entry});
                    defer gpa.free(full);
                    if (std.mem.eql(u8, resolved, full)) ok = true;
                }
                if (ok) continue;

                std.debug.print(
                    "\n{s}:{d}: import '{s}' reaches into the library\n" ++
                        "Import '{s}' instead. If what you need is not on the API, add it\n" ++
                        "there -- that decision belongs to the library, not to its callers.\n",
                    .{ path, import.line, import.path, facade },
                );
                return error.ImportBypassesFacade;
            }
        }
    }.check);
}
