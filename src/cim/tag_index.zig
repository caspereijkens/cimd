//! CIM objects and their children: what a parsed document is made of.
//!
//! One layer above `xml_scan.zig`, which finds tags in bytes and knows nothing
//! else. Here a tag becomes an object with an id and a type, and the tags
//! between its opener and its closer become children with names, values and a
//! property/reference distinction. `ChildIterator` is the single definition of
//! "what is a child" -- there were twelve, and five of them were wrong about
//! XML comments.
//!
//! A consumer that has a CIM document wants this file's types and never
//! `xml_scan`'s; the boundary array below is a construction detail that
//! `CimDocument` supplies and callers pass through.

const std = @import("std");
const ids = @import("ids.zig");
const parse = @import("parse.zig");
const xml_scan = @import("xml_scan.zig");
const assert = std.debug.assert;

// The scanning primitives this layer is built out of. Aliased rather than
// re-exported: a caller that wants raw scanning should say so by importing
// `xml_scan`, which is the whole point of the two files being two files.
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
) error{MalformedTag}!?[]const u8 {
    assert(property_name.len > 0);

    var it = ChildIterator.init_range(xml, boundaries, opening_tag_idx, closing_tag_idx);
    while (it.next()) |child| {
        if (is_text_property(child, property_name)) return child.value;
    }
    return null;
}

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
    /// asked for this name by name fail loudly instead: topology resolution
    /// reports a malformed reference rather than silently building the wrong
    /// network from a truncated export.
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
/// Skips comments, processing instructions and tags whose name will not parse,
/// matching the tolerance the previous walks had: a malformed child is not a
/// reason to fail a whole query.
pub const ChildIterator = struct {
    xml: []const u8,
    boundaries: []const TagBoundary,
    next_idx: u32,
    end_idx: u32,

    /// Iterate the children of a bound object.
    pub fn init(view: CimObjectView) ChildIterator {
        return init_range(view.xml, view.boundaries, view.object_tag_idx, view.closing_tag_idx);
    }

    /// Iterate the children of an element identified by its opening and closing
    /// boundary indices. For callers that hold a span but no view -- the SSH/TP
    /// overlay patches, which are elements inside a document they do not own.
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
            const parsed = extract_tag_type_terminated(self.xml, tag.start) catch continue;
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

/// Represents a CIM object with lazy property access
/// Compact CIM object -- indices and identity only, no embedded XML context.
/// Cheap to copy and store. Use CimObjectView (via CimDocument.view) to access properties.
pub const CimObject = struct {
    object_tag_idx: u32,
    closing_tag_idx: u32,
    id: []const u8,
    type_name: []const u8,

    /// xml and boundaries are needed only to extract type_name; they are not stored.
    pub fn init(
        xml: []const u8,
        boundaries: []const TagBoundary,
        object_tag_idx: u32,
        closing_tag_idx: u32,
        id: []const u8,
    ) error{MalformedTag}!CimObject {
        assert(id.len > 0);
        return .{
            .object_tag_idx = object_tag_idx,
            .closing_tag_idx = closing_tag_idx,
            .id = id,
            .type_name = try extract_tag_type(xml, boundaries[object_tag_idx].start),
        };
    }
};

/// Ephemeral view binding a CimObject to its XML context.
/// Create via CimDocument.view(obj). Stack-allocated; do not store in arrays.
pub const CimObjectView = struct {
    xml: []const u8,
    boundaries: []const TagBoundary,
    object_tag_idx: u32,
    closing_tag_idx: u32,
    id: []const u8,
    type_name: []const u8,

    /// The object's raw XML slice, from its opening '<' to its closing '>'
    /// (inclusive). Byte-equal slices are semantically equal objects, which
    /// diff uses as a fast path, and eqdiff emission copies child elements
    /// verbatim out of this region.
    pub fn raw_xml(self: CimObjectView) []const u8 {
        const start = self.boundaries[self.object_tag_idx].start;
        const end = self.boundaries[self.closing_tag_idx].end;
        assert(end > start);
        return self.xml[start .. end + 1];
    }

    /// Byte offset of the object's opening '<' in the document, for source
    /// positions in diagnostics and reports. Exposed so a caller that only wants
    /// "where is this object" does not have to index `boundaries` to get it.
    pub fn xml_offset(self: CimObjectView) u32 {
        return self.boundaries[self.object_tag_idx].start;
    }

    /// Get a text property value by name.
    pub fn getProperty(self: CimObjectView, property_name: []const u8) error{MalformedTag}!?[]const u8 {
        return get_property_from_indices(self.xml, self.boundaries, self.object_tag_idx, self.closing_tag_idx, property_name);
    }

    /// Get a reference (rdf:resource) value by name.
    pub fn getReference(self: CimObjectView, property_name: []const u8) error{MalformedTag}!?[]const u8 {
        return get_reference_from_indices(self.xml, self.boundaries, self.object_tag_idx, self.closing_tag_idx, property_name);
    }

    /// The key SSH/TP overlays use to patch this object: explicit
    /// IdentifiedObject.mRID, else the local RDF identifier with its leading
    /// hash and underscore stripped. Single source of truth for overlay keying.
    pub fn mrid(self: CimObjectView) error{MalformedTag}![]const u8 {
        return parse.non_blank(try self.getProperty("IdentifiedObject.mRID")) orelse ids.strip_underscore(ids.strip_hash(self.id));
    }

    /// Iterate this object's child elements in document order.
    pub fn children(self: CimObjectView) ChildIterator {
        return ChildIterator.init(self);
    }

    /// Batch-fetch multiple text properties in a single scan through child tags.
    pub fn getProperties(self: CimObjectView, comptime names: anytype) error{MalformedTag}![names.len]?[]const u8 {
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
    pub fn getReferences(self: CimObjectView, comptime names: anytype) error{MalformedTag}![names.len]?[]const u8 {
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
    pub fn getAllProperties(self: CimObjectView, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
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
    pub fn getAllReferences(self: CimObjectView, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
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
