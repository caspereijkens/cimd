//! Tests for `cimd validate-topology`. Each case wires a tiny EQ + TP
//! (and optional SSH) through the validate pipeline and checks the verdict
//! plus the rendered output.

const std = @import("std");
const CimModel = @import("cim_model.zig").CimModel;
const CimSsh = @import("cim_ssh.zig").CimSsh;
const CimTp = @import("cim_tp.zig").CimTp;
const CimIndex = @import("cim_index.zig").CimIndex;
const validate_topology = @import("validate_topology.zig");

const ValidateResult = struct {
    had_mismatches: bool,
    buf: [4096]u8,
    len: usize,

    fn output(self: *const ValidateResult) []const u8 {
        return self.buf[0..self.len];
    }

    fn contains(self: *const ValidateResult, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output(), needle) != null;
    }
};

fn run_validate(
    gpa: std.mem.Allocator,
    eq_xml: []const u8,
    tp_xml: []const u8,
    ssh_xml: ?[]const u8,
    options: validate_topology.ValidateOptions,
) !ValidateResult {
    var model = try CimModel.init(gpa, try gpa.dupe(u8, eq_xml));
    defer model.deinit(gpa);

    var tp = try CimTp.init(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);

    var ssh_opt: ?CimSsh = if (ssh_xml) |xml| try CimSsh.init(gpa, try gpa.dupe(u8, xml)) else null;
    defer if (ssh_opt) |*s| s.deinit(gpa);

    const boundary_ids: std.StringHashMapUnmanaged(void) = .empty;
    var index = try CimIndex.build(gpa, &model, boundary_ids);
    defer index.deinit(gpa);

    const ssh_ptr: ?*const CimSsh = if (ssh_opt) |*s| s else null;

    var result = ValidateResult{ .had_mismatches = false, .buf = undefined, .len = 0 };
    var writer: std.Io.Writer = .fixed(&result.buf);
    result.had_mismatches = try validate_topology.validate(
        gpa,
        &model,
        &index,
        &tp,
        ssh_ptr,
        options,
        &writer,
    );
    result.len = writer.end;
    return result;
}

/// Two CNs in a single VL, joined by a Breaker. SSH-aware tests vary the open flag.
const EQ_TWO_CNS_ONE_SWITCH =
    \\<rdf:RDF>
    \\  <cim:VoltageLevel rdf:ID="_VL1">
    \\    <cim:IdentifiedObject.mRID>VL1</cim:IdentifiedObject.mRID>
    \\  </cim:VoltageLevel>
    \\  <cim:ConnectivityNode rdf:ID="_CN_A">
    \\    <cim:IdentifiedObject.mRID>CN_A</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:ConnectivityNode rdf:ID="_CN_B">
    \\    <cim:IdentifiedObject.mRID>CN_B</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:Breaker rdf:ID="_BRK1">
    \\    <cim:IdentifiedObject.mRID>BRK1</cim:IdentifiedObject.mRID>
    \\    <cim:Switch.retained>false</cim:Switch.retained>
    \\  </cim:Breaker>
    \\  <cim:Terminal rdf:ID="_T_BRK1_A">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRK1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_A"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\  <cim:Terminal rdf:ID="_T_BRK1_B">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRK1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_B"/>
    \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\</rdf:RDF>
;

const SSH_BRK_OPEN =
    \\<rdf:RDF>
    \\  <md:FullModel rdf:about="urn:uuid:SSH"/>
    \\  <cim:Breaker rdf:about="#_BRK1">
    \\    <cim:Switch.open>true</cim:Switch.open>
    \\  </cim:Breaker>
    \\</rdf:RDF>
;

test "validate-topology: identical clusters → no mismatches, no output" {
    // Closed switch unions CN_A+CN_B; TP also groups them under TN1.
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:ConnectivityNode rdf:about="#_CN_A">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ConnectivityNode rdf:about="#_CN_B">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:ConnectivityNode>
        \\</rdf:RDF>
    ;
    const r = try run_validate(std.testing.allocator, EQ_TWO_CNS_ONE_SWITCH, tp_xml, null, .{});
    try std.testing.expect(!r.had_mismatches);
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

test "validate-topology: over-merge — closed switch joins CNs that TP keeps separate" {
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:ConnectivityNode rdf:about="#_CN_A">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ConnectivityNode rdf:about="#_CN_B">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN2"/>
        \\  </cim:ConnectivityNode>
        \\</rdf:RDF>
    ;
    const r = try run_validate(std.testing.allocator, EQ_TWO_CNS_ONE_SWITCH, tp_xml, null, .{});
    try std.testing.expect(r.had_mismatches);
    try std.testing.expect(r.contains("over-merge"));
    // Smallest-id-wins: _CN_A is the cluster representative.
    try std.testing.expect(r.contains("cluster=_CN_A"));
    try std.testing.expect(r.contains("tn _TN1"));
    try std.testing.expect(r.contains("tn _TN2"));
    try std.testing.expect(r.contains("cn _CN_A"));
    try std.testing.expect(r.contains("cn _CN_B"));
    // No under-merges: each TP TN holds only one CN.
    try std.testing.expect(!r.contains("under-merge"));
}

test "validate-topology: under-merge — open switch leaves CNs separate, TP groups them" {
    // SSH_BRK_OPEN flips BRK1 open, so cimd does not union CN_A and CN_B.
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:ConnectivityNode rdf:about="#_CN_A">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ConnectivityNode rdf:about="#_CN_B">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:ConnectivityNode>
        \\</rdf:RDF>
    ;
    const r = try run_validate(std.testing.allocator, EQ_TWO_CNS_ONE_SWITCH, tp_xml, SSH_BRK_OPEN, .{});
    try std.testing.expect(r.had_mismatches);
    try std.testing.expect(r.contains("under-merge"));
    try std.testing.expect(r.contains("tn=_TN1"));
    try std.testing.expect(r.contains("cluster _CN_A"));
    try std.testing.expect(r.contains("cluster _CN_B"));
    // No over-merges: each cimd cluster maps to exactly one TN.
    try std.testing.expect(!r.contains("over-merge"));
}

test "validate-topology: summary mode prints counts only" {
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:ConnectivityNode rdf:about="#_CN_A">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ConnectivityNode rdf:about="#_CN_B">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN2"/>
        \\  </cim:ConnectivityNode>
        \\</rdf:RDF>
    ;
    const r = try run_validate(
        std.testing.allocator,
        EQ_TWO_CNS_ONE_SWITCH,
        tp_xml,
        null,
        .{ .summary = true },
    );
    try std.testing.expect(r.had_mismatches);
    try std.testing.expect(r.contains("over-merges: 1"));
    try std.testing.expect(r.contains("under-merges: 0"));
    // Per-cluster detail is suppressed in summary mode.
    try std.testing.expect(!r.contains("cluster=_CN_A"));
}

/// Same skeleton as EQ_TWO_CNS_ONE_SWITCH but with Switch.retained=true.
/// Retained closed switches become SwitchBranches in the IIDM bus-branch view —
/// each end stays its own TopologicalNode in the TP file.
const EQ_TWO_CNS_RETAINED_SWITCH =
    \\<rdf:RDF>
    \\  <cim:VoltageLevel rdf:ID="_VL1">
    \\    <cim:IdentifiedObject.mRID>VL1</cim:IdentifiedObject.mRID>
    \\  </cim:VoltageLevel>
    \\  <cim:ConnectivityNode rdf:ID="_CN_A">
    \\    <cim:IdentifiedObject.mRID>CN_A</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:ConnectivityNode rdf:ID="_CN_B">
    \\    <cim:IdentifiedObject.mRID>CN_B</cim:IdentifiedObject.mRID>
    \\    <cim:ConnectivityNode.ConnectivityNodeContainer rdf:resource="#_VL1"/>
    \\  </cim:ConnectivityNode>
    \\  <cim:Breaker rdf:ID="_BRK1">
    \\    <cim:IdentifiedObject.mRID>BRK1</cim:IdentifiedObject.mRID>
    \\    <cim:Switch.retained>true</cim:Switch.retained>
    \\  </cim:Breaker>
    \\  <cim:Terminal rdf:ID="_T_BRK1_A">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRK1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_A"/>
    \\    <cim:ACDCTerminal.sequenceNumber>1</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\  <cim:Terminal rdf:ID="_T_BRK1_B">
    \\    <cim:Terminal.ConductingEquipment rdf:resource="#_BRK1"/>
    \\    <cim:Terminal.ConnectivityNode rdf:resource="#_CN_B"/>
    \\    <cim:ACDCTerminal.sequenceNumber>2</cim:ACDCTerminal.sequenceNumber>
    \\  </cim:Terminal>
    \\</rdf:RDF>
;

test "validate-topology: closed retained switch must not union CNs (matches TP separation)" {
    // TP keeps the two ends as distinct TopologicalNodes — that is the IIDM/PyPowSyBl
    // semantic for a retained closed switch (it becomes a SwitchBranch between buses).
    // cimd should mirror this: do not union across retained=true closed switches.
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:ConnectivityNode rdf:about="#_CN_A">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ConnectivityNode rdf:about="#_CN_B">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN2"/>
        \\  </cim:ConnectivityNode>
        \\</rdf:RDF>
    ;
    const r = try run_validate(std.testing.allocator, EQ_TWO_CNS_RETAINED_SWITCH, tp_xml, null, .{});
    try std.testing.expect(!r.had_mismatches);
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

test "validate-topology: json mode emits NDJSON with kind and partitions" {
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:ConnectivityNode rdf:about="#_CN_A">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:ConnectivityNode>
        \\  <cim:ConnectivityNode rdf:about="#_CN_B">
        \\    <cim:ConnectivityNode.TopologicalNode rdf:resource="#_TN2"/>
        \\  </cim:ConnectivityNode>
        \\</rdf:RDF>
    ;
    const r = try run_validate(
        std.testing.allocator,
        EQ_TWO_CNS_ONE_SWITCH,
        tp_xml,
        null,
        .{ .json = true },
    );
    try std.testing.expect(r.had_mismatches);
    try std.testing.expect(r.contains("\"kind\":\"over_merge\""));
    try std.testing.expect(r.contains("\"cluster\":\"_CN_A\""));
    try std.testing.expect(r.contains("\"tn\":\"_TN1\""));
    try std.testing.expect(r.contains("\"tn\":\"_TN2\""));
    // NDJSON: one record terminated by newline.
    try std.testing.expectEqual(@as(u8, '\n'), r.buf[r.len - 1]);
}
