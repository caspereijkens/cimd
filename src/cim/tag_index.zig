//! CIM objects and their children: what a parsed document is made of.
//!
//! One layer above `xml_scan.zig`, which finds tags in bytes and knows nothing
//! else. Here a tag becomes an object with an id and a type, and the tags
//! between its opener and its closer become children with names, values and a
//! property/reference distinction.

const std = @import("std");
const ids = @import("ids.zig");
const parse = @import("parse.zig");
const xml_scan = @import("xml_scan.zig");
const assert = std.debug.assert;

const TagBoundary = xml_scan.TagBoundary;
const extract_tag_type = xml_scan.extract_tag_type;
const extract_tag_type_terminated = xml_scan.extract_tag_type_terminated;
const extract_rdf_resource_within = xml_scan.extract_rdf_resource_within;
const is_element_open_tag = xml_scan.is_element_open_tag;

/// True when `child` can answer a text-property query: a literal, written in
/// expanded form. A self-closing element has no text content, so it is not one
/// even though `<name/>` is an empty literal.
inline fn is_text_property(child: Child, name: []const u8) bool {
    return child.kind == .property and !child.self_closing and std.mem.eql(u8, child.name, name);
}

pub fn get_property_from_indices(
    xml: []const u8,
    boundaries: []const TagBoundary,
    opening_tag_idx: u32,
    closing_tag_idx: u32,
    property_name: []const u8,
) ?[]const u8 {
    assert(property_name.len > 0);

    var it = ChildIterator.init_range(xml, boundaries, opening_tag_idx, closing_tag_idx);
    while (it.next()) |child| {
        if (is_text_property(child, property_name)) return child.value;
    }
    return null;
}

/// Unlike `get_property_from_indices` this can still fail: `ChildIterator` reads
/// every child without erroring, but a child whose `rdf:resource` will not parse
/// is a specific answer to a specific question, and returning it as "absent"
/// would be a lie.
pub fn get_reference_from_indices(
    xml: []const u8,
    boundaries: []const TagBoundary,
    opening_tag_idx: u32,
    closing_tag_idx: u32,
    property_name: []const u8,
) error{MalformedTag}!?[]const u8 {
    assert(property_name.len > 0);

    var it = ChildIterator.init_range(xml, boundaries, opening_tag_idx, closing_tag_idx);
    while (it.next()) |child| {
        if (!std.mem.eql(u8, child.name, property_name)) continue;
        // Asked for this name specifically, so an unreadable rdf:resource is an
        // answer the caller must not get as "absent".
        if (child.malformed_resource) return error.MalformedTag;
        if (child.kind == .reference) return child.value;
    }
    return null;
}

/// One child element of a CIM object -- the unit every consumer of a parsed
/// document actually works in, and the single answer to "what is a child".
///
/// Every field borrows from the document's `xml`, so a `Child` stays valid
/// exactly as long as the document does.
pub const Child = struct {
    /// Tag name with the namespace prefix stripped: `Terminal.ConductingEquipment`.
    name: []const u8,
    /// Text content for a property, the `rdf:resource` value for a reference.
    /// Empty (not null) for an empty literal in either syntax.
    value: []const u8,
    /// Follows the `rdf:resource` attribute, not the element syntax.
    kind: Kind,
    /// The element has an `rdf:resource=` whose value never closes inside the
    /// tag. Such a child is reported as a `.property` so tolerant walks treat it
    /// as "not a reference" and keep going, but the flag lets a walk that is
    /// asked for this name by name fail loudly instead, reporting a malformed
    /// reference rather than silently accepting a truncated export.
    malformed_resource: bool,
    /// Whether the element is written `<name/>`. Distinct from `kind`: a
    /// self-closing element without `rdf:resource` is an empty literal, so the
    /// property walks use this to keep skipping it while still calling it a
    /// property.
    self_closing: bool,
    /// The complete element slice, for consumers that copy it verbatim.
    raw: []const u8,

    pub const Kind = enum {
        /// Literal text content, including empty, in either syntax.
        property,
        /// Carries an `rdf:resource` attribute.
        reference,
    };
};

/// Walk the child elements of an object in document order.
///
/// This is *the* child walk. Before it there were twelve, each with its own
/// independently written skip rules, and five of them were wrong about XML
/// comments (see `xml_scan.is_element_open_tag`). Anything that needs an
/// object's children iterates this instead of indexing `boundaries`, which is
/// what let the boundary array leave the facade: it now lives in `xml_scan`,
/// reachable only by a caller that asks for raw scanning by name.
///
/// Skips comments and processing instructions: they are not elements, so they
/// are not children. It does *not* skip elements whose name will not parse --
/// there are none to skip. `CimDocument.init` runs
/// `xml_scan.build_closing_index`, which fails the whole document on an element
/// it cannot name, so every boundary that reaches this walk has already been
/// named once. An earlier version tolerated unparseable children here and so
/// answered queries from a document the scanner had not fully read; the check
/// now lives at the gate, where it can report an offset.
pub const ChildIterator = struct {
    xml: []const u8,
    boundaries: []const TagBoundary,
    next_idx: u32,
    end_idx: u32,

    /// Iterate the children of a bound element.
    pub fn init(view: ElementView) ChildIterator {
        return init_range(view.xml, view.boundaries, view.object_tag_idx, view.closing_tag_idx);
    }

    /// Iterate the children of an element identified by its opening and closing
    /// boundary indices. For callers that hold a span but no view -- the SSH/TP
    /// overlay patches, which are elements inside a document they do not own.
    ///
    /// Precondition: `boundaries` come from a document that has passed
    /// `xml_scan.build_closing_index` -- in practice, a `CimDocument`. That pass
    /// is what makes every element name here parseable, which `next` relies on.
    pub fn init_range(
        xml: []const u8,
        boundaries: []const TagBoundary,
        open_idx: u32,
        close_idx: u32,
    ) ChildIterator {
        assert(close_idx >= open_idx);
        assert(close_idx < boundaries.len);
        return .{
            .xml = xml,
            .boundaries = boundaries,
            .next_idx = open_idx + 1,
            .end_idx = close_idx,
        };
    }

    pub fn next(self: *ChildIterator) ?Child {
        while (self.next_idx < self.end_idx) {
            const i = self.next_idx;
            const tag = self.boundaries[i];
            self.next_idx += 1;

            if (!is_element_open_tag(self.xml, tag)) continue;
            // Unreachable by construction: this element's name already parsed in
            // `build_closing_index`, which failed the document if it could not.
            // See the precondition on `init_range`.
            const parsed = extract_tag_type_terminated(self.xml, tag.start) catch unreachable;
            const name = parsed.name;

            // No attributes, so no rdf:resource: the name ran into the end of
            // the tag. Skips the attribute scan for the plain text-property
            // child, which is most of a CIM document.
            const may_have_attributes = parsed.terminator != '>' and parsed.terminator != '/';
            var malformed_resource = false;
            const resource = if (!may_have_attributes) null else extract_rdf_resource_within(
                self.xml,
                tag.start,
                tag.end,
            ) catch blk: {
                malformed_resource = true;
                break :blk null;
            };
            const kind: Child.Kind = if (resource != null) .reference else .property;

            if (self.xml[tag.end - 1] == '/') {
                return .{
                    .name = name,
                    .value = resource orelse "",
                    .kind = kind,
                    .malformed_resource = malformed_resource,
                    .self_closing = true,
                    .raw = self.xml[tag.start .. tag.end + 1],
                };
            }

            // Expanded element, closed by the next boundary. CIM properties
            // never nest -- the same assumption every previous walk made when
            // slicing content up to the following tag. The closing boundary is
            // consumed with the opener so it is not offered as a child.
            const closing = self.boundaries[i + 1];
            self.next_idx = i + 2;
            return .{
                .name = name,
                .value = resource orelse self.xml[tag.end + 1 .. closing.start],
                .kind = kind,
                .malformed_resource = malformed_resource,
                .self_closing = false,
                .raw = self.xml[tag.start .. closing.end + 1],
            };
        }
        return null;
    }
};

/// The document storage shared by every object. Allocated separately from
/// CimDocument so an object remains bound to the same storage when its owning
/// document is moved.
pub const ObjectContext = struct {
    xml: []const u8,
    boundaries: []const TagBoundary,
};

/// One document-bound CIM object.
///
/// Identity and type are stored as slices, not as u32 spans resolved through
/// `context`. Spans would make the record 32 bytes instead of 48, but `id` and
/// `type_name` sit in every hot loop the library has -- the parse's type-count,
/// type-sort and id-index passes, and every type filter -- and there they feed
/// straight into string hashing and comparison. A stored slice arrives as one
/// load; a span has to be rebuilt from a base and two offsets at each of those
/// call sites. Measured on a 300 MB EQ, spans cost 5% of `cimd types`. Holding
/// the XML base pointer inline to shorten the load chain does not recover it --
/// the arithmetic is the cost, not the indirection.
pub const CimObject = struct {
    context: *const ObjectContext,
    object_tag_idx: u32,
    closing_tag_idx: u32,
    id_slice: []const u8,
    type_slice: []const u8,

    pub fn init(
        context: *const ObjectContext,
        object_tag_idx: u32,
        closing_tag_idx: u32,
        object_id: []const u8,
    ) error{MalformedTag}!CimObject {
        assert(object_id.len > 0);
        assert(object_tag_idx < context.boundaries.len);
        assert(closing_tag_idx < context.boundaries.len);
        assert(closing_tag_idx >= object_tag_idx);
        // Both must borrow from the document, or the object outlives its own
        // strings. `init` is the one place this can be established, so it is
        // established here rather than re-checked at every read.
        assert(within(context.xml, object_id));

        const object_type = try extract_tag_type(
            context.xml,
            context.boundaries[object_tag_idx].start,
        );
        assert(within(context.xml, object_type));
        return .{
            .context = context,
            .object_tag_idx = object_tag_idx,
            .closing_tag_idx = closing_tag_idx,
            .id_slice = object_id,
            .type_slice = object_type,
        };
    }

    pub inline fn id(self: CimObject) []const u8 {
        return self.id_slice;
    }

    pub inline fn type_name(self: CimObject) []const u8 {
        return self.type_slice;
    }

    pub inline fn raw_xml(self: CimObject) []const u8 {
        return self.element_view().raw_xml();
    }

    pub inline fn xml_offset(self: CimObject) u32 {
        return self.element_view().xml_offset();
    }

    pub inline fn property(self: CimObject, property_name: []const u8) ?[]const u8 {
        return self.element_view().property(property_name);
    }

    pub inline fn reference(self: CimObject, property_name: []const u8) error{MalformedTag}!?[]const u8 {
        return self.element_view().reference(property_name);
    }

    /// The key SSH/TP overlays use to patch this object: explicit
    /// IdentifiedObject.mRID, else the local RDF identifier with its leading
    /// hash and underscore stripped. Single source of truth for overlay keying.
    pub fn mrid(self: CimObject) error{MalformedTag}![]const u8 {
        return parse.non_blank(self.property("IdentifiedObject.mRID")) orelse
            ids.strip_underscore(ids.strip_hash(self.id()));
    }

    pub inline fn children(self: CimObject) ChildIterator {
        return self.element_view().children();
    }

    pub inline fn properties(self: CimObject, comptime names: anytype) error{MalformedTag}![names.len]?[]const u8 {
        return self.element_view().properties(names);
    }

    pub inline fn references(self: CimObject, comptime names: anytype) error{MalformedTag}![names.len]?[]const u8 {
        return self.element_view().references(names);
    }

    pub inline fn all_properties(self: CimObject, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
        return self.element_view().all_properties(gpa);
    }

    pub inline fn all_references(self: CimObject, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
        return self.element_view().all_references(gpa);
    }

    inline fn element_view(self: CimObject) ElementView {
        return .{
            .xml = self.context.xml,
            .boundaries = self.context.boundaries,
            .object_tag_idx = self.object_tag_idx,
            .closing_tag_idx = self.closing_tag_idx,
        };
    }
};

comptime {
    const fields_size =
        @sizeOf(*const ObjectContext) +
        2 * @sizeOf(u32) +
        2 * @sizeOf([]const u8);
    assert(@sizeOf(CimObject) == std.mem.alignForward(
        usize,
        fields_size,
        @alignOf(CimObject),
    ));
}

/// Whether `value` is a subslice of `source`. The invariant behind storing
/// borrowed slices on an object: they stay valid exactly as long as the
/// document's `xml` does, and no longer.
fn within(source: []const u8, value: []const u8) bool {
    const source_address = @intFromPtr(source.ptr);
    const value_address = @intFromPtr(value.ptr);
    return value_address >= source_address and
        value_address + value.len <= source_address + source.len;
}

/// Internal bound element span. Overlay patches use the same child queries as
/// objects but are not themselves objects declared by the document.
pub const ElementView = struct {
    xml: []const u8,
    boundaries: []const TagBoundary,
    object_tag_idx: u32,
    closing_tag_idx: u32,

    /// The object's raw XML slice, from its opening '<' to its closing '>'
    /// (inclusive). Byte-equal slices are semantically equal objects, which
    /// diff uses as a fast path, and eqdiff emission copies child elements
    /// verbatim out of this region.
    pub fn raw_xml(self: ElementView) []const u8 {
        const start = self.boundaries[self.object_tag_idx].start;
        const end = self.boundaries[self.closing_tag_idx].end;
        assert(end > start);
        return self.xml[start .. end + 1];
    }

    /// Byte offset of the object's opening '<' in the document, for source
    /// positions in diagnostics and reports. Exposed so a caller that only wants
    /// "where is this object" does not have to index `boundaries` to get it.
    pub fn xml_offset(self: ElementView) u32 {
        return self.boundaries[self.object_tag_idx].start;
    }

    /// Get a text property value by name.
    pub fn property(self: ElementView, property_name: []const u8) ?[]const u8 {
        return get_property_from_indices(self.xml, self.boundaries, self.object_tag_idx, self.closing_tag_idx, property_name);
    }

    /// Get a reference (rdf:resource) value by name.
    pub fn reference(self: ElementView, property_name: []const u8) error{MalformedTag}!?[]const u8 {
        return get_reference_from_indices(self.xml, self.boundaries, self.object_tag_idx, self.closing_tag_idx, property_name);
    }

    /// Iterate this object's child elements in document order.
    pub fn children(self: ElementView) ChildIterator {
        return ChildIterator.init(self);
    }

    /// Batch-fetch multiple text properties in a single scan through child tags.
    pub fn properties(self: ElementView, comptime names: anytype) error{MalformedTag}![names.len]?[]const u8 {
        var result: [names.len]?[]const u8 = .{null} ** names.len;
        var found_count: usize = 0;

        var it = self.children();
        while (it.next()) |child| {
            inline for (names, 0..) |name, idx| {
                if (result[idx] == null and is_text_property(child, name)) {
                    result[idx] = child.value;
                    found_count += 1;
                    if (found_count == names.len) return result;
                }
            }
        }

        return result;
    }

    /// Batch-fetch multiple rdf:resource references in a single scan through child tags.
    pub fn references(self: ElementView, comptime names: anytype) error{MalformedTag}![names.len]?[]const u8 {
        var result: [names.len]?[]const u8 = .{null} ** names.len;
        var found_count: usize = 0;

        var it = self.children();
        while (it.next()) |child| {
            inline for (names, 0..) |name, idx| {
                if (result[idx] == null and std.mem.eql(u8, child.name, name)) {
                    // Same rule as get_reference_from_indices: a requested name
                    // with an unreadable rdf:resource must not read as absent.
                    if (child.malformed_resource) return error.MalformedTag;
                    if (child.kind == .reference) {
                        result[idx] = child.value;
                        found_count += 1;
                        if (found_count == names.len) return result;
                    }
                }
            }
        }

        return result;
    }

    /// Get all text properties (not references) as a HashMap.
    pub fn all_properties(self: ElementView, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var result = std.StringHashMap([]const u8).init(gpa);
        errdefer result.deinit();

        var it = self.children();
        while (it.next()) |child| {
            if (child.kind != .property or child.self_closing) continue;
            try result.put(child.name, child.value);
        }

        return result;
    }

    /// Get all rdf:resource references as a HashMap.
    pub fn all_references(self: ElementView, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var result = std.StringHashMap([]const u8).init(gpa);
        errdefer result.deinit();

        var it = self.children();
        while (it.next()) |child| {
            if (child.kind != .reference) continue;
            try result.put(child.name, child.value);
        }

        return result;
    }
};
