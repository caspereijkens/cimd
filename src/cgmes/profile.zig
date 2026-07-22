//! Classification of CGMES exchange parts from their leading FullModel
//! metadata. Routing uses exact profile-URI matches; filenames are never
//! consulted.

const std = @import("std");
const tag_index = @import("tag_index.zig");

const assert = std.debug.assert;
const whitespace = " \t\r\n";

pub const profile_uris_max = 8;

pub const Kind = enum { eq, eqbd, ssh, tp, tpbd, sv, dl, dy, gl };

pub const Profile = union(enum) {
    known: Kind,
    unknown: []const u8,
    absent,
};

pub const Header = struct {
    profile: Profile,
    model_id: []const u8,
};

const UriKind = struct {
    uri: []const u8,
    kind: Kind,
};

// CGMES 2.4.15 and 3.0 exchange profile URIs. These are deliberately exact:
// EquipmentBoundary must never be routed as Equipment, nor TopologyBoundary
// as Topology.
const uri_kinds = [_]UriKind{
    .{ .uri = "http://entsoe.eu/CIM/EquipmentCore/3/1", .kind = .eq },
    .{ .uri = "http://entsoe.eu/CIM/EquipmentOperation/3/1", .kind = .eq },
    .{ .uri = "http://entsoe.eu/CIM/EquipmentShortCircuit/3/1", .kind = .eq },
    .{ .uri = "http://entsoe.eu/CIM/EquipmentBoundary/3/1", .kind = .eqbd },
    .{ .uri = "http://entsoe.eu/CIM/EquipmentBoundaryOperation/3/1", .kind = .eqbd },
    .{ .uri = "http://entsoe.eu/CIM/SteadyStateHypothesis/1/1", .kind = .ssh },
    .{ .uri = "http://entsoe.eu/CIM/Topology/4/1", .kind = .tp },
    .{ .uri = "http://entsoe.eu/CIM/TopologyBoundary/3/1", .kind = .tpbd },
    .{ .uri = "http://entsoe.eu/CIM/StateVariables/4/1", .kind = .sv },
    .{ .uri = "http://entsoe.eu/CIM/DiagramLayout/3/1", .kind = .dl },
    .{ .uri = "http://entsoe.eu/CIM/GeographicalLocation/2/1", .kind = .gl },
    .{ .uri = "http://entsoe.eu/CIM/Dynamics/3/1", .kind = .dy },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0", .kind = .eq },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/Operation-EU/3.0", .kind = .eq },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/ShortCircuit-EU/3.0", .kind = .eq },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/EquipmentBoundary-EU/3.0", .kind = .eqbd },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/SteadyStateHypothesis-EU/3.0", .kind = .ssh },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/Topology-EU/3.0", .kind = .tp },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/StateVariables-EU/3.0", .kind = .sv },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/DiagramLayout-EU/3.0", .kind = .dl },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/GeographicalLocation-EU/3.0", .kind = .gl },
    .{ .uri = "http://iec.ch/TC57/ns/CIM/Dynamics-EU/3.0", .kind = .dy },
};

pub fn kind_from_uri(uri: []const u8) ?Kind {
    for (uri_kinds) |entry| {
        if (std.mem.eql(u8, uri, entry.uri)) return entry.kind;
    }
    return null;
}

/// Inspect FullModel metadata without retaining allocations. Returned strings
/// borrow from `xml`.
pub fn classify(gpa: std.mem.Allocator, xml: []const u8) !Header {
    var boundaries = tag_index.find_tag_boundaries(gpa, xml) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedHeader,
    };
    defer boundaries.deinit(gpa);

    var full_model_index: ?u32 = null;
    for (boundaries.items, 0..) |tag, i| {
        if (xml[tag.start + 1] == '/' or xml[tag.start + 1] == '!' or xml[tag.start + 1] == '?') continue;
        const type_name = tag_index.extract_tag_type(xml, tag.start) catch continue;
        if (!std.mem.eql(u8, type_name, "FullModel")) continue;
        if (full_model_index != null) return error.AmbiguousHeader;
        full_model_index = @intCast(i);
    }

    const opening_index = full_model_index orelse return error.NoFullModel;
    const opening = boundaries.items[opening_index];
    if (xml[opening.end - 1] == '/') return error.MalformedHeader;
    const closing_index = tag_index.find_closing_tag(xml, boundaries.items, opening_index) catch
        return error.MalformedHeader;
    const model_id = tag_index.extract_rdf_about(xml, opening.start) catch
        return error.MalformedHeader;

    var profile_count: u8 = 0;
    var known: ?Kind = null;
    var first_unknown: ?[]const u8 = null;
    var i: u32 = opening_index + 1;
    while (i < closing_index) : (i += 1) {
        const tag = boundaries.items[i];
        if (xml[tag.start + 1] == '/' or xml[tag.start + 1] == '!' or xml[tag.start + 1] == '?') continue;
        const type_name = tag_index.extract_tag_type(xml, tag.start) catch continue;
        if (!std.mem.eql(u8, type_name, "Model.profile")) continue;
        if (profile_count >= profile_uris_max) return error.AmbiguousHeader;
        profile_count += 1;
        if (xml[tag.end - 1] == '/') return error.MalformedHeader;
        const value_closing = tag_index.find_closing_tag(xml, boundaries.items, @intCast(i)) catch
            return error.MalformedHeader;
        if (value_closing <= i) return error.MalformedHeader;
        const value = std.mem.trim(u8, xml[tag.end + 1 .. boundaries.items[value_closing].start], whitespace);
        if (value.len == 0) return error.MalformedHeader;
        if (kind_from_uri(value)) |kind| {
            if (known) |previous| {
                if (previous != kind) return error.AmbiguousHeader;
            } else {
                known = kind;
            }
        } else if (first_unknown == null) {
            first_unknown = value;
        }
        i = value_closing;
    }

    assert(profile_count <= profile_uris_max);
    return .{
        .model_id = model_id,
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
            "<md:Model.profile>http://example.com/extension</md:Model.profile>" ++
            "<md:Model.profile>http://entsoe.eu/CIM/EquipmentShortCircuit/3/1</md:Model.profile>",
    );
    const header = try classify(std.testing.allocator, xml);
    try std.testing.expectEqual(Kind.eq, header.profile.known);
    try std.testing.expectEqualStrings("urn:uuid:test", header.model_id);
}

test "classify absent unknown conflicting and duplicate headers" {
    const absent = try classify(std.testing.allocator, header_xml(""));
    try std.testing.expect(absent.profile == .absent);

    const unknown = try classify(std.testing.allocator, header_xml(
        "<md:Model.profile>http://example.com/new-profile</md:Model.profile>",
    ));
    try std.testing.expectEqualStrings("http://example.com/new-profile", unknown.profile.unknown);

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

test "profile URI matching is exact at boundary collisions" {
    try std.testing.expectEqual(Kind.eqbd, kind_from_uri("http://entsoe.eu/CIM/EquipmentBoundary/3/1").?);
    try std.testing.expectEqual(Kind.tpbd, kind_from_uri("http://entsoe.eu/CIM/TopologyBoundary/3/1").?);
    try std.testing.expect(kind_from_uri("http://entsoe.eu/CIM/EquipmentBoundary/3/1/extra") == null);
}

test "every supported 2.4.15 and 3.0 URI maps exactly" {
    for (uri_kinds) |entry| {
        try std.testing.expectEqual(entry.kind, kind_from_uri(entry.uri).?);
    }
    try std.testing.expect(kind_from_uri("http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0#") == null);
}
