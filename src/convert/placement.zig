const std = @import("std");
const iidm = @import("../iidm/model.zig");
const cim_index = @import("../topology/cross_ref.zig");
const cim_model = @import("../cgmes/eq.zig");
const utils = @import("../cgmes/ids.zig");
const bus_conv = @import("bus.zig");
const TP = @import("../cgmes/tp.zig").TP;
const topology_mod = @import("../topology/resolve.zig");

const strip_underscore = utils.strip_underscore;
const strip_hash = utils.strip_hash;

const assert = std.debug.assert;
const CimIndex = cim_index.CimIndex;
const Topology = topology_mod.Topology;

pub const Placement = struct {
    /// Raw rdf:ID of the containing VoltageLevel (merge-resolved in node-breaker,
    /// direct container in bus-branch). Matches voltage_level_map / substation_map keys.
    repr_voltage_level_id: []const u8,
    voltage_level: *iidm.VoltageLevel,
    /// Node number in node-breaker; 0 in bus-branch (ignored when bus is set).
    node: u32,
    /// Bus mRID in bus-branch; null in node-breaker. When set, IIDM serializer
    /// emits bus/connectableBus instead of node.
    bus: ?[]const u8 = null,
};

/// Resolve VoltageLevel and node for a terminal.
/// Looks up the terminal's CN to find the VL, and the terminal ID to find the node.
/// Returns null if the CN has no container, no matching VL, or no node assignment.
/// Boundary CN endpoints (container = ACLineSegment, not in voltage_level_map) return null.
pub fn resolve_terminal_placement(
    terminal_id: []const u8,
    conn_node_id: []const u8,
    index: *const CimIndex,
    topology: *const Topology,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const topology_mod.NodeMap,
) ?Placement {
    assert(terminal_id.len > 0);
    assert(conn_node_id.len > 0);
    const container_id = index.conn_node_container.get(conn_node_id) orelse return null;
    const repr_voltage_level_id = topology_mod.find_root(&topology.voltage_level_merge, container_id);
    const voltage_level = voltage_level_map.get(repr_voltage_level_id) orelse return null;
    const node = node_map.get(terminal_id) orelse return null;
    return .{ .repr_voltage_level_id = repr_voltage_level_id, .voltage_level = voltage_level, .node = node };
}

/// Unified placement resolver for equipment terminals.
/// node-breaker mode: resolves via EQ CN → VL + NodeMap-assigned node.
/// bus-branch mode: resolves via TP Terminal.TopologicalNode patch → BusPlacement.
pub const TerminalPlacer = struct {
    mode: Mode,
    index: *const CimIndex,
    topology: *const Topology,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),

    pub const Mode = union(enum) {
        node_breaker: *const topology_mod.NodeMap,
        bus_branch: BusBranch,
    };

    pub const BusBranch = struct {
        tp: TP,
        bus_map: *const bus_conv.BusMap,
    };

    pub fn resolve_terminal(self: TerminalPlacer, terminal_id: []const u8, conn_node_id: ?[]const u8) !?Placement {
        assert(terminal_id.len > 0);
        switch (self.mode) {
            .node_breaker => |node_map| {
                const cn = conn_node_id orelse return null;
                return resolve_terminal_placement(terminal_id, cn, self.index, self.topology, self.voltage_level_map, node_map);
            },
            .bus_branch => |bb| {
                const terminal_mrid = strip_underscore(terminal_id);
                const bp = try bus_conv.resolve_terminal_bus(bb.tp, bb.bus_map, terminal_mrid) orelse return null;
                return Placement{
                    .repr_voltage_level_id = bp.raw_voltage_level_id,
                    .voltage_level = bp.voltage_level,
                    .node = 0,
                    .bus = bp.bus_id,
                };
            },
        }
    }

    pub fn resolve_equipment(self: TerminalPlacer, equipment_id: []const u8) !?Placement {
        assert(equipment_id.len > 0);
        const terminals = self.index.equipment_terminals.get(equipment_id) orelse return null;
        if (terminals.items.len == 0) return null;
        const term = terminals.items[0];
        return self.resolve_terminal(term.id, term.conn_node_id);
    }
};

/// Build OperationalLimitsGroup list for one terminal from the CimIndex.
/// Caller owns the returned list and must deinit it.
/// Group properties format matches PyPowSyBl's CGMES extension:
///   CGMES.normalValue_CurrentLimit_patl, CGMES.OperationalLimitSetName,
///   CGMES.OperationalLimitSetRdfID, CGMES.OperationalLimit_CurrentLimit_patl.
pub fn build_op_lims(
    gpa: std.mem.Allocator,
    model: *const cim_model.CimModel,
    index: *const CimIndex,
    terminal_id: []const u8,
) !std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) {
    assert(terminal_id.len > 0);
    var groups: std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) = .empty;

    const limit_sets = index.terminal_limit_sets.get(terminal_id) orelse return groups;
    try groups.ensureTotalCapacity(gpa, limit_sets.items.len);

    for (limit_sets.items) |set| {
        const set_view = model.view(set);
        const set_mrid = try set_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(set.id);
        const set_name = try set_view.getProperty("IdentifiedObject.name") orelse set_mrid;

        var patl_value_str: ?[]const u8 = null;
        var patl_cl_mrid: ?[]const u8 = null;

        if (index.current_limits_by_set.get(set.id)) |current_limits| {
            for (current_limits.items) |current_limit| {
                const current_limit_view = model.view(current_limit);
                const type_ref = try current_limit_view.getReference("OperationalLimit.OperationalLimitType") orelse continue;
                const type_id = strip_hash(type_ref);
                const type_info = index.limit_types.get(type_id) orelse continue;
                if (!type_info.is_infinite) continue; // skip TATLs for now (none in dataset)

                patl_value_str = try current_limit_view.getProperty("CurrentLimit.value") orelse
                    try current_limit_view.getProperty("CurrentLimit.normalValue");
                patl_cl_mrid = try current_limit_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(current_limit.id);
            }
        }

        var props: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer props.deinit(gpa);
        try props.ensureTotalCapacity(gpa, 4);
        if (patl_value_str) |pv| {
            const formatted_pv = try iidm.format_float_str(gpa, std.mem.trim(u8, pv, " \t\r\n"));
            props.appendAssumeCapacity(.{ .name = "CGMES.normalValue_CurrentLimit_patl", .value = formatted_pv, .owned_value = true });
        }
        props.appendAssumeCapacity(.{ .name = "CGMES.OperationalLimitSetName", .value = set_name });
        props.appendAssumeCapacity(.{ .name = "CGMES.OperationalLimitSetRdfID", .value = set_mrid });
        if (patl_cl_mrid) |pm| props.appendAssumeCapacity(.{ .name = "CGMES.OperationalLimit_CurrentLimit_patl", .value = pm });

        const current_limits: ?iidm.CurrentLimits = if (patl_value_str) |pv| blk: {
            const value = std.fmt.parseFloat(f64, std.mem.trim(u8, pv, " \t\r\n")) catch break :blk null;
            break :blk .{ .permanent_limit = value };
        } else null;

        groups.appendAssumeCapacity(.{
            .id = set_mrid,
            .properties = props,
            .current_limits = current_limits,
        });
        props = .empty; // ownership transferred
    }

    return groups;
}
