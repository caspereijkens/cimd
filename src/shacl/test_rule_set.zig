const std = @import("std");
const turtle = @import("turtle.zig");
const rule_set = @import("rule_set.zig");
const RuleSet = rule_set.RuleSet;

const testing = std.testing;

const golden_source =
    \\@prefix sh:    <http://www.w3.org/ns/shacl#> .
    \\@prefix rdf:   <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
    \\@prefix owl:   <http://www.w3.org/2002/07/owl#> .
    \\@prefix xsd:   <http://www.w3.org/2001/XMLSchema#> .
    \\@prefix cim:   <https://cim.ucaiug.io/ns#> .
    \\@prefix cim16: <http://iec.ch/TC57/2013/CIM-schema-cim16#> .
    \\@prefix cim17: <http://iec.ch/TC57/CIM100#> .
    \\@prefix ex:    <http://example.org/rules#> .
    \\
    \\ex:Ontology a owl:Ontology ;
    \\    owl:versionInfo "9.9.9-test" .
    \\
    \\# Named property shape, referenced by two node shapes.
    \\ex:Line.r-datatype a sh:PropertyShape ;
    \\    sh:path cim:ACLineSegment.r ;
    \\    sh:name "ACLineSegment.r-datatype" ;
    \\    sh:message "r must be a float." ;
    \\    sh:severity sh:Violation ;
    \\    sh:nodeKind sh:Literal ;
    \\    sh:datatype xsd:float .
    \\
    \\# Multi-class target: cim16/cim17 variants of one class dedupe.
    \\ex:LineShape a sh:NodeShape ;
    \\    sh:targetClass cim16:ACLineSegment , cim17:ACLineSegment , cim:Switch ;
    \\    sh:property ex:Line.r-datatype ;
    \\    sh:property [ sh:path cim:IdentifiedObject.name ; sh:minCount 1 ;
    \\                  sh:maxCount 1 ; sh:name "name-cardinality" ;
    \\                  sh:message "name required." ; sh:severity sh:Warning ] .
    \\
    \\ex:LineShape2 a sh:NodeShape ;
    \\    sh:targetClass cim:ACLineSegment ;
    \\    sh:property ex:Line.r-datatype .
    \\
    \\# Closed shape; allowed paths dedupe namespace variants.
    \\ex:SwitchClosed a sh:NodeShape ;
    \\    sh:targetClass cim:Switch ;
    \\    sh:closed true ;
    \\    sh:ignoredProperties ( rdf:type ) ;
    \\    sh:severity sh:Info ;
    \\    sh:message "Property not in profile." ;
    \\    sh:name "PropertyNotInProfile" ;
    \\    sh:property [ sh:path cim:Switch.normalOpen ] ;
    \\    sh:property [ sh:path cim16:IdentifiedObject.name ] ;
    \\    sh:property [ sh:path cim17:IdentifiedObject.name ] .
    \\
    \\# Enumeration values; variants dedupe.
    \\ex:BreakerKind a sh:NodeShape ;
    \\    sh:targetClass cim:Breaker ;
    \\    sh:property [ sh:path cim:Switch.kind ; sh:nodeKind sh:IRI ;
    \\                  sh:in ( cim16:SwitchKind.breaker cim17:SwitchKind.breaker
    \\                          cim:SwitchKind.disconnector ) ] .
    \\
    \\# Associations: sh:class (idiom 4a) and (P rdf:type) + sh:in (idiom 4b).
    \\ex:TerminalShape a sh:NodeShape ;
    \\    sh:targetClass cim:Terminal ;
    \\    sh:property [ sh:path cim:Terminal.ConductingEquipment ;
    \\                  sh:class cim:ConductingEquipment ] ;
    \\    sh:property [ sh:path ( cim:Terminal.ConnectivityNode rdf:type ) ;
    \\                  sh:in ( cim:ConnectivityNode ) ] .
    \\
    \\# Class whitelist: targetSubjectsOf rdf:type + own-type path.
    \\ex:AllowedClasses-property a sh:PropertyShape ;
    \\    sh:path rdf:type ;
    \\    sh:name "ClassNotInProfile" ;
    \\    sh:severity sh:Info ;
    \\    sh:in ( cim:ACLineSegment cim:Switch cim:Breaker cim:Terminal ) .
    \\ex:AllowedClasses a sh:NodeShape ;
    \\    sh:property ex:AllowedClasses-property ;
    \\    sh:targetSubjectsOf rdf:type .
    \\
    \\# Forbidden inverse association: subjects-of + maxCount 0.
    \\ex:Inverse a sh:NodeShape ;
    \\    sh:targetSubjectsOf cim:Foo.Bar ;
    \\    sh:property [ sh:path cim:Foo.Bar ; sh:maxCount 0 ;
    \\                  sh:name "InverseAssociationPresent" ] .
    \\
    \\# Inverse-path cardinality via alternativePath collapse.
    \\ex:InvCount a sh:NodeShape ;
    \\    sh:targetClass cim:Substation ;
    \\    sh:property [ sh:path [ sh:alternativePath (
    \\                    [ sh:inversePath cim16:VoltageLevel.Substation ]
    \\                    [ sh:inversePath cim17:VoltageLevel.Substation ] ) ] ;
    \\                  sh:minCount 1 ; sh:name "SubstationHasVoltageLevel" ] .
    \\
    \\# Zero-corpus-use checks kept for W3C-style files.
    \\ex:RangeShape a sh:NodeShape ;
    \\    sh:targetClass cim:BaseVoltage ;
    \\    sh:property [ sh:path cim:BaseVoltage.nominalVoltage ;
    \\                  sh:minInclusive 0.0 ; sh:maxInclusive 1000.0 ;
    \\                  sh:minExclusive -1.5 ; sh:maxExclusive 1.0e6 ] ;
    \\    sh:property [ sh:path cim:IdentifiedObject.description ;
    \\                  sh:minLength 1 ; sh:maxLength 32 ] ;
    \\    sh:property [ sh:path cim:Foo.fixed ; sh:hasValue "42" ] .
    \\
    \\ex:NodeTarget a sh:NodeShape ;
    \\    sh:targetNode <#_object-1> ;
    \\    sh:property [ sh:path cim:Foo.fixed ; sh:minCount 1 ] .
    \\
    \\# sh:sparql loads as unsupported; its body is not a shape.
    \\ex:SparqlShape a sh:NodeShape ;
    \\    sh:targetClass cim:ACLineSegment ;
    \\    sh:name "C:TEST:sparql" ;
    \\    sh:sparql ex:SparqlShape-body .
    \\ex:SparqlShape-body a sh:SPARQLConstraint ;
    \\    sh:message "cross-object" ;
    \\    sh:select """SELECT $this
    \\WHERE { }""" .
    \\
    \\# Published-typo case: sh:MinCount is named, not swallowed.
    \\ex:TypoShape a sh:NodeShape ;
    \\    sh:targetClass cim:Switch ;
    \\    sh:property [ sh:path cim:Switch.kind ; sh:MinCount 1 ;
    \\                  sh:name "C:TEST:typo" ] .
    \\
    \\# sh:deactivated true: skipping IS the SHACL semantics.
    \\ex:Deactivated a sh:NodeShape ;
    \\    sh:targetClass cim:Switch ;
    \\    sh:deactivated true ;
    \\    sh:property [ sh:path cim:Switch.kind ; sh:minCount 1 ] .
    \\
    \\# Unsupported target kind: reported, not silently skipped.
    \\ex:ObjectsOf a sh:NodeShape ;
    \\    sh:name "C:TEST:objectsOf" ;
    \\    sh:targetObjectsOf cim:Foo.Bar .
;

fn load_golden(gpa: std.mem.Allocator) !RuleSet {
    return RuleSet.load(gpa, golden_source, "golden.ttl", &.{}, null);
}

test "rule sets can share a borrowed subslice" {
    const gpa = testing.allocator;
    const storage = try gpa.dupe(u8, "prefix" ++ golden_source ++ "suffix");
    defer gpa.free(storage);
    const source = storage[6 .. 6 + golden_source.len];
    var first = try RuleSet.load(gpa, source, "first.ttl", &.{}, null);
    var second = RuleSet.load(gpa, source, "second.ttl", &.{}, null) catch |err| {
        first.deinit(gpa);
        return err;
    };
    defer second.deinit(gpa);
    first.deinit(gpa);
    try testing.expectEqualStrings(golden_source, second.source);
    try testing.expect(second.shapes.len > 0);
    try testing.expect(second.shapes[0].name.len > 0);
}

test "rule loading preserves borrowed input through allocation and parse failures" {
    const source =
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\<shape> a sh:NodeShape ; sh:targetClass <Switch> ;
        \\    sh:property [ sh:path <name> ; sh:minCount 1 ; sh:message "say \"name\"" ] .
    ;
    try testing.checkAllAllocationFailures(testing.allocator, load_borrowed_rules, .{ source, null });
    try testing.checkAllAllocationFailures(testing.allocator, load_borrowed_rules, .{
        "unknown:shape unknown:property unknown:value .", error.UnknownPrefix,
    });
}

fn load_borrowed_rules(gpa: std.mem.Allocator, source: []const u8, expected_error: ?anyerror) !void {
    if (RuleSet.load(gpa, source, "borrowed.ttl", &.{}, null)) |loaded| {
        var rules = loaded;
        defer rules.deinit(gpa);
        try testing.expect(expected_error == null);
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try testing.expectEqual(expected_error orelse return err, err);
    }
}

fn shapes_named(rules: *const RuleSet, name: []const u8, out: []RuleSet.Shape) []RuleSet.Shape {
    var count: usize = 0;
    for (rules.shapes) |shape| {
        if (!std.mem.eql(u8, shape.name, name)) continue;
        out[count] = shape;
        count += 1;
    }
    return out[0..count];
}

fn constraints_of(rules: *const RuleSet, shape: RuleSet.Shape) []const RuleSet.Constraint {
    return rules.constraints[shape.constraints.start .. shape.constraints.start + shape.constraints.len];
}

test "golden: table sizes, class index, and provenance" {
    const gpa = testing.allocator;
    var rules = try load_golden(gpa);
    defer rules.deinit(gpa);

    try testing.expectEqualStrings("9.9.9-test", rules.version);
    try testing.expectEqual(@as(usize, 0), rules.strings.len);

    try testing.expectEqual(@as(u32, 10), rules.class_targeted_count);
    try testing.expectEqual(@as(usize, 13), rules.shapes.len);

    try testing.expectEqual(@as(u32, 6), rules.class_index.count());
    try testing.expectEqual(@as(u32, 3), rules.class_index.get("ACLineSegment").?.len);
    try testing.expectEqual(@as(u32, 3), rules.class_index.get("Switch").?.len);
    try testing.expectEqual(@as(u32, 1), rules.class_index.get("Breaker").?.len);
    try testing.expectEqual(@as(u32, 1), rules.class_index.get("Terminal").?.len);
    try testing.expectEqual(@as(u32, 1), rules.class_index.get("Substation").?.len);
    try testing.expectEqual(@as(u32, 1), rules.class_index.get("BaseVoltage").?.len);

    try testing.expectEqual(@as(usize, 21), rules.constraints.len);
    try testing.expectEqual(@as(usize, 7), rules.in_values.len);
    try testing.expectEqual(@as(usize, 2), rules.closed_paths.len);

    var it = rules.class_index.iterator();
    var covered: u32 = 0;
    while (it.next()) |entry| {
        const range = entry.value_ptr.*;
        covered += range.len;
        for (rules.shapes[range.start .. range.start + range.len]) |shape| {
            try testing.expectEqualStrings(entry.key_ptr.*, shape.target.class);
        }
    }
    try testing.expectEqual(rules.class_targeted_count, covered);
}

test "golden: multi-class flattening shares one constraint range" {
    const gpa = testing.allocator;
    var rules = try load_golden(gpa);
    defer rules.deinit(gpa);

    var buf: [4]RuleSet.Shape = undefined;
    const line_shapes = shapes_named(&rules, "LineShape", &buf);
    try testing.expectEqual(@as(usize, 2), line_shapes.len);
    try testing.expectEqual(line_shapes[0].constraints.start, line_shapes[1].constraints.start);
    try testing.expectEqual(@as(u32, 4), line_shapes[0].constraints.len);

    var found_switch = false;
    var found_line = false;
    for (line_shapes) |shape| {
        if (std.mem.eql(u8, shape.target.class, "Switch")) found_switch = true;
        if (std.mem.eql(u8, shape.target.class, "ACLineSegment")) found_line = true;
    }
    try testing.expect(found_switch);
    try testing.expect(found_line);

    const constraints = constraints_of(&rules, line_shapes[0]);
    try testing.expectEqualStrings("ACLineSegment.r-datatype", constraints[0].name);
    try testing.expectEqualStrings("ACLineSegment.r", constraints[0].path);
    try testing.expectEqual(RuleSet.PathKind.direct, constraints[0].path_kind);
    try testing.expect(constraints[0].check == .node_kind);
    try testing.expectEqual(RuleSet.NodeKind.literal, constraints[0].check.node_kind);
    try testing.expect(constraints[1].check == .datatype);
    try testing.expectEqual(RuleSet.Datatype.float, constraints[1].check.datatype);
    try testing.expectEqualStrings("r must be a float.", constraints[1].message);

    try testing.expectEqualStrings("name-cardinality", constraints[2].name);
    try testing.expectEqual(RuleSet.Severity.warning, constraints[2].severity);
    try testing.expect(constraints[2].check == .min_count);
    try testing.expectEqual(@as(u32, 1), constraints[2].check.min_count);
    try testing.expect(constraints[3].check == .max_count);

    var buf2: [4]RuleSet.Shape = undefined;
    const line2 = shapes_named(&rules, "LineShape2", &buf2);
    try testing.expectEqual(@as(usize, 1), line2.len);
    try testing.expectEqual(@as(u32, 2), line2[0].constraints.len);
    try testing.expect(line2[0].constraints.start != line_shapes[0].constraints.start);
}

test "golden: closed shape with sorted deduped allowed paths" {
    const gpa = testing.allocator;
    var rules = try load_golden(gpa);
    defer rules.deinit(gpa);

    var buf: [4]RuleSet.Shape = undefined;
    const closed = shapes_named(&rules, "PropertyNotInProfile", &buf);
    try testing.expectEqual(@as(usize, 1), closed.len);
    try testing.expectEqualStrings("Switch", closed[0].target.class);
    try testing.expectEqual(RuleSet.Severity.info, closed[0].severity);
    try testing.expectEqualStrings("Property not in profile.", closed[0].message);
    try testing.expectEqual(@as(u32, 0), closed[0].constraints.len);

    const allowed = rules.closed_paths_of(closed[0]);
    try testing.expectEqual(@as(usize, 2), allowed.len);
    try testing.expectEqualStrings("IdentifiedObject.name", allowed[0]);
    try testing.expectEqualStrings("Switch.normalOpen", allowed[1]);
}

test "golden: enumeration and association checks" {
    const gpa = testing.allocator;
    var rules = try load_golden(gpa);
    defer rules.deinit(gpa);

    var buf: [4]RuleSet.Shape = undefined;
    const breaker = shapes_named(&rules, "BreakerKind", &buf);
    try testing.expectEqual(@as(usize, 1), breaker.len);
    const breaker_constraints = constraints_of(&rules, breaker[0]);
    try testing.expectEqual(@as(usize, 2), breaker_constraints.len);
    try testing.expect(breaker_constraints[0].check == .node_kind);
    try testing.expect(breaker_constraints[1].check == .in);
    const kinds = rules.in_values_of(breaker_constraints[1]);
    try testing.expectEqual(@as(usize, 2), kinds.len);
    try testing.expectEqualStrings("SwitchKind.breaker", kinds[0]);
    try testing.expectEqualStrings("SwitchKind.disconnector", kinds[1]);

    const terminal = shapes_named(&rules, "TerminalShape", &buf);
    const terminal_constraints = constraints_of(&rules, terminal[0]);
    try testing.expectEqual(@as(usize, 2), terminal_constraints.len);
    try testing.expect(terminal_constraints[0].check == .class);
    try testing.expectEqualStrings("ConductingEquipment", terminal_constraints[0].check.class);
    try testing.expectEqual(RuleSet.PathKind.ref_type, terminal_constraints[1].path_kind);
    try testing.expectEqualStrings("Terminal.ConnectivityNode", terminal_constraints[1].path);
    try testing.expect(terminal_constraints[1].check == .in);
    const classes = rules.in_values_of(terminal_constraints[1]);
    try testing.expectEqual(@as(usize, 1), classes.len);
    try testing.expectEqualStrings("ConnectivityNode", classes[0]);
}

test "golden: subjects-of, own-type whitelist, node target, inverse path" {
    const gpa = testing.allocator;
    var rules = try load_golden(gpa);
    defer rules.deinit(gpa);

    var buf: [4]RuleSet.Shape = undefined;
    const whitelist = shapes_named(&rules, "AllowedClasses", &buf);
    try testing.expectEqual(@as(usize, 1), whitelist.len);
    try testing.expectEqualStrings("rdf:type", whitelist[0].target.subjects_of);
    const whitelist_constraints = constraints_of(&rules, whitelist[0]);
    try testing.expectEqual(@as(usize, 1), whitelist_constraints.len);
    try testing.expectEqualStrings("ClassNotInProfile", whitelist_constraints[0].name);
    try testing.expectEqual(RuleSet.PathKind.own_type, whitelist_constraints[0].path_kind);
    try testing.expectEqual(RuleSet.Severity.info, whitelist_constraints[0].severity);
    try testing.expectEqual(@as(usize, 4), rules.in_values_of(whitelist_constraints[0]).len);

    const inverse = shapes_named(&rules, "Inverse", &buf);
    try testing.expectEqualStrings("Foo.Bar", inverse[0].target.subjects_of);
    const inverse_constraints = constraints_of(&rules, inverse[0]);
    try testing.expectEqualStrings("InverseAssociationPresent", inverse_constraints[0].name);
    try testing.expect(inverse_constraints[0].check == .max_count);
    try testing.expectEqual(@as(u32, 0), inverse_constraints[0].check.max_count);

    const node_target = shapes_named(&rules, "NodeTarget", &buf);
    try testing.expectEqualStrings("_object-1", node_target[0].target.node);

    const inv_count = shapes_named(&rules, "InvCount", &buf);
    const inv_constraints = constraints_of(&rules, inv_count[0]);
    try testing.expectEqual(@as(usize, 1), inv_constraints.len);
    try testing.expectEqual(RuleSet.PathKind.inverse, inv_constraints[0].path_kind);
    try testing.expectEqualStrings("VoltageLevel.Substation", inv_constraints[0].path);
    try testing.expect(inv_constraints[0].check == .min_count);
}

test "golden: every remaining Check variant compiles" {
    const gpa = testing.allocator;
    var rules = try load_golden(gpa);
    defer rules.deinit(gpa);

    var buf: [4]RuleSet.Shape = undefined;
    const range_shape = shapes_named(&rules, "RangeShape", &buf);
    const constraints = constraints_of(&rules, range_shape[0]);
    try testing.expectEqual(@as(usize, 7), constraints.len);
    try testing.expectEqual(@as(f64, 0.0), constraints[0].check.min_inclusive);
    try testing.expectEqual(@as(f64, 1000.0), constraints[1].check.max_inclusive);
    try testing.expectEqual(@as(f64, -1.5), constraints[2].check.min_exclusive);
    try testing.expectEqual(@as(f64, 1.0e6), constraints[3].check.max_exclusive);
    try testing.expectEqual(@as(u32, 1), constraints[4].check.min_length);
    try testing.expectEqual(@as(u32, 32), constraints[5].check.max_length);
    try testing.expectEqualStrings("42", constraints[6].check.has_value);
}

test "golden: unsupported rules are counted and named" {
    const gpa = testing.allocator;
    var rules = try load_golden(gpa);
    defer rules.deinit(gpa);

    try testing.expectEqual(@as(usize, 3), rules.unsupported.len);
    var found_sparql = false;
    var found_typo = false;
    var found_objects_of = false;
    for (rules.unsupported) |entry| {
        if (std.mem.eql(u8, entry.component, "sparql")) {
            try testing.expectEqualStrings("C:TEST:sparql", entry.name);
            found_sparql = true;
        }
        if (std.mem.eql(u8, entry.component, "MinCount")) {
            try testing.expectEqualStrings("C:TEST:typo", entry.name);
            found_typo = true;
        }
        if (std.mem.eql(u8, entry.component, "targetObjectsOf")) {
            try testing.expectEqualStrings("C:TEST:objectsOf", entry.name);
            found_objects_of = true;
        }
    }
    try testing.expect(found_sparql);
    try testing.expect(found_typo);
    try testing.expect(found_objects_of);
}

test "value checks on inverse paths load as unsupported" {
    const gpa = testing.allocator;
    const source =
        \\@prefix sh:  <http://www.w3.org/ns/shacl#> .
        \\@prefix cim: <https://cim.ucaiug.io/ns#> .
        \\@prefix ex:  <http://example.org/rules#> .
        \\ex:Shape a sh:NodeShape ;
        \\    sh:targetClass cim:ACLineSegment ;
        \\    sh:property [ sh:path [ sh:inversePath cim:Terminal.ConductingEquipment ] ;
        \\                  sh:maxCount 0 ; sh:in ( cim:Terminal ) ;
        \\                  sh:name "C:TEST:inverse-in" ] .
    ;
    var rules = try RuleSet.load(gpa, source, "inverse.ttl", &.{}, null);
    defer rules.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), rules.constraints.len);
    try testing.expect(rules.constraints[0].check == .max_count);
    try testing.expectEqual(@as(usize, 1), rules.unsupported.len);
    try testing.expectEqualStrings("in", rules.unsupported[0].component);
    try testing.expectEqualStrings("C:TEST:inverse-in", rules.unsupported[0].name);
}

test "load reports the offending line for parse errors" {
    const gpa = testing.allocator;
    const source =
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\
        \\sh:x nope:y sh:z .
    ;
    var diagnostics: RuleSet.Diagnostics = .{};
    try testing.expectError(
        error.UnknownPrefix,
        RuleSet.load(gpa, source, "bad.ttl", &.{}, &diagnostics),
    );
    try testing.expectEqual(@as(u32, 3), diagnostics.line);
}

test "load rejects oversized rule sets" {
    const gpa = testing.allocator;
    const source = try gpa.alloc(u8, rule_set.rules_bytes_max + 1);
    defer gpa.free(source);
    @memset(source, ' ');
    try testing.expectError(
        error.RuleSetTooLarge,
        RuleSet.load(gpa, source, "huge.ttl", &.{}, null),
    );
}

test "escaped string literals decode at load; untouched strings stay in source" {
    const gpa = testing.allocator;
    const source =
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\@prefix cim: <http://cim#> .
        \\@prefix ex: <http://ex#> .
        \\
        \\ex:Esc a sh:NodeShape ;
        \\    sh:targetClass cim:Switch ;
        \\    sh:message "closed\nshape" ;
        \\    sh:property [ sh:path cim:Switch.kind ;
        \\                  sh:name "C:TEST:esc\u0041" ;
        \\                  sh:message "say \"no\" \\ once" ;
        \\                  sh:hasValue "A\tB" ;
        \\                  sh:minCount 1 ] .
    ;
    var rules = try RuleSet.load(gpa, source, "esc.ttl", &.{}, null);
    defer rules.deinit(gpa);

    try testing.expect(rules.strings.len > 0);
    try testing.expectEqual(@as(usize, 1), rules.shapes.len);
    const shape = rules.shapes[0];
    try testing.expectEqualStrings("closed\nshape", shape.message);
    const constraints = constraints_of(&rules, shape);
    try testing.expectEqual(@as(usize, 2), constraints.len); // hasValue + minCount
    for (constraints) |constraint| {
        try testing.expectEqualStrings("C:TEST:escA", constraint.name);
        try testing.expectEqualStrings("say \"no\" \\ once", constraint.message);
        if (constraint.check == .has_value) {
            try testing.expectEqualStrings("A\tB", constraint.check.has_value);
        }
    }
    try testing.expectEqualStrings("Esc", shape.name);
    const name_addr = @intFromPtr(shape.name.ptr);
    try testing.expect(name_addr >= @intFromPtr(rules.source.ptr));
    try testing.expect(name_addr < @intFromPtr(rules.source.ptr) + rules.source.len);
}

test "sh:in lists re-sort after escape decoding" {
    const gpa = testing.allocator;
    const source =
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\@prefix cim: <http://cim#> .
        \\@prefix ex: <http://ex#> .
        \\
        \\ex:InEsc a sh:NodeShape ;
        \\    sh:targetClass cim:Switch ;
        \\    sh:property [ sh:path cim:Switch.kind ;
        \\                  sh:in ( "a\u0021" "aZ" ) ;
        \\                  sh:name "C:TEST:in-esc" ] .
    ;
    var rules = try RuleSet.load(gpa, source, "in-esc.ttl", &.{}, null);
    defer rules.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), rules.constraints.len);
    const values = rules.in_values_of(rules.constraints[0]);
    try testing.expectEqual(@as(usize, 2), values.len);
    try testing.expectEqualStrings("a!", values[0]);
    try testing.expectEqualStrings("aZ", values[1]);
}

test "substitution table expands message constants at load" {
    const gpa = testing.allocator;
    const source =
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\@prefix cim: <http://cim#> .
        \\@prefix ex: <http://ex#> .
        \\
        \\ex:Limit a sh:NodeShape ;
        \\    sh:targetClass cim:ACLineSegment ;
        \\    sh:property [ sh:path cim:ACLineSegment.x ;
        \\                  sh:message "x below EQ_BRANCH_X_LIMIT, name over EQ_NAME_LEN; EQ_BRANCH_X_LIMIT is firm." ;
        \\                  sh:name "C:TEST:limit" ;
        \\                  sh:minCount 1 ] ;
        \\    sh:property [ sh:path cim:ACLineSegment.r ;
        \\                  sh:message "self-contained message" ;
        \\                  sh:name "C:TEST:plain" ;
        \\                  sh:minCount 1 ] .
    ;
    const substitutions = [_]RuleSet.Substitution{
        .{ .name = "EQ_BRANCH_X_LIMIT", .value = "0.01 Ohm" },
        .{ .name = "EQ_NAME_LEN", .value = "32 characters" },
    };
    var rules = try RuleSet.load(gpa, source, "subst.ttl", &substitutions, null);
    defer rules.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), rules.constraints.len);
    for (rules.constraints) |constraint| {
        if (std.mem.eql(u8, constraint.name, "C:TEST:limit")) {
            try testing.expectEqualStrings(
                "x below 0.01 Ohm, name over 32 characters; 0.01 Ohm is firm.",
                constraint.message,
            );
        } else {
            try testing.expectEqualStrings("self-contained message", constraint.message);
            const addr = @intFromPtr(constraint.message.ptr);
            try testing.expect(addr >= @intFromPtr(rules.source.ptr));
            try testing.expect(addr < @intFromPtr(rules.source.ptr) + rules.source.len);
        }
    }
}

test "substitution expansion past message_bytes_max is MessageTooLong" {
    const gpa = testing.allocator;
    const source =
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\@prefix cim: <http://cim#> .
        \\@prefix ex: <http://ex#> .
        \\
        \\ex:Blowup a sh:NodeShape ;
        \\    sh:targetClass cim:Switch ;
        \\    sh:property [ sh:path cim:Switch.kind ;
        \\                  sh:message "XX" ; sh:minCount 1 ] .
    ;
    const big = "a" ** rule_set.message_bytes_max;
    const substitutions = [_]RuleSet.Substitution{.{ .name = "X", .value = big }};
    var diagnostics: RuleSet.Diagnostics = .{};
    try testing.expectError(
        error.MessageTooLong,
        RuleSet.load(gpa, source, "blowup.ttl", &substitutions, &diagnostics),
    );
    try testing.expectEqual(@as(u32, 8), diagnostics.line);
}

test "a \\U escape naming an impossible codepoint fails the load with its line" {
    const gpa = testing.allocator;
    const source =
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\@prefix cim: <http://cim#> .
        \\@prefix ex: <http://ex#> .
        \\
        \\ex:Bad a sh:NodeShape ;
        \\    sh:targetClass cim:Switch ;
        \\    sh:property [ sh:path cim:Switch.kind ;
        \\                  sh:message "bad \UFFFFFFFF" ; sh:minCount 1 ] .
    ;
    var diagnostics: RuleSet.Diagnostics = .{};
    try testing.expectError(
        error.InvalidEscape,
        RuleSet.load(gpa, source, "badcp.ttl", &.{}, &diagnostics),
    );
    try testing.expectEqual(@as(u32, 8), diagnostics.line);
}

test "corpus smoke: pinned aggregate counts across the published rule sets" {
    const corpus_path = "testdata/shacl-corpus";
    const gpa = testing.allocator;
    const io = testing.io;

    var dir = std.Io.Dir.cwd().openDir(io, corpus_path, .{ .iterate = true }) catch |err|
        switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
    defer dir.close(io);

    var totals: struct {
        files: u32 = 0,
        broken: u32 = 0,
        shapes: u64 = 0,
        constraints: u64 = 0,
        unsupported: u64 = 0,
        sparql: u64 = 0,
        typo: u64 = 0,
    } = .{};

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ttl")) continue;
        totals.files += 1;

        const file = try dir.openFile(io, entry.name, .{});
        defer file.close(io);
        var file_reader = file.reader(io, &.{});
        const source = try file_reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(source);

        var diagnostics: RuleSet.Diagnostics = .{};
        var rules = RuleSet.load(gpa, source, entry.name, &.{}, &diagnostics) catch |err| {
            try testing.expectEqual(RuleSet.LoadError.UnknownPrefix, err);
            totals.broken += 1;
            continue;
        };
        defer rules.deinit(gpa);

        try testing.expect(rules.version.len > 0); // Published corpus carries provenance.
        try testing.expectEqual(@as(usize, 0), rules.strings.len);
        totals.shapes += rules.shapes.len;
        totals.constraints += rules.constraints.len;
        totals.unsupported += rules.unsupported.len;
        for (rules.unsupported) |unsupported| {
            if (std.mem.eql(u8, unsupported.component, "sparql")) totals.sparql += 1;
            if (std.mem.eql(u8, unsupported.component, "MinCount")) totals.typo += 1;
        }
    }

    try testing.expectEqual(@as(u32, 28), totals.files);
    try testing.expectEqual(@as(u32, 1), totals.broken);
    try testing.expectEqual(@as(u64, 58), totals.sparql);
    try testing.expectEqual(@as(u64, 1), totals.typo);
    try testing.expectEqual(@as(u64, 1_945), totals.shapes);
    try testing.expectEqual(@as(u64, 12_772), totals.constraints);
    try testing.expectEqual(@as(u64, 62), totals.unsupported);
}
