//! End-to-end tests that run the built `cimd` binary.
//!
//! Everything here is about decisions made *before* a model is compared:
//! argv parsing (cli.zig), model-set primary selection (model_set.zig), and
//! the cross-side checks in main.zig. Those paths report failure by writing a
//! diagnostic and exiting, so they are `noreturn` and invisible to in-process
//! tests -- src/test_diff.zig and src/test_eqdiff.zig construct models directly
//! and would keep passing with the whole routing layer removed. These tests
//! close that gap by asserting on exit codes and stderr text.
//!
//! Fixtures are written to a per-test temporary directory. They are deliberately
//! tiny: stdout and stderr are read serially from their pipes, which would
//! deadlock on output large enough to fill one.

const std = @import("std");
const build_options = @import("build_options");
const zip = @import("io/zip.zig");

const io = std.testing.io;

// ── Harness ───────────────────────────────────────────────────────────────────

const Result = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }

    fn stderr_contains(self: *const Result, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stderr, needle) != null;
    }

    fn stdout_contains(self: *const Result, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null;
    }
};

const output_bytes_max = 1 << 16;

/// Run `cimd` with `args` (argv[0] is supplied) and collect its output.
fn run(gpa: std.mem.Allocator, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, build_options.cimd_exe);
    try argv.appendSlice(gpa, args);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    var stdout_reader = child.stdout.?.reader(io, &.{});
    const stdout = try stdout_reader.interface.allocRemaining(gpa, .limited(output_bytes_max));
    errdefer gpa.free(stdout);
    var stderr_reader = child.stderr.?.reader(io, &.{});
    const stderr = try stderr_reader.interface.allocRemaining(gpa, .limited(output_bytes_max));
    errdefer gpa.free(stderr);

    const term = try child.wait(io);
    return .{
        .code = switch (term) {
            .exited => |code| code,
            else => return error.ChildTerminatedAbnormally,
        },
        .stdout = stdout,
        .stderr = stderr,
    };
}

/// A temporary directory plus the path prefix needed to name its files on a
/// command line. `std.testing.tmpDir` places it under the cache directory
/// relative to the cwd both this test and the child process inherit.
const Fixtures = struct {
    tmp: std.testing.TmpDir,

    fn init() Fixtures {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn deinit(self: *Fixtures) void {
        self.tmp.cleanup();
        self.* = undefined;
    }

    /// Write `data` to `name` and return its path as the CLI must spell it.
    /// The returned path borrows `buf`, which the caller owns.
    fn write(self: *Fixtures, buf: []u8, name: []const u8, data: []const u8) ![]const u8 {
        try self.tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
        return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ self.tmp.sub_path, name });
    }

    /// Write a stored (uncompressed) ZIP of `entries` and return its path.
    fn write_bundle(
        self: *Fixtures,
        gpa: std.mem.Allocator,
        buf: []u8,
        name: []const u8,
        entries: []const zip.TestZipEntry,
    ) ![]const u8 {
        const archive = try zip.make_test_stored_zip(gpa, entries);
        defer gpa.free(archive);
        return self.write(buf, name, archive);
    }
};

// ── Fixture documents ─────────────────────────────────────────────────────────
//
// One breaker per profile-flavoured document, small enough that a whole diff
// fits well inside a pipe buffer. The SSH/TP shapes use rdf:about patches on
// mRIDs an EQ document owns, as real exports do.

inline fn header(comptime profile_uri: ?[]const u8) []const u8 {
    const declarations =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#" xmlns:md="http://iec.ch/TC57/61970-552/ModelDescription/1#">
        \\
    ;
    const uri = profile_uri orelse return declarations;
    // The id is per-profile: an EQ and an EQBD part get merged into one
    // document, and two FullModels sharing an id is a duplicate-id error.
    return declarations ++
        "  <md:FullModel rdf:about=\"urn:uuid:fixture-" ++ uri ++ "\">\n" ++
        "    <md:Model.profile>" ++ uri ++ "</md:Model.profile>\n" ++
        "  </md:FullModel>\n";
}

const eq_uri = "http://entsoe.eu/CIM/EquipmentCore/3/1";
const ssh_uri = "http://entsoe.eu/CIM/SteadyStateHypothesis/1/1";
const tp_uri = "http://entsoe.eu/CIM/Topology/4/1";
const eqbd_uri = "http://entsoe.eu/CIM/EquipmentBoundary/3/1";

inline fn eq_document(comptime name: []const u8) []const u8 {
    return header(eq_uri) ++
        "  <cim:Breaker rdf:ID=\"_BR1\">\n" ++
        "    <cim:IdentifiedObject.name>" ++ name ++ "</cim:IdentifiedObject.name>\n" ++
        "  </cim:Breaker>\n</rdf:RDF>\n";
}

inline fn ssh_document(comptime open: []const u8) []const u8 {
    return header(ssh_uri) ++
        "  <cim:Breaker rdf:about=\"#_BR1\">\n" ++
        "    <cim:Switch.open>" ++ open ++ "</cim:Switch.open>\n" ++
        "  </cim:Breaker>\n</rdf:RDF>\n";
}

inline fn tp_document(comptime node: []const u8) []const u8 {
    return header(tp_uri) ++
        "  <cim:Terminal rdf:about=\"#_T1\">\n" ++
        "    <cim:Terminal.TopologicalNode rdf:resource=\"#" ++ node ++ "\"/>\n" ++
        "  </cim:Terminal>\n</rdf:RDF>\n";
}

/// Same SSH content with no FullModel at all -- the header-less fixture shape
/// the kind flags exist for.
inline fn headerless_ssh_document(comptime open: []const u8) []const u8 {
    return header(null) ++
        "  <cim:Breaker rdf:about=\"#_BR1\">\n" ++
        "    <cim:Switch.open>" ++ open ++ "</cim:Switch.open>\n" ++
        "  </cim:Breaker>\n</rdf:RDF>\n";
}

const eqbd_document = header(eqbd_uri) ++
    "  <cim:ConnectivityNode rdf:ID=\"_CN1\">\n" ++
    "    <cim:IdentifiedObject.name>Border</cim:IdentifiedObject.name>\n" ++
    "  </cim:ConnectivityNode>\n</rdf:RDF>\n";

const exit_differences = 3;
const exit_usage = 2;
const exit_data_error = 65;

// ── Auto-detected non-EQ sides ────────────────────────────────────────────────

test "diff routes two SSH files by their declared profile" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", ssh_document("false"));
    const b = try fixtures.write(&buf2, "b.xml", ssh_document("true"));

    var result = try run(gpa, &.{ "diff", a, b, "--patch" });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_differences), result.code);
    try std.testing.expect(result.stdout_contains("@@ Breaker @@"));
    try std.testing.expect(result.stdout_contains("- Switch.open: \"false\""));
    try std.testing.expect(result.stdout_contains("+ Switch.open: \"true\""));
}

test "diff routes two TP files by their declared profile" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", tp_document("_TN1"));
    const b = try fixtures.write(&buf2, "b.xml", tp_document("_TN2"));

    var result = try run(gpa, &.{ "diff", a, b, "--patch" });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_differences), result.code);
    try std.testing.expect(result.stdout_contains("Terminal.TopologicalNode"));
}

test "diff of identical SSH files exits 0" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", ssh_document("false"));
    const b = try fixtures.write(&buf2, "b.xml", ssh_document("false"));

    var result = try run(gpa, &.{ "diff", a, b, "--summary" });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "diff writes an SSH difference model by default" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", ssh_document("false"));
    const b = try fixtures.write(&buf2, "b.xml", ssh_document("true"));

    var result = try run(gpa, &.{ "diff", a, b });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_differences), result.code);
    try std.testing.expect(result.stdout_contains("<dm:DifferenceModel"));
    // The target's own profile survives into the difference model's header.
    try std.testing.expect(result.stdout_contains("<md:Model.profile>" ++ ssh_uri));
    try std.testing.expect(result.stdout_contains("<cim:Switch.open>true</cim:Switch.open>"));
}

// ── Explicit side routing ─────────────────────────────────────────────────────

test "diff --ssh routes header-less sides" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", headerless_ssh_document("false"));
    const b = try fixtures.write(&buf2, "b.xml", headerless_ssh_document("true"));

    var result = try run(gpa, &.{ "diff", "--ssh", a, "--ssh", b, "--patch" });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_differences), result.code);
    try std.testing.expect(result.stdout_contains("~ _BR1"));
}

test "diff side flags and positionals fill sides in argv order" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", ssh_document("false"));
    const b = try fixtures.write(&buf2, "b.xml", headerless_ssh_document("true"));

    // Positional left, flagged right: the patch header names them in that order
    // and the change reads false → true.
    var forward = try run(gpa, &.{ "diff", a, "--ssh", b, "--patch" });
    defer forward.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_differences), forward.code);
    try std.testing.expect(forward.stdout_contains("- Switch.open: \"false\""));
    try std.testing.expect(forward.stdout_contains("+ Switch.open: \"true\""));

    // Flag first: that side becomes the left one, so the change reverses.
    var reverse = try run(gpa, &.{ "diff", "--ssh", b, a, "--patch" });
    defer reverse.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_differences), reverse.code);
    try std.testing.expect(reverse.stdout_contains("- Switch.open: \"true\""));
    try std.testing.expect(reverse.stdout_contains("+ Switch.open: \"false\""));
}

test "diff rejects a side flag contradicting the declared profile" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", ssh_document("false"));
    const b = try fixtures.write(&buf2, "b.xml", ssh_document("true"));

    var result = try run(gpa, &.{ "diff", "--tp", a, b });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_data_error), result.code);
    try std.testing.expect(result.stderr_contains("declares ssh, contradicting --tp"));
}

test "diff rejects a third side operand" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", ssh_document("false"));

    var result = try run(gpa, &.{ "diff", a, a, "--ssh", a });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_usage), result.code);
    try std.testing.expect(result.stderr_contains("exactly two side operands are required"));
}

// ── Cross-side profile agreement ──────────────────────────────────────────────

test "diff rejects an EQ side against an SSH side" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "eq.xml", eq_document("North"));
    const b = try fixtures.write(&buf2, "ssh.xml", ssh_document("true"));

    var result = try run(gpa, &.{ "diff", a, b });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_data_error), result.code);
    try std.testing.expect(result.stderr_contains("both sides must be the same profile"));
    try std.testing.expect(result.stderr_contains("is eq"));
    try std.testing.expect(result.stderr_contains("is ssh"));
}

test "diff rejects a header-less side against a declared one" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    // The silent side is SSH here, but nothing in the file says so -- it is
    // just as plausibly the EQ document those mRIDs belong to, which would
    // diff to garbage. Refuse and name the flag that settles it.
    const a = try fixtures.write(&buf1, "a.xml", headerless_ssh_document("false"));
    const b = try fixtures.write(&buf2, "b.xml", ssh_document("true"));

    var result = try run(gpa, &.{ "diff", a, b, "--summary" });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_data_error), result.code);
    try std.testing.expect(result.stderr_contains("declares no profile"));
    try std.testing.expect(result.stderr_contains("route it with --ssh"));
}

test "diff compares a routed header-less side against a declared one" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", headerless_ssh_document("false"));
    const b = try fixtures.write(&buf2, "b.xml", ssh_document("true"));

    var result = try run(gpa, &.{ "diff", "--ssh", a, b, "--summary" });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_differences), result.code);
    try std.testing.expect(result.stdout_contains("Breaker"));
}

test "diff compares two header-less sides" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    // Neither side claims anything, so there is nothing to contradict.
    const a = try fixtures.write(&buf1, "a.xml", headerless_ssh_document("false"));
    const b = try fixtures.write(&buf2, "b.xml", headerless_ssh_document("true"));

    var result = try run(gpa, &.{ "diff", a, b, "--summary" });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_differences), result.code);
    try std.testing.expect(result.stdout_contains("Breaker"));
}

// ── Bundles ───────────────────────────────────────────────────────────────────

test "diff of bundle sides resolves the EQ part and skips the rest" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const a = try fixtures.write_bundle(gpa, &buf1, "a.zip", &.{
        .{ .name = "eq.xml", .data = eq_document("North") },
        .{ .name = "ssh.xml", .data = ssh_document("false") },
    });
    const b = try fixtures.write_bundle(gpa, &buf2, "b.zip", &.{
        .{ .name = "eq.xml", .data = eq_document("South") },
        .{ .name = "ssh.xml", .data = ssh_document("true") },
    });

    var result = try run(gpa, &.{ "diff", a, b, "--patch" });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_differences), result.code);
    // The EQ part is compared...
    try std.testing.expect(result.stdout_contains("- IdentifiedObject.name: \"North\""));
    // ...and the SSH part is skipped rather than silently mixed in.
    try std.testing.expect(!result.stdout_contains("Switch.open"));
    try std.testing.expect(result.stderr_contains("skipping ssh part"));
}

test "diff rejects a bundle side with no EQ part" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    const a = try fixtures.write_bundle(gpa, &buf1, "a.zip", &.{
        .{ .name = "ssh.xml", .data = ssh_document("false") },
        .{ .name = "tp.xml", .data = tp_document("_TN1") },
    });

    var result = try run(gpa, &.{ "diff", a, a });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_data_error), result.code);
    try std.testing.expect(result.stderr_contains("has no EQ part"));
}

// ── Boundary merge ────────────────────────────────────────────────────────────

test "diff --eqbd merges into EQ sides" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    var buf3: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", eq_document("North"));
    const b = try fixtures.write(&buf2, "b.xml", eq_document("South"));
    const bd = try fixtures.write(&buf3, "bd.xml", eqbd_document);

    var result = try run(gpa, &.{ "diff", a, b, "--eqbd", bd, "--patch" });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_differences), result.code);
    try std.testing.expect(result.stdout_contains("~ _BR1"));
    // The boundary is present on both sides, so it contributes no differences.
    try std.testing.expect(!result.stdout_contains("_CN1"));
}

test "diff --eqbd is rejected against non-EQ sides" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    var buf3: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", ssh_document("false"));
    const b = try fixtures.write(&buf2, "b.xml", ssh_document("true"));
    const bd = try fixtures.write(&buf3, "bd.xml", eqbd_document);

    var result = try run(gpa, &.{ "diff", a, b, "--eqbd", bd });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_data_error), result.code);
    try std.testing.expect(result.stderr_contains("cannot merge a boundary into ssh part"));
}

// ── Unrecognized profile URIs ─────────────────────────────────────────────────
//
// A header naming a profile the routing table does not know cannot be guessed
// at -- but a diff only needs the two sides to agree on *something*, so any side
// flag routes it. This is the escape hatch for boundary parts in particular:
// `--eqbd` names the shared boundary on `diff`, so there is no `--eqbd` side
// flag, and `--eq` is what an unrecognized boundary file takes.

const future_eqbd_uri = "http://iec.ch/TC57/ns/CIM/EquipmentBoundary-EU/4.0";

inline fn future_boundary_document(comptime name: []const u8) []const u8 {
    return header(future_eqbd_uri) ++
        "  <cim:ConnectivityNode rdf:ID=\"_CN1\">\n" ++
        "    <cim:IdentifiedObject.name>" ++ name ++ "</cim:IdentifiedObject.name>\n" ++
        "  </cim:ConnectivityNode>\n</rdf:RDF>\n";
}

test "diff refuses to guess at an unrecognized profile URI" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", future_boundary_document("North"));
    const b = try fixtures.write(&buf2, "b.xml", future_boundary_document("South"));

    var result = try run(gpa, &.{ "diff", a, b });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_data_error), result.code);
    try std.testing.expect(result.stderr_contains("unknown profile URI"));
    try std.testing.expect(result.stderr_contains("use a kind flag"));
}

test "diff compares unrecognized profiles routed under one agreed kind" {
    const gpa = std.testing.allocator;
    var fixtures = Fixtures.init();
    defer fixtures.deinit();
    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const a = try fixtures.write(&buf1, "a.xml", future_boundary_document("North"));
    const b = try fixtures.write(&buf2, "b.xml", future_boundary_document("South"));

    var result = try run(gpa, &.{ "diff", "--eq", a, "--eq", b, "--patch" });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, exit_differences), result.code);
    try std.testing.expect(result.stdout_contains("- IdentifiedObject.name: \"North\""));
    try std.testing.expect(result.stdout_contains("+ IdentifiedObject.name: \"South\""));
}
