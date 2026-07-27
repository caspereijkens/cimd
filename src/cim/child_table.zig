//! ChildTable -- every object's children, interned and precomputed once.
//!
//! `ChildIterator` answers "what are this object's children" by parsing the XML
//! each time it is asked. That is the right trade for a consumer that asks once
//! per object: the parse and the walk cost the same, so a table would be pure
//! overhead. It is the wrong trade for SHACL validation, which walks the same
//! object once per shape -- 825 times on the reference rule set -- and compares
//! child names as strings while doing it.
//!
//! So this is an *opt-in* index, owned by the run that wants it, not part of
//! `CimDocument`. Building it on the 300 MB reference file costs 51 ms and
//! 66 MB; commands that read each child once (`types`, `refs`, `diff`) never
//! build it and pay nothing.
//!
//! It is built *through* `ChildIterator`, not alongside it. That is deliberate:
//! step 4a's whole point was one definition of "what is a child", and a table
//! with its own independently written skip rules would be the thirteenth
//! hand-written child walk wearing a different hat. Building through the
//! iterator makes agreement structural rather than something tests have to
//! chase -- `test_child_table.zig` still checks it, but as a regression guard,
//! not as the only thing holding the two in line.
//!
//! One known divergence from a boundary walk, and the reason the corpus check
//! matters: `ChildIterator` takes the boundary after an expanded child to be
//! that child's closing tag, because CIM properties do not nest. A walk over
//! raw boundaries would visit a nested grandchild; this table does not contain
//! one. No CGMES profile nests property elements, and the reference corpus
//! confirms it, but a document that did would validate differently.

const std = @import("std");
const CimDocument = @import("document.zig").CimDocument;

const assert = std.debug.assert;

pub const ChildTable = struct {
    /// Borrowed from the document, so the table stays valid exactly as long as
    /// the document does. Held so the span accessors need no second argument.
    xml: []const u8,

    /// One entry per child, contiguous per object, in `document.objects` order:
    /// interned name id in the low 31 bits, `KIND_BIT` set for a reference.
    ///
    /// Split from `spans` rather than packed into one 20-byte record because the
    /// hot scan reads *only* this array -- a value is extracted at most once per
    /// child and only when a constraint needs it. Struct-of-arrays streams 13 MB
    /// past the cache on the reference file where an array-of-structs streams 66.
    tags: []u32,
    /// Value spans for the same children, at the same indices.
    spans: []Span,
    /// `child_start[i] .. child_start[i + 1]` is object `i`'s children, so this
    /// has one more entry than the document has objects.
    child_start: []u32,

    /// id -> name, for report text.
    names: std.ArrayList([]const u8),
    map: std.StringHashMap(u32),

    /// Set in a `tags` entry when the child carries an `rdf:resource`. Follows
    /// the attribute, not the element syntax -- same rule as `Child.kind`.
    pub const KIND_BIT: u32 = 1 << 31;
    /// Mask selecting the interned name id out of a `tags` entry.
    pub const NAME_MASK: u32 = ~KIND_BIT;
    /// The id for a name this document never uses. Equal to `NAME_MASK`, which
    /// no real id can reach: one child needs at least `<a></a>`, so the id count
    /// is far below `xml.len`, and `io/read.zig` caps `xml.len` at `maxInt(u32)`.
    /// Asserted at build. This is what lets a rule set be mapped into the
    /// document's id space once and then compared with plain `==`.
    pub const absent: u32 = NAME_MASK;

    /// The child's value only. The design sketch also carried the raw element
    /// span, for a consumer that re-emits an element verbatim -- but the only
    /// such consumer is `eqdiff`, which reads `ChildIterator` and has no reason
    /// to build a table. Carrying it anyway cost 26 MB of measured peak on the
    /// reference file to serve nobody, so it is not here. Add it back with a
    /// consumer and a measurement, not in advance.
    pub const Span = struct {
        value_start: u32,
        value_end: u32,
    };

    /// One object's children as parallel slices.
    pub const Children = struct {
        tags: []const u32,
        spans: []const Span,
    };

    pub fn build(gpa: std.mem.Allocator, model: *const CimDocument) !ChildTable {
        const child_start = try gpa.alloc(u32, model.objects.len + 1);
        errdefer gpa.free(child_start);

        var tags: std.ArrayList(u32) = .empty;
        errdefer tags.deinit(gpa);
        var spans: std.ArrayList(Span) = .empty;
        errdefer spans.deinit(gpa);
        // Every child occupies at least one boundary, and an expanded child two.
        // A hint only; the appends below still grow if a document is all
        // self-closing children.
        try tags.ensureTotalCapacity(gpa, model.boundaries.len / 2);
        try spans.ensureTotalCapacity(gpa, model.boundaries.len / 2);

        var names: std.ArrayList([]const u8) = .empty;
        errdefer names.deinit(gpa);
        var map = std.StringHashMap(u32).init(gpa);
        errdefer map.deinit();

        const xml = model.xml;
        for (model.objects, 0..) |obj, i| {
            child_start[i] = @intCast(tags.items.len);
            var it = obj.children();
            while (it.next()) |child| {
                const gop = try map.getOrPut(child.name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(names.items.len);
                    try names.append(gpa, child.name);
                }
                var tag = gop.value_ptr.*;
                if (child.kind == .reference) tag |= KIND_BIT;

                const value_start = value_offset(xml, child.value);
                try tags.append(gpa, tag);
                try spans.append(gpa, .{
                    .value_start = value_start,
                    .value_end = value_start + @as(u32, @intCast(child.value.len)),
                });
            }
        }
        child_start[model.objects.len] = @intCast(tags.items.len);

        assert(names.items.len == map.count());
        // Pairs with `absent`: a real id must never reach the sentinel.
        assert(names.items.len < absent);
        assert(tags.items.len == spans.items.len);

        // Taken one at a time, with their own errdefer: `toOwnedSlice` empties the
        // list on success, so once `tags` has handed over its buffer the
        // list-level errdefer above can no longer free it, and a failure in the
        // second transfer would leak the first.
        const owned_tags = try tags.toOwnedSlice(gpa);
        errdefer gpa.free(owned_tags);
        const owned_spans = try spans.toOwnedSlice(gpa);

        return .{
            .xml = xml,
            .tags = owned_tags,
            .spans = owned_spans,
            .child_start = child_start,
            .names = names,
            .map = map,
        };
    }

    pub fn deinit(self: *ChildTable, gpa: std.mem.Allocator) void {
        gpa.free(self.tags);
        gpa.free(self.spans);
        gpa.free(self.child_start);
        self.names.deinit(gpa);
        self.map.deinit();
    }

    /// Map a name into this document's id space. `absent` for a name the
    /// document never uses, which compares equal to no child.
    pub fn id_of(self: *const ChildTable, name: []const u8) u32 {
        return self.map.get(name) orelse absent;
    }

    pub fn name_of(self: *const ChildTable, id: u32) []const u8 {
        assert(id < self.names.items.len);
        return self.names.items[id];
    }

    pub fn children_of(self: *const ChildTable, object_index: u32) Children {
        assert(object_index + 1 < self.child_start.len);
        const start = self.child_start[object_index];
        const end = self.child_start[object_index + 1];
        // Children are laid out in object order, so a range can only run forward.
        assert(end >= start);
        return .{ .tags = self.tags[start..end], .spans = self.spans[start..end] };
    }

    pub fn value_of(self: *const ChildTable, span: Span) []const u8 {
        return self.xml[span.value_start..span.value_end];
    }

    pub inline fn name_id(tag: u32) u32 {
        return tag & NAME_MASK;
    }

    pub inline fn is_reference(tag: u32) bool {
        return tag & KIND_BIT != 0;
    }
};

/// Byte offset of a slice that borrows from `xml`. Every `Child` field does, by
/// construction -- the iterator only ever slices the document buffer.
fn offset_in(xml: []const u8, slice: []const u8) u32 {
    assert(@intFromPtr(slice.ptr) >= @intFromPtr(xml.ptr));
    const offset = @intFromPtr(slice.ptr) - @intFromPtr(xml.ptr);
    assert(offset + slice.len <= xml.len);
    return @intCast(offset);
}

/// `offset_in` for a child's value, which has one case that does not borrow:
/// `ChildIterator` reports an empty literal as the `""` constant rather than a
/// zero-length slice of the document, and that pointer is not in `xml` at all.
/// Both spellings read back as an empty slice, which is all any consumer of an
/// empty value can ask.
fn value_offset(xml: []const u8, value: []const u8) u32 {
    if (value.len == 0) return 0;
    return offset_in(xml, value);
}
