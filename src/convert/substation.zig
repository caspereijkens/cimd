const std = @import("std");
const cim = @import("../cim/cim.zig");
const iidm = @import("../iidm/model.zig");
const CimDocument = cim.CimDocument;
const cross_ref = @import("../topology/cross_ref.zig");
const tag_index = cim.tag_index;
const utils = cim.ids;
const resolve = @import("../topology/resolve.zig");
const parse = cim.parse;

const assert = std.debug.assert;
const Topology = resolve.Topology;

const CimObject = tag_index.CimObject;
const CimObjectView = tag_index.CimObjectView;
const CrossRef = cross_ref.CrossRef;
const strip_hash = utils.strip_hash;

/// Index into `iidm.Network.substations`. `u32` is intentional -- narrower than
/// `usize` per NASA Power of 10 (explicitly-sized integers); the upper bound is
/// enforced by `error.TooManySubstations` in `append_substation`.
pub const SubstationIndex = u32;

// Resolved CGMES region ancestry for a Substation.
const RegionChain = struct {
    sub_region: ?CimObjectView = null,
    region: ?CimObjectView = null,
};

fn resolve_region_chain(model: *const CimDocument, substation: CimObjectView) error{MalformedTag}!RegionChain {
    const sub_region_ref = try substation.getReference("Substation.Region") orelse return .{};
    const sub_region = model.getObjectById(strip_hash(sub_region_ref)) orelse return .{};

    const region_ref = try sub_region.getReference("SubGeographicalRegion.Region") orelse
        return .{ .sub_region = sub_region };
    const region = model.getObjectById(strip_hash(region_ref));
    return .{ .sub_region = sub_region, .region = region };
}

// Resolve the region name for a Substation.
// Substation.Region -> SubGeographicalRegion.IdentifiedObject.name.
fn resolve_geo_tag(sub_region: ?CimObjectView) error{MalformedTag}!?[]const u8 {
    const region = sub_region orelse return null;
    return parse.non_blank(try region.getProperty("IdentifiedObject.name"));
}

// Resolve the country code for a Substation.
// Substation.Region -> SubGeographicalRegion.Region -> GeographicalRegion.IdentifiedObject.name.
fn resolve_country(region: ?CimObjectView) error{MalformedTag}!?[]const u8 {
    const geo_region = region orelse return null;
    return parse.non_blank(try geo_region.getProperty("IdentifiedObject.name"));
}

// mRID (if present) or rdf:ID with leading underscore stripped.
fn resolve_mrid(object: CimObjectView) error{MalformedTag}![]const u8 {
    return object.mrid();
}

// Append one IIDM Substation to the Network. Assumes capacity has been pre-allocated.
// Records the substation's index (and all its stub IDs) into sub_id_map.
fn append_substation(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    topology: *const Topology,
    substation: CimObjectView,
    network: *iidm.Network,
    sub_id_map: *std.StringHashMapUnmanaged(SubstationIndex),
) !void {
    assert(std.mem.eql(u8, substation.type_name, "Substation"));

    const mrid = try resolve_mrid(substation);
    assert(mrid.len > 0);
    const name = parse.non_blank(try substation.getProperty("IdentifiedObject.name"));
    const region_chain = try resolve_region_chain(model, substation);
    const country = try resolve_country(region_chain.region);
    const geo_tag = try resolve_geo_tag(region_chain.sub_region);

    var geo_tags: std.ArrayListUnmanaged([]const u8) = .empty;
    var ownership_transferred = false;
    defer if (!ownership_transferred) geo_tags.deinit(gpa);
    if (geo_tag) |tag| {
        try geo_tags.ensureTotalCapacity(gpa, 1);
        geo_tags.appendAssumeCapacity(tag);
    }

    // CGMES provenance: regionName + regionId + subRegionId. Emitted in pypowsybl's
    // field order so the JIIDM byte stream matches.
    var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
    defer if (!ownership_transferred) properties.deinit(gpa);
    if (region_chain.region) |region| {
        const region_mrid = try resolve_mrid(region);
        const region_name = parse.non_blank(try region.getProperty("IdentifiedObject.name"));
        try properties.ensureTotalCapacity(gpa, 3);
        if (region_name) |rn| {
            properties.appendAssumeCapacity(.{ .name = "CGMES.regionName", .value = rn });
        }
        if (region_chain.sub_region) |sr| {
            const sub_region_mrid = try resolve_mrid(sr);
            properties.appendAssumeCapacity(.{ .name = "CGMES.subRegionId", .value = sub_region_mrid });
        }
        properties.appendAssumeCapacity(.{ .name = "CGMES.regionId", .value = region_mrid });
    }

    // Build MergedSubstation aliases for any stub substations merged into this one.
    var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
    defer if (!ownership_transferred) aliases.deinit(gpa);
    if (topology.substation_merge.get(substation.id)) |stubs| {
        assert(stubs.items.len > 0);
        try aliases.ensureTotalCapacity(gpa, stubs.items.len);
        for (stubs.items, 1..) |stub_id, n| {
            const stub = model.getObjectById(stub_id) orelse continue;
            const stub_mrid = try stub.mrid();
            aliases.appendAssumeCapacity(.{ .type_info = .{ .merged_substation = @intCast(n) }, .content = stub_mrid });
        }
    }

    network.substations.appendAssumeCapacity(.{
        .id = mrid,
        .name = name,
        .country = country,
        .geo_tags = geo_tags,
        .aliases = aliases,
        .properties = properties,
        .voltage_levels = .empty,
        .two_winding_transformers = .empty,
        .three_winding_transformers = .empty,
    });
    ownership_transferred = true;

    const raw_idx = network.substations.items.len - 1;
    if (raw_idx > std.math.maxInt(SubstationIndex)) return error.TooManySubstations;
    const idx: SubstationIndex = @intCast(raw_idx);
    sub_id_map.putAssumeCapacity(substation.id, idx);
    if (topology.substation_merge.get(substation.id)) |stubs| {
        for (stubs.items) |stub_id| sub_id_map.putAssumeCapacity(stub_id, idx);
    }
}

test "append_substation releases partial ownership on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        pub fn run(gpa: std.mem.Allocator) !void {
            const xml =
                \\<rdf:RDF>
                \\  <cim:GeographicalRegion rdf:ID="_GR1">
                \\    <cim:IdentifiedObject.mRID>GR1</cim:IdentifiedObject.mRID>
                \\    <cim:IdentifiedObject.name>Country</cim:IdentifiedObject.name>
                \\  </cim:GeographicalRegion>
                \\  <cim:SubGeographicalRegion rdf:ID="_SGR1">
                \\    <cim:IdentifiedObject.mRID>SGR1</cim:IdentifiedObject.mRID>
                \\    <cim:IdentifiedObject.name>GeoTag</cim:IdentifiedObject.name>
                \\    <cim:SubGeographicalRegion.Region rdf:resource="#_GR1"/>
                \\  </cim:SubGeographicalRegion>
                \\  <cim:Substation rdf:ID="_SS1">
                \\    <cim:IdentifiedObject.mRID>SS1</cim:IdentifiedObject.mRID>
                \\    <cim:Substation.Region rdf:resource="#_SGR1"/>
                \\  </cim:Substation>
                \\  <cim:Substation rdf:ID="_SS2">
                \\    <cim:IdentifiedObject.mRID>SS2</cim:IdentifiedObject.mRID>
                \\  </cim:Substation>
                \\</rdf:RDF>
            ;
            var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
            defer model.deinit(gpa);

            var topology = Topology.empty();
            defer topology.deinit(gpa);
            try topology.substation_merge.ensureTotalCapacity(gpa, 1);
            const merge = topology.substation_merge.getOrPutAssumeCapacity("_SS1");
            merge.value_ptr.* = .empty;
            try merge.value_ptr.append(gpa, "_SS2");

            var network = iidm.Network{
                .id = "test",
                .case_date = null,
                .substations = .empty,
                .lines = .empty,
                .hvdc_lines = .empty,
                .extensions = .empty,
            };
            defer network.deinit(gpa);
            try network.substations.ensureTotalCapacity(gpa, 1);

            var substation_id_map: std.StringHashMapUnmanaged(SubstationIndex) = .empty;
            defer substation_id_map.deinit(gpa);
            try substation_id_map.ensureTotalCapacity(gpa, 2);

            const substation = model.getObjectById("_SS1") orelse return error.TestFailed;
            try append_substation(gpa, &model, &topology, substation, &network, &substation_id_map);
            try std.testing.expectEqual(@as(usize, 1), network.substations.items.len);
            try std.testing.expectEqual(@as(u32, 2), substation_id_map.count());
        }
    }.run, .{});
}

pub fn convert_substations(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    topology: *const Topology,
    network: *iidm.Network,
    substation_id_map: *std.StringHashMapUnmanaged(SubstationIndex),
) !void {
    assert(network.substations.items.len == 0);

    const substations = model.get_objects_by_type("Substation");

    // Collect all stub IDs for O(1) skip checks.
    var stub_count: usize = 0;
    {
        var it = topology.substation_merge.valueIterator();
        while (it.next()) |list| stub_count += list.items.len;
    }

    var stub_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer stub_ids.deinit(gpa);
    try stub_ids.ensureTotalCapacity(gpa, @intCast(stub_count));
    {
        var it = topology.substation_merge.valueIterator();
        while (it.next()) |list| {
            for (list.items) |stub_id| {
                stub_ids.putAssumeCapacity(stub_id, {});
            }
        }
    }
    assert(stub_ids.count() == stub_count);

    try network.substations.ensureTotalCapacity(gpa, @intCast(substations.len - stub_count));
    try substation_id_map.ensureTotalCapacity(gpa, @intCast(substations.len));
    for (substations) |substation| {
        if (stub_ids.contains(substation.id)) continue;
        try append_substation(gpa, model, topology, model.view(substation), network, substation_id_map);
    }

    assert(network.substations.items.len == substations.len - stub_count);
    assert(substation_id_map.count() == substations.len);
}
