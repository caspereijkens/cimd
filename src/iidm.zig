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
    // voltage_levels, loads, generators, lines... (later)
    pub fn deinit(self: *Network, gpa: std.mem.Allocator) void {
        self.substations.deinit(gpa);
        self.voltage_levels.deinit(gpa);
        self.loads.deinit(gpa);
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
