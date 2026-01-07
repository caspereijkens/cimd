const std = @import("std");
const assert = std.debug.assert;

/// Vector size for SIMD operations (32 bytes = 256-bit AVX2)
/// Falls back to smaller sizes on older CPUs
const VECTOR_LEN = if (std.simd.suggestVectorLength(u8)) |size|
    @min(size, 32)
else
    32;

const Chunk = @Vector(VECTOR_LEN, u8);

/// Find all positions of a specific byte in the input using SIMD
/// Returns an ArrayList of positions where the byte was found
pub fn findByteSIMD(
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
        // Process 4 SIMD vectors in parallel
        inline for (0..unroll_factor) |j| {
            const offset = i + j * VECTOR_LEN;
            const chunk: Chunk = haystack[offset..][0..VECTOR_LEN].*;
            const matches: @Vector(VECTOR_LEN, bool) = chunk == all_needles;
            const mask: u32 = @bitCast(matches);

            var m = mask;
            while (m != 0) {
                const bit_pos = @ctz(m);
                // appendAssumeCapacity (no bounds check)
                result.appendAssumeCapacity(@intCast(offset + bit_pos));
                m &= m - 1;
            }
        }
    }

    // Handle remaining full vectors
    while (i + VECTOR_LEN <= haystack.len) : (i += VECTOR_LEN) {
        const chunk: Chunk = haystack[i..][0..VECTOR_LEN].*;
        const matches: @Vector(VECTOR_LEN, bool) = chunk == all_needles;
        const mask: u32 = @bitCast(matches);

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
fn verifyAndExtractPattern(
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
pub fn findPattern(
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
        inline for (0..unroll_factor) |j| {
            const offset = i + j * VECTOR_LEN;
            const chunk: Chunk = haystack[offset..][0..VECTOR_LEN].*;
            const matches: @Vector(VECTOR_LEN, bool) = chunk == all_first_bytes;
            const mask: u32 = @bitCast(matches);

            var m = mask;
            while (m != 0) {
                const bit_pos = @ctz(m);
                const candidate_pos = offset + bit_pos;

                if (verifyAndExtractPattern(haystack, candidate_pos, needle)) |match| {
                    result.appendAssumeCapacity(match);
                }

                m &= m - 1;
            }
        }
    }

    // Remaining full vectors
    while (i + VECTOR_LEN <= haystack.len) : (i += VECTOR_LEN) {
        const chunk: Chunk = haystack[i..][0..VECTOR_LEN].*;
        const matches: @Vector(VECTOR_LEN, bool) = chunk == all_first_bytes;
        const mask: u32 = @bitCast(matches);

        var m = mask;
        while (m != 0) {
            const bit_pos = @ctz(m);
            const candidate_pos = i + bit_pos;

            if (verifyAndExtractPattern(haystack, candidate_pos, needle)) |match| {
                result.appendAssumeCapacity(match);
            }

            m &= m - 1;
        }
    }

    // Scalar remainder
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == first_byte) {
            if (verifyAndExtractPattern(haystack, i, needle)) |match| {
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

/// Find all XML tag boundaries by pairing '<' and '>' characters
/// Uses SIMD to find delimiters, then pairs them sequentially
/// Returns ArrayList of TagBoundary in document order
pub fn findTagBoundaries(
    gpa: std.mem.Allocator,
    xml: []const u8,
) !std.ArrayList(TagBoundary) {
    var result: std.ArrayList(TagBoundary) = .empty;
    errdefer result.deinit(gpa);

    if (xml.len == 0) return result;

    // Find all '<'
    var lt_positions = try findByteSIMD(gpa, xml, '<');
    defer lt_positions.deinit(gpa);

    // Find all '>'
    var gt_positions = try findByteSIMD(gpa, xml, '>');
    defer gt_positions.deinit(gpa);

    if (lt_positions.items.len == 0 and gt_positions.items.len == 0) return result;

    // Check that we have as many lt as gt brackets, otherwise the input data is malformed.
    if (lt_positions.items.len != gt_positions.items.len) {
        return error.MalformedXML;
    }

    try result.ensureTotalCapacity(gpa, lt_positions.items.len);

    for (lt_positions.items, gt_positions.items) |lt_pos, gt_pos| {
        // In well-formed XML, '>' must come after '<'
        if (gt_pos <= lt_pos) {
            return error.MalformedXML;
        }
        result.appendAssumeCapacity(.{.start=lt_pos, .end=gt_pos});
    }
    return result;
}
// ============================================================================
// Tests
// ============================================================================

test "findByteSIMD - finds all angle brackets" {
    const gpa = std.testing.allocator;

    const input = "<a><b></b></a>";

    // Find all '<'
    var lt_positions = try findByteSIMD(gpa, input, '<');
    defer lt_positions.deinit(gpa);

    // Expected: positions 0, 3, 6, 10
    try std.testing.expectEqual(@as(usize, 4), lt_positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), lt_positions.items[0]);
    try std.testing.expectEqual(@as(u32, 3), lt_positions.items[1]);
    try std.testing.expectEqual(@as(u32, 6), lt_positions.items[2]);
    try std.testing.expectEqual(@as(u32, 10), lt_positions.items[3]);

    // Find all '>'
    var gt_positions = try findByteSIMD(gpa, input, '>');
    defer gt_positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), gt_positions.items.len);
    try std.testing.expectEqual(@as(u32, 2), gt_positions.items[0]);
    try std.testing.expectEqual(@as(u32, 5), gt_positions.items[1]);
    try std.testing.expectEqual(@as(u32, 9), gt_positions.items[2]);
    try std.testing.expectEqual(@as(u32, 13), gt_positions.items[3]);
}

test "findByteSIMD - handles empty input" {
    const gpa = std.testing.allocator;

    var positions = try findByteSIMD(gpa, "", '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), positions.items.len);
}

test "findByteSIMD - handles input with no matches" {
    const gpa = std.testing.allocator;

    var positions = try findByteSIMD(gpa, "hello world", '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), positions.items.len);
}

test "findByteSIMD - handles large input spanning multiple SIMD vectors" {
    const gpa = std.testing.allocator;

    // Create input larger than VECTOR_LEN to test chunking
    var buffer: [128]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<';
    buffer[32] = '<'; // Cross vector boundary
    buffer[64] = '<';
    buffer[127] = '<';

    var positions = try findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, 32), positions.items[1]);
    try std.testing.expectEqual(@as(u32, 64), positions.items[2]);
    try std.testing.expectEqual(@as(u32, 127), positions.items[3]);
}

test "findByteSIMD - exactly one vector (32 bytes)" {
    const gpa = std.testing.allocator;

    // Exactly VECTOR_LEN bytes - tests remaining vectors loop, not unrolled
    var buffer: [VECTOR_LEN]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<';
    buffer[16] = '<';
    buffer[31] = '<'; // Last position

    var positions = try findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, 16), positions.items[1]);
    try std.testing.expectEqual(@as(u32, 31), positions.items[2]);
}

test "findByteSIMD - two full vectors (64 bytes)" {
    const gpa = std.testing.allocator;

    // 2 * VECTOR_LEN - tests remaining vectors loop with 2 iterations
    var buffer: [VECTOR_LEN * 2]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<';
    buffer[VECTOR_LEN] = '<'; // Start of second vector
    buffer[VECTOR_LEN + 15] = '<'; // Middle of second vector

    var positions = try findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, VECTOR_LEN), positions.items[1]);
    try std.testing.expectEqual(@as(u32, VECTOR_LEN + 15), positions.items[2]);
}

test "findByteSIMD - three full vectors (96 bytes)" {
    const gpa = std.testing.allocator;

    // 3 * VECTOR_LEN - tests remaining vectors loop with 3 iterations
    var buffer: [VECTOR_LEN * 3]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[VECTOR_LEN * 0] = '<';
    buffer[VECTOR_LEN * 1] = '<';
    buffer[VECTOR_LEN * 2] = '<';

    var positions = try findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, VECTOR_LEN), positions.items[1]);
    try std.testing.expectEqual(@as(u32, VECTOR_LEN * 2), positions.items[2]);
}

test "findByteSIMD - unrolled loop with remainder" {
    const gpa = std.testing.allocator;

    // 130 bytes = 128 (unrolled) + 2 (scalar remainder)
    const unroll_size = VECTOR_LEN * 4;
    var buffer: [unroll_size + 2]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<'; // Unrolled loop
    buffer[unroll_size - 1] = '<'; // End of unrolled loop
    buffer[unroll_size] = '<'; // Scalar remainder
    buffer[unroll_size + 1] = '<'; // Scalar remainder

    var positions = try findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, unroll_size - 1), positions.items[1]);
    try std.testing.expectEqual(@as(u32, unroll_size), positions.items[2]);
    try std.testing.expectEqual(@as(u32, unroll_size + 1), positions.items[3]);
}

test "findByteSIMD - multiple unrolled iterations" {
    const gpa = std.testing.allocator;

    // 256 bytes = 2 iterations of unrolled loop (2 * 128)
    const unroll_size = VECTOR_LEN * 4;
    var buffer: [unroll_size * 2]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<'; // First unrolled iteration
    buffer[unroll_size] = '<'; // Second unrolled iteration
    buffer[unroll_size * 2 - 1] = '<'; // Last byte

    var positions = try findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, unroll_size), positions.items[1]);
    try std.testing.expectEqual(@as(u32, unroll_size * 2 - 1), positions.items[2]);
}

test "findByteSIMD - dense matches in single vector" {
    const gpa = std.testing.allocator;

    // Test multiple matches within a single SIMD vector (tests bit extraction loop)
    var buffer: [VECTOR_LEN]u8 = undefined;
    @memset(&buffer, '<'); // All matches!

    var positions = try findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    // Should find all 32 positions
    try std.testing.expectEqual(@as(usize, VECTOR_LEN), positions.items.len);
    for (positions.items, 0..) |pos, idx| {
        try std.testing.expectEqual(@as(u32, @intCast(idx)), pos);
    }
}

test "findByteSIMD - matches at vector boundaries" {
    const gpa = std.testing.allocator;

    // Test matches at first and last byte of each vector
    const unroll_size = VECTOR_LEN * 4;
    var buffer: [unroll_size + 10]u8 = undefined;
    @memset(&buffer, 'x');

    // First and last of each 32-byte vector
    buffer[0] = '<'; // Vector 0, first
    buffer[VECTOR_LEN - 1] = '<'; // Vector 0, last
    buffer[VECTOR_LEN] = '<'; // Vector 1, first
    buffer[VECTOR_LEN * 2 - 1] = '<'; // Vector 1, last
    buffer[unroll_size] = '<'; // First byte of remainder
    buffer[unroll_size + 9] = '<'; // Last byte of remainder

    var positions = try findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, VECTOR_LEN - 1), positions.items[1]);
    try std.testing.expectEqual(@as(u32, VECTOR_LEN), positions.items[2]);
    try std.testing.expectEqual(@as(u32, VECTOR_LEN * 2 - 1), positions.items[3]);
    try std.testing.expectEqual(@as(u32, unroll_size), positions.items[4]);
    try std.testing.expectEqual(@as(u32, unroll_size + 9), positions.items[5]);
}

test "findByteSIMD - no matches in SIMD sections but matches in remainder" {
    const gpa = std.testing.allocator;

    // All SIMD vectors have no matches, only remainder has matches
    var buffer: [VECTOR_LEN + 5]u8 = undefined;
    @memset(&buffer, 'x');

    // Only matches in scalar remainder
    buffer[VECTOR_LEN] = '<';
    buffer[VECTOR_LEN + 2] = '<';
    buffer[VECTOR_LEN + 4] = '<';

    var positions = try findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, VECTOR_LEN), positions.items[0]);
    try std.testing.expectEqual(@as(u32, VECTOR_LEN + 2), positions.items[1]);
    try std.testing.expectEqual(@as(u32, VECTOR_LEN + 4), positions.items[2]);
}

// ============================================================================
// Pattern Matching Tests
// ============================================================================

test "findPattern - finds rdf:ID with values" {
    const gpa = std.testing.allocator;

    const input =
        \\<cim:Substation rdf:ID="_SubStation1">
        \\<cim:Breaker rdf:ID="_BR1">
    ;

    var matches = try findPattern(gpa, input, "rdf:ID=\"");
    defer matches.deinit(gpa);

    // Should find 2 matches
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);

    // First match: _SubStation1
    const match1 = matches.items[0];
    try std.testing.expectEqual(@as(u32, 16), match1.pattern_start); // Position of 'r' in first rdf:ID
    try std.testing.expectEqual(@as(u32, 24), match1.value_start); // Position of '_' in _SubStation1
    try std.testing.expectEqual(@as(u32, 12), match1.value_len); // Length of "_SubStation1"

    // Verify extracted value
    const value1 = input[match1.value_start..][0..match1.value_len];
    try std.testing.expectEqualStrings("_SubStation1", value1);

    // Second match: _BR1
    const match2 = matches.items[1];
    try std.testing.expectEqual(@as(u32, 52), match2.pattern_start); // Position of 'r' in second rdf:ID
    const value2 = input[match2.value_start..][0..match2.value_len];
    try std.testing.expectEqualStrings("_BR1", value2);
}

test "findPattern - finds rdf:about with # prefix" {
    const gpa = std.testing.allocator;

    const input =
        \\<cim:Terminal rdf:about="#_T1">
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_CN1"/>
        \\</cim:Terminal>
    ;

    var matches = try findPattern(gpa, input, "rdf:about=\"");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), matches.items.len);

    const match = matches.items[0];
    const value = input[match.value_start..][0..match.value_len];
    try std.testing.expectEqualStrings("#_T1", value);
}

test "findPattern - no matches" {
    const gpa = std.testing.allocator;

    const input = "<root>Hello World</root>";

    var matches = try findPattern(gpa, input, "rdf:ID=\"");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "findPattern - empty input" {
    const gpa = std.testing.allocator;

    var matches = try findPattern(gpa, "", "rdf:ID=\"");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "verifyAndExtractPattern - valid pattern with value" {
    const input = "Hello rdf:ID=\"_SubStation1\" World";
    const pattern = "rdf:ID=\"";

    const match = verifyAndExtractPattern(input, 6, pattern);

    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(u32, 6), match.?.pattern_start);
    try std.testing.expectEqual(@as(u32, 14), match.?.value_start);
    try std.testing.expectEqual(@as(u32, 12), match.?.value_len);

    const value = input[match.?.value_start..][0..match.?.value_len];
    try std.testing.expectEqualStrings("_SubStation1", value);
}

test "verifyAndExtractPattern - empty value" {
    const input = "rdf:ID=\"\"";
    const pattern = "rdf:ID=\"";

    const match = verifyAndExtractPattern(input, 0, pattern);

    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(u32, 0), match.?.value_len);
}

test "verifyAndExtractPattern - pattern mismatch" {
    const input = "Hello rdf:about=\"value\"";
    const pattern = "rdf:ID=\"";

    const match = verifyAndExtractPattern(input, 6, pattern);

    try std.testing.expectEqual(@as(?PatternMatch, null), match);
}

test "verifyAndExtractPattern - no closing quote" {
    const input = "rdf:ID=\"unclosed";
    const pattern = "rdf:ID=\"";

    const match = verifyAndExtractPattern(input, 0, pattern);

    try std.testing.expectEqual(@as(?PatternMatch, null), match);
}

test "verifyAndExtractPattern - candidate near end of haystack" {
    const input = "rdf:";
    const pattern = "rdf:ID=\"";

    const match = verifyAndExtractPattern(input, 0, pattern);

    try std.testing.expectEqual(@as(?PatternMatch, null), match);
}

test "verifyAndExtractPattern - value with special characters" {
    const input = "rdf:ID=\"#_Node-123.456\"";
    const pattern = "rdf:ID=\"";

    const match = verifyAndExtractPattern(input, 0, pattern);

    try std.testing.expect(match != null);
    const value = input[match.?.value_start..][0..match.?.value_len];
    try std.testing.expectEqualStrings("#_Node-123.456", value);
}

test "findTagBoundaries - single tag" {
    const gpa = std.testing.allocator;

    const input = "<root>";

    var boundaries = try findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 5), boundaries.items[0].end);
}

test "findTagBoundaries - opening and closing tags" {
    const gpa = std.testing.allocator;

    const input = "<root></root>";

    var boundaries = try findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), boundaries.items.len);

    // <root>
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 5), boundaries.items[0].end);

    // </root>
    try std.testing.expectEqual(@as(u32, 6), boundaries.items[1].start);
    try std.testing.expectEqual(@as(u32, 12), boundaries.items[1].end);
}

test "findTagBoundaries - nested tags" {
    const gpa = std.testing.allocator;

    const input = "<root><child>text</child></root>";

    var boundaries = try findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), boundaries.items.len);

    // <root>
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 5), boundaries.items[0].end);

    // <child>
    try std.testing.expectEqual(@as(u32, 6), boundaries.items[1].start);
    try std.testing.expectEqual(@as(u32, 12), boundaries.items[1].end);

    // </child>
    try std.testing.expectEqual(@as(u32, 17), boundaries.items[2].start);
    try std.testing.expectEqual(@as(u32, 24), boundaries.items[2].end);

    // </root>
    try std.testing.expectEqual(@as(u32, 25), boundaries.items[3].start);
    try std.testing.expectEqual(@as(u32, 31), boundaries.items[3].end);
}

test "findTagBoundaries - tag with attributes" {
    const gpa = std.testing.allocator;

    const input = "<item id=\"123\" name=\"test\">";

    var boundaries = try findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 26), boundaries.items[0].end);
}

test "findTagBoundaries - self-closing tag" {
    const gpa = std.testing.allocator;

    const input = "<item />";

    var boundaries = try findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 7), boundaries.items[0].end);
}

test "findTagBoundaries - multiple sequential tags" {
    const gpa = std.testing.allocator;

    const input = "<a></a><b></b><c></c>";

    var boundaries = try findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6), boundaries.items.len);

    // Verify they're in correct order
    var prev_end: u32 = 0;
    for (boundaries.items) |boundary| {
        try std.testing.expect(boundary.start >= prev_end);
        try std.testing.expect(boundary.end > boundary.start);
        prev_end = boundary.end;
    }
}

test "findTagBoundaries - empty input" {
    const gpa = std.testing.allocator;

    var boundaries = try findTagBoundaries(gpa, "");
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), boundaries.items.len);
}

test "findTagBoundaries - no tags" {
    const gpa = std.testing.allocator;

    const input = "just plain text with no tags";

    var boundaries = try findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), boundaries.items.len);
}

test "findTagBoundaries - unmatched opening bracket" {
    const gpa = std.testing.allocator;

    const input = "<root"; // No closing >

    try std.testing.expectError(error.MalformedXML, findTagBoundaries(gpa, input));
}

test "findTagBoundaries - unmatched opening bracket followed by self-closing tag" {
    const gpa = std.testing.allocator;

    const input = "<root<item />"; // No closing >

    try std.testing.expectError(error.MalformedXML, findTagBoundaries(gpa, input));
}

test "findTagBoundaries - reversed bracket order" {
    const gpa = std.testing.allocator;

    const input = ">hello<"; // '>' before '<' - malformed

    try std.testing.expectError(error.MalformedXML, findTagBoundaries(gpa, input));
}

test "findTagBoundaries - CGMES-style XML" {
    const gpa = std.testing.allocator;

    const input =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), boundaries.items.len);

    // Verify all boundaries are valid (end > start)
    for (boundaries.items) |boundary| {
        try std.testing.expect(boundary.end > boundary.start);
        try std.testing.expect(input[boundary.start] == '<');
        try std.testing.expect(input[boundary.end] == '>');
    }
}
