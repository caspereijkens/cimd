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
        return .{
            .id = "network",
            .case_date = null,
            .substations = substations,
            .voltage_levels = voltage_levels,
            .loads = loads,
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
            const name = try load.getProperty("IdentifiedObject.name") orelse return error.MalformedXML;

            const p0_str = try load.getProperty("EnergyConsumer.p") orelse return error.MalformedXML;
            const p0 = try std.fmt.parseFloat(f64, p0_str);

            const q0_str = try load.getProperty("EnergyConsumer.q") orelse return error.MalformedXML;
            const q0 = try std.fmt.parseFloat(f64, q0_str);

            const connectivity_node_id = self.topology_resolver.getEquipmentBus(load.id, 1) orelse return error.MalformedXML;
            const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;
            const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id = topology.stripHash(voltage_level_ref);

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
};
