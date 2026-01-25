const std = @import("std");

pub const Load = struct {
    id: []const u8,
    name: ?[]const u8,
    node: ?[]const u8,
    p0: f64,
    q0: f64,
};

pub const Generator = struct {
    id: []const u8,
    name: ?[]const u8,
    node: ?[]const u8,
    min_p: ?f64,
    max_p: ?f64,
    target_p: f64,
    target_q: f64,
};

pub const SwitchKind = enum {
    breaker,
    disconnector,
    load_break_switch,
};

pub const Switch = struct {
    id: []const u8,
    name: ?[]const u8,
    node1: ?[]const u8,
    node2: ?[]const u8,
    open: bool,
    kind: SwitchKind,
};

// VoltageLevel contains equipment

pub const VoltageLevel = struct {
    id: []const u8,
    name: ?[]const u8,
    nominal_voltage: ?f64,
    low_voltage_limit: ?f64,
    high_voltage_limit: ?f64,
    generators: std.ArrayListUnmanaged(Generator),
    loads: std.ArrayListUnmanaged(Load),
    switches: std.ArrayListUnmanaged(Switch),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("nominal_voltage");
        try jws.write(self.nominal_voltage);
        try jws.objectField("low_voltage_limit");
        try jws.write(self.low_voltage_limit);
        try jws.objectField("high_voltage_limit");
        try jws.write(self.high_voltage_limit);
        try jws.objectField("generators");
        try jws.write(self.generators.items);
        try jws.objectField("loads");
        try jws.write(self.loads.items);
        try jws.objectField("switches");
        try jws.write(self.switches.items);
        try jws.endObject();
    }

    pub fn deinit(self: *VoltageLevel, allocator: std.mem.Allocator) void {
        self.generators.deinit(allocator);
        self.loads.deinit(allocator);
        self.switches.deinit(allocator);
    }
};

// Transformers at substation level

pub const TwoWindingsTransformer = struct {
    id: []const u8,
    name: ?[]const u8,
    node1: ?[]const u8,
    node2: ?[]const u8,
    rated_u1: f64,
    rated_u2: f64,
    r: f64,
    x: f64,
    g: f64,
    b: f64,
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
    geo_tags: ?[]const u8,
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
        try jws.objectField("geo_tags");
        try jws.write(self.geo_tags);
        try jws.objectField("voltage_levels");
        try jws.write(self.voltage_levels.items);
        try jws.objectField("two_winding_transformers");
        try jws.write(self.two_winding_transformers.items);
        try jws.objectField("three_winding_transformers");
        try jws.write(self.three_winding_transformers.items);
        try jws.endObject();
    }

    pub fn deinit(self: *Substation, allocator: std.mem.Allocator) void {
        for (self.voltage_levels.items) |*vl| {
            vl.deinit(allocator);
        }
        self.voltage_levels.deinit(allocator);
        self.two_winding_transformers.deinit(allocator);
        self.three_winding_transformers.deinit(allocator);
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
        try jws.objectField("case_date");
        try jws.write(self.case_date);
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
