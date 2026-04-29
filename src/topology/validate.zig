const std = @import("std");
const utils = @import("../cgmes/ids.zig");
const cim_model = @import("../cgmes/eq.zig");
const cim_index = @import("cross_ref.zig");
const cim_ssh = @import("../cgmes/ssh.zig");
const cim_tp = @import("../cgmes/tp.zig");
const topology = @import("resolve.zig");

const assert = std.debug.assert;

const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

const CimModel = cim_model.CimModel;
const SSH = cim_ssh.SSH;
const TP = cim_tp.TP;
const CimIndex = cim_index.CimIndex;

const IdMap = std.StringHashMapUnmanaged([]const u8);
const ListMap = std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8));
const CountMap = std.StringHashMapUnmanaged(u32);

/// Over-merge: cimd glued multiple TP TNs into one cluster.
/// Under-merge: cimd split a single TP TN into multiple clusters.
const Kind = enum {
    over_merge,
    under_merge,

    fn json_label(self: Kind) []const u8 {
        return switch (self) {
            .over_merge => "over_merge",
            .under_merge => "under_merge",
        };
    }

    fn text_label(self: Kind) []const u8 {
        return switch (self) {
            .over_merge => "over-merge",
            .under_merge => "under-merge",
        };
    }

    /// Field name for the outer group id (the thing being mis-clustered).
    fn group_label(self: Kind) []const u8 {
        return switch (self) {
            .over_merge => "cluster",
            .under_merge => "tn",
        };
    }

    /// Field name for each inner partition id (the distinct things found inside).
    fn partition_label(self: Kind) []const u8 {
        return switch (self) {
            .over_merge => "tn",
            .under_merge => "cluster",
        };
    }
};

/// One CN paired with the partition id it should belong to. The partition id
/// is a TP TN id when detecting over-merges, and a cimd cluster rep when
/// detecting under-merges — same struct, dual roles.
const Pair = struct {
    conn_node_id: []const u8,
    partition_id: []const u8,

    fn less(_: void, a: Pair, b: Pair) bool {
        return std.mem.order(u8, a.partition_id, b.partition_id) == .lt;
    }
};

pub const ValidateOptions = struct {
    /// Emit NDJSON instead of human-readable text.
    json: bool = false,
    /// Print only mismatch counts; skip per-cluster detail.
    summary: bool = false,
};

/// Validate cimd's CN clustering against TP. Returns true when any mismatches
/// were found so the caller can exit 1.
pub fn validate(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    tp: *const TP,
    ssh_opt: ?*const SSH,
    options: ValidateOptions,
    writer: anytype,
) !bool {
    var conn_node_to_root = try topology.build_conn_node_root_map(gpa, model, index, ssh_opt);
    defer conn_node_to_root.deinit(gpa);

    var conn_node_to_topo_node = try build_conn_node_to_topo_node(gpa, model, tp);
    defer conn_node_to_topo_node.deinit(gpa);

    var cimd_groups = try group_by_value(gpa, &conn_node_to_root);
    defer deinit_list_map(gpa, &cimd_groups);

    var tp_groups = try group_by_value(gpa, &conn_node_to_topo_node);
    defer deinit_list_map(gpa, &tp_groups);

    // Scratch must fit the largest group on either side.
    const scratch_cap = @max(largest_list(&cimd_groups), largest_list(&tp_groups));
    const scratch = try gpa.alloc(Pair, scratch_cap);
    defer gpa.free(scratch);

    const over = try detect_mismatches(
        writer,
        options,
        &cimd_groups,
        &conn_node_to_topo_node,
        scratch,
        .over_merge,
    );
    const under = try detect_mismatches(
        writer,
        options,
        &tp_groups,
        &conn_node_to_root,
        scratch,
        .under_merge,
    );

    if (options.summary) {
        try writer.print("over-merges: {d}, under-merges: {d}\n", .{ over, under });
    }

    return over + under > 0;
}

/// For each group, check whether its CNs all map to the same partition id.
/// If not, emit one mismatch record. Returns the number of mismatches found.
fn detect_mismatches(
    writer: anytype,
    options: ValidateOptions,
    groups: *const ListMap,
    cn_to_partition: *const IdMap,
    scratch: []Pair,
    kind: Kind,
) !u32 {
    var count: u32 = 0;
    var it = groups.iterator();
    while (it.next()) |entry| {
        const group_id = entry.key_ptr.*;
        const conn_node_ids = entry.value_ptr.items;

        // Fill (cn, partition) pairs; skip CNs without a partition mapping
        // (boundary CNs, or CNs absent from the TP patch set).
        var n: usize = 0;
        for (conn_node_ids) |conn_node_id| {
            const partition_id = cn_to_partition.get(conn_node_id) orelse continue;
            assert(n < scratch.len);
            scratch[n] = .{ .conn_node_id = conn_node_id, .partition_id = partition_id };
            n += 1;
        }
        if (n < 2) continue;

        std.mem.sort(Pair, scratch[0..n], {}, Pair.less);

        var distinct: u32 = 1;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            if (!std.mem.eql(u8, scratch[i].partition_id, scratch[i - 1].partition_id)) distinct += 1;
        }
        if (distinct < 2) continue;

        count += 1;
        if (!options.summary) try emit_mismatch(writer, options.json, kind, group_id, scratch[0..n]);
    }
    return count;
}

/// Emit one mismatch as NDJSON or human-readable text. `pairs` must be sorted
/// by partition_id so adjacent runs form one partition's CNs.
fn emit_mismatch(
    writer: anytype,
    json: bool,
    kind: Kind,
    group_id: []const u8,
    pairs: []const Pair,
) !void {
    assert(pairs.len >= 2);

    if (json) {
        try writer.print(
            "{{\"kind\":\"{s}\",\"{s}\":\"{s}\",\"partitions\":[",
            .{ kind.json_label(), kind.group_label(), group_id },
        );
        var first = true;
        var i: usize = 0;
        while (i < pairs.len) {
            var j = i + 1;
            while (j < pairs.len and std.mem.eql(u8, pairs[j].partition_id, pairs[i].partition_id)) j += 1;
            if (!first) try writer.writeByte(',');
            try writer.print(
                "{{\"{s}\":\"{s}\",\"cns\":[",
                .{ kind.partition_label(), pairs[i].partition_id },
            );
            for (pairs[i..j], 0..) |p, k| {
                if (k > 0) try writer.writeByte(',');
                try writer.print("\"{s}\"", .{p.conn_node_id});
            }
            try writer.writeAll("]}");
            first = false;
            i = j;
        }
        try writer.writeAll("]}\n");
    } else {
        try writer.print("~ {s}  {s}={s}\n", .{ kind.text_label(), kind.group_label(), group_id });
        var i: usize = 0;
        while (i < pairs.len) {
            var j = i + 1;
            while (j < pairs.len and std.mem.eql(u8, pairs[j].partition_id, pairs[i].partition_id)) j += 1;
            try writer.print("    {s} {s}\n", .{ kind.partition_label(), pairs[i].partition_id });
            for (pairs[i..j]) |p| try writer.print("      cn {s}\n", .{p.conn_node_id});
            i = j;
        }
    }
}

/// Group keys by their value: returns value → list of keys.
/// Two-pass (count, then fill) so each inner list is exact-sized.
fn group_by_value(
    gpa: std.mem.Allocator,
    map: *const IdMap,
) !ListMap {
    var counts: CountMap = .empty;
    defer counts.deinit(gpa);
    try counts.ensureTotalCapacity(gpa, @intCast(map.count()));

    {
        var vit = map.valueIterator();
        while (vit.next()) |value| {
            const gop = counts.getOrPutAssumeCapacity(value.*);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }

    var groups: ListMap = .empty;
    errdefer deinit_list_map(gpa, &groups);
    try groups.ensureTotalCapacity(gpa, counts.count());

    {
        var it = counts.iterator();
        while (it.next()) |e| {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            try list.ensureTotalCapacity(gpa, e.value_ptr.*);
            groups.putAssumeCapacity(e.key_ptr.*, list);
        }
    }

    {
        var it = map.iterator();
        while (it.next()) |e| {
            const list_ptr = groups.getPtr(e.value_ptr.*).?;
            list_ptr.appendAssumeCapacity(e.key_ptr.*);
        }
    }

    assert(groups.count() == counts.count());
    return groups;
}

fn build_conn_node_to_topo_node(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    tp: *const TP,
) !IdMap {
    const conn_nodes = model.get_objects_by_type("ConnectivityNode");

    var conn_node_to_topo_node: IdMap = .empty;
    errdefer conn_node_to_topo_node.deinit(gpa);
    try conn_node_to_topo_node.ensureTotalCapacity(gpa, @intCast(conn_nodes.len));

    for (conn_nodes) |conn_node| {
        const patch = tp.find_patch(strip_underscore(conn_node.id)) orelse continue;
        const topo_node_ref = (try tp.getReferenceFromPatch(
            patch,
            "ConnectivityNode.TopologicalNode",
        )) orelse continue;
        conn_node_to_topo_node.putAssumeCapacity(conn_node.id, strip_hash(topo_node_ref));
    }

    return conn_node_to_topo_node;
}

fn largest_list(groups: *const ListMap) usize {
    var max: usize = 0;
    var vit = groups.valueIterator();
    while (vit.next()) |list| {
        if (list.items.len > max) max = list.items.len;
    }
    return max;
}

fn deinit_list_map(gpa: std.mem.Allocator, groups: *ListMap) void {
    var vit = groups.valueIterator();
    while (vit.next()) |list| list.deinit(gpa);
    groups.deinit(gpa);
}
