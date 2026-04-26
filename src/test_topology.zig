const std = @import("std");
const topology = @import("topology.zig");
const tag_index = @import("tag_index.zig");
const CimSsh = @import("cim_ssh.zig").CimSsh;

const CimObject = tag_index.CimObject;

test "union_conn_nodes: two nodes share root after union" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 1);

    topology.union_conn_nodes(&parent, "conn_node1", "conn_node2");

    try std.testing.expectEqualStrings(
        topology.find_voltage_level(&parent, "conn_node1"),
        topology.find_voltage_level(&parent, "conn_node2"),
    );
}

test "union_conn_nodes: idempotent when already same component" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 2);

    topology.union_conn_nodes(&parent, "conn_node1", "conn_node2");
    const count = parent.count();
    topology.union_conn_nodes(&parent, "conn_node1", "conn_node2");

    try std.testing.expectEqual(count, parent.count());
}

test "union_conn_nodes: transitive — three nodes share root" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 2);

    topology.union_conn_nodes(&parent, "a", "b");
    topology.union_conn_nodes(&parent, "b", "c");

    const root_a = topology.find_voltage_level(&parent, "a");
    const root_b = topology.find_voltage_level(&parent, "b");
    const root_c = topology.find_voltage_level(&parent, "c");
    try std.testing.expectEqualStrings(root_a, root_b);
    try std.testing.expectEqualStrings(root_b, root_c);
}

test "union_conn_nodes: independent clusters do not interfere" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 2);

    topology.union_conn_nodes(&parent, "a", "b");
    topology.union_conn_nodes(&parent, "x", "y");

    const root_ab = topology.find_voltage_level(&parent, "a");
    const root_xy = topology.find_voltage_level(&parent, "x");
    try std.testing.expectEqualStrings(root_ab, topology.find_voltage_level(&parent, "b"));
    try std.testing.expectEqualStrings(root_xy, topology.find_voltage_level(&parent, "y"));
    try std.testing.expect(!std.mem.eql(u8, root_ab, root_xy));
}

test "find_voltage_level: id not in map returns itself" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("unknown", topology.find_voltage_level(&parent, "unknown"));
}

test "find_voltage_level: one level deep" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.put(std.testing.allocator, "stub", "repr");

    try std.testing.expectEqualStrings("repr", topology.find_voltage_level(&parent, "stub"));
    try std.testing.expectEqualStrings("repr", topology.find_voltage_level(&parent, "repr"));
}

test "find_voltage_level: two levels deep" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.put(std.testing.allocator, "a", "b");
    try parent.put(std.testing.allocator, "b", "c");

    try std.testing.expectEqualStrings("c", topology.find_voltage_level(&parent, "a"));
    try std.testing.expectEqualStrings("c", topology.find_voltage_level(&parent, "b"));
    try std.testing.expectEqualStrings("c", topology.find_voltage_level(&parent, "c"));
}

test "find_voltage_level: chain of four" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.put(std.testing.allocator, "a", "b");
    try parent.put(std.testing.allocator, "b", "c");
    try parent.put(std.testing.allocator, "c", "d");

    try std.testing.expectEqualStrings("d", topology.find_voltage_level(&parent, "a"));
    try std.testing.expectEqualStrings("d", topology.find_voltage_level(&parent, "b"));
    try std.testing.expectEqualStrings("d", topology.find_voltage_level(&parent, "c"));
    try std.testing.expectEqualStrings("d", topology.find_voltage_level(&parent, "d"));
}

test "find_voltage_level: two independent components" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.put(std.testing.allocator, "a", "b");
    try parent.put(std.testing.allocator, "x", "y");

    try std.testing.expectEqualStrings("b", topology.find_voltage_level(&parent, "a"));
    try std.testing.expectEqualStrings("y", topology.find_voltage_level(&parent, "x"));
}

test "topology.get_switch_count: all empty slices returns zero" {
    const slices = [topology.switch_types.len][]const CimObject{ &.{}, &.{}, &.{} };
    try std.testing.expectEqual(@as(usize, 0), topology.get_switch_count(slices));
}

test "topology.get_switch_count: one non-empty slice" {
    var objs: [3]CimObject = undefined;
    const slices = [topology.switch_types.len][]const CimObject{ &objs, &.{}, &.{} };
    try std.testing.expectEqual(@as(usize, 3), topology.get_switch_count(slices));
}

test "topology.get_switch_count: all non-empty slices summed" {
    var a: [2]CimObject = undefined;
    var b: [5]CimObject = undefined;
    var c: [1]CimObject = undefined;
    const slices = [topology.switch_types.len][]const CimObject{ &a, &b, &c };
    try std.testing.expectEqual(@as(usize, 8), topology.get_switch_count(slices));
}

test "topology.get_switch_count: mixed empty and non-empty" {
    var objs: [4]CimObject = undefined;
    const slices = [topology.switch_types.len][]const CimObject{ &.{}, &objs, &.{} };
    try std.testing.expectEqual(@as(usize, 4), topology.get_switch_count(slices));
}

const SSH_SWITCH_XML =
    \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="cim:" xmlns:md="md:">
    \\  <md:FullModel rdf:about="urn:uuid:SSH_FM"/>
    \\  <cim:Breaker rdf:about="#_BRK_OPEN">
    \\    <cim:Switch.open>true</cim:Switch.open>
    \\  </cim:Breaker>
    \\  <cim:Breaker rdf:about="#_BRK_CLOSED">
    \\    <cim:Switch.open>false</cim:Switch.open>
    \\  </cim:Breaker>
    \\  <cim:Breaker rdf:about="#_BRK_NO_OPEN_FIELD">
    \\    <cim:Switch.retained>true</cim:Switch.retained>
    \\  </cim:Breaker>
    \\</rdf:RDF>
;

test "is_switch_closed: open switch returns false" {
    const gpa = std.testing.allocator;
    var ssh = try CimSsh.init(gpa, try gpa.dupe(u8, SSH_SWITCH_XML));
    defer ssh.deinit(gpa);

    try std.testing.expectEqual(false, try topology.is_switch_closed(&ssh, "_BRK_OPEN"));
}

test "is_switch_closed: closed switch returns true" {
    const gpa = std.testing.allocator;
    var ssh = try CimSsh.init(gpa, try gpa.dupe(u8, SSH_SWITCH_XML));
    defer ssh.deinit(gpa);

    try std.testing.expectEqual(true, try topology.is_switch_closed(&ssh, "_BRK_CLOSED"));
}

test "is_switch_closed: no SSH patch defaults to closed" {
    const gpa = std.testing.allocator;
    var ssh = try CimSsh.init(gpa, try gpa.dupe(u8, SSH_SWITCH_XML));
    defer ssh.deinit(gpa);

    try std.testing.expectEqual(true, try topology.is_switch_closed(&ssh, "_BRK_UNKNOWN"));
}

test "is_switch_closed: patch present without Switch.open defaults to closed" {
    const gpa = std.testing.allocator;
    var ssh = try CimSsh.init(gpa, try gpa.dupe(u8, SSH_SWITCH_XML));
    defer ssh.deinit(gpa);

    try std.testing.expectEqual(true, try topology.is_switch_closed(&ssh, "_BRK_NO_OPEN_FIELD"));
}
