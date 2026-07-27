//! Overlay -- a CGMES supplementary part read as patches on a primary document.
//!
//! CGMES splits one model across parts: EQ carries the objects, TP and SSH
//! carry additions to them. This is the layer that lets a read of an EQ object
//! see what TP and SSH say about it.
//!
//! An overlay is **not** a second parser. It is a `CimDocument` -- the same
//! single-pass parse every other command uses -- plus the one index
//! `CimDocument` does not build: a lookup on the *normalized* mRID. That is the
//! whole reason this layer exists. `CimDocument` indexes an object under the id
//! as written, so `rdf:ID="_T1"` files under `_T1` and `rdf:about="#_T1"` under
//! `_T1` but `rdf:about="#T1"` under `T1`. An overlay has to find an object the
//! primary part spells differently, so it keys on
//! `strip_underscore(strip_hash(...))` -- `T1` for all three. Normalizing once,
//! here, is what keeps "which spelling?" out of every call site.
//!
//! TP and SSH were separate files with separate parsers until they were the
//! same file. What is left of the difference is one thing, and it is a real
//! distinction rather than an accident of how each was written: see `IdPolicy`.
//!
//! One consequence of sharing the parser is worth calling out, because it makes
//! overlays stricter than they used to be: a part that spells the same id both
//! ways -- `rdf:ID="X"` next to `rdf:about="#X"` -- is now a duplicate-id error,
//! since `CimDocument` files both under `X`. Primary documents have always
//! rejected that; overlays used to accept it and index the two independently.

const std = @import("std");
const tag_index = @import("../tag_index.zig");
const xml_scan = @import("../xml_scan.zig");
const ids = @import("../ids.zig");
const CimDocument = @import("../document.zig").CimDocument;

const assert = std.debug.assert;
pub const Diagnostics = @import("../diagnostics.zig").Diagnostics;

pub const CimObject = tag_index.CimObject;
const TagBoundary = xml_scan.TagBoundary;

/// How an `rdf:ID` element in an overlay is read. The single behavioural
/// difference between the CGMES supplementary profiles cimd overlays.
pub const IdPolicy = enum {
    /// TP. `rdf:ID` declares a *new* first-class object -- a `TopologicalNode`
    /// -- that exists in no other part. It is navigable by raw id like any
    /// primary object and patches nothing, so only `rdf:about` elements are
    /// patches.
    id_declares_object,
    /// SSH. `rdf:ID` is just another spelling of the key of the object being
    /// patched, so both attribute forms name a patch and the part contributes
    /// no objects of its own.
    id_names_patch,
};

/// A patched object: where its element sits, under the key overlays agree on.
pub const Patch = struct {
    /// Normalized -- no `#` fragment marker, no leading `_`.
    mrid: []const u8,
    patch_tag_idx: u32,
    closing_tag_idx: u32,
};

pub const Overlay = struct {
    /// The part, parsed by the one parser. Patches and declared objects are
    /// both ordinary objects in here; the two arrays below are classifications
    /// of it, not separate parses.
    doc: CimDocument,
    policy: IdPolicy,

    /// Borrowed from `doc`, which owns them, so they stay valid exactly as long
    /// as the overlay does. Held as fields because a patch is read by index into
    /// `boundaries` -- every consumer needs both, and `self.doc.xml` at each of
    /// those call sites says nothing the shorter spelling does not.
    xml: []const u8,
    boundaries: []const TagBoundary,

    /// Sorted by normalized mRID, so `find_patch` is a binary search.
    patches: []const Patch,

    /// Objects this part declares. Empty under `id_names_patch`. In document
    /// order, which `doc.objects` is not -- consumers emit in this order
    /// (`convert` writes one bus per TopologicalNode), so it is the part's
    /// order that has to survive, not the type grouping.
    new_objects: []const CimObject,

    /// Raw `rdf:ID` -> index into `new_objects`. Not `doc.id_to_index`, which
    /// also indexes the patched objects: a patch is a reference to something
    /// living in the primary part, not a thing this part offers to navigate to.
    id_to_object: std.StringHashMap(u32),

    /// Takes ownership of `xml`: on success the overlay owns it (freed by
    /// deinit), on error it is freed before returning. Callers never need to
    /// clean up `xml`.
    pub fn init(gpa: std.mem.Allocator, xml: []const u8, policy: IdPolicy) !Overlay {
        return initWithDiagnostics(gpa, xml, policy, null);
    }

    /// A TP part. The profiles still exist -- they just no longer need separate
    /// implementations, only these two names for the policy they pick.
    pub fn init_tp(gpa: std.mem.Allocator, xml: []const u8) !Overlay {
        return init(gpa, xml, .id_declares_object);
    }

    /// An SSH part.
    pub fn init_ssh(gpa: std.mem.Allocator, xml: []const u8) !Overlay {
        return init(gpa, xml, .id_names_patch);
    }

    pub fn initWithDiagnostics(
        gpa: std.mem.Allocator,
        xml: []const u8,
        policy: IdPolicy,
        diagnostics: ?*Diagnostics,
    ) !Overlay {
        // Takes ownership of `xml` and frees it on every failure path, which is
        // why there is no `errdefer gpa.free(xml)` here.
        var doc = try CimDocument.initWithDiagnostics(gpa, xml, diagnostics);
        errdefer doc.deinit(gpa);

        var patch_count: u32 = 0;
        var declared_count: u32 = 0;
        for (doc.objects) |obj| switch (classify(doc, obj, policy)) {
            .patch => patch_count += 1,
            .declares => declared_count += 1,
            .skip => {},
        };

        const patches = try gpa.alloc(Patch, patch_count);
        errdefer gpa.free(patches);
        const new_objects = try gpa.alloc(CimObject, declared_count);
        errdefer gpa.free(new_objects);

        var id_to_object = std.StringHashMap(u32).init(gpa);
        errdefer id_to_object.deinit();
        try id_to_object.ensureTotalCapacity(declared_count);

        var patch_cursor: u32 = 0;
        var object_cursor: u32 = 0;
        for (doc.objects) |obj| switch (classify(doc, obj, policy)) {
            .skip => {},
            .declares => {
                assert(object_cursor < declared_count);
                new_objects[object_cursor] = obj;
                object_cursor += 1;
            },
            .patch => |mrid| {
                assert(patch_cursor < patch_count);
                patches[patch_cursor] = .{
                    .mrid = mrid,
                    .patch_tag_idx = obj.object_tag_idx,
                    .closing_tag_idx = obj.closing_tag_idx,
                };
                patch_cursor += 1;
            },
        };
        assert(patch_cursor == patch_count);
        assert(object_cursor == declared_count);

        // `doc.objects` is grouped by type; restore the part's own order, since
        // consumers emit in it.
        std.mem.sort(CimObject, new_objects, {}, object_before);
        for (new_objects, 0..) |obj, i| {
            // Pairs with `CimDocument`'s duplicate-id rejection: the raw ids of
            // declared objects are already known distinct, so no entry can clash.
            id_to_object.putAssumeCapacityNoClobber(obj.id, @intCast(i));
        }

        std.mem.sort(Patch, patches, {}, patch_before);
        if (patches.len > 1) {
            for (patches[1..], 1..) |patch, i| {
                // Pairs with the sort above: the dedup walk relies on it.
                assert(!patch_before({}, patch, patches[i - 1]));
                if (!std.mem.eql(u8, patches[i - 1].mrid, patch.mrid)) continue;
                // Two spellings of one key. `CimDocument` cannot catch this --
                // `#T1` and `#_T1` are distinct ids to it and only collide once
                // normalized -- so the report is raised here, naming the later
                // element the way the file spells it.
                const later = if (patches[i - 1].patch_tag_idx > patch.patch_tag_idx)
                    patches[i - 1]
                else
                    patch;
                const tag_start = doc.boundaries[later.patch_tag_idx].start;
                const raw_id = raw_patch_id(doc.xml, tag_start) orelse unreachable;
                if (diagnostics) |d| d.record_duplicate_id(doc.xml, raw_id, tag_start);
                return error.DuplicateId;
            }
        }

        return .{
            .doc = doc,
            .policy = policy,
            .xml = doc.xml,
            .boundaries = doc.boundaries,
            .patches = patches,
            .new_objects = new_objects,
            .id_to_object = id_to_object,
        };
    }

    pub fn deinit(self: *Overlay, gpa: std.mem.Allocator) void {
        self.id_to_object.deinit();
        gpa.free(self.new_objects);
        gpa.free(self.patches);
        self.doc.deinit(gpa);
    }

    /// Look up the patch for a normalized mRID (no `#`, no leading `_`).
    /// Returns null if this part does not patch that object. Reuse the returned
    /// `Patch` when reading several properties of one object -- that is what it
    /// is for.
    pub fn find_patch(self: Overlay, mrid: []const u8) ?Patch {
        assert(mrid.len > 0);
        var lo: u32 = 0;
        var hi: u32 = @intCast(self.patches.len);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.patches[mid].mrid, mrid)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => {
                    const hit = self.patches[mid];
                    // Pair the binary search hit with a direct mrid compare.
                    assert(std.mem.eql(u8, hit.mrid, mrid));
                    return hit;
                },
            }
        }
        return null;
    }

    /// Read a text property from a patch returned by `find_patch`.
    pub fn getPropertyFromPatch(self: Overlay, patch: Patch, property_name: []const u8) !?[]const u8 {
        return tag_index.get_property_from_indices(
            self.xml,
            self.boundaries,
            patch.patch_tag_idx,
            patch.closing_tag_idx,
            property_name,
        );
    }

    /// Read an `rdf:resource` reference from a patch returned by `find_patch`.
    pub fn getReferenceFromPatch(self: Overlay, patch: Patch, reference_name: []const u8) !?[]const u8 {
        return tag_index.get_reference_from_indices(
            self.xml,
            self.boundaries,
            patch.patch_tag_idx,
            patch.closing_tag_idx,
            reference_name,
        );
    }

    /// Convenience wrapper for a single lookup. For several properties on the
    /// same object, use `find_patch` + `getPropertyFromPatch` and pay for one
    /// binary search.
    pub fn getProperty(self: Overlay, mrid: []const u8, property_name: []const u8) !?[]const u8 {
        const patch = self.find_patch(mrid) orelse return null;
        return self.getPropertyFromPatch(patch, property_name);
    }

    /// Convenience wrapper for a single reference lookup.
    pub fn getReference(self: Overlay, mrid: []const u8, reference_name: []const u8) !?[]const u8 {
        const patch = self.find_patch(mrid) orelse return null;
        return self.getReferenceFromPatch(patch, reference_name);
    }

    /// Look up an object this part declares, by raw `rdf:ID` (leading
    /// underscore included). Patched objects are deliberately not reachable
    /// here -- they belong to the primary part.
    pub fn get_object_by_id(self: Overlay, id: []const u8) ?tag_index.CimObjectView {
        const idx = self.id_to_object.get(id) orelse return null;
        const obj = self.new_objects[idx];
        // The stored object must round-trip -- pairs with the id_to_object build.
        assert(std.mem.eql(u8, obj.id, id));
        return self.view(obj);
    }

    /// Declared objects whose id starts with `id_prefix`, in document order.
    /// The caller owns the returned slice. Matching follows
    /// `ids.id_prefix_matches`.
    pub fn get_object_by_id_prefix(
        self: Overlay,
        gpa: std.mem.Allocator,
        id_prefix: []const u8,
    ) ![]const CimObject {
        var matches: std.ArrayList(CimObject) = .empty;
        errdefer matches.deinit(gpa);
        for (self.new_objects) |obj| {
            if (ids.id_prefix_matches(obj.id, id_prefix)) try matches.append(gpa, obj);
        }
        return matches.toOwnedSlice(gpa);
    }

    /// Bind a stored object to this part's XML context.
    pub fn view(self: Overlay, obj: CimObject) tag_index.CimObjectView {
        return self.doc.view(obj);
    }

    /// The part's `FullModel` metadata element, or null if it carries none.
    pub fn getFullModelView(self: Overlay) ?tag_index.CimObjectView {
        const group = self.doc.get_objects_by_type("FullModel");
        if (group.len == 0) return null;
        return self.doc.view(group[0]);
    }

    /// Read a property off the part's `FullModel`. Null when the element is
    /// absent or does not carry that property.
    pub fn getFullModelProperty(self: Overlay, property_name: []const u8) !?[]const u8 {
        assert(property_name.len > 0);
        const full_model = self.getFullModelView() orelse return null;
        return full_model.getProperty(property_name);
    }
};

const Classification = union(enum) {
    /// Metadata (`FullModel`), or an id that normalizes to nothing.
    skip,
    /// Declares a new object; it is stored under its raw `rdf:ID`.
    declares,
    /// Patches an object of the primary part; payload is the normalized mRID.
    patch: []const u8,
};

/// Decide what one already-parsed object means to the overlay layer. The
/// `#` requirement on `rdf:about` is what keeps `FullModel`'s `urn:uuid:` id
/// from being read as a patch key.
fn classify(doc: CimDocument, obj: CimObject, policy: IdPolicy) Classification {
    const tag_start = doc.boundaries[obj.object_tag_idx].start;

    if (xml_scan.extract_rdf_id(doc.xml, tag_start)) |raw| {
        if (raw.len > 0) switch (policy) {
            .id_declares_object => return .declares,
            .id_names_patch => {
                const mrid = ids.strip_underscore(raw);
                return if (mrid.len > 0) .{ .patch = mrid } else .skip;
            },
        };
    } else |_| {}

    if (xml_scan.extract_rdf_about(doc.xml, tag_start)) |raw| {
        if (raw.len > 1 and raw[0] == '#') {
            const mrid = ids.strip_underscore(ids.strip_hash(raw));
            if (mrid.len > 0) return .{ .patch = mrid };
        }
    } else |_| {}

    return .skip;
}

/// The identifier as the file spells it, for a duplicate-key report. Both
/// attribute forms can name a patch, so both are candidates.
fn raw_patch_id(xml: []const u8, tag_start: u32) ?[]const u8 {
    if (xml_scan.extract_rdf_id(xml, tag_start)) |raw| {
        if (ids.strip_underscore(raw).len > 0) return raw;
    } else |_| {}
    if (xml_scan.extract_rdf_about(xml, tag_start)) |raw| {
        if (raw.len > 1 and raw[0] == '#' and
            ids.strip_underscore(ids.strip_hash(raw)).len > 0) return raw;
    } else |_| {}
    return null;
}

fn patch_before(_: void, a: Patch, b: Patch) bool {
    return std.mem.order(u8, a.mrid, b.mrid) == .lt;
}

fn object_before(_: void, a: CimObject, b: CimObject) bool {
    return a.object_tag_idx < b.object_tag_idx;
}

/// A merged read of a primary object with its optional TP and SSH overlays.
/// Precedence is SSH > TP > primary: SSH shadows everything, TP shadows the
/// primary part. `init` runs one `find_patch` per overlay and caches the hit, so
/// the accessors below repeat no lookups.
pub const CimMergedView = struct {
    eq: tag_index.CimObjectView,
    tp: ?Context,
    ssh: ?Context,

    const Context = struct {
        xml: []const u8,
        boundaries: []const TagBoundary,
        patch: Patch,
    };

    pub fn init(
        eq: tag_index.CimObjectView,
        mrid: []const u8,
        tp_opt: ?Overlay,
        ssh_opt: ?Overlay,
    ) CimMergedView {
        assert(mrid.len > 0);
        assert(eq.id.len > 0);
        // mrid need not equal strip_underscore(eq.id): in CGMES the mRID may
        // differ from rdf:ID, and overlays key by mRID. Callers resolve it via
        // CimObjectView.mrid, so such models merge consistently across commands.
        return .{
            .eq = eq,
            .tp = context_for(tp_opt, mrid),
            .ssh = context_for(ssh_opt, mrid),
        };
    }

    fn context_for(overlay_opt: ?Overlay, mrid: []const u8) ?Context {
        const overlay = overlay_opt orelse return null;
        const patch = overlay.find_patch(mrid) orelse return null;
        return .{ .xml = overlay.xml, .boundaries = overlay.boundaries, .patch = patch };
    }

    /// Get a text property. SSH value takes priority, then TP, then the primary.
    pub fn getProperty(self: CimMergedView, name: []const u8) !?[]const u8 {
        if (self.ssh) |s| {
            if (try patch_view(s).getProperty(name)) |v| return v;
        }
        if (self.tp) |t| {
            if (try patch_view(t).getProperty(name)) |v| return v;
        }
        return self.eq.getProperty(name);
    }

    /// Get an rdf:resource reference. SSH value takes priority, then TP, then
    /// the primary.
    pub fn getReference(self: CimMergedView, name: []const u8) !?[]const u8 {
        if (self.ssh) |s| {
            if (try patch_view(s).getReference(name)) |v| return v;
        }
        if (self.tp) |t| {
            if (try patch_view(t).getReference(name)) |v| return v;
        }
        return self.eq.getReference(name);
    }

    fn patch_view(ctx: Context) tag_index.CimObjectView {
        return .{
            .xml = ctx.xml,
            .boundaries = ctx.boundaries,
            .object_tag_idx = ctx.patch.patch_tag_idx,
            .closing_tag_idx = ctx.patch.closing_tag_idx,
            .id = ctx.patch.mrid,
            .type_name = "",
        };
    }

    fn apply_overrides(result: anytype, values: anytype, comptime names: anytype) void {
        inline for (names, 0..) |_, idx| {
            if (values[idx]) |value| result[idx] = value;
        }
    }

    /// Batch-fetch text properties. SSH values take priority, then TP.
    pub fn getProperties(self: CimMergedView, comptime names: anytype) ![names.len]?[]const u8 {
        var result = try self.eq.getProperties(names);
        if (self.tp) |t| apply_overrides(&result, try patch_view(t).getProperties(names), names);
        if (self.ssh) |s| apply_overrides(&result, try patch_view(s).getProperties(names), names);
        return result;
    }

    /// Batch-fetch rdf:resource references. SSH values take priority, then TP.
    pub fn getReferences(self: CimMergedView, comptime names: anytype) ![names.len]?[]const u8 {
        var result = try self.eq.getReferences(names);
        if (self.tp) |t| apply_overrides(&result, try patch_view(t).getReferences(names), names);
        if (self.ssh) |s| apply_overrides(&result, try patch_view(s).getReferences(names), names);
        return result;
    }

    /// The union of primary + TP + SSH properties, SSH > TP > primary.
    /// Caller owns the returned map; values borrow from the underlying XML.
    pub fn getAllProperties(self: CimMergedView, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var result = try self.eq.getAllProperties(gpa);
        errdefer result.deinit();
        if (self.tp) |t| try overlay_into(&result, patch_view(t).getAllProperties(gpa));
        if (self.ssh) |s| try overlay_into(&result, patch_view(s).getAllProperties(gpa));
        return result;
    }

    /// The union of primary + TP + SSH references, SSH > TP > primary.
    /// Caller owns the returned map; values borrow from the underlying XML.
    pub fn getAllReferences(self: CimMergedView, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var result = try self.eq.getAllReferences(gpa);
        errdefer result.deinit();
        if (self.tp) |t| try overlay_into(&result, patch_view(t).getAllReferences(gpa));
        if (self.ssh) |s| try overlay_into(&result, patch_view(s).getAllReferences(gpa));
        return result;
    }

    fn overlay_into(
        dest: *std.StringHashMap([]const u8),
        patch_map_result: anytype,
    ) !void {
        var patch_map = try patch_map_result;
        defer patch_map.deinit();
        var it = patch_map.iterator();
        while (it.next()) |entry| try dest.put(entry.key_ptr.*, entry.value_ptr.*);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "an overlay separates declared objects from patches under the TP policy" {
    const gpa = testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:TP1">
        \\    <md:Model.scenarioTime>2026-01-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
        \\  <cim:TopologicalNode rdf:ID="_TN1">
        \\    <cim:IdentifiedObject.mRID>TN1</cim:IdentifiedObject.mRID>
        \\    <cim:TopologicalNode.BaseVoltage rdf:resource="#_BV220"/>
        \\  </cim:TopologicalNode>
        \\  <cim:TopologicalNode rdf:ID="_TN2">
        \\    <cim:IdentifiedObject.mRID>TN2</cim:IdentifiedObject.mRID>
        \\  </cim:TopologicalNode>
        \\  <cim:Terminal rdf:about="#_T_LOAD1">
        \\    <cim:Terminal.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:Terminal>
        \\  <cim:ConnectivityNode rdf:about="#_CN_LOAD">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:ConnectivityNode>
        \\</rdf:RDF>
    ;
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, xml));
    defer tp.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), tp.new_objects.len);
    try testing.expectEqual(@as(usize, 2), tp.patches.len);
    // Declared objects keep the part's order, not `doc.objects`' type grouping.
    try testing.expectEqualStrings("_TN1", tp.new_objects[0].id);
    try testing.expectEqualStrings("_TN2", tp.new_objects[1].id);

    // Patches are sorted -- the stripped mRIDs CN_LOAD < T_LOAD1 alphabetically.
    try testing.expectEqualStrings("CN_LOAD", tp.patches[0].mrid);
    try testing.expectEqualStrings("T_LOAD1", tp.patches[1].mrid);
}

test "the same rdf:ID is a patch under SSH and a declared object under TP" {
    const gpa = testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:ID="_SW1">
        \\    <cim:Switch.open>true</cim:Switch.open>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    var ssh = try Overlay.init_ssh(gpa, try gpa.dupe(u8, xml));
    defer ssh.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), ssh.patches.len);
    try testing.expectEqual(@as(usize, 0), ssh.new_objects.len);
    try testing.expect(ssh.find_patch("SW1") != null);
    try testing.expectEqual(@as(?tag_index.CimObjectView, null), ssh.get_object_by_id("_SW1"));

    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, xml));
    defer tp.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), tp.patches.len);
    try testing.expectEqual(@as(usize, 1), tp.new_objects.len);
    try testing.expectEqual(@as(?Patch, null), tp.find_patch("SW1"));
    try testing.expect(tp.get_object_by_id("_SW1") != null);
}

test "find_patch resolves a Terminal patch and its TopologicalNode reference" {
    const gpa = testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:about="#_T_LOAD1">
        \\    <cim:Terminal.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, xml));
    defer tp.deinit(gpa);

    const patch = tp.find_patch("T_LOAD1") orelse return error.TestFailed;
    const tn_ref = try tp.getReferenceFromPatch(patch, "Terminal.TopologicalNode");
    try testing.expect(tn_ref != null);
    try testing.expectEqualStrings("#_TN1", tn_ref.?);

    // Absent mRID yields null.
    try testing.expectEqual(@as(?Patch, null), tp.find_patch("not_there"));
}

test "get_object_by_id returns a declared object by raw rdf:ID" {
    const gpa = testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:TopologicalNode rdf:ID="_TN1">
        \\    <cim:IdentifiedObject.name>Bus 1</cim:IdentifiedObject.name>
        \\    <cim:TopologicalNode.BaseVoltage rdf:resource="#_BV220"/>
        \\  </cim:TopologicalNode>
        \\</rdf:RDF>
    ;
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, xml));
    defer tp.deinit(gpa);

    const view = tp.get_object_by_id("_TN1") orelse return error.TestFailed;
    try testing.expectEqualStrings("TopologicalNode", view.type_name);
    try testing.expectEqualStrings("_TN1", view.id);
    const name = try view.getProperty("IdentifiedObject.name");
    try testing.expect(name != null);
    try testing.expectEqualStrings("Bus 1", std.mem.trim(u8, name.?, " \t\r\n"));

    // Unknown id yields null.
    try testing.expectEqual(@as(?tag_index.CimObjectView, null), tp.get_object_by_id("_nope"));
}

test "get_object_by_id_prefix matches declared objects; leading _ optional" {
    const gpa = testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:TopologicalNode rdf:ID="_TN_abc1"/>
        \\  <cim:TopologicalNode rdf:ID="_TN_abc2"/>
        \\  <cim:TopologicalNode rdf:ID="_TN_xyz"/>
        \\</rdf:RDF>
    ;
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, xml));
    defer tp.deinit(gpa);

    const ambiguous = try tp.get_object_by_id_prefix(gpa, "TN_abc");
    defer gpa.free(ambiguous);
    try testing.expectEqual(@as(usize, 2), ambiguous.len);

    const unique = try tp.get_object_by_id_prefix(gpa, "_TN_xyz");
    defer gpa.free(unique);
    try testing.expectEqual(@as(usize, 1), unique.len);
    try testing.expectEqualStrings("_TN_xyz", unique[0].id);

    const none = try tp.get_object_by_id_prefix(gpa, "nope");
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "a declared object keeps a raw id that normalizes to nothing" {
    const gpa = testing.allocator;
    // `_` is a placeholder id: usable for navigation, useless as an overlay key.
    const xml = "<rdf:RDF><cim:TopologicalNode rdf:ID=\"_\"/></rdf:RDF>";
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, xml));
    defer tp.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), tp.new_objects.len);
    try testing.expectEqualStrings("_", tp.new_objects[0].id);
}

test "an identifier that normalizes to an empty key is not a patch" {
    const gpa = testing.allocator;
    const inputs = [_][]const u8{
        "<rdf:RDF><cim:Terminal rdf:about=\"#_\"/></rdf:RDF>",
        "<rdf:RDF><cim:Switch rdf:ID=\"_\"/></rdf:RDF>",
    };
    for (inputs) |xml| {
        var ssh = try Overlay.init_ssh(gpa, try gpa.dupe(u8, xml));
        defer ssh.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), ssh.patches.len);
    }
}

test "bare and underscored patch identifiers index to the same key" {
    const gpa = testing.allocator;
    const inputs = [_][]const u8{
        "<rdf:RDF><cim:Switch rdf:about=\"#SW1\"><cim:Switch.open>true</cim:Switch.open></cim:Switch></rdf:RDF>",
        "<rdf:RDF><cim:Switch rdf:about=\"#_SW1\"><cim:Switch.open>true</cim:Switch.open></cim:Switch></rdf:RDF>",
    };
    for (inputs) |xml| {
        var ssh = try Overlay.init_ssh(gpa, try gpa.dupe(u8, xml));
        defer ssh.deinit(gpa);
        const patch = ssh.find_patch("SW1") orelse return error.TestFailed;
        const value = try ssh.getPropertyFromPatch(patch, "Switch.open") orelse return error.TestFailed;
        try testing.expectEqualStrings("true", value);
    }
}

test "metadata tags are neither patches nor declared objects" {
    const gpa = testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:SKIP_ME">
        \\    <md:Model.profile>TP</md:Model.profile>
        \\  </md:FullModel>
        \\</rdf:RDF>
    ;
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, xml));
    defer tp.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), tp.new_objects.len);
    try testing.expectEqual(@as(usize, 0), tp.patches.len);
    // It is still an object of the part -- that is how FullModel is read.
    try testing.expect(tp.getFullModelView() != null);
}

test "duplicate declared rdf:IDs are rejected with a diagnostic" {
    const gpa = testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:TopologicalNode rdf:ID="_TN1"/>
        \\  <cim:TopologicalNode rdf:ID="_TN1"/>
        \\</rdf:RDF>
    ;
    try testing.expectError(error.DuplicateId, Overlay.init_tp(gpa, try gpa.dupe(u8, xml)));

    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.DuplicateId,
        Overlay.initWithDiagnostics(gpa, try gpa.dupe(u8, xml), .id_declares_object, &diagnostics),
    );
    try testing.expectEqualStrings("_TN1", diagnostics.duplicate_id());
    try testing.expectEqual(@as(u64, 3), diagnostics.duplicate_line);
    try testing.expect(!diagnostics.duplicate_id_truncated);
}

test "two spellings of one patch key are rejected with a diagnostic" {
    const gpa = testing.allocator;
    // `#T1` and `#_T1` are distinct ids to the parser and collide only once
    // normalized, so this is the overlay layer's own duplicate check firing.
    const xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:about="#T1"/>
        \\  <cim:Terminal rdf:about="#_T1"/>
        \\</rdf:RDF>
    ;
    try testing.expectError(error.DuplicateId, Overlay.init_tp(gpa, try gpa.dupe(u8, xml)));

    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.DuplicateId,
        Overlay.initWithDiagnostics(gpa, try gpa.dupe(u8, xml), .id_declares_object, &diagnostics),
    );
    try testing.expectEqualStrings("#_T1", diagnostics.duplicate_id());
    try testing.expectEqual(@as(u64, 3), diagnostics.duplicate_line);
}

test "under SSH an rdf:ID and an rdf:about naming one object collide" {
    const gpa = testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:ID="_SW1"/>
        \\  <cim:Switch rdf:about="#SW1"/>
        \\</rdf:RDF>
    ;
    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.DuplicateId,
        Overlay.initWithDiagnostics(gpa, try gpa.dupe(u8, xml), .id_names_patch, &diagnostics),
    );
    try testing.expectEqualStrings("#SW1", diagnostics.duplicate_id());
    try testing.expectEqual(@as(u64, 3), diagnostics.duplicate_line);
    try testing.expect(!diagnostics.duplicate_id_truncated);
}

test "sharing the parser makes an overlay reject a doubly-spelled id" {
    const gpa = testing.allocator;
    // `rdf:ID="X"` and `rdf:about="#X"` are one id to `CimDocument`, which has
    // always rejected the pair. Overlays used to index the two independently.
    const xml =
        \\<rdf:RDF>
        \\  <cim:TopologicalNode rdf:ID="_TN1"/>
        \\  <cim:Terminal rdf:about="#_TN1"/>
        \\</rdf:RDF>
    ;
    try testing.expectError(error.DuplicateId, Overlay.init_tp(gpa, try gpa.dupe(u8, xml)));
}

test "getFullModelView returns the metadata element with its urn id" {
    const gpa = testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:view-test-1">
        \\    <md:Model.scenarioTime>2024-06-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
        \\  <cim:Switch rdf:ID="_sw1">
        \\    <cim:Switch.open>false</cim:Switch.open>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    var ssh = try Overlay.init_ssh(gpa, try gpa.dupe(u8, xml));
    defer ssh.deinit(gpa);

    const view = ssh.getFullModelView();
    try testing.expect(view != null);
    try testing.expectEqualStrings("urn:uuid:view-test-1", view.?.id);
    try testing.expectEqualStrings("FullModel", view.?.type_name);
    const st = try view.?.getProperty("Model.scenarioTime");
    try testing.expect(st != null);
    try testing.expectEqualStrings("2024-06-01T00:00:00Z", std.mem.trim(u8, st.?, " \t\r\n"));
}

test "getFullModelProperty reads times, and yields null without a FullModel" {
    const gpa = testing.allocator;
    const with_model =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:ssh-model-1">
        \\    <md:Model.scenarioTime>2023-01-01T12:00:00Z</md:Model.scenarioTime>
        \\    <md:Model.created>2023-01-01T10:00:00Z</md:Model.created>
        \\  </md:FullModel>
        \\  <cim:Switch rdf:ID="_sw1">
        \\    <cim:Switch.open>false</cim:Switch.open>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    var ssh = try Overlay.init_ssh(gpa, try gpa.dupe(u8, with_model));
    defer ssh.deinit(gpa);

    const scenario_time = try ssh.getFullModelProperty("Model.scenarioTime");
    try testing.expect(scenario_time != null);
    try testing.expectEqualStrings("2023-01-01T12:00:00Z", std.mem.trim(u8, scenario_time.?, " \t\r\n"));
    const created = try ssh.getFullModelProperty("Model.created");
    try testing.expect(created != null);
    try testing.expectEqualStrings("2023-01-01T10:00:00Z", std.mem.trim(u8, created.?, " \t\r\n"));
    // Present FullModel, absent property.
    try testing.expectEqual(@as(?[]const u8, null), try ssh.getFullModelProperty("Model.version"));

    const without_model = "<rdf:RDF><cim:Switch rdf:ID=\"_sw1\"/></rdf:RDF>";
    var bare = try Overlay.init_ssh(gpa, try gpa.dupe(u8, without_model));
    defer bare.deinit(gpa);
    try testing.expectEqual(@as(?tag_index.CimObjectView, null), bare.getFullModelView());
    try testing.expectEqual(@as(?[]const u8, null), try bare.getFullModelProperty("Model.scenarioTime"));
}

test "CimMergedView applies SSH patches to bare EQ identifiers" {
    const gpa = testing.allocator;
    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:ID="SW1">
        \\    <cim:Switch.open>false</cim:Switch.open>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    const ssh_xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:about="#SW1">
        \\    <cim:Switch.open>true</cim:Switch.open>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    var eq = try CimDocument.init(gpa, try gpa.dupe(u8, eq_xml));
    defer eq.deinit(gpa);
    var ssh = try Overlay.init_ssh(gpa, try gpa.dupe(u8, ssh_xml));
    defer ssh.deinit(gpa);

    const view = eq.getObjectById("SW1") orelse return error.TestFailed;
    const mrid = try view.mrid();
    const merged = CimMergedView.init(view, mrid, null, ssh);
    try testing.expectEqualStrings("true", (try merged.getProperty("Switch.open")).?);
}

test "CimMergedView.getAllProperties merges EQ + TP + SSH with SSH precedence" {
    const gpa = testing.allocator;
    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:ID="_SW1">
        \\    <cim:IdentifiedObject.name>eq-name</cim:IdentifiedObject.name>
        \\    <cim:Switch.normalOpen>false</cim:Switch.normalOpen>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:about="#_SW1">
        \\    <cim:Switch.normalOpen>true</cim:Switch.normalOpen>
        \\    <cim:Switch.retained>false</cim:Switch.retained>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    const ssh_xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:about="#_SW1">
        \\    <cim:Switch.open>true</cim:Switch.open>
        \\    <cim:Switch.retained>true</cim:Switch.retained>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    var eq = try CimDocument.init(gpa, try gpa.dupe(u8, eq_xml));
    defer eq.deinit(gpa);
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);
    var ssh = try Overlay.init_ssh(gpa, try gpa.dupe(u8, ssh_xml));
    defer ssh.deinit(gpa);

    const view = eq.getObjectById("_SW1").?;
    const merged = CimMergedView.init(view, "SW1", tp, ssh);

    var props = try merged.getAllProperties(gpa);
    defer props.deinit();

    // EQ-only key preserved.
    try testing.expectEqualStrings("eq-name", props.get("IdentifiedObject.name").?);
    // TP overrides EQ.
    try testing.expectEqualStrings("true", props.get("Switch.normalOpen").?);
    // SSH overrides TP (Switch.retained).
    try testing.expectEqualStrings("true", props.get("Switch.retained").?);
    // SSH-only key included.
    try testing.expectEqualStrings("true", props.get("Switch.open").?);
}

test "CimMergedView.getAllReferences merges EQ + TP with TP precedence" {
    const gpa = testing.allocator;
    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_CE_eq"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:about="#_T1">
        \\    <cim:Terminal.TopologicalNode rdf:resource="#_TN1"/>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_CE_tp"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    var eq = try CimDocument.init(gpa, try gpa.dupe(u8, eq_xml));
    defer eq.deinit(gpa);
    var tp = try Overlay.init_tp(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);

    const view = eq.getObjectById("_T1").?;
    const merged = CimMergedView.init(view, "T1", tp, null);

    var refs = try merged.getAllReferences(gpa);
    defer refs.deinit();

    // TP-added reference visible.
    try testing.expectEqualStrings("#_TN1", refs.get("Terminal.TopologicalNode").?);
    // TP overrides the EQ value.
    try testing.expectEqualStrings("#_CE_tp", refs.get("Terminal.ConductingEquipment").?);
}
