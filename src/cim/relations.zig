//! Reference relationships as a histogram.
//!
//! `refs.zig` answers "what points at this object". This answers the question
//! one level up: across a whole scope, which (source class, property, target)
//! triples occur at all, and how often. That is the association structure of a
//! dataset -- a few hundred rows for a grid of a million objects -- so a
//! consumer can inspect how a model is wired without processing objects.
//!
//! Every name here borrows the documents' XML or the scope's interned type
//! table. Both must outlive the results, as everywhere else in the library.

const std = @import("std");
const uri = @import("uri.zig");
const ReferenceScope = @import("reference_index.zig").ReferenceScope;

const assert = std.debug.assert;

/// The aggregation key: one row per distinct (source class, property, target).
///
/// Three ids rather than three strings, so a reference costs one hash of twelve
/// bytes instead of three string hashes. All three are build-local -- the
/// scope's table for the source class, this build's intern maps for the rest --
/// and mean nothing once `build` returns, which is why they never leave it.
const Key = struct {
    source_type_id: u32,
    property_id: u32,
    target_id: u32,
};

comptime {
    // What makes the key one hash and not three: with no padding,
    // `std.hash.autoHash` takes its unique-representation path and hashes the
    // twelve bytes in a single update rather than walking fields. A field of
    // another width would still compile and would quietly cost the slower hash,
    // so the property the design rests on is asserted rather than assumed.
    assert(@sizeOf(Key) == 12);
    assert(std.meta.hasUniqueRepresentation(Key));
}

/// What one reference points at.
///
/// The three arms partition every counted reference -- it resolves, or it is
/// shaped like an enumeration literal, or it is neither -- which is what lets
/// the walk assert its totals against the reference count.
pub const Target = union(enum) {
    /// The reference resolved to an object in the scope. The payload is that
    /// object's class from the scope's interned table, not the referring
    /// element's guess at it.
    object: []const u8,
    /// Unresolved, but shaped like an enumeration literal: the payload is the
    /// class before the dot, `WindingConnection` for `...#WindingConnection.Y`.
    /// Counted per class and not per literal, so a property with five observed
    /// values is one row.
    enumeration: []const u8,
    /// Neither: a dangling reference, an alias the scope poisoned, or a
    /// malformed `rdf:resource`. Carries no name, because there is none that
    /// would be true.
    unresolved,

    /// Declaration order above is the sort order -- object < enumeration <
    /// unresolved. Named rather than left implicit because both comparators
    /// tie-break on it, so reordering the arms would silently reorder output.
    pub const Kind = std.meta.Tag(Target);

    /// The target's name, empty for `.unresolved`: an unresolved row sorts as
    /// if its target were the empty string.
    pub fn name(self: Target) []const u8 {
        return switch (self) {
            .object, .enumeration => |class| class,
            .unresolved => "",
        };
    }
};

/// One row: a (source class, property, target) triple and how often it occurs.
pub const Relation = struct {
    /// Class of the element the reference was written on -- its own class, not
    /// the one arbitration gave whatever id it carries. Unlike the target it
    /// carries no order-dependence: every element is walked exactly once
    /// whatever order the documents arrived in.
    source: []const u8,
    /// The full property name, `Equipment.EquipmentContainer` rather than
    /// `EquipmentContainer`. The prefix is the domain class, and dropping it
    /// would merge two properties that share a short name.
    property: []const u8,
    target: Target,
    count: u32,

    /// Descending count, then source, property, target name alphabetically,
    /// then target kind.
    ///
    /// Kind comes last and makes the comparator total: no two rows share all
    /// four key components by construction, so the tie-break is reached only
    /// where an association and an enumeration share a class name under one
    /// (source, property), and it separates them.
    pub fn by_count_desc(_: void, a: Relation, b: Relation) bool {
        _ = a;
        _ = b;
        @panic("TODO(#88): Relation.by_count_desc");
    }

    /// `by_count_desc` without the count: source, property, target name, then
    /// target kind.
    pub fn by_name(_: void, a: Relation, b: Relation) bool {
        _ = a;
        _ = b;
        @panic("TODO(#88): Relation.by_name");
    }
};

/// The reference count split three ways, so a caller can see the partition
/// without summing the rows.
///
/// u64 where the per-row counts are u32: a row is bounded by `relations_max`
/// pressure on distinct triples, but the totals are bounded only by the size
/// of the scope, and a grid already carries millions of references.
pub const Totals = struct {
    /// Every counted child: `.reference` kind, plus the malformed
    /// `rdf:resource` children `ChildIterator` reports as `.property`.
    references: u64 = 0,
    associations: u64 = 0,
    enumerations: u64 = 0,
    unresolved: u64 = 0,
};

/// Which order `sorted` returns rows in. Exactly two, because those are the
/// two questions: what is most common, and where is a given property.
pub const Order = enum { count_desc, name };

pub const RelationCounts = struct {
    /// Owned by this struct, one row per distinct (source, property, target).
    relations: []Relation,
    totals: Totals,

    /// A grid's association structure is a few hundred rows; five figures
    /// means the walk found something that is not a CIM model. Returned as an
    /// error rather than asserted: the count is a property of the caller's
    /// input, and input is checked, not asserted.
    pub const relations_max = 1 << 16;

    /// Counts every reference in every document the scope was built over.
    ///
    /// Takes the scope alone: it is the only thing that knows both which
    /// documents were indexe.d and how to resolve against them, so there is no
    /// way to hand this a document the scope has not seen.
    pub fn build(
        gpa: std.mem.Allocator,
        scope: *const ReferenceScope,
    ) error{ OutOfMemory, TooManyRelations }!RelationCounts {
        // Both maps and the histogram are build-locals that die with this
        // call, so all three take the managed form -- the same split the
        // library keeps everywhere: managed for a local (the scope's own
        // interner, document.zig's type counts), unmanaged for a field that
        // outlives the function that filled it.

        // Property name -> property_id: the one unavoidable per-reference
        // string hash. Keys borrow the documents' XML, which outlives the map.
        var properties = std.StringHashMap(u32).init(gpa);
        defer properties.deinit();

        // Enumeration class -> the name half of its target_id. A separate id
        // space from the scope's type ids, which is safe only because the kind
        // bits keep the two from ever being compared.
        var enumerations = std.StringHashMap(u32).init(gpa);
        defer enumerations.deinit();

        // The histogram. Freed on every path: on the error paths this is what
        // frees the partial state, and on the success path the rows have been
        // copied out into the caller's slice by then.
        var rows = std.AutoHashMap(Key, Relation).init(gpa);
        defer rows.deinit();

        // u64: bounded by the size of the scope, not by `relations_max`.
        var references_count: u64 = 0;
        var associations_count: u64 = 0;
        var enumerations_count: u64 = 0;
        var unresolved_count: u64 = 0;

        for (0..scope.document_count()) |di| {
            const document_index: u32 = @intCast(di);
            const cim_document = scope.document(document_index);
            var groups = cim_document.type_groups();
            while (groups.next()) |type_group| {
                // Once per group rather than once per object: every element in
                // it has the same class, and it is the element's own class,
                // not the one arbitration gave whatever id it carries.
                const source_type_id = scope.type_id_by_object(document_index, type_group.start);
                // Through the id rather than `type_group.type_name`, so the
                // name a row carries and the id its key holds cannot be read
                // from two different places and disagree.
                const source = scope.type_name(source_type_id);
                for (type_group.objects) |object| {
                    var children = object.children();
                    while (children.next()) |child| {
                        // A malformed `rdf:resource` is reported as a `.property`
                        // so tolerant walks keep going, but it is still an
                        // rdf:resource occurrence. Guard and classification share
                        // the one condition, so they cannot drift apart. The
                        // properties counterpart must exclude these same
                        // children, or the two commands double-count them.
                        if (child.kind != .reference and !child.malformed_resource) continue;
                        references_count += 1;

                        const property_id = try intern(&properties, child.name);

                        // Resolution first, so the shape rule can never outvote
                        // real data: an object whose id happens to read as
                        // `Class.value` is still an object.
                        const target: ClassifiedTarget = blk: {
                            if (child.malformed_resource) {
                                // `value` is the element's text -- empty for the
                                // self-closing form -- and never the truncated
                                // IRI, so there is nothing here to resolve or
                                // match a shape against.
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
                            // Checked where the counter increments, which is
                            // the only place it can be reached, rather than
                            // once at the end where it would already be wrong.
                            assert(row.value_ptr.count < std.math.maxInt(u32));
                            row.value_ptr.count += 1;
                        } else {
                            row.value_ptr.* = .{
                                .source = source,
                                .property = child.name,
                                .target = target.target,
                                .count = 1,
                            };
                            // After the insert, since only the map knows whether
                            // the key was new -- and after the row is filled, so
                            // `rows` never holds a value nothing has written.
                            // The deferred deinit frees what accumulated.
                            if (rows.count() > relations_max) return error.TooManyRelations;
                        }
                    }
                }
            }
        }

        // Pairs with the per-reference classification: every counted child
        // took exactly one arm, so the three must add back up.
        assert(associations_count + enumerations_count + unresolved_count == references_count);

        // Copied out: the map's storage is this function's, the rows are the
        // caller's. Nothing after this allocation can fail, so it needs no
        // errdefer.
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

    /// The rows only: every name in them borrows the documents' XML or the
    /// scope's interned table, and neither is this struct's to free.
    pub fn deinit(self: *RelationCounts, gpa: std.mem.Allocator) void {
        gpa.free(self.relations);
        self.* = undefined;
    }

    /// A copy of the rows in `order`. The caller frees it; the counts keep
    /// their own storage, so a caller may ask for both orders.
    pub fn sorted(
        self: *const RelationCounts,
        gpa: std.mem.Allocator,
        order: Order,
    ) error{OutOfMemory}![]Relation {
        _ = self;
        _ = gpa;
        _ = order;
        @panic("TODO(#88): RelationCounts.sorted");
    }
};

/// A classified target and the key component that stands for it. The two are
/// produced together so the name a row carries and the id its key holds always
/// come from one resolution, and cannot drift into disagreeing about what the
/// target is.
const ClassifiedTarget = struct {
    target: Target,
    id: u32,
};

/// `target_id`'s layout: the kind in the top bits, the name's id below.
///
/// The kind has to be in the key. An association and an enumeration stay
/// distinct even when the class name matches -- if they collided here the two
/// rows would have merged long before the comparators' kind tie-break could
/// separate them. Carrying it also lets two id spaces share one field: an
/// object's id comes from the scope's interned table and an enumeration's from
/// a map local to this build, and the kind bits mean the two are never compared.
const target_kind_bits = 2;
const target_name_bits = 32 - target_kind_bits;
const target_name_id_max = (1 << target_name_bits) - 1;

fn pack_target_id(kind: Target.Kind, name_id: u32) u32 {
    comptime assert(std.meta.fields(Target.Kind).len <= 1 << target_kind_bits);
    assert(name_id <= target_name_id_max);
    return (@as(u32, @intFromEnum(kind)) << target_name_bits) | name_id;
}

/// The single sentinel for `.unresolved`: there is no name to encode, so every
/// unresolved target under one (source, property) is one row, whatever it was
/// that failed to resolve.
const unresolved_target_id: u32 = pack_target_id(.unresolved, 0);

/// Mint a stable id for `name`, dense from zero in first-sight order.
///
/// `getOrPut` hands back a slot and not an id: `found_existing` says whether
/// this is the first sighting, and the value is the caller's to fill. The count
/// after insertion is the id, so nothing here carries a counter -- which holds
/// only because the map is added to and never removed from.
fn intern(interner: *std.StringHashMap(u32), name: []const u8) error{OutOfMemory}!u32 {
    const entry = try interner.getOrPut(name);
    // Guarded: rewriting an existing entry would mint a second id for one name
    // and split its rows in two.
    if (!entry.found_existing) entry.value_ptr.* = interner.count() - 1;
    return entry.value_ptr.*;
}

/// The two halves of an enumeration literal: `WindingConnection` and `Y`.
const EnumerationShape = struct {
    class: []const u8,
    value: []const u8,
};

/// Recognise an enumeration literal by its shape, e.g.
/// `http://iec.ch/TC57/CIM100#WindingConnection.Y`.
///
/// A shape test and deliberately not a namespace test. CGMES 2.4.15 and 3.0
/// declare different namespaces, exports bind them to prefixes of their own,
/// and a namespace list would have to grow once per vendor -- while the shape
/// is identical in all of them.
///
/// Reached only after resolution has already failed, so it can never outvote
/// real data. What it must not do is swallow an mRID, and the character rules
/// are chosen for exactly that: a bare UUID fragment has no dot, and one that
/// does have a dot is still rejected by its leading underscore or a hyphen.
fn is_enumeration_shape(value: []const u8) ?EnumerationShape {
    // The text after the last `#`. No fragment marker at all is a URN or a
    // path IRI, neither of which spells an enumeration literal in any export.
    const fragment = uri.fragment(value) orelse return null;

    // Split on the first dot, which is where the ticket puts the class/value
    // boundary. It is not the guard against a second dot -- `#A.b.c` is out
    // either way, by the value check below when splitting here and by the
    // class character rule when splitting on the last dot instead.
    const dot = std.mem.indexOfScalar(u8, fragment, '.') orelse return null;
    const class = fragment[0..dot];
    const literal = fragment[dot + 1 ..];
    if (class.len == 0 or literal.len == 0) return null;
    if (std.mem.indexOfScalar(u8, literal, '.') != null) return null;

    // A CIM class name: capital first, alphanumeric after. No `_` and no `-`,
    // which is what an mRID containing a dot trips over.
    if (!std.ascii.isUpper(class[0])) return null;
    for (class[1..]) |c| if (!std.ascii.isAlphanumeric(c)) return null;

    return .{ .class = class, .value = literal };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const CimDocument = @import("document.zig").CimDocument;

// The two namespaces CGMES ships, plus one nothing in this repo tracks. The
// rule under test is a shape rule, so all three must behave identically.
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
    // Nothing in the rule needs the namespace, so the compact form an export
    // may write instead reads the same.
    try expect_enumeration("#WindingConnection.Y", "WindingConnection", "Y");
    // Digits are class-name characters; only `_` and `-` are not.
    try expect_enumeration("#Cim16Kind.value", "Cim16Kind", "value");
}

test "is_enumeration_shape: mRIDs, URNs and malformed fragments are not literals" {
    // An mRID fragment: no dot at all, so nothing to split.
    try expect_not_enumeration("#_0aa1ce13-e5d9-4b3a-8f21-9c7a4d2e6b10");
    try expect_not_enumeration(cim16_ns ++ "_0aa1ce13-e5d9-4b3a-8f21-9c7a4d2e6b10");
    // A URN carries no fragment marker.
    try expect_not_enumeration("urn:uuid:0aa1ce13-e5d9-4b3a-8f21-9c7a4d2e6b10");
    // Class must open with A-Z.
    try expect_not_enumeration("#lower.case");
    // The underscore rule, reached only because this one does have a dot --
    // this is the case that keeps a dotted mRID out of the histogram.
    try expect_not_enumeration("#_a.b");
    // A fragment with no dot is an id, not a literal.
    try expect_not_enumeration("#WindingConnection");
    // Trailing dot: the value is empty.
    try expect_not_enumeration("#WindingConnection.");
    // The value holds a second dot.
    try expect_not_enumeration("#A.b.c");
    // An empty fragment.
    try expect_not_enumeration(cim100_ns);
    try expect_not_enumeration("#");
    // Leading dot: the class is empty.
    try expect_not_enumeration("#.Y");
    // A hyphen is not a class-name character either.
    try expect_not_enumeration("#Winding-Connection.Y");
}

test "Target.name is empty for unresolved and the class otherwise" {
    try testing.expectEqualStrings("ACLineSegment", (Target{ .object = "ACLineSegment" }).name());
    try testing.expectEqualStrings("PhaseCode", (Target{ .enumeration = "PhaseCode" }).name());
    const unresolved: Target = .unresolved;
    try testing.expectEqualStrings("", unresolved.name());

    // The tie-break order both comparators end on.
    try testing.expect(@intFromEnum(Target.Kind.object) < @intFromEnum(Target.Kind.enumeration));
    try testing.expect(@intFromEnum(Target.Kind.enumeration) < @intFromEnum(Target.Kind.unresolved));
}

fn init_test_document(xml: []const u8) !CimDocument {
    return CimDocument.init(testing.allocator, try testing.allocator.dupe(u8, xml));
}

// One document holding one of everything: a reference that resolves, an
// enumeration literal, a reference to an id nothing declares, a truncated
// `rdf:resource`, and literals of both syntaxes for the walk to skip.
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

    // Four rdf:resource children out of seven; the three literals are not
    // references in either syntax and never reach the classification.
    try expect_totals(counts, .{
        .references = 4,
        .associations = 1,
        .enumerations = 1,
        .unresolved = 2,
    });
}

test "RelationCounts.build: a second document resolves the first's dangling reference" {
    // `_missing` is dangling in a one-document scope and an association in a
    // two-document one, over the same bytes. Pins that the walk classifies
    // through the scope rather than through either document alone -- and the
    // second document carries a reference of its own, back into the first, so
    // a walk that stopped after document 0 would lose it rather than counting
    // the same totals by luck.
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
    // `ChildIterator` reports the truncated child as a `.property`, so a walk
    // that trusted `kind` alone would drop it from the reference total and
    // hand it to the properties command instead -- counting it twice across
    // the two.
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
    // Includes an object with no children, which the walk must step over
    // rather than trip on.
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

    // Four references, four distinct triples -- but the two unresolved ones
    // share the sentinel target and differ only in their property, which is
    // what keeps them apart.
    try testing.expectEqual(@as(usize, 4), counts.relations.len);
    try expect_row(counts, "ACLineSegment", "Equipment.EquipmentContainer", .object, "BaseVoltage", 1);
    try expect_row(counts, "ACLineSegment", "ConductingEquipment.phases", .enumeration, "PhaseCode", 1);
    try expect_row(counts, "ACLineSegment", "ACLineSegment.BaseVoltage", .unresolved, "", 1);
    try expect_row(counts, "ACLineSegment", "Equipment.aggregate", .unresolved, "", 1);
}

test "RelationCounts.build: a polymorphic property is one row per target class" {
    // `Terminal.ConductingEquipment` points at whatever equipment the terminal
    // belongs to, so one property yields as many rows as classes observed --
    // and the two ACLineSegment edges share a row rather than making two.
    //
    // The second property is interleaved on purpose: it means every property
    // here is seen again after another has been interned, which is the only
    // arrangement in which an interner that re-mints an existing name would
    // show up as wrong rows rather than as the same rows by luck.
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
    // Same source, same property, same target *name* -- `PhaseCode` as a class
    // that exists in the document and as an enumeration class. Only the kind
    // separates them, and it separates them in the key, not just in the sort:
    // without it these two collapse into one row of count 2.
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
    // An id that reads exactly like an enumeration literal. The shape test
    // would take it, so this pins that it is never reached for a reference
    // that resolves.
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

test "stubs: signatures are analysed" {
    // Scaffolding, to be deleted as each body lands. Zig never analyses the
    // body of an unreferenced declaration, so without this a stub with a
    // signature that does not compile ships through a green `zig build test`
    // -- which is exactly how two ReferenceScope accessors got through in #87.
    _ = &Relation.by_count_desc;
    _ = &Relation.by_name;
    _ = &RelationCounts.sorted;
}
