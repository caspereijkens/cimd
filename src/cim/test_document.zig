const std = @import("std");
const CimDocument = @import("document.zig").CimDocument;

test "CimDocument.init - parses all top-level CIM objects" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:IdentifiedObject.name>380kV</cim:IdentifiedObject.name>
        \\  </cim:VoltageLevel>
        \\  <cim:Substation rdf:ID="_SS2">
        \\    <cim:IdentifiedObject.name>South Station</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;

    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    // Should find 3 CIM objects (not the rdf:RDF wrapper)
    try std.testing.expectEqual(3, model.objects.len);

    // After type-grouping, objects are ordered by type, not parse order
    const substations = model.objects_by_type("Substation");
    try std.testing.expectEqual(2, substations.len);
    try std.testing.expectEqualStrings("_SS1", substations[0].id());
    try std.testing.expectEqualStrings("_SS2", substations[1].id());
    try std.testing.expectEqualStrings(
        "North Station",
        (substations[0].property("IdentifiedObject.name")).?,
    );
    const voltage_levels = model.objects_by_type("VoltageLevel");
    try std.testing.expectEqual(1, voltage_levels.len);
}

test "CimDocument.init - parses objects in a default namespace" {
    const xml =
        \\<rdf:RDF xmlns="http://iec.ch/TC57/2013/CIM-schema-cim16#"
        \\         xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        \\  <FullModel xmlns="http://iec.ch/TC57/61970-552/ModelDescription/1#"
        \\             rdf:about="urn:uuid:model">
        \\    <Model.profile>http://entsoe.eu/CIM/EquipmentCore/3/1</Model.profile>
        \\  </FullModel>
        \\  <EffectivityResult rdf:ID="_result">
        \\    <EffectivityResult.CBCO rdf:resource="#_cbco"/>
        \\  </EffectivityResult>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), model.objects.len);
    const result = model.object_by_id("_result") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("EffectivityResult", result.type_name());
    try std.testing.expectEqualStrings(
        "#_cbco",
        (try result.reference("EffectivityResult.CBCO")).?,
    );
    const full_model = model.object_by_id("urn:uuid:model") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("FullModel", full_model.type_name());
}

test "CimDocument.object_by_id - finds object by ID" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:IdentifiedObject.name>380kV</cim:IdentifiedObject.name>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;

    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    // Should find VL1
    const voltage_level = model.object_by_id("_VL1") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("_VL1", voltage_level.id());
    try std.testing.expectEqualStrings("VoltageLevel", voltage_level.type_name());
    try std.testing.expectEqualStrings(
        "380kV",
        (voltage_level.property("IdentifiedObject.name")).?,
    );

    // Should return null for non-existent ID
    const missing = model.object_by_id("_NOTFOUND");
    try std.testing.expect(missing == null);
}

test "CimDocument.objects_by_type - returns all objects of given type" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:IdentifiedObject.name>380kV</cim:IdentifiedObject.name>
        \\  </cim:VoltageLevel>
        \\  <cim:Substation rdf:ID="_SS2">
        \\    <cim:IdentifiedObject.name>South</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <cim:Substation rdf:ID="_SS3">
        \\    <cim:IdentifiedObject.name>East</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;

    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    // Get all Substations (should be 3)
    const substations = model.objects_by_type("Substation");
    try std.testing.expectEqual(3, substations.len);
    try std.testing.expectEqualStrings("_SS1", substations[0].id());
    try std.testing.expectEqualStrings("_SS2", substations[1].id());
    try std.testing.expectEqualStrings("_SS3", substations[2].id());

    // Get all VoltageLevels (should be 1)
    const voltage_levels = model.objects_by_type("VoltageLevel");
    try std.testing.expectEqual(1, voltage_levels.len);
    try std.testing.expectEqualStrings("_VL1", voltage_levels[0].id());

    // Get non-existent type (should be empty)
    const missing = model.objects_by_type("DoesNotExist");
    try std.testing.expectEqual(0, missing.len);
}

test "CimDocument.type_groups - visits each exact type once without allocation" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\  <cim:VoltageLevel rdf:ID="_VL1"/>
        \\  <cim:Substation rdf:ID="_SS2"/>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    var groups = model.type_groups();
    var groups_count: u32 = 0;
    var objects_count: u32 = 0;
    var saw_substations = false;
    var saw_voltage_levels = false;
    while (groups.next()) |group| {
        groups_count += 1;
        objects_count += @intCast(group.objects.len);
        for (group.objects) |object| {
            try std.testing.expectEqualStrings(group.type_name, object.type_name());
        }

        if (std.mem.eql(u8, group.type_name, "Substation")) {
            try std.testing.expectEqual(@as(usize, 2), group.objects.len);
            saw_substations = true;
        } else if (std.mem.eql(u8, group.type_name, "VoltageLevel")) {
            try std.testing.expectEqual(@as(usize, 1), group.objects.len);
            saw_voltage_levels = true;
        } else {
            return error.TestUnexpectedResult;
        }
    }

    try std.testing.expectEqual(@as(u32, 2), groups_count);
    try std.testing.expectEqual(@as(u32, 3), objects_count);
    try std.testing.expect(saw_substations);
    try std.testing.expect(saw_voltage_levels);
    try std.testing.expect(groups.next() == null);
}

test "CimDocument.sorted_type_counts - returns sorted counts for each object type" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\  <cim:VoltageLevel rdf:ID="_VL1"/>
        \\  <cim:Substation rdf:ID="_SS2"/>
        \\  <cim:ACLineSegment rdf:ID="_L1"/>
        \\  <cim:ACLineSegment rdf:ID="_L2"/>
        \\  <cim:ACLineSegment rdf:ID="_L3"/>
        \\  <cim:Zone rdf:ID="_Z1"/>
        \\  <cim:Zone rdf:ID="_Z2"/>
        \\  <cim:Zone rdf:ID="_Z3"/>
        \\  <cim:Zone rdf:ID="_Z4"/>
        \\  <cim:Zone rdf:ID="_Z5"/>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;

    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const counts = try model.sorted_type_counts(gpa);
    defer gpa.free(counts);

    try std.testing.expectEqual(@as(usize, 4), counts.len);
    try std.testing.expectEqualStrings("ACLineSegment", counts[0].type_name);
    try std.testing.expectEqual(@as(u32, 3), counts[0].count);
    try std.testing.expectEqualStrings("Substation", counts[1].type_name);
    try std.testing.expectEqual(@as(u32, 2), counts[1].count);
    try std.testing.expectEqualStrings("VoltageLevel", counts[2].type_name);
    try std.testing.expectEqual(@as(u32, 1), counts[2].count);
    try std.testing.expectEqualStrings("Zone", counts[3].type_name);
    try std.testing.expectEqual(@as(u32, 5), counts[3].count);
}

test "CimDocument.init - handles empty XML" {
    const xml = "<rdf:RDF></rdf:RDF>";

    const gpa = std.testing.allocator;

    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    try std.testing.expectEqual(0, model.objects.len);
}

test "CimDocument.init - falls back to rdf:about when rdf:ID is unusable" {
    const xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:ID="" rdf:about="urn:uuid:empty-id">
        \\    <md:Model.scenarioTime>2026-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
        \\  <md:FullModel rdf:about="urn:uuid:malformed-id" rdf:ID="_BROKEN>
        \\    <md:Model.scenarioTime>2026-01-02T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;

    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    try std.testing.expectEqual(2, model.objects.len);
    _ = model.object_by_id("urn:uuid:empty-id") orelse return error.TestFailed;
    _ = model.object_by_id("urn:uuid:malformed-id") orelse return error.TestFailed;
}

test "EQ objects maintain CimObject functionality" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\    <cim:Substation.Region rdf:resource="#_Region1"/>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;

    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const obj = model.object_by_id("_SS1") orelse return error.TestFailed;

    // Should still be able to get properties
    const name = obj.property("IdentifiedObject.name");
    try std.testing.expectEqualStrings("North Station", name.?);

    // Should still be able to get references
    const region = try obj.reference("Substation.Region");
    try std.testing.expectEqualStrings("#_Region1", region.?);
}

test "CimDocument.init - an unnameable element fails the whole document" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\  <>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;

    // The alternative was to drop `<>` and hand back a document with one object
    // in it, which reports success for a file the scanner could not read. The
    // parse fails at the gate instead, so no consumer ever walks a document that
    // silently lost a tag. `init` owns the buffer and frees it on error.
    try std.testing.expectError(
        error.MalformedXML,
        CimDocument.init(gpa, try gpa.dupe(u8, xml)),
    );
}

test "CimDocument.init - comments and PIs are not elements and do not fail" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<rdf:RDF>
        \\  <!-- <cim:Substation rdf:ID="_commented_out"> -->
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    // Being strict about elements must not make the parser strict about things
    // that are not elements: the declaration and the comment are skipped, and the
    // commented-out object does not become real.
    try std.testing.expectEqual(@as(usize, 1), model.objects.len);
    try std.testing.expect(model.object_by_id("_commented_out") == null);
    try std.testing.expect(model.object_by_id("_SS1") != null);
}

test "CimDocument.init - a stray '<' inside a tag errors instead of panicking" {
    // Regression: this document used to parse, and then panic in the child walk
    // with "start index 38 is larger than end index 35" -- `find_tag_boundaries`
    // emitted `<m>/>` as a boundary starting inside `<cim:P <m>`, and the walk
    // sliced backwards between the two. Reachable from `cimd get` on a file.
    const xml = "<rdf:RDF><cim:S rdf:ID=\"_1\"><cim:P <m>/></cim:P></cim:S></rdf:RDF>";

    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.MalformedXML,
        CimDocument.init(gpa, try gpa.dupe(u8, xml)),
    );
}
