//! Grid-model rule tests over the fused engine, ported from the
//! pre-redesign suite: the same fixtures and intents, asserted against the
//! collected report. Focused tests request a single rule via
//! `validate_model_rules`, so a minimal fixture never trips unrelated rules;
//! a small set of integration tests at the bottom runs the full engine.

const std = @import("std");

const cim = @import("../cim/cim.zig");
const qocdc = @import("qocdc.zig");

const gpa = std.testing.allocator;

const Run = struct {
    model: cim.CimDocument,
    report: qocdc.Report,

    fn deinit(self: *Run) void {
        self.report.deinit(gpa);
        self.model.deinit(gpa);
    }
};

/// Parse `xml` and run exactly the rules in `mask`.
fn run_rules(xml: []const u8, mask: qocdc.RuleMask) !Run {
    var model = try cim.CimDocument.init(gpa, try gpa.dupe(u8, xml));
    errdefer model.deinit(gpa);
    var report: qocdc.Report = .empty;
    errdefer report.deinit(gpa);
    try qocdc.validate_model_rules(&report, gpa, &model, mask);
    return .{ .model = model, .report = report };
}

fn run_rule(xml: []const u8, rule: qocdc.Rule) !Run {
    return run_rules(xml, qocdc.RuleMask.initOne(rule));
}

/// The rule fired exactly `count` times and nothing else did.
fn expect_rule(run: *const Run, rule: qocdc.Rule, count: u32) !void {
    try std.testing.expectEqual(count, run.report.count(rule));
    try std.testing.expectEqual(@as(u64, count), run.report.total());
}

fn expect_clean(run: *const Run) !void {
    try std.testing.expectEqual(@as(u64, 0), run.report.total());
}

/// Some violation of `rule` names `object_id`.
fn expect_violation(run: *const Run, rule: qocdc.Rule, object_id: []const u8) !void {
    for (run.report.violations.items) |violation| {
        if (violation.rule == rule and std.mem.eql(u8, violation.object_id, object_id)) return;
    }
    return error.TestExpectedViolation;
}

// CGMES profile headers for version- and kind-gated rules.
const header_eq_v2 =
    \\  <md:FullModel rdf:about="urn:uuid:test-eq-v2">
    \\    <md:Model.profile>http://entsoe.eu/CIM/EquipmentCore/3/1</md:Model.profile>
    \\  </md:FullModel>
    \\
;
const header_eq_v3 =
    \\  <md:FullModel rdf:about="urn:uuid:test-eq-v3">
    \\    <md:Model.profile>http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0</md:Model.profile>
    \\  </md:FullModel>
    \\
;
const header_eqbd_v3 =
    \\  <md:FullModel rdf:about="urn:uuid:test-eqbd-v3">
    \\    <md:Model.profile>http://iec.ch/TC57/ns/CIM/EquipmentBoundary-EU/3.0</md:Model.profile>
    \\  </md:FullModel>
    \\
;

// ── NameLength ────────────────────────────────────────────────────────────

test "NameLength accepts named objects and nameless exemptions" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_s1">
        \\    <cim:IdentifiedObject.name>Sub One</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Terminal rdf:ID="_t1">
        \\  </cim:Terminal>
        \\  <cim:RatioTapChangerTablePoint rdf:ID="_pt1">
        \\  </cim:RatioTapChangerTablePoint>
        \\</rdf:RDF>
    , .NameLength);
    defer run.deinit();
    try expect_clean(&run);
}

test "NameLength rejects missing, empty, and overlong names" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_missing">
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_empty">
        \\    <cim:IdentifiedObject.name></cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_ok">
        \\    <cim:IdentifiedObject.name>fine</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    , .NameLength);
    defer run.deinit();
    try expect_rule(&run, .NameLength, 2);
    try expect_violation(&run, .NameLength, "_missing");
    try expect_violation(&run, .NameLength, "_empty");
}

test "NameLength rejects a name longer than 128 characters" {
    const long_name = "x" ** 129;
    var run = try run_rule(
        "<rdf:RDF><cim:Substation rdf:ID=\"_long\">" ++
            "<cim:IdentifiedObject.name>" ++ long_name ++ "</cim:IdentifiedObject.name>" ++
            "</cim:Substation></rdf:RDF>",
        .NameLength,
    );
    defer run.deinit();
    try expect_rule(&run, .NameLength, 1);
    try std.testing.expectEqualStrings(long_name, run.report.violations.items[0].detail);
}

// ── ShortNameLength / EICLength / DescriptionLength ───────────────────────

test "ShortNameLength accepts up to 12 characters and absence" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_s1">
        \\    <entsoe:IdentifiedObject.shortName>twelve_chars</entsoe:IdentifiedObject.shortName>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_s2">
        \\  </cim:Substation>
        \\</rdf:RDF>
    , .ShortNameLength);
    defer run.deinit();
    try expect_clean(&run);
}

test "ShortNameLength rejects a 13-character short name" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_s1">
        \\    <entsoe:IdentifiedObject.shortName>thirteen_char</entsoe:IdentifiedObject.shortName>
        \\  </cim:Substation>
        \\</rdf:RDF>
    , .ShortNameLength);
    defer run.deinit();
    try expect_rule(&run, .ShortNameLength, 1);
    try expect_violation(&run, .ShortNameLength, "_s1");
}

test "EICLength accepts exactly 16 characters and absence, rejects others" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_ok">
        \\    <entsoe:IdentifiedObject.energyIdentCodeEic>16CHARACTERCODE1</entsoe:IdentifiedObject.energyIdentCodeEic>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_absent">
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_short">
        \\    <entsoe:IdentifiedObject.energyIdentCodeEic>short</entsoe:IdentifiedObject.energyIdentCodeEic>
        \\  </cim:Substation>
        \\</rdf:RDF>
    , .EICLength);
    defer run.deinit();
    try expect_rule(&run, .EICLength, 1);
    try expect_violation(&run, .EICLength, "_short");
}

test "DescriptionLength rejects a description longer than 256 characters" {
    const long_description = "d" ** 257;
    var run = try run_rule(
        "<rdf:RDF><cim:Substation rdf:ID=\"_s1\">" ++
            "<cim:IdentifiedObject.description>" ++ long_description ++ "</cim:IdentifiedObject.description>" ++
            "</cim:Substation><cim:Substation rdf:ID=\"_s2\"></cim:Substation></rdf:RDF>",
        .DescriptionLength,
    );
    defer run.deinit();
    try expect_rule(&run, .DescriptionLength, 1);
    try expect_violation(&run, .DescriptionLength, "_s1");
}

// ── BoundaryPoint rules (EQBD gate) ───────────────────────────────────────

fn boundary_point_xml(comptime body: []const u8) []const u8 {
    return "<rdf:RDF>\n" ++ header_eqbd_v3 ++
        "  <entsoe:BoundaryPoint rdf:ID=\"_bp1\">\n" ++ body ++
        "  </entsoe:BoundaryPoint>\n</rdf:RDF>";
}

const complete_boundary_point_body =
    \\    <entsoe:BoundaryPoint.fromEndIsoCode>NL</entsoe:BoundaryPoint.fromEndIsoCode>
    \\    <entsoe:BoundaryPoint.toEndIsoCode>DE</entsoe:BoundaryPoint.toEndIsoCode>
    \\    <entsoe:BoundaryPoint.fromEndName>From End</entsoe:BoundaryPoint.fromEndName>
    \\    <entsoe:BoundaryPoint.toEndName>To End</entsoe:BoundaryPoint.toEndName>
    \\    <entsoe:BoundaryPoint.fromEndNameTso>TSO A</entsoe:BoundaryPoint.fromEndNameTso>
    \\    <entsoe:BoundaryPoint.toEndNameTso>TSO B</entsoe:BoundaryPoint.toEndNameTso>
    \\
;

test "BoundaryPoint rules accept a complete boundary point" {
    var mask = qocdc.RuleMask.initEmpty();
    mask.insert(.CNFromEndIsoCode);
    mask.insert(.CNToEndIsoCode);
    mask.insert(.CNFromEndNameLength);
    mask.insert(.CNToEndNameLength);
    mask.insert(.CNFromEndNameTsoLength);
    mask.insert(.CNToEndNameTsoLength);
    var run = try run_rules(boundary_point_xml(complete_boundary_point_body), mask);
    defer run.deinit();
    try expect_clean(&run);
}

test "CNFromEndIsoCode rejects an unknown country code and a missing one" {
    var bad = try run_rule(boundary_point_xml(
        \\    <entsoe:BoundaryPoint.fromEndIsoCode>XX</entsoe:BoundaryPoint.fromEndIsoCode>
        \\
    ), .CNFromEndIsoCode);
    defer bad.deinit();
    try expect_rule(&bad, .CNFromEndIsoCode, 1);

    var missing = try run_rule(boundary_point_xml(""), .CNFromEndIsoCode);
    defer missing.deinit();
    try expect_rule(&missing, .CNFromEndIsoCode, 1);
}

test "CNFromEndIsoCode accepts a lowercase country code" {
    // ReferenceStringSet comparisons are case-insensitive per QoCDC.
    var run = try run_rule(boundary_point_xml(
        \\    <entsoe:BoundaryPoint.fromEndIsoCode>nl</entsoe:BoundaryPoint.fromEndIsoCode>
        \\
    ), .CNFromEndIsoCode);
    defer run.deinit();
    try expect_clean(&run);
}

test "CNToEndNameLength rejects a missing and an overlong to-end name" {
    var missing = try run_rule(boundary_point_xml(""), .CNToEndNameLength);
    defer missing.deinit();
    try expect_rule(&missing, .CNToEndNameLength, 1);

    const long_name = "n" ** 129;
    var long = try run_rule(boundary_point_xml(
        "    <entsoe:BoundaryPoint.toEndName>" ++ long_name ++ "</entsoe:BoundaryPoint.toEndName>\n",
    ), .CNToEndNameLength);
    defer long.deinit();
    try expect_rule(&long, .CNToEndNameLength, 1);
}

test "BoundaryPoint rules are gated on the EQBD profile" {
    // The same incomplete BoundaryPoint inside an EQ document: no findings.
    var run = try run_rule(
        "<rdf:RDF>\n" ++ header_eq_v3 ++
            "  <entsoe:BoundaryPoint rdf:ID=\"_bp1\">\n  </entsoe:BoundaryPoint>\n</rdf:RDF>",
        .CNFromEndIsoCode,
    );
    defer run.deinit();
    try expect_clean(&run);
}

// ── NominalVoltage ────────────────────────────────────────────────────────

test "NominalVoltage accepts positive values, rejects zero, negative, missing, malformed" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_ok">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="_zero">
        \\    <cim:BaseVoltage.nominalVoltage>0</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="_negative">
        \\    <cim:BaseVoltage.nominalVoltage>-10</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="_missing">
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="_malformed">
        \\    <cim:BaseVoltage.nominalVoltage>abc</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    , .NominalVoltage);
    defer run.deinit();
    try expect_rule(&run, .NominalVoltage, 4);
    try expect_violation(&run, .NominalVoltage, "_zero");
    try expect_violation(&run, .NominalVoltage, "_negative");
    try expect_violation(&run, .NominalVoltage, "_missing");
    try expect_violation(&run, .NominalVoltage, "_malformed");
}

// ── LoadResponseCharacteristic rules ──────────────────────────────────────

fn lrc_exponent_xml(
    buffer: []u8,
    p_voltage_exponent: []const u8,
    q_voltage_exponent: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "<rdf:RDF><cim:LoadResponseCharacteristic rdf:ID=\"_LRC1\">" ++
            "<cim:LoadResponseCharacteristic.exponentModel>true</cim:LoadResponseCharacteristic.exponentModel>" ++
            "<cim:LoadResponseCharacteristic.pVoltageExponent>{s}</cim:LoadResponseCharacteristic.pVoltageExponent>" ++
            "<cim:LoadResponseCharacteristic.qVoltageExponent>{s}</cim:LoadResponseCharacteristic.qVoltageExponent>" ++
            "</cim:LoadResponseCharacteristic></rdf:RDF>",
        .{ p_voltage_exponent, q_voltage_exponent },
    );
}

test "LRCExponentModel accepts in-range exponents and ignores a false exponentModel" {
    var buffer: [1024]u8 = undefined;
    const in_range = [_][2][]const u8{
        .{ "0", "2" },
        .{ "0.5", "1.5" },
        .{ "2", "0" },
    };
    for (in_range) |pair| {
        var run = try run_rule(try lrc_exponent_xml(&buffer, pair[0], pair[1]), .LRCExponentModel);
        defer run.deinit();
        try expect_clean(&run);
    }

    // exponentModel false: the exponents are not validated.
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_LRC1">
        \\    <cim:LoadResponseCharacteristic.exponentModel>false</cim:LoadResponseCharacteristic.exponentModel>
        \\  </cim:LoadResponseCharacteristic>
        \\</rdf:RDF>
    , .LRCExponentModel);
    defer run.deinit();
    try expect_clean(&run);
}

test "LRCExponentModel rejects out-of-range, missing, and malformed exponents" {
    var buffer: [1024]u8 = undefined;
    const out_of_range = [_][2][]const u8{
        .{ "-0.1", "1" },
        .{ "1", "2.1" },
        .{ "abc", "1" },
    };
    for (out_of_range) |pair| {
        var run = try run_rule(try lrc_exponent_xml(&buffer, pair[0], pair[1]), .LRCExponentModel);
        defer run.deinit();
        try expect_rule(&run, .LRCExponentModel, 1);
    }

    // Missing exponents while exponentModel is true.
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:LoadResponseCharacteristic rdf:ID="_LRC1">
        \\    <cim:LoadResponseCharacteristic.exponentModel>true</cim:LoadResponseCharacteristic.exponentModel>
        \\  </cim:LoadResponseCharacteristic>
        \\</rdf:RDF>
    , .LRCExponentModel);
    defer run.deinit();
    try expect_rule(&run, .LRCExponentModel, 1);
}

fn lrc_coefficient_xml(buffer: []u8, coefficients: [6]?[]const u8) ![]const u8 {
    const names = [_][]const u8{
        "LoadResponseCharacteristic.pConstantImpedance",
        "LoadResponseCharacteristic.pConstantCurrent",
        "LoadResponseCharacteristic.pConstantPower",
        "LoadResponseCharacteristic.qConstantImpedance",
        "LoadResponseCharacteristic.qConstantCurrent",
        "LoadResponseCharacteristic.qConstantPower",
    };
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll(
        "<rdf:RDF><cim:LoadResponseCharacteristic rdf:ID=\"_LRC1\">" ++
            "<cim:LoadResponseCharacteristic.exponentModel>false</cim:LoadResponseCharacteristic.exponentModel>",
    );
    for (names, coefficients) |name, coefficient| {
        const value = coefficient orelse continue;
        try writer.print("<cim:{s}>{s}</cim:{s}>", .{ name, value, name });
    }
    try writer.writeAll("</cim:LoadResponseCharacteristic></rdf:RDF>");
    return writer.buffered();
}

test "LCRCoefficientModel requires all six coefficients when exponentModel is false" {
    var buffer: [2048]u8 = undefined;
    var complete = try run_rule(try lrc_coefficient_xml(&buffer, .{
        "0.2", "0.3", "0.5", "0.1", "0.4", "0.5",
    }), .LCRCoefficientModel);
    defer complete.deinit();
    try expect_clean(&complete);

    var missing = try run_rule(try lrc_coefficient_xml(&buffer, .{
        "0.2", "0.3", null, "0.1", "0.4", "0.5",
    }), .LCRCoefficientModel);
    defer missing.deinit();
    try expect_rule(&missing, .LCRCoefficientModel, 1);

    var blank = try run_rule(try lrc_coefficient_xml(&buffer, .{
        "0.2", "0.3", "  ", "0.1", "0.4", "0.5",
    }), .LCRCoefficientModel);
    defer blank.deinit();
    try expect_rule(&blank, .LCRCoefficientModel, 1);
}

test "LCRCoefficientParameters requires both sums to equal one" {
    var buffer: [2048]u8 = undefined;
    var exact = try run_rule(try lrc_coefficient_xml(&buffer, .{
        "0.2", "0.3", "0.5", "0.1", "0.4", "0.5",
    }), .LCRCoefficientParameters);
    defer exact.deinit();
    try expect_clean(&exact);

    // Within NUMERIC_TOLERANCE.
    var tolerant = try run_rule(try lrc_coefficient_xml(&buffer, .{
        "0.2", "0.3", "0.5002", "0.1", "0.4", "0.5",
    }), .LCRCoefficientParameters);
    defer tolerant.deinit();
    try expect_clean(&tolerant);

    var p_off = try run_rule(try lrc_coefficient_xml(&buffer, .{
        "0.2", "0.3", "0.6", "0.1", "0.4", "0.5",
    }), .LCRCoefficientParameters);
    defer p_off.deinit();
    try expect_rule(&p_off, .LCRCoefficientParameters, 1);

    var q_off = try run_rule(try lrc_coefficient_xml(&buffer, .{
        "0.2", "0.3", "0.5", "0.1", "0.4", "0.6",
    }), .LCRCoefficientParameters);
    defer q_off.deinit();
    try expect_rule(&q_off, .LCRCoefficientParameters, 1);
}

// ── EnergySourceVoltage ───────────────────────────────────────────────────

test "EnergySourceVoltage rejects any voltage attribute, whatever its syntax" {
    var clean = try run_rule(
        \\<rdf:RDF>
        \\  <cim:EnergySource rdf:ID="_es1">
        \\    <cim:EnergySource.activePower>10</cim:EnergySource.activePower>
        \\  </cim:EnergySource>
        \\</rdf:RDF>
    , .EnergySourceVoltage);
    defer clean.deinit();
    try expect_clean(&clean);

    var magnitude = try run_rule(
        \\<rdf:RDF>
        \\  <cim:EnergySource rdf:ID="_es1">
        \\    <cim:EnergySource.voltageMagnitude>400</cim:EnergySource.voltageMagnitude>
        \\  </cim:EnergySource>
        \\</rdf:RDF>
    , .EnergySourceVoltage);
    defer magnitude.deinit();
    try expect_rule(&magnitude, .EnergySourceVoltage, 1);

    // A self-closing declaration still counts as present.
    var self_closing = try run_rule(
        \\<rdf:RDF>
        \\  <cim:EnergySource rdf:ID="_es1">
        \\    <cim:EnergySource.voltageAngle/>
        \\  </cim:EnergySource>
        \\</rdf:RDF>
    , .EnergySourceVoltage);
    defer self_closing.deinit();
    try expect_rule(&self_closing, .EnergySourceVoltage, 1);
}

// ── SVCRatings ────────────────────────────────────────────────────────────

fn svc_xml(buffer: []u8, capacitive: []const u8, inductive: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "<rdf:RDF><cim:StaticVarCompensator rdf:ID=\"_svc1\">" ++
            "<cim:StaticVarCompensator.capacitiveRating>{s}</cim:StaticVarCompensator.capacitiveRating>" ++
            "<cim:StaticVarCompensator.inductiveRating>{s}</cim:StaticVarCompensator.inductiveRating>" ++
            "</cim:StaticVarCompensator></rdf:RDF>",
        .{ capacitive, inductive },
    );
}

test "SVCRatings accepts positive capacitive and negative inductive ratings" {
    var buffer: [1024]u8 = undefined;
    var run = try run_rule(try svc_xml(&buffer, "100", "-100"), .SVCRatings);
    defer run.deinit();
    try expect_clean(&run);
}

test "SVCRatings rejects blank, malformed, non-finite, and wrong-sign ratings" {
    var buffer: [1024]u8 = undefined;
    const invalid = [_][2][]const u8{
        .{ "0", "-100" }, // capacitive must be > 0
        .{ "-5", "-100" },
        .{ "100", "0" }, // inductive must be < 0
        .{ "100", "5" },
        .{ "abc", "-100" },
        .{ "100", "abc" },
        .{ " ", "-100" },
        .{ "inf", "-100" }, // non-finite
    };
    for (invalid) |pair| {
        var run = try run_rule(try svc_xml(&buffer, pair[0], pair[1]), .SVCRatings);
        defer run.deinit();
        try expect_rule(&run, .SVCRatings, 1);
    }

    var missing = try run_rule(
        \\<rdf:RDF>
        \\  <cim:StaticVarCompensator rdf:ID="_svc1">
        \\  </cim:StaticVarCompensator>
        \\</rdf:RDF>
    , .SVCRatings);
    defer missing.deinit();
    try expect_rule(&missing, .SVCRatings, 1);
}

// ── GeneratingUnitNominalP ────────────────────────────────────────────────

fn generating_unit_xml(buffer: []u8, nominal_p: ?[]const u8, rated_s: ?[]const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("<rdf:RDF><cim:HydroGeneratingUnit rdf:ID=\"_gu1\">");
    if (nominal_p) |value| {
        try writer.print("<cim:GeneratingUnit.nominalP>{s}</cim:GeneratingUnit.nominalP>", .{value});
    }
    if (rated_s) |value| {
        try writer.print("<cim:GeneratingUnit.ratedS>{s}</cim:GeneratingUnit.ratedS>", .{value});
    }
    try writer.writeAll("</cim:HydroGeneratingUnit></rdf:RDF>");
    return writer.buffered();
}

test "GeneratingUnitNominalP accepts nominalP within ratedS and absent attributes" {
    var buffer: [1024]u8 = undefined;
    const accept = [_][2]?[]const u8{
        .{ "100", "120" },
        .{ "100", "100" },
        .{ "100", null }, // no ratedS: nothing to compare
        .{ null, null }, // no nominalP: rule does not apply
    };
    for (accept) |pair| {
        var run = try run_rule(try generating_unit_xml(&buffer, pair[0], pair[1]), .GeneratingUnitNominalP);
        defer run.deinit();
        try expect_clean(&run);
    }
}

test "GeneratingUnitNominalP rejects non-positive, malformed, and exceeding values" {
    var buffer: [1024]u8 = undefined;
    const reject = [_][2]?[]const u8{
        .{ "0", "120" },
        .{ "-5", "120" },
        .{ "abc", "120" },
        .{ "130", "120" }, // nominalP > ratedS
        .{ "100", "abc" },
    };
    for (reject) |pair| {
        var run = try run_rule(try generating_unit_xml(&buffer, pair[0], pair[1]), .GeneratingUnitNominalP);
        defer run.deinit();
        try expect_rule(&run, .GeneratingUnitNominalP, 1);
    }
}

// ── SynchronousCondenser ─────────────────────────────────────────────────

test "SynchronousCondenser rejects a condenser associated with a GeneratingUnit" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:SynchronousMachine rdf:ID="_sm1">
        \\    <cim:SynchronousMachine.type rdf:resource="#SynchronousMachineKind.condenser"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_gu1"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:GeneratingUnit rdf:ID="_gu1"/>
        \\</rdf:RDF>
    , .SynchronousCondenser);
    defer run.deinit();
    try expect_rule(&run, .SynchronousCondenser, 1);
    try expect_violation(&run, .SynchronousCondenser, "_sm1");
}

test "SynchronousCondenser accepts an unassociated condenser and associated generators" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:SynchronousMachine rdf:ID="_condenser">
        \\    <cim:SynchronousMachine.type rdf:resource="http://iec.ch/TC57/CIM100#SynchronousMachineKind.condenser"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_generator">
        \\    <cim:SynchronousMachine.type rdf:resource="#SynchronousMachineKind.generator"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_gu1"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_dual">
        \\    <cim:SynchronousMachine.type rdf:resource="#SynchronousMachineKind.generatorOrCondenser"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_gu2"/>
        \\  </cim:SynchronousMachine>
        \\</rdf:RDF>
    , .SynchronousCondenser);
    defer run.deinit();
    try expect_clean(&run);
}

// ── MeasType ──────────────────────────────────────────────────────────────

fn measurement_type_xml(buffer: []u8, comptime header: []const u8, value: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "<rdf:RDF>\n" ++ header ++
            "  <cim:Analog rdf:ID=\"_m1\">\n" ++
            "    <cim:Measurement.measurementType>{s}</cim:Measurement.measurementType>\n" ++
            "  </cim:Analog>\n</rdf:RDF>",
        .{value},
    );
}

test "MeasType accepts the version's allowed types" {
    var buffer: [2048]u8 = undefined;
    var v2 = try run_rule(try measurement_type_xml(&buffer, header_eq_v2, "LineToLineVoltage"), .MeasType);
    defer v2.deinit();
    try expect_clean(&v2);

    var v3 = try run_rule(try measurement_type_xml(&buffer, header_eq_v3, "Voltage"), .MeasType);
    defer v3.deinit();
    try expect_clean(&v3);
}

test "MeasType rejects the other version's renamed type and unknown types" {
    var buffer: [2048]u8 = undefined;
    // LineToLineVoltage became Voltage in v3.0.
    var v3_old_name = try run_rule(try measurement_type_xml(&buffer, header_eq_v3, "LineToLineVoltage"), .MeasType);
    defer v3_old_name.deinit();
    try expect_rule(&v3_old_name, .MeasType, 1);

    var v2_new_name = try run_rule(try measurement_type_xml(&buffer, header_eq_v2, "Voltage"), .MeasType);
    defer v2_new_name.deinit();
    try expect_rule(&v2_new_name, .MeasType, 1);

    var unknown = try run_rule(try measurement_type_xml(&buffer, header_eq_v2, "Bogus"), .MeasType);
    defer unknown.deinit();
    try expect_rule(&unknown, .MeasType, 1);
}

test "MeasType treats an empty-literal measurementType as a violation, absence as none" {
    var empty = try run_rule(
        "<rdf:RDF>\n" ++ header_eq_v2 ++
            "  <cim:Analog rdf:ID=\"_m1\">\n" ++
            "    <cim:Measurement.measurementType/>\n" ++
            "  </cim:Analog>\n</rdf:RDF>",
        .MeasType,
    );
    defer empty.deinit();
    try expect_rule(&empty, .MeasType, 1);

    var absent = try run_rule(
        "<rdf:RDF>\n" ++ header_eq_v2 ++
            "  <cim:Analog rdf:ID=\"_m1\">\n  </cim:Analog>\n</rdf:RDF>",
        .MeasType,
    );
    defer absent.deinit();
    try expect_clean(&absent);
}

// ── MeasUnit ──────────────────────────────────────────────────────────────

fn measurement_unit_xml(
    buffer: []u8,
    comptime header: []const u8,
    comptime class: []const u8,
    unit: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "<rdf:RDF>\n" ++ header ++
            "  <cim:" ++ class ++ " rdf:ID=\"_m1\">\n" ++
            "    <cim:Measurement.unitSymbol rdf:resource=\"http://iec.ch/TC57/2013/CIM-schema-cim16#{s}\"/>\n" ++
            "  </cim:" ++ class ++ ">\n</rdf:RDF>",
        .{unit},
    );
}

test "MeasUnit accepts the version's allowed units per class" {
    var buffer: [2048]u8 = undefined;
    var v2 = try run_rule(try measurement_unit_xml(&buffer, header_eq_v2, "Analog", "UnitSymbol.deg"), .MeasUnit);
    defer v2.deinit();
    try expect_clean(&v2);

    var v3_analog = try run_rule(try measurement_unit_xml(&buffer, header_eq_v3, "Analog", "UnitSymbol.W"), .MeasUnit);
    defer v3_analog.deinit();
    try expect_clean(&v3_analog);

    var v3_accumulator = try run_rule(try measurement_unit_xml(&buffer, header_eq_v3, "Accumulator", "UnitSymbol.Wh"), .MeasUnit);
    defer v3_accumulator.deinit();
    try expect_clean(&v3_accumulator);

    var v3_discrete = try run_rule(try measurement_unit_xml(&buffer, header_eq_v3, "Discrete", "UnitSymbol.none"), .MeasUnit);
    defer v3_discrete.deinit();
    try expect_clean(&v3_discrete);
}

test "MeasUnit rejects units outside the version's class list" {
    var buffer: [2048]u8 = undefined;
    // none is a 2.4.15 unit but not an Analog v3.0 unit.
    var v3_none = try run_rule(try measurement_unit_xml(&buffer, header_eq_v3, "Analog", "UnitSymbol.none"), .MeasUnit);
    defer v3_none.deinit();
    try expect_rule(&v3_none, .MeasUnit, 1);

    // Wh is an Accumulator unit, not an Analog one.
    var v3_wrong_class = try run_rule(try measurement_unit_xml(&buffer, header_eq_v3, "Analog", "UnitSymbol.Wh"), .MeasUnit);
    defer v3_wrong_class.deinit();
    try expect_rule(&v3_wrong_class, .MeasUnit, 1);

    var v2_unknown = try run_rule(try measurement_unit_xml(&buffer, header_eq_v2, "Analog", "UnitSymbol.Wh"), .MeasUnit);
    defer v2_unknown.deinit();
    try expect_rule(&v2_unknown, .MeasUnit, 1);
}

test "MeasUnit treats a text-serialized unitSymbol as a violation, absence as none" {
    var text_form = try run_rule(
        "<rdf:RDF>\n" ++ header_eq_v2 ++
            "  <cim:Analog rdf:ID=\"_m1\">\n" ++
            "    <cim:Measurement.unitSymbol>UnitSymbol.W</cim:Measurement.unitSymbol>\n" ++
            "  </cim:Analog>\n</rdf:RDF>",
        .MeasUnit,
    );
    defer text_form.deinit();
    try expect_rule(&text_form, .MeasUnit, 1);

    var absent = try run_rule(
        "<rdf:RDF>\n" ++ header_eq_v2 ++
            "  <cim:Analog rdf:ID=\"_m1\">\n  </cim:Analog>\n</rdf:RDF>",
        .MeasUnit,
    );
    defer absent.deinit();
    try expect_clean(&absent);
}

// ── Header behavior ───────────────────────────────────────────────────────

test "TooManyProfileParts reports an unresolved header once, always-rules still run" {
    // No FullModel header at all, and a NameLength violation alongside.
    var mask = qocdc.RuleMask.initEmpty();
    mask.insert(.TooManyProfileParts);
    mask.insert(.NameLength);
    var run = try run_rules(
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_nameless">
        \\  </cim:Substation>
        \\</rdf:RDF>
    , mask);
    defer run.deinit();
    try std.testing.expectEqual(@as(u32, 1), run.report.count(.TooManyProfileParts));
    try std.testing.expectEqual(@as(u32, 1), run.report.count(.NameLength));
    try std.testing.expectEqual(@as(u64, 2), run.report.total());
    // The offsetless header finding precedes the placed one in emission order.
    try std.testing.expectEqual(qocdc.Rule.TooManyProfileParts, run.report.violations.items[0].rule);
}

test "an unresolved header disables gated rules but not version-lenient ones" {
    // BoundaryPoint rules (eqbd gate) stay off; MeasType runs with a null
    // version and accepts either version's value space.
    var mask = qocdc.RuleMask.initEmpty();
    mask.insert(.CNFromEndIsoCode);
    mask.insert(.MeasType);
    var run = try run_rules(
        \\<rdf:RDF>
        \\  <entsoe:BoundaryPoint rdf:ID="_bp1">
        \\  </entsoe:BoundaryPoint>
        \\  <cim:Analog rdf:ID="_m1">
        \\    <cim:Measurement.measurementType>LineToLineVoltage</cim:Measurement.measurementType>
        \\  </cim:Analog>
        \\  <cim:Analog rdf:ID="_m2">
        \\    <cim:Measurement.measurementType>Bogus</cim:Measurement.measurementType>
        \\  </cim:Analog>
        \\</rdf:RDF>
    , mask);
    defer run.deinit();
    try std.testing.expectEqual(@as(u32, 0), run.report.count(.CNFromEndIsoCode));
    try expect_violation(&run, .MeasType, "_m2");
    try std.testing.expectEqual(@as(u32, 1), run.report.count(.MeasType));
}

// ── Containment ───────────────────────────────────────────────────────────

test "GenerationContainment accepts a Substation container, rejects others and absence" {
    var ok = try run_rule(
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_sub1"></cim:Substation>
        \\  <cim:HydroGeneratingUnit rdf:ID="_gu1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_sub1"/>
        \\  </cim:HydroGeneratingUnit>
        \\</rdf:RDF>
    , .GenerationContainment);
    defer ok.deinit();
    try expect_clean(&ok);

    var wrong = try run_rule(
        \\<rdf:RDF>
        \\  <cim:VoltageLevel rdf:ID="_vl1"></cim:VoltageLevel>
        \\  <cim:HydroGeneratingUnit rdf:ID="_gu1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_vl1"/>
        \\  </cim:HydroGeneratingUnit>
        \\</rdf:RDF>
    , .GenerationContainment);
    defer wrong.deinit();
    try expect_rule(&wrong, .GenerationContainment, 1);
    try expect_violation(&wrong, .GenerationContainment, "_gu1");

    var missing = try run_rule(
        \\<rdf:RDF>
        \\  <cim:HydroGeneratingUnit rdf:ID="_gu1"></cim:HydroGeneratingUnit>
        \\</rdf:RDF>
    , .GenerationContainment);
    defer missing.deinit();
    try expect_rule(&missing, .GenerationContainment, 1);
}

test "containment rejects a dangling container reference" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:PowerTransformer rdf:ID="_pt1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_nowhere"/>
        \\  </cim:PowerTransformer>
        \\</rdf:RDF>
    , .PTContainment);
    defer run.deinit();
    try expect_rule(&run, .PTContainment, 1);
}

test "SwitchContainment accepts VoltageLevel, Bay, and DCConverterUnit for subclasses" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:VoltageLevel rdf:ID="_vl1"></cim:VoltageLevel>
        \\  <cim:Bay rdf:ID="_bay1"></cim:Bay>
        \\  <cim:DCConverterUnit rdf:ID="_dcu1"></cim:DCConverterUnit>
        \\  <cim:Breaker rdf:ID="_sw1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_vl1"/>
        \\  </cim:Breaker>
        \\  <cim:Disconnector rdf:ID="_sw2">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_bay1"/>
        \\  </cim:Disconnector>
        \\  <cim:Breaker rdf:ID="_sw3">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_dcu1"/>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    , .SwitchContainment);
    defer run.deinit();
    try expect_clean(&run);
}

test "SCContainment tolerates an absent container but not a wrong one" {
    var absent = try run_rule(
        \\<rdf:RDF>
        \\  <cim:SeriesCompensator rdf:ID="_sc1"></cim:SeriesCompensator>
        \\</rdf:RDF>
    , .SCContainment);
    defer absent.deinit();
    try expect_clean(&absent);

    var wrong = try run_rule(
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_sub1"></cim:Substation>
        \\  <cim:SeriesCompensator rdf:ID="_sc1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_sub1"/>
        \\  </cim:SeriesCompensator>
        \\</rdf:RDF>
    , .SCContainment);
    defer wrong.deinit();
    try expect_rule(&wrong, .SCContainment, 1);
}

test "InjectionContainment requires a VoltageLevel for every listed type" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:VoltageLevel rdf:ID="_vl1"></cim:VoltageLevel>
        \\  <cim:EnergyConsumer rdf:ID="_ok">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_vl1"/>
        \\  </cim:EnergyConsumer>
        \\  <cim:SynchronousMachine rdf:ID="_no_container">
        \\  </cim:SynchronousMachine>
        \\  <cim:StaticVarCompensator rdf:ID="_no_container2">
        \\  </cim:StaticVarCompensator>
        \\</rdf:RDF>
    , .InjectionContainment);
    defer run.deinit();
    try expect_rule(&run, .InjectionContainment, 2);
    try expect_violation(&run, .InjectionContainment, "_no_container");
    try expect_violation(&run, .InjectionContainment, "_no_container2");
}

test "DCEQContainment covers the DC equipment list" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:DCConverterUnit rdf:ID="_dcu1"></cim:DCConverterUnit>
        \\  <cim:DCBreaker rdf:ID="_ok">
        \\    <cim:DCEquipment.EquipmentContainer rdf:resource="#_dcu1"/>
        \\  </cim:DCBreaker>
        \\</rdf:RDF>
    , .DCEQContainment);
    defer run.deinit();
    // The reference uses the wrong name (DCEquipment. instead of Equipment.),
    // so the required Equipment.EquipmentContainer is absent: a violation.
    try expect_rule(&run, .DCEQContainment, 1);
}

test "ACDCConvContainment requires a DCConverterUnit" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:DCConverterUnit rdf:ID="_dcu1"></cim:DCConverterUnit>
        \\  <cim:VsConverter rdf:ID="_ok">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_dcu1"/>
        \\  </cim:VsConverter>
        \\  <cim:CsConverter rdf:ID="_missing"></cim:CsConverter>
        \\</rdf:RDF>
    , .ACDCConvContainment);
    defer run.deinit();
    try expect_rule(&run, .ACDCConvContainment, 1);
    try expect_violation(&run, .ACDCConvContainment, "_missing");
}

test "CNContainment allows VoltageLevel, Bay, Line in EQ but only Line in EQBD" {
    const body =
        \\  <cim:VoltageLevel rdf:ID="_vl1"></cim:VoltageLevel>
        \\  <cim:Line rdf:ID="_line1"></cim:Line>
        \\  <cim:ConnectivityNode rdf:ID="_cn_vl">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_vl1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ConnectivityNode rdf:ID="_cn_line">
        \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_line1"/>
        \\  </cim:ConnectivityNode>
        \\
    ;
    var eq = try run_rule("<rdf:RDF>\n" ++ header_eq_v3 ++ body ++ "</rdf:RDF>", .CNContainment);
    defer eq.deinit();
    try expect_clean(&eq);

    var eqbd = try run_rule("<rdf:RDF>\n" ++ header_eqbd_v3 ++ body ++ "</rdf:RDF>", .CNContainment);
    defer eqbd.deinit();
    // The VoltageLevel-contained node violates under EQBD; the Line one is fine.
    try expect_rule(&eqbd, .CNContainment, 1);
    try expect_violation(&eqbd, .CNContainment, "_cn_vl");
}

test "CNContainment does not apply to SSH parts" {
    var run = try run_rule(
        "<rdf:RDF>\n" ++
            "  <md:FullModel rdf:about=\"urn:uuid:test-ssh\">\n" ++
            "    <md:Model.profile>http://iec.ch/TC57/ns/CIM/SteadyStateHypothesis-EU/3.0</md:Model.profile>\n" ++
            "  </md:FullModel>\n" ++
            "  <cim:ConnectivityNode rdf:ID=\"_cn1\"></cim:ConnectivityNode>\n" ++
            "</rdf:RDF>",
        .CNContainment,
    );
    defer run.deinit();
    try expect_clean(&run);
}

// ── CNRequiredInEQOperations ──────────────────────────────────────────────

const header_eq_v2_operation =
    \\  <md:FullModel rdf:about="urn:uuid:test-eq-v2-op">
    \\    <md:Model.profile>http://entsoe.eu/CIM/EquipmentCore/3/1</md:Model.profile>
    \\    <md:Model.profile>http://entsoe.eu/CIM/EquipmentOperation/3/1</md:Model.profile>
    \\  </md:FullModel>
    \\
;

const terminal_without_cn =
    \\  <cim:Terminal rdf:ID="_t1">
    \\  </cim:Terminal>
    \\
;

test "CNRequiredInEQOperations fires for v2 operation and v3 equipment models" {
    var v2_op = try run_rule(
        "<rdf:RDF>\n" ++ header_eq_v2_operation ++ terminal_without_cn ++ "</rdf:RDF>",
        .CNRequiredInEQOperations,
    );
    defer v2_op.deinit();
    try expect_rule(&v2_op, .CNRequiredInEQOperations, 1);

    var v3_eq = try run_rule(
        "<rdf:RDF>\n" ++ header_eq_v3 ++ terminal_without_cn ++ "</rdf:RDF>",
        .CNRequiredInEQOperations,
    );
    defer v3_eq.deinit();
    try expect_rule(&v3_eq, .CNRequiredInEQOperations, 1);
}

test "CNRequiredInEQOperations skips non-operation v2 and non-equipment v3 profiles" {
    var v2_core = try run_rule(
        "<rdf:RDF>\n" ++ header_eq_v2 ++ terminal_without_cn ++ "</rdf:RDF>",
        .CNRequiredInEQOperations,
    );
    defer v2_core.deinit();
    try expect_clean(&v2_core);

    var v3_eqbd = try run_rule(
        "<rdf:RDF>\n" ++ header_eqbd_v3 ++ terminal_without_cn ++ "</rdf:RDF>",
        .CNRequiredInEQOperations,
    );
    defer v3_eqbd.deinit();
    try expect_clean(&v3_eqbd);
}

test "CNRequiredInEQOperations accepts a Terminal with a ConnectivityNode" {
    var run = try run_rule(
        "<rdf:RDF>\n" ++ header_eq_v3 ++
            "  <cim:ConnectivityNode rdf:ID=\"_cn1\"></cim:ConnectivityNode>\n" ++
            "  <cim:Terminal rdf:ID=\"_t1\">\n" ++
            "    <cim:Terminal.ConnectivityNode rdf:resource=\"#_cn1\"/>\n" ++
            "  </cim:Terminal>\n" ++
            "</rdf:RDF>",
        .CNRequiredInEQOperations,
    );
    defer run.deinit();
    try expect_clean(&run);
}

// ── TerminalCount1 / TerminalCount2 ───────────────────────────────────────

/// Comptime fixture assembly: the comptime parameter forces the argument
/// expression -- including calls to the builders below -- to fold at comptime.
fn rdf(comptime body: []const u8) []const u8 {
    return "<rdf:RDF>\n" ++ body ++ "</rdf:RDF>";
}

fn terminal(comptime id: []const u8, comptime equipment: []const u8) []const u8 {
    return "  <cim:Terminal rdf:ID=\"" ++ id ++ "\">\n" ++
        "    <cim:Terminal.ConductingEquipment rdf:resource=\"#" ++ equipment ++ "\"/>\n" ++
        "  </cim:Terminal>\n";
}

fn numbered_terminal(comptime id: []const u8, comptime equipment: []const u8, comptime seq: []const u8) []const u8 {
    return "  <cim:Terminal rdf:ID=\"" ++ id ++ "\">\n" ++
        "    <cim:Terminal.ConductingEquipment rdf:resource=\"#" ++ equipment ++ "\"/>\n" ++
        "    <cim:ACDCTerminal.sequenceNumber>" ++ seq ++ "</cim:ACDCTerminal.sequenceNumber>\n" ++
        "  </cim:Terminal>\n";
}

test "TerminalCount1 requires exactly one terminal" {
    var ok = try run_rule(rdf(
        "  <cim:EnergyConsumer rdf:ID=\"_ec1\"></cim:EnergyConsumer>\n" ++
        terminal("_t1", "_ec1")
        ), .TerminalCount1);
    defer ok.deinit();
    try expect_clean(&ok);

    var zero = try run_rule(rdf(
        "  <cim:EnergyConsumer rdf:ID=\"_ec1\"></cim:EnergyConsumer>\n"
        ), .TerminalCount1);
    defer zero.deinit();
    try expect_rule(&zero, .TerminalCount1, 1);
    try expect_violation(&zero, .TerminalCount1, "_ec1");

    var two = try run_rule(rdf(
        "  <cim:EnergySource rdf:ID=\"_es1\"></cim:EnergySource>\n" ++
        terminal("_t1", "_es1") ++
        terminal("_t2", "_es1")
        ), .TerminalCount1);
    defer two.deinit();
    try expect_rule(&two, .TerminalCount1, 1);
}

test "TerminalCount1 covers subclasses and the strict-subclass Connector case" {
    // SynchronousMachine is_a RegulatingCondEq; BusbarSection is a strict
    // subclass of Connector.
    var run = try run_rule(rdf(
        "  <cim:SynchronousMachine rdf:ID=\"_sm1\"></cim:SynchronousMachine>\n" ++
        "  <cim:BusbarSection rdf:ID=\"_bb1\"></cim:BusbarSection>\n"
        ), .TerminalCount1);
    defer run.deinit();
    try expect_rule(&run, .TerminalCount1, 2);
}

test "TerminalCount2 requires exactly two terminals" {
    var ok = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        terminal("_t1", "_line1") ++
        terminal("_t2", "_line1")
        ), .TerminalCount2);
    defer ok.deinit();
    try expect_clean(&ok);

    var one = try run_rule(rdf(
        "  <cim:Breaker rdf:ID=\"_sw1\"></cim:Breaker>\n" ++
        terminal("_t1", "_sw1")
        ), .TerminalCount2);
    defer one.deinit();
    try expect_rule(&one, .TerminalCount2, 1);
    try expect_violation(&one, .TerminalCount2, "_sw1");

    var three = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        terminal("_t1", "_line1") ++
        terminal("_t2", "_line1") ++
        terminal("_t3", "_line1")
        ), .TerminalCount2);
    defer three.deinit();
    try expect_rule(&three, .TerminalCount2, 1);
}

test "terminal counting ignores non-Terminal referrers and DC associations" {
    // A DCTerminal via the DC association does not count toward the
    // exact-Terminal cardinality rules.
    var run = try run_rule(rdf(
        "  <cim:EnergyConsumer rdf:ID=\"_ec1\"></cim:EnergyConsumer>\n" ++
        terminal("_t1", "_ec1") ++
        "  <cim:DCTerminal rdf:ID=\"_dct1\">\n" ++
        "    <cim:DCTerminal.DCConductingEquipment rdf:resource=\"#_ec1\"/>\n" ++
        "  </cim:DCTerminal>\n"
        ), .TerminalCount1);
    defer run.deinit();
    try expect_clean(&run);
}

// ── TerminalSeqNum / TerminalSeqNumOrder ──────────────────────────────────

test "TerminalSeqNum requires sequence numbers on EquivalentBranch terminals" {
    var ok = try run_rule(rdf(
        "  <cim:EquivalentBranch rdf:ID=\"_eb1\"></cim:EquivalentBranch>\n" ++
        numbered_terminal("_t1", "_eb1", "1") ++
        numbered_terminal("_t2", "_eb1", "2")
        ), .TerminalSeqNum);
    defer ok.deinit();
    try expect_clean(&ok);

    var missing = try run_rule(rdf(
        "  <cim:EquivalentBranch rdf:ID=\"_eb1\"></cim:EquivalentBranch>\n" ++
        numbered_terminal("_t1", "_eb1", "1") ++
        terminal("_t2", "_eb1")
        ), .TerminalSeqNum);
    defer missing.deinit();
    try expect_rule(&missing, .TerminalSeqNum, 1);
    try expect_violation(&missing, .TerminalSeqNum, "_t2");
}

const mutual_coupling_fixture =
    "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
    "  <cim:ACLineSegment rdf:ID=\"_line2\"></cim:ACLineSegment>\n" ++
    numbered_terminal("_t1a", "_line1", "1") ++
    numbered_terminal("_t2a", "_line2", "1") ++
    "  <cim:MutualCoupling rdf:ID=\"_mc1\">\n" ++
    "    <cim:MutualCoupling.First_Terminal rdf:resource=\"#_t1a\"/>\n" ++
    "    <cim:MutualCoupling.Second_Terminal rdf:resource=\"#_t2a\"/>\n" ++
    "  </cim:MutualCoupling>\n";

test "TerminalSeqNum requires sequence numbers only on coupled ACLineSegments" {
    // _line3 is uncoupled: its unnumbered terminal is fine. _line1 is
    // coupled: its unnumbered second terminal violates.
    var run = try run_rule(rdf(
        mutual_coupling_fixture ++
        terminal("_t1b", "_line1") ++
        "  <cim:ACLineSegment rdf:ID=\"_line3\"></cim:ACLineSegment>\n" ++
        terminal("_t3a", "_line3")
        ), .TerminalSeqNum);
    defer run.deinit();
    try expect_rule(&run, .TerminalSeqNum, 1);
    try expect_violation(&run, .TerminalSeqNum, "_t1b");
}

test "a MutualCoupling with one bad end still couples the resolvable end's line" {
    // The Second_Terminal dangles, so MCFirstSecond would fire -- but
    // _line1 is still coupled through the resolvable First_Terminal, and its
    // unnumbered terminal still violates TerminalSeqNum. MCFirstSecond is
    // NOT requested: its violation must not leak into this run.
    var run = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        numbered_terminal("_t1a", "_line1", "1") ++
        terminal("_t1b", "_line1") ++
        "  <cim:MutualCoupling rdf:ID=\"_mc1\">\n" ++
        "    <cim:MutualCoupling.First_Terminal rdf:resource=\"#_t1a\"/>\n" ++
        "    <cim:MutualCoupling.Second_Terminal rdf:resource=\"#_nowhere\"/>\n" ++
        "  </cim:MutualCoupling>\n"
        ), .TerminalSeqNum);
    defer run.deinit();
    try expect_rule(&run, .TerminalSeqNum, 1);
    try expect_violation(&run, .TerminalSeqNum, "_t1b");
}

test "TerminalSeqNumOrder accepts contiguous 1..k and tolerates absence" {
    var ok = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        numbered_terminal("_t1", "_line1", "2") ++
        numbered_terminal("_t2", "_line1", "1")
        ), .TerminalSeqNumOrder);
    defer ok.deinit();
    try expect_clean(&ok);

    // Unnumbered terminals are skipped, not violations.
    var unnumbered = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        terminal("_t1", "_line1") ++
        terminal("_t2", "_line1")
        ), .TerminalSeqNumOrder);
    defer unnumbered.deinit();
    try expect_clean(&unnumbered);
}

test "TerminalSeqNumOrder rejects gaps, missing 1, duplicates, and unparseable numbers" {
    var gap = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        numbered_terminal("_t1", "_line1", "1") ++
        numbered_terminal("_t2", "_line1", "3")
        ), .TerminalSeqNumOrder);
    defer gap.deinit();
    try expect_rule(&gap, .TerminalSeqNumOrder, 1);
    try expect_violation(&gap, .TerminalSeqNumOrder, "_line1");

    var no_one = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        numbered_terminal("_t1", "_line1", "2")
        ), .TerminalSeqNumOrder);
    defer no_one.deinit();
    try expect_rule(&no_one, .TerminalSeqNumOrder, 1);

    var duplicate = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        numbered_terminal("_t1", "_line1", "1") ++
        numbered_terminal("_t2", "_line1", "1")
        ), .TerminalSeqNumOrder);
    defer duplicate.deinit();
    try expect_rule(&duplicate, .TerminalSeqNumOrder, 1);

    var unparseable = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        numbered_terminal("_t1", "_line1", "abc")
        ), .TerminalSeqNumOrder);
    defer unparseable.deinit();
    try expect_rule(&unparseable, .TerminalSeqNumOrder, 1);
    try expect_violation(&unparseable, .TerminalSeqNumOrder, "_t1");
}

test "TerminalSeqNumOrder has no arbitrary terminal-count limit" {
    // Ten numbered terminals on one equipment, contiguous 1..10.
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(gpa);
    try xml.appendSlice(gpa, "<rdf:RDF>\n  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n");
    for (1..11) |i| {
        var writer = std.Io.Writer.Allocating.fromArrayList(gpa, &xml);
        defer xml = writer.toArrayList();
        try writer.writer.print(
            "  <cim:Terminal rdf:ID=\"_t{d}\">\n" ++
                "    <cim:Terminal.ConductingEquipment rdf:resource=\"#_line1\"/>\n" ++
                "    <cim:ACDCTerminal.sequenceNumber>{d}</cim:ACDCTerminal.sequenceNumber>\n" ++
                "  </cim:Terminal>\n",
            .{ i, i },
        );
    }
    try xml.appendSlice(gpa, "</rdf:RDF>");
    var run = try run_rule(xml.items, .TerminalSeqNumOrder);
    defer run.deinit();
    try expect_clean(&run);
}

// ── PTTerminalConsistency ─────────────────────────────────────────────────

test "PTTerminalConsistency accepts a consistent end and rejects mismatches" {
    var ok = try run_rule(rdf(
        "  <cim:PowerTransformer rdf:ID=\"_pt1\"></cim:PowerTransformer>\n" ++
        terminal("_t1", "_pt1") ++
        "  <cim:PowerTransformerEnd rdf:ID=\"_end1\">\n" ++
        "    <cim:TransformerEnd.Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:PowerTransformerEnd.PowerTransformer rdf:resource=\"#_pt1\"/>\n" ++
        "  </cim:PowerTransformerEnd>\n"
        ), .PTTerminalConsistency);
    defer ok.deinit();
    try expect_clean(&ok);

    // The terminal belongs to a different transformer.
    var mismatch = try run_rule(rdf(
        "  <cim:PowerTransformer rdf:ID=\"_pt1\"></cim:PowerTransformer>\n" ++
        "  <cim:PowerTransformer rdf:ID=\"_pt2\"></cim:PowerTransformer>\n" ++
        terminal("_t1", "_pt2") ++
        "  <cim:PowerTransformerEnd rdf:ID=\"_end1\">\n" ++
        "    <cim:TransformerEnd.Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:PowerTransformerEnd.PowerTransformer rdf:resource=\"#_pt1\"/>\n" ++
        "  </cim:PowerTransformerEnd>\n"
        ), .PTTerminalConsistency);
    defer mismatch.deinit();
    try expect_rule(&mismatch, .PTTerminalConsistency, 1);
    try expect_violation(&mismatch, .PTTerminalConsistency, "_end1");
}

test "PTTerminalConsistency rejects missing and dangling references" {
    var missing = try run_rule(
        \\<rdf:RDF>
        \\  <cim:PowerTransformerEnd rdf:ID="_end1">
        \\  </cim:PowerTransformerEnd>
        \\</rdf:RDF>
    , .PTTerminalConsistency);
    defer missing.deinit();
    try expect_rule(&missing, .PTTerminalConsistency, 1);

    var dangling = try run_rule(rdf(
        "  <cim:PowerTransformer rdf:ID=\"_pt1\"></cim:PowerTransformer>\n" ++
        "  <cim:PowerTransformerEnd rdf:ID=\"_end1\">\n" ++
        "    <cim:TransformerEnd.Terminal rdf:resource=\"#_nowhere\"/>\n" ++
        "    <cim:PowerTransformerEnd.PowerTransformer rdf:resource=\"#_pt1\"/>\n" ++
        "  </cim:PowerTransformerEnd>\n"
        ), .PTTerminalConsistency);
    defer dangling.deinit();
    try expect_rule(&dangling, .PTTerminalConsistency, 1);
}

test "PTTerminalConsistency rejects an equipment that is not a PowerTransformer" {
    var run = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        terminal("_t1", "_line1") ++
        "  <cim:PowerTransformerEnd rdf:ID=\"_end1\">\n" ++
        "    <cim:TransformerEnd.Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:PowerTransformerEnd.PowerTransformer rdf:resource=\"#_line1\"/>\n" ++
        "  </cim:PowerTransformerEnd>\n"
        ), .PTTerminalConsistency);
    defer run.deinit();
    try expect_rule(&run, .PTTerminalConsistency, 1);
}

// ── MCFirstSecond ─────────────────────────────────────────────────────────

test "MCFirstSecond accepts terminals of two different ACLineSegments" {
    var run = try run_rule(rdf(mutual_coupling_fixture), .MCFirstSecond);
    defer run.deinit();
    try expect_clean(&run);
}

test "MCFirstSecond rejects same-line ends, non-line equipment, and bad references" {
    var same_line = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        terminal("_t1", "_line1") ++
        terminal("_t2", "_line1") ++
        "  <cim:MutualCoupling rdf:ID=\"_mc1\">\n" ++
        "    <cim:MutualCoupling.First_Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:MutualCoupling.Second_Terminal rdf:resource=\"#_t2\"/>\n" ++
        "  </cim:MutualCoupling>\n"
        ), .MCFirstSecond);
    defer same_line.deinit();
    try expect_rule(&same_line, .MCFirstSecond, 1);
    try expect_violation(&same_line, .MCFirstSecond, "_mc1");

    // The second terminal's equipment is a Breaker, not an ACLineSegment.
    var not_line = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        "  <cim:Breaker rdf:ID=\"_sw1\"></cim:Breaker>\n" ++
        terminal("_t1", "_line1") ++
        terminal("_t2", "_sw1") ++
        "  <cim:MutualCoupling rdf:ID=\"_mc1\">\n" ++
        "    <cim:MutualCoupling.First_Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:MutualCoupling.Second_Terminal rdf:resource=\"#_t2\"/>\n" ++
        "  </cim:MutualCoupling>\n"
        ), .MCFirstSecond);
    defer not_line.deinit();
    try expect_rule(&not_line, .MCFirstSecond, 1);

    var missing_ref = try run_rule(rdf(
        "  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        terminal("_t1", "_line1") ++
        "  <cim:MutualCoupling rdf:ID=\"_mc1\">\n" ++
        "    <cim:MutualCoupling.First_Terminal rdf:resource=\"#_t1\"/>\n" ++
        "  </cim:MutualCoupling>\n"
        ), .MCFirstSecond);
    defer missing_ref.deinit();
    try expect_rule(&missing_ref, .MCFirstSecond, 1);
}

// ── MeasTerminal ──────────────────────────────────────────────────────────

test "MeasTerminal accepts a terminal of the referenced equipment" {
    var run = try run_rule(rdf(
        "  <cim:Breaker rdf:ID=\"_sw1\"></cim:Breaker>\n" ++
        terminal("_t1", "_sw1") ++
        "  <cim:Analog rdf:ID=\"_m1\">\n" ++
        "    <cim:Measurement.Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:Measurement.PowerSystemResource rdf:resource=\"#_sw1\"/>\n" ++
        "  </cim:Analog>\n"
        ), .MeasTerminal);
    defer run.deinit();
    try expect_clean(&run);
}

test "MeasTerminal rejects a terminal of a different equipment" {
    var run = try run_rule(rdf(
        "  <cim:Breaker rdf:ID=\"_sw1\"></cim:Breaker>\n" ++
        "  <cim:Breaker rdf:ID=\"_sw2\"></cim:Breaker>\n" ++
        terminal("_t1", "_sw2") ++
        "  <cim:Analog rdf:ID=\"_m1\">\n" ++
        "    <cim:Measurement.Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:Measurement.PowerSystemResource rdf:resource=\"#_sw1\"/>\n" ++
        "  </cim:Analog>\n"
        ), .MeasTerminal);
    defer run.deinit();
    try expect_rule(&run, .MeasTerminal, 1);
    try expect_violation(&run, .MeasTerminal, "_m1");
}

test "MeasTerminal skips TapPosition and SwitchPosition measurements" {
    var run = try run_rule(rdf(
        "  <cim:Discrete rdf:ID=\"_m1\">\n" ++
        "    <cim:Measurement.measurementType>TapPosition</cim:Measurement.measurementType>\n" ++
        "  </cim:Discrete>\n" ++
        "  <cim:Discrete rdf:ID=\"_m2\">\n" ++
        "    <cim:Measurement.measurementType>SwitchPosition</cim:Measurement.measurementType>\n" ++
        "  </cim:Discrete>\n"
        ), .MeasTerminal);
    defer run.deinit();
    try expect_clean(&run);
}

test "MeasTerminal rejects missing references on an ordinary measurement" {
    var run = try run_rule(rdf(
        "  <cim:Analog rdf:ID=\"_m1\">\n" ++
        "    <cim:Measurement.measurementType>Angle</cim:Measurement.measurementType>\n" ++
        "  </cim:Analog>\n"
        ), .MeasTerminal);
    defer run.deinit();
    try expect_rule(&run, .MeasTerminal, 1);
}

// ── CEBaseVoltage ─────────────────────────────────────────────────────────

test "CEBaseVoltage accepts a direct BaseVoltage association" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_bv1"></cim:BaseVoltage>
        \\  <cim:Breaker rdf:ID="_sw1">
        \\    <cim:ConductingEquipment.BaseVoltage rdf:resource="#_bv1"/>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    , .CEBaseVoltage);
    defer run.deinit();
    try expect_clean(&run);
}

test "CEBaseVoltage accepts containment in a VoltageLevel without a direct association" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:VoltageLevel rdf:ID="_vl1"></cim:VoltageLevel>
        \\  <cim:Breaker rdf:ID="_sw1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_vl1"/>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    , .CEBaseVoltage);
    defer run.deinit();
    try expect_clean(&run);
}

test "CEBaseVoltage rejects equipment with neither association nor containment" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_sw1"></cim:Breaker>
        \\</rdf:RDF>
    , .CEBaseVoltage);
    defer run.deinit();
    try expect_rule(&run, .CEBaseVoltage, 1);
    try expect_violation(&run, .CEBaseVoltage, "_sw1");
}

test "CEBaseVoltage exempts the branch classes" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_line1"></cim:ACLineSegment>
        \\  <cim:PowerTransformer rdf:ID="_pt1"></cim:PowerTransformer>
        \\  <cim:SeriesCompensator rdf:ID="_sc1"></cim:SeriesCompensator>
        \\  <cim:EquivalentBranch rdf:ID="_eb1"></cim:EquivalentBranch>
        \\  <cim:VsConverter rdf:ID="_vsc1"></cim:VsConverter>
        \\</rdf:RDF>
    , .CEBaseVoltage);
    defer run.deinit();
    try expect_clean(&run);
}

test "CEBaseVoltage requires agreement between the association and the container" {
    var agree = try run_rule(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_bv1"></cim:BaseVoltage>
        \\  <cim:VoltageLevel rdf:ID="_vl1">
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_bv1"/>
        \\  </cim:VoltageLevel>
        \\  <cim:Breaker rdf:ID="_sw1">
        \\    <cim:ConductingEquipment.BaseVoltage rdf:resource="#_bv1"/>
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_vl1"/>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    , .CEBaseVoltage);
    defer agree.deinit();
    try expect_clean(&agree);

    var disagree = try run_rule(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_bv1"></cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="_bv2"></cim:BaseVoltage>
        \\  <cim:VoltageLevel rdf:ID="_vl1">
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_bv2"/>
        \\  </cim:VoltageLevel>
        \\  <cim:Breaker rdf:ID="_sw1">
        \\    <cim:ConductingEquipment.BaseVoltage rdf:resource="#_bv1"/>
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_vl1"/>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    , .CEBaseVoltage);
    defer disagree.deinit();
    try expect_rule(&disagree, .CEBaseVoltage, 1);
    try expect_violation(&disagree, .CEBaseVoltage, "_sw1");
}

test "CEBaseVoltage resolves Bay containment through its VoltageLevel" {
    var agree = try run_rule(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_bv1"></cim:BaseVoltage>
        \\  <cim:VoltageLevel rdf:ID="_vl1">
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_bv1"/>
        \\  </cim:VoltageLevel>
        \\  <cim:Bay rdf:ID="_bay1">
        \\    <cim:Bay.VoltageLevel rdf:resource="#_vl1"/>
        \\  </cim:Bay>
        \\  <cim:Breaker rdf:ID="_sw1">
        \\    <cim:ConductingEquipment.BaseVoltage rdf:resource="#_bv1"/>
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_bay1"/>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    , .CEBaseVoltage);
    defer agree.deinit();
    try expect_clean(&agree);

    var disagree = try run_rule(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_bv1"></cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="_bv2"></cim:BaseVoltage>
        \\  <cim:VoltageLevel rdf:ID="_vl1">
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_bv2"/>
        \\  </cim:VoltageLevel>
        \\  <cim:Bay rdf:ID="_bay1">
        \\    <cim:Bay.VoltageLevel rdf:resource="#_vl1"/>
        \\  </cim:Bay>
        \\  <cim:Breaker rdf:ID="_sw1">
        \\    <cim:ConductingEquipment.BaseVoltage rdf:resource="#_bv1"/>
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_bay1"/>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    , .CEBaseVoltage);
    defer disagree.deinit();
    try expect_rule(&disagree, .CEBaseVoltage, 1);
}

test "CEBaseVoltage accepts a boundary-set BaseVoltage reference" {
    // The referenced BaseVoltage is not defined in this document. That is
    // legitimate (it lives in the boundary set) and must not violate.
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_sw1">
        \\    <cim:ConductingEquipment.BaseVoltage rdf:resource="#_bv_external"/>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    , .CEBaseVoltage);
    defer run.deinit();
    try expect_clean(&run);
}

// ── Mask isolation and integration ────────────────────────────────────────

test "a single-rule mask reports nothing for other rules' violations" {
    // The fixture violates NameLength and SVCRatings; only SVCRatings is
    // requested.
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:StaticVarCompensator rdf:ID="_svc1">
        \\  </cim:StaticVarCompensator>
        \\</rdf:RDF>
    , .SVCRatings);
    defer run.deinit();
    try expect_rule(&run, .SVCRatings, 1);
}

test "validate_model collects violations across rules in one run" {
    var model = try cim.CimDocument.init(gpa, try gpa.dupe(u8,
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:test-eq-v3">
        \\    <md:Model.profile>http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0</md:Model.profile>
        \\  </md:FullModel>
        \\  <cim:BaseVoltage rdf:ID="_bv1">
        \\    <cim:IdentifiedObject.name>BV 110</cim:IdentifiedObject.name>
        \\    <cim:BaseVoltage.nominalVoltage>-110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:Substation rdf:ID="_nameless">
        \\  </cim:Substation>
        \\</rdf:RDF>
    ));
    defer model.deinit(gpa);
    var report: qocdc.Report = .empty;
    defer report.deinit(gpa);
    try qocdc.validate_model(&report, gpa, &model);

    try std.testing.expectEqual(@as(u32, 1), report.count(.NominalVoltage));
    try std.testing.expectEqual(@as(u32, 1), report.count(.NameLength));
    try std.testing.expectEqual(@as(u32, 0), report.count(.TooManyProfileParts));
}

test "rendering shows the first 100 per rule in document order, verified by identity" {
    // 105 bad BaseVoltages: totals stay exact, exactly the first 100 in
    // document order are rendered, and the suppression line accounts for the
    // rest.
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(gpa);
    try xml.appendSlice(gpa, "<rdf:RDF>\n");
    for (0..105) |i| {
        var writer = std.Io.Writer.Allocating.fromArrayList(gpa, &xml);
        defer xml = writer.toArrayList();
        try writer.writer.print(
            "  <cim:BaseVoltage rdf:ID=\"_b{d:0>3}\">\n" ++
                "    <cim:BaseVoltage.nominalVoltage>0</cim:BaseVoltage.nominalVoltage>\n" ++
                "  </cim:BaseVoltage>\n",
            .{i},
        );
    }
    try xml.appendSlice(gpa, "</rdf:RDF>");

    var run = try run_rule(xml.items, .NominalVoltage);
    defer run.deinit();
    try std.testing.expectEqual(@as(u32, 105), run.report.count(.NominalVoltage));

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const total = try qocdc.write_report(gpa, &out.writer, &run.model, &run.report);
    try std.testing.expectEqual(@as(u64, 105), total);

    const text = out.written();
    try std.testing.expectEqual(@as(usize, 100), std.mem.count(u8, text, "qocdc: NominalVoltage: _b"));
    // Identity: the earliest object is shown, the last five are not.
    try std.testing.expect(std.mem.indexOf(u8, text, "_b000 line") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_b099 line") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_b100 line") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_b104 line") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "qocdc: NominalVoltage: 5 further violations suppressed (100 shown, 105 total)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "qocdc: 105 violations across 1 rules") != null);
}

test "every violation of one rule is counted, not just the first" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_b1">
        \\    <cim:BaseVoltage.nominalVoltage>0</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="_b2">
        \\    <cim:BaseVoltage.nominalVoltage>-1</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="_b3">
        \\    <cim:BaseVoltage.nominalVoltage>1</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    , .NominalVoltage);
    defer run.deinit();
    try expect_rule(&run, .NominalVoltage, 2);
    try expect_violation(&run, .NominalVoltage, "_b1");
    try expect_violation(&run, .NominalVoltage, "_b2");
}
