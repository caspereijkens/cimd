//! Generate the `parent_edges` body of `src/cgmes/cim_types.zig` from CGMES
//! RDFS profile files.
//!
//! Build-time codegen tool. Run via:
//!   zig build gen-cim-types -- path/to/Equipment-AP.rdf [more.rdf ...]
//! or let scripts/fetch-cim-rdfs.sh download the official profiles and drive
//! this in one step.
//!
//! CGMES ships one RDFS per profile (EQ, SSH, SV, TP, ...), and the table spans
//! several of them, so pass every profile RDFS you want covered; their parent
//! edges are unioned and deduped. The output is the initializer body for
//! `parent_edges`; review the diff and splice it in (then `zig fmt`).
//!
//! Crucially, this reuses the very same tag scanner (`tag_index.zig`) that cimd
//! parses CIM with at runtime, so the class names emitted here are exactly the
//! ones cimd recognizes, with no second XML implementation to drift from.
//!
//! Like the runtime scanner, attribute matching is by literal `rdf:`/`rdfs:`
//! prefix, not namespace resolution. This is deliberate: a profile using a
//! different RDF prefix would be unreadable by cimd at runtime too, so a table
//! built from it would be useless. The official ENTSO-E CGMES profiles use the
//! conventional prefixes.

const std = @import("std");
const tag_index = @import("cgmes/tag_index.zig");
const read_path = @import("io/read.zig").read_path;

const TagBoundary = tag_index.TagBoundary;

const Edge = struct {
    child: []const u8,
    parent: []const u8,
};

/// Reduce an RDF identifier to its bare class name: drop everything up to and
/// including the last '#' or '/', then if a '.' remains keep the trailing
/// segment (so "ACLineSegment.r" → "r", which `is_class_name` then rejects).
fn local_name(value: []const u8) []const u8 {
    var v = value;
    if (std.mem.lastIndexOfScalar(u8, v, '#')) |i| v = v[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, v, '/')) |i| v = v[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, v, '.')) |i| v = v[i + 1 ..];
    return v;
}

/// True for CIM class identifiers: an uppercase initial followed by
/// alphanumerics or underscores (the `^[A-Z][A-Za-z0-9_]*$` of the old script).
/// This is what distinguishes a real class from property/datatype/enum names.
fn is_class_name(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isUpper(name[0])) return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// The class declared by an opening tag, via rdf:about (preferred) or rdf:ID.
/// Returns null when the tag declares no class or the name isn't a class name.
fn class_id(xml: []const u8, start: u32) ?[]const u8 {
    const raw = tag_index.extract_rdf_about(xml, start) catch
        tag_index.extract_rdf_id(xml, start) catch return null;
    const name = local_name(raw);
    return if (is_class_name(name)) name else null;
}

/// The superclass of the element opening at `opening_idx`: the first
/// `rdfs:subClassOf` child whose resource resolves to a class name. A class may
/// carry several subClassOf edges (e.g. a stereotype/datatype reference beside
/// the real superclass), so non-class ones are skipped rather than treated as
/// fatal. Returns null for root classes (no qualifying subClassOf).
fn parent_id(xml: []const u8, boundaries: []const TagBoundary, opening_idx: u32) ?[]const u8 {
    // Scope the search to this element's children; self-closing / unclosed
    // elements have none, so any error here just means "no parent".
    const close = tag_index.find_closing_tag(xml, boundaries, opening_idx) catch return null;

    // Walk *direct* children only. A nested rdfs:subClassOf (e.g. one wrapping an
    // inline owl:Restriction) is not this class's superclass, so we step over
    // each container child's whole subtree rather than scanning every descendant
    // tag, matching the deleted Python generator's immediate-children semantics.
    var j = opening_idx + 1;
    while (j < close) {
        const boundary = boundaries[j];
        const second = if (boundary.start + 1 < xml.len) xml[boundary.start + 1] else 0;

        // Comments '<!', PIs/declarations '<?', and stray closers '</' are not
        // element children to recurse into; step over each as one boundary.
        if (second == '!' or second == '?' or second == '/') {
            j += 1;
            continue;
        }

        if (std.mem.eql(u8, tag_index.extract_tag_type(xml, boundary.start) catch "", "subClassOf")) {
            // The superclass rides on rdf:resource of the subClassOf tag itself;
            // a subClassOf that instead wraps an inline node carries none here
            // and is correctly skipped.
            if (tag_index.extract_rdf_resource_within(xml, boundary.start, boundary.end) catch null) |resource| {
                const name = local_name(resource);
                if (is_class_name(name)) return name;
            }
        }

        // Advance to the next direct child: past a self-closing tag, or past a
        // container child's entire subtree.
        if (xml[boundary.end - 1] == '/') {
            j += 1;
        } else if (tag_index.find_closing_tag(xml, boundaries, j)) |child_close| {
            j = child_close + 1;
        } else |_| {
            j += 1;
        }
    }
    return null;
}

/// Append every child→parent edge found in one RDFS document to `edges`.
/// Emitted slices borrow `xml`, which the caller must keep alive.
fn collect_edges(gpa: std.mem.Allocator, xml: []const u8, edges: *std.ArrayList(Edge)) !void {
    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);
    const items = boundaries.items;

    for (items, 0..) |boundary, idx| {
        if (boundary.start + 1 >= xml.len) continue;
        // Skip closing tags '</', comments '<!' and declarations/PIs '<?'.
        switch (xml[boundary.start + 1]) {
            '/', '!', '?' => continue,
            else => {},
        }
        const child = class_id(xml, boundary.start) orelse continue;
        const parent = parent_id(xml, items, @intCast(idx)) orelse continue;
        if (std.mem.eql(u8, child, parent)) continue;
        try edges.append(gpa, .{ .child = child, .parent = parent });
    }
}

/// Sort by (child, parent) so identical edges from different profiles become
/// adjacent and can be deduped on output. Mirrors the old script's sorted set.
fn edge_less_than(_: void, a: Edge, b: Edge) bool {
    return switch (std.mem.order(u8, a.child, b.child)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.parent, b.parent) == .lt,
    };
}

fn edge_eql(a: Edge, b: Edge) bool {
    return std.mem.eql(u8, a.child, b.child) and std.mem.eql(u8, a.parent, b.parent);
}

fn usage(io: std.Io) noreturn {
    _ = std.Io.File.stderr().writeStreamingAll(
        io,
        "usage: gen-cim-types <CIM-schema.rdf> [more.rdf ...]\n",
    ) catch {};
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // One arena for the whole run: file contents and edge slices outlive each
    // file's parse, and a build-time tool has no reason to free incrementally.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // program name

    var edges: std.ArrayList(Edge) = .empty;
    var saw_file = false;
    while (args.next()) |path| {
        saw_file = true;
        const xml = try read_path(io, arena, path);
        try collect_edges(arena, xml, &edges);
    }
    if (!saw_file) usage(io);

    std.mem.sort(Edge, edges.items, {}, edge_less_than);

    var write_buffer: [64 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &write_buffer);
    const w = &file_writer.interface;
    var prev: ?Edge = null;
    for (edges.items) |edge| {
        if (prev) |p| if (edge_eql(p, edge)) continue;
        try w.print("    .{{ .child = \"{s}\", .parent = \"{s}\" }},\n", .{ edge.child, edge.parent });
        prev = edge;
    }
    try w.flush();
}

test "is_class_name accepts class identifiers, rejects the rest" {
    try std.testing.expect(is_class_name("ACLineSegment"));
    try std.testing.expect(is_class_name("NuclearGeneratingUnit"));
    try std.testing.expect(is_class_name("F1_2"));
    try std.testing.expect(!is_class_name("")); // empty
    try std.testing.expect(!is_class_name("enumValue")); // lowercase initial
    try std.testing.expect(!is_class_name("9Foo")); // digit initial
    try std.testing.expect(!is_class_name("Foo-Bar")); // hyphen
}

test "local_name strips namespace, path and property segments" {
    try std.testing.expectEqualStrings("Conductor", local_name("http://iec.ch/TC57/CIM100#Conductor"));
    try std.testing.expectEqualStrings("GeneratingUnit", local_name("#GeneratingUnit"));
    try std.testing.expectEqualStrings("Equipment", local_name("Equipment"));
    try std.testing.expectEqualStrings("r", local_name("#ACLineSegment.r"));
}

test "collect_edges picks the real superclass and ignores non-classes" {
    const xml =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        \\         xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#">
        \\  <rdf:Description rdf:about="#NuclearGeneratingUnit">
        \\    <rdfs:subClassOf rdf:resource="#enum-value"/>
        \\    <rdfs:subClassOf rdf:resource="#GeneratingUnit"/>
        \\  </rdf:Description>
        \\  <rdf:Description rdf:about="#ACLineSegment.r">
        \\    <rdfs:domain rdf:resource="#ACLineSegment"/>
        \\  </rdf:Description>
        \\</rdf:RDF>
    ;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(std.testing.allocator);
    try collect_edges(std.testing.allocator, xml, &edges);

    try std.testing.expectEqual(@as(usize, 1), edges.items.len);
    try std.testing.expectEqualStrings("NuclearGeneratingUnit", edges.items[0].child);
    // The leading non-class subClassOf (#enum-value) is skipped, not fatal.
    try std.testing.expectEqualStrings("GeneratingUnit", edges.items[0].parent);
}

test "collect_edges ignores rdfs:subClassOf nested in an inline node" {
    // The first direct child is a subClassOf wrapping an owl:Restriction whose
    // own nested subClassOf points at #WRONG; only the real direct-child
    // subClassOf (#RealParent) must be picked.
    const xml =
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        \\         xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#"
        \\         xmlns:owl="http://www.w3.org/2002/07/owl#">
        \\  <rdf:Description rdf:about="#Foo">
        \\    <rdfs:subClassOf>
        \\      <owl:Restriction>
        \\        <rdfs:subClassOf rdf:resource="#WRONG"/>
        \\      </owl:Restriction>
        \\    </rdfs:subClassOf>
        \\    <rdfs:subClassOf rdf:resource="#RealParent"/>
        \\  </rdf:Description>
        \\</rdf:RDF>
    ;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(std.testing.allocator);
    try collect_edges(std.testing.allocator, xml, &edges);

    try std.testing.expectEqual(@as(usize, 1), edges.items.len);
    try std.testing.expectEqualStrings("Foo", edges.items[0].child);
    try std.testing.expectEqualStrings("RealParent", edges.items[0].parent);
}
