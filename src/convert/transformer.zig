const std = @import("std");
const iidm = @import("../iidm.zig");
const cim_model = @import("../cgmes/eq.zig");
const cim_index = @import("../cim_index.zig");
const tag_index = @import("../cgmes/tag_index.zig");
const utils = @import("../cgmes/ids.zig");
const topology = @import("../topology.zig");

const assert = std.debug.assert;
const testing = std.testing;

const CimModel = cim_model.CimModel;
const CimObject = tag_index.CimObject;
const CimObjectView = tag_index.CimObjectView;
const CimIndex = cim_index.CimIndex;
const placement_mod = @import("placement.zig");

const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;
const Placement = placement_mod.Placement;
const TerminalPlacer = placement_mod.TerminalPlacer;
const resolve_terminal_placement = placement_mod.resolve_terminal_placement;
const NodeMap = topology.NodeMap;
const max_tap_steps = 10_000;

fn build_ends_by_transformer(
    gpa: std.mem.Allocator,
    model: *const CimModel,
) !std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObjectView)) {
    var ends_by_transformer: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObjectView)) = .empty;

    const ends = model.get_objects_by_type("PowerTransformerEnd");

    try ends_by_transformer.ensureTotalCapacity(gpa, @intCast(ends.len));

    for (ends) |end| {
        const end_view = model.view(end);
        const transformer_ref = try end_view.getReference("PowerTransformerEnd.PowerTransformer") orelse continue;
        const transformer_id = strip_hash(transformer_ref);

        const gop = ends_by_transformer.getOrPutAssumeCapacity(transformer_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, end_view);
    }

    var it = ends_by_transformer.valueIterator();
    while (it.next()) |transformer_ends| {
        std.sort.block(CimObjectView, transformer_ends.items, {}, view_less_than);
    }

    assert(ends.len == 0 or ends_by_transformer.count() > 0);

    return ends_by_transformer;
}

const TapChangerCommon = struct { low_step: i32, normal_step: i32, ltc_flag: bool };

fn read_tap_changer_regulating(
    model: *const CimModel,
    tap_changer: CimObjectView,
    ssh_opt: ?@import("../cgmes/ssh.zig").CimSsh,
) !?bool {
    const control_ref = try tap_changer.getReference("TapChanger.TapChangerControl") orelse return null;
    if (ssh_opt) |ssh| {
        const control_id = strip_hash(control_ref);
        const control_mrid = if (model.getObjectById(control_id)) |control_view|
            (try control_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(control_id))
        else
            strip_underscore(control_id);
        const enabled = try ssh.getProperty(control_mrid, "RegulatingCondEq.controlEnabled") orelse "false";
        return std.mem.eql(u8, enabled, "true");
    }
    return false;
}

fn read_tap_changer_common(tap_changer: CimObjectView) !?TapChangerCommon {
    const props = try tap_changer.getProperties(.{
        "TapChanger.lowStep",
        "TapChanger.normalStep",
        "TapChanger.ltcFlag",
    });
    const low_step_str = props[0] orelse return null;
    const low_step = try std.fmt.parseInt(i32, low_step_str, 10);
    const normal_step_str = props[1] orelse return null;
    const normal_step = try std.fmt.parseInt(i32, normal_step_str, 10);
    const ltc_flag_str = props[2] orelse return null;
    const ltc_flag = std.mem.eql(u8, ltc_flag_str, "true");
    return .{ .low_step = low_step, .normal_step = normal_step, .ltc_flag = ltc_flag };
}

// Raw CGMES step values. rho transform differs between ratio (invert) and phase (passthrough)
// tap changers, so the caller applies it.
const TapChangerBaseStep = struct { r: f64, x: f64, g: f64, b: f64, cgmes_ratio: f64 };

fn read_tap_changer_base_step(point: CimObjectView) !?TapChangerBaseStep {
    const props = try point.getProperties(.{
        "TapChangerTablePoint.r",
        "TapChangerTablePoint.x",
        "TapChangerTablePoint.g",
        "TapChangerTablePoint.b",
        "TapChangerTablePoint.ratio",
    });
    const r = try std.fmt.parseFloat(f64, props[0] orelse "0.0");
    const x = try std.fmt.parseFloat(f64, props[1] orelse "0.0");
    const g = try std.fmt.parseFloat(f64, props[2] orelse "0.0");
    const b = try std.fmt.parseFloat(f64, props[3] orelse "0.0");
    const ratio_str = props[4] orelse return null;
    const cgmes_ratio = try std.fmt.parseFloat(f64, ratio_str);
    return .{ .r = r, .x = x, .g = g, .b = b, .cgmes_ratio = cgmes_ratio };
}

const OrderedRatioStep = struct {
    step_num: i32,
    step: iidm.RatioTapChangerStep,
    fn less_than(_: void, a: @This(), b: @This()) bool {
        return a.step_num < b.step_num;
    }
};

fn build_ratio_table_points(
    gpa: std.mem.Allocator,
    model: *const CimModel,
) !std.StringHashMapUnmanaged(std.ArrayListUnmanaged(OrderedRatioStep)) {
    const tables = model.get_objects_by_type("RatioTapChangerTable");
    const points = model.get_objects_by_type("RatioTapChangerTablePoint");
    var points_by_table: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(OrderedRatioStep)) = .empty;
    try points_by_table.ensureTotalCapacity(gpa, @intCast(tables.len));
    for (points) |point| {
        const point_view = model.view(point);
        const table_ref = try point_view.getReference("RatioTapChangerTablePoint.RatioTapChangerTable") orelse continue;
        const base = try read_tap_changer_base_step(point_view) orelse continue;
        const step_num_str = try point_view.getProperty("TapChangerTablePoint.step") orelse continue;
        const step_num = try std.fmt.parseInt(i32, step_num_str, 10);
        // pypowsybl inverts cgmes_ratio for ratio tap changers.
        const rho = if (base.cgmes_ratio != 0.0) 1.0 / base.cgmes_ratio else 1.0;
        const gop = points_by_table.getOrPutAssumeCapacity(strip_hash(table_ref));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, .{
            .step_num = step_num,
            .step = .{ .r = base.r, .x = base.x, .g = base.g, .b = base.b, .rho = rho },
        });
    }
    // CGMES does not guarantee TablePoint XML order matches step order — sort explicitly.
    var sort_it = points_by_table.valueIterator();
    while (sort_it.next()) |list| std.sort.block(OrderedRatioStep, list.items, {}, OrderedRatioStep.less_than);
    assert(points.len == 0 or points_by_table.count() > 0);
    return points_by_table;
}

fn build_linear_ratio_steps(
    gpa: std.mem.Allocator,
    tap_changer: CimObjectView,
    low_step: i32,
) !?std.ArrayListUnmanaged(iidm.RatioTapChangerStep) {
    const high_step_str = try tap_changer.getProperty("TapChanger.highStep") orelse return null;
    const high_step = try std.fmt.parseInt(i32, high_step_str, 10);
    const neutral_step_str = try tap_changer.getProperty("TapChanger.neutralStep") orelse return null;
    const neutral_step = try std.fmt.parseInt(i32, neutral_step_str, 10);
    const increment_str = try tap_changer.getProperty("RatioTapChanger.stepVoltageIncrement") orelse return null;
    const increment = try std.fmt.parseFloat(f64, increment_str);

    if (high_step < low_step) return error.InvalidTapStepRange;
    const step_count_i64 = @as(i64, high_step) - @as(i64, low_step) + 1;
    if (step_count_i64 > max_tap_steps) return error.TapStepRangeTooLarge;
    const step_count: usize = @intCast(step_count_i64);

    var steps: std.ArrayListUnmanaged(iidm.RatioTapChangerStep) = .empty;
    try steps.ensureTotalCapacity(gpa, step_count);
    for (0..step_count) |i| {
        const step: i32 = low_step + @as(i32, @intCast(i));
        // pypowsybl emits rho = 1 / cgmes_ratio; CGMES linear ratio at step = 1 + (step-neutral)*inc/100.
        const offset = @as(i64, step) - @as(i64, neutral_step);
        const cgmes_ratio = 1.0 + @as(f64, @floatFromInt(offset)) * increment / 100.0;
        const rho = if (cgmes_ratio != 0.0) 1.0 / cgmes_ratio else 1.0;
        steps.appendAssumeCapacity(.{ .r = 0.0, .x = 0.0, .g = 0.0, .b = 0.0, .rho = rho });
    }
    assert(steps.items.len > 0);
    return steps;
}

const RatioTapChangerEntry = struct {
    mrid: []const u8,
    tap_changer: iidm.RatioTapChanger,

    fn deinit(self: *RatioTapChangerEntry, gpa: std.mem.Allocator) void {
        self.tap_changer.deinit(gpa);
    }
};

const PhaseTapChangerEntry = struct {
    mrid: []const u8,
    tap_changer: iidm.PhaseTapChanger,

    fn deinit(self: *PhaseTapChangerEntry, gpa: std.mem.Allocator) void {
        self.tap_changer.deinit(gpa);
    }
};

fn build_ratio_tap_changer_map(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    ssh_opt: ?@import("../cgmes/ssh.zig").CimSsh,
) !std.StringHashMapUnmanaged(RatioTapChangerEntry) {
    var points_by_table = try build_ratio_table_points(gpa, model);
    defer {
        var it = points_by_table.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        points_by_table.deinit(gpa);
    }

    const tap_changers = model.get_objects_by_type("RatioTapChanger");
    var ratio_tap_changer_map: std.StringHashMapUnmanaged(RatioTapChangerEntry) = .empty;
    try ratio_tap_changer_map.ensureTotalCapacity(gpa, @intCast(tap_changers.len));

    for (tap_changers) |tap_changer| {
        const tap_changer_view = model.view(tap_changer);
        const end_ref = try tap_changer_view.getReference("RatioTapChanger.TransformerEnd") orelse continue;
        const common = try read_tap_changer_common(tap_changer_view) orelse continue;
        const regulating = try read_tap_changer_regulating(model, tap_changer_view, ssh_opt);

        const owned_steps = if (try tap_changer_view.getReference("RatioTapChanger.RatioTapChangerTable")) |table_ref| blk: {
            const ordered = points_by_table.get(strip_hash(table_ref)) orelse continue;
            var s: std.ArrayListUnmanaged(iidm.RatioTapChangerStep) = .empty;
            try s.ensureTotalCapacity(gpa, ordered.items.len);
            for (ordered.items) |os| s.appendAssumeCapacity(os.step);
            break :blk s;
        } else blk: {
            break :blk try build_linear_ratio_steps(gpa, tap_changer_view, common.low_step) orelse continue;
        };

        const mrid = try tap_changer_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(tap_changer.id);
        ratio_tap_changer_map.putAssumeCapacity(strip_hash(end_ref), .{
            .mrid = mrid,
            .tap_changer = .{
                .low_tap_position = common.low_step,
                .tap_position = common.normal_step,
                .load_tap_changing_capabilities = common.ltc_flag,
                .regulating = if (common.ltc_flag) (regulating orelse false) else null,
                .regulation_mode = null,
                .terminal_ref = null,
                .steps = owned_steps,
            },
        });
    }
    return ratio_tap_changer_map;
}

const OrderedPhaseStep = struct {
    step_num: i32,
    step: iidm.PhaseTapChangerStep,
    fn less_than(_: void, a: @This(), b: @This()) bool {
        return a.step_num < b.step_num;
    }
};

fn build_phase_tap_changer_map(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    ssh_opt: ?@import("../cgmes/ssh.zig").CimSsh,
) !std.StringHashMapUnmanaged(PhaseTapChangerEntry) {
    var points_by_table: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(OrderedPhaseStep)) = .empty;
    defer {
        var it = points_by_table.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        points_by_table.deinit(gpa);
    }

    const tables = model.get_objects_by_type("PhaseTapChangerTable");
    try points_by_table.ensureTotalCapacity(gpa, @intCast(tables.len));

    const points = model.get_objects_by_type("PhaseTapChangerTablePoint");

    // Build RAW (pre-movement) steps keyed by table. Scaling and rho/alpha movement
    // depend on which end the tap changer sits on; both are applied per tap changer below.
    for (points) |point| {
        const point_view = model.view(point);
        const table_ref = try point_view.getReference("PhaseTapChangerTablePoint.PhaseTapChangerTable") orelse continue;
        const table_id = strip_hash(table_ref);

        const base = try read_tap_changer_base_step(point_view) orelse continue;
        const alpha_str = try point_view.getProperty("PhaseTapChangerTablePoint.angle") orelse "0.0";
        const alpha = try std.fmt.parseFloat(f64, alpha_str);
        const step_num_str = try point_view.getProperty("TapChangerTablePoint.step") orelse continue;
        const step_num = try std.fmt.parseInt(i32, step_num_str, 10);

        const gop = points_by_table.getOrPutAssumeCapacity(table_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, .{
            .step_num = step_num,
            .step = .{
                .r = base.r,
                .x = base.x,
                .g = base.g,
                .b = base.b,
                .rho = base.cgmes_ratio,
                .alpha = alpha,
            },
        });
    }

    // CGMES does not guarantee TablePoint XML order matches step order — sort explicitly.
    var sort_it = points_by_table.valueIterator();
    while (sort_it.next()) |list| std.sort.block(OrderedPhaseStep, list.items, {}, OrderedPhaseStep.less_than);

    const tap_changers = model.get_objects_by_type("PhaseTapChangerTabular");

    var phase_tap_changer_map: std.StringHashMapUnmanaged(PhaseTapChangerEntry) = .empty;
    try phase_tap_changer_map.ensureTotalCapacity(gpa, @intCast(tap_changers.len));

    for (tap_changers) |tap_changer| {
        const tap_changer_view = model.view(tap_changer);
        const end_ref = try tap_changer_view.getReference("PhaseTapChanger.TransformerEnd") orelse continue;
        const end_id = strip_hash(end_ref);
        const regulating = try read_tap_changer_regulating(model, tap_changer_view, ssh_opt);

        const common = try read_tap_changer_common(tap_changer_view) orelse continue;

        const table_ref = try tap_changer_view.getReference("PhaseTapChangerTabular.PhaseTapChangerTable") orelse continue;
        const table_id = strip_hash(table_ref);
        const ordered_steps = points_by_table.get(table_id) orelse continue;

        // IIDM stores the tap changer on side 2. Two transforms happen here:
        //   End 1 (move=true): pypowsybl moves the tap changer to end 2 by inverting rho
        //     (1/ρ for magnitude, −α for angle). r/x/g/b pass through unchanged.
        //   End 2 (move=false): rho/alpha passthrough, but r/x/g/b go through the |a|²
        //     referral formula:
        //       step.r = 100 * ((1 + cgmes_r/100) * a² - 1)
        //       step.g = 100 * ((1 + cgmes_g/100) / a² - 1)
        const end_obj = model.getObjectById(end_id) orelse continue;
        const end_number_str = try end_obj.getProperty("TransformerEnd.endNumber") orelse "0";
        const end_number = std.fmt.parseInt(u32, end_number_str, 10) catch 0;
        const move = end_number == 1;

        var owned_steps: std.ArrayListUnmanaged(iidm.PhaseTapChangerStep) = .empty;
        try owned_steps.ensureTotalCapacity(gpa, ordered_steps.items.len);
        for (ordered_steps.items) |os| {
            var step = os.step;
            if (move) {
                step.rho = if (step.rho != 0.0) 1.0 / step.rho else step.rho;
                step.alpha = -step.alpha;
            } else {
                const a2 = step.rho * step.rho;
                if (a2 != 0.0) {
                    step.r = 100.0 * ((1.0 + step.r / 100.0) * a2 - 1.0);
                    step.x = 100.0 * ((1.0 + step.x / 100.0) * a2 - 1.0);
                    step.g = 100.0 * ((1.0 + step.g / 100.0) / a2 - 1.0);
                    step.b = 100.0 * ((1.0 + step.b / 100.0) / a2 - 1.0);
                }
            }
            owned_steps.appendAssumeCapacity(step);
        }

        const mrid = try tap_changer_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(tap_changer.id);
        // PhaseTapChangerTabular maps to CURRENT_LIMITER in pypowsybl's CGMES importer.
        phase_tap_changer_map.putAssumeCapacity(end_id, .{
            .mrid = mrid,
            .tap_changer = .{
                .low_tap_position = common.low_step,
                .tap_position = common.normal_step,
                .load_tap_changing_capabilities = common.ltc_flag,
                .regulating = if (common.ltc_flag) (regulating orelse false) else null,
                .regulation_mode = "CURRENT_LIMITER",
                .steps = owned_steps,
            },
        });
    }
    return phase_tap_changer_map;
}

fn view_less_than(_: void, a: CimObjectView, b: CimObjectView) bool {
    const end_number0_str = a.getProperty("TransformerEnd.endNumber") catch "0" orelse "0";
    const end_number0 = std.fmt.parseInt(u32, end_number0_str, 10) catch 0;

    const end_number1_str = b.getProperty("TransformerEnd.endNumber") catch "0" orelse "0";
    const end_number1 = std.fmt.parseInt(u32, end_number1_str, 10) catch 0;

    return end_number0 < end_number1;
}

const TestEnd = struct { model: cim_model.CimModel, end: CimObjectView };

fn make_end(xml: []const u8) !TestEnd {
    const model = try cim_model.CimModel.init(testing.allocator, try testing.allocator.dupe(u8, xml));
    return .{ .model = model, .end = model.view(model.get_objects_by_type("PowerTransformerEnd")[0]) };
}

test "view_less_than: end 1 < end 2" {
    var t1 = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e1">
        \\  <cim:TransformerEnd.endNumber>1</cim:TransformerEnd.endNumber>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer t1.model.deinit(testing.allocator);
    var t2 = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e2">
        \\  <cim:TransformerEnd.endNumber>2</cim:TransformerEnd.endNumber>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer t2.model.deinit(testing.allocator);
    try testing.expect(view_less_than({}, t1.end, t2.end));
    try testing.expect(!view_less_than({}, t2.end, t1.end));
}

test "view_less_than: equal end numbers are not less than" {
    var t = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e1">
        \\  <cim:TransformerEnd.endNumber>2</cim:TransformerEnd.endNumber>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer t.model.deinit(testing.allocator);
    try testing.expect(!view_less_than({}, t.end, t.end));
}

test "view_less_than: missing endNumber falls back to 0, sorts before any numbered end" {
    var tm = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_em">
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer tm.model.deinit(testing.allocator);
    var t1 = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e1">
        \\  <cim:TransformerEnd.endNumber>1</cim:TransformerEnd.endNumber>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer t1.model.deinit(testing.allocator);
    try testing.expect(view_less_than({}, tm.end, t1.end));
    try testing.expect(!view_less_than({}, t1.end, tm.end));
}

test "view_less_than: end 1 < end 3" {
    var t1 = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e1">
        \\  <cim:TransformerEnd.endNumber>1</cim:TransformerEnd.endNumber>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer t1.model.deinit(testing.allocator);
    var t3 = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e3">
        \\  <cim:TransformerEnd.endNumber>3</cim:TransformerEnd.endNumber>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer t3.model.deinit(testing.allocator);
    try testing.expect(view_less_than({}, t1.end, t3.end));
    try testing.expect(!view_less_than({}, t3.end, t1.end));
}

test "view_less_than: transitivity — end1 < end2 and end2 < end3 implies end1 < end3" {
    var t1 = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e1">
        \\  <cim:TransformerEnd.endNumber>1</cim:TransformerEnd.endNumber>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer t1.model.deinit(testing.allocator);
    var t2 = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e2">
        \\  <cim:TransformerEnd.endNumber>2</cim:TransformerEnd.endNumber>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer t2.model.deinit(testing.allocator);
    var t3 = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e3">
        \\  <cim:TransformerEnd.endNumber>3</cim:TransformerEnd.endNumber>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer t3.model.deinit(testing.allocator);
    try testing.expect(view_less_than({}, t1.end, t2.end)); // end1 < end2
    try testing.expect(view_less_than({}, t2.end, t3.end)); // end2 < end3
    try testing.expect(view_less_than({}, t1.end, t3.end)); // therefore end1 < end3
}

const EndElectrical = struct { r: f64, x: f64, g: f64, b: f64, rated_u: f64, rated_s: ?f64 };

fn read_end_electrical(end: CimObjectView) !?EndElectrical {
    const props = try end.getProperties(.{
        "PowerTransformerEnd.ratedU",
        "PowerTransformerEnd.r",
        "PowerTransformerEnd.x",
        "PowerTransformerEnd.g",
        "PowerTransformerEnd.b",
        "PowerTransformerEnd.ratedS",
    });
    const rated_u = try std.fmt.parseFloat(f64, props[0] orelse return null);
    const r = try std.fmt.parseFloat(f64, props[1] orelse "0.0");
    const x = try std.fmt.parseFloat(f64, props[2] orelse "0.0");
    const g = try std.fmt.parseFloat(f64, props[3] orelse "0.0");
    const b = try std.fmt.parseFloat(f64, props[4] orelse "0.0");
    const rated_s: ?f64 = blk: {
        const s = props[5] orelse break :blk null;
        break :blk try std.fmt.parseFloat(f64, s);
    };
    return .{ .r = r, .x = x, .g = g, .b = b, .rated_u = rated_u, .rated_s = rated_s };
}

fn resolve_end_placement(
    end: CimObjectView,
    placer: TerminalPlacer,
) !?Placement {
    const terminal_ref = try end.getReference("TransformerEnd.Terminal") orelse return null;
    const terminal_id = strip_hash(terminal_ref);
    // terminal_conn_node may be missing in bus-branch mode (no CN); placer handles that.
    const conn_node_id = placer.index.terminal_conn_node.get(terminal_id);
    return placer.resolve_terminal(terminal_id, conn_node_id);
}

fn pre_allocate_transformers(
    gpa: std.mem.Allocator,
    ends_by_transformer: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObjectView)),
    substation_map: *const std.StringHashMapUnmanaged(*iidm.Substation),
    placer: TerminalPlacer,
) !void {
    assert(placer.voltage_level_map.count() > 0);

    var transformer_counts: std.AutoHashMapUnmanaged(usize, struct { two: usize, three: usize }) = .empty;
    defer transformer_counts.deinit(gpa);
    try transformer_counts.ensureTotalCapacity(gpa, @intCast(ends_by_transformer.count()));

    var it = ends_by_transformer.iterator();
    while (it.next()) |entry| {
        const ends = entry.value_ptr.*;
        const winding_count = ends.items.len;
        if (winding_count != 2 and winding_count != 3) continue;

        const placement1 = try resolve_end_placement(ends.items[0], placer) orelse continue;
        const substation = substation_map.get(placement1.repr_voltage_level_id) orelse continue;

        const gop = transformer_counts.getOrPutAssumeCapacity(@intFromPtr(substation));
        if (!gop.found_existing) gop.value_ptr.* = .{ .two = 0, .three = 0 };
        if (winding_count == 2) gop.value_ptr.two += 1 else gop.value_ptr.three += 1;
    }

    var counts_it = transformer_counts.iterator();
    while (counts_it.next()) |entry| {
        const substation: *iidm.Substation = @ptrFromInt(entry.key_ptr.*);
        try substation.two_winding_transformers.ensureTotalCapacity(gpa, entry.value_ptr.two);
        try substation.three_winding_transformers.ensureTotalCapacity(gpa, entry.value_ptr.three);
    }

    assert(transformer_counts.count() <= placer.voltage_level_map.count());
}

fn append_two_windings_transformer(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    transformer: CimObjectView,
    ends: []const CimObjectView,
    substation: *iidm.Substation,
    placer: TerminalPlacer,
    ratio_tap_changer_map: *std.StringHashMapUnmanaged(RatioTapChangerEntry),
    phase_tap_changer_map: *std.StringHashMapUnmanaged(PhaseTapChangerEntry),
) !void {
    assert(ends.len == 2);

    const p1 = try resolve_end_placement(ends[0], placer) orelse return;
    const p2 = try resolve_end_placement(ends[1], placer) orelse return;
    const e1 = try read_end_electrical(ends[0]) orelse return;
    const e2 = try read_end_electrical(ends[1]) orelse return;

    const ratio = e2.rated_u / e1.rated_u;
    const ratio2 = ratio * ratio;

    const mrid = try transformer.getProperty("IdentifiedObject.mRID") orelse strip_underscore(transformer.id);
    const name = try transformer.getProperty("IdentifiedObject.name");

    // Tap changers keyed by end rdf:ID (= end.id). Track which end (1 or 2) so we can
    // emit the correct CGMES.RatioTapChanger<N> / CGMES.PhaseTapChanger<N> alias.
    var ratio_tc: ?RatioTapChangerEntry = null;
    var ratio_tc_side: u8 = 0;
    if (ratio_tap_changer_map.fetchRemove(ends[0].id)) |kv| {
        ratio_tc = kv.value;
        ratio_tc_side = 1;
    } else if (ratio_tap_changer_map.fetchRemove(ends[1].id)) |kv| {
        ratio_tc = kv.value;
        ratio_tc_side = 2;
    }
    var phase_tc: ?PhaseTapChangerEntry = null;
    var phase_tc_side: u8 = 0;
    if (phase_tap_changer_map.fetchRemove(ends[0].id)) |kv| {
        phase_tc = kv.value;
        phase_tc_side = 1;
    } else if (phase_tap_changer_map.fetchRemove(ends[1].id)) |kv| {
        phase_tc = kv.value;
        phase_tc_side = 2;
    }

    // aliases + operational limits per terminal, keyed by end's own Terminal.
    const t1_id = strip_hash(try ends[0].getReference("TransformerEnd.Terminal") orelse return);
    const t2_id = strip_hash(try ends[1].getReference("TransformerEnd.Terminal") orelse return);

    var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
    errdefer aliases.deinit(gpa);
    try aliases.ensureTotalCapacity(gpa, 6);
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal1" }, .content = strip_underscore(t1_id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal2" }, .content = strip_underscore(t2_id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.TransformerEnd1" }, .content = strip_underscore(ends[0].id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.TransformerEnd2" }, .content = strip_underscore(ends[1].id) });
    if (ratio_tc) |rtc| {
        const type_str: []const u8 = if (ratio_tc_side == 1) "CGMES.RatioTapChanger1" else "CGMES.RatioTapChanger2";
        aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = type_str }, .content = rtc.mrid });
    }
    if (phase_tc) |ptc| {
        const type_str: []const u8 = if (phase_tc_side == 1) "CGMES.PhaseTapChanger1" else "CGMES.PhaseTapChanger2";
        aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = type_str }, .content = ptc.mrid });
    }

    var op_lims_groups_1 = try placement_mod.build_op_lims(gpa, model, placer.index, t1_id);
    errdefer {
        for (op_lims_groups_1.items) |*group| group.deinit(gpa);
        op_lims_groups_1.deinit(gpa);
    }
    var op_lims_groups_2 = try placement_mod.build_op_lims(gpa, model, placer.index, t2_id);
    errdefer {
        for (op_lims_groups_2.items) |*group| group.deinit(gpa);
        op_lims_groups_2.deinit(gpa);
    }
    const selected_1: ?[]const u8 = if (op_lims_groups_1.items.len > 0) op_lims_groups_1.items[0].id else null;
    const selected_2: ?[]const u8 = if (op_lims_groups_2.items.len > 0) op_lims_groups_2.items[0].id else null;

    substation.two_winding_transformers.appendAssumeCapacity(.{
        .id = mrid,
        .name = name,
        .r = e1.r * ratio2,
        .x = e1.x * ratio2,
        .g = e1.g / ratio2,
        .b = e1.b / ratio2,
        .rated_u1 = e1.rated_u,
        .rated_u2 = e2.rated_u,
        .rated_s = e1.rated_s,
        .voltage_level_id1 = p1.voltage_level.id,
        .node1 = p1.node,
        .bus1 = p1.bus,
        .connectable_bus1 = p1.bus,
        .voltage_level_id2 = p2.voltage_level.id,
        .node2 = p2.node,
        .bus2 = p2.bus,
        .connectable_bus2 = p2.bus,
        .ratio_tap_changer = if (ratio_tc) |e| e.tap_changer else null,
        .phase_tap_changer = if (phase_tc) |e| e.tap_changer else null,
        .selected_op_lims_group1_id = selected_1,
        .selected_op_lims_group2_id = selected_2,
        .op_lims_groups1 = op_lims_groups_1,
        .op_lims_groups2 = op_lims_groups_2,
        .aliases = aliases,
    });
}

fn append_three_windings_transformer(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    transformer: CimObjectView,
    ends: []const CimObjectView,
    substation: *iidm.Substation,
    placer: TerminalPlacer,
    ratio_tap_changer_map: *std.StringHashMapUnmanaged(RatioTapChangerEntry),
) !void {
    assert(ends.len == 3);

    const p1 = try resolve_end_placement(ends[0], placer) orelse return;
    const p2 = try resolve_end_placement(ends[1], placer) orelse return;
    const p3 = try resolve_end_placement(ends[2], placer) orelse return;
    const e1 = try read_end_electrical(ends[0]) orelse return;
    const e2 = try read_end_electrical(ends[1]) orelse return;
    const e3 = try read_end_electrical(ends[2]) orelse return;

    const mrid = try transformer.getProperty("IdentifiedObject.mRID") orelse strip_underscore(transformer.id);
    const name = try transformer.getProperty("IdentifiedObject.name");

    // Tap changers keyed by end rdf:ID (= end.id). fetchRemove takes ownership.
    const rtc1 = ratio_tap_changer_map.fetchRemove(ends[0].id);
    const rtc2 = ratio_tap_changer_map.fetchRemove(ends[1].id);
    const rtc3 = ratio_tap_changer_map.fetchRemove(ends[2].id);

    // aliases + operational limits per terminal, keyed by end's own Terminal.
    const t1_id = strip_hash(try ends[0].getReference("TransformerEnd.Terminal") orelse return);
    const t2_id = strip_hash(try ends[1].getReference("TransformerEnd.Terminal") orelse return);
    const t3_id = strip_hash(try ends[2].getReference("TransformerEnd.Terminal") orelse return);

    var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
    errdefer aliases.deinit(gpa);
    try aliases.ensureTotalCapacity(gpa, 9);
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal1" }, .content = strip_underscore(t1_id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal2" }, .content = strip_underscore(t2_id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal3" }, .content = strip_underscore(t3_id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.TransformerEnd1" }, .content = strip_underscore(ends[0].id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.TransformerEnd2" }, .content = strip_underscore(ends[1].id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.TransformerEnd3" }, .content = strip_underscore(ends[2].id) });
    if (rtc1) |kv| aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.RatioTapChanger1" }, .content = kv.value.mrid });
    if (rtc2) |kv| aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.RatioTapChanger2" }, .content = kv.value.mrid });
    if (rtc3) |kv| aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.RatioTapChanger3" }, .content = kv.value.mrid });

    var op_lims_groups_1 = try placement_mod.build_op_lims(gpa, model, placer.index, t1_id);
    errdefer {
        for (op_lims_groups_1.items) |*group| group.deinit(gpa);
        op_lims_groups_1.deinit(gpa);
    }
    var op_lims_groups_2 = try placement_mod.build_op_lims(gpa, model, placer.index, t2_id);
    errdefer {
        for (op_lims_groups_2.items) |*group| group.deinit(gpa);
        op_lims_groups_2.deinit(gpa);
    }
    var op_lims_groups_3 = try placement_mod.build_op_lims(gpa, model, placer.index, t3_id);
    errdefer {
        for (op_lims_groups_3.items) |*group| group.deinit(gpa);
        op_lims_groups_3.deinit(gpa);
    }
    const selected_1: ?[]const u8 = if (op_lims_groups_1.items.len > 0) op_lims_groups_1.items[0].id else null;
    const selected_2: ?[]const u8 = if (op_lims_groups_2.items.len > 0) op_lims_groups_2.items[0].id else null;
    const selected_3: ?[]const u8 = if (op_lims_groups_3.items.len > 0) op_lims_groups_3.items[0].id else null;

    // Refer each end's r/x/g/b to the star-point voltage (u0 = u1). Ratio per end
    // is u1/uN. Impedance scales by ratio²; admittance by 1/ratio². End 1 ratio is 1.
    const ratio2_2 = if (e2.rated_u != 0.0) (e1.rated_u / e2.rated_u) * (e1.rated_u / e2.rated_u) else 1.0;
    const ratio2_3 = if (e3.rated_u != 0.0) (e1.rated_u / e3.rated_u) * (e1.rated_u / e3.rated_u) else 1.0;

    substation.three_winding_transformers.appendAssumeCapacity(.{
        .id = mrid,
        .name = name,
        .rated_u0 = e1.rated_u, // star point voltage = HV (end1) rated voltage
        .voltage_level_id1 = p1.voltage_level.id,
        .node1 = p1.node,
        .bus1 = p1.bus,
        .connectable_bus1 = p1.bus,
        .voltage_level_id2 = p2.voltage_level.id,
        .node2 = p2.node,
        .bus2 = p2.bus,
        .connectable_bus2 = p2.bus,
        .voltage_level_id3 = p3.voltage_level.id,
        .node3 = p3.node,
        .bus3 = p3.bus,
        .connectable_bus3 = p3.bus,
        .r1 = e1.r,
        .x1 = e1.x,
        .g1 = e1.g,
        .b1 = e1.b,
        .rated_u1 = e1.rated_u,
        .rated_s1 = e1.rated_s,
        .r2 = e2.r * ratio2_2,
        .x2 = e2.x * ratio2_2,
        .g2 = e2.g / ratio2_2,
        .b2 = e2.b / ratio2_2,
        .rated_u2 = e2.rated_u,
        .rated_s2 = e2.rated_s,
        .r3 = e3.r * ratio2_3,
        .x3 = e3.x * ratio2_3,
        .g3 = e3.g / ratio2_3,
        .b3 = e3.b / ratio2_3,
        .rated_u3 = e3.rated_u,
        .rated_s3 = e3.rated_s,
        .ratio_tap_changer1 = if (rtc1) |kv| kv.value.tap_changer else null,
        .ratio_tap_changer2 = if (rtc2) |kv| kv.value.tap_changer else null,
        .ratio_tap_changer3 = if (rtc3) |kv| kv.value.tap_changer else null,
        .selected_op_lims_group_id1 = selected_1,
        .selected_op_lims_group_id2 = selected_2,
        .selected_op_lims_group_id3 = selected_3,
        .op_lims_groups1 = op_lims_groups_1,
        .op_lims_groups2 = op_lims_groups_2,
        .op_lims_groups3 = op_lims_groups_3,
        .aliases = aliases,
    });
}

pub fn convert_transformers(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    substation_map: *const std.StringHashMapUnmanaged(*iidm.Substation),
    placer: TerminalPlacer,
    ssh_opt: ?@import("../cgmes/ssh.zig").CimSsh,
) !void {
    var ends_by_transformer: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObjectView)) = try build_ends_by_transformer(gpa, model);
    defer {
        var it = ends_by_transformer.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        ends_by_transformer.deinit(gpa);
    }

    var ratio_tap_changer_map = try build_ratio_tap_changer_map(gpa, model, ssh_opt);
    defer {
        var it = ratio_tap_changer_map.valueIterator();
        while (it.next()) |value| value.deinit(gpa);
        ratio_tap_changer_map.deinit(gpa);
    }

    var phase_tap_changer_map = try build_phase_tap_changer_map(gpa, model, ssh_opt);
    defer {
        var it = phase_tap_changer_map.valueIterator();
        while (it.next()) |value| value.deinit(gpa);
        phase_tap_changer_map.deinit(gpa);
    }

    try pre_allocate_transformers(gpa, &ends_by_transformer, substation_map, placer);

    const transformers = model.get_objects_by_type("PowerTransformer");
    for (transformers) |transformer| {
        const transformer_view = model.view(transformer);
        const ends = ends_by_transformer.get(transformer.id) orelse continue;
        const end1 = ends.items[0];
        const placement = try resolve_end_placement(end1, placer) orelse continue;
        const substation = substation_map.get(placement.repr_voltage_level_id) orelse continue;

        switch (ends.items.len) {
            2 => try append_two_windings_transformer(gpa, model, transformer_view, ends.items, substation, placer, &ratio_tap_changer_map, &phase_tap_changer_map),
            3 => try append_three_windings_transformer(gpa, model, transformer_view, ends.items, substation, placer, &ratio_tap_changer_map),
            else => continue,
        }
    }
    assert(transformers.len == 0 or ends_by_transformer.count() > 0);
}
