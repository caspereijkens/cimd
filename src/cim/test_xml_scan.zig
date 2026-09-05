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
    var error_offset: xml_scan.MalformedXML = .{};

    try std.testing.expectError(
        error.MalformedXML,
        xml_scan.find_tag_boundaries_with_error_offset(gpa, input, &error_offset),
    );
    try std.testing.expectEqual(@as(u32, 0), error_offset.offset);
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

test "xml_scan.extract_tag_type - default namespace element" {
    const xml = "<Substation>";
    const tag_type = try xml_scan.extract_tag_type(xml, 0);
    try std.testing.expectEqualStrings("Substation", tag_type);
}

test "xml_scan.extract_tag_type - unprefixed element with prefixed attribute" {
    const xml = "<EffectivityResult rdf:ID=\"_result\">";
    const tag_type = try xml_scan.extract_tag_type(xml, 0);
    try std.testing.expectEqualStrings("EffectivityResult", tag_type);
}

test "xml_scan.extract_tag_type - malformed names" {
    const cases = [_]struct { xml: []const u8, start_idx: u32 }{
        .{ .xml = "", .start_idx = 0 },
        .{ .xml = "prefix", .start_idx = 6 },
        .{ .xml = "<", .start_idx = 0 },
        .{ .xml = "</", .start_idx = 0 },
        .{ .xml = "<>", .start_idx = 0 },
        .{ .xml = "<:Name>", .start_idx = 0 },
        .{ .xml = "<Name", .start_idx = 0 },
        .{ .xml = "<cim:>", .start_idx = 0 },
        .{ .xml = "<cim:Name", .start_idx = 0 },
        .{ .xml = "<?xml version=\"1.0\"?>", .start_idx = 0 },
        .{ .xml = "<![CDATA[text]]>", .start_idx = 0 },
    };
    for (cases) |case| {
        try std.testing.expectError(
            error.MalformedTag,
            xml_scan.extract_tag_type(case.xml, case.start_idx),
        );
    }
}

test "xml_scan.extract_tag_type - name and terminator across every chunk alignment" {
    // The prefix colon and the name terminator are found in a single SIMD
    // sweep, so a name whose two hits fall in the same 32-byte chunk takes a
    // different path through it than one that straddles a chunk boundary or
    // resolves in the scalar tail. Slide each case past VECTOR_LEN to cover
    // all three.
    const cases = [_]struct { tag: []const u8, name: []const u8, terminator: u8 }{
        .{ .tag = "<cim:ACLineSegment.r>", .name = "ACLineSegment.r", .terminator = '>' },
        .{ .tag = "<ACLineSegment.r>", .name = "ACLineSegment.r", .terminator = '>' },
        .{
            .tag = "<cim:GeneratingUnit.maxOperatingP rdf:ID=\"_1\">",
            .name = "GeneratingUnit.maxOperatingP",
            .terminator = ' ',
        },
        .{ .tag = "</cim:Substation>", .name = "Substation", .terminator = '>' },
        .{ .tag = "<cim:X/>", .name = "X", .terminator = '/' },
    };
    var buf: [256]u8 = undefined;
    for (cases) |case| {
        var pad: u32 = 0;
        while (pad <= xml_scan.VECTOR_LEN + 8) : (pad += 1) {
            @memset(buf[0..pad], ' ');
            @memcpy(buf[pad..][0..case.tag.len], case.tag);
            const total = pad + @as(u32, @intCast(case.tag.len));
            const got = try xml_scan.extract_tag_type_terminated(buf[0..total], pad);
            try std.testing.expectEqualStrings(case.name, got.name);
            try std.testing.expectEqual(case.terminator, got.terminator);
        }
    }
}

test "xml_scan.find_tag_boundaries - DOCTYPE with an internal subset is one boundary" {
    // The entity declaration's '<' comes before the DOCTYPE's own '>', so
    // pairing delimiters naively splits this into two overlapping boundaries.
    // It is well-formed XML and must be spanned, not rejected.
    const gpa = std.testing.allocator;
    const xml =
        \\<!DOCTYPE rdf:RDF [<!ENTITY label "Station">]>
        \\<rdf:RDF><cim:Substation rdf:ID="_1"></cim:Substation></rdf:RDF>
    ;
    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const doctype = boundaries.items[0];
    try std.testing.expectEqualStrings(
        "<!DOCTYPE rdf:RDF [<!ENTITY label \"Station\">]>",
        xml[doctype.start .. doctype.end + 1],
    );
    try std.testing.expect(!xml_scan.is_element_open_tag(xml, doctype));

    // And the document still parses through the closing index.
    const closing = try xml_scan.build_closing_index(gpa, xml, boundaries.items);
    defer gpa.free(closing);
}

test "xml_scan.find_tag_boundaries - CDATA holding '<' is one boundary" {
    const gpa = std.testing.allocator;
    const xml = "<a><![CDATA[x<y>z]]></a>";
    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), boundaries.items.len);
    const cdata = boundaries.items[1];
    try std.testing.expectEqualStrings(
        "<![CDATA[x<y>z]]>",
        xml[cdata.start .. cdata.end + 1],
    );
}

test "xml_scan.build_closing_index - end tags must repeat the opener's QName" {
    // Nesting is matched on the qualified name. Local names alone would balance
    // all three of these, because `extract_tag_type` strips the prefix.
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        "<rdf:RDF><cim:Substation rdf:ID=\"_1\"></Substation></rdf:RDF>",
        "<rdf:RDF><cim:Substation rdf:ID=\"_1\"></md:Substation></rdf:RDF>",
        "<rdf:RDF><Substation rdf:ID=\"_1\"></cim:Substation></rdf:RDF>",
    };
    for (cases) |xml| {
        var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
        defer boundaries.deinit(gpa);
        try std.testing.expectError(
            error.MalformedXML,
            xml_scan.build_closing_index(gpa, xml, boundaries.items),
        );
    }

    // An unprefixed pair is still well-formed: the default namespace is a
    // namespace like any other.
    const ok = "<RDF><Substation rdf:ID=\"_1\"></Substation></RDF>";
    var boundaries = try xml_scan.find_tag_boundaries(gpa, ok);
    defer boundaries.deinit(gpa);
    const closing = try xml_scan.build_closing_index(gpa, ok, boundaries.items);
    defer gpa.free(closing);
    try std.testing.expectEqual(@as(u32, 2), closing[1]);
}

test "xml_scan.extract_tag_type - a second colon is not a QName" {
    // The sweep returns the first two hits from the terminator set. When the
    // first is the prefix colon, the second is the name's terminator -- and a
    // colon is not a legal one.
    try std.testing.expectError(
        error.MalformedTag,
        xml_scan.extract_tag_type("<a:b:c>", 0),
    );
    try std.testing.expectError(
        error.MalformedTag,
        xml_scan.extract_tag_type("<cim:Sub:Station rdf:ID=\"_1\">", 0),
    );
}

test "xml_scan.extract_tag_type - scan stays within its own tag" {
    const xml = "<First><cim:Second>";
    const first = try xml_scan.extract_tag_type(xml, 0);
    const second = try xml_scan.extract_tag_type(xml, 7);

    try std.testing.expectEqualStrings("First", first);
    try std.testing.expectEqualStrings("Second", second);
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

test "xml_scan.find_closing_tag - comment cannot alter same-name depth" {
    const gpa = std.testing.allocator;
    const xml = "<cim:Name><!--cim:Name ignored--></cim:Name>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing_idx = try xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectEqual(@as(u32, 2), closing_idx);
}

test "xml_scan.find_closing_tag - non-element opener returns MalformedTag" {
    const gpa = std.testing.allocator;
    const xml = "<!--cim:Name-->";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const result = xml_scan.find_closing_tag(xml, boundaries.items, 0);
    try std.testing.expectError(error.MalformedTag, result);
}

test "xml_scan.find_closing_tag - unnameable element aborts the search" {
    const gpa = std.testing.allocator;
    const xml = "<cim:Name><></cim:Name>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // `<>` is an element boundary whose name will not parse. Skipping it would
    // return 2 -- the right answer read out of a document the scanner could not
    // fully read. Same rule as `build_closing_index`.
    try std.testing.expectError(
        error.MalformedTag,
        xml_scan.find_closing_tag(xml, boundaries.items, 0),
    );
}

test "xml_scan.find_closing_tag - comments and PIs are still skipped" {
    const gpa = std.testing.allocator;
    const xml = "<cim:Name><!-- cim:Name --><?pi cim:Name?></cim:Name>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Strictness is about elements. A non-element is not tolerated, it simply is
    // not part of the nesting -- and must not be mistaken for a nested opener.
    try std.testing.expectEqual(
        @as(u32, 3),
        try xml_scan.find_closing_tag(xml, boundaries.items, 0),
    );
}

test "xml_scan.build_closing_index - mismatched nesting returns MalformedXML" {
    const gpa = std.testing.allocator;
    const xml = "<cim:Root><cim:Child></cim:Root></cim:Child>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    var error_offset: xml_scan.MalformedXML = .{};
    const result = xml_scan.build_closing_index_with_error_offset(gpa, xml, boundaries.items, &error_offset);
    try std.testing.expectError(error.MalformedXML, result);
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, xml, "</cim:Root>").?)),
        error_offset.offset,
    );
}

test "xml_scan.build_closing_index - unclosed opener returns MalformedXML" {
    const gpa = std.testing.allocator;
    const xml = "<cim:Root><cim:Child></cim:Child>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    var error_offset: xml_scan.MalformedXML = .{};
    const result = xml_scan.build_closing_index_with_error_offset(gpa, xml, boundaries.items, &error_offset);
    try std.testing.expectError(error.MalformedXML, result);
    // The outermost unclosed opener, not end-of-input: a caller mapping the
    // offset back to a line (or to a file segment) must land on the real defect.
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, xml, "<cim:Root>").?)),
        error_offset.offset,
    );
}

test "xml_scan.build_closing_index - malformed closer cannot close an opener" {
    const gpa = std.testing.allocator;
    const xml = "<cim:Root></cim:Root/>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    var error_offset: xml_scan.MalformedXML = .{};
    const result = xml_scan.build_closing_index_with_error_offset(
        gpa,
        xml,
        boundaries.items,
        &error_offset,
    );
    try std.testing.expectError(error.MalformedXML, result);
    // The offset names the malformed closer itself, not the opener it failed to
    // close: `</cim:Root/>` is the tag the user has to fix.
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, xml, "</cim:Root/>").?)),
        error_offset.offset,
    );
}

test "xml_scan.build_closing_index - unnameable element fails the document" {
    const gpa = std.testing.allocator;
    const xml = "<cim:Root><></cim:Root>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    var error_offset: xml_scan.MalformedXML = .{};
    const result = xml_scan.build_closing_index_with_error_offset(
        gpa,
        xml,
        boundaries.items,
        &error_offset,
    );
    // This pass is the gate every later consumer trusts, so an element it cannot
    // name fails the parse here rather than being quietly dropped from the
    // document that gets handed on.
    try std.testing.expectError(error.MalformedXML, result);
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, xml, "<>").?)),
        error_offset.offset,
    );
}

test "xml_scan.build_closing_index - non-elements are skipped, not rejected" {
    const gpa = std.testing.allocator;
    const xml = "<cim:Root><!-- c --><?pi x?><cim:Child/></cim:Root>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing_for = try xml_scan.build_closing_index(gpa, xml, boundaries.items);
    defer gpa.free(closing_for);

    // Comment, PI and self-closing element all point at themselves; only the
    // real pair is matched. Strict about elements, silent about non-elements.
    try std.testing.expectEqualSlices(u32, &.{ 4, 1, 2, 3, 4 }, closing_for);
}

test "xml_scan.build_closing_index - default namespace elements balance" {
    const gpa = std.testing.allocator;
    const xml =
        "<rdf:RDF xmlns=\"http://iec.ch/TC57/2013/CIM-schema-cim16#\" " ++
        "xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" ++
        "<EffectivityResult rdf:ID=\"_result\">" ++
        "<EffectivityResult.CBCO rdf:resource=\"#_cbco\"/>" ++
        "</EffectivityResult></rdf:RDF>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    const closing_for = try xml_scan.build_closing_index(gpa, xml, boundaries.items);
    defer gpa.free(closing_for);

    try std.testing.expectEqualSlices(u32, &.{ 4, 3, 2, 3, 4 }, closing_for);
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
        }
    }
}

test "find_tag_boundaries - '<' inside a tag is rejected" {
    const gpa = std.testing.allocator;
    // Left alone, `<m>` here becomes a second boundary starting *inside*
    // `<cim:P <m>`, and the overlap panics whatever slices between the two.
    const xml = "<rdf:RDF><cim:S rdf:ID=\"_1\"><cim:P <m>/></cim:P></cim:S></rdf:RDF>";

    var error_offset: xml_scan.MalformedXML = .{};
    try std.testing.expectError(
        error.MalformedXML,
        xml_scan.find_tag_boundaries_with_error_offset(gpa, xml, &error_offset),
    );
    // The offset names the offending inner '<', not the tag that contains it.
    try std.testing.expectEqual(
        @as(u32, @intCast(std.mem.indexOf(u8, xml, "<m>").?)),
        error_offset.offset,
    );
}

test "find_tag_boundaries - '<' inside a comment is still legal" {
    const gpa = std.testing.allocator;
    // The distinction that makes the rule above correct: '<' is legal inside a
    // comment and illegal inside a tag, so only one of the two is rejected.
    const xml = "<rdf:RDF><!-- <cim:S rdf:ID=\"_x\"> --><cim:S rdf:ID=\"_1\"/></rdf:RDF>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), boundaries.items.len);
    try std.testing.expectEqualStrings(
        "<!-- <cim:S rdf:ID=\"_x\"> -->",
        xml[boundaries.items[1].start .. boundaries.items[1].end + 1],
    );
}

test "find_tag_boundaries - boundaries never overlap" {
    const gpa = std.testing.allocator;
    const xml =
        "<?xml version=\"1.0\"?><rdf:RDF><!-- <a> --><cim:S rdf:ID=\"_1\">" ++
        "<cim:S.name>x</cim:S.name><cim:S.R rdf:resource=\"#_R\"/></cim:S></rdf:RDF>";

    var boundaries = try xml_scan.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // The property the postcondition in `find_tag_boundaries` asserts, stated
    // once as a test so it is visible to a reader who never trips the assert.
    for (boundaries.items[1..], 1..) |t, i| {
        try std.testing.expect(t.start > boundaries.items[i - 1].end);
    }
}
