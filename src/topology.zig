const std = @import("std");
const utils = @import("utils.zig");
const cim_model = @import("cim_model.zig");

const assert = std.debug.assert;

const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

const CimModel = cim_model.CimModel;

pub fn find_voltage_level(parent: *const std.StringHashMapUnmanaged([]const u8), id: []const u8) []const u8 {
    var current = id;
    while (true) {
        const p = parent.get(current) orelse return current;
        current = p;
    }
}

pub fn union_voltage_levels(
    model: *const CimModel,
    parent: *std.StringHashMapUnmanaged([]const u8),
    id_a: []const u8,
    id_b: []const u8,
) !void {
    const root_a = find_voltage_level(parent, id_a);
    const root_b = find_voltage_level(parent, id_b);
    if (std.mem.eql(u8, root_a, root_b)) return;

    const voltage_level_a = model.getObjectById(root_a) orelse return;
    const voltage_level_b = model.getObjectById(root_b) orelse return;
    const mrid_a = try voltage_level_a.getProperty("IdentifiedObject.mRID") orelse
        strip_underscore(root_a);
    const mrid_b = try voltage_level_b.getProperty("IdentifiedObject.mRID") orelse
        strip_underscore(root_b);

    // stub points to representative; representative has the smaller mRID
    if (std.mem.lessThan(u8, mrid_a, mrid_b)) {
        parent.putAssumeCapacity(root_b, root_a);
    } else {
        parent.putAssumeCapacity(root_a, root_b);
    }
}

pub fn union_conn_nodes(
    parent: *std.StringHashMapUnmanaged([]const u8),
    id_a: []const u8,
    id_b: []const u8,
) void {
    const root_a = find_voltage_level(parent, id_a);
    const root_b = find_voltage_level(parent, id_b);
    if (std.mem.eql(u8, root_a, root_b)) return;
    parent.putAssumeCapacity(root_a, root_b);
}

/// Union two substation raw IDs. The one with the smaller stripped mRID becomes the root.
pub fn union_substations(
    gpa: std.mem.Allocator,
    parent: *std.StringHashMapUnmanaged([]const u8),
    id_a: []const u8,
    id_b: []const u8,
) !void {
    const root_a = find(parent, id_a);
    const root_b = find(parent, id_b);
    if (std.mem.eql(u8, root_a, root_b)) return;
    // Keep the substation with the smaller mRID as the root (representative).
    if (std.mem.lessThan(u8, strip_underscore(root_a), strip_underscore(root_b))) {
        try parent.put(gpa, root_b, root_a);
    } else {
        try parent.put(gpa, root_a, root_b);
    }
}

/// Union-Find path compression (iterative).
pub fn find(parent: *const std.StringHashMapUnmanaged([]const u8), x: []const u8) []const u8 {
    var cur = x;
    while (true) {
        const p = parent.get(cur) orelse return cur;
        if (std.mem.eql(u8, p, cur)) return cur;
        cur = p;
    }
}
