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
    node_index_maps: std.StringHashMapUnmanaged(NodeIndexMap),

    const VoltageLevelRef = struct { substation_idx: usize, voltage_level_idx: usize };

    const NodeIndexMap = struct {
        cn_to_index: std.StringHashMapUnmanaged(u32),
        next_index: u32,

        fn getOrAssign(self: *NodeIndexMap, gpa: std.mem.Allocator, cn_id: []const u8) !u32 {
            const gop = try self.cn_to_index.getOrPut(gpa, cn_id);
            if (!gop.found_existing) {
                gop.value_ptr.* = self.next_index;
                self.next_index += 1;
            }
            return gop.value_ptr.*;
        }

        fn deinit(self: *NodeIndexMap, gpa: std.mem.Allocator) void {
            self.cn_to_index.deinit(gpa);
        }
    };

    pub fn init(gpa: std.mem.Allocator, model: *const CimModel, topology_resolver: *const TopologyResolver) Converter {
        return .{
            .gpa = gpa,
            .model = model,
            .topology_resolver = topology_resolver,
            .substation_map = .empty,
            .voltage_level_map = .empty,
            .node_index_maps = .empty,
        };
    }

    pub fn deinit(self: *Converter) void {
        self.substation_map.deinit(self.gpa);
        self.voltage_level_map.deinit(self.gpa);
        var it = self.node_index_maps.valueIterator();
        while (it.next()) |map| {
            map.deinit(self.gpa);
        }
        self.node_index_maps.deinit(self.gpa);
    }

    fn getNodeIndex(self: *Converter, voltage_level_id: []const u8, cn_id: []const u8) !u32 {
        const gop = try self.node_index_maps.getOrPut(self.gpa, voltage_level_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .cn_to_index = .empty, .next_index = 0 };
        }
        return gop.value_ptr.getOrAssign(self.gpa, cn_id);
    }

    pub fn convert(self: *Converter) !iidm.Network {
        const full_model_list = try self.model.getObjectsByType(self.gpa, "FullModel");
        defer self.gpa.free(full_model_list);

        if (full_model_list.len == 0) {
            return error.MalformedXML;
        } else if (full_model_list.len > 1) {
            return error.TooManyFullModelTags;
        }
        const full_model = full_model_list[0];

        const case_date = try full_model.getProperty("Model.scenarioTime");

        var network: iidm.Network = .{
            .id = full_model.id,
            .case_date = case_date,
            .substations = .empty,
            .lines = .empty,
        };
        errdefer network.deinit(self.gpa);

        try self.convertSubstations(&network);

        try self.convertVoltageLevels(&network);

        try self.convertBusbarSections(&network);
        try self.convertSwitches(&network);
        try self.convertLoads(&network);
        try self.convertGenerators(&network);

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
            const id = try substation.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(substation.id);
            const name = try substation.getProperty("IdentifiedObject.name");

            // Resolve geo_tags from Substation.Region -> SubGeographicalRegion.name
            var geo_tags: std.ArrayListUnmanaged([]const u8) = .empty;
            if (try substation.getReference("Substation.Region")) |region_ref| {
                if (self.model.getObjectById(topology.stripHash(region_ref))) |region| {
                    if (try region.getProperty("IdentifiedObject.name")) |region_name| {
                        try geo_tags.append(self.gpa, region_name);
                    }
                }
            }

            network.substations.appendAssumeCapacity(.{
                .id = id,
                .name = name,
                .country = null,
                .geo_tags = geo_tags,
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
            const id = try voltage_level.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(voltage_level.id);
            const name = try voltage_level.getProperty("IdentifiedObject.name");
            const substation_ref = try voltage_level.getReference("VoltageLevel.Substation") orelse return error.MalformedXML;
            const substation_id = topology.stripHash(substation_ref);
            const base_voltage_ref = try voltage_level.getReference("VoltageLevel.BaseVoltage") orelse return error.MalformedXML;
            const base_voltage_id = topology.stripHash(base_voltage_ref);
            const low_voltage_limit: ?f64 = if (try voltage_level.getProperty("VoltageLevel.lowVoltageLimit")) |val|
                try std.fmt.parseFloat(f64, val)
            else
                null;
            const high_voltage_limit: ?f64 = if (try voltage_level.getProperty("VoltageLevel.highVoltageLimit")) |val|
                try std.fmt.parseFloat(f64, val)
            else
                null;
            const substation_idx = self.substation_map.get(substation_id) orelse return error.MalformedXML;
            const substation = &network.substations.items[substation_idx];

            const voltage_level_idx = substation.voltage_levels.items.len;
            try substation.voltage_levels.append(self.gpa, .{
                .id = id,
                .name = name,
                .nominal_voltage = nominal_voltages.get(base_voltage_id),
                .low_voltage_limit = low_voltage_limit,
                .high_voltage_limit = high_voltage_limit,
                .generators = .empty,
                .loads = .empty,
                .node_breaker_topology = .{ .busbar_sections = .empty, .switches = .empty },
            });

            self.voltage_level_map.putAssumeCapacity(voltage_level.id, .{ .substation_idx = substation_idx, .voltage_level_idx = voltage_level_idx });
        }
    }

    fn getVoltageLevel(self: *Converter, network: *iidm.Network, voltage_level_id: []const u8) ?*iidm.VoltageLevel {
        const ref = self.voltage_level_map.get(voltage_level_id) orelse return null;
        return &network.substations.items[ref.substation_idx].voltage_levels.items[ref.voltage_level_idx];
    }

    fn convertLoads(self: *Converter, network: *iidm.Network) !void {
        const energy_consumers = try self.model.getObjectsByType(self.gpa, "EnergyConsumer");
        defer self.gpa.free(energy_consumers);

        for (energy_consumers) |load| {
            try self.addLoad(network, load, "EnergyConsumer.p", "EnergyConsumer.q");
        }

        const energy_sources = try self.model.getObjectsByType(self.gpa, "EnergySource");
        defer self.gpa.free(energy_sources);

        for (energy_sources) |load| {
            try self.addLoad(network, load, "EnergySource.activePower", "EnergySource.reactivePower");
        }
    }

    fn addLoad(self: *Converter, network: *iidm.Network, load: cim_model.CimObject, p_prop: []const u8, q_prop: []const u8) !void {
        const connectivity_node_id = self.topology_resolver.getEquipmentNode(load.id, 1) orelse return error.MalformedXML;
        const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;

        const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
        const voltage_level_id = topology.stripHash(voltage_level_ref);
        const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;

        const name = try load.getProperty("IdentifiedObject.name");
        // p and q are in SSH profile, not EQ - default to 0 if missing
        const p0 = if (try load.getProperty(p_prop)) |p_str|
            try std.fmt.parseFloat(f64, p_str)
        else
            0.0;
        const q0 = if (try load.getProperty(q_prop)) |q_str|
            try std.fmt.parseFloat(f64, q_str)
        else
            0.0;

        const node_index = try self.getNodeIndex(voltage_level_id, connectivity_node_id);

        try voltage_level.loads.append(self.gpa, .{
            .id = load.id,
            .name = name,
            .node = node_index,
            .p0 = p0,
            .q0 = q0,
        });
    }

    fn convertGenerators(self: *Converter, network: *iidm.Network) !void {
        const generators = try self.model.getObjectsByType(self.gpa, "SynchronousMachine");
        defer self.gpa.free(generators);

        for (generators) |generator| {
            const connectivity_node_id = self.topology_resolver.getEquipmentNode(generator.id, 1) orelse return error.MalformedXML;
            const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;
            const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id = topology.stripHash(voltage_level_ref);

            const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;

            const generating_unit_ref = try generator.getReference("RotatingMachine.GeneratingUnit") orelse return error.MalformedXML;
            const generating_unit = self.model.getObjectById(topology.stripHash(generating_unit_ref)) orelse return error.MalformedXML;

            const name = try generator.getProperty("IdentifiedObject.name");
            // minOperatingP and maxOperatingP may be optional
            const min_p = if (try generating_unit.getProperty("GeneratingUnit.minOperatingP")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                null;
            const max_p = if (try generating_unit.getProperty("GeneratingUnit.maxOperatingP")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                null;
            // initialP is often in SSH, not EQ
            const target_p = if (try generating_unit.getProperty("GeneratingUnit.initialP")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                0.0;

            const node_index = try self.getNodeIndex(voltage_level_id, connectivity_node_id);

            try voltage_level.generators.append(self.gpa, .{
                .id = generator.id,
                .name = name,
                .node = node_index,
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
                const id = try sw.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(sw.id);
                const connectivity_node1_id = self.topology_resolver.getEquipmentNode(sw.id, 1) orelse return error.MalformedXML;
                const connectivity_node2_id = self.topology_resolver.getEquipmentNode(sw.id, 2) orelse return error.MalformedXML;

                const connectivity_node1 = self.model.getObjectById(connectivity_node1_id) orelse return error.MalformedXML;
                const voltage_level1_ref = try connectivity_node1.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;

                const connectivity_node2 = self.model.getObjectById(connectivity_node2_id) orelse return error.MalformedXML;
                const voltage_level2_ref = try connectivity_node2.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;

                if (!std.mem.eql(u8, voltage_level1_ref, voltage_level2_ref)) return error.MalformedXML;

                const voltage_level_id = topology.stripHash(voltage_level1_ref);
                const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;

                const name = try sw.getProperty("IdentifiedObject.name");
                // Switch.normalOpen is in EQ profile Switch.open is typically in SSH profile,
                const open_str = try sw.getProperty("Switch.normalOpen") orelse
                     try sw.getProperty("Switch.open") orelse "false";

                const node1_index = try self.getNodeIndex(voltage_level_id, connectivity_node1_id);
                const node2_index = try self.getNodeIndex(voltage_level_id, connectivity_node2_id);

                try voltage_level.node_breaker_topology.switches.append(self.gpa, .{
                    .id = id,
                    .name = name,
                    .kind = mapping.kind,
                    .open = std.mem.eql(u8, open_str, "true"),
                    .node1 = node1_index,
                    .node2 = node2_index,
                });
            }
        }
    }

    fn convertBusbarSections(self: *Converter, network: *iidm.Network) !void {
        const busbar_sections = try self.model.getObjectsByType(self.gpa, "BusbarSection");
        defer self.gpa.free(busbar_sections);

        for (busbar_sections) |busbar_section| {
            const id = try busbar_section.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(busbar_section.id);
            const connectivity_node_id = self.topology_resolver.getEquipmentNode(busbar_section.id, 1) orelse return error.MalformedXML;
            const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;

            const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id = topology.stripHash(voltage_level_ref);
            const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;

            const name = try busbar_section.getProperty("IdentifiedObject.name");
            const node_index = try self.getNodeIndex(voltage_level_id, connectivity_node_id);

            try voltage_level.node_breaker_topology.busbar_sections.append(self.gpa, .{
                .id = id,
                .name = name,
                .node = node_index,
            });
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
            const connectivity_node1_id = self.topology_resolver.getEquipmentNode(transformer.id, 1) orelse return error.MalformedXML;
            const connectivity_node1 = self.model.getObjectById(connectivity_node1_id) orelse return error.MalformedXML;
            const voltage_level1_ref = try connectivity_node1.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level1_id = topology.stripHash(voltage_level1_ref);
            const voltage_level_ref = self.voltage_level_map.get(voltage_level1_id) orelse return error.MalformedXML;
            const substation = &network.substations.items[voltage_level_ref.substation_idx];

            const connectivity_node2_id = self.topology_resolver.getEquipmentNode(transformer.id, 2) orelse return error.MalformedXML;

            if (ends.ends[2]) |end3| {
                const connectivity_node3_id = self.topology_resolver.getEquipmentNode(transformer.id, 3) orelse return error.MalformedXML;

                try substation.three_winding_transformers.append(self.gpa, .{
                    .id = transformer.id,
                    .name = name,
                    .node1 = connectivity_node1_id,
                    .node2 = connectivity_node2_id,
                    .node3 = connectivity_node3_id,
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
                const rated_u1 = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.ratedU") orelse return error.MalformedXML);
                const rated_u2 = try std.fmt.parseFloat(f64, try end2.getProperty("PowerTransformerEnd.ratedU") orelse return error.MalformedXML);

                if (rated_u1 == 0 or rated_u2 == 0) return error.InvalidRatedVoltage;

                // IIDM convention: parameters are referred to side 2 (low voltage)
                // Convert from CGMES (side 1) to IIDM:
                // - Series impedance (r, x): multiply by (ratedU2/ratedU1)²
                // - Shunt admittance (g, b): divide by (ratedU2/ratedU1)² = multiply by (ratedU1/ratedU2)²
                const ratio = rated_u2 / rated_u1;
                const ratio_sq = ratio * ratio;

                try substation.two_winding_transformers.append(self.gpa, .{
                    .id = transformer.id,
                    .name = name,
                    .node1 = connectivity_node1_id,
                    .node2 = connectivity_node2_id,
                    .rated_u1 = rated_u1,
                    .rated_u2 = rated_u2,
                    .r = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.r") orelse return error.MalformedXML) * ratio_sq,
                    .x = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.x") orelse return error.MalformedXML) * ratio_sq,
                    .g = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.g") orelse return error.MalformedXML) / ratio_sq,
                    .b = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.b") orelse return error.MalformedXML) / ratio_sq,
                });
            }
        }
    }

    fn convertLines(self: *Converter, network: *iidm.Network) !void {
        const lines = try self.model.getObjectsByType(self.gpa, "ACLineSegment");
        defer self.gpa.free(lines);

        try network.lines.ensureTotalCapacity(self.gpa, lines.len);

        for (lines) |line| {
            const connectivity_node1_id = self.topology_resolver.getEquipmentNode(line.id, 1) orelse return error.MalformedXML;
            const connectivity_node2_id = self.topology_resolver.getEquipmentNode(line.id, 2) orelse return error.MalformedXML;

            const name = try line.getProperty("IdentifiedObject.name") orelse return error.MalformedXML;
            const r = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.r") orelse return error.MalformedXML);
            const x = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.x") orelse return error.MalformedXML);
            const bch = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.bch") orelse return error.MalformedXML);
            // gch is optional in CGMES, default to 0 if not present
            const gch = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.gch") orelse "0");

            network.lines.appendAssumeCapacity(.{
                .id = line.id,
                .name = name,
                .node1 = connectivity_node1_id,
                .node2 = connectivity_node2_id,
                .r = r,
                .x = x,
                .g1 = gch / 2,
                .g2 = gch / 2,
                .b1 = bch / 2,
                .b2 = bch / 2,
            });
        }
    }
};
