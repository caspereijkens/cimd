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

// ── SVCSlope ────────────────────────────────────────────────────────────

test "SVCSlope accepts absence, zero, and positive finite values" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:StaticVarCompensator rdf:ID="_absent"/>
        \\  <cim:StaticVarCompensator rdf:ID="_zero">
        \\    <cim:StaticVarCompensator.slope>0</cim:StaticVarCompensator.slope>
        \\  </cim:StaticVarCompensator>
        \\  <cim:StaticVarCompensator rdf:ID="_negative_zero">
        \\    <cim:StaticVarCompensator.slope>-0</cim:StaticVarCompensator.slope>
        \\  </cim:StaticVarCompensator>
        \\  <cim:StaticVarCompensator rdf:ID="_positive">
        \\    <cim:StaticVarCompensator.slope>
        \\      1.5e-6
        \\    </cim:StaticVarCompensator.slope>
        \\  </cim:StaticVarCompensator>
        \\  <cim:BaseVoltage rdf:ID="_unrelated">
        \\    <cim:StaticVarCompensator.slope>-1</cim:StaticVarCompensator.slope>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    , .SVCSlope);
    defer run.deinit();
    try expect_clean(&run);
}

test "SVCSlope rejects negative and unusable provided values" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:StaticVarCompensator rdf:ID="_negative">
        \\    <cim:StaticVarCompensator.slope>-1</cim:StaticVarCompensator.slope>
        \\  </cim:StaticVarCompensator>
        \\  <cim:StaticVarCompensator rdf:ID="_small_negative">
        \\    <cim:StaticVarCompensator.slope>-1e-300</cim:StaticVarCompensator.slope>
        \\  </cim:StaticVarCompensator>
        \\  <cim:StaticVarCompensator rdf:ID="_self_closing">
        \\    <cim:StaticVarCompensator.slope/>
        \\  </cim:StaticVarCompensator>
        \\  <cim:StaticVarCompensator rdf:ID="_empty">
        \\    <cim:StaticVarCompensator.slope></cim:StaticVarCompensator.slope>
        \\  </cim:StaticVarCompensator>
        \\  <cim:StaticVarCompensator rdf:ID="_blank">
        \\    <cim:StaticVarCompensator.slope> </cim:StaticVarCompensator.slope>
        \\  </cim:StaticVarCompensator>
        \\  <cim:StaticVarCompensator rdf:ID="_malformed">
        \\    <cim:StaticVarCompensator.slope>unknown</cim:StaticVarCompensator.slope>
        \\  </cim:StaticVarCompensator>
        \\  <cim:StaticVarCompensator rdf:ID="_nan">
        \\    <cim:StaticVarCompensator.slope>nan</cim:StaticVarCompensator.slope>
        \\  </cim:StaticVarCompensator>
        \\  <cim:StaticVarCompensator rdf:ID="_positive_inf">
        \\    <cim:StaticVarCompensator.slope>inf</cim:StaticVarCompensator.slope>
        \\  </cim:StaticVarCompensator>
        \\  <cim:StaticVarCompensator rdf:ID="_negative_inf">
        \\    <cim:StaticVarCompensator.slope>-inf</cim:StaticVarCompensator.slope>
        \\  </cim:StaticVarCompensator>
        \\</rdf:RDF>
    , .SVCSlope);
    defer run.deinit();
    try expect_rule(&run, .SVCSlope, 9);
    try expect_violation(&run, .SVCSlope, "_negative");
    try expect_violation(&run, .SVCSlope, "_small_negative");
    try expect_violation(&run, .SVCSlope, "_self_closing");
    try expect_violation(&run, .SVCSlope, "_empty");
    try expect_violation(&run, .SVCSlope, "_blank");
    try expect_violation(&run, .SVCSlope, "_malformed");
    try expect_violation(&run, .SVCSlope, "_nan");
    try expect_violation(&run, .SVCSlope, "_positive_inf");
    try expect_violation(&run, .SVCSlope, "_negative_inf");
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

// ── SMQLimits2 ───────────────────────────────────────────────────────────

test "SMQLimits2 accepts a complete minQ and maxQ pair" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:SynchronousMachine rdf:ID="_sm1">
        \\    <cim:SynchronousMachine.minQ>-50</cim:SynchronousMachine.minQ>
        \\    <cim:SynchronousMachine.maxQ>60</cim:SynchronousMachine.maxQ>
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_missing"/>
        \\  </cim:SynchronousMachine>
        \\</rdf:RDF>
    , .SMQLimits2);
    defer run.deinit();
    try expect_clean(&run);
}

test "SMQLimits2 accepts the machine's forward capability-curve association" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:SynchronousMachine rdf:ID="_sm1">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_curve1"/>
        \\    <cim:SynchronousMachine.minQ>-50</cim:SynchronousMachine.minQ>
        \\  </cim:SynchronousMachine>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_curve1"/>
        \\</rdf:RDF>
    , .SMQLimits2);
    defer run.deinit();
    try expect_clean(&run);
}

test "SMQLimits2 rejects incomplete limits and unusable curve references" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:SynchronousMachine rdf:ID="_neither"/>
        \\  <cim:SynchronousMachine rdf:ID="_min_only">
        \\    <cim:SynchronousMachine.minQ>-50</cim:SynchronousMachine.minQ>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_max_only">
        \\    <cim:SynchronousMachine.maxQ>60</cim:SynchronousMachine.maxQ>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_blank_min">
        \\    <cim:SynchronousMachine.minQ> </cim:SynchronousMachine.minQ>
        \\    <cim:SynchronousMachine.maxQ>60</cim:SynchronousMachine.maxQ>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_empty_curve">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource=""/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_dangling_curve">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_missing"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_wrong_curve_type">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_not_a_curve"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:BaseVoltage rdf:ID="_not_a_curve"/>
        \\</rdf:RDF>
    , .SMQLimits2);
    defer run.deinit();
    try expect_rule(&run, .SMQLimits2, 7);
    try expect_violation(&run, .SMQLimits2, "_neither");
    try expect_violation(&run, .SMQLimits2, "_min_only");
    try expect_violation(&run, .SMQLimits2, "_max_only");
    try expect_violation(&run, .SMQLimits2, "_blank_min");
    try expect_violation(&run, .SMQLimits2, "_empty_curve");
    try expect_violation(&run, .SMQLimits2, "_dangling_curve");
    try expect_violation(&run, .SMQLimits2, "_wrong_curve_type");
}

// ── RatedS ────────────────────────────────────────────────────────────────

test "RatedS accepts positive finite ratings for target classes and subclasses" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:RotatingMachine rdf:ID="_rotating">
        \\    <cim:RotatingMachine.ratedS>100</cim:RotatingMachine.ratedS>
        \\  </cim:RotatingMachine>
        \\  <cim:SynchronousMachine rdf:ID="_synchronous">
        \\    <cim:RotatingMachine.ratedS>
        \\      200
        \\    </cim:RotatingMachine.ratedS>
        \\  </cim:SynchronousMachine>
        \\  <cim:AsynchronousMachine rdf:ID="_asynchronous">
        \\    <cim:RotatingMachine.ratedS>300</cim:RotatingMachine.ratedS>
        \\  </cim:AsynchronousMachine>
        \\  <cim:PowerTransformerEnd rdf:ID="_transformer_end">
        \\    <cim:PowerTransformerEnd.ratedS>400</cim:PowerTransformerEnd.ratedS>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:TransformerEnd rdf:ID="_generic_transformer_end"/>
        \\  <cim:BaseVoltage rdf:ID="_unrelated"/>
        \\</rdf:RDF>
    , .RatedS);
    defer run.deinit();
    try expect_clean(&run);
}

test "RatedS rejects missing, blank, malformed, non-finite, and non-positive values" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:RotatingMachine rdf:ID="_rm_missing"/>
        \\  <cim:RotatingMachine rdf:ID="_rm_self_closing">
        \\    <cim:RotatingMachine.ratedS/>
        \\  </cim:RotatingMachine>
        \\  <cim:RotatingMachine rdf:ID="_rm_zero">
        \\    <cim:RotatingMachine.ratedS>0</cim:RotatingMachine.ratedS>
        \\  </cim:RotatingMachine>
        \\  <cim:SynchronousMachine rdf:ID="_rm_negative">
        \\    <cim:RotatingMachine.ratedS>-1</cim:RotatingMachine.ratedS>
        \\  </cim:SynchronousMachine>
        \\  <cim:AsynchronousMachine rdf:ID="_rm_malformed">
        \\    <cim:RotatingMachine.ratedS>unknown</cim:RotatingMachine.ratedS>
        \\  </cim:AsynchronousMachine>
        \\  <cim:RotatingMachine rdf:ID="_rm_nan">
        \\    <cim:RotatingMachine.ratedS>nan</cim:RotatingMachine.ratedS>
        \\  </cim:RotatingMachine>
        \\  <cim:RotatingMachine rdf:ID="_rm_inf">
        \\    <cim:RotatingMachine.ratedS>inf</cim:RotatingMachine.ratedS>
        \\  </cim:RotatingMachine>
        \\  <cim:PowerTransformerEnd rdf:ID="_pte_missing"/>
        \\  <cim:PowerTransformerEnd rdf:ID="_pte_blank">
        \\    <cim:PowerTransformerEnd.ratedS> </cim:PowerTransformerEnd.ratedS>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:PowerTransformerEnd rdf:ID="_pte_zero">
        \\    <cim:PowerTransformerEnd.ratedS>-0</cim:PowerTransformerEnd.ratedS>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:PowerTransformerEnd rdf:ID="_pte_negative">
        \\    <cim:PowerTransformerEnd.ratedS>-2</cim:PowerTransformerEnd.ratedS>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:PowerTransformerEnd rdf:ID="_pte_malformed">
        \\    <cim:PowerTransformerEnd.ratedS>unknown</cim:PowerTransformerEnd.ratedS>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:PowerTransformerEnd rdf:ID="_pte_nan">
        \\    <cim:PowerTransformerEnd.ratedS>nan</cim:PowerTransformerEnd.ratedS>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:PowerTransformerEnd rdf:ID="_pte_inf">
        \\    <cim:PowerTransformerEnd.ratedS>inf</cim:PowerTransformerEnd.ratedS>
        \\  </cim:PowerTransformerEnd>
        \\</rdf:RDF>
    , .RatedS);
    defer run.deinit();
    try expect_rule(&run, .RatedS, 14);
    try expect_violation(&run, .RatedS, "_rm_missing");
    try expect_violation(&run, .RatedS, "_rm_self_closing");
    try expect_violation(&run, .RatedS, "_rm_zero");
    try expect_violation(&run, .RatedS, "_rm_negative");
    try expect_violation(&run, .RatedS, "_rm_malformed");
    try expect_violation(&run, .RatedS, "_rm_nan");
    try expect_violation(&run, .RatedS, "_rm_inf");
    try expect_violation(&run, .RatedS, "_pte_missing");
    try expect_violation(&run, .RatedS, "_pte_blank");
    try expect_violation(&run, .RatedS, "_pte_zero");
    try expect_violation(&run, .RatedS, "_pte_negative");
    try expect_violation(&run, .RatedS, "_pte_malformed");
    try expect_violation(&run, .RatedS, "_pte_nan");
    try expect_violation(&run, .RatedS, "_pte_inf");
}

test "RatedS requires the property belonging to each target class" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:RotatingMachine rdf:ID="_rotating_wrong_property">
        \\    <cim:PowerTransformerEnd.ratedS>100</cim:PowerTransformerEnd.ratedS>
        \\  </cim:RotatingMachine>
        \\  <cim:PowerTransformerEnd rdf:ID="_transformer_wrong_property">
        \\    <cim:RotatingMachine.ratedS>100</cim:RotatingMachine.ratedS>
        \\  </cim:PowerTransformerEnd>
        \\</rdf:RDF>
    , .RatedS);
    defer run.deinit();
    try expect_rule(&run, .RatedS, 2);
    try expect_violation(&run, .RatedS, "_rotating_wrong_property");
    try expect_violation(&run, .RatedS, "_transformer_wrong_property");
}

// ── ShuntCompensatorSensitivity ───────────────────────────────────────────

test "ShuntCompensatorSensitivity accepts absence and positive finite values" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ShuntCompensator rdf:ID="_base_absent"/>
        \\  <cim:LinearShuntCompensator rdf:ID="_linear_absent"/>
        \\  <cim:NonlinearShuntCompensator rdf:ID="_nonlinear_absent"/>
        \\  <cim:ShuntCompensator rdf:ID="_base_positive">
        \\    <cim:ShuntCompensator.voltageSensitivity>1</cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:ShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_linear_whitespace">
        \\    <cim:ShuntCompensator.voltageSensitivity>
        \\      2.5
        \\    </cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:NonlinearShuntCompensator rdf:ID="_nonlinear_scientific">
        \\    <cim:ShuntCompensator.voltageSensitivity>1e-6</cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:NonlinearShuntCompensator>
        \\  <cim:BaseVoltage rdf:ID="_unrelated">
        \\    <cim:ShuntCompensator.voltageSensitivity>-1</cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    , .ShuntCompensatorSensitivity);
    defer run.deinit();
    try expect_clean(&run);
}

test "ShuntCompensatorSensitivity rejects every provided non-positive or invalid value" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ShuntCompensator rdf:ID="_self_closing">
        \\    <cim:ShuntCompensator.voltageSensitivity/>
        \\  </cim:ShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_empty">
        \\    <cim:ShuntCompensator.voltageSensitivity></cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:NonlinearShuntCompensator rdf:ID="_blank">
        \\    <cim:ShuntCompensator.voltageSensitivity> </cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:NonlinearShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_zero">
        \\    <cim:ShuntCompensator.voltageSensitivity>0</cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:ShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_negative_zero">
        \\    <cim:ShuntCompensator.voltageSensitivity>-0</cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:NonlinearShuntCompensator rdf:ID="_negative">
        \\    <cim:ShuntCompensator.voltageSensitivity>-1</cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:NonlinearShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_malformed">
        \\    <cim:ShuntCompensator.voltageSensitivity>unknown</cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:ShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_nan">
        \\    <cim:ShuntCompensator.voltageSensitivity>nan</cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:NonlinearShuntCompensator rdf:ID="_positive_inf">
        \\    <cim:ShuntCompensator.voltageSensitivity>inf</cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:NonlinearShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_negative_inf">
        \\    <cim:ShuntCompensator.voltageSensitivity>-inf</cim:ShuntCompensator.voltageSensitivity>
        \\  </cim:ShuntCompensator>
        \\</rdf:RDF>
    , .ShuntCompensatorSensitivity);
    defer run.deinit();
    try expect_rule(&run, .ShuntCompensatorSensitivity, 10);
    try expect_violation(&run, .ShuntCompensatorSensitivity, "_self_closing");
    try expect_violation(&run, .ShuntCompensatorSensitivity, "_empty");
    try expect_violation(&run, .ShuntCompensatorSensitivity, "_blank");
    try expect_violation(&run, .ShuntCompensatorSensitivity, "_zero");
    try expect_violation(&run, .ShuntCompensatorSensitivity, "_negative_zero");
    try expect_violation(&run, .ShuntCompensatorSensitivity, "_negative");
    try expect_violation(&run, .ShuntCompensatorSensitivity, "_malformed");
    try expect_violation(&run, .ShuntCompensatorSensitivity, "_nan");
    try expect_violation(&run, .ShuntCompensatorSensitivity, "_positive_inf");
    try expect_violation(&run, .ShuntCompensatorSensitivity, "_negative_inf");
}

// ── CATieFlow ─────────────────────────────────────────────────────────────

test "CATieFlow accepts interchange control areas with resolved TieFlow references" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:TieFlow rdf:ID="_tf1">
        \\    <cim:TieFlow.ControlArea rdf:resource="#_ca1"/>
        \\  </cim:TieFlow>
        \\  <cim:ControlArea rdf:ID="_ca1">
        \\    <cim:ControlArea.type rdf:resource="#ControlAreaTypeKind.Interchange"/>
        \\  </cim:ControlArea>
        \\  <cim:ControlArea rdf:about="http://example.com/grid#_ca2">
        \\    <cim:ControlArea.type rdf:resource="http://iec.ch/TC57/CIM100#ControlAreaTypeKind.Interchange"/>
        \\  </cim:ControlArea>
        \\  <cim:TieFlow rdf:ID="_tf2">
        \\    <cim:TieFlow.ControlArea rdf:resource="#_ca2"/>
        \\  </cim:TieFlow>
        \\</rdf:RDF>
    , .CATieFlow);
    defer run.deinit();
    try expect_clean(&run);
}

test "CATieFlow ignores control areas whose type is not interchange" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ControlArea rdf:ID="_absent_type"/>
        \\  <cim:ControlArea rdf:ID="_literal_type">
        \\    <cim:ControlArea.type>ControlAreaTypeKind.Interchange</cim:ControlArea.type>
        \\  </cim:ControlArea>
        \\  <cim:ControlArea rdf:ID="_empty_reference">
        \\    <cim:ControlArea.type rdf:resource=""/>
        \\  </cim:ControlArea>
        \\  <cim:ControlArea rdf:ID="_actual">
        \\    <cim:ControlArea.type rdf:resource="#ControlAreaTypeKind.Actual"/>
        \\  </cim:ControlArea>
        \\  <cim:BaseVoltage rdf:ID="_unrelated">
        \\    <cim:ControlArea.type rdf:resource="#ControlAreaTypeKind.Interchange"/>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    , .CATieFlow);
    defer run.deinit();
    try expect_clean(&run);
}

test "CATieFlow checks each interchange control area independently" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ControlArea rdf:ID="_with_flow">
        \\    <cim:ControlArea.type rdf:resource="#ControlAreaTypeKind.Interchange"/>
        \\  </cim:ControlArea>
        \\  <cim:ControlArea rdf:ID="_without_flow">
        \\    <cim:ControlArea.type rdf:resource="#ControlAreaTypeKind.Interchange"/>
        \\  </cim:ControlArea>
        \\  <cim:ControlArea rdf:ID="_missing_association">
        \\    <cim:ControlArea.type rdf:resource="#ControlAreaTypeKind.Interchange"/>
        \\  </cim:ControlArea>
        \\  <cim:ControlArea rdf:ID="_dangling_association">
        \\    <cim:ControlArea.type rdf:resource="#ControlAreaTypeKind.Interchange"/>
        \\  </cim:ControlArea>
        \\  <cim:ControlArea rdf:ID="_wrong_target">
        \\    <cim:ControlArea.type rdf:resource="#ControlAreaTypeKind.Interchange"/>
        \\  </cim:ControlArea>
        \\  <cim:ControlArea rdf:ID="_empty_association">
        \\    <cim:ControlArea.type rdf:resource="#ControlAreaTypeKind.Interchange"/>
        \\  </cim:ControlArea>
        \\  <cim:ControlArea rdf:ID="_non_interchange">
        \\    <cim:ControlArea.type rdf:resource="#ControlAreaTypeKind.Actual"/>
        \\  </cim:ControlArea>
        \\  <cim:BaseVoltage rdf:ID="_not_a_control_area"/>
        \\  <cim:TieFlow rdf:ID="_valid_tf">
        \\    <cim:TieFlow.ControlArea rdf:resource="#_with_flow"/>
        \\  </cim:TieFlow>
        \\  <cim:TieFlow rdf:ID="_missing_tf"/>
        \\  <cim:TieFlow rdf:ID="_dangling_tf">
        \\    <cim:TieFlow.ControlArea rdf:resource="#_missing"/>
        \\  </cim:TieFlow>
        \\  <cim:TieFlow rdf:ID="_wrong_target_tf">
        \\    <cim:TieFlow.ControlArea rdf:resource="#_not_a_control_area"/>
        \\  </cim:TieFlow>
        \\  <cim:TieFlow rdf:ID="_empty_tf">
        \\    <cim:TieFlow.ControlArea rdf:resource=""/>
        \\  </cim:TieFlow>
        \\  <cim:TieFlow rdf:ID="_non_interchange_tf">
        \\    <cim:TieFlow.ControlArea rdf:resource="#_non_interchange"/>
        \\  </cim:TieFlow>
        \\</rdf:RDF>
    , .CATieFlow);
    defer run.deinit();
    try expect_rule(&run, .CATieFlow, 5);
    try expect_violation(&run, .CATieFlow, "_without_flow");
    try expect_violation(&run, .CATieFlow, "_missing_association");
    try expect_violation(&run, .CATieFlow, "_dangling_association");
    try expect_violation(&run, .CATieFlow, "_wrong_target");
    try expect_violation(&run, .CATieFlow, "_empty_association");
}

// ── OperationalLimitSetAtTerminal ─────────────────────────────────────────

test "OperationalLimitSetAtTerminal accepts associations that resolve to Terminals" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:OperationalLimitSet rdf:ID="_terminal_only">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_t1"/>
        \\  </cim:OperationalLimitSet>
        \\  <cim:OperationalLimitSet rdf:ID="_both_associations">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="http://example.com/grid#_t2"/>
        \\    <cim:OperationalLimitSet.Equipment rdf:resource="#_equipment"/>
        \\  </cim:OperationalLimitSet>
        \\  <cim:OperationalLimitSet rdf:ID="_urn_terminal">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="urn:uuid:terminal"/>
        \\  </cim:OperationalLimitSet>
        \\  <cim:Terminal rdf:ID="_t1"/>
        \\  <cim:Terminal rdf:about="http://example.com/grid#_t2"/>
        \\  <cim:Terminal rdf:about="urn:uuid:terminal"/>
        \\  <cim:Equipment rdf:ID="_equipment"/>
        \\  <cim:BaseVoltage rdf:ID="_unrelated"/>
        \\</rdf:RDF>
    , .OperationalLimitSetAtTerminal);
    defer run.deinit();
    try expect_clean(&run);
}

test "OperationalLimitSetAtTerminal ignores Equipment and rejects unusable Terminal associations" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:OperationalLimitSet rdf:ID="_missing"/>
        \\  <cim:OperationalLimitSet rdf:ID="_equipment_only">
        \\    <cim:OperationalLimitSet.Equipment rdf:resource="#_equipment"/>
        \\  </cim:OperationalLimitSet>
        \\  <cim:OperationalLimitSet rdf:ID="_self_closing">
        \\    <cim:OperationalLimitSet.Terminal/>
        \\  </cim:OperationalLimitSet>
        \\  <cim:OperationalLimitSet rdf:ID="_literal">
        \\    <cim:OperationalLimitSet.Terminal>#_t1</cim:OperationalLimitSet.Terminal>
        \\  </cim:OperationalLimitSet>
        \\  <cim:OperationalLimitSet rdf:ID="_empty_reference">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource=""/>
        \\  </cim:OperationalLimitSet>
        \\  <cim:OperationalLimitSet rdf:ID="_blank_reference">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="   "/>
        \\  </cim:OperationalLimitSet>
        \\  <cim:OperationalLimitSet rdf:ID="_malformed_reference">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_t1 />
        \\  </cim:OperationalLimitSet>
        \\  <cim:OperationalLimitSet rdf:ID="_dangling_reference">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_missing"/>
        \\  </cim:OperationalLimitSet>
        \\  <cim:OperationalLimitSet rdf:ID="_wrong_target_type">
        \\    <cim:OperationalLimitSet.Terminal rdf:resource="#_equipment"/>
        \\  </cim:OperationalLimitSet>
        \\  <cim:Equipment rdf:ID="_equipment"/>
        \\</rdf:RDF>
    , .OperationalLimitSetAtTerminal);
    defer run.deinit();
    try expect_rule(&run, .OperationalLimitSetAtTerminal, 9);
    try expect_violation(&run, .OperationalLimitSetAtTerminal, "_missing");
    try expect_violation(&run, .OperationalLimitSetAtTerminal, "_equipment_only");
    try expect_violation(&run, .OperationalLimitSetAtTerminal, "_self_closing");
    try expect_violation(&run, .OperationalLimitSetAtTerminal, "_literal");
    try expect_violation(&run, .OperationalLimitSetAtTerminal, "_empty_reference");
    try expect_violation(&run, .OperationalLimitSetAtTerminal, "_blank_reference");
    try expect_violation(&run, .OperationalLimitSetAtTerminal, "_malformed_reference");
    try expect_violation(&run, .OperationalLimitSetAtTerminal, "_dangling_reference");
    try expect_violation(&run, .OperationalLimitSetAtTerminal, "_wrong_target_type");
}

// ── ControlModeCompatibility ──────────────────────────────────────────────

const ControlModeCase = struct {
    controller_class: []const u8,
    controller_association: []const u8,
    control_class: []const u8,
    mode: []const u8,
    target_class: []const u8 = "ACLineSegment",
};

fn control_mode_case_xml(buffer: []u8, case: ControlModeCase) ![]const u8 {
    return std.fmt.bufPrint(buffer,
        \\<rdf:RDF>
        \\  <cim:{s} rdf:ID="_controller">
        \\    <cim:{s} rdf:resource="#_control"/>
        \\  </cim:{s}>
        \\  <cim:{s} rdf:ID="_control">
        \\    <cim:RegulatingControl.mode rdf:resource="http://iec.ch/TC57/CIM100#RegulatingControlModeKind.{s}"/>
        \\    <cim:RegulatingControl.Terminal rdf:resource="#_terminal"/>
        \\  </cim:{s}>
        \\  <cim:{s} rdf:ID="_target"/>
        \\  <cim:Terminal rdf:ID="_terminal">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_target"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    , .{
        case.controller_class,
        case.controller_association,
        case.controller_class,
        case.control_class,
        case.mode,
        case.control_class,
        case.target_class,
    });
}

test "ControlModeCompatibility accepts every class-specific mode" {
    const allowed = [_]ControlModeCase{
        .{ .controller_class = "PhaseTapChangerLinear", .controller_association = "TapChanger.TapChangerControl", .control_class = "TapChangerControl", .mode = "activePower" },
        .{ .controller_class = "RatioTapChanger", .controller_association = "TapChanger.TapChangerControl", .control_class = "TapChangerControl", .mode = "voltage" },
        .{ .controller_class = "RatioTapChanger", .controller_association = "TapChanger.TapChangerControl", .control_class = "TapChangerControl", .mode = "reactivePower" },
        .{ .controller_class = "RatioTapChanger", .controller_association = "TapChanger.TapChangerControl", .control_class = "TapChangerControl", .mode = "powerFactor" },
        .{ .controller_class = "SynchronousMachine", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "voltage" },
        .{ .controller_class = "SynchronousMachine", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "reactivePower" },
        .{ .controller_class = "SynchronousMachine", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "powerFactor" },
        .{ .controller_class = "NonlinearShuntCompensator", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "voltage" },
        .{ .controller_class = "NonlinearShuntCompensator", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "reactivePower" },
        .{ .controller_class = "NonlinearShuntCompensator", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "powerFactor" },
        .{ .controller_class = "StaticVarCompensator", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "voltage" },
        .{ .controller_class = "StaticVarCompensator", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "reactivePower" },
        .{ .controller_class = "SynchronousMachine", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "voltage", .target_class = "BusbarSection" },
    };

    var buffer: [2048]u8 = undefined;
    for (allowed) |case| {
        var run = try run_rule(try control_mode_case_xml(&buffer, case), .ControlModeCompatibility);
        defer run.deinit();
        try expect_clean(&run);
    }
}

test "ControlModeCompatibility rejects every class-specific mismatch" {
    const rejected = [_]ControlModeCase{
        .{ .controller_class = "PhaseTapChangerTabular", .controller_association = "TapChanger.TapChangerControl", .control_class = "TapChangerControl", .mode = "voltage" },
        .{ .controller_class = "RatioTapChanger", .controller_association = "TapChanger.TapChangerControl", .control_class = "TapChangerControl", .mode = "activePower" },
        .{ .controller_class = "SynchronousMachine", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "activePower" },
        .{ .controller_class = "LinearShuntCompensator", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "activePower" },
        .{ .controller_class = "StaticVarCompensator", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "powerFactor" },
        .{ .controller_class = "StaticVarCompensator", .controller_association = "RegulatingCondEq.RegulatingControl", .control_class = "RegulatingControl", .mode = "reactivePower", .target_class = "BusbarSection" },
    };

    var buffer: [2048]u8 = undefined;
    for (rejected) |case| {
        var run = try run_rule(try control_mode_case_xml(&buffer, case), .ControlModeCompatibility);
        defer run.deinit();
        try expect_rule(&run, .ControlModeCompatibility, 1);
        try expect_violation(&run, .ControlModeCompatibility, "_control");
    }
}

test "ControlModeCompatibility rejects prohibited and unknown modes globally" {
    const rejected = [_][]const u8{
        "currentFlow",
        "admittance",
        "timeScheduled",
        "temperature",
        "activePowerControl",
        "unknown",
    };

    var buffer: [1024]u8 = undefined;
    for (rejected) |mode| {
        const xml = try std.fmt.bufPrint(&buffer,
            \\<rdf:RDF>
            \\  <cim:RegulatingControl rdf:ID="_control">
            \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.{s}"/>
            \\  </cim:RegulatingControl>
            \\</rdf:RDF>
        , .{mode});
        var run = try run_rule(xml, .ControlModeCompatibility);
        defer run.deinit();
        try expect_rule(&run, .ControlModeCompatibility, 1);
    }
}

test "ControlModeCompatibility treats absent optional associations differently from malformed ones" {
    var absent = try run_rule(
        \\<rdf:RDF>
        \\  <cim:RegulatingControl rdf:ID="_both_absent"/>
        \\  <cim:RegulatingControl rdf:ID="_terminal_absent">
        \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.activePower"/>
        \\  </cim:RegulatingControl>
        \\  <cim:RegulatingControl rdf:ID="_mode_absent">
        \\    <cim:RegulatingControl.Terminal rdf:resource="#_terminal"/>
        \\  </cim:RegulatingControl>
        \\  <cim:ACLineSegment rdf:ID="_line"/>
        \\  <cim:Terminal rdf:ID="_terminal">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_line"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    , .ControlModeCompatibility);
    defer absent.deinit();
    try expect_clean(&absent);

    var malformed = try run_rule(
        \\<rdf:RDF>
        \\  <cim:RegulatingControl rdf:ID="_literal">
        \\    <cim:RegulatingControl.mode>RegulatingControlModeKind.voltage</cim:RegulatingControl.mode>
        \\  </cim:RegulatingControl>
        \\  <cim:RegulatingControl rdf:ID="_self_closing">
        \\    <cim:RegulatingControl.mode/>
        \\  </cim:RegulatingControl>
        \\  <cim:RegulatingControl rdf:ID="_empty_reference">
        \\    <cim:RegulatingControl.mode rdf:resource=""/>
        \\  </cim:RegulatingControl>
        \\</rdf:RDF>
    , .ControlModeCompatibility);
    defer malformed.deinit();
    try expect_rule(&malformed, .ControlModeCompatibility, 3);
    try expect_violation(&malformed, .ControlModeCompatibility, "_literal");
    try expect_violation(&malformed, .ControlModeCompatibility, "_self_closing");
    try expect_violation(&malformed, .ControlModeCompatibility, "_empty_reference");
}

test "ControlModeCompatibility validates the complete controlled Terminal path" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:RegulatingControl rdf:ID="_literal_terminal">
        \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.voltage"/>
        \\    <cim:RegulatingControl.Terminal>#_valid_terminal</cim:RegulatingControl.Terminal>
        \\  </cim:RegulatingControl>
        \\  <cim:RegulatingControl rdf:ID="_dangling_terminal">
        \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.voltage"/>
        \\    <cim:RegulatingControl.Terminal rdf:resource="#_missing"/>
        \\  </cim:RegulatingControl>
        \\  <cim:RegulatingControl rdf:ID="_wrong_terminal_type">
        \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.voltage"/>
        \\    <cim:RegulatingControl.Terminal rdf:resource="#_line"/>
        \\  </cim:RegulatingControl>
        \\  <cim:RegulatingControl rdf:ID="_dc_terminal">
        \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.voltage"/>
        \\    <cim:RegulatingControl.Terminal rdf:resource="#_dc"/>
        \\  </cim:RegulatingControl>
        \\  <cim:RegulatingControl rdf:ID="_terminal_without_equipment">
        \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.voltage"/>
        \\    <cim:RegulatingControl.Terminal rdf:resource="#_no_equipment"/>
        \\  </cim:RegulatingControl>
        \\  <cim:RegulatingControl rdf:ID="_terminal_dangling_equipment">
        \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.voltage"/>
        \\    <cim:RegulatingControl.Terminal rdf:resource="#_dangling_equipment"/>
        \\  </cim:RegulatingControl>
        \\  <cim:RegulatingControl rdf:ID="_terminal_wrong_equipment_type">
        \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.voltage"/>
        \\    <cim:RegulatingControl.Terminal rdf:resource="#_wrong_equipment"/>
        \\  </cim:RegulatingControl>
        \\  <cim:RegulatingControl rdf:ID="_valid">
        \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.voltage"/>
        \\    <cim:RegulatingControl.Terminal rdf:resource="http://example.com/grid#_valid_terminal"/>
        \\  </cim:RegulatingControl>
        \\  <cim:ACLineSegment rdf:ID="_line"/>
        \\  <cim:BaseVoltage rdf:ID="_base_voltage"/>
        \\  <cim:DCTerminal rdf:ID="_dc"/>
        \\  <cim:Terminal rdf:ID="_no_equipment"/>
        \\  <cim:Terminal rdf:ID="_dangling_equipment">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_missing_equipment"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_wrong_equipment">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_base_voltage"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:about="http://example.com/grid#_valid_terminal">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_line"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    , .ControlModeCompatibility);
    defer run.deinit();
    try expect_rule(&run, .ControlModeCompatibility, 7);
    try expect_violation(&run, .ControlModeCompatibility, "_literal_terminal");
    try expect_violation(&run, .ControlModeCompatibility, "_dangling_terminal");
    try expect_violation(&run, .ControlModeCompatibility, "_wrong_terminal_type");
    try expect_violation(&run, .ControlModeCompatibility, "_dc_terminal");
    try expect_violation(&run, .ControlModeCompatibility, "_terminal_without_equipment");
    try expect_violation(&run, .ControlModeCompatibility, "_terminal_dangling_equipment");
    try expect_violation(&run, .ControlModeCompatibility, "_terminal_wrong_equipment_type");
}

test "ControlModeCompatibility intersects restrictions for shared controls" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:SynchronousMachine rdf:ID="_sm_ok">
        \\    <cim:RegulatingCondEq.RegulatingControl rdf:resource="#_shared_ok"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:StaticVarCompensator rdf:ID="_svc_ok">
        \\    <cim:RegulatingCondEq.RegulatingControl rdf:resource="#_shared_ok"/>
        \\  </cim:StaticVarCompensator>
        \\  <cim:RegulatingControl rdf:ID="_shared_ok">
        \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.reactivePower"/>
        \\  </cim:RegulatingControl>
        \\  <cim:SynchronousMachine rdf:ID="_sm_bad">
        \\    <cim:RegulatingCondEq.RegulatingControl rdf:resource="#_shared_bad"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:StaticVarCompensator rdf:ID="_svc_bad">
        \\    <cim:RegulatingCondEq.RegulatingControl rdf:resource="#_shared_bad"/>
        \\  </cim:StaticVarCompensator>
        \\  <cim:RegulatingControl rdf:ID="_shared_bad">
        \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.powerFactor"/>
        \\  </cim:RegulatingControl>
        \\  <cim:PhaseTapChangerSymmetrical rdf:ID="_phase">
        \\    <cim:TapChanger.TapChangerControl rdf:resource="#_tap_shared"/>
        \\  </cim:PhaseTapChangerSymmetrical>
        \\  <cim:RatioTapChanger rdf:ID="_ratio">
        \\    <cim:TapChanger.TapChangerControl rdf:resource="#_tap_shared"/>
        \\  </cim:RatioTapChanger>
        \\  <cim:TapChangerControl rdf:ID="_tap_shared">
        \\    <cim:RegulatingControl.mode rdf:resource="#RegulatingControlModeKind.activePower"/>
        \\  </cim:TapChangerControl>
        \\</rdf:RDF>
    , .ControlModeCompatibility);
    defer run.deinit();
    try expect_rule(&run, .ControlModeCompatibility, 2);
    try expect_violation(&run, .ControlModeCompatibility, "_shared_bad");
    try expect_violation(&run, .ControlModeCompatibility, "_tap_shared");
}

// ── ACLineSegmentR ────────────────────────────────────────────────────────

test "ACLineSegmentR accepts absence, zero, and positive finite resistance" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_absent"/>
        \\  <cim:ACLineSegment rdf:ID="_zero">
        \\    <cim:ACLineSegment.r>0</cim:ACLineSegment.r>
        \\  </cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_negative_zero">
        \\    <cim:ACLineSegment.r>-0</cim:ACLineSegment.r>
        \\  </cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_positive">
        \\    <cim:ACLineSegment.r>
        \\      1.5e-6
        \\    </cim:ACLineSegment.r>
        \\  </cim:ACLineSegment>
        \\  <cim:SeriesCompensator rdf:ID="_unrelated">
        \\    <cim:ACLineSegment.r>-1</cim:ACLineSegment.r>
        \\  </cim:SeriesCompensator>
        \\</rdf:RDF>
    , .ACLineSegmentR);
    defer run.deinit();
    try expect_clean(&run);
}

test "ACLineSegmentR rejects negative and unusable provided resistance" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_negative">
        \\    <cim:ACLineSegment.r>-1</cim:ACLineSegment.r>
        \\  </cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_small_negative">
        \\    <cim:ACLineSegment.r>-1e-300</cim:ACLineSegment.r>
        \\  </cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_self_closing">
        \\    <cim:ACLineSegment.r/>
        \\  </cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_empty">
        \\    <cim:ACLineSegment.r></cim:ACLineSegment.r>
        \\  </cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_blank">
        \\    <cim:ACLineSegment.r> </cim:ACLineSegment.r>
        \\  </cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_malformed">
        \\    <cim:ACLineSegment.r>unknown</cim:ACLineSegment.r>
        \\  </cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_nan">
        \\    <cim:ACLineSegment.r>nan</cim:ACLineSegment.r>
        \\  </cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_positive_inf">
        \\    <cim:ACLineSegment.r>inf</cim:ACLineSegment.r>
        \\  </cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_negative_inf">
        \\    <cim:ACLineSegment.r>-inf</cim:ACLineSegment.r>
        \\  </cim:ACLineSegment>
        \\</rdf:RDF>
    , .ACLineSegmentR);
    defer run.deinit();
    try expect_rule(&run, .ACLineSegmentR, 9);
    try expect_violation(&run, .ACLineSegmentR, "_negative");
    try expect_violation(&run, .ACLineSegmentR, "_small_negative");
    try expect_violation(&run, .ACLineSegmentR, "_self_closing");
    try expect_violation(&run, .ACLineSegmentR, "_empty");
    try expect_violation(&run, .ACLineSegmentR, "_blank");
    try expect_violation(&run, .ACLineSegmentR, "_malformed");
    try expect_violation(&run, .ACLineSegmentR, "_nan");
    try expect_violation(&run, .ACLineSegmentR, "_positive_inf");
    try expect_violation(&run, .ACLineSegmentR, "_negative_inf");
}

// ── LinearShuntCompensatorG ─────────────────────────────────────────────

test "LinearShuntCompensatorG accepts absence, zero, and positive finite conductance" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:LinearShuntCompensator rdf:ID="_absent"/>
        \\  <cim:LinearShuntCompensator rdf:ID="_zero">
        \\    <cim:LinearShuntCompensator.gPerSection>0</cim:LinearShuntCompensator.gPerSection>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_negative_zero">
        \\    <cim:LinearShuntCompensator.gPerSection>-0</cim:LinearShuntCompensator.gPerSection>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_positive">
        \\    <cim:LinearShuntCompensator.gPerSection>
        \\      1.5e-6
        \\    </cim:LinearShuntCompensator.gPerSection>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:NonlinearShuntCompensator rdf:ID="_unrelated">
        \\    <cim:LinearShuntCompensator.gPerSection>-1</cim:LinearShuntCompensator.gPerSection>
        \\  </cim:NonlinearShuntCompensator>
        \\</rdf:RDF>
    , .LinearShuntCompensatorG);
    defer run.deinit();
    try expect_clean(&run);
}

test "LinearShuntCompensatorG rejects negative and unusable provided conductance" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:LinearShuntCompensator rdf:ID="_negative">
        \\    <cim:LinearShuntCompensator.gPerSection>-1</cim:LinearShuntCompensator.gPerSection>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_small_negative">
        \\    <cim:LinearShuntCompensator.gPerSection>-1e-300</cim:LinearShuntCompensator.gPerSection>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_self_closing">
        \\    <cim:LinearShuntCompensator.gPerSection/>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_empty">
        \\    <cim:LinearShuntCompensator.gPerSection></cim:LinearShuntCompensator.gPerSection>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_blank">
        \\    <cim:LinearShuntCompensator.gPerSection> </cim:LinearShuntCompensator.gPerSection>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_malformed">
        \\    <cim:LinearShuntCompensator.gPerSection>unknown</cim:LinearShuntCompensator.gPerSection>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_nan">
        \\    <cim:LinearShuntCompensator.gPerSection>nan</cim:LinearShuntCompensator.gPerSection>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_positive_inf">
        \\    <cim:LinearShuntCompensator.gPerSection>inf</cim:LinearShuntCompensator.gPerSection>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_negative_inf">
        \\    <cim:LinearShuntCompensator.gPerSection>-inf</cim:LinearShuntCompensator.gPerSection>
        \\  </cim:LinearShuntCompensator>
        \\</rdf:RDF>
    , .LinearShuntCompensatorG);
    defer run.deinit();
    try expect_rule(&run, .LinearShuntCompensatorG, 9);
    try expect_violation(&run, .LinearShuntCompensatorG, "_negative");
    try expect_violation(&run, .LinearShuntCompensatorG, "_small_negative");
    try expect_violation(&run, .LinearShuntCompensatorG, "_self_closing");
    try expect_violation(&run, .LinearShuntCompensatorG, "_empty");
    try expect_violation(&run, .LinearShuntCompensatorG, "_blank");
    try expect_violation(&run, .LinearShuntCompensatorG, "_malformed");
    try expect_violation(&run, .LinearShuntCompensatorG, "_nan");
    try expect_violation(&run, .LinearShuntCompensatorG, "_positive_inf");
    try expect_violation(&run, .LinearShuntCompensatorG, "_negative_inf");
}

// ── ShuntCompensatorSections ────────────────────────────────────────────

test "ShuntCompensatorSections accepts inclusive bounds for every shunt kind" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ShuntCompensator rdf:ID="_absent"/>
        \\  <cim:ShuntCompensator rdf:ID="_zero">
        \\    <cim:ShuntCompensator.normalSections>0</cim:ShuntCompensator.normalSections>
        \\    <cim:ShuntCompensator.maximumSections>0</cim:ShuntCompensator.maximumSections>
        \\  </cim:ShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_between">
        \\    <cim:ShuntCompensator.normalSections>
        \\      2
        \\    </cim:ShuntCompensator.normalSections>
        \\    <cim:ShuntCompensator.maximumSections>3</cim:ShuntCompensator.maximumSections>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:NonlinearShuntCompensator rdf:ID="_equal">
        \\    <cim:ShuntCompensator.normalSections>4</cim:ShuntCompensator.normalSections>
        \\    <cim:ShuntCompensator.maximumSections>4</cim:ShuntCompensator.maximumSections>
        \\  </cim:NonlinearShuntCompensator>
        \\  <cim:BaseVoltage rdf:ID="_unrelated">
        \\    <cim:ShuntCompensator.normalSections>2</cim:ShuntCompensator.normalSections>
        \\    <cim:ShuntCompensator.maximumSections>1</cim:ShuntCompensator.maximumSections>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    , .ShuntCompensatorSections);
    defer run.deinit();
    try expect_clean(&run);
}

test "ShuntCompensatorSections rejects invalid normalSections" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ShuntCompensator rdf:ID="_negative">
        \\    <cim:ShuntCompensator.normalSections>-1</cim:ShuntCompensator.normalSections>
        \\  </cim:ShuntCompensator>
        \\  <cim:LinearShuntCompensator rdf:ID="_above_maximum">
        \\    <cim:ShuntCompensator.normalSections>3</cim:ShuntCompensator.normalSections>
        \\    <cim:ShuntCompensator.maximumSections>2</cim:ShuntCompensator.maximumSections>
        \\  </cim:LinearShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_self_closing">
        \\    <cim:ShuntCompensator.normalSections/>
        \\  </cim:ShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_empty">
        \\    <cim:ShuntCompensator.normalSections></cim:ShuntCompensator.normalSections>
        \\  </cim:ShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_blank">
        \\    <cim:ShuntCompensator.normalSections> </cim:ShuntCompensator.normalSections>
        \\  </cim:ShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_malformed">
        \\    <cim:ShuntCompensator.normalSections>unknown</cim:ShuntCompensator.normalSections>
        \\  </cim:ShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_decimal">
        \\    <cim:ShuntCompensator.normalSections>1.5</cim:ShuntCompensator.normalSections>
        \\  </cim:ShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_positive_inf">
        \\    <cim:ShuntCompensator.normalSections>inf</cim:ShuntCompensator.normalSections>
        \\  </cim:ShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_overflow">
        \\    <cim:ShuntCompensator.normalSections>4294967296</cim:ShuntCompensator.normalSections>
        \\  </cim:ShuntCompensator>
        \\</rdf:RDF>
    , .ShuntCompensatorSections);
    defer run.deinit();
    try expect_rule(&run, .ShuntCompensatorSections, 9);
    try expect_violation(&run, .ShuntCompensatorSections, "_negative");
    try expect_violation(&run, .ShuntCompensatorSections, "_above_maximum");
    try expect_violation(&run, .ShuntCompensatorSections, "_self_closing");
    try expect_violation(&run, .ShuntCompensatorSections, "_empty");
    try expect_violation(&run, .ShuntCompensatorSections, "_blank");
    try expect_violation(&run, .ShuntCompensatorSections, "_malformed");
    try expect_violation(&run, .ShuntCompensatorSections, "_decimal");
    try expect_violation(&run, .ShuntCompensatorSections, "_positive_inf");
    try expect_violation(&run, .ShuntCompensatorSections, "_overflow");
}

test "ShuntCompensatorSections rejects unusable maximumSections" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ShuntCompensator rdf:ID="_self_closing">
        \\    <cim:ShuntCompensator.normalSections>0</cim:ShuntCompensator.normalSections>
        \\    <cim:ShuntCompensator.maximumSections/>
        \\  </cim:ShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_empty">
        \\    <cim:ShuntCompensator.normalSections>0</cim:ShuntCompensator.normalSections>
        \\    <cim:ShuntCompensator.maximumSections></cim:ShuntCompensator.maximumSections>
        \\  </cim:ShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_blank">
        \\    <cim:ShuntCompensator.normalSections>0</cim:ShuntCompensator.normalSections>
        \\    <cim:ShuntCompensator.maximumSections> </cim:ShuntCompensator.maximumSections>
        \\  </cim:ShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_malformed">
        \\    <cim:ShuntCompensator.normalSections>0</cim:ShuntCompensator.normalSections>
        \\    <cim:ShuntCompensator.maximumSections>unknown</cim:ShuntCompensator.maximumSections>
        \\  </cim:ShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_negative">
        \\    <cim:ShuntCompensator.normalSections>0</cim:ShuntCompensator.normalSections>
        \\    <cim:ShuntCompensator.maximumSections>-1</cim:ShuntCompensator.maximumSections>
        \\  </cim:ShuntCompensator>
        \\  <cim:ShuntCompensator rdf:ID="_decimal">
        \\    <cim:ShuntCompensator.normalSections>0</cim:ShuntCompensator.normalSections>
        \\    <cim:ShuntCompensator.maximumSections>1.5</cim:ShuntCompensator.maximumSections>
        \\  </cim:ShuntCompensator>
        \\</rdf:RDF>
    , .ShuntCompensatorSections);
    defer run.deinit();
    try expect_rule(&run, .ShuntCompensatorSections, 6);
    try expect_violation(&run, .ShuntCompensatorSections, "_self_closing");
    try expect_violation(&run, .ShuntCompensatorSections, "_empty");
    try expect_violation(&run, .ShuntCompensatorSections, "_blank");
    try expect_violation(&run, .ShuntCompensatorSections, "_malformed");
    try expect_violation(&run, .ShuntCompensatorSections, "_negative");
    try expect_violation(&run, .ShuntCompensatorSections, "_decimal");
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

fn phased_terminal(comptime id: []const u8, comptime equipment: []const u8, comptime phase: []const u8) []const u8 {
    return "  <cim:Terminal rdf:ID=\"" ++ id ++ "\">\n" ++
        "    <cim:Terminal.ConductingEquipment rdf:resource=\"#" ++ equipment ++ "\"/>\n" ++
        "    <cim:Terminal.phases rdf:resource=\"#PhaseCode." ++ phase ++ "\"/>\n" ++
        "  </cim:Terminal>\n";
}

test "TerminalCount1 requires exactly one terminal" {
    var ok = try run_rule(rdf("  <cim:EnergyConsumer rdf:ID=\"_ec1\"></cim:EnergyConsumer>\n" ++
        terminal("_t1", "_ec1")), .TerminalCount1);
    defer ok.deinit();
    try expect_clean(&ok);

    var zero = try run_rule(rdf("  <cim:EnergyConsumer rdf:ID=\"_ec1\"></cim:EnergyConsumer>\n"), .TerminalCount1);
    defer zero.deinit();
    try expect_rule(&zero, .TerminalCount1, 1);
    try expect_violation(&zero, .TerminalCount1, "_ec1");

    var two = try run_rule(rdf("  <cim:EnergySource rdf:ID=\"_es1\"></cim:EnergySource>\n" ++
        terminal("_t1", "_es1") ++
        terminal("_t2", "_es1")), .TerminalCount1);
    defer two.deinit();
    try expect_rule(&two, .TerminalCount1, 1);
}

test "TerminalCount1 covers subclasses and the strict-subclass Connector case" {
    // SynchronousMachine is_a RegulatingCondEq; BusbarSection is a strict
    // subclass of Connector.
    var run = try run_rule(rdf("  <cim:SynchronousMachine rdf:ID=\"_sm1\"></cim:SynchronousMachine>\n" ++
        "  <cim:BusbarSection rdf:ID=\"_bb1\"></cim:BusbarSection>\n"), .TerminalCount1);
    defer run.deinit();
    try expect_rule(&run, .TerminalCount1, 2);
}

test "TerminalCount2 requires exactly two terminals" {
    var ok = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        terminal("_t1", "_line1") ++
        terminal("_t2", "_line1")), .TerminalCount2);
    defer ok.deinit();
    try expect_clean(&ok);

    var one = try run_rule(rdf("  <cim:Breaker rdf:ID=\"_sw1\"></cim:Breaker>\n" ++
        terminal("_t1", "_sw1")), .TerminalCount2);
    defer one.deinit();
    try expect_rule(&one, .TerminalCount2, 1);
    try expect_violation(&one, .TerminalCount2, "_sw1");

    var three = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        terminal("_t1", "_line1") ++
        terminal("_t2", "_line1") ++
        terminal("_t3", "_line1")), .TerminalCount2);
    defer three.deinit();
    try expect_rule(&three, .TerminalCount2, 1);
}

test "terminal counting ignores non-Terminal referrers and DC associations" {
    // A DCTerminal via the DC association does not count toward the
    // exact-Terminal cardinality rules.
    var run = try run_rule(rdf("  <cim:EnergyConsumer rdf:ID=\"_ec1\"></cim:EnergyConsumer>\n" ++
        terminal("_t1", "_ec1") ++
        "  <cim:DCTerminal rdf:ID=\"_dct1\">\n" ++
        "    <cim:DCTerminal.DCConductingEquipment rdf:resource=\"#_ec1\"/>\n" ++
        "  </cim:DCTerminal>\n"), .TerminalCount1);
    defer run.deinit();
    try expect_clean(&run);
}

// ── TerminalSeqNum / TerminalSeqNumOrder ──────────────────────────────────

test "TerminalSeqNum requires sequence numbers on EquivalentBranch terminals" {
    var ok = try run_rule(rdf("  <cim:EquivalentBranch rdf:ID=\"_eb1\"></cim:EquivalentBranch>\n" ++
        numbered_terminal("_t1", "_eb1", "1") ++
        numbered_terminal("_t2", "_eb1", "2")), .TerminalSeqNum);
    defer ok.deinit();
    try expect_clean(&ok);

    var missing = try run_rule(rdf("  <cim:EquivalentBranch rdf:ID=\"_eb1\"></cim:EquivalentBranch>\n" ++
        numbered_terminal("_t1", "_eb1", "1") ++
        terminal("_t2", "_eb1")), .TerminalSeqNum);
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
    var run = try run_rule(rdf(mutual_coupling_fixture ++
        terminal("_t1b", "_line1") ++
        "  <cim:ACLineSegment rdf:ID=\"_line3\"></cim:ACLineSegment>\n" ++
        terminal("_t3a", "_line3")), .TerminalSeqNum);
    defer run.deinit();
    try expect_rule(&run, .TerminalSeqNum, 1);
    try expect_violation(&run, .TerminalSeqNum, "_t1b");
}

test "a MutualCoupling with one bad end still couples the resolvable end's line" {
    // The Second_Terminal dangles, so MCFirstSecond would fire -- but
    // _line1 is still coupled through the resolvable First_Terminal, and its
    // unnumbered terminal still violates TerminalSeqNum. MCFirstSecond is
    // NOT requested: its violation must not leak into this run.
    var run = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        numbered_terminal("_t1a", "_line1", "1") ++
        terminal("_t1b", "_line1") ++
        "  <cim:MutualCoupling rdf:ID=\"_mc1\">\n" ++
        "    <cim:MutualCoupling.First_Terminal rdf:resource=\"#_t1a\"/>\n" ++
        "    <cim:MutualCoupling.Second_Terminal rdf:resource=\"#_nowhere\"/>\n" ++
        "  </cim:MutualCoupling>\n"), .TerminalSeqNum);
    defer run.deinit();
    try expect_rule(&run, .TerminalSeqNum, 1);
    try expect_violation(&run, .TerminalSeqNum, "_t1b");
}

test "TerminalSeqNumOrder accepts contiguous 1..k and tolerates absence" {
    var ok = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        numbered_terminal("_t1", "_line1", "2") ++
        numbered_terminal("_t2", "_line1", "1")), .TerminalSeqNumOrder);
    defer ok.deinit();
    try expect_clean(&ok);

    // Unnumbered terminals are skipped, not violations.
    var unnumbered = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        terminal("_t1", "_line1") ++
        terminal("_t2", "_line1")), .TerminalSeqNumOrder);
    defer unnumbered.deinit();
    try expect_clean(&unnumbered);
}

test "TerminalSeqNumOrder rejects gaps, missing 1, duplicates, and unparseable numbers" {
    var gap = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        numbered_terminal("_t1", "_line1", "1") ++
        numbered_terminal("_t2", "_line1", "3")), .TerminalSeqNumOrder);
    defer gap.deinit();
    try expect_rule(&gap, .TerminalSeqNumOrder, 1);
    try expect_violation(&gap, .TerminalSeqNumOrder, "_line1");

    var no_one = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        numbered_terminal("_t1", "_line1", "2")), .TerminalSeqNumOrder);
    defer no_one.deinit();
    try expect_rule(&no_one, .TerminalSeqNumOrder, 1);

    var duplicate = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        numbered_terminal("_t1", "_line1", "1") ++
        numbered_terminal("_t2", "_line1", "1")), .TerminalSeqNumOrder);
    defer duplicate.deinit();
    try expect_rule(&duplicate, .TerminalSeqNumOrder, 1);

    var unparseable = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        numbered_terminal("_t1", "_line1", "abc")), .TerminalSeqNumOrder);
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

// ── PhaseCodeGround ───────────────────────────────────────────────────────

test "PhaseCodeGround accepts N and the grounding default, and ignores other equipment" {
    var run = try run_rule(rdf(
        "  <cim:PetersenCoil rdf:ID=\"_coil\"></cim:PetersenCoil>\n" ++
            "  <cim:Ground rdf:ID=\"_ground\"></cim:Ground>\n" ++
            "  <cim:GroundingImpedance rdf:ID=\"_impedance\"></cim:GroundingImpedance>\n" ++
            "  <cim:GroundDisconnector rdf:ID=\"_disconnector\"></cim:GroundDisconnector>\n" ++
            "  <cim:Breaker rdf:ID=\"_breaker\"></cim:Breaker>\n" ++
            phased_terminal("_coil_t", "_coil", "N") ++
            terminal("_ground_t", "_ground") ++
            phased_terminal("_impedance_t", "_impedance", "N") ++
            phased_terminal("_disconnector_t1", "_disconnector", "N") ++
            phased_terminal("_disconnector_t2", "_disconnector", "N") ++
            phased_terminal("_breaker_t", "_breaker", "ABC"),
    ), .PhaseCodeGround);
    defer run.deinit();
    try expect_clean(&run);
}

fn phase_code_ground_case_xml(buffer: []u8, phase: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "<rdf:RDF>" ++
            "<cim:Ground rdf:ID=\"_ground\"/>" ++
            "<cim:Terminal rdf:ID=\"_terminal\">" ++
            "<cim:Terminal.ConductingEquipment rdf:resource=\"#_ground\"/>" ++
            "<cim:Terminal.phases rdf:resource=\"#PhaseCode.{s}\"/>" ++
            "</cim:Terminal>" ++
            "</rdf:RDF>",
        .{phase},
    );
}

test "PhaseCodeGround rejects every known non-neutral PhaseCode" {
    const non_neutral_phase_codes = [_][]const u8{
        "A",    "AB",  "ABC", "ABCN", "ABN", "AC", "ACN", "AN", "B",
        "BC",   "BCN", "BN",  "C",    "CN",  "X",  "XN",  "XY", "XYN",
        "none", "s1",  "s12", "s12N", "s1N", "s2", "s2N",
    };
    var buffer: [1024]u8 = undefined;
    for (non_neutral_phase_codes) |phase| {
        var run = try run_rule(
            try phase_code_ground_case_xml(&buffer, phase),
            .PhaseCodeGround,
        );
        defer run.deinit();
        try expect_rule(&run, .PhaseCodeGround, 1);
        try expect_violation(&run, .PhaseCodeGround, "_terminal");
    }
}

test "PhaseCodeGround checks every target and both GroundDisconnector terminals" {
    var run = try run_rule(rdf(
        "  <cim:PetersenCoil rdf:ID=\"_coil\"></cim:PetersenCoil>\n" ++
            "  <cim:Ground rdf:ID=\"_ground\"></cim:Ground>\n" ++
            "  <cim:GroundingImpedance rdf:ID=\"_impedance\"></cim:GroundingImpedance>\n" ++
            "  <cim:GroundDisconnector rdf:ID=\"_disconnector\"></cim:GroundDisconnector>\n" ++
            phased_terminal("_coil_t", "_coil", "ABC") ++
            phased_terminal("_ground_t", "_ground", "unknown") ++
            "  <cim:Terminal rdf:ID=\"_impedance_t\">\n" ++
            "    <cim:Terminal.ConductingEquipment rdf:resource=\"#_impedance\"/>\n" ++
            "    <cim:Terminal.phases>PhaseCode.N</cim:Terminal.phases>\n" ++
            "  </cim:Terminal>\n" ++
            phased_terminal("_disconnector_t1", "_disconnector", "N") ++
            phased_terminal("_disconnector_t2", "_disconnector", "A"),
    ), .PhaseCodeGround);
    defer run.deinit();
    try expect_rule(&run, .PhaseCodeGround, 4);
    try expect_violation(&run, .PhaseCodeGround, "_coil_t");
    try expect_violation(&run, .PhaseCodeGround, "_ground_t");
    try expect_violation(&run, .PhaseCodeGround, "_impedance_t");
    try expect_violation(&run, .PhaseCodeGround, "_disconnector_t2");
}

// ── PTTerminalConsistency ─────────────────────────────────────────────────

test "PTTerminalConsistency accepts a consistent end and rejects mismatches" {
    var ok = try run_rule(rdf("  <cim:PowerTransformer rdf:ID=\"_pt1\"></cim:PowerTransformer>\n" ++
        terminal("_t1", "_pt1") ++
        "  <cim:PowerTransformerEnd rdf:ID=\"_end1\">\n" ++
        "    <cim:TransformerEnd.Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:PowerTransformerEnd.PowerTransformer rdf:resource=\"#_pt1\"/>\n" ++
        "  </cim:PowerTransformerEnd>\n"), .PTTerminalConsistency);
    defer ok.deinit();
    try expect_clean(&ok);

    // The terminal belongs to a different transformer.
    var mismatch = try run_rule(rdf("  <cim:PowerTransformer rdf:ID=\"_pt1\"></cim:PowerTransformer>\n" ++
        "  <cim:PowerTransformer rdf:ID=\"_pt2\"></cim:PowerTransformer>\n" ++
        terminal("_t1", "_pt2") ++
        "  <cim:PowerTransformerEnd rdf:ID=\"_end1\">\n" ++
        "    <cim:TransformerEnd.Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:PowerTransformerEnd.PowerTransformer rdf:resource=\"#_pt1\"/>\n" ++
        "  </cim:PowerTransformerEnd>\n"), .PTTerminalConsistency);
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

    var dangling = try run_rule(rdf("  <cim:PowerTransformer rdf:ID=\"_pt1\"></cim:PowerTransformer>\n" ++
        "  <cim:PowerTransformerEnd rdf:ID=\"_end1\">\n" ++
        "    <cim:TransformerEnd.Terminal rdf:resource=\"#_nowhere\"/>\n" ++
        "    <cim:PowerTransformerEnd.PowerTransformer rdf:resource=\"#_pt1\"/>\n" ++
        "  </cim:PowerTransformerEnd>\n"), .PTTerminalConsistency);
    defer dangling.deinit();
    try expect_rule(&dangling, .PTTerminalConsistency, 1);
}

test "PTTerminalConsistency rejects an equipment that is not a PowerTransformer" {
    var run = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        terminal("_t1", "_line1") ++
        "  <cim:PowerTransformerEnd rdf:ID=\"_end1\">\n" ++
        "    <cim:TransformerEnd.Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:PowerTransformerEnd.PowerTransformer rdf:resource=\"#_line1\"/>\n" ++
        "  </cim:PowerTransformerEnd>\n"), .PTTerminalConsistency);
    defer run.deinit();
    try expect_rule(&run, .PTTerminalConsistency, 1);
}

// ── TooManyTapChangers ───────────────────────────────────────────────────

fn power_transformer_end(comptime id: []const u8) []const u8 {
    return "  <cim:PowerTransformerEnd rdf:ID=\"" ++ id ++ "\"/>\n";
}

fn tap_changer(
    comptime class: []const u8,
    comptime end_property: []const u8,
    comptime id: []const u8,
    comptime end: []const u8,
) []const u8 {
    return "  <cim:" ++ class ++ " rdf:ID=\"" ++ id ++ "\">\n" ++
        "    <cim:" ++ end_property ++ " rdf:resource=\"#" ++ end ++ "\"/>\n" ++
        "  </cim:" ++ class ++ ">\n";
}

fn controlled_tap_changer(
    comptime class: []const u8,
    comptime end_property: []const u8,
    comptime id: []const u8,
    comptime end: []const u8,
    comptime control: []const u8,
    comptime enabled: []const u8,
) []const u8 {
    return "  <cim:" ++ class ++ " rdf:ID=\"" ++ id ++ "\">\n" ++
        "    <cim:" ++ end_property ++ " rdf:resource=\"#" ++ end ++ "\"/>\n" ++
        "    <cim:TapChanger.TapChangerControl rdf:resource=\"#" ++ control ++ "\"/>\n" ++
        "    <cim:TapChanger.controlEnabled>" ++ enabled ++ "</cim:TapChanger.controlEnabled>\n" ++
        "  </cim:" ++ class ++ ">\n";
}

fn tap_changer_control(comptime id: []const u8, comptime enabled: []const u8) []const u8 {
    return "  <cim:TapChangerControl rdf:ID=\"" ++ id ++ "\">\n" ++
        "    <cim:RegulatingControl.enabled>" ++ enabled ++ "</cim:RegulatingControl.enabled>\n" ++
        "  </cim:TapChangerControl>\n";
}

test "TooManyTapChangers accepts at most one phase and one ratio changer per end" {
    var run = try run_rule(rdf(
        power_transformer_end("_empty") ++
            power_transformer_end("_phase_only") ++
            power_transformer_end("_ratio_only") ++
            power_transformer_end("_combined") ++
            tap_changer("PhaseTapChangerLinear", "PhaseTapChanger.TransformerEnd", "_phase1", "_phase_only") ++
            tap_changer("PhaseTapChangerTabular", "PhaseTapChanger.TransformerEnd", "_phase2", "_combined") ++
            tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_ratio1", "_ratio_only") ++
            tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_ratio2", "_combined"),
    ), .TooManyTapChangers);
    defer run.deinit();
    try expect_clean(&run);
}

test "TooManyTapChangers rejects duplicate kinds once per transformer end" {
    var run = try run_rule(rdf(
        power_transformer_end("_duplicate_phase") ++
            power_transformer_end("_duplicate_ratio") ++
            power_transformer_end("_multiple_reasons") ++
            tap_changer("PhaseTapChangerLinear", "PhaseTapChanger.TransformerEnd", "_p1", "_duplicate_phase") ++
            tap_changer("PhaseTapChangerTabular", "PhaseTapChanger.TransformerEnd", "_p2", "_duplicate_phase") ++
            tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_r1", "_duplicate_ratio") ++
            tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_r2", "_duplicate_ratio") ++
            tap_changer("PhaseTapChangerAsymmetrical", "PhaseTapChanger.TransformerEnd", "_mp1", "_multiple_reasons") ++
            tap_changer("PhaseTapChangerSymmetrical", "PhaseTapChanger.TransformerEnd", "_mp2", "_multiple_reasons") ++
            tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_mr1", "_multiple_reasons") ++
            tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_mr2", "_multiple_reasons"),
    ), .TooManyTapChangers);
    defer run.deinit();
    try expect_rule(&run, .TooManyTapChangers, 3);
    try expect_violation(&run, .TooManyTapChangers, "_duplicate_phase");
    try expect_violation(&run, .TooManyTapChangers, "_duplicate_ratio");
    try expect_violation(&run, .TooManyTapChangers, "_multiple_reasons");
}

test "TooManyTapChangers rejects two regulating tap changers" {
    var run = try run_rule(rdf(
        power_transformer_end("_separate_controls") ++
            power_transformer_end("_shared_control") ++
            controlled_tap_changer("PhaseTapChangerLinear", "PhaseTapChanger.TransformerEnd", "_sp", "_separate_controls", "_phase_control", "true") ++
            controlled_tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_sr", "_separate_controls", "_ratio_control", " true ") ++
            controlled_tap_changer("PhaseTapChangerTabular", "PhaseTapChanger.TransformerEnd", "_hp", "_shared_control", "_shared", "true") ++
            controlled_tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_hr", "_shared_control", "_shared", "true") ++
            tap_changer_control("_phase_control", "true") ++
            tap_changer_control("_ratio_control", "true") ++
            tap_changer_control("_shared", "true"),
    ), .TooManyTapChangers);
    defer run.deinit();
    try expect_rule(&run, .TooManyTapChangers, 2);
    try expect_violation(&run, .TooManyTapChangers, "_separate_controls");
    try expect_violation(&run, .TooManyTapChangers, "_shared_control");
}

test "TooManyTapChangers requires both enabled flags for regulation" {
    var run = try run_rule(rdf(
        power_transformer_end("_tap_disabled") ++
            power_transformer_end("_control_disabled") ++
            power_transformer_end("_no_controls") ++
            controlled_tap_changer("PhaseTapChangerLinear", "PhaseTapChanger.TransformerEnd", "_tp", "_tap_disabled", "_tc1", "true") ++
            controlled_tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_tr", "_tap_disabled", "_tc2", "false") ++
            controlled_tap_changer("PhaseTapChangerLinear", "PhaseTapChanger.TransformerEnd", "_cp", "_control_disabled", "_cc1", "true") ++
            controlled_tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_cr", "_control_disabled", "_cc2", "true") ++
            tap_changer("PhaseTapChangerLinear", "PhaseTapChanger.TransformerEnd", "_np", "_no_controls") ++
            tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_nr", "_no_controls") ++
            tap_changer_control("_tc1", "true") ++
            tap_changer_control("_tc2", "true") ++
            tap_changer_control("_cc1", "true") ++
            tap_changer_control("_cc2", "false"),
    ), .TooManyTapChangers);
    defer run.deinit();
    try expect_clean(&run);
}

test "TooManyTapChangers ignores unusable end associations and keeps ends separate" {
    var run = try run_rule(rdf(
        power_transformer_end("_end_a") ++
            power_transformer_end("_end_b") ++
            "  <cim:TransformerEnd rdf:ID=\"_generic_end\"/>\n" ++
            tap_changer("PhaseTapChangerLinear", "PhaseTapChanger.TransformerEnd", "_pa", "_end_a") ++
            tap_changer("PhaseTapChangerLinear", "PhaseTapChanger.TransformerEnd", "_pb", "_end_b") ++
            tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_ra", "_end_a") ++
            tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_rb", "_end_b") ++
            tap_changer("PhaseTapChangerLinear", "PhaseTapChanger.TransformerEnd", "_wrong1", "_generic_end") ++
            tap_changer("PhaseTapChangerTabular", "PhaseTapChanger.TransformerEnd", "_wrong2", "_generic_end") ++
            tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_dangling1", "_missing") ++
            tap_changer("RatioTapChanger", "RatioTapChanger.TransformerEnd", "_dangling2", "_missing"),
    ), .TooManyTapChangers);
    defer run.deinit();
    try expect_clean(&run);
}

// ── MCFirstSecond ─────────────────────────────────────────────────────────

test "MCFirstSecond accepts terminals of two different ACLineSegments" {
    var run = try run_rule(rdf(mutual_coupling_fixture), .MCFirstSecond);
    defer run.deinit();
    try expect_clean(&run);
}

test "MCFirstSecond rejects same-line ends, non-line equipment, and bad references" {
    var same_line = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        terminal("_t1", "_line1") ++
        terminal("_t2", "_line1") ++
        "  <cim:MutualCoupling rdf:ID=\"_mc1\">\n" ++
        "    <cim:MutualCoupling.First_Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:MutualCoupling.Second_Terminal rdf:resource=\"#_t2\"/>\n" ++
        "  </cim:MutualCoupling>\n"), .MCFirstSecond);
    defer same_line.deinit();
    try expect_rule(&same_line, .MCFirstSecond, 1);
    try expect_violation(&same_line, .MCFirstSecond, "_mc1");

    // The second terminal's equipment is a Breaker, not an ACLineSegment.
    var not_line = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        "  <cim:Breaker rdf:ID=\"_sw1\"></cim:Breaker>\n" ++
        terminal("_t1", "_line1") ++
        terminal("_t2", "_sw1") ++
        "  <cim:MutualCoupling rdf:ID=\"_mc1\">\n" ++
        "    <cim:MutualCoupling.First_Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:MutualCoupling.Second_Terminal rdf:resource=\"#_t2\"/>\n" ++
        "  </cim:MutualCoupling>\n"), .MCFirstSecond);
    defer not_line.deinit();
    try expect_rule(&not_line, .MCFirstSecond, 1);

    var missing_ref = try run_rule(rdf("  <cim:ACLineSegment rdf:ID=\"_line1\"></cim:ACLineSegment>\n" ++
        terminal("_t1", "_line1") ++
        "  <cim:MutualCoupling rdf:ID=\"_mc1\">\n" ++
        "    <cim:MutualCoupling.First_Terminal rdf:resource=\"#_t1\"/>\n" ++
        "  </cim:MutualCoupling>\n"), .MCFirstSecond);
    defer missing_ref.deinit();
    try expect_rule(&missing_ref, .MCFirstSecond, 1);
}

// ── MeasTerminal ──────────────────────────────────────────────────────────

test "MeasTerminal accepts a terminal of the referenced equipment" {
    var run = try run_rule(rdf("  <cim:Breaker rdf:ID=\"_sw1\"></cim:Breaker>\n" ++
        terminal("_t1", "_sw1") ++
        "  <cim:Analog rdf:ID=\"_m1\">\n" ++
        "    <cim:Measurement.Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:Measurement.PowerSystemResource rdf:resource=\"#_sw1\"/>\n" ++
        "  </cim:Analog>\n"), .MeasTerminal);
    defer run.deinit();
    try expect_clean(&run);
}

test "MeasTerminal rejects a terminal of a different equipment" {
    var run = try run_rule(rdf("  <cim:Breaker rdf:ID=\"_sw1\"></cim:Breaker>\n" ++
        "  <cim:Breaker rdf:ID=\"_sw2\"></cim:Breaker>\n" ++
        terminal("_t1", "_sw2") ++
        "  <cim:Analog rdf:ID=\"_m1\">\n" ++
        "    <cim:Measurement.Terminal rdf:resource=\"#_t1\"/>\n" ++
        "    <cim:Measurement.PowerSystemResource rdf:resource=\"#_sw1\"/>\n" ++
        "  </cim:Analog>\n"), .MeasTerminal);
    defer run.deinit();
    try expect_rule(&run, .MeasTerminal, 1);
    try expect_violation(&run, .MeasTerminal, "_m1");
}

test "MeasTerminal skips TapPosition and SwitchPosition measurements" {
    var run = try run_rule(rdf("  <cim:Discrete rdf:ID=\"_m1\">\n" ++
        "    <cim:Measurement.measurementType>TapPosition</cim:Measurement.measurementType>\n" ++
        "  </cim:Discrete>\n" ++
        "  <cim:Discrete rdf:ID=\"_m2\">\n" ++
        "    <cim:Measurement.measurementType>SwitchPosition</cim:Measurement.measurementType>\n" ++
        "  </cim:Discrete>\n"), .MeasTerminal);
    defer run.deinit();
    try expect_clean(&run);
}

test "MeasTerminal rejects missing references on an ordinary measurement" {
    var run = try run_rule(rdf("  <cim:Analog rdf:ID=\"_m1\">\n" ++
        "    <cim:Measurement.measurementType>Angle</cim:Measurement.measurementType>\n" ++
        "  </cim:Analog>\n"), .MeasTerminal);
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
    const totals = try qocdc.write_report(gpa, &out.writer, &run.model, &run.report, .plain);
    try std.testing.expectEqual(@as(u64, 105), totals.total());

    const text = out.written();
    const level = @tagName(qocdc.severity(.NominalVoltage));
    var prefix_buffer: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buffer, "qocdc: {s}: NominalVoltage: _b", .{level});
    try std.testing.expectEqual(@as(usize, 100), std.mem.count(u8, text, prefix));
    // Identity: the earliest object is shown, the last five are not.
    try std.testing.expect(std.mem.indexOf(u8, text, "_b000 line") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_b099 line") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_b100 line") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_b104 line") == null);
    var suppressed_buffer: [128]u8 = undefined;
    const suppressed = try std.fmt.bufPrint(
        &suppressed_buffer,
        "qocdc: {s}: NominalVoltage: 5 further violations suppressed (100 shown, 105 total)",
        .{level},
    );
    try std.testing.expect(std.mem.indexOf(u8, text, suppressed) != null);
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

// ── RCCYValues ─────────────────────────────────────────────────────────────────────────────

test "RCCYValues accepts equality when another point has strict width" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_curve"/>
        \\  <cim:CurveData rdf:ID="_equal">
        \\    <cim:CurveData.Curve rdf:resource="#_curve"/>
        \\    <cim:CurveData.y1value>-1</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>-1.0</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_wide">
        \\    <cim:CurveData.Curve rdf:resource="#_curve"/>
        \\    <cim:CurveData.y1value>-2</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>-1</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\</rdf:RDF>
    , .RCCYValues);
    defer run.deinit();
    try expect_clean(&run);
}

test "RCCYValues rejects a point whose upper y value is lower" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_curve"/>
        \\  <cim:CurveData rdf:ID="_reversed">
        \\    <cim:CurveData.Curve rdf:resource="#_curve"/>
        \\    <cim:CurveData.y1value>1</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>0</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\</rdf:RDF>
    , .RCCYValues);
    defer run.deinit();
    try expect_rule(&run, .RCCYValues, 1);
    try expect_violation(&run, .RCCYValues, "_reversed");
}

test "RCCYValues rejects every point when all y values are equal" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_curve"/>
        \\  <cim:CurveData rdf:ID="_equal1">
        \\    <cim:CurveData.Curve rdf:resource="#_curve"/>
        \\    <cim:CurveData.y1value>0</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>-0</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_equal2">
        \\    <cim:CurveData.Curve rdf:resource="#_curve"/>
        \\    <cim:CurveData.y1value>2</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>2.0</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\</rdf:RDF>
    , .RCCYValues);
    defer run.deinit();
    try expect_rule(&run, .RCCYValues, 2);
    try expect_violation(&run, .RCCYValues, "_equal1");
    try expect_violation(&run, .RCCYValues, "_equal2");
}

test "RCCYValues keeps aggregate state separate for each curve" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_flat_curve"/>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_wide_curve"/>
        \\  <cim:CurveData rdf:ID="_flat">
        \\    <cim:CurveData.Curve rdf:resource="#_flat_curve"/>
        \\    <cim:CurveData.y1value>3</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>3</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_wide">
        \\    <cim:CurveData.Curve rdf:resource="#_wide_curve"/>
        \\    <cim:CurveData.y1value>-2</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>-1</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\</rdf:RDF>
    , .RCCYValues);
    defer run.deinit();
    try expect_rule(&run, .RCCYValues, 1);
    try expect_violation(&run, .RCCYValues, "_flat");
}

test "RCCYValues ignores CurveData outside its reference scope" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:Curve rdf:ID="_generic"/>
        \\  <cim:BaseVoltage rdf:ID="_wrong_type"/>
        \\  <cim:CurveData rdf:ID="_generic_point">
        \\    <cim:CurveData.Curve rdf:resource="#_generic"/>
        \\    <cim:CurveData.y1value>1</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>0</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_wrong_point">
        \\    <cim:CurveData.Curve rdf:resource="#_wrong_type"/>
        \\    <cim:CurveData.y1value>1</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>0</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_dangling_point">
        \\    <cim:CurveData.Curve rdf:resource="#_missing"/>
        \\    <cim:CurveData.y1value>1</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>0</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_unassociated_point">
        \\    <cim:CurveData.y1value>1</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>0</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\</rdf:RDF>
    , .RCCYValues);
    defer run.deinit();
    try expect_clean(&run);
}

test "RCCYValues does not infer all-equal across unusable points" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_missing_curve"/>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_blank_curve"/>
        \\  <cim:CurveData rdf:ID="_missing_equal">
        \\    <cim:CurveData.Curve rdf:resource="#_missing_curve"/>
        \\    <cim:CurveData.y1value>1</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>1</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_missing_y2">
        \\    <cim:CurveData.Curve rdf:resource="#_missing_curve"/>
        \\    <cim:CurveData.y1value>2</cim:CurveData.y1value>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_blank_equal">
        \\    <cim:CurveData.Curve rdf:resource="#_blank_curve"/>
        \\    <cim:CurveData.y1value>3</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value>3</cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_blank_y2">
        \\    <cim:CurveData.Curve rdf:resource="#_blank_curve"/>
        \\    <cim:CurveData.y1value>4</cim:CurveData.y1value>
        \\    <cim:CurveData.y2value> </cim:CurveData.y2value>
        \\  </cim:CurveData>
        \\</rdf:RDF>
    , .RCCYValues);
    defer run.deinit();
    try expect_rule(&run, .RCCYValues, 1);
    try expect_violation(&run, .RCCYValues, "_blank_y2");
}

// ── RCCXValues2 ─────────────────────────────────────────────────────────────────────────────

fn rcc_x_case_xml(
    buffer: []u8,
    machine_type: ?[]const u8,
    x_values: []const ?[]const u8,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll(
        "<rdf:RDF><cim:ReactiveCapabilityCurve rdf:ID=\"_curve\"/>" ++
            "<cim:SynchronousMachine rdf:ID=\"_machine\">" ++
            "<cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource=\"#_curve\"/>",
    );
    if (machine_type) |value| {
        try writer.print(
            "<cim:SynchronousMachine.type rdf:resource=\"#SynchronousMachineKind.{s}\"/>",
            .{value},
        );
    }
    try writer.writeAll("</cim:SynchronousMachine>");
    for (x_values, 0..) |x_value, i| {
        try writer.print(
            "<cim:CurveData rdf:ID=\"_point{d}\">" ++
                "<cim:CurveData.Curve rdf:resource=\"#_curve\"/>",
            .{i},
        );
        if (x_value) |value| {
            try writer.print(
                "<cim:CurveData.xvalue>{s}</cim:CurveData.xvalue>",
                .{value},
            );
        }
        try writer.writeAll("</cim:CurveData>");
    }
    try writer.writeAll("</rdf:RDF>");
    return writer.buffered();
}

test "RCCXValues2 accepts every machine-type boundary" {
    const Case = struct { machine_type: ?[]const u8, x_values: []const ?[]const u8 };
    const cases = [_]Case{
        .{ .machine_type = "condenser", .x_values = &.{"-0"} },
        .{ .machine_type = "generator", .x_values = &.{ "0", "1" } },
        .{ .machine_type = "generatorOrCondenser", .x_values = &.{ "0", "2", "-5" } },
        .{ .machine_type = "motor", .x_values = &.{ "0", "-1" } },
        .{ .machine_type = "motorOrCondenser", .x_values = &.{ "0", "-2", "5" } },
        .{ .machine_type = "generatorOrMotor", .x_values = &.{ "-1", "0", "1" } },
        .{ .machine_type = "generatorOrCondenserOrMotor", .x_values = &.{ "-1", "-0", "1" } },
    };
    var buffer: [4096]u8 = undefined;
    for (cases) |case| {
        var run = try run_rule(
            try rcc_x_case_xml(&buffer, case.machine_type, case.x_values),
            .RCCXValues2,
        );
        defer run.deinit();
        try expect_clean(&run);
    }
}

test "RCCXValues2 rejects invalid counts and x-value signs" {
    const Case = struct { machine_type: ?[]const u8, x_values: []const ?[]const u8 };
    const cases = [_]Case{
        .{ .machine_type = "condenser", .x_values = &.{} },
        .{ .machine_type = "condenser", .x_values = &.{"1"} },
        .{ .machine_type = "condenser", .x_values = &.{ "0", "0" } },
        .{ .machine_type = "generator", .x_values = &.{"0"} },
        .{ .machine_type = "generatorOrCondenser", .x_values = &.{ "-1", "-2" } },
        .{ .machine_type = "motor", .x_values = &.{"0"} },
        .{ .machine_type = "motorOrCondenser", .x_values = &.{ "1", "2" } },
        .{ .machine_type = "generatorOrMotor", .x_values = &.{ "-1", "1" } },
        .{ .machine_type = "generatorOrMotor", .x_values = &.{ "1", "2", "3" } },
        .{ .machine_type = "generatorOrCondenserOrMotor", .x_values = &.{ "-1", "-2", "-3" } },
    };
    var buffer: [4096]u8 = undefined;
    for (cases) |case| {
        var run = try run_rule(
            try rcc_x_case_xml(&buffer, case.machine_type, case.x_values),
            .RCCXValues2,
        );
        defer run.deinit();
        try expect_rule(&run, .RCCXValues2, 1);
        try expect_violation(&run, .RCCXValues2, "_machine");
    }
}

test "RCCXValues2 rejects unusable x values and machine types" {
    const Case = struct { machine_type: ?[]const u8, x_values: []const ?[]const u8 };
    const cases = [_]Case{
        .{ .machine_type = "generator", .x_values = &.{ "0", "nan" } },
        .{ .machine_type = "motor", .x_values = &.{ "0", null } },
        .{ .machine_type = "generatorOrMotor", .x_values = &.{ "-1", "1", "" } },
        .{ .machine_type = "unknown", .x_values = &.{ "-1", "0", "1" } },
        .{ .machine_type = null, .x_values = &.{ "-1", "0", "1" } },
    };
    var buffer: [4096]u8 = undefined;
    for (cases) |case| {
        var run = try run_rule(
            try rcc_x_case_xml(&buffer, case.machine_type, case.x_values),
            .RCCXValues2,
        );
        defer run.deinit();
        try expect_rule(&run, .RCCXValues2, 1);
        try expect_violation(&run, .RCCXValues2, "_machine");
    }
}

test "RCCXValues2 evaluates machines sharing one curve independently" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_curve"/>
        \\  <cim:SynchronousMachine rdf:ID="_generator">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_curve"/>
        \\    <cim:SynchronousMachine.type rdf:resource="#SynchronousMachineKind.generator"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_motor">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_curve"/>
        \\    <cim:SynchronousMachine.type rdf:resource="#SynchronousMachineKind.motor"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:CurveData rdf:ID="_zero">
        \\    <cim:CurveData.Curve rdf:resource="#_curve"/>
        \\    <cim:CurveData.xvalue>0</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_positive">
        \\    <cim:CurveData.Curve rdf:resource="#_curve"/>
        \\    <cim:CurveData.xvalue>1</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\</rdf:RDF>
    , .RCCXValues2);
    defer run.deinit();
    try expect_rule(&run, .RCCXValues2, 1);
    try expect_violation(&run, .RCCXValues2, "_motor");
}

test "RCCXValues2 keeps interleaved curves separate" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_generator_curve"/>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_motor_curve"/>
        \\  <cim:SynchronousMachine rdf:ID="_generator">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_generator_curve"/>
        \\    <cim:SynchronousMachine.type rdf:resource="#SynchronousMachineKind.generator"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_motor">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_motor_curve"/>
        \\    <cim:SynchronousMachine.type rdf:resource="#SynchronousMachineKind.motor"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:CurveData rdf:ID="_g0">
        \\    <cim:CurveData.Curve rdf:resource="#_generator_curve"/>
        \\    <cim:CurveData.xvalue>0</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_m0">
        \\    <cim:CurveData.Curve rdf:resource="#_motor_curve"/>
        \\    <cim:CurveData.xvalue>0</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_g1">
        \\    <cim:CurveData.Curve rdf:resource="#_generator_curve"/>
        \\    <cim:CurveData.xvalue>1</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_m1">
        \\    <cim:CurveData.Curve rdf:resource="#_motor_curve"/>
        \\    <cim:CurveData.xvalue>1</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\</rdf:RDF>
    , .RCCXValues2);
    defer run.deinit();
    try expect_rule(&run, .RCCXValues2, 1);
    try expect_violation(&run, .RCCXValues2, "_motor");
}

test "RCCXValues2 ignores machines without a resolved reactive curve" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:Curve rdf:ID="_generic"/>
        \\  <cim:SynchronousMachine rdf:ID="_absent">
        \\    <cim:SynchronousMachine.type rdf:resource="#SynchronousMachineKind.condenser"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_dangling">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_missing"/>
        \\    <cim:SynchronousMachine.type rdf:resource="#SynchronousMachineKind.condenser"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_generic_curve">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_generic"/>
        \\    <cim:SynchronousMachine.type rdf:resource="#SynchronousMachineKind.condenser"/>
        \\  </cim:SynchronousMachine>
        \\</rdf:RDF>
    , .RCCXValues2);
    defer run.deinit();
    try expect_clean(&run);
}

// ── RCCXValues3 ──────────────────────────────────────────────────────────

fn rcc_x_bounds_case_xml(
    buffer: []u8,
    min_p: ?[]const u8,
    max_p: ?[]const u8,
    x_values: []const ?[]const u8,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("<rdf:RDF><cim:HydroGeneratingUnit rdf:ID=\"_unit\">");
    if (min_p) |value| {
        try writer.print(
            "<cim:GeneratingUnit.minOperatingP>{s}</cim:GeneratingUnit.minOperatingP>",
            .{value},
        );
    }
    if (max_p) |value| {
        try writer.print(
            "<cim:GeneratingUnit.maxOperatingP>{s}</cim:GeneratingUnit.maxOperatingP>",
            .{value},
        );
    }
    try writer.writeAll(
        "</cim:HydroGeneratingUnit>" ++
            "<cim:ReactiveCapabilityCurve rdf:ID=\"_curve\"/>" ++
            "<cim:SynchronousMachine rdf:ID=\"_machine\">" ++
            "<cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource=\"#_curve\"/>" ++
            "<cim:RotatingMachine.GeneratingUnit rdf:resource=\"#_unit\"/>" ++
            "</cim:SynchronousMachine>",
    );
    for (x_values, 0..) |x_value, i| {
        try writer.print(
            "<cim:CurveData rdf:ID=\"_point{d}\">" ++
                "<cim:CurveData.Curve rdf:resource=\"#_curve\"/>",
            .{i},
        );
        if (x_value) |value| {
            try writer.print(
                "<cim:CurveData.xvalue>{s}</cim:CurveData.xvalue>",
                .{value},
            );
        }
        try writer.writeAll("</cim:CurveData>");
    }
    try writer.writeAll("</rdf:RDF>");
    return writer.buffered();
}

test "RCCXValues3 accepts boundary and interior values for a generating-unit subtype" {
    var buffer: [4096]u8 = undefined;
    var run = try run_rule(
        try rcc_x_bounds_case_xml(&buffer, "-10", "20", &.{ "-10", "0", "20" }),
        .RCCXValues3,
    );
    defer run.deinit();
    try expect_clean(&run);
}

test "RCCXValues3 rejects values outside the generating-unit bounds once per machine" {
    const cases = [_][]const ?[]const u8{
        &.{ "-11", "0", "20" },
        &.{ "-10", "0", "21" },
        &.{ "-11", "21" },
    };
    var buffer: [4096]u8 = undefined;
    for (cases) |x_values| {
        var run = try run_rule(
            try rcc_x_bounds_case_xml(&buffer, "-10", "20", x_values),
            .RCCXValues3,
        );
        defer run.deinit();
        try expect_rule(&run, .RCCXValues3, 1);
        try expect_violation(&run, .RCCXValues3, "_machine");
    }
}

test "RCCXValues3 rejects unusable points and generating-unit bounds" {
    const Case = struct {
        min_p: ?[]const u8,
        max_p: ?[]const u8,
        x_values: []const ?[]const u8,
    };
    const cases = [_]Case{
        .{ .min_p = "-10", .max_p = "20", .x_values = &.{ "0", null } },
        .{ .min_p = "-10", .max_p = "20", .x_values = &.{ "0", "nan" } },
        .{ .min_p = null, .max_p = "20", .x_values = &.{"0"} },
        .{ .min_p = "-10", .max_p = "", .x_values = &.{"0"} },
    };
    var buffer: [4096]u8 = undefined;
    for (cases) |case| {
        var run = try run_rule(
            try rcc_x_bounds_case_xml(&buffer, case.min_p, case.max_p, case.x_values),
            .RCCXValues3,
        );
        defer run.deinit();
        try expect_rule(&run, .RCCXValues3, 1);
        try expect_violation(&run, .RCCXValues3, "_machine");
    }
}

test "RCCXValues3 evaluates machines sharing a curve against their own units" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:GeneratingUnit rdf:ID="_wide_unit">
        \\    <cim:GeneratingUnit.minOperatingP>-10</cim:GeneratingUnit.minOperatingP>
        \\    <cim:GeneratingUnit.maxOperatingP>20</cim:GeneratingUnit.maxOperatingP>
        \\  </cim:GeneratingUnit>
        \\  <cim:GeneratingUnit rdf:ID="_narrow_unit">
        \\    <cim:GeneratingUnit.minOperatingP>0</cim:GeneratingUnit.minOperatingP>
        \\    <cim:GeneratingUnit.maxOperatingP>10</cim:GeneratingUnit.maxOperatingP>
        \\  </cim:GeneratingUnit>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_curve"/>
        \\  <cim:SynchronousMachine rdf:ID="_wide_machine">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_curve"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_wide_unit"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_narrow_machine">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_curve"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_narrow_unit"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:CurveData rdf:ID="_low">
        \\    <cim:CurveData.Curve rdf:resource="#_curve"/>
        \\    <cim:CurveData.xvalue>-5</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_high">
        \\    <cim:CurveData.Curve rdf:resource="#_curve"/>
        \\    <cim:CurveData.xvalue>15</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\</rdf:RDF>
    , .RCCXValues3);
    defer run.deinit();
    try expect_rule(&run, .RCCXValues3, 1);
    try expect_violation(&run, .RCCXValues3, "_narrow_machine");
}

test "RCCXValues3 keeps interleaved curves separate" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:GeneratingUnit rdf:ID="_unit_a">
        \\    <cim:GeneratingUnit.minOperatingP>0</cim:GeneratingUnit.minOperatingP>
        \\    <cim:GeneratingUnit.maxOperatingP>10</cim:GeneratingUnit.maxOperatingP>
        \\  </cim:GeneratingUnit>
        \\  <cim:GeneratingUnit rdf:ID="_unit_b">
        \\    <cim:GeneratingUnit.minOperatingP>-10</cim:GeneratingUnit.minOperatingP>
        \\    <cim:GeneratingUnit.maxOperatingP>0</cim:GeneratingUnit.maxOperatingP>
        \\  </cim:GeneratingUnit>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_curve_a"/>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_curve_b"/>
        \\  <cim:SynchronousMachine rdf:ID="_machine_a">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_curve_a"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_unit_a"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_machine_b">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_curve_b"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_unit_b"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:CurveData rdf:ID="_a0">
        \\    <cim:CurveData.Curve rdf:resource="#_curve_a"/>
        \\    <cim:CurveData.xvalue>0</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_b0">
        \\    <cim:CurveData.Curve rdf:resource="#_curve_b"/>
        \\    <cim:CurveData.xvalue>-10</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_a1">
        \\    <cim:CurveData.Curve rdf:resource="#_curve_a"/>
        \\    <cim:CurveData.xvalue>10</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_b1">
        \\    <cim:CurveData.Curve rdf:resource="#_curve_b"/>
        \\    <cim:CurveData.xvalue>1</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\</rdf:RDF>
    , .RCCXValues3);
    defer run.deinit();
    try expect_rule(&run, .RCCXValues3, 1);
    try expect_violation(&run, .RCCXValues3, "_machine_b");
}

test "RCCXValues3 ignores machines outside its resolved relationship scope" {
    var run = try run_rule(
        \\<rdf:RDF>
        \\  <cim:GeneratingUnit rdf:ID="_unit">
        \\    <cim:GeneratingUnit.minOperatingP>0</cim:GeneratingUnit.minOperatingP>
        \\    <cim:GeneratingUnit.maxOperatingP>10</cim:GeneratingUnit.maxOperatingP>
        \\  </cim:GeneratingUnit>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_curve"/>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_empty_curve"/>
        \\  <cim:Curve rdf:ID="_generic_curve"/>
        \\  <cim:BaseVoltage rdf:ID="_wrong_unit"/>
        \\  <cim:SynchronousMachine rdf:ID="_no_curve">
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_unit"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_dangling_curve">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_missing"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_unit"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_wrong_curve">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_generic_curve"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_unit"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_no_unit">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_curve"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_dangling_unit">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_curve"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_missing"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_wrong_unit_type">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_curve"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_wrong_unit"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:SynchronousMachine rdf:ID="_no_points">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_empty_curve"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_unit"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:CurveData rdf:ID="_outside">
        \\    <cim:CurveData.Curve rdf:resource="#_curve"/>
        \\    <cim:CurveData.xvalue>20</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\</rdf:RDF>
    , .RCCXValues3);
    defer run.deinit();
    try expect_clean(&run);
}

test "RCCXValues2 and RCCXValues3 share point harvesting without duplicate rows" {
    var mask = qocdc.RuleMask.initEmpty();
    mask.insert(.RCCXValues2);
    mask.insert(.RCCXValues3);
    var run = try run_rules(
        \\<rdf:RDF>
        \\  <cim:GeneratingUnit rdf:ID="_unit">
        \\    <cim:GeneratingUnit.minOperatingP>0</cim:GeneratingUnit.minOperatingP>
        \\    <cim:GeneratingUnit.maxOperatingP>10</cim:GeneratingUnit.maxOperatingP>
        \\  </cim:GeneratingUnit>
        \\  <cim:ReactiveCapabilityCurve rdf:ID="_curve"/>
        \\  <cim:SynchronousMachine rdf:ID="_machine">
        \\    <cim:SynchronousMachine.InitialReactiveCapabilityCurve rdf:resource="#_curve"/>
        \\    <cim:RotatingMachine.GeneratingUnit rdf:resource="#_unit"/>
        \\    <cim:SynchronousMachine.type rdf:resource="#SynchronousMachineKind.generator"/>
        \\  </cim:SynchronousMachine>
        \\  <cim:CurveData rdf:ID="_zero">
        \\    <cim:CurveData.Curve rdf:resource="#_curve"/>
        \\    <cim:CurveData.xvalue>0</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\  <cim:CurveData rdf:ID="_high">
        \\    <cim:CurveData.Curve rdf:resource="#_curve"/>
        \\    <cim:CurveData.xvalue>20</cim:CurveData.xvalue>
        \\  </cim:CurveData>
        \\</rdf:RDF>
    , mask);
    defer run.deinit();
    try expect_rule(&run, .RCCXValues3, 1);
    try expect_violation(&run, .RCCXValues3, "_machine");
}
