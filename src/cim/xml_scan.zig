//! Raw scanning also serves incomplete fragments and diagnostics that have no CIM object model.

const std = @import("std");
const assert = std.debug.assert;

pub const VECTOR_LEN = if (std.simd.suggestVectorLength(u8)) |size|
    @min(size, 32)
else
    32;

const Chunk = @Vector(VECTOR_LEN, u8);
const Mask = std.meta.Int(.unsigned, VECTOR_LEN);

pub fn find_byte_simd(
    gpa: std.mem.Allocator,
    haystack: []const u8,
    needle: u8,
) !std.ArrayList(u32) {
    if (haystack.len > std.math.maxInt(u32)) return error.FileTooLarge;

    var result: std.ArrayList(u32) = .empty;
    errdefer result.deinit(gpa);

    if (haystack.len == 0) return result;

    // XML delimiters are sparse; this estimate limits reallocations on typical input.
    const estimated_matches = @max(@divFloor(haystack.len, 10), 16);
    try result.ensureTotalCapacity(gpa, estimated_matches);

    const all_needles: Chunk = @splat(needle);
    var i: usize = 0;

    const unroll_factor = 4;
    const unroll_size = VECTOR_LEN * unroll_factor;

    while (i + unroll_size <= haystack.len) : (i += unroll_size) {
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

    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == needle) {
            try result.ensureUnusedCapacity(gpa, 1);
            result.appendAssumeCapacity(@intCast(i));
        }
    }

    return result;
}

/// Avoid building std.mem.indexOf's skip table for each short XML attribute scan.
pub fn find_needle_anchored(haystack: []const u8, comptime needle: []const u8) ?usize {
    comptime assert(needle.len > 0);
    if (haystack.len < needle.len) return null;

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

/// A lookup table avoids comparing every byte against every set member.
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

/// Tag prefixes and name terminators usually share a chunk; find both without reloading it.
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
        while (mask != 0) : (mask &= mask - 1) {
            const pos = i + @ctz(mask);
            if (first) |f| return .{ .first = f, .second = pos };
            first = pos;
        }
    }

    while (index_of_any_pos_table(haystack, i, set)) |pos| {
        if (first) |f| return .{ .first = f, .second = pos };
        first = pos;
        i = pos + 1;
    }

    if (first) |f| return .{ .first = f, .second = null };
    return null;
}

pub const TagBoundary = struct {
    start: u32,
    end: u32,
};

pub const MalformedReason = enum {
    unclosed_tag,
    nested_tag_open,
    unterminated_section,
    closing_tag_self_closed,
    unreadable_tag_name,
    unexpected_closing_tag,
    mismatched_closing_tag,
    unclosed_element,

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
    none,
    unterminated,
    ends_at: u32,
};

/// Span whole sections so interior delimiters cannot create overlapping tag boundaries.
/// The DTD shortcut assumes no brackets inside quoted entity values, as in CGMES.
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

/// Scanning forward from each opener avoids a second file pass and an index of every >.
pub fn find_tag_boundaries(
    gpa: std.mem.Allocator,
    xml: []const u8,
) !std.ArrayList(TagBoundary) {
    var error_offset: MalformedXML = .{};
    return find_tag_boundaries_with_error_offset(gpa, xml, &error_offset);
}

pub fn find_tag_boundaries_with_error_offset(
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

    try result.ensureTotalCapacity(gpa, lts.len);

    var lt_idx: usize = 0;
    while (lt_idx < lts.len) {
        const lt = lts[lt_idx];

        const section: MarkupSection = if (lt + 1 < xml.len and xml[lt + 1] == '!')
            markup_section_end(xml, lt)
        else
            .none;

        const close_gt: u32 = switch (section) {
            .none => {
                const gt: u32 = @intCast(std.mem.indexOfScalarPos(u8, xml, lt + 1, '>') orelse
                    return malformed_xml(error_offset, lt, .unclosed_tag, xml.len));
                // Nested openers would create overlapping boundaries and break downstream slices.
                if (lt_idx + 1 < lts.len and lts[lt_idx + 1] < gt) {
                    return malformed_xml(error_offset, lts[lt_idx + 1], .nested_tag_open, xml.len);
                }
                result.appendAssumeCapacity(.{ .start = lt, .end = gt });
                lt_idx += 1;
                continue;
            },
            .unterminated => return malformed_xml(error_offset, lt, .unterminated_section, xml.len),
            .ends_at => |end| end,
        };

        result.appendAssumeCapacity(.{ .start = lt, .end = close_gt });
        lt_idx += 1;
        while (lt_idx < lts.len and lts[lt_idx] < close_gt) : (lt_idx += 1) {}
    }

    assert(result.items.len > 0);
    for (result.items[1..], 1..) |t, i| {
        assert(t.start > result.items[i - 1].end);
    }

    return result;
}

pub fn extract_tag_type(slice: []const u8, start_idx: u32) error{MalformedTag}![]const u8 {
    return (try extract_tag_type_terminated(slice, start_idx)).name;
}

/// CIM typing ignores prefixes; XML nesting must match qualified names exactly.
/// Returning the terminator lets child walks skip attribute scans when none can exist.
pub fn extract_tag_type_terminated(
    slice: []const u8,
    start_idx: u32,
) error{MalformedTag}!struct { name: []const u8, qname: []const u8, terminator: u8 } {
    assert(slice.len <= std.math.maxInt(u32));

    var name_start: u32 = start_idx;
    if (name_start >= slice.len) return error.MalformedTag;
    if (slice[name_start] == '<') name_start += 1;
    if (name_start < slice.len and slice[name_start] == '/') name_start += 1;
    if (name_start >= slice.len) return error.MalformedTag;

    if (slice[name_start] == '!' or slice[name_start] == '?') return error.MalformedTag;

    // Include the colon to locate the prefix and name end in one scan.
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
    if (slice[end_idx] == ':') return error.MalformedTag;
    assert(end_idx > local_start);
    assert(end_idx < slice.len);

    return .{
        .name = slice[local_start..end_idx],
        .qname = slice[name_start..end_idx],
        .terminator = slice[end_idx],
    };
}

/// Bound the closing quote so later markup cannot terminate a malformed attribute.
pub inline fn extract_attribute_within(
    slice: []const u8,
    start_idx: u32,
    end_idx: u32,
    comptime name: []const u8,
) error{MalformedTag}!?[]const u8 {
    assert(end_idx >= start_idx);
    assert(end_idx <= slice.len);

    const pattern = name ++ "=\"";

    const pattern_offset = find_needle_anchored(slice[start_idx..end_idx], pattern) orelse return null;
    const value_start_idx = start_idx + pattern_offset + pattern.len;
    const value_end_idx = std.mem.indexOfScalarPos(u8, slice, value_start_idx, '"') orelse
        return error.MalformedTag;

    if (value_end_idx >= end_idx) return error.MalformedTag;

    return slice[value_start_idx..value_end_idx];
}

pub fn extract_rdf_id(slice: []const u8, start_idx: u32) error{ NoRdfId, MalformedTag }![]const u8 {
    const gt_idx = std.mem.indexOfScalarPos(u8, slice, start_idx, '>') orelse return error.MalformedTag;
    return (try extract_attribute_within(slice, start_idx, @intCast(gt_idx), "rdf:ID")) orelse
        error.NoRdfId;
}

pub fn extract_rdf_about(slice: []const u8, start_idx: u32) error{ NoRdfAbout, MalformedTag }![]const u8 {
    const gt_idx = std.mem.indexOfScalarPos(u8, slice, start_idx, '>') orelse return error.MalformedTag;
    return (try extract_attribute_within(slice, start_idx, @intCast(gt_idx), "rdf:about")) orelse
        error.NoRdfAbout;
}

pub fn extract_rdf_resource_within(
    slice: []const u8,
    start_idx: u32,
    end_idx: u32,
) error{MalformedTag}!?[]const u8 {
    return extract_attribute_within(slice, start_idx, end_idx, "rdf:resource");
}

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
    if (boundary_kind(xml, opening_tag) != .element_open) return error.MalformedTag;

    if (xml[opening_tag.end - 1] == '/') return error.SelfClosingTag;

    var depth: u32 = 1;
    // Count only matching names to support incomplete fragments such as <a><b></a>.
    // Full nesting validation belongs to build_closing_index.
    const opening_qname = (try extract_tag_type_terminated(xml, opening_tag.start)).qname;
    for (boundaries[opening_tag_idx + 1 ..], opening_tag_idx + 1..) |tag, i| {
        const kind = boundary_kind(xml, tag);
        if (kind == .non_element) continue;
        const self_closing = xml[tag.end - 1] == '/';
        if (kind == .element_close and self_closing) return error.MalformedTag;
        const tag_qname = (try extract_tag_type_terminated(xml, tag.start)).qname;
        if (self_closing) continue;
        if (!std.mem.eql(u8, opening_qname, tag_qname)) continue;

        if (kind == .element_close) {
            assert(depth > 0);
            depth -= 1;
            if (depth == 0) return @intCast(i);
        } else {
            assert(depth < std.math.maxInt(u32));
            depth += 1;
        }
    }
    return error.NoClosingTag;
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

/// Reject non-elements before parsing names so commented-out children cannot become live.
pub inline fn is_element_open_tag(xml: []const u8, tag: TagBoundary) bool {
    return boundary_kind(xml, tag) == .element_open;
}

/// Validate every element name here so later child walks can assume they are parseable.
pub fn build_closing_index(
    gpa: std.mem.Allocator,
    xml: []const u8,
    boundaries: []const TagBoundary,
) ![]u32 {
    var error_offset: MalformedXML = .{};
    return build_closing_index_with_error_offset(gpa, xml, boundaries, &error_offset);
}

pub fn build_closing_index_with_error_offset(
    gpa: std.mem.Allocator,
    xml: []const u8,
    boundaries: []const TagBoundary,
    error_offset: *MalformedXML,
) ![]u32 {
    assert(xml.len <= std.math.maxInt(u32));
    const closing_for = try gpa.alloc(u32, boundaries.len);
    errdefer gpa.free(closing_for);

    // Fill slots during the walk to avoid an extra array write; closers fill their openers.

    const StackEntry = struct { qname: []const u8, idx: u32 };
    var stack: std.ArrayListUnmanaged(StackEntry) = .empty;
    defer stack.deinit(gpa);

    for (boundaries, 0..) |tag, i| {
        switch (boundary_kind(xml, tag)) {
            .non_element => closing_for[i] = @intCast(i),
            .element_close => {
                if (xml[tag.end - 1] == '/') return malformed_xml(error_offset, tag.start, .closing_tag_self_closed, xml.len);
                const parsed = extract_tag_type_terminated(xml, tag.start) catch
                    return malformed_xml(error_offset, tag.start, .unreadable_tag_name, xml.len);
                if (stack.items.len == 0) return malformed_xml(error_offset, tag.start, .unexpected_closing_tag, xml.len);
                if (!std.mem.eql(u8, stack.items[stack.items.len - 1].qname, parsed.qname)) {
                    return malformed_xml(error_offset, tag.start, .mismatched_closing_tag, xml.len);
                }
                const opener = stack.pop().?;
                closing_for[opener.idx] = @intCast(i);
                closing_for[i] = @intCast(i);
            },
            .element_open => {
                // Validate self-closing names too, even though they bypass the stack.
                const parsed = extract_tag_type_terminated(xml, tag.start) catch
                    return malformed_xml(error_offset, tag.start, .unreadable_tag_name, xml.len);
                if (xml[tag.end - 1] == '/') {
                    closing_for[i] = @intCast(i);
                    continue;
                }
                try stack.append(gpa, .{ .qname = parsed.qname, .idx = @intCast(i) });
            },
        }
    }

    // The opener locates the broken segment more usefully than end-of-input.
    if (stack.items.len != 0) return malformed_xml(
        error_offset,
        boundaries[stack.items[0].idx].start,
        .unclosed_element,
        xml.len,
    );

    for (closing_for, 0..) |c, i| {
        assert(c >= i);
        assert(c < boundaries.len);
    }

    return closing_for;
}
