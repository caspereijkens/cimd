const std = @import("std");
const cim_model = @import("cim_model.zig");
const topology = @import("topology.zig");
const iidm = @import("iidm.zig");

const CimModel = cim_model.CimModel;
const TopologyResolver = topology.TopologyResolver;
const SwitchKind = iidm.SwitchKind;

const switch_type_mapping = [_]struct { cim_type: []const u8, kind: SwitchKind }{
    .{ .cim_type = "Breaker", .kind = .breaker },
    .{ .cim_type = "Disconnector", .kind = .disconnector },
    .{ .cim_type = "LoadBreakSwitch", .kind = .load_break_switch },
};

pub const Converter = struct {
    gpa: std.mem.Allocator,
    model: *const CimModel,
    topology_resolver: *const TopologyResolver,

    substation_map: std.StringHashMapUnmanaged(usize),
    voltage_level_map: std.StringHashMapUnmanaged(VoltageLevelRef),

    const VoltageLevelRef = struct { substation_idx: usize, voltage_level_idx: usize };

    pub fn init(gpa: std.mem.Allocator, model: *const CimModel, topology_resolver: *const TopologyResolver) Converter {
        return .{
            .gpa = gpa,
            .model = model,
            .topology_resolver = topology_resolver,
            .substation_map = .empty,
            .voltage_level_map = .empty,
        };
    }

    pub fn deinit(self: *Converter) void {
        self.substation_map.deinit(self.gpa);
        self.voltage_level_map.deinit(self.gpa);
    }

    pub fn convert(self: *Converter) !iidm.Network {
        var network: iidm.Network = .{
            .id = "network",
            .case_date = null,
            .substations = .empty,
            .lines = .empty,
        };
        errdefer network.deinit(self.gpa);

        try self.convertSubstations(&network);

        try self.convertVoltageLevels(&network);

        try self.convertLoads(&network);
        try self.convertGenerators(&network);
        try self.convertSwitches(&network);

        try self.convertTransformers(&network);

        try self.convertLines(&network);

        return network;
    }

    fn convertSubstations(self: *Converter, network: *iidm.Network) !void {
        const substations = try self.model.getObjectsByType(self.gpa, "Substation");
        defer self.gpa.free(substations);

        try network.substations.ensureTotalCapacity(self.gpa, substations.len);
        try self.substation_map.ensureTotalCapacity(self.gpa, @intCast(substations.len));

        for (substations, 0..) |substation, idx| {
            const name = try substation.getProperty("IdentifiedObject.name");
            network.substations.appendAssumeCapacity(.{
                .id = substation.id,
                .name = name,
                .country = null,
                .geo_tags = null,
                .voltage_levels = .empty,
                .two_winding_transformers = .empty,
                .three_winding_transformers = .empty,
            });
            self.substation_map.putAssumeCapacity(substation.id, idx);
        }
    }

    fn convertVoltageLevels(self: *Converter, network: *iidm.Network) !void {
        const voltage_levels = try self.model.getObjectsByType(self.gpa, "VoltageLevel");
        defer self.gpa.free(voltage_levels);

        // Build BaseVoltage lookup
        const base_voltages = try self.model.getObjectsByType(self.gpa, "BaseVoltage");
        defer self.gpa.free(base_voltages);

        var nominal_voltages: std.StringHashMapUnmanaged(f64) = .empty;
        defer nominal_voltages.deinit(self.gpa);
        try nominal_voltages.ensureTotalCapacity(self.gpa, @intCast(base_voltages.len));

        for (base_voltages) |base_voltage| {
            const nominal_voltage_str = try base_voltage.getProperty("BaseVoltage.nominalVoltage") orelse return error.MalformedXML;
            nominal_voltages.putAssumeCapacity(base_voltage.id, try std.fmt.parseFloat(f64, nominal_voltage_str));
        }

        try self.voltage_level_map.ensureTotalCapacity(self.gpa, @intCast(voltage_levels.len));

        for (voltage_levels) |voltage_level| {
            const name = try voltage_level.getProperty("IdentifiedObject.name");
            const substation_ref = try voltage_level.getReference("VoltageLevel.Substation") orelse return error.MalformedXML;
            const substation_id = topology.stripHash(substation_ref);
            const base_voltage_ref = try voltage_level.getReference("VoltageLevel.BaseVoltage") orelse return error.MalformedXML;
            const base_voltage_id = topology.stripHash(base_voltage_ref);

            const substation_idx = self.substation_map.get(substation_id) orelse return error.MalformedXML;
            const substation = &network.substations.items[substation_idx];

            const voltage_level_idx = substation.voltage_levels.items.len;
            try substation.voltage_levels.append(self.gpa, .{
                .id = voltage_level.id,
                .name = name,
                .nominal_voltage = nominal_voltages.get(base_voltage_id),
                .low_voltage_limit = null,
                .high_voltage_limit = null,
                .generators = .empty,
                .loads = .empty,
                .switches = .empty,
            });

            self.voltage_level_map.putAssumeCapacity(voltage_level.id, .{ .substation_idx = substation_idx, .voltage_level_idx = voltage_level_idx });
        }
    }

    fn getVoltageLevel(self: *Converter, network: *iidm.Network, voltage_level_id: []const u8) ?*iidm.VoltageLevel {
        const ref = self.voltage_level_map.get(voltage_level_id) orelse return null;
        return &network.substations.items[ref.substation_idx].voltage_levels.items[ref.voltage_level_idx];
    }

    fn convertLoads(self: *Converter, network: *iidm.Network) !void {
        const loads = try self.model.getObjectsByType(self.gpa, "EnergyConsumer");
        defer self.gpa.free(loads);

        for (loads) |load| {
            const connectivity_node_id = self.topology_resolver.getEquipmentBus(load.id, 1) orelse return error.MalformedXML;
            const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;

            const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id = topology.stripHash(voltage_level_ref);
            const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;

            const name = try load.getProperty("IdentifiedObject.name");
            const p0 = try std.fmt.parseFloat(f64, try load.getProperty("EnergyConsumer.p") orelse return error.MalformedXML);
            const q0 = try std.fmt.parseFloat(f64, try load.getProperty("EnergyConsumer.q") orelse return error.MalformedXML);

            try voltage_level.loads.append(self.gpa, .{
                .id = load.id,
                .name = name,
                .bus = connectivity_node_id,
                .p0 = p0,
                .q0 = q0,
            });
        }
    }

    fn convertGenerators(self: *Converter, network: *iidm.Network) !void {
        const generators = try self.model.getObjectsByType(self.gpa, "SynchronousMachine");
        defer self.gpa.free(generators);

        for (generators) |generator| {
            const connectivity_node_id = self.topology_resolver.getEquipmentBus(generator.id, 1) orelse return error.MalformedXML;
            const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;
            const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id = topology.stripHash(voltage_level_ref);

            const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;

            const generating_unit_ref = try generator.getReference("RotatingMachine.GeneratingUnit") orelse return error.MalformedXML;
            const generating_unit = self.model.getObjectById(topology.stripHash(generating_unit_ref)) orelse return error.MalformedXML;

            const name = try generator.getProperty("IdentifiedObject.name");
            const min_p = try std.fmt.parseFloat(f64, try generating_unit.getProperty("GeneratingUnit.minOperatingP") orelse return error.MalformedXML);
            const max_p = try std.fmt.parseFloat(f64, try generating_unit.getProperty("GeneratingUnit.maxOperatingP") orelse return error.MalformedXML);
            const target_p = try std.fmt.parseFloat(f64, try generating_unit.getProperty("GeneratingUnit.initialP") orelse return error.MalformedXML);

            try voltage_level.generators.append(self.gpa, .{
                .id = generator.id,
                .name = name,
                .bus = connectivity_node_id,
                .min_p = min_p,
                .max_p = max_p,
                .target_p = target_p,
                .target_q = 0,
            });
        }
    }

    fn convertSwitches(self: *Converter, network: *iidm.Network) !void {
        for (switch_type_mapping) |mapping| {
            const switches = try self.model.getObjectsByType(self.gpa, mapping.cim_type);
            defer self.gpa.free(switches);

            for (switches) |sw| {
                const connectivity_node1_id = self.topology_resolver.getEquipmentBus(sw.id, 1) orelse return error.MalformedXML;
                const connectivity_node2_id = self.topology_resolver.getEquipmentBus(sw.id, 2) orelse return error.MalformedXML;

                const connectivity_node1 = self.model.getObjectById(connectivity_node1_id) orelse return error.MalformedXML;
                const voltage_level1_ref = try connectivity_node1.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;

                const connectivity_node2 = self.model.getObjectById(connectivity_node2_id) orelse return error.MalformedXML;
                const voltage_level2_ref = try connectivity_node2.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;

                if (!std.mem.eql(u8, voltage_level1_ref, voltage_level2_ref)) return error.MalformedXML;

                const voltage_level = self.getVoltageLevel(network, topology.stripHash(voltage_level1_ref)) orelse return error.MalformedXML;

                const name = try sw.getProperty("IdentifiedObject.name");
                const open_str = try sw.getProperty("Switch.open") orelse "false";

                try voltage_level.switches.append(self.gpa, .{
                    .id = sw.id,
                    .name = name,
                    .bus1 = connectivity_node1_id,
                    .bus2 = connectivity_node2_id,
                    .open = std.mem.eql(u8, open_str, "true"),
                    .kind = mapping.kind,
                });
            }
        }
    }

    fn convertTransformers(self: *Converter, network: *iidm.Network) !void {
        const transformers = try self.model.getObjectsByType(self.gpa, "PowerTransformer");
        defer self.gpa.free(transformers);

        const all_ends = try self.model.getObjectsByType(self.gpa, "PowerTransformerEnd");
        defer self.gpa.free(all_ends);

        const EndArray = struct { ends: [3]?cim_model.CimObject = .{ null, null, null } };
        var ends_map: std.StringHashMapUnmanaged(EndArray) = .empty;
        defer ends_map.deinit(self.gpa);

        for (all_ends) |end| {
            const transformer_ref = try end.getReference("PowerTransformerEnd.PowerTransformer") orelse return error.MalformedXML;
            const transformer_id = topology.stripHash(transformer_ref);
            const end_num = try std.fmt.parseInt(u32, try end.getProperty("TransformerEnd.endNumber") orelse return error.MalformedXML, 10);

            const gop = try ends_map.getOrPut(self.gpa, transformer_id);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            if (end_num >= 1 and end_num <= 3) gop.value_ptr.ends[end_num - 1] = end;
        }

        for (transformers) |transformer| {
            const ends = ends_map.get(transformer.id) orelse return error.MalformedXML;
            const end1 = ends.ends[0] orelse return error.MalformedXML;
            const end2 = ends.ends[1] orelse return error.MalformedXML;
            const name = try transformer.getProperty("IdentifiedObject.name");

            // Get substation via first voltage level
            const connectivity_node1_id = self.topology_resolver.getEquipmentBus(transformer.id, 1) orelse return error.MalformedXML;
            const connectivity_node1 = self.model.getObjectById(connectivity_node1_id) orelse return error.MalformedXML;
            const voltage_level1_ref = try connectivity_node1.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level1_id = topology.stripHash(voltage_level1_ref);
            const voltage_level_ref = self.voltage_level_map.get(voltage_level1_id) orelse return error.MalformedXML;
            const substation = &network.substations.items[voltage_level_ref.substation_idx];

            const connectivity_node2_id = self.topology_resolver.getEquipmentBus(transformer.id, 2) orelse return error.MalformedXML;

            if (ends.ends[2]) |end3| {
                const connectivity_node3_id = self.topology_resolver.getEquipmentBus(transformer.id, 3) orelse return error.MalformedXML;

                try substation.three_winding_transformers.append(self.gpa, .{
                    .id = transformer.id,
                    .name = name,
                    .bus1 = connectivity_node1_id,
                    .bus2 = connectivity_node2_id,
                    .bus3 = connectivity_node3_id,
                    .rated_u1 = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.ratedU") orelse return error.MalformedXML),
                    .rated_u2 = try std.fmt.parseFloat(f64, try end2.getProperty("PowerTransformerEnd.ratedU") orelse return error.MalformedXML),
                    .rated_u3 = try std.fmt.parseFloat(f64, try end3.getProperty("PowerTransformerEnd.ratedU") orelse return error.MalformedXML),
                    .r1 = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.r") orelse return error.MalformedXML),
                    .r2 = try std.fmt.parseFloat(f64, try end2.getProperty("PowerTransformerEnd.r") orelse return error.MalformedXML),
                    .r3 = try std.fmt.parseFloat(f64, try end3.getProperty("PowerTransformerEnd.r") orelse return error.MalformedXML),
                    .x1 = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.x") orelse return error.MalformedXML),
                    .x2 = try std.fmt.parseFloat(f64, try end2.getProperty("PowerTransformerEnd.x") orelse return error.MalformedXML),
                    .x3 = try std.fmt.parseFloat(f64, try end3.getProperty("PowerTransformerEnd.x") orelse return error.MalformedXML),
                    .g1 = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.g") orelse return error.MalformedXML),
                    .g2 = try std.fmt.parseFloat(f64, try end2.getProperty("PowerTransformerEnd.g") orelse return error.MalformedXML),
                    .g3 = try std.fmt.parseFloat(f64, try end3.getProperty("PowerTransformerEnd.g") orelse return error.MalformedXML),
                    .b1 = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.b") orelse return error.MalformedXML),
                    .b2 = try std.fmt.parseFloat(f64, try end2.getProperty("PowerTransformerEnd.b") orelse return error.MalformedXML),
                    .b3 = try std.fmt.parseFloat(f64, try end3.getProperty("PowerTransformerEnd.b") orelse return error.MalformedXML),
                });
            } else {
                try substation.two_winding_transformers.append(self.gpa, .{
                    .id = transformer.id,
                    .name = name,
                    .bus1 = connectivity_node1_id,
                    .bus2 = connectivity_node2_id,
                    .rated_u1 = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.ratedU") orelse return error.MalformedXML),
                    .rated_u2 = try std.fmt.parseFloat(f64, try end2.getProperty("PowerTransformerEnd.ratedU") orelse return error.MalformedXML),
                    .r = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.r") orelse return error.MalformedXML),
                    .x = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.x") orelse return error.MalformedXML),
                    .g = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.g") orelse return error.MalformedXML),
                    .b = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.b") orelse return error.MalformedXML),
                });
            }
        }
    }

    fn convertLines(self: *Converter, network: *iidm.Network) !void {
        const lines = try self.model.getObjectsByType(self.gpa, "ACLineSegment");
        defer self.gpa.free(lines);

        try network.lines.ensureTotalCapacity(self.gpa, lines.len);

        for (lines) |line| {
            const connectivity_node1_id = self.topology_resolver.getEquipmentBus(line.id, 1) orelse return error.MalformedXML;
            const connectivity_node2_id = self.topology_resolver.getEquipmentBus(line.id, 2) orelse return error.MalformedXML;

            const name = try line.getProperty("IdentifiedObject.name") orelse return error.MalformedXML;
            const r = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.r") orelse return error.MalformedXML);
            const x = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.x") orelse return error.MalformedXML);
            const bch = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.bch") orelse return error.MalformedXML);

            network.lines.appendAssumeCapacity(.{
                .id = line.id,
                .name = name,
                .bus1 = connectivity_node1_id,
                .bus2 = connectivity_node2_id,
                .r = r,
                .x = x,
                .g1 = 0,
                .g2 = 0,
                .b1 = bch / 2,
                .b2 = bch / 2,
            });
        }
    }
};
