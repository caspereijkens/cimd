const std = @import("std");
const iidm = @import("../iidm.zig");
const cim_model = @import("../cim_model.zig");
const cim_index = @import("../cim_index.zig");
const tag_index = @import("../tag_index.zig");
const utils = @import("../utils.zig");

const assert = std.debug.assert;

const CimModel = cim_model.CimModel;
const CimObject = tag_index.CimObject;
const CimIndex = cim_index.CimIndex;
const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

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

    assert(ends_by_transformer.count() > 0);

    return ends_by_transformer;
}

fn lessThanFn(_: void, end0: CimObject, end1: CimObject) bool {
    const end_number0_str = end0.getProperty("TransformerEnd.endNumber") catch "0" orelse "0";
    const end_number0 = std.fmt.parseInt(u32, end_number0_str, 10) catch 0;

    const end_number1_str = end1.getProperty("TransformerEnd.endNumber") catch "0" orelse "0";
    const end_number1 = std.fmt.parseInt(u32, end_number1_str, 10) catch 0;

    return end_number0 < end_number1;
}

fn build_ratio_tap_changer_map(
    gpa: std.mem.Allocator,
    model: *const CimModel,
) !std.StringHashMapUnmanaged(iidm.RatioTapChanger) {
    var points_by_table: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(iidm.RatioTapChangerStep)) = .empty;
    defer {
        var it = points_by_table.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        points_by_table.deinit(gpa);
    }

    const tables = model.getObjectsByType("RatioTapChangerTable");
    try points_by_table.ensureTotalCapacity(gpa, @intCast(tables.len));

    const points = model.getObjectsByType("RatioTapChangerTablePoint");

    for (points) |point| {
        const table_ref = try point.getReference("RatioTapChangerTablePoint.RatioTapChangerTable") orelse continue;
        const table_id = strip_hash(table_ref);

        const r_str = try point.getProperty("TapChangerTablePoint.r") orelse "0.0";
        const r = try std.fmt.parseFloat(f64, r_str);

        const x_str = try point.getProperty("TapChangerTablePoint.x") orelse "0.0";
        const x = try std.fmt.parseFloat(f64, x_str);

        const g_str = try point.getProperty("TapChangerTablePoint.g") orelse "0.0";
        const g = try std.fmt.parseFloat(f64, g_str);

        const b_str = try point.getProperty("TapChangerTablePoint.b") orelse "0.0";
        const b = try std.fmt.parseFloat(f64, b_str);

        const ratio_str = try point.getProperty("TapChangerTablePoint.ratio") orelse continue;
        const ratio = try std.fmt.parseFloat(f64, ratio_str);
        const rho = if (ratio != 0.0) 1.0 / ratio else 1.0;

        const gop = points_by_table.getOrPutAssumeCapacity(table_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, .{
            .r = r,
            .x = x,
            .g = g,
            .b = b,
            .rho = rho,
        });
    }

    const tap_changers = model.getObjectsByType("RatioTapChanger");

    var ratio_tap_changer_map: std.StringHashMapUnmanaged(iidm.RatioTapChanger) = .empty;
    try ratio_tap_changer_map.ensureTotalCapacity(gpa, @intCast(tap_changers.len));

    for (tap_changers) |tap_changer| {
        const end_ref = try tap_changer.getReference("RatioTapChanger.TransformerEnd") orelse continue;
        const end_id = strip_hash(end_ref);

        const low_step_str = try tap_changer.getProperty("TapChanger.lowStep") orelse continue;
        const low_step = try std.fmt.parseInt(i32, low_step_str, 10);

        const normal_step_str = try tap_changer.getProperty("TapChanger.normalStep") orelse continue;
        const normal_step = try std.fmt.parseInt(i32, normal_step_str, 10);

        const ltc_flag_str = try tap_changer.getProperty("TapChanger.ltcFlag") orelse continue;
        const ltc_flag = std.mem.eql(u8, ltc_flag_str, "true");

        var owned_steps: std.ArrayListUnmanaged(iidm.RatioTapChangerStep) = .empty;

        if (try tap_changer.getReference("RatioTapChanger.RatioTapChangerTable")) |table_ref| {
            // Tabular case
            const table_id = strip_hash(table_ref);
            const steps = points_by_table.get(table_id) orelse continue;

            try owned_steps.ensureTotalCapacity(gpa, steps.items.len);
            owned_steps.appendSliceAssumeCapacity(steps.items);
        } else {
            // Linear case
            const high_step_str = try tap_changer.getProperty("TapChanger.highStep") orelse continue;
            const high_step = try std.fmt.parseInt(i32, high_step_str, 10);

            try owned_steps.ensureTotalCapacity(gpa, @intCast(high_step - low_step + 1));
            const neutral_step_str = try tap_changer.getProperty("TapChanger.neutralStep") orelse continue;
            const neutral_step = try std.fmt.parseInt(i32, neutral_step_str, 10);

            const step_voltage_increment_str = try tap_changer.getProperty("RatioTapChanger.stepVoltageIncrement") orelse continue;
            const step_voltage_increment = try std.fmt.parseFloat(f64, step_voltage_increment_str);

            var step: i32 = low_step;
            while (step <= high_step) : (step += 1) {
                const rho = 1.0 + @as(f64, @floatFromInt(step - neutral_step)) * step_voltage_increment / 100.0;
                owned_steps.appendAssumeCapacity(.{
                    .r = 0.0,
                    .x = 0.0,
                    .g = 0.0,
                    .b = 0.0,
                    .rho = rho,
                });
            }
        }

        ratio_tap_changer_map.putAssumeCapacity(end_id, .{
            .low_tap_position = low_step,
            .tap_position = normal_step,
            .load_tap_changing_capabilities = ltc_flag,
            .regulating = null,
            .regulation_mode = null,
            .terminal_ref = null,
            .steps = owned_steps,
        });
    }
    return ratio_tap_changer_map;
}
