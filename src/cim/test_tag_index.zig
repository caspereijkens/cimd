//! Tests for the CIM object layer: objects, their children, and the property
//! and reference queries built on them. Raw tag scanning is tested in
//! test_xml_scan.zig.

const std = @import("std");
const assert = std.debug.assert;
const tag_index = @import("tag_index.zig");
const xml_scan = @import("xml_scan.zig");
const ElementView = tag_index.ElementView;

const TestObject = struct {
    element: ElementView,
    id: []const u8,
    type_name: []const u8,

    fn property(self: TestObject, name: []const u8) !?[]const u8 {
        return self.element.property(name);
    }

    fn reference(self: TestObject, name: []const u8) !?[]const u8 {
        return self.element.reference(name);
    }

    fn children(self: TestObject) tag_index.ChildIterator {
        return self.element.children();
    }

    fn properties(self: TestObject, comptime names: anytype) ![names.len]?[]const u8 {
        return self.element.properties(names);
    }

    fn references(self: TestObject, comptime names: anytype) ![names.len]?[]const u8 {
        return self.element.references(names);
    }

    fn all_properties(self: TestObject, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
        return self.element.all_properties(gpa);
    }

    fn all_references(self: TestObject, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
        return self.element.all_references(gpa);
    }
};

/// Test helper: bind one parsed element span for object-query tests.
fn make_cim_object(
    xml: []const u8,
    boundaries: []const xml_scan.TagBoundary,
    tag_idx: u32,
    closing_idx: u32,
) !TestObject {
    const start = boundaries[tag_idx].start;
    const id = xml_scan.extract_rdf_id(xml, start) catch |err| switch (err) {
        error.NoRdfId => try xml_scan.extract_rdf_about(xml, start),
        error.MalformedTag => return error.MalformedTag,
    };
    return .{
        .element = .{
            .xml = xml,
            .boundaries = boundaries,
            .object_tag_idx = tag_idx,
            .closing_tag_idx = closing_idx,
        },
        .id = id,
        .type_name = try xml_scan.extract_tag_type(xml, boundaries[tag_idx].start),
    };
}

test "tag_index.get_property_from_indices - simple property with text content" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Substation: opening at 0, closing at 3
    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 3), closing);

    // Get the "IdentifiedObject.name" property
    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "IdentifiedObject.name");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("North Station", value.?);
}

test "tag_index.get_property_from_indices - property not found returns null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    // Request property that doesn't exist
    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "NonExistent.property");
    try std.testing.expectEqual(@as(?[]const u8, null), value);
}

test "tag_index.get_property_from_indices - empty property value" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.name></cim:Property.name>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.name");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("", value.?);
}

test "tag_index.get_property_from_indices - multiple properties, find specific one" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  <cim:IdentifiedObject.description>Main substation</cim:IdentifiedObject.description>
        \\  <cim:Substation.Region rdf:resource="#_R1"/>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    // Get first property
    const name = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "IdentifiedObject.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("North Station", name.?);

    // Get second property
    const desc = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "IdentifiedObject.description");
    try std.testing.expect(desc != null);
    try std.testing.expectEqualStrings("Main substation", desc.?);
}

test "tag_index.get_property_from_indices - self-closing property tag returns null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:Substation.Region rdf:resource="#_R1"/>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    // Self-closing tag has no text content
    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Substation.Region");
    try std.testing.expectEqual(@as(?[]const u8, null), value);
}

test "tag_index.get_property_from_indices - property with whitespace preserved" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.value>  Leading and trailing spaces  </cim:Property.value>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.value");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("  Leading and trailing spaces  ", value.?);
}

test "tag_index.get_property_from_indices - property name must match exactly" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.name>Value</cim:Property.name>
        \\  <cim:Property.nameExtra>Other</cim:Property.nameExtra>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    // Should find exact match "Property.name", not "Property.nameExtra"
    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.name");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("Value", value.?);

    // Should NOT match partial "Property.name" when looking for "Property.nameExtra"
    const value2 = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.nameExtra");
    try std.testing.expect(value2 != null);
    try std.testing.expectEqualStrings("Other", value2.?);
}

test "tag_index.get_property_from_indices - property with special characters" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.value>Value with &lt;special&gt; chars &amp; symbols</cim:Property.value>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.value");
    try std.testing.expect(value != null);
    // Note: We return raw XML content, not decoded entities
    try std.testing.expectEqualStrings("Value with &lt;special&gt; chars &amp; symbols", value.?);
}

test "tag_index.get_property_from_indices - multiple same-name properties returns first" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.value>First</cim:Property.value>
        \\  <cim:Property.value>Second</cim:Property.value>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    // Should return first occurrence
    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.value");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("First", value.?);
}

test "tag_index.get_property_from_indices - property with numeric value" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:VoltageLevel>
        \\  <cim:VoltageLevel.nominalV>380.0</cim:VoltageLevel.nominalV>
        \\</cim:VoltageLevel>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "VoltageLevel.nominalV");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("380.0", value.?);
}

test "tag_index.get_property_from_indices - no properties in object" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Object></cim:Object>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Any.property");
    try std.testing.expectEqual(@as(?[]const u8, null), value);
}

test "tag_index.get_property_from_indices - nested object doesn't interfere" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Outer>
        \\  <cim:Outer.property>OuterValue</cim:Outer.property>
        \\  <cim:Inner>
        \\    <cim:Inner.property>InnerValue</cim:Inner.property>
        \\  </cim:Inner>
        \\</cim:Outer>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const outer_closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    // Getting property from Outer should find its own property, not nested one
    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, outer_closing, "Outer.property");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("OuterValue", value.?);
}

test "tag_index.get_property_from_indices - property with newlines and indentation" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.text>
        \\    Multi-line
        \\    content
        \\  </cim:Property.text>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.text");
    try std.testing.expect(value != null);
    // Should preserve all whitespace including newlines
    try std.testing.expect(std.mem.indexOf(u8, value.?, "Multi-line") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.?, "content") != null);
}

test "tag_index.get_property_from_indices - self-closing tag before target property" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation>
        \\  <cim:Region rdf:resource="#_R1"/>
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    // Should skip self-closing Region and find name
    const value = tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "IdentifiedObject.name");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("North Station", value.?);
}

test "tag_index.get_reference_from_indices - simple reference extraction" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:Substation.Region rdf:resource="#_Region1"/>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Substation.Region");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_Region1", ref.?);
}

test "tag_index.get_reference_from_indices - reference not found returns null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:Substation.Region rdf:resource="#_Region1"/>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "NonExistent.property");
    try std.testing.expectEqual(@as(?[]const u8, null), ref);
}

test "tag_index.get_reference_from_indices - property exists but no rdf:resource" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation>
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    // Property exists but has text content, not rdf:resource
    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "IdentifiedObject.name");
    try std.testing.expectEqual(@as(?[]const u8, null), ref);
}

test "tag_index.get_reference_from_indices - multiple properties find specific reference" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_CN1"/>
        \\  <cim:Terminal.ConductingEquipment rdf:resource="#_CE1"/>
        \\  <cim:IdentifiedObject.name>Terminal 1</cim:IdentifiedObject.name>
        \\</cim:Terminal>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    // Get first reference
    const conn_node = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Terminal.ConnectivityNode");
    try std.testing.expect(conn_node != null);
    try std.testing.expectEqualStrings("#_CN1", conn_node.?);

    // Get second reference
    const ce = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Terminal.ConductingEquipment");
    try std.testing.expect(ce != null);
    try std.testing.expectEqualStrings("#_CE1", ce.?);
}

test "tag_index.get_reference_from_indices - reference with hash prefix" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_LocalRef"/>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_LocalRef", ref.?);
}

test "tag_index.get_reference_from_indices - reference without hash prefix" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="_ExternalRef"/>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("_ExternalRef", ref.?);
}

test "tag_index.get_reference_from_indices - empty reference value" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource=""/>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("", ref.?);
}

test "tag_index.get_reference_from_indices - reference with URI" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="http://example.com/resource#_R1"/>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("http://example.com/resource#_R1", ref.?);
}

test "tag_index.get_reference_from_indices - reference with special characters" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_Node-123.456_v2"/>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_Node-123.456_v2", ref.?);
}

test "tag_index.get_reference_from_indices - multiple same-name properties returns first" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_First"/>
        \\  <cim:Property.ref rdf:resource="#_Second"/>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_First", ref.?);
}

test "tag_index.get_reference_from_indices - property name must match exactly" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_Ref1"/>
        \\  <cim:Property.refExtra rdf:resource="#_Ref2"/>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const ref1 = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref1 != null);
    try std.testing.expectEqualStrings("#_Ref1", ref1.?);

    const ref2 = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.refExtra");
    try std.testing.expect(ref2 != null);
    try std.testing.expectEqualStrings("#_Ref2", ref2.?);
}

test "tag_index.get_reference_from_indices - no properties in object" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Object></cim:Object>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Any.property");
    try std.testing.expectEqual(@as(?[]const u8, null), ref);
}

test "tag_index.get_reference_from_indices - nested object doesn't interfere" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Outer>
        \\  <cim:Outer.ref rdf:resource="#_OuterRef"/>
        \\  <cim:Inner>
        \\    <cim:Inner.ref rdf:resource="#_InnerRef"/>
        \\  </cim:Inner>
        \\</cim:Outer>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const outer_closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    // Getting reference from Outer should find its own reference
    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, outer_closing, "Outer.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_OuterRef", ref.?);
}

test "tag_index.get_reference_from_indices - non-self-closing tag with rdf:resource" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_Ref1"></cim:Property.ref>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    // Should still extract rdf:resource even if tag is not self-closing
    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_Ref1", ref.?);
}

test "tag_index.get_reference_from_indices - rdf:resource with other attributes" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref name="test" rdf:resource="#_Ref1" other="value"/>
        \\</cim:Object>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_Ref1", ref.?);
}

test "tag_index.CimObject - create simple object" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);

    // Create CimObject
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    // Check metadata
    try std.testing.expectEqualStrings("_SS1", obj.id);
    try std.testing.expectEqualStrings("Substation", obj.type_name);
}

test "tag_index.CimObject - property returns text content" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  <cim:IdentifiedObject.description>Main substation</cim:IdentifiedObject.description>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    // Get properties
    const name = try obj.property("IdentifiedObject.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("North Station", name.?);

    const desc = try obj.property("IdentifiedObject.description");
    try std.testing.expect(desc != null);
    try std.testing.expectEqualStrings("Main substation", desc.?);
}

test "tag_index.CimObject - property returns null when not found" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    const result = try obj.property("NonExistent.property");
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "tag_index.CimObject - reference returns rdf:resource value" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_CN1"/>
        \\  <cim:Terminal.ConductingEquipment rdf:resource="#_CE1"/>
        \\</cim:Terminal>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    // Check metadata
    try std.testing.expectEqualStrings("_T1", obj.id);
    try std.testing.expectEqualStrings("Terminal", obj.type_name);

    // Get references
    const conn_node = try obj.reference("Terminal.ConnectivityNode");
    try std.testing.expect(conn_node != null);
    try std.testing.expectEqualStrings("#_CN1", conn_node.?);

    const ce = try obj.reference("Terminal.ConductingEquipment");
    try std.testing.expect(ce != null);
    try std.testing.expectEqualStrings("#_CE1", ce.?);
}

test "tag_index.CimObject - reference returns null when not found" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_CN1"/>
        \\</cim:Terminal>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    const result = try obj.reference("NonExistent.property");
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "tag_index.CimObject - mixed properties and references" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:ACLineSegment rdf:ID="_L1">
        \\  <cim:IdentifiedObject.name>Line 1</cim:IdentifiedObject.name>
        \\  <cim:ACLineSegment.r>0.5</cim:ACLineSegment.r>
        \\  <cim:ACLineSegment.BaseVoltage rdf:resource="#_BV1"/>
        \\</cim:ACLineSegment>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    // Check metadata
    try std.testing.expectEqualStrings("_L1", obj.id);
    try std.testing.expectEqualStrings("ACLineSegment", obj.type_name);

    // Get text properties
    const name = try obj.property("IdentifiedObject.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("Line 1", name.?);

    const r = try obj.property("ACLineSegment.r");
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("0.5", r.?);

    // Get reference
    const bv = try obj.reference("ACLineSegment.BaseVoltage");
    try std.testing.expect(bv != null);
    try std.testing.expectEqualStrings("#_BV1", bv.?);
}

test "tag_index.CimObject - empty object (no properties)" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Object rdf:ID=\"_O1\"></cim:Object>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    try std.testing.expectEqualStrings("_O1", obj.id);
    try std.testing.expectEqualStrings("Object", obj.type_name);

    const prop = try obj.property("Any.property");
    try std.testing.expectEqual(@as(?[]const u8, null), prop);
}

test "tag_index.CimObject - object with long ID" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_Very_Long_Identifier_With_Many_Characters_12345\"></cim:Substation>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    try std.testing.expectEqualStrings("_Very_Long_Identifier_With_Many_Characters_12345", obj.id);
}

test "tag_index.CimObject - object with dots in type name" {
    const gpa = std.testing.allocator;

    const xml = "<cim:IdentifiedObject.name rdf:ID=\"_ID1\"></cim:IdentifiedObject.name>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    try std.testing.expectEqualStrings("_ID1", obj.id);
    try std.testing.expectEqualStrings("IdentifiedObject.name", obj.type_name);
}

test "tag_index.CimObject - multiple objects from same XML" {
    const gpa = std.testing.allocator;

    const xml =
        \\<root>
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>Station 1</cim:IdentifiedObject.name>
        \\</cim:Substation>
        \\<cim:Substation rdf:ID="_SS2">
        \\  <cim:IdentifiedObject.name>Station 2</cim:IdentifiedObject.name>
        \\</cim:Substation>
        \\</root>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // First Substation (index 1)
    const closing1 = try xml_scan.find_closing_tag(xml, boundaries.items, 1);
    const obj1 = try make_cim_object(xml, boundaries.items, 1, closing1);

    try std.testing.expectEqualStrings("_SS1", obj1.id);
    try std.testing.expectEqualStrings("Substation", obj1.type_name);

    const name1 = try obj1.property("IdentifiedObject.name");
    try std.testing.expect(name1 != null);
    try std.testing.expectEqualStrings("Station 1", name1.?);

    // Second Substation (index 5)
    const closing2 = try xml_scan.find_closing_tag(xml, boundaries.items, 5);
    const obj2 = try make_cim_object(xml, boundaries.items, 5, closing2);

    try std.testing.expectEqualStrings("_SS2", obj2.id);
    try std.testing.expectEqualStrings("Substation", obj2.type_name);

    const name2 = try obj2.property("IdentifiedObject.name");
    try std.testing.expect(name2 != null);
    try std.testing.expectEqualStrings("Station 2", name2.?);

    // Verify they share the same xml and boundaries references
    try std.testing.expectEqual(obj1.element.xml.ptr, obj2.element.xml.ptr);
    try std.testing.expectEqual(obj1.element.boundaries.ptr, obj2.element.boundaries.ptr);
}

test "tag_index.CimObject - self-closing tag" {
    const gpa = std.testing.allocator;

    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\</rdf:RDF>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // The Substation is at index 1
    const closing = xml_scan.find_closing_tag(xml, boundaries.items, 1) catch |err| blk: {
        try std.testing.expectEqual(error.SelfClosingTag, err);
        break :blk 1; // Use same index for self-closing
    };
    try std.testing.expectEqual(@as(u32, 1), closing); // Self-closing returns same index

    const obj = try make_cim_object(xml, boundaries.items, 1, closing);

    try std.testing.expectEqualStrings("_SS1", obj.id);
    try std.testing.expectEqualStrings("Substation", obj.type_name);

    // Self-closing tags should have no properties
    const prop = try obj.property("SomeProperty");
    try std.testing.expect(prop == null);

    // Self-closing tags should have no references
    const ref = try obj.reference("SomeReference");
    try std.testing.expect(ref == null);
}

test "tag_index.CimObject - property on self-closing tag returns null" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Terminal rdf:ID=\"_T1\"/>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = xml_scan.find_closing_tag(xml, boundaries.items, 0) catch |err| blk: {
        try std.testing.expectEqual(error.SelfClosingTag, err);
        break :blk 0; // Use same index for self-closing
    };
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    // Verify self-closing
    try std.testing.expectEqual(obj.element.object_tag_idx, obj.element.closing_tag_idx);

    // All property lookups should return null
    const name = try obj.property("IdentifiedObject.name");
    try std.testing.expect(name == null);

    const desc = try obj.property("IdentifiedObject.description");
    try std.testing.expect(desc == null);
}

test "tag_index.CimObject - reference on self-closing tag returns null" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Terminal rdf:ID=\"_T1\"/>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = xml_scan.find_closing_tag(xml, boundaries.items, 0) catch |err| blk: {
        try std.testing.expectEqual(error.SelfClosingTag, err);
        break :blk 0; // Use same index for self-closing
    };
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    // Verify self-closing
    try std.testing.expectEqual(obj.element.object_tag_idx, obj.element.closing_tag_idx);

    // All reference lookups should return null
    const ref1 = try obj.reference("Terminal.ConductingEquipment");
    try std.testing.expect(ref1 == null);

    const ref2 = try obj.reference("Terminal.ConnectivityNode");
    try std.testing.expect(ref2 == null);
}

test "tag_index.get_property_from_indices - self-closing tag returns null" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_SS1\"/>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // For self-closing tag, opening_idx == closing_idx
    const result = tag_index.get_property_from_indices(xml, boundaries.items, 0, 0, "SomeProperty");
    try std.testing.expect(result == null);
}

test "tag_index.get_reference_from_indices - self-closing tag returns null" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_SS1\"/>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // For self-closing tag, opening_idx == closing_idx
    const result = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, 0, "SomeReference");
    try std.testing.expect(result == null);
}

test "CimObject.all_properties - returns all text properties" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  <cim:IdentifiedObject.description>Main substation</cim:IdentifiedObject.description>
        \\  <cim:Substation.Region rdf:resource="#_Region1"/>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    var props = try obj.all_properties(gpa);
    defer props.deinit();

    // Should have 2 properties (not the reference)
    try std.testing.expectEqual(2, props.count());

    // Check property values
    const name = props.get("IdentifiedObject.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("North Station", name.?);

    const desc = props.get("IdentifiedObject.description");
    try std.testing.expect(desc != null);
    try std.testing.expectEqualStrings("Main substation", desc.?);

    // Should NOT include the reference
    try std.testing.expect(props.get("Substation.Region") == null);
}

test "CimObject.all_references - returns all rdf:resource references" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  <cim:Substation.Region rdf:resource="#_Region1"/>
        \\  <cim:Substation.VoltageLevel rdf:resource="#_VL1"/>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    var refs = try obj.all_references(gpa);
    defer refs.deinit();

    // Should have 2 references
    try std.testing.expectEqual(2, refs.count());

    // Check reference values
    const region = refs.get("Substation.Region");
    try std.testing.expect(region != null);
    try std.testing.expectEqualStrings("#_Region1", region.?);

    const voltage_level = refs.get("Substation.VoltageLevel");
    try std.testing.expect(voltage_level != null);
    try std.testing.expectEqualStrings("#_VL1", voltage_level.?);

    // Should NOT include text properties
    try std.testing.expect(refs.get("IdentifiedObject.name") == null);
}

test "CimObject.all_properties - empty object returns empty map" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_SS1\"/>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = xml_scan.find_closing_tag(xml, boundaries.items, 0) catch |err| blk: {
        try std.testing.expectEqual(error.SelfClosingTag, err);
        break :blk 0;
    };
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    var props = try obj.all_properties(gpa);
    defer props.deinit();

    try std.testing.expectEqual(0, props.count());
}

test "CimObject.all_references - empty object returns empty map" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_SS1\"/>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = xml_scan.find_closing_tag(xml, boundaries.items, 0) catch |err| blk: {
        try std.testing.expectEqual(error.SelfClosingTag, err);
        break :blk 0;
    };
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    var refs = try obj.all_references(gpa);
    defer refs.deinit();

    try std.testing.expectEqual(0, refs.count());
}

test "CimObject.all_properties - handles mixed properties and references" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  <cim:Terminal.ConductingEquipment rdf:resource="#_Line1"/>
        \\  <cim:IdentifiedObject.name>Terminal 1</cim:IdentifiedObject.name>
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_Node1"/>
        \\</cim:Terminal>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    var props = try obj.all_properties(gpa);
    defer props.deinit();

    var refs = try obj.all_references(gpa);
    defer refs.deinit();

    // Should have 2 properties
    try std.testing.expectEqual(2, props.count());
    try std.testing.expectEqualStrings("1", props.get("ACDCTerminal.sequenceNumber").?);
    try std.testing.expectEqualStrings("Terminal 1", props.get("IdentifiedObject.name").?);

    // Should have 2 references
    try std.testing.expectEqual(2, refs.count());
    try std.testing.expectEqualStrings("#_Line1", refs.get("Terminal.ConductingEquipment").?);
    try std.testing.expectEqualStrings("#_Node1", refs.get("Terminal.ConnectivityNode").?);
}

test "CimObject child walks - a commented-out child is not a live child" {
    const gpa = std.testing.allocator;

    // Every walk sees the comment as one boundary spanning `<!-- ... -->`.
    // Reading it as an element yields a reference and a property that the
    // document does not assert, and `extract_tag_type` on the bare comment
    // takes its name from the tag that follows it.
    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <!-- <cim:Terminal.ConductingEquipment rdf:resource="#_Stale"/> -->
        \\  <!-- <cim:IdentifiedObject.name>Stale</cim:IdentifiedObject.name> -->
        \\  <!-- plain prose, no markup at all -->
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_Node1"/>
        \\  <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\</cim:Terminal>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    // all_references / all_properties
    var refs = try obj.all_references(gpa);
    defer refs.deinit();
    try std.testing.expectEqual(1, refs.count());
    try std.testing.expectEqualStrings("#_Node1", refs.get("Terminal.ConnectivityNode").?);
    try std.testing.expect(refs.get("Terminal.ConductingEquipment") == null);

    var props = try obj.all_properties(gpa);
    defer props.deinit();
    try std.testing.expectEqual(1, props.count());
    try std.testing.expectEqualStrings("1", props.get("ACDCTerminal.sequenceNumber").?);
    try std.testing.expect(props.get("IdentifiedObject.name") == null);

    // Single-name lookups
    try std.testing.expect(try obj.reference("Terminal.ConductingEquipment") == null);
    try std.testing.expect(try obj.property("IdentifiedObject.name") == null);
    try std.testing.expectEqualStrings("#_Node1", (try obj.reference("Terminal.ConnectivityNode")).?);

    // Batch lookups
    const batch_refs = try obj.references(.{ "Terminal.ConductingEquipment", "Terminal.ConnectivityNode" });
    try std.testing.expect(batch_refs[0] == null);
    try std.testing.expectEqualStrings("#_Node1", batch_refs[1].?);

    const batch_props = try obj.properties(.{ "IdentifiedObject.name", "ACDCTerminal.sequenceNumber" });
    try std.testing.expect(batch_props[0] == null);
    try std.testing.expectEqualStrings("1", batch_props[1].?);
}

test "CimObject child walks - a PI inside an object is not a child" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <?cim:IdentifiedObject.name value="Stale"?>
        \\  <cim:IdentifiedObject.name>Real</cim:IdentifiedObject.name>
        \\</cim:Terminal>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    try std.testing.expectEqualStrings("Real", (try obj.property("IdentifiedObject.name")).?);

    var props = try obj.all_properties(gpa);
    defer props.deinit();
    try std.testing.expectEqual(1, props.count());
    try std.testing.expectEqualStrings("Real", props.get("IdentifiedObject.name").?);
}

test "tag_index.CimObject - properties batch matches individual property" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:ACLineSegment rdf:ID="_Line1">
        \\  <cim:IdentifiedObject.mRID>line-mrid</cim:IdentifiedObject.mRID>
        \\  <cim:IdentifiedObject.name>Line 1</cim:IdentifiedObject.name>
        \\  <cim:ACLineSegment.r>1.5</cim:ACLineSegment.r>
        \\  <cim:ACLineSegment.x>12.3</cim:ACLineSegment.x>
        \\  <cim:ACLineSegment.bch>0.001</cim:ACLineSegment.bch>
        \\  <cim:ACLineSegment.gch>0.0005</cim:ACLineSegment.gch>
        \\</cim:ACLineSegment>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    // Batch fetch
    const props = try obj.properties(.{
        "IdentifiedObject.mRID",
        "IdentifiedObject.name",
        "ACLineSegment.r",
        "ACLineSegment.x",
        "ACLineSegment.bch",
        "ACLineSegment.gch",
    });

    // Verify each matches individual property
    try std.testing.expectEqualStrings("line-mrid", props[0].?);
    try std.testing.expectEqualStrings("Line 1", props[1].?);
    try std.testing.expectEqualStrings("1.5", props[2].?);
    try std.testing.expectEqualStrings("12.3", props[3].?);
    try std.testing.expectEqualStrings("0.001", props[4].?);
    try std.testing.expectEqualStrings("0.0005", props[5].?);

    // Cross-check with individual calls
    try std.testing.expectEqualStrings(props[0].?, (try obj.property("IdentifiedObject.mRID")).?);
    try std.testing.expectEqualStrings(props[2].?, (try obj.property("ACLineSegment.r")).?);
}

test "tag_index.CimObject - properties returns null for missing names" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    const props = try obj.properties(.{
        "IdentifiedObject.name",
        "IdentifiedObject.mRID",
        "NonExistent.property",
    });

    try std.testing.expectEqualStrings("North Station", props[0].?);
    try std.testing.expect(props[1] == null);
    try std.testing.expect(props[2] == null);
}

test "tag_index.CimObject - properties on self-closing tag returns all null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1"/>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const obj = try make_cim_object(xml, boundaries.items, 0, 0);

    const props = try obj.properties(.{
        "IdentifiedObject.name",
        "IdentifiedObject.mRID",
    });

    try std.testing.expect(props[0] == null);
    try std.testing.expect(props[1] == null);
}

test "tag_index.CimObject - references batch matches individual reference" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:IdentifiedObject.name>Terminal 1</cim:IdentifiedObject.name>
        \\  <cim:Terminal.ConductingEquipment rdf:resource="#_Line1"/>
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_Node1"/>
        \\  <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\</cim:Terminal>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    // Batch fetch references
    const refs = try obj.references(.{
        "Terminal.ConductingEquipment",
        "Terminal.ConnectivityNode",
    });

    try std.testing.expectEqualStrings("#_Line1", refs[0].?);
    try std.testing.expectEqualStrings("#_Node1", refs[1].?);

    // Cross-check with individual calls
    try std.testing.expectEqualStrings(refs[0].?, (try obj.reference("Terminal.ConductingEquipment")).?);
    try std.testing.expectEqualStrings(refs[1].?, (try obj.reference("Terminal.ConnectivityNode")).?);
}

test "tag_index.CimObject - references returns null for missing names" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:Terminal.ConductingEquipment rdf:resource="#_Line1"/>
        \\</cim:Terminal>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    const refs = try obj.references(.{
        "Terminal.ConductingEquipment",
        "Terminal.ConnectivityNode",
    });

    try std.testing.expectEqualStrings("#_Line1", refs[0].?);
    try std.testing.expect(refs[1] == null);
}

test "tag_index.CimObject - references on self-closing tag returns all null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1"/>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const obj = try make_cim_object(xml, boundaries.items, 0, 0);

    const refs = try obj.references(.{
        "Terminal.ConductingEquipment",
        "Terminal.ConnectivityNode",
    });

    try std.testing.expect(refs[0] == null);
    try std.testing.expect(refs[1] == null);
}

// ── ChildIterator ─────────────────────────────────────────────────────────────
//
// The one child walk. These tests pin the classification every consumer now
// shares: what counts as a child at all, and property vs. reference.

const CHILD_WALK_XML =
    \\<cim:Terminal rdf:ID="_T1">
    \\  <cim:Terminal.name>Feeder 1</cim:Terminal.name>
    \\  <!-- <cim:Terminal.Ghost rdf:resource="#_GHOST"/> -->
    \\  <?ignore-me rdf:resource="#_PI"?>
    \\  <cim:Terminal.ConductingEquipment rdf:resource="#_CE1"/>
    \\  <cim:Terminal.expanded rdf:resource="#_EX1"></cim:Terminal.expanded>
    \\  <cim:Terminal.empty/>
    \\  <cim:Terminal.blank></cim:Terminal.blank>
    \\</cim:Terminal>
;

test "tag_index.ChildIterator - classifies every child, and only real children" {
    const gpa = std.testing.allocator;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, CHILD_WALK_XML);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(CHILD_WALK_XML, boundaries.items, 0);
    const obj = try make_cim_object(CHILD_WALK_XML, boundaries.items, 0, closing);

    const Expected = struct {
        name: []const u8,
        value: []const u8,
        kind: tag_index.Child.Kind,
        self_closing: bool,
    };
    // The comment and the PI are absent: neither is a child, however much the
    // comment looks like one. Closing boundaries of expanded elements are
    // consumed with their openers, so they are not offered either.
    const expected = [_]Expected{
        .{ .name = "Terminal.name", .value = "Feeder 1", .kind = .property, .self_closing = false },
        .{ .name = "Terminal.ConductingEquipment", .value = "#_CE1", .kind = .reference, .self_closing = true },
        // rdf:resource in expanded form is still a reference -- the kind follows
        // the attribute, not the syntax.
        .{ .name = "Terminal.expanded", .value = "#_EX1", .kind = .reference, .self_closing = false },
        // Both spellings of an empty literal, distinguished only by self_closing.
        .{ .name = "Terminal.empty", .value = "", .kind = .property, .self_closing = true },
        .{ .name = "Terminal.blank", .value = "", .kind = .property, .self_closing = false },
    };

    var seen: usize = 0;
    var it = obj.children();
    while (it.next()) |child| : (seen += 1) {
        try std.testing.expect(seen < expected.len);
        const want = expected[seen];
        try std.testing.expectEqualStrings(want.name, child.name);
        try std.testing.expectEqualStrings(want.value, child.value);
        try std.testing.expectEqual(want.kind, child.kind);
        try std.testing.expectEqual(want.self_closing, child.self_closing);
        try std.testing.expect(!child.malformed_resource);
        // raw is the whole element, whichever form it takes.
        try std.testing.expect(std.mem.startsWith(u8, child.raw, "<cim:"));
        try std.testing.expect(std.mem.endsWith(u8, child.raw, ">"));
    }
    try std.testing.expectEqual(expected.len, seen);
}

test "tag_index.ChildIterator - raw spans the whole element in both forms" {
    const gpa = std.testing.allocator;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, CHILD_WALK_XML);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(CHILD_WALK_XML, boundaries.items, 0);
    const obj = try make_cim_object(CHILD_WALK_XML, boundaries.items, 0, closing);

    var it = obj.children();
    const first = it.next().?;
    try std.testing.expectEqualStrings(
        "<cim:Terminal.name>Feeder 1</cim:Terminal.name>",
        first.raw,
    );
    const self_closed = it.next().?;
    try std.testing.expectEqualStrings(
        "<cim:Terminal.ConductingEquipment rdf:resource=\"#_CE1\"/>",
        self_closed.raw,
    );
    const expanded = it.next().?;
    try std.testing.expectEqualStrings(
        "<cim:Terminal.expanded rdf:resource=\"#_EX1\"></cim:Terminal.expanded>",
        expanded.raw,
    );
}

test "tag_index.ChildIterator - the six walks agree with it" {
    const gpa = std.testing.allocator;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, CHILD_WALK_XML);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(CHILD_WALK_XML, boundaries.items, 0);
    const obj = try make_cim_object(CHILD_WALK_XML, boundaries.items, 0, closing);

    // Text properties: expanded literals only. A self-closing element has no
    // text content, and an rdf:resource carrier is a reference in either form.
    var props = try obj.all_properties(gpa);
    defer props.deinit();
    try std.testing.expectEqual(@as(u32, 2), props.count());
    try std.testing.expectEqualStrings("Feeder 1", props.get("Terminal.name").?);
    try std.testing.expectEqualStrings("", props.get("Terminal.blank").?);
    try std.testing.expect(props.get("Terminal.expanded") == null);
    try std.testing.expect(props.get("Terminal.empty") == null);
    try std.testing.expect(props.get("Terminal.Ghost") == null);

    var refs = try obj.all_references(gpa);
    defer refs.deinit();
    try std.testing.expectEqual(@as(u32, 2), refs.count());
    try std.testing.expectEqualStrings("#_CE1", refs.get("Terminal.ConductingEquipment").?);
    try std.testing.expectEqualStrings("#_EX1", refs.get("Terminal.expanded").?);
    try std.testing.expect(refs.get("Terminal.Ghost") == null);

    // The single-name and batch forms resolve to the same answers.
    try std.testing.expectEqualStrings("Feeder 1", (try obj.property("Terminal.name")).?);
    try std.testing.expect((try obj.property("Terminal.expanded")) == null);
    try std.testing.expect((try obj.property("Terminal.empty")) == null);
    try std.testing.expectEqualStrings("#_EX1", (try obj.reference("Terminal.expanded")).?);
    try std.testing.expect((try obj.reference("Terminal.name")) == null);

    const batch_props = try obj.properties(.{ "Terminal.name", "Terminal.expanded", "Terminal.empty" });
    try std.testing.expectEqualStrings("Feeder 1", batch_props[0].?);
    try std.testing.expect(batch_props[1] == null);
    try std.testing.expect(batch_props[2] == null);

    const batch_refs = try obj.references(.{ "Terminal.ConductingEquipment", "Terminal.expanded", "Terminal.name" });
    try std.testing.expectEqualStrings("#_CE1", batch_refs[0].?);
    try std.testing.expectEqualStrings("#_EX1", batch_refs[1].?);
    try std.testing.expect(batch_refs[2] == null);
}

test "tag_index.ChildIterator - an unreadable rdf:resource fails the query that asked for it" {
    const gpa = std.testing.allocator;

    // The quote never closes inside the tag, so the resource value cannot be
    // read. Topology resolution depends on hearing about this.
    const xml =
        \\<cim:VoltageLevel rdf:ID="_VL1">
        \\  <cim:VoltageLevel.BaseVoltage rdf:resource="#_BV1/>
        \\  <cim:VoltageLevel.name>VL</cim:VoltageLevel.name>
        \\</cim:VoltageLevel>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    const obj = try make_cim_object(xml, boundaries.items, 0, closing);

    var it = obj.children();
    const bad = it.next().?;
    try std.testing.expectEqualStrings("VoltageLevel.BaseVoltage", bad.name);
    try std.testing.expect(bad.malformed_resource);
    // Reported as a property so tolerant walks treat it as "not a reference".
    try std.testing.expectEqual(tag_index.Child.Kind.property, bad.kind);

    // Asked for by name: loud.
    try std.testing.expectError(error.MalformedTag, obj.reference("VoltageLevel.BaseVoltage"));
    try std.testing.expectError(error.MalformedTag, obj.references(.{"VoltageLevel.BaseVoltage"}));

    // Not asked for: the malformed child must not poison an unrelated query.
    try std.testing.expectEqualStrings("VL", (try obj.property("VoltageLevel.name")).?);
    try std.testing.expect((try obj.reference("VoltageLevel.Substation")) == null);

    // Tolerant walks drop it rather than failing the whole object.
    var refs = try obj.all_references(gpa);
    defer refs.deinit();
    try std.testing.expectEqual(@as(u32, 0), refs.count());
}
