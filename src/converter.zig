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

    // Operational limits maps (built once, used by transformers and lines)
    terminal_to_limit_set_map: std.StringHashMapUnmanaged([]const u8),
    patl_type_ids: std.StringHashMapUnmanaged(void),
    tatl_type_durations: std.StringHashMapUnmanaged([]const u8), 
    limit_set_to_value_map: std.StringHashMapUnmanaged(f64),

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
            .terminal_to_limit_set_map = .empty,
            .patl_type_ids = .empty,
            .tatl_type_durations = .empty,
            .limit_set_to_value_map = .empty,
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
        self.terminal_to_limit_set_map.deinit(self.gpa);
        self.patl_type_ids.deinit(self.gpa);
        self.tatl_type_durations.deinit(self.gpa);
        self.limit_set_to_value_map.deinit(self.gpa);
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

    fn buildOperationalLimitsMaps(self: *Converter) !void {
        // Terminal ID → OperationalLimitSet ID
        const op_lim_sets = try self.model.getObjectsByType(self.gpa, "OperationalLimitSet");
        defer self.gpa.free(op_lim_sets);

        try self.terminal_to_limit_set_map.ensureTotalCapacity(self.gpa, @intCast(op_lim_sets.len));
        for (op_lim_sets) |op_lim_set| {
            const terminal_ref = try op_lim_set.getReference("OperationalLimitSet.Terminal") orelse continue;
            const terminal_id = topology.stripHash(terminal_ref);
            const set_id = try op_lim_set.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(op_lim_set.id);
            self.terminal_to_limit_set_map.putAssumeCapacity(terminal_id, set_id);
        }

        // Build set of PATL (permanent) and TATL (temporary) limit type IDs
        const limit_types = try self.model.getObjectsByType(self.gpa, "OperationalLimitType");
        defer self.gpa.free(limit_types);

        for (limit_types) |limit_type| {
            const is_infinite = try limit_type.getProperty("OperationalLimitType.isInfiniteDuration") orelse "false";
            if (std.mem.eql(u8, is_infinite, "true")) {
                try self.patl_type_ids.put(self.gpa, limit_type.id, {});
            } else {
                // TATL type - store with acceptable duration
                if (try limit_type.getProperty("OperationalLimitType.acceptableDuration")) |duration| {
                    try self.tatl_type_durations.put(self.gpa, limit_type.id, duration);
                }
            }
        }

        // OperationalLimitSet ID → permanent limit value (PATL only)
        const current_limits = try self.model.getObjectsByType(self.gpa, "CurrentLimit");
        defer self.gpa.free(current_limits);

        try self.limit_set_to_value_map.ensureTotalCapacity(self.gpa, @intCast(current_limits.len));
        for (current_limits) |current_limit| {
            const type_ref = try current_limit.getReference("OperationalLimit.OperationalLimitType") orelse continue;
            const type_id = topology.stripHash(type_ref);
            if (!self.patl_type_ids.contains(type_id)) continue;

            const set_ref = try current_limit.getReference("OperationalLimit.OperationalLimitSet") orelse continue;
            const set_id = topology.stripHash(set_ref);
            const value_str = try current_limit.getProperty("CurrentLimit.normalValue") orelse continue;
            const value = try std.fmt.parseFloat(f64, value_str);
            self.limit_set_to_value_map.putAssumeCapacity(set_id, value);
        }
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
            .hvdc_lines = .empty,
            .extensions = .empty,
        };
        errdefer network.deinit(self.gpa);

        try self.convertSubstations(&network);

        try self.convertVoltageLevels(&network);

        try self.buildCurvePointsMap();
        try self.buildOperationalLimitsMaps();

        try self.convertBusbarSections(&network);
        try self.convertSwitches(&network);
        try self.convertLoads(&network);
        try self.convertShunts(&network);
        try self.convertStaticVarCompensators(&network);
        try self.convertGenerators(&network);
        try self.convertVsConverters(&network);
        try self.convertCsConverters(&network);

        try self.convertTransformers(&network);

        try self.convertLines(&network);
        try self.convertHvdcLines(&network);
        try self.buildExtensions(&network);

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

            // Resolve geo_tags and properties from Substation.Region -> SubGeographicalRegion
            var geo_tags: std.ArrayListUnmanaged([]const u8) = .empty;
            var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
            if (try substation.getReference("Substation.Region")) |sub_region_ref| {
                if (self.model.getObjectById(topology.stripHash(sub_region_ref))) |sub_region| {
                    if (try sub_region.getProperty("IdentifiedObject.name")) |region_name| {
                        try geo_tags.append(self.gpa, region_name);
                        try properties.append(self.gpa, .{ .name = "CGMES.regionName", .value = region_name });
                    }
                    // SubGeographicalRegion ID (URL decode to convert + to space)
                    const sub_region_id_raw = try sub_region.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(sub_region.id);
                    const sub_region_id = try topology.urlDecode(self.gpa, sub_region_id_raw);
                    try properties.append(self.gpa, .{ .name = "CGMES.subRegionId", .value = sub_region_id });
                    // GeographicalRegion ID from SubGeographicalRegion.Region
                    if (try sub_region.getReference("SubGeographicalRegion.Region")) |geo_region_ref| {
                        if (self.model.getObjectById(topology.stripHash(geo_region_ref))) |geo_region| {
                            const geo_region_id_raw = try geo_region.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(geo_region.id);
                            const geo_region_id = try topology.urlDecode(self.gpa, geo_region_id_raw);
                            try properties.append(self.gpa, .{ .name = "CGMES.regionId", .value = geo_region_id });
                        }
                    }
                }
            }

            network.substations.appendAssumeCapacity(.{
                .id = id,
                .name = name,
                .country = null,
                .geo_tags = geo_tags,
                .properties = properties,
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
            const low_voltage_limit_str = try voltage_level.getProperty("VoltageLevel.lowVoltageLimit");
            const high_voltage_limit_str = try voltage_level.getProperty("VoltageLevel.highVoltageLimit");
            const low_voltage_limit: ?f64 = if (low_voltage_limit_str) |val|
                try std.fmt.parseFloat(f64, val)
            else
                null;
            const high_voltage_limit: ?f64 = if (high_voltage_limit_str) |val|
                try std.fmt.parseFloat(f64, val)
            else
                null;

            // Build properties for CGMES voltage limits (formatted with decimal point)
            var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
            if (low_voltage_limit_str) |val| {
                try properties.append(self.gpa, .{ .name = "CGMES.lowVoltageLimit", .value = try iidm.formatFloatStr(self.gpa, val) });
            }
            if (high_voltage_limit_str) |val| {
                try properties.append(self.gpa, .{ .name = "CGMES.highVoltageLimit", .value = try iidm.formatFloatStr(self.gpa, val) });
            }

            const substation_idx = self.substation_map.get(substation_id) orelse return error.MalformedXML;
            const substation = &network.substations.items[substation_idx];

            const voltage_level_idx = substation.voltage_levels.items.len;
            try substation.voltage_levels.append(self.gpa, .{
                .id = id,
                .name = name,
                .nominal_voltage = nominal_voltages.get(base_voltage_id),
                .low_voltage_limit = low_voltage_limit,
                .high_voltage_limit = high_voltage_limit,
                .properties = properties,
                .node_breaker_topology = .{ .busbar_sections = .empty, .switches = .empty },
                .generators = .empty,
                .loads = .empty,
                .shunts = .empty,
                .static_var_compensators = .empty,
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
            try self.addLoad(network, load, "EnergyConsumer");
        }

        const energy_sources = try self.model.getObjectsByType(self.gpa, "EnergySource");
        defer self.gpa.free(energy_sources);

        for (energy_sources) |load| {
            try self.addLoad(network, load, "EnergySource");
        }
    }

    fn addLoad(self: *Converter, network: *iidm.Network, load: cim_model.CimObject, original_class: []const u8) !void {
        const connectivity_node_id = self.topology_resolver.getEquipmentNode(load.id, 1) orelse return error.MalformedXML;
        const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;

        const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
        const voltage_level_id = topology.stripHash(voltage_level_ref);
        const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;

        const id = try load.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(load.id);
        const name = try load.getProperty("IdentifiedObject.name");

        const node_index = try self.getNodeIndex(voltage_level_id, connectivity_node_id);

        // Build aliases from terminal ID
        var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
        if (self.topology_resolver.getEquipmentTerminals(load.id)) |term_infos| {
            for (term_infos) |info| {
                if (self.model.getObjectById(info.id)) |terminal| {
                    const terminal_mrid = try terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(terminal.id);
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal1", .content = terminal_mrid });
                }
            }
        }

        // Build properties (pFixed, originalClass, qFixed)
        var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
        const p_fixed = try load.getProperty("EnergyConsumer.pFixed") orelse "0.0";
        const q_fixed = try load.getProperty("EnergyConsumer.qFixed") orelse "0.0";
        try properties.append(self.gpa, .{ .name = "CGMES.pFixed", .value = try iidm.formatFloatStr(self.gpa, p_fixed) });
        try properties.append(self.gpa, .{ .name = "CGMES.originalClass", .value = original_class });
        try properties.append(self.gpa, .{ .name = "CGMES.qFixed", .value = try iidm.formatFloatStr(self.gpa, q_fixed) });

        try voltage_level.loads.append(self.gpa, .{
            .id = id,
            .name = name,
            .load_type = .other,
            .node = node_index,
            .aliases = aliases,
            .properties = properties,
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

            var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
            if (self.topology_resolver.getEquipmentTerminals(linear_shunt_compensator.id)) |term_infos| {
                for (term_infos) |info| {
                    if (self.model.getObjectById(info.id)) |terminal| {
                        const terminal_mrid = try terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(terminal.id);
                        try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal1", .content = terminal_mrid });
                    }
                }
            }

            var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
            const normal_sections = try linear_shunt_compensator.getProperty("ShuntCompensator.normalSections") orelse "0";
            try properties.append(self.gpa, .{ .name = "CGMES.normalSections", .value = normal_sections });

            try voltage_level.shunts.append(self.gpa, .{
                .id = id,
                .name = name,
                .section_count = 0,
                .voltage_regulator_on = false,
                .node = node_index,
                .shunt_linear_model = shunt_linear_model,
                .aliases = aliases,
                .properties = properties,
            });
        }
    }

    fn convertStaticVarCompensators(self: *Converter, network: *iidm.Network) !void {
        const svcs = try self.model.getObjectsByType(self.gpa, "StaticVarCompensator");
        defer self.gpa.free(svcs);

        for (svcs) |svc| {
            const id = try svc.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(svc.id);
            const name = try svc.getProperty("IdentifiedObject.name");
            const connectivity_node_id = self.topology_resolver.getEquipmentNode(svc.id, 1) orelse return error.MalformedXML;
            const connectivity_node = self.model.getObjectById(connectivity_node_id) orelse return error.MalformedXML;

            const voltage_level_ref = try connectivity_node.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id = topology.stripHash(voltage_level_ref);
            const voltage_level = self.getVoltageLevel(network, voltage_level_id) orelse return error.MalformedXML;

            // Get nominal voltage for susceptance calculation
            const nominal_v = voltage_level.nominal_voltage orelse 1.0;

            // Get susceptance limits: convert from Mvar to susceptance (S)
            // b = Q / V where Q is in Mvar and V is in kV
            const inductive_rating = if (try svc.getProperty("StaticVarCompensator.inductiveRating")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                0.0;
            const capacitive_rating = if (try svc.getProperty("StaticVarCompensator.capacitiveRating")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                0.0;
            const b_min = inductive_rating / nominal_v;
            const b_max = capacitive_rating / nominal_v;

            // Get regulation mode
            const control_mode_ref = try svc.getReference("StaticVarCompensator.sVCControlMode");
            const regulation_mode: iidm.SvcRegulationMode = if (control_mode_ref) |mode_ref| blk: {
                const mode_str = mode_ref;
                if (std.mem.indexOf(u8, mode_str, "reactivePower") != null) {
                    break :blk .reactive_power;
                } else if (std.mem.indexOf(u8, mode_str, "voltage") != null) {
                    break :blk .voltage;
                } else {
                    break :blk .off;
                }
            } else .off;

            // Get regulating status
            const regulating = if (try svc.getProperty("RegulatingCondEq.controlEnabled")) |v|
                std.mem.eql(u8, v, "true")
            else
                false;

            const node_index = try self.getNodeIndex(voltage_level_id, connectivity_node_id);

            var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
            if (self.topology_resolver.getEquipmentTerminals(svc.id)) |term_infos| {
                for (term_infos) |info| {
                    if (self.model.getObjectById(info.id)) |terminal| {
                        const terminal_mrid = try terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(terminal.id);
                        try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal1", .content = terminal_mrid });
                    }
                }
            }

            var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
            var voltage_setpoint: ?[]const u8 = null;
            if (try svc.getReference("RegulatingCondEq.RegulatingControl")) |reg_control_ref| {
                const reg_control_id = topology.stripHash(reg_control_ref);
                if (self.model.getObjectById(reg_control_id)) |reg_control| {
                    const rc_mrid = try reg_control.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(reg_control.id);
                    try properties.append(self.gpa, .{ .name = "CGMES.RegulatingControl", .value = rc_mrid });
                    // Get voltage set point from regulating control
                    voltage_setpoint = try reg_control.getProperty("RegulatingControl.targetValue");
                }
            }
            // Also try direct property on SVC if not found in RegulatingControl
            if (voltage_setpoint == null) {
                voltage_setpoint = try svc.getProperty("StaticVarCompensator.voltageSetPoint");
            }
            if (voltage_setpoint) |target_value| {
                try properties.append(self.gpa, .{ .name = "CGMES.svcEquipmentVoltageSetPoint", .value = iidm.formatFloatStr(self.gpa, target_value) catch target_value });
            }

            try voltage_level.static_var_compensators.append(self.gpa, .{
                .id = id,
                .name = name,
                .b_min = b_min,
                .b_max = b_max,
                .regulation_mode = regulation_mode,
                .regulating = regulating,
                .node = node_index,
                .aliases = aliases,
                .properties = properties,
            });
        }
    }

    fn convertVsConverters(self: *Converter, network: *iidm.Network) !void {
        // Build DC terminal lookup: converter_id -> list of DC terminals
        const dc_terminals = try self.model.getObjectsByType(self.gpa, "ACDCConverterDCTerminal");
        defer self.gpa.free(dc_terminals);

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

            // Build aliases: AC terminal first
            var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
            if (self.topology_resolver.getEquipmentTerminals(vs_converter.id)) |term_infos| {
                for (term_infos) |info| {
                    if (self.model.getObjectById(info.id)) |terminal| {
                        const terminal_mrid = try terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(terminal.id);
                        try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal1", .content = terminal_mrid });
                    }
                }
            }
            // DC terminals (DCTerminal2 first, then DCTerminal1)
            for (dc_terminals) |dc_terminal| {
                const converter_ref = try dc_terminal.getReference("ACDCConverterDCTerminal.DCConductingEquipment") orelse continue;
                if (!std.mem.eql(u8, topology.stripHash(converter_ref), vs_converter.id)) continue;
                const dc_terminal_mrid = try dc_terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(dc_terminal.id);
                if (std.mem.endsWith(u8, dc_terminal_mrid, "_2")) {
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.DCTerminal2", .content = dc_terminal_mrid });
                }
            }
            for (dc_terminals) |dc_terminal| {
                const converter_ref = try dc_terminal.getReference("ACDCConverterDCTerminal.DCConductingEquipment") orelse continue;
                if (!std.mem.eql(u8, topology.stripHash(converter_ref), vs_converter.id)) continue;
                const dc_terminal_mrid = try dc_terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(dc_terminal.id);
                if (!std.mem.endsWith(u8, dc_terminal_mrid, "_2")) {
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.DCTerminal1", .content = dc_terminal_mrid });
                }
            }

            var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
            try properties.append(self.gpa, .{ .name = "CGMES.terminalSign", .value = "1" });

            // When no capability curve, use unbounded min/max reactive limits
            const min_max_limits: ?iidm.MinMaxReactiveLimits = if (curve_points.items.len == 0)
                .{ .min_q = -std.math.floatMax(f64), .max_q = std.math.floatMax(f64) }
            else
                null;

            try voltage_level.vs_converter_stations.append(self.gpa, .{
                .id = id,
                .name = name,
                .voltage_regulator_on = voltage_regulator_on,
                .loss_factor = loss_factor,
                .node = node_index,
                .reactive_power_setpoint = 0,
                .reactive_capability_curve_points = curve_points,
                .min_max_reactive_limits = min_max_limits,
                .aliases = aliases,
                .properties = properties,
            });
        }
    }

    fn convertCsConverters(self: *Converter, network: *iidm.Network) !void {
        const dc_terminals = try self.model.getObjectsByType(self.gpa, "ACDCConverterDCTerminal");
        defer self.gpa.free(dc_terminals);

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

            // Build aliases: DCTerminal2, DCTerminal1, then Terminal1 (AC)
            var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
            // DC terminals first (DCTerminal2, then DCTerminal1)
            for (dc_terminals) |dc_terminal| {
                const converter_ref = try dc_terminal.getReference("ACDCConverterDCTerminal.DCConductingEquipment") orelse continue;
                if (!std.mem.eql(u8, topology.stripHash(converter_ref), cs_converter.id)) continue;
                const dc_terminal_mrid = try dc_terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(dc_terminal.id);
                if (std.mem.endsWith(u8, dc_terminal_mrid, "_2")) {
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.DCTerminal2", .content = dc_terminal_mrid });
                }
            }
            for (dc_terminals) |dc_terminal| {
                const converter_ref = try dc_terminal.getReference("ACDCConverterDCTerminal.DCConductingEquipment") orelse continue;
                if (!std.mem.eql(u8, topology.stripHash(converter_ref), cs_converter.id)) continue;
                const dc_terminal_mrid = try dc_terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(dc_terminal.id);
                if (!std.mem.endsWith(u8, dc_terminal_mrid, "_2")) {
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.DCTerminal1", .content = dc_terminal_mrid });
                }
            }
            // AC terminal last
            if (self.topology_resolver.getEquipmentTerminals(cs_converter.id)) |term_infos| {
                for (term_infos) |info| {
                    if (self.model.getObjectById(info.id)) |terminal| {
                        const terminal_mrid = try terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(terminal.id);
                        try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal1", .content = terminal_mrid });
                    }
                }
            }

            try voltage_level.lcc_converter_stations.append(self.gpa, .{
                .id = id,
                .name = name,
                .loss_factor = loss_factor,
                .power_factor = power_factor,
                .node = node_index,
                .aliases = aliases,
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

            // Reactive capability curve
            var curve_points: std.ArrayListUnmanaged(iidm.ReactiveCapabilityCurvePoint) = .empty;
            errdefer curve_points.deinit(self.gpa);

            if (try generator.getReference("SynchronousMachine.InitialReactiveCapabilityCurve")) |curve_ref| {
                curve_points = try self.getCurvePoints(topology.stripHash(curve_ref));
            }

            const node_index = try self.getNodeIndex(voltage_level_id, connectivity_node_id);

            var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
            if (self.topology_resolver.getEquipmentTerminals(generator.id)) |term_infos| {
                for (term_infos) |info| {
                    if (self.model.getObjectById(info.id)) |terminal| {
                        const terminal_mrid = try terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(terminal.id);
                        try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal1", .content = terminal_mrid });
                    }
                }
            }

            var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
            // SynchronousMachine.type - try as reference first, then property
            // Extract enum value after last dot (e.g., "generator" from "...#SynchronousMachineKind.generator")
            const sm_type_raw = try generator.getReference("SynchronousMachine.type") orelse
                try generator.getProperty("SynchronousMachine.type");
            if (sm_type_raw) |sm_type| {
                const sm_type_value = if (std.mem.lastIndexOfScalar(u8, sm_type, '.')) |dot_idx|
                    sm_type[dot_idx + 1 ..]
                else
                    sm_type;
                try properties.append(self.gpa, .{ .name = "CGMES.synchronousMachineType", .value = sm_type_value });
            }
            // RegulatingControl.mode - keep full URL
            if (try generator.getReference("RegulatingCondEq.RegulatingControl")) |rc_ref| {
                if (self.model.getObjectById(topology.stripHash(rc_ref))) |rc| {
                    // Try as reference first, then property
                    const mode = try rc.getReference("RegulatingControl.mode") orelse
                        try rc.getProperty("RegulatingControl.mode");
                    if (mode) |m| {
                        try properties.append(self.gpa, .{ .name = "CGMES.mode", .value = m });
                    }
                    const rc_id = try rc.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(rc.id);
                    try properties.append(self.gpa, .{ .name = "CGMES.originalClass", .value = "SynchronousMachine" });
                    // GeneratingUnit ID
                    const gen_unit_id = try generating_unit.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(generating_unit.id);
                    try properties.append(self.gpa, .{ .name = "CGMES.GeneratingUnit", .value = gen_unit_id });
                    try properties.append(self.gpa, .{ .name = "CGMES.RegulatingControl", .value = rc_id });
                }
            } else {
                try properties.append(self.gpa, .{ .name = "CGMES.originalClass", .value = "SynchronousMachine" });
                const gen_unit_id = try generating_unit.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(generating_unit.id);
                try properties.append(self.gpa, .{ .name = "CGMES.GeneratingUnit", .value = gen_unit_id });
            }

            try voltage_level.generators.append(self.gpa, .{
                .id = id,
                .name = name,
                .energy_source = energy_source,
                .min_p = min_p,
                .max_p = max_p,
                .rated_s = rated_s,
                .voltage_regulator_on = voltage_regulator_on,
                .node = node_index,
                .reactive_capability_curve_points = curve_points,
                .aliases = aliases,
                .properties = properties,
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

                // Build aliases from terminal IDs (Terminal2 first, then Terminal1)
                var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
                if (self.topology_resolver.getEquipmentTerminals(sw.id)) |term_infos| {
                    // First pass: add Terminal2
                    for (term_infos) |info| {
                        if (info.sequence == 2) {
                            if (self.model.getObjectById(info.id)) |terminal| {
                                const terminal_mrid = try terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(terminal.id);
                                try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal2", .content = terminal_mrid });
                            }
                        }
                    }
                    // Second pass: add Terminal1
                    for (term_infos) |info| {
                        if (info.sequence == 1) {
                            if (self.model.getObjectById(info.id)) |terminal| {
                                const terminal_mrid = try terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(terminal.id);
                                try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal1", .content = terminal_mrid });
                            }
                        }
                    }
                }

                var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
                try properties.append(self.gpa, .{ .name = "CGMES.originalClass", .value = mapping.cim_type });
                try properties.append(self.gpa, .{ .name = "CGMES.normalOpen", .value = open_str });

                try voltage_level.node_breaker_topology.switches.append(self.gpa, .{
                    .id = id,
                    .name = name,
                    .kind = mapping.kind,
                    .open = std.mem.eql(u8, open_str, "true"),
                    .retained = mapping.kind == .breaker, // only breakers retained in bus/breaker topology
                    .node1 = node1_index,
                    .node2 = node2_index,
                    .aliases = aliases,
                    .properties = properties,
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

            var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
            if (self.topology_resolver.getEquipmentTerminals(busbar_section.id)) |term_infos| {
                for (term_infos) |info| {
                    if (self.model.getObjectById(info.id)) |terminal| {
                        const terminal_mrid = try terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(terminal.id);
                        try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal1", .content = terminal_mrid });
                    }
                }
            }

            try voltage_level.node_breaker_topology.busbar_sections.append(self.gpa, .{
                .id = id,
                .name = name,
                .node = node_index,
                .aliases = aliases,
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
            // IIDM uses opposite sign convention for phase angle
            const alpha = if (try table_point.getProperty("PhaseTapChangerTablePoint.angle")) |alpha_str| -(try std.fmt.parseFloat(f64, alpha_str)) else 0.0;

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
                const ratio_tap_changer = try self.buildRatioTapChanger(end1.id, id, 1, &ratio_tap_changer_map, &table_points_map);

                // Build phase tap changer if present on end1
                const phase_tap_changer = try self.buildPhaseTapChanger(end1.id, &phase_tap_changer_map, &phase_table_points_map);

                // Build operational limits from terminal references
                const terminal1_ref = try end1.getReference("TransformerEnd.Terminal") orelse return error.MalformedXML;
                const terminal1_id = topology.stripHash(terminal1_ref);
                const terminal2_ref = try end2.getReference("TransformerEnd.Terminal") orelse return error.MalformedXML;
                const terminal2_id = topology.stripHash(terminal2_ref);

                var op_lims_1 = try self.buildOperationalLimitsGroups(terminal1_id);
                errdefer op_lims_1.deinit(self.gpa);
                const op_lims_2 = try self.buildOperationalLimitsGroups(terminal2_id);

                // Selected operational limits group IDs (first group for each side)
                const selected_op_lims_1: ?[]const u8 = if (op_lims_1.items.len > 0) op_lims_1.items[0].id else null;
                const selected_op_lims_2: ?[]const u8 = if (op_lims_2.items.len > 0) op_lims_2.items[0].id else null;

                var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
                // PhaseTapChanger1
                if (phase_tap_changer_map.get(end1.id)) |ptc| {
                    const ptc_id = try ptc.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(ptc.id);
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.PhaseTapChanger1", .content = ptc_id });
                }
                // Terminal1
                if (self.model.getObjectById(terminal1_id)) |t1| {
                    const t1_mrid = try t1.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(t1.id);
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal1", .content = t1_mrid });
                }
                // Terminal2
                if (self.model.getObjectById(terminal2_id)) |t2| {
                    const t2_mrid = try t2.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(t2.id);
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal2", .content = t2_mrid });
                }
                // RatioTapChanger1
                if (ratio_tap_changer_map.get(end1.id)) |rtc| {
                    const rtc_id = try rtc.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(rtc.id);
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.RatioTapChanger1", .content = rtc_id });
                }
                // TransformerEnd2
                const end2_id = try end2.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(end2.id);
                try aliases.append(self.gpa, .{ .@"type" = "CGMES.TransformerEnd2", .content = end2_id });
                // TransformerEnd1
                const end1_mrid = try end1.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(end1.id);
                try aliases.append(self.gpa, .{ .@"type" = "CGMES.TransformerEnd1", .content = end1_mrid });

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
                    .selected_op_lims_group_id_1 = selected_op_lims_1,
                    .selected_op_lims_group_id_2 = selected_op_lims_2,
                    .op_lims_groups_1 = op_lims_1,
                    .op_lims_groups_2 = op_lims_2,
                    .aliases = aliases,
                });
            }
        }
    }

    fn buildRatioTapChanger(
        self: *Converter,
        end_id: []const u8,
        transformer_id: []const u8,
        end_number: u32,
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

        // Terminal reference with side based on end number
        const side: []const u8 = if (end_number == 1) "ONE" else "TWO";

        return .{
            .low_tap_position = low_step,
            .tap_position = normal_step,
            .load_tap_changing_capabilities = ltc_flag,
            .regulating = false,
            .regulation_mode = "VOLTAGE",
            .terminal_ref = .{ .id = transformer_id, .side = side },
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
            .regulation_mode = "CURRENT_LIMITER",
            .steps = steps,
        };
    }

    fn buildOperationalLimitsGroups(self: *Converter, terminal_id: []const u8) !std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) {
        var groups: std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) = .empty;
        errdefer groups.deinit(self.gpa);

        // Find OperationalLimitSet for this terminal
        const op_lim_sets = try self.model.getObjectsByType(self.gpa, "OperationalLimitSet");
        defer self.gpa.free(op_lim_sets);

        for (op_lim_sets) |op_lim_set| {
            const set_terminal_ref = try op_lim_set.getReference("OperationalLimitSet.Terminal") orelse continue;
            if (!std.mem.eql(u8, topology.stripHash(set_terminal_ref), terminal_id)) continue;

            const set_id = try op_lim_set.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(op_lim_set.id);
            const set_name = try op_lim_set.getProperty("IdentifiedObject.name") orelse "DEFAULT";

            // Find CurrentLimits for this set (PATL and TATL)
            var patl_value: ?f64 = null;
            var patl_value_str: ?[]const u8 = null;
            var patl_limit_id: ?[]const u8 = null;
            var temporary_limits: std.ArrayListUnmanaged(iidm.TemporaryLimit) = .empty;

            const current_limits_objs = try self.model.getObjectsByType(self.gpa, "CurrentLimit");
            defer self.gpa.free(current_limits_objs);

            // Build properties list
            var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;

            for (current_limits_objs) |cl| {
                const cl_set_ref = try cl.getReference("OperationalLimit.OperationalLimitSet") orelse continue;
                if (!std.mem.eql(u8, topology.stripHash(cl_set_ref), op_lim_set.id)) continue;

                const type_ref = try cl.getReference("OperationalLimit.OperationalLimitType") orelse continue;
                const type_id = topology.stripHash(type_ref);

                const cl_value_str = try cl.getProperty("CurrentLimit.normalValue");
                const cl_id = try cl.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(cl.id);

                // Check if PATL type
                if (self.patl_type_ids.contains(type_id)) {
                    patl_value_str = cl_value_str;
                    if (cl_value_str) |val_str| {
                        patl_value = try std.fmt.parseFloat(f64, val_str);
                    }
                    patl_limit_id = cl_id;
                } else if (self.tatl_type_durations.get(type_id)) |duration| {
                    // TATL type - add properties with duration suffix
                    if (cl_value_str) |val| {
                        const prop_name = try std.fmt.allocPrint(self.gpa, "CGMES.normalValue_CurrentLimit_tatl_{s}", .{duration});
                        try properties.append(self.gpa, .{ .name = prop_name, .value = try iidm.formatFloatStr(self.gpa, val) });
                    }
                    const limit_prop_name = try std.fmt.allocPrint(self.gpa, "CGMES.OperationalLimit_CurrentLimit_tatl_{s}", .{duration});
                    try properties.append(self.gpa, .{ .name = limit_prop_name, .value = cl_id });

                    // Also add to temporary limits in CurrentLimits
                    if (cl_value_str) |val_str| {
                        // Get the name from the CurrentLimit object itself
                        const limit_name = try cl.getProperty("IdentifiedObject.name") orelse "TATL";
                        const duration_int = std.fmt.parseInt(u32, duration, 10) catch null;
                        // Omit acceptableDuration if it's 2147483647 (infinite)
                        const acceptable_dur: ?u32 = if (duration_int) |d| (if (d == 2147483647) null else d) else null;
                        try temporary_limits.append(self.gpa, .{
                            .name = limit_name,
                            .acceptable_duration = acceptable_dur,
                            .value = try std.fmt.parseFloat(f64, val_str),
                        });
                    }
                }
            }

            // Add PATL properties first (before TATL)
            if (patl_value_str) |val| {
                // Insert at beginning
                try properties.insert(self.gpa, 0, .{ .name = "CGMES.normalValue_CurrentLimit_patl", .value = try iidm.formatFloatStr(self.gpa, val) });
            }
            try properties.append(self.gpa, .{ .name = "CGMES.OperationalLimitSetName", .value = set_name });
            try properties.append(self.gpa, .{ .name = "CGMES.OperationalLimitSetRdfID", .value = set_id });
            if (patl_limit_id) |cl_id| {
                try properties.append(self.gpa, .{ .name = "CGMES.OperationalLimit_CurrentLimit_patl", .value = cl_id });
            }

            // Build current_limits with permanent and temporary limits
            const current_limits: ?iidm.CurrentLimits = if (patl_value) |pv| .{
                .permanent_limit = pv,
                .temporary_limits = temporary_limits,
            } else null;

            try groups.append(self.gpa, .{
                .id = set_id,
                .properties = properties,
                .current_limits = current_limits,
            });
        }

        return groups;
    }

    fn convertLines(self: *Converter, network: *iidm.Network) !void {
        const lines = try self.model.getObjectsByType(self.gpa, "ACLineSegment");
        defer self.gpa.free(lines);

        try network.lines.ensureTotalCapacity(self.gpa, lines.len);

        for (lines) |line| {
            const connectivity_node1_id = self.topology_resolver.getEquipmentNode(line.id, 1) orelse return error.MalformedXML;
            const connectivity_node2_id = self.topology_resolver.getEquipmentNode(line.id, 2) orelse return error.MalformedXML;

            // Get voltage level IDs from connectivity nodes
            const cn1 = self.model.getObjectById(connectivity_node1_id) orelse return error.MalformedXML;
            const cn2 = self.model.getObjectById(connectivity_node2_id) orelse return error.MalformedXML;
            const vl1_ref = try cn1.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const vl2_ref = try cn2.getReference("ConnectivityNode.ConnectivityNodeContainer") orelse return error.MalformedXML;
            const voltage_level_id_1 = topology.stripUnderscore(topology.stripHash(vl1_ref));
            const voltage_level_id_2 = topology.stripUnderscore(topology.stripHash(vl2_ref));

            // Get node indices
            const node1 = try self.getNodeIndex(voltage_level_id_1, connectivity_node1_id);
            const node2 = try self.getNodeIndex(voltage_level_id_2, connectivity_node2_id);

            const id = try line.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(line.id);
            const name = try line.getProperty("IdentifiedObject.name") orelse return error.MalformedXML;
            const r = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.r") orelse return error.MalformedXML);
            const x = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.x") orelse return error.MalformedXML);
            const bch = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.bch") orelse return error.MalformedXML);
            // gch is optional in CGMES, default to 0 if not present
            const gch = try std.fmt.parseFloat(f64, try line.getProperty("ACLineSegment.gch") orelse "0");

            // Get terminal IDs from topology resolver (O(1) lookup, already built)
            var t1_id: ?[]const u8 = null;
            var t2_id: ?[]const u8 = null;
            if (self.topology_resolver.getEquipmentTerminals(line.id)) |term_infos| {
                for (term_infos) |info| {
                    if (info.sequence == 1) t1_id = info.id;
                    if (info.sequence == 2) t2_id = info.id;
                }
            }

            // Build aliases from terminal IDs
            var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
            if (t1_id) |tid| {
                if (self.model.getObjectById(tid)) |terminal| {
                    const terminal_mrid = try terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(terminal.id);
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal1", .content = terminal_mrid });
                }
            }
            if (t2_id) |tid| {
                if (self.model.getObjectById(tid)) |terminal| {
                    const terminal_mrid = try terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(terminal.id);
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.Terminal2", .content = terminal_mrid });
                }
            }

            // Build properties
            var properties: std.ArrayListUnmanaged(iidm.Property) = .empty;
            try properties.append(self.gpa, .{ .name = "CGMES.originalClass", .value = "ACLineSegment" });

            // Build operational limits from terminal references
            var op_lims_1: std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) = .empty;
            errdefer op_lims_1.deinit(self.gpa);
            var op_lims_2: std.ArrayListUnmanaged(iidm.OperationalLimitsGroup) = .empty;
            errdefer op_lims_2.deinit(self.gpa);

            if (t1_id) |tid| {
                op_lims_1 = try self.buildOperationalLimitsGroups(tid);
            }
            if (t2_id) |tid| {
                op_lims_2 = try self.buildOperationalLimitsGroups(tid);
            }

            // Get selected operational limits group IDs (first one if exists)
            const selected_op_lims_1: ?[]const u8 = if (op_lims_1.items.len > 0) op_lims_1.items[0].id else null;
            const selected_op_lims_2: ?[]const u8 = if (op_lims_2.items.len > 0) op_lims_2.items[0].id else null;

            network.lines.appendAssumeCapacity(.{
                .id = id,
                .name = name,
                .voltage_level_id_1 = voltage_level_id_1,
                .node1 = node1,
                .voltage_level_id_2 = voltage_level_id_2,
                .node2 = node2,
                .r = r,
                .x = x,
                .g1 = gch / 2,
                .g2 = gch / 2,
                .b1 = bch / 2,
                .b2 = bch / 2,
                .selected_op_lims_group_id_1 = selected_op_lims_1,
                .selected_op_lims_group_id_2 = selected_op_lims_2,
                .aliases = aliases,
                .properties = properties,
                .op_lims_groups_1 = op_lims_1,
                .op_lims_groups_2 = op_lims_2,
            });
        }
    }

    fn convertHvdcLines(self: *Converter, network: *iidm.Network) !void {
        const dc_line_segments = try self.model.getObjectsByType(self.gpa, "DCLineSegment");
        defer self.gpa.free(dc_line_segments);

        const dc_terminals = try self.model.getObjectsByType(self.gpa, "DCTerminal");
        defer self.gpa.free(dc_terminals);

        const conv_dc_terminals = try self.model.getObjectsByType(self.gpa, "ACDCConverterDCTerminal");
        defer self.gpa.free(conv_dc_terminals);

        const vs_converters = try self.model.getObjectsByType(self.gpa, "VsConverter");
        defer self.gpa.free(vs_converters);

        const cs_converters = try self.model.getObjectsByType(self.gpa, "CsConverter");
        defer self.gpa.free(cs_converters);

        for (dc_line_segments) |dc_line| {
            const id = try dc_line.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(dc_line.id);
            const name = try dc_line.getProperty("IdentifiedObject.name");

            const r = if (try dc_line.getProperty("DCLineSegment.resistance")) |v|
                try std.fmt.parseFloat(f64, v)
            else
                0.0;

            var converter_station_1: ?[]const u8 = null;
            var converter_station_2: ?[]const u8 = null;
            var nominal_v: f64 = 0.0;
            var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;

            // Find DCTerminals connected to this DC line
            for (dc_terminals) |dc_terminal| {
                const equipment_ref = try dc_terminal.getReference("DCTerminal.DCConductingEquipment") orelse
                    try dc_terminal.getReference("DCBaseTerminal.DCConductingEquipment") orelse continue;
                const equipment_ref_id = topology.stripUnderscore(topology.stripHash(equipment_ref));
                const dc_line_id_stripped = topology.stripUnderscore(dc_line.id);
                if (!std.mem.eql(u8, equipment_ref_id, dc_line_id_stripped)) continue;

                const dc_node_ref = try dc_terminal.getReference("DCBaseTerminal.DCNode") orelse
                    try dc_terminal.getReference("DCBaseTerminal.DCTopologicalNode") orelse continue;
                const dc_node_id = topology.stripUnderscore(topology.stripHash(dc_node_ref));

                const terminal_mrid = try dc_terminal.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(dc_terminal.id);
                const seq_str = try dc_terminal.getProperty("ACDCTerminal.sequenceNumber") orelse "1";
                const seq = std.fmt.parseInt(u32, seq_str, 10) catch 1;

                // Find converter connected to this DC node via ACDCConverterDCTerminal
                for (conv_dc_terminals) |conv_dc_term| {
                    const conv_node_ref = try conv_dc_term.getReference("DCBaseTerminal.DCNode") orelse
                        try conv_dc_term.getReference("DCBaseTerminal.DCTopologicalNode") orelse continue;
                    const conv_node_id = topology.stripUnderscore(topology.stripHash(conv_node_ref));
                    if (!std.mem.eql(u8, conv_node_id, dc_node_id)) continue;

                    const conv_equip_ref = try conv_dc_term.getReference("ACDCConverterDCTerminal.DCConductingEquipment") orelse continue;
                    const conv_equip_id = topology.stripUnderscore(topology.stripHash(conv_equip_ref));

                    // Check VsConverters
                    for (vs_converters) |converter| {
                        const converter_id_stripped = topology.stripUnderscore(converter.id);
                        if (!std.mem.eql(u8, converter_id_stripped, conv_equip_id)) continue;
                        const conv_id = try converter.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(converter.id);
                        if (seq == 1) converter_station_1 = conv_id else converter_station_2 = conv_id;
                        if (try converter.getProperty("ACDCConverter.ratedUdc")) |v| {
                            nominal_v = try std.fmt.parseFloat(f64, v);
                        }
                    }

                    // Check CsConverters
                    for (cs_converters) |converter| {
                        const cs_converter_id_stripped = topology.stripUnderscore(converter.id);
                        if (!std.mem.eql(u8, cs_converter_id_stripped, conv_equip_id)) continue;
                        const conv_id = try converter.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(converter.id);
                        if (seq == 1) converter_station_1 = conv_id else converter_station_2 = conv_id;
                        if (try converter.getProperty("ACDCConverter.ratedUdc")) |v| {
                            nominal_v = try std.fmt.parseFloat(f64, v);
                        }
                    }
                }

                if (seq == 2) {
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.DCTerminal2", .content = terminal_mrid });
                } else {
                    try aliases.append(self.gpa, .{ .@"type" = "CGMES.DCTerminal1", .content = terminal_mrid });
                }
            }

            // Reorder aliases: DCTerminal2 first
            var reordered: std.ArrayListUnmanaged(iidm.Alias) = .empty;
            for (aliases.items) |a| {
                if (std.mem.eql(u8, a.@"type", "CGMES.DCTerminal2")) try reordered.append(self.gpa, a);
            }
            for (aliases.items) |a| {
                if (std.mem.eql(u8, a.@"type", "CGMES.DCTerminal1")) try reordered.append(self.gpa, a);
            }
            aliases.deinit(self.gpa);

            if (converter_station_1 == null or converter_station_2 == null) continue;

            try network.hvdc_lines.append(self.gpa, .{
                .id = id,
                .name = name,
                .r = r,
                .nominal_v = nominal_v,
                .converters_mode = .side_1_rectifier_side_2_inverter,
                .active_power_setpoint = 0.0,
                .max_p = 0.0,
                .converter_station_1 = converter_station_1.?,
                .converter_station_2 = converter_station_2.?,
                .aliases = reordered,
            });
        }
    }

    fn buildExtensions(self: *Converter, network: *iidm.Network) !void {
        // Build tap changer extensions for transformers
        const power_transformers = try self.model.getObjectsByType(self.gpa, "PowerTransformer");
        defer self.gpa.free(power_transformers);

        for (power_transformers) |pt| {
            const pt_id = try pt.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(pt.id);

            var tap_changers: std.ArrayListUnmanaged(iidm.TapChangerInfo) = .empty;

            // Find PhaseTapChanger for this transformer
            const phase_tap_changers = try self.model.getObjectsByType(self.gpa, "PhaseTapChangerTabular");
            defer self.gpa.free(phase_tap_changers);

            for (phase_tap_changers) |ptc| {
                const tw_ref = try ptc.getReference("PhaseTapChanger.TransformerEnd") orelse continue;
                const tw_id = topology.stripHash(tw_ref);
                // Check if this transformer end belongs to our power transformer
                if (self.model.getObjectById(tw_id)) |tw| {
                    const pt_ref = try tw.getReference("TransformerEnd.Terminal") orelse continue;
                    const terminal = self.model.getObjectById(topology.stripHash(pt_ref)) orelse continue;
                    const eq_ref = try terminal.getReference("Terminal.ConductingEquipment") orelse continue;
                    if (!std.mem.eql(u8, topology.stripHash(eq_ref), pt.id)) continue;

                    const ptc_id = try ptc.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(ptc.id);
                    const step_str = try ptc.getProperty("TapChanger.normalStep") orelse "1";
                    const step = std.fmt.parseInt(u32, step_str, 10) catch 1;

                    try tap_changers.append(self.gpa, .{
                        .id = ptc_id,
                        .tap_changer_type = "PhaseTapChangerTabular",
                        .step = step,
                        .control_id = null,
                    });
                }
            }

            // Find RatioTapChanger for this transformer
            const ratio_tap_changers = try self.model.getObjectsByType(self.gpa, "RatioTapChanger");
            defer self.gpa.free(ratio_tap_changers);

            for (ratio_tap_changers) |rtc| {
                const tw_ref = try rtc.getReference("RatioTapChanger.TransformerEnd") orelse continue;
                const tw_id = topology.stripHash(tw_ref);
                if (self.model.getObjectById(tw_id)) |tw| {
                    const pt_ref = try tw.getReference("TransformerEnd.Terminal") orelse continue;
                    const terminal = self.model.getObjectById(topology.stripHash(pt_ref)) orelse continue;
                    const eq_ref = try terminal.getReference("Terminal.ConductingEquipment") orelse continue;
                    if (!std.mem.eql(u8, topology.stripHash(eq_ref), pt.id)) continue;

                    const rtc_id = try rtc.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(rtc.id);
                    const step_str = try rtc.getProperty("TapChanger.normalStep") orelse "1";
                    const step = std.fmt.parseInt(u32, step_str, 10) catch 1;

                    var control_id: ?[]const u8 = null;
                    if (try rtc.getReference("TapChanger.TapChangerControl")) |tc_ref| {
                        const tc_id = topology.stripHash(tc_ref);
                        if (self.model.getObjectById(tc_id)) |tc| {
                            control_id = try tc.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(tc.id);
                        }
                    }

                    try tap_changers.append(self.gpa, .{
                        .id = rtc_id,
                        .tap_changer_type = null,
                        .step = step,
                        .control_id = control_id,
                    });
                }
            }

            if (tap_changers.items.len > 0) {
                try network.extensions.append(self.gpa, .{
                    .id = pt_id,
                    .cgmes_tap_changers = .{ .tap_changers = tap_changers },
                });
            }
        }

        // Build SVC extensions (voltagePerReactivePowerControl)
        const svcs = try self.model.getObjectsByType(self.gpa, "StaticVarCompensator");
        defer self.gpa.free(svcs);

        for (svcs) |svc| {
            const svc_id = try svc.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(svc.id);

            // Get slope from regulating control if available
            var slope: f64 = 0.0;
            if (try svc.getReference("RegulatingCondEq.RegulatingControl")) |rc_ref| {
                if (self.model.getObjectById(topology.stripHash(rc_ref))) |rc| {
                    if (try rc.getProperty("RegulatingControl.targetDeadband")) |v| {
                        slope = try std.fmt.parseFloat(f64, v);
                    }
                }
            }

            try network.extensions.append(self.gpa, .{
                .id = svc_id,
                .voltage_per_reactive_power_control = .{ .slope = slope },
            });
        }

        // Build metadata extension from FullModel
        const full_models = try self.model.getObjectsByType(self.gpa, "FullModel");
        defer self.gpa.free(full_models);

        if (full_models.len > 0) {
            const fm = full_models[0];
            const fm_id = fm.id;

            var profiles: std.ArrayListUnmanaged(iidm.ModelProfile) = .empty;
            // Profile can be a reference or text property
            if (try fm.getReference("Model.profile")) |profile| {
                try profiles.append(self.gpa, .{ .content = profile });
            } else if (try fm.getProperty("Model.profile")) |profile| {
                try profiles.append(self.gpa, .{ .content = profile });
            }

            var models: std.ArrayListUnmanaged(iidm.MetadataModel) = .empty;
            try models.append(self.gpa, .{
                .subset = "EQUIPMENT",
                .modeling_authority_set = try fm.getProperty("Model.modelingAuthoritySet") orelse "powsybl.org",
                .id = fm_id,
                .version = 1,
                .description = try fm.getProperty("Model.description") orelse "EQ Model",
                .profiles = profiles,
            });

            // Build base voltage mapping
            const base_voltages = try self.model.getObjectsByType(self.gpa, "BaseVoltage");
            defer self.gpa.free(base_voltages);

            var bv_list: std.ArrayListUnmanaged(iidm.BaseVoltage) = .empty;
            for (base_voltages) |bv| {
                const bv_id = try bv.getProperty("IdentifiedObject.mRID") orelse topology.stripUnderscore(bv.id);
                const nominal_v = if (try bv.getProperty("BaseVoltage.nominalVoltage")) |v|
                    try std.fmt.parseFloat(f64, v)
                else
                    0.0;

                try bv_list.append(self.gpa, .{
                    .nominal_voltage = nominal_v,
                    .source = "IGM",
                    .id = bv_id,
                });
            }

            try network.extensions.append(self.gpa, .{
                .id = fm_id,
                .cgmes_metadata_models = .{ .models = models },
                .base_voltage_mapping = .{ .base_voltages = bv_list },
                .cim_characteristics = .{
                    .topology_kind = "NODE_BREAKER",
                    .cim_version = 100,
                },
            });
        }

        // Build extension versions based on what extensions are present
        var has_tap_changers = false;
        var has_voltage_control = false;
        var has_metadata = false;
        var has_base_voltage = false;
        var has_cim_chars = false;

        for (network.extensions.items) |ext| {
            if (ext.cgmes_tap_changers != null) has_tap_changers = true;
            if (ext.voltage_per_reactive_power_control != null) has_voltage_control = true;
            if (ext.cgmes_metadata_models != null) has_metadata = true;
            if (ext.base_voltage_mapping != null) has_base_voltage = true;
            if (ext.cim_characteristics != null) has_cim_chars = true;
        }

        if (has_tap_changers) {
            try network.extension_versions.append(self.gpa, .{ .extension_name = "cgmesTapChangers" });
        }
        if (has_voltage_control) {
            try network.extension_versions.append(self.gpa, .{ .extension_name = "voltagePerReactivePowerControl" });
        }
        if (has_metadata) {
            try network.extension_versions.append(self.gpa, .{ .extension_name = "cgmesMetadataModels" });
        }
        if (has_base_voltage) {
            try network.extension_versions.append(self.gpa, .{ .extension_name = "baseVoltageMapping" });
        }
        if (has_cim_chars) {
            try network.extension_versions.append(self.gpa, .{ .extension_name = "cimCharacteristics" });
        }
    }
};
