const std = @import("std");
const EQ = @import("eq.zig").EQ;

test "EQ.init - parses all top-level CIM objects" {
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

    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    // Should find 3 CIM objects (not the rdf:RDF wrapper)
    try std.testing.expectEqual(3, model.objects.len);

    // After type-grouping, objects are ordered by type, not parse order
    const substations = model.get_objects_by_type("Substation");
    try std.testing.expectEqual(2, substations.len);
    try std.testing.expectEqualStrings("_SS1", substations[0].id);
    try std.testing.expectEqualStrings("_SS2", substations[1].id);
    const voltage_levels = model.get_objects_by_type("VoltageLevel");
    try std.testing.expectEqual(1, voltage_levels.len);
}

test "EQ.getObjectById - finds object by ID" {
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

    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    // Should find VL1
    const voltage_level = model.getObjectById("_VL1") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("_VL1", voltage_level.id);
    try std.testing.expectEqualStrings("VoltageLevel", voltage_level.type_name);

    // Should return null for non-existent ID
    const missing = model.getObjectById("_NOTFOUND");
    try std.testing.expect(missing == null);
}

test "EQ.get_objects_by_type - returns all objects of given type" {
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

    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    // Get all Substations (should be 3)
    const substations = model.get_objects_by_type("Substation");
    try std.testing.expectEqual(3, substations.len);
    try std.testing.expectEqualStrings("_SS1", substations[0].id);
    try std.testing.expectEqualStrings("_SS2", substations[1].id);
    try std.testing.expectEqualStrings("_SS3", substations[2].id);

    // Get all VoltageLevels (should be 1)
    const voltage_levels = model.get_objects_by_type("VoltageLevel");
    try std.testing.expectEqual(1, voltage_levels.len);
    try std.testing.expectEqualStrings("_VL1", voltage_levels[0].id);

    // Get non-existent type (should be empty)
    const missing = model.get_objects_by_type("DoesNotExist");
    try std.testing.expectEqual(0, missing.len);
}

test "EQ.sorted_type_counts - returns sorted counts for each object type" {
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

    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
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

test "EQ.init - handles empty XML" {
    const xml = "<rdf:RDF></rdf:RDF>";

    const gpa = std.testing.allocator;

    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    try std.testing.expectEqual(0, model.objects.len);
}

test "EQ.init - falls back to rdf:about when rdf:ID is unusable" {
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

    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    try std.testing.expectEqual(2, model.objects.len);
    _ = model.getObjectById("urn:uuid:empty-id") orelse return error.TestFailed;
    _ = model.getObjectById("urn:uuid:malformed-id") orelse return error.TestFailed;
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

    var model = try EQ.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const obj = model.getObjectById("_SS1") orelse return error.TestFailed;

    // Should still be able to get properties
    const name = try obj.getProperty("IdentifiedObject.name");
    try std.testing.expectEqualStrings("North Station", name.?);

    // Should still be able to get references
    const region = try obj.getReference("Substation.Region");
    try std.testing.expectEqualStrings("#_Region1", region.?);
}
