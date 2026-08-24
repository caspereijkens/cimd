const std = @import("std");
const cim = @import("../cim/cim.zig");
const iidm = @import("../iidm/model.zig");
const cross_ref = @import("../topology/cross_ref.zig");
const CimDocument = cim.CimDocument;

const utils = cim.ids;
const bus_conv = @import("bus.zig");
const Overlay = cim.Overlay;
const resolve = @import("../topology/resolve.zig");
const parse = cim.parse;

const strip_underscore = utils.strip_underscore;
const strip_hash = utils.strip_hash;

const assert = std.debug.assert;
const CrossRef = cross_ref.CrossRef;
const Topology = resolve.Topology;

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

/// Equipment raw ID → its resolved Placement. `pre_allocate_equipment` already
/// resolves every load/shunt/SVC/generator/busbar to count per-VoltageLevel
/// capacity; it records those resolutions here so the matching convert pass can
/// look them up (one hashmap probe) instead of re-running the full CN → VL →
/// node resolution a second time. resolve is a pure function of immutable
/// indices, so a cache hit is byte-identical to recomputing.
pub const PlacementCache = std.StringHashMapUnmanaged(Placement);

/// Resolve VoltageLevel and node for a terminal.
/// Looks up the terminal's CN to find the VL, and the terminal ID to find the node.
/// Returns null if the CN has no container, no matching VL, or no node assignment.
/// Boundary CN endpoints (container = ACLineSegment, not in voltage_level_map) return null.
pub fn resolve_terminal_placement(
    terminal_ordinal: u32,
    conn_node_id: []const u8,
    index: *const CrossRef,
    topology: *const Topology,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const resolve.NodeMap,
) ?Placement {
    assert(conn_node_id.len > 0);
    const container_id = index.conn_node_container.get(conn_node_id) orelse return null;
    const repr_voltage_level_id = resolve.find_root(&topology.voltage_level_merge, container_id);
    const voltage_level = voltage_level_map.get(repr_voltage_level_id) orelse return null;
    const node = node_map.get(terminal_ordinal) orelse return null;
    return .{ .repr_voltage_level_id = repr_voltage_level_id, .voltage_level = voltage_level, .node = node };
}

/// Unified placement resolver for equipment terminals.
/// node-breaker mode: resolves via EQ CN → VL + NodeMap-assigned node.
/// bus-branch mode: resolves via TP Terminal.TopologicalNode patch → BusPlacement.
pub const TerminalPlacer = struct {
    mode: Mode,
    index: *const CrossRef,
    topology: *const Topology,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    /// Optional memoized equipment-placement lookups (see PlacementCache).
    /// When set, resolve_equipment returns the cached placement; when null it
    /// computes from scratch. pre_allocate_equipment runs with a null cache (it
    /// is the one building it); the convert pass runs with it populated.
    placement_cache: ?*const PlacementCache = null,

    pub const Mode = union(enum) {
        node_breaker: *const resolve.NodeMap,
        bus_branch: BusBranch,
    };

    pub const BusBranch = struct {
        tp: Overlay,
        bus_map: *const bus_conv.BusMap,
    };

    /// `terminal_ordinal` is null only where `conn_node_id` is too -- both come
    /// from the same `TerminalInfo` or the same `terminal_conn_node` entry -- so
    /// node-breaker's early return on a missing ordinal is the null the
    /// `node_map` miss used to produce.
    pub fn resolve_terminal(
        self: TerminalPlacer,
        terminal_id: []const u8,
        conn_node_id: ?[]const u8,
        terminal_ordinal: ?u32,
    ) !?Placement {
        assert(terminal_id.len > 0);
        switch (self.mode) {
            .node_breaker => |node_map| {
                const cn = conn_node_id orelse return null;
                const ordinal = terminal_ordinal orelse return null;
                return resolve_terminal_placement(ordinal, cn, self.index, self.topology, self.voltage_level_map, node_map);
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
        // A populated cache holds every placeable equipment of the types that
        // pre_allocate_equipment resolved; a miss means unplaceable (the same
        // null the compute path returns), so callers' `orelse continue` is
        // unchanged.
        if (self.placement_cache) |cache| return cache.get(equipment_id);
        const terminals = self.index.equipment_terminals.get(equipment_id) orelse return null;
        if (terminals.items.len == 0) return null;
        const term = terminals.items[0];
        return self.resolve_terminal(term.id, term.conn_node_id, term.ordinal);
    }
};

/// Build OperationalLimitsGroup list for one terminal from the CrossRef.
/// Caller owns the returned list and must deinit it.
/// Group properties format matches PyPowSyBl's CGMES extension:
///   CGMES.normalValue_CurrentLimit_patl, CGMES.OperationalLimitSetName,
///   CGMES.OperationalLimitSetRdfID, CGMES.OperationalLimit_CurrentLimit_patl.
pub fn build_op_lims(
    gpa: std.mem.Allocator,
    index: *const CrossRef,
    terminal_id: []const u8,
) !std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) {
    assert(terminal_id.len > 0);
    var groups: std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) = .empty;
    errdefer {
        for (groups.items) |*group| group.deinit(gpa);
        groups.deinit(gpa);
    }

    const limit_sets = index.terminal_limit_sets.get(terminal_id) orelse return groups;
    try groups.ensureTotalCapacity(gpa, limit_sets.items.len);

    for (limit_sets.items) |set| {
        const set_mrid = try set.mrid();
        const set_name = parse.non_blank(set.property("IdentifiedObject.name")) orelse set_mrid;

        var patl_value: ?f64 = null;
        var patl_cl_mrid: ?[]const u8 = null;

        if (index.current_limits_by_set.get(set.id())) |current_limits| {
            for (current_limits.items) |current_limit| {
                const type_ref = try current_limit.reference("OperationalLimit.OperationalLimitType") orelse continue;
                const type_id = strip_hash(type_ref);
                const type_info = index.limit_types.get(type_id) orelse continue;
                if (!type_info.is_infinite) continue; // skip TATLs for now (none in dataset)

                const value_str = parse.non_blank(current_limit.property("CurrentLimit.value")) orelse
                    parse.non_blank(current_limit.property("CurrentLimit.normalValue")) orelse continue;
                patl_value = try parse.float_req(value_str);
                patl_cl_mrid = try current_limit.mrid();
                break;
            }
        }

        var props: std.ArrayListUnmanaged(iidm.Property) = .empty;
        errdefer props.deinit(gpa);
        try props.ensureTotalCapacity(gpa, 4);
        if (patl_value) |value| {
            const formatted_pv = try iidm.format_float(gpa, value);
            props.appendAssumeCapacity(.{ .name = "CGMES.normalValue_CurrentLimit_patl", .value = formatted_pv, .owned_value = true });
        }
        props.appendAssumeCapacity(.{ .name = "CGMES.OperationalLimitSetName", .value = set_name });
        props.appendAssumeCapacity(.{ .name = "CGMES.OperationalLimitSetRdfID", .value = set_mrid });
        if (patl_cl_mrid) |pm| props.appendAssumeCapacity(.{ .name = "CGMES.OperationalLimit_CurrentLimit_patl", .value = pm });

        const current_limits: ?iidm.CurrentLimits = if (patl_value) |value|
            .{ .permanent_limit = value }
        else
            null;

        groups.appendAssumeCapacity(.{
            .id = set_mrid,
            .properties = props,
            .current_limits = current_limits,
        });
        props = .empty; // ownership transferred
    }

    return groups;
}
