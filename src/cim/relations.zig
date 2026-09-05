const std = @import("std");
const uri = @import("uri.zig");
const ReferenceScope = @import("reference_index.zig").ReferenceScope;

const assert = std.debug.assert;

const Key = struct {
    source_type_id: u32,
    property_id: u32,
    target_id: u32,
};

comptime {
    // Keep autoHash on its single-update path instead of hashing fields separately.
    assert(@sizeOf(Key) == 12);
    assert(std.meta.hasUniqueRepresentation(Key));
}

pub const Target = union(enum) {
    object: []const u8,
    enumeration: []const u8,
    unresolved,

    /// Reordering variants changes both comparators' tie-break order.
    pub const Kind = std.meta.Tag(Target);

    pub fn name(self: Target) []const u8 {
        return switch (self) {
            .object, .enumeration => |class| class,
            .unresolved => "",
        };
    }
};

pub const Relation = struct {
    source: []const u8,
    property: []const u8,
    target: Target,
    count: u32,

    /// count descending, then the by_name chain
    pub fn by_count_desc(_: void, a: Relation, b: Relation) bool {
        if (a.count != b.count) return a.count > b.count;
        return by_name({}, a, b);
    }

    /// source → property → target name → kind
    pub fn by_name(_: void, a: Relation, b: Relation) bool {
        switch (std.mem.order(u8, a.source, b.source)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        switch (std.mem.order(u8, a.property, b.property)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        switch (std.mem.order(u8, a.target.name(), b.target.name())) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        // Reached only when a name is shared across kinds, or shared as the
        // empty name every unresolved target carries.
        return @intFromEnum(std.meta.activeTag(a.target)) <
            @intFromEnum(std.meta.activeTag(b.target));
    }
};

pub const Totals = struct {
    references: u64 = 0,
    associations: u64 = 0,
    enumerations: u64 = 0,
    unresolved: u64 = 0,
};

pub const Order = enum { count_desc, name };

pub const RelationCounts = struct {
    relations: []Relation,
    totals: Totals,

    pub const relations_max = 1 << 16;

    pub fn build(
        gpa: std.mem.Allocator,
        scope: *const ReferenceScope,
    ) error{ OutOfMemory, TooManyRelations }!RelationCounts {
        var properties = std.StringHashMap(u32).init(gpa);
        defer properties.deinit();

        var enumerations = std.StringHashMap(u32).init(gpa);
        defer enumerations.deinit();

        var rows = std.AutoHashMap(Key, Relation).init(gpa);
        defer rows.deinit();

        var references_count: u64 = 0;
        var associations_count: u64 = 0;
        var enumerations_count: u64 = 0;
        var unresolved_count: u64 = 0;

        for (0..scope.document_count()) |di| {
            const document_index: u32 = @intCast(di);
            const cim_document = scope.document(document_index);
            var groups = cim_document.type_groups();
            while (groups.next()) |type_group| {
                // Use the element's own class; ID arbitration may select a different object.
                const source_type_id = scope.type_id_by_object(document_index, type_group.start);
                const source = scope.type_name(source_type_id);
                for (type_group.objects) |object| {
                    var children = object.children();
                    while (children.next()) |child| {
                        // Malformed resources have property kind but count as references;
                        // the properties walk must exclude them to avoid double-counting.
                        if (child.kind != .reference and !child.malformed_resource) continue;
                        references_count += 1;

                        const property_id = try intern(&properties, child.name);

                        // Resolve first: object IDs can look like enumeration literals.
                        const target: ClassifiedTarget = blk: {
                            if (child.malformed_resource) {
                                // Malformed resources expose element text, not an IRI we can resolve.
                                unresolved_count += 1;
                                break :blk .{ .target = .unresolved, .id = unresolved_target_id };
                            } else if (scope.type_id_by_reference(child.value)) |target_type_id| {
                                associations_count += 1;
                                break :blk .{
                                    .target = .{ .object = scope.type_name(target_type_id) },
                                    .id = pack_target_id(.object, target_type_id),
                                };
                            } else if (is_enumeration_shape(child.value)) |enumeration_shape| {
                                enumerations_count += 1;
                                break :blk .{
                                    .target = .{ .enumeration = enumeration_shape.class },
                                    .id = pack_target_id(
                                        .enumeration,
                                        try intern(&enumerations, enumeration_shape.class),
                                    ),
                                };
                            } else {
                                unresolved_count += 1;
                                break :blk .{ .target = .unresolved, .id = unresolved_target_id };
                            }
                        };

                        const row = try rows.getOrPut(Key{
                            .source_type_id = source_type_id,
                            .property_id = property_id,
                            .target_id = target.id,
                        });
                        if (row.found_existing) {
                            assert(row.value_ptr.count < std.math.maxInt(u32));
                            row.value_ptr.count += 1;
                        } else {
                            row.value_ptr.* = .{
                                .source = source,
                                .property = child.name,
                                .target = target.target,
                                .count = 1,
                            };
                            if (rows.count() > relations_max) return error.TooManyRelations;
                        }
                    }
                }
            }
        }

        assert(associations_count + enumerations_count + unresolved_count == references_count);

        const relations = try gpa.alloc(Relation, rows.count());
        var written: u32 = 0;
        var row_iterator = rows.valueIterator();
        while (row_iterator.next()) |row| : (written += 1) relations[written] = row.*;
        assert(written == relations.len);

        return .{
            .relations = relations,
            .totals = Totals{
                .references = references_count,
                .associations = associations_count,
                .enumerations = enumerations_count,
                .unresolved = unresolved_count,
            },
        };
    }

    /// Names borrow the documents and scope, so only the row storage is ours to free.
    pub fn deinit(self: *RelationCounts, gpa: std.mem.Allocator) void {
        gpa.free(self.relations);
        self.* = undefined;
    }

    /// Separate storage lets callers keep both orders; the caller frees the copy.
    pub fn sorted(
        self: *const RelationCounts,
        gpa: std.mem.Allocator,
        order: Order,
    ) error{OutOfMemory}![]Relation {
        const relations = try gpa.dupe(Relation, self.relations);
        // std.mem.sort takes the comparator comptime, so the switch picks the
        // call rather than the function value.
        switch (order) {
            .count_desc => {
                std.mem.sort(Relation, relations, {}, Relation.by_count_desc);
                assert_strict_order(relations, Relation.by_count_desc);
            },
            .name => {
                std.mem.sort(Relation, relations, {}, Relation.by_name);
                assert_strict_order(relations, Relation.by_name);
            },
        }
        return relations;
    }
};

/// Adjacent pairs pin down the whole order: strict on every neighbour means no
/// ties survived, which is the property `build` guarantees by keying rows on
/// all four components.
fn assert_strict_order(
    relations: []const Relation,
    comptime less_than: fn (void, Relation, Relation) bool,
) void {
    if (relations.len == 0) return;
    for (relations[0 .. relations.len - 1], relations[1..]) |a, b| {
        assert(less_than({}, a, b));
        assert(!less_than({}, b, a));
    }
}

const ClassifiedTarget = struct {
    target: Target,
    id: u32,
};

/// Kind bits prevent collisions between scope type IDs and local enumeration IDs.
const target_kind_bits = 2;
const target_name_bits = 32 - target_kind_bits;
const target_name_id_max = (1 << target_name_bits) - 1;

fn pack_target_id(kind: Target.Kind, name_id: u32) u32 {
    comptime assert(std.meta.fields(Target.Kind).len <= 1 << target_kind_bits);
    assert(name_id <= target_name_id_max);
    return (@as(u32, @intFromEnum(kind)) << target_name_bits) | name_id;
}

const unresolved_target_id: u32 = pack_target_id(.unresolved, 0);

/// Count-derived IDs stay unique only while entries are never removed.
fn intern(interner: *std.StringHashMap(u32), name: []const u8) error{OutOfMemory}!u32 {
    const entry = try interner.getOrPut(name);
    if (!entry.found_existing) entry.value_ptr.* = interner.count() - 1;
    return entry.value_ptr.*;
}

const EnumerationShape = struct {
    class: []const u8,
    value: []const u8,
};

/// Shape matching tolerates differing CGMES and vendor namespaces.
fn is_enumeration_shape(value: []const u8) ?EnumerationShape {
    const fragment = uri.fragment(value) orelse return null;

    const dot = std.mem.indexOfScalar(u8, fragment, '.') orelse return null;
    const class = fragment[0..dot];
    const literal = fragment[dot + 1 ..];
    if (class.len == 0 or literal.len == 0) return null;
    if (std.mem.indexOfScalar(u8, literal, '.') != null) return null;

    // Reject underscores and hyphens to keep dotted mRIDs out.
    if (!std.ascii.isUpper(class[0])) return null;
    for (class[1..]) |c| if (!std.ascii.isAlphanumeric(c)) return null;

    return .{ .class = class, .value = literal };
}

const testing = std.testing;
const CimDocument = @import("document.zig").CimDocument;
const ReverseRefIndex = @import("refs.zig").ReverseRefIndex;

const cim16_ns = "http://iec.ch/TC57/2013/CIM-schema-cim16#";
const cim100_ns = "http://iec.ch/TC57/CIM100#";
const untracked_ns = "http://example.com/vendor-profile/2029#";

fn expect_enumeration(value: []const u8, class: []const u8, literal: []const u8) !void {
    const shape = is_enumeration_shape(value) orelse {
        std.debug.print("\nexpected enumeration shape for '{s}'\n", .{value});
        return error.TestExpectedEnumerationShape;
    };
    try testing.expectEqualStrings(class, shape.class);
    try testing.expectEqualStrings(literal, shape.value);
}

fn expect_not_enumeration(value: []const u8) !void {
    if (is_enumeration_shape(value)) |shape| {
        std.debug.print(
            "\n'{s}' was read as enumeration '{s}' . '{s}'\n",
            .{ value, shape.class, shape.value },
        );
        return error.TestUnexpectedEnumerationShape;
    }
}

test "is_enumeration_shape: enumeration literals in every namespace" {
    inline for (.{ cim16_ns, cim100_ns, untracked_ns }) |ns| {
        try expect_enumeration(ns ++ "WindingConnection.Y", "WindingConnection", "Y");
        try expect_enumeration(ns ++ "PhaseCode.ABC", "PhaseCode", "ABC");
        try expect_enumeration(
            ns ++ "RegulatingControlModeKind.voltage",
            "RegulatingControlModeKind",
            "voltage",
        );
    }
}

test "is_enumeration_shape: a bare fragment reference is enough" {
    try expect_enumeration("#WindingConnection.Y", "WindingConnection", "Y");
    try expect_enumeration("#Cim16Kind.value", "Cim16Kind", "value");
}

test "is_enumeration_shape: mRIDs, URNs and malformed fragments are not literals" {
    try expect_not_enumeration("#_0aa1ce13-e5d9-4b3a-8f21-9c7a4d2e6b10");
    try expect_not_enumeration(cim16_ns ++ "_0aa1ce13-e5d9-4b3a-8f21-9c7a4d2e6b10");
    try expect_not_enumeration("urn:uuid:0aa1ce13-e5d9-4b3a-8f21-9c7a4d2e6b10");
    try expect_not_enumeration("#lower.case");
    try expect_not_enumeration("#_a.b");
    try expect_not_enumeration("#WindingConnection");
    try expect_not_enumeration("#WindingConnection.");
    try expect_not_enumeration("#A.b.c");
    try expect_not_enumeration(cim100_ns);
    try expect_not_enumeration("#");
    try expect_not_enumeration("#.Y");
    try expect_not_enumeration("#Winding-Connection.Y");
}

test "Target.name is empty for unresolved and the class otherwise" {
    try testing.expectEqualStrings("ACLineSegment", (Target{ .object = "ACLineSegment" }).name());
    try testing.expectEqualStrings("PhaseCode", (Target{ .enumeration = "PhaseCode" }).name());
    const unresolved: Target = .unresolved;
    try testing.expectEqualStrings("", unresolved.name());

    try testing.expect(@intFromEnum(Target.Kind.object) < @intFromEnum(Target.Kind.enumeration));
    try testing.expect(@intFromEnum(Target.Kind.enumeration) < @intFromEnum(Target.Kind.unresolved));
}

fn init_test_document(xml: []const u8) !CimDocument {
    return CimDocument.init(testing.allocator, try testing.allocator.dupe(u8, xml));
}

const mixed_document =
    \\<rdf:RDF>
    \\  <cim:ACLineSegment rdf:ID="_l1">
    \\    <cim:IdentifiedObject.name>Line 1</cim:IdentifiedObject.name>
    \\    <cim:Equipment.EquipmentContainer rdf:resource="#_bv1"/>
    \\    <cim:ACLineSegment.r>0.1</cim:ACLineSegment.r>
    \\    <cim:ConductingEquipment.phases rdf:resource="http://iec.ch/TC57/CIM100#PhaseCode.ABC"/>
    \\    <cim:ACLineSegment.BaseVoltage rdf:resource="#_missing"/>
    \\    <cim:Equipment.aggregate rdf:resource="#_oops/>
    \\  </cim:ACLineSegment>
    \\  <cim:BaseVoltage rdf:ID="_bv1">
    \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\</rdf:RDF>
;

fn expect_totals(counts: RelationCounts, expected: Totals) !void {
    try testing.expectEqual(expected.references, counts.totals.references);
    try testing.expectEqual(expected.associations, counts.totals.associations);
    try testing.expectEqual(expected.enumerations, counts.totals.enumerations);
    try testing.expectEqual(expected.unresolved, counts.totals.unresolved);
}

test "RelationCounts.build: the totals partition the reference count" {
    var model = try init_test_document(mixed_document);
    defer model.deinit(testing.allocator);
    var scope = try ReferenceScope.init(testing.allocator, &.{&model});
    defer scope.deinit(testing.allocator);

    var counts = try RelationCounts.build(testing.allocator, &scope);
    defer counts.deinit(testing.allocator);

    try expect_totals(counts, .{
        .references = 4,
        .associations = 1,
        .enumerations = 1,
        .unresolved = 2,
    });
}

test "RelationCounts.build: a second document resolves the first's dangling reference" {
    // The back-reference also catches walks that skip the second document.
    var primary = try init_test_document(mixed_document);
    defer primary.deinit(testing.allocator);
    var secondary = try init_test_document(
        \\<rdf:RDF>
        \\  <cim:VoltageLevel rdf:ID="_missing">
        \\    <cim:IdentifiedObject.name>VL</cim:IdentifiedObject.name>
        \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_bv1"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    );
    defer secondary.deinit(testing.allocator);

    var scope = try ReferenceScope.init(testing.allocator, &.{ &primary, &secondary });
    defer scope.deinit(testing.allocator);

    var counts = try RelationCounts.build(testing.allocator, &scope);
    defer counts.deinit(testing.allocator);

    try expect_totals(counts, .{
        .references = 5,
        .associations = 3,
        .enumerations = 1,
        .unresolved = 1,
    });
}

test "RelationCounts.build: a malformed rdf:resource is an unresolved reference, not a literal" {
    var model = try init_test_document(
        \\<rdf:RDF>
        \\  <cim:ACLineSegment rdf:ID="_l1">
        \\    <cim:IdentifiedObject.name>Line 1</cim:IdentifiedObject.name>
        \\    <cim:Equipment.aggregate rdf:resource="#_oops/>
        \\  </cim:ACLineSegment>
        \\</rdf:RDF>
    );
    defer model.deinit(testing.allocator);
    var scope = try ReferenceScope.init(testing.allocator, &.{&model});
    defer scope.deinit(testing.allocator);

    var counts = try RelationCounts.build(testing.allocator, &scope);
    defer counts.deinit(testing.allocator);

    try expect_totals(counts, .{
        .references = 1,
        .associations = 0,
        .enumerations = 0,
        .unresolved = 1,
    });
}

test "RelationCounts.build: no references at all is zero totals, not an error" {
    var model = try init_test_document(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_bv1">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:Terminal rdf:ID="_t1"/>
        \\</rdf:RDF>
    );
    defer model.deinit(testing.allocator);
    var scope = try ReferenceScope.init(testing.allocator, &.{&model});
    defer scope.deinit(testing.allocator);

    var counts = try RelationCounts.build(testing.allocator, &scope);
    defer counts.deinit(testing.allocator);

    try expect_totals(counts, .{});
    try testing.expectEqual(@as(usize, 0), counts.relations.len);
}

fn find_row(
    counts: RelationCounts,
    source: []const u8,
    property: []const u8,
    kind: Target.Kind,
    target_name: []const u8,
) ?Relation {
    for (counts.relations) |relation| {
        if (!std.mem.eql(u8, relation.source, source)) continue;
        if (!std.mem.eql(u8, relation.property, property)) continue;
        if (std.meta.activeTag(relation.target) != kind) continue;
        if (!std.mem.eql(u8, relation.target.name(), target_name)) continue;
        return relation;
    }
    return null;
}

fn expect_row(
    counts: RelationCounts,
    source: []const u8,
    property: []const u8,
    kind: Target.Kind,
    target_name: []const u8,
    count: u32,
) !void {
    const relation = find_row(counts, source, property, kind, target_name) orelse {
        std.debug.print(
            "\nno row for {s} . {s} -> .{s} '{s}'\n",
            .{ source, property, @tagName(kind), target_name },
        );
        return error.TestExpectedRelation;
    };
    try testing.expectEqual(count, relation.count);
}

test "RelationCounts.build: one row per distinct triple, counted" {
    var model = try init_test_document(mixed_document);
    defer model.deinit(testing.allocator);
    var scope = try ReferenceScope.init(testing.allocator, &.{&model});
    defer scope.deinit(testing.allocator);

    var counts = try RelationCounts.build(testing.allocator, &scope);
    defer counts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), counts.relations.len);
    try expect_row(counts, "ACLineSegment", "Equipment.EquipmentContainer", .object, "BaseVoltage", 1);
    try expect_row(counts, "ACLineSegment", "ConductingEquipment.phases", .enumeration, "PhaseCode", 1);
    try expect_row(counts, "ACLineSegment", "ACLineSegment.BaseVoltage", .unresolved, "", 1);
    try expect_row(counts, "ACLineSegment", "Equipment.aggregate", .unresolved, "", 1);
}

test "RelationCounts.build: a polymorphic property is one row per target class" {
    // Interleaving properties exposes interners that assign new IDs to existing names.
    var model = try init_test_document(
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_t1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_l1"/>
        \\    <cim:Terminal.phases rdf:resource="http://iec.ch/TC57/CIM100#PhaseCode.ABC"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_t2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_l1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_t3">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_b1"/>
        \\    <cim:Terminal.phases rdf:resource="http://iec.ch/TC57/CIM100#PhaseCode.ABC"/>
        \\  </cim:Terminal>
        \\  <cim:ACLineSegment rdf:ID="_l1"/>
        \\  <cim:Breaker rdf:ID="_b1"/>
        \\</rdf:RDF>
    );
    defer model.deinit(testing.allocator);
    var scope = try ReferenceScope.init(testing.allocator, &.{&model});
    defer scope.deinit(testing.allocator);

    var counts = try RelationCounts.build(testing.allocator, &scope);
    defer counts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), counts.relations.len);
    try expect_row(counts, "Terminal", "Terminal.ConductingEquipment", .object, "ACLineSegment", 2);
    try expect_row(counts, "Terminal", "Terminal.ConductingEquipment", .object, "Breaker", 1);
    try expect_row(counts, "Terminal", "Terminal.phases", .enumeration, "PhaseCode", 2);
    try expect_totals(counts, .{ .references = 5, .associations = 3, .enumerations = 2 });
}

test "RelationCounts.build: an association and an enumeration sharing a class name are two rows" {
    var model = try init_test_document(
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_t1">
        \\    <cim:Terminal.phases rdf:resource="#_p1"/>
        \\    <cim:Terminal.phases rdf:resource="http://iec.ch/TC57/CIM100#PhaseCode.ABC"/>
        \\  </cim:Terminal>
        \\  <cim:PhaseCode rdf:ID="_p1"/>
        \\</rdf:RDF>
    );
    defer model.deinit(testing.allocator);
    var scope = try ReferenceScope.init(testing.allocator, &.{&model});
    defer scope.deinit(testing.allocator);

    var counts = try RelationCounts.build(testing.allocator, &scope);
    defer counts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), counts.relations.len);
    try expect_row(counts, "Terminal", "Terminal.phases", .object, "PhaseCode", 1);
    try expect_row(counts, "Terminal", "Terminal.phases", .enumeration, "PhaseCode", 1);
    try expect_totals(counts, .{ .references = 2, .associations = 1, .enumerations = 1 });
}

test "RelationCounts.build: resolution beats the shape rule" {
    var model = try init_test_document(
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_t1">
        \\    <cim:Terminal.phases rdf:resource="#PhaseCode.ABC"/>
        \\  </cim:Terminal>
        \\  <cim:PhaseCode rdf:ID="PhaseCode.ABC"/>
        \\</rdf:RDF>
    );
    defer model.deinit(testing.allocator);
    var scope = try ReferenceScope.init(testing.allocator, &.{&model});
    defer scope.deinit(testing.allocator);

    var counts = try RelationCounts.build(testing.allocator, &scope);
    defer counts.deinit(testing.allocator);

    try expect_totals(counts, .{ .references = 1, .associations = 1 });
    try expect_row(counts, "Terminal", "Terminal.phases", .object, "PhaseCode", 1);
}

fn expect_relation(expected: Relation, actual: Relation) !void {
    try testing.expectEqualStrings(expected.source, actual.source);
    try testing.expectEqualStrings(expected.property, actual.property);
    try testing.expectEqual(std.meta.activeTag(expected.target), std.meta.activeTag(actual.target));
    try testing.expectEqualStrings(expected.target.name(), actual.target.name());
    try testing.expectEqual(expected.count, actual.count);
}

/// One row per level of both chains: `_line` is alone on source, `_breaker` on
/// property, and the last three share (source, property) so only the target
/// name and then the kind can separate them. `_line` also carries the odd
/// count, so the two orders disagree about where it goes.
const sort_fixture = [_]Relation{
    .{ .source = "Terminal", .property = "Terminal.phases", .target = .{ .object = "PhaseCode" }, .count = 4 },
    .{ .source = "ACLineSegment", .property = "Equipment.EquipmentContainer", .target = .{ .object = "Line" }, .count = 1 },
    .{ .source = "Terminal", .property = "Terminal.phases", .target = .unresolved, .count = 4 },
    .{ .source = "Terminal", .property = "Terminal.ConductingEquipment", .target = .{ .object = "Breaker" }, .count = 4 },
    .{ .source = "Terminal", .property = "Terminal.phases", .target = .{ .enumeration = "PhaseCode" }, .count = 4 },
};

const sort_fixture_object = sort_fixture[0];
const sort_fixture_line = sort_fixture[1];
const sort_fixture_unresolved = sort_fixture[2];
const sort_fixture_breaker = sort_fixture[3];
const sort_fixture_enumeration = sort_fixture[4];

fn expect_sorted(rows: []Relation, order: Order, expected: []const Relation) !void {
    const counts = RelationCounts{ .relations = rows, .totals = .{} };
    const got = try counts.sorted(testing.allocator, order);
    defer testing.allocator.free(got);

    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, have| try expect_relation(want, have);
}

test "Relation.by_name: source, then property, then target name, then kind" {
    var rows = sort_fixture;
    try expect_sorted(&rows, .name, &.{
        sort_fixture_line,
        sort_fixture_breaker,
        // An unresolved target's empty name sorts ahead of every real one, so
        // the kind tie-break is reached only by the two PhaseCode rows.
        sort_fixture_unresolved,
        sort_fixture_object,
        sort_fixture_enumeration,
    });
}

test "Relation.by_count_desc: count first, then the by_name chain" {
    var rows = sort_fixture;
    try expect_sorted(&rows, .count_desc, &.{
        sort_fixture_breaker,
        sort_fixture_unresolved,
        sort_fixture_object,
        sort_fixture_enumeration,
        sort_fixture_line,
    });
}

test "RelationCounts.sorted: the result does not depend on the input order" {
    var forward = sort_fixture;
    var reversed = sort_fixture;
    std.mem.reverse(Relation, &reversed);

    for ([_]Order{ .count_desc, .name }) |order| {
        const from_forward = RelationCounts{ .relations = &forward, .totals = .{} };
        const from_reversed = RelationCounts{ .relations = &reversed, .totals = .{} };

        const a = try from_forward.sorted(testing.allocator, order);
        defer testing.allocator.free(a);
        const b = try from_reversed.sorted(testing.allocator, order);
        defer testing.allocator.free(b);

        for (a, b) |x, y| try expect_relation(x, y);
    }
}

test "RelationCounts.sorted: a copy, so both orders stay valid at once" {
    var rows = sort_fixture;
    const counts = RelationCounts{ .relations = &rows, .totals = .{} };

    const by_count = try counts.sorted(testing.allocator, .count_desc);
    defer testing.allocator.free(by_count);
    const by_name = try counts.sorted(testing.allocator, .name);
    defer testing.allocator.free(by_name);

    try expect_relation(sort_fixture_breaker, by_count[0]);
    try expect_relation(sort_fixture_line, by_name[0]);
    for (sort_fixture, counts.relations) |untouched, row| try expect_relation(untouched, row);
}

test "RelationCounts.build: association rows agree with ReverseRefIndex" {
    // Constrained so the two are comparable: one document, no overlays, rdf:ID
    // form throughout, and nothing malformed.
    var model = try init_test_document(
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_t1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_l1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_t2">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_l1"/>
        \\  </cim:Terminal>
        \\  <cim:Terminal rdf:ID="_t3">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_b1"/>
        \\  </cim:Terminal>
        \\  <cim:ACLineSegment rdf:ID="_l1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_vl1"/>
        \\  </cim:ACLineSegment>
        \\  <cim:Breaker rdf:ID="_b1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_vl1"/>
        \\  </cim:Breaker>
        \\  <cim:VoltageLevel rdf:ID="_vl1"/>
        \\</rdf:RDF>
    );
    defer model.deinit(testing.allocator);
    var scope = try ReferenceScope.init(testing.allocator, &.{&model});
    defer scope.deinit(testing.allocator);

    var index = try ReverseRefIndex.build(testing.allocator, &model);
    defer index.deinit(testing.allocator);

    var counts = try RelationCounts.build(testing.allocator, &scope);
    defer counts.deinit(testing.allocator);

    var checked: u32 = 0;
    for (counts.relations) |row| {
        const target_class = switch (row.target) {
            .object => |class| class,
            .enumeration, .unresolved => continue,
        };
        var edges: u32 = 0;
        for (model.objects) |object| {
            if (!std.mem.eql(u8, object.type_name(), target_class)) continue;
            for (index.lookup(object.id())) |edge| {
                if (!std.mem.eql(u8, edge.referrer_type, row.source)) continue;
                if (!std.mem.eql(u8, edge.reference_name, row.property)) continue;
                edges += 1;
            }
        }
        try testing.expectEqual(row.count, edges);
        checked += 1;
    }
    // A loop that compared nothing would pass just as quietly.
    try testing.expectEqual(@as(u32, 4), checked);
}

/// `property_count` distinct properties on one object, every one of them
/// dangling. The targets all collapse onto the unresolved sentinel, so the
/// property is the only thing making the rows distinct.
fn document_with_distinct_properties(property_count: u32) !CimDocument {
    var xml: std.ArrayListUnmanaged(u8) = .empty;
    errdefer xml.deinit(testing.allocator);

    try xml.appendSlice(testing.allocator,
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_t1">
        \\
    );
    for (0..property_count) |i| {
        var line: [80]u8 = undefined;
        try xml.appendSlice(testing.allocator, try std.fmt.bufPrint(
            &line,
            "    <cim:Terminal.p{d} rdf:resource=\"#_missing\"/>\n",
            .{i},
        ));
    }
    try xml.appendSlice(testing.allocator,
        \\  </cim:Terminal>
        \\</rdf:RDF>
    );

    const owned = try xml.toOwnedSlice(testing.allocator);
    errdefer testing.allocator.free(owned);
    return CimDocument.init(testing.allocator, owned);
}

test "RelationCounts.build: exactly relations_max distinct rows is accepted" {
    var model = try document_with_distinct_properties(RelationCounts.relations_max);
    defer model.deinit(testing.allocator);
    var scope = try ReferenceScope.init(testing.allocator, &.{&model});
    defer scope.deinit(testing.allocator);

    var counts = try RelationCounts.build(testing.allocator, &scope);
    defer counts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, RelationCounts.relations_max), counts.relations.len);
}

test "RelationCounts.build: one row past relations_max is an error, and frees what it had" {
    var model = try document_with_distinct_properties(RelationCounts.relations_max + 1);
    defer model.deinit(testing.allocator);
    var scope = try ReferenceScope.init(testing.allocator, &.{&model});
    defer scope.deinit(testing.allocator);

    // Unwrapped by hand rather than with expectError: an unexpected success
    // owns rows that have to be freed, or the leak check fires instead of the
    // assertion and buries which one actually broke.
    if (RelationCounts.build(testing.allocator, &scope)) |built| {
        var counts = built;
        counts.deinit(testing.allocator);
        return error.TestExpectedTooManyRelations;
    } else |err| {
        // The abandoned rows and both interners leak here if the error path
        // skips a deinit; testing.allocator is what notices.
        try testing.expectEqual(error.TooManyRelations, err);
    }
}

fn build_then_free(gpa: std.mem.Allocator, scope: *const ReferenceScope) !void {
    var counts = try RelationCounts.build(gpa, scope);
    counts.deinit(gpa);
}

fn sort_then_free(gpa: std.mem.Allocator, counts: *const RelationCounts) !void {
    const by_count = try counts.sorted(gpa, .count_desc);
    defer gpa.free(by_count);
    const by_name = try counts.sorted(gpa, .name);
    gpa.free(by_name);
}

test "RelationCounts: every allocation failure unwinds without leaking" {
    var model = try init_test_document(mixed_document);
    defer model.deinit(testing.allocator);
    var scope = try ReferenceScope.init(testing.allocator, &.{&model});
    defer scope.deinit(testing.allocator);

    try testing.checkAllAllocationFailures(testing.allocator, build_then_free, .{&scope});

    var counts = try RelationCounts.build(testing.allocator, &scope);
    defer counts.deinit(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, sort_then_free, .{&counts});
}
