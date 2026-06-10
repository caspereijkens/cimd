//! IEC 61970-552 difference model ("EQDIFF") output for `cimd diff`.
//!
//! The difference model carries the statements needed to transform model1
//! into model2:
//!   - dm:forwardDifferences — statements present only in model2
//!     (added objects, new property values).
//!   - dm:reverseDifferences — statements present only in model1
//!     (removed objects, old property values).
//!
//! Objects are matched by mRID, properties field-by-field, with the same
//! semantics as diff.zig's report formats. Statements are copied verbatim
//! from the source XML, so values, escaping, and namespace prefixes survive
//! the round trip; the root element merges the xmlns declarations of both
//! inputs so every copied prefix stays bound. When the inputs bind the same
//! prefix to different namespaces, model2's binding wins at the root and
//! model1's is re-declared locally on each statement block copied from
//! model1, so both sides keep their source meaning.
//!
//! Output is deterministic: no wall clock, no RNG. The difference-model id is
//! derived from a hash of both inputs, header metadata is copied from
//! model2's FullModel (the target of the transformation), and statement order
//! is fixed (types alphabetically, objects in document order, changed
//! properties alphabetically). The same invocation always produces a
//! byte-identical document.
//!
//! Exit-code contract is shared with diff.zig: the document is always
//! written, and the caller exits 1 when differences were found.

const std = @import("std");
const assert = std.debug.assert;

const EQ = @import("cgmes/eq.zig").EQ;
const tag_index = @import("cgmes/tag_index.zig");
const cim_types = @import("cgmes/cim_types.zig");
const diff = @import("diff.zig");

const rdf_uri = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
const dm_uri = "http://iec.ch/2002/schema/CIM_difference_model#";
const md_uri = "http://iec.ch/TC57/61970-552/ModelDescription/1#";

pub const Options = struct {
    /// When set, only objects of this CIM type (incl. subtypes) are compared.
    type_filter: ?[]const u8 = null,
};

// ── Entry points ──────────────────────────────────────────────────────────────

/// Write the difference model that transforms `model1` into `model2`.
/// Returns true when any differences were found (so main.zig can exit 1).
pub fn write_models(
    gpa: std.mem.Allocator,
    model1: *EQ,
    model2: *EQ,
    options: Options,
    writer: anytype,
) !bool {
    var forward: std.Io.Writer.Allocating = .init(gpa);
    defer forward.deinit();
    var reverse: std.Io.Writer.Allocating = .init(gpa);
    defer reverse.deinit();

    var type_counts1 = try model1.getTypeCounts(gpa);
    defer type_counts1.deinit();
    var type_counts2 = try model2.getTypeCounts(gpa);
    defer type_counts2.deinit();
    const type_names = try diff.type_name_union(gpa, &type_counts1, &type_counts2);
    defer gpa.free(type_names);

    var xmlns = try merge_xmlns(gpa, model1, model2);
    defer xmlns.deinit(gpa);

    var had_diffs = false;
    for (type_names) |type_name| {
        // FullModel is exchange metadata, not grid data; it feeds the
        // DifferenceModel header instead of the statement sections.
        if (std.mem.eql(u8, type_name, "FullModel")) continue;
        if (!cim_types.matches_filter(type_name, options.type_filter)) continue;
        if (try diff_type(gpa, model1, model2, type_name, xmlns.conflicts.items, &forward.writer, &reverse.writer)) {
            had_diffs = true;
        }
    }

    // FullModel emits no statements, but a metadata-only update is still a
    // difference: the exit-code contract promises 0 only for identical inputs.
    if (cim_types.matches_filter("FullModel", options.type_filter)) {
        if (try full_models_differ(gpa, model1, model2)) had_diffs = true;
    }

    const uuid = difference_model_uuid(model1, model2, options, null);
    try write_document(gpa, model1, model2, uuid, &xmlns, forward.written(), reverse.written(), writer);
    return had_diffs;
}

/// Difference model restricted to a single object identified by `mrid`.
/// Lookup and type-filter semantics mirror diff.diff_single.
pub fn write_single(
    gpa: std.mem.Allocator,
    model1: *EQ,
    model2: *EQ,
    mrid: []const u8,
    options: Options,
    writer: anytype,
) !diff.SingleDiffStatus {
    const v1 = model1.getObjectById(mrid);
    const v2 = model2.getObjectById(mrid);

    if (v1 == null and v2 == null) return .not_found;

    if (v1) |v| if (!cim_types.matches_filter(v.type_name, options.type_filter)) return .{ .type_mismatch = v.type_name };
    if (v2) |v| if (!cim_types.matches_filter(v.type_name, options.type_filter)) return .{ .type_mismatch = v.type_name };

    var forward: std.Io.Writer.Allocating = .init(gpa);
    defer forward.deinit();
    var reverse: std.Io.Writer.Allocating = .init(gpa);
    defer reverse.deinit();

    var xmlns = try merge_xmlns(gpa, model1, model2);
    defer xmlns.deinit(gpa);

    var had_diffs = false;
    if (v1 == null) {
        try emit_full_object(&forward.writer, v2.?, &.{});
        had_diffs = true;
    } else if (v2 == null) {
        try emit_full_object(&reverse.writer, v1.?, xmlns.conflicts.items);
        had_diffs = true;
    } else if (!std.mem.eql(u8, v1.?.type_name, v2.?.type_name)) {
        // Same mRID, different CIM type: a replacement, not a property change.
        // Mirrors write_models, which matches within concrete types and emits
        // the typed remove+add a consumer needs to transform the object.
        try emit_full_object(&reverse.writer, v1.?, xmlns.conflicts.items);
        try emit_full_object(&forward.writer, v2.?, &.{});
        had_diffs = true;
    } else {
        had_diffs = try emit_changed_object(gpa, v1.?, v2.?, xmlns.conflicts.items, &forward.writer, &reverse.writer);
    }

    const uuid = difference_model_uuid(model1, model2, options, mrid);
    try write_document(gpa, model1, model2, uuid, &xmlns, forward.written(), reverse.written(), writer);
    return .{ .diff = had_diffs };
}

// ── Per-type comparison ───────────────────────────────────────────────────────

/// Match one type's objects by mRID and emit statements for every difference.
/// Same matching structure as diff.diff_type_core, different emission.
fn diff_type(
    gpa: std.mem.Allocator,
    model1: *EQ,
    model2: *EQ,
    type_name: []const u8,
    conflicts1: []const XmlnsDecl,
    forward: *std.Io.Writer,
    reverse: *std.Io.Writer,
) !bool {
    const objects1 = model1.get_objects_by_type(type_name);
    const objects2 = model2.get_objects_by_type(type_name);

    var map = std.StringHashMap(u32).init(gpa);
    defer map.deinit();
    try map.ensureTotalCapacity(@intCast(objects2.len));
    for (objects2, 0..) |obj2, idx| map.putAssumeCapacity(obj2.id, @intCast(idx));

    const matched = try gpa.alloc(bool, objects2.len);
    defer gpa.free(matched);
    @memset(matched, false);

    var had_diffs = false;
    for (objects1) |obj1| {
        if (map.get(obj1.id)) |idx| {
            matched[idx] = true;
            const view1 = model1.view(obj1);
            const view2 = model2.view(objects2[idx]);
            if (try emit_changed_object(gpa, view1, view2, conflicts1, forward, reverse)) had_diffs = true;
        } else {
            // Removed: every statement of the object goes to reverseDifferences.
            try emit_full_object(reverse, model1.view(obj1), conflicts1);
            had_diffs = true;
        }
    }
    for (objects2, matched) |obj2, was_matched| {
        if (!was_matched) {
            try emit_full_object(forward, model2.view(obj2), &.{});
            had_diffs = true;
        }
    }
    return had_diffs;
}

// ── Child element access ──────────────────────────────────────────────────────

/// One child element of a CIM object.
const Child = struct {
    /// Tag name with namespace prefix stripped — the comparison key,
    /// consistent with diff.zig's semantic matching.
    name: []const u8,
    /// Text content for property elements, rdf:resource for references —
    /// the comparison value.
    value: []const u8,
    /// The complete element slice, copied verbatim into the output.
    raw: []const u8,
};

/// Walk the child elements of an object in document order. Skips comments,
/// processing instructions, and malformed tags, mirroring the tolerance of
/// CimObjectView.getAllProperties/getAllReferences.
const ChildIterator = struct {
    xml: []const u8,
    boundaries: []const tag_index.TagBoundary,
    next_idx: u32,
    end_idx: u32,

    fn init(view: tag_index.CimObjectView) ChildIterator {
        return .{
            .xml = view.xml,
            .boundaries = view.boundaries,
            .next_idx = view.object_tag_idx + 1,
            .end_idx = view.closing_tag_idx,
        };
    }

    fn next(self: *ChildIterator) ?Child {
        while (self.next_idx < self.end_idx) {
            const i = self.next_idx;
            const tag = self.boundaries[i];
            self.next_idx += 1;

            switch (self.xml[tag.start + 1]) {
                '/', '!', '?' => continue, // closing tag, comment, or PI
                else => {},
            }
            const name = tag_index.extract_tag_type(self.xml, tag.start) catch continue;

            // Self-closing: a reference (rdf:resource) in CIM XML.
            if (self.xml[tag.end - 1] == '/') {
                const resource = tag_index.extract_rdf_resource_within(self.xml, tag.start, tag.end) catch null;
                return .{
                    .name = name,
                    .value = resource orelse "",
                    .raw = self.xml[tag.start .. tag.end + 1],
                };
            }

            // Property element: text content, closed by the next boundary.
            // CIM properties never nest — the same assumption getAllProperties
            // makes when slicing content up to the following tag.
            const closing = self.boundaries[i + 1];
            self.next_idx = i + 2;
            return .{
                .name = name,
                .value = self.xml[tag.end + 1 .. closing.start],
                .raw = self.xml[tag.start .. closing.end + 1],
            };
        }
        return null;
    }
};

// ── Statement comparison ──────────────────────────────────────────────────────

/// The statements an object gained (forward) and lost (reverse) between the
/// two models. Borrowed slices into the model XML; only the lists are owned.
const ChangeSet = struct {
    forward: std.ArrayList(Child),
    reverse: std.ArrayList(Child),

    fn any(self: *const ChangeSet) bool {
        return self.forward.items.len > 0 or self.reverse.items.len > 0;
    }

    fn deinit(self: *ChangeSet, gpa: std.mem.Allocator) void {
        self.forward.deinit(gpa);
        self.reverse.deinit(gpa);
    }
};

/// Compare two views of the same object as multisets of (name, value)
/// statements. Repeated child elements (e.g. multiple Terminal references on
/// an OperationalLimitSet) each count individually — keying by name alone
/// would silently drop all but the last occurrence.
fn change_set(
    gpa: std.mem.Allocator,
    view1: tag_index.CimObjectView,
    view2: tag_index.CimObjectView,
) !ChangeSet {
    var children1: std.ArrayList(Child) = .empty;
    defer children1.deinit(gpa);
    var it1 = ChildIterator.init(view1);
    while (it1.next()) |child| try children1.append(gpa, child);

    var changes: ChangeSet = .{ .forward = .empty, .reverse = .empty };
    errdefer changes.deinit(gpa);

    const matched = try gpa.alloc(bool, children1.items.len);
    defer gpa.free(matched);
    @memset(matched, false);

    // Bounded by the object's child count squared — objects are small.
    var it2 = ChildIterator.init(view2);
    outer: while (it2.next()) |new_child| {
        for (children1.items, matched) |old_child, *was_matched| {
            if (!was_matched.* and
                std.mem.eql(u8, old_child.name, new_child.name) and
                std.mem.eql(u8, old_child.value, new_child.value))
            {
                was_matched.* = true;
                continue :outer;
            }
        }
        try changes.forward.append(gpa, new_child);
    }
    for (children1.items, matched) |old_child, was_matched| {
        if (!was_matched) try changes.reverse.append(gpa, old_child);
    }

    return changes;
}

// ── Statement emission ────────────────────────────────────────────────────────

/// Emit changed-property statements for an object present in both models:
/// new values to forwardDifferences, old values to reverseDifferences.
/// Returns true when any statement was written.
fn emit_changed_object(
    gpa: std.mem.Allocator,
    view1: tag_index.CimObjectView,
    view2: tag_index.CimObjectView,
    conflicts1: []const XmlnsDecl,
    forward: *std.Io.Writer,
    reverse: *std.Io.Writer,
) !bool {
    // Fast path: byte-identical XML is semantically identical (cf. diff_object).
    if (std.mem.eql(u8, view1.raw_xml(), view2.raw_xml())) return false;

    var changes = try change_set(gpa, view1, view2);
    defer changes.deinit(gpa);
    if (!changes.any()) return false;

    // Document order of the children is per-side; sort for stable output.
    sort_by_name(changes.forward.items);
    sort_by_name(changes.reverse.items);

    try emit_description(forward, view2, changes.forward.items, &.{});
    try emit_description(reverse, view1, changes.reverse.items, conflicts1);
    return true;
}

fn sort_by_name(children: []Child) void {
    // Stable: repeated same-named statements keep their document order.
    std.sort.insertion(Child, children, {}, struct {
        fn lessThan(_: void, a: Child, b: Child) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
}

/// One rdf:Description block carrying a subset of an object's statements.
fn emit_description(
    writer: *std.Io.Writer,
    view: tag_index.CimObjectView,
    statements: []const Child,
    conflicts: []const XmlnsDecl,
) !void {
    if (statements.len == 0) return;
    try writer.writeAll("      <rdf:Description rdf:about=\"");
    try write_about(writer, view);
    try writer.writeByte('"');
    try emit_local_xmlns(writer, view);
    try emit_conflict_xmlns(writer, view, conflicts);
    try writer.writeAll(">\n");
    for (statements) |statement| try writer.print("        {s}\n", .{statement.raw});
    try writer.writeAll("      </rdf:Description>\n");
}

/// Emit a complete object (typed element, all child statements) for objects
/// present in only one model. Iterates children directly, preserving
/// repeated elements.
fn emit_full_object(
    writer: *std.Io.Writer,
    view: tag_index.CimObjectView,
    conflicts: []const XmlnsDecl,
) !void {
    const tag = view.boundaries[view.object_tag_idx];
    const qualified = qualified_tag_name(view.xml, tag);
    try writer.print("      <{s} rdf:about=\"", .{qualified});
    try write_about(writer, view);
    try writer.writeByte('"');
    try emit_local_xmlns(writer, view);
    try emit_conflict_xmlns(writer, view, conflicts);
    try writer.writeAll(">\n");

    var it = ChildIterator.init(view);
    while (it.next()) |child| try writer.print("        {s}\n", .{child.raw});

    try writer.print("      </{s}>\n", .{qualified});
}

/// Re-emit xmlns declarations the source made locally on the object's opening
/// tag. The reconstructed opening tag would otherwise drop them, leaving the
/// object's own prefix (or one used by its copied children) unbound.
fn emit_local_xmlns(writer: *std.Io.Writer, view: tag_index.CimObjectView) !void {
    const tag = view.boundaries[view.object_tag_idx];
    var it = XmlnsIterator{ .slice = view.xml[tag.start..tag.end] };
    while (it.next()) |declaration| try writer.print(" {s}", .{declaration.raw});
}

/// Re-declare model1 root bindings that the merged root rebinds to a different
/// namespace (see merge_xmlns), so statements copied verbatim from model1 keep
/// their source meaning. A prefix the object's own tag declares wins instead —
/// it was inner-most in the source, and attribute names must stay unique.
fn emit_conflict_xmlns(
    writer: *std.Io.Writer,
    view: tag_index.CimObjectView,
    conflicts: []const XmlnsDecl,
) !void {
    const tag = view.boundaries[view.object_tag_idx];
    outer: for (conflicts) |conflict| {
        var it = XmlnsIterator{ .slice = view.xml[tag.start..tag.end] };
        while (it.next()) |local| {
            if (std.mem.eql(u8, local.name, conflict.name)) continue :outer;
        }
        try writer.print(" {s}", .{conflict.raw});
    }
}

/// rdf:about value for an object: rdf:ID-style ids ("_mrid") become the
/// document-relative "#_mrid"; ids that already came from an rdf:about
/// attribute (full URIs) are kept verbatim.
fn write_about(writer: *std.Io.Writer, view: tag_index.CimObjectView) !void {
    const tag = view.boundaries[view.object_tag_idx];
    const opening = view.xml[tag.start..tag.end];
    if (std.mem.indexOf(u8, opening, "rdf:ID=\"") != null) {
        try writer.print("#{s}", .{view.id});
    } else {
        try writer.print("{s}", .{view.id});
    }
}

/// Tag name including its namespace prefix, e.g. "cim:Substation".
fn qualified_tag_name(xml: []const u8, tag: tag_index.TagBoundary) []const u8 {
    const inner = xml[tag.start + 1 .. tag.end];
    const end = std.mem.indexOfAny(u8, inner, " \t\r\n/") orelse inner.len;
    assert(end > 0);
    return inner[0..end];
}

// ── Document assembly ─────────────────────────────────────────────────────────

fn write_document(
    gpa: std.mem.Allocator,
    model1: *EQ,
    model2: *EQ,
    uuid: [36]u8,
    xmlns: *MergedXmlns,
    forward_body: []const u8,
    reverse_body: []const u8,
    writer: anytype,
) !void {
    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rdf:RDF");

    const declarations = &xmlns.declarations;
    if (!has_xmlns(declarations.items, "xmlns:rdf")) {
        try declarations.append(gpa, .{
            .name = "xmlns:rdf",
            .value = rdf_uri,
            .raw = "xmlns:rdf=\"" ++ rdf_uri ++ "\"",
        });
    }

    // The prefixes our generated elements use must bind to the right
    // namespaces even when an input claims "dm" or "md" for something else.
    const dm = try resolve_namespace_prefix(gpa, declarations, "dm", dm_uri);
    defer dm.deinit(gpa);
    const md: ResolvedPrefix = if (full_model(model1) != null)
        try resolve_namespace_prefix(gpa, declarations, "md", md_uri)
    else
        .{ .name = "md", .owned = null };
    defer md.deinit(gpa);

    for (declarations.items) |declaration| try writer.print(" {s}", .{declaration.raw});
    try writer.writeAll(">\n");

    try writer.print("  <{s}:DifferenceModel rdf:about=\"urn:uuid:{s}\">\n", .{ dm.name, uuid });

    // Header metadata: copy model2's FullModel statements verbatim (the
    // difference model describes its target), then record provenance by
    // superseding model1's FullModel.
    if (full_model(model2)) |fm| {
        var it = ChildIterator.init(fm);
        while (it.next()) |child| {
            try writer.writeAll("    ");
            try emit_header_child(writer, child.raw, xmlns.header_conflicts.items);
            try writer.writeByte('\n');
        }
    }
    if (full_model(model1)) |fm| {
        try writer.print("    <{s}:Model.Supersedes rdf:resource=\"{s}\"/>\n", .{ md.name, fm.id });
    }

    try writer.print("    <{s}:forwardDifferences rdf:parseType=\"Statements\">\n", .{dm.name});
    try writer.writeAll(forward_body);
    try writer.print("    </{s}:forwardDifferences>\n", .{dm.name});
    try writer.print("    <{s}:reverseDifferences rdf:parseType=\"Statements\">\n", .{dm.name});
    try writer.writeAll(reverse_body);
    try writer.print("    </{s}:reverseDifferences>\n", .{dm.name});
    try writer.print("  </{s}:DifferenceModel>\n</rdf:RDF>\n", .{dm.name});
}

/// Copy one FullModel child into the DifferenceModel header, re-declaring
/// FullModel-local bindings the merged root rebinds (see merge_xmlns). The
/// child loses its declaring FullModel parent in the copy, so without the
/// re-declaration its prefix would resolve to the root's wrong namespace.
/// The declarations are inserted right after the element name; a prefix the
/// child's own tag declares wins instead (cf. emit_conflict_xmlns).
fn emit_header_child(
    writer: *std.Io.Writer,
    raw: []const u8,
    conflicts: []const XmlnsDecl,
) !void {
    if (conflicts.len == 0) return writer.writeAll(raw);

    assert(raw.len > 1 and raw[0] == '<');
    const name_end = std.mem.indexOfAny(u8, raw, " \t\r\n/>") orelse raw.len;
    const tag_end = std.mem.indexOfScalar(u8, raw, '>') orelse raw.len;

    try writer.writeAll(raw[0..name_end]);
    outer: for (conflicts) |conflict| {
        var it = XmlnsIterator{ .slice = raw[0..tag_end] };
        while (it.next()) |local| {
            if (std.mem.eql(u8, local.name, conflict.name)) continue :outer;
        }
        try writer.print(" {s}", .{conflict.raw});
    }
    try writer.writeAll(raw[name_end..]);
}

/// The prefix generated elements use for a given namespace, plus the backing
/// allocation when a numbered fallback declaration had to be created.
const ResolvedPrefix = struct {
    name: []const u8,
    owned: ?[]u8,

    fn deinit(self: ResolvedPrefix, gpa: std.mem.Allocator) void {
        if (self.owned) |s| gpa.free(s);
    }
};

/// Pick the prefix to use for `uri`: reuse an input declaration already bound
/// to that exact namespace; otherwise declare `preferred`; if an input claims
/// `preferred` for a different namespace, fall back to `preferred0..9`.
fn resolve_namespace_prefix(
    gpa: std.mem.Allocator,
    declarations: *std.ArrayList(XmlnsDecl),
    comptime preferred: []const u8,
    comptime uri: []const u8,
) !ResolvedPrefix {
    for (declarations.items) |declaration| {
        if (std.mem.eql(u8, declaration.value, uri) and
            std.mem.startsWith(u8, declaration.name, "xmlns:"))
        {
            return .{ .name = declaration.name["xmlns:".len..], .owned = null };
        }
    }

    if (!has_xmlns(declarations.items, "xmlns:" ++ preferred)) {
        try declarations.append(gpa, .{
            .name = "xmlns:" ++ preferred,
            .value = uri,
            .raw = "xmlns:" ++ preferred ++ "=\"" ++ uri ++ "\"",
        });
        return .{ .name = preferred, .owned = null };
    }

    // `preferred` is bound to a different namespace; probe a bounded set of
    // numbered alternatives. Ten collisions on one prefix family means the
    // input is adversarial, not a grid model — fail loud.
    for (0..10) |n| {
        const owned = try std.fmt.allocPrint(gpa, "xmlns:" ++ preferred ++ "{d}=\"" ++ uri ++ "\"", .{n});
        errdefer gpa.free(owned);
        const name = owned[0 .. "xmlns:".len + preferred.len + 1];
        if (has_xmlns(declarations.items, name)) {
            gpa.free(owned);
            continue;
        }
        try declarations.append(gpa, .{ .name = name, .value = uri, .raw = owned });
        return .{ .name = name["xmlns:".len..], .owned = owned };
    }
    return error.NamespacePrefixExhausted;
}

/// The output root's xmlns declarations, plus the source bindings the merge
/// rebound to a different namespace. Statements and header children are
/// copied verbatim, so silently dropping a conflicting binding would change
/// what the copied elements mean — emission re-declares `conflicts` locally
/// on every model1-sourced statement block and `header_conflicts` on every
/// FullModel child copied into the DifferenceModel header.
const MergedXmlns = struct {
    declarations: std.ArrayList(XmlnsDecl),
    conflicts: std.ArrayList(XmlnsDecl),
    header_conflicts: std.ArrayList(XmlnsDecl),

    fn deinit(self: *MergedXmlns, gpa: std.mem.Allocator) void {
        self.declarations.deinit(gpa);
        self.conflicts.deinit(gpa);
        self.header_conflicts.deinit(gpa);
    }
};

/// Merge the root xmlns declarations of both inputs: model2 first (the
/// document describes the transformation target, so its prefixes win at the
/// root), then model1 — new prefixes join the root, prefixes the root already
/// binds to a *different* namespace become conflicts. FullModel-local
/// declarations are hoisted the same way: their children lose the declaring
/// parent when copied into the header.
fn merge_xmlns(gpa: std.mem.Allocator, model1: *const EQ, model2: *const EQ) !MergedXmlns {
    var merged: MergedXmlns = .{ .declarations = .empty, .conflicts = .empty, .header_conflicts = .empty };
    errdefer merged.deinit(gpa);

    if (root_element(model2)) |root| {
        try merge_tag_xmlns(gpa, model2.xml[root.start..root.end], &merged.declarations, null);
    }
    if (root_element(model1)) |root| {
        try merge_tag_xmlns(gpa, model1.xml[root.start..root.end], &merged.declarations, &merged.conflicts);
    }

    // Only model2's FullModel children are copied into the header; model1's
    // FullModel contributes nothing verbatim (just its id, in a generated
    // rdf:resource), so its conflicting locals need no re-declaration.
    if (full_model(model2)) |fm| {
        const tag = fm.boundaries[fm.object_tag_idx];
        try merge_tag_xmlns(gpa, fm.xml[tag.start..tag.end], &merged.declarations, &merged.header_conflicts);
    }
    if (full_model(model1)) |fm| {
        const tag = fm.boundaries[fm.object_tag_idx];
        try merge_tag_xmlns(gpa, fm.xml[tag.start..tag.end], &merged.declarations, null);
    }

    return merged;
}

/// Merge one opening tag's xmlns declarations into `declarations`: new
/// prefixes are appended (first declaration of a prefix wins); prefixes
/// already bound to a *different* namespace are recorded in `conflicts` (when
/// given) so emission can re-declare them locally.
fn merge_tag_xmlns(
    gpa: std.mem.Allocator,
    tag_slice: []const u8,
    declarations: *std.ArrayList(XmlnsDecl),
    conflicts: ?*std.ArrayList(XmlnsDecl),
) !void {
    var it = XmlnsIterator{ .slice = tag_slice };
    while (it.next()) |declaration| {
        const existing = find_xmlns(declarations.items, declaration.name) orelse {
            try declarations.append(gpa, declaration);
            continue;
        };
        const list = conflicts orelse continue;
        if (!std.mem.eql(u8, existing.value, declaration.value) and
            !has_xmlns(list.items, declaration.name))
        {
            try list.append(gpa, declaration);
        }
    }
}

fn full_model(model: *const EQ) ?tag_index.CimObjectView {
    const objects = model.get_objects_by_type("FullModel");
    if (objects.len == 0) return null;
    return model.view(objects[0]);
}

/// Semantic comparison of the two FullModel headers: differing presence, id,
/// or statement multiset all count as a difference.
fn full_models_differ(gpa: std.mem.Allocator, model1: *const EQ, model2: *const EQ) !bool {
    const fm1 = full_model(model1) orelse return full_model(model2) != null;
    const fm2 = full_model(model2) orelse return true;

    if (!std.mem.eql(u8, fm1.id, fm2.id)) return true;
    if (std.mem.eql(u8, fm1.raw_xml(), fm2.raw_xml())) return false;

    var changes = try change_set(gpa, fm1, fm2);
    defer changes.deinit(gpa);
    return changes.any();
}

const XmlnsDecl = struct {
    /// Attribute name, e.g. "xmlns:cim" or "xmlns".
    name: []const u8,
    /// The namespace URI the prefix is bound to.
    value: []const u8,
    /// Full attribute slice, e.g. `xmlns:cim="http://..."`.
    raw: []const u8,
};

fn has_xmlns(declarations: []const XmlnsDecl, name: []const u8) bool {
    return find_xmlns(declarations, name) != null;
}

fn find_xmlns(declarations: []const XmlnsDecl, name: []const u8) ?XmlnsDecl {
    for (declarations) |declaration| {
        if (std.mem.eql(u8, declaration.name, name)) return declaration;
    }
    return null;
}

/// Iterate xmlns declarations ("xmlns" or "xmlns:prefix") within an opening
/// tag's slice.
const XmlnsIterator = struct {
    slice: []const u8,
    i: usize = 0,

    fn next(self: *XmlnsIterator) ?XmlnsDecl {
        while (std.mem.indexOfPos(u8, self.slice, self.i, "xmlns")) |pos| {
            // Must start an attribute, i.e. be preceded by whitespace.
            if (pos == 0 or !std.ascii.isWhitespace(self.slice[pos - 1])) {
                self.i = pos + "xmlns".len;
                continue;
            }
            const eq_offset = std.mem.indexOfScalarPos(u8, self.slice, pos, '=') orelse return null;
            const name = std.mem.trimEnd(u8, self.slice[pos..eq_offset], " \t\r\n");
            if (eq_offset + 1 >= self.slice.len or self.slice[eq_offset + 1] != '"') {
                self.i = eq_offset + 1;
                continue;
            }
            const quote_end = std.mem.indexOfScalarPos(u8, self.slice, eq_offset + 2, '"') orelse return null;
            self.i = quote_end + 1;
            return .{
                .name = name,
                .value = self.slice[eq_offset + 2 .. quote_end],
                .raw = self.slice[pos .. quote_end + 1],
            };
        }
        return null;
    }
};

/// The first real element of the document (skipping the XML declaration,
/// comments, and doctype) — for CGMES this is rdf:RDF.
fn root_element(model: *const EQ) ?tag_index.TagBoundary {
    for (model.boundaries) |tag| {
        if (tag.start + 1 >= model.xml.len) return null;
        switch (model.xml[tag.start + 1]) {
            '?', '!', '/' => continue,
            else => return tag,
        }
    }
    return null;
}

// ── Difference-model id ───────────────────────────────────────────────────────

/// Deterministic difference-model id derived from both inputs and any filters:
/// the same diff invocation always produces the same document. Formatted as a
/// version-5-style (name-based) RFC 4122 UUID.
fn difference_model_uuid(
    model1: *const EQ,
    model2: *const EQ,
    options: Options,
    mrid: ?[]const u8,
) [36]u8 {
    var bytes: [16]u8 = undefined;
    inline for (.{ 0, 1 }) |seed| {
        var hasher = std.hash.Wyhash.init(seed);
        hasher.update(model1.xml);
        hasher.update(model2.xml);
        hasher.update(options.type_filter orelse "");
        hasher.update(mrid orelse "");
        std.mem.writeInt(u64, bytes[seed * 8 ..][0..8], hasher.final(), .little);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5 (name-based)
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant

    var out: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 0;
    for (bytes, 0..) |byte, idx| {
        if (idx == 4 or idx == 6 or idx == 8 or idx == 10) {
            out[i] = '-';
            i += 1;
        }
        out[i] = hex[byte >> 4];
        out[i + 1] = hex[byte & 0xf];
        i += 2;
    }
    assert(i == out.len);
    return out;
}
