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
        // Worst case: every byte in the block matches — reserve before entering.
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

/// Find all XML tag boundaries by pairing '<' and '>' characters.
/// Uses two SIMD passes (one per delimiter) then zips the results.
/// Returns ArrayList of TagBoundary in document order.
pub fn find_tag_boundaries(
    gpa: std.mem.Allocator,
    xml: []const u8,
) !std.ArrayList(TagBoundary) {
    var result: std.ArrayList(TagBoundary) = .empty;
    errdefer result.deinit(gpa);

    if (xml.len == 0) return result;

    // Find all '<'
    var lt_positions = try find_byte_simd(gpa, xml, '<');
    defer lt_positions.deinit(gpa);

    // Find all '>'
    var gt_positions = try find_byte_simd(gpa, xml, '>');
    defer gt_positions.deinit(gpa);

    if (lt_positions.items.len == 0 and gt_positions.items.len == 0) return result;

    // Unequal counts mean malformed XML (e.g. unmatched '<' or '>').
    if (lt_positions.items.len != gt_positions.items.len) {
        return error.MalformedXML;
    }

    try result.ensureTotalCapacity(gpa, lt_positions.items.len);

    for (lt_positions.items, gt_positions.items) |lt_pos, gt_pos| {
        // In well-formed XML, '>' must come after '<'.
        if (gt_pos <= lt_pos) {
            return error.MalformedXML;
        }
        result.appendAssumeCapacity(.{ .start = lt_pos, .end = gt_pos });
    }
    return result;
}

/// Extract tag type from XML tag, stripping namespace
/// Example: "<cim:Substation rdf:ID="_SS1">" → "Substation"
pub fn extract_tag_type(slice: []const u8, start_idx: u32) error{MalformedTag}![]const u8 {
    const colon_idx = std.mem.indexOfScalarPos(u8, slice, start_idx, ':') orelse return error.MalformedTag;
    const end_idx = std.mem.indexOfAnyPos(u8, slice, colon_idx, " >") orelse return error.MalformedTag;
    return slice[colon_idx + 1 .. end_idx];
}

/// Extract rdf:ID value from an XML tag
/// Example: "<cim:Substation rdf:ID="_SS1">" → "_SS1"
/// Returns error.NoRdfId if tag doesn't have rdf:ID
/// Returns error.MalformedTag if rdf:ID exists but is malformed
pub fn extract_rdf_id(slice: []const u8, start_idx: u32) error{ NoRdfId, MalformedTag }![]const u8 {
    const gt_idx = std.mem.indexOfScalarPos(u8, slice, start_idx, '>') orelse return error.MalformedTag;

    const pattern = "rdf:ID=\"";

    const tag_content = slice[start_idx..gt_idx];
    const pattern_offset = std.mem.indexOf(u8, tag_content, pattern) orelse return error.NoRdfId;
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
    const pattern_offset = std.mem.indexOf(u8, tag_content, pattern) orelse return error.NoRdfAbout;
    const pattern_start_idx = start_idx + pattern_offset;

    const value_start_idx = pattern_start_idx + pattern.len;
    const value_end_idx = std.mem.indexOfScalarPos(u8, slice, value_start_idx, '"') orelse return error.MalformedTag;

    // Check if closing quote is within this tag
    if (value_end_idx >= gt_idx) return error.MalformedTag;

    return slice[value_start_idx..value_end_idx];
}

/// Extract rdf:Resource value from an XML tag
/// Returns error.NoRdfResource if tag doesn't have rdf:Resource
/// Returns error.MalformedTag if rdf:Resource exists but is malformed
pub fn extract_rdf_resource(slice: []const u8, start_idx: u32) error{MalformedTag}!?[]const u8 {
    const gt_idx = std.mem.indexOfScalarPos(u8, slice, start_idx, '>') orelse return error.MalformedTag;

    const pattern = "rdf:resource=\"";

    const tag_content = slice[start_idx..gt_idx];
    const pattern_offset = std.mem.indexOf(u8, tag_content, pattern) orelse return null;
    const pattern_start_idx = start_idx + pattern_offset;

    const value_start_idx = pattern_start_idx + pattern.len;
    const value_end_idx = std.mem.indexOfScalarPos(u8, slice, value_start_idx, '"') orelse return error.MalformedTag;

    // Check if closing quote is within this tag
    if (value_end_idx >= gt_idx) return error.MalformedTag;

    return slice[value_start_idx..value_end_idx];
}

pub fn find_closing_tag(
    xml: []const u8,
    boundaries: []const TagBoundary,
    opening_tag_idx: u32,
) error{ NoClosingTag, SelfClosingTag, MalformedTag }!u32 {
    // I have chosen assert over error here because I think this is always a programmer error and never can be caused by bad user input.
    assert(opening_tag_idx < boundaries.len);

    const opening_tag = boundaries[opening_tag_idx];

    // Check if self-closing.
    if (xml[opening_tag.end - 1] == '/') return error.SelfClosingTag;

    var depth: u32 = 1;
    const opening_tag_type = try extract_tag_type(xml, opening_tag.start);
    return blk: {
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
        break :blk error.NoClosingTag;
    };
}

pub fn get_property_from_indices(
    xml: []const u8,
    boundaries: []const TagBoundary,
    opening_tag_idx: u32,
    closing_tag_idx: u32,
    property_name: []const u8,
) error{MalformedTag}!?[]const u8 {
    // Self-closing tags have no properties
    if (closing_tag_idx == opening_tag_idx) return null;

    assert(property_name.len > 0);
    assert(closing_tag_idx < boundaries.len);

    // Neighbouring tags have no properties
    if (closing_tag_idx == opening_tag_idx + 1) return null;

    for (boundaries[opening_tag_idx + 1 .. closing_tag_idx], opening_tag_idx + 1..) |tag, i| {
        if (xml[tag.start + 1] == '/' or xml[tag.end - 1] == '/') {
            // Skip closing and self-closing tags
            continue;
        }
        const tag_type = extract_tag_type(xml, tag.start) catch continue;
        if (std.mem.eql(u8, tag_type, property_name)) {
            return xml[tag.end + 1 .. boundaries[i + 1].start];
        }
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
    // Self-closing tags have no properties
    if (closing_tag_idx == opening_tag_idx) return null;

    assert(property_name.len > 0);
    assert(closing_tag_idx < boundaries.len);

    // Neighbouring tags have no properties
    if (closing_tag_idx == opening_tag_idx + 1) return null;

    for (boundaries[opening_tag_idx + 1 .. closing_tag_idx]) |tag| {
        if (xml[tag.start + 1] == '/') {
            // Skip closing tags
            continue;
        }
        const tag_type = extract_tag_type(xml, tag.start) catch continue;
        if (std.mem.eql(u8, tag_type, property_name)) {
            return extract_rdf_resource(xml, tag.start);
        }
    }
    return null;
}

/// Represents a CIM object with lazy property access
/// Zero-copy, index-based design for minimal memory footprint
pub const CimObject = struct {
    xml: []const u8,
    boundaries: []const TagBoundary,

    object_tag_idx: u32,
    closing_tag_idx: u32,

    id: []const u8,
    type_name: []const u8,

    pub fn init(
        xml: []const u8,
        boundaries: []const TagBoundary,
        object_tag_idx: u32,
        closing_tag_idx: u32,
        id: []const u8,
    ) error{MalformedTag}!CimObject {
        assert(id.len > 0);
        return .{
            .xml = xml,
            .boundaries = boundaries,
            .object_tag_idx = object_tag_idx,
            .closing_tag_idx = closing_tag_idx,
            .id = id,
            .type_name = try extract_tag_type(xml, boundaries[object_tag_idx].start),
        };
    }

    /// Get a text property value by name
    /// Returns null if property doesn't exist
    pub fn getProperty(self: CimObject, property_name: []const u8) error{MalformedTag}!?[]const u8 {
        return get_property_from_indices(self.xml, self.boundaries, self.object_tag_idx, self.closing_tag_idx, property_name);
    }

    /// Get a reference (rdf:resource) value by name
    /// Returns null if property doesn't exist or has no rdf:resource
    pub fn getReference(self: CimObject, property_name: []const u8) error{MalformedTag}!?[]const u8 {
        return get_reference_from_indices(self.xml, self.boundaries, self.object_tag_idx, self.closing_tag_idx, property_name);
    }

    /// Batch-fetch multiple text properties in a single scan through child tags.
    /// Returns a fixed-size array of optional values corresponding to each name.
    pub fn getProperties(self: CimObject, comptime names: anytype) error{MalformedTag}![names.len]?[]const u8 {
        var result: [names.len]?[]const u8 = .{null} ** names.len;

        if (self.closing_tag_idx == self.object_tag_idx) return result;
        if (self.closing_tag_idx == self.object_tag_idx + 1) return result;

        var found_count: usize = 0;

        for (self.boundaries[self.object_tag_idx + 1 .. self.closing_tag_idx], self.object_tag_idx + 1..) |tag, tag_idx| {
            if (self.xml[tag.start + 1] == '/' or self.xml[tag.end - 1] == '/') continue;

            const tag_type = extract_tag_type(self.xml, tag.start) catch continue;

            inline for (names, 0..) |name, idx| {
                if (result[idx] == null and std.mem.eql(u8, tag_type, name)) {
                    result[idx] = self.xml[tag.end + 1 .. self.boundaries[tag_idx + 1].start];
                    found_count += 1;
                    if (found_count == names.len) return result;
                }
            }
        }

        return result;
    }

    /// Batch-fetch multiple rdf:resource references in a single scan through child tags.
    /// Returns a fixed-size array of optional values corresponding to each name.
    pub fn getReferences(self: CimObject, comptime names: anytype) error{MalformedTag}![names.len]?[]const u8 {
        var result: [names.len]?[]const u8 = .{null} ** names.len;

        if (self.closing_tag_idx == self.object_tag_idx) return result;
        if (self.closing_tag_idx == self.object_tag_idx + 1) return result;

        var found_count: usize = 0;

        for (self.boundaries[self.object_tag_idx + 1 .. self.closing_tag_idx]) |tag| {
            if (self.xml[tag.start + 1] == '/') continue;

            const tag_type = extract_tag_type(self.xml, tag.start) catch continue;

            inline for (names, 0..) |name, idx| {
                if (result[idx] == null and std.mem.eql(u8, tag_type, name)) {
                    result[idx] = try extract_rdf_resource(self.xml, tag.start);
                    found_count += 1;
                    if (found_count == names.len) return result;
                }
            }
        }

        return result;
    }

    /// Get all text properties (not references) as a HashMap
    pub fn getAllProperties(self: CimObject, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var result = std.StringHashMap([]const u8).init(gpa);
        errdefer result.deinit();

        // Handle self-closing tags
        if (self.closing_tag_idx == self.object_tag_idx) return result;

        // Iterate through all tags between opening and closing
        for (self.boundaries[self.object_tag_idx + 1 .. self.closing_tag_idx], self.object_tag_idx + 1..) |tag, i| {
            // Skip closing tags and self-closing tags.
            // In CIM XML, references are always self-closing; properties never are.
            if (self.xml[tag.start + 1] == '/' or self.xml[tag.end - 1] == '/') continue;
            const tag_type = try extract_tag_type(self.xml, tag.start);
            const content = self.xml[tag.end + 1 .. self.boundaries[i + 1].start];
            try result.put(tag_type, content);
        }

        return result;
    }

    /// Get all rdf:resource references as a HashMap
    pub fn getAllReferences(self: CimObject, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var result = std.StringHashMap([]const u8).init(gpa);
        errdefer result.deinit();

        // Handle self-closing tags
        if (self.closing_tag_idx == self.object_tag_idx) return result;

        // Iterate through all tags between opening and closing
        for (self.boundaries[self.object_tag_idx + 1 .. self.closing_tag_idx]) |tag| {
            // Skip closing tags (self-closing do have references though)
            if (self.xml[tag.start + 1] == '/') {
                continue;
            }

            const tag_type = extract_tag_type(self.xml, tag.start) catch continue;
            const reference = extract_rdf_resource(self.xml, tag.start) catch continue;

            if (reference) |ref_value| {
                try result.put(tag_type, ref_value);
            }
        }

        return result;
    }
};
