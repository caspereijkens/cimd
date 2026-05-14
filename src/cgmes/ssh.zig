const std = @import("std");
const tag_index = @import("tag_index.zig");
const utils = @import("ids.zig");
const TP = @import("tp.zig").TP;
const TpPatch = @import("tp.zig").TpPatch;

const assert = std.debug.assert;

pub const SshPatch = struct {
    mrid: []const u8,
    patch_tag_idx: u32,
    closing_tag_idx: u32,
};

pub const SSH = struct {
    xml: []const u8,
    boundaries: []const tag_index.TagBoundary,
    patches: []const SshPatch,

    /// Takes ownership of `xml`: on success the SSH owns it (freed by deinit),
    /// on error it is freed before returning. Callers never need to clean up `xml`.
    pub fn init(gpa: std.mem.Allocator, xml: []const u8) !SSH {
        errdefer gpa.free(xml);
        assert(xml.len > 0);

        var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
        errdefer boundaries.deinit(gpa);

        const closing_for = try tag_index.build_closing_index(gpa, xml, boundaries.items);
        defer gpa.free(closing_for);

        var patch_count: usize = 0;
        for (boundaries.items) |tag| {
            if (extract_patch_mrid(xml, tag.start) != null) patch_count += 1;
        }

        const patches = try gpa.alloc(SshPatch, patch_count);
        errdefer gpa.free(patches);

        var write_idx: usize = 0;
        for (boundaries.items, 0..) |tag, tag_idx| {
            const mrid = extract_patch_mrid(xml, tag.start) orelse continue;
            assert(write_idx < patch_count);
            patches[write_idx] = .{
                .mrid = mrid,
                .patch_tag_idx = @intCast(tag_idx),
                .closing_tag_idx = closing_for[tag_idx],
            };
            write_idx += 1;
        }
        assert(write_idx == patch_count);

        std.mem.sort(SshPatch, patches, {}, patch_less_than);
        if (patches.len > 1) {
            for (patches[1..], 1..) |patch, i| {
                if (std.mem.eql(u8, patches[i - 1].mrid, patch.mrid)) return error.DuplicateId;
            }
        }

        return .{
            .xml = xml,
            .boundaries = try boundaries.toOwnedSlice(gpa),
            .patches = patches,
        };
    }

    pub fn deinit(self: *SSH, gpa: std.mem.Allocator) void {
        gpa.free(self.patches);
        gpa.free(self.boundaries);
        gpa.free(self.xml);
    }

    /// Look up the patch for an mRID. Returns null if not present in SSH.
    /// Use the returned SshPatch with getPropertyFromPatch/getReferenceFromPatch
    /// when reading multiple properties for the same object — avoids redundant
    /// binary searches.
    pub fn find_patch(self: SSH, mrid: []const u8) ?SshPatch {
        assert(mrid.len > 0);
        var lo: usize = 0;
        var hi: usize = self.patches.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.patches[mid].mrid, mrid)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return self.patches[mid],
            }
        }
        return null;
    }

    /// Read a text property from a patch returned by find_patch.
    pub fn getPropertyFromPatch(self: SSH, patch: SshPatch, property_name: []const u8) !?[]const u8 {
        return tag_index.get_property_from_indices(
            self.xml,
            self.boundaries,
            patch.patch_tag_idx,
            patch.closing_tag_idx,
            property_name,
        );
    }

    /// Read an rdf:resource reference from a patch returned by find_patch.
    pub fn getReferenceFromPatch(self: SSH, patch: SshPatch, reference_name: []const u8) !?[]const u8 {
        return tag_index.get_reference_from_indices(
            self.xml,
            self.boundaries,
            patch.patch_tag_idx,
            patch.closing_tag_idx,
            reference_name,
        );
    }

    /// Convenience wrapper for single-property lookups (e.g. eq get).
    /// For multiple properties on the same object, use find_patch + getPropertyFromPatch.
    pub fn getProperty(self: SSH, mrid: []const u8, property_name: []const u8) !?[]const u8 {
        const patch = self.find_patch(mrid) orelse return null;
        return self.getPropertyFromPatch(patch, property_name);
    }

    /// Convenience wrapper for single-reference lookups.
    /// For multiple references on the same object, use find_patch + getReferenceFromPatch.
    pub fn getReference(self: SSH, mrid: []const u8, reference_name: []const u8) !?[]const u8 {
        const patch = self.find_patch(mrid) orelse return null;
        return self.getReferenceFromPatch(patch, reference_name);
    }

    /// Return a CimObjectView over the SSH FullModel metadata element.
    /// Returns null if no FullModel is present in the SSH XML.
    pub fn getFullModelView(self: SSH) !?tag_index.CimObjectView {
        assert(self.boundaries.len > 0);
        assert(self.xml.len > 0);
        for (self.boundaries, 0..) |tag, tag_idx| {
            const type_name = tag_index.extract_tag_type(self.xml, tag.start) catch continue;
            if (!std.mem.eql(u8, type_name, "FullModel")) continue;
            const closing_idx = tag_index.find_closing_tag(self.xml, self.boundaries, @intCast(tag_idx)) catch continue;
            const id = tag_index.extract_rdf_about(self.xml, tag.start) catch continue;
            return .{
                .xml = self.xml,
                .boundaries = self.boundaries,
                .object_tag_idx = @intCast(tag_idx),
                .closing_tag_idx = closing_idx,
                .id = id,
                .type_name = "FullModel",
            };
        }
        return null;
    }

    /// Get a property from the SSH FullModel metadata element.
    /// Returns null if the FullModel is absent or the property is not found.
    pub fn getFullModelProperty(self: SSH, property_name: []const u8) !?[]const u8 {
        assert(property_name.len > 0);
        assert(self.boundaries.len > 0);
        const view = try self.getFullModelView() orelse return null;
        return view.getProperty(property_name);
    }
};

/// A merged view of an EQ object with optional TP and SSH overlays.
/// Priority for getProperty / getReference: SSH > TP > EQ — SSH shadows everything,
/// TP shadows EQ, EQ is the fallback. `init` runs one find_patch per overlay and
/// caches the result, so getProperty / getReference are free of repeated lookups.
pub const CimMergedView = struct {
    eq: tag_index.CimObjectView,
    tp: ?TpContext,
    ssh: ?SshContext,

    const SshContext = struct {
        xml: []const u8,
        boundaries: []const tag_index.TagBoundary,
        patch: SshPatch,
    };

    const TpContext = struct {
        xml: []const u8,
        boundaries: []const tag_index.TagBoundary,
        patch: TpPatch,
    };

    pub fn init(
        eq: tag_index.CimObjectView,
        mrid: []const u8,
        tp_opt: ?TP,
        ssh_opt: ?SSH,
    ) CimMergedView {
        assert(mrid.len > 0);
        var tp: ?TpContext = null;
        if (tp_opt) |t| {
            if (t.find_patch(mrid)) |patch| {
                tp = .{ .xml = t.xml, .boundaries = t.boundaries, .patch = patch };
            }
        }
        var ssh: ?SshContext = null;
        if (ssh_opt) |s| {
            if (s.find_patch(mrid)) |patch| {
                ssh = .{ .xml = s.xml, .boundaries = s.boundaries, .patch = patch };
            }
        }
        return .{ .eq = eq, .tp = tp, .ssh = ssh };
    }

    /// Get a text property. SSH value takes priority, then TP, then EQ.
    pub fn getProperty(self: CimMergedView, name: []const u8) !?[]const u8 {
        if (self.ssh) |s| {
            if (try tag_index.get_property_from_indices(
                s.xml,
                s.boundaries,
                s.patch.patch_tag_idx,
                s.patch.closing_tag_idx,
                name,
            )) |v| return v;
        }
        if (self.tp) |t| {
            if (try tag_index.get_property_from_indices(
                t.xml,
                t.boundaries,
                t.patch.patch_tag_idx,
                t.patch.closing_tag_idx,
                name,
            )) |v| return v;
        }
        return self.eq.getProperty(name);
    }

    /// Get an rdf:resource reference. SSH value takes priority, then TP, then EQ.
    pub fn getReference(self: CimMergedView, name: []const u8) !?[]const u8 {
        if (self.ssh) |s| {
            if (try tag_index.get_reference_from_indices(
                s.xml,
                s.boundaries,
                s.patch.patch_tag_idx,
                s.patch.closing_tag_idx,
                name,
            )) |v| return v;
        }
        if (self.tp) |t| {
            if (try tag_index.get_reference_from_indices(
                t.xml,
                t.boundaries,
                t.patch.patch_tag_idx,
                t.patch.closing_tag_idx,
                name,
            )) |v| return v;
        }
        return self.eq.getReference(name);
    }

    fn patch_view(ctx: anytype) tag_index.CimObjectView {
        return .{
            .xml = ctx.xml,
            .boundaries = ctx.boundaries,
            .object_tag_idx = ctx.patch.patch_tag_idx,
            .closing_tag_idx = ctx.patch.closing_tag_idx,
            .id = ctx.patch.mrid,
            .type_name = "",
        };
    }

    fn apply_overrides(result: anytype, values: anytype, comptime names: anytype) void {
        inline for (names, 0..) |_, idx| {
            if (values[idx]) |value| result[idx] = value;
        }
    }

    /// Batch-fetch text properties. SSH values take priority, then TP, then EQ.
    pub fn getProperties(self: CimMergedView, comptime names: anytype) ![names.len]?[]const u8 {
        var result = try self.eq.getProperties(names);
        if (self.tp) |t| apply_overrides(&result, try patch_view(t).getProperties(names), names);
        if (self.ssh) |s| apply_overrides(&result, try patch_view(s).getProperties(names), names);
        return result;
    }

    /// Batch-fetch rdf:resource references. SSH values take priority, then TP, then EQ.
    pub fn getReferences(self: CimMergedView, comptime names: anytype) ![names.len]?[]const u8 {
        var result = try self.eq.getReferences(names);
        if (self.tp) |t| apply_overrides(&result, try patch_view(t).getReferences(names), names);
        if (self.ssh) |s| apply_overrides(&result, try patch_view(s).getReferences(names), names);
        return result;
    }

    /// Return the union of EQ + TP + SSH properties, with SSH > TP > EQ precedence.
    /// Caller owns the returned map; values borrow from the underlying XML buffers.
    pub fn getAllProperties(self: CimMergedView, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var result = try self.eq.getAllProperties(gpa);
        errdefer result.deinit();
        if (self.tp) |t| try overlay_into(&result, patch_view(t).getAllProperties(gpa));
        if (self.ssh) |s| try overlay_into(&result, patch_view(s).getAllProperties(gpa));
        return result;
    }

    /// Return the union of EQ + TP + SSH references, with SSH > TP > EQ precedence.
    /// Caller owns the returned map; values borrow from the underlying XML buffers.
    pub fn getAllReferences(self: CimMergedView, gpa: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var result = try self.eq.getAllReferences(gpa);
        errdefer result.deinit();
        if (self.tp) |t| try overlay_into(&result, patch_view(t).getAllReferences(gpa));
        if (self.ssh) |s| try overlay_into(&result, patch_view(s).getAllReferences(gpa));
        return result;
    }

    fn overlay_into(
        dest: *std.StringHashMap([]const u8),
        patch_map_result: anytype,
    ) !void {
        var patch_map = try patch_map_result;
        defer patch_map.deinit();
        var it = patch_map.iterator();
        while (it.next()) |entry| try dest.put(entry.key_ptr.*, entry.value_ptr.*);
    }
};

/// Returns the stripped mRID if this tag is an SSH equipment patch, null otherwise.
/// Accepts rdf:ID="_mrid" → "mrid" and rdf:about="#_mrid" → "mrid".
/// Rejects metadata (urn: URIs, FullModel, etc.).
fn extract_patch_mrid(xml: []const u8, tag_start: u32) ?[]const u8 {
    if (tag_index.extract_rdf_id(xml, tag_start)) |raw| {
        if (raw.len > 0 and raw[0] == '_') return utils.strip_underscore(raw);
    } else |_| {}

    if (tag_index.extract_rdf_about(xml, tag_start)) |raw| {
        if (raw.len > 1 and raw[0] == '#' and raw[1] == '_')
            return utils.strip_underscore(utils.strip_hash(raw));
    } else |_| {}

    return null;
}

fn patch_less_than(_: void, a: SshPatch, b: SshPatch) bool {
    return std.mem.order(u8, a.mrid, b.mrid) == .lt;
}

test "SSH.getFullModelView - returns view with correct id and type_name" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:view-test-1">
        \\    <md:Model.scenarioTime>2024-06-01T00:00:00Z</md:Model.scenarioTime>
        \\  </md:FullModel>
        \\  <cim:Switch rdf:ID="_sw1">
        \\    <cim:Switch.open>false</cim:Switch.open>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    var ssh = try SSH.init(gpa, try gpa.dupe(u8, xml));
    defer ssh.deinit(gpa);

    const view = try ssh.getFullModelView();
    try std.testing.expect(view != null);
    try std.testing.expectEqualStrings("urn:uuid:view-test-1", view.?.id);
    try std.testing.expectEqualStrings("FullModel", view.?.type_name);
    // Verify child properties are reachable through the view.
    const st = try view.?.getProperty("Model.scenarioTime");
    try std.testing.expect(st != null);
    try std.testing.expectEqualStrings(
        "2024-06-01T00:00:00Z",
        std.mem.trim(u8, st.?, " \t\r\n"),
    );
}

test "SSH.getFullModelView - returns null when no FullModel present" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:ID="_sw1">
        \\    <cim:Switch.open>true</cim:Switch.open>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    var ssh = try SSH.init(gpa, try gpa.dupe(u8, xml));
    defer ssh.deinit(gpa);

    const view = try ssh.getFullModelView();
    try std.testing.expectEqual(@as(?tag_index.CimObjectView, null), view);
}

test "SSH.getFullModelProperty - returns scenarioTime from SSH FullModel" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:ssh-model-1">
        \\    <md:Model.scenarioTime>2023-01-01T12:00:00Z</md:Model.scenarioTime>
        \\    <md:Model.created>2023-01-01T10:00:00Z</md:Model.created>
        \\  </md:FullModel>
        \\  <cim:Switch rdf:ID="_sw1">
        \\    <cim:Switch.open>false</cim:Switch.open>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    var ssh = try SSH.init(gpa, try gpa.dupe(u8, xml));
    defer ssh.deinit(gpa);

    const scenario_time = try ssh.getFullModelProperty("Model.scenarioTime");
    try std.testing.expect(scenario_time != null);
    try std.testing.expectEqualStrings("2023-01-01T12:00:00Z", std.mem.trim(u8, scenario_time.?, " \t\r\n"));

    const created = try ssh.getFullModelProperty("Model.created");
    try std.testing.expect(created != null);
    try std.testing.expectEqualStrings("2023-01-01T10:00:00Z", std.mem.trim(u8, created.?, " \t\r\n"));
}

test "SSH.getFullModelProperty - returns null when property absent" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:ssh-model-2">
        \\    <md:Model.created>2023-06-15T08:00:00Z</md:Model.created>
        \\  </md:FullModel>
        \\</rdf:RDF>
    ;
    var ssh = try SSH.init(gpa, try gpa.dupe(u8, xml));
    defer ssh.deinit(gpa);

    const result = try ssh.getFullModelProperty("Model.scenarioTime");
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "SSH.getFullModelProperty - returns null when no FullModel present" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:ID="_sw1">
        \\    <cim:Switch.open>true</cim:Switch.open>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    var ssh = try SSH.init(gpa, try gpa.dupe(u8, xml));
    defer ssh.deinit(gpa);

    const result = try ssh.getFullModelProperty("Model.scenarioTime");
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "SSH.init - rejects duplicate patch mRIDs" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:ID="_SW1"/>
        \\  <cim:Switch rdf:about="#_SW1"/>
        \\</rdf:RDF>
    ;

    try std.testing.expectError(error.DuplicateId, SSH.init(gpa, try gpa.dupe(u8, xml)));
}

const EQ = @import("eq.zig").EQ;

test "CimMergedView.getAllProperties merges EQ + TP + SSH with SSH precedence" {
    const gpa = std.testing.allocator;
    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:ID="_SW1">
        \\    <cim:IdentifiedObject.name>eq-name</cim:IdentifiedObject.name>
        \\    <cim:Switch.normalOpen>false</cim:Switch.normalOpen>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:about="#_SW1">
        \\    <cim:Switch.normalOpen>true</cim:Switch.normalOpen>
        \\    <cim:Switch.retained>false</cim:Switch.retained>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    const ssh_xml =
        \\<rdf:RDF>
        \\  <cim:Switch rdf:about="#_SW1">
        \\    <cim:Switch.open>true</cim:Switch.open>
        \\    <cim:Switch.retained>true</cim:Switch.retained>
        \\  </cim:Switch>
        \\</rdf:RDF>
    ;
    var eq = try EQ.init(gpa, try gpa.dupe(u8, eq_xml));
    defer eq.deinit(gpa);
    var tp = try TP.init(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);
    var ssh = try SSH.init(gpa, try gpa.dupe(u8, ssh_xml));
    defer ssh.deinit(gpa);

    const view = eq.getObjectById("_SW1").?;
    const merged = CimMergedView.init(view, "SW1", tp, ssh);

    var props = try merged.getAllProperties(gpa);
    defer props.deinit();

    // EQ-only key preserved.
    try std.testing.expectEqualStrings("eq-name", props.get("IdentifiedObject.name").?);
    // TP overrides EQ.
    try std.testing.expectEqualStrings("true", props.get("Switch.normalOpen").?);
    // SSH overrides TP (Switch.retained).
    try std.testing.expectEqualStrings("true", props.get("Switch.retained").?);
    // SSH-only key included.
    try std.testing.expectEqualStrings("true", props.get("Switch.open").?);
}

test "CimMergedView.getAllReferences merges EQ + TP with TP precedence" {
    const gpa = std.testing.allocator;
    const eq_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:ID="_T1">
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_CE_eq"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    const tp_xml =
        \\<rdf:RDF>
        \\  <cim:Terminal rdf:about="#_T1">
        \\    <cim:Terminal.TopologicalNode rdf:resource="#_TN1"/>
        \\    <cim:Terminal.ConductingEquipment rdf:resource="#_CE_tp"/>
        \\  </cim:Terminal>
        \\</rdf:RDF>
    ;
    var eq = try EQ.init(gpa, try gpa.dupe(u8, eq_xml));
    defer eq.deinit(gpa);
    var tp = try TP.init(gpa, try gpa.dupe(u8, tp_xml));
    defer tp.deinit(gpa);

    const view = eq.getObjectById("_T1").?;
    const merged = CimMergedView.init(view, "T1", tp, null);

    var refs = try merged.getAllReferences(gpa);
    defer refs.deinit();

    // TP-added reference visible.
    try std.testing.expectEqualStrings("#_TN1", refs.get("Terminal.TopologicalNode").?);
    // TP overrides the EQ value.
    try std.testing.expectEqualStrings("#_CE_tp", refs.get("Terminal.ConductingEquipment").?);
}
