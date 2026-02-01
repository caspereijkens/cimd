const std = @import("std");
const assert = std.debug.assert;
const cim_model = @import("cim_model.zig");
const CimModel = cim_model.CimModel;

pub const TerminalInfo = struct {
    id: []const u8,
    sequence: u32,
    node_id: ?[]const u8,
};

pub const TopologyStats = struct {
    terminal_count: usize,
    equipment_count: usize,
    connected_terminals: usize,
    connected_nodes: usize,
};

/// All CIM ConductingEquipment subtypes that can be referenced by Terminal.ConductingEquipment
const conducting_equipment_types = [_][]const u8{
    // Loads
    "EnergyConsumer",
    "ConformLoad",
    "NonConformLoad",
    "StationSupply",
    // Generators
    "SynchronousMachine",
    "AsynchronousMachine",
    // Lines and cables
    "ACLineSegment",
    "DCLineSegment",
    // Transformers
    "PowerTransformer",
    // Switches
    "Breaker",
    "Disconnector",
    "LoadBreakSwitch",
    "Switch",
    "ProtectedSwitch",
    "GroundDisconnector",
    "Jumper",
    "Fuse",
    "Cut",
    "Ground",
    // Compensators
    "SeriesCompensator",
    "LinearShuntCompensator",
    "NonlinearShuntCompensator",
    "StaticVarCompensator",
    // Equivalents
    "EquivalentInjection",
    "EquivalentBranch",
    "EquivalentShunt",
    // Other
    "ExternalNetworkInjection",
    "EnergySource",
    "BusbarSection",
    "PetersenCoil",
    "GroundingImpedance",
    // HVDC converters
    "CsConverter",
    "VsConverter",
};

pub const TopologyResolver = struct {
    gpa: std.mem.Allocator,
    equipment_model: *const CimModel,
    terminal_to_equipment: std.StringHashMap([]const u8),
    terminal_to_node: std.StringHashMap([]const u8),
    connected_node_ids: std.StringHashMap(void),
    equipment_terminals: std.StringHashMap(std.ArrayList(TerminalInfo)),

    pub fn init(
        gpa: std.mem.Allocator,
        equipment_model: *const CimModel,
    ) !TopologyResolver {
        var terminal_to_equipment = std.StringHashMap([]const u8).init(gpa);
        errdefer terminal_to_equipment.deinit();

        var terminal_to_node = std.StringHashMap([]const u8).init(gpa);
        errdefer terminal_to_node.deinit();

        var connected_node_ids = std.StringHashMap(void).init(gpa);
        errdefer connected_node_ids.deinit();

        var equipment_terminals = std.StringHashMap(std.ArrayList(TerminalInfo)).init(gpa);
        errdefer {
            var it = equipment_terminals.valueIterator();
            while (it.next()) |list| list.deinit(gpa);
            equipment_terminals.deinit();
        }
        var resolver = TopologyResolver{
            .gpa = gpa,
            .equipment_model = equipment_model,
            .terminal_to_equipment = terminal_to_equipment,
            .terminal_to_node = terminal_to_node,
            .connected_node_ids = connected_node_ids,
            .equipment_terminals = equipment_terminals,
        };

        errdefer resolver.deinit();

        var valid_equipment_ids = std.StringHashMap(void).init(gpa);
        defer valid_equipment_ids.deinit();
        for (conducting_equipment_types) |eq_type| {
            const equipment = try equipment_model.getObjectsByType(gpa, eq_type);
            defer gpa.free(equipment);
            for (equipment) |eq| {
                try valid_equipment_ids.put(eq.id, {});
            }
        }

        const eq_terminals = try equipment_model.getObjectsByType(gpa, "Terminal");
        defer gpa.free(eq_terminals);

        // Build valid ConnectivityNode ID set - O(c) where c = connectivity nodes
        const connectivity_nodes = try equipment_model.getObjectsByType(gpa, "ConnectivityNode");
        defer gpa.free(connectivity_nodes);

        var valid_cn_ids = std.StringHashMap(void).init(gpa);
        defer valid_cn_ids.deinit();
        for (connectivity_nodes) |cn| {
            try valid_cn_ids.put(cn.id, {});
        }
        // Code:
        //   const num_terminals = eq_terminals.len;
        //   try resolver.terminal_to_equipment.ensureTotalCapacity(num_terminals);
        //   try resolver.terminal_to_node.ensureTotalCapacity(num_terminals);
        //   try resolver.equipment_terminals.ensureTotalCapacity(num_terminals / 2);

        for (eq_terminals) |terminal| {
            const equipment_ref = try terminal.getReference("Terminal.ConductingEquipment") orelse
                return error.MissingConductingEquipmentReference;
            const equipment_id = stripHash(equipment_ref);

            if (valid_equipment_ids.get(equipment_id) == null) {
                return error.DanglingConductingEquipmentReference;
            }

            try resolver.terminal_to_equipment.put(terminal.id, equipment_id);
            const sequence_number_str = try terminal.getProperty("ACDCTerminal.sequenceNumber") orelse "1";
            const sequence_number = std.fmt.parseInt(u32, sequence_number_str, 10) catch 1;
            const result = try resolver.equipment_terminals.getOrPut(equipment_id);

            if (!result.found_existing) {
                // First object of this type - create new ArrayList
                result.value_ptr.* = .empty;
            }

            var node_id: ?[]const u8 = null;
            if (try terminal.getReference("Terminal.ConnectivityNode")) |node_ref| {
                node_id = stripHash(node_ref);
                if (valid_cn_ids.get(node_id.?) == null) {
                    return error.DanglingConnectivityNodeReference;
                }
                try resolver.terminal_to_node.put(terminal.id, node_id.?);
                try resolver.connected_node_ids.put(node_id.?, {});
            }

            try result.value_ptr.append(gpa, TerminalInfo{
                .id = terminal.id,
                .sequence = sequence_number,
                .node_id = node_id,
            });
        }

        return resolver;
    }

    /// Get node ID for equipment terminal
    pub fn getEquipmentNode(
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
        self.connected_node_ids.deinit();
    }

    /// Get all terminals for an equipment_id.
    pub fn getEquipmentTerminals(
        self: TopologyResolver,
        equipment_id: []const u8,
    ) ?[]const TerminalInfo {
        const terminals = self.equipment_terminals.get(equipment_id) orelse return null;
        return terminals.items;
    }

    /// Get terminal count, equipment count and other statistics of a processed model.
    pub fn getStats(self: TopologyResolver) TopologyStats {
        return .{
            .terminal_count = self.terminal_to_equipment.count(),
            .equipment_count = self.equipment_terminals.count(),
            .connected_terminals = self.terminal_to_node.count(),
            .connected_nodes = self.connected_node_ids.count(),
        };
    }
};

/// Helper function to strip leading '#' from rdf:resource references
pub fn stripHash(ref: []const u8) []const u8 {
    assert(ref.len > 0);

    if (ref[0] != '#') return ref;

    return ref[1..];
}

/// Helper function to strip leading '_' from rdf:ID
pub fn stripUnderscore(ref: []const u8) []const u8 {
    assert(ref.len > 0);

    if (ref[0] != '_') return ref;

    return ref[1..];
}

/// Decode URL-encoded string (converts '+' to space)
pub fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // Check if decoding is needed
    var needs_decode = false;
    for (input) |c| {
        if (c == '+') {
            needs_decode = true;
            break;
        }
    }
    if (!needs_decode) return input;

    // Allocate and decode
    const result = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| {
        result[i] = if (c == '+') ' ' else c;
    }
    return result;
}
