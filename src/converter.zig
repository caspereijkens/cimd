const std = @import("std");
const cim_model = @import("cim_model.zig");
const topology = @import("topology.zig");
const iidm = @import("iidm.zig");

const assert = std.debug.assert;
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

    pub fn init(gpa: std.mem.Allocator, model: *const CimModel, topology_resolver: *const TopologyResolver) Converter {
        return .{
            .gpa = gpa,
            .model = model,
            .topology_resolver = topology_resolver,
        };
    }

    pub fn convert(self: *const Converter) !iidm.Network {
        const substations = try self.convertSubstations();
        const voltage_levels = try self.convertVoltageLevels();
        const loads = try self.convertLoads();
        const generators = try self.convertGenerators();
        const lines = try self.convertLines();
        const transformer_result = try self.convertTransformers();
        const switches = try self.convertSwitches();
        return .{
            .id = "network",
            .case_date = null,
            .substations = substations,
            .voltage_levels = voltage_levels,
            .loads = loads,
            .generators = generators,
            .lines = lines,
            .two_winding_transformers = transformer_result.two_winding,
            .three_winding_transformers = transformer_result.three_winding,
            .switches = switches,
        };
    }

    fn convertSubstations(self: *const Converter) !std.ArrayList(iidm.Substation) {
        var iidm_substations: std.ArrayList(iidm.Substation) = .empty;
        errdefer iidm_substations.deinit(self.gpa);

        const substations = try self.model.getObjectsByType(self.gpa, "Substation");
        defer self.gpa.free(substations);
        try iidm_substations.ensureTotalCapacity(self.gpa, substations.len);
        for (substations) |substation| {
            const name = try substation.getProperty("IdentifiedObject.name") orelse return error.MalformedXML;
            iidm_substations.appendAssumeCapacity(.{
                .id = substation.id,
                .name = name,
                .country = null,
                .geo_tags = null,
            });
        }
        return iidm_substations;
    }

    fn convertVoltageLevels(self: *const Converter) !std.ArrayList(iidm.VoltageLevel) {
        var iidm_voltage_levels: std.ArrayList(iidm.VoltageLevel) = .empty;
        errdefer iidm_voltage_levels.deinit(self.gpa);

        const voltage_levels = try self.model.getObjectsByType(self.gpa, "VoltageLevel");
        defer self.gpa.free(voltage_levels);
        try iidm_voltage_levels.ensureTotalCapacity(self.gpa, voltage_levels.len);

        const base_voltages = try self.model.getObjectsByType(self.gpa, "BaseVoltage");
        defer self.gpa.free(base_voltages);

        var nominal_voltages = std.StringHashMap(f64).init(self.gpa);
        defer nominal_voltages.deinit();
        for (base_voltages) |base_voltage| {
            const nominal_voltage = try base_voltage.getProperty("BaseVoltage.nominalVoltage") orelse return error.MalformedXML;
            const nominal_voltage_value = try std.fmt.parseFloat(f64, nominal_voltage);
            try nominal_voltages.put(base_voltage.id, nominal_voltage_value);
        }

        for (voltage_levels) |voltage_level| {
            const name = try voltage_level.getProperty("IdentifiedObject.name") orelse return error.MalformedXML;

            const substation_ref = try voltage_level.getReference("VoltageLevel.Substation") orelse return error.MalformedXML;
            const substation_id = topology.stripHash(substation_ref);

            const base_voltage_ref = try voltage_level.getReference("VoltageLevel.BaseVoltage") orelse return error.MalformedXML;
            const base_voltage_id = topology.stripHash(base_voltage_ref);
            const nominal_voltage = nominal_voltages.get(base_voltage_id);
            iidm_voltage_levels.appendAssumeCapacity(.{
                .id = voltage_level.id,
                .name = name,
                .substation_id = substation_id,
                .nominal_voltage = nominal_voltage,
                .low_voltage_limit = null,
                .high_voltage_limit = null,
            });
        }
        return iidm_voltage_levels;
    }

    fn convertLoads(self: *const Converter) !std.ArrayList(iidm.Load) {
        var iidm_loads: std.ArrayList(iidm.Load) = .empty;
        errdefer iidm_loads.deinit(self.gpa);

        const loads = try self.model.getObjectsByType(self.gpa, "EnergyConsumer");
        defer self.gpa.free(loads);
        try iidm_loads.ensureTotalCapacity(self.gpa, loads.len);

        for (loads) |load| {
            // Get bus from topology resolver (sequence 1 for single-terminal equipment)
            const connectivity_node_id = self.topology_resolver.getEquipmentBus(load.id, 1) orelse return error.MalformedXML;
            // Get the ConnectivityNode to find its container (VoltageLevel)
            const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;
            const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id = topology.stripHash(voltage_level_ref);

            const name = try load.getProperty("IdentifiedObject.name") orelse return error.MalformedXML;

            const p0_str = try load.getProperty("EnergyConsumer.p") orelse return error.MalformedXML;
            const p0 = try std.fmt.parseFloat(f64, p0_str);

            const q0_str = try load.getProperty("EnergyConsumer.q") orelse return error.MalformedXML;
            const q0 = try std.fmt.parseFloat(f64, q0_str);

            iidm_loads.appendAssumeCapacity(.{
                .id = load.id,
                .name = name,
                .voltage_level_id = voltage_level_id,
                .bus = connectivity_node_id,
                .p0 = p0,
                .q0 = q0,
            });
        }
        return iidm_loads;
    }

    fn convertGenerators(self: *const Converter) !std.ArrayList(iidm.Generator) {
        var iidm_generators: std.ArrayList(iidm.Generator) = .empty;
        errdefer iidm_generators.deinit(self.gpa);

        const generators = try self.model.getObjectsByType(self.gpa, "SynchronousMachine");
        defer self.gpa.free(generators);
        try iidm_generators.ensureTotalCapacity(self.gpa, generators.len);

        for (generators) |generator| {
            // Get bus from topology resolver (sequence 1 for single-terminal equipment)
            const connectivity_node_id = self.topology_resolver.getEquipmentBus(generator.id, 1) orelse return error.MalformedXML;

            // Get the ConnectivityNode to find its container (VoltageLevel)
            const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;
            const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id = topology.stripHash(voltage_level_ref);

            const generating_unit_ref = try generator.getReference("RotatingMachine.GeneratingUnit") orelse return error.MalformedXML;
            const generating_unit_id = topology.stripHash(generating_unit_ref);
            const generating_unit = self.model.getObjectById(generating_unit_id) orelse return error.MalformedXML;

            const name = try generator.getProperty("IdentifiedObject.name") orelse return error.MalformedXML;

            const min_p_str = try generating_unit.getProperty("GeneratingUnit.minOperatingP") orelse return error.MalformedXML;
            const min_p = try std.fmt.parseFloat(f64, min_p_str);

            const max_p_str = try generating_unit.getProperty("GeneratingUnit.maxOperatingP") orelse return error.MalformedXML;
            const max_p = try std.fmt.parseFloat(f64, max_p_str);

            const target_p_str = try generating_unit.getProperty("GeneratingUnit.initialP") orelse return error.MalformedXML;
            const target_p = try std.fmt.parseFloat(f64, target_p_str);
            iidm_generators.appendAssumeCapacity(.{
                .id = generator.id,
                .name = name,
                .voltage_level_id = voltage_level_id,
                .bus = connectivity_node_id,
                .min_p = min_p,
                .max_p = max_p,
                .target_p = target_p,
                .target_q = 0,
            });
        }
        return iidm_generators;
    }

    fn convertLines(self: *const Converter) !std.ArrayList(iidm.Line) {
        var iidm_lines: std.ArrayList(iidm.Line) = .empty;
        errdefer iidm_lines.deinit(self.gpa);

        const lines = try self.model.getObjectsByType(self.gpa, "ACLineSegment");
        defer self.gpa.free(lines);
        try iidm_lines.ensureTotalCapacity(self.gpa, lines.len);

        for (lines) |line| {
            // Get bus from topology resolver (sequence 1, 2 for double-terminal equipment)
            const connectivity_node_id1 = self.topology_resolver.getEquipmentBus(line.id, 1) orelse return error.MalformedXML;
            const connectivity_node_id2 = self.topology_resolver.getEquipmentBus(line.id, 2) orelse return error.MalformedXML;

            // Get the ConnectivityNode to find its container (VoltageLevel)
            const connectivity_node1 = self.model.getObjectById(connectivity_node_id1) orelse return error.MalformedXML;
            const connectivity_node2 = self.model.getObjectById(connectivity_node_id2) orelse return error.MalformedXML;

            const voltage_level_ref1 = try connectivity_node1.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_ref2 = try connectivity_node2.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;

            const voltage_level_id1 = topology.stripHash(voltage_level_ref1);
            const voltage_level_id2 = topology.stripHash(voltage_level_ref2);

            const name = try line.getProperty("IdentifiedObject.name") orelse return error.MalformedXML;

            const r_str = try line.getProperty("ACLineSegment.r") orelse return error.MalformedXML;
            const r = try std.fmt.parseFloat(f64, r_str);

            const x_str = try line.getProperty("ACLineSegment.x") orelse return error.MalformedXML;
            const x = try std.fmt.parseFloat(f64, x_str);

            const bch_str = try line.getProperty("ACLineSegment.bch") orelse return error.MalformedXML;
            const bch = try std.fmt.parseFloat(f64, bch_str);

            iidm_lines.appendAssumeCapacity(.{
                .id = line.id,
                .name = name,
                .voltage_level_id1 = voltage_level_id1,
                .voltage_level_id2 = voltage_level_id2,
                .bus1 = connectivity_node_id1,
                .bus2 = connectivity_node_id2,
                .r = r,
                .x = x,
                .g1 = 0,
                .g2 = 0,
                .b1 = bch / 2,
                .b2 = bch / 2,
            });
        }
        return iidm_lines;
    }

    const TransformerResult = struct {
        two_winding: std.ArrayList(iidm.TwoWindingsTransformer),
        three_winding: std.ArrayList(iidm.ThreeWindingsTransformer),
    };

    fn convertTransformers(self: *const Converter) !TransformerResult {
        var two_winding: std.ArrayList(iidm.TwoWindingsTransformer) = .empty;
        errdefer two_winding.deinit(self.gpa);

        var three_winding: std.ArrayList(iidm.ThreeWindingsTransformer) = .empty;
        errdefer three_winding.deinit(self.gpa);

        const transformers = try self.model.getObjectsByType(self.gpa, "PowerTransformer");
        defer self.gpa.free(transformers);

        const all_ends = try self.model.getObjectsByType(self.gpa, "PowerTransformerEnd");
        defer self.gpa.free(all_ends);

        // Build transformer_id → [end1, end2, end3] lookup for electrical parameters
        const EndArray = struct { ends: [3]?cim_model.CimObject = .{ null, null, null } };
        var ends_by_transformer = std.StringHashMap(EndArray).init(self.gpa);
        defer ends_by_transformer.deinit();

        for (all_ends) |end| {
            const transformer_ref = try end.getReference("PowerTransformerEnd.PowerTransformer") orelse return error.MalformedXML;
            const transformer_id = topology.stripHash(transformer_ref);
            const end_num_str = try end.getProperty("TransformerEnd.endNumber") orelse return error.MalformedXML;
            const end_num = try std.fmt.parseInt(u32, end_num_str, 10);

            const gop = try ends_by_transformer.getOrPut(transformer_id);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            if (end_num >= 1 and end_num <= 3) {
                gop.value_ptr.ends[end_num - 1] = end;
            }
        }

        for (transformers) |transformer| {
            const ends = ends_by_transformer.get(transformer.id) orelse return error.MalformedXML;
            const end1 = ends.ends[0] orelse return error.MalformedXML;
            const end2 = ends.ends[1] orelse return error.MalformedXML;
            const name = try transformer.getProperty("IdentifiedObject.name");

            if (ends.ends[2]) |end3| {
                // 3-winding transformer
                const cn1_id = self.topology_resolver.getEquipmentBus(transformer.id, 1) orelse return error.MalformedXML;
                const cn2_id = self.topology_resolver.getEquipmentBus(transformer.id, 2) orelse return error.MalformedXML;
                const cn3_id = self.topology_resolver.getEquipmentBus(transformer.id, 3) orelse return error.MalformedXML;

                const cn1 = self.model.getObjectById(cn1_id) orelse return error.MalformedXML;
                const cn2 = self.model.getObjectById(cn2_id) orelse return error.MalformedXML;
                const cn3 = self.model.getObjectById(cn3_id) orelse return error.MalformedXML;

                const vl1_ref = try cn1.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
                const vl2_ref = try cn2.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
                const vl3_ref = try cn3.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;

                try three_winding.append(self.gpa, .{
                    .id = transformer.id,
                    .name = name,
                    .voltage_level_id1 = topology.stripHash(vl1_ref),
                    .voltage_level_id2 = topology.stripHash(vl2_ref),
                    .voltage_level_id3 = topology.stripHash(vl3_ref),
                    .bus1 = cn1_id,
                    .bus2 = cn2_id,
                    .bus3 = cn3_id,
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
                // 2-winding transformer
                const cn1_id = self.topology_resolver.getEquipmentBus(transformer.id, 1) orelse return error.MalformedXML;
                const cn2_id = self.topology_resolver.getEquipmentBus(transformer.id, 2) orelse return error.MalformedXML;

                const cn1 = self.model.getObjectById(cn1_id) orelse return error.MalformedXML;
                const cn2 = self.model.getObjectById(cn2_id) orelse return error.MalformedXML;

                const vl1_ref = try cn1.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
                const vl2_ref = try cn2.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;

                try two_winding.append(self.gpa, .{
                    .id = transformer.id,
                    .name = name,
                    .voltage_level_id1 = topology.stripHash(vl1_ref),
                    .voltage_level_id2 = topology.stripHash(vl2_ref),
                    .bus1 = cn1_id,
                    .bus2 = cn2_id,
                    .rated_u1 = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.ratedU") orelse return error.MalformedXML),
                    .rated_u2 = try std.fmt.parseFloat(f64, try end2.getProperty("PowerTransformerEnd.ratedU") orelse return error.MalformedXML),
                    .r = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.r") orelse return error.MalformedXML),
                    .x = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.x") orelse return error.MalformedXML),
                    .g = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.g") orelse return error.MalformedXML),
                    .b = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.b") orelse return error.MalformedXML),
                });
            }
        }

        return .{ .two_winding = two_winding, .three_winding = three_winding };
    }

    fn convertSwitches(self: *const Converter) !std.ArrayList(iidm.Switch) {
        var result: std.ArrayList(iidm.Switch) = .empty;
        errdefer result.deinit(self.gpa);

        var total_count: usize = 0;
        for (switch_type_mapping) |mapping| {
            if (self.model.type_index.get(mapping.cim_type)) |indices| {
                total_count += indices.items.len;
            }
        }
        try result.ensureTotalCapacity(self.gpa, total_count);

        for (switch_type_mapping) |mapping| {
            const switches = try self.model.getObjectsByType(self.gpa, mapping.cim_type);
            defer self.gpa.free(switches);

            for (switches) |@"switch"| {
                const cn1_id = self.topology_resolver.getEquipmentBus(@"switch".id, 1) orelse return error.MalformedXML;
                const cn2_id = self.topology_resolver.getEquipmentBus(@"switch".id, 2) orelse return error.MalformedXML;

                const cn1 = self.model.getObjectById(cn1_id) orelse return error.MalformedXML;
                const cn2 = self.model.getObjectById(cn2_id) orelse return error.MalformedXML;
                const vl1_ref = try cn1.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
                const vl2_ref = try cn2.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
                if (!std.mem.eql(u8, vl1_ref, vl2_ref)) {
                    return error.MalformedXML;
                }
                const name = try @"switch".getProperty("IdentifiedObject.name");
                const open_str = try @"switch".getProperty("Switch.open") orelse "false";
                result.appendAssumeCapacity(.{
                    .id = @"switch".id,
                    .name = name,
                    .voltage_level_id = topology.stripHash(vl1_ref),
                    .bus1 = cn1_id,
                    .bus2 = cn2_id,
                    .open = std.mem.eql(u8, open_str, "true"),
                    .kind = mapping.kind,
                });
            }
        }

        return result;
    }
};
