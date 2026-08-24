//! Raw XML and RDF/XML scanning: the layer under `CimDocument`, and the only
//! part of this library that does not know what a CIM object is.
//!
//! It is a separate module because it has two separate kinds of consumer, and
//! conflating them is what kept the boundary array in the library's public
//! contract. A CIM consumer wants objects and their children and should never
//! import this file: `CimDocument`, `CimObject` and `object.children()`
//! answer everything it needs. What is left are the callers that genuinely
//! scan XML this library does not model -- `gen_cim_types.zig` reads RDFS
//! schema files, `cgmes/profile.zig` reads a FullModel header before there is a
//! document to speak of, `browse.zig` slices raw source text for display, and
//! `validate.zig` counts newlines for report line numbers. For them a tag
//! boundary is the right level, and a child table would be both wrong and
//! slower.
//!
//! So the split is not "internal versus external" -- both halves are exported.
//! It is "does this operation involve a CIM object", and the answer here is
//! always no. Everything below takes bytes and offsets and returns bytes and
//! offsets.

const std = @import("std");
const assert = std.debug.assert;

/// Vector size for SIMD operations (32 bytes = 256-bit AVX2)
/// Falls back to smaller sizes on older CPUs
pub const VECTOR_LEN = if (std.simd.suggestVectorLength(u8)) |size|
    @min(size, 32)
else
    32;

const Chunk = @Vector(VECTOR_LEN, u8);
const Mask = std.meta.Int(.unsigned, VECTOR_LEN);

/// Find all positions of a specific byte in the input using SIMD
/// Returns an ArrayList of positions where the byte was found
pub fn find_byte_simd(
    gpa: std.mem.Allocator,
    haystack: []const u8,
    needle: u8,
) !std.ArrayList(u32) {
    // Catch u32 overflow early (returns error if file size > 4.2GB)
    if (haystack.len > std.math.maxInt(u32)) return error.FileTooLarge;

    var result: std.ArrayList(u32) = .empty;
    errdefer result.deinit(gpa);

    if (haystack.len == 0) return result;

    // Pre-allocate for sparse matches (estimated 5-10% density in XML)
    const estimated_matches = @max(@divFloor(haystack.len, 10), 16);
    try result.ensureTotalCapacity(gpa, estimated_matches);

    const all_needles: Chunk = @splat(needle);
    var i: usize = 0;

    // Process 4 vectors per iteration
    // Better instruction pipelining, reduces loop overhead by 4x
    const unroll_factor = 4;
    const unroll_size = VECTOR_LEN * unroll_factor;

    while (i + unroll_size <= haystack.len) : (i += unroll_size) {
        // Worst case: every byte in the block matches -- reserve before entering.
        try result.ensureUnusedCapacity(gpa, unroll_size);
        inline for (0..unroll_factor) |j| {
            const offset = i + j * VECTOR_LEN;
            const chunk: Chunk = haystack[offset..][0..VECTOR_LEN].*;
            const matches: @Vector(VECTOR_LEN, bool) = chunk == all_needles;
            const mask: Mask = @bitCast(matches);

            var m = mask;
            while (m != 0) {
                const bit_pos = @ctz(m);
                result.appendAssumeCapacity(@intCast(offset + bit_pos));
                m &= m - 1;
            }
        }
    }

    // Handle remaining full vectors
    while (i + VECTOR_LEN <= haystack.len) : (i += VECTOR_LEN) {
        try result.ensureUnusedCapacity(gpa, VECTOR_LEN);
        const chunk: Chunk = haystack[i..][0..VECTOR_LEN].*;
        const matches: @Vector(VECTOR_LEN, bool) = chunk == all_needles;
        const mask: Mask = @bitCast(matches);

        var m = mask;
        while (m != 0) {
            const bit_pos = @ctz(m);
            result.appendAssumeCapacity(@intCast(i + bit_pos));
            m &= m - 1;
        }
    }

    // Handle remainder - scalar fallback
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == needle) {
            try result.ensureUnusedCapacity(gpa, 1);
            result.appendAssumeCapacity(@intCast(i));
        }
    }

    return result;
}

/// Result of finding a pattern match
pub const PatternMatch = struct {
    /// Position where the pattern starts (the 'r' in "rdf:")
    pattern_start: u32,
    /// Position where the value starts (after the opening quote)
    value_start: u32,
    /// Length of the value (excluding quotes)
    value_len: u32,
};

/// Find `needle` in `haystack`, anchored on its first byte.
///
/// `std.mem.indexOf` dispatches to Boyer-Moore-Horspool once the haystack
/// exceeds 52 bytes, and builds a 256-entry skip table *per call*. An XML tag
/// is around 80 bytes, so every attribute lookup paid for a table it then used
/// for a handful of comparisons: 69 ns against 9.6 ns for this scan, measured
/// on one 78-byte tag. Anchoring on the needle's first byte keeps the inner
/// `eql` rare, since every pattern here starts with the 'r' of "rdf:".
///
/// The needle is comptime so the length is known at the compare.
pub fn find_needle_anchored(haystack: []const u8, comptime needle: []const u8) ?usize {
    comptime assert(needle.len > 0);
    if (haystack.len < needle.len) return null;

    // Only positions where the whole needle still fits are candidates.
    const limit = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= limit) {
        const hit = std.mem.indexOfScalarPos(u8, haystack[0 .. limit + 1], i, needle[0]) orelse
            return null;
        if (std.mem.eql(u8, haystack[hit..][0..needle.len], needle)) return hit;
        i = hit + 1;
    }
    return null;
}

/// First byte at or after `start` that belongs to `set`, via a comptime lookup
/// table. `std.mem.indexOfAnyPos` is a scalar loop over the needle set, so it
/// costs one compare per (byte x set member); this costs one load per byte.
pub fn index_of_any_pos_table(haystack: []const u8, start: usize, comptime set: []const u8) ?usize {
    const table = comptime blk: {
        var t = [_]bool{false} ** 256;
        for (set) |c| t[c] = true;
        break :blk t;
    };
    var i: usize = start;
    while (i < haystack.len) : (i += 1) {
        if (table[haystack[i]]) return i;
    }
    return null;
}

/// `index_of_any_pos_table`, vectorized: one compare per (vector x set member)
/// instead of one load per byte, with the table version handling the tail.
///
/// Worth the machinery because the tag-name terminator scan is on the hottest
/// path there is -- once per child element, for every consumer, now that the
/// single child walk classifies each child as it goes. A tag name is ~20 bytes,
/// so the whole scan usually resolves in the first chunk.
pub fn index_of_any_pos_simd(haystack: []const u8, start: usize, comptime set: []const u8) ?usize {
    comptime assert(set.len > 0);

    const splats = comptime blk: {
        var s: [set.len]Chunk = undefined;
        for (set, 0..) |c, j| s[j] = @splat(c);
        break :blk s;
    };

    var i: usize = start;
    while (i + VECTOR_LEN <= haystack.len) : (i += VECTOR_LEN) {
        const chunk: Chunk = haystack[i..][0..VECTOR_LEN].*;
        var mask: Mask = 0;
        inline for (splats) |splat| {
            const eq: @Vector(VECTOR_LEN, bool) = chunk == splat;
            mask |= @as(Mask, @bitCast(eq));
        }
        // Lowest set bit is the earliest matching byte in the chunk, so the
        // first hit found is the first hit overall.
        if (mask != 0) return i + @ctz(mask);
    }
    return index_of_any_pos_table(haystack, i, set);
}

/// Positions of the first two bytes from `set` at or after `start`, in one pass.
/// `second` is null when the haystack ends after the first hit.
///
/// This exists for `extract_tag_type_terminated`, which needs both the prefix
/// colon and the name terminator. Those are the first two members of the same
/// set, and in a qualified tag name they almost always land in the same 32-byte
/// chunk -- `<cim:ACLineSegment.r ` resolves entirely inside chunk one. Calling
/// `index_of_any_pos_simd` twice reloads those bytes and pays the per-member
/// compares a second time, on what profiling puts at the hottest line in the
/// scanner. Finding both from one load halves that.
pub fn first_two_of_any_pos_simd(
    haystack: []const u8,
    start: usize,
    comptime set: []const u8,
) ?struct { first: usize, second: ?usize } {
    comptime assert(set.len > 0);
    assert(start <= haystack.len);

    const splats = comptime blk: {
        var sp: [set.len]Chunk = undefined;
        for (set, 0..) |c, j| sp[j] = @splat(c);
        break :blk sp;
    };

    var first: ?usize = null;
    var i: usize = start;
    while (i + VECTOR_LEN <= haystack.len) : (i += VECTOR_LEN) {
        const chunk: Chunk = haystack[i..][0..VECTOR_LEN].*;
        var mask: Mask = 0;
        inline for (splats) |splat| {
            const eq: @Vector(VECTOR_LEN, bool) = chunk == splat;
            mask |= @as(Mask, @bitCast(eq));
        }
        // Walk the set bits low to high: they are in ascending byte order, so
        // the first two encountered are the first two hits overall. The common
        // case leaves this loop on its second iteration, having never issued a
        // second load.
        while (mask != 0) : (mask &= mask - 1) {
            const pos = i + @ctz(mask);
            if (first) |f| return .{ .first = f, .second = pos };
            first = pos;
        }
    }

    // Tail: fewer than VECTOR_LEN bytes left, so scan them a byte at a time.
    while (index_of_any_pos_table(haystack, i, set)) |pos| {
        if (first) |f| return .{ .first = f, .second = pos };
        first = pos;
        i = pos + 1;
    }

    if (first) |f| return .{ .first = f, .second = null };
    return null;
}

/// Verify needle at position and extract quoted value if match found
/// Returns PatternMatch if pattern matches and closing quote is found, null otherwise
pub fn verify_and_extract_pattern(
    haystack: []const u8,
    candidate_pos: usize,
    needle: []const u8,
) ?PatternMatch {
    // Check bounds for pattern
    if (candidate_pos + needle.len > haystack.len) return null;

    // Verify full pattern matches
    if (!std.mem.eql(u8, haystack[candidate_pos..][0..needle.len], needle)) {
        return null;
    }

    // Find closing quote for value
    const value_start = candidate_pos + needle.len;
    const closing_quote_offset = std.mem.indexOfScalarPos(u8, haystack, value_start, '"') orelse return null;
    assert(closing_quote_offset >= value_start);
    const value_len = closing_quote_offset - value_start;

    return .{
        .pattern_start = @intCast(candidate_pos),
        .value_start = @intCast(value_start),
        .value_len = @intCast(value_len),
    };
}

/// Find all occurrences of a pattern followed by a quoted value
/// Pattern example: "rdf:ID=\"" (8 bytes)
/// Returns matches with position and extracted value location
pub fn find_pattern(
    gpa: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
) !std.ArrayList(PatternMatch) {
    assert(needle.len > 0);

    var result: std.ArrayList(PatternMatch) = .empty;
    errdefer result.deinit(gpa);

    if (haystack.len == 0 or needle.len > haystack.len) return result;

    const estimated_matches = @max(@divFloor(haystack.len, 1000), 16);
    try result.ensureTotalCapacity(gpa, estimated_matches);

    const first_byte = needle[0];
    const all_first_bytes: Chunk = @splat(first_byte);

    var i: usize = 0;

    const unroll_factor = 4;
    const unroll_size = VECTOR_LEN * unroll_factor;

    // Process 4 vectors per iteration
    while (i + unroll_size <= haystack.len) : (i += unroll_size) {
        // Worst case: every byte in the block is the pattern's first byte.
        try result.ensureUnusedCapacity(gpa, unroll_size);
        inline for (0..unroll_factor) |j| {
            const offset = i + j * VECTOR_LEN;
            const chunk: Chunk = haystack[offset..][0..VECTOR_LEN].*;
            const matches: @Vector(VECTOR_LEN, bool) = chunk == all_first_bytes;
            const mask: Mask = @bitCast(matches);

            var m = mask;
            while (m != 0) {
                const bit_pos = @ctz(m);
                const candidate_pos = offset + bit_pos;

                if (verify_and_extract_pattern(haystack, candidate_pos, needle)) |match| {
                    result.appendAssumeCapacity(match);
                }

                m &= m - 1;
            }
        }
    }

    // Remaining full vectors
    while (i + VECTOR_LEN <= haystack.len) : (i += VECTOR_LEN) {
        try result.ensureUnusedCapacity(gpa, VECTOR_LEN);
        const chunk: Chunk = haystack[i..][0..VECTOR_LEN].*;
        const matches: @Vector(VECTOR_LEN, bool) = chunk == all_first_bytes;
        const mask: Mask = @bitCast(matches);

        var m = mask;
        while (m != 0) {
            const bit_pos = @ctz(m);
            const candidate_pos = i + bit_pos;

            if (verify_and_extract_pattern(haystack, candidate_pos, needle)) |match| {
                result.appendAssumeCapacity(match);
            }

            m &= m - 1;
        }
    }

    // Scalar remainder
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == first_byte) {
            if (verify_and_extract_pattern(haystack, i, needle)) |match| {
                try result.ensureUnusedCapacity(gpa, 1);
                result.appendAssumeCapacity(match);
            }
        }
    }

    return result;
}

/// Represents the boundaries of a single XML tag
pub const TagBoundary = struct {
    /// Position of '<' character
    start: u32,
    /// Position of '>' character
    end: u32,
};

/// Why a document failed to scan. The offset alone says where to look; this
/// says what to look for, and the two are only useful together -- "a '<' inside
/// a tag" at line 40 is actionable in a way that "something is wrong" at line 40
/// is not.
pub const MalformedReason = enum {
    unclosed_tag,
    nested_tag_open,
    unterminated_section,
    closing_tag_self_closed,
    unreadable_tag_name,
    unexpected_closing_tag,
    mismatched_closing_tag,
    unclosed_element,

    /// Completes the sentence "malformed XML at line N: ...".
    pub fn describe(self: MalformedReason) []const u8 {
        return switch (self) {
            .unclosed_tag => "a tag is opened with '<' but never closed with '>'",
            .nested_tag_open => "'<' appears inside a tag; write it as &lt; in text",
            .unterminated_section => "a comment, CDATA section or DOCTYPE is never closed",
            .closing_tag_self_closed => "a closing tag cannot also be self-closing",
            .unreadable_tag_name => "a tag name is missing or not a valid XML qualified name",
            .unexpected_closing_tag => "a closing tag appears with no element open",
            .mismatched_closing_tag => "a closing tag does not match the element it closes",
            .unclosed_element => "an element is opened but never closed",
        };
    }
};

/// Where a scan failed and why. Populated only when the scan returns
/// `error.MalformedXML`.
pub const MalformedXML = struct {
    offset: u32 = 0,
    reason: MalformedReason = .unclosed_element,
};

fn malformed_xml(
    info: *MalformedXML,
    offset: u32,
    reason: MalformedReason,
    xml_len: usize,
) error{MalformedXML} {
    assert(offset <= xml_len);
    info.* = .{ .offset = offset, .reason = reason };
    return error.MalformedXML;
}

const MarkupSection = union(enum) {
    /// `<!` did not open a section this scanner spans; treat it as a plain tag.
    none,
    /// A section was opened but never closed.
    unterminated,
    /// Index of the '>' that closes the section.
    ends_at: u32,
};

/// End of a `<!...>` markup section starting at `lt`.
///
/// These have to be recognised as a whole because a '<' inside one is character
/// data, not the start of a tag. An internal DTD subset holds them by
/// construction -- `<!DOCTYPE rdf:RDF [<!ENTITY name "Station">]>` has two '<'
/// and two '>' interleaved -- and so can a CDATA section. Pairing those
/// naively yields boundaries that start inside their predecessor, which every
/// consumer's slicing assumes cannot happen; spanning the section keeps that
/// invariant without rejecting a well-formed document.
///
/// The subset scan tracks `[` / `]` rather than parsing declarations, so a ']'
/// inside a quoted entity value would end it early. That form does not occur in
/// CGMES, and getting it wrong yields a diagnostic, not a bad parse.
fn markup_section_end(xml: []const u8, lt: u32) MarkupSection {
    assert(xml.len <= std.math.maxInt(u32));
    assert(lt < xml.len);
    assert(xml[lt] == '<');

    const rest = xml[lt..];

    if (std.mem.startsWith(u8, rest, "<!--")) {
        const at = std.mem.indexOfPos(u8, xml, lt + 4, "-->") orelse return .unterminated;
        return .{ .ends_at = @intCast(at + 2) };
    }

    if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
        const at = std.mem.indexOfPos(u8, xml, lt + 9, "]]>") orelse return .unterminated;
        return .{ .ends_at = @intCast(at + 2) };
    }

    if (std.mem.startsWith(u8, rest, "<!DOCTYPE")) {
        var i: u32 = lt + 9;
        var in_subset = false;
        while (i < xml.len) : (i += 1) {
            switch (xml[i]) {
                '[' => in_subset = true,
                ']' => in_subset = false,
                '>' => if (!in_subset) return .{ .ends_at = i },
                else => {},
            }
        }
        return .unterminated;
    }

    return .none;
}

/// Find all XML tag boundaries by pairing '<' and '>' characters.
///
/// One SIMD pass indexes every '<'; each tag's '>' is then found by scanning
/// forward from its own '<'. Indexing '>' as well and zipping the two lists
/// gives the same answer for a cost the second index does not earn: a whole
/// second pass over the file plus a u32 per '>' -- 28MB of it on a 300MB
/// document -- to order delimiters that scanning forward orders for free.
///
/// Stray '>' in text content (legal per the XML spec -- only '<' and '&' must
/// be escaped in character data) fall out with no code at all: they sit before
/// the next '<', and nothing looks backwards.
///
/// Markup sections (`<!-- -->`, `<![CDATA[ ]]>`, `<!DOCTYPE ... [ ... ]>`) hold
/// delimiters that are data rather than markup, so each is emitted as a single
/// boundary spanning the whole section -- see `markup_section_end`.
///
/// Returns ArrayList of TagBoundary in document order.
pub fn find_tag_boundaries(
    gpa: std.mem.Allocator,
    xml: []const u8,
) !std.ArrayList(TagBoundary) {
    var error_offset: MalformedXML = .{};
    return find_tag_boundariesWithErrorOffset(gpa, xml, &error_offset);
}

/// The diagnostic variant records the byte that made the scan fail. The
/// caller only reads `error_offset` when this returns error.MalformedXML.
pub fn find_tag_boundariesWithErrorOffset(
    gpa: std.mem.Allocator,
    xml: []const u8,
    error_offset: *MalformedXML,
) !std.ArrayList(TagBoundary) {
    var result: std.ArrayList(TagBoundary) = .empty;
    errdefer result.deinit(gpa);

    if (xml.len == 0) return result;

    var lt_positions = try find_byte_simd(gpa, xml, '<');
    defer lt_positions.deinit(gpa);
    const lts = lt_positions.items;

    if (lts.len == 0) return result;

    // Upper bound: every '<' opens a tag. Markup sections only reduce this.
    try result.ensureTotalCapacity(gpa, lts.len);

    var lt_idx: usize = 0;
    while (lt_idx < lts.len) {
        const lt = lts[lt_idx];

        // Fast path: most '<' open a normal element. One byte-compare guards
        // the markup-section branch; the compiler keeps this in a single
        // predictable branch since '!' is rare immediately after '<'.
        const section: MarkupSection = if (lt + 1 < xml.len and xml[lt + 1] == '!')
            markup_section_end(xml, lt)
        else
            .none;

        if (section == .none) {
            // A tag is short, so this lands in the first chunk or two. Starting
            // from `lt` is also what makes a stray '>' in earlier text content a
            // non-issue: it is behind us and never considered.
            const gt: u32 = @intCast(std.mem.indexOfScalarPos(u8, xml, lt + 1, '>') orelse
                return malformed_xml(error_offset, lt, .unclosed_tag, xml.len));
            // '<' is never legal inside a tag. Left alone it gets paired with a
            // later '>' into a boundary that *starts inside this one*, and every
            // consumer slices between adjacent boundaries assuming they do not
            // overlap -- `ChildIterator` reads `xml[tag.end + 1 .. closing.start]`,
            // which panics when they do. A markup section skips the '<' inside
            // its span, because there the '<' is legal; here it is not, so it is
            // reported rather than dropped. The offset names the inner '<',
            // which is the byte to fix.
            if (lt_idx + 1 < lts.len and lts[lt_idx + 1] < gt) {
                return malformed_xml(error_offset, lts[lt_idx + 1], .nested_tag_open, xml.len);
            }
            result.appendAssumeCapacity(.{ .start = lt, .end = gt });
            lt_idx += 1;
            continue;
        }

        // A markup section is emitted as one boundary spanning the whole thing.
        // Its interior '<' are data, so the cursor skips past them -- that is
        // what keeps the section from splitting into boundaries that overlap the
        // ones around it.
        const close_gt = switch (section) {
            .none => unreachable,
            .unterminated => return malformed_xml(error_offset, lt, .unterminated_section, xml.len),
            .ends_at => |end| end,
        };

        result.appendAssumeCapacity(.{ .start = lt, .end = close_gt });
        lt_idx += 1;
        while (lt_idx < lts.len and lts[lt_idx] < close_gt) : (lt_idx += 1) {}
    }

    // Postcondition: boundaries are disjoint and strictly ordered. Everything
    // downstream slices between adjacent boundaries on that assumption, so a
    // regression here surfaces as an out-of-range slice panic several layers
    // away rather than as anything diagnosable. Catch it at the source.
    if (result.items.len > 0) {
        for (result.items[1..], 1..) |t, i| {
            assert(t.start > result.items[i - 1].end);
        }
    }

    return result;
}

/// Extract an element's local name, stripping its namespace prefix when present.
/// Examples:
///   "<cim:Substation rdf:ID="_SS1">" → "Substation"
///   "<Substation rdf:ID="_SS1">"     → "Substation"
/// Tag-name terminator set includes all XML whitespace (space, tab, CR, LF)
/// plus '>' and '/', so multi-line opening tags like `<rdf:RDF\n  xmlns=...>`
/// and attribute-less self-closing tags like `<cim:X/>` are handled
/// correctly. The scans stop at the first whitespace or tag end, so callers
/// may pass the complete XML: neither an attribute colon nor a prefix in a
/// later tag can affect the result. Comments, CDATA and processing instructions
/// are not elements and return `error.MalformedTag`.
pub fn extract_tag_type(slice: []const u8, start_idx: u32) error{MalformedTag}![]const u8 {
    return (try extract_tag_type_terminated(slice, start_idx)).name;
}

/// `extract_tag_type`, plus the qualified name and the byte that ended it.
///
/// `qname` is the name exactly as written, prefix included -- "cim:Substation"
/// where `name` is "Substation". CIM typing wants the local name, because a
/// document is free to bind the CIM namespace to any prefix or to no prefix at
/// all; XML *nesting* wants the qualified one, because an end tag must repeat
/// its opener's name verbatim. Matching on `name` alone would balance
/// `<cim:Substation></Substation>`, which is not well-formed XML.
///
/// The terminator answers
/// "can this element carry attributes at all" for free: '>' or '/' means the name
/// ran straight into the end of the tag, so there is no room for an
/// `rdf:resource`. `ChildIterator` uses that to skip the attribute scan on the
/// ordinary `<cim:X.y>text</cim:X.y>` child, which is most of a CIM document --
/// without it, classifying every child eagerly costs a second pass over each
/// tag and shows up as a ~8% regression on `refs`.
pub fn extract_tag_type_terminated(
    slice: []const u8,
    start_idx: u32,
) error{MalformedTag}!struct { name: []const u8, qname: []const u8, terminator: u8 } {
    assert(slice.len <= std.math.maxInt(u32));

    var name_start: u32 = start_idx;
    if (name_start >= slice.len) return error.MalformedTag;
    if (slice[name_start] == '<') name_start += 1;
    if (name_start >= slice.len) return error.MalformedTag;
    if (slice[name_start] == '/') name_start += 1;
    if (name_start >= slice.len) return error.MalformedTag;

    if (slice[name_start] == '!' or slice[name_start] == '?') return error.MalformedTag;

    // The colon is in the terminator set so that one sweep locates both the
    // prefix separator and the end of the name. An unprefixed name stops at its
    // terminator and never needs `second`.
    const terminators = ": \t\r\n>/";
    const hits = first_two_of_any_pos_simd(slice, name_start, terminators) orelse
        return error.MalformedTag;

    const prefix_end: u32 = @intCast(hits.first);
    if (prefix_end == name_start) return error.MalformedTag;
    assert(prefix_end > name_start);
    assert(prefix_end < slice.len);

    if (slice[prefix_end] != ':') {
        return .{
            .name = slice[name_start..prefix_end],
            .qname = slice[name_start..prefix_end],
            .terminator = slice[prefix_end],
        };
    }

    const local_start = prefix_end + 1;
    const end_idx: u32 = @intCast(hits.second orelse return error.MalformedTag);
    if (end_idx == local_start) return error.MalformedTag;
    // A second colon: `a:b:c` is not a QName.
    if (slice[end_idx] == ':') return error.MalformedTag;
    assert(end_idx > local_start);
    assert(end_idx < slice.len);

    return .{
        .name = slice[local_start..end_idx],
        .qname = slice[name_start..end_idx],
        .terminator = slice[end_idx],
    };
}

/// Extract rdf:ID value from an XML tag
/// Example: "<cim:Substation rdf:ID="_SS1">" → "_SS1"
/// Returns error.NoRdfId if tag doesn't have rdf:ID
/// Returns error.MalformedTag if rdf:ID exists but is malformed
pub fn extract_rdf_id(slice: []const u8, start_idx: u32) error{ NoRdfId, MalformedTag }![]const u8 {
    const gt_idx = std.mem.indexOfScalarPos(u8, slice, start_idx, '>') orelse return error.MalformedTag;

    const pattern = "rdf:ID=\"";

    const tag_content = slice[start_idx..gt_idx];
    const pattern_offset = find_needle_anchored(tag_content, pattern) orelse return error.NoRdfId;
    const pattern_start_idx = start_idx + pattern_offset;

    const value_start_idx = pattern_start_idx + pattern.len;
    const value_end_idx = std.mem.indexOfScalarPos(u8, slice, value_start_idx, '"') orelse return error.MalformedTag;

    // Check if closing quote is within this tag
    if (value_end_idx >= gt_idx) return error.MalformedTag;

    return slice[value_start_idx..value_end_idx];
}

/// Extract rdf:about value from an XML tag
/// Example: "<md:FullModel rdf:about="urn:uuid:...">" → "urn:uuid:..."
/// Returns error.NoRdfAbout if tag doesn't have rdf:about
/// Returns error.MalformedTag if rdf:about exists but is malformed
pub fn extract_rdf_about(slice: []const u8, start_idx: u32) error{ NoRdfAbout, MalformedTag }![]const u8 {
    const gt_idx = std.mem.indexOfScalarPos(u8, slice, start_idx, '>') orelse return error.MalformedTag;

    const pattern = "rdf:about=\"";

    const tag_content = slice[start_idx..gt_idx];
    const pattern_offset = find_needle_anchored(tag_content, pattern) orelse return error.NoRdfAbout;
    const pattern_start_idx = start_idx + pattern_offset;

    const value_start_idx = pattern_start_idx + pattern.len;
    const value_end_idx = std.mem.indexOfScalarPos(u8, slice, value_start_idx, '"') orelse return error.MalformedTag;

    // Check if closing quote is within this tag
    if (value_end_idx >= gt_idx) return error.MalformedTag;

    return slice[value_start_idx..value_end_idx];
}

/// Extract rdf:resource value from an XML tag whose '>' position is already
/// known (`end_idx`, the boundary's `.end`). Skips the re-scan for '>' that the
/// start-only `extract_rdf_resource` must do -- the hot reference-scanning loops
/// in `refs`/`get` call this with the boundary they already hold.
/// Returns null if the tag has no rdf:resource; error.MalformedTag if malformed.
pub fn extract_rdf_resource_within(
    slice: []const u8,
    start_idx: u32,
    end_idx: u32,
) error{MalformedTag}!?[]const u8 {
    assert(end_idx > start_idx);
    assert(end_idx < slice.len);

    const pattern = "rdf:resource=\"";

    const tag_content = slice[start_idx..end_idx];
    const pattern_offset = find_needle_anchored(tag_content, pattern) orelse return null;
    const pattern_start_idx = start_idx + pattern_offset;

    const value_start_idx = pattern_start_idx + pattern.len;
    const value_end_idx = std.mem.indexOfScalarPos(u8, slice, value_start_idx, '"') orelse return error.MalformedTag;

    // Check if closing quote is within this tag
    if (value_end_idx >= end_idx) return error.MalformedTag;

    return slice[value_start_idx..value_end_idx];
}

/// Extract rdf:resource value from an XML tag, locating the tag's '>' itself.
/// Use `extract_rdf_resource_within` when the boundary's `.end` is already known.
/// Returns null if tag doesn't have rdf:resource.
/// Returns error.MalformedTag if rdf:resource exists but is malformed.
pub fn extract_rdf_resource(slice: []const u8, start_idx: u32) error{MalformedTag}!?[]const u8 {
    const gt_idx = std.mem.indexOfScalarPos(u8, slice, start_idx, '>') orelse return error.MalformedTag;
    return extract_rdf_resource_within(slice, start_idx, @intCast(gt_idx));
}

/// Find the closing boundary paired with an opening element boundary.
/// Returns `error.MalformedTag` if `opening_tag_idx` is a non-element boundary
/// or its name cannot be parsed.
///
/// Strict, and identically so to `build_closing_index`: comments, processing
/// instructions and CDATA are skipped because they are not elements and take no
/// part in nesting, but an *element* whose name will not parse is malformed XML
/// and aborts the search. Skipping it instead would silently answer a nesting
/// question using a document the scanner could not fully read.
pub fn find_closing_tag(
    xml: []const u8,
    boundaries: []const TagBoundary,
    opening_tag_idx: u32,
) error{ NoClosingTag, SelfClosingTag, MalformedTag }!u32 {
    assert(opening_tag_idx < boundaries.len);

    const opening_tag = boundaries[opening_tag_idx];
    assert(opening_tag.start < opening_tag.end);
    if (boundary_kind(xml, opening_tag) != .element_open) return error.MalformedTag;

    // Check if self-closing.
    if (xml[opening_tag.end - 1] == '/') return error.SelfClosingTag;

    var depth: u32 = 1;
    // Qualified names, matching `build_closing_index`: depth tracking has to
    // agree with the index the rest of the document is read through.
    const opening_qname = (try extract_tag_type_terminated(xml, opening_tag.start)).qname;
    const result_idx: u32 = blk: {
        for (boundaries[opening_tag_idx + 1 ..], opening_tag_idx + 1..) |tag, i| {
            const kind = boundary_kind(xml, tag);
            if (kind == .non_element) continue;
            const self_closing = xml[tag.end - 1] == '/';
            // A closing tag cannot also be self-closing: `</x/>` is malformed
            // XML, not an empty element.
            if (kind == .element_close and self_closing) return error.MalformedTag;
            const tag_qname = (try extract_tag_type_terminated(xml, tag.start)).qname;
            // A self-closing element opens and closes at once: its name still has
            // to parse, but it cannot change the depth.
            if (self_closing) continue;

            switch (kind) {
                .element_close => if (std.mem.eql(u8, opening_qname, tag_qname)) {
                    assert(depth > 0);
                    depth -= 1;
                    if (depth == 0) break :blk @intCast(i);
                },
                .element_open => if (std.mem.eql(u8, opening_qname, tag_qname)) {
                    assert(depth < std.math.maxInt(u32));
                    depth += 1;
                },
                .non_element => unreachable,
            }
        }
        return error.NoClosingTag;
    };
    // Postcondition: the closer lies strictly after the opener and within bounds,
    // pairing with the bounds precondition above.
    assert(result_idx > opening_tag_idx);
    assert(result_idx < boundaries.len);
    return result_idx;
}

const BoundaryKind = enum { element_open, element_close, non_element };

inline fn boundary_kind(xml: []const u8, tag: TagBoundary) BoundaryKind {
    assert(tag.start < tag.end);
    assert(tag.end < xml.len);
    assert(xml[tag.start] == '<');
    return switch (xml[tag.start + 1]) {
        '/' => .element_close,
        '!', '?' => .non_element,
        else => .element_open,
    };
}

/// True when a boundary is an element opening tag, i.e. a candidate child of the
/// object being walked. False for closing tags, comments and processing
/// instructions.
///
/// The comment case is load-bearing, not defensive: `find_tag_boundaries` emits
/// a comment as one boundary spanning the whole `<!-- ... -->` section, so a
/// commented-out child would otherwise be read as a live one. A comment's bytes
/// can also resemble a qualified element name closely enough to perturb tag
/// matching unless the boundary is rejected before parsing its name.
///
/// Every child walk must apply this; property walks additionally skip
/// self-closing tags, which cannot carry a text value.
pub inline fn is_element_open_tag(xml: []const u8, tag: TagBoundary) bool {
    return boundary_kind(xml, tag) == .element_open;
}

/// Pre-compute closing tag indices for all boundaries.
/// For an opening element, `closing_for[i]` is the matching closing boundary,
/// or `i` when it is self-closing. Closing and non-element boundaries retain
/// their default `i` value.
///
/// This is the document's gate, and it is strict: any element whose name will
/// not parse fails the whole parse with `error.MalformedXML`. Non-elements
/// (comments, processing instructions, CDATA, doctype) are skipped -- that is
/// not tolerance, they simply are not elements. Because `CimDocument.init` runs
/// this pass before anything walks the document, every later consumer may take
/// it as given that an element boundary has a parseable name; `ChildIterator`
/// relies on exactly that.
/// Caller owns the returned slice.
pub fn build_closing_index(
    gpa: std.mem.Allocator,
    xml: []const u8,
    boundaries: []const TagBoundary,
) ![]u32 {
    var error_offset: MalformedXML = .{};
    return build_closing_indexWithErrorOffset(gpa, xml, boundaries, &error_offset);
}

/// The diagnostic variant records the offset of the offending tag: the closing
/// tag that failed to match, or the outermost opener that was never closed.
pub fn build_closing_indexWithErrorOffset(
    gpa: std.mem.Allocator,
    xml: []const u8,
    boundaries: []const TagBoundary,
    error_offset: *MalformedXML,
) ![]u32 {
    assert(xml.len <= std.math.maxInt(u32));
    const closing_for = try gpa.alloc(u32, boundaries.len);
    errdefer gpa.free(closing_for);

    // Default: each tag closes itself (correct for self-closing; overwritten for pairs).
    for (closing_for, 0..) |*v, i| v.* = @intCast(i);

    // Stack entries: the opener's qualified name + its boundary index. Nesting
    // is matched on the qualified name, not the local one: an XML end tag must
    // repeat its opener's name exactly, so `<cim:Substation></Substation>` and
    // `<cim:X></md:X>` are both malformed even though the local names agree.
    const StackEntry = struct { qname: []const u8, idx: u32 };
    var stack: std.ArrayListUnmanaged(StackEntry) = .empty;
    defer stack.deinit(gpa);

    for (boundaries, 0..) |tag, i| {
        switch (boundary_kind(xml, tag)) {
            // Not an element, so it takes no part in nesting. This is the only
            // boundary this pass passes over.
            .non_element => {},
            .element_close => {
                // A closing tag cannot also be self-closing: `</x/>` is
                // malformed XML, not an empty element, and must not be dropped.
                if (xml[tag.end - 1] == '/') return malformed_xml(error_offset, tag.start, .closing_tag_self_closed, xml.len);
                const parsed = extract_tag_type_terminated(xml, tag.start) catch
                    return malformed_xml(error_offset, tag.start, .unreadable_tag_name, xml.len);
                if (stack.items.len == 0) return malformed_xml(error_offset, tag.start, .unexpected_closing_tag, xml.len);
                if (!std.mem.eql(u8, stack.items[stack.items.len - 1].qname, parsed.qname)) {
                    return malformed_xml(error_offset, tag.start, .mismatched_closing_tag, xml.len);
                }
                const opener = stack.pop().?;
                closing_for[opener.idx] = @intCast(i);
            },
            .element_open => {
                // The name is parsed before the self-closing test: `<x/>` never
                // reaches the stack, but it is still an element and still has to
                // be readable for the document to be well-formed.
                const parsed = extract_tag_type_terminated(xml, tag.start) catch
                    return malformed_xml(error_offset, tag.start, .unreadable_tag_name, xml.len);
                // Self-closing -- already defaulted, nothing to push.
                if (xml[tag.end - 1] == '/') continue;
                try stack.append(gpa, .{ .qname = parsed.qname, .idx = @intCast(i) });
            },
        }
    }

    // Every opener must have been matched; a non-empty stack means unclosed tags.
    // Report the outermost unclosed opener -- that is the tag the user must fix,
    // and unlike end-of-input it falls inside the segment that actually broke.
    if (stack.items.len != 0) return malformed_xml(
        error_offset,
        boundaries[stack.items[0].idx].start,
        .unclosed_element,
        xml.len,
    );

    // Postcondition: every entry either points to itself (self-closing) or to a
    // boundary strictly after it. A regression in the matching logic above
    // (e.g. an off-by-one on the closing-tag write) would surface here rather
    // than silently corrupt downstream property extraction.
    for (closing_for, 0..) |c, i| {
        assert(c >= i);
        assert(c < boundaries.len);
    }

    return closing_for;
}
