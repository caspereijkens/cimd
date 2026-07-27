const std = @import("std");
const cim = @import("../cim/cim.zig");
const topology = @import("resolve.zig");
const CrossRef = @import("cross_ref.zig").CrossRef;
const CimDocument = cim.CimDocument;
const Overlay = cim.Overlay;

const CimObject = cim.CimObject;

const EQ_MALFORMED_LATE_TOPOLOGY_REFERENCE =
    \\<rdf:RDF>
    \\  <cim:VoltageLevel rdf:ID="_VL1">
    \\    <cim:VoltageLevel.BaseVoltage rdf:resource="#_BV1/>
    \\  </cim:VoltageLevel>
    \\  <cim:ConnectivityNode rdf:ID="_CN1">
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:EnergyConsumer rdf:ID="_LOAD1"/>
    \\  <cim:Terminal rdf:ID="_T1">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_LOAD1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN1"/>
    \\  </cim:Terminal>
    \\</rdf:RDF>
;

test "build_topological_nodes reports malformed references after cross-reference succeeds" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, EQ_MALFORMED_LATE_TOPOLOGY_REFERENCE));
    defer model.deinit(gpa);

    const boundary_ids: std.StringHashMapUnmanaged(void) = .empty;
    var index = try CrossRef.build_for_topology(gpa, &model, boundary_ids);
    defer index.deinit(gpa);

    var resolved = try topology.Topology.build_for_topological_nodes(gpa, &model, &index);
    defer resolved.deinit(gpa);

    try std.testing.expectError(
        error.MalformedTag,
        topology.build_topological_nodes(gpa, &model, &index, &resolved, null),
    );
}

test "union_smallest_id_wins: two nodes share root after union" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 1);

    topology.union_smallest_id_wins(&parent, "conn_node1", "conn_node2");

    try std.testing.expectEqualStrings(
        topology.find_root(&parent, "conn_node1"),
        topology.find_root(&parent, "conn_node2"),
    );
}

test "union_smallest_id_wins: idempotent when already same component" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 2);

    topology.union_smallest_id_wins(&parent, "conn_node1", "conn_node2");
    const count = parent.count();
    topology.union_smallest_id_wins(&parent, "conn_node1", "conn_node2");

    try std.testing.expectEqual(count, parent.count());
}

test "union_smallest_id_wins: transitive -- three nodes share root" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 2);

    topology.union_smallest_id_wins(&parent, "a", "b");
    topology.union_smallest_id_wins(&parent, "b", "c");

    const root_a = topology.find_root(&parent, "a");
    const root_b = topology.find_root(&parent, "b");
    const root_c = topology.find_root(&parent, "c");
    try std.testing.expectEqualStrings(root_a, root_b);
    try std.testing.expectEqualStrings(root_b, root_c);
}

test "union_smallest_id_wins: independent clusters do not interfere" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 2);

    topology.union_smallest_id_wins(&parent, "a", "b");
    topology.union_smallest_id_wins(&parent, "x", "y");

    const root_ab = topology.find_root(&parent, "a");
    const root_xy = topology.find_root(&parent, "x");
    try std.testing.expectEqualStrings(root_ab, topology.find_root(&parent, "b"));
    try std.testing.expectEqualStrings(root_xy, topology.find_root(&parent, "y"));
    try std.testing.expect(!std.mem.eql(u8, root_ab, root_xy));
}

test "union_smallest_id_wins: handles existing parent chains" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.ensureTotalCapacity(std.testing.allocator, 3);
    parent.putAssumeCapacity("a", "b");
    parent.putAssumeCapacity("b", "c");

    topology.union_smallest_id_wins(&parent, "a", "d");

    try std.testing.expectEqualStrings("c", topology.find_root(&parent, "a"));
    try std.testing.expectEqualStrings("c", topology.find_root(&parent, "b"));
    try std.testing.expectEqualStrings("c", topology.find_root(&parent, "d"));
}

test "find_root: id not in map returns itself" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("unknown", topology.find_root(&parent, "unknown"));
}

test "find_root: one level deep" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.put(std.testing.allocator, "stub", "repr");

    try std.testing.expectEqualStrings("repr", topology.find_root(&parent, "stub"));
    try std.testing.expectEqualStrings("repr", topology.find_root(&parent, "repr"));
}

test "find_root: two levels deep" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.put(std.testing.allocator, "a", "b");
    try parent.put(std.testing.allocator, "b", "c");

    try std.testing.expectEqualStrings("c", topology.find_root(&parent, "a"));
    try std.testing.expectEqualStrings("c", topology.find_root(&parent, "b"));
    try std.testing.expectEqualStrings("c", topology.find_root(&parent, "c"));
}

test "find_root: chain of four" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.put(std.testing.allocator, "a", "b");
    try parent.put(std.testing.allocator, "b", "c");
    try parent.put(std.testing.allocator, "c", "d");

    try std.testing.expectEqualStrings("d", topology.find_root(&parent, "a"));
    try std.testing.expectEqualStrings("d", topology.find_root(&parent, "b"));
    try std.testing.expectEqualStrings("d", topology.find_root(&parent, "c"));
    try std.testing.expectEqualStrings("d", topology.find_root(&parent, "d"));
}

test "find_root: two independent components" {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer parent.deinit(std.testing.allocator);
    try parent.put(std.testing.allocator, "a", "b");
    try parent.put(std.testing.allocator, "x", "y");

    try std.testing.expectEqualStrings("b", topology.find_root(&parent, "a"));
    try std.testing.expectEqualStrings("y", topology.find_root(&parent, "x"));
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

test "TopologicalNode jsonStringify: escapes strings and uses command field names" {
    const gpa = std.testing.allocator;
    const nodes = [_]topology.TopologicalNode{.{
        .mrid = "CN\"1",
        .name = "Line\\Name\n",
        .base_voltage = "BV1",
        .conn_node_container = "VL1",
    }};

    const json = try std.json.Stringify.valueAlloc(gpa, .{ .topologicalNodes = nodes[0..] }, .{});
    defer gpa.free(json);

    try std.testing.expectEqualStrings(
        "{\"topologicalNodes\":[{\"mrid\":\"CN\\\"1\",\"name\":\"Line\\\\Name\\n\",\"baseVoltage\":\"BV1\",\"voltageLevel\":\"VL1\"}]}",
        json,
    );
}

const EQ_SWITCH_WITH_MISSING_CN =
    \\<rdf:RDF>
    \\  <cim:VoltageLevel rdf:ID="_VL1">
    \\    <cim:IdentifiedObject.mRID>VL1</cim:IdentifiedObject.mRID>
    \\  </cim:VoltageLevel>
    \\  <cim:ConnectivityNode rdf:ID="_CN_A">
    \\    <cim:IdentifiedObject.mRID>CN_A</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:Breaker rdf:ID="_BRK1">
    \\    <cim:IdentifiedObject.mRID>BRK1</cim:IdentifiedObject.mRID>
    \\  </cim:Breaker>
    \\  <cim:Terminal rdf:ID="_T_BRK1_A">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRK1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_A"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\  <cim:Terminal rdf:ID="_T_BRK1_MISSING">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRK1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_MISSING"/>
    \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\</rdf:RDF>
;

test "build_conn_node_root_map: ignores switch endpoints that reference missing ConnectivityNodes" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, EQ_SWITCH_WITH_MISSING_CN));
    defer model.deinit(gpa);

    const boundary_ids: std.StringHashMapUnmanaged(void) = .empty;
    var index = try CrossRef.build_for_topology(gpa, &model, boundary_ids);
    defer index.deinit(gpa);

    var roots = try topology.build_conn_node_root_map(gpa, &model, &index, null);
    defer roots.deinit(gpa);

    try std.testing.expectEqual(@as(@TypeOf(roots.count()), 1), roots.count());
    try std.testing.expectEqualStrings("_CN_A", roots.get("_CN_A").?);
    try std.testing.expect(!roots.contains("_CN_MISSING"));
}

const EQ_DIRECT_BUSBAR =
    \\<rdf:RDF>
    \\  <cim:VoltageLevel rdf:ID="_VL1">
    \\    <cim:IdentifiedObject.mRID>VL1</cim:IdentifiedObject.mRID>
    \\  </cim:VoltageLevel>
    \\  <cim:ConnectivityNode rdf:ID="_CN_A">
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:BusbarSection rdf:ID="_BBS1">
    \\    <cim:IdentifiedObject.mRID>BBS1</cim:IdentifiedObject.mRID>
    \\  </cim:BusbarSection>
    \\  <cim:Terminal rdf:ID="_T_BBS1">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BBS1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_A"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\</rdf:RDF>
;

test "Topology.build: direct busbar ConnectivityNode is reachable from itself" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, EQ_DIRECT_BUSBAR));
    defer model.deinit(gpa);

    const boundary_ids: std.StringHashMapUnmanaged(void) = .empty;
    var index = try CrossRef.build(gpa, &model, boundary_ids);
    defer index.deinit(gpa);

    var topology_data = try topology.Topology.build(gpa, &model, &index);
    defer topology_data.deinit(gpa);

    try std.testing.expectEqualStrings(
        "BBS1",
        topology_data.conn_node_reachable_busbar_section.get("_CN_A").?,
    );
}

test "Topology.build_with_options: can skip reachable busbar index" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, EQ_DIRECT_BUSBAR));
    defer model.deinit(gpa);

    const boundary_ids: std.StringHashMapUnmanaged(void) = .empty;
    var index = try CrossRef.build(gpa, &model, boundary_ids);
    defer index.deinit(gpa);

    var topology_data = try topology.Topology.build_with_options(gpa, &model, &index, .{
        .include_reachable_busbar_section = false,
    });
    defer topology_data.deinit(gpa);

    try std.testing.expectEqual(@as(@TypeOf(topology_data.conn_node_reachable_busbar_section.count()), 0), topology_data.conn_node_reachable_busbar_section.count());
}

test "topology builders tolerate a model without connectivity nodes" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:VoltageLevel.Substation rdf:resource="#_SS1"/>
        \\  </cim:VoltageLevel>
        \\  <cim:BusbarSection rdf:ID="_BBS1"/>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BBS1"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, xml));
    defer model.deinit(gpa);

    const boundary_ids: std.StringHashMapUnmanaged(void) = .empty;
    var index = try CrossRef.build(gpa, &model, boundary_ids);
    defer index.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), index.conn_node_container.count());

    var topology_data = try topology.Topology.build(gpa, &model, &index);
    defer topology_data.deinit(gpa);

    var voltage_levels: std.StringHashMapUnmanaged(void) = .empty;
    defer voltage_levels.deinit(gpa);
    try voltage_levels.put(gpa, "_VL1", {});
    var node_map_result = try topology.build_node_map(gpa, &model, &index, &topology_data, &voltage_levels, null);
    defer node_map_result.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), node_map_result.node_map.count());

    var nodes = try topology.build_topological_nodes(gpa, &model, &index, &topology_data, null);
    defer nodes.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), nodes.items.len);
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

const EQ_SWITCH_XML =
    \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cim="cim:">
    \\  <cim:Breaker rdf:ID="_BRK_OPEN"/>
    \\  <cim:Breaker rdf:ID="_BRK_CLOSED"/>
    \\  <cim:Breaker rdf:ID="_BRK_NO_OPEN_FIELD"/>
    \\</rdf:RDF>
;

test "is_switch_closed: open switch returns false" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, EQ_SWITCH_XML));
    defer model.deinit(gpa);
    var ssh = try Overlay.init_ssh(gpa, try gpa.dupe(u8, SSH_SWITCH_XML));
    defer ssh.deinit(gpa);

    try std.testing.expectEqual(false, try topology.is_switch_closed(&model, &ssh, "_BRK_OPEN"));
}

test "is_switch_closed: closed switch returns true" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, EQ_SWITCH_XML));
    defer model.deinit(gpa);
    var ssh = try Overlay.init_ssh(gpa, try gpa.dupe(u8, SSH_SWITCH_XML));
    defer ssh.deinit(gpa);

    try std.testing.expectEqual(true, try topology.is_switch_closed(&model, &ssh, "_BRK_CLOSED"));
}

test "is_switch_closed: no SSH patch defaults to closed" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, EQ_SWITCH_XML));
    defer model.deinit(gpa);
    var ssh = try Overlay.init_ssh(gpa, try gpa.dupe(u8, SSH_SWITCH_XML));
    defer ssh.deinit(gpa);

    try std.testing.expectEqual(true, try topology.is_switch_closed(&model, &ssh, "_BRK_UNKNOWN"));
}

test "is_switch_closed: patch present without Switch.open defaults to closed" {
    const gpa = std.testing.allocator;
    var model = try CimDocument.init(gpa, try gpa.dupe(u8, EQ_SWITCH_XML));
    defer model.deinit(gpa);
    var ssh = try Overlay.init_ssh(gpa, try gpa.dupe(u8, SSH_SWITCH_XML));
    defer ssh.deinit(gpa);

    try std.testing.expectEqual(true, try topology.is_switch_closed(&model, &ssh, "_BRK_NO_OPEN_FIELD"));
}
