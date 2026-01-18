const std = @import("std");

// src/iidm.zig - IIDM data structures
pub const Substation = struct {
    id: []const u8,
    name: ?[]const u8,
    country: ?[]const u8,
    geo_tags: ?[]const u8,
};

pub const Network = struct {
    id: []const u8,
    case_date: ?[]const u8,
    substations: std.ArrayList(Substation),
    voltage_levels: std.ArrayList(VoltageLevel),
    loads: std.ArrayList(Load),
    generators: std.ArrayList(Generator),
    lines: std.ArrayList(Line),
    two_winding_transformers: std.ArrayList(TwoWindingsTransformer),
    three_winding_transformers: std.ArrayList(ThreeWindingsTransformer),
    switches: std.ArrayList(Switch),

    pub fn deinit(self: *Network, gpa: std.mem.Allocator) void {
        self.substations.deinit(gpa);
        self.voltage_levels.deinit(gpa);
        self.loads.deinit(gpa);
        self.generators.deinit(gpa);
        self.lines.deinit(gpa);
        self.two_winding_transformers.deinit(gpa);
        self.three_winding_transformers.deinit(gpa);
        self.switches.deinit(gpa);
    }
};

pub const VoltageLevel = struct {
    id: []const u8,
    name: ?[]const u8,
    substation_id: []const u8,
    nominal_voltage: ?f64,
    low_voltage_limit: ?f64,
    high_voltage_limit: ?f64,
};

pub const Load = struct {
    id: []const u8,
    name: ?[]const u8,
    voltage_level_id: []const u8,
    bus: ?[]const u8,
    p0: f64,
    q0: f64,
};

pub const Generator = struct {
    id: []const u8,
    name: ?[]const u8,
    voltage_level_id: []const u8,
    bus: ?[]const u8,
    min_p: ?f64,
    max_p: ?f64,
    target_p: f64,
    target_q: f64,
};

pub const Line = struct {
    id: []const u8,
    name: ?[]const u8,
    voltage_level_id1: []const u8,
    voltage_level_id2: []const u8,
    bus1: ?[]const u8,
    bus2: ?[]const u8,
    r: f64,
    x: f64,
    g1: f64,
    g2: f64,
    b1: f64,
    b2: f64,
};

pub const TwoWindingsTransformer = struct {
    id: []const u8,
    name: ?[]const u8,
    voltage_level_id1: []const u8,
    voltage_level_id2: []const u8,
    bus1: ?[]const u8,
    bus2: ?[]const u8,
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
    voltage_level_id1: []const u8,
    voltage_level_id2: []const u8,
    voltage_level_id3: []const u8,
    bus1: ?[]const u8,
    bus2: ?[]const u8,
    bus3: ?[]const u8,
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

pub const SwitchKind = enum {
    breaker,
    disconnector,
    load_break_switch,
};

pub const Switch = struct {
    id: []const u8,
    name: ?[]const u8,
    voltage_level_id: []const u8,
    bus1: ?[]const u8,
    bus2: ?[]const u8,
    open: bool,
    kind: SwitchKind,
};
