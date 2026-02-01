const std = @import("std");

/// Write a float to JSON, ensuring at least one decimal place (e.g., 100.0 not 100)
fn writeFloat(jws: anytype, value: f64) !void {
    // Check for special values
    if (std.math.isNan(value) or std.math.isInf(value)) {
        try jws.write(null);
        return;
    }

    // Format with enough precision, then ensure decimal point
    var buf: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d}", .{value}) catch {
        try jws.write(value);
        return;
    };

    // Check if it has a decimal point
    const has_decimal = std.mem.indexOfScalar(u8, formatted, '.') != null;

    if (has_decimal) {
        try jws.print("{s}", .{formatted});
    } else {
        try jws.print("{s}.0", .{formatted});
    }
}

/// Write an optional float to JSON
fn writeOptionalFloat(jws: anytype, value: ?f64) !void {
    if (value) |v| {
        try writeFloat(jws, v);
    } else {
        try jws.write(null);
    }
}

/// Format a float string to ensure it has a decimal point (e.g., "100" -> "100.0")
/// Returns the original string if it already has a decimal, otherwise allocates a new one.
pub fn formatFloatStr(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
    // Check if it already has a decimal point
    if (std.mem.indexOfScalar(u8, str, '.') != null) {
        return str;
    }
    // Allocate new string with .0 suffix
    const result = try allocator.alloc(u8, str.len + 2);
    @memcpy(result[0..str.len], str);
    result[str.len] = '.';
    result[str.len + 1] = '0';
    return result;
}

/// Write a date string with milliseconds (e.g., "2017-06-25T16:43:00.000Z")
fn writeDateWithMillis(jws: anytype, date: ?[]const u8) !void {
    if (date) |d| {
        // Check if already has milliseconds (contains a dot before Z)
        if (std.mem.lastIndexOfScalar(u8, d, '.')) |_| {
            try jws.write(d);
        } else if (std.mem.endsWith(u8, d, "Z")) {
            // Insert .000 before the Z
            try jws.print("\"{s}.000Z\"", .{d[0 .. d.len - 1]});
        } else {
            try jws.write(d);
        }
    } else {
        try jws.write(null);
    }
}

pub const LoadType = enum {
    other,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.write(switch (self) {
            .other => "UNDEFINED",
        });
    }
};

pub const Load = struct {
    id: []const u8,
    name: ?[]const u8,
    load_type: LoadType,
    node: u32,
    aliases: std.ArrayListUnmanaged(Alias),
    properties: std.ArrayListUnmanaged(Property),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("loadType");
        try jws.write(self.load_type);
        try jws.objectField("node");
        try jws.write(self.node);
        if (self.aliases.items.len > 0) {
            try jws.objectField("aliases");
            try jws.write(self.aliases.items);
        }
        if (self.properties.items.len > 0) {
            try jws.objectField("properties");
            try jws.write(self.properties.items);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *Load, allocator: std.mem.Allocator) void {
        self.aliases.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

pub const ShuntLinearModel = struct {
    b_per_section: f64,
    g_per_section: f64,
    max_section_count: u32,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("bPerSection");
        try writeFloat(jws, self.b_per_section);
        try jws.objectField("gPerSection");
        try writeFloat(jws, self.g_per_section);
        try jws.objectField("maximumSectionCount");
        try jws.write(self.max_section_count);
        try jws.endObject();
    }
};

pub const Shunt = struct {
    id: []const u8,
    name: ?[]const u8,
    section_count: u32,
    voltage_regulator_on: bool,
    node: u32,
    shunt_linear_model: ShuntLinearModel,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("sectionCount");
        try jws.write(self.section_count);
        try jws.objectField("voltageRegulatorOn");
        try jws.write(self.voltage_regulator_on);
        try jws.objectField("node");
        try jws.write(self.node);
        try jws.objectField("shuntLinearModel");
        try jws.write(self.shunt_linear_model);
        try jws.endObject();
    }
};

pub const VsConverterStation = struct {
    id: []const u8,
    name: ?[]const u8,
    voltage_regulator_on: bool,
    loss_factor: f64,
    reactive_power_setpoint: f64,
    node: u32,
    reactive_capability_curve_points: std.ArrayListUnmanaged(ReactiveCapabilityCurvePoint),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("voltageRegulatorOn");
        try jws.write(self.voltage_regulator_on);
        try jws.objectField("lossFactor");
        try writeFloat(jws, self.loss_factor);
        try jws.objectField("reactivePowerSetpoint");
        try writeFloat(jws, self.reactive_power_setpoint);
        try jws.objectField("node");
        try jws.write(self.node);
        if (self.reactive_capability_curve_points.items.len > 0) {
            try jws.objectField("reactiveCapabilityCurve");
            try jws.beginObject();
            try jws.objectField("points");
            try jws.write(self.reactive_capability_curve_points.items);
            try jws.endObject();
        }
        try jws.endObject();
    }

    pub fn deinit(self: *VsConverterStation, allocator: std.mem.Allocator) void {
        self.reactive_capability_curve_points.deinit(allocator);
    }
};

pub const LccConverterStation = struct {
    id: []const u8,
    name: ?[]const u8,
    loss_factor: f64,
    power_factor: f64,
    node: u32,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("lossFactor");
        try writeFloat(jws, self.loss_factor);
        try jws.objectField("powerFactor");
        try writeFloat(jws, self.power_factor);
        try jws.objectField("node");
        try jws.write(self.node);
        try jws.endObject();
    }
};

pub const EnergySource = enum {
    hydro,
    thermal,
    wind,
    solar,
    nuclear,
    other,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.write(switch (self) {
            .hydro => "HYDRO",
            .thermal => "THERMAL",
            .wind => "WIND",
            .solar => "SOLAR",
            .nuclear => "NUCLEAR",
            .other => "OTHER",
        });
    }
};

pub const ReactiveCapabilityCurvePoint = struct {
    p: f64,
    min_q: f64,
    max_q: f64,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("p");
        try writeFloat(jws, self.p);
        try jws.objectField("minQ");
        try writeFloat(jws, self.min_q);
        try jws.objectField("maxQ");
        try writeFloat(jws, self.max_q);
        try jws.endObject();
    }
};

pub const Generator = struct {
    id: []const u8,
    name: ?[]const u8,
    energy_source: EnergySource,
    min_p: ?f64,
    max_p: ?f64,
    rated_s: ?f64,
    voltage_regulator_on: bool,
    node: u32,
    target_p: f64,
    target_q: f64,
    reactive_capability_curve_points: std.ArrayListUnmanaged(ReactiveCapabilityCurvePoint),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("energySource");
        try jws.write(self.energy_source);
        try jws.objectField("minP");
        try writeOptionalFloat(jws, self.min_p);
        try jws.objectField("maxP");
        try writeOptionalFloat(jws, self.max_p);
        if (self.rated_s) |rs| {
            try jws.objectField("ratedS");
            try writeFloat(jws, rs);
        }
        try jws.objectField("voltageRegulatorOn");
        try jws.write(self.voltage_regulator_on);
        try jws.objectField("node");
        try jws.write(self.node);
        try jws.objectField("targetP");
        try writeFloat(jws, self.target_p);
        try jws.objectField("targetQ");
        try writeFloat(jws, self.target_q);
        if (self.reactive_capability_curve_points.items.len > 0) {
            try jws.objectField("reactiveCapabilityCurve");
            try jws.beginObject();
            try jws.objectField("points");
            try jws.write(self.reactive_capability_curve_points.items);
            try jws.endObject();
        }
        try jws.endObject();
    }

    pub fn deinit(self: *Generator, allocator: std.mem.Allocator) void {
        self.reactive_capability_curve_points.deinit(allocator);
    }
};

pub const SwitchKind = enum {
    breaker,
    disconnector,
    load_break_switch,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.write(switch (self) {
            .breaker => "BREAKER",
            .disconnector => "DISCONNECTOR",
            .load_break_switch => "LOAD_BREAK_SWITCH",
        });
    }
};

pub const Switch = struct {
    id: []const u8,
    name: ?[]const u8,
    kind: SwitchKind,
    retained: bool = true,
    open: bool,
    node1: u32,
    node2: u32,
    aliases: std.ArrayListUnmanaged(Alias),
    properties: std.ArrayListUnmanaged(Property),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("kind");
        try jws.write(self.kind);
        try jws.objectField("retained");
        try jws.write(self.retained);
        try jws.objectField("open");
        try jws.write(self.open);
        try jws.objectField("node1");
        try jws.write(self.node1);
        try jws.objectField("node2");
        try jws.write(self.node2);
        if (self.aliases.items.len > 0) {
            try jws.objectField("aliases");
            try jws.write(self.aliases.items);
        }
        if (self.properties.items.len > 0) {
            try jws.objectField("properties");
            try jws.write(self.properties.items);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *Switch, allocator: std.mem.Allocator) void {
        self.aliases.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

pub const Alias = struct {
    @"type": []const u8,
    content: []const u8,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("type");
        try jws.write(self.@"type");
        try jws.objectField("content");
        try jws.write(self.content);
        try jws.endObject();
    }
};

pub const BusbarSection = struct {
    id: []const u8,
    name: ?[]const u8,
    node: u32,
    aliases: std.ArrayListUnmanaged(Alias),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("node");
        try jws.write(self.node);
        if (self.aliases.items.len > 0) {
            try jws.objectField("aliases");
            try jws.write(self.aliases.items);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *BusbarSection, allocator: std.mem.Allocator) void {
        self.aliases.deinit(allocator);
    }
};

pub const NodeBreakerTopology = struct {
    busbar_sections: std.ArrayListUnmanaged(BusbarSection),
    switches: std.ArrayListUnmanaged(Switch),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("busbarSections");
        try jws.write(self.busbar_sections.items);
        try jws.objectField("switches");
        try jws.write(self.switches.items);
        try jws.endObject();
    }

    pub fn deinit(self: *NodeBreakerTopology, allocator: std.mem.Allocator) void {
        for (self.busbar_sections.items) |*bbs| {
            bbs.deinit(allocator);
        }
        self.busbar_sections.deinit(allocator);
        for (self.switches.items) |*sw| {
            sw.deinit(allocator);
        }
        self.switches.deinit(allocator);
    }
};

// VoltageLevel contains equipment

pub const VoltageLevel = struct {
    id: []const u8,
    name: ?[]const u8,
    nominal_voltage: ?f64,
    low_voltage_limit: ?f64,
    high_voltage_limit: ?f64,
    properties: std.ArrayListUnmanaged(Property),
    node_breaker_topology: NodeBreakerTopology,
    generators: std.ArrayListUnmanaged(Generator),
    loads: std.ArrayListUnmanaged(Load),
    shunts: std.ArrayListUnmanaged(Shunt),
    vs_converter_stations: std.ArrayListUnmanaged(VsConverterStation),
    lcc_converter_stations: std.ArrayListUnmanaged(LccConverterStation),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("nominalV");
        try writeOptionalFloat(jws, self.nominal_voltage);
        try jws.objectField("lowVoltageLimit");
        try writeOptionalFloat(jws, self.low_voltage_limit);
        try jws.objectField("highVoltageLimit");
        try writeOptionalFloat(jws, self.high_voltage_limit);
        try jws.objectField("topologyKind");
        try jws.write("NODE_BREAKER");
        if (self.properties.items.len > 0) {
            try jws.objectField("properties");
            try jws.write(self.properties.items);
        }
        try jws.objectField("nodeBreakerTopology");
        try jws.write(self.node_breaker_topology);
        if (self.generators.items.len > 0) {
            try jws.objectField("generators");
            try jws.write(self.generators.items);
        }
        if (self.loads.items.len > 0) {
            try jws.objectField("loads");
            try jws.write(self.loads.items);
        }
        if (self.shunts.items.len > 0) {
            try jws.objectField("shunts");
            try jws.write(self.shunts.items);
        }
        if (self.vs_converter_stations.items.len > 0) {
            try jws.objectField("vscConverterStations");
            try jws.write(self.vs_converter_stations.items);
        }
        if (self.lcc_converter_stations.items.len > 0) {
            try jws.objectField("lccConverterStations");
            try jws.write(self.lcc_converter_stations.items);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *VoltageLevel, allocator: std.mem.Allocator) void {
        for (self.generators.items) |*gen| {
            gen.deinit(allocator);
        }
        for (self.loads.items) |*load| {
            load.deinit(allocator);
        }
        for (self.vs_converter_stations.items) |*vsc| {
            vsc.deinit(allocator);
        }
        self.node_breaker_topology.deinit(allocator);
        self.generators.deinit(allocator);
        self.loads.deinit(allocator);
        self.shunts.deinit(allocator);
        self.vs_converter_stations.deinit(allocator);
        self.lcc_converter_stations.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

pub const RatioTapChangerStep = struct {
    r: f64,
    x: f64,
    g: f64,
    b: f64,
    rho: f64,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("r");
        try writeFloat(jws, self.r);
        try jws.objectField("x");
        try writeFloat(jws, self.x);
        try jws.objectField("g");
        try writeFloat(jws, self.g);
        try jws.objectField("b");
        try writeFloat(jws, self.b);
        try jws.objectField("rho");
        try writeFloat(jws, self.rho);
        try jws.endObject();
    }
};

// New step type with alpha
pub const PhaseTapChangerStep = struct {
    r: f64,
    x: f64,
    g: f64,
    b: f64,
    rho: f64,
    alpha: f64, // phase shift angle in degrees

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("r");
        try writeFloat(jws, self.r);
        try jws.objectField("x");
        try writeFloat(jws, self.x);
        try jws.objectField("g");
        try writeFloat(jws, self.g);
        try jws.objectField("b");
        try writeFloat(jws, self.b);
        try jws.objectField("rho");
        try writeFloat(jws, self.rho);
        try jws.objectField("alpha");
        try writeFloat(jws, self.alpha);
        try jws.endObject();
    }
};

pub const RatioTapChanger = struct {
    low_tap_position: i32,
    tap_position: i32,
    load_tap_changing_capabilities: bool,
    regulating: bool,
    steps: std.ArrayListUnmanaged(RatioTapChangerStep),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("lowTapPosition");
        try jws.write(self.low_tap_position);
        try jws.objectField("tapPosition");
        try jws.write(self.tap_position);
        try jws.objectField("loadTapChangingCapabilities");
        try jws.write(self.load_tap_changing_capabilities);
        try jws.objectField("regulating");
        try jws.write(self.regulating);
        try jws.objectField("steps");
        try jws.write(self.steps.items);
        try jws.endObject();
    }

    pub fn deinit(self: *RatioTapChanger, allocator: std.mem.Allocator) void {
        self.steps.deinit(allocator);
    }
};

pub const PhaseTapChanger = struct {
    low_tap_position: i32,
    tap_position: i32,
    load_tap_changing_capabilities: bool,
    regulating: bool,
    steps: std.ArrayListUnmanaged(PhaseTapChangerStep),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("lowTapPosition");
        try jws.write(self.low_tap_position);
        try jws.objectField("tapPosition");
        try jws.write(self.tap_position);
        try jws.objectField("loadTapChangingCapabilities");
        try jws.write(self.load_tap_changing_capabilities);
        try jws.objectField("regulating");
        try jws.write(self.regulating);
        try jws.objectField("steps");
        try jws.write(self.steps.items);
        try jws.endObject();
    }

    pub fn deinit(self: *PhaseTapChanger, allocator: std.mem.Allocator) void {
        self.steps.deinit(allocator);
    }
};

pub const CurrentLimits = struct {
    permanent_limit: f64,

    pub fn jsonStringify(self: CurrentLimits, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("permanentLimit");
        try writeFloat(jws, self.permanent_limit);
        try jws.endObject();
    }
};

pub const OperationalLimitsGroup = struct {
    id: []const u8,
    current_limits: ?CurrentLimits = null,

    pub fn jsonStringify(self: OperationalLimitsGroup, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        if (self.current_limits) |cl| {
            try jws.objectField("currentLimits");
            try cl.jsonStringify(jws);
        }
        try jws.endObject();
    }
};

pub const TwoWindingsTransformer = struct {
    id: []const u8,
    name: ?[]const u8,
    r: f64,
    x: f64,
    g: f64,
    b: f64,
    rated_u1: f64,
    rated_u2: f64,
    rated_s: ?f64,
    voltage_level_id1: []const u8,
    node1: u32,
    voltage_level_id2: []const u8,
    node2: u32,
    ratio_tap_changer: ?RatioTapChanger,
    phase_tap_changer: ?PhaseTapChanger,
    op_lims_groups_1: std.ArrayListUnmanaged(OperationalLimitsGroup),
    op_lims_groups_2: std.ArrayListUnmanaged(OperationalLimitsGroup),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("r");
        try writeFloat(jws, self.r);
        try jws.objectField("x");
        try writeFloat(jws, self.x);
        try jws.objectField("g");
        try writeFloat(jws, self.g);
        try jws.objectField("b");
        try writeFloat(jws, self.b);
        try jws.objectField("ratedU1");
        try writeFloat(jws, self.rated_u1);
        try jws.objectField("ratedU2");
        try writeFloat(jws, self.rated_u2);
        if (self.rated_s) |rs| {
            try jws.objectField("ratedS");
            try writeFloat(jws, rs);
        }
        try jws.objectField("voltageLevelId1");
        try jws.write(self.voltage_level_id1);
        try jws.objectField("node1");
        try jws.write(self.node1);
        try jws.objectField("voltageLevelId2");
        try jws.write(self.voltage_level_id2);
        try jws.objectField("node2");
        try jws.write(self.node2);
        if (self.ratio_tap_changer) |tc| {
            try jws.objectField("ratioTapChanger");
            try jws.write(tc);
        }
        if (self.phase_tap_changer) |tc| {
            try jws.objectField("phaseTapChanger");
            try jws.write(tc);
        }
        if (self.op_lims_groups_1.items.len > 0) {
            try jws.objectField("operationalLimitsGroups1");
            try jws.beginArray();
            for (self.op_lims_groups_1.items) |olg| {
                try olg.jsonStringify(jws);
            }
            try jws.endArray();
        }
        if (self.op_lims_groups_2.items.len > 0) {
            try jws.objectField("operationalLimitsGroups2");
            try jws.beginArray();
            for (self.op_lims_groups_2.items) |olg| {
                try olg.jsonStringify(jws);
            }
            try jws.endArray();
        }
        try jws.endObject();
    }

    pub fn deinit(self: *TwoWindingsTransformer, allocator: std.mem.Allocator) void {
        if (self.ratio_tap_changer) |*rtc| {
            rtc.deinit(allocator);
        }
        if (self.phase_tap_changer) |*ptc| {
            ptc.deinit(allocator);
        }
        self.op_lims_groups_1.deinit(allocator);
        self.op_lims_groups_2.deinit(allocator);
    }
};

pub const ThreeWindingsTransformer = struct {
    id: []const u8,
    name: ?[]const u8,
    node1: ?[]const u8,
    node2: ?[]const u8,
    node3: ?[]const u8,
    rated_u1: f64,
    rated_u2: f64,
    rated_u3: f64,
    r1: f64,
    r2: f64,
    r3: f64,
    x1: f64,
    x2: f64,
    x3: f64,
    g1: f64,
    g2: f64,
    g3: f64,
    b1: f64,
    b2: f64,
    b3: f64,
};

// Substation contains voltage levels and transformers

pub const Property = struct {
    name: []const u8,
    value: []const u8,
};

pub const Substation = struct {
    id: []const u8,
    name: ?[]const u8,
    country: ?[]const u8,
    geo_tags: std.ArrayListUnmanaged([]const u8),
    properties: std.ArrayListUnmanaged(Property),
    voltage_levels: std.ArrayListUnmanaged(VoltageLevel),
    two_winding_transformers: std.ArrayListUnmanaged(TwoWindingsTransformer),
    three_winding_transformers: std.ArrayListUnmanaged(ThreeWindingsTransformer),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        if (self.country) |country| {
            try jws.objectField("country");
            try jws.write(country);
        }
        try jws.objectField("geographicalTags");
        try jws.write(self.geo_tags.items);
        if (self.properties.items.len > 0) {
            try jws.objectField("properties");
            try jws.write(self.properties.items);
        }
        try jws.objectField("voltageLevels");
        try jws.write(self.voltage_levels.items);
        try jws.objectField("twoWindingsTransformers");
        try jws.write(self.two_winding_transformers.items);
        try jws.objectField("threeWindingsTransformers");
        try jws.write(self.three_winding_transformers.items);
        try jws.endObject();
    }

    pub fn deinit(self: *Substation, allocator: std.mem.Allocator) void {
        for (self.voltage_levels.items) |*vl| {
            vl.deinit(allocator);
        }
        self.voltage_levels.deinit(allocator);
        for (self.two_winding_transformers.items) |*twt| {
            twt.deinit(allocator);
        }
        self.two_winding_transformers.deinit(allocator);
        self.three_winding_transformers.deinit(allocator);
        self.properties.deinit(allocator);
        self.geo_tags.deinit(allocator);
    }
};

pub const Line = struct {
    id: []const u8,
    name: ?[]const u8,
    node1: ?[]const u8,
    node2: ?[]const u8,
    r: f64,
    x: f64,
    g1: f64,
    g2: f64,
    b1: f64,
    b2: f64,
    op_lims_groups_1: std.ArrayListUnmanaged(OperationalLimitsGroup),
    op_lims_groups_2: std.ArrayListUnmanaged(OperationalLimitsGroup),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("node1");
        try jws.write(self.node1);
        try jws.objectField("node2");
        try jws.write(self.node2);
        try jws.objectField("r");
        try writeFloat(jws, self.r);
        try jws.objectField("x");
        try writeFloat(jws, self.x);
        try jws.objectField("g1");
        try writeFloat(jws, self.g1);
        try jws.objectField("g2");
        try writeFloat(jws, self.g2);
        try jws.objectField("b1");
        try writeFloat(jws, self.b1);
        try jws.objectField("b2");
        try writeFloat(jws, self.b2);
        if (self.op_lims_groups_1.items.len > 0) {
            try jws.objectField("operationalLimitsGroups1");
            try jws.beginArray();
            for (self.op_lims_groups_1.items) |olg| {
                try olg.jsonStringify(jws);
            }
            try jws.endArray();
        }
        if (self.op_lims_groups_2.items.len > 0) {
            try jws.objectField("operationalLimitsGroups2");
            try jws.beginArray();
            for (self.op_lims_groups_2.items) |olg| {
                try olg.jsonStringify(jws);
            }
            try jws.endArray();
        }
        try jws.endObject();
    }

    pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
        self.op_lims_groups_1.deinit(allocator);
        self.op_lims_groups_2.deinit(allocator);
    }
};

pub const Network = struct {
    id: []const u8, // taken from FullModel rdf:about
    case_date: ?[]const u8, // taken from FullModel -> Model.scenarioTime
    substations: std.ArrayListUnmanaged(Substation),
    lines: std.ArrayListUnmanaged(Line),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("version");
        try jws.write("1.15");
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("caseDate");
        try writeDateWithMillis(jws, self.case_date);
        try jws.objectField("forecastDistance");
        try jws.write(0);
        try jws.objectField("sourceFormat");
        try jws.write("CGMES");
        try jws.objectField("minimumValidationLevel");
        try jws.write("EQUIPMENT");
        try jws.objectField("substations");
        try jws.write(self.substations.items);
        try jws.objectField("lines");
        try jws.write(self.lines.items);
        try jws.endObject();
    }

    pub fn deinit(self: *Network, allocator: std.mem.Allocator) void {
        for (self.substations.items) |*sub| {
            sub.deinit(allocator);
        }
        self.substations.deinit(allocator);
        for (self.lines.items) |*line| {
            line.deinit(allocator);
        }
        self.lines.deinit(allocator);
    }
};
