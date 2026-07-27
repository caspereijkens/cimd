//! Tests for the raw XML/RDF scanning layer. Object-level behaviour --
//! children, properties, references -- lives in test_tag_index.zig.

const std = @import("std");
const assert = std.debug.assert;
const xml_scan = @import("xml_scan.zig");

test "xml_scan.find_byte_simd - finds all angle brackets" {
    const gpa = std.testing.allocator;

    const input = "<a><b></b></a>";

    // Find all '<'
    var lt_positions = try xml_scan.find_byte_simd(gpa, input, '<');
    defer lt_positions.deinit(gpa);

    // Expected: positions 0, 3, 6, 10
    try std.testing.expectEqual(@as(usize, 4), lt_positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), lt_positions.items[0]);
    try std.testing.expectEqual(@as(u32, 3), lt_positions.items[1]);
    try std.testing.expectEqual(@as(u32, 6), lt_positions.items[2]);
    try std.testing.expectEqual(@as(u32, 10), lt_positions.items[3]);

    // Find all '>'
    var gt_positions = try xml_scan.find_byte_simd(gpa, input, '>');
    defer gt_positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), gt_positions.items.len);
    try std.testing.expectEqual(@as(u32, 2), gt_positions.items[0]);
    try std.testing.expectEqual(@as(u32, 5), gt_positions.items[1]);
    try std.testing.expectEqual(@as(u32, 9), gt_positions.items[2]);
    try std.testing.expectEqual(@as(u32, 13), gt_positions.items[3]);
}

test "xml_scan.find_byte_simd - handles empty input" {
    const gpa = std.testing.allocator;

    var positions = try xml_scan.find_byte_simd(gpa, "", '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), positions.items.len);
}

test "xml_scan.find_byte_simd - handles input with no matches" {
    const gpa = std.testing.allocator;

    var positions = try xml_scan.find_byte_simd(gpa, "hello world", '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), positions.items.len);
}

test "xml_scan.find_byte_simd - handles large input spanning multiple SIMD vectors" {
    const gpa = std.testing.allocator;

    // Create input larger than xml_scan.VECTOR_LEN to test chunking
    var buffer: [128]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<';
    buffer[32] = '<'; // Cross vector boundary
    buffer[64] = '<';
    buffer[127] = '<';

    var positions = try xml_scan.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, 32), positions.items[1]);
    try std.testing.expectEqual(@as(u32, 64), positions.items[2]);
    try std.testing.expectEqual(@as(u32, 127), positions.items[3]);
}

test "xml_scan.find_byte_simd - exactly one vector (VECTOR_LEN bytes)" {
    const gpa = std.testing.allocator;

    // Exactly xml_scan.VECTOR_LEN bytes - tests remaining vectors loop, not unrolled
    var buffer: [xml_scan.VECTOR_LEN]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<';
    buffer[xml_scan.VECTOR_LEN / 2] = '<';
    buffer[xml_scan.VECTOR_LEN - 1] = '<'; // Last position

    var positions = try xml_scan.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, xml_scan.VECTOR_LEN / 2), positions.items[1]);
    try std.testing.expectEqual(@as(u32, xml_scan.VECTOR_LEN - 1), positions.items[2]);
}

test "xml_scan.find_byte_simd - two full vectors (64 bytes)" {
    const gpa = std.testing.allocator;

    // 2 * xml_scan.VECTOR_LEN - tests remaining vectors loop with 2 iterations
    var buffer: [xml_scan.VECTOR_LEN * 2]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<';
    buffer[xml_scan.VECTOR_LEN] = '<'; // Start of second vector
    buffer[xml_scan.VECTOR_LEN + 15] = '<'; // Middle of second vector

    var positions = try xml_scan.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, xml_scan.VECTOR_LEN), positions.items[1]);
    try std.testing.expectEqual(@as(u32, xml_scan.VECTOR_LEN + 15), positions.items[2]);
}

test "xml_scan.find_byte_simd - three full vectors (96 bytes)" {
    const gpa = std.testing.allocator;

    // 3 * xml_scan.VECTOR_LEN - tests remaining vectors loop with 3 iterations
    var buffer: [xml_scan.VECTOR_LEN * 3]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[xml_scan.VECTOR_LEN * 0] = '<';
    buffer[xml_scan.VECTOR_LEN * 1] = '<';
    buffer[xml_scan.VECTOR_LEN * 2] = '<';

    var positions = try xml_scan.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, xml_scan.VECTOR_LEN), positions.items[1]);
    try std.testing.expectEqual(@as(u32, xml_scan.VECTOR_LEN * 2), positions.items[2]);
}

test "xml_scan.find_byte_simd - unrolled loop with remainder" {
    const gpa = std.testing.allocator;

    // 130 bytes = 128 (unrolled) + 2 (scalar remainder)
    const unroll_size = xml_scan.VECTOR_LEN * 4;
    var buffer: [unroll_size + 2]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<'; // Unrolled loop
    buffer[unroll_size - 1] = '<'; // End of unrolled loop
    buffer[unroll_size] = '<'; // Scalar remainder
    buffer[unroll_size + 1] = '<'; // Scalar remainder

    var positions = try xml_scan.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, unroll_size - 1), positions.items[1]);
    try std.testing.expectEqual(@as(u32, unroll_size), positions.items[2]);
    try std.testing.expectEqual(@as(u32, unroll_size + 1), positions.items[3]);
}

test "xml_scan.find_byte_simd - multiple unrolled iterations" {
    const gpa = std.testing.allocator;

    // 256 bytes = 2 iterations of unrolled loop (2 * 128)
    const unroll_size = xml_scan.VECTOR_LEN * 4;
    var buffer: [unroll_size * 2]u8 = undefined;
    @memset(&buffer, 'x');
    buffer[0] = '<'; // First unrolled iteration
    buffer[unroll_size] = '<'; // Second unrolled iteration
    buffer[unroll_size * 2 - 1] = '<'; // Last byte

    var positions = try xml_scan.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, unroll_size), positions.items[1]);
    try std.testing.expectEqual(@as(u32, unroll_size * 2 - 1), positions.items[2]);
}

test "xml_scan.find_byte_simd - dense matches in single vector" {
    const gpa = std.testing.allocator;

    // Test multiple matches within a single SIMD vector (tests bit extraction loop)
    var buffer: [xml_scan.VECTOR_LEN]u8 = undefined;
    @memset(&buffer, '<'); // All matches!

    var positions = try xml_scan.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    // Should find all 32 positions
    try std.testing.expectEqual(@as(usize, xml_scan.VECTOR_LEN), positions.items.len);
    for (positions.items, 0..) |pos, idx| {
        try std.testing.expectEqual(@as(u32, @intCast(idx)), pos);
    }
}

test "xml_scan.find_byte_simd - matches at vector boundaries" {
    const gpa = std.testing.allocator;

    // Test matches at first and last byte of each vector
    const unroll_size = xml_scan.VECTOR_LEN * 4;
    var buffer: [unroll_size + 10]u8 = undefined;
    @memset(&buffer, 'x');

    // First and last of each 32-byte vector
    buffer[0] = '<'; // Vector 0, first
    buffer[xml_scan.VECTOR_LEN - 1] = '<'; // Vector 0, last
    buffer[xml_scan.VECTOR_LEN] = '<'; // Vector 1, first
    buffer[xml_scan.VECTOR_LEN * 2 - 1] = '<'; // Vector 1, last
    buffer[unroll_size] = '<'; // First byte of remainder
    buffer[unroll_size + 9] = '<'; // Last byte of remainder

    var positions = try xml_scan.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 6), positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), positions.items[0]);
    try std.testing.expectEqual(@as(u32, xml_scan.VECTOR_LEN - 1), positions.items[1]);
    try std.testing.expectEqual(@as(u32, xml_scan.VECTOR_LEN), positions.items[2]);
    try std.testing.expectEqual(@as(u32, xml_scan.VECTOR_LEN * 2 - 1), positions.items[3]);
    try std.testing.expectEqual(@as(u32, unroll_size), positions.items[4]);
    try std.testing.expectEqual(@as(u32, unroll_size + 9), positions.items[5]);
}

test "xml_scan.find_byte_simd - no matches in SIMD sections but matches in remainder" {
    const gpa = std.testing.allocator;

    // All SIMD vectors have no matches, only remainder has matches
    var buffer: [xml_scan.VECTOR_LEN + 5]u8 = undefined;
    @memset(&buffer, 'x');

    // Only matches in scalar remainder
    buffer[xml_scan.VECTOR_LEN] = '<';
    buffer[xml_scan.VECTOR_LEN + 2] = '<';
    buffer[xml_scan.VECTOR_LEN + 4] = '<';

    var positions = try xml_scan.find_byte_simd(gpa, &buffer, '<');
    defer positions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), positions.items.len);
    try std.testing.expectEqual(@as(u32, xml_scan.VECTOR_LEN), positions.items[0]);
    try std.testing.expectEqual(@as(u32, xml_scan.VECTOR_LEN + 2), positions.items[1]);
    try std.testing.expectEqual(@as(u32, xml_scan.VECTOR_LEN + 4), positions.items[2]);
}

// ============================================================================
// Pattern Matching Tests
// ============================================================================

test "xml_scan.find_pattern - finds rdf:ID with values" {
    const gpa = std.testing.allocator;

    const input =
        \\<cim:Substation rdf:ID="_SubStation1">
        \\<cim:Breaker rdf:ID="_BR1">
    ;

    var matches = try xml_scan.find_pattern(gpa, input, "rdf:ID=\"");
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

test "xml_scan.find_pattern - finds rdf:about with # prefix" {
    const gpa = std.testing.allocator;

    const input =
        \\<cim:Terminal rdf:about="#_T1">
        \\  <cim:Terminal.ConnectivityNode rdf:resource="#_CN1"/>
        \\</cim:Terminal>
    ;

    var matches = try xml_scan.find_pattern(gpa, input, "rdf:about=\"");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), matches.items.len);

    const match = matches.items[0];
    const value = input[match.value_start..][0..match.value_len];
    try std.testing.expectEqualStrings("#_T1", value);
}

test "xml_scan.find_pattern - no matches" {
    const gpa = std.testing.allocator;

    const input = "<root>Hello World</root>";

    var matches = try xml_scan.find_pattern(gpa, input, "rdf:ID=\"");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "xml_scan.find_pattern - empty input" {
    const gpa = std.testing.allocator;

    var matches = try xml_scan.find_pattern(gpa, "", "rdf:ID=\"");
    defer matches.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "xml_scan.verify_and_extract_pattern - valid pattern with value" {
    const input = "Hello rdf:ID=\"_SubStation1\" World";
    const pattern = "rdf:ID=\"";

    const match = xml_scan.verify_and_extract_pattern(input, 6, pattern);

    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(u32, 6), match.?.pattern_start);
    try std.testing.expectEqual(@as(u32, 14), match.?.value_start);
    try std.testing.expectEqual(@as(u32, 12), match.?.value_len);

    const value = input[match.?.value_start..][0..match.?.value_len];
    try std.testing.expectEqualStrings("_SubStation1", value);
}

test "xml_scan.verify_and_extract_pattern - empty value" {
    const input = "rdf:ID=\"\"";
    const pattern = "rdf:ID=\"";

    const match = xml_scan.verify_and_extract_pattern(input, 0, pattern);

    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(u32, 0), match.?.value_len);
}

test "xml_scan.verify_and_extract_pattern - pattern mismatch" {
    const input = "Hello rdf:about=\"value\"";
    const pattern = "rdf:ID=\"";

    const match = xml_scan.verify_and_extract_pattern(input, 6, pattern);

    try std.testing.expectEqual(@as(?xml_scan.PatternMatch, null), match);
}

test "xml_scan.verify_and_extract_pattern - no closing quote" {
    const input = "rdf:ID=\"unclosed";
    const pattern = "rdf:ID=\"";

    const match = xml_scan.verify_and_extract_pattern(input, 0, pattern);

    try std.testing.expectEqual(@as(?xml_scan.PatternMatch, null), match);
}

test "xml_scan.verify_and_extract_pattern - candidate near end of haystack" {
    const input = "rdf:";
    const pattern = "rdf:ID=\"";

    const match = xml_scan.verify_and_extract_pattern(input, 0, pattern);

    try std.testing.expectEqual(@as(?xml_scan.PatternMatch, null), match);
}

test "xml_scan.verify_and_extract_pattern - value with special characters" {
    const input = "rdf:ID=\"#_Node-123.456\"";
    const pattern = "rdf:ID=\"";

    const match = xml_scan.verify_and_extract_pattern(input, 0, pattern);

    try std.testing.expect(match != null);
    const value = input[match.?.value_start..][0..match.?.value_len];
    try std.testing.expectEqualStrings("#_Node-123.456", value);
}

test "xml_scan.find_tag_boundaries - single tag" {
    const gpa = std.testing.allocator;

    const input = "<root>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 5), boundaries.items[0].end);
}

test "xml_scan.find_tag_boundaries - opening and closing tags" {
    const gpa = std.testing.allocator;

    const input = "<root></root>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), boundaries.items.len);

    // <root>
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 5), boundaries.items[0].end);

    // </root>
    try std.testing.expectEqual(@as(u32, 6), boundaries.items[1].start);
    try std.testing.expectEqual(@as(u32, 12), boundaries.items[1].end);
}

test "xml_scan.find_tag_boundaries - nested tags" {
    const gpa = std.testing.allocator;

    const input = "<root><child>text</child></root>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
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

test "xml_scan.find_tag_boundaries - tag with attributes" {
    const gpa = std.testing.allocator;

    const input = "<item id=\"123\" name=\"test\">";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 26), boundaries.items[0].end);
}

test "xml_scan.find_tag_boundaries - self-closing tag" {
    const gpa = std.testing.allocator;

    const input = "<item />";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
    try std.testing.expectEqual(@as(u32, 0), boundaries.items[0].start);
    try std.testing.expectEqual(@as(u32, 7), boundaries.items[0].end);
}

test "xml_scan.find_tag_boundaries - multiple sequential tags" {
    const gpa = std.testing.allocator;

    const input = "<a></a><b></b><c></c>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
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

test "xml_scan.find_tag_boundaries - empty input" {
    const gpa = std.testing.allocator;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, "");
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), boundaries.items.len);
}

test "xml_scan.find_tag_boundaries - no tags" {
    const gpa = std.testing.allocator;

    const input = "just plain text with no tags";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), boundaries.items.len);
}

test "xml_scan.find_tag_boundaries - unmatched opening bracket" {
    const gpa = std.testing.allocator;

    const input = "<root"; // No closing >

    try std.testing.expectError(error.MalformedXML, xml_scan.find_tag_boundaries(gpa, input));
}

test "xml_scan.find_tag_boundaries - unmatched opening bracket followed by self-closing tag" {
    const gpa = std.testing.allocator;

    const input = "<root<item />"; // No closing >

    try std.testing.expectError(error.MalformedXML, xml_scan.find_tag_boundaries(gpa, input));
}

test "xml_scan.find_tag_boundaries - reversed bracket order" {
    const gpa = std.testing.allocator;

    const input = ">hello<"; // '>' before '<' - malformed

    try std.testing.expectError(error.MalformedXML, xml_scan.find_tag_boundaries(gpa, input));
}

test "xml_scan.find_tag_boundaries - stray '>' in text content is tolerated" {
    // '>' in XML character data is legal per the XML spec (only '<' and '&' must be escaped).
    // CGMES tools occasionally emit raw '>' in property values; the scanner must not
    // reject the file or produce a mis-paired boundary.
    const gpa = std.testing.allocator;
    const input = "<cim:Foo rdf:ID=\"_1\"><cim:Foo.name>a>b</cim:Foo.name></cim:Foo>";
    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    // Four tags: opening, property opening, property closing, object closing.
    // The stray '>' inside "a>b" must not create a spurious boundary.
    try std.testing.expectEqual(@as(usize, 4), boundaries.items.len);
    for (boundaries.items) |b| {
        try std.testing.expect(input[b.start] == '<');
        try std.testing.expect(input[b.end] == '>');
    }
}

test "xml_scan.find_tag_boundaries - CGMES-style XML" {
    const gpa = std.testing.allocator;

    const input =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), boundaries.items.len);

    // Verify all boundaries are valid (end > start)
    for (boundaries.items) |boundary| {
        try std.testing.expect(boundary.end > boundary.start);
        try std.testing.expect(input[boundary.start] == '<');
        try std.testing.expect(input[boundary.end] == '>');
    }
}

test "xml_scan.find_tag_boundaries - comment with angle bracket text" {
    const gpa = std.testing.allocator;

    const input = "<root><!-- CN_A <-> CN_B --><child/></root>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), boundaries.items.len);
    try std.testing.expectEqualStrings("<root>", input[boundaries.items[0].start .. boundaries.items[0].end + 1]);
    try std.testing.expectEqualStrings("<!-- CN_A <-> CN_B -->", input[boundaries.items[1].start .. boundaries.items[1].end + 1]);
    try std.testing.expectEqualStrings("<child/>", input[boundaries.items[2].start .. boundaries.items[2].end + 1]);
    try std.testing.expectEqualStrings("</root>", input[boundaries.items[3].start .. boundaries.items[3].end + 1]);
}

test "xml_scan.find_tag_boundaries - empty comment" {
    const gpa = std.testing.allocator;

    const input = "<a><!----></a>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), boundaries.items.len);
    try std.testing.expectEqualStrings("<a>", input[boundaries.items[0].start .. boundaries.items[0].end + 1]);
    try std.testing.expectEqualStrings("<!---->", input[boundaries.items[1].start .. boundaries.items[1].end + 1]);
    try std.testing.expectEqualStrings("</a>", input[boundaries.items[2].start .. boundaries.items[2].end + 1]);
}

test "xml_scan.find_tag_boundaries - multi-line comment" {
    const gpa = std.testing.allocator;

    const input = "<a><!--\nline1 <foo>\nline2 -->\n</a>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), boundaries.items.len);
    try std.testing.expectEqualStrings("<a>", input[boundaries.items[0].start .. boundaries.items[0].end + 1]);
    try std.testing.expectEqualStrings("<!--\nline1 <foo>\nline2 -->", input[boundaries.items[1].start .. boundaries.items[1].end + 1]);
    try std.testing.expectEqualStrings("</a>", input[boundaries.items[2].start .. boundaries.items[2].end + 1]);
}

test "xml_scan.find_tag_boundaries - multiple adjacent comments" {
    const gpa = std.testing.allocator;

    const input = "<!--a--><!--b<x>--><r/>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, input);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), boundaries.items.len);
    try std.testing.expectEqualStrings("<!--a-->", input[boundaries.items[0].start .. boundaries.items[0].end + 1]);
    try std.testing.expectEqualStrings("<!--b<x>-->", input[boundaries.items[1].start .. boundaries.items[1].end + 1]);
    try std.testing.expectEqualStrings("<r/>", input[boundaries.items[2].start .. boundaries.items[2].end + 1]);
}

test "xml_scan.find_tag_boundaries - unterminated comment" {
    const gpa = std.testing.allocator;

    const input = "<a><!-- never closes";

    try std.testing.expectError(error.MalformedXML, xml_scan.find_tag_boundaries(gpa, input));
}

test "xml_scan.extract_tag_type - simple tag" {
    const xml = "<cim:Substation rdf:ID=\"_SS1\">";
    const tag_type = try xml_scan.extract_tag_type(xml, 0);
    try std.testing.expectEqualStrings("Substation", tag_type);
}

test "xml_scan.extract_tag_type - with namespace" {
    const xml = "<cim:VoltageLevel>";
    const tag_type = try xml_scan.extract_tag_type(xml, 0);
    try std.testing.expectEqualStrings("VoltageLevel", tag_type);
}

test "xml_scan.extract_tag_type - no namespace (error)" {
    const xml = "<Substation>"; // No colon!
    const result = xml_scan.extract_tag_type(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "xml_scan.extract_tag_type - colon before tag (handles start_index)" {
    const xml = "prefix:data<cim:Substation>";
    const tag_type = try xml_scan.extract_tag_type(xml, 11); // Points to '<'
    try std.testing.expectEqualStrings("Substation", tag_type);
}

test "xml_scan.extract_tag_type - multi-line tag with newline after name" {
    const xml = "<rdf:RDF\n    xmlns:rdf=\"http://example/\">";
    const tag_type = try xml_scan.extract_tag_type(xml, 0);
    try std.testing.expectEqualStrings("RDF", tag_type);
}

test "xml_scan.extract_tag_type - attribute-less self-closing tag" {
    const xml = "<cim:IdentifiedObject.name/>";
    const tag_type = try xml_scan.extract_tag_type(xml, 0);
    try std.testing.expectEqualStrings("IdentifiedObject.name", tag_type);
}

test "xml_scan.extract_tag_type - tab whitespace after name" {
    const xml = "<cim:Substation\trdf:ID=\"_SS1\">";
    const tag_type = try xml_scan.extract_tag_type(xml, 0);
    try std.testing.expectEqualStrings("Substation", tag_type);
}

test "xml_scan.extract_tag_type - CRLF after name" {
    const xml = "<cim:Substation\r\n    rdf:ID=\"_SS1\">";
    const tag_type = try xml_scan.extract_tag_type(xml, 0);
    try std.testing.expectEqualStrings("Substation", tag_type);
}

test "xml_scan.extract_rdf_id - simple tag" {
    const xml = "<cim:Substation rdf:ID=\"_SS1\">";
    const id = try xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("_SS1", id);
}

test "xml_scan.extract_rdf_id - multiple attributes" {
    const xml = "<cim:Substation name=\"test\" rdf:ID=\"_SS1\" other=\"value\">";
    const id = try xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("_SS1", id);
}

test "xml_scan.extract_rdf_id - with hash prefix" {
    const xml = "<cim:Terminal rdf:ID=\"#_T1\">";
    const id = try xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("#_T1", id);
}

test "xml_scan.extract_rdf_id - self-closing tag" {
    const xml = "<cim:Line rdf:ID=\"_L1\"/>";
    const id = try xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("_L1", id);
}

test "xml_scan.extract_rdf_id - long ID" {
    const xml = "<cim:Substation rdf:ID=\"_Very_Long_Substation_Identifier_12345\">";
    const id = try xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("_Very_Long_Substation_Identifier_12345", id);
}

test "xml_scan.extract_rdf_id - no rdf:ID (error)" {
    const xml = "<cim:Substation name=\"test\">";
    const result = xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.NoRdfId, result);
}

test "xml_scan.extract_rdf_id - malformed (no closing quote)" {
    const xml = "<cim:Substation rdf:ID=\"_SS1>";
    const result = xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "xml_scan.extract_rdf_id - start_index in middle of document" {
    const xml = "some prefix text <cim:Substation rdf:ID=\"_SS1\"> more text";
    const id = try xml_scan.extract_rdf_id(xml, 17); // Points to '<' at position 17
    try std.testing.expectEqualStrings("_SS1", id);
}

test "xml_scan.extract_rdf_id - empty value" {
    const xml = "<cim:Substation rdf:ID=\"\"/>";
    const id = try xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("", id);
}

test "xml_scan.extract_rdf_id - has 'r' but no rdf:ID pattern" {
    const xml = "<cim:Substation random=\"test\">";
    const result = xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.NoRdfId, result);
}

test "xml_scan.extract_rdf_id - pattern appears after tag close" {
    const xml = "<cim:Substation> rdf:ID=\"_SS1\"";
    const result = xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.NoRdfId, result);
}

test "xml_scan.extract_rdf_id - closing quote missing (no quote at all)" {
    const xml = "<cim:Substation rdf:ID=\"_SS1>";
    const result = xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "xml_scan.extract_rdf_id - closing quote after tag boundary" {
    const xml = "<cim:Substation rdf:ID=\"_SS1> later text \"";
    const result = xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "xml_scan.extract_rdf_id - rdf:ID at end of tag with space" {
    const xml = "<cim:Substation name=\"test\" rdf:ID=\"_SS1\" >";
    const id = try xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("_SS1", id);
}

test "xml_scan.extract_rdf_id - multiple 'r' characters before pattern" {
    const xml = "<cim:Substation region=\"west\" resource=\"power\" rdf:ID=\"_SS1\">";
    const id = try xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("_SS1", id);
}

test "xml_scan.extract_rdf_id - pattern lookalike (rdf:resource not rdf:ID)" {
    const xml = "<cim:Terminal rdf:resource=\"#_CN1\">";
    const result = xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.NoRdfId, result);
}

test "xml_scan.extract_rdf_id - value contains equals sign" {
    const xml = "<cim:Equation rdf:ID=\"x=y+z\">";
    const id = try xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectEqualStrings("x=y+z", id);
}

test "xml_scan.extract_rdf_id - value contains angle brackets (invalid XML)" {
    // Angle brackets in attribute values are invalid XML
    // Must be escaped as &lt; and &gt;
    const xml = "<cim:Formula rdf:ID=\"a<b>c\">";
    const result = xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "xml_scan.extract_rdf_id - no tag close bracket" {
    const xml = "<cim:Substation rdf:ID=\"_SS1\"";
    const result = xml_scan.extract_rdf_id(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

// ============================================================================
// extract_rdf_resource Tests
// ============================================================================

test "xml_scan.extract_rdf_resource - simple resource extraction" {
    const xml = "<cim:Substation.Region rdf:resource=\"#_Region1\"/>";
    const resource = try xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Region1", resource.?);
}

test "xml_scan.extract_rdf_resource - multiple attributes" {
    const xml = "<cim:Terminal name=\"test\" rdf:resource=\"#_T1\" other=\"value\"/>";
    const resource = try xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_T1", resource.?);
}

test "xml_scan.extract_rdf_resource - with hash prefix" {
    const xml = "<cim:Property rdf:resource=\"#_LocalRef\"/>";
    const resource = try xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_LocalRef", resource.?);
}

test "xml_scan.extract_rdf_resource - without hash prefix" {
    const xml = "<cim:Property rdf:resource=\"_ExternalRef\"/>";
    const resource = try xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("_ExternalRef", resource.?);
}

test "xml_scan.extract_rdf_resource - non-self-closing tag" {
    const xml = "<cim:Property rdf:resource=\"#_Ref1\"></cim:Property>";
    const resource = try xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Ref1", resource.?);
}

test "xml_scan.extract_rdf_resource - empty value" {
    const xml = "<cim:Property rdf:resource=\"\"/>";
    const resource = try xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("", resource.?);
}

test "xml_scan.extract_rdf_resource - no rdf:resource returns null" {
    const xml = "<cim:Substation name=\"test\"/>";
    const resource = try xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expectEqual(@as(?[]const u8, null), resource);
}

test "xml_scan.extract_rdf_resource - full URI" {
    const xml = "<cim:Property rdf:resource=\"http://example.com/resource#_R1\"/>";
    const resource = try xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("http://example.com/resource#_R1", resource.?);
}

test "xml_scan.extract_rdf_resource - special characters in value" {
    const xml = "<cim:Property rdf:resource=\"#_Node-123.456_v2\"/>";
    const resource = try xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Node-123.456_v2", resource.?);
}

test "xml_scan.extract_rdf_resource - malformed (no closing quote)" {
    const xml = "<cim:Property rdf:resource=\"#_Ref1/>";
    const result = xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "xml_scan.extract_rdf_resource - closing quote after tag boundary" {
    const xml = "<cim:Property rdf:resource=\"#_Ref1> later text \"";
    const result = xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "xml_scan.extract_rdf_resource - pattern appears after tag close" {
    const xml = "<cim:Property> rdf:resource=\"#_Ref1\"";
    const resource = try xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expectEqual(@as(?[]const u8, null), resource);
}

test "xml_scan.extract_rdf_resource - no tag close bracket" {
    const xml = "<cim:Property rdf:resource=\"#_Ref1\"";
    const result = xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "xml_scan.extract_rdf_resource - start_index in middle of document" {
    const xml = "prefix text <cim:Property rdf:resource=\"#_Ref1\"/> more text";
    const resource = try xml_scan.extract_rdf_resource(xml, 12);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Ref1", resource.?);
}

test "xml_scan.extract_rdf_resource - rdf:resource at end of tag" {
    const xml = "<cim:Property name=\"test\" other=\"value\" rdf:resource=\"#_Ref1\" />";
    const resource = try xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("#_Ref1", resource.?);
}

test "xml_scan.extract_rdf_resource - value contains equals sign" {
    const xml = "<cim:Property rdf:resource=\"x=y+z\"/>";
    const resource = try xml_scan.extract_rdf_resource(xml, 0);
    try std.testing.expect(resource != null);
    try std.testing.expectEqualStrings("x=y+z", resource.?);
}

// ============================================================================
// extract_rdf_about Tests
// ============================================================================

test "xml_scan.extract_rdf_about - simple FullModel tag" {
    const xml = "<md:FullModel rdf:about=\"urn:uuid:ieee9cdf_N_EQUIPMENT\">";
    const about = try xml_scan.extract_rdf_about(xml, 0);
    try std.testing.expectEqualStrings("urn:uuid:ieee9cdf_N_EQUIPMENT", about);
}

test "xml_scan.extract_rdf_about - with timestamp in value" {
    const xml = "<md:FullModel rdf:about=\"urn:uuid:ieee9cdf_N_EQUIPMENT_2009-04-26T00:00:00Z_1_1D__FM\">";
    const about = try xml_scan.extract_rdf_about(xml, 0);
    try std.testing.expectEqualStrings("urn:uuid:ieee9cdf_N_EQUIPMENT_2009-04-26T00:00:00Z_1_1D__FM", about);
}

test "xml_scan.extract_rdf_about - multiple attributes" {
    const xml = "<md:FullModel xmlns:md=\"http://example.com\" rdf:about=\"urn:uuid:test\" other=\"value\">";
    const about = try xml_scan.extract_rdf_about(xml, 0);
    try std.testing.expectEqualStrings("urn:uuid:test", about);
}

test "xml_scan.extract_rdf_about - self-closing tag" {
    const xml = "<md:Model rdf:about=\"urn:uuid:model123\"/>";
    const about = try xml_scan.extract_rdf_about(xml, 0);
    try std.testing.expectEqualStrings("urn:uuid:model123", about);
}

test "xml_scan.extract_rdf_about - no rdf:about (error)" {
    const xml = "<md:FullModel name=\"test\">";
    const result = xml_scan.extract_rdf_about(xml, 0);
    try std.testing.expectError(error.NoRdfAbout, result);
}

test "xml_scan.extract_rdf_about - malformed (no closing quote)" {
    const xml = "<md:FullModel rdf:about=\"urn:uuid:test>";
    const result = xml_scan.extract_rdf_about(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "xml_scan.extract_rdf_about - closing quote after tag boundary" {
    const xml = "<md:FullModel rdf:about=\"urn:uuid:test> later text \"";
    const result = xml_scan.extract_rdf_about(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "xml_scan.extract_rdf_about - no tag close bracket" {
    const xml = "<md:FullModel rdf:about=\"urn:uuid:test\"";
    const result = xml_scan.extract_rdf_about(xml, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "xml_scan.extract_rdf_about - start_index in middle of document" {
    const xml = "prefix text <md:FullModel rdf:about=\"urn:uuid:test\"> more text";
    const about = try xml_scan.extract_rdf_about(xml, 12);
    try std.testing.expectEqualStrings("urn:uuid:test", about);
}

test "xml_scan.extract_rdf_about - empty value" {
    const xml = "<md:FullModel rdf:about=\"\"/>";
    const about = try xml_scan.extract_rdf_about(xml, 0);
    try std.testing.expectEqualStrings("", about);
}

test "xml_scan.extract_rdf_about - pattern appears after tag close" {
    const xml = "<md:FullModel> rdf:about=\"urn:uuid:test\"";
    const result = xml_scan.extract_rdf_about(xml, 0);
    try std.testing.expectError(error.NoRdfAbout, result);
}

test "xml_scan.extract_rdf_about - has rdf:ID but not rdf:about" {
    const xml = "<cim:Substation rdf:ID=\"_SS1\">";
    const result = xml_scan.extract_rdf_about(xml, 0);
    try std.testing.expectError(error.NoRdfAbout, result);
}

test "xml_scan.find_closing_tag - simple opening and closing tag" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Root></cim:Root>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing_idx = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 1), closing_idx);
}

test "xml_scan.find_closing_tag - tag with text content" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Name>North Station</cim:Name>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing_idx = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 1), closing_idx);
}

test "xml_scan.find_closing_tag - nested different tags" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Root><cim:Child>text</cim:Child></cim:Root>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Find closing tag for Root (index 0) -> should be index 3
    const root_closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 3), root_closing);

    // Find closing tag for Child (index 1) -> should be index 2
    const child_closing = try xml_scan.find_closing_tag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 2), child_closing);
}

test "xml_scan.find_closing_tag - nested same-name tags (depth counting)" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Item><cim:Item></cim:Item></cim:Item>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Find closing tag for outer Item (index 0) -> should be index 3
    const outer_closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 3), outer_closing);

    // Find closing tag for inner Item (index 1) -> should be index 2
    const inner_closing = try xml_scan.find_closing_tag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 2), inner_closing);
}

test "xml_scan.find_closing_tag - deeply nested same-name tags" {
    const gpa = std.testing.allocator;

    const xml = "<ns:a><ns:a><ns:a></ns:a></ns:a></ns:a>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Outermost (index 0) -> closing at index 5
    const outer = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 5), outer);

    // Middle (index 1) -> closing at index 4
    const middle = try xml_scan.find_closing_tag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 4), middle);

    // Innermost (index 2) -> closing at index 3
    const inner = try xml_scan.find_closing_tag(xml, boundaries.items, 2);
    try std.testing.expectEqual(@as(u32, 3), inner);
}

test "xml_scan.find_closing_tag - CGMES example with properties" {
    const gpa = std.testing.allocator;

    const xml =
        \\<cim:Substation rdf:ID="_SS1">
        \\  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
        \\  <cim:Substation.Region rdf:resource="#_R1"/>
        \\</cim:Substation>
    ;

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Find closing for Substation (index 0) -> should be last tag (index 4)
    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 4), closing);

    // Find closing for IdentifiedObject.name (index 1) -> should be index 2
    const name_closing = try xml_scan.find_closing_tag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 2), name_closing);
}

test "xml_scan.find_closing_tag - self-closing tag returns error" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Terminal rdf:resource=\"#_T1\"/>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const result = xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectError(error.SelfClosingTag, result);
}

test "xml_scan.find_closing_tag - self-closing tag with space before slash" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Item />";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const result = xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectError(error.SelfClosingTag, result);
}

test "xml_scan.find_closing_tag - no closing tag (error)" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Root><cim:Child></cim:Child>"; // Root not closed

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const result = xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectError(error.NoClosingTag, result);
}

test "xml_scan.build_closing_index - mismatched nesting returns MalformedXML" {
    const gpa = std.testing.allocator;
    const xml = "<cim:Root><cim:Child></cim:Root></cim:Child>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const result = xml_scan.build_closing_index(gpa, xml, boundaries.items);
    try std.testing.expectError(error.MalformedXML, result);
}

test "xml_scan.build_closing_index - unclosed opener returns MalformedXML" {
    const gpa = std.testing.allocator;
    const xml = "<cim:Root><cim:Child></cim:Child>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const result = xml_scan.build_closing_index(gpa, xml, boundaries.items);
    try std.testing.expectError(error.MalformedXML, result);
}

test "xml_scan.find_closing_tag - multiple same-name tags at same level" {
    const gpa = std.testing.allocator;

    const xml = "<ns:root><ns:item>1</ns:item><ns:item>2</ns:item></ns:root>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // First item (index 1) -> closes at index 2
    const first_item = try xml_scan.find_closing_tag(xml, boundaries.items, 1);
    try std.testing.expectEqual(@as(u32, 2), first_item);

    // Second item (index 3) -> closes at index 4
    const second_item = try xml_scan.find_closing_tag(xml, boundaries.items, 3);
    try std.testing.expectEqual(@as(u32, 4), second_item);

    // Root (index 0) -> closes at index 5
    const root = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 5), root);
}

test "xml_scan.find_closing_tag - mixed self-closing and normal tags" {
    const gpa = std.testing.allocator;

    const xml = "<ns:root><ns:item/><ns:child>text</ns:child></ns:root>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Root (index 0) -> closes at index 4 (self-closing item at index 1 doesn't affect depth)
    const root_closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 4), root_closing);

    // Child (index 2) -> closes at index 3
    const child_closing = try xml_scan.find_closing_tag(xml, boundaries.items, 2);
    try std.testing.expectEqual(@as(u32, 3), child_closing);

    // Item is self-closing
    const item_result = xml_scan.find_closing_tag(xml, boundaries.items, 1);
    try std.testing.expectError(error.SelfClosingTag, item_result);
}

test "xml_scan.find_closing_tag - tag with attributes" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Substation rdf:ID=\"_SS1\" name=\"test\"></cim:Substation>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 1), closing);
}

test "xml_scan.find_closing_tag - empty tag" {
    const gpa = std.testing.allocator;

    const xml = "<cim:Value></cim:Value>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 1), closing);
}
test "xml_scan.find_needle_anchored - matches std.mem.indexOf, including false anchors" {
    const needle = "rdf:ID=\"";
    const cases = [_][]const u8{
        // Plain hit, hit at offset 0, hit at the very end of the haystack.
        "<cim:Substation rdf:ID=\"_SS1\">",
        "rdf:ID=\"_a\">",
        "<cim:X rdf:ID=\"",
        // False anchors on 'r' before the real match -- the case a naive
        // anchored scan gets wrong by giving up at the first candidate.
        "<cim:X r rdf:ID=\"_a\">",
        "<cim:X rdf: rdf:ID=\"_a\">",
        "<cim:X rdf:IDx=\"1\" rdf:ID=\"_a\">",
        "rrrrrrdf:ID=\"_a\">",
        // No match at all, including a truncated needle at the end.
        "<cim:X rdf:about=\"#_a\"/>",
        "<cim:X rdf:ID=",
        "rdf",
        "",
    };
    for (cases) |haystack| {
        try std.testing.expectEqual(
            std.mem.indexOf(u8, haystack, needle),
            xml_scan.find_needle_anchored(haystack, needle),
        );
    }
}

test "xml_scan.index_of_any_pos_table/simd - match std.mem.indexOfAnyPos" {
    const set = " \t\r\n>/";
    const cases = [_][]const u8{
        "<cim:Substation rdf:ID=\"_SS1\">",
        "<cim:X/>",
        "<rdf:RDF\n  xmlns=\"x\">",
        "cim:NoTerminatorHere",
        ">",
        "",
        // Longer than one vector, so the SIMD path runs and then hands a tail
        // to the scalar table: a hit in the first chunk, a hit only in the
        // tail, every whitespace form, and no hit at all.
        "<cim:VeryLongTagNameThatExceedsThirtyTwoBytesForSure>",
        "cim:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa>",
        "cim:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t",
        "cim:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r",
        "cim:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    for (cases) |haystack| {
        var start: usize = 0;
        while (start <= haystack.len) : (start += 1) {
            const want = std.mem.indexOfAnyPos(u8, haystack, start, set);
            try std.testing.expectEqual(want, xml_scan.index_of_any_pos_table(haystack, start, set));
            try std.testing.expectEqual(want, xml_scan.index_of_any_pos_simd(haystack, start, set));
        }
    }
}
