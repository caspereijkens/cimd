//! Turtle tokenizer and triple iterator for SHACL rule-set files.
//!
//! Produces RDF triples from a bounded subset of Turtle 1.1. This module
//! knows nothing about SHACL; it yields triples; rule_set.zig interprets
//! them. The mechanism/meaning separation mirrors xml_scan.zig vs tag_index.zig.
//!
//! Zero-copy: every namespace, local name, and literal value is a slice into
//! `source` (the caller keeps the buffer alive). IRIs are split into
//! (namespace, local) with the trailing '#' or '/' separator stripped from
//! the namespace, so `cim16:CurrentLimit` and
//! `<http://iec.ch/TC57/2013/CIM-schema-cim16#CurrentLimit>` compare equal
//! part-by-part, and local names compare namespace-insensitively for
//! downstream namespace-variant deduplication.
//!
//! Anything outside the accepted grammar is a hard error, not a skip: a
//! construct we do not recognize is a rule we would misread, and misreading
//! a validation rule produces false confidence, the worst failure mode a
//! validator has. Every error carries the 1-based line number in
//! `Turtle.line`.
//!
//! No recursion: anonymous property lists and collections parse iteratively
//! with an explicit fixed-depth frame stack. All loops are bounded by the
//! byte position, which strictly advances; `next` asserts progress.

const std = @import("std");
const assert = std.debug.assert;

/// Maximum @prefix/PREFIX directives per file. Corpus max: 19 per file.
pub const prefixes_count_max = 64;

/// Maximum combined nesting depth of anonymous blank nodes `[...]` and
/// collections `(...)`. Corpus max: 2 (alternativePath of inversePath).
pub const blank_depth_max = 8;

/// Maximum values in one RDF collection `(...)`. Corpus max: 482 raw
/// values in one sh:in list; 4x headroom over that observed reality.
pub const in_list_values_max = 2048;

/// Maximum distinct labeled blank nodes (`_:label`) per file. Zero corpus
/// uses, accepted because other publishers' files use them, so the bound
/// only keeps the label table statically sized inside the parser.
pub const blank_labels_count_max = 256;

pub const rdf_namespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns";
pub const shacl_namespace = "http://www.w3.org/ns/shacl";
pub const xsd_namespace = "http://www.w3.org/2001/XMLSchema";
pub const owl_namespace = "http://www.w3.org/2002/07/owl";

pub const rdf_type: Iri = .{ .namespace = rdf_namespace, .local = "type" };
pub const rdf_first: Iri = .{ .namespace = rdf_namespace, .local = "first" };
pub const rdf_rest: Iri = .{ .namespace = rdf_namespace, .local = "rest" };
pub const rdf_nil: Iri = .{ .namespace = rdf_namespace, .local = "nil" };

pub const Iri = struct {
    /// Namespace with the trailing '#' or '/' separator stripped, e.g.
    /// "http://www.w3.org/ns/shacl". Prefixed names carry their prefix's
    /// expansion; relative IRIs carry the file's @base.
    namespace: []const u8,
    /// Local name, e.g. "minCount" or "ACLineSegment.r". May be empty
    /// (the prefixed name `cim:` alone is legal Turtle).
    local: []const u8,

    pub fn eql(a: Iri, b: Iri) bool {
        if (!std.mem.eql(u8, a.namespace, b.namespace)) return false;
        return std.mem.eql(u8, a.local, b.local);
    }
};

pub const Literal = struct {
    /// Raw lexical form between the quotes (escapes are validated but not
    /// decoded; decoding would force a copy the streaming parser cannot
    /// own; consumers that store strings decode via `decode_escape`, as
    /// rule_set.zig does at load); for numbers and booleans, the bare token.
    value: []const u8,
    kind: Kind,
    /// Explicit `^^datatype` annotation, when written.
    datatype: ?Iri,

    pub const Kind = enum(u8) { string, integer, decimal, double, boolean };
};

pub const Term = union(enum) {
    iri: Iri,
    blank: u32,
    literal: Literal,
};

/// One decoded escape sequence: up to 4 UTF-8 bytes produced from
/// `consumed` raw bytes.
pub const DecodedEscape = struct {
    bytes: [4]u8,
    written: u8,
    consumed: u8,
};

/// Decode the escape sequence starting at `raw[pos]` (which must be '\').
/// Infallible by contract: the tokenizer validated shape, hex digits, and
/// codepoint range (validate_escape), so `raw` must be a string literal
/// value it accepted; anything else asserts.
pub fn decode_escape(raw: []const u8, pos: u32) DecodedEscape {
    assert(pos < raw.len and raw[pos] == '\\');
    assert(pos + 1 < raw.len); // validate_escape guarantees a body
    const single: ?u8 = switch (raw[pos + 1]) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        '"' => '"',
        '\\' => '\\',
        'u', 'U' => null,
        else => unreachable, // validate_escape rejects everything else
    };
    if (single) |byte| {
        return .{ .bytes = .{ byte, 0, 0, 0 }, .written = 1, .consumed = 2 };
    }
    const digits: u8 = if (raw[pos + 1] == 'u') 4 else 8;
    assert(pos + 2 + @as(u32, digits) <= raw.len); // validate_escape counted them
    const hex = raw[pos + 2 .. pos + 2 + @as(u32, digits)];
    const codepoint = std.fmt.parseInt(u21, hex, 16) catch unreachable; // range-checked at parse
    var result = DecodedEscape{ .bytes = undefined, .written = 0, .consumed = 2 + digits };
    result.written = std.unicode.utf8Encode(codepoint, &result.bytes) catch unreachable;
    return result;
}

pub const Triple = struct {
    /// Always .iri or .blank, never .literal.
    subject: Term,
    predicate: Iri,
    object: Term,
    /// 1-based line in the rules file at the point this triple was emitted.
    line: u32,
};

pub const Error = error{
    UnexpectedCharacter,
    UnexpectedEndOfInput,
    MalformedStatement,
    UnterminatedIri,
    IriContainsWhitespace,
    UnterminatedString,
    InvalidEscape,
    InvalidNumber,
    InvalidDirective,
    UnknownPrefix,
    RelativePrefixIri,
    RelativeBaseIri,
    TooManyPrefixes,
    TooManyBlankLabels,
    TooManyListValues,
    BlankDepthExceeded,
    UnsupportedConstruct,
};

pub const Turtle = struct {
    source: []const u8,
    source_name: []const u8,
    /// Current byte position. Strictly advances across next() calls.
    pos: u32,
    /// Current 1-based line; on error, this is the line to report.
    line: u32,
    /// @base namespace (separator-stripped); empty until a base directive.
    base: []const u8,

    state: State,
    /// Current statement subject/predicate (property-list context only;
    /// collections keep their chain node in their frame instead).
    subject: Term,
    predicate: Iri,

    prefixes: [prefixes_count_max]Prefix,
    prefixes_count: u32,

    labels: [blank_labels_count_max]Label,
    labels_count: u32,
    /// Next synthetic blank-node id (labeled and anonymous share one space).
    blank_count: u32,

    frames: [blank_depth_max]Frame,
    frames_count: u32,

    /// Triples produced by the last grammar step but not yet returned.
    /// A single step emits at most 2 (a collection element's rdf:rest link
    /// plus its rdf:first value).
    pending: [pending_count_max]Triple,
    pending_head: u32,
    pending_count: u32,

    const pending_count_max = 4;

    const State = enum(u8) {
        /// Expect a directive, a subject term, or end of input.
        subject,
        /// Expect a predicate (IRI, prefixed name, or `a`).
        predicate,
        /// After ';': expect a predicate, another ';', '.', or ']'.
        predicate_or_end,
        /// After a top-level `[...]` subject: expect a predicate or '.'.
        subject_continue,
        /// Expect an object term, '[', or '('.
        object,
        /// After an object: expect ',', ';', '.', or ']'.
        post_object,
        /// Inside a collection: expect an element term or ')'.
        collection_element,
    };

    const Prefix = struct { name: []const u8, namespace: []const u8 };
    const Label = struct { name: []const u8, blank_id: u32 };

    const Frame = struct {
        /// Outer subject/predicate to restore when a property list closes.
        /// Unused by collection frames (their emissions key off `node`).
        subject: Term,
        predicate: Iri,
        /// Property list: the blank node this `[...]` denotes.
        /// Collection: the current chain node awaiting rdf:rest.
        node: u32,
        /// Collection: whether `node`'s rdf:first has been emitted.
        has_first: bool,
        /// Collection: elements consumed so far, bounded by
        /// in_list_values_max.
        values_count: u32,
        kind: Kind,

        const Kind = enum(u8) { property_list_subject, property_list_object, collection };
    };

    pub fn init(source: []const u8, source_name: []const u8) Turtle {
        // u32 positions must cover the file; the loader's rules_bytes_max
        // (64 MiB) is far below this, so only programmer error trips it.
        assert(source.len < std.math.maxInt(u32));
        return .{
            .source = source,
            .source_name = source_name,
            .pos = 0,
            .line = 1,
            .base = "",
            .state = .subject,
            .subject = .{ .blank = 0 },
            .predicate = rdf_type,
            .prefixes = undefined,
            .prefixes_count = 0,
            .labels = undefined,
            .labels_count = 0,
            .blank_count = 0,
            .frames = undefined,
            .frames_count = 0,
            .pending = undefined,
            .pending_head = 0,
            .pending_count = 0,
        };
    }

    /// Returns the next triple, or null at a clean end of input.
    /// On error, `self.line` holds the offending line.
    pub fn next(self: *Turtle) Error!?Triple {
        if (self.pending_count > 0) return self.pending_pop();
        const pos_before = self.pos;
        while (self.pending_count == 0) {
            const progressed = try self.step();
            if (!progressed) {
                // End of input is only legal between statements.
                if (self.state != .subject) return Error.UnexpectedEndOfInput;
                if (self.frames_count != 0) return Error.UnexpectedEndOfInput;
                return null;
            }
        }
        // Non-termination is impossible by construction: every step consumes
        // at least one byte. This assert documents and enforces it.
        assert(self.pos > pos_before);
        return self.pending_pop();
    }

    fn step(self: *Turtle) Error!bool {
        self.skip_trivia();
        if (self.pos >= self.source.len) return false;
        const pos_before = self.pos;
        switch (self.state) {
            .subject => try self.step_subject(),
            .predicate, .predicate_or_end, .subject_continue => try self.step_predicate(),
            .object => try self.step_object(),
            .post_object => try self.step_post_object(),
            .collection_element => try self.step_collection_element(),
        }
        // Pairs with next()'s progress assert: a step that consumed nothing
        // would loop forever.
        assert(self.pos > pos_before);
        return true;
    }

    fn step_subject(self: *Turtle) Error!void {
        const c = self.source[self.pos];
        if (c == '@') return self.parse_at_directive();
        if (c == '<') {
            self.subject = .{ .iri = try self.scan_iri_ref() };
            self.state = .predicate;
            return;
        }
        if (c == '[') return self.open_property_list(.subject_position);
        // Collections as subjects are legal Turtle with zero published uses;
        // fail fast rather than carry the extra frame variant.
        if (c == '(') return Error.UnsupportedConstruct;
        if (c == '\'' or c == '"') return Error.UnexpectedCharacter;
        const token = self.scan_name_token();
        if (token.len == 0) return Error.UnexpectedCharacter;
        if (std.mem.startsWith(u8, token, "_:")) {
            self.subject = .{ .blank = try self.blank_for_label(token[2..]) };
            self.state = .predicate;
            return;
        }
        if (std.mem.indexOfScalar(u8, token, ':') != null) {
            self.subject = .{ .iri = try self.resolve_pname(token) };
            self.state = .predicate;
            return;
        }
        // SPARQL-style directives have no '@' and no terminating '.'.
        if (std.ascii.eqlIgnoreCase(token, "prefix")) return self.parse_prefix_directive(false);
        if (std.ascii.eqlIgnoreCase(token, "base")) return self.parse_base_directive(false);
        return Error.UnexpectedCharacter;
    }

    fn step_predicate(self: *Turtle) Error!void {
        assert(self.state == .predicate or self.state == .predicate_or_end or
            self.state == .subject_continue);
        const c = self.source[self.pos];
        if (self.state == .predicate_or_end) {
            // Trailing ';' before '.' or ']' is legal, as is ';;'.
            if (c == ';') {
                self.pos += 1;
                return;
            }
            if (c == '.') return self.end_statement();
            if (c == ']') {
                self.pos += 1;
                return self.close_property_list();
            }
        }
        if (self.state == .subject_continue) {
            // `[ ... ] .`: a blank-node statement with no outer predicate.
            if (c == '.') return self.end_statement();
        }
        self.predicate = try self.scan_predicate();
        self.state = .object;
    }

    fn step_object(self: *Turtle) Error!void {
        const c = self.source[self.pos];
        if (c == '[') return self.open_property_list(.object_position);
        if (c == '(') return self.open_collection();
        const object = try self.scan_term();
        self.emit(self.subject, self.predicate, object);
        self.state = .post_object;
    }

    fn step_post_object(self: *Turtle) Error!void {
        switch (self.source[self.pos]) {
            ',' => {
                self.pos += 1;
                self.state = .object;
            },
            ';' => {
                self.pos += 1;
                self.state = .predicate_or_end;
            },
            '.' => try self.end_statement(),
            ']' => {
                self.pos += 1;
                try self.close_property_list();
            },
            else => return Error.UnexpectedCharacter,
        }
    }

    fn step_collection_element(self: *Turtle) Error!void {
        assert(self.frames_count > 0);
        const frame = &self.frames[self.frames_count - 1];
        assert(frame.kind == .collection);
        const c = self.source[self.pos];
        if (c == ')') {
            // open_collection never pushes a frame for an empty list, so the
            // chain node here always carries a value.
            assert(frame.has_first);
            self.pos += 1;
            self.emit(.{ .blank = frame.node }, rdf_rest, .{ .iri = rdf_nil });
            self.frames_count -= 1;
            self.state = self.state_after_object();
            return;
        }
        if (frame.values_count >= in_list_values_max) return Error.TooManyListValues;
        frame.values_count += 1;
        if (frame.has_first) {
            const next_node = self.new_blank();
            self.emit(.{ .blank = frame.node }, rdf_rest, .{ .blank = next_node });
            frame.node = next_node;
            frame.has_first = false;
        }
        if (c == '[') return self.open_element_property_list(frame);
        if (c == '(') return self.open_element_collection(frame);
        const element = try self.scan_term();
        self.emit(.{ .blank = frame.node }, rdf_first, element);
        frame.has_first = true;
    }

    /// `[` as an element of a collection: link it into the chain, then parse
    /// its body exactly like an object-position property list.
    fn open_element_property_list(self: *Turtle, frame: *Frame) Error!void {
        assert(self.source[self.pos] == '[');
        assert(frame.kind == .collection);
        self.pos += 1;
        self.skip_trivia();
        const blank_id = self.new_blank();
        self.emit(.{ .blank = frame.node }, rdf_first, .{ .blank = blank_id });
        frame.has_first = true;
        if (self.pos < self.source.len and self.source[self.pos] == ']') {
            self.pos += 1;
            return; // `[]`: a plain blank term; stay in .collection_element.
        }
        try self.push_frame(.{
            .subject = self.subject,
            .predicate = self.predicate,
            .node = blank_id,
            .has_first = false,
            .values_count = 0,
            .kind = .property_list_object,
        });
        self.subject = .{ .blank = blank_id };
        self.state = .predicate;
    }

    /// `(` as an element of a collection: nested list.
    fn open_element_collection(self: *Turtle, frame: *Frame) Error!void {
        assert(self.source[self.pos] == '(');
        assert(frame.kind == .collection);
        self.pos += 1;
        self.skip_trivia();
        if (self.pos < self.source.len and self.source[self.pos] == ')') {
            self.pos += 1;
            self.emit(.{ .blank = frame.node }, rdf_first, .{ .iri = rdf_nil });
            frame.has_first = true;
            return;
        }
        const head = self.new_blank();
        self.emit(.{ .blank = frame.node }, rdf_first, .{ .blank = head });
        frame.has_first = true;
        try self.push_frame(.{
            .subject = self.subject,
            .predicate = self.predicate,
            .node = head,
            .has_first = false,
            .values_count = 0,
            .kind = .collection,
        });
        // state stays .collection_element, now for the inner frame.
        assert(self.state == .collection_element);
    }

    const PropertyListPosition = enum { subject_position, object_position };

    fn open_property_list(self: *Turtle, position: PropertyListPosition) Error!void {
        assert(self.source[self.pos] == '[');
        self.pos += 1;
        self.skip_trivia();
        const blank_id = self.new_blank();
        if (self.pos < self.source.len and self.source[self.pos] == ']') {
            // `[]` is a plain blank-node term, no frame needed.
            self.pos += 1;
            switch (position) {
                .subject_position => {
                    self.subject = .{ .blank = blank_id };
                    self.state = .predicate;
                },
                .object_position => {
                    self.emit(self.subject, self.predicate, .{ .blank = blank_id });
                    self.state = .post_object;
                },
            }
            return;
        }
        if (position == .object_position) {
            self.emit(self.subject, self.predicate, .{ .blank = blank_id });
        }
        try self.push_frame(.{
            .subject = self.subject,
            .predicate = self.predicate,
            .node = blank_id,
            .has_first = false,
            .values_count = 0,
            .kind = switch (position) {
                .subject_position => .property_list_subject,
                .object_position => .property_list_object,
            },
        });
        self.subject = .{ .blank = blank_id };
        self.state = .predicate;
    }

    fn open_collection(self: *Turtle) Error!void {
        assert(self.source[self.pos] == '(');
        self.pos += 1;
        self.skip_trivia();
        if (self.pos < self.source.len and self.source[self.pos] == ')') {
            self.pos += 1;
            self.emit(self.subject, self.predicate, .{ .iri = rdf_nil });
            self.state = .post_object;
            return;
        }
        const head = self.new_blank();
        self.emit(self.subject, self.predicate, .{ .blank = head });
        try self.push_frame(.{
            .subject = self.subject,
            .predicate = self.predicate,
            .node = head,
            .has_first = false,
            .values_count = 0,
            .kind = .collection,
        });
        self.state = .collection_element;
    }

    fn close_property_list(self: *Turtle) Error!void {
        if (self.frames_count == 0) return Error.MalformedStatement;
        const frame = self.frames[self.frames_count - 1];
        if (frame.kind == .collection) return Error.MalformedStatement;
        self.frames_count -= 1;
        switch (frame.kind) {
            .property_list_subject => {
                assert(self.frames_count == 0);
                self.subject = .{ .blank = frame.node };
                self.state = .subject_continue;
            },
            .property_list_object => {
                self.subject = frame.subject;
                self.predicate = frame.predicate;
                self.state = self.state_after_object();
            },
            .collection => unreachable,
        }
    }

    fn end_statement(self: *Turtle) Error!void {
        assert(self.source[self.pos] == '.');
        // A '.' inside an open '[' or '(' is malformed, not a terminator.
        if (self.frames_count != 0) return Error.MalformedStatement;
        self.pos += 1;
        self.state = .subject;
    }

    /// Where parsing continues after an object completes: collections take
    /// their next element, everything else expects ',', ';', '.', or ']'.
    fn state_after_object(self: *const Turtle) State {
        if (self.frames_count > 0) {
            if (self.frames[self.frames_count - 1].kind == .collection) {
                return .collection_element;
            }
        }
        return .post_object;
    }

    // ── Terms ─────────────────────────────────────────────────────────────

    fn scan_predicate(self: *Turtle) Error!Iri {
        const c = self.source[self.pos];
        if (c == '<') return self.scan_iri_ref();
        const token = self.scan_name_token();
        if (token.len == 0) return Error.UnexpectedCharacter;
        if (token.len == 1 and token[0] == 'a') return rdf_type;
        if (std.mem.startsWith(u8, token, "_:")) return Error.MalformedStatement;
        return self.resolve_pname(token);
    }

    /// One simple term: IRI, prefixed name, literal, or labeled blank node.
    /// '[' and '(' are handled by the state machine, not here.
    fn scan_term(self: *Turtle) Error!Term {
        const c = self.source[self.pos];
        if (c == '<') return .{ .iri = try self.scan_iri_ref() };
        if (c == '"') return .{ .literal = try self.scan_string_literal() };
        // Single-quoted strings are legal Turtle with zero corpus uses;
        // rejected to keep the accepted grammar deliberately small.
        if (c == '\'') return Error.UnsupportedConstruct;
        if (c == '+' or c == '-' or std.ascii.isDigit(c)) {
            return .{ .literal = try self.scan_number() };
        }
        const token = self.scan_name_token();
        if (token.len == 0) return Error.UnexpectedCharacter;
        if (std.mem.startsWith(u8, token, "_:")) {
            return .{ .blank = try self.blank_for_label(token[2..]) };
        }
        if (std.mem.eql(u8, token, "true") or std.mem.eql(u8, token, "false")) {
            return .{ .literal = .{ .value = token, .kind = .boolean, .datatype = null } };
        }
        return .{ .iri = try self.resolve_pname(token) };
    }

    fn scan_iri_ref(self: *Turtle) Error!Iri {
        return self.split_iri(try self.scan_iri_text());
    }

    /// The raw text between '<' and '>'. Whitespace or a nested '<'
    /// (RDF-star) is a hard error. So are \uXXXX/\UXXXXXXXX escapes:
    /// IRIs are split and matched as raw bytes (namespaces, class and
    /// property names), so an undecoded escape would silently match
    /// nothing, and the corpus never escapes an IRI.
    fn scan_iri_text(self: *Turtle) Error![]const u8 {
        assert(self.source[self.pos] == '<');
        self.pos += 1;
        const start = self.pos;
        // The first byte from this set decides the outcome (whitespace is the
        // only multi-byte case).
        const stop: u32 = @intCast(std.mem.indexOfAnyPos(u8, self.source, self.pos, "> \t\r\n<\\") orelse
            return Error.UnterminatedIri);
        switch (self.source[stop]) {
            '>' => {
                self.pos = stop + 1;
                return self.source[start..stop];
            },
            '<' => return Error.UnterminatedIri,
            '\\' => return Error.UnsupportedConstruct,
            else => return Error.IriContainsWhitespace,
        }
    }

    /// Split a full IRI into (namespace, local) at the last '#' or '/',
    /// dropping the separator; relative references resolve against @base.
    fn split_iri(self: *const Turtle, text: []const u8) Iri {
        if (iri_is_absolute(text)) {
            if (std.mem.lastIndexOfAny(u8, text, "#/")) |idx| {
                return .{ .namespace = text[0..idx], .local = text[idx + 1 ..] };
            }
            return .{ .namespace = "", .local = text };
        }
        // Relative reference: identity within this file is all that matters
        // because all shape references resolve within their own file. The
        // base slice + the raw fragment is a faithful, zero-copy identity.
        if (text.len > 0 and text[0] == '#') {
            return .{ .namespace = self.base, .local = text[1..] };
        }
        return .{ .namespace = self.base, .local = text };
    }

    fn scan_string_literal(self: *Turtle) Error!Literal {
        assert(self.source[self.pos] == '"');
        const long = self.pos + 2 < self.source.len and
            self.source[self.pos + 1] == '"' and self.source[self.pos + 2] == '"';
        const value = if (long)
            try self.scan_long_string_value()
        else
            try self.scan_short_string_value();
        var datatype: ?Iri = null;
        if (self.pos < self.source.len and self.source[self.pos] == '@') {
            try self.scan_language_tag();
        } else if (self.pos + 1 < self.source.len and
            self.source[self.pos] == '^' and self.source[self.pos + 1] == '^')
        {
            self.pos += 2;
            datatype = try self.scan_datatype_iri();
        }
        return .{ .value = value, .kind = .string, .datatype = datatype };
    }

    fn scan_short_string_value(self: *Turtle) Error![]const u8 {
        assert(self.source[self.pos] == '"');
        self.pos += 1;
        const start = self.pos;
        // Skip ordinary bytes stopping only at the closer, a line break
        // (illegal in a short string), or an escape.
        while (std.mem.indexOfAnyPos(u8, self.source, self.pos, "\"\n\r\\")) |stop_usize| {
            const stop: u32 = @intCast(stop_usize);
            self.pos = stop;
            switch (self.source[stop]) {
                '"' => {
                    self.pos = stop + 1;
                    return self.source[start..stop];
                },
                '\n', '\r' => return Error.UnterminatedString,
                else => try self.validate_escape(), // '\\', advances past the escape
            }
        }
        return Error.UnterminatedString;
    }

    fn scan_long_string_value(self: *Turtle) Error![]const u8 {
        assert(self.source[self.pos] == '"');
        self.pos += 3;
        const start = self.pos;
        // Ordinary bytes are skipped. Only a quote (possible closer), an
        // escape, or a newline (line count) need handling.
        while (std.mem.indexOfAnyPos(u8, self.source, self.pos, "\"\\\n")) |stop_usize| {
            const stop: u32 = @intCast(stop_usize);
            switch (self.source[stop]) {
                // Close at the first `"""` not followed by another quote, so up
                // to two embedded quotes before the closer parse as content.
                '"' => {
                    const rest = self.source[stop..];
                    if (rest.len >= 3 and rest[1] == '"' and rest[2] == '"' and
                        (rest.len == 3 or rest[3] != '"'))
                    {
                        self.pos = stop + 3;
                        return self.source[start..stop];
                    }
                    self.pos = stop + 1;
                },
                '\\' => {
                    self.pos = stop;
                    try self.validate_escape();
                },
                '\n' => {
                    self.line += 1;
                    self.pos = stop + 1;
                },
                else => unreachable,
            }
        }
        return Error.UnterminatedString;
    }

    /// Validate (but do not decode) one string escape sequence at `pos`,
    /// advancing past it. \u/\U are checked down to the codepoint: hex
    /// digits alone can still name a surrogate half or exceed U+10FFFF,
    /// and rejecting that here keeps the line number (decoding happens
    /// long after parsing, rule_set.zig).
    fn validate_escape(self: *Turtle) Error!void {
        assert(self.source[self.pos] == '\\');
        if (self.pos + 1 >= self.source.len) return Error.InvalidEscape;
        const c = self.source[self.pos + 1];
        const hex_digits: u32 = switch (c) {
            'u' => 4,
            'U' => 8,
            '"', '\\', 'n', 'r', 't' => 0,
            else => return Error.InvalidEscape,
        };
        self.pos += 2;
        var codepoint: u32 = 0;
        var i: u32 = 0;
        while (i < hex_digits) : (i += 1) {
            if (self.pos >= self.source.len) return Error.InvalidEscape;
            const digit = std.fmt.charToDigit(self.source[self.pos], 16) catch
                return Error.InvalidEscape;
            codepoint = codepoint * 16 + digit;
            self.pos += 1;
        }
        if (codepoint > 0x10FFFF) return Error.InvalidEscape;
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return Error.InvalidEscape;
    }

    /// Language tags are validated and dropped: nothing downstream is
    /// language-sensitive (messages report verbatim).
    fn scan_language_tag(self: *Turtle) Error!void {
        assert(self.source[self.pos] == '@');
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.source.len) : (self.pos += 1) {
            const c = self.source[self.pos];
            if (!std.ascii.isAlphanumeric(c) and c != '-') break;
        }
        if (self.pos == start) return Error.UnexpectedCharacter;
    }

    fn scan_datatype_iri(self: *Turtle) Error!Iri {
        if (self.pos >= self.source.len) return Error.UnexpectedEndOfInput;
        if (self.source[self.pos] == '<') return self.scan_iri_ref();
        const token = self.scan_name_token();
        if (token.len == 0) return Error.UnexpectedCharacter;
        return self.resolve_pname(token);
    }

    fn scan_number(self: *Turtle) Error!Literal {
        const start = self.pos;
        if (self.source[self.pos] == '+' or self.source[self.pos] == '-') self.pos += 1;
        var digits_count: u32 = 0;
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            self.pos += 1;
            digits_count += 1;
        }
        if (digits_count == 0) return Error.InvalidNumber;
        var kind: Literal.Kind = .integer;
        // '.' only joins the number when a digit follows; a bare trailing
        // '.' is the statement terminator (`sh:order 8.` style).
        if (self.pos + 1 < self.source.len and self.source[self.pos] == '.' and
            std.ascii.isDigit(self.source[self.pos + 1]))
        {
            self.pos += 1;
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                self.pos += 1;
            }
            kind = .decimal;
        }
        if (self.pos < self.source.len and
            (self.source[self.pos] == 'e' or self.source[self.pos] == 'E'))
        {
            self.pos += 1;
            if (self.pos < self.source.len and
                (self.source[self.pos] == '+' or self.source[self.pos] == '-'))
            {
                self.pos += 1;
            }
            var exponent_digits: u32 = 0;
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                self.pos += 1;
                exponent_digits += 1;
            }
            if (exponent_digits == 0) return Error.InvalidNumber;
            kind = .double;
        }
        // Numbers glue to punctuation (`sh:order 8;`) but not to letters.
        if (self.pos < self.source.len and !is_term_delimiter(self.source[self.pos])) {
            return Error.InvalidNumber;
        }
        return .{ .value = self.source[start..self.pos], .kind = kind, .datatype = null };
    }

    // ── Names and prefixes ────────────────────────────────────────────────

    /// Scan a name-ish token (prefixed name, keyword, or `_:label`),
    /// backing off trailing '.'s: a pname cannot end with '.', so those
    /// are statement terminators.
    fn scan_name_token(self: *Turtle) []const u8 {
        const start = self.pos;
        while (self.pos < self.source.len and is_name_char(self.source[self.pos])) {
            self.pos += 1;
        }
        while (self.pos > start and self.source[self.pos - 1] == '.') {
            self.pos -= 1;
        }
        return self.source[start..self.pos];
    }

    fn resolve_pname(self: *const Turtle, token: []const u8) Error!Iri {
        assert(token.len > 0);
        const colon = std.mem.indexOfScalar(u8, token, ':') orelse
            return Error.UnexpectedCharacter;
        const namespace = self.lookup_prefix(token[0..colon]) orelse
            return Error.UnknownPrefix;
        return .{ .namespace = namespace, .local = token[colon + 1 ..] };
    }

    fn lookup_prefix(self: *const Turtle, name: []const u8) ?[]const u8 {
        for (self.prefixes[0..self.prefixes_count]) |prefix| {
            if (std.mem.eql(u8, prefix.name, name)) return prefix.namespace;
        }
        return null;
    }

    fn put_prefix(self: *Turtle, name: []const u8, namespace: []const u8) Error!void {
        for (self.prefixes[0..self.prefixes_count]) |*prefix| {
            if (std.mem.eql(u8, prefix.name, name)) {
                // Redefinition is legal Turtle; later wins.
                prefix.namespace = namespace;
                return;
            }
        }
        if (self.prefixes_count >= prefixes_count_max) return Error.TooManyPrefixes;
        self.prefixes[self.prefixes_count] = .{ .name = name, .namespace = namespace };
        self.prefixes_count += 1;
    }

    // ── Directives ────────────────────────────────────────────────────────

    fn parse_at_directive(self: *Turtle) Error!void {
        assert(self.source[self.pos] == '@');
        self.pos += 1;
        const word = self.scan_name_token();
        // '@' forms are case-sensitive per the Turtle grammar.
        if (std.mem.eql(u8, word, "prefix")) return self.parse_prefix_directive(true);
        if (std.mem.eql(u8, word, "base")) return self.parse_base_directive(true);
        return Error.InvalidDirective;
    }

    fn parse_prefix_directive(self: *Turtle, expect_dot: bool) Error!void {
        self.skip_trivia();
        const name_start = self.pos;
        while (self.pos < self.source.len and is_name_char(self.source[self.pos]) and
            self.source[self.pos] != ':')
        {
            self.pos += 1;
        }
        const name = self.source[name_start..self.pos];
        try self.expect_char(':');
        self.skip_trivia();
        if (self.pos >= self.source.len) return Error.UnexpectedEndOfInput;
        if (self.source[self.pos] != '<') return Error.InvalidDirective;
        const iri_text = try self.scan_iri_text();
        // A relative expansion would need base concatenation (a copy); no
        // publisher writes one, so it fails fast instead of growing a system.
        if (!iri_is_absolute(iri_text)) return Error.RelativePrefixIri;
        if (expect_dot) {
            self.skip_trivia();
            try self.expect_char('.');
        }
        try self.put_prefix(name, strip_namespace_separator(iri_text));
    }

    fn parse_base_directive(self: *Turtle, expect_dot: bool) Error!void {
        self.skip_trivia();
        if (self.pos >= self.source.len) return Error.UnexpectedEndOfInput;
        if (self.source[self.pos] != '<') return Error.InvalidDirective;
        const iri_text = try self.scan_iri_text();
        if (!iri_is_absolute(iri_text)) return Error.RelativeBaseIri;
        if (expect_dot) {
            self.skip_trivia();
            try self.expect_char('.');
        }
        self.base = strip_namespace_separator(iri_text);
    }

    // ── Blank nodes ───────────────────────────────────────────────────────

    fn new_blank(self: *Turtle) u32 {
        const id = self.blank_count;
        self.blank_count += 1;
        return id;
    }

    fn blank_for_label(self: *Turtle, label: []const u8) Error!u32 {
        if (label.len == 0) return Error.UnexpectedCharacter;
        for (self.labels[0..self.labels_count]) |entry| {
            if (std.mem.eql(u8, entry.name, label)) return entry.blank_id;
        }
        if (self.labels_count >= blank_labels_count_max) return Error.TooManyBlankLabels;
        const id = self.new_blank();
        self.labels[self.labels_count] = .{ .name = label, .blank_id = id };
        self.labels_count += 1;
        return id;
    }

    fn push_frame(self: *Turtle, frame: Frame) Error!void {
        if (self.frames_count >= blank_depth_max) return Error.BlankDepthExceeded;
        self.frames[self.frames_count] = frame;
        self.frames_count += 1;
    }

    // ── Low-level scanning ────────────────────────────────────────────────

    fn skip_trivia(self: *Turtle) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\n') {
                self.line += 1;
                self.pos += 1;
            } else if (c == ' ' or c == '\t' or c == '\r') {
                self.pos += 1;
            } else if (c == '#') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn expect_char(self: *Turtle, expected: u8) Error!void {
        if (self.pos >= self.source.len) return Error.UnexpectedEndOfInput;
        if (self.source[self.pos] != expected) return Error.UnexpectedCharacter;
        self.pos += 1;
    }

    fn emit(self: *Turtle, subject: Term, predicate: Iri, object: Term) void {
        assert(subject != .literal);
        assert(self.pending_count < pending_count_max);
        const slot = (self.pending_head + self.pending_count) % pending_count_max;
        self.pending[slot] = .{
            .subject = subject,
            .predicate = predicate,
            .object = object,
            .line = self.line,
        };
        self.pending_count += 1;
    }

    fn pending_pop(self: *Turtle) Triple {
        assert(self.pending_count > 0);
        const triple = self.pending[self.pending_head];
        self.pending_head = (self.pending_head + 1) % pending_count_max;
        self.pending_count -= 1;
        if (self.pending_count == 0) self.pending_head = 0;
        return triple;
    }
};

/// Name characters cover PN_CHARS plus ':' and '%' (pname locals may contain
/// both); bytes >= 0x80 pass through so UTF-8 names survive unvalidated,
/// the compiler only ever compares names, never interprets them.
fn is_name_char(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return c == '_' or c == '-' or c == '.' or c == ':' or c == '%' or c >= 0x80;
}

/// What may legally follow a number: whitespace or structural punctuation.
/// (`sh:order 8;` glues digits to ';'; the corpus does this everywhere.)
fn is_term_delimiter(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', ';', ',', '.', '(', ')', '[', ']', '#' => true,
        else => false,
    };
}

/// True when the text begins with an RFC 3986 scheme ("http:", "urn:", ...).
fn iri_is_absolute(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..]) |c| {
        if (c == ':') return true;
        const scheme_char = std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.';
        if (!scheme_char) return false;
    }
    return false;
}

/// Drop one trailing '#' or '/' so prefix expansions and split full IRIs
/// agree on namespace identity (see Iri.namespace).
fn strip_namespace_separator(text: []const u8) []const u8 {
    if (text.len == 0) return text;
    const last = text[text.len - 1];
    if (last == '#' or last == '/') return text[0 .. text.len - 1];
    return text;
}
