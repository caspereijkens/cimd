//! ChildTable tests.
//!
//! The table is built through `ChildIterator`, so agreement is structural
//! rather than coincidental. These tests still check it: the point is to catch a
//! future change to either side that breaks the equivalence, since validation
//! reads the table and everything else reads the iterator, and a silent
//! divergence between them would show up only as a wrong report.

const std = @import("std");
const tag_index = @import("tag_index.zig");
const ChildTable = @import("child_table.zig").ChildTable;
const CimDocument = @import("document.zig").CimDocument;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Every shape the classification has to get right, in two objects so the
/// per-object ranges are exercised too: a property, a commented-out child that
/// looks exactly like a real one, a processing instruction, both reference
/// syntaxes, and both empty-literal syntaxes.
const TABLE_XML =
    \\<rdf:RDF>
    \\  <cim:Terminal rdf:ID="_T1">
    \\    <cim:Terminal.name>Feeder 1</cim:Terminal.name>
    \\    <!-- <cim:Terminal.Ghost rdf:resource="#_GHOST"/> -->
    \\    <?ignore-me rdf:resource="#_PI"?>
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_CE1"/>
    \\    <cim:Terminal.expanded rdf:resource="#_EX1"></cim:Terminal.expanded>
    \\    <cim:Terminal.empty/>
    \\    <cim:Terminal.blank></cim:Terminal.blank>
    \\  </cim:Terminal>
    \\  <cim:Substation rdf:ID="_SS1">
    \\    <cim:IdentifiedObject.name>Station A</cim:IdentifiedObject.name>
    \\  </cim:Substation>
    \\</rdf:RDF>
;

fn build(gpa: std.mem.Allocator, xml: []const u8) !struct { CimDocument, ChildTable } {
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    errdefer model.deinit(gpa);
    const table = try ChildTable.build(gpa, &model);
    return .{ model, table };
}

test "ChildTable - agrees with ChildIterator on every child of every object" {
    const gpa = std.testing.allocator;
    var model, var table = try build(gpa, TABLE_XML);
    defer model.deinit(gpa);
    defer table.deinit(gpa);

    var total: u32 = 0;
    for (model.objects, 0..) |obj, i| {
        const children = table.children_of(@intCast(i));
        var it = obj.children();
        var n: u32 = 0;
        while (it.next()) |child| : (n += 1) {
            try expect(n < children.tags.len);
            const tag = children.tags[n];
            const span = children.spans[n];

            try expectEqualStrings(child.name, table.name_of(ChildTable.name_id(tag)));
            try expectEqual(child.kind == .reference, ChildTable.is_reference(tag));
            try expectEqualStrings(child.value, table.value_of(span));
        }
        // Neither side may have children the other does not.
        try expectEqual(n, children.tags.len);
        total += n;
    }
    try expectEqual(total, @as(u32, @intCast(table.tags.len)));
}

test "ChildTable - excludes comments, processing instructions and closing tags" {
    const gpa = std.testing.allocator;
    var model, var table = try build(gpa, TABLE_XML);
    defer model.deinit(gpa);
    defer table.deinit(gpa);

    const terminal = model.id_to_index.get("_T1").?;
    const children = table.children_of(terminal);
    // Five real children out of eleven boundaries in the object's span: the
    // comment that looks like `Terminal.Ghost`, the PI, and three closing tags
    // are all absent. A walk that only skipped '/' would report seven.
    try expectEqual(@as(usize, 5), children.tags.len);

    const names = [_][]const u8{
        "Terminal.name",
        "Terminal.ConductingEquipment",
        "Terminal.expanded",
        "Terminal.empty",
        "Terminal.blank",
    };
    for (children.tags, names) |tag, want| {
        try expectEqualStrings(want, table.name_of(ChildTable.name_id(tag)));
    }
    // The ghost never got interned at all, so no rule can match it by name.
    try expectEqual(ChildTable.absent, table.id_of("Terminal.Ghost"));
}

test "ChildTable - kind follows rdf:resource, not the element syntax" {
    const gpa = std.testing.allocator;
    var model, var table = try build(gpa, TABLE_XML);
    defer model.deinit(gpa);
    defer table.deinit(gpa);

    const children = table.children_of(model.id_to_index.get("_T1").?);
    const expected = [_]struct { reference: bool, value: []const u8 }{
        .{ .reference = false, .value = "Feeder 1" },
        .{ .reference = true, .value = "#_CE1" },
        // Expanded, but carries rdf:resource: still a reference.
        .{ .reference = true, .value = "#_EX1" },
        // Both empty-literal spellings read back as an empty value, including
        // the self-closing one the iterator reports as the "" constant rather
        // than a slice of the document.
        .{ .reference = false, .value = "" },
        .{ .reference = false, .value = "" },
    };
    for (children.tags, children.spans, expected) |tag, span, want| {
        try expectEqual(want.reference, ChildTable.is_reference(tag));
        try expectEqualStrings(want.value, table.value_of(span));
    }
}

test "ChildTable - ranges are contiguous, ordered, and cover every child" {
    const gpa = std.testing.allocator;
    var model, var table = try build(gpa, TABLE_XML);
    defer model.deinit(gpa);
    defer table.deinit(gpa);

    try expectEqual(model.objects.len + 1, table.child_start.len);
    try expectEqual(@as(u32, 0), table.child_start[0]);
    try expectEqual(@as(u32, @intCast(table.tags.len)), table.child_start[model.objects.len]);
    for (1..table.child_start.len) |i| {
        try expect(table.child_start[i] >= table.child_start[i - 1]);
    }
    try expectEqual(table.tags.len, table.spans.len);
}

test "ChildTable - an absent name is inert, and every real id is a valid name" {
    const gpa = std.testing.allocator;
    var model, var table = try build(gpa, TABLE_XML);
    defer model.deinit(gpa);
    defer table.deinit(gpa);

    // The interning contract validation depends on: a rule naming something the
    // document never uses gets a sentinel that no child can equal, so it matches
    // nothing rather than aliasing onto a real name.
    try expectEqual(ChildTable.absent, table.id_of("Switch.open"));
    try expectEqual(ChildTable.absent, table.id_of(""));
    for (table.tags) |tag| {
        try expect(ChildTable.name_id(tag) != ChildTable.absent);
        try expect(ChildTable.name_id(tag) < table.names.items.len);
    }
    // A name that is present resolves to itself.
    const id = table.id_of("Terminal.name");
    try expect(id != ChildTable.absent);
    try expectEqualStrings("Terminal.name", table.name_of(id));
}

fn build_then_free(gpa: std.mem.Allocator, xml: []const u8) !void {
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);
    var table = try ChildTable.build(gpa, &model);
    table.deinit(gpa);
}

test "ChildTable - build frees everything it took when an allocation fails" {
    // `build` hands three separate allocations plus two containers to its return
    // value, and `toOwnedSlice` empties the list it takes from -- so a failure
    // between two transfers leaves an allocation that no list-level errdefer can
    // still reach. This runs the whole path once per allocation site with that
    // site failing, and reports any bytes not given back.
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        build_then_free,
        .{TABLE_XML},
    );
}

test "ChildTable - an object with no children gets an empty range" {
    const gpa = std.testing.allocator;
    var model, var table = try build(gpa,
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\  <cim:Substation rdf:ID="_SS2">
        \\    <cim:IdentifiedObject.name>B</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    );
    defer model.deinit(gpa);
    defer table.deinit(gpa);

    try expectEqual(@as(usize, 0), table.children_of(model.id_to_index.get("_SS1").?).tags.len);
    try expectEqual(@as(usize, 1), table.children_of(model.id_to_index.get("_SS2").?).tags.len);
}

test "ChildTable - a malformed rdf:resource is a property, matching the iterator" {
    const gpa = std.testing.allocator;
    // The resource value never closes inside the tag. ChildIterator reports this
    // as a property with malformed_resource set; the table keeps the property
    // classification, which is what validation compared before it existed.
    var model, var table = try build(gpa,
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_CE1 />
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );
    defer model.deinit(gpa);
    defer table.deinit(gpa);

    const children = table.children_of(model.id_to_index.get("_T1").?);
    var it = model.objects[model.id_to_index.get("_T1").?].children();
    var n: u32 = 0;
    while (it.next()) |child| : (n += 1) {
        try expectEqual(child.kind == .reference, ChildTable.is_reference(children.tags[n]));
        try expectEqualStrings(child.value, table.value_of(children.spans[n]));
    }
    try expectEqual(n, children.tags.len);
}
