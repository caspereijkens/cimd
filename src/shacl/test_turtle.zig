//! Tests for the Turtle tokenizer + triple iterator (turtle.zig).
//!
//! Positive and negative space, exhaustively: every accepted construct has a
//! test, and every rejected construct has a test asserting the precise error
//! and its line number; data crossing the valid/invalid boundary is where
//! the bugs are.

const std = @import("std");
const turtle = @import("turtle.zig");
const Turtle = turtle.Turtle;
const Triple = turtle.Triple;
const Term = turtle.Term;
const Iri = turtle.Iri;

const testing = std.testing;

/// Parse the whole source, returning owned triples. Fails the test on any
/// parse error, so error-path tests use expect_parse_error instead.
fn parse_all(gpa: std.mem.Allocator, source: []const u8) ![]Triple {
    var parser = Turtle.init(source, "test.ttl");
    var triples: std.ArrayList(Triple) = .empty;
    errdefer triples.deinit(gpa);
    while (try parser.next()) |triple| try triples.append(gpa, triple);
    return triples.toOwnedSlice(gpa);
}

/// Assert parsing fails with exactly `expected` on 1-based line
/// `expected_line`.
fn expect_parse_error(
    source: []const u8,
    expected: turtle.Error,
    expected_line: u32,
) !void {
    var parser = Turtle.init(source, "test.ttl");
    while (parser.next()) |triple_opt| {
        if (triple_opt == null) return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(expected, err);
        try testing.expectEqual(expected_line, parser.line);
    }
}

fn expect_iri(term: Term, namespace: []const u8, local: []const u8) !void {
    try testing.expect(term == .iri);
    try testing.expectEqualStrings(namespace, term.iri.namespace);
    try testing.expectEqualStrings(local, term.iri.local);
}

fn expect_literal(term: Term, kind: turtle.Literal.Kind, value: []const u8) !void {
    try testing.expect(term == .literal);
    try testing.expectEqual(kind, term.literal.kind);
    try testing.expectEqualStrings(value, term.literal.value);
}

fn expect_blank(term: Term) !u32 {
    try testing.expect(term == .blank);
    return term.blank;
}

// ── Valid space ───────────────────────────────────────────────────────────

test "single triple with full IRIs splits namespace and local" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa, "<http://ex#s> <http://ex/p> <urn:uuid:42> .");
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 1), triples.len);
    try expect_iri(triples[0].subject, "http://ex", "s");
    try testing.expectEqualStrings("http://ex", triples[0].predicate.namespace);
    try testing.expectEqualStrings("p", triples[0].predicate.local);
    // No '#' or '/' separator: the whole IRI is the local name.
    try expect_iri(triples[0].object, "", "urn:uuid:42");
}

test "prefixed names resolve; empty prefix and empty local are legal" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\@prefix : <http://ex#> .
        \\:s sh:prefixes sh: .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 1), triples.len);
    try expect_iri(triples[0].subject, "http://ex", "s");
    try testing.expectEqualStrings(turtle.shacl_namespace, triples[0].predicate.namespace);
    try testing.expectEqualStrings("prefixes", triples[0].predicate.local);
    // `sh:` with an empty local names the namespace itself.
    try expect_iri(triples[0].object, turtle.shacl_namespace, "");
}

test "SPARQL-style PREFIX and BASE directives take no dot" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\PREFIX ex: <http://ex#>
        \\base <http://base/doc>
        \\ex:s ex:p <#frag> .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 1), triples.len);
    try expect_iri(triples[0].object, "http://base/doc", "frag");
}

test "@base resolves relative IRIs by identity" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@base <https://ap-con.cim4.eu/AssessedElement-Simple/2.4> .
        \\@prefix owl: <http://www.w3.org/2002/07/owl#> .
        \\<#Ontology> owl:versionIRI <2.4/2.4> .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 1), triples.len);
    const base = "https://ap-con.cim4.eu/AssessedElement-Simple/2.4";
    try expect_iri(triples[0].subject, base, "Ontology");
    try expect_iri(triples[0].object, base, "2.4/2.4");
}

test "the a keyword is rdf:type" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\@prefix ex: <http://ex#> .
        \\ex:shape a sh:NodeShape .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 1), triples.len);
    try testing.expect(triples[0].predicate.eql(turtle.rdf_type));
    try expect_iri(triples[0].object, turtle.shacl_namespace, "NodeShape");
}

test "predicate lists, object lists, and a trailing semicolon" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix ex: <http://ex#> .
        \\ex:s ex:p ex:a , ex:b ;
        \\     ex:q ex:c ;
        \\     .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 3), triples.len);
    try expect_iri(triples[0].object, "http://ex", "a");
    try expect_iri(triples[1].object, "http://ex", "b");
    try testing.expectEqualStrings("p", triples[1].predicate.local);
    try testing.expectEqualStrings("q", triples[2].predicate.local);
    try expect_iri(triples[2].object, "http://ex", "c");
    // All three share the subject.
    for (triples) |t| try expect_iri(t.subject, "http://ex", "s");
}

test "string literals: escapes kept raw, language tag dropped, datatype kept" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix ex: <http://ex#> .
        \\@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
        \\ex:s ex:p "a\"b\\c\n" , "ENTSO-E"@en , "2025-09-11"^^xsd:date .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 3), triples.len);
    // Escapes are validated but not decoded; the raw lexical form.
    try expect_literal(triples[0].object, .string, "a\\\"b\\\\c\\n");
    try testing.expectEqual(@as(?Iri, null), triples[0].object.literal.datatype);
    try expect_literal(triples[1].object, .string, "ENTSO-E");
    try expect_literal(triples[2].object, .string, "2025-09-11");
    const datatype = triples[2].object.literal.datatype.?;
    try testing.expectEqualStrings(turtle.xsd_namespace, datatype.namespace);
    try testing.expectEqualStrings("date", datatype.local);
}

test "long strings span lines, embed quotes, and count lines" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix ex: <http://ex#> .
        \\ex:s ex:p """SELECT $this
        \\WHERE { "x" ""quoted"" }""" .
        \\ex:s ex:q ex:o .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 2), triples.len);
    try expect_literal(
        triples[0].object,
        .string,
        "SELECT $this\nWHERE { \"x\" \"\"quoted\"\" }",
    );
    // The newline inside the long string was counted: the second statement
    // sits on line 4.
    try testing.expectEqual(@as(u32, 4), triples[1].line);
}

test "unicode escapes validate in strings; escaped IRIs are unsupported" {
    const gpa = testing.allocator;
    // Regular (escape-processed) Zig literals: "\\u0041" is backslash-u-0041.
    const source = "@prefix ex: <http://ex#> .\n" ++
        "ex:s ex:p \"u\\u0041U\\U00000042\" .";
    const triples = try parse_all(gpa, source);
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 1), triples.len);
    try expect_literal(triples[0].object, .string, "u\\u0041U\\U00000042");

    // IRIs are split and matched as raw bytes, so an undecoded escape
    // would silently match nothing, so the tokenizer rejects it.
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\n" ++ "ex:s ex:p <http://ex#\\u0043> .",
        error.UnsupportedConstruct,
        2,
    );
}

test "decode_escape covers every accepted form" {
    const cases = [_]struct { raw: []const u8, bytes: []const u8 }{
        .{ .raw = "\\n", .bytes = "\n" },
        .{ .raw = "\\r", .bytes = "\r" },
        .{ .raw = "\\t", .bytes = "\t" },
        .{ .raw = "\\\"", .bytes = "\"" },
        .{ .raw = "\\\\", .bytes = "\\" },
        .{ .raw = "\\u0041", .bytes = "A" },
        .{ .raw = "\\u00e9", .bytes = "é" }, // 2-byte UTF-8
        .{ .raw = "\\u20AC", .bytes = "€" }, // 3-byte UTF-8
        .{ .raw = "\\U0001F600", .bytes = "😀" }, // 4-byte UTF-8
    };
    for (cases) |case| {
        const escape = turtle.decode_escape(case.raw, 0);
        try testing.expectEqual(@as(u8, @intCast(case.raw.len)), escape.consumed);
        try testing.expectEqualStrings(case.bytes, escape.bytes[0..escape.written]);
    }
    // Offset decoding: the escape need not start the string.
    const mid = turtle.decode_escape("ab\\nc", 2);
    try testing.expectEqualStrings("\n", mid.bytes[0..mid.written]);
}

test "escapes naming impossible codepoints fail at parse with their line" {
    // Hex digits alone cannot make a codepoint: a surrogate half and
    // beyond-U+10FFFF values are rejected while the line is still known.
    const prefix = "@prefix ex: <http://ex#> .\n";
    try expect_parse_error(prefix ++ "ex:s ex:p \"a\\uD800\" .", error.InvalidEscape, 2);
    try expect_parse_error(prefix ++ "ex:s ex:p \"a\\U00110000\" .", error.InvalidEscape, 2);
    try expect_parse_error(prefix ++ "ex:s ex:p \"a\\UFFFFFFFF\" .", error.InvalidEscape, 2);
}

test "numeric and boolean literals, including numbers glued to punctuation" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix ex: <http://ex#> .
        \\ex:s ex:p 17;
        \\     ex:q -1.5, 1.5e-3, +2E6, true, false .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 6), triples.len);
    try expect_literal(triples[0].object, .integer, "17");
    try expect_literal(triples[1].object, .decimal, "-1.5");
    try expect_literal(triples[2].object, .double, "1.5e-3");
    try expect_literal(triples[3].object, .double, "+2E6");
    try expect_literal(triples[4].object, .boolean, "true");
    try expect_literal(triples[5].object, .boolean, "false");
}

test "integer glued to the statement dot" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix ex: <http://ex#> .
        \\ex:s ex:p 8.
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 1), triples.len);
    try expect_literal(triples[0].object, .integer, "8");
}

test "pname locals keep interior dots but shed the statement dot" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix cim: <https://cim.ucaiug.io/ns#> .
        \\cim:ACLineSegment.r cim:p cim:Foo.bar.
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 1), triples.len);
    try expect_iri(triples[0].subject, "https://cim.ucaiug.io/ns", "ACLineSegment.r");
    try expect_iri(triples[0].object, "https://cim.ucaiug.io/ns", "Foo.bar");
}

test "anonymous property list as object emits the parent triple first" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\@prefix ex: <http://ex#> .
        \\ex:shape sh:path [ sh:inversePath ex:p ] ; sh:maxCount 1 .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 3), triples.len);
    const blank_id = try expect_blank(triples[0].object);
    try testing.expectEqualStrings("path", triples[0].predicate.local);
    // The inner triple's subject is that same blank node.
    try testing.expectEqual(blank_id, try expect_blank(triples[1].subject));
    try testing.expectEqualStrings("inversePath", triples[1].predicate.local);
    try expect_iri(triples[1].object, "http://ex", "p");
    // After ']' the outer context is restored.
    try expect_iri(triples[2].subject, "http://ex", "shape");
    try expect_literal(triples[2].object, .integer, "1");
}

test "empty blank node [] is a plain term" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix ex: <http://ex#> .
        \\ex:s ex:p [] , [ ] .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 2), triples.len);
    const first = try expect_blank(triples[0].object);
    const second = try expect_blank(triples[1].object);
    try testing.expect(first != second);
}

test "property list as subject, with and without following predicates" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix ex: <http://ex#> .
        \\[ ex:p ex:o ] .
        \\[ ex:p ex:o2 ] ex:q ex:r .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 3), triples.len);
    const subject_blank = try expect_blank(triples[0].subject);
    try expect_iri(triples[0].object, "http://ex", "o");
    // The second statement's blank subject carries both its inner triple
    // and the outer predicateObjectList.
    const second_blank = try expect_blank(triples[1].subject);
    try testing.expect(subject_blank != second_blank);
    try testing.expectEqual(second_blank, try expect_blank(triples[2].subject));
    try expect_iri(triples[2].object, "http://ex", "r");
}

test "labeled blank nodes map to stable ids" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix ex: <http://ex#> .
        \\_:b0 ex:p _:b1 .
        \\_:b1 ex:p _:b0 .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 2), triples.len);
    const b0 = try expect_blank(triples[0].subject);
    const b1 = try expect_blank(triples[0].object);
    try testing.expect(b0 != b1);
    try testing.expectEqual(b1, try expect_blank(triples[1].subject));
    try testing.expectEqual(b0, try expect_blank(triples[1].object));
}

test "empty collection is rdf:nil" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix ex: <http://ex#> .
        \\ex:s ex:p () .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 1), triples.len);
    try testing.expect(triples[0].object == .iri);
    try testing.expect(triples[0].object.iri.eql(turtle.rdf_nil));
}

test "collection expands to an rdf:first/rdf:rest chain" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\@prefix ex: <http://ex#> .
        \\ex:s sh:in ( ex:a ex:b ) .
    );
    defer gpa.free(triples);

    // s in b0; b0 first a; b0 rest b1; b1 first b; b1 rest nil.
    try testing.expectEqual(@as(usize, 5), triples.len);
    const head = try expect_blank(triples[0].object);
    try testing.expectEqual(head, try expect_blank(triples[1].subject));
    try testing.expect(triples[1].predicate.eql(turtle.rdf_first));
    try expect_iri(triples[1].object, "http://ex", "a");
    try testing.expect(triples[2].predicate.eql(turtle.rdf_rest));
    const second = try expect_blank(triples[2].object);
    try testing.expectEqual(second, try expect_blank(triples[3].subject));
    try expect_iri(triples[3].object, "http://ex", "b");
    try testing.expect(triples[4].predicate.eql(turtle.rdf_rest));
    try testing.expect(triples[4].object.iri.eql(turtle.rdf_nil));
}

test "sequence path (P rdf:type) parses as a two-element chain" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
        \\@prefix ex: <http://ex#> .
        \\ex:shape sh:path ( ex:p rdf:type ) .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 5), triples.len);
    try expect_iri(triples[1].object, "http://ex", "p");
    try testing.expect(triples[3].object.iri.eql(turtle.rdf_type));
}

test "alternativePath of inverse paths: depth-2 nesting" {
    const gpa = testing.allocator;
    // The deepest structure in the corpus: a property list containing a
    // collection containing property lists.
    const triples = try parse_all(gpa,
        \\@prefix sh: <http://www.w3.org/ns/shacl#> .
        \\@prefix ex: <http://ex#> .
        \\ex:shape sh:path [ sh:alternativePath ( [sh:inversePath ex:p] [sh:inversePath ex:q] ) ] .
    );
    defer gpa.free(triples);

    // shape path b0; b0 alternativePath b1(head); b1 first b2; b2 inversePath p;
    // b1 rest b3; b3 first b4; b4 inversePath q; b3 rest nil.
    try testing.expectEqual(@as(usize, 8), triples.len);
    try testing.expectEqualStrings("alternativePath", triples[1].predicate.local);
    try testing.expectEqualStrings("inversePath", triples[3].predicate.local);
    try expect_iri(triples[3].object, "http://ex", "p");
    try testing.expectEqualStrings("inversePath", triples[6].predicate.local);
    try expect_iri(triples[6].object, "http://ex", "q");
    try testing.expect(triples[7].object.iri.eql(turtle.rdf_nil));
}

test "nested empty structures inside a collection" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix ex: <http://ex#> .
        \\ex:s ex:p ( () [] ) .
    );
    defer gpa.free(triples);

    // s p b0; b0 first nil; b0 rest b1; b1 first b_empty; b1 rest nil.
    try testing.expectEqual(@as(usize, 5), triples.len);
    try testing.expect(triples[1].object.iri.eql(turtle.rdf_nil));
    _ = try expect_blank(triples[3].object);
}

test "comments are trivia; triples report their line numbers" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\# a license header
        \\@prefix ex: <http://ex#> . # trailing comment
        \\ex:s ex:p ex:o . # comment with "quotes" and <brackets>
        \\
        \\ex:s2 ex:p ex:o2 .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 2), triples.len);
    try testing.expectEqual(@as(u32, 3), triples[0].line);
    try testing.expectEqual(@as(u32, 5), triples[1].line);
}

test "prefix redefinition: the later binding wins" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa,
        \\@prefix ex: <http://old#> .
        \\@prefix ex: <http://new#> .
        \\ex:s ex:p ex:o .
    );
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 1), triples.len);
    try expect_iri(triples[0].subject, "http://new", "s");
}

test "tabs separate tokens (the corpus typo line uses them)" {
    const gpa = testing.allocator;
    const triples = try parse_all(gpa, "@prefix sh: <http://www.w3.org/ns/shacl#> .\n" ++
        "\t\tsh:a\tsh:MinCount\t\t1;\n\t\tsh:b 2 .");
    defer gpa.free(triples);

    try testing.expectEqual(@as(usize, 2), triples.len);
    try testing.expectEqualStrings("MinCount", triples[0].predicate.local);
    try testing.expectEqualStrings("b", triples[1].predicate.local);
}

// ── Invalid space ─────────────────────────────────────────────────────────

test "unterminated IRI at end of input" {
    try expect_parse_error("<http://ex#s", error.UnterminatedIri, 1);
}

test "IRI containing whitespace" {
    try expect_parse_error("<http://ex #s> <http://ex#p> <http://ex#o> .", error.IriContainsWhitespace, 1);
}

test "RDF-star quoted triples are rejected" {
    try expect_parse_error("<<<http://ex#s>>> <http://ex#p> <http://ex#o> .", error.UnterminatedIri, 1);
}

test "unterminated string at end of input" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s ex:p \"never closed .",
        error.UnterminatedString,
        2,
    );
}

test "raw newline inside a short string" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s ex:p \"broken\nstring\" .",
        error.UnterminatedString,
        2,
    );
}

test "invalid escape sequence" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s ex:p \"bad \\q escape\" .",
        error.InvalidEscape,
        2,
    );
}

test "truncated unicode escape" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s ex:p \"\\u12\" .",
        error.InvalidEscape,
        2,
    );
}

test "unknown prefix carries the offending line" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\n\nex:s nope:p ex:o .",
        error.UnknownPrefix,
        3,
    );
}

test "single-quoted strings are unsupported" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s ex:p 'single' .",
        error.UnsupportedConstruct,
        2,
    );
}

test "collection as subject is unsupported" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\n( ex:a ) ex:p ex:o .",
        error.UnsupportedConstruct,
        2,
    );
}

test "number glued to letters" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s ex:p 12abc .",
        error.InvalidNumber,
        2,
    );
}

test "exponent without digits" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s ex:p 1e .",
        error.InvalidNumber,
        2,
    );
}

test "blank-node nesting beyond blank_depth_max" {
    // Depth 9 of `[ ex:p [ ... ] ]` exceeds the fixed stack of 8.
    const source = "@prefix ex: <http://ex#> .\nex:s ex:p " ++
        ("[ ex:p " ** 9) ++ "ex:o" ++ (" ]" ** 9) ++ " .";
    try expect_parse_error(source, error.BlankDepthExceeded, 2);
}

test "statement dot inside an open bracket" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s ex:p [ ex:q ex:o . ] .",
        error.MalformedStatement,
        2,
    );
}

test "closing bracket without an open one" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s ex:p ex:o ] .",
        error.MalformedStatement,
        2,
    );
}

test "end of input mid-statement" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s ex:p",
        error.UnexpectedEndOfInput,
        2,
    );
}

test "end of input inside an open property list" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s ex:p [ ex:q ex:o .",
        error.MalformedStatement,
        2,
    );
}

test "relative prefix expansion is rejected" {
    try expect_parse_error(
        "@base <http://ex/> .\n@prefix rel: <fragment#> .",
        error.RelativePrefixIri,
        2,
    );
}

test "relative base is rejected" {
    try expect_parse_error("@base <fragment> .", error.RelativeBaseIri, 1);
}

test "misspelled directive" {
    try expect_parse_error("@prefixes ex: <http://ex#> .", error.InvalidDirective, 1);
}

test "missing dot after @prefix" {
    try expect_parse_error(
        "@prefix ex: <http://ex#>\nex:s ex:p ex:o .",
        error.UnexpectedCharacter,
        2,
    );
}

test "literal in predicate position" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s \"lit\" ex:o .",
        error.UnexpectedCharacter,
        2,
    );
}

test "blank label in predicate position" {
    try expect_parse_error(
        "@prefix ex: <http://ex#> .\nex:s _:b0 ex:o .",
        error.MalformedStatement,
        2,
    );
}

test "bare word without colon as subject" {
    try expect_parse_error("subject <http://ex#p> <http://ex#o> .", error.UnexpectedCharacter, 1);
}

test "stray statement dot" {
    try expect_parse_error(". <http://ex#p> <http://ex#o> .", error.UnexpectedCharacter, 1);
}

test "collection exceeding in_list_values_max" {
    const gpa = testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    try source.appendSlice(gpa, "@prefix ex: <http://ex#> .\nex:s ex:p (");
    var i: u32 = 0;
    while (i < turtle.in_list_values_max + 1) : (i += 1) {
        try source.appendSlice(gpa, " ex:v");
    }
    try source.appendSlice(gpa, " ) .");
    try expect_parse_error(source.items, error.TooManyListValues, 2);
}

test "prefix table overflow" {
    const gpa = testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    var line_buf: [64]u8 = undefined;
    var i: u32 = 0;
    while (i < turtle.prefixes_count_max + 1) : (i += 1) {
        const line = try std.fmt.bufPrint(&line_buf, "@prefix p{d}: <http://ex{d}#> .\n", .{ i, i });
        try source.appendSlice(gpa, line);
    }
    try expect_parse_error(source.items, error.TooManyPrefixes, turtle.prefixes_count_max + 1);
}

test "blank label table overflow" {
    const gpa = testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    try source.appendSlice(gpa, "@prefix ex: <http://ex#> .\n");
    var line_buf: [64]u8 = undefined;
    var i: u32 = 0;
    while (i < turtle.blank_labels_count_max + 1) : (i += 1) {
        const line = try std.fmt.bufPrint(&line_buf, "_:b{d} ex:p ex:o .\n", .{i});
        try source.appendSlice(gpa, line);
    }
    try expect_parse_error(source.items, error.TooManyBlankLabels, turtle.blank_labels_count_max + 2);
}

// ── Corpus-shaped smoke ───────────────────────────────────────────────────

test "corpus smoke: every published rule-set file parses cleanly" {
    // Pair tests with the real thing: symlink a published rule-set directory
    // (e.g. ApplicationProfiles_NCP/SHACL) to testdata/shacl-corpus to parse
    // all of it; skipped when the corpus is not on disk.
    const corpus_path = "testdata/shacl-corpus";
    const gpa = testing.allocator;
    const io = testing.io;

    var dir = std.Io.Dir.cwd().openDir(io, corpus_path, .{ .iterate = true }) catch |err|
        switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
    defer dir.close(io);

    // One published file is broken Turtle: NC-AP-Con-Complex-Common uses the
    // undeclared prefix `io:` (a typo for `ido:`) on line 17. Strict parsers
    // (rdflib included) reject it; fail-fast parsing must too. Guessing what
    // `io:` expands to would be misreading a rule. The error must name the
    // line so the user can fix the file.
    const broken_file = "NC-AP-Con-Complex-Common-SHACL_v1-0-0.ttl";

    var files_count: u32 = 0;
    var broken_count: u32 = 0;
    var triples_count: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ttl")) continue;
        files_count += 1;

        const file = try dir.openFile(io, entry.name, .{});
        defer file.close(io);
        var file_reader = file.reader(io, &.{});
        const source = try file_reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(source);

        var parser = Turtle.init(source, entry.name);
        while (true) {
            // The catch must live in the loop body: a `break` inside a while
            // *condition* expression would bind to the outer directory loop.
            const triple_opt = parser.next() catch |err| {
                if (std.mem.eql(u8, entry.name, broken_file)) {
                    try testing.expectEqual(turtle.Error.UnknownPrefix, err);
                    try testing.expectEqual(@as(u32, 17), parser.line);
                    broken_count += 1;
                    break;
                }
                std.debug.print("{s}:{d}: {t}\n", .{ entry.name, parser.line, err });
                return err;
            };
            if (triple_opt == null) break;
            triples_count += 1;
        }
    }

    // Pinned totals for ApplicationProfiles_NCP_v2-4-1-2: 28 files, of which
    // 27 parse to 72,503 triples (collections expanded to rdf:first/rest
    // chains; the analysis script's statement-level count for all 28 files
    // is 72,545). A corpus revision bump that changes these is a visible
    // diff, not a silent one.
    try testing.expectEqual(@as(u32, 28), files_count);
    try testing.expectEqual(@as(u32, 1), broken_count);
    try testing.expectEqual(@as(u64, 72_503), triples_count);
}

test "a corpus-shaped shape block parses into the expected triple count" {
    const gpa = testing.allocator;
    // Mirrors the AssessedElement Simple file's structure: ontology header
    // with typed/tagged literals, a named property shape, a closed node
    // shape with inline path-only property shapes, and an sh:in list.
    const triples = try parse_all(gpa,
        \\@base   <https://ap-con.cim4.eu/AssessedElement-Simple/2.4> .
        \\@prefix ae:  <https://ap-con.cim4.eu/AssessedElement-Simple/2.4#> .
        \\@prefix nc:  <https://cim4.eu/ns/nc#> .
        \\@prefix owl: <http://www.w3.org/2002/07/owl#> .
        \\@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
        \\@prefix sh:  <http://www.w3.org/ns/shacl#> .
        \\@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
        \\
        \\ae:Ontology  rdf:type  owl:Ontology;
        \\        owl:versionIRI    <2.4/2.4>;
        \\        owl:versionInfo   "2.4.0"@en .
        \\
        \\ae:CrossBorderRelevance.mRID-cardinality
        \\        rdf:type        sh:PropertyShape;
        \\        sh:maxCount     1;
        \\        sh:message      "Missing required property (attribute).";
        \\        sh:minCount     1;
        \\        sh:name         "CrossBorderRelevance.mRID-cardinality";
        \\        sh:order        57;
        \\        sh:path         nc:CrossBorderRelevance.mRID;
        \\        sh:severity     sh:Violation .
        \\
        \\ae:CrossBorderRelevance-AllowedProperties
        \\        rdf:type              sh:NodeShape;
        \\        sh:closed             true;
        \\        sh:ignoredProperties  ( rdf:type );
        \\        sh:property           [ sh:path  nc:CrossBorderRelevance.mRID ];
        \\        sh:severity           sh:Info;
        \\        sh:targetClass        nc:CrossBorderRelevance .
        \\
        \\ae:Kind-datatype
        \\        sh:in ( nc:Kind.a nc:Kind.b nc:Kind.c );
        \\        sh:nodeKind sh:IRI .
    );
    defer gpa.free(triples);

    // Ontology: 3. Property shape: 8. Closed node shape: 6 stated + 2 for
    // the (rdf:type) list + 1 inline sh:path. In-list: 2 stated + 6 chain.
    try testing.expectEqual(@as(usize, 28), triples.len);
}
