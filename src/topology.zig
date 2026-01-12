const std = @import("std");
const assert = std.debug.assert;
const cim_model = @import("cim_model.zig");
const CimModel = cim_model.CimModel;

pub const TopologyMode = enum {
    no_topology,
    bus_breaker,
};

pub const TerminalInfo = struct {
    id: []const u8,
    sequence: u32,
    node_id: ?[]const u8,
};

pub const TopologyResolver = struct {
    gpa: std.mem.Allocator,
    equipment_model: *const CimModel,
    topology_model: ?*const CimModel,
    terminal_to_equipment: std.StringHashMap([]const u8),
    terminal_to_node: std.StringHashMap([]const u8),
    equipment_terminals: std.StringHashMap(std.ArrayList(TerminalInfo)),
    mode: TopologyMode,

    pub fn init(
        gpa: std.mem.Allocator,
        equipment_model: *const CimModel,
        topology_model: ?*const CimModel,
    ) !TopologyResolver {
        var terminal_to_equipment = std.StringHashMap([]const u8).init(gpa);
        errdefer terminal_to_equipment.deinit();

        var terminal_to_node = std.StringHashMap([]const u8).init(gpa);
        errdefer terminal_to_node.deinit();

        var equipment_terminals = std.StringHashMap(std.ArrayList(TerminalInfo)).init(gpa);
        errdefer {
            var it = equipment_terminals.valueIterator();
            while (it.next()) |list| list.deinit(gpa);
            equipment_terminals.deinit();
        }
        var resolver = TopologyResolver{
            .gpa = gpa,
            .equipment_model = equipment_model,
            .topology_model = topology_model,
            .terminal_to_equipment = terminal_to_equipment,
            .terminal_to_node = terminal_to_node,
            .equipment_terminals = equipment_terminals,
            .mode = .no_topology,
        };

        errdefer resolver.deinit();

        const eq_terminals = try equipment_model.getObjectsByType(gpa, "Terminal");
        defer gpa.free(eq_terminals);

        // PERF: Pre-allocate HashMaps if init time becomes a bottleneck.
        // Code:
        //   const num_terminals = eq_terminals.len;
        //   try resolver.terminal_to_equipment.ensureTotalCapacity(num_terminals);
        //   try resolver.terminal_to_node.ensureTotalCapacity(num_terminals);
        //   try resolver.equipment_terminals.ensureTotalCapacity(num_terminals / 2);

        for (eq_terminals) |terminal| {
            const equipment_ref = try terminal.getReference("Terminal.ConductingEquipment");
            if (equipment_ref == null) return error.MissingConductingEquipmentReference;
            const equipment_id = stripHash(equipment_ref.?);
            try resolver.terminal_to_equipment.put(terminal.id, equipment_id);
            const sequence_number_str = try terminal.getProperty("ACDCTerminal.sequenceNumber") orelse "1";
            const sequence_number = std.fmt.parseInt(u32, sequence_number_str, 10) catch 1;
            const result = try resolver.equipment_terminals.getOrPut(equipment_id);

            if (!result.found_existing) {
                // First object of this type - create new ArrayList
                result.value_ptr.* = .empty;
            }
            try result.value_ptr.append(gpa, TerminalInfo{ .id = terminal.id, .sequence = sequence_number, .node_id = null });
        }

        if (topology_model) |tp_model| {
            const topological_nodes = try tp_model.getObjectsByType(gpa, "TopologicalNode");
            defer gpa.free(topological_nodes);

            if (topological_nodes.len > 0) {
                resolver.mode = .bus_breaker;
            }

            const tp_terminals = try tp_model.getObjectsByType(gpa, "Terminal");
            defer gpa.free(tp_terminals);

            for (tp_terminals) |terminal| {
                const node_ref = try terminal.getReference("Terminal.TopologicalNode") orelse continue;

                const node_id = stripHash(node_ref);

                try resolver.terminal_to_node.put(terminal.id, node_id);
                const equipment_id = resolver.terminal_to_equipment.get(terminal.id) orelse continue;
                const terminal_infos = resolver.equipment_terminals.get(equipment_id) orelse continue;
                for (terminal_infos.items) |*terminal_info| blk: {
                    if (std.mem.eql(u8, terminal_info.id, terminal.id)) {
                        terminal_info.node_id = node_id;
                        break :blk;
                    }
                }
            }
        }

        return resolver;
    }

    /// Get bus ID for equipment terminal (primary API for Stage 5)
    pub fn getEquipmentBus(
        self: TopologyResolver,
        equipment_id: []const u8,
        terminal_sequence: u32,
    ) ?[]const u8 {
        const terminals = self.getEquipmentTerminals(equipment_id) orelse return null;
        for (terminals) |terminal| {
            if (terminal.sequence == terminal_sequence) {
                return terminal.node_id;
            }
        }

        return null;
    }

    pub fn deinit(self: *TopologyResolver) void {
        var it = self.equipment_terminals.valueIterator();
        while (it.next()) |list| {
            list.deinit(self.gpa);
        }

        self.terminal_to_equipment.deinit();
        self.terminal_to_node.deinit();
        self.equipment_terminals.deinit();
    }

    /// Get all terminals for an equipment_id.
    pub fn getEquipmentTerminals(
        self: TopologyResolver,
        equipment_id: []const u8,
    ) ?[]const TerminalInfo {
        const terminals = self.equipment_terminals.get(equipment_id) orelse return null;
        return terminals.items;
    }
};

/// Helper function to strip leading '#' from rdf:resource references
fn stripHash(ref: []const u8) []const u8 {
    assert(ref.len > 0);

    if (ref[0] != '#') return ref;

    return ref[1..];
}
