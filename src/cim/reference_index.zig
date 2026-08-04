//! Object lookup by raw reference value.
//!
//! A raw `rdf:resource` arrives in several shapes -- "_x", "#_x", a full
//! fragment IRI ("http://a#_x"), a path-style IRI (".../id/_x"), or a URN --
//! while `CimDocument.id_to_index` is keyed by the raw stored id (rdf:ID form,
//! or rdf:about with only a *leading* '#' stripped at parse). This index owns
//! the normalization between the two spaces so no consumer re-derives it.
//!
//! Precedence is fixed:
//!   1. An exact raw match always wins.
//!   2. Otherwise the reference's local form (fragment, else last path
//!      segment) is matched against raw ids -- this is how "#_x" finds "_x".
//!   3. Otherwise a UNIQUE local alias of a full-IRI id resolves. An alias
//!      shared by two ids is poisoned and resolves to null, never to an
//!      arbitrary object. The parser only rejects duplicate raw ids, so
//!      normalized collisions are the caller's data, not a bug here.

const std = @import("std");
const assert = std.debug.assert;

const CimDocument = @import("document.zig").CimDocument;
const uri = @import("uri.zig");

pub const ReferenceIndex = struct {
    model: *const CimDocument,
    /// local alias -> object index, only for ids whose local form differs
    /// from the raw id (full-IRI rdf:about forms); `ambiguous` on collision.
    aliases: std.StringHashMap(u32),

    const ambiguous: u32 = std.math.maxInt(u32);

    pub fn init(gpa: std.mem.Allocator, model: *const CimDocument) !ReferenceIndex {
        assert(model.objects.len < ambiguous);
        var aliases = std.StringHashMap(u32).init(gpa);
        errdefer aliases.deinit();
        for (model.objects, 0..) |obj, index| {
            const id = obj.id();
            const local = local_form(id);
            if (std.mem.eql(u8, local, id)) continue;
            if (local.len == 0) continue;
            const entry = try aliases.getOrPut(local);
            // Two distinct raw ids sharing a local form: poison the alias so
            // lookup answers null instead of picking one arbitrarily.
            entry.value_ptr.* = if (entry.found_existing) ambiguous else @intCast(index);
        }
        return .{ .model = model, .aliases = aliases };
    }

    pub fn deinit(self: *ReferenceIndex) void {
        self.aliases.deinit();
    }

    /// Object index for a raw reference value, or null when dangling or
    /// ambiguous. Idempotent over already-local inputs: the local form of a
    /// local form is itself.
    pub fn object_index_by_reference(self: *const ReferenceIndex, reference: []const u8) ?u32 {
        if (self.model.id_to_index.get(reference)) |index| return index;
        const local = local_form(reference);
        if (!std.mem.eql(u8, local, reference)) {
            if (self.model.id_to_index.get(local)) |index| return index;
        }
        const index = self.aliases.get(local) orelse return null;
        if (index == ambiguous) return null;
        assert(index < self.model.objects.len);
        return index;
    }

    /// Local name of a reference: the URI fragment when present, else the
    /// last path segment, else the value unchanged (rdf:ID forms, URNs).
    fn local_form(reference: []const u8) []const u8 {
        if (uri.fragment(reference)) |fragment| return fragment;
        if (std.mem.lastIndexOfScalar(u8, reference, '/')) |index| return reference[index + 1 ..];
        return reference;
    }
};

// ── tests ─────────────────────────────────────────────────────────────────

const test_gpa = std.testing.allocator;

fn init_document(xml: []const u8) !CimDocument {
    return CimDocument.init(test_gpa, try test_gpa.dupe(u8, xml));
}

const rdf_id_document =
    \\<rdf:RDF>
    \\  <cim:BaseVoltage rdf:ID="_bv1">
    \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\</rdf:RDF>
;

test "ReferenceIndex resolves _x, #_x, fragment IRI, and path IRI against rdf:ID" {
    var model = try init_document(rdf_id_document);
    defer model.deinit(test_gpa);
    var index = try ReferenceIndex.init(test_gpa, &model);
    defer index.deinit();

    // rdf:ID documents need no aliases at all.
    try std.testing.expectEqual(@as(u32, 0), index.aliases.count());
    try std.testing.expectEqual(@as(?u32, 0), index.object_index_by_reference("_bv1"));
    try std.testing.expectEqual(@as(?u32, 0), index.object_index_by_reference("#_bv1"));
    try std.testing.expectEqual(@as(?u32, 0), index.object_index_by_reference("http://example.com/data#_bv1"));
    try std.testing.expectEqual(@as(?u32, 0), index.object_index_by_reference("http://example.com/id/_bv1"));
    try std.testing.expectEqual(@as(?u32, null), index.object_index_by_reference("_other"));
    try std.testing.expectEqual(@as(?u32, null), index.object_index_by_reference(""));
}

test "ReferenceIndex resolves against rdf:about ids stored as full IRIs" {
    var model = try init_document(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:about="http://example.com/data#_bv1">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    );
    defer model.deinit(test_gpa);
    var index = try ReferenceIndex.init(test_gpa, &model);
    defer index.deinit();

    // Raw form: exact match. Local forms: via the alias map.
    try std.testing.expectEqual(@as(?u32, 0), index.object_index_by_reference("http://example.com/data#_bv1"));
    try std.testing.expectEqual(@as(?u32, 0), index.object_index_by_reference("_bv1"));
    try std.testing.expectEqual(@as(?u32, 0), index.object_index_by_reference("#_bv1"));
}

test "ReferenceIndex resolves URN ids by exact raw match" {
    var model = try init_document(
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:484c5d95-2ef3-4bbb-84ff-56ff5023dcbe">
        \\    <md:Model.version>1</md:Model.version>
        \\  </md:FullModel>
        \\</rdf:RDF>
    );
    defer model.deinit(test_gpa);
    var index = try ReferenceIndex.init(test_gpa, &model);
    defer index.deinit();

    try std.testing.expectEqual(
        @as(?u32, 0),
        index.object_index_by_reference("urn:uuid:484c5d95-2ef3-4bbb-84ff-56ff5023dcbe"),
    );
    try std.testing.expectEqual(@as(?u32, null), index.object_index_by_reference("urn:uuid:other"));
}

test "ReferenceIndex: ambiguous local alias resolves to null, raw forms still win" {
    var model = try init_document(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:about="http://a.example/data#_shared">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:about="http://b.example/data#_shared">
        \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    );
    defer model.deinit(test_gpa);
    var index = try ReferenceIndex.init(test_gpa, &model);
    defer index.deinit();

    // Both raw forms resolve to their own object.
    const a = index.object_index_by_reference("http://a.example/data#_shared");
    const b = index.object_index_by_reference("http://b.example/data#_shared");
    try std.testing.expect(a != null and b != null);
    try std.testing.expect(a.? != b.?);
    // The bare alias is ambiguous: never an arbitrary object.
    try std.testing.expectEqual(@as(?u32, null), index.object_index_by_reference("_shared"));
    try std.testing.expectEqual(@as(?u32, null), index.object_index_by_reference("#_shared"));
}

test "ReferenceIndex: exact raw match beats another id's alias" {
    var model = try init_document(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_bv1">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:about="http://a.example/data#_bv1">
        \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    );
    defer model.deinit(test_gpa);
    var index = try ReferenceIndex.init(test_gpa, &model);
    defer index.deinit();

    const raw = index.object_index_by_reference("_bv1").?;
    const iri = index.object_index_by_reference("http://a.example/data#_bv1").?;
    try std.testing.expect(raw != iri);
    try std.testing.expectEqualStrings("_bv1", model.objects[raw].id());
}
