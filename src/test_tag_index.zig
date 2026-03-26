const std = @import("std");
const assert = std.debug.assert;
const tag_index = @import("tag_index.zig");
const CimObject = tag_index.CimObject;

test "tag_index.find_byte_simd - finds all angle brackets" {
    const gpa = std.testing.allocator;

    const input = "<a><b></b></a>";

    // Find all '<'
    var lt_positions = try tag_index.find_byte_simd(gpa, input, '<');
    defer lt_positions.deinit(gpa);

    // Expected: positions 0, 3, 6, 10
    try std.testing.expectEqual(@as(usize, 4), lt_positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), lt_positions.items[0]);
    try std.testing.expectEqual(@as(u32, 3), lt_positions.items[1]);
    try std.testing.expectEqual(@as(u32, 6), lt_positions.items[2]);
    try std.testing.expectEqual(@as(u32, 10), lt_positions.items[3]);

    // Find all '>'
    var gt_positions = try tag_index.find_byte_simd(gpa, input, '>');
    defer gt_positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), gt_positions.items.len);
    try std.testing.expectEqual(@as(u32, 2), gt_positions.items[0]);
    try std.testing.expectEqual(@as(u32, 5), gt_positions.items[1]);
    try std.testing.expectEqual(@as(u32, 9), gt_positions.items[2]);
    try std.testing.expectEqual(@as(u32, 13), gt_positions.items[3]);
}

test "tag_index.find_byte_simd - handles empty input" {
    const gpa = std.testing.allocator;

    var positions = try tag_index.find_byte_simd(gpa, "", '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), positions.items.len);
}

test "tag_index.find_byte_simd - handles input with no matches" {
    const gpa = std.testing.allocator;

    var positions = try tag_index.find_byte_simd(gpa, "hello world", '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), positions.items.len);
}

test "tag_index.find_byte_simd - handles large input spanning multiple SIMD vectors" {
    const gpa = std.testing.allocator;

    // Create input larger than tag_index.VECTOR_LEN to test chunking
    var buffer: [128]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<';
    buffer[32] = '<'; // Cross vector boundary
    buffer[64] = '<';
    buffer[127] = '<';

    var positions = try tag_index.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, 32), positions.items[1]);
    try std.testing.expectEqual(@as(u32, 64), positions.items[2]);
    try std.testing.expectEqual(@as(u32, 127), positions.items[3]);
}

test "tag_index.find_byte_simd - exactly one vector (VECTOR_LEN bytes)" {
    const gpa = std.testing.allocator;

    // Exactly tag_index.VECTOR_LEN bytes - tests remaining vectors loop, not unrolled
    var buffer: [tag_index.VECTOR_LEN]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<';
    buffer[tag_index.VECTOR_LEN / 2] = '<';
    buffer[tag_index.VECTOR_LEN - 1] = '<'; // Last position

    var positions = try tag_index.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN / 2), positions.items[1]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN - 1), positions.items[2]);
}

test "tag_index.find_byte_simd - two full vectors (64 bytes)" {
    const gpa = std.testing.allocator;

    // 2 * tag_index.VECTOR_LEN - tests remaining vectors loop with 2 iterations
    var buffer: [tag_index.VECTOR_LEN * 2]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<';
    buffer[tag_index.VECTOR_LEN] = '<'; // Start of second vector
    buffer[tag_index.VECTOR_LEN + 15] = '<'; // Middle of second vector

    var positions = try tag_index.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN), positions.items[1]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN + 15), positions.items[2]);
}

test "tag_index.find_byte_simd - three full vectors (96 bytes)" {
    const gpa = std.testing.allocator;

    // 3 * tag_index.VECTOR_LEN - tests remaining vectors loop with 3 iterations
    var buffer: [tag_index.VECTOR_LEN * 3]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[tag_index.VECTOR_LEN * 0] = '<';
    buffer[tag_index.VECTOR_LEN * 1] = '<';
    buffer[tag_index.VECTOR_LEN * 2] = '<';

    var positions = try tag_index.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN), positions.items[1]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN * 2), positions.items[2]);
}

test "tag_index.find_byte_simd - unrolled loop with remainder" {
    const gpa = std.testing.allocator;

    // 130 bytes = 128 (unrolled) + 2 (scalar remainder)
    const unroll_size = tag_index.VECTOR_LEN * 4;
    var buffer: [unroll_size + 2]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<'; // Unrolled loop
    buffer[unroll_size - 1] = '<'; // End of unrolled loop
    buffer[unroll_size] = '<'; // Scalar remainder
    buffer[unroll_size + 1] = '<'; // Scalar remainder

    var positions = try tag_index.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, unroll_size - 1), positions.items[1]);
    try std.testing.expectEqual(@as(u32, unroll_size), positions.items[2]);
    try std.testing.expectEqual(@as(u32, unroll_size + 1), positions.items[3]);
}

test "tag_index.find_byte_simd - multiple unrolled iterations" {
    const gpa = std.testing.allocator;

    // 256 bytes = 2 iterations of unrolled loop (2 * 128)
    const unroll_size = tag_index.VECTOR_LEN * 4;
    var buffer: [unroll_size * 2]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<'; // First unrolled iteration
    buffer[unroll_size] = '<'; // Second unrolled iteration
    buffer[unroll_size * 2 - 1] = '<'; // Last byte

    var positions = try tag_index.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, unroll_size), positions.items[1]);
    try std.testing.expectEqual(@as(u32, unroll_size * 2 - 1), positions.items[2]);
}

test "tag_index.find_byte_simd - dense matches in single vector" {
    const gpa = std.testing.allocator;

    // Test multiple matches within a single SIMD vector (tests bit extraction loop)
    var buffer: [tag_index.VECTOR_LEN]u8 = undefined;
    @memset(&buffer, '<'); // All matches!

    var positions = try tag_index.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    // Should find all 32 positions
    try std.testing.expectEqual(@as(usize, tag_index.VECTOR_LEN), positions.items.len);
    for (positions.items, 0..) |pos, idx| {
        try std.testing.expectEqual(@as(u32, @intCast(idx)), pos);
    }
}

test "tag_index.find_byte_simd - matches at vector boundaries" {
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

    var positions = try tag_index.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN - 1), positions.items[1]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN), positions.items[2]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN * 2 - 1), positions.items[3]);
    try std.testing.expectEqual(@as(u32, unroll_size), positions.items[4]);
    try std.testing.expectEqual(@as(u32, unroll_size + 9), positions.items[5]);
}

test "tag_index.find_byte_simd - no matches in SIMD sections but matches in remainder" {
    const gpa = std.testing.allocator;

    // All SIMD vectors have no matches, only remainder has matches
    var buffer: [tag_index.VECTOR_LEN + 5]u8 = undefined;
    @memset(&buffer, 'x');

    // Only matches in scalar remainder
    buffer[tag_index.VECTOR_LEN] = '<';
    buffer[tag_index.VECTOR_LEN + 2] = '<';
    buffer[tag_index.VECTOR_LEN + 4] = '<';

    var positions = try tag_index.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN), positions.items[0]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN + 2), positions.items[1]);
    try std.testing.expectEqual(@as(u32, tag_index.VECTOR_LEN + 4), positions.items[2]);
}

// ============================================================================
// Pattern Matching Tests
// ============================================================================

test "tag_index.find_pattern - finds rdf:ID with values" {
    const gpa = std.testing.allocator;

    const input =
        \\<cim:Substation rdf:ID="_SubStation1">
        \\<cim:Breaker rdf:ID="_BR1">
    ;

    var matches = try tag_index.find_pattern(gpa, input, "rdf:ID=\"");
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

test "tag_index.find_pattern - finds rdf:about with # prefix" {
    const gpa = std.testing.allocator;

    const input =
        \\<cim:Terminal rdf:about="#_T1">
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_CN1"/>
        \\</cim:Terminal>
    ;

    var matches = try tag_index.find_pattern(gpa, input, "rdf:about=\"");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), matches.items.len);

    const match = matches.items[0];
    const value = input[match.value_start..][0..match.value_len];
    try std.testing.expectEqualStrings("#_T1", value);
}

test "tag_index.find_pattern - no matches" {
    const gpa = std.testing.allocator;

    const input = "<root>Hello World</root>";

    var matches = try tag_index.find_pattern(gpa, input, "rdf:ID=\"");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "tag_index.find_pattern - empty input" {
    const gpa = std.testing.allocator;

    var matches = try tag_index.find_pattern(gpa, "", "rdf:ID=\"");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "tag_index.verify_and_extract_pattern - valid pattern with value" {
    const input = "Hello rdf:ID=\"_SubStation1\" World";
    const pattern = "rdf:ID=\"";

    const match = tag_index.verify_and_extract_pattern(input, 6, pattern);

    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(u32, 6), match.?.pattern_start);
    try std.testing.expectEqual(@as(u32, 14), match.?.value_start);
    try std.testing.expectEqual(@as(u32, 12), match.?.value_len);

    const value = input[match.?.value_start..][0..match.?.value_len];
    try std.testing.expectEqualStrings("_SubStation1", value);
}

test "tag_index.verify_and_extract_pattern - empty value" {
    const input = "rdf:ID=\"\"";
    const pattern = "rdf:ID=\"";

    const match = tag_index.verify_and_extract_pattern(input, 0, pattern);

    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(u32, 0), match.?.value_len);
}

test "tag_index.verify_and_extract_pattern - pattern mismatch" {
    const input = "Hello rdf:about=\"value\"";
    const pattern = "rdf:ID=\"";

    const match = tag_index.verify_and_extract_pattern(input, 6, pattern);

    try std.testing.expectEqual(@as(?tag_index.PatternMatch, null), match);
}

test "tag_index.verify_and_extract_pattern - no closing quote" {
    const input = "rdf:ID=\"unclosed";
    const pattern = "rdf:ID=\"";

    const match = tag_index.verify_and_extract_pattern(input, 0, pattern);

    try std.testing.expectEqual(@as(?tag_index.PatternMatch, null), match);
}

test "tag_index.verify_and_extract_pattern - candidate near end of haystack" {
    const input = "rdf:";
    const pattern = "rdf:ID=\"";

    const match = tag_index.verify_and_extract_pattern(input, 0, pattern);

    try std.testing.expectEqual(@as(?tag_index.PatternMatch, null), match);
}

test "tag_index.verify_and_extract_pattern - value with special characters" {
    const input = "rdf:ID=\"#_Node-123.456\"";
    const pattern = "rdf:ID=\"";

    const match = tag_index.verify_and_extract_pattern(input, 0, pattern);

    try std.testing.expect(match != null);
    const value = input[match.?.value_start..][0..match.?.value_len];
    try std.testing.expectEqualStrings("#_Node-123.456", value);
}

test "tag_index.find_tag_boundaries - single tag" {
    const gpa = std.testing.allocator;

    const input = "<root>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 5), boundaries.items[0].end);
}

test "tag_index.find_tag_boundaries - opening and closing tags" {
    const gpa = std.testing.allocator;

    const input = "<root></root>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), boundaries.items.len);

    // <root>
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 5), boundaries.items[0].end);

    // </root>
    try std.testing.expectEqual(@as(u32, 6), boundaries.items[1].start);
    try std.testing.expectEqual(@as(u32, 12), boundaries.items[1].end);
}

test "tag_index.find_tag_boundaries - nested tags" {
    const gpa = std.testing.allocator;

    const input = "<root><child>text</child></root>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, input);
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

test "tag_index.find_tag_boundaries - tag with attributes" {
    const gpa = std.testing.allocator;

    const input = "<item id=\"123\" name=\"test\">";

    var boundaries = try tag_index.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 26), boundaries.items[0].end);
}

test "tag_index.find_tag_boundaries - self-closing tag" {
    const gpa = std.testing.allocator;

    const input = "<item />";

    var boundaries = try tag_index.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 7), boundaries.items[0].end);
}

test "tag_index.find_tag_boundaries - multiple sequential tags" {
    const gpa = std.testing.allocator;

    const input = "<a></a><b></b><c></c>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, input);
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

test "tag_index.find_tag_boundaries - empty input" {
    const gpa = std.testing.allocator;

    var boundaries = try tag_index.find_tag_boundaries(gpa, "");
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), boundaries.items.len);
}

test "tag_index.find_tag_boundaries - no tags" {
    const gpa = std.testing.allocator;

    const input = "just plain text with no tags";

    var boundaries = try tag_index.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), boundaries.items.len);
}

test "tag_index.find_tag_boundaries - unmatched opening bracket" {
    const gpa = std.testing.allocator;

    const input = "<root"; // No closing >

    try std.testing.expectError(error.MalformedXML, tag_index.find_tag_boundaries(gpa, input));
}

test "tag_index.find_tag_boundaries - unmatched opening bracket followed by self-closing tag" {
    const gpa = std.testing.allocator;

    const input = "<root<item />"; // No closing >

    try std.testing.expectError(error.MalformedXML, tag_index.find_tag_boundaries(gpa, input));
}

test "tag_index.find_tag_boundaries - reversed bracket order" {
    const gpa = std.testing.allocator;

    const input = ">hello<"; // '>' before '<' - malformed

    try std.testing.expectError(error.MalformedXML, tag_index.find_tag_boundaries(gpa, input));
}

test "tag_index.find_tag_boundaries - CGMES-style XML" {
    const gpa = std.testing.allocator;

    const input =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), boundaries.items.len);

    // Verify all boundaries are valid (end > start)
    for (boundaries.items) |boundary| {
        try std.testing.expect(boundary.end > boundary.start);
        try std.testing.expect(input[boundary.start] == '<');
        try std.testing.expect(input[boundary.end] == '>');
    }
}

test "tag_index.extract_tag_type - simple tag" {
    const xml = "<cim:Substation rdf:ID=\"_SS1\">";
    const tag_type = try tag_index.extract_tag_type(xml, 0);
    try std.testing.expectEqualStrings("Substation", tag_type);
}

test "tag_index.extract_tag_type - with namespace" {
    const xml = "<cim:VoltageLevel>";
    const tag_type = try tag_index.extract_tag_type(xml, 0);
    try std.testing.expectEqualStrings("VoltageLevel", tag_type);
}

test "tag_index.extract_tag_type - no namespace (error)" {
    const xml = "<Substation>"; // No colon!
    const result = tag_index.extract_tag_type(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extract_tag_type - colon before tag (handles start_index)" {
    const xml = "prefix:data<cim:Substation>";
    const tag_type = try tag_index.extract_tag_type(xml, 11); // Points to '<'
    try std.testing.expectEqualStrings("Substation", tag_type);
}

test "tag_index.extract_rdf_id - simple tag" {
    const xml = "<cim:Substation rdf:ID=\"_SS1\">";
    const id = try tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("_SS1", id);
}

test "tag_index.extract_rdf_id - multiple attributes" {
    const xml = "<cim:Substation name=\"test\" rdf:ID=\"_SS1\" other=\"value\">";
    const id = try tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("_SS1", id);
}

test "tag_index.extract_rdf_id - with hash prefix" {
    const xml = "<cim:Terminal rdf:ID=\"#_T1\">";
    const id = try tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("#_T1", id);
}

test "tag_index.extract_rdf_id - self-closing tag" {
    const xml = "<cim:Line rdf:ID=\"_L1\"/>";
    const id = try tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("_L1", id);
}

test "tag_index.extract_rdf_id - long ID" {
    const xml = "<cim:Substation rdf:ID=\"_Very_Long_Substation_Identifier_12345\">";
    const id = try tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("_Very_Long_Substation_Identifier_12345", id);
}

test "tag_index.extract_rdf_id - no rdf:ID (error)" {
    const xml = "<cim:Substation name=\"test\">";
    const result = tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.NoRdfId, result);
}

test "tag_index.extract_rdf_id - malformed (no closing quote)" {
    const xml = "<cim:Substation rdf:ID=\"_SS1>";
    const result = tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extract_rdf_id - start_index in middle of document" {
    const xml = "some prefix text <cim:Substation rdf:ID=\"_SS1\"> more text";
    const id = try tag_index.extract_rdf_id(xml, 17); // Points to '<' at position 17
    try std.testing.expectEqualStrings("_SS1", id);
}

test "tag_index.extract_rdf_id - empty value" {
    const xml = "<cim:Substation rdf:ID=\"\"/>";
    const id = try tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("", id);
}

test "tag_index.extract_rdf_id - has 'r' but no rdf:ID pattern" {
    const xml = "<cim:Substation random=\"test\">";
    const result = tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.NoRdfId, result);
}

test "tag_index.extract_rdf_id - pattern appears after tag close" {
    const xml = "<cim:Substation> rdf:ID=\"_SS1\"";
    const result = tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.NoRdfId, result);
}

test "tag_index.extract_rdf_id - closing quote missing (no quote at all)" {
    const xml = "<cim:Substation rdf:ID=\"_SS1>";
    const result = tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extract_rdf_id - closing quote after tag boundary" {
    const xml = "<cim:Substation rdf:ID=\"_SS1> later text \"";
    const result = tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extract_rdf_id - rdf:ID at end of tag with space" {
    const xml = "<cim:Substation name=\"test\" rdf:ID=\"_SS1\" >";
    const id = try tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("_SS1", id);
}

test "tag_index.extract_rdf_id - multiple 'r' characters before pattern" {
    const xml = "<cim:Substation region=\"west\" resource=\"power\" rdf:ID=\"_SS1\">";
    const id = try tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("_SS1", id);
}

test "tag_index.extract_rdf_id - pattern lookalike (rdf:resource not rdf:ID)" {
    const xml = "<cim:Terminal rdf:resource=\"#_CN1\">";
    const result = tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.NoRdfId, result);
}

test "tag_index.extract_rdf_id - value contains equals sign" {
    const xml = "<cim:Equation rdf:ID=\"x=y+z\">";
    const id = try tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("x=y+z", id);
}

test "tag_index.extract_rdf_id - value contains angle brackets (invalid XML)" {
    // Angle brackets in attribute values are invalid XML
    // Must be escaped as &lt; and &gt;
    const xml = "<cim:Formula rdf:ID=\"a<b>c\">";
    const result = tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extract_rdf_id - no tag close bracket" {
    const xml = "<cim:Substation rdf:ID=\"_SS1\"";
    const result = tag_index.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

// ============================================================================
// extract_rdf_resource Tests
// ============================================================================

test "tag_index.extract_rdf_resource - simple resource extraction" {
    const xml = "<cim:Substation.Region rdf:resource=\"#_Region1\"/>";
    const resource = try tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Region1", resource.?);
}

test "tag_index.extract_rdf_resource - multiple attributes" {
    const xml = "<cim:Terminal name=\"test\" rdf:resource=\"#_T1\" other=\"value\"/>";
    const resource = try tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_T1", resource.?);
}

test "tag_index.extract_rdf_resource - with hash prefix" {
    const xml = "<cim:Property rdf:resource=\"#_LocalRef\"/>";
    const resource = try tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_LocalRef", resource.?);
}

test "tag_index.extract_rdf_resource - without hash prefix" {
    const xml = "<cim:Property rdf:resource=\"_ExternalRef\"/>";
    const resource = try tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("_ExternalRef", resource.?);
}

test "tag_index.extract_rdf_resource - non-self-closing tag" {
    const xml = "<cim:Property rdf:resource=\"#_Ref1\"></cim:Property>";
    const resource = try tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Ref1", resource.?);
}

test "tag_index.extract_rdf_resource - empty value" {
    const xml = "<cim:Property rdf:resource=\"\"/>";
    const resource = try tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("", resource.?);
}

test "tag_index.extract_rdf_resource - no rdf:resource returns null" {
    const xml = "<cim:Substation name=\"test\"/>";
    const resource = try tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expectEqual(@as(?[]const u8, null), resource);
}

test "tag_index.extract_rdf_resource - full URI" {
    const xml = "<cim:Property rdf:resource=\"http://example.com/resource#_R1\"/>";
    const resource = try tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("http://example.com/resource#_R1", resource.?);
}

test "tag_index.extract_rdf_resource - special characters in value" {
    const xml = "<cim:Property rdf:resource=\"#_Node-123.456_v2\"/>";
    const resource = try tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Node-123.456_v2", resource.?);
}

test "tag_index.extract_rdf_resource - malformed (no closing quote)" {
    const xml = "<cim:Property rdf:resource=\"#_Ref1/>";
    const result = tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extract_rdf_resource - closing quote after tag boundary" {
    const xml = "<cim:Property rdf:resource=\"#_Ref1> later text \"";
    const result = tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extract_rdf_resource - pattern appears after tag close" {
    const xml = "<cim:Property> rdf:resource=\"#_Ref1\"";
    const resource = try tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expectEqual(@as(?[]const u8, null), resource);
}

test "tag_index.extract_rdf_resource - no tag close bracket" {
    const xml = "<cim:Property rdf:resource=\"#_Ref1\"";
    const result = tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extract_rdf_resource - start_index in middle of document" {
    const xml = "prefix text <cim:Property rdf:resource=\"#_Ref1\"/> more text";
    const resource = try tag_index.extract_rdf_resource(xml, 12);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Ref1", resource.?);
}

test "tag_index.extract_rdf_resource - rdf:resource at end of tag" {
    const xml = "<cim:Property name=\"test\" other=\"value\" rdf:resource=\"#_Ref1\" />";
    const resource = try tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Ref1", resource.?);
}

test "tag_index.extract_rdf_resource - value contains equals sign" {
    const xml = "<cim:Property rdf:resource=\"x=y+z\"/>";
    const resource = try tag_index.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("x=y+z", resource.?);
}

// ============================================================================
// extract_rdf_about Tests
// ============================================================================

test "tag_index.extract_rdf_about - simple FullModel tag" {
    const xml = "<md:FullModel rdf:about=\"urn:uuid:ieee9cdf_N_EQUIPMENT\">";
    const about = try tag_index.extract_rdf_about(xml, 0);
    try std.testing.expectEqualStrings("urn:uuid:ieee9cdf_N_EQUIPMENT", about);
}

test "tag_index.extract_rdf_about - with timestamp in value" {
    const xml = "<md:FullModel rdf:about=\"urn:uuid:ieee9cdf_N_EQUIPMENT_2009-04-26T00:00:00Z_1_1D__FM\">";
    const about = try tag_index.extract_rdf_about(xml, 0);
    try std.testing.expectEqualStrings("urn:uuid:ieee9cdf_N_EQUIPMENT_2009-04-26T00:00:00Z_1_1D__FM", about);
}

test "tag_index.extract_rdf_about - multiple attributes" {
    const xml = "<md:FullModel xmlns:md=\"http://example.com\" rdf:about=\"urn:uuid:test\" other=\"value\">";
    const about = try tag_index.extract_rdf_about(xml, 0);
    try std.testing.expectEqualStrings("urn:uuid:test", about);
}

test "tag_index.extract_rdf_about - self-closing tag" {
    const xml = "<md:Model rdf:about=\"urn:uuid:model123\"/>";
    const about = try tag_index.extract_rdf_about(xml, 0);
    try std.testing.expectEqualStrings("urn:uuid:model123", about);
}

test "tag_index.extract_rdf_about - no rdf:about (error)" {
    const xml = "<md:FullModel name=\"test\">";
    const result = tag_index.extract_rdf_about(xml, 0);
    try std.testing.expectError(error.NoRdfAbout, result);
}

test "tag_index.extract_rdf_about - malformed (no closing quote)" {
    const xml = "<md:FullModel rdf:about=\"urn:uuid:test>";
    const result = tag_index.extract_rdf_about(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extract_rdf_about - closing quote after tag boundary" {
    const xml = "<md:FullModel rdf:about=\"urn:uuid:test> later text \"";
    const result = tag_index.extract_rdf_about(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extract_rdf_about - no tag close bracket" {
    const xml = "<md:FullModel rdf:about=\"urn:uuid:test\"";
    const result = tag_index.extract_rdf_about(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "tag_index.extract_rdf_about - start_index in middle of document" {
    const xml = "prefix text <md:FullModel rdf:about=\"urn:uuid:test\"> more text";
    const about = try tag_index.extract_rdf_about(xml, 12);
    try std.testing.expectEqualStrings("urn:uuid:test", about);
}

test "tag_index.extract_rdf_about - empty value" {
    const xml = "<md:FullModel rdf:about=\"\"/>";
    const about = try tag_index.extract_rdf_about(xml, 0);
    try std.testing.expectEqualStrings("", about);
}

test "tag_index.extract_rdf_about - pattern appears after tag close" {
    const xml = "<md:FullModel> rdf:about=\"urn:uuid:test\"";
    const result = tag_index.extract_rdf_about(xml, 0);
    try std.testing.expectError(error.NoRdfAbout, result);
}

test "tag_index.extract_rdf_about - has rdf:ID but not rdf:about" {
    const xml = "<cim:Substation rdf:ID=\"_SS1\">";
    const result = tag_index.extract_rdf_about(xml, 0);
    try std.testing.expectError(error.NoRdfAbout, result);
}

test "tag_index.find_closing_tag - simple opening and closing tag" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Root></cim:Root>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing_idx = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 1), closing_idx);
}

test "tag_index.find_closing_tag - tag with text content" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Name>North Station</cim:Name>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing_idx = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 1), closing_idx);
}

test "tag_index.find_closing_tag - nested different tags" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Root><cim:Child>text</cim:Child></cim:Root>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Find closing tag for Root (index 0) -> should be index 3
    const root_closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 3), root_closing);

    // Find closing tag for Child (index 1) -> should be index 2
    const child_closing = try tag_index.find_closing_tag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 2), child_closing);
}

test "tag_index.find_closing_tag - nested same-name tags (depth counting)" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Item><cim:Item></cim:Item></cim:Item>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Find closing tag for outer Item (index 0) -> should be index 3
    const outer_closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 3), outer_closing);

    // Find closing tag for inner Item (index 1) -> should be index 2
    const inner_closing = try tag_index.find_closing_tag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 2), inner_closing);
}

test "tag_index.find_closing_tag - deeply nested same-name tags" {
    const gpa = std.testing.allocator;

    const xml = "<ns:a><ns:a><ns:a></ns:a></ns:a></ns:a>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Outermost (index 0) -> closing at index 5
    const outer = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 5), outer);

    // Middle (index 1) -> closing at index 4
    const middle = try tag_index.find_closing_tag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 4), middle);

    // Innermost (index 2) -> closing at index 3
    const inner = try tag_index.find_closing_tag(xml, boundaries.items, 2);
    try std.testing.expectEqual(@as(u32, 3), inner);
}

test "tag_index.find_closing_tag - CGMES example with properties" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  <cim:Substation.Region rdf:resource="#_R1"/>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Find closing for Substation (index 0) -> should be last tag (index 4)
    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 4), closing);

    // Find closing for IdentifiedObject.name (index 1) -> should be index 2
    const name_closing = try tag_index.find_closing_tag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 2), name_closing);
}

test "tag_index.find_closing_tag - self-closing tag returns error" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Terminal rdf:resource=\"#_T1\"/>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const result = tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectError(error.SelfClosingTag, result);
}

test "tag_index.find_closing_tag - self-closing tag with space before slash" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Item />";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const result = tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectError(error.SelfClosingTag, result);
}

test "tag_index.find_closing_tag - no closing tag (error)" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Root><cim:Child></cim:Child>"; // Root not closed

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const result = tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectError(error.NoClosingTag, result);
}

test "tag_index.find_closing_tag - multiple same-name tags at same level" {
    const gpa = std.testing.allocator;

    const xml = "<ns:root><ns:item>1</ns:item><ns:item>2</ns:item></ns:root>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // First item (index 1) -> closes at index 2
    const first_item = try tag_index.find_closing_tag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 2), first_item);

    // Second item (index 3) -> closes at index 4
    const second_item = try tag_index.find_closing_tag(xml, boundaries.items, 3);
    try std.testing.expectEqual(@as(u32, 4), second_item);

    // Root (index 0) -> closes at index 5
    const root = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 5), root);
}

test "tag_index.find_closing_tag - mixed self-closing and normal tags" {
    const gpa = std.testing.allocator;

    const xml = "<ns:root><ns:item/><ns:child>text</ns:child></ns:root>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Root (index 0) -> closes at index 4 (self-closing item at index 1 doesn't affect depth)
    const root_closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 4), root_closing);

    // Child (index 2) -> closes at index 3
    const child_closing = try tag_index.find_closing_tag(xml, boundaries.items, 2);
    try std.testing.expectEqual(@as(u32, 3), child_closing);

    // Item is self-closing
    const item_result = tag_index.find_closing_tag(xml, boundaries.items, 1);
    try std.testing.expectError(error.SelfClosingTag, item_result);
}

test "tag_index.find_closing_tag - tag with attributes" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_SS1\" name=\"test\"></cim:Substation>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 1), closing);
}

test "tag_index.find_closing_tag - empty tag" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Value></cim:Value>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 1), closing);
}

test "tag_index.get_property_from_indices - simple property with text content" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Substation: opening at 0, closing at 3
    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 3), closing);

    // Get the "IdentifiedObject.name" property
    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "IdentifiedObject.name");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("North Station", value.?);
}

test "tag_index.get_property_from_indices - property not found returns null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    // Request property that doesn't exist
    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "NonExistent.property");
    try std.testing.expectEqual(@as(?[]const u8, null), value);
}

test "tag_index.get_property_from_indices - empty property value" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.name></cim:Property.name>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.name");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("", value.?);
}

test "tag_index.get_property_from_indices - multiple properties, find specific one" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  <cim:IdentifiedObject.description>Main substation</cim:IdentifiedObject.description>
        \\  <cim:Substation.Region rdf:resource="#_R1"/>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    // Get first property
    const name = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "IdentifiedObject.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("North Station", name.?);

    // Get second property
    const desc = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "IdentifiedObject.description");
    try std.testing.expect(desc != null);
    try std.testing.expectEqualStrings("Main substation", desc.?);
}

test "tag_index.get_property_from_indices - self-closing property tag returns null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:Substation.Region rdf:resource="#_R1"/>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    // Self-closing tag has no text content
    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Substation.Region");
    try std.testing.expectEqual(@as(?[]const u8, null), value);
}

test "tag_index.get_property_from_indices - property with whitespace preserved" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.value>  Leading and trailing spaces  </cim:Property.value>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.value");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("  Leading and trailing spaces  ", value.?);
}

test "tag_index.get_property_from_indices - property name must match exactly" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.name>Value</cim:Property.name>
        \\  <cim:Property.nameExtra>Other</cim:Property.nameExtra>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    // Should find exact match "Property.name", not "Property.nameExtra"
    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.name");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("Value", value.?);

    // Should NOT match partial "Property.name" when looking for "Property.nameExtra"
    const value2 = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.nameExtra");
    try std.testing.expect(value2 != null);
    try std.testing.expectEqualStrings("Other", value2.?);
}

test "tag_index.get_property_from_indices - property with special characters" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.value>Value with &lt;special&gt; chars &amp; symbols</cim:Property.value>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.value");
    try std.testing.expect(value != null);
    // Note: We return raw XML content, not decoded entities
    try std.testing.expectEqualStrings("Value with &lt;special&gt; chars &amp; symbols", value.?);
}

test "tag_index.get_property_from_indices - multiple same-name properties returns first" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.value>First</cim:Property.value>
        \\  <cim:Property.value>Second</cim:Property.value>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    // Should return first occurrence
    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.value");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("First", value.?);
}

test "tag_index.get_property_from_indices - property with numeric value" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:VoltageLevel>
        \\  <cim:VoltageLevel.nominalV>380.0</cim:VoltageLevel.nominalV>
        \\</cim:VoltageLevel>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "VoltageLevel.nominalV");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("380.0", value.?);
}

test "tag_index.get_property_from_indices - no properties in object" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Object></cim:Object>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Any.property");
    try std.testing.expectEqual(@as(?[]const u8, null), value);
}

test "tag_index.get_property_from_indices - nested object doesn't interfere" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Outer>
        \\  <cim:Outer.property>OuterValue</cim:Outer.property>
        \\  <cim:Inner>
        \\    <cim:Inner.property>InnerValue</cim:Inner.property>
        \\  </cim:Inner>
        \\</cim:Outer>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const outer_closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    // Getting property from Outer should find its own property, not nested one
    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, outer_closing, "Outer.property");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("OuterValue", value.?);
}

test "tag_index.get_property_from_indices - property with newlines and indentation" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.text>
        \\    Multi-line
        \\    content
        \\  </cim:Property.text>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "Property.text");
    try std.testing.expect(value != null);
    // Should preserve all whitespace including newlines
    try std.testing.expect(std.mem.indexOf(u8, value.?, "Multi-line") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.?, "content") != null);
}

test "tag_index.get_property_from_indices - self-closing tag before target property" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation>
        \\  <cim:Region rdf:resource="#_R1"/>
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    // Should skip self-closing Region and find name
    const value = try tag_index.get_property_from_indices(xml, boundaries.items, 0, closing, "IdentifiedObject.name");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("North Station", value.?);
}

test "tag_index.get_reference_from_indices - simple reference extraction" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:Substation.Region rdf:resource="#_Region1"/>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Substation.Region");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_Region1", ref.?);
}

test "tag_index.get_reference_from_indices - reference not found returns null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:Substation.Region rdf:resource="#_Region1"/>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "NonExistent.property");
    try std.testing.expectEqual(@as(?[]const u8, null), ref);
}

test "tag_index.get_reference_from_indices - property exists but no rdf:resource" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation>
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    // Property exists but has text content, not rdf:resource
    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "IdentifiedObject.name");
    try std.testing.expectEqual(@as(?[]const u8, null), ref);
}

test "tag_index.get_reference_from_indices - multiple properties find specific reference" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_CN1"/>
        \\  <cim:Terminal.ConductingEquipment rdf:resource="#_CE1"/>
        \\  <cim:IdentifiedObject.name>Terminal 1</cim:IdentifiedObject.name>
        \\</cim:Terminal>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    // Get first reference
    const conn_node = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Terminal.ConnectivityNode");
    try std.testing.expect(conn_node != null);
    try std.testing.expectEqualStrings("#_CN1", conn_node.?);

    // Get second reference
    const ce = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Terminal.ConductingEquipment");
    try std.testing.expect(ce != null);
    try std.testing.expectEqualStrings("#_CE1", ce.?);
}

test "tag_index.get_reference_from_indices - reference with hash prefix" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_LocalRef"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_LocalRef", ref.?);
}

test "tag_index.get_reference_from_indices - reference without hash prefix" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="_ExternalRef"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("_ExternalRef", ref.?);
}

test "tag_index.get_reference_from_indices - empty reference value" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource=""/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("", ref.?);
}

test "tag_index.get_reference_from_indices - reference with URI" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="http://example.com/resource#_R1"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("http://example.com/resource#_R1", ref.?);
}

test "tag_index.get_reference_from_indices - reference with special characters" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_Node-123.456_v2"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_Node-123.456_v2", ref.?);
}

test "tag_index.get_reference_from_indices - multiple same-name properties returns first" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_First"/>
        \\  <cim:Property.ref rdf:resource="#_Second"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_First", ref.?);
}

test "tag_index.get_reference_from_indices - property name must match exactly" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_Ref1"/>
        \\  <cim:Property.refExtra rdf:resource="#_Ref2"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const ref1 = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref1 != null);
    try std.testing.expectEqualStrings("#_Ref1", ref1.?);

    const ref2 = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.refExtra");
    try std.testing.expect(ref2 != null);
    try std.testing.expectEqualStrings("#_Ref2", ref2.?);
}

test "tag_index.get_reference_from_indices - no properties in object" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Object></cim:Object>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Any.property");
    try std.testing.expectEqual(@as(?[]const u8, null), ref);
}

test "tag_index.get_reference_from_indices - nested object doesn't interfere" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Outer>
        \\  <cim:Outer.ref rdf:resource="#_OuterRef"/>
        \\  <cim:Inner>
        \\    <cim:Inner.ref rdf:resource="#_InnerRef"/>
        \\  </cim:Inner>
        \\</cim:Outer>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const outer_closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    // Getting reference from Outer should find its own reference
    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, outer_closing, "Outer.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_OuterRef", ref.?);
}

test "tag_index.get_reference_from_indices - non-self-closing tag with rdf:resource" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref rdf:resource="#_Ref1"></cim:Property.ref>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    // Should still extract rdf:resource even if tag is not self-closing
    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_Ref1", ref.?);
}

test "tag_index.get_reference_from_indices - rdf:resource with other attributes" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Object>
        \\  <cim:Property.ref name="test" rdf:resource="#_Ref1" other="value"/>
        \\</cim:Object>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    const ref = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, closing, "Property.ref");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("#_Ref1", ref.?);
}

test "tag_index.CimObject - create simple object" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);

    // Create CimObject
    const obj = try tag_index.CimObject.init(xml, boundaries.items, 0, closing);

    // Check metadata
    try std.testing.expectEqualStrings("_SS1", obj.id);
    try std.testing.expectEqualStrings("Substation", obj.type_name);
}

test "tag_index.CimObject - getProperty returns text content" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  <cim:IdentifiedObject.description>Main substation</cim:IdentifiedObject.description>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try tag_index.CimObject.init(xml, boundaries.items, 0, closing);

    // Get properties
    const name = try obj.getProperty("IdentifiedObject.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("North Station", name.?);

    const desc = try obj.getProperty("IdentifiedObject.description");
    try std.testing.expect(desc != null);
    try std.testing.expectEqualStrings("Main substation", desc.?);
}

test "tag_index.CimObject - getProperty returns null when not found" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try tag_index.CimObject.init(xml, boundaries.items, 0, closing);

    const result = try obj.getProperty("NonExistent.property");
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "tag_index.CimObject - getReference returns rdf:resource value" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_CN1"/>
        \\  <cim:Terminal.ConductingEquipment rdf:resource="#_CE1"/>
        \\</cim:Terminal>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try tag_index.CimObject.init(xml, boundaries.items, 0, closing);

    // Check metadata
    try std.testing.expectEqualStrings("_T1", obj.id);
    try std.testing.expectEqualStrings("Terminal", obj.type_name);

    // Get references
    const conn_node = try obj.getReference("Terminal.ConnectivityNode");
    try std.testing.expect(conn_node != null);
    try std.testing.expectEqualStrings("#_CN1", conn_node.?);

    const ce = try obj.getReference("Terminal.ConductingEquipment");
    try std.testing.expect(ce != null);
    try std.testing.expectEqualStrings("#_CE1", ce.?);
}

test "tag_index.CimObject - getReference returns null when not found" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_CN1"/>
        \\</cim:Terminal>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try tag_index.CimObject.init(xml, boundaries.items, 0, closing);

    const result = try obj.getReference("NonExistent.property");
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "tag_index.CimObject - mixed properties and references" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:ACLineSegment rdf:ID="_L1">
        \\  <cim:IdentifiedObject.name>Line 1</cim:IdentifiedObject.name>
        \\  <cim:ACLineSegment.r>0.5</cim:ACLineSegment.r>
        \\  <cim:ACLineSegment.BaseVoltage rdf:resource="#_BV1"/>
        \\</cim:ACLineSegment>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try tag_index.CimObject.init(xml, boundaries.items, 0, closing);

    // Check metadata
    try std.testing.expectEqualStrings("_L1", obj.id);
    try std.testing.expectEqualStrings("ACLineSegment", obj.type_name);

    // Get text properties
    const name = try obj.getProperty("IdentifiedObject.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("Line 1", name.?);

    const r = try obj.getProperty("ACLineSegment.r");
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("0.5", r.?);

    // Get reference
    const bv = try obj.getReference("ACLineSegment.BaseVoltage");
    try std.testing.expect(bv != null);
    try std.testing.expectEqualStrings("#_BV1", bv.?);
}

test "tag_index.CimObject - empty object (no properties)" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Object rdf:ID=\"_O1\"></cim:Object>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try tag_index.CimObject.init(xml, boundaries.items, 0, closing);

    try std.testing.expectEqualStrings("_O1", obj.id);
    try std.testing.expectEqualStrings("Object", obj.type_name);

    const prop = try obj.getProperty("Any.property");
    try std.testing.expectEqual(@as(?[]const u8, null), prop);
}

test "tag_index.CimObject - object with long ID" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_Very_Long_Identifier_With_Many_Characters_12345\"></cim:Substation>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try tag_index.CimObject.init(xml, boundaries.items, 0, closing);

    try std.testing.expectEqualStrings("_Very_Long_Identifier_With_Many_Characters_12345", obj.id);
}

test "tag_index.CimObject - object with dots in type name" {
    const gpa = std.testing.allocator;

    const xml = "<cim:IdentifiedObject.name rdf:ID=\"_ID1\"></cim:IdentifiedObject.name>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try tag_index.CimObject.init(xml, boundaries.items, 0, closing);

    try std.testing.expectEqualStrings("_ID1", obj.id);
    try std.testing.expectEqualStrings("IdentifiedObject.name", obj.type_name);
}

test "tag_index.CimObject - multiple objects from same XML" {
    const gpa = std.testing.allocator;

    const xml =
        \\<root>
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>Station 1</cim:IdentifiedObject.name>
        \\</cim:Substation>
        \\<cim:Substation rdf:ID="_SS2">
        \\  <cim:IdentifiedObject.name>Station 2</cim:IdentifiedObject.name>
        \\</cim:Substation>
        \\</root>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // First Substation (index 1)
    const closing1 = try tag_index.find_closing_tag(xml, boundaries.items, 1);
    const obj1 = try tag_index.CimObject.init(xml, boundaries.items, 1, closing1);

    try std.testing.expectEqualStrings("_SS1", obj1.id);
    try std.testing.expectEqualStrings("Substation", obj1.type_name);

    const name1 = try obj1.getProperty("IdentifiedObject.name");
    try std.testing.expect(name1 != null);
    try std.testing.expectEqualStrings("Station 1", name1.?);

    // Second Substation (index 5)
    const closing2 = try tag_index.find_closing_tag(xml, boundaries.items, 5);
    const obj2 = try tag_index.CimObject.init(xml, boundaries.items, 5, closing2);

    try std.testing.expectEqualStrings("_SS2", obj2.id);
    try std.testing.expectEqualStrings("Substation", obj2.type_name);

    const name2 = try obj2.getProperty("IdentifiedObject.name");
    try std.testing.expect(name2 != null);
    try std.testing.expectEqualStrings("Station 2", name2.?);

    // Verify they share the same xml and boundaries references
    try std.testing.expectEqual(obj1.xml.ptr, obj2.xml.ptr);
    try std.testing.expectEqual(obj1.boundaries.ptr, obj2.boundaries.ptr);
}

test "tag_index.CimObject - self-closing tag" {
    const gpa = std.testing.allocator;

    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\</rdf:RDF>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // The Substation is at index 1
    const closing = tag_index.find_closing_tag(xml, boundaries.items, 1) catch |err| blk: {
        try std.testing.expectEqual(error.SelfClosingTag, err);
        break :blk 1; // Use same index for self-closing
    };
    try std.testing.expectEqual(@as(u32, 1), closing); // Self-closing returns same index

    const obj = try tag_index.CimObject.init(xml, boundaries.items, 1, closing);

    try std.testing.expectEqualStrings("_SS1", obj.id);
    try std.testing.expectEqualStrings("Substation", obj.type_name);

    // Self-closing tags should have no properties
    const prop = try obj.getProperty("SomeProperty");
    try std.testing.expect(prop == null);

    // Self-closing tags should have no references
    const ref = try obj.getReference("SomeReference");
    try std.testing.expect(ref == null);
}

test "tag_index.CimObject - getProperty on self-closing tag returns null" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Terminal rdf:ID=\"_T1\"/>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = tag_index.find_closing_tag(xml, boundaries.items, 0) catch |err| blk: {
        try std.testing.expectEqual(error.SelfClosingTag, err);
        break :blk 0; // Use same index for self-closing
    };
    const obj = try tag_index.CimObject.init(xml, boundaries.items, 0, closing);

    // Verify self-closing
    try std.testing.expectEqual(obj.object_tag_idx, obj.closing_tag_idx);

    // All property lookups should return null
    const name = try obj.getProperty("IdentifiedObject.name");
    try std.testing.expect(name == null);

    const desc = try obj.getProperty("IdentifiedObject.description");
    try std.testing.expect(desc == null);
}

test "tag_index.CimObject - getReference on self-closing tag returns null" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Terminal rdf:ID=\"_T1\"/>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = tag_index.find_closing_tag(xml, boundaries.items, 0) catch |err| blk: {
        try std.testing.expectEqual(error.SelfClosingTag, err);
        break :blk 0; // Use same index for self-closing
    };
    const obj = try tag_index.CimObject.init(xml, boundaries.items, 0, closing);

    // Verify self-closing
    try std.testing.expectEqual(obj.object_tag_idx, obj.closing_tag_idx);

    // All reference lookups should return null
    const ref1 = try obj.getReference("Terminal.ConductingEquipment");
    try std.testing.expect(ref1 == null);

    const ref2 = try obj.getReference("Terminal.ConnectivityNode");
    try std.testing.expect(ref2 == null);
}

test "tag_index.get_property_from_indices - self-closing tag returns null" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_SS1\"/>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // For self-closing tag, opening_idx == closing_idx
    const result = try tag_index.get_property_from_indices(xml, boundaries.items, 0, 0, "SomeProperty");
    try std.testing.expect(result == null);
}

test "tag_index.get_reference_from_indices - self-closing tag returns null" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_SS1\"/>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // For self-closing tag, opening_idx == closing_idx
    const result = try tag_index.get_reference_from_indices(xml, boundaries.items, 0, 0, "SomeReference");
    try std.testing.expect(result == null);
}

test "CimObject.getAllProperties - returns all text properties" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  <cim:IdentifiedObject.description>Main substation</cim:IdentifiedObject.description>
        \\  <cim:Substation.Region rdf:resource="#_Region1"/>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try CimObject.init(xml, boundaries.items, 0, closing);

    var props = try obj.getAllProperties(gpa);
    defer props.deinit();

    // Should have 2 properties (not the reference)
    try std.testing.expectEqual(2, props.count());

    // Check property values
    const name = props.get("IdentifiedObject.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("North Station", name.?);

    const desc = props.get("IdentifiedObject.description");
    try std.testing.expect(desc != null);
    try std.testing.expectEqualStrings("Main substation", desc.?);

    // Should NOT include the reference
    try std.testing.expect(props.get("Substation.Region") == null);
}

test "CimObject.getAllReferences - returns all rdf:resource references" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  <cim:Substation.Region rdf:resource="#_Region1"/>
        \\  <cim:Substation.VoltageLevel rdf:resource="#_VL1"/>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try CimObject.init(xml, boundaries.items, 0, closing);

    var refs = try obj.getAllReferences(gpa);
    defer refs.deinit();

    // Should have 2 references
    try std.testing.expectEqual(2, refs.count());

    // Check reference values
    const region = refs.get("Substation.Region");
    try std.testing.expect(region != null);
    try std.testing.expectEqualStrings("#_Region1", region.?);

    const voltage_level = refs.get("Substation.VoltageLevel");
    try std.testing.expect(voltage_level != null);
    try std.testing.expectEqualStrings("#_VL1", voltage_level.?);

    // Should NOT include text properties
    try std.testing.expect(refs.get("IdentifiedObject.name") == null);
}

test "CimObject.getAllProperties - empty object returns empty map" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_SS1\"/>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = tag_index.find_closing_tag(xml, boundaries.items, 0) catch |err| blk: {
        try std.testing.expectEqual(error.SelfClosingTag, err);
        break :blk 0;
    };
    const obj = try CimObject.init(xml, boundaries.items, 0, closing);

    var props = try obj.getAllProperties(gpa);
    defer props.deinit();

    try std.testing.expectEqual(0, props.count());
}

test "CimObject.getAllReferences - empty object returns empty map" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_SS1\"/>";

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = tag_index.find_closing_tag(xml, boundaries.items, 0) catch |err| blk: {
        try std.testing.expectEqual(error.SelfClosingTag, err);
        break :blk 0;
    };
    const obj = try CimObject.init(xml, boundaries.items, 0, closing);

    var refs = try obj.getAllReferences(gpa);
    defer refs.deinit();

    try std.testing.expectEqual(0, refs.count());
}

test "CimObject.getAllProperties - handles mixed properties and references" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\  <cim:Terminal.ConductingEquipment rdf:resource="#_Line1"/>
        \\  <cim:IdentifiedObject.name>Terminal 1</cim:IdentifiedObject.name>
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_Node1"/>
        \\</cim:Terminal>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try CimObject.init(xml, boundaries.items, 0, closing);

    var props = try obj.getAllProperties(gpa);
    defer props.deinit();

    var refs = try obj.getAllReferences(gpa);
    defer refs.deinit();

    // Should have 2 properties
    try std.testing.expectEqual(2, props.count());
    try std.testing.expectEqualStrings("1", props.get("ACDCTerminal.sequenceNumber").?);
    try std.testing.expectEqualStrings("Terminal 1", props.get("IdentifiedObject.name").?);

    // Should have 2 references
    try std.testing.expectEqual(2, refs.count());
    try std.testing.expectEqualStrings("#_Line1", refs.get("Terminal.ConductingEquipment").?);
    try std.testing.expectEqualStrings("#_Node1", refs.get("Terminal.ConnectivityNode").?);
}

test "tag_index.CimObject - getProperties batch matches individual getProperty" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:ACLineSegment rdf:ID="_Line1">
        \\  <cim:IdentifiedObject.mRID>line-mrid</cim:IdentifiedObject.mRID>
        \\  <cim:IdentifiedObject.name>Line 1</cim:IdentifiedObject.name>
        \\  <cim:ACLineSegment.r>1.5</cim:ACLineSegment.r>
        \\  <cim:ACLineSegment.x>12.3</cim:ACLineSegment.x>
        \\  <cim:ACLineSegment.bch>0.001</cim:ACLineSegment.bch>
        \\  <cim:ACLineSegment.gch>0.0005</cim:ACLineSegment.gch>
        \\</cim:ACLineSegment>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try CimObject.init(xml, boundaries.items, 0, closing);

    // Batch fetch
    const props = try obj.getProperties(.{
        "IdentifiedObject.mRID",
        "IdentifiedObject.name",
        "ACLineSegment.r",
        "ACLineSegment.x",
        "ACLineSegment.bch",
        "ACLineSegment.gch",
    });

    // Verify each matches individual getProperty
    try std.testing.expectEqualStrings("line-mrid", props[0].?);
    try std.testing.expectEqualStrings("Line 1", props[1].?);
    try std.testing.expectEqualStrings("1.5", props[2].?);
    try std.testing.expectEqualStrings("12.3", props[3].?);
    try std.testing.expectEqualStrings("0.001", props[4].?);
    try std.testing.expectEqualStrings("0.0005", props[5].?);

    // Cross-check with individual calls
    try std.testing.expectEqualStrings(props[0].?, (try obj.getProperty("IdentifiedObject.mRID")).?);
    try std.testing.expectEqualStrings(props[2].?, (try obj.getProperty("ACLineSegment.r")).?);
}

test "tag_index.CimObject - getProperties returns null for missing names" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try CimObject.init(xml, boundaries.items, 0, closing);

    const props = try obj.getProperties(.{
        "IdentifiedObject.name",
        "IdentifiedObject.mRID",
        "NonExistent.property",
    });

    try std.testing.expectEqualStrings("North Station", props[0].?);
    try std.testing.expect(props[1] == null);
    try std.testing.expect(props[2] == null);
}

test "tag_index.CimObject - getProperties on self-closing tag returns all null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1"/>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const obj = try CimObject.init(xml, boundaries.items, 0, 0);

    const props = try obj.getProperties(.{
        "IdentifiedObject.name",
        "IdentifiedObject.mRID",
    });

    try std.testing.expect(props[0] == null);
    try std.testing.expect(props[1] == null);
}

test "tag_index.CimObject - getReferences batch matches individual getReference" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:IdentifiedObject.name>Terminal 1</cim:IdentifiedObject.name>
        \\  <cim:Terminal.ConductingEquipment rdf:resource="#_Line1"/>
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_Node1"/>
        \\  <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
        \\</cim:Terminal>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try CimObject.init(xml, boundaries.items, 0, closing);

    // Batch fetch references
    const refs = try obj.getReferences(.{
        "Terminal.ConductingEquipment",
        "Terminal.ConnectivityNode",
    });

    try std.testing.expectEqualStrings("#_Line1", refs[0].?);
    try std.testing.expectEqualStrings("#_Node1", refs[1].?);

    // Cross-check with individual calls
    try std.testing.expectEqualStrings(refs[0].?, (try obj.getReference("Terminal.ConductingEquipment")).?);
    try std.testing.expectEqualStrings(refs[1].?, (try obj.getReference("Terminal.ConnectivityNode")).?);
}

test "tag_index.CimObject - getReferences returns null for missing names" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Terminal rdf:ID="_T1">
        \\  <cim:Terminal.ConductingEquipment rdf:resource="#_Line1"/>
        \\</cim:Terminal>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try tag_index.find_closing_tag(xml, boundaries.items, 0);
    const obj = try CimObject.init(xml, boundaries.items, 0, closing);

    const refs = try obj.getReferences(.{
        "Terminal.ConductingEquipment",
        "Terminal.ConnectivityNode",
    });

    try std.testing.expectEqualStrings("#_Line1", refs[0].?);
    try std.testing.expect(refs[1] == null);
}

test "tag_index.CimObject - getReferences on self-closing tag returns all null" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1"/>
    ;

    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const obj = try CimObject.init(xml, boundaries.items, 0, 0);

    const refs = try obj.getReferences(.{
        "Terminal.ConductingEquipment",
        "Terminal.ConnectivityNode",
    });

    try std.testing.expect(refs[0] == null);
    try std.testing.expect(refs[1] == null);
}
