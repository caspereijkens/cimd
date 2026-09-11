//! CimDocument -- one parsed CIM document, and cimd's primary parse target.
//!
//! Profile-agnostic: it indexes top-level objects carrying `rdf:ID` or
//! `rdf:about`, which is every CGMES profile (EQ, SSH, TP, SV, DL, DY, GL) and
//! any other CIM document of that shape. Nothing here knows what a profile is;
//! routing a file to a profile is cgmes/profile.zig's job, and the
//! CGMES-specific overlay reads live in cgmes/overlay.zig, which is this
//! same parse plus an index on the normalized mRID.
//!
//! It is *not* a general RDF/XML parser, and does not resolve namespaces.
//! Element local names are read from either `prefix:LocalName` or the
//! unprefixed `LocalName` form used with a default namespace. RDF attributes
//! are still matched literally as `rdf:ID="` and `rdf:about="`. A document that
//! binds the RDF namespace to any prefix other than `rdf` is therefore not
//! recognized -- and fails quietly, indexing zero objects rather than erroring,
//! because "no tag here declares an id" is also what an ordinary non-object
//! element looks like. Every CGMES export in the wild uses the `rdf:` binding,
//! so this buys a single-pass scan with no namespace bookkeeping; supporting
//! other RDF bindings later would require resolving prefixes at parse time.
//!
//! Objects are grouped into contiguous type ranges, with a raw ID lookup map.
//! Strings borrow immutable caller-owned XML. Objects also borrow the document's
//! context and boundaries, so both input and parsed storage must remain alive.

const std = @import("std");
const tag_index = @import("tag_index.zig");
const xml_scan = @import("xml_scan.zig");
pub const CimObject = tag_index.CimObject;
const TagBoundary = xml_scan.TagBoundary;
const ids = @import("ids.zig");
const cim_types = @import("cim_types.zig");

const assert = std.debug.assert;
pub const Diagnostics = @import("diagnostics.zig").Diagnostics;

pub const CimDocument = struct {
    objects: []CimObject,
    id_to_index: std.StringHashMap(u32),
    type_index: std.StringHashMap(TypeRange),

    context: *tag_index.ObjectContext,
    xml: []const u8,
    boundaries: []TagBoundary,

    const TypeRange = struct { start: u32, len: u32 };
    pub const TypeGroup = struct {
        type_name: []const u8,
        objects: []const CimObject,
        /// Index of `objects[0]` in the document's object array; the counting
        /// sort guarantees the group occupies `start..start + objects.len`.
        /// Lets consumers key side tables by object index without touching
        /// the storage layout.
        start: u32,
    };
    pub const TypeGroupIterator = struct {
        model: *const CimDocument,
        next_index: u32 = 0,

        pub fn next(self: *TypeGroupIterator) ?TypeGroup {
            const objects_count: u32 = @intCast(self.model.objects.len);
            if (self.next_index == objects_count) return null;
            assert(self.next_index < objects_count);

            const start = self.next_index;
            const type_name = self.model.objects[start].type_name();
            const range = self.model.type_index.get(type_name).?;
            assert(range.start == start);
            assert(range.len > 0);
            const end = start + range.len;
            assert(end <= objects_count);
            self.next_index = end;

            const objects = self.model.objects[start..end];
            assert(std.mem.eql(u8, objects[0].type_name(), type_name));
            assert(std.mem.eql(u8, objects[objects.len - 1].type_name(), type_name));
            return .{ .type_name = type_name, .objects = objects, .start = start };
        }
    };
    pub const TypeCount = struct {
        type_name: []const u8,
        count: u32,

        /// Alphabetical by type name. The single ordering shared by every
        /// type-count display (the `types` command, the get-ambiguity
        /// breakdown, and its JSON envelope), so they can't sort differently.
        pub fn less_than(_: void, a: TypeCount, b: TypeCount) bool {
            return std.mem.order(u8, a.type_name, b.type_name) == .lt;
        }
    };

    /// Borrows immutable XML on success and failure; the input must outlive the document.
    pub fn init(gpa: std.mem.Allocator, xml: []const u8) !CimDocument {
        return init_with_diagnostics(gpa, xml, null);
    }

    /// Borrows XML under the same lifetime contract as init.
    pub fn init_with_diagnostics(gpa: std.mem.Allocator, xml: []const u8, diagnostics: ?*Diagnostics) !CimDocument {
        if (xml.len == 0) return error.EmptyInput;

        var malformed: xml_scan.MalformedXML = .{};
        var boundary_list = xml_scan.find_tag_boundaries_with_error_offset(gpa, xml, &malformed) catch |err| {
            if (err == error.MalformedXML) if (diagnostics) |d| d.record_malformed_xml(xml, malformed);
            return err;
        };
        errdefer boundary_list.deinit(gpa);
        const boundaries = try boundary_list.toOwnedSlice(gpa);
        errdefer gpa.free(boundaries);

        const context = try gpa.create(tag_index.ObjectContext);
        errdefer gpa.destroy(context);
        context.* = .{ .xml = xml, .boundaries = boundaries };

        const closing_for = xml_scan.build_closing_index_with_error_offset(
            gpa,
            xml,
            boundaries,
            &malformed,
        ) catch |err| {
            if (err == error.MalformedXML) if (diagnostics) |d| d.record_malformed_xml(xml, malformed);
            return err;
        };
        defer gpa.free(closing_for);

        const tables = try build_object_tables(gpa, context, closing_for, diagnostics);
        return .{
            .objects = tables.objects,
            .id_to_index = tables.id_to_index,
            .type_index = tables.type_index,
            .context = context,
            .xml = xml,
            .boundaries = boundaries,
        };
    }

    pub fn deinit(self: *CimDocument, gpa: std.mem.Allocator) void {
        self.type_index.deinit();
        self.id_to_index.deinit();
        gpa.free(self.objects);
        gpa.destroy(self.context);
        gpa.free(self.boundaries);
    }

    /// The document's XML bytes. The stable accessor for consumers that need
    /// the source text (header classification, offset-to-line mapping)
    /// without coupling to the storage field.
    pub fn source(self: *const CimDocument) []const u8 {
        return self.xml;
    }

    pub fn object_count(self: *const CimDocument) u32 {
        assert(self.objects.len <= std.math.maxInt(u32));
        return @intCast(self.objects.len);
    }

    pub fn object_at(self: *const CimDocument, index: u32) CimObject {
        assert(index < self.objects.len);
        return self.objects[index];
    }

    pub fn object_by_id(self: CimDocument, id: []const u8) ?CimObject {
        const idx = self.id_to_index.get(id) orelse return null;
        const result = self.objects[idx];
        // Pair with the index lookup: the stored object's id must round-trip.
        assert(result.context == self.context);
        assert(std.mem.eql(u8, result.id(), id));
        return result;
    }

    /// Returns objects whose mRID starts with `id_prefix`, in storage order
    /// (grouped by type). The caller owns the returned slice. Matching follows
    /// `ids.id_prefix_matches`: literal startsWith (so FullModel `urn:uuid:...`
    /// ids resolve) plus a leading-underscore convenience for the rdf:ID form.
    pub fn objects_by_id_prefix(
        self: CimDocument,
        gpa: std.mem.Allocator,
        id_prefix: []const u8,
    ) ![]const tag_index.CimObject {
        var count: usize = 0;
        for (self.objects) |obj| count += @intFromBool(ids.id_prefix_matches(obj.id(), id_prefix));
        const matches = try gpa.alloc(CimObject, count);
        errdefer comptime unreachable;
        var index: usize = 0;
        for (self.objects) |obj| {
            if (!ids.id_prefix_matches(obj.id(), id_prefix)) continue;
            matches[index] = obj;
            index += 1;
        }
        assert(index == count);
        return matches;
    }

    pub fn objects_by_type(self: CimDocument, type_name: []const u8) []const CimObject {
        const range = self.type_index.get(type_name) orelse return &[_]CimObject{};
        return self.objects[range.start .. range.start + range.len];
    }

    /// Iterate the document's allocation-free exact-type groups. Every object
    /// appears once, and every returned slice contains one exact CIM type.
    pub fn type_groups(self: *const CimDocument) TypeGroupIterator {
        assert(self.objects.len <= std.math.maxInt(u32));
        return .{ .model = self };
    }

    /// Count objects matching `requested_type`, including CIM subtypes.
    /// Uses the compact type index, so count-mode does not scan every object.
    pub fn count_objects_by_type_filter(self: CimDocument, requested_type: []const u8) usize {
        var count: usize = 0;
        var it = self.type_index.iterator();
        while (it.next()) |entry| {
            if (cim_types.matches_filter(entry.key_ptr.*, requested_type)) {
                count += entry.value_ptr.*.len;
            }
        }
        assert(count <= self.objects.len);
        return count;
    }

    /// Return objects matching `requested_type`, including CIM subtypes.
    /// Caller owns the returned slice. Output order follows `self.objects`.
    pub fn collect_objects_by_type_filter(
        self: CimDocument,
        gpa: std.mem.Allocator,
        requested_type: []const u8,
    ) ![]CimObject {
        const count = self.count_objects_by_type_filter(requested_type);
        const out = try gpa.alloc(CimObject, count);
        errdefer comptime unreachable;

        var i: usize = 0;
        for (self.objects) |obj| {
            if (!cim_types.matches_filter(obj.type_name(), requested_type)) continue;
            assert(i < out.len);
            out[i] = obj;
            i += 1;
        }
        assert(i == out.len);
        for (out) |obj| assert(cim_types.matches_filter(obj.type_name(), requested_type));
        return out;
    }

    /// Return a heap-allocated, alphabetically sorted type-count list.
    /// Caller owns the returned slice and must free it with gpa.free().
    pub fn sorted_type_counts(self: CimDocument, gpa: std.mem.Allocator) ![]TypeCount {
        const n = self.type_index.count();
        const out = try gpa.alloc(TypeCount, n);
        errdefer comptime unreachable;

        var i: usize = 0;
        var it = self.type_index.iterator();
        while (it.next()) |entry| {
            out[i] = .{
                .type_name = entry.key_ptr.*,
                .count = entry.value_ptr.*.len,
            };
            i += 1;
        }
        assert(i == n);

        std.mem.sort(TypeCount, out, {}, TypeCount.less_than);

        return out;
    }
};

/// Object discovery treats malformed and absent identity attributes alike
/// because a tag without a usable identifier cannot be indexed as an object.
fn extract_attribute_from_tag(xml: []const u8, tag: TagBoundary, comptime name: []const u8) ?[]const u8 {
    return xml_scan.extract_attribute_within(xml, tag.start, tag.end, name) catch null;
}

/// Extract the identifier that makes a tag a CIM object. Prefer a non-empty
/// rdf:ID, but keep inventory-style commands tolerant by falling back to
/// rdf:about when rdf:ID is absent, empty, or malformed.
fn extract_object_id_from_tag(xml: []const u8, tag: TagBoundary) ?[]const u8 {
    if (tag.start + 1 >= tag.end) return null;
    switch (xml[tag.start + 1]) {
        '/', '!', '?' => return null,
        else => {},
    }

    if (extract_attribute_from_tag(xml, tag, "rdf:ID")) |id| {
        if (id.len > 0) return id;
    }

    if (extract_attribute_from_tag(xml, tag, "rdf:about")) |about| {
        if (about.len > 0) {
            const local_id = ids.strip_hash(about);
            return if (local_id.len > 0) local_id else about;
        }
    }

    return null;
}

const ObjectIterator = struct {
    context: *const tag_index.ObjectContext,
    closing_for: []const u32,
    next_index: u32 = 0,

    fn next(self: *ObjectIterator) ?struct { tag_index: u32, id: []const u8 } {
        const context = self.context;
        assert(self.closing_for.len == context.boundaries.len);
        while (self.next_index < context.boundaries.len) {
            const index = self.next_index;
            self.next_index += 1;
            const id = extract_object_id_from_tag(context.xml, context.boundaries[index]) orelse continue;
            self.next_index = self.closing_for[index] + 1;
            assert(self.next_index > index);
            return .{ .tag_index = index, .id = id };
        }
        return null;
    }
};

const ObjectTables = struct {
    objects: []CimObject,
    id_to_index: std.StringHashMap(u32),
    type_index: std.StringHashMap(CimDocument.TypeRange),
};

const DiscoveredObject = struct {
    tag_index: u32,
    type_id: u32,
    id_start: u32,
    id_len: u32,

    /// Borrows `xml` by construction: the record stores offsets, not a slice.
    fn id(self: DiscoveredObject, xml: []const u8) []const u8 {
        return xml[self.id_start..][0..self.id_len];
    }
};

comptime {
    assert(@sizeOf(DiscoveredObject) == 16);
}

const DiscoveredType = struct { ordinal: u32, count: u32 };

const Discovery = struct {
    objects: std.ArrayList(DiscoveredObject) = .empty,
    types: std.StringHashMap(DiscoveredType),

    fn deinit(self: *Discovery, gpa: std.mem.Allocator) void {
        self.objects.deinit(gpa);
        self.types.deinit();
    }

    fn add(self: *Discovery, gpa: std.mem.Allocator, context: *const tag_index.ObjectContext, boundary: u32, id: []const u8) !void {
        const name = xml_scan.extract_tag_type(context.xml, context.boundaries[boundary].start) catch unreachable;
        try self.objects.ensureUnusedCapacity(gpa, 1);
        try self.types.ensureUnusedCapacity(1);
        errdefer comptime unreachable;

        const type_entry = self.types.getOrPutAssumeCapacity(name);
        if (!type_entry.found_existing) {
            type_entry.value_ptr.* = .{ .ordinal = self.types.count() - 1, .count = 0 };
        }
        type_entry.value_ptr.count += 1;
        self.objects.appendAssumeCapacity(.{
            .tag_index = boundary,
            .type_id = type_entry.value_ptr.ordinal,
            .id_start = @intCast(@intFromPtr(id.ptr) - @intFromPtr(context.xml.ptr)),
            .id_len = @intCast(id.len),
        });
    }
};

test "discovery insertion leaves both collections unchanged on allocation failure" {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    for (0..128) |i| try writer.print("<ext:T{d} rdf:ID=\"id{d}\"/>", .{ i % 53, i });
    const xml = writer.buffered();
    var boundaries = try xml_scan.find_tag_boundaries(std.testing.allocator, xml);
    defer boundaries.deinit(std.testing.allocator);
    const context: tag_index.ObjectContext = .{ .xml = xml, .boundaries = boundaries.items };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_discovery_failures, .{&context});
}

fn check_discovery_failures(gpa: std.mem.Allocator, context: *const tag_index.ObjectContext) !void {
    var discovery: Discovery = .{ .types = std.StringHashMap(DiscoveredType).init(gpa) };
    defer discovery.deinit(gpa);
    for (context.boundaries, 0..) |tag, index| {
        const name = try xml_scan.extract_tag_type(context.xml, tag.start);
        const id = extract_object_id_from_tag(context.xml, tag).?;
        const object_count = discovery.objects.items.len;
        const type_count = discovery.types.count();
        const previous = discovery.types.get(name);
        discovery.add(gpa, context, @intCast(index), id) catch |err| {
            try std.testing.expectEqual(object_count, discovery.objects.items.len);
            try std.testing.expectEqual(type_count, discovery.types.count());
            try std.testing.expectEqualDeep(previous, discovery.types.get(name));
            return err;
        };
    }
}

fn build_object_tables(
    gpa: std.mem.Allocator,
    context: *tag_index.ObjectContext,
    closing_for: []const u32,
    diagnostics: ?*Diagnostics,
) !ObjectTables {
    var discovery: Discovery = .{ .types = std.StringHashMap(DiscoveredType).init(gpa) };
    defer discovery.deinit(gpa);
    var iterator: ObjectIterator = .{ .context = context, .closing_for = closing_for };
    while (iterator.next()) |entry| try discovery.add(gpa, context, entry.tag_index, entry.id);

    const count: u32 = @intCast(discovery.objects.items.len);
    const objects = try gpa.alloc(CimObject, count);
    errdefer gpa.free(objects);
    var id_to_index = std.StringHashMap(u32).init(gpa);
    errdefer id_to_index.deinit();
    var type_index = std.StringHashMap(CimDocument.TypeRange).init(gpa);
    errdefer type_index.deinit();
    const Cursor = struct {
        next: u32,
        // Interned from the first occurrence; it need not lie inside this object's tag.
        name: []const u8,
    };
    const cursors = try gpa.alloc(Cursor, discovery.types.count());
    defer gpa.free(cursors);
    try id_to_index.ensureTotalCapacity(count);
    try type_index.ensureTotalCapacity(discovery.types.count());

    var position: u32 = 0;
    var types = discovery.types.iterator();
    while (types.next()) |entry| {
        // The name reaches us from extract_tag_type, so the borrow is worth
        // checking; once per type covers every object that will point at it.
        assert(within(context.xml, entry.key_ptr.*));
        cursors[entry.value_ptr.ordinal] = .{ .next = position, .name = entry.key_ptr.* };
        type_index.putAssumeCapacityNoClobber(entry.key_ptr.*, .{ .start = position, .len = entry.value_ptr.count });
        position += entry.value_ptr.count;
    }
    assert(position == count);

    for (discovery.objects.items) |entry| {
        const id = entry.id(context.xml);
        const seen = id_to_index.getOrPutAssumeCapacity(id);
        if (seen.found_existing) {
            if (diagnostics) |d| d.record_duplicate_id(context.xml, id, context.boundaries[entry.tag_index].start);
            return error.DuplicateId;
        }
        const cursor = &cursors[entry.type_id];
        assert(entry.tag_index < context.boundaries.len);
        const closing_tag_index = closing_for[entry.tag_index];
        assert(closing_tag_index < context.boundaries.len);
        assert(closing_tag_index >= entry.tag_index);
        assert(id.len > 0);
        seen.value_ptr.* = cursor.next;
        objects[cursor.next] = .{
            .context = context,
            .object_tag_idx = entry.tag_index,
            .closing_tag_idx = closing_tag_index,
            .id_slice = id,
            .type_slice = cursor.name,
        };
        cursor.next += 1;
    }
    assert(id_to_index.count() == count);
    return .{ .objects = objects, .id_to_index = id_to_index, .type_index = type_index };
}

fn within(source: []const u8, value: []const u8) bool {
    const source_address = @intFromPtr(source.ptr);
    const value_address = @intFromPtr(value.ptr);
    if (value_address < source_address) return false;
    const offset = value_address - source_address;
    return offset <= source.len and value.len <= source.len - offset;
}

test "CimDocument.init rejects duplicate RDF identifiers" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_DUP">
        \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\  <cim:BaseVoltage rdf:ID="_DUP">
        \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
        \\  </cim:BaseVoltage>
        \\</rdf:RDF>
    ;

    try std.testing.expectError(error.DuplicateId, CimDocument.init(gpa, xml));
}

test "EQ diagnostics record duplicate RDF identifier" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:BaseVoltage rdf:ID="_DUP"/>
        \\  <cim:BaseVoltage rdf:ID="_DUP"/>
        \\</rdf:RDF>
    ;
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(
        error.DuplicateId,
        CimDocument.init_with_diagnostics(gpa, xml, &diagnostics),
    );
    try std.testing.expectEqualStrings("_DUP", diagnostics.duplicate_id());
    try std.testing.expectEqual(@as(u64, 3), diagnostics.duplicate_line);
    try std.testing.expect(!diagnostics.duplicate_id_truncated);
}

test "EQ diagnostics record malformed XML position" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation>
        \\  </cim:WrongType>
        \\</rdf:RDF>
    ;
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(
        error.MalformedXML,
        CimDocument.init_with_diagnostics(gpa, xml, &diagnostics),
    );
    try std.testing.expect(diagnostics.malformed_xml_recorded);
    try std.testing.expectEqual(@as(u64, 3), diagnostics.malformed_xml_line);
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, xml, "</cim:WrongType>").?)),
        diagnostics.malformed_xml_offset,
    );
}

test "EQ inventory retains underscore-only identifiers" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_"/>
        \\  <cim:Substation rdf:ID="__"/>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, xml);
    defer model.deinit(gpa);
    try std.testing.expect(model.object_by_id("_") != null);
    try std.testing.expect(model.object_by_id("__") != null);
}

test "EQ inventory ignores identifier-looking text in comments" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <!-- placeholder rdf:ID="_" to be filled in later -->
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(gpa, xml);
    defer model.deinit(gpa);
    try std.testing.expect(model.object_by_id("_SS1") != null);
}

test "EQ normalizes local rdf:about identifiers for lookup and mRID resolution" {
    const gpa = std.testing.allocator;
    const xml = "<rdf:RDF><cim:Substation rdf:about=\"#_SSX\"/></rdf:RDF>";
    var model = try CimDocument.init(gpa, xml);
    defer model.deinit(gpa);

    const view = model.object_by_id("_SSX") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("SSX", try view.mrid());
    const matches = try model.objects_by_id_prefix(gpa, "SSX");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
}

test "EQ rejects rdf:ID and local rdf:about spellings of the same identifier" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:about="#_SS1"/>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\</rdf:RDF>
    ;
    try std.testing.expectError(error.DuplicateId, CimDocument.init(gpa, xml));
}

const PREFIX_TEST_XML =
    \\<rdf:RDF>
    \\  <cim:BaseVoltage rdf:ID="_abc123">
    \\    <cim:BaseVoltage.nominalVoltage>110</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\  <cim:BaseVoltage rdf:ID="_abc456">
    \\    <cim:BaseVoltage.nominalVoltage>220</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\  <cim:BaseVoltage rdf:ID="_xyz789">
    \\    <cim:BaseVoltage.nominalVoltage>400</cim:BaseVoltage.nominalVoltage>
    \\  </cim:BaseVoltage>
    \\</rdf:RDF>
;

test "objects_by_id_prefix returns a unique match" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, PREFIX_TEST_XML);
    defer model.deinit(gpa);

    const matches = try model.objects_by_id_prefix(gpa, "xyz");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("_xyz789", matches[0].id());
}

test "objects_by_id_prefix returns all ambiguous matches" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, PREFIX_TEST_XML);
    defer model.deinit(gpa);

    const matches = try model.objects_by_id_prefix(gpa, "abc");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);

    var seen_123 = false;
    var seen_456 = false;
    for (matches) |m| {
        if (std.mem.eql(u8, m.id(), "_abc123")) seen_123 = true;
        if (std.mem.eql(u8, m.id(), "_abc456")) seen_456 = true;
    }
    try std.testing.expect(seen_123 and seen_456);
}

test "objects_by_id_prefix returns empty slice on no match" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, PREFIX_TEST_XML);
    defer model.deinit(gpa);

    const matches = try model.objects_by_id_prefix(gpa, "nope");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "objects_by_id_prefix accepts prefix with explicit underscore" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, PREFIX_TEST_XML);
    defer model.deinit(gpa);

    const matches = try model.objects_by_id_prefix(gpa, "_xyz");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("_xyz789", matches[0].id());
}

test "objects_by_id_prefix matches full mRID" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, PREFIX_TEST_XML);
    defer model.deinit(gpa);

    const matches = try model.objects_by_id_prefix(gpa, "_abc123");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("_abc123", matches[0].id());
}
