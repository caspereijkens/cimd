const std = @import("std");
const assert = std.debug.assert;
const tag_index = @import("tag_index.zig");

test "tag_index.findByteSIMD - finds all angle brackets" {
    const gpa = std.testing.allocator;

    const input = "<a><b></b></a>";

    // Find all '<'
    var lt_positions = try tag_index.findByteSIMD(gpa, input, '<');
    defer lt_positions.deinit(gpa);

    // Expected: positions 0, 3, 6, 10
    try std.testing.expectEqual(@as(usize, 4), lt_positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), lt_positions.items[0]);
    try std.testing.expectEqual(@as(u32, 3), lt_positions.items[1]);
    try std.testing.expectEqual(@as(u32, 6), lt_positions.items[2]);
    try std.testing.expectEqual(@as(u32, 10), lt_positions.items[3]);

    // Find all '>'
    var gt_positions = try tag_index.findByteSIMD(gpa, input, '>');
    defer gt_positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), gt_positions.items.len);
    try std.testing.expectEqual(@as(u32, 2), gt_positions.items[0]);
    try std.testing.expectEqual(@as(u32, 5), gt_positions.items[1]);
    try std.testing.expectEqual(@as(u32, 9), gt_positions.items[2]);
    try std.testing.expectEqual(@as(u32, 13), gt_positions.items[3]);
}

test "tag_index.findByteSIMD - handles empty input" {
    const gpa = std.testing.allocator;

    var positions = try tag_index.findByteSIMD(gpa, "", '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), positions.items.len);
}

test "tag_index.findByteSIMD - handles input with no matches" {
    const gpa = std.testing.allocator;

    var positions = try tag_index.findByteSIMD(gpa, "hello world", '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), positions.items.len);
}

test "tag_index.findByteSIMD - handles large input spanning multiple SIMD vectors" {
    const gpa = std.testing.allocator;

    // Create input larger than tag_index.VECTOR_LEN to test chunking
    var buffer: [128]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<';
    buffer[32] = '<'; // Cross vector boundary
    buffer[64] = '<';
    buffer[127] = '<';

    var positions = try tag_index.findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, 32), positions.items[1]);
    try std.testing.expectEqual(@as(u32, 64), positions.items[2]);
    try std.testing.expectEqual(@as(u32, 127), positions.items[3]);
}

test "tag_index.findByteSIMD - exactly one vector (32 bytes)" {
    const gpa = std.testing.allocator;

    // Exactly tag_index.VECTOR_LEN bytes - tests remaining vectors loop, not unrolled
    var buffer: [tag_index.VECTOR_LEN]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<';
    buffer[16] = '<';
    buffer[31] = '<'; // Last position

    var positions = try tag_index.findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, 16), positions.items[1]);
    try std.testing.expectEqual(@as(u32, 31), positions.items[2]);
}

test "tag_index.findByteSIMD - two full vectors (64 bytes)" {
    const gpa = std.testing.allocator;

    // 2 * tag_index.VECTOR_LEN - tests remaining vectors loop with 2 iterations
    var buffer: [tag_index.VECTOR_LEN * 2]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<';
    buffer[tag_index.VECTOR_LEN] = '<'; // Start of second vector
    buffer[tag_index.VECTOR_LEN + 15] = '<'; // Middle of second vector

    var positions = try tag_index.findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN), positions.items[1]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN + 15), positions.items[2]);
}

test "tag_index.findByteSIMD - three full vectors (96 bytes)" {
    const gpa = std.testing.allocator;

    // 3 * tag_index.VECTOR_LEN - tests remaining vectors loop with 3 iterations
    var buffer: [tag_index.VECTOR_LEN * 3]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[tag_index.VECTOR_LEN * 0] = '<';
    buffer[tag_index.VECTOR_LEN * 1] = '<';
    buffer[tag_index.VECTOR_LEN * 2] = '<';

    var positions = try tag_index.findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN), positions.items[1]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN * 2), positions.items[2]);
}

test "tag_index.findByteSIMD - unrolled loop with remainder" {
    const gpa = std.testing.allocator;

    // 130 bytes = 128 (unrolled) + 2 (scalar remainder)
    const unroll_size = tag_index.VECTOR_LEN * 4;
    var buffer: [unroll_size + 2]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<'; // Unrolled loop
    buffer[unroll_size - 1] = '<'; // End of unrolled loop
    buffer[unroll_size] = '<'; // Scalar remainder
    buffer[unroll_size + 1] = '<'; // Scalar remainder

    var positions = try tag_index.findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, unroll_size - 1), positions.items[1]);
    try std.testing.expectEqual(@as(u32, unroll_size), positions.items[2]);
    try std.testing.expectEqual(@as(u32, unroll_size + 1), positions.items[3]);
}

test "tag_index.findByteSIMD - multiple unrolled iterations" {
    const gpa = std.testing.allocator;

    // 256 bytes = 2 iterations of unrolled loop (2 * 128)
    const unroll_size = tag_index.VECTOR_LEN * 4;
    var buffer: [unroll_size * 2]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<'; // First unrolled iteration
    buffer[unroll_size] = '<'; // Second unrolled iteration
    buffer[unroll_size * 2 - 1] = '<'; // Last byte

    var positions = try tag_index.findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, unroll_size), positions.items[1]);
    try std.testing.expectEqual(@as(u32, unroll_size * 2 - 1), positions.items[2]);
}

test "tag_index.findByteSIMD - dense matches in single vector" {
    const gpa = std.testing.allocator;

    // Test multiple matches within a single SIMD vector (tests bit extraction loop)
    var buffer: [tag_index.VECTOR_LEN]u8 = undefined;
    @memset(&buffer, '<'); // All matches!

    var positions = try tag_index.findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    // Should find all 32 positions
    try std.testing.expectEqual(@as(usize, tag_index.VECTOR_LEN), positions.items.len);
    for (positions.items, 0..) |pos, idx| {
        try std.testing.expectEqual(@as(u32, @intCast(idx)), pos);
    }
}

test "tag_index.findByteSIMD - matches at vector boundaries" {
    const gpa = std.testing.allocator;

    // Test matches at first and last byte of each vector
    const unroll_size = tag_index.VECTOR_LEN * 4;
    var buffer: [unroll_size + 10]u8 = undefined;
    @memset(&buffer, 'x');

    // First and last of each 32-byte vector
    buffer[0] = '<'; // Vector 0, first
    buffer[tag_index.VECTOR_LEN - 1] = '<'; // Vector 0, last
    buffer[tag_index.VECTOR_LEN] = '<'; // Vector 1, first
    buffer[tag_index.VECTOR_LEN * 2 - 1] = '<'; // Vector 1, last
    buffer[unroll_size] = '<'; // First byte of remainder
    buffer[unroll_size + 9] = '<'; // Last byte of remainder

    var positions = try tag_index.findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN - 1), positions.items[1]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN), positions.items[2]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN * 2 - 1), positions.items[3]);
    try std.testing.expectEqual(@as(u32, unroll_size), positions.items[4]);
    try std.testing.expectEqual(@as(u32, unroll_size + 9), positions.items[5]);
}

test "tag_index.findByteSIMD - no matches in SIMD sections but matches in remainder" {
    const gpa = std.testing.allocator;

    // All SIMD vectors have no matches, only remainder has matches
    var buffer: [tag_index.VECTOR_LEN + 5]u8 = undefined;
    @memset(&buffer, 'x');

    // Only matches in scalar remainder
    buffer[tag_index.VECTOR_LEN] = '<';
    buffer[tag_index.VECTOR_LEN + 2] = '<';
    buffer[tag_index.VECTOR_LEN + 4] = '<';

    var positions = try tag_index.findByteSIMD(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN), positions.items[0]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN + 2), positions.items[1]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN + 4), positions.items[2]);
}

// ============================================================================
// Pattern Matching Tests
// ============================================================================

test "tag_index.findPattern - finds rdf:ID with values" {
    const gpa = std.testing.allocator;

    const input =
        \\<cim:Substation rdf:ID="_SubStation1">
        \\<cim:Breaker rdf:ID="_BR1">
    ;

    var matches = try tag_index.findPattern(gpa, input, "rdf:ID=\"");
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

test "tag_index.findPattern - finds rdf:about with # prefix" {
    const gpa = std.testing.allocator;

    const input =
        \\<cim:Terminal rdf:about="#_T1">
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_CN1"/>
        \\</cim:Terminal>
    ;

    var matches = try tag_index.findPattern(gpa, input, "rdf:about=\"");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), matches.items.len);

    const match = matches.items[0];
    const value = input[match.value_start..][0..match.value_len];
    try std.testing.expectEqualStrings("#_T1", value);
}

test "tag_index.findPattern - no matches" {
    const gpa = std.testing.allocator;

    const input = "<root>Hello World</root>";

    var matches = try tag_index.findPattern(gpa, input, "rdf:ID=\"");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "tag_index.findPattern - empty input" {
    const gpa = std.testing.allocator;

    var matches = try tag_index.findPattern(gpa, "", "rdf:ID=\"");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "tag_index.verifyAndExtractPattern - valid pattern with value" {
    const input = "Hello rdf:ID=\"_SubStation1\" World";
    const pattern = "rdf:ID=\"";

    const match = tag_index.verifyAndExtractPattern(input, 6, pattern);

    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(u32, 6), match.?.pattern_start);
    try std.testing.expectEqual(@as(u32, 14), match.?.value_start);
    try std.testing.expectEqual(@as(u32, 12), match.?.value_len);

    const value = input[match.?.value_start..][0..match.?.value_len];
    try std.testing.expectEqualStrings("_SubStation1", value);
}

test "tag_index.verifyAndExtractPattern - empty value" {
    const input = "rdf:ID=\"\"";
    const pattern = "rdf:ID=\"";

    const match = tag_index.verifyAndExtractPattern(input, 0, pattern);

    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(u32, 0), match.?.value_len);
}

test "tag_index.verifyAndExtractPattern - pattern mismatch" {
    const input = "Hello rdf:about=\"value\"";
    const pattern = "rdf:ID=\"";

    const match = tag_index.verifyAndExtractPattern(input, 6, pattern);

    try std.testing.expectEqual(@as(?tag_index.PatternMatch, null), match);
}

test "tag_index.verifyAndExtractPattern - no closing quote" {
    const input = "rdf:ID=\"unclosed";
    const pattern = "rdf:ID=\"";

    const match = tag_index.verifyAndExtractPattern(input, 0, pattern);

    try std.testing.expectEqual(@as(?tag_index.PatternMatch, null), match);
}

test "tag_index.verifyAndExtractPattern - candidate near end of haystack" {
    const input = "rdf:";
    const pattern = "rdf:ID=\"";

    const match = tag_index.verifyAndExtractPattern(input, 0, pattern);

    try std.testing.expectEqual(@as(?tag_index.PatternMatch, null), match);
}

test "tag_index.verifyAndExtractPattern - value with special characters" {
    const input = "rdf:ID=\"#_Node-123.456\"";
    const pattern = "rdf:ID=\"";

    const match = tag_index.verifyAndExtractPattern(input, 0, pattern);

    try std.testing.expect(match != null);
    const value = input[match.?.value_start..][0..match.?.value_len];
    try std.testing.expectEqualStrings("#_Node-123.456", value);
}

test "tag_index.findTagBoundaries - single tag" {
    const gpa = std.testing.allocator;

    const input = "<root>";

    var boundaries = try tag_index.findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 5), boundaries.items[0].end);
}

test "tag_index.findTagBoundaries - opening and closing tags" {
    const gpa = std.testing.allocator;

    const input = "<root></root>";

    var boundaries = try tag_index.findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), boundaries.items.len);

    // <root>
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 5), boundaries.items[0].end);

    // </root>
    try std.testing.expectEqual(@as(u32, 6), boundaries.items[1].start);
    try std.testing.expectEqual(@as(u32, 12), boundaries.items[1].end);
}

test "tag_index.findTagBoundaries - nested tags" {
    const gpa = std.testing.allocator;

    const input = "<root><child>text</child></root>";

    var boundaries = try tag_index.findTagBoundaries(gpa, input);
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

test "tag_index.findTagBoundaries - tag with attributes" {
    const gpa = std.testing.allocator;

    const input = "<item id=\"123\" name=\"test\">";

    var boundaries = try tag_index.findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 26), boundaries.items[0].end);
}

test "tag_index.findTagBoundaries - self-closing tag" {
    const gpa = std.testing.allocator;

    const input = "<item />";

    var boundaries = try tag_index.findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 7), boundaries.items[0].end);
}

test "tag_index.findTagBoundaries - multiple sequential tags" {
    const gpa = std.testing.allocator;

    const input = "<a></a><b></b><c></c>";

    var boundaries = try tag_index.findTagBoundaries(gpa, input);
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

test "tag_index.findTagBoundaries - empty input" {
    const gpa = std.testing.allocator;

    var boundaries = try tag_index.findTagBoundaries(gpa, "");
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), boundaries.items.len);
}

test "tag_index.findTagBoundaries - no tags" {
    const gpa = std.testing.allocator;

    const input = "just plain text with no tags";

    var boundaries = try tag_index.findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), boundaries.items.len);
}

test "tag_index.findTagBoundaries - unmatched opening bracket" {
    const gpa = std.testing.allocator;

    const input = "<root"; // No closing >

    try std.testing.expectError(error.MalformedXML, tag_index.findTagBoundaries(gpa, input));
}

test "tag_index.findTagBoundaries - unmatched opening bracket followed by self-closing tag" {
    const gpa = std.testing.allocator;

    const input = "<root<item />"; // No closing >

    try std.testing.expectError(error.MalformedXML, tag_index.findTagBoundaries(gpa, input));
}

test "tag_index.findTagBoundaries - reversed bracket order" {
    const gpa = std.testing.allocator;

    const input = ">hello<"; // '>' before '<' - malformed

    try std.testing.expectError(error.MalformedXML, tag_index.findTagBoundaries(gpa, input));
}

test "tag_index.findTagBoundaries - CGMES-style XML" {
    const gpa = std.testing.allocator;

    const input =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), boundaries.items.len);

    // Verify all boundaries are valid (end > start)
    for (boundaries.items) |boundary| {
        try std.testing.expect(boundary.end > boundary.start);
        try std.testing.expect(input[boundary.start] == '<');
        try std.testing.expect(input[boundary.end] == '>');
    }
}

test "tag_index.extractTagType - simple tag" {
    const xml = "<cim:Substation rdf:ID=\"_SS1\">";
    const tag_type = try tag_index.extractTagType(xml, 0);
    try std.testing.expectEqualStrings("Substation", tag_type);
}

test "tag_index.extractTagType - with namespace" {
    const xml = "<cim:VoltageLevel>";
    const tag_type = try tag_index.extractTagType(xml, 0);
    try std.testing.expectEqualStrings("VoltageLevel", tag_type);
}

test "tag_index.extractTagType - no namespace (error)" {
    const xml = "<Substation>"; // No colon!
    const result = tag_index.extractTagType(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extractTagType - colon before tag (handles start_index)" {
    const xml = "prefix:data<cim:Substation>";
    const tag_type = try tag_index.extractTagType(xml, 11); // Points to '<'
    try std.testing.expectEqualStrings("Substation", tag_type);
}

test "tag_index.extractRdfId - simple tag" {
    const xml = "<cim:Substation rdf:ID=\"_SS1\">";
    const id = try tag_index.extractRdfId(xml, 0);
    try std.testing.expectEqualStrings("_SS1", id);
}

test "tag_index.extractRdfId - multiple attributes" {
    const xml = "<cim:Substation name=\"test\" rdf:ID=\"_SS1\" other=\"value\">";
    const id = try tag_index.extractRdfId(xml, 0);
    try std.testing.expectEqualStrings("_SS1", id);
}

test "tag_index.extractRdfId - with hash prefix" {
    const xml = "<cim:Terminal rdf:ID=\"#_T1\">";
    const id = try tag_index.extractRdfId(xml, 0);
    try std.testing.expectEqualStrings("#_T1", id);
}

test "tag_index.extractRdfId - self-closing tag" {
    const xml = "<cim:Line rdf:ID=\"_L1\"/>";
    const id = try tag_index.extractRdfId(xml, 0);
    try std.testing.expectEqualStrings("_L1", id);
}

test "tag_index.extractRdfId - long ID" {
    const xml = "<cim:Substation rdf:ID=\"_Very_Long_Substation_Identifier_12345\">";
    const id = try tag_index.extractRdfId(xml, 0);
    try std.testing.expectEqualStrings("_Very_Long_Substation_Identifier_12345", id);
}

test "tag_index.extractRdfId - no rdf:ID (error)" {
    const xml = "<cim:Substation name=\"test\">";
    const result = tag_index.extractRdfId(xml, 0);
    try std.testing.expectError(error.NoRdfId, result);
}

test "tag_index.extractRdfId - malformed (no closing quote)" {
    const xml = "<cim:Substation rdf:ID=\"_SS1>";
    const result = tag_index.extractRdfId(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extractRdfId - start_index in middle of document" {
    const xml = "some prefix text <cim:Substation rdf:ID=\"_SS1\"> more text";
    const id = try tag_index.extractRdfId(xml, 17); // Points to '<' at position 17
    try std.testing.expectEqualStrings("_SS1", id);
}

test "tag_index.extractRdfId - empty value" {
    const xml = "<cim:Substation rdf:ID=\"\"/>";
    const id = try tag_index.extractRdfId(xml, 0);
    try std.testing.expectEqualStrings("", id);
}

test "tag_index.extractRdfId - has 'r' but no rdf:ID pattern" {
    const xml = "<cim:Substation random=\"test\">";
    const result = tag_index.extractRdfId(xml, 0);
    try std.testing.expectError(error.NoRdfId, result);
}

test "tag_index.extractRdfId - pattern appears after tag close" {
    const xml = "<cim:Substation> rdf:ID=\"_SS1\"";
    const result = tag_index.extractRdfId(xml, 0);
    try std.testing.expectError(error.NoRdfId, result);
}

test "tag_index.extractRdfId - closing quote missing (no quote at all)" {
    const xml = "<cim:Substation rdf:ID=\"_SS1>";
    const result = tag_index.extractRdfId(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extractRdfId - closing quote after tag boundary" {
    const xml = "<cim:Substation rdf:ID=\"_SS1> later text \"";
    const result = tag_index.extractRdfId(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extractRdfId - rdf:ID at end of tag with space" {
    const xml = "<cim:Substation name=\"test\" rdf:ID=\"_SS1\" >";
    const id = try tag_index.extractRdfId(xml, 0);
    try std.testing.expectEqualStrings("_SS1", id);
}

test "tag_index.extractRdfId - multiple 'r' characters before pattern" {
    const xml = "<cim:Substation region=\"west\" resource=\"power\" rdf:ID=\"_SS1\">";
    const id = try tag_index.extractRdfId(xml, 0);
    try std.testing.expectEqualStrings("_SS1", id);
}

test "tag_index.extractRdfId - pattern lookalike (rdf:resource not rdf:ID)" {
    const xml = "<cim:Terminal rdf:resource=\"#_CN1\">";
    const result = tag_index.extractRdfId(xml, 0);
    try std.testing.expectError(error.NoRdfId, result);
}

test "tag_index.extractRdfId - value contains equals sign" {
    const xml = "<cim:Equation rdf:ID=\"x=y+z\">";
    const id = try tag_index.extractRdfId(xml, 0);
    try std.testing.expectEqualStrings("x=y+z", id);
}

test "tag_index.extractRdfId - value contains angle brackets (invalid XML)" {
    // Angle brackets in attribute values are invalid XML
    // Must be escaped as &lt; and &gt;
    const xml = "<cim:Formula rdf:ID=\"a<b>c\">";
    const result = tag_index.extractRdfId(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extractRdfId - no tag close bracket" {
    const xml = "<cim:Substation rdf:ID=\"_SS1\"";
    const result = tag_index.extractRdfId(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

// ============================================================================
// extractRdfResource Tests
// ============================================================================

test "tag_index.extractRdfResource - simple resource extraction" {
    const xml = "<cim:Substation.Region rdf:resource=\"#_Region1\"/>";
    const resource = try tag_index.extractRdfResource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Region1", resource.?);
}

test "tag_index.extractRdfResource - multiple attributes" {
    const xml = "<cim:Terminal name=\"test\" rdf:resource=\"#_T1\" other=\"value\"/>";
    const resource = try tag_index.extractRdfResource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_T1", resource.?);
}

test "tag_index.extractRdfResource - with hash prefix" {
    const xml = "<cim:Property rdf:resource=\"#_LocalRef\"/>";
    const resource = try tag_index.extractRdfResource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_LocalRef", resource.?);
}

test "tag_index.extractRdfResource - without hash prefix" {
    const xml = "<cim:Property rdf:resource=\"_ExternalRef\"/>";
    const resource = try tag_index.extractRdfResource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("_ExternalRef", resource.?);
}

test "tag_index.extractRdfResource - non-self-closing tag" {
    const xml = "<cim:Property rdf:resource=\"#_Ref1\"></cim:Property>";
    const resource = try tag_index.extractRdfResource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Ref1", resource.?);
}

test "tag_index.extractRdfResource - empty value" {
    const xml = "<cim:Property rdf:resource=\"\"/>";
    const resource = try tag_index.extractRdfResource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("", resource.?);
}

test "tag_index.extractRdfResource - no rdf:resource returns null" {
    const xml = "<cim:Substation name=\"test\"/>";
    const resource = try tag_index.extractRdfResource(xml, 0);
    try std.testing.expectEqual(@as(?[]const u8, null), resource);
}

test "tag_index.extractRdfResource - full URI" {
    const xml = "<cim:Property rdf:resource=\"http://example.com/resource#_R1\"/>";
    const resource = try tag_index.extractRdfResource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("http://example.com/resource#_R1", resource.?);
}

test "tag_index.extractRdfResource - special characters in value" {
    const xml = "<cim:Property rdf:resource=\"#_Node-123.456_v2\"/>";
    const resource = try tag_index.extractRdfResource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Node-123.456_v2", resource.?);
}

test "tag_index.extractRdfResource - malformed (no closing quote)" {
    const xml = "<cim:Property rdf:resource=\"#_Ref1/>";
    const result = tag_index.extractRdfResource(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extractRdfResource - closing quote after tag boundary" {
    const xml = "<cim:Property rdf:resource=\"#_Ref1> later text \"";
    const result = tag_index.extractRdfResource(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extractRdfResource - pattern appears after tag close" {
    const xml = "<cim:Property> rdf:resource=\"#_Ref1\"";
    const resource = try tag_index.extractRdfResource(xml, 0);
    try std.testing.expectEqual(@as(?[]const u8, null), resource);
}

test "tag_index.extractRdfResource - no tag close bracket" {
    const xml = "<cim:Property rdf:resource=\"#_Ref1\"";
    const result = tag_index.extractRdfResource(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extractRdfResource - start_index in middle of document" {
    const xml = "prefix text <cim:Property rdf:resource=\"#_Ref1\"/> more text";
    const resource = try tag_index.extractRdfResource(xml, 12);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Ref1", resource.?);
}

test "tag_index.extractRdfResource - rdf:resource at end of tag" {
    const xml = "<cim:Property name=\"test\" other=\"value\" rdf:resource=\"#_Ref1\" />";
    const resource = try tag_index.extractRdfResource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Ref1", resource.?);
}

test "tag_index.extractRdfResource - value contains equals sign" {
    const xml = "<cim:Property rdf:resource=\"x=y+z\"/>";
    const resource = try tag_index.extractRdfResource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("x=y+z", resource.?);
}

test "tag_index.findClosingTag - simple opening and closing tag" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Root></cim:Root>";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing_idx = try tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 1), closing_idx);
}

test "tag_index.findClosingTag - tag with text content" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Name>North Station</cim:Name>";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing_idx = try tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 1), closing_idx);
}

test "tag_index.findClosingTag - nested different tags" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Root><cim:Child>text</cim:Child></cim:Root>";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Find closing tag for Root (index 0) -> should be index 3
    const root_closing = try tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 3), root_closing);

    // Find closing tag for Child (index 1) -> should be index 2
    const child_closing = try tag_index.findClosingTag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 2), child_closing);
}

test "tag_index.findClosingTag - nested same-name tags (depth counting)" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Item><cim:Item></cim:Item></cim:Item>";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Find closing tag for outer Item (index 0) -> should be index 3
    const outer_closing = try tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 3), outer_closing);

    // Find closing tag for inner Item (index 1) -> should be index 2
    const inner_closing = try tag_index.findClosingTag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 2), inner_closing);
}

test "tag_index.findClosingTag - deeply nested same-name tags" {
    const gpa = std.testing.allocator;

    const xml = "<ns:a><ns:a><ns:a></ns:a></ns:a></ns:a>";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Outermost (index 0) -> closing at index 5
    const outer = try tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 5), outer);

    // Middle (index 1) -> closing at index 4
    const middle = try tag_index.findClosingTag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 4), middle);

    // Innermost (index 2) -> closing at index 3
    const inner = try tag_index.findClosingTag(xml, boundaries.items, 2);
    try std.testing.expectEqual(@as(u32, 3), inner);
}

test "tag_index.findClosingTag - CGMES example with properties" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  <cim:Substation.Region rdf:resource="#_R1"/>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Find closing for Substation (index 0) -> should be last tag (index 4)
    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 4), closing);

    // Find closing for IdentifiedObject.name (index 1) -> should be index 2
    const name_closing = try tag_index.findClosingTag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 2), name_closing);
}

test "tag_index.findClosingTag - self-closing tag returns error" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Terminal rdf:resource=\"#_T1\"/>";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const result = tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectError(error.SelfClosingTag, result);
}

test "tag_index.findClosingTag - self-closing tag with space before slash" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Item />";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const result = tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectError(error.SelfClosingTag, result);
}

test "tag_index.findClosingTag - no closing tag (error)" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Root><cim:Child></cim:Child>"; // Root not closed

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const result = tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectError(error.NoClosingTag, result);
}

test "tag_index.findClosingTag - multiple same-name tags at same level" {
    const gpa = std.testing.allocator;

    const xml = "<ns:root><ns:item>1</ns:item><ns:item>2</ns:item></ns:root>";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // First item (index 1) -> closes at index 2
    const first_item = try tag_index.findClosingTag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 2), first_item);

    // Second item (index 3) -> closes at index 4
    const second_item = try tag_index.findClosingTag(xml, boundaries.items, 3);
    try std.testing.expectEqual(@as(u32, 4), second_item);

    // Root (index 0) -> closes at index 5
    const root = try tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 5), root);
}

test "tag_index.findClosingTag - mixed self-closing and normal tags" {
    const gpa = std.testing.allocator;

    const xml = "<ns:root><ns:item/><ns:child>text</ns:child></ns:root>";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Root (index 0) -> closes at index 4 (self-closing item at index 1 doesn't affect depth)
    const root_closing = try tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 4), root_closing);

    // Child (index 2) -> closes at index 3
    const child_closing = try tag_index.findClosingTag(xml, boundaries.items, 2);
    try std.testing.expectEqual(@as(u32, 3), child_closing);

    // Item is self-closing
    const item_result = tag_index.findClosingTag(xml, boundaries.items, 1);
    try std.testing.expectError(error.SelfClosingTag, item_result);
}

test "tag_index.findClosingTag - tag with attributes" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_SS1\" name=\"test\"></cim:Substation>";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 1), closing);
}

test "tag_index.findClosingTag - empty tag" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Value></cim:Value>";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 1), closing);
}

test "tag_index.getProperty - simple property with text content" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Substation: opening at 0, closing at 3
    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 3), closing);

    // Get the "IdentifiedObject.name" property
    const value = try tag_index.getProperty(xml, boundaries.items, 0, closing, "IdentifiedObject.name");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("North Station", value.?);
}

test "tag_index.getProperty - property not found returns null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    // Request property that doesn't exist
    const value = try tag_index.getProperty(xml, boundaries.items, 0, closing, "NonExistent.property");
    try std.testing.expectEqual(@as(?[]const u8, null), value);
}

test "tag_index.getProperty - empty property value" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.name></cim:Property.name>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const value = try tag_index.getProperty(xml, boundaries.items, 0, closing, "Property.name");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("", value.?);
}

test "tag_index.getProperty - multiple properties, find specific one" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  <cim:IdentifiedObject.description>Main substation</cim:IdentifiedObject.description>
        \\  <cim:Substation.Region rdf:resource="#_R1"/>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    // Get first property
    const name = try tag_index.getProperty(xml, boundaries.items, 0, closing, "IdentifiedObject.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("North Station", name.?);

    // Get second property
    const desc = try tag_index.getProperty(xml, boundaries.items, 0, closing, "IdentifiedObject.description");
    try std.testing.expect(desc != null);
    try std.testing.expectEqualStrings("Main substation", desc.?);
}

test "tag_index.getProperty - self-closing property tag returns null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:Substation.Region rdf:resource="#_R1"/>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    // Self-closing tag has no text content
    const value = try tag_index.getProperty(xml, boundaries.items, 0, closing, "Substation.Region");
    try std.testing.expectEqual(@as(?[]const u8, null), value);
}

test "tag_index.getProperty - property with whitespace preserved" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.value>  Leading and trailing spaces  </cim:Property.value>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const value = try tag_index.getProperty(xml, boundaries.items, 0, closing, "Property.value");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("  Leading and trailing spaces  ", value.?);
}

test "tag_index.getProperty - property name must match exactly" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.name>Value</cim:Property.name>
        \\  <cim:Property.nameExtra>Other</cim:Property.nameExtra>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    // Should find exact match "Property.name", not "Property.nameExtra"
    const value = try tag_index.getProperty(xml, boundaries.items, 0, closing, "Property.name");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("Value", value.?);

    // Should NOT match partial "Property.name" when looking for "Property.nameExtra"
    const value2 = try tag_index.getProperty(xml, boundaries.items, 0, closing, "Property.nameExtra");
    try std.testing.expect(value2 != null);
    try std.testing.expectEqualStrings("Other", value2.?);
}

test "tag_index.getProperty - property with special characters" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.value>Value with &lt;special&gt; chars &amp; symbols</cim:Property.value>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const value = try tag_index.getProperty(xml, boundaries.items, 0, closing, "Property.value");
    try std.testing.expect(value != null);
    // Note: We return raw XML content, not decoded entities
    try std.testing.expectEqualStrings("Value with &lt;special&gt; chars &amp; symbols", value.?);
}

test "tag_index.getProperty - multiple same-name properties returns first" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.value>First</cim:Property.value>
        \\  <cim:Property.value>Second</cim:Property.value>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    // Should return first occurrence
    const value = try tag_index.getProperty(xml, boundaries.items, 0, closing, "Property.value");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("First", value.?);
}

test "tag_index.getProperty - property with numeric value" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:VoltageLevel>
        \\  <cim:VoltageLevel.nominalV>380.0</cim:VoltageLevel.nominalV>
        \\</cim:VoltageLevel>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const value = try tag_index.getProperty(xml, boundaries.items, 0, closing, "VoltageLevel.nominalV");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("380.0", value.?);
}

test "tag_index.getProperty - no properties in object" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Object></cim:Object>";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const value = try tag_index.getProperty(xml, boundaries.items, 0, closing, "Any.property");
    try std.testing.expectEqual(@as(?[]const u8, null), value);
}

test "tag_index.getProperty - nested object doesn't interfere" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Outer>
        \\  <cim:Outer.property>OuterValue</cim:Outer.property>
        \\  <cim:Inner>
        \\    <cim:Inner.property>InnerValue</cim:Inner.property>
        \\  </cim:Inner>
        \\</cim:Outer>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const outer_closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    // Getting property from Outer should find its own property, not nested one
    const value = try tag_index.getProperty(xml, boundaries.items, 0, outer_closing, "Outer.property");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("OuterValue", value.?);
}

test "tag_index.getProperty - property with newlines and indentation" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.text>
        \\    Multi-line
        \\    content
        \\  </cim:Property.text>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const value = try tag_index.getProperty(xml, boundaries.items, 0, closing, "Property.text");
    try std.testing.expect(value != null);
    // Should preserve all whitespace including newlines
    try std.testing.expect(std.mem.indexOf(u8, value.?, "Multi-line") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.?, "content") != null);
}

test "tag_index.getProperty - self-closing tag before target property" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation>
        \\  <cim:Region rdf:resource="#_R1"/>
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    // Should skip self-closing Region and find name
    const value = try tag_index.getProperty(xml, boundaries.items, 0, closing, "IdentifiedObject.name");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("North Station", value.?);
}

test "tag_index.getReference - simple reference extraction" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:Substation.Region rdf:resource="#_Region1"/>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const ref = try tag_index.getReference(xml, boundaries.items, 0, closing, "Substation.Region");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_Region1", ref.?);
}

test "tag_index.getReference - reference not found returns null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:Substation.Region rdf:resource="#_Region1"/>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const ref = try tag_index.getReference(xml, boundaries.items, 0, closing, "NonExistent.property");
    try std.testing.expectEqual(@as(?[]const u8, null), ref);
}

test "tag_index.getReference - property exists but no rdf:resource" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation>
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    // Property exists but has text content, not rdf:resource
    const ref = try tag_index.getReference(xml, boundaries.items, 0, closing, "IdentifiedObject.name");
    try std.testing.expectEqual(@as(?[]const u8, null), ref);
}

test "tag_index.getReference - multiple properties find specific reference" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_CN1"/>
        \\  <cim:Terminal.ConductingEquipment rdf:resource="#_CE1"/>
        \\  <cim:IdentifiedObject.name>Terminal 1</cim:IdentifiedObject.name>
        \\</cim:Terminal>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    // Get first reference
    const cn = try tag_index.getReference(xml, boundaries.items, 0, closing, "Terminal.ConnectivityNode");
    try std.testing.expect(cn != null);
    try std.testing.expectEqualStrings("#_CN1", cn.?);

    // Get second reference
    const ce = try tag_index.getReference(xml, boundaries.items, 0, closing, "Terminal.ConductingEquipment");
    try std.testing.expect(ce != null);
    try std.testing.expectEqualStrings("#_CE1", ce.?);
}

test "tag_index.getReference - reference with hash prefix" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_LocalRef"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const ref = try tag_index.getReference(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_LocalRef", ref.?);
}

test "tag_index.getReference - reference without hash prefix" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="_ExternalRef"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const ref = try tag_index.getReference(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("_ExternalRef", ref.?);
}

test "tag_index.getReference - empty reference value" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource=""/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const ref = try tag_index.getReference(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("", ref.?);
}

test "tag_index.getReference - reference with URI" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="http://example.com/resource#_R1"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const ref = try tag_index.getReference(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("http://example.com/resource#_R1", ref.?);
}

test "tag_index.getReference - reference with special characters" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_Node-123.456_v2"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const ref = try tag_index.getReference(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_Node-123.456_v2", ref.?);
}

test "tag_index.getReference - multiple same-name properties returns first" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_First"/>
        \\  <cim:Property.ref rdf:resource="#_Second"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const ref = try tag_index.getReference(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_First", ref.?);
}

test "tag_index.getReference - property name must match exactly" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_Ref1"/>
        \\  <cim:Property.refExtra rdf:resource="#_Ref2"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const ref1 = try tag_index.getReference(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref1 != null);
    try std.testing.expectEqualStrings("#_Ref1", ref1.?);

    const ref2 = try tag_index.getReference(xml, boundaries.items, 0, closing, "Property.refExtra");
    try std.testing.expect(ref2 != null);
    try std.testing.expectEqualStrings("#_Ref2", ref2.?);
}

test "tag_index.getReference - no properties in object" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Object></cim:Object>";

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const ref = try tag_index.getReference(xml, boundaries.items, 0, closing, "Any.property");
    try std.testing.expectEqual(@as(?[]const u8, null), ref);
}

test "tag_index.getReference - nested object doesn't interfere" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Outer>
        \\  <cim:Outer.ref rdf:resource="#_OuterRef"/>
        \\  <cim:Inner>
        \\    <cim:Inner.ref rdf:resource="#_InnerRef"/>
        \\  </cim:Inner>
        \\</cim:Outer>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const outer_closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    // Getting reference from Outer should find its own reference
    const ref = try tag_index.getReference(xml, boundaries.items, 0, outer_closing, "Outer.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_OuterRef", ref.?);
}

test "tag_index.getReference - non-self-closing tag with rdf:resource" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_Ref1"></cim:Property.ref>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    // Should still extract rdf:resource even if tag is not self-closing
    const ref = try tag_index.getReference(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_Ref1", ref.?);
}

test "tag_index.getReference - rdf:resource with other attributes" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref name="test" rdf:resource="#_Ref1" other="value"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.findTagBoundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.findClosingTag(xml, boundaries.items, 0);

    const ref = try tag_index.getReference(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_Ref1", ref.?);
}
