const std = @import("std");
const cim = @import("../cim/cim.zig");
const iidm = @import("../iidm/model.zig");
const CimDocument = cim.CimDocument;
const cross_ref = @import("../topology/cross_ref.zig");
const utils = cim.ids;
const topology = @import("../topology/resolve.zig");
const parse = cim.parse;

const assert = std.debug.assert;
const testing = std.testing;

const CimObject = cim.CimObject;
const CrossRef = cross_ref.CrossRef;
const placement_mod = @import("placement.zig");

const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;
const Placement = placement_mod.Placement;
const TerminalPlacer = placement_mod.TerminalPlacer;
const resolve_terminal_placement = placement_mod.resolve_terminal_placement;
const NodeMap = topology.NodeMap;
const max_tap_steps = 10_000;
/// Smaller ratios invert to values above one million and are not meaningful tap positions.
const min_tap_ratio_magnitude: f64 = 1e-6;

pub const TapChangerInfoMap = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(iidm.TapChangerInfo));

pub fn deinit_tap_changer_info_map(gpa: std.mem.Allocator, map: *TapChangerInfoMap) void {
    var it = map.valueIterator();
    while (it.next()) |list| list.deinit(gpa);
    map.deinit(gpa);
}

fn build_ends_by_transformer(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
) !std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObject)) {
    var ends_by_transformer: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObject)) = .empty;

    const ends = model.objects_by_type("PowerTransformerEnd");

    try ends_by_transformer.ensureTotalCapacity(gpa, @intCast(ends.len));

    for (ends) |end| {
        const transformer_ref = try end.reference("PowerTransformerEnd.PowerTransformer") orelse continue;
        const transformer_id = strip_hash(transformer_ref);

        const gop = ends_by_transformer.getOrPutAssumeCapacity(transformer_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, end);
    }

    var it = ends_by_transformer.valueIterator();
    while (it.next()) |transformer_ends| {
        std.sort.block(CimObject, transformer_ends.items, {}, view_less_than);
    }

    return ends_by_transformer;
}

test "build_ends_by_transformer skips ends without a transformer reference" {
    const xml =
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_end">
        \\  <cim:TransformerEnd.endNumber>1</cim:TransformerEnd.endNumber>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    ;
    var model = try CimDocument.init(testing.allocator, try testing.allocator.dupe(u8, xml));
    defer model.deinit(testing.allocator);
    var ends_by_transformer = try build_ends_by_transformer(testing.allocator, &model);
    defer {
        var it = ends_by_transformer.valueIterator();
        while (it.next()) |ends| ends.deinit(testing.allocator);
        ends_by_transformer.deinit(testing.allocator);
    }

    try testing.expectEqual(@as(u32, 0), ends_by_transformer.count());
}

const TapChangerCommon = struct { low_step: i32, normal_step: i32, ltc_flag: bool };

fn read_tap_changer_regulating(
    model: *const CimDocument,
    tap_changer: CimObject,
    ssh_opt: ?cim.Overlay,
) !?bool {
    const control_ref = try tap_changer.reference("TapChanger.TapChangerControl") orelse return null;
    if (ssh_opt) |ssh| {
        const control_id = strip_hash(control_ref);
        const control_mrid = if (model.object_by_id(control_id)) |control|
            try control.mrid()
        else
            strip_underscore(control_id);
        return parse.flag(ssh.property(control_mrid, "RegulatingCondEq.controlEnabled"));
    }
    return false;
}

fn read_tap_changer_common(tap_changer: CimObject) !?TapChangerCommon {
    const props = try tap_changer.properties(.{
        "TapChanger.lowStep",
        "TapChanger.normalStep",
        "TapChanger.ltcFlag",
    });
    const low_step = try parse.int_req(i32, parse.non_blank(props[0]) orelse return null);
    const normal_step = try parse.int_req(i32, parse.non_blank(props[1]) orelse return null);
    const ltc_flag = parse.flag(props[2]);
    return .{ .low_step = low_step, .normal_step = normal_step, .ltc_flag = ltc_flag };
}

test "blank ltcFlag keeps the tap changer disabled" {
    const xml =
        \\<rdf:RDF><cim:RatioTapChanger rdf:ID="_rtc">
        \\  <cim:TapChanger.lowStep>0</cim:TapChanger.lowStep>
        \\  <cim:TapChanger.normalStep>0</cim:TapChanger.normalStep>
        \\  <cim:TapChanger.ltcFlag></cim:TapChanger.ltcFlag>
        \\</cim:RatioTapChanger></rdf:RDF>
    ;
    var model = try CimDocument.init(testing.allocator, try testing.allocator.dupe(u8, xml));
    defer model.deinit(testing.allocator);
    const tap_changer = model.objects_by_type("RatioTapChanger")[0];
    const common = (try read_tap_changer_common(tap_changer)).?;
    try testing.expect(!common.ltc_flag);
}

fn append_tap_changer_info(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    map: *TapChangerInfoMap,
    end_id: []const u8,
    tap_changer_mrid: []const u8,
    tap_changer_type: ?[]const u8,
    normal_step: i32,
) !void {
    const end_obj = model.object_by_id(end_id) orelse return;
    const transformer_ref = try end_obj.reference("PowerTransformerEnd.PowerTransformer") orelse return;
    const transformer_id = strip_hash(transformer_ref);
    const transformer_obj = model.object_by_id(transformer_id) orelse return;
    const transformer_mrid = try transformer_obj.mrid();

    const gop = try map.getOrPut(gpa, transformer_mrid);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(gpa, .{
        .id = tap_changer_mrid,
        .tap_changer_type = tap_changer_type,
        .step = normal_step,
    });
}

// Raw CGMES step values. rho transform differs between ratio (invert) and phase (passthrough)
// tap changers, so the caller applies it.
const TapChangerBaseStep = struct { r: f64, x: f64, g: f64, b: f64, cgmes_ratio: f64 };

fn validate_tap_ratio(ratio: f64) error{InvalidNumericValue}!void {
    if (!std.math.isFinite(ratio) or @abs(ratio) < min_tap_ratio_magnitude) {
        return error.InvalidNumericValue;
    }
}

fn read_tap_changer_base_step(point: CimObject) !?TapChangerBaseStep {
    const props = try point.properties(.{
        "TapChangerTablePoint.r",
        "TapChangerTablePoint.x",
        "TapChangerTablePoint.g",
        "TapChangerTablePoint.b",
        "TapChangerTablePoint.ratio",
    });
    const r = try parse.float_strict(props[0], 0.0);
    const x = try parse.float_strict(props[1], 0.0);
    const g = try parse.float_strict(props[2], 0.0);
    const b = try parse.float_strict(props[3], 0.0);
    const cgmes_ratio = try parse.float_req(parse.non_blank(props[4]) orelse return null);
    try validate_tap_ratio(cgmes_ratio);
    return .{ .r = r, .x = x, .g = g, .b = b, .cgmes_ratio = cgmes_ratio };
}

test "tap changer table points reject zero ratio for ratio and phase paths" {
    const xml =
        \\<rdf:RDF><cim:RatioTapChangerTablePoint rdf:ID="_point">
        \\  <cim:TapChangerTablePoint.ratio>0</cim:TapChangerTablePoint.ratio>
        \\</cim:RatioTapChangerTablePoint>
        \\<cim:PhaseTapChangerTablePoint rdf:ID="_phase_point">
        \\  <cim:TapChangerTablePoint.ratio>0</cim:TapChangerTablePoint.ratio>
        \\</cim:PhaseTapChangerTablePoint></rdf:RDF>
    ;
    var model = try CimDocument.init(testing.allocator, try testing.allocator.dupe(u8, xml));
    defer model.deinit(testing.allocator);
    const point = model.objects_by_type("RatioTapChangerTablePoint")[0];
    const phase_point = model.objects_by_type("PhaseTapChangerTablePoint")[0];

    try testing.expectError(error.InvalidNumericValue, read_tap_changer_base_step(point));
    try testing.expectError(error.InvalidNumericValue, read_tap_changer_base_step(phase_point));
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
    model: *const CimDocument,
) !std.StringHashMapUnmanaged(std.ArrayListUnmanaged(OrderedRatioStep)) {
    const tables = model.objects_by_type("RatioTapChangerTable");
    const points = model.objects_by_type("RatioTapChangerTablePoint");
    var points_by_table: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(OrderedRatioStep)) = .empty;
    errdefer {
        var it = points_by_table.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        points_by_table.deinit(gpa);
    }
    try points_by_table.ensureTotalCapacity(gpa, @intCast(tables.len));
    for (points) |point| {
        const table_ref = try point.reference("RatioTapChangerTablePoint.RatioTapChangerTable") orelse continue;
        const base = try read_tap_changer_base_step(point) orelse continue;
        const step_num_str = parse.non_blank(point.property("TapChangerTablePoint.step")) orelse continue;
        const step_num = try parse.int_req(i32, step_num_str);
        // pypowsybl inverts cgmes_ratio for ratio tap changers.
        const rho = 1.0 / base.cgmes_ratio;
        const gop = try points_by_table.getOrPut(gpa, strip_hash(table_ref));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, .{
            .step_num = step_num,
            .step = .{ .r = base.r, .x = base.x, .g = base.g, .b = base.b, .rho = rho },
        });
    }
    // CGMES does not guarantee TablePoint XML order matches step order -- sort explicitly.
    var sort_it = points_by_table.valueIterator();
    while (sort_it.next()) |list| std.sort.block(OrderedRatioStep, list.items, {}, OrderedRatioStep.less_than);
    return points_by_table;
}

test "tap point maps tolerate dangling table references and skipped points" {
    const dangling_xml =
        \\<rdf:RDF>
        \\  <cim:RatioTapChangerTablePoint rdf:ID="_ratio_point">
        \\    <cim:RatioTapChangerTablePoint.RatioTapChangerTable rdf:resource="#_missing_ratio_table"/>
        \\    <cim:TapChangerTablePoint.step>0</cim:TapChangerTablePoint.step>
        \\    <cim:TapChangerTablePoint.ratio>1</cim:TapChangerTablePoint.ratio>
        \\  </cim:RatioTapChangerTablePoint>
        \\  <cim:PhaseTapChangerTablePoint rdf:ID="_phase_point">
        \\    <cim:PhaseTapChangerTablePoint.PhaseTapChangerTable rdf:resource="#_missing_phase_table"/>
        \\    <cim:TapChangerTablePoint.step>0</cim:TapChangerTablePoint.step>
        \\    <cim:TapChangerTablePoint.ratio>1</cim:TapChangerTablePoint.ratio>
        \\  </cim:PhaseTapChangerTablePoint>
        \\</rdf:RDF>
    ;
    var dangling_model = try CimDocument.init(testing.allocator, try testing.allocator.dupe(u8, dangling_xml));
    defer dangling_model.deinit(testing.allocator);
    var ratio_points = try build_ratio_table_points(testing.allocator, &dangling_model);
    defer {
        var it = ratio_points.valueIterator();
        while (it.next()) |points| points.deinit(testing.allocator);
        ratio_points.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(u32, 1), ratio_points.count());

    var phase_map = try build_phase_tap_changer_map(testing.allocator, &dangling_model, null, null);
    defer {
        var it = phase_map.valueIterator();
        while (it.next()) |entry| entry.deinit(testing.allocator);
        phase_map.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(u32, 0), phase_map.count());

    const skipped_xml =
        \\<rdf:RDF>
        \\  <cim:RatioTapChangerTable rdf:ID="_table"/>
        \\  <cim:RatioTapChangerTablePoint rdf:ID="_point">
        \\    <cim:RatioTapChangerTablePoint.RatioTapChangerTable rdf:resource="#_table"/>
        \\    <cim:TapChangerTablePoint.step>0</cim:TapChangerTablePoint.step>
        \\  </cim:RatioTapChangerTablePoint>
        \\</rdf:RDF>
    ;
    var skipped_model = try CimDocument.init(testing.allocator, try testing.allocator.dupe(u8, skipped_xml));
    defer skipped_model.deinit(testing.allocator);
    var skipped_points = try build_ratio_table_points(testing.allocator, &skipped_model);
    defer skipped_points.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), skipped_points.count());
}

fn build_linear_ratio_steps(
    gpa: std.mem.Allocator,
    tap_changer: CimObject,
    low_step: i32,
) !?std.ArrayListUnmanaged(iidm.RatioTapChangerStep) {
    const high_step_str = parse.non_blank(tap_changer.property("TapChanger.highStep")) orelse return null;
    const high_step = try parse.int_req(i32, high_step_str);
    const neutral_step_str = parse.non_blank(tap_changer.property("TapChanger.neutralStep")) orelse return null;
    const neutral_step = try parse.int_req(i32, neutral_step_str);
    const increment_str = parse.non_blank(tap_changer.property("RatioTapChanger.stepVoltageIncrement")) orelse return null;
    const increment = try parse.float_req(increment_str);

    if (high_step < low_step) return error.InvalidTapStepRange;
    const step_count_i64 = @as(i64, high_step) - @as(i64, low_step) + 1;
    if (step_count_i64 > max_tap_steps) return error.TapStepRangeTooLarge;
    const step_count: usize = @intCast(step_count_i64);

    var steps: std.ArrayListUnmanaged(iidm.RatioTapChangerStep) = .empty;
    errdefer steps.deinit(gpa);
    try steps.ensureTotalCapacity(gpa, step_count);
    for (0..step_count) |i| {
        const step: i32 = low_step + @as(i32, @intCast(i));
        // pypowsybl emits rho = 1 / cgmes_ratio; CGMES linear ratio at step = 1 + (step-neutral)*inc/100.
        const offset = @as(i64, step) - @as(i64, neutral_step);
        const cgmes_ratio = 1.0 + @as(f64, @floatFromInt(offset)) * increment / 100.0;
        try validate_tap_ratio(cgmes_ratio);
        const rho = 1.0 / cgmes_ratio;
        steps.appendAssumeCapacity(.{ .r = 0.0, .x = 0.0, .g = 0.0, .b = 0.0, .rho = rho });
    }
    assert(steps.items.len > 0);
    return steps;
}

test "build_linear_ratio_steps rejects a computed near-zero ratio" {
    const xml =
        \\<rdf:RDF><cim:RatioTapChanger rdf:ID="_tap">
        \\  <cim:TapChanger.highStep>0</cim:TapChanger.highStep>
        \\  <cim:TapChanger.neutralStep>300</cim:TapChanger.neutralStep>
        \\  <cim:RatioTapChanger.stepVoltageIncrement>0.3333333</cim:RatioTapChanger.stepVoltageIncrement>
        \\</cim:RatioTapChanger></rdf:RDF>
    ;
    var model = try CimDocument.init(testing.allocator, try testing.allocator.dupe(u8, xml));
    defer model.deinit(testing.allocator);
    const tap_changer = model.objects_by_type("RatioTapChanger")[0];

    try testing.expectError(error.InvalidNumericValue, build_linear_ratio_steps(testing.allocator, tap_changer, 0));
}

const RatioTapChangerEntry = struct {
    rdf_id: []const u8,
    mrid: []const u8,
    tap_changer: iidm.RatioTapChanger,

    fn deinit(self: *RatioTapChangerEntry, gpa: std.mem.Allocator) void {
        self.tap_changer.deinit(gpa);
    }
};

const PhaseTapChangerEntry = struct {
    rdf_id: []const u8,
    mrid: []const u8,
    tap_changer: iidm.PhaseTapChanger,

    fn deinit(self: *PhaseTapChangerEntry, gpa: std.mem.Allocator) void {
        self.tap_changer.deinit(gpa);
    }
};

fn build_ratio_tap_changer_map(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    ssh_opt: ?cim.Overlay,
    tap_changer_info_map: ?*TapChangerInfoMap,
) !std.StringHashMapUnmanaged(RatioTapChangerEntry) {
    var points_by_table = try build_ratio_table_points(gpa, model);
    defer {
        var it = points_by_table.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        points_by_table.deinit(gpa);
    }

    const tap_changers = model.objects_by_type("RatioTapChanger");
    var ratio_tap_changer_map: std.StringHashMapUnmanaged(RatioTapChangerEntry) = .empty;
    errdefer {
        var it = ratio_tap_changer_map.valueIterator();
        while (it.next()) |entry| entry.deinit(gpa);
        ratio_tap_changer_map.deinit(gpa);
    }
    try ratio_tap_changer_map.ensureTotalCapacity(gpa, @intCast(tap_changers.len));

    for (tap_changers) |tap_changer| {
        const end_ref = try tap_changer.reference("RatioTapChanger.TransformerEnd") orelse continue;
        const end_id = strip_hash(end_ref);
        const common = try read_tap_changer_common(tap_changer) orelse continue;
        const regulating = try read_tap_changer_regulating(model, tap_changer, ssh_opt);
        const mrid = try tap_changer.mrid();

        const owned_steps = if (try tap_changer.reference("RatioTapChanger.RatioTapChangerTable")) |table_ref| blk: {
            const ordered = points_by_table.get(strip_hash(table_ref)) orelse continue;
            var s: std.ArrayListUnmanaged(iidm.RatioTapChangerStep) = .empty;
            try s.ensureTotalCapacity(gpa, ordered.items.len);
            for (ordered.items) |os| s.appendAssumeCapacity(os.step);
            break :blk s;
        } else blk: {
            break :blk try build_linear_ratio_steps(gpa, tap_changer, common.low_step) orelse continue;
        };

        const gop = ratio_tap_changer_map.getOrPutAssumeCapacity(end_id);
        if (gop.found_existing) gop.value_ptr.deinit(gpa);
        gop.value_ptr.* = .{
            .rdf_id = tap_changer.id(),
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
        };
    }

    // Record only tap changers that survived all validation and replacement.
    // A second pass preserves CGMES parse order while filtering duplicate
    // changers on the same TransformerEnd down to the retained entry.
    if (tap_changer_info_map) |info_map| {
        for (tap_changers) |tap_changer| {
            const end_ref = try tap_changer.reference("RatioTapChanger.TransformerEnd") orelse continue;
            const end_id = strip_hash(end_ref);
            const retained = ratio_tap_changer_map.get(end_id) orelse continue;
            if (!std.mem.eql(u8, tap_changer.id(), retained.rdf_id)) continue;
            try append_tap_changer_info(gpa, model, info_map, end_id, retained.mrid, null, retained.tap_changer.tap_position);
        }
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
    model: *const CimDocument,
    ssh_opt: ?cim.Overlay,
    tap_changer_info_map: ?*TapChangerInfoMap,
) !std.StringHashMapUnmanaged(PhaseTapChangerEntry) {
    var points_by_table: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(OrderedPhaseStep)) = .empty;
    defer {
        var it = points_by_table.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        points_by_table.deinit(gpa);
    }

    const points = model.objects_by_type("PhaseTapChangerTablePoint");
    const tables = model.objects_by_type("PhaseTapChangerTable");
    try points_by_table.ensureTotalCapacity(gpa, @intCast(tables.len));

    // Build RAW (pre-movement) steps keyed by table. Scaling and rho/alpha movement
    // depend on which end the tap changer sits on; both are applied per tap changer below.
    for (points) |point| {
        const table_ref = try point.reference("PhaseTapChangerTablePoint.PhaseTapChangerTable") orelse continue;
        const table_id = strip_hash(table_ref);

        const base = try read_tap_changer_base_step(point) orelse continue;
        const alpha = try parse.float_strict(point.property("PhaseTapChangerTablePoint.angle"), 0.0);
        const step_num_str = parse.non_blank(point.property("TapChangerTablePoint.step")) orelse continue;
        const step_num = try parse.int_req(i32, step_num_str);

        const gop = try points_by_table.getOrPut(gpa, table_id);
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

    // CGMES does not guarantee TablePoint XML order matches step order -- sort explicitly.
    var sort_it = points_by_table.valueIterator();
    while (sort_it.next()) |list| std.sort.block(OrderedPhaseStep, list.items, {}, OrderedPhaseStep.less_than);

    const tap_changers = model.objects_by_type("PhaseTapChangerTabular");

    var phase_tap_changer_map: std.StringHashMapUnmanaged(PhaseTapChangerEntry) = .empty;
    errdefer {
        var it = phase_tap_changer_map.valueIterator();
        while (it.next()) |entry| entry.deinit(gpa);
        phase_tap_changer_map.deinit(gpa);
    }
    try phase_tap_changer_map.ensureTotalCapacity(gpa, @intCast(tap_changers.len));

    for (tap_changers) |tap_changer| {
        const end_ref = try tap_changer.reference("PhaseTapChanger.TransformerEnd") orelse continue;
        const end_id = strip_hash(end_ref);
        const regulating = try read_tap_changer_regulating(model, tap_changer, ssh_opt);

        const common = try read_tap_changer_common(tap_changer) orelse continue;
        const mrid = try tap_changer.mrid();

        const table_ref = try tap_changer.reference("PhaseTapChangerTabular.PhaseTapChangerTable") orelse continue;
        const table_id = strip_hash(table_ref);
        const ordered_steps = points_by_table.get(table_id) orelse continue;

        // IIDM stores the tap changer on side 2. Two transforms happen here:
        //   End 1 (move=true): pypowsybl moves the tap changer to end 2 by inverting rho
        //     (1/ρ for magnitude, −α for angle). r/x/g/b pass through unchanged.
        //   End 2 (move=false): rho/alpha passthrough, but r/x/g/b go through the |a|²
        //     referral formula:
        //       step.r = 100 * ((1 + cgmes_r/100) * a² - 1)
        //       step.g = 100 * ((1 + cgmes_g/100) / a² - 1)
        const end_obj = model.object_by_id(end_id) orelse continue;
        const end_number = parse.int_or(u32, end_obj.property("TransformerEnd.endNumber"), 0);
        const move = end_number == 1;

        var owned_steps: std.ArrayListUnmanaged(iidm.PhaseTapChangerStep) = .empty;
        try owned_steps.ensureTotalCapacity(gpa, ordered_steps.items.len);
        for (ordered_steps.items) |os| {
            var step = os.step;
            if (move) {
                step.rho = 1.0 / step.rho;
                step.alpha = -step.alpha;
            } else {
                const a2 = step.rho * step.rho;
                step.r = 100.0 * ((1.0 + step.r / 100.0) * a2 - 1.0);
                step.x = 100.0 * ((1.0 + step.x / 100.0) * a2 - 1.0);
                step.g = 100.0 * ((1.0 + step.g / 100.0) / a2 - 1.0);
                step.b = 100.0 * ((1.0 + step.b / 100.0) / a2 - 1.0);
            }
            owned_steps.appendAssumeCapacity(step);
        }

        // PhaseTapChangerTabular maps to CURRENT_LIMITER in pypowsybl's CGMES importer.
        const gop = phase_tap_changer_map.getOrPutAssumeCapacity(end_id);
        if (gop.found_existing) gop.value_ptr.deinit(gpa);
        gop.value_ptr.* = .{
            .rdf_id = tap_changer.id(),
            .mrid = mrid,
            .tap_changer = .{
                .low_tap_position = common.low_step,
                .tap_position = common.normal_step,
                .load_tap_changing_capabilities = common.ltc_flag,
                .regulating = if (common.ltc_flag) (regulating orelse false) else null,
                .regulation_mode = "CURRENT_LIMITER",
                .steps = owned_steps,
            },
        };
    }

    if (tap_changer_info_map) |info_map| {
        for (tap_changers) |tap_changer| {
            const end_ref = try tap_changer.reference("PhaseTapChanger.TransformerEnd") orelse continue;
            const end_id = strip_hash(end_ref);
            const retained = phase_tap_changer_map.get(end_id) orelse continue;
            if (!std.mem.eql(u8, tap_changer.id(), retained.rdf_id)) continue;
            try append_tap_changer_info(gpa, model, info_map, end_id, retained.mrid, "PhaseTapChangerTabular", retained.tap_changer.tap_position);
        }
    }
    return phase_tap_changer_map;
}

test "build_phase_tap_changer_map unwinds entries when a later changer is invalid" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:PhaseTapChangerTable rdf:ID="_table"/>
        \\  <cim:PhaseTapChangerTablePoint rdf:ID="_point">
        \\    <cim:PhaseTapChangerTablePoint.PhaseTapChangerTable rdf:resource="#_table"/>
        \\    <cim:TapChangerTablePoint.step>0</cim:TapChangerTablePoint.step>
        \\    <cim:TapChangerTablePoint.ratio>1</cim:TapChangerTablePoint.ratio>
        \\  </cim:PhaseTapChangerTablePoint>
        \\  <cim:PowerTransformerEnd rdf:ID="_end1">
        \\    <cim:TransformerEnd.endNumber>1</cim:TransformerEnd.endNumber>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:PhaseTapChangerTabular rdf:ID="_valid">
        \\    <cim:PhaseTapChanger.TransformerEnd rdf:resource="#_end1"/>
        \\    <cim:PhaseTapChangerTabular.PhaseTapChangerTable rdf:resource="#_table"/>
        \\    <cim:TapChanger.lowStep>0</cim:TapChanger.lowStep>
        \\    <cim:TapChanger.normalStep>0</cim:TapChanger.normalStep>
        \\  </cim:PhaseTapChangerTabular>
        \\  <cim:PhaseTapChangerTabular rdf:ID="_invalid">
        \\    <cim:PhaseTapChanger.TransformerEnd rdf:resource="#_end2"/>
        \\    <cim:TapChanger.lowStep>not-an-integer</cim:TapChanger.lowStep>
        \\    <cim:TapChanger.normalStep>0</cim:TapChanger.normalStep>
        \\  </cim:PhaseTapChangerTabular>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(testing.allocator, try testing.allocator.dupe(u8, xml));
    defer model.deinit(testing.allocator);

    try testing.expectError(error.InvalidIntegerValue, build_phase_tap_changer_map(testing.allocator, &model, null, null));
}

test "tap changer info includes only retained map entries" {
    const xml =
        \\<rdf:RDF>
        \\  <cim:PowerTransformer rdf:ID="_transformer"/>
        \\  <cim:PowerTransformerEnd rdf:ID="_end1">
        \\    <cim:TransformerEnd.endNumber>1</cim:TransformerEnd.endNumber>
        \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#_transformer"/>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:PowerTransformerEnd rdf:ID="_end2">
        \\    <cim:TransformerEnd.endNumber>2</cim:TransformerEnd.endNumber>
        \\    <cim:PowerTransformerEnd.PowerTransformer rdf:resource="#_transformer"/>
        \\  </cim:PowerTransformerEnd>
        \\  <cim:RatioTapChanger rdf:ID="_ratio_first">
        \\    <cim:IdentifiedObject.mRID>ratio_same</cim:IdentifiedObject.mRID>
        \\    <cim:RatioTapChanger.TransformerEnd rdf:resource="#_end1"/>
        \\    <cim:TapChanger.lowStep>0</cim:TapChanger.lowStep>
        \\    <cim:TapChanger.highStep>0</cim:TapChanger.highStep>
        \\    <cim:TapChanger.normalStep>0</cim:TapChanger.normalStep>
        \\    <cim:TapChanger.neutralStep>0</cim:TapChanger.neutralStep>
        \\    <cim:RatioTapChanger.stepVoltageIncrement>1</cim:RatioTapChanger.stepVoltageIncrement>
        \\  </cim:RatioTapChanger>
        \\  <cim:RatioTapChanger rdf:ID="_ratio_skipped">
        \\    <cim:RatioTapChanger.TransformerEnd rdf:resource="#_end2"/>
        \\    <cim:RatioTapChanger.RatioTapChangerTable rdf:resource="#_missing_ratio_table"/>
        \\    <cim:TapChanger.lowStep>0</cim:TapChanger.lowStep>
        \\    <cim:TapChanger.normalStep>0</cim:TapChanger.normalStep>
        \\  </cim:RatioTapChanger>
        \\  <cim:RatioTapChanger rdf:ID="_ratio_second">
        \\    <cim:IdentifiedObject.mRID>ratio_same</cim:IdentifiedObject.mRID>
        \\    <cim:RatioTapChanger.TransformerEnd rdf:resource="#_end1"/>
        \\    <cim:TapChanger.lowStep>0</cim:TapChanger.lowStep>
        \\    <cim:TapChanger.highStep>0</cim:TapChanger.highStep>
        \\    <cim:TapChanger.normalStep>0</cim:TapChanger.normalStep>
        \\    <cim:TapChanger.neutralStep>0</cim:TapChanger.neutralStep>
        \\    <cim:RatioTapChanger.stepVoltageIncrement>1</cim:RatioTapChanger.stepVoltageIncrement>
        \\  </cim:RatioTapChanger>
        \\  <cim:PhaseTapChangerTable rdf:ID="_phase_table"/>
        \\  <cim:PhaseTapChangerTablePoint rdf:ID="_phase_point">
        \\    <cim:PhaseTapChangerTablePoint.PhaseTapChangerTable rdf:resource="#_phase_table"/>
        \\    <cim:TapChangerTablePoint.step>0</cim:TapChangerTablePoint.step>
        \\    <cim:TapChangerTablePoint.ratio>1</cim:TapChangerTablePoint.ratio>
        \\  </cim:PhaseTapChangerTablePoint>
        \\  <cim:PhaseTapChangerTabular rdf:ID="_phase_first">
        \\    <cim:IdentifiedObject.mRID>phase_same</cim:IdentifiedObject.mRID>
        \\    <cim:PhaseTapChanger.TransformerEnd rdf:resource="#_end1"/>
        \\    <cim:PhaseTapChangerTabular.PhaseTapChangerTable rdf:resource="#_phase_table"/>
        \\    <cim:TapChanger.lowStep>0</cim:TapChanger.lowStep>
        \\    <cim:TapChanger.normalStep>0</cim:TapChanger.normalStep>
        \\  </cim:PhaseTapChangerTabular>
        \\  <cim:PhaseTapChangerTabular rdf:ID="_phase_second">
        \\    <cim:IdentifiedObject.mRID>phase_same</cim:IdentifiedObject.mRID>
        \\    <cim:PhaseTapChanger.TransformerEnd rdf:resource="#_end1"/>
        \\    <cim:PhaseTapChangerTabular.PhaseTapChangerTable rdf:resource="#_phase_table"/>
        \\    <cim:TapChanger.lowStep>0</cim:TapChanger.lowStep>
        \\    <cim:TapChanger.normalStep>0</cim:TapChanger.normalStep>
        \\  </cim:PhaseTapChangerTabular>
        \\  <cim:PhaseTapChangerTabular rdf:ID="_phase_skipped">
        \\    <cim:PhaseTapChanger.TransformerEnd rdf:resource="#_end2"/>
        \\    <cim:PhaseTapChangerTabular.PhaseTapChangerTable rdf:resource="#_missing_phase_table"/>
        \\    <cim:TapChanger.lowStep>0</cim:TapChanger.lowStep>
        \\    <cim:TapChanger.normalStep>0</cim:TapChanger.normalStep>
        \\  </cim:PhaseTapChangerTabular>
        \\</rdf:RDF>
    ;
    var model = try CimDocument.init(testing.allocator, try testing.allocator.dupe(u8, xml));
    defer model.deinit(testing.allocator);

    var tap_changer_info_map: TapChangerInfoMap = .empty;
    defer deinit_tap_changer_info_map(testing.allocator, &tap_changer_info_map);

    var ratio_map = try build_ratio_tap_changer_map(testing.allocator, &model, null, &tap_changer_info_map);
    defer {
        var it = ratio_map.valueIterator();
        while (it.next()) |entry| entry.deinit(testing.allocator);
        ratio_map.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(u32, 1), ratio_map.count());
    try testing.expectEqualStrings("_ratio_second", ratio_map.get("_end1").?.rdf_id);
    try testing.expectEqualStrings("ratio_same", ratio_map.get("_end1").?.mrid);

    var phase_map = try build_phase_tap_changer_map(testing.allocator, &model, null, &tap_changer_info_map);
    defer {
        var it = phase_map.valueIterator();
        while (it.next()) |entry| entry.deinit(testing.allocator);
        phase_map.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(u32, 1), phase_map.count());
    try testing.expectEqualStrings("_phase_second", phase_map.get("_end1").?.rdf_id);
    try testing.expectEqualStrings("phase_same", phase_map.get("_end1").?.mrid);

    const retained_info = tap_changer_info_map.get("transformer") orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 2), retained_info.items.len);
    try testing.expectEqualStrings("ratio_same", retained_info.items[0].id);
    try testing.expectEqualStrings("phase_same", retained_info.items[1].id);
}

fn view_less_than(_: void, a: CimObject, b: CimObject) bool {
    const end_number0 = parse.int_or(u32, a.property("TransformerEnd.endNumber"), 0);
    const end_number1 = parse.int_or(u32, b.property("TransformerEnd.endNumber"), 0);
    return end_number0 < end_number1;
}

const TestEnd = struct { model: CimDocument, end: CimObject };

fn make_end(xml: []const u8) !TestEnd {
    const model = try CimDocument.init(testing.allocator, try testing.allocator.dupe(u8, xml));
    return .{ .model = model, .end = model.objects_by_type("PowerTransformerEnd")[0] };
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

test "CimObject.mrid treats blank content as absent" {
    var t = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_fallback">
        \\  <cim:IdentifiedObject.mRID>
        \\
        \\  </cim:IdentifiedObject.mRID>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer t.model.deinit(testing.allocator);

    try testing.expectEqualStrings("fallback", try t.end.mrid());
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

test "view_less_than: transitivity -- end1 < end2 and end2 < end3 implies end1 < end3" {
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

fn read_end_electrical(end: CimObject) !?EndElectrical {
    const props = try end.properties(.{
        "PowerTransformerEnd.ratedU",
        "PowerTransformerEnd.r",
        "PowerTransformerEnd.x",
        "PowerTransformerEnd.g",
        "PowerTransformerEnd.b",
        "PowerTransformerEnd.ratedS",
    });
    const rated_u = try parse.float_req(parse.non_blank(props[0]) orelse return null);
    if (rated_u == 0.0) return error.InvalidNumericValue;
    const r = try parse.float_strict(props[1], 0.0);
    const x = try parse.float_strict(props[2], 0.0);
    const g = try parse.float_strict(props[3], 0.0);
    const b = try parse.float_strict(props[4], 0.0);
    const rated_s: ?f64 = if (parse.non_blank(props[5])) |s| try parse.float_req(s) else null;
    return .{ .r = r, .x = x, .g = g, .b = b, .rated_u = rated_u, .rated_s = rated_s };
}

test "read_end_electrical treats explicit-empty and self-closing values as absent" {
    var explicit_empty = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e1">
        \\  <cim:PowerTransformerEnd.ratedU></cim:PowerTransformerEnd.ratedU>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer explicit_empty.model.deinit(testing.allocator);
    try testing.expect((try read_end_electrical(explicit_empty.end)) == null);

    var self_closing = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e1">
        \\  <cim:PowerTransformerEnd.ratedU/>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer self_closing.model.deinit(testing.allocator);
    try testing.expect((try read_end_electrical(self_closing.end)) == null);

    var optional_empty = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e1">
        \\  <cim:PowerTransformerEnd.ratedU>220</cim:PowerTransformerEnd.ratedU>
        \\  <cim:PowerTransformerEnd.ratedS></cim:PowerTransformerEnd.ratedS>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer optional_empty.model.deinit(testing.allocator);
    const electrical = (try read_end_electrical(optional_empty.end)).?;
    try testing.expectEqual(@as(f64, 220.0), electrical.rated_u);
    try testing.expectEqual(@as(?f64, null), electrical.rated_s);

    var zero_rated_u = try make_end(
        \\<rdf:RDF><cim:PowerTransformerEnd rdf:ID="_e1">
        \\  <cim:PowerTransformerEnd.ratedU>0</cim:PowerTransformerEnd.ratedU>
        \\</cim:PowerTransformerEnd></rdf:RDF>
    );
    defer zero_rated_u.model.deinit(testing.allocator);
    try testing.expectError(error.InvalidNumericValue, read_end_electrical(zero_rated_u.end));
}

fn resolve_end_placement(
    end: CimObject,
    placer: TerminalPlacer,
) !?Placement {
    const terminal_ref = try end.reference("TransformerEnd.Terminal") orelse return null;
    const terminal_id = strip_hash(terminal_ref);
    // terminal_conn_node may be missing in bus-branch mode (no CN); placer handles
    // that. One lookup yields both the CN and the ordinal, so the node comes out
    // of NodeMap without hashing the id a second time.
    const terminal_ref_info = placer.index.terminal_conn_node.get(terminal_id);
    return placer.resolve_terminal(
        terminal_id,
        if (terminal_ref_info) |info| info.conn_node_id else null,
        if (terminal_ref_info) |info| info.ordinal else null,
    );
}

fn pre_allocate_transformers(
    gpa: std.mem.Allocator,
    ends_by_transformer: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObject)),
    substation_map: *const std.StringHashMapUnmanaged(*iidm.Substation),
    placer: TerminalPlacer,
) !void {
    var transformer_counts: std.AutoHashMapUnmanaged(*iidm.Substation, struct { two: u32, three: u32 }) = .empty;
    defer transformer_counts.deinit(gpa);
    try transformer_counts.ensureTotalCapacity(gpa, @intCast(ends_by_transformer.count()));

    var it = ends_by_transformer.iterator();
    while (it.next()) |entry| {
        const ends = entry.value_ptr.*;
        const winding_count = ends.items.len;
        if (winding_count != 2 and winding_count != 3) continue;

        const placement1 = try resolve_end_placement(ends.items[0], placer) orelse continue;
        const substation = substation_map.get(placement1.repr_voltage_level_id) orelse continue;

        const gop = transformer_counts.getOrPutAssumeCapacity(substation);
        if (!gop.found_existing) gop.value_ptr.* = .{ .two = 0, .three = 0 };
        const field = if (winding_count == 2) &gop.value_ptr.two else &gop.value_ptr.three;
        field.* = std.math.add(u32, field.*, 1) catch return error.TooManyTransformers;
    }

    var counts_it = transformer_counts.iterator();
    while (counts_it.next()) |entry| {
        const substation = entry.key_ptr.*;
        try substation.two_winding_transformers.ensureTotalCapacity(gpa, @intCast(entry.value_ptr.two));
        try substation.three_winding_transformers.ensureTotalCapacity(gpa, @intCast(entry.value_ptr.three));
    }

    assert(transformer_counts.count() <= placer.voltage_level_map.count());
}

fn append_two_windings_transformer(
    gpa: std.mem.Allocator,
    transformer: CimObject,
    ends: []const CimObject,
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

    const mrid = try transformer.mrid();
    const name = parse.non_blank(transformer.property("IdentifiedObject.name"));

    // Tap changers keyed by end rdf:ID (= end.id). Track which end (1 or 2) so we can
    // emit the correct CGMES.RatioTapChanger<N> / CGMES.PhaseTapChanger<N> alias.
    var ratio_tc: ?RatioTapChangerEntry = null;
    var ratio_tc_side: u8 = 0;
    if (ratio_tap_changer_map.fetchRemove(ends[0].id())) |kv| {
        ratio_tc = kv.value;
        ratio_tc_side = 1;
    } else if (ratio_tap_changer_map.fetchRemove(ends[1].id())) |kv| {
        ratio_tc = kv.value;
        ratio_tc_side = 2;
    }
    var phase_tc: ?PhaseTapChangerEntry = null;
    var phase_tc_side: u8 = 0;
    if (phase_tap_changer_map.fetchRemove(ends[0].id())) |kv| {
        phase_tc = kv.value;
        phase_tc_side = 1;
    } else if (phase_tap_changer_map.fetchRemove(ends[1].id())) |kv| {
        phase_tc = kv.value;
        phase_tc_side = 2;
    }
    var tap_changers_transferred = false;
    defer if (!tap_changers_transferred) {
        if (ratio_tc) |*entry| entry.deinit(gpa);
        if (phase_tc) |*entry| entry.deinit(gpa);
    };

    // aliases + operational limits per terminal, keyed by end's own Terminal.
    const t1_id = strip_hash(try ends[0].reference("TransformerEnd.Terminal") orelse return);
    const t2_id = strip_hash(try ends[1].reference("TransformerEnd.Terminal") orelse return);

    var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
    errdefer aliases.deinit(gpa);
    try aliases.ensureTotalCapacity(gpa, 6);
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal1" }, .content = strip_underscore(t1_id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal2" }, .content = strip_underscore(t2_id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.TransformerEnd1" }, .content = strip_underscore(ends[0].id()) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.TransformerEnd2" }, .content = strip_underscore(ends[1].id()) });
    if (ratio_tc) |rtc| {
        const type_str: []const u8 = if (ratio_tc_side == 1) "CGMES.RatioTapChanger1" else "CGMES.RatioTapChanger2";
        aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = type_str }, .content = rtc.mrid });
    }
    if (phase_tc) |ptc| {
        const type_str: []const u8 = if (phase_tc_side == 1) "CGMES.PhaseTapChanger1" else "CGMES.PhaseTapChanger2";
        aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = type_str }, .content = ptc.mrid });
    }

    var op_lims_groups_1 = try placement_mod.build_op_lims(gpa, placer.index, t1_id);
    errdefer {
        for (op_lims_groups_1.items) |*group| group.deinit(gpa);
        op_lims_groups_1.deinit(gpa);
    }
    var op_lims_groups_2 = try placement_mod.build_op_lims(gpa, placer.index, t2_id);
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
    tap_changers_transferred = true;
}

fn append_three_windings_transformer(
    gpa: std.mem.Allocator,
    transformer: CimObject,
    ends: []const CimObject,
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

    const mrid = try transformer.mrid();
    const name = parse.non_blank(transformer.property("IdentifiedObject.name"));

    // Tap changers keyed by end rdf:ID (= end.id). fetchRemove takes ownership.
    const rtc1 = ratio_tap_changer_map.fetchRemove(ends[0].id());
    const rtc2 = ratio_tap_changer_map.fetchRemove(ends[1].id());
    const rtc3 = ratio_tap_changer_map.fetchRemove(ends[2].id());
    var tap_changers_transferred = false;
    defer if (!tap_changers_transferred) {
        if (rtc1) |kv| {
            var entry = kv.value;
            entry.deinit(gpa);
        }
        if (rtc2) |kv| {
            var entry = kv.value;
            entry.deinit(gpa);
        }
        if (rtc3) |kv| {
            var entry = kv.value;
            entry.deinit(gpa);
        }
    };

    // aliases + operational limits per terminal, keyed by end's own Terminal.
    const t1_id = strip_hash(try ends[0].reference("TransformerEnd.Terminal") orelse return);
    const t2_id = strip_hash(try ends[1].reference("TransformerEnd.Terminal") orelse return);
    const t3_id = strip_hash(try ends[2].reference("TransformerEnd.Terminal") orelse return);

    var aliases: std.ArrayListUnmanaged(iidm.Alias) = .empty;
    errdefer aliases.deinit(gpa);
    try aliases.ensureTotalCapacity(gpa, 9);
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal1" }, .content = strip_underscore(t1_id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal2" }, .content = strip_underscore(t2_id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.Terminal3" }, .content = strip_underscore(t3_id) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.TransformerEnd1" }, .content = strip_underscore(ends[0].id()) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.TransformerEnd2" }, .content = strip_underscore(ends[1].id()) });
    aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.TransformerEnd3" }, .content = strip_underscore(ends[2].id()) });
    if (rtc1) |kv| aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.RatioTapChanger1" }, .content = kv.value.mrid });
    if (rtc2) |kv| aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.RatioTapChanger2" }, .content = kv.value.mrid });
    if (rtc3) |kv| aliases.appendAssumeCapacity(.{ .type_info = .{ .static_string = "CGMES.RatioTapChanger3" }, .content = kv.value.mrid });

    var op_lims_groups_1 = try placement_mod.build_op_lims(gpa, placer.index, t1_id);
    errdefer {
        for (op_lims_groups_1.items) |*group| group.deinit(gpa);
        op_lims_groups_1.deinit(gpa);
    }
    var op_lims_groups_2 = try placement_mod.build_op_lims(gpa, placer.index, t2_id);
    errdefer {
        for (op_lims_groups_2.items) |*group| group.deinit(gpa);
        op_lims_groups_2.deinit(gpa);
    }
    var op_lims_groups_3 = try placement_mod.build_op_lims(gpa, placer.index, t3_id);
    errdefer {
        for (op_lims_groups_3.items) |*group| group.deinit(gpa);
        op_lims_groups_3.deinit(gpa);
    }
    const selected_1: ?[]const u8 = if (op_lims_groups_1.items.len > 0) op_lims_groups_1.items[0].id else null;
    const selected_2: ?[]const u8 = if (op_lims_groups_2.items.len > 0) op_lims_groups_2.items[0].id else null;
    const selected_3: ?[]const u8 = if (op_lims_groups_3.items.len > 0) op_lims_groups_3.items[0].id else null;

    // Refer each end's r/x/g/b to the star-point voltage (u0 = u1). Ratio per end
    // is u1/uN. Impedance scales by ratio²; admittance by 1/ratio². End 1 ratio is 1.
    const ratio2_2 = (e1.rated_u / e2.rated_u) * (e1.rated_u / e2.rated_u);
    const ratio2_3 = (e1.rated_u / e3.rated_u) * (e1.rated_u / e3.rated_u);

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
    tap_changers_transferred = true;
}

pub fn convert_transformers(
    gpa: std.mem.Allocator,
    model: *const CimDocument,
    substation_map: *const std.StringHashMapUnmanaged(*iidm.Substation),
    placer: TerminalPlacer,
    ssh_opt: ?cim.Overlay,
    tap_changer_info_map: ?*TapChangerInfoMap,
) !void {
    var ends_by_transformer: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(CimObject)) = try build_ends_by_transformer(gpa, model);
    defer {
        var it = ends_by_transformer.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        ends_by_transformer.deinit(gpa);
    }

    var ratio_tap_changer_map = try build_ratio_tap_changer_map(gpa, model, ssh_opt, tap_changer_info_map);
    defer {
        var it = ratio_tap_changer_map.valueIterator();
        while (it.next()) |value| value.deinit(gpa);
        ratio_tap_changer_map.deinit(gpa);
    }

    var phase_tap_changer_map = try build_phase_tap_changer_map(gpa, model, ssh_opt, tap_changer_info_map);
    defer {
        var it = phase_tap_changer_map.valueIterator();
        while (it.next()) |value| value.deinit(gpa);
        phase_tap_changer_map.deinit(gpa);
    }

    try pre_allocate_transformers(gpa, &ends_by_transformer, substation_map, placer);

    const transformers = model.objects_by_type("PowerTransformer");
    for (transformers) |transformer| {
        const ends = ends_by_transformer.get(transformer.id()) orelse continue;
        const end1 = ends.items[0];
        const placement = try resolve_end_placement(end1, placer) orelse continue;
        const substation = substation_map.get(placement.repr_voltage_level_id) orelse continue;

        switch (ends.items.len) {
            2 => try append_two_windings_transformer(gpa, transformer, ends.items, substation, placer, &ratio_tap_changer_map, &phase_tap_changer_map),
            3 => try append_three_windings_transformer(gpa, transformer, ends.items, substation, placer, &ratio_tap_changer_map),
            else => continue,
        }
    }
}

test "convert_transformers skips a transformer without ends" {
    const xml = "<rdf:RDF><cim:PowerTransformer rdf:ID=\"_transformer\"/></rdf:RDF>";
    var model = try CimDocument.init(testing.allocator, try testing.allocator.dupe(u8, xml));
    defer model.deinit(testing.allocator);

    var index = CrossRef.empty();
    defer index.deinit(testing.allocator);
    var topology_data = topology.Topology.empty();
    defer topology_data.deinit(testing.allocator);
    var voltage_level_map: std.StringHashMapUnmanaged(*iidm.VoltageLevel) = .empty;
    defer voltage_level_map.deinit(testing.allocator);
    var node_map: NodeMap = .empty;
    defer node_map.deinit(testing.allocator);
    const placer = TerminalPlacer{
        .mode = .{ .node_breaker = &node_map },
        .index = &index,
        .topology = &topology_data,
        .voltage_level_map = &voltage_level_map,
    };
    var substation_map: std.StringHashMapUnmanaged(*iidm.Substation) = .empty;
    defer substation_map.deinit(testing.allocator);

    try convert_transformers(testing.allocator, &model, &substation_map, placer, null, null);
}
