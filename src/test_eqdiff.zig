const std = @import("std");
const EQ = @import("cgmes/eq.zig").EQ;
const eqdiff = @import("eqdiff.zig");

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Run write_models on two XML strings and return (had_diffs, output).
/// Output is written into a fixed stack buffer — tests must not exceed 16 KiB.
const EqdiffResult = struct {
    had_diffs: bool,
    buf: [16384]u8,
    len: usize,

    fn output(self: *const EqdiffResult) []const u8 {
        return self.buf[0..self.len];
    }

    fn contains(self: *const EqdiffResult, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output(), needle) != null;
    }

    /// True when `needle` appears inside the given dm: section.
    fn section_contains(self: *const EqdiffResult, comptime section: []const u8, needle: []const u8) bool {
        const out = self.output();
        const open = std.mem.indexOf(u8, out, "<dm:" ++ section ++ " rdf:parseType=\"Statements\">") orelse return false;
        const close = std.mem.indexOf(u8, out, "</dm:" ++ section ++ ">") orelse return false;
        if (close < open) return false;
        return std.mem.indexOf(u8, out[open..close], needle) != null;
    }
};

fn run_eqdiff(
    gpa: std.mem.Allocator,
    xml1: []const u8,
    xml2: []const u8,
    options: eqdiff.Options,
) !EqdiffResult {
    var model1 = try EQ.init(gpa, try gpa.dupe(u8, xml1));
    defer model1.deinit(gpa);
    var model2 = try EQ.init(gpa, try gpa.dupe(u8, xml2));
    defer model2.deinit(gpa);

    var result = EqdiffResult{ .had_diffs = false, .buf = undefined, .len = 0 };
    var writer: std.Io.Writer = .fixed(&result.buf);
    result.had_diffs = try eqdiff.write_models(gpa, &model1, &model2, options, &writer);
    result.len = writer.end;
    return result;
}

const RDF_OPEN =
    \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#">
;

// ── Document structure ────────────────────────────────────────────────────────

test "eqdiff - identical models: no diffs, valid empty difference model" {
    const xml = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml, xml, .{});
    try std.testing.expect(!r.had_diffs);
    try std.testing.expect(r.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
    try std.testing.expect(r.contains("<dm:DifferenceModel rdf:about=\"urn:uuid:"));
    try std.testing.expect(r.contains("<dm:forwardDifferences rdf:parseType=\"Statements\">"));
    try std.testing.expect(r.contains("<dm:reverseDifferences rdf:parseType=\"Statements\">"));
    // No statements in either section.
    try std.testing.expect(!r.contains("rdf:Description"));
    try std.testing.expect(!r.section_contains("forwardDifferences", "<cim:"));
    try std.testing.expect(!r.section_contains("reverseDifferences", "<cim:"));
}

test "eqdiff - root element merges input xmlns and declares dm" {
    const xml = RDF_OPEN ++ "\n</rdf:RDF>";
    const r = try run_eqdiff(std.testing.allocator, xml, xml, .{});
    try std.testing.expect(r.contains("xmlns:cim=\"http://iec.ch/TC57/CIM100#\""));
    try std.testing.expect(r.contains("xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\""));
    try std.testing.expect(r.contains("xmlns:dm=\"http://iec.ch/2002/schema/CIM_difference_model#\""));
}

test "eqdiff - input claiming the dm prefix forces a fallback prefix" {
    // The input binds "dm" to an unrelated extension namespace; the generated
    // difference-model elements must not silently inherit that binding.
    const xml =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#" xmlns:dm="http://example.com/other-extension#">
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml, xml, .{});
    // The input's declaration is preserved...
    try std.testing.expect(r.contains("xmlns:dm=\"http://example.com/other-extension#\""));
    // ...and the difference model binds a fallback prefix to the IEC namespace.
    try std.testing.expect(r.contains("xmlns:dm0=\"http://iec.ch/2002/schema/CIM_difference_model#\""));
    try std.testing.expect(r.contains("<dm0:DifferenceModel rdf:about=\"urn:uuid:"));
    try std.testing.expect(r.contains("<dm0:forwardDifferences rdf:parseType=\"Statements\">"));
    try std.testing.expect(r.contains("</dm0:reverseDifferences>"));
    try std.testing.expect(!r.contains("<dm:DifferenceModel"));
}

test "eqdiff - input prefix already bound to the IEC namespace is reused" {
    const xml =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#" xmlns:diff="http://iec.ch/2002/schema/CIM_difference_model#">
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml, xml, .{});
    try std.testing.expect(r.contains("<diff:DifferenceModel rdf:about=\"urn:uuid:"));
    try std.testing.expect(r.contains("<diff:forwardDifferences rdf:parseType=\"Statements\">"));
    // No second declaration of the same namespace under "dm".
    try std.testing.expect(!r.contains("xmlns:dm="));
}

test "eqdiff - FullModel-local xmlns is hoisted to the root" {
    // model2's FullModel declares md locally and model1 has no FullModel:
    // the copied header children must not end up with an unbound prefix.
    const xml1 =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#">
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#">
        \\  <md:FullModel rdf:about="urn:uuid:22222222-2222-2222-2222-222222222222" xmlns:md="http://iec.ch/TC57/61970-552/ModelDescription/1#">
        \\    <md:Model.version>2</md:Model.version>
        \\  </md:FullModel>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.contains("xmlns:md=\"http://iec.ch/TC57/61970-552/ModelDescription/1#\""));
    try std.testing.expect(r.contains("<md:Model.version>2</md:Model.version>"));
}

test "eqdiff - FullModel-local xmlns conflicting with the root is rejected" {
    // The roots bind md to an unrelated namespace; model2's FullModel rebinds
    // it locally. Its children are copied into the header without their
    // declaring parent, so the conflicting binding cannot be represented in
    // the merged root scope — rejected rather than silently reinterpreted.
    const xml1 =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#" xmlns:md="http://example.com/other#">
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#" xmlns:md="http://example.com/other#">
        \\  <md:FullModel rdf:about="urn:uuid:22222222-2222-2222-2222-222222222222" xmlns:md="http://iec.ch/TC57/61970-552/ModelDescription/1#">
        \\    <md:Model.version>2</md:Model.version>
        \\  </md:FullModel>
        \\</rdf:RDF>
    ;
    try std.testing.expectError(
        error.ConflictingNamespaceBindings,
        run_eqdiff(std.testing.allocator, xml1, xml2, .{}),
    );
}

test "eqdiff - inputs binding one prefix to different namespaces are rejected" {
    // The inputs bind cim to different schema versions. Statements are copied
    // verbatim, so a single merged root scope cannot keep both meanings —
    // EQ-like inputs always agree per prefix, so this is rejected loudly.
    const xml1 =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/2013/CIM-schema-cim16#">
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#">
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>South</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    try std.testing.expectError(
        error.ConflictingNamespaceBindings,
        run_eqdiff(std.testing.allocator, xml1, xml2, .{}),
    );
}

test "eqdiff - object-local xmlns overriding the root is preserved, not a conflict" {
    // Conflict detection only applies to the root and FullModel scopes;
    // a binding local to an ordinary object's tag is re-declared on the
    // emitted element (emit_local_xmlns) and keeps its source meaning.
    const xml1 = RDF_OPEN ++
        \\
        \\  <ext:Marker rdf:ID="_M1" xmlns:ext="http://example.com/local#">
        \\    <ext:Marker.note>Old</ext:Marker.note>
        \\  </ext:Marker>
        \\</rdf:RDF>
    ;
    const xml2 = RDF_OPEN ++ "\n</rdf:RDF>";
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.section_contains("reverseDifferences", "<ext:Marker rdf:about=\"#_M1\" xmlns:ext=\"http://example.com/local#\">"));
}

test "eqdiff - deterministic: same inputs produce byte-identical output" {
    const xml1 = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>South</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const a = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    const b = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(a.had_diffs);
    try std.testing.expectEqualStrings(a.output(), b.output());
}

// ── Added / removed objects ───────────────────────────────────────────────────

test "eqdiff - added object goes to forwardDifferences as a typed element" {
    const xml1 = RDF_OPEN ++ "\n</rdf:RDF>";
    const xml2 = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\    <cim:Substation.Region rdf:resource="#_R1"/>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.section_contains("forwardDifferences", "<cim:Substation rdf:about=\"#_SS1\">"));
    try std.testing.expect(r.section_contains("forwardDifferences", "<cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>"));
    try std.testing.expect(r.section_contains("forwardDifferences", "<cim:Substation.Region rdf:resource=\"#_R1\"/>"));
    try std.testing.expect(!r.section_contains("reverseDifferences", "_SS1"));
}

test "eqdiff - removed object goes to reverseDifferences" {
    const xml1 = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 = RDF_OPEN ++ "\n</rdf:RDF>";
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.section_contains("reverseDifferences", "<cim:Substation rdf:about=\"#_SS1\">"));
    try std.testing.expect(r.section_contains("reverseDifferences", "<cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>"));
    try std.testing.expect(!r.section_contains("forwardDifferences", "_SS1"));
}

test "eqdiff - added object with repeated child elements preserves all of them" {
    const xml1 = RDF_OPEN ++ "\n</rdf:RDF>";
    const xml2 = RDF_OPEN ++
        \\
        \\  <cim:OperationalLimitSet rdf:ID="_OLS1">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_T1"/>
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_T2"/>
        \\  </cim:OperationalLimitSet>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.section_contains("forwardDifferences", "rdf:resource=\"#_T1\""));
    try std.testing.expect(r.section_contains("forwardDifferences", "rdf:resource=\"#_T2\""));
}

// ── Changed objects ───────────────────────────────────────────────────────────

test "eqdiff - changed property: new value forward, old value reverse" {
    const xml1 = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\    <cim:IdentifiedObject.description>Main site</cim:IdentifiedObject.description>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>South</cim:IdentifiedObject.name>
        \\    <cim:IdentifiedObject.description>Main site</cim:IdentifiedObject.description>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.section_contains("forwardDifferences", "<rdf:Description rdf:about=\"#_SS1\">"));
    try std.testing.expect(r.section_contains("forwardDifferences", "<cim:IdentifiedObject.name>South</cim:IdentifiedObject.name>"));
    try std.testing.expect(r.section_contains("reverseDifferences", "<rdf:Description rdf:about=\"#_SS1\">"));
    try std.testing.expect(r.section_contains("reverseDifferences", "<cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>"));
    // Unchanged property must appear in neither section.
    try std.testing.expect(!r.contains("Main site"));
}

test "eqdiff - changed reference is copied verbatim per side" {
    const xml1 = RDF_OPEN ++
        \\
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:VoltageLevel.Substation rdf:resource="#_SS1"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ;
    const xml2 = RDF_OPEN ++
        \\
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:VoltageLevel.Substation rdf:resource="#_SS2"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.section_contains("forwardDifferences", "<cim:VoltageLevel.Substation rdf:resource=\"#_SS2\"/>"));
    try std.testing.expect(r.section_contains("reverseDifferences", "<cim:VoltageLevel.Substation rdf:resource=\"#_SS1\"/>"));
}

test "eqdiff - property added to existing object appears only forward" {
    const xml1 = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\    <cim:IdentifiedObject.description>New docs</cim:IdentifiedObject.description>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.section_contains("forwardDifferences", "New docs"));
    try std.testing.expect(!r.section_contains("reverseDifferences", "New docs"));
    // The unchanged name is not part of the delta.
    try std.testing.expect(!r.section_contains("forwardDifferences", "IdentifiedObject.name"));
}

test "eqdiff - whitespace-only XML difference yields no statements" {
    const xml1 = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    // Same data, different indentation and child order.
    const xml2 = RDF_OPEN ++
        \\
        \\    <cim:Substation rdf:ID="_SS1">
        \\        <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\    </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(!r.had_diffs);
    try std.testing.expect(!r.contains("rdf:Description"));
}

test "eqdiff - removing one of two repeated statements is detected" {
    const xml1 = RDF_OPEN ++
        \\
        \\  <cim:OperationalLimitSet rdf:ID="_OLS1">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_T1"/>
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_T2"/>
        \\  </cim:OperationalLimitSet>
        \\</rdf:RDF>
    ;
    const xml2 = RDF_OPEN ++
        \\
        \\  <cim:OperationalLimitSet rdf:ID="_OLS1">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_T2"/>
        \\  </cim:OperationalLimitSet>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.section_contains("reverseDifferences", "rdf:resource=\"#_T1\""));
    // T2 survives unchanged: it must appear in neither section.
    try std.testing.expect(!r.section_contains("reverseDifferences", "rdf:resource=\"#_T2\""));
    try std.testing.expect(!r.section_contains("forwardDifferences", "rdf:resource"));
}

test "eqdiff - adding a repeated statement emits only the new one" {
    const xml1 = RDF_OPEN ++
        \\
        \\  <cim:OperationalLimitSet rdf:ID="_OLS1">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_T1"/>
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_T2"/>
        \\  </cim:OperationalLimitSet>
        \\</rdf:RDF>
    ;
    const xml2 = RDF_OPEN ++
        \\
        \\  <cim:OperationalLimitSet rdf:ID="_OLS1">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_T1"/>
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_T2"/>
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_T3"/>
        \\  </cim:OperationalLimitSet>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.section_contains("forwardDifferences", "rdf:resource=\"#_T3\""));
    // T1 and T2 are unchanged — no reverse statements at all.
    try std.testing.expect(!r.section_contains("forwardDifferences", "rdf:resource=\"#_T2\""));
    try std.testing.expect(!r.section_contains("reverseDifferences", "rdf:resource"));
}

// ── Local xmlns declarations ──────────────────────────────────────────────────

const RDF_OPEN_NO_CIM =
    \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
;

test "eqdiff - added object keeps a locally declared xmlns" {
    const xml1 = RDF_OPEN_NO_CIM ++ "\n</rdf:RDF>";
    const xml2 = RDF_OPEN_NO_CIM ++
        \\
        \\  <cim:Substation rdf:ID="_SS1" xmlns:cim="http://iec.ch/TC57/CIM100#">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.section_contains(
        "forwardDifferences",
        "<cim:Substation rdf:about=\"#_SS1\" xmlns:cim=\"http://iec.ch/TC57/CIM100#\">",
    ));
}

test "eqdiff - changed object carries a locally declared xmlns on its description" {
    const xml1 = RDF_OPEN_NO_CIM ++
        \\
        \\  <cim:Substation rdf:ID="_SS1" xmlns:cim="http://iec.ch/TC57/CIM100#">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 = RDF_OPEN_NO_CIM ++
        \\
        \\  <cim:Substation rdf:ID="_SS1" xmlns:cim="http://iec.ch/TC57/CIM100#">
        \\    <cim:IdentifiedObject.name>South</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{});
    try std.testing.expect(r.section_contains(
        "forwardDifferences",
        "<rdf:Description rdf:about=\"#_SS1\" xmlns:cim=\"http://iec.ch/TC57/CIM100#\">",
    ));
}

// ── Type filter ───────────────────────────────────────────────────────────────

test "eqdiff - type filter restricts statements" {
    const xml1 = RDF_OPEN ++ "\n</rdf:RDF>";
    const xml2 = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:BaseVoltage rdf:ID="_BV1">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, xml1, xml2, .{ .type_filter = "BaseVoltage" });
    try std.testing.expect(r.had_diffs);
    try std.testing.expect(r.section_contains("forwardDifferences", "_BV1"));
    try std.testing.expect(!r.contains("_SS1"));
}

// ── FullModel handling ────────────────────────────────────────────────────────

const XML_WITH_FULLMODEL_V1 =
    \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#" xmlns:md="http://iec.ch/TC57/61970-552/ModelDescription/1#">
    \\  <md:FullModel rdf:about="urn:uuid:11111111-1111-1111-1111-111111111111">
    \\    <md:Model.profile>http://entsoe.eu/CIM/EquipmentCore/3/1</md:Model.profile>
    \\    <md:Model.version>1</md:Model.version>
    \\  </md:FullModel>
    \\  <cim:Substation rdf:ID="_SS1">
    \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
    \\  </cim:Substation>
    \\</rdf:RDF>
;

const XML_WITH_FULLMODEL_V2 =
    \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#" xmlns:md="http://iec.ch/TC57/61970-552/ModelDescription/1#">
    \\  <md:FullModel rdf:about="urn:uuid:22222222-2222-2222-2222-222222222222">
    \\    <md:Model.profile>http://entsoe.eu/CIM/EquipmentCore/3/1</md:Model.profile>
    \\    <md:Model.version>2</md:Model.version>
    \\  </md:FullModel>
    \\  <cim:Substation rdf:ID="_SS1">
    \\    <cim:IdentifiedObject.name>South</cim:IdentifiedObject.name>
    \\  </cim:Substation>
    \\</rdf:RDF>
;

test "eqdiff - FullModel feeds the header, not the statement sections" {
    const r = try run_eqdiff(std.testing.allocator, XML_WITH_FULLMODEL_V1, XML_WITH_FULLMODEL_V2, .{});
    try std.testing.expect(r.had_diffs);
    // Header copies model2's FullModel description and supersedes model1's.
    try std.testing.expect(r.contains("<md:Model.version>2</md:Model.version>"));
    try std.testing.expect(r.contains("<md:Model.Supersedes rdf:resource=\"urn:uuid:11111111-1111-1111-1111-111111111111\"/>"));
    // The FullModel delta (version 1 → 2) must not show up as statements.
    try std.testing.expect(!r.section_contains("forwardDifferences", "Model.version"));
    try std.testing.expect(!r.section_contains("reverseDifferences", "Model.version"));
    // The real change does.
    try std.testing.expect(r.section_contains("forwardDifferences", "South"));
    try std.testing.expect(r.section_contains("reverseDifferences", "North"));
}

test "eqdiff - FullModel-only update still counts as a difference" {
    // Same grid data as V1; only the FullModel metadata differs. No statements
    // are emitted, but the exit-code contract promises 0 only for identical
    // inputs — metadata-only model updates must not be hidden from automation.
    const xml2 =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#" xmlns:md="http://iec.ch/TC57/61970-552/ModelDescription/1#">
        \\  <md:FullModel rdf:about="urn:uuid:22222222-2222-2222-2222-222222222222">
        \\    <md:Model.profile>http://entsoe.eu/CIM/EquipmentCore/3/1</md:Model.profile>
        \\    <md:Model.version>2</md:Model.version>
        \\  </md:FullModel>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff(std.testing.allocator, XML_WITH_FULLMODEL_V1, xml2, .{});
    try std.testing.expect(r.had_diffs);
    // Still no statements: the FullModel delta lives in the header only.
    try std.testing.expect(!r.contains("rdf:Description"));
    try std.testing.expect(!r.section_contains("forwardDifferences", "<md:"));
    try std.testing.expect(!r.section_contains("reverseDifferences", "<md:"));
    try std.testing.expect(!r.section_contains("forwardDifferences", "<cim:"));
    try std.testing.expect(!r.section_contains("reverseDifferences", "<cim:"));
}

test "eqdiff - identical models with identical FullModel report no diff" {
    const r = try run_eqdiff(std.testing.allocator, XML_WITH_FULLMODEL_V1, XML_WITH_FULLMODEL_V1, .{});
    try std.testing.expect(!r.had_diffs);
}

// ── Single-object mode ────────────────────────────────────────────────────────

fn run_eqdiff_single(
    gpa: std.mem.Allocator,
    xml1: []const u8,
    xml2: []const u8,
    mrid: []const u8,
    options: eqdiff.Options,
) !struct { status: @import("diff.zig").SingleDiffStatus, result: EqdiffResult } {
    var model1 = try EQ.init(gpa, try gpa.dupe(u8, xml1));
    defer model1.deinit(gpa);
    var model2 = try EQ.init(gpa, try gpa.dupe(u8, xml2));
    defer model2.deinit(gpa);

    var result = EqdiffResult{ .had_diffs = false, .buf = undefined, .len = 0 };
    var writer: std.Io.Writer = .fixed(&result.buf);
    const status = try eqdiff.write_single(gpa, &model1, &model2, mrid, options, &writer);
    result.len = writer.end;
    if (status == .diff) result.had_diffs = status.diff;
    return .{ .status = status, .result = result };
}

test "eqdiff single - changed object emits only that object" {
    const xml1 = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:BaseVoltage rdf:ID="_BV1">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    ;
    const xml2 = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>South</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:BaseVoltage rdf:ID="_BV1">
        \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    ;
    const r = try run_eqdiff_single(std.testing.allocator, xml1, xml2, "_SS1", .{});
    try std.testing.expect(r.status.diff);
    try std.testing.expect(r.result.section_contains("forwardDifferences", "South"));
    try std.testing.expect(r.result.section_contains("reverseDifferences", "North"));
    try std.testing.expect(!r.result.contains("_BV1"));
}

test "eqdiff single - missing mrid returns not_found, identical returns no diff" {
    const xml = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const missing = try run_eqdiff_single(std.testing.allocator, xml, xml, "_NOPE", .{});
    try std.testing.expect(missing.status == .not_found);

    const same = try run_eqdiff_single(std.testing.allocator, xml, xml, "_SS1", .{});
    try std.testing.expect(!same.status.diff);
    try std.testing.expect(same.result.contains("<dm:DifferenceModel"));
}

test "eqdiff single - type change with same mrid emits typed remove+add" {
    const xml1 = RDF_OPEN ++
        \\
        \\  <cim:Breaker rdf:ID="_SW1">
        \\    <cim:IdentifiedObject.name>Bay switch</cim:IdentifiedObject.name>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    ;
    const xml2 = RDF_OPEN ++
        \\
        \\  <cim:Disconnector rdf:ID="_SW1">
        \\    <cim:IdentifiedObject.name>Bay switch</cim:IdentifiedObject.name>
        \\  </cim:Disconnector>
        \\</rdf:RDF>
    ;
    // Identical children, only the CIM type differs — must still be a diff,
    // expressed as a typed remove+add (a child-statement delta cannot retype).
    const r = try run_eqdiff_single(std.testing.allocator, xml1, xml2, "_SW1", .{});
    try std.testing.expect(r.status.diff);
    try std.testing.expect(r.result.section_contains("reverseDifferences", "<cim:Breaker rdf:about=\"#_SW1\">"));
    try std.testing.expect(r.result.section_contains("forwardDifferences", "<cim:Disconnector rdf:about=\"#_SW1\">"));
}

test "eqdiff single - conflicting prefix bindings are rejected" {
    const xml1 =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/2013/CIM-schema-cim16#">
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    const xml2 =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="http://iec.ch/TC57/CIM100#">
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>South</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    try std.testing.expectError(
        error.ConflictingNamespaceBindings,
        run_eqdiff_single(std.testing.allocator, xml1, xml2, "_SS1", .{}),
    );
}

test "eqdiff single - type filter mismatch reports actual type" {
    const gpa = std.testing.allocator;
    const xml = RDF_OPEN ++
        \\
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;
    // Models stay alive for the whole test: the type_mismatch payload is a
    // slice into the model XML (cf. run_diff_single in test_diff.zig).
    var model1 = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model1.deinit(gpa);
    var model2 = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model2.deinit(gpa);

    var buf: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const status = try eqdiff.write_single(gpa, &model1, &model2, "_SS1", .{ .type_filter = "BaseVoltage" }, &writer);
    try std.testing.expect(status == .type_mismatch);
    try std.testing.expectEqualStrings("Substation", status.type_mismatch);
}
