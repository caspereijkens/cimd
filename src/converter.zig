const std = @import("std");
const cim_model = @import("cim_model.zig");
const topology = @import("topology.zig");
const iidm = @import("iidm.zig");

const CimModel = cim_model.CimModel;
const TopologyResolver = topology.TopologyResolver;

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
        return .{
            .id = "network",
            .case_date = null,
            .substations = substations,
            .voltage_levels = voltage_levels,
            .loads = loads,
            .generators = generators,
            .lines = lines,
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
};
