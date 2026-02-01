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
    curve_points_map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(iidm.ReactiveCapabilityCurvePoint)),

    const VoltageLevelRef = struct { substation_idx: usize, voltage_level_idx: usize };

    const NodeIndexMap = struct {
        cn_to_index: std.StringHashMapUnmanaged(u32),
        next_index: u32,

        fn getOrAssign(self: *NodeIndexMap, gpa: std.mem.Allocator, contingency_node_id: []const u8) !u32 {
            const gop = try self.cn_to_index.getOrPut(gpa, contingency_node_id);
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
            .curve_points_map = .empty,
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
        self.freeCurvePointsMap();
    }

    fn buildCurvePointsMap(self: *Converter) !void {
        const curve_datas = try self.model.getObjectsByType(self.gpa, "CurveData");
        defer self.gpa.free(curve_datas);

        for (curve_datas) |curve_data| {
            const curve_ref = try curve_data.getReference("CurveData.Curve") orelse continue;
            const curve_id = topology.stripHash(curve_ref);
            const x_value = try std.fmt.parseFloat(f64, try curve_data.getProperty("CurveData.xvalue") orelse continue);
            const y1_value = try std.fmt.parseFloat(f64, try curve_data.getProperty("CurveData.y1value") orelse continue);
            const y2_value = try std.fmt.parseFloat(f64, try curve_data.getProperty("CurveData.y2value") orelse continue);

            const gop = try self.curve_points_map.getOrPut(self.gpa, curve_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.gpa, .{ .p = x_value, .min_q = y1_value, .max_q = y2_value });
        }
    }

    fn freeCurvePointsMap(self: *Converter) void {
        var it = self.curve_points_map.valueIterator();
        while (it.next()) |list| list.deinit(self.gpa);
        self.curve_points_map.deinit(self.gpa);
    }

    fn getCurvePoints(self: *Converter, curve_id: []const u8) !std.ArrayListUnmanaged(iidm.ReactiveCapabilityCurvePoint) {
        var points: std.ArrayListUnmanaged(iidm.ReactiveCapabilityCurvePoint) = .empty;
        if (self.curve_points_map.get(curve_id)) |src| {
            try points.appendSlice(self.gpa, src.items);
        }
        return points;
    }

    fn getNodeIndex(self: *Converter, voltage_level_id: []const u8, contingency_node_id: []const u8) !u32 {
        const gop = try self.node_index_maps.getOrPut(self.gpa, voltage_level_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .cn_to_index = .empty, .next_index = 0 };
        }
        return gop.value_ptr.getOrAssign(self.gpa, contingency_node_id);
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

        try self.buildCurvePointsMap();

        try self.convertBusbarSections(&network);
        try self.convertSwitches(&network);
        try self.convertLoads(&network);
        try self.convertShunts(&network);
        try self.convertGenerators(&network);
        try self.convertVsConverters(&network);
        try self.convertCsConverters(&network);

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
                .node_breaker_topology = .{ .busbar_sections = .empty, .switches = .empty },
                .generators = .empty,
                .loads = .empty,
                .shunts = .empty,
                .vs_converter_stations = .empty,
                .lcc_converter_stations = .empty,
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
            try self.addLoad(network, load);
        }

        const energy_sources = try self.model.getObjectsByType(self.gpa, "EnergySource");
        defer self.gpa.free(energy_sources);

        for (energy_sources) |load| {
            try self.addLoad(network, load);
        }
    }

    fn addLoad(self: *Converter, network: *iidm.Network, load: cim_model.CimObject) !void {
        const connectivity_node_id = self.topology_resolver.getEquipmentNode(load.id, 1) orelse return error.MalformedXML;
        const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;

        const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
        const voltage_level_id = topology.stripHash(voltage_level_ref);
        const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;

        const id = try load.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(load.id);
        const name = try load.getProperty("IdentifiedObject.name");

        const node_index = try self.getNodeIndex(voltage_level_id, connectivity_node_id);

        try voltage_level.loads.append(self.gpa, .{
            .id = id,
            .name = name,
            .load_type = .other,
            .node = node_index,
        });
    }

    fn convertShunts(self: *Converter, network: *iidm.Network) !void {
        const linear_shunt_compensators = try self.model.getObjectsByType(self.gpa, "LinearShuntCompensator");
        defer self.gpa.free(linear_shunt_compensators);

        for (linear_shunt_compensators) |linear_shunt_compensator| {
            const id = try linear_shunt_compensator.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(linear_shunt_compensator.id);
            const name = try linear_shunt_compensator.getProperty("IdentifiedObject.name");
            const connectivity_node_id = self.topology_resolver.getEquipmentNode(linear_shunt_compensator.id, 1) orelse return error.MalformedXML;
            const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;

            const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id = topology.stripHash(voltage_level_ref);
            const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;
            const shunt_linear_model: iidm.ShuntLinearModel = .{
                .b_per_section = try std.fmt.parseFloat(f64, try linear_shunt_compensator.getProperty("LinearShuntCompensator.bPerSection") orelse return error.MalformedXML),
                .g_per_section = try std.fmt.parseFloat(f64, try linear_shunt_compensator.getProperty("LinearShuntCompensator.gPerSection") orelse return error.MalformedXML),
                .max_section_count = try std.fmt.parseInt(u32, try linear_shunt_compensator.getProperty("ShuntCompensator.maximumSections") orelse return error.MalformedXML, 10),
            };

            const node_index = try self.getNodeIndex(voltage_level_id, connectivity_node_id);
            try voltage_level.shunts.append(self.gpa, .{
                .id = id,
                .name = name,
                .section_count = 0,
                .voltage_regulator_on = false,
                .node = node_index,
                .shunt_linear_model = shunt_linear_model,
            });
        }
    }

    fn convertVsConverters(self: *Converter, network: *iidm.Network) !void {
        const vs_converters = try self.model.getObjectsByType(self.gpa, "VsConverter");
        defer self.gpa.free(vs_converters);

        for (vs_converters) |vs_converter| {
            const connectivity_node_id = self.topology_resolver.getEquipmentNode(vs_converter.id, 1) orelse return error.MalformedXML;
            const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;
            const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id = topology.stripHash(voltage_level_ref);

            const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;

            const id = try vs_converter.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(vs_converter.id);
            const name = try vs_converter.getProperty("IdentifiedObject.name");

            const voltage_regulator_on = if (try vs_converter.getProperty("RegulatingCondEq.controlEnabled")) |v|
                std.mem.eql(u8, v, "true")
            else
                false;

            const loss_factor = if (try vs_converter.getProperty("ACDCConverter.idleLoss")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                0.0;

            var curve_points: std.ArrayListUnmanaged(iidm.ReactiveCapabilityCurvePoint) = .empty;
            errdefer curve_points.deinit(self.gpa);

            if (try vs_converter.getReference("VsConverter.CapabilityCurve")) |curve_ref| {
                curve_points = try self.getCurvePoints(topology.stripHash(curve_ref));
            }

            const node_index = try self.getNodeIndex(voltage_level_id, connectivity_node_id);

            try voltage_level.vs_converter_stations.append(self.gpa, .{
                .id = id,
                .name = name,
                .voltage_regulator_on = voltage_regulator_on,
                .loss_factor = loss_factor,
                .node = node_index,
                .reactive_power_setpoint = 0,
                .reactive_capability_curve_points = curve_points,
            });
        }
    }

    fn convertCsConverters(self: *Converter, network: *iidm.Network) !void {
        const cs_converters = try self.model.getObjectsByType(self.gpa, "CsConverter");
        defer self.gpa.free(cs_converters);

        for (cs_converters) |cs_converter| {
            const connectivity_node_id = self.topology_resolver.getEquipmentNode(cs_converter.id, 1) orelse return error.MalformedXML;
            const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;
            const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id = topology.stripHash(voltage_level_ref);

            const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;

            const id = try cs_converter.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(cs_converter.id);
            const name = try cs_converter.getProperty("IdentifiedObject.name");

            const loss_factor = if (try cs_converter.getProperty("ACDCConverter.idleLoss")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                0.0;

            // Power factor defaults to 0.8 for LCC converters (typical value)
            const power_factor = if (try cs_converter.getProperty("CsConverter.ratedPowerFactor")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                0.8;

            const node_index = try self.getNodeIndex(voltage_level_id, connectivity_node_id);

            try voltage_level.lcc_converter_stations.append(self.gpa, .{
                .id = id,
                .name = name,
                .loss_factor = loss_factor,
                .power_factor = power_factor,
                .node = node_index,
            });
        }
    }

    fn mapEnergySource(type_name: []const u8) iidm.EnergySource {
        if (std.mem.eql(u8, type_name, "HydroGeneratingUnit")) return .hydro;
        if (std.mem.eql(u8, type_name, "ThermalGeneratingUnit")) return .thermal;
        if (std.mem.eql(u8, type_name, "WindGeneratingUnit")) return .wind;
        if (std.mem.eql(u8, type_name, "SolarGeneratingUnit")) return .solar;
        if (std.mem.eql(u8, type_name, "NuclearGeneratingUnit")) return .nuclear;
        return .other;
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

            const id = try generator.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(generator.id);
            const name = try generator.getProperty("IdentifiedObject.name");
            const energy_source = mapEnergySource(generating_unit.type_name);

            // minOperatingP and maxOperatingP may be optional
            const min_p = if (try generating_unit.getProperty("GeneratingUnit.minOperatingP")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                null;
            const max_p = if (try generating_unit.getProperty("GeneratingUnit.maxOperatingP")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                null;
            const rated_s = if (try generator.getProperty("RotatingMachine.ratedS")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                null;

            // controlEnabled is in SSH profile, default false for EQ-only
            const voltage_regulator_on = if (try generator.getProperty("RegulatingCondEq.controlEnabled")) |v|
                std.mem.eql(u8, v, "true")
            else
                false;

            // initialP is often in SSH, not EQ
            const target_p = if (try generating_unit.getProperty("GeneratingUnit.initialP")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                0.0;

            // Reactive capability curve
            var curve_points: std.ArrayListUnmanaged(iidm.ReactiveCapabilityCurvePoint) = .empty;
            errdefer curve_points.deinit(self.gpa);

            if (try generator.getReference("SynchronousMachine.InitialReactiveCapabilityCurve")) |curve_ref| {
                curve_points = try self.getCurvePoints(topology.stripHash(curve_ref));
            }

            const node_index = try self.getNodeIndex(voltage_level_id, connectivity_node_id);

            try voltage_level.generators.append(self.gpa, .{
                .id = id,
                .name = name,
                .energy_source = energy_source,
                .min_p = min_p,
                .max_p = max_p,
                .rated_s = rated_s,
                .voltage_regulator_on = voltage_regulator_on,
                .node = node_index,
                .target_p = target_p,
                .target_q = 0,
                .reactive_capability_curve_points = curve_points,
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
                    .retained = mapping.kind == .breaker, // only breakers retained in bus/breaker topology
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
            const connectivity_node_id = self.topology_resolver.getEquipmentNode(busbar_section.id, 1) orelse return error.MalformedXML;
            const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;

            const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id = topology.stripHash(voltage_level_ref);
            const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;

            const id = try busbar_section.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(busbar_section.id);
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
        const EndArray = struct { ends: [3]?cim_model.CimObject = .{ null, null, null } };

        const transformers = try self.model.getObjectsByType(self.gpa, "PowerTransformer");
        defer self.gpa.free(transformers);

        const power_transformer_ends = try self.model.getObjectsByType(self.gpa, "PowerTransformerEnd");
        defer self.gpa.free(power_transformer_ends);

        const ratio_tap_changers = try self.model.getObjectsByType(self.gpa, "RatioTapChanger");
        defer self.gpa.free(ratio_tap_changers);

        const phase_tap_changers = try self.model.getObjectsByType(self.gpa, "PhaseTapChangerTabular");
        defer self.gpa.free(phase_tap_changers);

        const table_points = try self.model.getObjectsByType(self.gpa, "RatioTapChangerTablePoint");
        defer self.gpa.free(table_points);

        const phase_table_points = try self.model.getObjectsByType(self.gpa, "PhaseTapChangerTablePoint");
        defer self.gpa.free(phase_table_points);

        var ends_map: std.StringHashMapUnmanaged(EndArray) = .empty;
        defer ends_map.deinit(self.gpa);

        var ratio_tap_changer_map: std.StringHashMapUnmanaged(cim_model.CimObject) = .empty;
        defer ratio_tap_changer_map.deinit(self.gpa);
        try ratio_tap_changer_map.ensureTotalCapacity(self.gpa, @intCast(ratio_tap_changers.len));

        var phase_tap_changer_map: std.StringHashMapUnmanaged(cim_model.CimObject) = .empty;
        defer phase_tap_changer_map.deinit(self.gpa);
        try phase_tap_changer_map.ensureTotalCapacity(self.gpa, @intCast(phase_tap_changers.len));

        var table_points_map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(iidm.RatioTapChangerStep)) = .empty;
        defer {
            var it = table_points_map.valueIterator();
            while (it.next()) |list| list.deinit(self.gpa);
            table_points_map.deinit(self.gpa);
        }

        var phase_table_points_map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(iidm.PhaseTapChangerStep)) = .empty;
        defer {
            var it = phase_table_points_map.valueIterator();
            while (it.next()) |list| list.deinit(self.gpa);
            phase_table_points_map.deinit(self.gpa);
        }

        const op_lim_sets = try self.model.getObjectsByType(self.gpa, "OperationalLimitSet");
        defer self.gpa.free(op_lim_sets);

        var terminal_to_limit_set_map: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer terminal_to_limit_set_map.deinit(self.gpa);
        try terminal_to_limit_set_map.ensureTotalCapacity(self.gpa, @intCast(op_lim_sets.len));

        for (op_lim_sets) |op_lim_set| {
            const terminal_ref = try op_lim_set.getReference("OperationalLimitSet.Terminal") orelse continue;
            const terminal_id = topology.stripHash(terminal_ref);
            terminal_to_limit_set_map.putAssumeCapacity(terminal_id, op_lim_set.id);
        }

        // Build set of PATL (permanent) limit type IDs
        const limit_types = try self.model.getObjectsByType(self.gpa, "OperationalLimitType");
        defer self.gpa.free(limit_types);

        var patl_type_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer patl_type_ids.deinit(self.gpa);

        for (limit_types) |limit_type| {
            // Check if this is a PATL type (infinite duration = permanent limit)
            const is_infinite = try limit_type.getProperty("OperationalLimitType.isInfiniteDuration") orelse "false";
            if (std.mem.eql(u8, is_infinite, "true")) {
                try patl_type_ids.put(self.gpa, limit_type.id, {});
            }
        }

        // Operational limits: OperationalLimitSet ID → permanent limit value (PATL only)
        const current_limits = try self.model.getObjectsByType(self.gpa, "CurrentLimit");
        defer self.gpa.free(current_limits);

        var limit_set_to_value_map: std.StringHashMapUnmanaged(f64) = .empty;
        defer limit_set_to_value_map.deinit(self.gpa);
        try limit_set_to_value_map.ensureTotalCapacity(self.gpa, @intCast(current_limits.len));

        for (current_limits) |current_limit| {
            // Only use PATL (permanent) limits
            const type_ref = try current_limit.getReference("OperationalLimit.OperationalLimitType") orelse continue;
            const type_id = topology.stripHash(type_ref);
            if (!patl_type_ids.contains(type_id)) continue;

            const set_ref = try current_limit.getReference("OperationalLimit.OperationalLimitSet") orelse continue;
            const set_id = topology.stripHash(set_ref);
            const value_str = try current_limit.getProperty("CurrentLimit.normalValue") orelse continue;
            const value = try std.fmt.parseFloat(f64, value_str);
            limit_set_to_value_map.putAssumeCapacity(set_id, value);
        }

        for (ratio_tap_changers) |ratio_tap_changer| {
            const transformer_end_ref = try ratio_tap_changer.getReference("RatioTapChanger.TransformerEnd") orelse return error.MalformedXML;
            const transformer_end_id = topology.stripHash(transformer_end_ref);

            ratio_tap_changer_map.putAssumeCapacity(transformer_end_id, ratio_tap_changer);
        }

        for (table_points) |table_point| {
            const table_ref = try table_point.getReference("RatioTapChangerTablePoint.RatioTapChangerTable") orelse continue;
            const table_id = topology.stripHash(table_ref);

            // Properties inherited from TapChangerTablePoint base class
            const r = if (try table_point.getProperty("TapChangerTablePoint.r")) |r_str| try std.fmt.parseFloat(f64, r_str) else 0.0;
            const x = if (try table_point.getProperty("TapChangerTablePoint.x")) |x_str| try std.fmt.parseFloat(f64, x_str) else 0.0;
            const g = if (try table_point.getProperty("TapChangerTablePoint.g")) |g_str| try std.fmt.parseFloat(f64, g_str) else 0.0;
            const b = if (try table_point.getProperty("TapChangerTablePoint.b")) |b_str| try std.fmt.parseFloat(f64, b_str) else 0.0;
            const cgmes_ratio = try std.fmt.parseFloat(f64, try table_point.getProperty("TapChangerTablePoint.ratio") orelse continue);
            // IIDM uses inverse of CGMES ratio convention
            const rho = if (cgmes_ratio != 0) 1.0 / cgmes_ratio else 1.0;

            const gop = try table_points_map.getOrPut(self.gpa, table_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.gpa, .{
                .r = r,
                .x = x,
                .g = g,
                .b = b,
                .rho = rho,
            });
        }

        for (phase_tap_changers) |phase_tap_changer| {
            const transformer_end_ref = try phase_tap_changer.getReference("PhaseTapChanger.TransformerEnd") orelse return error.MalformedXML;
            const transformer_end_id = topology.stripHash(transformer_end_ref);

            phase_tap_changer_map.putAssumeCapacity(transformer_end_id, phase_tap_changer);
        }

        for (phase_table_points) |table_point| {
            const table_ref = try table_point.getReference("PhaseTapChangerTablePoint.PhaseTapChangerTable") orelse continue;
            const table_id = topology.stripHash(table_ref);

            const r = if (try table_point.getProperty("TapChangerTablePoint.r")) |r_str| try std.fmt.parseFloat(f64, r_str) else 0.0;
            const x = if (try table_point.getProperty("TapChangerTablePoint.x")) |x_str| try std.fmt.parseFloat(f64, x_str) else 0.0;
            const g = if (try table_point.getProperty("TapChangerTablePoint.g")) |g_str| try std.fmt.parseFloat(f64, g_str) else 0.0;
            const b = if (try table_point.getProperty("TapChangerTablePoint.b")) |b_str| try std.fmt.parseFloat(f64, b_str) else 0.0;
            const cgmes_ratio = try std.fmt.parseFloat(f64, try table_point.getProperty("TapChangerTablePoint.ratio") orelse continue);
            // IIDM uses inverse of CGMES ratio convention
            const rho = if (cgmes_ratio != 0) 1.0 / cgmes_ratio else 1.0;
            const alpha = if (try table_point.getProperty("PhaseTapChangerTablePoint.angle")) |alpha_str| try std.fmt.parseFloat(f64, alpha_str) else 0.0;

            const gop = try phase_table_points_map.getOrPut(self.gpa, table_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.gpa, .{
                .r = r,
                .x = x,
                .g = g,
                .b = b,
                .rho = rho,
                .alpha = alpha,
            });
        }

        for (power_transformer_ends) |end| {
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

            const id = try transformer.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(transformer.id);
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
                    .id = id,
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

                // ratedS from first end (if present)
                const rated_s = if (try end1.getProperty("PowerTransformerEnd.ratedS")) |rated_s_str|
                    try std.fmt.parseFloat(f64, rated_s_str)
                else
                    null;

                // Get voltage level ID and node index for side 2
                const connectivity_node2 = self.model.getObjectById(connectivity_node2_id) orelse return error.MalformedXML;
                const voltage_level2_ref = try connectivity_node2.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
                const voltage_level2_id = topology.stripHash(voltage_level2_ref);

                // Get IIDM voltage level IDs (use mRID if available)
                const vl1 = self.getVoltageLevel(network, voltage_level1_id) orelse return error.MalformedXML;
                const vl2 = self.getVoltageLevel(network, voltage_level2_id) orelse return error.MalformedXML;

                const node1_index = try self.getNodeIndex(voltage_level1_id, connectivity_node1_id);
                const node2_index = try self.getNodeIndex(voltage_level2_id, connectivity_node2_id);

                // Build ratio tap changer if present on end1
                const ratio_tap_changer = try self.buildRatioTapChanger(end1.id, &ratio_tap_changer_map, &table_points_map);

                // Build phase tap changer if present on end1
                const phase_tap_changer = try self.buildPhaseTapChanger(end1.id, &phase_tap_changer_map, &phase_table_points_map);

                // Build operational limits from terminal references
                const terminal1_ref = try end1.getReference("TransformerEnd.Terminal") orelse return error.MalformedXML;
                const terminal1_id = topology.stripHash(terminal1_ref);
                const terminal2_ref = try end2.getReference("TransformerEnd.Terminal") orelse return error.MalformedXML;
                const terminal2_id = topology.stripHash(terminal2_ref);

                var op_lims_1 = try self.buildOperationalLimitsGroups(terminal1_id, &terminal_to_limit_set_map, &limit_set_to_value_map);
                errdefer op_lims_1.deinit(self.gpa);
                const op_lims_2 = try self.buildOperationalLimitsGroups(terminal2_id, &terminal_to_limit_set_map, &limit_set_to_value_map);

                try substation.two_winding_transformers.append(self.gpa, .{
                    .id = id,
                    .name = name,
                    .r = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.r") orelse return error.MalformedXML) * ratio_sq,
                    .x = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.x") orelse return error.MalformedXML) * ratio_sq,
                    .g = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.g") orelse return error.MalformedXML) / ratio_sq,
                    .b = try std.fmt.parseFloat(f64, try end1.getProperty("PowerTransformerEnd.b") orelse return error.MalformedXML) / ratio_sq,
                    .rated_u1 = rated_u1,
                    .rated_u2 = rated_u2,
                    .rated_s = rated_s,
                    .voltage_level_id1 = vl1.id,
                    .node1 = node1_index,
                    .voltage_level_id2 = vl2.id,
                    .node2 = node2_index,
                    .ratio_tap_changer = ratio_tap_changer,
                    .phase_tap_changer = phase_tap_changer,
                    .op_lims_groups_1 = op_lims_1,
                    .op_lims_groups_2 = op_lims_2,
                });
            }
        }
    }

    fn buildRatioTapChanger(
        self: *Converter,
        end_id: []const u8,
        tap_changer_map: *const std.StringHashMapUnmanaged(cim_model.CimObject),
        points_map: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged(iidm.RatioTapChangerStep)),
    ) !?iidm.RatioTapChanger {
        const rtc_obj = tap_changer_map.get(end_id) orelse return null;

        const low_step = try std.fmt.parseInt(i32, try rtc_obj.getProperty("TapChanger.lowStep") orelse return error.MalformedXML, 10);
        const normal_step = try std.fmt.parseInt(i32, try rtc_obj.getProperty("TapChanger.normalStep") orelse return error.MalformedXML, 10);
        const ltc_flag_str = try rtc_obj.getProperty("TapChanger.ltcFlag") orelse "false";
        const ltc_flag = std.mem.eql(u8, ltc_flag_str, "true");

        var steps: std.ArrayListUnmanaged(iidm.RatioTapChangerStep) = .empty;
        errdefer steps.deinit(self.gpa);

        if (try rtc_obj.getReference("RatioTapChanger.RatioTapChangerTable")) |table_ref| {
            const table_id = topology.stripHash(table_ref);
            if (points_map.get(table_id)) |points| {
                try steps.appendSlice(self.gpa, points.items);
            }
        }

        return .{
            .low_tap_position = low_step,
            .tap_position = normal_step,
            .load_tap_changing_capabilities = ltc_flag,
            .regulating = false,
            .steps = steps,
        };
    }

    fn buildPhaseTapChanger(
        self: *Converter,
        end_id: []const u8,
        tap_changer_map: *const std.StringHashMapUnmanaged(cim_model.CimObject),
        points_map: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged(iidm.PhaseTapChangerStep)),
    ) !?iidm.PhaseTapChanger {
        const ptc_obj = tap_changer_map.get(end_id) orelse return null;

        const low_step = try std.fmt.parseInt(i32, try ptc_obj.getProperty("TapChanger.lowStep") orelse return error.MalformedXML, 10);
        const normal_step = try std.fmt.parseInt(i32, try ptc_obj.getProperty("TapChanger.normalStep") orelse return error.MalformedXML, 10);
        const ltc_flag_str = try ptc_obj.getProperty("TapChanger.ltcFlag") orelse "false";
        const ltc_flag = std.mem.eql(u8, ltc_flag_str, "true");

        var steps: std.ArrayListUnmanaged(iidm.PhaseTapChangerStep) = .empty;
        errdefer steps.deinit(self.gpa);

        if (try ptc_obj.getReference("PhaseTapChangerTabular.PhaseTapChangerTable")) |table_ref| {
            const table_id = topology.stripHash(table_ref);
            if (points_map.get(table_id)) |points| {
                try steps.appendSlice(self.gpa, points.items);
            }
        }

        return .{
            .low_tap_position = low_step,
            .tap_position = normal_step,
            .load_tap_changing_capabilities = ltc_flag,
            .regulating = false,
            .steps = steps,
        };
    }

    fn buildOperationalLimitsGroups(
        self: *Converter,
        terminal_id: []const u8,
        terminal_to_set_map: *const std.StringHashMapUnmanaged([]const u8),
        set_to_value_map: *const std.StringHashMapUnmanaged(f64),
    ) !std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) {
        var groups: std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) = .empty;
        errdefer groups.deinit(self.gpa);

        if (terminal_to_set_map.get(terminal_id)) |set_id| {
            const current_limits: ?iidm.CurrentLimits = if (set_to_value_map.get(set_id)) |value|
                .{ .permanent_limit = value }
            else
                null;

            try groups.append(self.gpa, .{
                .id = set_id,
                .current_limits = current_limits,
            });
        }

        return groups;
    }

    fn convertLines(self: *Converter, network: *iidm.Network) !void {
        const lines = try self.model.getObjectsByType(self.gpa, "ACLineSegment");
        defer self.gpa.free(lines);

        // Build terminal lookup: equipment_id -> (terminal1_id, terminal2_id)
        const terminals = try self.model.getObjectsByType(self.gpa, "Terminal");
        defer self.gpa.free(terminals);

        const TerminalPair = struct { t1: ?[]const u8 = null, t2: ?[]const u8 = null };
        var equipment_terminals: std.StringHashMapUnmanaged(TerminalPair) = .empty;
        defer equipment_terminals.deinit(self.gpa);

        for (terminals) |terminal| {
            const equip_ref = try terminal.getReference("Terminal.ConductingEquipment") orelse continue;
            const equip_id = topology.stripHash(equip_ref);
            const seq_str = try terminal.getProperty("ACDCTerminal.sequenceNumber") orelse continue;
            const seq = std.fmt.parseInt(u32, seq_str, 10) catch continue;

            const gop = try equipment_terminals.getOrPut(self.gpa, equip_id);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            if (seq == 1) gop.value_ptr.t1 = terminal.id;
            if (seq == 2) gop.value_ptr.t2 = terminal.id;
        }

        // Operational limits: Terminal ID → OperationalLimitSet
        const op_lim_sets = try self.model.getObjectsByType(self.gpa, "OperationalLimitSet");
        defer self.gpa.free(op_lim_sets);

        var terminal_to_limit_set_map: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer terminal_to_limit_set_map.deinit(self.gpa);
        try terminal_to_limit_set_map.ensureTotalCapacity(self.gpa, @intCast(op_lim_sets.len));

        for (op_lim_sets) |op_lim_set| {
            const terminal_ref = try op_lim_set.getReference("OperationalLimitSet.Terminal") orelse continue;
            const terminal_id = topology.stripHash(terminal_ref);
            terminal_to_limit_set_map.putAssumeCapacity(terminal_id, op_lim_set.id);
        }

        // Build set of PATL (permanent) limit type IDs
        const limit_types = try self.model.getObjectsByType(self.gpa, "OperationalLimitType");
        defer self.gpa.free(limit_types);

        var patl_type_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer patl_type_ids.deinit(self.gpa);

        for (limit_types) |limit_type| {
            const is_infinite = try limit_type.getProperty("OperationalLimitType.isInfiniteDuration") orelse "false";
            if (std.mem.eql(u8, is_infinite, "true")) {
                try patl_type_ids.put(self.gpa, limit_type.id, {});
            }
        }

        // Operational limits: OperationalLimitSet ID → permanent limit value (PATL only)
        const current_limits = try self.model.getObjectsByType(self.gpa, "CurrentLimit");
        defer self.gpa.free(current_limits);

        var limit_set_to_value_map: std.StringHashMapUnmanaged(f64) = .empty;
        defer limit_set_to_value_map.deinit(self.gpa);
        try limit_set_to_value_map.ensureTotalCapacity(self.gpa, @intCast(current_limits.len));

        for (current_limits) |current_limit| {
            // Only use PATL (permanent) limits
            const type_ref = try current_limit.getReference("OperationalLimit.OperationalLimitType") orelse continue;
            const type_id = topology.stripHash(type_ref);
            if (!patl_type_ids.contains(type_id)) continue;

            const set_ref = try current_limit.getReference("OperationalLimit.OperationalLimitSet") orelse continue;
            const set_id = topology.stripHash(set_ref);
            const value_str = try current_limit.getProperty("CurrentLimit.normalValue") orelse continue;
            const value = try std.fmt.parseFloat(f64, value_str);
            limit_set_to_value_map.putAssumeCapacity(set_id, value);
        }

        try network.lines.ensureTotalCapacity(self.gpa, lines.len);

        for (lines) |line| {
            const connectivity_node1_id = self.topology_resolver.getEquipmentNode(line.id, 1) orelse return error.MalformedXML;
            const connectivity_node2_id = self.topology_resolver.getEquipmentNode(line.id, 2) orelse return error.MalformedXML;

            const id = try line.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(line.id);
            const name = try line.getProperty("IdentifiedObject.name") orelse return error.MalformedXML;
            const r = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.r") orelse return error.MalformedXML);
            const x = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.x") orelse return error.MalformedXML);
            const bch = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.bch") orelse return error.MalformedXML);
            // gch is optional in CGMES, default to 0 if not present
            const gch = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.gch") orelse "0");

            // Build operational limits from terminal references
            const term_pair = equipment_terminals.get(line.id) orelse TerminalPair{};
            var op_lims_1: std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) = .empty;
            errdefer op_lims_1.deinit(self.gpa);
            var op_lims_2: std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) = .empty;
            errdefer op_lims_2.deinit(self.gpa);

            if (term_pair.t1) |t1_id| {
                op_lims_1 = try self.buildOperationalLimitsGroups(t1_id, &terminal_to_limit_set_map, &limit_set_to_value_map);
            }
            if (term_pair.t2) |t2_id| {
                op_lims_2 = try self.buildOperationalLimitsGroups(t2_id, &terminal_to_limit_set_map, &limit_set_to_value_map);
            }

            network.lines.appendAssumeCapacity(.{
                .id = id,
                .name = name,
                .node1 = connectivity_node1_id,
                .node2 = connectivity_node2_id,
                .r = r,
                .x = x,
                .g1 = gch / 2,
                .g2 = gch / 2,
                .b1 = bch / 2,
                .b2 = bch / 2,
                .op_lims_groups_1 = op_lims_1,
                .op_lims_groups_2 = op_lims_2,
            });
        }
    }
};
