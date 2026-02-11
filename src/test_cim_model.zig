const std = @import("std");
const CimModel = @import("cim_model.zig").CimModel;

test "CimModel.init - parses all top-level CIM objects" {
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

    var model = try CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    // Should find 3 CIM objects (not the rdf:RDF wrapper)
    try std.testing.expectEqual(3, model.objects.len);

    // After type-grouping, objects are ordered by type, not parse order
    const substations = model.getObjectsByType("Substation");
    try std.testing.expectEqual(2, substations.len);
    try std.testing.expectEqualStrings("_SS1", substations[0].id);
    try std.testing.expectEqualStrings("_SS2", substations[1].id);
    const voltage_levels = model.getObjectsByType("VoltageLevel");
    try std.testing.expectEqual(1, voltage_levels.len);
}

test "CimModel.getObjectById - finds object by ID" {
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

    var model = try CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    // Should find VL1
    const vl = model.getObjectById("_VL1") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("_VL1", vl.id);
    try std.testing.expectEqualStrings("VoltageLevel", vl.type_name);

    // Should return null for non-existent ID
    const missing = model.getObjectById("_NOTFOUND");
    try std.testing.expect(missing == null);
}

test "CimModel.getObjectsByType - returns all objects of given type" {
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

    var model = try CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    // Get all Substations (should be 3)
    const substations = model.getObjectsByType("Substation");
    try std.testing.expectEqual(3, substations.len);
    try std.testing.expectEqualStrings("_SS1", substations[0].id);
    try std.testing.expectEqualStrings("_SS2", substations[1].id);
    try std.testing.expectEqualStrings("_SS3", substations[2].id);

    // Get all VoltageLevels (should be 1)
    const voltage_levels = model.getObjectsByType("VoltageLevel");
    try std.testing.expectEqual(1, voltage_levels.len);
    try std.testing.expectEqualStrings("_VL1", voltage_levels[0].id);

    // Get non-existent type (should be empty)
    const missing = model.getObjectsByType("DoesNotExist");
    try std.testing.expectEqual(0, missing.len);
}

test "CimModel.getTypeCounts - returns count of each object type" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\  <cim:VoltageLevel rdf:ID="_VL1"/>
        \\  <cim:Substation rdf:ID="_SS2"/>
        \\  <cim:ACLineSegment rdf:ID="_L1"/>
        \\  <cim:ACLineSegment rdf:ID="_L2"/>
        \\  <cim:ACLineSegment rdf:ID="_L3"/>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;

    var model = try CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    var counts = try model.getTypeCounts(gpa);
    defer counts.deinit();

    // Should have exactly 3 types
    try std.testing.expectEqual(3, counts.count());

    // Check specific counts
    try std.testing.expectEqual(2, counts.get("Substation").?);
    try std.testing.expectEqual(1, counts.get("VoltageLevel").?);
    try std.testing.expectEqual(3, counts.get("ACLineSegment").?);
}

test "CimModel.init - handles empty XML" {
    const xml = "<rdf:RDF></rdf:RDF>";

    const gpa = std.testing.allocator;

    var model = try CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    try std.testing.expectEqual(0, model.objects.len);
}

test "CimModel objects maintain CimObject functionality" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\    <cim:Substation.Region rdf:resource="#_Region1"/>
        \\  </cim:Substation>
        \\</rdf:RDF>
    ;

    const gpa = std.testing.allocator;

    var model = try CimModel.init(gpa, xml);
    defer model.deinit(gpa);

    const obj = model.getObjectById("_SS1") orelse return error.TestFailed;

    // Should still be able to get properties
    const name = try obj.getProperty("IdentifiedObject.name");
    try std.testing.expectEqualStrings("North Station", name.?);

    // Should still be able to get references
    const region = try obj.getReference("Substation.Region");
    try std.testing.expectEqualStrings("#_Region1", region.?);
}
