const std = @import("std");
const iidm = @import("../iidm.zig");
const cim_model = @import("../cim_model.zig");
const cim_index = @import("../cim_index.zig");
const tag_index = @import("../tag_index.zig");
const utils = @import("../utils.zig");

const assert = std.debug.assert;

const CimModel = cim_model.CimModel;
const CimObject = tag_index.CimObject;
const CimObjectView = tag_index.CimObjectView;
const CimIndex = cim_index.CimIndex;
const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

// Resolve the region name for a Substation.
// Substation.Region -> SubGeographicalRegion.IdentifiedObject.name.
fn resolve_geo_tag(model: *const CimModel, substation: CimObjectView) error{MalformedTag}!?[]const u8 {
    const region_ref = try substation.getReference("Substation.Region") orelse return null;
    const region = model.getObjectById(strip_hash(region_ref)) orelse return null;
    return try region.getProperty("IdentifiedObject.name");
}

// Resolve the country code for a Substation.
// Substation.Region -> SubGeographicalRegion.Region -> GeographicalRegion.IdentifiedObject.name.
fn resolve_country(model: *const CimModel, substation: CimObjectView) error{MalformedTag}!?[]const u8 {
    const region_ref = try substation.getReference("Substation.Region") orelse return null;
    const region = model.getObjectById(strip_hash(region_ref)) orelse return null;

    const geo_region_ref = try region.getReference("SubGeographicalRegion.Region") orelse return null;
    const geo_region = model.getObjectById(strip_hash(geo_region_ref)) orelse return null;
    return try geo_region.getProperty("IdentifiedObject.name");
}

// Append one IIDM Substation to the Network. Assumes capacity has been pre-allocated.
// Records the substation's index (and all its stub IDs) into sub_id_map.
fn append_substation(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    substation: CimObjectView,
    network: *iidm.Network,
    sub_id_map: *std.StringHashMapUnmanaged(usize),
) !void {
    assert(std.mem.eql(u8, substation.type_name, "Substation"));

    const mrid = try substation.getProperty("IdentifiedObject.mRID") orelse strip_underscore(substation.id);
    assert(mrid.len > 0);
    const name = try substation.getProperty("IdentifiedObject.name");
    const country = try resolve_country(model, substation);
    const geo_tag = try resolve_geo_tag(model, substation);

    var geo_tags: std.ArrayListUnmanaged([]const u8) = .empty;
    if (geo_tag) |tag| {
        try geo_tags.ensureTotalCapacity(gpa, 1);
        geo_tags.appendAssumeCapacity(tag);
    }

    // Build MergedSubstation aliases for any stub substations merged into this one.
    var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
    if (index.substation_merge.get(substation.id)) |stubs| {
        assert(stubs.items.len > 0);
        try aliases.ensureTotalCapacity(gpa, stubs.items.len);
        for (stubs.items, 1..) |stub_id, n| {
            const stub = model.getObjectById(stub_id) orelse continue;
            const stub_mrid = try stub.getProperty("IdentifiedObject.mRID") orelse strip_underscore(stub_id);
            const alias_type = try std.fmt.allocPrint(gpa, "MergedSubstation{d}", .{n});
            aliases.appendAssumeCapacity(.{ .type = alias_type, .content = stub_mrid });
        }
    }

    network.substations.appendAssumeCapacity(.{
        .id = mrid,
        .name = name,
        .country = country,
        .geo_tags = geo_tags,
        .aliases = aliases,
        .properties = .empty,
        .voltage_levels = .empty,
        .two_winding_transformers = .empty,
        .three_winding_transformers = .empty,
    });

    const idx = network.substations.items.len - 1;
    sub_id_map.putAssumeCapacity(substation.id, idx);
    if (index.substation_merge.get(substation.id)) |stubs| {
        for (stubs.items) |stub_id| sub_id_map.putAssumeCapacity(stub_id, idx);
    }
}

pub fn convert_substations(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    network: *iidm.Network,
    substation_id_map: *std.StringHashMapUnmanaged(usize),
) !void {
    assert(network.substations.items.len == 0);

    const substations = model.get_objects_by_type("Substation");

    // Collect all stub IDs for O(1) skip checks.
    var stub_count: usize = 0;
    {
        var it = index.substation_merge.valueIterator();
        while (it.next()) |list| stub_count += list.items.len;
    }

    var stub_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer stub_ids.deinit(gpa);
    try stub_ids.ensureTotalCapacity(gpa, @intCast(stub_count));
    {
        var it = index.substation_merge.valueIterator();
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
        try append_substation(gpa, model, index, model.view(substation), network, substation_id_map);
    }

    assert(network.substations.items.len == substations.len - stub_count);
    assert(substation_id_map.count() == substations.len);
}
