const std = @import("std");
const browse = @import("browse.zig");
const EQ = @import("cgmes/eq.zig").EQ;
const TP = @import("cgmes/tp.zig").TP;
const SSH = @import("cgmes/ssh.zig").SSH;
const refs = @import("refs.zig");
const CimObject = @import("cgmes/eq.zig").CimObject;

const BrowseFixture = struct {
    eq: EQ,
    tp: ?TP = null,
    ssh: ?SSH = null,

    fn init(
        gpa: std.mem.Allocator,
        eq_xml: []const u8,
        tp_xml: ?[]const u8,
        ssh_xml: ?[]const u8,
    ) !BrowseFixture {
        return .{
            .eq = try EQ.init(gpa, try gpa.dupe(u8, eq_xml)),
            .tp = if (tp_xml) |xml| try TP.init(gpa, try gpa.dupe(u8, xml)) else null,
            .ssh = if (ssh_xml) |xml| try SSH.init(gpa, try gpa.dupe(u8, xml)) else null,
        };
    }

    fn deinit(self: *BrowseFixture, gpa: std.mem.Allocator) void {
        if (self.ssh) |*ssh| ssh.deinit(gpa);
        if (self.tp) |*tp| tp.deinit(gpa);
        self.eq.deinit(gpa);
    }
};

fn run_browse_session(
    gpa: std.mem.Allocator,
    fixture: *BrowseFixture,
    start_id: []const u8,
    scripted_input: []const u8,
) ![]const u8 {
    var input = std.Io.Reader.fixed(scripted_input);
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();

    try browse.browse(
        undefined,
        gpa,
        .{ .input = &input, .output = &output.writer },
        &fixture.eq,
        fixture.tp,
        fixture.ssh,
        start_id,
    );
    return try output.toOwnedSlice();
}

fn run_pick_session(
    gpa: std.mem.Allocator,
    prefix: []const u8,
    matches: []const CimObject,
    scripted_input: []const u8,
) !struct { output: []const u8, picked: []const u8 } {
    var input = std.Io.Reader.fixed(scripted_input);
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();

    const picked = try browse.pick_from_prefix(
        undefined,
        gpa,
        .{ .input = &input, .output = &output.writer },
        prefix,
        matches,
    );
    return .{ .output = try output.toOwnedSlice(), .picked = picked };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected output to contain:\n{s}\n\nactual output:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("expected output not to contain:\n{s}\n\nactual output:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedContains;
    }
}

fn combined_candidates(
    gpa: std.mem.Allocator,
    eq: *const EQ,
    tp: TP,
    prefix: []const u8,
) ![]const CimObject {
    return refs.collect_target_candidates(gpa, eq, tp, prefix);
}

test "run_browse_session captures a basic object view" {
    const gpa = std.testing.allocator;
    var fixture = try BrowseFixture.init(gpa,
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1">
        \\    <cim:IdentifiedObject.name>North</cim:IdentifiedObject.name>
        \\  </cim:Substation>
        \\</rdf:RDF>
    , null, null);
    defer fixture.deinit(gpa);

    const out = try run_browse_session(gpa, &fixture, "_SS1", "q\n");
    defer gpa.free(out);

    try expectContains(out, "Substation");
    try expectContains(out, "_SS1");
    try expectContains(out, "IdentifiedObject.name");
}

test "browse renders TP and SSH patches inline" {
    const gpa = std.testing.allocator;
    var fixture = try BrowseFixture.init(gpa,
        \\<rdf:RDF>
        \\  <cim:Switch rdf:ID="_SW1">
        \\    <cim:IdentifiedObject.name>Switch One</cim:IdentifiedObject.name>
        \\  </cim:Switch>
        \\  <cim:RegulatingControl rdf:ID="_RC1"/>
        \\  <cim:TopologicalNode rdf:ID="_TN1"/>
        \\</rdf:RDF>
    ,
        \\<rdf:RDF>
        \\  <cim:Switch rdf:about="#_SW1">
        \\    <cim:Switch.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ,
        \\<rdf:RDF>
        \\  <cim:Switch rdf:about="#_SW1">
        \\    <cim:Switch.open>false</cim:Switch.open>
        \\    <cim:RegulatingCondEq.RegulatingControl rdf:resource="#_RC1"/>
        \\  </cim:Switch>
        \\</rdf:RDF>
    );
    defer fixture.deinit(gpa);

    const out = try run_browse_session(gpa, &fixture, "_SW1", "q\n");
    defer gpa.free(out);

    try expectContains(out, "--- TP ---");
    try expectContains(out, "Switch.");
    try expectContains(out, "TopologicalNode");
    try expectContains(out, "--- SSH ---");
    try expectContains(out, "Switch.open");
    try expectContains(out, "RegulatingCondEq.");
    try expectContains(out, "RegulatingControl");
}

test "browse back refs flat below threshold" {
    const gpa = std.testing.allocator;
    var fixture = try BrowseFixture.init(gpa,
        \\<rdf:RDF>
        \\  <cim:Line rdf:ID="_L1"/>
        \\  <cim:ACLineSegment rdf:ID="_A1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_L1"/>
        \\  </cim:ACLineSegment>
        \\  <cim:Switch rdf:ID="_SW1">
        \\    <cim:Equipment.EquipmentContainer rdf:resource="#_L1"/>
        \\  </cim:Switch>
        \\</rdf:RDF>
    , null, null);
    defer fixture.deinit(gpa);

    const out = try run_browse_session(gpa, &fixture, "_L1", "r\nq\n");
    defer gpa.free(out);

    try expectContains(out, "References to Line");
    try expectContains(out, "ACLineSegment");
    try expectContains(out, "Switch");
    try expectNotContains(out, "pick a type to drill in");
}

test "browse back refs grouped above threshold" {
    const gpa = std.testing.allocator;
    var fixture = try BrowseFixture.init(gpa,
        \\<rdf:RDF>
        \\  <cim:Line rdf:ID="_L1"/>
        \\  <cim:ACLineSegment rdf:ID="_A01"><cim:Equipment.EquipmentContainer rdf:resource="#_L1"/></cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_A02"><cim:Equipment.EquipmentContainer rdf:resource="#_L1"/></cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_A03"><cim:Equipment.EquipmentContainer rdf:resource="#_L1"/></cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_A04"><cim:Equipment.EquipmentContainer rdf:resource="#_L1"/></cim:ACLineSegment>
        \\  <cim:ACLineSegment rdf:ID="_A05"><cim:Equipment.EquipmentContainer rdf:resource="#_L1"/></cim:ACLineSegment>
        \\  <cim:Switch rdf:ID="_SW01"><cim:Equipment.EquipmentContainer rdf:resource="#_L1"/></cim:Switch>
        \\  <cim:Switch rdf:ID="_SW02"><cim:Equipment.EquipmentContainer rdf:resource="#_L1"/></cim:Switch>
        \\  <cim:Switch rdf:ID="_SW03"><cim:Equipment.EquipmentContainer rdf:resource="#_L1"/></cim:Switch>
        \\  <cim:Switch rdf:ID="_SW04"><cim:Equipment.EquipmentContainer rdf:resource="#_L1"/></cim:Switch>
        \\  <cim:Switch rdf:ID="_SW05"><cim:Equipment.EquipmentContainer rdf:resource="#_L1"/></cim:Switch>
        \\</rdf:RDF>
    , null, null);
    defer fixture.deinit(gpa);

    const out = try run_browse_session(gpa, &fixture, "_L1", "r\nq\n");
    defer gpa.free(out);

    try expectContains(out, "10 referrers");
    try expectContains(out, "pick a type to drill in");
    try expectContains(out, "ACLineSegment");
    try expectContains(out, "Switch");
    try expectContains(out, "(All)");
}

test "prefix picker flat below threshold" {
    const gpa = std.testing.allocator;
    var fixture = try BrowseFixture.init(gpa,
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_P1"/>
        \\  <cim:VoltageLevel rdf:ID="_P2"/>
        \\</rdf:RDF>
    , null, null);
    defer fixture.deinit(gpa);

    const matches = try fixture.eq.get_object_by_id_prefix(gpa, "P");
    defer gpa.free(matches);
    const result = try run_pick_session(gpa, "P", matches, "1\n");
    defer gpa.free(result.output);

    try std.testing.expect(std.mem.startsWith(u8, result.picked, "_P"));
    try expectContains(result.output, "'P' matched 2 objects:");
    try expectContains(result.output, "Substation");
    try expectContains(result.output, "VoltageLevel");
    try expectNotContains(result.output, "pick a type to drill in");
}

test "prefix picker grouped above threshold and drill-down" {
    const gpa = std.testing.allocator;
    var fixture = try BrowseFixture.init(gpa,
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_P01"/>
        \\  <cim:Substation rdf:ID="_P02"/>
        \\  <cim:Substation rdf:ID="_P03"/>
        \\  <cim:Substation rdf:ID="_P04"/>
        \\  <cim:Substation rdf:ID="_P05"/>
        \\  <cim:VoltageLevel rdf:ID="_P06"/>
        \\  <cim:VoltageLevel rdf:ID="_P07"/>
        \\  <cim:VoltageLevel rdf:ID="_P08"/>
        \\  <cim:VoltageLevel rdf:ID="_P09"/>
        \\  <cim:VoltageLevel rdf:ID="_P10"/>
        \\</rdf:RDF>
    , null, null);
    defer fixture.deinit(gpa);

    const matches = try fixture.eq.get_object_by_id_prefix(gpa, "P");
    defer gpa.free(matches);
    const result = try run_pick_session(gpa, "P", matches, "1\n1\n");
    defer gpa.free(result.output);

    try expectContains(result.output, "'P' matched 10 objects");
    try expectContains(result.output, "pick a type to drill in");
    try expectContains(result.output, "(All)");
    try expectContains(result.output, "'P' / ");
    try std.testing.expect(std.mem.startsWith(u8, result.picked, "_P"));
}

test "prefix candidates span EQ and TP" {
    const gpa = std.testing.allocator;
    var fixture = try BrowseFixture.init(gpa,
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_X1"/>
        \\</rdf:RDF>
    ,
        \\<rdf:RDF>
        \\  <cim:TopologicalNode rdf:ID="_X2"/>
        \\</rdf:RDF>
    , null);
    defer fixture.deinit(gpa);
    const tp = fixture.tp orelse unreachable;

    const matches = try combined_candidates(gpa, &fixture.eq, tp, "X");
    defer gpa.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    const result = try run_pick_session(gpa, "X", matches, "2\n");
    defer gpa.free(result.output);

    try std.testing.expect(std.mem.startsWith(u8, result.picked, "_X"));
    try expectContains(result.output, "Terminal");
    try expectContains(result.output, "TopologicalNode");
}

test "back at root prints nudge" {
    const gpa = std.testing.allocator;
    var fixture = try BrowseFixture.init(gpa,
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\</rdf:RDF>
    , null, null);
    defer fixture.deinit(gpa);

    const out = try run_browse_session(gpa, &fixture, "_SS1", "b\nq\n");
    defer gpa.free(out);

    try expectContains(out, "Already at root");
}

test "zero-referrer object prints No referrers" {
    const gpa = std.testing.allocator;
    var fixture = try BrowseFixture.init(gpa,
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\</rdf:RDF>
    , null, null);
    defer fixture.deinit(gpa);

    const out = try run_browse_session(gpa, &fixture, "_SS1", "r\nq\n");
    defer gpa.free(out);

    try expectContains(out, "No referrers.");
}

test "patch rendering preserves ordering: object < TP < SSH" {
    const gpa = std.testing.allocator;
    var fixture = try BrowseFixture.init(gpa,
        \\<rdf:RDF>
        \\  <cim:Switch rdf:ID="_SW1">
        \\    <cim:IdentifiedObject.name>Switch One</cim:IdentifiedObject.name>
        \\  </cim:Switch>
        \\  <cim:TopologicalNode rdf:ID="_TN1"/>
        \\</rdf:RDF>
    ,
        \\<rdf:RDF>
        \\  <cim:Switch rdf:about="#_SW1">
        \\    <cim:Switch.TopologicalNode rdf:resource="#_TN1"/>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ,
        \\<rdf:RDF>
        \\  <cim:Switch rdf:about="#_SW1">
        \\    <cim:Switch.open>false</cim:Switch.open>
        \\  </cim:Switch>
        \\</rdf:RDF>
    );
    defer fixture.deinit(gpa);

    const out = try run_browse_session(gpa, &fixture, "_SW1", "q\n");
    defer gpa.free(out);

    const obj_idx = std.mem.indexOf(u8, out, "Switch One").?;
    const tp_idx = std.mem.indexOf(u8, out, "--- TP ---").?;
    const ssh_idx = std.mem.indexOf(u8, out, "--- SSH ---").?;
    try std.testing.expect(obj_idx < tp_idx);
    try std.testing.expect(tp_idx < ssh_idx);
}

test "follow reference builds breadcrumb trace" {
    const gpa = std.testing.allocator;
    var fixture = try BrowseFixture.init(gpa,
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_SS1"/>
        \\  <cim:VoltageLevel rdf:ID="_VL1">
        \\    <cim:VoltageLevel.Substation rdf:resource="#_SS1"/>
        \\  </cim:VoltageLevel>
        \\</rdf:RDF>
    , null, null);
    defer fixture.deinit(gpa);

    // Start at _VL1, follow the only numbered reference (-> _SS1), then quit.
    const out = try run_browse_session(gpa, &fixture, "_VL1", "1\nq\n");
    defer gpa.free(out);

    // After the follow, the footer of the second screen shows the trace.
    try expectContains(out, "VoltageLevel -> Substation");
}

test "prefix picker can expand grouped overview to flat all" {
    const gpa = std.testing.allocator;
    var fixture = try BrowseFixture.init(gpa,
        \\<rdf:RDF>
        \\  <cim:Substation rdf:ID="_Q01"/>
        \\  <cim:Substation rdf:ID="_Q02"/>
        \\  <cim:Substation rdf:ID="_Q03"/>
        \\  <cim:Substation rdf:ID="_Q04"/>
        \\  <cim:Substation rdf:ID="_Q05"/>
        \\  <cim:VoltageLevel rdf:ID="_Q06"/>
        \\  <cim:VoltageLevel rdf:ID="_Q07"/>
        \\  <cim:VoltageLevel rdf:ID="_Q08"/>
        \\  <cim:VoltageLevel rdf:ID="_Q09"/>
        \\  <cim:VoltageLevel rdf:ID="_Q10"/>
        \\</rdf:RDF>
    , null, null);
    defer fixture.deinit(gpa);

    const matches = try fixture.eq.get_object_by_id_prefix(gpa, "Q");
    defer gpa.free(matches);
    const result = try run_pick_session(gpa, "Q", matches, "3\n10\n");
    defer gpa.free(result.output);

    try std.testing.expect(std.mem.startsWith(u8, result.picked, "_Q"));
    try expectContains(result.output, "'Q' matched 10 objects");
    try expectContains(result.output, " [1-10]");
}
