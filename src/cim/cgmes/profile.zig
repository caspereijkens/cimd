//! Classification of CGMES exchange parts from their leading FullModel
//! metadata. Routing uses exact profile-URI matches; filenames are never
//! consulted.

const std = @import("std");
const xml_scan = @import("../xml_scan.zig");

const assert = std.debug.assert;
const whitespace = " \t\r\n";

pub const profile_uris_max = 8;

/// A specific profile declaration from a FullModel header. These names are
/// version-independent: both the CGMES 2.4 and 3.0 URIs map to the same value.
pub const DeclaredProfile = enum {
    equipment_core,
    equipment_operation,
    equipment_short_circuit,
    equipment_boundary,
    equipment_boundary_operation,
    steady_state_hypothesis,
    topology,
    topology_boundary,
    state_variables,
    diagram_layout,
    dynamics,
    geographical_location,
};

pub const DeclaredProfiles = std.EnumSet(DeclaredProfile);

pub const Version = enum { v2_4_15, v3_0 };

pub const Kind = enum { eq, eqbd, ssh, tp, tpbd, sv, dl, dy, gl };

pub const Profile = union(enum) {
    known: Kind,
    unknown: []const u8,
    absent,
};

pub const Header = struct {
    profile: Profile,
    model_id: []const u8,
    declared_profiles: DeclaredProfiles,
    /// The CGMES version the recognized profile URIs agree on. Null when no URI
    /// was recognized, and also when two were recognized but disagreed: the part
    /// still routes on `profile`, but no version-specific rule may be applied.
    version: ?Version,

    pub fn has_profile(self: Header, profile: DeclaredProfile) bool {
        return self.declared_profiles.contains(profile);
    }
};

const UriKind = struct {
    uri: []const u8,
    kind: Kind,
    declared_profile: DeclaredProfile,
};

// CGMES 2.4.15 and 3.0 exchange profile URIs. These are deliberately exact:
// EquipmentBoundary must never be routed as Equipment, nor TopologyBoundary
// as Topology.
const uri_kinds = [_]UriKind{
    .{ .uri = "http://entsoe.eu/CIM/EquipmentCore/3/1", .kind = .eq, .declared_profile = .equipment_core },
    .{ .uri = "http://entsoe.eu/CIM/EquipmentOperation/3/1", .kind = .eq, .declared_profile = .equipment_operation },
    .{ .uri = "http://entsoe.eu/CIM/EquipmentShortCircuit/3/1", .kind = .eq, .declared_profile = .equipment_short_circuit },
    .{ .uri = "http://entsoe.eu/CIM/EquipmentBoundary/3/1", .kind = .eqbd, .declared_profile = .equipment_boundary },
    .{ .uri = "http://entsoe.eu/CIM/EquipmentBoundaryOperation/3/1", .kind = .eqbd, .declared_profile = .equipment_boundary_operation },
    .{ .uri = "http://entsoe.eu/CIM/SteadyStateHypothesis/1/1", .kind = .ssh, .declared_profile = .steady_state_hypothesis },
    .{ .uri = "http://entsoe.eu/CIM/Topology/4/1", .kind = .tp, .declared_profile = .topology },
    .{ .uri = "http://entsoe.eu/CIM/TopologyBoundary/3/1", .kind = .tpbd, .declared_profile = .topology_boundary },
    .{ .uri = "http://entsoe.eu/CIM/StateVariables/4/1", .kind = .sv, .declared_profile = .state_variables },
    .{ .uri = "http://entsoe.eu/CIM/DiagramLayout/3/1", .kind = .dl, .declared_profile = .diagram_layout },
    .{ .uri = "http://entsoe.eu/CIM/GeographicalLocation/2/1", .kind = .gl, .declared_profile = .geographical_location },
    .{ .uri = "http://entsoe.eu/CIM/Dynamics/3/1", .kind = .dy, .declared_profile = .dynamics },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0", .kind = .eq, .declared_profile = .equipment_core },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/Operation-EU/3.0", .kind = .eq, .declared_profile = .equipment_operation },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/ShortCircuit-EU/3.0", .kind = .eq, .declared_profile = .equipment_short_circuit },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/EquipmentBoundary-EU/3.0", .kind = .eqbd, .declared_profile = .equipment_boundary },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/SteadyStateHypothesis-EU/3.0", .kind = .ssh, .declared_profile = .steady_state_hypothesis },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/Topology-EU/3.0", .kind = .tp, .declared_profile = .topology },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/StateVariables-EU/3.0", .kind = .sv, .declared_profile = .state_variables },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/DiagramLayout-EU/3.0", .kind = .dl, .declared_profile = .diagram_layout },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/GeographicalLocation-EU/3.0", .kind = .gl, .declared_profile = .geographical_location },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/Dynamics-EU/3.0", .kind = .dy, .declared_profile = .dynamics },
};

fn profile_from_uri(uri: []const u8) ?UriKind {
    for (uri_kinds) |entry| {
        if (std.mem.eql(u8, uri, entry.uri)) return entry;
    }
    return null;
}

pub fn kind_from_uri(uri: []const u8) ?Kind {
    const profile = profile_from_uri(uri) orelse return null;
    return profile.kind;
}

pub fn declared_profile_from_uri(uri: []const u8) ?DeclaredProfile {
    const profile = profile_from_uri(uri) orelse return null;
    return profile.declared_profile;
}

pub fn version_from_uri(uri: []const u8) ?Version {
    _ = profile_from_uri(uri) orelse return null;
    if (std.mem.startsWith(u8, uri, "http://entsoe.eu/CIM/")) return .v2_4_15;
    assert(std.mem.startsWith(u8, uri, "http://iec.ch/TC57/ns/CIM/"));
    return .v3_0;
}

/// Bytes inspected around the header in the common case. A FullModel element
/// with `profile_uris_max` URIs is a few hundred bytes and sits at the top of
/// the part; indexing every tag of a 36 MB EQ profile just to read it is the
/// dominant cost of classification. A window too small for the element is
/// retried against the whole part, so this bound never changes an outcome.
const header_window_max = 1 << 20;

const name_start = "FullModel";

/// Inspect FullModel metadata without retaining allocations. Returned strings
/// borrow from `xml`.
pub fn classify(gpa: std.mem.Allocator, xml: []const u8) !Header {
    const candidate = find_header_candidate(xml) orelse return error.NoFullModel;
    // Two candidates may be two headers (ambiguous) or one header plus a
    // mention in a comment or attribute; only the tag walk can tell them
    // apart, so hand the whole part over.
    if (candidate.needs_full_walk) return classify_range(gpa, xml);

    // The window starts at the document, never at the candidate: comments and
    // CDATA sections are only recognised by walking from the beginning, so a
    // slice starting mid-comment would read commented-out markup as a header.
    // A part carries its header at the top, so the retained prefix is short.
    const limit: u64 = @as(u64, candidate.start) + header_window_max;
    if (limit >= xml.len) return classify_range(gpa, xml);
    // Cut between tags. A window ending inside one is malformed XML, and which
    // byte the cut lands on is an accident of the input, so without this the
    // fast path would fall back on roughly half of all parts.
    const end = std.mem.lastIndexOfScalar(u8, xml[0..@intCast(limit)], '>') orelse
        return classify_range(gpa, xml);
    return classify_range(gpa, xml[0 .. end + 1]) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // The element did not fit the window; the part itself is the answer.
        else => classify_range(gpa, xml),
    };
}

/// Longest qualified tag name the filter decides on its own. `md:FullModel` is
/// twelve bytes; anything longer is handed to the tag walk rather than guessed
/// at, so the cap can never hide a header.
const qualified_name_max = 128;

const HeaderCandidate = struct {
    /// Offset of the `<` opening a tag whose local name is `FullModel`.
    start: u32,
    /// The filter could not settle the part on its own: a second candidate, or
    /// a tag name too long to decide.
    needs_full_walk: bool,
};

/// Locate the first tag that could open a FullModel element. This is a filter,
/// not a parser: a tag name cannot be escaped, so it never misses a real
/// header, but a `FullModel` mention inside a comment or an attribute value
/// can add a candidate the exhaustive walk would reject.
/// The scan is anchored on the local name rather than on `<`: a CGMES part has
/// hundreds of thousands of tags but only a handful of `F` bytes, so this is a
/// vectorized byte search that inspects a few dozen positions.
fn find_header_candidate(xml: []const u8) ?HeaderCandidate {
    assert(xml.len <= std.math.maxInt(u32));

    var found: ?u32 = null;
    var search: u32 = 0;
    while (std.mem.indexOfScalarPos(u8, xml, search, name_start[0])) |index| {
        const at: u32 = @intCast(index);
        search = at + 1;
        switch (header_tag_match(xml, at)) {
            .no => {},
            .undecided => return .{ .start = found orelse 0, .needs_full_walk = true },
            .yes => {
                const start = tag_start_before(xml, at);
                if (found != null) return .{ .start = found.?, .needs_full_walk = true };
                found = start;
            },
        }
    }
    return if (found) |start| .{ .start = start, .needs_full_walk = false } else null;
}

const TagMatch = enum { no, yes, undecided };

/// Decide whether the local name at `at` opens a FullModel element, given the
/// qualified name that precedes it and the byte that follows it.
fn header_tag_match(xml: []const u8, at: u32) TagMatch {
    assert(xml[at] == name_start[0]);

    if (!std.mem.startsWith(u8, xml[at..], name_start)) return .no;
    const after = xml[at + name_start.len ..];
    if (after.len == 0) return .no;
    if (after[0] != '>' and after[0] != '/' and
        std.mem.indexOfScalar(u8, whitespace, after[0]) == null) return .no;

    var begin = at;
    while (begin > 0 and at - begin < qualified_name_max and is_name_byte(xml[begin - 1])) {
        begin -= 1;
    }
    // An over-long qualified name is not something this filter should rule on.
    if (at - begin == qualified_name_max) return .undecided;
    if (begin != at and xml[at - 1] != ':') return .no;
    if (begin == 0) return .no;
    // A prefix byte outside the ASCII name set: let the tag walk decide.
    if (xml[begin - 1] >= 0x80) return .undecided;
    return if (xml[begin - 1] == '<') .yes else .no;
}

fn tag_start_before(xml: []const u8, at: u32) u32 {
    var begin = at;
    while (begin > 0 and is_name_byte(xml[begin - 1])) begin -= 1;
    assert(begin > 0 and xml[begin - 1] == '<');
    return begin - 1;
}

fn is_name_byte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == ':' or byte == '_' or
        byte == '-' or byte == '.';
}

fn classify_range(gpa: std.mem.Allocator, xml: []const u8) !Header {
    var boundaries = xml_scan.find_tag_boundaries(gpa, xml) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedHeader,
    };
    defer boundaries.deinit(gpa);

    var full_model_index: ?u32 = null;
    for (boundaries.items, 0..) |tag, i| {
        if (xml[tag.start + 1] == '/' or xml[tag.start + 1] == '!' or xml[tag.start + 1] == '?') continue;
        const type_name = xml_scan.extract_tag_type(xml, tag.start) catch continue;
        if (!std.mem.eql(u8, type_name, "FullModel")) continue;
        if (full_model_index != null) return error.AmbiguousHeader;
        full_model_index = @intCast(i);
    }

    const opening_index = full_model_index orelse return error.NoFullModel;
    const opening = boundaries.items[opening_index];
    if (xml[opening.end - 1] == '/') return error.MalformedHeader;
    const closing_index = xml_scan.find_closing_tag(xml, boundaries.items, opening_index) catch
        return error.MalformedHeader;
    const model_id = xml_scan.extract_rdf_about(xml, opening.start) catch
        return error.MalformedHeader;

    var profile_count: u8 = 0;
    var known: ?Kind = null;
    var first_unknown: ?[]const u8 = null;
    var declared_profiles: DeclaredProfiles = .empty;
    var version: ?Version = null;
    var version_conflict = false;
    var i: u32 = opening_index + 1;
    while (i < closing_index) : (i += 1) {
        const tag = boundaries.items[i];
        if (xml[tag.start + 1] == '/' or xml[tag.start + 1] == '!' or xml[tag.start + 1] == '?') continue;
        const type_name = xml_scan.extract_tag_type(xml, tag.start) catch continue;
        if (!std.mem.eql(u8, type_name, "Model.profile")) continue;
        if (profile_count >= profile_uris_max) return error.AmbiguousHeader;
        profile_count += 1;
        if (xml[tag.end - 1] == '/') return error.MalformedHeader;
        const value_closing = xml_scan.find_closing_tag(xml, boundaries.items, @intCast(i)) catch
            return error.MalformedHeader;
        if (value_closing <= i) return error.MalformedHeader;
        const value = std.mem.trim(u8, xml[tag.end + 1 .. boundaries.items[value_closing].start], whitespace);
        if (value.len == 0) return error.MalformedHeader;
        if (profile_from_uri(value)) |declared_profile| {
            const kind = declared_profile.kind;
            const declared_version = version_from_uri(value).?;
            declared_profiles.insert(declared_profile.declared_profile);
            if (known) |previous| {
                if (previous != kind) return error.AmbiguousHeader;
            } else {
                known = kind;
            }
            // A version disagreement is not a routing failure: the Kind check
            // above is what decides where the part goes, and a transition-era
            // header can name the 2.4.15 and 3.0 URIs of the same profile.
            // Reporting it as ambiguous would abort every command on a file
            // that routes unambiguously, so the version -- advisory data for
            // the validators -- is dropped instead.
            if (version) |previous| {
                if (previous != declared_version) version_conflict = true;
            } else {
                version = declared_version;
            }
        } else if (first_unknown == null) {
            first_unknown = value;
        }
        i = value_closing;
    }

    assert(profile_count <= profile_uris_max);
    return .{
        .model_id = model_id,
        .declared_profiles = declared_profiles,
        .version = if (version_conflict) null else version,
        .profile = if (known) |kind|
            .{ .known = kind }
        else if (first_unknown) |uri|
            .{ .unknown = uri }
        else
            .absent,
    };
}

fn header_xml(comptime profiles: []const u8) []const u8 {
    return "<rdf:RDF><md:FullModel rdf:about=\"urn:uuid:test\">" ++ profiles ++
        "</md:FullModel></rdf:RDF>";
}

test "classify known multi-profile header" {
    const xml = header_xml(
        "<md:Model.profile> http://entsoe.eu/CIM/EquipmentCore/3/1 </md:Model.profile>" ++
            "<md:Model.profile>http://entsoe.eu/CIM/EquipmentOperation/3/1</md:Model.profile>" ++
            "<md:Model.profile>http://example.com/extension</md:Model.profile>" ++
            "<md:Model.profile>http://entsoe.eu/CIM/EquipmentShortCircuit/3/1</md:Model.profile>",
    );
    const header = try classify(std.testing.allocator, xml);
    try std.testing.expectEqual(Kind.eq, header.profile.known);
    try std.testing.expectEqualStrings("urn:uuid:test", header.model_id);
    try std.testing.expect(header.has_profile(.equipment_core));
    try std.testing.expect(header.has_profile(.equipment_operation));
    try std.testing.expect(header.has_profile(.equipment_short_circuit));
    try std.testing.expectEqual(@as(usize, 3), header.declared_profiles.count());
    try std.testing.expectEqual(Version.v2_4_15, header.version.?);
}

test "classify header in a default namespace" {
    const xml =
        "<rdf:RDF xmlns=\"http://iec.ch/TC57/61970-552/ModelDescription/1#\" " ++
        "xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" ++
        "<FullModel rdf:about=\"urn:uuid:default\">" ++
        "<Model.profile>http://entsoe.eu/CIM/EquipmentCore/3/1</Model.profile>" ++
        "</FullModel></rdf:RDF>";

    const header = try classify(std.testing.allocator, xml);
    try std.testing.expectEqual(Kind.eq, header.profile.known);
    try std.testing.expectEqualStrings("urn:uuid:default", header.model_id);
    try std.testing.expect(header.has_profile(.equipment_core));
    try std.testing.expectEqual(Version.v2_4_15, header.version.?);
}

test "classify keeps routing when profile URIs disagree about the version" {
    const xml = header_xml(
        "<md:Model.profile>http://entsoe.eu/CIM/EquipmentCore/3/1</md:Model.profile>" ++
            "<md:Model.profile>http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0</md:Model.profile>",
    );
    const header = try classify(std.testing.allocator, xml);
    try std.testing.expectEqual(Kind.eq, header.profile.known);
    try std.testing.expect(header.has_profile(.equipment_core));
    try std.testing.expectEqual(@as(?Version, null), header.version);

    // Two profiles of the same Kind from different CGMES versions: still one
    // routing answer, and no version for a version-specific rule to trust.
    const mixed = try classify(std.testing.allocator, header_xml(
        "<md:Model.profile>http://entsoe.eu/CIM/EquipmentCore/3/1</md:Model.profile>" ++
            "<md:Model.profile>http://iec.ch/TC57/ns/CIM/Operation-EU/3.0</md:Model.profile>",
    ));
    try std.testing.expectEqual(Kind.eq, mixed.profile.known);
    try std.testing.expect(mixed.has_profile(.equipment_operation));
    try std.testing.expectEqual(@as(?Version, null), mixed.version);
}

test "classify recognizes both equipment operation profile versions" {
    const operation_uris = [_][]const u8{
        "http://entsoe.eu/CIM/EquipmentOperation/3/1",
        "http://iec.ch/TC57/ns/CIM/Operation-EU/3.0",
    };
    const expected_versions = [_]Version{ .v2_4_15, .v3_0 };
    for (operation_uris, expected_versions) |operation_uri, expected_version| {
        const xml = try std.fmt.allocPrint(
            std.testing.allocator,
            "<rdf:RDF><md:FullModel rdf:about=\"urn:uuid:test\">" ++
                "<md:Model.profile>{s}</md:Model.profile>" ++
                "</md:FullModel></rdf:RDF>",
            .{operation_uri},
        );
        defer std.testing.allocator.free(xml);

        const header = try classify(std.testing.allocator, xml);
        try std.testing.expectEqual(Kind.eq, header.profile.known);
        try std.testing.expectEqual(expected_version, header.version.?);
        try std.testing.expect(header.has_profile(.equipment_operation));
        try std.testing.expect(!header.has_profile(.equipment_core));
    }
}

test "classify absent unknown conflicting and duplicate headers" {
    const absent = try classify(std.testing.allocator, header_xml(""));
    try std.testing.expect(absent.profile == .absent);
    try std.testing.expect(absent.version == null);
    try std.testing.expectEqual(@as(usize, 0), absent.declared_profiles.count());

    const unknown = try classify(std.testing.allocator, header_xml(
        "<md:Model.profile>http://example.com/new-profile</md:Model.profile>",
    ));
    try std.testing.expectEqualStrings("http://example.com/new-profile", unknown.profile.unknown);
    try std.testing.expect(unknown.version == null);
    try std.testing.expectEqual(@as(usize, 0), unknown.declared_profiles.count());

    try std.testing.expectError(error.AmbiguousHeader, classify(std.testing.allocator, header_xml(
        "<md:Model.profile>http://entsoe.eu/CIM/EquipmentCore/3/1</md:Model.profile>" ++
            "<md:Model.profile>http://entsoe.eu/CIM/Topology/4/1</md:Model.profile>",
    )));
    try std.testing.expectError(error.AmbiguousHeader, classify(
        std.testing.allocator,
        "<rdf:RDF><md:FullModel rdf:about=\"urn:uuid:first\"></md:FullModel>" ++
            "<md:FullModel rdf:about=\"urn:uuid:second\"></md:FullModel></rdf:RDF>",
    ));
}

test "classify distinguishes missing and malformed metadata" {
    try std.testing.expectError(error.NoFullModel, classify(std.testing.allocator, "<rdf:RDF></rdf:RDF>"));
    try std.testing.expectError(error.MalformedHeader, classify(std.testing.allocator, header_xml(
        "<md:Model.profile> \n\t </md:Model.profile>",
    )));
    try std.testing.expectError(error.MalformedHeader, classify(
        std.testing.allocator,
        "<rdf:RDF><md:FullModel><md:Model.profile>x</md:Model.profile></md:FullModel></rdf:RDF>",
    ));
}

test "header scan ignores FullModel text outside a tag" {
    const gpa = std.testing.allocator;
    const profile = "<md:Model.profile>http://entsoe.eu/CIM/Topology/4/1</md:Model.profile>";
    // A comment, a closing tag and a longer local name all mention the literal
    // the fast scan anchors on; none of them is a second header.
    const commented = try classify(gpa, "<rdf:RDF><!-- FullModel --><md:FullModel rdf:about=\"urn:uuid:a\">" ++
        profile ++ "</md:FullModel><md:FullModelRef/></rdf:RDF>");
    try std.testing.expectEqual(Kind.tp, commented.profile.known);
    try std.testing.expectEqualStrings("urn:uuid:a", commented.model_id);

    // Two real headers stay ambiguous even when a decoy precedes them.
    try std.testing.expectError(error.AmbiguousHeader, classify(gpa, "<rdf:RDF><!-- FullModel --><md:FullModel rdf:about=\"urn:uuid:a\"></md:FullModel>" ++
        "<md:FullModel rdf:about=\"urn:uuid:b\"></md:FullModel></rdf:RDF>"));

    // A commented-out header is tag-shaped, so the scan cannot reject it; the
    // classified range still starts at the document, which is where the
    // comment is recognised.
    try std.testing.expectError(error.NoFullModel, classify(gpa, "<rdf:RDF><!-- <md:FullModel rdf:about=\"urn:uuid:a\">" ++ profile ++
        "</md:FullModel> --></rdf:RDF>"));
}

test "classify windows to a tag boundary" {
    const gpa = std.testing.allocator;
    const head = "<rdf:RDF><md:FullModel rdf:about=\"urn:uuid:near\">" ++
        "<md:Model.profile>http://entsoe.eu/CIM/EquipmentCore/3/1</md:Model.profile></md:FullModel>";
    const filler = "<cim:Substation rdf:ID=\"_s\"><cim:IdentifiedObject.name>x</cim:IdentifiedObject.name></cim:Substation>";
    const tag_start = "<rdf:RDF>".len;

    // Pad until the window edge lands inside a tag rather than between two, the
    // case that used to reindex the whole part.
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(gpa);
    try xml.appendSlice(gpa, head);
    while (xml.items.len < header_window_max * 2) try xml.appendSlice(gpa, filler);
    try xml.appendSlice(gpa, "</rdf:RDF>");

    const edge = xml.items[0 .. header_window_max + tag_start];
    try std.testing.expect(std.mem.lastIndexOfScalar(u8, edge, '<').? >
        std.mem.lastIndexOfScalar(u8, edge, '>').?);

    const header = try classify(gpa, xml.items);
    try std.testing.expectEqual(Kind.eq, header.profile.known);
    try std.testing.expectEqualStrings("urn:uuid:near", header.model_id);
}

test "classify reaches a header past the fast-path window" {
    const gpa = std.testing.allocator;
    const head = "<rdf:RDF><md:FullModel rdf:about=\"urn:uuid:far\">";
    const filler = "<cim:Substation rdf:ID=\"_s\"><cim:IdentifiedObject.name>x</cim:IdentifiedObject.name></cim:Substation>";
    const tail = "<md:Model.profile>http://entsoe.eu/CIM/EquipmentCore/3/1</md:Model.profile></md:FullModel></rdf:RDF>";

    // The element itself spans more than `header_window_max`, so the windowed
    // attempt fails and the whole part is re-read.
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(gpa);
    try xml.appendSlice(gpa, head);
    while (xml.items.len < header_window_max + filler.len) try xml.appendSlice(gpa, filler);
    try xml.appendSlice(gpa, tail);

    const header = try classify(gpa, xml.items);
    try std.testing.expectEqual(Kind.eq, header.profile.known);
    try std.testing.expectEqualStrings("urn:uuid:far", header.model_id);
}

test "profile URI matching is exact at boundary collisions" {
    try std.testing.expectEqual(Kind.eqbd, kind_from_uri("http://entsoe.eu/CIM/EquipmentBoundary/3/1").?);
    try std.testing.expectEqual(Kind.tpbd, kind_from_uri("http://entsoe.eu/CIM/TopologyBoundary/3/1").?);
    try std.testing.expect(kind_from_uri("http://entsoe.eu/CIM/EquipmentBoundary/3/1/extra") == null);
}

test "every supported 2.4.15 and 3.0 URI maps exactly" {
    for (uri_kinds) |entry| {
        try std.testing.expectEqual(entry.kind, kind_from_uri(entry.uri).?);
        try std.testing.expectEqual(entry.declared_profile, declared_profile_from_uri(entry.uri).?);
        try std.testing.expect(version_from_uri(entry.uri) != null);
    }
    try std.testing.expect(kind_from_uri("http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0#") == null);
    try std.testing.expect(declared_profile_from_uri("http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0#") == null);
    try std.testing.expect(version_from_uri("http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0#") == null);
}
