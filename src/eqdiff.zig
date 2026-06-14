//! IEC 61970-552 difference model ("EQDIFF") output for `cimd diff`.
//!
//! The difference model carries the statements needed to transform model1
//! into model2:
//!   - dm:forwardDifferences — statements present only in model2
//!     (added objects, new property values).
//!   - dm:reverseDifferences — statements present only in model1
//!     (removed objects, old property values).
//!
//! Change detection (mRID matching, statement multiset comparison) lives in
//! diff_core.zig and is shared with the report formats in diff.zig; this
//! module renders the results as a difference-model document. Statements are
//! copied verbatim from the source XML, so values, escaping, and namespace
//! prefixes survive the round trip; the root element merges the xmlns
//! declarations of both inputs so every copied prefix stays bound. Because
//! copied statements keep their prefixes, inputs that bind the same prefix
//! to two different namespaces cannot be represented and are rejected with
//! error.ConflictingNamespaceBindings rather than silently reinterpreted.
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
const core = @import("diff_core.zig");

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
    writer: *std.Io.Writer,
) !bool {
    var forward: std.Io.Writer.Allocating = .init(gpa);
    defer forward.deinit();
    var reverse: std.Io.Writer.Allocating = .init(gpa);
    defer reverse.deinit();

    const type_names = try core.type_name_union(gpa, model1, model2);
    defer gpa.free(type_names);

    var xmlns = try merge_xmlns(gpa, model1, model2);
    defer xmlns.deinit(gpa);

    const emitter = StatementEmitter{ .forward = &forward.writer, .reverse = &reverse.writer };

    var had_diffs = false;
    for (type_names) |type_name| {
        // FullModel is exchange metadata, not grid data; it feeds the
        // DifferenceModel header instead of the statement sections.
        if (std.mem.eql(u8, type_name, "FullModel")) continue;
        if (!cim_types.matches_filter(type_name, options.type_filter)) continue;
        const stats = try core.match_type(gpa, model1, model2, type_name, &emitter);
        if (stats.any()) had_diffs = true;
    }

    // FullModel emits no statements, but a metadata-only update is still a
    // difference: the exit-code contract promises 0 only for identical inputs.
    if (cim_types.matches_filter("FullModel", options.type_filter)) {
        if (try core.full_models_differ(gpa, model1, model2)) had_diffs = true;
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
    writer: *std.Io.Writer,
) !core.SingleDiffStatus {
    const match = core.match_single(model1, model2, mrid, options.type_filter);
    switch (match) {
        .not_found => return .not_found,
        .type_mismatch => |actual| return .{ .type_mismatch = actual },
        else => {},
    }

    var forward: std.Io.Writer.Allocating = .init(gpa);
    defer forward.deinit();
    var reverse: std.Io.Writer.Allocating = .init(gpa);
    defer reverse.deinit();

    var xmlns = try merge_xmlns(gpa, model1, model2);
    defer xmlns.deinit(gpa);

    var had_diffs = true;
    switch (match) {
        .not_found, .type_mismatch => unreachable,
        .added => |view| try emit_full_object(&forward.writer, view),
        .removed => |view| try emit_full_object(&reverse.writer, view),
        .replaced => |r| {
            // Same mRID, different CIM type: a typed remove+add, since a
            // child-statement delta cannot retype an object.
            try emit_full_object(&reverse.writer, r.old);
            try emit_full_object(&forward.writer, r.new);
        },
        .matched => |m| {
            if (try core.object_changes(gpa, m.old, m.new)) |changes_owned| {
                var changes = changes_owned;
                defer changes.deinit(gpa);
                try emit_description(&forward.writer, m.new, changes.forward.items);
                try emit_description(&reverse.writer, m.old, changes.reverse.items);
            } else {
                had_diffs = false;
            }
        },
    }

    const uuid = difference_model_uuid(model1, model2, options, mrid);
    try write_document(gpa, model1, model2, uuid, &xmlns, forward.written(), reverse.written(), writer);
    return .{ .diff = had_diffs };
}

// ── Statement emission ────────────────────────────────────────────────────────

/// core.match_type emitter: added objects go to forwardDifferences, removed
/// objects to reverseDifferences, changed statements split across both.
const StatementEmitter = struct {
    forward: *std.Io.Writer,
    reverse: *std.Io.Writer,

    pub fn added(self: *const StatementEmitter, view: tag_index.CimObjectView) !void {
        try emit_full_object(self.forward, view);
    }

    pub fn removed(self: *const StatementEmitter, view: tag_index.CimObjectView) !void {
        try emit_full_object(self.reverse, view);
    }

    pub fn changed(
        self: *const StatementEmitter,
        view1: tag_index.CimObjectView,
        view2: tag_index.CimObjectView,
        changes: *const core.ChangeSet,
    ) !void {
        try emit_description(self.forward, view2, changes.forward.items);
        try emit_description(self.reverse, view1, changes.reverse.items);
    }
};

/// One rdf:Description block carrying a subset of an object's statements.
fn emit_description(
    writer: *std.Io.Writer,
    view: tag_index.CimObjectView,
    statements: []const core.Statement,
) !void {
    if (statements.len == 0) return;
    try writer.writeAll("      <rdf:Description rdf:about=\"");
    try write_about(writer, view);
    try writer.writeByte('"');
    try emit_local_xmlns(writer, view);
    try writer.writeAll(">\n");
    for (statements) |statement| try writer.print("        {s}\n", .{statement.raw});
    try writer.writeAll("      </rdf:Description>\n");
}

/// Emit a complete object (typed element, all child statements) for objects
/// present in only one model. Iterates children directly, preserving
/// repeated elements.
fn emit_full_object(writer: *std.Io.Writer, view: tag_index.CimObjectView) !void {
    const tag = view.boundaries[view.object_tag_idx];
    const qualified = qualified_tag_name(view.xml, tag);
    try writer.print("      <{s} rdf:about=\"", .{qualified});
    try write_about(writer, view);
    try writer.writeByte('"');
    try emit_local_xmlns(writer, view);
    try writer.writeAll(">\n");

    var it = core.StatementIterator.init(view);
    while (it.next()) |statement| try writer.print("        {s}\n", .{statement.raw});

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
    declarations: *std.ArrayList(XmlnsDecl),
    forward_body: []const u8,
    reverse_body: []const u8,
    writer: *std.Io.Writer,
) !void {
    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rdf:RDF");

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
    const md: ResolvedPrefix = if (core.full_model(model1) != null)
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
    if (core.full_model(model2)) |fm| {
        var it = core.StatementIterator.init(fm);
        while (it.next()) |statement| try writer.print("    {s}\n", .{statement.raw});
    }
    if (core.full_model(model1)) |fm| {
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

/// Merge the xmlns declarations of both inputs' root elements (the first
/// declaration of a prefix wins) plus model2's FullModel-local ones — its
/// children are copied into the header without their declaring parent.
/// model1's FullModel is not merged: it contributes only its id, inside a
/// generated rdf:resource attribute where prefix bindings are irrelevant,
/// so its local declarations are needed by nothing in the output and must
/// not cause rejection.
///
/// Statements are copied verbatim, so a prefix bound to two different
/// namespaces cannot be represented in the single merged scope: rejected with
/// error.ConflictingNamespaceBindings rather than silently changing what the
/// copied statements mean. (Declarations local to an ordinary object's tag
/// are exempt — emit_local_xmlns re-declares them on the emitted element.)
fn merge_xmlns(gpa: std.mem.Allocator, model1: *const EQ, model2: *const EQ) !std.ArrayList(XmlnsDecl) {
    var declarations: std.ArrayList(XmlnsDecl) = .empty;
    errdefer declarations.deinit(gpa);

    if (root_element(model2)) |root| {
        try merge_tag_xmlns(gpa, model2.xml[root.start..root.end], &declarations);
    }
    if (root_element(model1)) |root| {
        try merge_tag_xmlns(gpa, model1.xml[root.start..root.end], &declarations);
    }
    if (core.full_model(model2)) |fm| {
        const tag = fm.boundaries[fm.object_tag_idx];
        try merge_tag_xmlns(gpa, fm.xml[tag.start..tag.end], &declarations);
    }

    return declarations;
}

/// Merge one opening tag's xmlns declarations into `declarations`: new
/// prefixes are appended; a prefix already bound to the same namespace is
/// skipped; a prefix already bound to a *different* namespace is a conflict.
fn merge_tag_xmlns(
    gpa: std.mem.Allocator,
    tag_slice: []const u8,
    declarations: *std.ArrayList(XmlnsDecl),
) !void {
    var it = XmlnsIterator{ .slice = tag_slice };
    while (it.next()) |declaration| {
        const existing = find_xmlns(declarations.items, declaration.name) orelse {
            try declarations.append(gpa, declaration);
            continue;
        };
        if (!std.mem.eql(u8, existing.value, declaration.value)) {
            return error.ConflictingNamespaceBindings;
        }
    }
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
