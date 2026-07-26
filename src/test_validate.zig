//! End-to-end tests for SHACL validation (validate.zig): small EQ fixtures
//! with known violations, asserting rule code, message, file name, and line
//! number. Covers the corpus idioms beyond plain property checks: a
//! closed-shape violation, a forbidden-inverse (maxCount 0) hit, a
//! class-whitelist hit, and inverse-path cardinality via the referrer-count
//! pass.

const std = @import("std");
const cim = @import("cim/cim.zig");
const diagnostics_mod = cim.diagnostics;
const CimDocument = cim.CimDocument;
const RuleSet = @import("shacl/rule_set.zig").RuleSet;
const validate = @import("validate.zig");

const testing = std.testing;

// Line numbers below are asserted; keep the layout stable.
// _line1 opens on line 2, _line2 on line 7, _t1 on line 10,
// _b1 on line 14, _u1 on line 18.
const fixture_xml =
    \\<rdf:RDF>
    \\  <cim:ACLineSegment rdf:ID="_line1">
    \\    <cim:IdentifiedObject.name>L1</cim:IdentifiedObject.name>
    \\    <cim:ACLineSegment.r>abc</cim:ACLineSegment.r>
    \\    <cim:ACLineSegment.evil>1</cim:ACLineSegment.evil>
    \\  </cim:ACLineSegment>
    \\  <cim:ACLineSegment rdf:ID="_line2">
    \\    <cim:ACLineSegment.r>1.5</cim:ACLineSegment.r>
    \\  </cim:ACLineSegment>
    \\  <cim:Terminal rdf:ID="_t1">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_line1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_missing"/>
    \\  </cim:Terminal>
    \\  <cim:Breaker rdf:ID="_b1">
    \\    <cim:IdentifiedObject.name>B1</cim:IdentifiedObject.name>
    \\    <cim:Switch.kind rdf:resource="http://ex#SwitchKind.weird"/>
    \\  </cim:Breaker>
    \\  <cim:UnknownThing rdf:ID="_u1">
    \\    <cim:ACLineSegment.evil rdf:resource="#_line1"/>
    \\  </cim:UnknownThing>
    \\</rdf:RDF>
;

const fixture_rules =
    \\@prefix sh:  <http://www.w3.org/ns/shacl#> .
    \\@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
    \\@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    \\@prefix owl: <http://www.w3.org/2002/07/owl#> .
    \\@prefix cim: <https://cim.ucaiug.io/ns#> .
    \\@prefix ex:  <http://example.org/rules#> .
    \\
    \\ex:Ontology a owl:Ontology ; owl:versionInfo "1.0.0-fixture" .
    \\
    \\# Datatype + cardinality on ACLineSegment: _line1 has a non-float r,
    \\# _line2 misses the required name.
    \\ex:LineShape a sh:NodeShape ;
    \\    sh:targetClass cim:ACLineSegment ;
    \\    sh:property [ sh:path cim:ACLineSegment.r ; sh:nodeKind sh:Literal ;
    \\                  sh:datatype xsd:float ; sh:name "ACLineSegment.r-datatype" ;
    \\                  sh:message "r violates xsd:float." ] ;
    \\    sh:property [ sh:path cim:IdentifiedObject.name ; sh:minCount 1 ;
    \\                  sh:name "IdentifiedObject.name-cardinality" ;
    \\                  sh:message "Missing required name." ] .
    \\
    \\# Closed shape: ACLineSegment.evil is not part of the profile.
    \\ex:LineClosed a sh:NodeShape ;
    \\    sh:targetClass cim:ACLineSegment ;
    \\    sh:closed true ;
    \\    sh:ignoredProperties ( rdf:type ) ;
    \\    sh:severity sh:Info ;
    \\    sh:name "PropertyNotInProfile" ;
    \\    sh:message "This property is not part of the profile." ;
    \\    sh:property [ sh:path cim:IdentifiedObject.name ] ;
    \\    sh:property [ sh:path cim:ACLineSegment.r ] .
    \\
    \\# Enumeration on Switch.kind, targeting the parent class: Breaker must
    \\# match via the CIM subtype walk. Warning severity.
    \\ex:SwitchKindShape a sh:NodeShape ;
    \\    sh:targetClass cim:Switch ;
    \\    sh:property [ sh:path cim:Switch.kind ; sh:nodeKind sh:IRI ;
    \\                  sh:in ( cim:SwitchKind.breaker cim:SwitchKind.disconnector ) ;
    \\                  sh:severity sh:Warning ; sh:name "Switch.kind-enum" ;
    \\                  sh:message "Not a known SwitchKind." ] .
    \\
    \\# Association checks on Terminal: sh:class (dangling => violation) and
    \\# the (P rdf:type) + sh:in idiom (dangling => vacuous).
    \\ex:TerminalShape a sh:NodeShape ;
    \\    sh:targetClass cim:Terminal ;
    \\    sh:property [ sh:path cim:Terminal.ConnectivityNode ;
    \\                  sh:class cim:ConnectivityNode ;
    \\                  sh:name "Terminal.ConnectivityNode-class" ;
    \\                  sh:message "Must resolve to a ConnectivityNode." ] ;
    \\    sh:property [ sh:path ( cim:Terminal.ConnectivityNode rdf:type ) ;
    \\                  sh:in ( cim:ConnectivityNode ) ;
    \\                  sh:name "Terminal.ConnectivityNode-refType" ;
    \\                  sh:message "Referenced object has the wrong class." ] ;
    \\    sh:property [ sh:path ( cim:Terminal.ConductingEquipment rdf:type ) ;
    \\                  sh:in ( cim:ACLineSegment cim:Breaker ) ;
    \\                  sh:name "Terminal.ConductingEquipment-refType" ;
    \\                  sh:message "Referenced object has the wrong class." ] .
    \\
    \\# Class whitelist: UnknownThing is not in the profile.
    \\ex:AllowedClasses-property a sh:PropertyShape ;
    \\    sh:path rdf:type ;
    \\    sh:in ( cim:ACLineSegment cim:Terminal cim:Breaker ) ;
    \\    sh:severity sh:Info ;
    \\    sh:name "ClassNotInProfile" ;
    \\    sh:message "This class is not part of the profile." .
    \\ex:AllowedClasses a sh:NodeShape ;
    \\    sh:property ex:AllowedClasses-property ;
    \\    sh:targetSubjectsOf rdf:type .
    \\
    \\# Forbidden inverse association: both _line1 (text form) and _u1
    \\# (reference form) carry the forbidden property.
    \\ex:Inverse a sh:NodeShape ;
    \\    sh:targetSubjectsOf cim:ACLineSegment.evil ;
    \\    sh:property [ sh:path cim:ACLineSegment.evil ; sh:maxCount 0 ;
    \\                  sh:name "InverseAssociationPresent" ;
    \\                  sh:message "Inverse association is present." ] .
    \\
    \\# Inverse-path cardinality: _t1's Terminal.ConductingEquipment
    \\# references _line1; nobody references _line2.
    \\ex:LineTerminated a sh:NodeShape ;
    \\    sh:targetClass cim:ACLineSegment ;
    \\    sh:property [ sh:path [ sh:inversePath cim:Terminal.ConductingEquipment ] ;
    \\                  sh:minCount 1 ; sh:name "ACLineSegment.Terminal-inverseMin" ;
    \\                  sh:message "Conducting equipment needs a terminal." ] ;
    \\    sh:property [ sh:path [ sh:inversePath cim:Terminal.ConductingEquipment ] ;
    \\                  sh:maxCount 0 ; sh:severity sh:Warning ;
    \\                  sh:name "ACLineSegment.Terminal-inverseMax" ;
    \\                  sh:message "No terminal allowed here." ] .
    \\
    \\# One inert sparql rule, to exercise the honesty note.
    \\ex:SparqlShape a sh:NodeShape ;
    \\    sh:targetClass cim:Terminal ;
    \\    sh:name "C:FIXTURE:sparql" ;
    \\    sh:sparql ex:SparqlBody .
;

const Fixture = struct {
    model: CimDocument,
    rules: RuleSet,
    evaluation: validate.Evaluation,

    fn init(gpa: std.mem.Allocator) !Fixture {
        var model = try CimDocument.init(gpa, try gpa.dupe(u8, fixture_xml));
        errdefer model.deinit(gpa);
        var rules = try RuleSet.load(gpa, try gpa.dupe(u8, fixture_rules), "fixture.ttl", &.{}, null);
        errdefer rules.deinit(gpa);
        const evaluation = try validate.evaluate(gpa, &model, &rules);
        return .{ .model = model, .rules = rules, .evaluation = evaluation };
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.evaluation.deinit(gpa);
        self.rules.deinit(gpa);
        self.model.deinit(gpa);
    }

    /// Count violations whose rule code is `name`, optionally checking that
    /// each names the expected object.
    fn count_named(self: *const Fixture, name: []const u8, object_id: ?[]const u8) u32 {
        var count: u32 = 0;
        for (self.evaluation.violations.items) |violation| {
            const rule_name = if (violation.constraint == validate.constraint_none)
                self.rules.shapes[violation.shape].name
            else
                self.rules.constraints[violation.constraint].name;
            if (!std.mem.eql(u8, rule_name, name)) continue;
            if (object_id) |id| {
                if (!std.mem.eql(u8, violation.object_id, id)) continue;
            }
            count += 1;
        }
        return count;
    }
};

test "evaluate finds exactly the planted violations" {
    const gpa = testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    // Datatype: only _line1 ("abc" is not a float; 1.5 is).
    try testing.expectEqual(@as(u32, 1), fixture.count_named("ACLineSegment.r-datatype", "_line1"));
    try testing.expectEqual(@as(u32, 1), fixture.count_named("ACLineSegment.r-datatype", null));
    // Cardinality: only _line2 misses the name.
    try testing.expectEqual(@as(u32, 1), fixture.count_named("IdentifiedObject.name-cardinality", "_line2"));
    try testing.expectEqual(@as(u32, 1), fixture.count_named("IdentifiedObject.name-cardinality", null));
    // Closed shape: _line1's evil property, nothing else.
    try testing.expectEqual(@as(u32, 1), fixture.count_named("PropertyNotInProfile", "_line1"));
    try testing.expectEqual(@as(u32, 1), fixture.count_named("PropertyNotInProfile", null));
    // Enumeration via subtype targeting (Breaker is_a Switch).
    try testing.expectEqual(@as(u32, 1), fixture.count_named("Switch.kind-enum", "_b1"));
    // sh:class on a dangling reference violates...
    try testing.expectEqual(@as(u32, 1), fixture.count_named("Terminal.ConnectivityNode-class", "_t1"));
    // ...but the (P rdf:type) path over the same dangling reference yields
    // no value, so the in-check passes vacuously.
    try testing.expectEqual(@as(u32, 0), fixture.count_named("Terminal.ConnectivityNode-refType", null));
    // The resolvable reference's type is in the allowed set.
    try testing.expectEqual(@as(u32, 0), fixture.count_named("Terminal.ConductingEquipment-refType", null));
    // Class whitelist: only UnknownThing.
    try testing.expectEqual(@as(u32, 1), fixture.count_named("ClassNotInProfile", "_u1"));
    // Forbidden inverse: _line1 (text form) and _u1 (reference form).
    try testing.expectEqual(@as(u32, 1), fixture.count_named("InverseAssociationPresent", "_line1"));
    try testing.expectEqual(@as(u32, 1), fixture.count_named("InverseAssociationPresent", "_u1"));
    // Inverse-path cardinality: _t1 refers to _line1, nobody to _line2.
    try testing.expectEqual(@as(u32, 1), fixture.count_named("ACLineSegment.Terminal-inverseMin", "_line2"));
    try testing.expectEqual(@as(u32, 1), fixture.count_named("ACLineSegment.Terminal-inverseMin", null));
    try testing.expectEqual(@as(u32, 1), fixture.count_named("ACLineSegment.Terminal-inverseMax", "_line1"));
    try testing.expectEqual(@as(u32, 1), fixture.count_named("ACLineSegment.Terminal-inverseMax", null));

    // Nothing else fired: the sum of the planted hits is the whole list.
    try testing.expectEqual(@as(usize, 10), fixture.evaluation.violations.items.len);
    try testing.expectEqual(@as(u64, 0), fixture.evaluation.truncated);
}

test "report carries file:line, rule code, message, and honesty note" {
    const gpa = testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const totals = try validate.write_report(
        gpa,
        &out.writer,
        &fixture.model,
        &.{.{ .name = "eq.xml", .start = 0, .line_start = 1 }},
        &.{.{ .rules = &fixture.rules, .evaluation = &fixture.evaluation }},
        .{},
    );
    const report = out.written();

    // Severity totals drive the exit code: violations fail the run,
    // warnings and infos do not.
    try testing.expectEqual(@as(u64, 6), totals.violations);
    try testing.expectEqual(@as(u64, 2), totals.warnings);
    try testing.expectEqual(@as(u64, 2), totals.infos);
    try testing.expectEqual(@as(u64, 0), totals.truncated);

    // Header with provenance.
    try testing.expect(std.mem.indexOf(u8, report, "rules: fixture.ttl (version 1.0.0-fixture)") != null);

    // Report entries include data file name, object line number, rule code,
    // and message.
    try testing.expect(std.mem.indexOf(u8, report, "eq.xml:2: violation: ACLineSegment.r-datatype: r violates xsd:float. [abc] (object _line1)") != null);
    try testing.expect(std.mem.indexOf(u8, report, "eq.xml:7: violation: IdentifiedObject.name-cardinality: Missing required name. (object _line2)") != null);
    try testing.expect(std.mem.indexOf(u8, report, "eq.xml:2: info: PropertyNotInProfile: This property is not part of the profile. [ACLineSegment.evil] (object _line1)") != null);
    try testing.expect(std.mem.indexOf(u8, report, "eq.xml:14: warning: Switch.kind-enum: Not a known SwitchKind. [SwitchKind.weird] (object _b1)") != null);
    try testing.expect(std.mem.indexOf(u8, report, "eq.xml:18: info: ClassNotInProfile: This class is not part of the profile. [UnknownThing] (object _u1)") != null);
    // Inverse cardinality violations carry the same traceability.
    try testing.expect(std.mem.indexOf(u8, report, "eq.xml:7: violation: ACLineSegment.Terminal-inverseMin: Conducting equipment needs a terminal. (object _line2)") != null);
    try testing.expect(std.mem.indexOf(u8, report, "eq.xml:2: warning: ACLineSegment.Terminal-inverseMax: No terminal allowed here. (object _line1)") != null);

    // The unchecked sparql rule is counted and named.
    try testing.expect(std.mem.indexOf(u8, report, "note: 1 rules not checked (1 sh:sparql); see --list-skipped") != null);
    try testing.expect(std.mem.indexOf(u8, report, "summary: 6 violations, 2 warnings, 2 info") != null);
    // Without --list-skipped, no per-rule skip lines.
    try testing.expect(std.mem.indexOf(u8, report, "skipped:") == null);
}

test "report --list-skipped names each unchecked rule" {
    const gpa = testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try validate.write_report(
        gpa,
        &out.writer,
        &fixture.model,
        &.{.{ .name = "eq.xml", .start = 0, .line_start = 1 }},
        &.{.{ .rules = &fixture.rules, .evaluation = &fixture.evaluation }},
        .{ .list_skipped = true },
    );
    try testing.expect(std.mem.indexOf(u8, out.written(), "skipped: C:FIXTURE:sparql (sh:sparql)") != null);
}

test "report resolves offsets into the correct data segment" {
    const gpa = testing.allocator;
    // Two concatenated documents, as --eqbd produces: the second segment's
    // violations must report the second file's name and a line local to it.
    const eq_part =
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_a">
        \\    <cim:IdentifiedObject.name>A</cim:IdentifiedObject.name>
        \\  </cim:ACLineSegment>
        \\</rdf:RDF>
        \\
    ;
    const eqbd_part =
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_b">
        \\    <cim:IdentifiedObject.name>B</cim:IdentifiedObject.name>
        \\  </cim:ACLineSegment>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try std.mem.concat(gpa, u8, &.{ eq_part, eqbd_part }));
    defer model.deinit(gpa);

    const rules_source =
        \\@prefix sh:  <http://www.w3.org/ns/shacl#> .
        \\@prefix cim: <https://cim.ucaiug.io/ns#> .
        \\@prefix ex:  <http://example.org/rules#> .
        \\ex:Shape a sh:NodeShape ;
        \\    sh:targetClass cim:ACLineSegment ;
        \\    sh:property [ sh:path cim:ACLineSegment.r ; sh:minCount 1 ;
        \\                  sh:name "r-required" ; sh:message "r is required." ] .
    ;
    var rules = try RuleSet.load(gpa, try gpa.dupe(u8, rules_source), "rules.ttl", &.{}, null);
    defer rules.deinit(gpa);

    var evaluation = try validate.evaluate(gpa, &model, &rules);
    defer evaluation.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), evaluation.violations.items.len);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try validate.write_report(
        gpa,
        &out.writer,
        &model,
        &.{
            .{ .name = "eq.xml", .start = 0, .line_start = 1 },
            .{
                .name = "eqbd.xml",
                .start = @intCast(eq_part.len),
                .line_start = diagnostics_mod.line_number_at(eq_part, @intCast(eq_part.len)),
            },
        },
        &.{.{ .rules = &rules, .evaluation = &evaluation }},
        .{},
    );
    const report = out.written();
    try testing.expect(std.mem.indexOf(u8, report, "eq.xml:2: violation: r-required") != null);
    try testing.expect(std.mem.indexOf(u8, report, "eqbd.xml:2: violation: r-required") != null);
}

test "node target evaluates exactly the named object" {
    const gpa = testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, fixture_xml));
    defer model.deinit(gpa);

    const rules_source =
        \\@prefix sh:  <http://www.w3.org/ns/shacl#> .
        \\@prefix cim: <https://cim.ucaiug.io/ns#> .
        \\@prefix ex:  <http://example.org/rules#> .
        \\ex:NodeShape1 a sh:NodeShape ;
        \\    sh:targetNode <#_line2> ;
        \\    sh:property [ sh:path cim:IdentifiedObject.name ; sh:minCount 1 ;
        \\                  sh:name "node-name-required" ] .
        \\ex:NodeShape2 a sh:NodeShape ;
        \\    sh:targetNode <#_does-not-exist> ;
        \\    sh:property [ sh:path cim:IdentifiedObject.name ; sh:minCount 1 ;
        \\                  sh:name "node-missing-target" ] .
    ;
    var rules = try RuleSet.load(gpa, try gpa.dupe(u8, rules_source), "rules.ttl", &.{}, null);
    defer rules.deinit(gpa);

    var evaluation = try validate.evaluate(gpa, &model, &rules);
    defer evaluation.deinit(gpa);

    // _line2 has no name: one violation. The unresolvable node target
    // matches nothing; valid, not an error.
    try testing.expectEqual(@as(usize, 1), evaluation.violations.items.len);
    const violation = evaluation.violations.items[0];
    try testing.expectEqualStrings("_line2", violation.object_id);
    try testing.expectEqualStrings("node-name-required", rules.constraints[violation.constraint].name);
}

test "rdf:about instance files (SSH/TP/SV) resolve references and referrers" {
    const gpa = testing.allocator;
    // Non-EQ instance files carry rdf:about="#_id" ids; sh:class resolution
    // and the referrer-count pass must match them against a reference's
    // hash-stripped local form.
    const xml =
        \\<rdf:RDF>
        \\  <cim:SvVoltage rdf:about="#_sv1">
        \\    <cim:SvVoltage.TopologicalNode rdf:resource="#_tn1"/>
        \\  </cim:SvVoltage>
        \\  <cim:TopologicalNode rdf:about="#_tn1">
        \\  </cim:TopologicalNode>
        \\  <cim:TopologicalNode rdf:about="#_tn2">
        \\  </cim:TopologicalNode>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const rules_source =
        \\@prefix sh:  <http://www.w3.org/ns/shacl#> .
        \\@prefix cim: <https://cim.ucaiug.io/ns#> .
        \\@prefix ex:  <http://example.org/rules#> .
        \\ex:SvShape a sh:NodeShape ;
        \\    sh:targetClass cim:SvVoltage ;
        \\    sh:property [ sh:path cim:SvVoltage.TopologicalNode ;
        \\                  sh:class cim:TopologicalNode ;
        \\                  sh:name "SvVoltage.TopologicalNode-class" ;
        \\                  sh:message "Must resolve to a TopologicalNode." ] .
        \\ex:TnShape a sh:NodeShape ;
        \\    sh:targetClass cim:TopologicalNode ;
        \\    sh:property [ sh:path [ sh:inversePath cim:SvVoltage.TopologicalNode ] ;
        \\                  sh:minCount 1 ; sh:name "TopologicalNode.SvVoltage-inverse" ;
        \\                  sh:message "Node lacks a voltage result." ] .
    ;
    var rules = try RuleSet.load(gpa, try gpa.dupe(u8, rules_source), "rules.ttl", &.{}, null);
    defer rules.deinit(gpa);

    var evaluation = try validate.evaluate(gpa, &model, &rules);
    defer evaluation.deinit(gpa);

    // The sh:class reference resolves (no violation); the inverse count
    // sees _tn1's referrer and misses one for _tn2 only.
    try testing.expectEqual(@as(usize, 1), evaluation.violations.items.len);
    const violation = evaluation.violations.items[0];
    try testing.expectEqualStrings("_tn2", violation.object_id);
    try testing.expectEqualStrings(
        "TopologicalNode.SvVoltage-inverse",
        rules.constraints[violation.constraint].name,
    );
}

test "escape-decoded and substitution-expanded messages flow into the report" {
    const gpa = testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, fixture_xml));
    defer model.deinit(gpa);

    const rules_source =
        \\@prefix sh:  <http://www.w3.org/ns/shacl#> .
        \\@prefix cim: <https://cim.ucaiug.io/ns#> .
        \\@prefix ex:  <http://example.org/rules#> .
        \\ex:Shape a sh:NodeShape ;
        \\    sh:targetClass cim:ACLineSegment ;
        \\    sh:property [ sh:path cim:IdentifiedObject.name ; sh:minCount 1 ;
        \\                  sh:name "name-required" ;
        \\                  sh:message "\"name\" must be at least EQ_NAME_MIN long." ] .
    ;
    const substitutions = [_]RuleSet.Substitution{
        .{ .name = "EQ_NAME_MIN", .value = "1 character" },
    };
    var rules = try RuleSet.load(
        gpa,
        try gpa.dupe(u8, rules_source),
        "rules.ttl",
        &substitutions,
        null,
    );
    defer rules.deinit(gpa);

    var evaluation = try validate.evaluate(gpa, &model, &rules);
    defer evaluation.deinit(gpa);
    // _line1 has a name; only _line2 violates.
    try testing.expectEqual(@as(usize, 1), evaluation.violations.items.len);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try validate.write_report(
        gpa,
        &out.writer,
        &model,
        &.{.{ .name = "eq.xml", .start = 0, .line_start = 1 }},
        &.{.{ .rules = &rules, .evaluation = &evaluation }},
        .{},
    );
    const report = out.written();
    // The Turtle \" escapes decoded and the constant expanded.
    try testing.expect(std.mem.indexOf(
        u8,
        report,
        "eq.xml:7: violation: name-required: \"name\" must be at least 1 character long.",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, report, "EQ_NAME_MIN") == null);
}

test "the QoCDC constant table reaches users as value and unit" {
    const gpa = testing.allocator;
    // The exact example from the QoCDC requirement: EQ_BRANCH_X_LIMIT
    // must report as "0.01 Ohm".
    const rules_source =
        \\@prefix sh:  <http://www.w3.org/ns/shacl#> .
        \\@prefix cim: <https://cim.ucaiug.io/ns#> .
        \\@prefix ex:  <http://example.org/rules#> .
        \\ex:Shape a sh:NodeShape ;
        \\    sh:targetClass cim:ACLineSegment ;
        \\    sh:property [ sh:path cim:ACLineSegment.x ; sh:minCount 1 ;
        \\                  sh:name "branch-x" ;
        \\                  sh:message "x is not >= EQ_BRANCH_X_LIMIT for a two-winding transformer." ] .
    ;
    var rules = try RuleSet.load(
        gpa,
        try gpa.dupe(u8, rules_source),
        "rules.ttl",
        &validate.qocdc_substitutions,
        null,
    );
    defer rules.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), rules.constraints.len);
    try testing.expectEqualStrings(
        "x is not >= 0.01 Ohm for a two-winding transformer.",
        rules.constraints[0].message,
    );
}

test "name interning: rule names absent from the document match no child" {
    const gpa = testing.allocator;

    // Every rule path below except IdentifiedObject.name is a name this
    // document never uses, so it interns to NameTable.absent. Absent must
    // behave exactly like "no such child": vacuous where a value is required,
    // firing where presence is required. A commented-out child must not
    // register either, in the closed-shape scan or the cardinality counts.
    const xml =
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_b1">
        \\    <cim:IdentifiedObject.name>B1</cim:IdentifiedObject.name>
        \\    <!-- <cim:Switch.absentHere>9</cim:Switch.absentHere> -->
        \\  </cim:Breaker>
        \\</rdf:RDF>
    ;
    const rules_source =
        \\@prefix sh:  <http://www.w3.org/ns/shacl#> .
        \\@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
        \\@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
        \\@prefix cim: <https://cim.ucaiug.io/ns#> .
        \\@prefix ex:  <http://example.org/rules#> .
        \\ex:Absent a sh:NodeShape ;
        \\    sh:targetClass cim:Breaker ;
        \\    sh:property [ sh:path cim:Switch.absentHere ; sh:minCount 1 ;
        \\                  sh:name "absent-min" ; sh:message "m" ] ;
        \\    sh:property [ sh:path cim:Switch.absentHere ; sh:maxCount 0 ;
        \\                  sh:name "absent-max" ; sh:message "m" ] ;
        \\    sh:property [ sh:path cim:Switch.absentHere ; sh:datatype xsd:float ;
        \\                  sh:name "absent-datatype" ; sh:message "m" ] ;
        \\    sh:property [ sh:path cim:IdentifiedObject.name ; sh:minCount 1 ;
        \\                  sh:name "present-min" ; sh:message "m" ] .
        \\# Closed shape whose allowed set is entirely absent from the document,
        \\# plus the one name that is present.
        \\ex:Closed a sh:NodeShape ;
        \\    sh:targetClass cim:Breaker ;
        \\    sh:closed true ;
        \\    sh:name "closed-absent" ;
        \\    sh:message "m" ;
        \\    sh:property [ sh:path cim:Switch.absentHere ] ;
        \\    sh:property [ sh:path cim:IdentifiedObject.name ] .
    ;

    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);
    var rules = try RuleSet.load(gpa, try gpa.dupe(u8, rules_source), "fixture.ttl", &.{}, null);
    defer rules.deinit(gpa);
    var evaluation = try validate.evaluate(gpa, &model, &rules);
    defer evaluation.deinit(gpa);

    var absent_min: u32 = 0;
    var others: u32 = 0;
    for (evaluation.violations.items) |violation| {
        const rule_name = if (violation.constraint == validate.constraint_none)
            rules.shapes[violation.shape].name
        else
            rules.constraints[violation.constraint].name;
        if (std.mem.eql(u8, rule_name, "absent-min")) absent_min += 1 else others += 1;
    }

    // minCount 1 on an absent name fires once, for _b1.
    try testing.expectEqual(@as(u32, 1), absent_min);
    // maxCount 0 and the datatype check are vacuous; the present name
    // satisfies its minCount; and the comment is neither a closed-shape
    // violation nor a value for Switch.absentHere.
    try testing.expectEqual(@as(u32, 0), others);
}

test "a subjects-of shape reports nothing when the document lacks its target property" {
    const gpa = testing.allocator;

    // The three shapes below carry the *same* constraint and differ only in
    // what they target, which is what makes the first one's silence meaningful
    // rather than incidental: _b2 has no Switch.kind, so any shape that
    // actually reaches it fires.
    //
    // This is the invariant `evaluate_shape` skips the sweep on. A subjects-of
    // shape targets the subjects of one predicate, so a document containing
    // that predicate nowhere has an empty target set and can produce no
    // result -- SHACL semantics, not an implementation shortcut. Getting the
    // skip wrong in the other direction is the real risk, so the live target
    // and the rdf:type idiom are checked here too.
    const xml =
        \\<rdf:RDF>
        \\  <cim:Breaker rdf:ID="_b1">
        \\    <cim:IdentifiedObject.name>B1</cim:IdentifiedObject.name>
        \\    <cim:Switch.kind rdf:resource="http://ex#SwitchKind.gasInsulated"/>
        \\  </cim:Breaker>
        \\  <cim:Breaker rdf:ID="_b2">
        \\    <cim:IdentifiedObject.name>B2</cim:IdentifiedObject.name>
        \\  </cim:Breaker>
        \\</rdf:RDF>
    ;
    const rules_source =
        \\@prefix sh:  <http://www.w3.org/ns/shacl#> .
        \\@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
        \\@prefix cim: <https://cim.ucaiug.io/ns#> .
        \\@prefix ex:  <http://example.org/rules#> .
        \\# Target property absent from the document: no subjects, no findings.
        \\ex:Dead a sh:NodeShape ;
        \\    sh:targetSubjectsOf cim:Switch.absentHere ;
        \\    sh:property [ sh:path cim:Switch.kind ; sh:minCount 1 ;
        \\                  sh:name "dead-sweep" ; sh:message "m" ] .
        \\# Target property present on both objects: _b2 fires.
        \\ex:Live a sh:NodeShape ;
        \\    sh:targetSubjectsOf cim:IdentifiedObject.name ;
        \\    sh:property [ sh:path cim:Switch.kind ; sh:minCount 1 ;
        \\                  sh:name "live-sweep" ; sh:message "m" ] .
        \\# rdf:type is the "every object" idiom, and is never a child tag --
        \\# it must not be mistaken for a property the document lacks.
        \\ex:Typed a sh:NodeShape ;
        \\    sh:targetSubjectsOf rdf:type ;
        \\    sh:property [ sh:path cim:Switch.kind ; sh:minCount 1 ;
        \\                  sh:name "type-sweep" ; sh:message "m" ] .
    ;

    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);
    var rules = try RuleSet.load(gpa, try gpa.dupe(u8, rules_source), "fixture.ttl", &.{}, null);
    defer rules.deinit(gpa);
    var evaluation = try validate.evaluate(gpa, &model, &rules);
    defer evaluation.deinit(gpa);

    var dead: u32 = 0;
    var live: u32 = 0;
    var typed: u32 = 0;
    for (evaluation.violations.items) |violation| {
        const rule_name = rules.constraints[violation.constraint].name;
        if (std.mem.eql(u8, rule_name, "dead-sweep")) dead += 1;
        if (std.mem.eql(u8, rule_name, "live-sweep")) live += 1;
        if (std.mem.eql(u8, rule_name, "type-sweep")) typed += 1;
    }

    try testing.expectEqual(@as(u32, 0), dead);
    // Both reach _b2 and only _b2, so neither skipped a shape it owed work.
    try testing.expectEqual(@as(u32, 1), live);
    try testing.expectEqual(@as(u32, 1), typed);
}
