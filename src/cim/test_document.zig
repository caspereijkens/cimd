const std = @import("std");
const CimDocument = @import("document.zig").CimDocument;

test "dense rootless objects retain custom types, source order within groups, and ID lookup" {
    const gpa = std.testing.allocator;
    var buffer: [32 * 1024]u8 = undefined;
    var xml = std.Io.Writer.fixed(&buffer);
    for (0..256) |i| try xml.print("<ext:Custom{d} rdf:ID=\"id{d}\"/>", .{ i % 97, i });
    var model = try CimDocument.init(gpa, xml.buffered());
    defer model.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 256), model.object_count());

    for (0..97) |type_id| {
        var type_buffer: [32]u8 = undefined;
        const type_name = try std.fmt.bufPrint(&type_buffer, "Custom{d}", .{type_id});
        const group = model.objects_by_type(type_name);
        const expected_count = (255 - type_id) / 97 + 1;
        try std.testing.expectEqual(expected_count, group.len);
        for (group, 0..) |object, offset| {
            var id_buffer: [32]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buffer, "id{d}", .{type_id + offset * 97});
            try std.testing.expectEqualStrings(id, object.id());
            const found = model.object_by_id(id).?;
            try std.testing.expectEqualStrings(type_name, found.type_name());
            try std.testing.expectEqual(object.object_tag_idx, found.object_tag_idx);
        }
    }
    try std.testing.checkAllAllocationFailures(gpa, parse_borrowed, .{ xml.buffered(), null });
}

test "documents can share a borrowed subslice without taking ownership" {
    const gpa = std.testing.allocator;
    const content = "<cim:A rdf:ID=\"a\"><cim:A.name>shared</cim:A.name></cim:A>";
    const storage = try gpa.dupe(u8, "prefix" ++ content ++ "suffix");
    defer gpa.free(storage);
    const xml = storage[6 .. 6 + content.len];
    var first = try CimDocument.init(gpa, xml);
    var second = CimDocument.init(gpa, xml) catch |err| {
        first.deinit(gpa);
        return err;
    };
    defer second.deinit(gpa);
    first.deinit(gpa);
    try std.testing.expectEqualStrings(content, xml);
    try std.testing.expectEqualStrings("shared", second.object_by_id("a").?.property("A.name").?);
}

test "duplicate diagnostics retain source priority across distinct types" {
    const gpa = std.testing.allocator;
    const xml = "<cim:Z rdf:ID=\"a\"/><cim:A rdf:ID=\"b\"/>" ++
        "<cim:B rdf:ID=\"a\"/><cim:Z rdf:ID=\"b\"/>";
    var diagnostics: @import("diagnostics.zig").Diagnostics = .{};
    try std.testing.expectError(error.DuplicateId, CimDocument.init_with_diagnostics(gpa, xml, &diagnostics));
    try std.testing.expectEqualStrings("a", diagnostics.duplicate_id());
    try std.testing.expectEqual(std.mem.indexOf(u8, xml, "<cim:B").?, diagnostics.duplicate_offset);
}

test "discovery descends through wrappers but skips children of accepted objects" {
    const xml =
        "<outer><inner><cim:A rdf:ID=\"\" rdf:about=\"#a\">" ++
        "<cim:B rdf:ID=\"hidden\"/></cim:A>" ++
        "<wrapper><ext:A rdf:ID=\"b\"/></wrapper></inner></outer>" ++
        "<A rdf:ID=\"c\"/>";
    var model = try CimDocument.init(std.testing.allocator, xml);
    defer model.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), model.object_count());
    try std.testing.expect(model.object_by_id("hidden") == null);
    const objects = model.objects_by_type("A");
    for (objects, [_][]const u8{ "a", "b", "c" }) |object, id| {
        try std.testing.expectEqualStrings(id, object.id());
        try std.testing.expectEqual(object.object_tag_idx, model.object_by_id(id).?.object_tag_idx);
    }
}

fn parse_borrowed(gpa: std.mem.Allocator, xml: []const u8, expected_error: ?anyerror) !void {
    if (CimDocument.init(gpa, xml)) |parsed| {
        var model = parsed;
        defer model.deinit(gpa);
        try std.testing.expect(expected_error == null);
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(expected_error orelse return err, err);
    }
}

test "construction releases scratch storage at every allocation failure and validation exit" {
    const valid = "<rdf:RDF><cim:A rdf:ID=\"a\"/><ext:B rdf:ID=\"b\"/>" ++
        "<cim:A rdf:ID=\"c\"><cim:A.name>C</cim:A.name></cim:A></rdf:RDF>";
    const duplicate = "<cim:A rdf:ID=\"a\"/><cim:B rdf:ID=\"a\"/>";
    const malformed = "<rdf:RDF><cim:A rdf:ID=\"a\"/></wrong>";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parse_borrowed, .{ valid, null });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parse_borrowed, .{ duplicate, error.DuplicateId });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parse_borrowed, .{ malformed, error.MalformedXML });
}

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

    var model = try CimDocument.init(gpa, xml);
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
    var model = try CimDocument.init(gpa, xml);
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

    var model = try CimDocument.init(gpa, xml);
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

    var model = try CimDocument.init(gpa, xml);
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
    var model = try CimDocument.init(gpa, xml);
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

    var model = try CimDocument.init(gpa, xml);
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

    var model = try CimDocument.init(gpa, xml);
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

    var model = try CimDocument.init(gpa, xml);
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

    var model = try CimDocument.init(gpa, xml);
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

    // Dropping an unreadable tag would report success for a document that silently lost data.
    try std.testing.expectError(
        error.MalformedXML,
        CimDocument.init(gpa, xml),
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
    var model = try CimDocument.init(gpa, xml);
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
        CimDocument.init(gpa, xml),
    );
}
