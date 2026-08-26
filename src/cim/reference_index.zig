//! Object lookup by raw reference value.
//!
//! A raw `rdf:resource` arrives in several shapes: "_x", "#_x", a full
//! fragment IRI ("http://a#_x"), a path-style IRI (".../id/_x"), or a URN.
//! `CimDocument.id_to_index` is keyed by the raw stored id (rdf:ID form,
//! or rdf:about with only a leading '#' stripped at parse). Reference index
//! is used for normalization between these two spaces.
//!
//! Precedence is fixed, and reads as a ladder of three rungs:
//!   1. An exact raw match always wins.
//!   2. Otherwise the reference's local form (fragment, else last path
//!      segment) is matched against raw ids. This is how "#_x" finds "_x".
//!   3. Otherwise a UNIQUE local alias of a full-IRI id resolves. An alias
//!      shared by two ids is poisoned and resolves to null, never to an
//!      arbitrary object. The parser only rejects duplicate raw ids, so
//!      normalized collisions are the caller's data, not a bug here.
//!
//! Each rung is a probe step taking a key already hashed -- the raw
//! reference for rung 1, its local form for rungs 2 and 3 -- rather than a
//! line that hashes inline. `object_index_by_reference` is the driver over
//! the three for one document. A driver holding one index per document runs
//! the same ladder stage-major (every document's rung 1, then every
//! document's rung 2, then every document's rung 3) over the same two keys,
//! so the hash count is two whatever the document count. One ladder, two
//! drivers, and they cannot disagree about precedence.

const std = @import("std");
const assert = std.debug.assert;

const CimDocument = @import("document.zig").CimDocument;
const uri = @import("uri.zig");

pub const ReferenceIndex = struct {
    model: *const CimDocument,
    /// local alias -> object index, only for ids whose local form differs
    /// from the raw id (full-IRI rdf:about forms); `ambiguous` on collision.
    aliases: std.StringHashMap(u32),

    /// Poison value for a local alias two distinct raw ids share. It is the
    /// one `u32` that can never be an object index: `init` asserts the
    /// object count stays below it, so a stored value either is this
    /// sentinel or is in range, and no separate presence flag is needed.
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
    ///
    /// The single-document driver over the ladder: the first rung with a hit
    /// decides, and rung 3's poison is a null rather than a fall-through.
    pub fn object_index_by_reference(self: *const ReferenceIndex, reference: []const u8) ?u32 {
        const raw = HashedKey.init(reference);
        if (self.probe_exact_raw(raw)) |index| return index;

        const local = LocalKey.init(reference, raw);
        if (self.probe_local_against_raw(local)) |index| return index;
        return switch (self.probe_unique_alias(local)) {
            .unique => |index| index,
            .none, .ambiguous => null,
        };
    }

    /// Rung 1: the raw reference against raw ids.
    fn probe_exact_raw(self: *const ReferenceIndex, raw: HashedKey) ?u32 {
        const index = raw.get(&self.model.id_to_index) orelse return null;
        assert(index < self.model.objects.len);
        return index;
    }

    /// Rung 2: the reference's local form against raw ids -- how "#_x" finds
    /// "_x". A reference that is already local has nothing left to try here:
    /// rung 1 probed the same map with the same key.
    fn probe_local_against_raw(self: *const ReferenceIndex, local: LocalKey) ?u32 {
        if (local.is_raw) return null;
        const index = local.key.get(&self.model.id_to_index) orelse return null;
        assert(index < self.model.objects.len);
        return index;
    }

    /// Rung 3: the local form against the alias table.
    ///
    /// Reports what the table holds and leaves the rule -- only a unique
    /// alias resolves -- to the driver, because a poisoned alias means "this
    /// reference is null" to a one-document driver and "poison the whole
    /// scope, do not let another document's alias answer" to an N-document
    /// one. Folding it to null here would hide that difference.
    fn probe_unique_alias(self: *const ReferenceIndex, local: LocalKey) AliasProbe {
        const index = local.key.get(&self.aliases) orelse return .none;
        if (index == ambiguous) return .ambiguous;
        assert(index < self.model.objects.len);
        return .{ .unique = index };
    }
};

/// What rung 3's alias table has to say about a local form.
const AliasProbe = union(enum) {
    /// No id in this document carries that local alias.
    none,
    /// Exactly one does, at this object index.
    unique: u32,
    /// Two distinct raw ids share it, so it names no single object.
    ambiguous,
};

/// A probe key with its hash computed once. Both maps the ladder probes
/// (`CimDocument.id_to_index` and `ReferenceIndex.aliases`) are
/// `StringHashMap` over the same context, so one hash of a key serves both,
/// and doubles as the key for every document a driver spans.
const HashedKey = struct {
    bytes: []const u8,
    /// `bytes` under the very function `StringHashMap` hashes with. It must
    /// stay that function: a hash the map was not built with silently misses
    /// rather than failing, so `HashedKey` is the only place it is named.
    digest: u64,

    fn init(bytes: []const u8) HashedKey {
        return .{ .bytes = bytes, .digest = std.hash_map.hashString(bytes) };
    }

    fn get(self: HashedKey, map: *const std.StringHashMap(u32)) ?u32 {
        return map.getAdapted(self.bytes, self);
    }

    /// `getAdapted` context: hand back the precomputed hash instead of
    /// recomputing it, and compare bytes exactly as `StringContext` does.
    /// `pub` because `std.HashMap` calls it, not because callers here do --
    /// `HashedKey` itself is private to this file.
    pub fn hash(self: HashedKey, key: []const u8) u64 {
        // `get` passes its own `bytes`, and the hash is only that slice's.
        assert(key.ptr == self.bytes.ptr);
        assert(key.len == self.bytes.len);
        return self.digest;
    }

    pub fn eql(_: HashedKey, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

/// The key rungs 2 and 3 share: the reference's local form, hashed once and
/// serving both maps. Built only once rung 1 has missed, so a reference that
/// resolves exactly is never hashed twice, and reusing `raw` when the local
/// form *is* the raw value puts the ceiling for any reference at two hashes
/// -- however many documents the driver spans them over.
const LocalKey = struct {
    key: HashedKey,
    /// The local form is the raw value: rung 2 would repeat rung 1, and
    /// rung 3 probes the alias table with rung 1's hash rather than a second
    /// hash of the same bytes.
    is_raw: bool,

    fn init(reference: []const u8, raw: HashedKey) LocalKey {
        assert(raw.bytes.ptr == reference.ptr);
        assert(raw.bytes.len == reference.len);

        const local = local_form(reference);
        const is_raw = std.mem.eql(u8, local, reference);
        // The local form is always a suffix of the reference, which is what
        // makes equal lengths and equal content the same question.
        assert(local.len <= reference.len);
        if (is_raw) assert(local.len == reference.len);
        if (!is_raw) assert(local.len < reference.len);

        return .{ .key = if (is_raw) raw else HashedKey.init(local), .is_raw = is_raw };
    }
};

/// Local name of a reference: the URI fragment when present, else the
/// last path segment, else the value unchanged (rdf:ID forms, URNs).
fn local_form(reference: []const u8) []const u8 {
    if (uri.fragment(reference)) |fragment| return fragment;
    if (std.mem.lastIndexOfScalar(u8, reference, '/')) |index| return reference[index + 1 ..];
    return reference;
}

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

const mixed_id_document =
    \\<rdf:RDF>
    \\  <cim:BaseVoltage rdf:ID="_bv1">
    \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\  <cim:BaseVoltage rdf:about="http://a.example/data#_bv1">
    \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\</rdf:RDF>
;

test "ReferenceIndex: exact raw match beats another id's alias" {
    var model = try init_document(mixed_id_document);
    defer model.deinit(test_gpa);
    var index = try ReferenceIndex.init(test_gpa, &model);
    defer index.deinit();

    const raw = index.object_index_by_reference("_bv1").?;
    const iri = index.object_index_by_reference("http://a.example/data#_bv1").?;
    try std.testing.expect(raw != iri);
    try std.testing.expectEqualStrings("_bv1", model.objects[raw].id());
}

test "ReferenceIndex: the precomputed-hash probe agrees with a plain map get" {
    var model = try init_document(mixed_id_document);
    defer model.deinit(test_gpa);
    var index = try ReferenceIndex.init(test_gpa, &model);
    defer index.deinit();

    // A hash the map was not built with misses silently rather than failing,
    // so pin the adapted probe against the map's own context -- on hits, on
    // misses, and on the empty reference, whose local form is itself.
    const references = [_][]const u8{
        "_bv1",
        "#_bv1",
        "http://a.example/data#_bv1",
        "http://example.com/id/_bv1",
        "_missing",
        "",
    };
    for (references) |reference| {
        const raw = HashedKey.init(reference);
        const local = LocalKey.init(reference, raw);
        try std.testing.expectEqualStrings(reference, raw.bytes);
        try std.testing.expectEqualStrings(local_form(reference), local.key.bytes);
        try std.testing.expectEqual(
            model.id_to_index.get(reference),
            raw.get(&model.id_to_index),
        );
        try std.testing.expectEqual(
            model.id_to_index.get(local.key.bytes),
            local.key.get(&model.id_to_index),
        );
        try std.testing.expectEqual(
            index.aliases.get(local.key.bytes),
            local.key.get(&index.aliases),
        );
    }
}
