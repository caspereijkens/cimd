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
const cim_types = @import("cim_types.zig");
const uri = @import("uri.zig");

const cim_documents_max: u32 = 128;

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

pub const ReferenceScope = struct {
    cim_documents: []const *const CimDocument,
    /// type id -> name. Borrows document xml; ids index this table.
    type_names: []const []const u8,
    /// one dense array per CIM document, indexed by object index.
    type_ids: [][]u32,
    /// one per document, in scope order. Rung 3 has no alias table to probe
    /// without them, and holding every document's here is what lets a single
    /// pair of hashed keys serve the whole sweep.
    indexes: []ReferenceIndex,

    pub fn init(gpa: std.mem.Allocator, cim_documents: []const *const CimDocument) !ReferenceScope {
        assert(cim_documents.len > 0);
        assert(cim_documents.len <= cim_documents_max);

        // Interner dedupes type names, so one type seen in two documents
        // interns to one id.
        var interner = std.StringHashMap(u32).init(gpa);
        defer interner.deinit();

        var type_names: std.ArrayList([]const u8) = .empty;
        errdefer type_names.deinit(gpa);

        const type_ids = try gpa.alloc([]u32, cim_documents.len);
        var filled: u32 = 0;
        errdefer {
            for (type_ids[0..filled]) |slots| gpa.free(slots);
            gpa.free(type_ids);
        }

        const indexes = try gpa.alloc(ReferenceIndex, cim_documents.len);
        var indexes_built: u32 = 0;
        errdefer {
            for (indexes[0..indexes_built]) |*index| index.deinit();
            gpa.free(indexes);
        }

        for (cim_documents, 0..) |cim_document, document_index| {
            indexes[document_index] = try ReferenceIndex.init(gpa, cim_document);
            indexes_built += 1;

            const slots = try gpa.alloc(u32, cim_document.object_count());
            type_ids[document_index] = slots;
            filled += 1;

            var objects_covered: u32 = 0;
            var type_groups = cim_document.type_groups();
            while (type_groups.next()) |type_group| {
                assert(type_group.start == objects_covered);

                const interner_entry = try interner.getOrPut(type_group.type_name);
                if (!interner_entry.found_existing) {
                    try type_names.append(gpa, type_group.type_name);
                    assert(type_names.items.len <= std.math.maxInt(u32));
                    interner_entry.value_ptr.* = @intCast(type_names.items.len - 1);
                }

                const group_object_count: u32 = @intCast(type_group.objects.len);
                @memset(
                    slots[type_group.start .. type_group.start + group_object_count],
                    interner_entry.value_ptr.*,
                );
                objects_covered += group_object_count;
            }
            assert(objects_covered == cim_document.object_count());
        }

        // A document cannot declare an id twice, so a single document has
        // nothing to contest and pays nothing for the pass.
        if (cim_documents.len > 1) {
            arbitrate_collisions(indexes, type_ids, type_names.items);
        }

        return .{
            .cim_documents = cim_documents,
            .type_names = try type_names.toOwnedSlice(gpa),
            .type_ids = type_ids,
            .indexes = indexes,
        };
    }

    pub fn deinit(self: *ReferenceScope, gpa: std.mem.Allocator) void {
        for (self.indexes) |*index| index.deinit();
        gpa.free(self.indexes);
        for (self.type_ids) |slots| gpa.free(slots);
        gpa.free(self.type_ids);
        // The table only: the names themselves borrow document xml.
        gpa.free(self.type_names);
    }

    pub fn document_count(self: *const ReferenceScope) u32 {
        // `init` bounded the slice, so the narrowing cannot lose a document.
        assert(self.cim_documents.len <= cim_documents_max);
        return @intCast(self.cim_documents.len);
    }

    /// A consumer that walks objects takes them from here rather than holding
    /// its own slice, so it cannot walk a different set than the scope
    /// resolves over. Borrowed: the document outlives the scope, not the
    /// other way round.
    pub fn document(self: *const ReferenceScope, index: u32) *const CimDocument {
        assert(index < self.document_count());
        return self.cim_documents[index];
    }

    /// The primitive the other accessors are layered over. Total: every
    /// object index has an entry, which is what the covering assertion in
    /// `init` buys.
    pub fn type_id_by_object(self: *const ReferenceScope, document_index: u32, object_index: u32) u32 {
        assert(document_index < self.document_count());
        const document_type_ids = self.type_ids[document_index];
        assert(object_index < document_type_ids.len);

        return document_type_ids[object_index];
    }

    /// Render an id. Ids index this scope's own table: stable for its
    /// lifetime, meaningless outside it. The single renderer, so the id space
    /// and the name space cannot disagree.
    pub fn type_name(self: *const ReferenceScope, type_id: u32) []const u8 {
        assert(type_id < self.type_names.len);
        return self.type_names[type_id];
    }

    pub fn type_name_by_object(self: *const ReferenceScope, document_index: u32, object_index: u32) []const u8 {
        return self.type_name(self.type_id_by_object(document_index, object_index));
    }

    /// Type id for whatever the reference resolves to, or null when it names
    /// no single object: dangling, or an alias the scope poisoned.
    pub fn type_id_by_reference(self: *const ReferenceScope, reference: []const u8) ?u32 {
        const object = self.resolve(reference) orelse return null;
        return self.type_id_by_object(object.document_index, object.object_index);
    }

    /// Type name for whatever the reference resolves to, null wherever
    /// `type_id_by_reference` is. Renders through that id rather than the
    /// resolved object's own name so that arbitration, which rewrites the id
    /// and not the element, cannot leave name callers and id callers
    /// disagreeing about the same object.
    pub fn type_name_by_reference(self: *const ReferenceScope, reference: []const u8) ?[]const u8 {
        const type_id = self.type_id_by_reference(reference) orelse return null;
        return self.type_name(type_id);
    }

    /// An object index means nothing without the document it indexes, so a
    /// scope-level resolve answers with both.
    const ObjectRef = struct {
        document_index: u32,
        object_index: u32,
    };

    /// Object behind a reference, or null when it names none.
    ///
    /// Stage-major -- every document's rung 1 before any document's rung 2 --
    /// so precedence belongs to the reference rather than to the input slice:
    /// an exact raw match in the last document beats an alias match in the
    /// first. Document-major would make the answer depend on argument order.
    ///
    /// Both keys are built here and handed to every document, so a lookup
    /// costs two hashes whatever the document count.
    fn resolve(self: *const ReferenceScope, reference: []const u8) ?ObjectRef {
        const raw = HashedKey.init(reference);
        for (self.indexes, 0..) |*index, document_index| {
            if (index.probe_exact_raw(raw)) |object_index| {
                return .{ .document_index = @intCast(document_index), .object_index = object_index };
            }
        }

        const local = LocalKey.init(reference, raw);
        for (self.indexes, 0..) |*index, document_index| {
            if (index.probe_local_against_raw(local)) |object_index| {
                return .{ .document_index = @intCast(document_index), .object_index = object_index };
            }
        }

        return self.probe_unique_alias(local);
    }

    /// Rung 3 across the scope. Sweeps every document even once it holds a
    /// hit, because a later document can poison the alias: a reference that
    /// names two objects must resolve to null, not to whichever was found
    /// first.
    fn probe_unique_alias(self: *const ReferenceScope, local: LocalKey) ?ObjectRef {
        var hit: ?ObjectRef = null;
        var hit_id: []const u8 = "";

        for (self.indexes, 0..) |*index, document_index| {
            switch (index.probe_unique_alias(local)) {
                .none => {},
                // Poisoned within one document poisons the scope: the
                // reference already names no single object, and another
                // document's alias must not paper over that.
                .ambiguous => return null,
                .unique => |object_index| {
                    const id = index.model.objects[object_index].id();
                    if (hit == null) {
                        hit = .{ .document_index = @intCast(document_index), .object_index = object_index };
                        hit_id = id;
                        continue;
                    }
                    // Alias collision: two raw ids sharing one local form
                    // name two objects, so the alias names none. The same
                    // raw id twice is one identity seen in two documents,
                    // settled in the dense arrays at build time, not here.
                    if (!std.mem.eql(u8, id, hit_id)) return null;
                },
            }
        }
        return hit;
    }

    /// One document's declaration of an identity, carrying the type id its
    /// dense array holds before arbitration.
    const Candidate = struct {
        document_index: u32,
        object_index: u32,
        type_id: u32,
    };

    /// Give every identity declared in more than one document one type,
    /// written into all of its slots.
    ///
    /// A contested id otherwise takes the type of whichever document the
    /// ladder reached first, so the same parts in a different order type the
    /// same object differently. Settling it here rather than on lookup is
    /// also what keeps the query path a dense-array read with no branch.
    ///
    /// Costs a lookup per object per earlier document -- quadratic in the
    /// document count, in exchange for allocating nothing. A scope is a
    /// handful of CGMES parts, and `cim_documents_max` is the bound if that
    /// stops holding.
    fn arbitrate_collisions(
        indexes: []const ReferenceIndex,
        type_ids: []const []u32,
        type_names: []const []const u8,
    ) void {
        assert(indexes.len == type_ids.len);
        assert(indexes.len > 1);

        // Document 0 has nothing before it to collide with.
        for (indexes[1..], 1..) |*index, document_index| {
            const earlier = indexes[0..document_index];
            for (index.model.objects) |object| {
                const key = HashedKey.init(object.id());

                var earlier_count: u32 = 0;
                for (earlier) |*previous| {
                    if (key.get(&previous.model.id_to_index) != null) earlier_count += 1;
                }

                // Settling on the second occurrence and only there keeps
                // the writes to one pass per identity: `settle_identity`
                // gathers the whole set from every document, so a third
                // occurrence has nothing left to add.
                if (earlier_count == 1) settle_identity(indexes, type_ids, type_names, key);
            }
        }
    }

    /// Collect one identity's declarations and write the arbitrated winner
    /// back into every one of their slots.
    fn settle_identity(
        indexes: []const ReferenceIndex,
        type_ids: []const []u32,
        type_names: []const []const u8,
        key: HashedKey,
    ) void {
        // A document holds an id at most once, so the candidates cannot
        // outnumber the documents `init` already bounded.
        var candidates: [cim_documents_max]Candidate = undefined;
        var candidate_count: u32 = 0;
        for (indexes, 0..) |*index, document_index| {
            const object_index = key.get(&index.model.id_to_index) orelse continue;
            assert(object_index < type_ids[document_index].len);
            candidates[candidate_count] = .{
                .document_index = @intCast(document_index),
                .object_index = object_index,
                .type_id = type_ids[document_index][object_index],
            };
            candidate_count += 1;
        }
        // The caller found this id in two documents through these same
        // maps, so both must turn up again.
        assert(candidate_count >= 2);

        const winner = arbitrate(candidates[0..candidate_count], type_names);
        for (candidates[0..candidate_count]) |candidate| {
            type_ids[candidate.document_index][candidate.object_index] = winner;
        }
    }

    /// The type a contested identity answers with: the candidate that `is_a`
    /// every other, because a part declaring Disconnector says strictly more
    /// about the object than one declaring Equipment. Unrelated classes make
    /// no such claim over each other, so the name breaks the tie -- an
    /// arbitrary answer, but the same one under every input order.
    ///
    /// Judged against the whole set rather than folded through a running
    /// winner. A fold forgets the candidates it discarded, so three classes
    /// with no common subtype settle differently per permutation.
    fn arbitrate(candidates: []const Candidate, type_names: []const []const u8) u32 {
        assert(candidates.len >= 2);

        for (candidates) |candidate| {
            const name = type_names[candidate.type_id];
            var subtype_of_all = true;
            for (candidates) |other| {
                if (!cim_types.is_a(name, type_names[other.type_id])) {
                    subtype_of_all = false;
                    break;
                }
            }
            // A CIM class has one parent, so a candidate's ancestors are a
            // chain: at most one candidate can sit below all of them, and
            // the first found is that one.
            if (subtype_of_all) return candidate.type_id;
        }

        var winner = candidates[0].type_id;
        for (candidates[1..]) |candidate| {
            const order = std.mem.order(u8, type_names[candidate.type_id], type_names[winner]);
            // Names are interned, so distinct ids are distinct names: the
            // ordering is total and leaves no tie for input order to settle.
            assert(order != .eq or candidate.type_id == winner);
            if (order == .lt) winner = candidate.type_id;
        }
        return winner;
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

const alias_only_document =
    \\<rdf:RDF>
    \\  <cim:Breaker rdf:about="http://a.example/data#_x">
    \\    <cim:IdentifiedObject.name>from A</cim:IdentifiedObject.name>
    \\  </cim:Breaker>
    \\</rdf:RDF>
;

const raw_id_document =
    \\<rdf:RDF>
    \\  <cim:Disconnector rdf:ID="_x">
    \\    <cim:IdentifiedObject.name>from B</cim:IdentifiedObject.name>
    \\  </cim:Disconnector>
    \\  <cim:Terminal rdf:ID="_y">
    \\    <cim:IdentifiedObject.name>terminal</cim:IdentifiedObject.name>
    \\  </cim:Terminal>
    \\</rdf:RDF>
;

test "ReferenceScope: a one-document scope answers like ReferenceIndex" {
    var model = try init_document(mixed_id_document);
    defer model.deinit(test_gpa);
    var index = try ReferenceIndex.init(test_gpa, &model);
    defer index.deinit();
    var scope = try ReferenceScope.init(test_gpa, &.{&model});
    defer scope.deinit(test_gpa);

    // The shapes the single-document fixtures cover, plus the two misses.
    const references = [_][]const u8{
        "_bv1",
        "#_bv1",
        "http://a.example/data#_bv1",
        "http://example.com/id/_bv1",
        "_missing",
        "",
    };
    for (references) |reference| {
        const expected: ?[]const u8 = if (index.object_index_by_reference(reference)) |object_index|
            model.objects[object_index].type_name()
        else
            null;
        const actual = scope.type_name_by_reference(reference);

        try std.testing.expectEqual(expected == null, actual == null);
        if (expected) |name| try std.testing.expectEqualStrings(name, actual.?);
        // A caller reading ids and a caller reading names must not diverge.
        if (scope.type_id_by_reference(reference)) |type_id| {
            try std.testing.expectEqualStrings(scope.type_name(type_id), actual.?);
        } else {
            try std.testing.expect(actual == null);
        }
    }
}

test "ReferenceScope: totality -- every object index renders to its own type name" {
    var model = try init_document(mixed_id_document);
    defer model.deinit(test_gpa);
    var scope = try ReferenceScope.init(test_gpa, &.{&model});
    defer scope.deinit(test_gpa);

    // A one-document scope has nothing to arbitrate, so the dense array is
    // exactly the elements' own names.
    for (model.objects, 0..) |object, object_index| {
        try std.testing.expectEqualStrings(
            object.type_name(),
            scope.type_name_by_object(0, @intCast(object_index)),
        );
    }
}

test "ReferenceScope: references resolve across documents" {
    var a = try init_document(alias_only_document);
    defer a.deinit(test_gpa);
    var b = try init_document(raw_id_document);
    defer b.deinit(test_gpa);
    var scope = try ReferenceScope.init(test_gpa, &.{ &a, &b });
    defer scope.deinit(test_gpa);

    // Rung 2 reaches the second document: "#_y" finds raw "_y" there.
    try std.testing.expectEqualStrings("Terminal", scope.type_name_by_reference("#_y").?);
    try std.testing.expectEqualStrings("Terminal", scope.type_name_by_reference("_y").?);
    try std.testing.expect(scope.type_name_by_reference("_nowhere") == null);
}

test "ReferenceScope: stage-major precedence survives document order" {
    var a = try init_document(alias_only_document);
    defer a.deinit(test_gpa);
    var b = try init_document(raw_id_document);
    defer b.deinit(test_gpa);

    // "_x" is an exact raw id in B and only an alias in A, so rung 1 decides
    // in both orders. Document-major resolution would answer Breaker when A
    // comes first.
    inline for (.{ .{ &a, &b }, .{ &b, &a } }) |documents| {
        var scope = try ReferenceScope.init(test_gpa, &documents);
        defer scope.deinit(test_gpa);
        try std.testing.expectEqualStrings("Disconnector", scope.type_name_by_reference("_x").?);
    }
}

test "ReferenceScope: aliases ambiguous within or across documents resolve to null" {
    var shared = try init_document(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:about="http://a.example/data#_shared">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:about="http://b.example/data#_shared">
        \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    );
    defer shared.deinit(test_gpa);
    var other = try init_document(raw_id_document);
    defer other.deinit(test_gpa);

    // Ambiguous inside one document stays ambiguous once that document is in
    // a scope: another document cannot un-poison it.
    var one = try ReferenceScope.init(test_gpa, &.{&shared});
    defer one.deinit(test_gpa);
    try std.testing.expect(one.type_name_by_reference("_shared") == null);
    var two = try ReferenceScope.init(test_gpa, &.{ &shared, &other });
    defer two.deinit(test_gpa);
    try std.testing.expect(two.type_name_by_reference("_shared") == null);

    // Unique in each document but naming different raw ids: an alias
    // collision only the scope can see.
    var split_a = try init_document(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:about="http://a.example/data#_shared">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    );
    defer split_a.deinit(test_gpa);
    var split_b = try init_document(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:about="http://b.example/data#_shared">
        \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    );
    defer split_b.deinit(test_gpa);
    var split = try ReferenceScope.init(test_gpa, &.{ &split_a, &split_b });
    defer split.deinit(test_gpa);
    try std.testing.expect(split.type_name_by_reference("_shared") == null);
    // Each raw form still names its own object.
    try std.testing.expect(split.type_name_by_reference("http://a.example/data#_shared") != null);
    try std.testing.expect(split.type_name_by_reference("http://b.example/data#_shared") != null);
}

test "ReferenceScope: document_count and document return the input, in order" {
    var a = try init_document(alias_only_document);
    defer a.deinit(test_gpa);
    var b = try init_document(raw_id_document);
    defer b.deinit(test_gpa);
    var scope = try ReferenceScope.init(test_gpa, &.{ &a, &b });
    defer scope.deinit(test_gpa);

    try std.testing.expectEqual(@as(u32, 2), scope.document_count());
    try std.testing.expect(scope.document(0) == &a);
    try std.testing.expect(scope.document(1) == &b);
}

test "ReferenceScope: degenerate inputs" {
    var empty = try init_document(
        \\<rdf:RDF>
        \\</rdf:RDF>
    );
    defer empty.deinit(test_gpa);
    var b = try init_document(raw_id_document);
    defer b.deinit(test_gpa);

    try std.testing.expectEqual(@as(u32, 0), empty.object_count());
    var scope = try ReferenceScope.init(test_gpa, &.{ &empty, &b });
    defer scope.deinit(test_gpa);

    // An empty reference is a miss, not an assertion failure.
    try std.testing.expect(scope.type_name_by_reference("") == null);
    try std.testing.expect(scope.type_id_by_reference("") == null);
    try std.testing.expect(scope.type_name_by_reference("_nothing") == null);
    // A document contributing no objects still resolves past.
    try std.testing.expectEqualStrings("Terminal", scope.type_name_by_reference("_y").?);
}

const eq_document =
    \\<rdf:RDF>
    \\  <cim:Disconnector rdf:ID="_sw">
    \\    <cim:IdentifiedObject.name>DIS</cim:IdentifiedObject.name>
    \\  </cim:Disconnector>
    \\</rdf:RDF>
;

const ssh_document =
    \\<rdf:RDF>
    \\  <cim:Equipment rdf:about="#_sw">
    \\    <cim:Equipment.inService>true</cim:Equipment.inService>
    \\  </cim:Equipment>
    \\</rdf:RDF>
;

test "ReferenceScope: the more specific of two declarations wins the identity" {
    var eq = try init_document(eq_document);
    defer eq.deinit(test_gpa);
    var ssh = try init_document(ssh_document);
    defer ssh.deinit(test_gpa);

    // An SSH patch names the object Equipment only because that is all it
    // has to say about it; EQ's Disconnector is the class of the object.
    // Reading the patch's own object must not answer with the weaker one.
    inline for (.{ .{ &eq, &ssh }, .{ &ssh, &eq } }) |documents| {
        var scope = try ReferenceScope.init(test_gpa, &documents);
        defer scope.deinit(test_gpa);

        try std.testing.expectEqualStrings("Disconnector", scope.type_name_by_reference("_sw").?);
        try std.testing.expectEqualStrings("Disconnector", scope.type_name_by_reference("#_sw").?);
        for (0..scope.document_count()) |document_index| {
            try std.testing.expectEqualStrings(
                "Disconnector",
                scope.type_name_by_object(@intCast(document_index), 0),
            );
        }
        // The id form and the name form still answer as one.
        const type_id = scope.type_id_by_reference("_sw").?;
        try std.testing.expectEqualStrings(scope.type_name(type_id), scope.type_name_by_reference("_sw").?);
        try std.testing.expectEqual(type_id, scope.type_id_by_object(0, 0));
        try std.testing.expectEqual(type_id, scope.type_id_by_object(1, 0));
    }
}

test "ReferenceScope: three declarations settle the same under every permutation" {
    var conducting = try init_document(
        \\<rdf:RDF>
        \\  <cim:ConductingEquipment rdf:ID="_p"/>
        \\</rdf:RDF>
    );
    defer conducting.deinit(test_gpa);
    var switching = try init_document(
        \\<rdf:RDF>
        \\  <cim:Switch rdf:ID="_p"/>
        \\</rdf:RDF>
    );
    defer switching.deinit(test_gpa);
    var extension = try init_document(
        \\<rdf:RDF>
        \\  <ext:FooSwitch rdf:ID="_p"/>
        \\</rdf:RDF>
    );
    defer extension.deinit(test_gpa);

    // Switch is_a ConductingEquipment, but the extension class is below
    // neither, so no candidate is below all three and the name decides. A
    // running fold would answer FooSwitch wherever it met the extension
    // class last, and ConductingEquipment where it met it first.
    inline for (.{
        .{ &conducting, &switching, &extension },
        .{ &conducting, &extension, &switching },
        .{ &switching, &conducting, &extension },
        .{ &switching, &extension, &conducting },
        .{ &extension, &conducting, &switching },
        .{ &extension, &switching, &conducting },
    }) |documents| {
        var scope = try ReferenceScope.init(test_gpa, &documents);
        defer scope.deinit(test_gpa);

        try std.testing.expectEqualStrings("ConductingEquipment", scope.type_name_by_reference("_p").?);
        for (0..scope.document_count()) |document_index| {
            try std.testing.expectEqualStrings(
                "ConductingEquipment",
                scope.type_name_by_object(@intCast(document_index), 0),
            );
        }
    }
}

test "ReferenceScope: unrelated classes tie-break on the name" {
    var terminal = try init_document(
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_q"/>
        \\</rdf:RDF>
    );
    defer terminal.deinit(test_gpa);
    var base_voltage = try init_document(
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_q"/>
        \\</rdf:RDF>
    );
    defer base_voltage.deinit(test_gpa);

    // Neither class is below the other, so there is nothing to prefer and
    // the lexicographic order stands in for a rule.
    inline for (.{ .{ &terminal, &base_voltage }, .{ &base_voltage, &terminal } }) |documents| {
        var scope = try ReferenceScope.init(test_gpa, &documents);
        defer scope.deinit(test_gpa);
        try std.testing.expectEqualStrings("BaseVoltage", scope.type_name_by_reference("_q").?);
    }
}

test "ReferenceScope: identical declarations and uncontested objects keep their own class" {
    var a = try init_document(
        \\<rdf:RDF>
        \\  <ext:FooSwitch rdf:ID="_p"/>
        \\  <cim:Terminal rdf:ID="_a_only"/>
        \\</rdf:RDF>
    );
    defer a.deinit(test_gpa);
    var b = try init_document(
        \\<rdf:RDF>
        \\  <ext:FooSwitch rdf:ID="_p"/>
        \\  <cim:BaseVoltage rdf:ID="_b_only"/>
        \\</rdf:RDF>
    );
    defer b.deinit(test_gpa);

    var scope = try ReferenceScope.init(test_gpa, &.{ &a, &b });
    defer scope.deinit(test_gpa);

    // An extension class is unrelated to every class but itself, which is
    // what stops a contested identity being renamed out from under a
    // document that never disagreed.
    try std.testing.expectEqualStrings("FooSwitch", scope.type_name_by_reference("_p").?);
    try std.testing.expectEqualStrings("Terminal", scope.type_name_by_reference("_a_only").?);
    try std.testing.expectEqualStrings("BaseVoltage", scope.type_name_by_reference("_b_only").?);

    // Nothing in either dense array moved: the agreeing pair resolved to
    // what both already held, and the rest was never a candidate.
    inline for (.{ a, b }, 0..) |model, document_index| {
        for (model.objects, 0..) |object, object_index| {
            try std.testing.expectEqualStrings(
                object.type_name(),
                scope.type_name_by_object(@intCast(document_index), @intCast(object_index)),
            );
        }
    }
}

fn init_and_deinit_scope(gpa: std.mem.Allocator, cim_documents: []const *const CimDocument) !void {
    var scope = try ReferenceScope.init(gpa, cim_documents);
    scope.deinit(gpa);
}

test "ReferenceScope: init leaks nothing when any allocation fails" {
    var a = try init_document(alias_only_document);
    defer a.deinit(test_gpa);
    var b = try init_document(raw_id_document);
    defer b.deinit(test_gpa);

    // init allocates at four sites and each one can fail with the previous
    // three already owned, so the errdefer chain has to unwind partial state
    // rather than a whole scope. The documents come from the outer allocator,
    // so only init's own allocations fault.
    const cim_documents: []const *const CimDocument = &.{ &a, &b };
    try std.testing.checkAllAllocationFailures(test_gpa, init_and_deinit_scope, .{cim_documents});
}
