const std = @import("std");
const iidm = @import("../iidm.zig");
const cim_model = @import("../cim_model.zig");
const cim_index = @import("../cim_index.zig");
const tag_index = @import("../tag_index.zig");
const utils = @import("../utils.zig");

const assert = std.debug.assert;
const testing = std.testing;

const CimModel = cim_model.CimModel;
const CimObject = tag_index.CimObject;
const CimIndex = cim_index.CimIndex;
const placement_mod = @import("placement.zig");
const connection_mod = @import("connection.zig");

const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;
const Placement = placement_mod.Placement;
const resolve_terminal_placement = placement_mod.resolve_terminal_placement;
const NodeMap = connection_mod.NodeMap;

fn build_ends_by_transformer(
    gpa: std.mem.Allocator,
    model: *const CimModel,
) !std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObject)) {
    var ends_by_transformer: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObject)) = .empty;

    const ends = model.getObjectsByType("PowerTransformerEnd");

    try ends_by_transformer.ensureTotalCapacity(gpa, @intCast(ends.len));

    for (ends) |end| {
        const transformer_ref = try end.getReference("PowerTransformerEnd.PowerTransformer") orelse continue;
        const transformer_id = strip_hash(transformer_ref);

        const gop = ends_by_transformer.getOrPutAssumeCapacity(transformer_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, end);
    }

    var it = ends_by_transformer.valueIterator();
    while (it.next()) |transformer_ends| {
        std.sort.block(CimObject, transformer_ends.items, {}, lessThanFn);
    }

    assert(ends.len == 0 or ends_by_transformer.count() > 0);

    return ends_by_transformer;
}

const TapChangerCommon = struct { low_step: i32, normal_step: i32, ltc_flag: bool };

fn read_tap_changer_common(tap_changer: CimObject) !?TapChangerCommon {
    const low_step_str = try tap_changer.getProperty("TapChanger.lowStep") orelse return null;
    const low_step = try std.fmt.parseInt(i32, low_step_str, 10);
    const normal_step_str = try tap_changer.getProperty("TapChanger.normalStep") orelse return null;
    const normal_step = try std.fmt.parseInt(i32, normal_step_str, 10);
    const ltc_flag_str = try tap_changer.getProperty("TapChanger.ltcFlag") orelse return null;
    const ltc_flag = std.mem.eql(u8, ltc_flag_str, "true");
    return .{ .low_step = low_step, .normal_step = normal_step, .ltc_flag = ltc_flag };
}

const TapChangerBaseStep = struct { r: f64, x: f64, g: f64, b: f64, rho: f64 };

fn read_tap_changer_base_step(point: CimObject) !?TapChangerBaseStep {
    const r = try std.fmt.parseFloat(f64, try point.getProperty("TapChangerTablePoint.r") orelse "0.0");
    const x = try std.fmt.parseFloat(f64, try point.getProperty("TapChangerTablePoint.x") orelse "0.0");
    const g = try std.fmt.parseFloat(f64, try point.getProperty("TapChangerTablePoint.g") orelse "0.0");
    const b = try std.fmt.parseFloat(f64, try point.getProperty("TapChangerTablePoint.b") orelse "0.0");
    const ratio_str = try point.getProperty("TapChangerTablePoint.ratio") orelse return null;
    const ratio = try std.fmt.parseFloat(f64, ratio_str);
    return .{ .r = r, .x = x, .g = g, .b = b, .rho = if (ratio != 0.0) 1.0 / ratio else 1.0 };
}

fn build_ratio_table_points(
    gpa: std.mem.Allocator,
    model: *const CimModel,
) !std.StringHashMapUnmanaged(std.ArrayListUnmanaged(iidm.RatioTapChangerStep)) {
    const tables = model.getObjectsByType("RatioTapChangerTable");
    const points = model.getObjectsByType("RatioTapChangerTablePoint");
    var points_by_table: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(iidm.RatioTapChangerStep)) = .empty;
    try points_by_table.ensureTotalCapacity(gpa, @intCast(tables.len));
    for (points) |point| {
        const table_ref = try point.getReference("RatioTapChangerTablePoint.RatioTapChangerTable") orelse continue;
        const base = try read_tap_changer_base_step(point) orelse continue;
        const gop = points_by_table.getOrPutAssumeCapacity(strip_hash(table_ref));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, .{ .r = base.r, .x = base.x, .g = base.g, .b = base.b, .rho = base.rho });
    }
    assert(points.len == 0 or points_by_table.count() > 0);
    return points_by_table;
}

fn build_linear_ratio_steps(
    gpa: std.mem.Allocator,
    tap_changer: CimObject,
    low_step: i32,
) !?std.ArrayListUnmanaged(iidm.RatioTapChangerStep) {
    const high_step_str = try tap_changer.getProperty("TapChanger.highStep") orelse return null;
    const high_step = try std.fmt.parseInt(i32, high_step_str, 10);
    const neutral_step_str = try tap_changer.getProperty("TapChanger.neutralStep") orelse return null;
    const neutral_step = try std.fmt.parseInt(i32, neutral_step_str, 10);
    const increment_str = try tap_changer.getProperty("RatioTapChanger.stepVoltageIncrement") orelse return null;
    const increment = try std.fmt.parseFloat(f64, increment_str);

    var steps: std.ArrayListUnmanaged(iidm.RatioTapChangerStep) = .empty;
    try steps.ensureTotalCapacity(gpa, @intCast(high_step - low_step + 1));
    var step: i32 = low_step;
    while (step <= high_step) : (step += 1) {
        const rho = 1.0 + @as(f64, @floatFromInt(step - neutral_step)) * increment / 100.0;
        steps.appendAssumeCapacity(.{ .r = 0.0, .x = 0.0, .g = 0.0, .b = 0.0, .rho = rho });
    }
    assert(steps.items.len > 0);
    return steps;
}

fn build_ratio_tap_changer_map(
    gpa: std.mem.Allocator,
    model: *const CimModel,
) !std.StringHashMapUnmanaged(iidm.RatioTapChanger) {
    var points_by_table = try build_ratio_table_points(gpa, model);
    defer {
        var it = points_by_table.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        points_by_table.deinit(gpa);
    }

    const tap_changers = model.getObjectsByType("RatioTapChanger");
    var ratio_tap_changer_map: std.StringHashMapUnmanaged(iidm.RatioTapChanger) = .empty;
    try ratio_tap_changer_map.ensureTotalCapacity(gpa, @intCast(tap_changers.len));

    for (tap_changers) |tap_changer| {
        const end_ref = try tap_changer.getReference("RatioTapChanger.TransformerEnd") orelse continue;
        const common = try read_tap_changer_common(tap_changer) orelse continue;

        const owned_steps = if (try tap_changer.getReference("RatioTapChanger.RatioTapChangerTable")) |table_ref| blk: {
            const steps = points_by_table.get(strip_hash(table_ref)) orelse continue;
            var s: std.ArrayListUnmanaged(iidm.RatioTapChangerStep) = .empty;
            try s.ensureTotalCapacity(gpa, steps.items.len);
            s.appendSliceAssumeCapacity(steps.items);
            break :blk s;
        } else blk: {
            break :blk try build_linear_ratio_steps(gpa, tap_changer, common.low_step) orelse continue;
        };

        ratio_tap_changer_map.putAssumeCapacity(strip_hash(end_ref), .{
            .low_tap_position = common.low_step,
            .tap_position = common.normal_step,
            .load_tap_changing_capabilities = common.ltc_flag,
            .regulating = null,
            .regulation_mode = null,
            .terminal_ref = null,
            .steps = owned_steps,
        });
    }
    return ratio_tap_changer_map;
}

fn build_phase_tap_changer_map(
    gpa: std.mem.Allocator,
    model: *const CimModel,
) !std.StringHashMapUnmanaged(iidm.PhaseTapChanger) {
    var points_by_table: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(iidm.PhaseTapChangerStep)) = .empty;
    defer {
        var it = points_by_table.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        points_by_table.deinit(gpa);
    }

    const tables = model.getObjectsByType("PhaseTapChangerTable");
    try points_by_table.ensureTotalCapacity(gpa, @intCast(tables.len));

    const points = model.getObjectsByType("PhaseTapChangerTablePoint");

    for (points) |point| {
        const table_ref = try point.getReference("PhaseTapChangerTablePoint.PhaseTapChangerTable") orelse continue;
        const table_id = strip_hash(table_ref);

        const base = try read_tap_changer_base_step(point) orelse continue;
        const alpha_str = try point.getProperty("PhaseTapChangerTablePoint.angle") orelse "0.0";
        const alpha = try std.fmt.parseFloat(f64, alpha_str);

        const gop = points_by_table.getOrPutAssumeCapacity(table_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, .{
            .r = base.r,
            .x = base.x,
            .g = base.g,
            .b = base.b,
            .rho = base.rho,
            .alpha = alpha,
        });
    }

    const tap_changers = model.getObjectsByType("PhaseTapChangerTabular");

    var phase_tap_changer_map: std.StringHashMapUnmanaged(iidm.PhaseTapChanger) = .empty;
    try phase_tap_changer_map.ensureTotalCapacity(gpa, @intCast(tap_changers.len));

    for (tap_changers) |tap_changer| {
        const end_ref = try tap_changer.getReference("PhaseTapChanger.TransformerEnd") orelse continue;
        const end_id = strip_hash(end_ref);

        const common = try read_tap_changer_common(tap_changer) orelse continue;

        const table_ref = try tap_changer.getReference("PhaseTapChanger.PhaseTapChangerTable") orelse continue;
        const table_id = strip_hash(table_ref);
        const steps = points_by_table.get(table_id) orelse continue;

        var owned_steps: std.ArrayListUnmanaged(iidm.PhaseTapChangerStep) = .empty;
        try owned_steps.ensureTotalCapacity(gpa, steps.items.len);
        owned_steps.appendSliceAssumeCapacity(steps.items);

        phase_tap_changer_map.putAssumeCapacity(end_id, .{
            .low_tap_position = common.low_step,
            .tap_position = common.normal_step,
            .load_tap_changing_capabilities = common.ltc_flag,
            .regulating = null,
            .regulation_mode = null,
            .steps = owned_steps,
        });
    }
    return phase_tap_changer_map;
}

fn lessThanFn(_: void, end0: CimObject, end1: CimObject) bool {
    const end_number0_str = end0.getProperty("TransformerEnd.endNumber") catch "0" orelse "0";
    const end_number0 = std.fmt.parseInt(u32, end_number0_str, 10) catch 0;

    const end_number1_str = end1.getProperty("TransformerEnd.endNumber") catch "0" orelse "0";
    const end_number1 = std.fmt.parseInt(u32, end_number1_str, 10) catch 0;

    return end_number0 < end_number1;
}

const TestEnd = struct { model: cim_model.CimModel, end: CimObject };

fn make_end(xml: []const u8) !TestEnd {
    const model = try cim_model.CimModel.init(testing.allocator, xml);
    return .{ .model = model, .end = model.getObjectsByType("PowerTransformerEnd")[0] };
}

test "lessThanFn: end 1 < end 2" {
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
    try testing.expect(lessThanFn({}, t1.end, t2.end));
    try testing.expect(!lessThanFn({}, t2.end, t1.end));
}

test "lessThanFn: equal end numbers are not less than" {
    var t = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e1">
        \\  <cim:TransformerEnd.endNumber>2</cim:TransformerEnd.endNumber>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer t.model.deinit(testing.allocator);
    try testing.expect(!lessThanFn({}, t.end, t.end));
}

test "lessThanFn: missing endNumber falls back to 0, sorts before any numbered end" {
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
    try testing.expect(lessThanFn({}, tm.end, t1.end));
    try testing.expect(!lessThanFn({}, t1.end, tm.end));
}

test "lessThanFn: end 1 < end 3" {
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
    try testing.expect(lessThanFn({}, t1.end, t3.end));
    try testing.expect(!lessThanFn({}, t3.end, t1.end));
}

test "lessThanFn: transitivity — end1 < end2 and end2 < end3 implies end1 < end3" {
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
    try testing.expect(lessThanFn({}, t1.end, t2.end)); // end1 < end2
    try testing.expect(lessThanFn({}, t2.end, t3.end)); // end2 < end3
    try testing.expect(lessThanFn({}, t1.end, t3.end)); // therefore end1 < end3
}

const EndElectrical = struct { r: f64, x: f64, g: f64, b: f64, rated_u: f64, rated_s: ?f64 };

fn read_end_electrical(end: CimObject) !?EndElectrical {
    const rated_u = try std.fmt.parseFloat(f64, try end.getProperty("PowerTransformerEnd.ratedU") orelse return null);
    const r = try std.fmt.parseFloat(f64, try end.getProperty("PowerTransformerEnd.r") orelse "0.0");
    const x = try std.fmt.parseFloat(f64, try end.getProperty("PowerTransformerEnd.x") orelse "0.0");
    const g = try std.fmt.parseFloat(f64, try end.getProperty("PowerTransformerEnd.g") orelse "0.0");
    const b = try std.fmt.parseFloat(f64, try end.getProperty("PowerTransformerEnd.b") orelse "0.0");
    const rated_s: ?f64 = blk: {
        const s = try end.getProperty("PowerTransformerEnd.ratedS") orelse break :blk null;
        break :blk try std.fmt.parseFloat(f64, s);
    };
    return .{ .r = r, .x = x, .g = g, .b = b, .rated_u = rated_u, .rated_s = rated_s };
}

fn resolve_end_placement(
    end: CimObject,
    index: *const CimIndex,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
) !?Placement {
    const terminal_ref = try end.getReference("TransformerEnd.Terminal") orelse return null;
    const terminal_id = strip_hash(terminal_ref);
    const conn_node_id = index.terminal_conn_node.get(terminal_id) orelse return null;
    return resolve_terminal_placement(terminal_id, conn_node_id, index, voltage_level_map, node_map);
}

fn pre_allocate_transformers(
    gpa: std.mem.Allocator,
    ends_by_transformer: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObject)),
    substation_map: *const std.StringHashMapUnmanaged(*iidm.Substation),
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    index: *const CimIndex,
    node_map: *const NodeMap,
) !void {
    assert(voltage_level_map.count() > 0);

    var transformer_counts: std.AutoHashMapUnmanaged(usize, struct { two: usize, three: usize }) = .empty;
    defer transformer_counts.deinit(gpa);
    try transformer_counts.ensureTotalCapacity(gpa, @intCast(ends_by_transformer.count()));

    var it = ends_by_transformer.iterator();
    while (it.next()) |entry| {
        const ends = entry.value_ptr.*;
        const winding_count = ends.items.len;
        if (winding_count != 2 and winding_count != 3) continue;

        const placement1 = try resolve_end_placement(ends.items[0], index, voltage_level_map, node_map) orelse continue;
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

    assert(transformer_counts.count() <= voltage_level_map.count());
}

fn append_two_windings_transformer(
    transformer: CimObject,
    ends: []const CimObject,
    substation: *iidm.Substation,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
    index: *const CimIndex,
    ratio_tap_changer_map: *std.StringHashMapUnmanaged(iidm.RatioTapChanger),
    phase_tap_changer_map: *std.StringHashMapUnmanaged(iidm.PhaseTapChanger),
) !void {
    assert(ends.len == 2);

    const p1 = try resolve_end_placement(ends[0], index, voltage_level_map, node_map) orelse return;
    const p2 = try resolve_end_placement(ends[1], index, voltage_level_map, node_map) orelse return;
    const e1 = try read_end_electrical(ends[0]) orelse return;
    const e2 = try read_end_electrical(ends[1]) orelse return;

    const ratio = e2.rated_u / e1.rated_u;
    const ratio2 = ratio * ratio;

    const mrid = try transformer.getProperty("IdentifiedObject.mRID") orelse strip_underscore(transformer.id);
    const name = try transformer.getProperty("IdentifiedObject.name");

    // Tap changers keyed by end rdf:ID (strip_hash of reference = end.id). fetchRemove takes ownership.
    const ratio_tc = ratio_tap_changer_map.fetchRemove(ends[0].id) orelse
        ratio_tap_changer_map.fetchRemove(ends[1].id);
    const phase_tc = phase_tap_changer_map.fetchRemove(ends[0].id) orelse
        phase_tap_changer_map.fetchRemove(ends[1].id);

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
        .voltage_level_id2 = p2.voltage_level.id,
        .node2 = p2.node,
        .ratio_tap_changer = if (ratio_tc) |kv| kv.value else null,
        .phase_tap_changer = if (phase_tc) |kv| kv.value else null,
        .selected_op_lims_group1_id = null,
        .selected_op_lims_group2_id = null,
        .op_lims_groups1 = .empty,
        .op_lims_groups2 = .empty,
        .aliases = .empty,
    });
}

fn append_three_windings_transformer(
    transformer: CimObject,
    ends: []const CimObject,
    substation: *iidm.Substation,
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
    index: *const CimIndex,
    ratio_tap_changer_map: *std.StringHashMapUnmanaged(iidm.RatioTapChanger),
) !void {
    assert(ends.len == 3);

    const p1 = try resolve_end_placement(ends[0], index, voltage_level_map, node_map) orelse return;
    const p2 = try resolve_end_placement(ends[1], index, voltage_level_map, node_map) orelse return;
    const p3 = try resolve_end_placement(ends[2], index, voltage_level_map, node_map) orelse return;
    const e1 = try read_end_electrical(ends[0]) orelse return;
    const e2 = try read_end_electrical(ends[1]) orelse return;
    const e3 = try read_end_electrical(ends[2]) orelse return;

    const mrid = try transformer.getProperty("IdentifiedObject.mRID") orelse strip_underscore(transformer.id);
    const name = try transformer.getProperty("IdentifiedObject.name");

    // Tap changers keyed by end rdf:ID. fetchRemove takes ownership.
    const rtc1 = ratio_tap_changer_map.fetchRemove(ends[0].id);
    const rtc2 = ratio_tap_changer_map.fetchRemove(ends[1].id);
    const rtc3 = ratio_tap_changer_map.fetchRemove(ends[2].id);

    substation.three_winding_transformers.appendAssumeCapacity(.{
        .id = mrid,
        .name = name,
        .rated_u0 = e1.rated_u, // star point voltage = HV (end1) rated voltage
        .voltage_level_id1 = p1.voltage_level.id,
        .node1 = p1.node,
        .voltage_level_id2 = p2.voltage_level.id,
        .node2 = p2.node,
        .voltage_level_id3 = p3.voltage_level.id,
        .node3 = p3.node,
        .r1 = e1.r,
        .x1 = e1.x,
        .g1 = e1.g,
        .b1 = e1.b,
        .rated_u1 = e1.rated_u,
        .rated_s1 = e1.rated_s,
        .r2 = e2.r,
        .x2 = e2.x,
        .g2 = e2.g,
        .b2 = e2.b,
        .rated_u2 = e2.rated_u,
        .rated_s2 = e2.rated_s,
        .r3 = e3.r,
        .x3 = e3.x,
        .g3 = e3.g,
        .b3 = e3.b,
        .rated_u3 = e3.rated_u,
        .rated_s3 = e3.rated_s,
        .ratio_tap_changer1 = if (rtc1) |kv| kv.value else null,
        .ratio_tap_changer2 = if (rtc2) |kv| kv.value else null,
        .ratio_tap_changer3 = if (rtc3) |kv| kv.value else null,
        .selected_op_lims_group_id1 = null,
        .selected_op_lims_group_id2 = null,
        .selected_op_lims_group_id3 = null,
        .op_lims_groups1 = .empty,
        .op_lims_groups2 = .empty,
        .op_lims_groups3 = .empty,
        .aliases = .empty,
    });
}

pub fn convert_transformers(
    gpa: std.mem.Allocator,
    model: *const CimModel,
    index: *const CimIndex,
    substation_map: *const std.StringHashMapUnmanaged(*iidm.Substation),
    voltage_level_map: *const std.StringHashMapUnmanaged(*iidm.VoltageLevel),
    node_map: *const NodeMap,
) !void {
    var ends_by_transformer = try build_ends_by_transformer(gpa, model);
    defer {
        var it = ends_by_transformer.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        ends_by_transformer.deinit(gpa);
    }

    var ratio_tap_changer_map = try build_ratio_tap_changer_map(gpa, model);
    defer {
        var it = ratio_tap_changer_map.valueIterator();
        while (it.next()) |value| value.deinit(gpa);
        ratio_tap_changer_map.deinit(gpa);
    }

    var phase_tap_changer_map = try build_phase_tap_changer_map(gpa, model);
    defer {
        var it = phase_tap_changer_map.valueIterator();
        while (it.next()) |value| value.deinit(gpa);
        phase_tap_changer_map.deinit(gpa);
    }

    try pre_allocate_transformers(gpa, &ends_by_transformer, substation_map, voltage_level_map, index, node_map);

    const transformers = model.getObjectsByType("PowerTransformer");
    for (transformers) |transformer| {
        const ends = ends_by_transformer.get(transformer.id) orelse continue;
        const end1 = ends.items[0];
        const placement = try resolve_end_placement(end1, index, voltage_level_map, node_map) orelse continue;
        const substation = substation_map.get(placement.repr_voltage_level_id) orelse continue;

        switch (ends.items.len) {
            2 => try append_two_windings_transformer(transformer, ends.items, substation, voltage_level_map, node_map, index, &ratio_tap_changer_map, &phase_tap_changer_map),
            3 => try append_three_windings_transformer(transformer, ends.items, substation, voltage_level_map, node_map, index, &ratio_tap_changer_map),
            else => continue,
        }
    }
    assert(transformers.len == 0 or ends_by_transformer.count() > 0);
}
