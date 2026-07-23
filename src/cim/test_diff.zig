const std = @import("std");
const CimDocument = @import("document.zig").CimDocument;
const diff = @import("diff.zig");
const DiffOptions = diff.DiffOptions;

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Run diff_models on two XML strings and return (had_diffs, output).
/// Output is written into a fixed stack buffer -- tests must not exceed 8 KiB.
const DiffResult = struct {
    had_diffs: bool,
    buf: [8192]u8,
    len: usize,

    fn output(self: *const DiffResult) []const u8 {
        return self.buf[0..self.len];
    }

    fn contains(self: *const DiffResult, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output(), needle) != null;
    }
};

fn run_diff(
    gpa: std.mem.Allocator,
    xml1: []const u8,
    xml2: []const u8,
    options: DiffOptions,
) !DiffResult {
    var model1 = try CimDocument.init(gpa, try gpa.dupe(u8, xml1));
    defer model1.deinit(gpa);
    var model2 = try CimDocument.init(gpa, try gpa.dupe(u8, xml2));
    defer model2.deinit(gpa);

    var result = DiffResult{ .had_diffs = false, .buf = undefined, .len = 0 };
    var writer: std.Io.Writer = .fixed(&result.buf);
    result.had_diffs = try diff.diff_models(
        gpa,
        &model1,
        &model2,
        "file1.xml",
        "file2.xml",
        options,
        &writer,
    );
    result.len = writer.end;
    return result;
}

// ── Return value ──────────────────────────────────────────────────────────────

test "diff - identical models return false, empty output" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml, xml, .{});
    try std.testing.expect(!r.had_diffs);
    // In text mode only the --- / +++ header is emitted for identical models.
    try std.testing.expect(!r.contains("@@ Substation @@"));
}

test "diff - added object returns true" {
    const xml1 = "<rdf:RDF></rdf:RDF>";
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
}

test "diff - removed object returns true" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 = "<rdf:RDF></rdf:RDF>";
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
}

test "diff - changed property returns true" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>South</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
}

test "diff - changed reference returns true" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:VoltageLevel.Substation rdf:resource="#_SS1"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:VoltageLevel.Substation rdf:resource="#_SS2"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
}

// ── Semantic correctness ───────────────────────────────────────────────────────

test "diff - property XML order does not matter (semantic diff)" {
    // The KEY invariant: same data in different XML element order → no diff.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\    <cim:IdentifiedObject.description>Main site</cim:IdentifiedObject.description>
        \\    <cim:Substation.Region rdf:resource="#_R1"/>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:Substation.Region rdf:resource="#_R1"/>
        \\    <cim:IdentifiedObject.description>Main site</cim:IdentifiedObject.description>
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(!r.had_diffs);
}

test "diff - object XML order does not matter (matching by mRID)" {
    // SS1 and SS2 appear in reversed order in the two files but are identical.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Alpha</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_SS2">
        \\    <cim:IdentifiedObject.name>Beta</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS2">
        \\    <cim:IdentifiedObject.name>Beta</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Alpha</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(!r.had_diffs);
}

test "diff - unchanged object not included in output" {
    // SS1 is unchanged, SS2 is changed. Only SS2 should appear in the output.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Unchanged</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_SS2">
        \\    <cim:IdentifiedObject.name>OldName</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Unchanged</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_SS2">
        \\    <cim:IdentifiedObject.name>NewName</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(!r.contains("Unchanged"));
    try std.testing.expect(r.contains("_SS2"));
}

test "diff - added property detected" {
    // Model2 has an extra property on an existing object.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\    <cim:IdentifiedObject.description>New description</cim:IdentifiedObject.description>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("IdentifiedObject.description"));
}

test "diff - removed property detected" {
    // Model1 has a property that model2 drops.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\    <cim:IdentifiedObject.description>Disappears</cim:IdentifiedObject.description>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("IdentifiedObject.description"));
}

// ── Edge cases ────────────────────────────────────────────────────────────────

test "diff - both models empty" {
    const xml = "<rdf:RDF></rdf:RDF>";
    const r = try run_diff(std.testing.allocator, xml, xml, .{});
    try std.testing.expect(!r.had_diffs);
}

test "diff - model1 empty, all objects added" {
    const xml1 = "<rdf:RDF></rdf:RDF>";
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_SS2">
        \\    <cim:IdentifiedObject.name>Also New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("+ _SS1"));
    try std.testing.expect(r.contains("+ _SS2"));
    // No removed lines (the "--- file1.xml" header does not count as a removal).
    try std.testing.expect(!r.contains("- _"));
}

test "diff - model2 empty, all objects removed" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Gone</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 = "<rdf:RDF></rdf:RDF>";
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("- _SS1"));
    // No added lines (the "+++ file2.xml" header does not count as an addition).
    try std.testing.expect(!r.contains("+ _"));
}

test "diff - type only in model1 (all removed)" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:PowerTransformer rdf:ID="_T1">
        \\    <cim:IdentifiedObject.name>T1</cim:IdentifiedObject.name>
        \\  </cim:PowerTransformer>
        \\</rdf:RDF>
    ;
    const xml2 = "<rdf:RDF></rdf:RDF>";
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("@@ PowerTransformer @@"));
    try std.testing.expect(r.contains("- _T1"));
}

test "diff - type only in model2 (all added)" {
    const xml1 = "<rdf:RDF></rdf:RDF>";
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:PowerTransformer rdf:ID="_T1">
        \\    <cim:IdentifiedObject.name>T1</cim:IdentifiedObject.name>
        \\  </cim:PowerTransformer>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("@@ PowerTransformer @@"));
    try std.testing.expect(r.contains("+ _T1"));
}

test "diff - object with no name property does not crash" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\</rdf:RDF>
    ;
    const xml2 = "<rdf:RDF></rdf:RDF>";
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("_SS1"));
}

test "diff - multiple properties changed in one object" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>OldName</cim:IdentifiedObject.name>
        \\    <cim:IdentifiedObject.description>OldDesc</cim:IdentifiedObject.description>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>NewName</cim:IdentifiedObject.name>
        \\    <cim:IdentifiedObject.description>NewDesc</cim:IdentifiedObject.description>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("IdentifiedObject.name"));
    try std.testing.expect(r.contains("IdentifiedObject.description"));
    try std.testing.expect(r.contains("OldName"));
    try std.testing.expect(r.contains("NewName"));
}

// ── Text output format ────────────────────────────────────────────────────────

test "diff - text output has file header" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>A</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>B</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.contains("--- file1.xml"));
    try std.testing.expect(r.contains("+++ file2.xml"));
}

test "diff - text output type header only for types with diffs" {
    // Substation changes, VoltageLevel does not.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Old</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:IdentifiedObject.name>Same</cim:IdentifiedObject.name>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:IdentifiedObject.name>Same</cim:IdentifiedObject.name>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.contains("@@ Substation @@"));
    try std.testing.expect(!r.contains("@@ VoltageLevel @@"));
}

test "diff - text output added object has + prefix" {
    const xml1 = "<rdf:RDF></rdf:RDF>";
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.contains("+ _SS1"));
}

test "diff - text output removed object has - prefix" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Gone</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 = "<rdf:RDF></rdf:RDF>";
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.contains("- _SS1"));
}

test "diff - text output changed object has ~ prefix and indented property diff" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>OldName</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>NewName</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.contains("~ _SS1"));
    // Property diff lines are indented with two spaces.
    try std.testing.expect(r.contains("  - IdentifiedObject.name"));
    try std.testing.expect(r.contains("  + IdentifiedObject.name"));
    try std.testing.expect(r.contains("OldName"));
    try std.testing.expect(r.contains("NewName"));
}

test "diff - text output added object shows name" {
    const xml1 = "<rdf:RDF></rdf:RDF>";
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>TheStation</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.contains("TheStation"));
}

// ── JSON output ───────────────────────────────────────────────────────────────

test "diff - json mode has no file header" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>A</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml, xml, .{ .format = .json });
    try std.testing.expect(!r.contains("---"));
    try std.testing.expect(!r.contains("+++"));
}

test "diff - json mode added object emits status added" {
    const xml1 = "<rdf:RDF></rdf:RDF>";
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{ .format = .json });
    try std.testing.expect(r.contains("\"status\":\"added\""));
    try std.testing.expect(r.contains("\"mrid\":\"_SS1\""));
    try std.testing.expect(r.contains("\"type\":\"Substation\""));
}

test "diff - json mode removed object emits status removed" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Gone</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 = "<rdf:RDF></rdf:RDF>";
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{ .format = .json });
    try std.testing.expect(r.contains("\"status\":\"removed\""));
    try std.testing.expect(r.contains("\"mrid\":\"_SS1\""));
}

test "diff - json mode changed object emits status changed with changes array" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>OldName</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>NewName</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{ .format = .json });
    try std.testing.expect(r.contains("\"status\":\"changed\""));
    try std.testing.expect(r.contains("\"changes\":["));
    try std.testing.expect(r.contains("\"property\":\"IdentifiedObject.name\""));
    try std.testing.expect(r.contains("\"from\":\"OldName\""));
    try std.testing.expect(r.contains("\"to\":\"NewName\""));
}

test "diff - json mode identical models produce no output" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Same</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml, xml, .{ .format = .json });
    try std.testing.expect(!r.had_diffs);
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

test "diff - json mode added property shows from null" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\    <cim:IdentifiedObject.description>Added</cim:IdentifiedObject.description>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{ .format = .json });
    try std.testing.expect(r.contains("\"from\":null"));
    try std.testing.expect(r.contains("\"to\":\"Added\""));
}

test "diff - json mode removed property shows to null" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\    <cim:IdentifiedObject.description>Removed</cim:IdentifiedObject.description>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{ .format = .json });
    try std.testing.expect(r.contains("\"to\":null"));
    try std.testing.expect(r.contains("\"from\":\"Removed\""));
}

test "diff - json mode escapes quotes and backslashes in values" {
    // XML text content may contain raw quotes/backslashes; unescaped emission
    // would corrupt the NDJSON stream.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>plain</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>say "hi" \now</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{ .format = .json });
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("\"to\":\"say \\\"hi\\\" \\\\now\""));

    // Every emitted line must parse as JSON.
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.output(), "\n"), '\n');
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        parsed.deinit();
    }
}

// ── Summary mode ──────────────────────────────────────────────────────────────

test "diff - summary mode shows per-type counts" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Changed</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_SS2">
        \\    <cim:IdentifiedObject.name>Removed</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>ChangedNew</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_SS3">
        \\    <cim:IdentifiedObject.name>Added</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    // SS1 changed, SS2 removed, SS3 added → +1 -1 ~1
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{ .format = .summary });
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("+1"));
    try std.testing.expect(r.contains("-1"));
    try std.testing.expect(r.contains("~1"));
    try std.testing.expect(r.contains("Substation"));
}

test "diff - summary mode emits no object lines" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Old</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{ .format = .summary });
    try std.testing.expect(!r.contains("~ _SS1"));
    try std.testing.expect(!r.contains("IdentifiedObject.name"));
    try std.testing.expect(!r.contains("@@ Substation @@"));
    try std.testing.expect(!r.contains("---"));
}

test "diff - summary mode identical models produce no output" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Same</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml, xml, .{ .format = .summary });
    try std.testing.expect(!r.had_diffs);
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

// ── Type filter ───────────────────────────────────────────────────────────────

test "diff - type filter restricts comparison to one type" {
    // Both types differ but only Substation is requested.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>OldSS</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:IdentifiedObject.name>OldVL</cim:IdentifiedObject.name>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>NewSS</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:IdentifiedObject.name>NewVL</cim:IdentifiedObject.name>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{ .type_filter = "Substation" });
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("@@ Substation @@"));
    try std.testing.expect(!r.contains("@@ VoltageLevel @@"));
    try std.testing.expect(!r.contains("OldVL"));
}

test "diff - type filter includes CIM subtypes" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_ACL1">
        \\    <cim:IdentifiedObject.name>OldLine</cim:IdentifiedObject.name>
        \\  </cim:ACLineSegment>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>OldSub</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_ACL1">
        \\    <cim:IdentifiedObject.name>NewLine</cim:IdentifiedObject.name>
        \\  </cim:ACLineSegment>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>NewSub</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{ .type_filter = "ConductingEquipment" });
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("@@ ACLineSegment @@"));
    try std.testing.expect(!r.contains("@@ Substation @@"));
}

test "diff - type filter for nonexistent type returns no diffs" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>A</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>B</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml, xml2, .{ .type_filter = "PowerTransformer" });
    try std.testing.expect(!r.had_diffs);
}

// ── Multi-type ────────────────────────────────────────────────────────────────

test "diff - multiple types, mixed changes" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Same</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:IdentifiedObject.name>OldVL</cim:IdentifiedObject.name>
        \\  </cim:VoltageLevel>
        \\  <cim:PowerTransformer rdf:ID="_T1">
        \\    <cim:IdentifiedObject.name>T1</cim:IdentifiedObject.name>
        \\  </cim:PowerTransformer>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Same</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:IdentifiedObject.name>NewVL</cim:IdentifiedObject.name>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    // VoltageLevel changed.
    try std.testing.expect(r.contains("@@ VoltageLevel @@"));
    // PowerTransformer removed.
    try std.testing.expect(r.contains("@@ PowerTransformer @@"));
    // Substation unchanged -- no header.
    try std.testing.expect(!r.contains("@@ Substation @@"));
}

test "diff - type change with same mrid is removed from old type and added to new type" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_SW1">
        \\    <cim:IdentifiedObject.name>Bay switch</cim:IdentifiedObject.name>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Disconnector rdf:ID="_SW1">
        \\    <cim:IdentifiedObject.name>Bay switch</cim:IdentifiedObject.name>
        \\  </cim:Disconnector>
        \\</rdf:RDF>
    ;

    const patch = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(patch.had_diffs);
    try std.testing.expect(patch.contains("@@ Breaker @@"));
    try std.testing.expect(patch.contains("- _SW1  \"Bay switch\""));
    try std.testing.expect(patch.contains("@@ Disconnector @@"));
    try std.testing.expect(patch.contains("+ _SW1  \"Bay switch\""));

    const summary = try run_diff(std.testing.allocator, xml1, xml2, .{ .format = .summary });
    try std.testing.expect(summary.had_diffs);
    try std.testing.expect(summary.contains("Breaker  +0 -1 ~0"));
    try std.testing.expect(summary.contains("Disconnector  +1 -0 ~0"));
}

test "diff - reference change detected alongside unchanged properties" {
    // Name is the same, but the VL's parent substation reference changed.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:IdentifiedObject.name>380kV</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.Substation rdf:resource="#_SS1"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:IdentifiedObject.name>380kV</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.Substation rdf:resource="#_SS2"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("VoltageLevel.Substation"));
}

test "diff - property flipped to a reference with the same value is detected" {
    // <cim:X>#_A</cim:X> vs <cim:X rdf:resource="#_A"/>: same name and
    // lexical value, different statement kind. The CIM schema fixes each
    // property's kind, so the flip is a removal plus an addition -- it must
    // not silently match.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:Substation.Region>#_R1</cim:Substation.Region>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:Substation.Region rdf:resource="#_R1"/>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("  - Substation.Region: \"#_R1\""));
    try std.testing.expect(r.contains("  + Substation.Region: \"#_R1\""));

    const json = try run_diff(std.testing.allocator, xml1, xml2, .{ .format = .json });
    try std.testing.expect(json.had_diffs);
    try std.testing.expect(json.contains("\"property\":\"Substation.Region\",\"from\":\"#_R1\",\"to\":null"));
    try std.testing.expect(json.contains("\"property\":\"Substation.Region\",\"from\":null,\"to\":\"#_R1\""));
}

test "diff - empty self-closing literal equals explicit empty literal" {
    // Without rdf:resource, <cim:X/> is just XML empty-element syntax for an
    // empty literal -- the kind follows the attribute, not the syntax, so the
    // two spellings must not produce a false difference.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name/>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name></cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(!r.had_diffs);

    // An actual rdf:resource -- even an empty one -- is still a reference,
    // so against the empty literal the kinds differ.
    const xml3 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name rdf:resource=""/>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r2 = try run_diff(std.testing.allocator, xml2, xml3, .{});
    try std.testing.expect(r2.had_diffs);
}

test "diff - expanded reference equals self-closing reference" {
    // <cim:X rdf:resource="#_A"></cim:X> is the expanded serialization of
    // <cim:X rdf:resource="#_A"/>: kind and value follow the attribute in
    // both element forms.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:Substation.Region rdf:resource="#_R1"></cim:Substation.Region>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:Substation.Region rdf:resource="#_R1"/>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(!r.had_diffs);

    // Against an empty literal the expanded reference is still a reference.
    const xml3 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:Substation.Region></cim:Substation.Region>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r2 = try run_diff(std.testing.allocator, xml1, xml3, .{});
    try std.testing.expect(r2.had_diffs);
}

// ── Single-mRID diff helper ───────────────────────────────────────────────────

const SingleResult = struct {
    status: diff.SingleDiffStatus,
    buf: [8192]u8,
    len: usize,
    /// Owned copy of the type_mismatch name, valid after model deinit.
    /// Null for all other status variants.
    type_mismatch_name: ?[]u8 = null,

    fn output(self: *const SingleResult) []const u8 {
        return self.buf[0..self.len];
    }

    fn contains(self: *const SingleResult, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output(), needle) != null;
    }

    fn deinit(self: *SingleResult, gpa: std.mem.Allocator) void {
        if (self.type_mismatch_name) |s| gpa.free(s);
    }
};

fn run_diff_single(
    gpa: std.mem.Allocator,
    xml1: []const u8,
    xml2: []const u8,
    mrid: []const u8,
    options: DiffOptions,
) !SingleResult {
    var model1 = try CimDocument.init(gpa, try gpa.dupe(u8, xml1));
    errdefer model1.deinit(gpa);
    var model2 = try CimDocument.init(gpa, try gpa.dupe(u8, xml2));
    errdefer model2.deinit(gpa);

    var result = SingleResult{ .status = .not_found, .buf = undefined, .len = 0 };
    var writer: std.Io.Writer = .fixed(&result.buf);
    const raw_status = try diff.diff_single(gpa, &model1, &model2, mrid, "file1.xml", "file2.xml", options, &writer);
    result.len = writer.end;

    // type_mismatch payload points into model xml -- dupe it before models are freed.
    result.status = switch (raw_status) {
        .type_mismatch => |name| blk: {
            result.type_mismatch_name = try gpa.dupe(u8, name);
            break :blk .{ .type_mismatch = result.type_mismatch_name.? };
        },
        else => raw_status,
    };

    model2.deinit(gpa);
    model1.deinit(gpa);
    return result;
}

// ── Single-mRID: return values ────────────────────────────────────────────────

test "diff single - identical object returns diff=false" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml, xml, "_SS1", .{});
    switch (r.status) {
        .diff => |had| try std.testing.expect(!had),
        else => return error.TestUnexpectedResult,
    }
}

test "diff single - changed object returns diff=true" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>OldName</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>NewName</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{});
    switch (r.status) {
        .diff => |had| try std.testing.expect(had),
        else => return error.TestUnexpectedResult,
    }
}

test "diff single - object only in model2 returns diff=true (added)" {
    const xml1 = "<rdf:RDF></rdf:RDF>";
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{});
    switch (r.status) {
        .diff => |had| try std.testing.expect(had),
        else => return error.TestUnexpectedResult,
    }
}

test "diff single - object only in model1 returns diff=true (removed)" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Gone</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 = "<rdf:RDF></rdf:RDF>";
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{});
    switch (r.status) {
        .diff => |had| try std.testing.expect(had),
        else => return error.TestUnexpectedResult,
    }
}

test "diff single - type change with same mrid is reported as removed+added" {
    // Identical children, only the CIM type differs -- must still be a diff,
    // mirroring diff_models which matches within concrete types.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_SW1">
        \\    <cim:IdentifiedObject.name>Bay switch</cim:IdentifiedObject.name>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Disconnector rdf:ID="_SW1">
        \\    <cim:IdentifiedObject.name>Bay switch</cim:IdentifiedObject.name>
        \\  </cim:Disconnector>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SW1", .{});
    switch (r.status) {
        .diff => |had| try std.testing.expect(had),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(r.contains("- _SW1"));
    try std.testing.expect(r.contains("+ _SW1"));

    const json = try run_diff_single(std.testing.allocator, xml1, xml2, "_SW1", .{ .format = .json });
    try std.testing.expect(json.contains("{\"type\":\"Breaker\",\"mrid\":\"_SW1\",\"status\":\"removed\"}"));
    try std.testing.expect(json.contains("{\"type\":\"Disconnector\",\"mrid\":\"_SW1\",\"status\":\"added\"}"));

    const summary = try run_diff_single(std.testing.allocator, xml1, xml2, "_SW1", .{ .format = .summary });
    try std.testing.expect(summary.contains("Breaker  +0 -1 ~0"));
    try std.testing.expect(summary.contains("Disconnector  +1 -0 ~0"));
}

test "diff single - mRID not in either model returns not_found" {
    const xml = "<rdf:RDF></rdf:RDF>";
    const r = try run_diff_single(std.testing.allocator, xml, xml, "_MISSING", .{});
    try std.testing.expectEqual(diff.SingleDiffStatus.not_found, r.status);
}

test "diff single - mRID not in either model produces no output" {
    const xml = "<rdf:RDF></rdf:RDF>";
    const r = try run_diff_single(std.testing.allocator, xml, xml, "_MISSING", .{});
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

// ── Single-mRID: type verification ───────────────────────────────────────────

test "diff single - correct type passes verification" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>A</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>B</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{ .type_filter = "Substation" });
    switch (r.status) {
        .diff => |had| try std.testing.expect(had),
        else => return error.TestUnexpectedResult,
    }
}

test "diff single - base type passes subtype verification" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_ACL1">
        \\    <cim:IdentifiedObject.name>A</cim:IdentifiedObject.name>
        \\  </cim:ACLineSegment>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_ACL1">
        \\    <cim:IdentifiedObject.name>B</cim:IdentifiedObject.name>
        \\  </cim:ACLineSegment>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_ACL1", .{ .type_filter = "ConductingEquipment" });
    switch (r.status) {
        .diff => |had| try std.testing.expect(had),
        else => return error.TestUnexpectedResult,
    }
}

test "diff single - wrong type returns type_mismatch with actual type" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    var r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{ .type_filter = "PowerTransformer" });
    defer r.deinit(std.testing.allocator);
    switch (r.status) {
        .type_mismatch => |actual| try std.testing.expectEqualStrings("Substation", actual),
        else => return error.TestUnexpectedResult,
    }
}

test "diff single - type mismatch produces no output" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    var r = try run_diff_single(std.testing.allocator, xml, xml, "_SS1", .{ .type_filter = "PowerTransformer" });
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

test "diff single - type check applies to model2 when object only in model2" {
    // Object is added (not in model1) but --type matches -- should proceed normally.
    const xml1 = "<rdf:RDF></rdf:RDF>";
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{ .type_filter = "Substation" });
    switch (r.status) {
        .diff => |had| try std.testing.expect(had),
        else => return error.TestUnexpectedResult,
    }
}

test "diff single - type check applies to model2 when object only in model2, wrong type" {
    const xml1 = "<rdf:RDF></rdf:RDF>";
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    var r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{ .type_filter = "VoltageLevel" });
    defer r.deinit(std.testing.allocator);
    switch (r.status) {
        .type_mismatch => |actual| try std.testing.expectEqualStrings("Substation", actual),
        else => return error.TestUnexpectedResult,
    }
}

// ── Single-mRID: text output ──────────────────────────────────────────────────

test "diff single - added object has + prefix and file header" {
    const xml1 = "<rdf:RDF></rdf:RDF>";
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{});
    try std.testing.expect(r.contains("--- file1.xml"));
    try std.testing.expect(r.contains("+++ file2.xml"));
    try std.testing.expect(r.contains("+ _SS1"));
}

test "diff single - removed object has - prefix" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Gone</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 = "<rdf:RDF></rdf:RDF>";
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{});
    try std.testing.expect(r.contains("- _SS1"));
}

test "diff single - changed object has ~ prefix and property diff lines" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>OldName</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>NewName</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{});
    try std.testing.expect(r.contains("~ _SS1"));
    try std.testing.expect(r.contains("  - IdentifiedObject.name"));
    try std.testing.expect(r.contains("  + IdentifiedObject.name"));
    try std.testing.expect(r.contains("OldName"));
    try std.testing.expect(r.contains("NewName"));
}

test "diff single - identical object produces only file header, no diff lines" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Same</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml, xml, "_SS1", .{});
    try std.testing.expect(r.contains("--- file1.xml"));
    try std.testing.expect(!r.contains("~ "));
    try std.testing.expect(!r.contains("+ _"));
    try std.testing.expect(!r.contains("- _"));
}

test "diff single - other objects in the model are not diffed" {
    // SS2 is different between the two models, but we only asked for SS1.
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Same</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_SS2">
        \\    <cim:IdentifiedObject.name>OldSS2</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Same</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_SS2">
        \\    <cim:IdentifiedObject.name>NewSS2</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{});
    switch (r.status) {
        .diff => |had| try std.testing.expect(!had),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!r.contains("_SS2"));
}

// ── Single-mRID: JSON output ──────────────────────────────────────────────────

test "diff single - json mode changed object" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>OldName</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>NewName</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{ .format = .json });
    try std.testing.expect(r.contains("\"status\":\"changed\""));
    try std.testing.expect(r.contains("\"mrid\":\"_SS1\""));
    try std.testing.expect(!r.contains("---"));
}

test "diff single - json mode added object" {
    const xml1 = "<rdf:RDF></rdf:RDF>";
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{ .format = .json });
    try std.testing.expect(r.contains("\"status\":\"added\""));
    try std.testing.expect(r.contains("\"mrid\":\"_SS1\""));
}

test "diff single - json mode identical object produces no output" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Same</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml, xml, "_SS1", .{ .format = .json });
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

// ── Single-mRID: summary mode ─────────────────────────────────────────────────

test "diff single - summary mode added shows +1 count" {
    const xml1 = "<rdf:RDF></rdf:RDF>";
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{ .format = .summary });
    try std.testing.expect(r.contains("+1"));
    try std.testing.expect(r.contains("Substation"));
    try std.testing.expect(!r.contains("+ _SS1"));
}

test "diff single - summary mode changed shows ~1 count" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Old</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>New</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml1, xml2, "_SS1", .{ .format = .summary });
    try std.testing.expect(r.contains("~1"));
    try std.testing.expect(!r.contains("~ _SS1"));
}

test "diff single - summary mode identical produces no output" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>Same</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_diff_single(std.testing.allocator, xml, xml, "_SS1", .{ .format = .summary });
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

// ── Non-EQ profiles ───────────────────────────────────────────────────────────
//
// SSH, TP and the other profiles carry rdf:about patches on mRIDs the EQ
// profile owns, rather than rdf:ID-declared objects. Matching and statement
// comparison are profile-agnostic, so these diff exactly like EQ objects.

test "diff - SSH switch states differ" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:about="#_BR1">
        \\    <cim:Switch.open>false</cim:Switch.open>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:about="#_BR1">
        \\    <cim:Switch.open>true</cim:Switch.open>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("@@ Breaker @@"));
    try std.testing.expect(r.contains("~ _BR1"));
    try std.testing.expect(r.contains("  - Switch.open: \"false\""));
    try std.testing.expect(r.contains("  + Switch.open: \"true\""));
}

test "diff - SSH type filter selects one patched type" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:about="#_BR1">
        \\    <cim:Switch.open>false</cim:Switch.open>
        \\  </cim:Breaker>
        \\  <cim:SynchronousMachine rdf:about="#_SM1">
        \\    <cim:RotatingMachine.p>-10</cim:RotatingMachine.p>
        \\  </cim:SynchronousMachine>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:about="#_BR1">
        \\    <cim:Switch.open>true</cim:Switch.open>
        \\  </cim:Breaker>
        \\  <cim:SynchronousMachine rdf:about="#_SM1">
        \\    <cim:RotatingMachine.p>-20</cim:RotatingMachine.p>
        \\  </cim:SynchronousMachine>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{ .type_filter = "Switch" });
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("~ _BR1"));
    try std.testing.expect(!r.contains("_SM1"));
}

test "diff - TP topological node reassignment" {
    const xml1 =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:about="#_T1">
        \\    <cim:Terminal.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:about="#_T1">
        \\    <cim:Terminal.TopologicalNode rdf:resource="#_TN2"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    const r = try run_diff(std.testing.allocator, xml1, xml2, .{ .format = .json });
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.contains("\"property\":\"Terminal.TopologicalNode\""));
    try std.testing.expect(r.contains("\"from\":\"#_TN1\""));
    try std.testing.expect(r.contains("\"to\":\"#_TN2\""));
}
