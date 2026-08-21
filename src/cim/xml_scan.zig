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

fn malformed_xml(error_offset: *u32, offset: u32, xml_len: usize) error{MalformedXML} {
    assert(offset <= xml_len);
    error_offset.* = offset;
    return error.MalformedXML;
}

/// Find all XML tag boundaries by pairing '<' and '>' characters.
/// Uses two SIMD passes (one per delimiter) then zips the results, skipping
/// `<` and `>` that appear inside XML comments (`<!-- ... -->`). The comment
/// itself is emitted as a single boundary spanning the whole section.
/// Stray '>' characters in text content (legal per the XML spec -- only '<'
/// and '&' must be escaped in character data) are skipped silently.
/// Returns ArrayList of TagBoundary in document order.
pub fn find_tag_boundaries(
    gpa: std.mem.Allocator,
    xml: []const u8,
) !std.ArrayList(TagBoundary) {
    var error_offset: u32 = undefined;
    return find_tag_boundariesWithErrorOffset(gpa, xml, &error_offset);
}

/// The diagnostic variant records the byte that made the scan fail. The
/// caller only reads `error_offset` when this returns error.MalformedXML.
pub fn find_tag_boundariesWithErrorOffset(
    gpa: std.mem.Allocator,
    xml: []const u8,
    error_offset: *u32,
) !std.ArrayList(TagBoundary) {
    var result: std.ArrayList(TagBoundary) = .empty;
    errdefer result.deinit(gpa);

    if (xml.len == 0) return result;

    var lt_positions = try find_byte_simd(gpa, xml, '<');
    defer lt_positions.deinit(gpa);

    var gt_positions = try find_byte_simd(gpa, xml, '>');
    defer gt_positions.deinit(gpa);

    const lts = lt_positions.items;
    const gts = gt_positions.items;

    if (lts.len == 0 and gts.len == 0) return result;

    // Upper bound: every '<' opens a tag. Comments only reduce this.
    try result.ensureTotalCapacity(gpa, lts.len);

    var lt_idx: usize = 0;
    var gt_idx: usize = 0;

    while (lt_idx < lts.len) {
        const lt = lts[lt_idx];

        // Fast path: most '<' open a normal element. One byte-compare guards
        // the comment branch; the compiler keeps this in a single predictable
        // branch since '!' is rare immediately after '<'.
        const is_comment = lt + 3 < xml.len and
            xml[lt + 1] == '!' and xml[lt + 2] == '-' and xml[lt + 3] == '-';

        if (!is_comment) {
            // Skip any stray '>' positions that appear in text content before
            // this tag's '<'. Such '>' are legal XML character data.
            while (gt_idx < gts.len and gts[gt_idx] < lt) : (gt_idx += 1) {}
            if (gt_idx >= gts.len) return malformed_xml(error_offset, lt, xml.len);
            const gt = gts[gt_idx];
            result.appendAssumeCapacity(.{ .start = lt, .end = gt });
            lt_idx += 1;
            gt_idx += 1;
            continue;
        }

        // Comment: walk gt_idx forward to the first '>' preceded by '--',
        // then skip any '<' positions that fell inside the comment span.
        // The opening '<!--' occupies lt..lt+3, so any '>' at or before lt+3
        // can't be the closer (and would already be paired with a prior tag).
        while (gt_idx < gts.len and gts[gt_idx] <= lt + 3) : (gt_idx += 1) {}

        const close_gt = while (gt_idx < gts.len) : (gt_idx += 1) {
            const gt = gts[gt_idx];
            if (xml[gt - 1] == '-' and xml[gt - 2] == '-') break gt;
        } else return malformed_xml(error_offset, lt, xml.len);

        result.appendAssumeCapacity(.{ .start = lt, .end = close_gt });
        gt_idx += 1;
        lt_idx += 1;
        while (lt_idx < lts.len and lts[lt_idx] < close_gt) : (lt_idx += 1) {}
    }

    // Any remaining '>' entries are stray (text content after the last tag) -- ignore them.

    return result;
}

/// Extract tag type from XML tag, stripping namespace
/// Example: "<cim:Substation rdf:ID="_SS1">" → "Substation"
/// Tag-name terminator set includes all XML whitespace (space, tab, CR, LF)
/// plus '>' and '/', so multi-line opening tags like `<rdf:RDF\n  xmlns=...>`
/// and attribute-less self-closing tags like `<cim:X/>` are handled
/// correctly. Scan stays bounded to a single tag at the call sites.
pub fn extract_tag_type(slice: []const u8, start_idx: u32) error{MalformedTag}![]const u8 {
    return (try extract_tag_type_terminated(slice, start_idx)).name;
}

/// `extract_tag_type`, plus the byte that ended the name. The terminator answers
/// "can this element carry attributes at all" for free: '>' or '/' means the name
/// ran straight into the end of the tag, so there is no room for an
/// `rdf:resource`. `ChildIterator` uses that to skip the attribute scan on the
/// ordinary `<cim:X.y>text</cim:X.y>` child, which is most of a CIM document --
/// without it, classifying every child eagerly costs a second pass over each
/// tag and shows up as a ~8% regression on `refs`.
pub fn extract_tag_type_terminated(
    slice: []const u8,
    start_idx: u32,
) error{MalformedTag}!struct { name: []const u8, terminator: u8 } {
    const colon_idx = std.mem.indexOfScalarPos(u8, slice, start_idx, ':') orelse return error.MalformedTag;
    const end_idx = index_of_any_pos_simd(slice, colon_idx, " \t\r\n>/") orelse return error.MalformedTag;
    return .{ .name = slice[colon_idx + 1 .. end_idx], .terminator = slice[end_idx] };
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

pub fn find_closing_tag(
    xml: []const u8,
    boundaries: []const TagBoundary,
    opening_tag_idx: u32,
) error{ NoClosingTag, SelfClosingTag, MalformedTag }!u32 {
    assert(opening_tag_idx < boundaries.len);

    const opening_tag = boundaries[opening_tag_idx];
    assert(opening_tag.start < opening_tag.end);

    // Check if self-closing.
    if (xml[opening_tag.end - 1] == '/') return error.SelfClosingTag;

    var depth: u32 = 1;
    const opening_tag_type = try extract_tag_type(xml, opening_tag.start);
    const result_idx: u32 = blk: {
        for (boundaries[opening_tag_idx + 1 ..], opening_tag_idx + 1..) |tag, i| {
            if (xml[tag.start + 1] == '/') {
                const tag_type = extract_tag_type(xml, tag.start + 1) catch continue;
                if (std.mem.eql(u8, opening_tag_type, tag_type)) {
                    assert(depth > 0);
                    depth -= 1;
                    if (depth == 0) break :blk @intCast(i);
                }
            } else if (xml[tag.end - 1] != '/') {
                // Opening tag (not self-closing)
                const tag_type = extract_tag_type(xml, tag.start) catch continue;
                if (std.mem.eql(u8, opening_tag_type, tag_type)) {
                    assert(depth < std.math.maxInt(u32));
                    depth += 1;
                }
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

/// True when a boundary is an element opening tag, i.e. a candidate child of the
/// object being walked. False for closing tags, comments and processing
/// instructions.
///
/// The comment case is load-bearing, not defensive: `find_tag_boundaries` emits
/// a comment as one boundary spanning the whole `<!-- ... -->` section, so a
/// commented-out child would otherwise be read as a live one. `extract_tag_type`
/// also scans forward past the boundary for its ':', so an ordinary comment can
/// take its name -- and a property walk its value -- from the following tag.
///
/// Every child walk must apply this; property walks additionally skip
/// self-closing tags, which cannot carry a text value.
pub inline fn is_element_open_tag(xml: []const u8, tag: TagBoundary) bool {
    assert(tag.start + 1 < xml.len);
    const c = xml[tag.start + 1];
    return c != '/' and c != '!' and c != '?';
}

/// Pre-compute closing tag indices for all boundaries.
/// closing_for[i] == i means self-closing. Otherwise closing_for[i] is the
/// index of the matching closing boundary.
/// Caller owns the returned slice.
pub fn build_closing_index(
    gpa: std.mem.Allocator,
    xml: []const u8,
    boundaries: []const TagBoundary,
) ![]u32 {
    var error_offset: u32 = undefined;
    return build_closing_indexWithErrorOffset(gpa, xml, boundaries, &error_offset);
}

/// The diagnostic variant records the offset of the offending tag: the closing
/// tag that failed to match, or the outermost opener that was never closed.
pub fn build_closing_indexWithErrorOffset(
    gpa: std.mem.Allocator,
    xml: []const u8,
    boundaries: []const TagBoundary,
    error_offset: *u32,
) ![]u32 {
    assert(xml.len <= std.math.maxInt(u32));
    const closing_for = try gpa.alloc(u32, boundaries.len);
    errdefer gpa.free(closing_for);

    // Default: each tag closes itself (correct for self-closing; overwritten for pairs).
    for (closing_for, 0..) |*v, i| v.* = @intCast(i);

    // Stack entries: opening tag type + its boundary index.
    const StackEntry = struct { type_name: []const u8, idx: u32 };
    var stack: std.ArrayListUnmanaged(StackEntry) = .empty;
    defer stack.deinit(gpa);

    for (boundaries, 0..) |tag, i| {
        if (xml[tag.end - 1] == '/') {
            // Self-closing -- already defaulted, nothing to push.
        } else if (xml[tag.start + 1] == '!' or xml[tag.start + 1] == '?') {
            // XML comment (<!--) or processing instruction (<?).
            // Not an element -- never pushed, never popped.
        } else if (xml[tag.start + 1] == '/') {
            // Closing tag -- must match the stack top; CGMES XML is always well-nested.
            // Bound the type search to within this tag to prevent cross-tag colon matches.
            const tag_xml = xml[tag.start .. tag.end + 1];
            const type_name = extract_tag_type(tag_xml, 1) catch continue;
            if (stack.items.len == 0) return malformed_xml(error_offset, tag.start, xml.len);
            if (!std.mem.eql(u8, stack.items[stack.items.len - 1].type_name, type_name)) {
                return malformed_xml(error_offset, tag.start, xml.len);
            }
            const opener = stack.pop().?;
            closing_for[opener.idx] = @intCast(i);
        } else {
            // Opening tag -- push.
            // Bound the type search to within this tag to prevent cross-tag colon matches
            // (e.g. a boundary created by '<->' inside an XML comment could otherwise look
            // past the boundary end and find the ':' in the following real tag's namespace).
            const tag_xml = xml[tag.start .. tag.end + 1];
            const type_name = extract_tag_type(tag_xml, 0) catch continue;
            try stack.append(gpa, .{ .type_name = type_name, .idx = @intCast(i) });
        }
    }

    // Every opener must have been matched; a non-empty stack means unclosed tags.
    // Report the outermost unclosed opener -- that is the tag the user must fix,
    // and unlike end-of-input it falls inside the segment that actually broke.
    if (stack.items.len != 0) return malformed_xml(error_offset, boundaries[stack.items[0].idx].start, xml.len);

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
