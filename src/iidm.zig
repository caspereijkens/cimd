const std = @import("std");

/// Write a float to JSON, ensuring at least one decimal place (e.g., 100.0 not 100)
/// Also handles scientific notation: converts 'e' to 'E' and removes '+' sign
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

    // Process the formatted string: convert 'e' to 'E', remove '+', ensure decimal
    var out_buf: [34]u8 = undefined;
    var out_len: usize = 0;
    var has_decimal = false;
    var has_exponent = false;

    for (formatted) |c| {
        if (c == '.') {
            has_decimal = true;
            out_buf[out_len] = c;
            out_len += 1;
        } else if (c == 'e') {
            has_exponent = true;
            out_buf[out_len] = 'E';
            out_len += 1;
        } else if (c == '+') {
            // Skip '+' sign (typically after E)
        } else {
            out_buf[out_len] = c;
            out_len += 1;
        }
    }

    // Add .0 if no decimal and no exponent
    if (!has_decimal and !has_exponent) {
        out_buf[out_len] = '.';
        out_len += 1;
        out_buf[out_len] = '0';
        out_len += 1;
    }

    try jws.print("{s}", .{out_buf[0..out_len]});
}

/// Write an optional float to JSON
fn write_optional_float(jws: anytype, value: ?f64) !void {
    if (value) |v| {
        try writeFloat(jws, v);
    } else {
        try jws.write(null);
    }
}

/// Write an operational limits group array if non-empty
fn write_op_lims_groups(jws: anytype, field_name: []const u8, groups: std.ArrayListUnmanaged(OperationalLimitsGroup)) !void {
    if (groups.items.len > 0) {
        try jws.objectField(field_name);
        try jws.beginArray();
        for (groups.items) |olg| {
            try olg.jsonStringify(jws);
        }
        try jws.endArray();
    }
}

/// Write a float, using scientific notation for very large values
fn write_float_auto(jws: anytype, value: f64) !void {
    if (@abs(value) >= 1e10) {
        try write_float_scientific(jws, value);
    } else {
        try writeFloat(jws, value);
    }
}

/// Format a float string to ensure it has a decimal point (e.g., "100" -> "100.0")
/// Returns the original string if it already has a decimal, otherwise allocates a new one.
pub fn format_float_str(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
    // If string is in scientific notation (contains 'e'/'E'), parse and reformat as
    // fixed-point decimal to match Java's Double.toString behaviour (e.g. "1250000.0").
    const has_exp = std.mem.indexOfAny(u8, str, "eE") != null;
    if (has_exp) {
        const value = try std.fmt.parseFloat(f64, str);
        const formatted = try std.fmt.allocPrint(allocator, "{d}", .{value});
        if (std.mem.indexOfScalar(u8, formatted, '.') == null) {
            defer allocator.free(formatted);
            return std.fmt.allocPrint(allocator, "{s}.0", .{formatted});
        }
        return formatted;
    }
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
fn write_date_with_millis(jws: anytype, date: ?[]const u8) !void {
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

pub const ExponentialModel = struct {
    np: f64,
    nq: f64,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("np");
        try writeFloat(jws, self.np);
        try jws.objectField("nq");
        try writeFloat(jws, self.nq);
        try jws.endObject();
    }
};

pub const ZipModel = struct {
    c0p: f64,
    c1p: f64,
    c2p: f64,
    c0q: f64,
    c1q: f64,
    c2q: f64,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("c0p");
        try writeFloat(jws, self.c0p);
        try jws.objectField("c1p");
        try writeFloat(jws, self.c1p);
        try jws.objectField("c2p");
        try writeFloat(jws, self.c2p);
        try jws.objectField("c0q");
        try writeFloat(jws, self.c0q);
        try jws.objectField("c1q");
        try writeFloat(jws, self.c1q);
        try jws.objectField("c2q");
        try writeFloat(jws, self.c2q);
        try jws.endObject();
    }
};

pub const Load = struct {
    id: []const u8,
    name: ?[]const u8,
    load_type: LoadType,
    node: u32,
    exponential_model: ?ExponentialModel = null,
    zip_model: ?ZipModel = null,
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
        if (self.exponential_model) |em| {
            try jws.objectField("exponentialModel");
            try em.jsonStringify(jws);
        }
        if (self.zip_model) |zm| {
            try jws.objectField("zipModel");
            try zm.jsonStringify(jws);
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
    regulating_terminal: ?[]const u8 = null,
    node: u32,
    shunt_linear_model: ShuntLinearModel,
    aliases: std.ArrayListUnmanaged(Alias),
    properties: std.ArrayListUnmanaged(Property),

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
        if (self.aliases.items.len > 0) {
            try jws.objectField("aliases");
            try jws.write(self.aliases.items);
        }
        if (self.properties.items.len > 0) {
            try jws.objectField("properties");
            try jws.write(self.properties.items);
        }
        if (self.regulating_terminal) |rt| {
            try jws.objectField("regulatingTerminal");
            try jws.beginObject();
            try jws.objectField("id");
            try jws.write(rt);
            try jws.endObject();
        }
        try jws.objectField("shuntLinearModel");
        try jws.write(self.shunt_linear_model);
        try jws.endObject();
    }

    pub fn deinit(self: *Shunt, allocator: std.mem.Allocator) void {
        self.aliases.deinit(allocator);
        self.properties.deinit(allocator);
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
    min_max_reactive_limits: ?MinMaxReactiveLimits = null,
    aliases: std.ArrayListUnmanaged(Alias),
    properties: std.ArrayListUnmanaged(Property),

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
        if (self.aliases.items.len > 0) {
            try jws.objectField("aliases");
            try jws.write(self.aliases.items);
        }
        if (self.properties.items.len > 0) {
            try jws.objectField("properties");
            try jws.write(self.properties.items);
        }
        if (self.reactive_capability_curve_points.items.len > 0) {
            try jws.objectField("reactiveCapabilityCurve");
            try jws.beginObject();
            try jws.objectField("points");
            try jws.write(self.reactive_capability_curve_points.items);
            try jws.endObject();
        } else if (self.min_max_reactive_limits) |limits| {
            try jws.objectField("minMaxReactiveLimits");
            try limits.jsonStringify(jws);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *VsConverterStation, allocator: std.mem.Allocator) void {
        self.reactive_capability_curve_points.deinit(allocator);
        self.aliases.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

pub const LccConverterStation = struct {
    id: []const u8,
    name: ?[]const u8,
    loss_factor: f64,
    power_factor: f64,
    node: u32,
    aliases: std.ArrayListUnmanaged(Alias),

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
        if (self.aliases.items.len > 0) {
            try jws.objectField("aliases");
            try jws.write(self.aliases.items);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *LccConverterStation, allocator: std.mem.Allocator) void {
        self.aliases.deinit(allocator);
    }
};

pub const SvcRegulationMode = enum {
    voltage,
    reactive_power,
    off,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.write(switch (self) {
            .voltage => "VOLTAGE",
            .reactive_power => "REACTIVE_POWER",
            .off => "OFF",
        });
    }
};

pub const StaticVarCompensator = struct {
    id: []const u8,
    name: ?[]const u8,
    b_min: f64,
    b_max: f64,
    regulation_mode: SvcRegulationMode,
    regulating: bool,
    node: u32,
    aliases: std.ArrayListUnmanaged(Alias),
    properties: std.ArrayListUnmanaged(Property),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("bMin");
        try writeFloat(jws, self.b_min);
        try jws.objectField("bMax");
        try writeFloat(jws, self.b_max);
        try jws.objectField("regulationMode");
        try self.regulation_mode.jsonStringify(jws);
        try jws.objectField("regulating");
        try jws.write(self.regulating);
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

    pub fn deinit(self: *StaticVarCompensator, allocator: std.mem.Allocator) void {
        self.aliases.deinit(allocator);
        self.properties.deinit(allocator);
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

pub const MinMaxReactiveLimits = struct {
    min_q: f64,
    max_q: f64,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("minQ");
        try write_float_scientific(jws, self.min_q);
        try jws.objectField("maxQ");
        try write_float_scientific(jws, self.max_q);
        try jws.endObject();
    }
};

fn write_float_scientific(jws: anytype, value: f64) !void {
    var buf: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{e}", .{value}) catch {
        try jws.write(value);
        return;
    };
    // Convert lowercase 'e' to uppercase 'E' and remove '+' after E
    var out_buf: [32]u8 = undefined;
    var out_len: usize = 0;
    for (formatted) |c| {
        if (c == 'e') {
            out_buf[out_len] = 'E';
            out_len += 1;
        } else if (c == '+') {
            // Skip the '+' sign after E
        } else {
            out_buf[out_len] = c;
            out_len += 1;
        }
    }
    try jws.print("{s}", .{out_buf[0..out_len]});
}

pub const Generator = struct {
    id: []const u8,
    name: ?[]const u8,
    energy_source: EnergySource,
    min_p: ?f64,
    max_p: ?f64,
    rated_s: ?f64,
    is_condenser: bool = false,
    voltage_regulator_on: bool,
    regulating_terminal: ?[]const u8 = null,
    node: u32,
    reactive_capability_curve_points: std.ArrayListUnmanaged(ReactiveCapabilityCurvePoint),
    min_max_reactive_limits: ?MinMaxReactiveLimits = null,
    aliases: std.ArrayListUnmanaged(Alias),
    properties: std.ArrayListUnmanaged(Property),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("energySource");
        try jws.write(self.energy_source);
        try jws.objectField("minP");
        try write_optional_float(jws, self.min_p);
        try jws.objectField("maxP");
        try write_optional_float(jws, self.max_p);
        if (self.rated_s) |rs| {
            try jws.objectField("ratedS");
            try writeFloat(jws, rs);
        }
        if (self.is_condenser) {
            try jws.objectField("isCondenser");
            try jws.write(true);
        }
        try jws.objectField("voltageRegulatorOn");
        try jws.write(self.voltage_regulator_on);
        if (self.regulating_terminal) |rt| {
            try jws.objectField("regulatingTerminal");
            try jws.beginObject();
            try jws.objectField("id");
            try jws.write(rt);
            try jws.endObject();
        }
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
        if (self.reactive_capability_curve_points.items.len > 0) {
            try jws.objectField("reactiveCapabilityCurve");
            try jws.beginObject();
            try jws.objectField("points");
            try jws.write(self.reactive_capability_curve_points.items);
            try jws.endObject();
        } else if (self.min_max_reactive_limits) |limits| {
            try jws.objectField("minMaxReactiveLimits");
            try limits.jsonStringify(jws);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *Generator, allocator: std.mem.Allocator) void {
        self.reactive_capability_curve_points.deinit(allocator);
        self.aliases.deinit(allocator);
        self.properties.deinit(allocator);
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

    /// Convert a CIM type name to a SwitchKind.
    /// Only valid for the three switch types: Breaker, Disconnector, LoadBreakSwitch.
    pub fn from_cim_type(cim_type: []const u8) SwitchKind {
        if (std.mem.eql(u8, cim_type, "Breaker")) return .breaker;
        if (std.mem.eql(u8, cim_type, "Disconnector")) return .disconnector;
        if (std.mem.eql(u8, cim_type, "LoadBreakSwitch")) return .load_break_switch;
        unreachable;
    }
};

test "SwitchKind.from_cim_type: Breaker" {
    try std.testing.expectEqual(SwitchKind.breaker, SwitchKind.from_cim_type("Breaker"));
}

test "SwitchKind.from_cim_type: Disconnector" {
    try std.testing.expectEqual(SwitchKind.disconnector, SwitchKind.from_cim_type("Disconnector"));
}

test "SwitchKind.from_cim_type: LoadBreakSwitch" {
    try std.testing.expectEqual(SwitchKind.load_break_switch, SwitchKind.from_cim_type("LoadBreakSwitch"));
}

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
    type: []const u8,
    content: []const u8,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("type");
        try jws.write(self.type);
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

pub const InternalConnection = struct {
    node1: u32,
    node2: u32,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("node1");
        try jws.write(self.node1);
        try jws.objectField("node2");
        try jws.write(self.node2);
        try jws.endObject();
    }
};

pub const NodeBreakerTopology = struct {
    busbar_sections: std.ArrayListUnmanaged(BusbarSection),
    switches: std.ArrayListUnmanaged(Switch),
    internal_connections: std.ArrayListUnmanaged(InternalConnection),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("busbarSections");
        try jws.write(self.busbar_sections.items);
        if (self.internal_connections.items.len > 0) {
            try jws.objectField("internalConnections");
            try jws.write(self.internal_connections.items);
        }
        try jws.objectField("switches");
        try jws.write(self.switches.items);
        try jws.endObject();
    }

    pub fn deinit(self: *NodeBreakerTopology, allocator: std.mem.Allocator) void {
        for (self.busbar_sections.items) |*busbar_section| {
            busbar_section.deinit(allocator);
        }
        self.busbar_sections.deinit(allocator);
        for (self.switches.items) |*sw| {
            sw.deinit(allocator);
        }
        self.switches.deinit(allocator);
        self.internal_connections.deinit(allocator);
    }
};

// VoltageLevel contains equipment

pub const VoltageLevel = struct {
    id: []const u8,
    name: ?[]const u8,
    nominal_voltageoltage: ?f64,
    low_voltage_limit: ?f64,
    high_voltage_limit: ?f64,
    aliases: std.ArrayListUnmanaged(Alias),
    properties: std.ArrayListUnmanaged(Property),
    node_breaker_topology: NodeBreakerTopology,
    generators: std.ArrayListUnmanaged(Generator),
    loads: std.ArrayListUnmanaged(Load),
    shunts: std.ArrayListUnmanaged(Shunt),
    static_var_compensators: std.ArrayListUnmanaged(StaticVarCompensator),
    vs_converter_stations: std.ArrayListUnmanaged(VsConverterStation),
    lcc_converter_stations: std.ArrayListUnmanaged(LccConverterStation),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("nominalV");
        try write_optional_float(jws, self.nominal_voltageoltage);
        try jws.objectField("lowVoltageLimit");
        try write_optional_float(jws, self.low_voltage_limit);
        try jws.objectField("highVoltageLimit");
        try write_optional_float(jws, self.high_voltage_limit);
        try jws.objectField("topologyKind");
        try jws.write("NODE_BREAKER");
        if (self.aliases.items.len > 0) {
            try jws.objectField("aliases");
            try jws.write(self.aliases.items);
        }
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
        if (self.static_var_compensators.items.len > 0) {
            try jws.objectField("staticVarCompensators");
            try jws.write(self.static_var_compensators.items);
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
        for (self.shunts.items) |*shunt| {
            shunt.deinit(allocator);
        }
        for (self.static_var_compensators.items) |*svc| {
            svc.deinit(allocator);
        }
        for (self.vs_converter_stations.items) |*vsc| {
            vsc.deinit(allocator);
        }
        for (self.lcc_converter_stations.items) |*lcc| {
            lcc.deinit(allocator);
        }
        self.node_breaker_topology.deinit(allocator);
        self.generators.deinit(allocator);
        self.loads.deinit(allocator);
        self.shunts.deinit(allocator);
        self.static_var_compensators.deinit(allocator);
        self.vs_converter_stations.deinit(allocator);
        self.lcc_converter_stations.deinit(allocator);
        self.aliases.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

/// A fictitious VoltageLevel created for boundary ConnectivityNodes.
/// In CGMES, boundary terminals connect to CNs whose container is a Line,
/// not a VoltageLevel. pypowsybl creates a synthetic VL with id "<CN_id>_VL".
pub const FictitiousVoltageLevel = struct {
    id: []const u8,
    name: ?[]const u8,
    nominal_voltage: ?f64,
    line_container_id: []const u8,
    internal_connections: std.ArrayListUnmanaged(InternalConnection) = .empty,
    generators: std.ArrayListUnmanaged(Generator) = .empty,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("fictitious");
        try jws.write(true);
        try jws.objectField("nominalV");
        try write_optional_float(jws, self.nominal_voltage);
        try jws.objectField("topologyKind");
        try jws.write("NODE_BREAKER");
        try jws.objectField("properties");
        try jws.beginArray();
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write("CGMES.LineContainerId");
        try jws.objectField("value");
        try jws.write(self.line_container_id);
        try jws.endObject();
        try jws.endArray();
        try jws.objectField("nodeBreakerTopology");
        try jws.beginObject();
        if (self.internal_connections.items.len > 0) {
            try jws.objectField("internalConnections");
            try jws.write(self.internal_connections.items);
        }
        try jws.endObject();
        if (self.generators.items.len > 0) {
            try jws.objectField("generators");
            try jws.write(self.generators.items);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *FictitiousVoltageLevel, allocator: std.mem.Allocator) void {
        allocator.free(self.id); // id is always heap-allocated via allocPrint in line.zig
        self.internal_connections.deinit(allocator);
        for (self.generators.items) |*gen| gen.deinit(allocator);
        self.generators.deinit(allocator);
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

pub const TerminalRef = struct {
    id: []const u8,
    side: []const u8,
};

pub const RatioTapChanger = struct {
    low_tap_position: i32,
    tap_position: i32,
    load_tap_changing_capabilities: bool,
    regulating: ?bool,
    regulation_mode: ?[]const u8,
    terminal_ref: ?TerminalRef,
    steps: std.ArrayListUnmanaged(RatioTapChangerStep),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        if (self.regulating) |reg| {
            try jws.objectField("regulating");
            try jws.write(reg);
        }
        try jws.objectField("lowTapPosition");
        try jws.write(self.low_tap_position);
        try jws.objectField("tapPosition");
        try jws.write(self.tap_position);
        try jws.objectField("loadTapChangingCapabilities");
        try jws.write(self.load_tap_changing_capabilities);
        if (self.regulation_mode) |mode| {
            try jws.objectField("regulationMode");
            try jws.write(mode);
        }
        if (self.terminal_ref) |ref| {
            try jws.objectField("terminalRef");
            try jws.beginObject();
            try jws.objectField("id");
            try jws.write(ref.id);
            try jws.objectField("side");
            try jws.write(ref.side);
            try jws.endObject();
        }
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
    regulating: ?bool,
    regulation_mode: ?[]const u8,
    steps: std.ArrayListUnmanaged(PhaseTapChangerStep),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        if (self.regulating) |reg| {
            try jws.objectField("regulating");
            try jws.write(reg);
        }
        try jws.objectField("lowTapPosition");
        try jws.write(self.low_tap_position);
        try jws.objectField("tapPosition");
        try jws.write(self.tap_position);
        try jws.objectField("loadTapChangingCapabilities");
        try jws.write(self.load_tap_changing_capabilities);
        if (self.regulation_mode) |mode| {
            try jws.objectField("regulationMode");
            try jws.write(mode);
        }
        try jws.objectField("steps");
        try jws.write(self.steps.items);
        try jws.endObject();
    }

    pub fn deinit(self: *PhaseTapChanger, allocator: std.mem.Allocator) void {
        self.steps.deinit(allocator);
    }
};

pub const TemporaryLimit = struct {
    name: []const u8,
    acceptable_duration: ?u32 = null,
    value: f64,

    pub fn jsonStringify(self: TemporaryLimit, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(self.name);
        if (self.acceptable_duration) |dur| {
            try jws.objectField("acceptableDuration");
            try jws.write(dur);
        }
        try jws.objectField("value");
        try write_float_auto(jws, self.value);
        try jws.endObject();
    }
};

pub const CurrentLimits = struct {
    permanent_limit: f64,
    temporary_limits: std.ArrayListUnmanaged(TemporaryLimit) = .empty,

    pub fn jsonStringify(self: CurrentLimits, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("permanentLimit");
        try writeFloat(jws, self.permanent_limit);
        if (self.temporary_limits.items.len > 0) {
            try jws.objectField("temporaryLimits");
            try jws.write(self.temporary_limits.items);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *CurrentLimits, allocator: std.mem.Allocator) void {
        self.temporary_limits.deinit(allocator);
    }
};

pub const OperationalLimitsGroup = struct {
    id: []const u8,
    properties: std.ArrayListUnmanaged(Property),
    current_limits: ?CurrentLimits = null,

    pub fn jsonStringify(self: OperationalLimitsGroup, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        if (self.properties.items.len > 0) {
            try jws.objectField("properties");
            try jws.write(self.properties.items);
        }
        if (self.current_limits) |cl| {
            try jws.objectField("currentLimits");
            try cl.jsonStringify(jws);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *OperationalLimitsGroup, allocator: std.mem.Allocator) void {
        self.properties.deinit(allocator);
        if (self.current_limits) |*cl| {
            cl.deinit(allocator);
        }
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
    selected_op_lims_group1_id: ?[]const u8,
    selected_op_lims_group2_id: ?[]const u8,
    op_lims_groups1: std.ArrayListUnmanaged(OperationalLimitsGroup),
    op_lims_groups2: std.ArrayListUnmanaged(OperationalLimitsGroup),
    aliases: std.ArrayListUnmanaged(Alias),

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
        if (self.selected_op_lims_group1_id) |id| {
            try jws.objectField("selectedOperationalLimitsGroupId1");
            try jws.write(id);
        }
        if (self.selected_op_lims_group2_id) |id| {
            try jws.objectField("selectedOperationalLimitsGroupId2");
            try jws.write(id);
        }
        if (self.aliases.items.len > 0) {
            try jws.objectField("aliases");
            try jws.write(self.aliases.items);
        }
        if (self.ratio_tap_changer) |tc| {
            try jws.objectField("ratioTapChanger");
            try jws.write(tc);
        }
        if (self.phase_tap_changer) |tc| {
            try jws.objectField("phaseTapChanger");
            try jws.write(tc);
        }
        try write_op_lims_groups(jws, "operationalLimitsGroups1", self.op_lims_groups1);
        try write_op_lims_groups(jws, "operationalLimitsGroups2", self.op_lims_groups2);
        try jws.endObject();
    }

    pub fn deinit(self: *TwoWindingsTransformer, allocator: std.mem.Allocator) void {
        if (self.ratio_tap_changer) |*rtc| {
            rtc.deinit(allocator);
        }
        if (self.phase_tap_changer) |*ptc| {
            ptc.deinit(allocator);
        }
        for (self.op_lims_groups1.items) |*olg| {
            olg.deinit(allocator);
        }
        self.op_lims_groups1.deinit(allocator);
        for (self.op_lims_groups2.items) |*olg| {
            olg.deinit(allocator);
        }
        self.op_lims_groups2.deinit(allocator);
        self.aliases.deinit(allocator);
    }
};

pub const ThreeWindingsTransformer = struct {
    id: []const u8,
    name: ?[]const u8,
    rated_u0: f64,
    voltage_level_id1: []const u8,
    node1: u32,
    voltage_level_id2: []const u8,
    node2: u32,
    voltage_level_id3: []const u8,
    node3: u32,
    r1: f64,
    x1: f64,
    g1: f64,
    b1: f64,
    rated_u1: f64,
    rated_s1: ?f64,
    r2: f64,
    x2: f64,
    g2: f64,
    b2: f64,
    rated_u2: f64,
    rated_s2: ?f64,
    r3: f64,
    x3: f64,
    g3: f64,
    b3: f64,
    rated_u3: f64,
    rated_s3: ?f64,
    selected_op_lims_group_id1: ?[]const u8,
    selected_op_lims_group_id2: ?[]const u8,
    selected_op_lims_group_id3: ?[]const u8,
    aliases: std.ArrayListUnmanaged(Alias),
    ratio_tap_changer1: ?RatioTapChanger,
    ratio_tap_changer2: ?RatioTapChanger,
    ratio_tap_changer3: ?RatioTapChanger,
    op_lims_groups1: std.ArrayListUnmanaged(OperationalLimitsGroup),
    op_lims_groups2: std.ArrayListUnmanaged(OperationalLimitsGroup),
    op_lims_groups3: std.ArrayListUnmanaged(OperationalLimitsGroup),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("ratedU0");
        try writeFloat(jws, self.rated_u0);
        try jws.objectField("voltageLevelId1");
        try jws.write(self.voltage_level_id1);
        try jws.objectField("node1");
        try jws.write(self.node1);
        try jws.objectField("voltageLevelId2");
        try jws.write(self.voltage_level_id2);
        try jws.objectField("node2");
        try jws.write(self.node2);
        try jws.objectField("voltageLevelId3");
        try jws.write(self.voltage_level_id3);
        try jws.objectField("node3");
        try jws.write(self.node3);
        try jws.objectField("r1");
        try writeFloat(jws, self.r1);
        try jws.objectField("x1");
        try writeFloat(jws, self.x1);
        try jws.objectField("g1");
        try writeFloat(jws, self.g1);
        try jws.objectField("b1");
        try writeFloat(jws, self.b1);
        try jws.objectField("ratedU1");
        try writeFloat(jws, self.rated_u1);
        if (self.rated_s1) |rs| {
            try jws.objectField("ratedS1");
            try writeFloat(jws, rs);
        }
        try jws.objectField("r2");
        try writeFloat(jws, self.r2);
        try jws.objectField("x2");
        try writeFloat(jws, self.x2);
        try jws.objectField("g2");
        try writeFloat(jws, self.g2);
        try jws.objectField("b2");
        try writeFloat(jws, self.b2);
        try jws.objectField("ratedU2");
        try writeFloat(jws, self.rated_u2);
        if (self.rated_s2) |rs| {
            try jws.objectField("ratedS2");
            try writeFloat(jws, rs);
        }
        try jws.objectField("r3");
        try writeFloat(jws, self.r3);
        try jws.objectField("x3");
        try writeFloat(jws, self.x3);
        try jws.objectField("g3");
        try writeFloat(jws, self.g3);
        try jws.objectField("b3");
        try writeFloat(jws, self.b3);
        try jws.objectField("ratedU3");
        try writeFloat(jws, self.rated_u3);
        if (self.rated_s3) |rs| {
            try jws.objectField("ratedS3");
            try writeFloat(jws, rs);
        }
        if (self.selected_op_lims_group_id1) |sid| {
            try jws.objectField("selectedOperationalLimitsGroupId1");
            try jws.write(sid);
        }
        if (self.selected_op_lims_group_id2) |sid| {
            try jws.objectField("selectedOperationalLimitsGroupId2");
            try jws.write(sid);
        }
        if (self.selected_op_lims_group_id3) |sid| {
            try jws.objectField("selectedOperationalLimitsGroupId3");
            try jws.write(sid);
        }
        if (self.aliases.items.len > 0) {
            try jws.objectField("aliases");
            try jws.write(self.aliases.items);
        }
        if (self.ratio_tap_changer1) |tc| {
            try jws.objectField("ratioTapChanger1");
            try jws.write(tc);
        }
        if (self.ratio_tap_changer2) |tc| {
            try jws.objectField("ratioTapChanger2");
            try jws.write(tc);
        }
        if (self.ratio_tap_changer3) |tc| {
            try jws.objectField("ratioTapChanger3");
            try jws.write(tc);
        }
        try write_op_lims_groups(jws, "operationalLimitsGroups1", self.op_lims_groups1);
        try write_op_lims_groups(jws, "operationalLimitsGroups2", self.op_lims_groups2);
        try write_op_lims_groups(jws, "operationalLimitsGroups3", self.op_lims_groups3);
        try jws.endObject();
    }

    pub fn deinit(self: *ThreeWindingsTransformer, allocator: std.mem.Allocator) void {
        if (self.ratio_tap_changer1) |*rtc| rtc.deinit(allocator);
        if (self.ratio_tap_changer2) |*rtc| rtc.deinit(allocator);
        if (self.ratio_tap_changer3) |*rtc| rtc.deinit(allocator);
        for (self.op_lims_groups1.items) |*olg| olg.deinit(allocator);
        self.op_lims_groups1.deinit(allocator);
        for (self.op_lims_groups2.items) |*olg| olg.deinit(allocator);
        self.op_lims_groups2.deinit(allocator);
        for (self.op_lims_groups3.items) |*olg| olg.deinit(allocator);
        self.op_lims_groups3.deinit(allocator);
        self.aliases.deinit(allocator);
    }
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
    aliases: std.ArrayListUnmanaged(Alias),
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
        if (self.aliases.items.len > 0) {
            try jws.objectField("aliases");
            try jws.write(self.aliases.items);
        }
        if (self.properties.items.len > 0) {
            try jws.objectField("properties");
            try jws.write(self.properties.items);
        }
        try jws.objectField("voltageLevels");
        try jws.write(self.voltage_levels.items);

        if (self.two_winding_transformers.items.len > 0) {
            try jws.objectField("twoWindingsTransformers");
            try jws.write(self.two_winding_transformers.items);
        }
        if (self.three_winding_transformers.items.len > 0) {
            try jws.objectField("threeWindingsTransformers");
            try jws.write(self.three_winding_transformers.items);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *Substation, allocator: std.mem.Allocator) void {
        for (self.voltage_levels.items) |*voltage_level| {
            voltage_level.deinit(allocator);
        }
        self.voltage_levels.deinit(allocator);
        for (self.two_winding_transformers.items) |*twt| {
            twt.deinit(allocator);
        }
        self.two_winding_transformers.deinit(allocator);
        for (self.three_winding_transformers.items) |*twt| {
            twt.deinit(allocator);
        }
        self.three_winding_transformers.deinit(allocator);
        self.aliases.deinit(allocator);
        self.properties.deinit(allocator);
        self.geo_tags.deinit(allocator);
    }
};

pub const Line = struct {
    id: []const u8,
    name: ?[]const u8,
    voltage_level1_id: []const u8,
    node1: u32,
    voltage_level2_id: []const u8,
    node2: u32,
    r: f64,
    x: f64,
    g1: f64,
    g2: f64,
    b1: f64,
    b2: f64,
    selected_op_lims_group1_id: ?[]const u8 = null,
    selected_op_lims_group2_id: ?[]const u8 = null,
    aliases: std.ArrayListUnmanaged(Alias),
    properties: std.ArrayListUnmanaged(Property),
    op_lims_groups1: std.ArrayListUnmanaged(OperationalLimitsGroup),
    op_lims_groups2: std.ArrayListUnmanaged(OperationalLimitsGroup),

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
        try jws.objectField("g1");
        try writeFloat(jws, self.g1);
        try jws.objectField("b1");
        try writeFloat(jws, self.b1);
        try jws.objectField("g2");
        try writeFloat(jws, self.g2);
        try jws.objectField("b2");
        try writeFloat(jws, self.b2);
        try jws.objectField("voltageLevelId1");
        try jws.write(self.voltage_level1_id);
        try jws.objectField("node1");
        try jws.write(self.node1);
        try jws.objectField("voltageLevelId2");
        try jws.write(self.voltage_level2_id);
        try jws.objectField("node2");
        try jws.write(self.node2);
        if (self.selected_op_lims_group1_id) |id| {
            try jws.objectField("selectedOperationalLimitsGroupId1");
            try jws.write(id);
        }
        if (self.selected_op_lims_group2_id) |id| {
            try jws.objectField("selectedOperationalLimitsGroupId2");
            try jws.write(id);
        }
        if (self.aliases.items.len > 0) {
            try jws.objectField("aliases");
            try jws.write(self.aliases.items);
        }
        if (self.properties.items.len > 0) {
            try jws.objectField("properties");
            try jws.write(self.properties.items);
        }
        try write_op_lims_groups(jws, "operationalLimitsGroups1", self.op_lims_groups1);
        try write_op_lims_groups(jws, "operationalLimitsGroups2", self.op_lims_groups2);
        try jws.endObject();
    }

    pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
        self.aliases.deinit(allocator);
        self.properties.deinit(allocator);
        for (self.op_lims_groups1.items) |*olg| {
            olg.deinit(allocator);
        }
        self.op_lims_groups1.deinit(allocator);
        for (self.op_lims_groups2.items) |*olg| {
            olg.deinit(allocator);
        }
        self.op_lims_groups2.deinit(allocator);
    }
};

pub const HvdcConvertersMode = enum {
    side_1_rectifier_side_2_inverter,
    side_1_inverter_side_2_rectifier,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.write(switch (self) {
            .side_1_rectifier_side_2_inverter => "SIDE_1_RECTIFIER_SIDE_2_INVERTER",
            .side_1_inverter_side_2_rectifier => "SIDE_1_INVERTER_SIDE_2_RECTIFIER",
        });
    }
};

pub const HvdcLine = struct {
    id: []const u8,
    name: ?[]const u8,
    r: f64,
    nominal_voltage: f64,
    converters_mode: HvdcConvertersMode,
    active_power_setpoint: f64,
    max_p: f64,
    converter_station_1: []const u8,
    converter_station_2: []const u8,
    aliases: std.ArrayListUnmanaged(Alias),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("r");
        try writeFloat(jws, self.r);
        try jws.objectField("nominalV");
        try writeFloat(jws, self.nominal_voltage);
        try jws.objectField("convertersMode");
        try self.converters_mode.jsonStringify(jws);
        try jws.objectField("activePowerSetpoint");
        try writeFloat(jws, self.active_power_setpoint);
        try jws.objectField("maxP");
        try writeFloat(jws, self.max_p);
        try jws.objectField("converterStation1");
        try jws.write(self.converter_station_1);
        try jws.objectField("converterStation2");
        try jws.write(self.converter_station_2);
        if (self.aliases.items.len > 0) {
            try jws.objectField("aliases");
            try jws.write(self.aliases.items);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *HvdcLine, allocator: std.mem.Allocator) void {
        self.aliases.deinit(allocator);
    }
};

// Extension types
pub const TapChangerInfo = struct {
    id: []const u8,
    tap_changer_type: ?[]const u8 = null, // e.g., "PhaseTapChangerTabular"
    step: i32,
    control_id: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        if (self.tap_changer_type) |t| {
            try jws.objectField("type");
            try jws.write(t);
        }
        try jws.objectField("step");
        try jws.write(self.step);
        if (self.control_id) |c| {
            try jws.objectField("controlId");
            try jws.write(c);
        }
        try jws.endObject();
    }
};

pub const CgmesTapChangers = struct {
    tap_changers: std.ArrayListUnmanaged(TapChangerInfo),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("tapChangers");
        try jws.write(self.tap_changers.items);
        try jws.endObject();
    }

    pub fn deinit(self: *CgmesTapChangers, allocator: std.mem.Allocator) void {
        self.tap_changers.deinit(allocator);
    }
};

pub const VoltagePerReactivePowerControl = struct {
    slope: f64,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("slope");
        try writeFloat(jws, self.slope);
        try jws.endObject();
    }
};

pub const ModelProfile = struct {
    content: []const u8,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("content");
        try jws.write(self.content);
        try jws.endObject();
    }
};

/// A "dependentOn" model reference inside cgmesMetadataModels.
pub const DependentOnModel = struct {
    content: []const u8,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("content");
        try jws.write(self.content);
        try jws.endObject();
    }
};

pub const MetadataModel = struct {
    subset: []const u8,
    modeling_authority_set: []const u8,
    id: []const u8,
    version: u32,
    /// Heap-allocated (XML entities decoded). Freed by deinit.
    description: []u8,
    profiles: std.ArrayListUnmanaged(ModelProfile),
    dependent_on_models: std.ArrayListUnmanaged(DependentOnModel) = .empty,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("subset");
        try jws.write(self.subset);
        try jws.objectField("modelingAuthoritySet");
        try jws.write(self.modeling_authority_set);
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("version");
        try jws.write(self.version);
        try jws.objectField("description");
        try jws.write(self.description);
        try jws.objectField("profiles");
        try jws.write(self.profiles.items);
        if (self.dependent_on_models.items.len > 0) {
            try jws.objectField("dependentOnModels");
            try jws.write(self.dependent_on_models.items);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *MetadataModel, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        self.profiles.deinit(allocator);
        self.dependent_on_models.deinit(allocator);
    }
};

pub const CgmesMetadataModels = struct {
    models: std.ArrayListUnmanaged(MetadataModel),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("models");
        try jws.write(self.models.items);
        try jws.endObject();
    }

    pub fn deinit(self: *CgmesMetadataModels, allocator: std.mem.Allocator) void {
        for (self.models.items) |*m| m.deinit(allocator);
        self.models.deinit(allocator);
    }
};

pub const BaseVoltage = struct {
    nominal_voltageoltage: f64,
    source: []const u8,
    id: []const u8,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("nominalVoltage");
        try writeFloat(jws, self.nominal_voltageoltage);
        try jws.objectField("source");
        try jws.write(self.source);
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.endObject();
    }
};

pub const BaseVoltageMapping = struct {
    base_voltages: std.ArrayListUnmanaged(BaseVoltage),

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("baseVoltages");
        try jws.write(self.base_voltages.items);
        try jws.endObject();
    }

    pub fn deinit(self: *BaseVoltageMapping, allocator: std.mem.Allocator) void {
        self.base_voltages.deinit(allocator);
    }
};

pub const CimCharacteristics = struct {
    topology_kind: []const u8,
    cim_version: u32,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("topologyKind");
        try jws.write(self.topology_kind);
        try jws.objectField("cimVersion");
        try jws.write(self.cim_version);
        try jws.endObject();
    }
};

pub const LoadDetail = struct {
    fixed_active_power: f64,
    fixed_reactive_power: f64,
    variable_active_power: f64,
    variable_reactive_power: f64,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("fixedActivePower");
        try writeFloat(jws, self.fixed_active_power);
        try jws.objectField("fixedReactivePower");
        try writeFloat(jws, self.fixed_reactive_power);
        try jws.objectField("variableActivePower");
        try writeFloat(jws, self.variable_active_power);
        try jws.objectField("variableReactivePower");
        try writeFloat(jws, self.variable_reactive_power);
        try jws.endObject();
    }
};

pub const CoordinatedReactiveControl = struct {
    q_percent: f64,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("qPercent");
        try writeFloat(jws, self.q_percent);
        try jws.endObject();
    }
};

pub const Extension = struct {
    id: []const u8,
    cgmes_tap_changers: ?CgmesTapChangers = null,
    voltage_per_reactive_power_control: ?VoltagePerReactivePowerControl = null,
    cgmes_metadata_models: ?CgmesMetadataModels = null,
    base_voltage_mapping: ?BaseVoltageMapping = null,
    cim_characteristics: ?CimCharacteristics = null,
    detail: ?LoadDetail = null,
    coordinated_reactive_control: ?CoordinatedReactiveControl = null,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        if (self.cgmes_tap_changers) |tc| {
            try jws.objectField("cgmesTapChangers");
            try tc.jsonStringify(jws);
        }
        if (self.voltage_per_reactive_power_control) |v| {
            try jws.objectField("voltagePerReactivePowerControl");
            try v.jsonStringify(jws);
        }
        if (self.cgmes_metadata_models) |m| {
            try jws.objectField("cgmesMetadataModels");
            try m.jsonStringify(jws);
        }
        if (self.base_voltage_mapping) |b| {
            try jws.objectField("baseVoltageMapping");
            try b.jsonStringify(jws);
        }
        if (self.cim_characteristics) |c| {
            try jws.objectField("cimCharacteristics");
            try c.jsonStringify(jws);
        }
        if (self.detail) |d| {
            try jws.objectField("detail");
            try d.jsonStringify(jws);
        }
        if (self.coordinated_reactive_control) |crc| {
            try jws.objectField("coordinatedReactiveControl");
            try crc.jsonStringify(jws);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *Extension, allocator: std.mem.Allocator) void {
        if (self.cgmes_tap_changers) |*tc| tc.deinit(allocator);
        if (self.cgmes_metadata_models) |*m| m.deinit(allocator);
        if (self.base_voltage_mapping) |*b| b.deinit(allocator);
    }
};

pub const ExtensionVersion = struct {
    extension_name: []const u8,
    version: []const u8 = "1.0",

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("extensionName");
        try jws.write(self.extension_name);
        try jws.objectField("version");
        try jws.write(self.version);
        try jws.endObject();
    }
};

pub const AreaBoundary = struct {
    id: []const u8,
    side: []const u8, // "ONE" or "TWO"

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("ac");
        try jws.write(true);
        try jws.objectField("type");
        try jws.write("terminalRef");
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("side");
        try jws.write(self.side);
        try jws.endObject();
    }
};

pub const Area = struct {
    id: []const u8,
    name: []const u8,
    area_type: []const u8,
    boundaries: std.ArrayListUnmanaged(AreaBoundary) = .empty,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("areaType");
        try jws.write(self.area_type);
        try jws.objectField("areaBoundaries");
        try jws.write(self.boundaries.items);
        try jws.endObject();
    }

    pub fn deinit(self: *Area, allocator: std.mem.Allocator) void {
        self.boundaries.deinit(allocator);
    }
};

pub const Network = struct {
    id: []const u8, // taken from FullModel rdf:about
    case_date: ?[]const u8, // taken from FullModel -> Model.scenarioTime
    forecast_distance: u32 = 0, // minutes between Model.created and Model.scenarioTime
    substations: std.ArrayListUnmanaged(Substation),
    fictitious_voltage_levels: std.ArrayListUnmanaged(FictitiousVoltageLevel) = .empty,
    lines: std.ArrayListUnmanaged(Line),
    hvdc_lines: std.ArrayListUnmanaged(HvdcLine),
    areas: std.ArrayListUnmanaged(Area) = .empty,
    extensions: std.ArrayListUnmanaged(Extension),
    extension_versions: std.ArrayListUnmanaged(ExtensionVersion) = .empty,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("version");
        try jws.write("1.15");
        if (self.extension_versions.items.len > 0) {
            try jws.objectField("extensionVersions");
            try jws.write(self.extension_versions.items);
        }
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("caseDate");
        try write_date_with_millis(jws, self.case_date);
        try jws.objectField("forecastDistance");
        try jws.write(self.forecast_distance);
        try jws.objectField("sourceFormat");
        try jws.write("CGMES");
        try jws.objectField("minimumValidationLevel");
        try jws.write("EQUIPMENT");
        try jws.objectField("substations");
        try jws.beginArray();
        for (self.substations.items) |substation| {
            if (substation.voltage_levels.items.len == 0) continue;
            try jws.write(substation);
        }
        try jws.endArray();
        if (self.fictitious_voltage_levels.items.len > 0) {
            try jws.objectField("voltageLevels");
            try jws.write(self.fictitious_voltage_levels.items);
        }
        try jws.objectField("lines");
        try jws.write(self.lines.items);
        if (self.hvdc_lines.items.len > 0) {
            try jws.objectField("hvdcLines");
            try jws.write(self.hvdc_lines.items);
        }
        if (self.areas.items.len > 0) {
            try jws.objectField("areas");
            try jws.write(self.areas.items);
        }
        if (self.extensions.items.len > 0) {
            try jws.objectField("extensions");
            try jws.write(self.extensions.items);
        }
        try jws.endObject();
    }

    pub fn deinit(self: *Network, allocator: std.mem.Allocator) void {
        for (self.substations.items) |*substation| {
            substation.deinit(allocator);
        }
        self.substations.deinit(allocator);
        for (self.fictitious_voltage_levels.items) |*fvoltage_level| {
            fvoltage_level.deinit(allocator);
        }
        self.fictitious_voltage_levels.deinit(allocator);
        for (self.lines.items) |*line| {
            line.deinit(allocator);
        }
        self.lines.deinit(allocator);
        for (self.hvdc_lines.items) |*hvdc| {
            hvdc.deinit(allocator);
        }
        self.hvdc_lines.deinit(allocator);
        for (self.areas.items) |*area| {
            area.deinit(allocator);
        }
        self.areas.deinit(allocator);
        for (self.extensions.items) |*ext| {
            ext.deinit(allocator);
        }
        self.extensions.deinit(allocator);
        self.extension_versions.deinit(allocator);
    }
};
