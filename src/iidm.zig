const std = @import("std");

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
};

pub const ShuntLinearModel = struct {
    b_per_section: f64,
    g_per_section: f64,
    max_section_count: u32,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("bPerSection");
        try jws.write(self.b_per_section);
        try jws.objectField("gPerSection");
        try jws.write(self.g_per_section);
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
        try jws.write(self.loss_factor);
        try jws.objectField("reactivePowerSetpoint");
        try jws.write(self.reactive_power_setpoint);
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
        try jws.write(self.p);
        try jws.objectField("minQ");
        try jws.write(self.min_q);
        try jws.objectField("maxQ");
        try jws.write(self.max_q);
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
        try jws.write(self.min_p);
        try jws.objectField("maxP");
        try jws.write(self.max_p);
        if (self.rated_s) |rs| {
            try jws.objectField("ratedS");
            try jws.write(rs);
        }
        try jws.objectField("voltageRegulatorOn");
        try jws.write(self.voltage_regulator_on);
        try jws.objectField("node");
        try jws.write(self.node);
        try jws.objectField("targetP");
        try jws.write(self.target_p);
        try jws.objectField("targetQ");
        try jws.write(self.target_q);
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
    open: bool,
    retained: bool = true,
    node1: u32,
    node2: u32,
};

pub const BusbarSection = struct {
    id: []const u8,
    name: ?[]const u8,
    node: u32,
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
        self.busbar_sections.deinit(allocator);
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
    node_breaker_topology: NodeBreakerTopology,
    generators: std.ArrayListUnmanaged(Generator),
    loads: std.ArrayListUnmanaged(Load),
    shunts: std.ArrayListUnmanaged(Shunt),
    vs_converter_stations: std.ArrayListUnmanaged(VsConverterStation),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("nominalV");
        try jws.write(self.nominal_voltage);
        try jws.objectField("lowVoltageLimit");
        try jws.write(self.low_voltage_limit);
        try jws.objectField("highVoltageLimit");
        try jws.write(self.high_voltage_limit);
        try jws.objectField("topologyKind");
        try jws.write("NODE_BREAKER");
        try jws.objectField("nodeBreakerTopology");
        try jws.write(self.node_breaker_topology);
        try jws.objectField("generators");
        try jws.write(self.generators.items);
        try jws.objectField("loads");
        try jws.write(self.loads.items);
        try jws.objectField("shunts");
        try jws.write(self.shunts.items);
        try jws.objectField("vscConverterStations");
        try jws.write(self.vs_converter_stations.items);
        try jws.endObject();
    }

    pub fn deinit(self: *VoltageLevel, allocator: std.mem.Allocator) void {
        for (self.generators.items) |*gen| {
            gen.deinit(allocator);
        }
        for (self.vs_converter_stations.items) |*vsc| {
            vsc.deinit(allocator);
        }
        self.node_breaker_topology.deinit(allocator);
        self.generators.deinit(allocator);
        self.loads.deinit(allocator);
        self.shunts.deinit(allocator);
        self.vs_converter_stations.deinit(allocator);
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
        try jws.write(self.r);
        try jws.objectField("x");
        try jws.write(self.x);
        try jws.objectField("g");
        try jws.write(self.g);
        try jws.objectField("b");
        try jws.write(self.b);
        try jws.objectField("rho");
        try jws.write(self.rho);
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

// Transformers at substation level

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

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("r");
        try jws.write(self.r);
        try jws.objectField("x");
        try jws.write(self.x);
        try jws.objectField("g");
        try jws.write(self.g);
        try jws.objectField("b");
        try jws.write(self.b);
        try jws.objectField("ratedU1");
        try jws.write(self.rated_u1);
        try jws.objectField("ratedU2");
        try jws.write(self.rated_u2);
        if (self.rated_s) |rs| {
            try jws.objectField("ratedS");
            try jws.write(rs);
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
        try jws.endObject();
    }

    pub fn deinit(self: *TwoWindingsTransformer, allocator: std.mem.Allocator) void {
        if (self.ratio_tap_changer) |*rtc| {
            rtc.deinit(allocator);
        }
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

pub const Substation = struct {
    id: []const u8,
    name: ?[]const u8,
    country: ?[]const u8,
    geo_tags: std.ArrayListUnmanaged([]const u8),
    voltage_levels: std.ArrayListUnmanaged(VoltageLevel),
    two_winding_transformers: std.ArrayListUnmanaged(TwoWindingsTransformer),
    three_winding_transformers: std.ArrayListUnmanaged(ThreeWindingsTransformer),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("country");
        try jws.write(self.country);
        try jws.objectField("geographicalTags");
        try jws.write(self.geo_tags.items);
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
};

pub const Network = struct {
    id: []const u8, // taken from FullModel rdf:about
    case_date: ?[]const u8, // taken from FullModel -> Model.scenarioTime
    substations: std.ArrayListUnmanaged(Substation),
    lines: std.ArrayListUnmanaged(Line),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("caseDate");
        try jws.write(self.case_date);
        try jws.objectField("sourceFormat");
        try jws.write("CGMES");
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
        self.lines.deinit(allocator);
    }
};
