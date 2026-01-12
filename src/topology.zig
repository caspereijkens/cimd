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

        // STEP 3: Process topology model (if provided)
        // For now, just skip this - we'll add it in the next test
        // Use if (topology_model) |tp_model| { ... } to handle optional

        return resolver;
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
