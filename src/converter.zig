const std = @import("std");
const iidm = @import("iidm.zig");
const cim_model = @import("cim_model.zig");
const cim_index = @import("cim_index.zig");
const utils = @import("utils.zig");
const tag_index = @import("tag_index.zig");
const substation_conv = @import("convert/substation.zig");
const voltage_level_conv = @import("convert/voltage_level.zig");
const connection_conv = @import("convert/connection.zig");
const equipment_conv = @import("convert/equipment.zig");
const transformer_conv = @import("convert/transformer.zig");
const line_conv = @import("convert/line.zig");

const assert = std.debug.assert;
const CimModel = cim_model.CimModel;
const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

/// Decode XML character entities in-place into a newly-allocated string.
/// Handles &lt; &gt; &amp; &quot; &apos; only (CGMES descriptions use these).
fn decode_xml_entities(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    try result.ensureTotalCapacity(gpa, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '+') {
            try result.append(gpa, ' ');
            i += 1;
            continue;
        }
        if (s[i] != '&') {
            try result.append(gpa, s[i]);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, s[i..], "&lt;")) {
            try result.append(gpa, '<');
            i += 4;
        } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
            try result.append(gpa, '>');
            i += 4;
        } else if (std.mem.startsWith(u8, s[i..], "&amp;")) {
            try result.append(gpa, '&');
            i += 5;
        } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
            try result.append(gpa, '"');
            i += 6;
        } else if (std.mem.startsWith(u8, s[i..], "&apos;")) {
            try result.append(gpa, '\'');
            i += 6;
        } else {
            try result.append(gpa, s[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(gpa);
}

/// Parse ISO8601 datetime "YYYY-MM-DDTHH:MM:SSZ" to seconds since Unix epoch.
/// Uses the Howard Hinnant civil-from-days algorithm.
fn parse_iso8601_seconds(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    // Days since Unix epoch using Gregorian calendar algorithm.
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else @as(i64, year);
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const m: i64 = @as(i64, month);
    const doy: i64 = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else @as(i64, 9))) + 2, 5) + @as(i64, day) - 1;
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days_since_epoch: i64 = era * 146097 + doe - 719468;

    return days_since_epoch * 86400 + hour * 3600 + minute * 60 + second;
}

/// Convert ControlArea + TieFlow CIM objects to IIDM Area objects.
/// Each ControlArea becomes one Area. Each TieFlow becomes one AreaBoundary:
///   boundary.id   = ConductingEquipment mRID of the TieFlow.Terminal
///   boundary.side = sequenceNumber of the TieFlow.Terminal (1→"ONE", 2→"TWO")
///   boundary.ac   = true (always, as all equipment is AC in EQ profiles)
fn convert_areas(gpa: std.mem.Allocator, model: *const CimModel, network: *iidm.Network) !void {
    const control_areas = model.get_objects_by_type("ControlArea");
    assert(network.areas.items.len == 0);
    if (control_areas.len == 0) return;

    try network.areas.ensureTotalCapacity(gpa, control_areas.len);

    for (control_areas) |ca| {
        const ca_mrid = try ca.getProperty("IdentifiedObject.mRID") orelse strip_underscore(ca.id);
        const ca_name = try ca.getProperty("IdentifiedObject.name") orelse ca_mrid;

        // ControlArea.type is a rdf:resource; extract the fragment after '#'.
        const area_type: []const u8 = blk: {
            const raw = try ca.getReference("ControlArea.type") orelse break :blk "ControlAreaTypeKind.Interchange";
            const hash = std.mem.lastIndexOfScalar(u8, raw, '#') orelse break :blk raw;
            break :blk raw[hash + 1 ..];
        };

        // Collect all TieFlow objects that reference this ControlArea.
        const tieflows = model.get_objects_by_type("TieFlow");
        var boundaries: std.ArrayListUnmanaged(iidm.AreaBoundary) = .empty;
        errdefer boundaries.deinit(gpa);

        for (tieflows) |tf| {
            const ca_ref = try tf.getReference("TieFlow.ControlArea") orelse continue;
            const ca_id = strip_hash(ca_ref);
            if (!std.mem.eql(u8, ca_id, ca.id) and !std.mem.eql(u8, ca_id, ca_mrid)) continue;

            const term_ref = try tf.getReference("TieFlow.Terminal") orelse continue;
            const term_id = strip_hash(term_ref);
            const term_obj = model.getObjectById(term_id) orelse continue;

            const equipment_ref = try term_obj.getReference("Terminal.ConductingEquipment") orelse continue;
            const equipment_id = strip_hash(equipment_ref);
            const equipment = model.getObjectById(equipment_id) orelse continue;
            const eq_mrid = try equipment.getProperty("IdentifiedObject.mRID") orelse strip_underscore(equipment_id);

            const seq_str = try term_obj.getProperty("ACDCTerminal.sequenceNumber") orelse "1";
            const seq = std.fmt.parseInt(u32, std.mem.trim(u8, seq_str, " \t\r\n"), 10) catch 1;
            const side: []const u8 = if (seq == 1) "ONE" else "TWO";

            try boundaries.append(gpa, .{ .id = eq_mrid, .side = side });
        }

        assert(boundaries.items.len > 0);
        network.areas.appendAssumeCapacity(.{
            .id = ca_mrid,
            .name = ca_name,
            .area_type = area_type,
            .boundaries = boundaries,
        });
    }
}

/// Convert a CimModel into an IIDM Network.
/// Caller owns the returned network and must call network.deinit(gpa).
pub fn convert(gpa: std.mem.Allocator, model: *const CimModel) !iidm.Network {
    assert(model.get_objects_by_type("Substation").len > 0);

    const boundary_ids: std.StringHashMapUnmanaged(void) = .empty;
    var index = try cim_index.CimIndex.build(gpa, model, boundary_ids);
    defer index.deinit(gpa);

    // ---- FullModel metadata: id, caseDate, forecastDistance ----
    const full_models = model.get_objects_by_type("FullModel");
    const eq_full_model: ?*const cim_model.CimObject = if (full_models.len > 0) &full_models[0] else null;
    const network_id = if (eq_full_model) |fm| fm.id else "unknown";
    const scenario_time: ?[]const u8 = if (eq_full_model) |fm|
        try fm.getProperty("Model.scenarioTime")
    else
        null;
    const created_time: ?[]const u8 = if (eq_full_model) |fm|
        try fm.getProperty("Model.created")
    else
        null;
    const forecast_distance: u32 = blk: {
        const st = scenario_time orelse break :blk 0;
        const ct = created_time orelse break :blk 0;
        const st_secs = parse_iso8601_seconds(std.mem.trim(u8, st, " \t\r\n")) orelse break :blk 0;
        const ct_secs = parse_iso8601_seconds(std.mem.trim(u8, ct, " \t\r\n")) orelse break :blk 0;
        const diff_secs = st_secs - ct_secs;
        break :blk if (diff_secs > 0) @intCast(@divTrunc(diff_secs, 60)) else 0;
    };

    var network = iidm.Network{
        .id = network_id,
        .case_date = scenario_time,
        .forecast_distance = forecast_distance,
        .substations = .empty,
        .lines = .empty,
        .hvdc_lines = .empty,
        .extensions = .empty,
    };
    errdefer network.deinit(gpa);

    var sub_id_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer sub_id_map.deinit(gpa);
    try substation_conv.convert_substations(gpa, model, &index, &network, &sub_id_map);

    try voltage_level_conv.convert_voltage_levels(gpa, model, &index, &network, &sub_id_map);

    var substation_map: std.StringHashMapUnmanaged(*iidm.Substation) = .empty;
    defer substation_map.deinit(gpa);
    var voltage_level_map = try voltage_level_conv.build_voltage_level_map(gpa, model, &index, &network, &sub_id_map, &substation_map);
    defer voltage_level_map.deinit(gpa);

    var node_map = try connection_conv.build_node_map(gpa, model, &index, &voltage_level_map);
    defer node_map.deinit(gpa);

    try equipment_conv.pre_allocate_equipment(gpa, model, &index, &voltage_level_map);
    try equipment_conv.convert_busbar_sections(model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_switches(model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_loads(gpa, model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_shunts(model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_static_var_compensators(model, &index, &voltage_level_map, &node_map);
    try equipment_conv.convert_generators(gpa, model, &index, &voltage_level_map, &node_map);
    try transformer_conv.convert_transformers(gpa, model, &index, &substation_map, &voltage_level_map, &node_map);
    try line_conv.convert_lines(gpa, model, &index, &network, &voltage_level_map, &node_map);
    try convert_areas(gpa, model, &network);

    // -------------------------------------------------------------------------
    // Emit top-level extensions.
    // Order matches PyPowSyBl: cgmesTapChangers, detail, coordinatedReactiveControl,
    // cgmesMetadataModels, baseVoltageMapping, cimCharacteristics.
    //
    // -------------------------------------------------------------------------

    // cgmesTapChangers: one extension per transformer that has a RatioTapChanger
    // or PhaseTapChangerTabular. The extension ID is the PowerTransformer mRID.
    // step = TapChanger.normalStep.
    {
        // Build a map: transformer_mrid -> list of TapChangerInfo
        var xfmr_tc_map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(iidm.TapChangerInfo)) = .empty;
        defer {
            var it = xfmr_tc_map.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(gpa);
            xfmr_tc_map.deinit(gpa);
        }

        const tc_types = [_]struct { type_name: []const u8, is_phase: bool }{
            .{ .type_name = "RatioTapChanger", .is_phase = false },
            .{ .type_name = "PhaseTapChangerTabular", .is_phase = true },
        };
        for (tc_types) |tc_type| {
            for (model.get_objects_by_type(tc_type.type_name)) |tc| {
                const step_str = try tc.getProperty("TapChanger.normalStep") orelse continue;
                const step = std.fmt.parseInt(i32, std.mem.trim(u8, step_str, " \t\r\n"), 10) catch continue;
                const tc_mrid = try tc.getProperty("IdentifiedObject.mRID") orelse strip_underscore(tc.id);

                // TransformerEnd → PowerTransformer
                const end_ref = try tc.getReference(if (tc_type.is_phase) "PhaseTapChanger.TransformerEnd" else "RatioTapChanger.TransformerEnd") orelse continue;
                const end_id = strip_hash(end_ref);
                const end_obj = model.getObjectById(end_id) orelse continue;
                const xfmr_ref = try end_obj.getReference("PowerTransformerEnd.PowerTransformer") orelse continue;
                const xfmr_id = strip_hash(xfmr_ref);
                const xfmr_obj = model.getObjectById(xfmr_id) orelse continue;
                const xfmr_mrid = try xfmr_obj.getProperty("IdentifiedObject.mRID") orelse strip_underscore(xfmr_id);

                const gop = try xfmr_tc_map.getOrPut(gpa, xfmr_mrid);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(gpa, .{
                    .id = tc_mrid,
                    .tap_changer_type = if (tc_type.is_phase) "PhaseTapChangerTabular" else null,
                    .step = step,
                });
            }
        }

        if (xfmr_tc_map.count() > 0) {
            try network.extensions.ensureTotalCapacity(gpa, network.extensions.items.len + xfmr_tc_map.count());
            var it = xfmr_tc_map.iterator();
            while (it.next()) |entry| {
                network.extensions.appendAssumeCapacity(.{
                    .id = entry.key_ptr.*,
                    .cgmes_tap_changers = .{ .tap_changers = entry.value_ptr.* },
                });
                entry.value_ptr.* = .empty; // ownership transferred
            }
            try network.extension_versions.append(gpa, .{ .extension_name = "cgmesTapChangers" });
        }
    }

    // detail extension: every load gets {fixedActivePower, fixedReactivePower,
    // variableActivePower, variableReactivePower} all zero. The EQ profile does
    // not provide a fixed/variable power split; PyPowSyBl defaults to all-zero.
    {
        var load_count: usize = 0;
        for (network.substations.items) |substation| {
            for (substation.voltage_levels.items) |voltage_level| {
                load_count += voltage_level.loads.items.len;
            }
        }
        try network.extensions.ensureTotalCapacity(gpa, network.extensions.items.len + load_count);
        for (network.substations.items) |substation| {
            for (substation.voltage_levels.items) |voltage_level| {
                for (voltage_level.loads.items) |load| {
                    network.extensions.appendAssumeCapacity(.{
                        .id = load.id,
                        .detail = .{
                            .fixed_active_power = 0.0,
                            .fixed_reactive_power = 0.0,
                            .variable_active_power = 0.0,
                            .variable_reactive_power = 0.0,
                        },
                    });
                }
            }
        }
        if (load_count > 0) {
            try network.extension_versions.append(gpa, .{ .extension_name = "detail" });
        }
    }

    // coordinatedReactiveControl: generators with SynchronousMachine.qPercent.
    {
        const machines = model.get_objects_by_type("SynchronousMachine");
        var crc_count: usize = 0;
        for (machines) |m| {
            if (try m.getProperty("SynchronousMachine.qPercent") != null) crc_count += 1;
        }
        if (crc_count > 0) {
            try network.extensions.ensureTotalCapacity(gpa, network.extensions.items.len + crc_count);
            for (machines) |m| {
                const qpct_str = try m.getProperty("SynchronousMachine.qPercent") orelse continue;
                const qpct = std.fmt.parseFloat(f64, std.mem.trim(u8, qpct_str, " \t\r\n")) catch continue;
                const mrid = try m.getProperty("IdentifiedObject.mRID") orelse strip_underscore(m.id);
                network.extensions.appendAssumeCapacity(.{
                    .id = mrid,
                    .coordinated_reactive_control = .{ .q_percent = qpct },
                });
            }
            try network.extension_versions.append(gpa, .{ .extension_name = "coordinatedReactiveControl" });
        }
    }

    // cgmesMetadataModels + baseVoltageMapping + cimCharacteristics:
    // PyPowSyBl combines all three into a single extension entry keyed by network ID.
    // Order of fields in the entry: cgmesMetadataModels, baseVoltageMapping, cimCharacteristics.
    {
        // --- cgmesMetadataModels ---
        // Order: dependencies (EQBD) first, then the main EQ model.
        // Subset derived from profile URL: CoreEquipment → "EQUIPMENT", else "UNKNOWN".
        const profile_to_subset = struct {
            fn get(profile_url: []const u8) []const u8 {
                if (std.mem.indexOf(u8, profile_url, "CoreEquipment") != null) return "EQUIPMENT";
                return "UNKNOWN";
            }
        }.get;

        var metadata_models: std.ArrayListUnmanaged(iidm.MetadataModel) = .empty;
        errdefer {
            for (metadata_models.items) |*m| m.deinit(gpa);
            metadata_models.deinit(gpa);
        }

        const fm_count = full_models.len;
        for (0..fm_count) |round| {
            const start_i: usize = if (round == 0) 1 else 0;
            const end_i: usize = if (round == 0) fm_count else 1;
            for (full_models[start_i..end_i]) |fm| {
                const fm_id = fm.id;
                const mas = try fm.getProperty("Model.modelingAuthoritySet") orelse "";
                const raw_desc = try fm.getProperty("Model.description") orelse "";
                const desc = try decode_xml_entities(gpa, raw_desc);
                const version_str = try fm.getProperty("Model.version") orelse "0";
                const version = std.fmt.parseInt(u32, std.mem.trim(u8, version_str, " \t\r\n"), 10) catch 0;

                var profiles: std.ArrayListUnmanaged(iidm.ModelProfile) = .empty;
                var dependent_on: std.ArrayListUnmanaged(iidm.DependentOnModel) = .empty;
                var subset: []const u8 = "UNKNOWN";
                for (fm.boundaries[fm.object_tag_idx + 1 .. fm.closing_tag_idx], fm.object_tag_idx + 1..) |tag, ti| {
                    if (fm.xml[tag.start + 1] == '/') continue; // skip closing tags
                    const is_self_closing = fm.xml[tag.end - 1] == '/';
                    const tag_type = tag_index.extract_tag_type(fm.xml, tag.start) catch continue;
                    if (std.mem.eql(u8, tag_type, "Model.profile") and !is_self_closing) {
                        const content = fm.xml[tag.end + 1 .. fm.boundaries[ti + 1].start];
                        try profiles.append(gpa, .{ .content = content });
                        const s = profile_to_subset(content);
                        if (!std.mem.eql(u8, s, "UNKNOWN")) subset = s;
                    } else if (std.mem.eql(u8, tag_type, "Model.DependentOn")) {
                        const ref = tag_index.extract_rdf_resource(fm.xml, tag.start) catch continue;
                        if (ref) |r| try dependent_on.append(gpa, .{ .content = r });
                    }
                }
                try metadata_models.append(gpa, .{
                    .subset = subset,
                    .modeling_authority_set = mas,
                    .id = fm_id,
                    .version = version,
                    .description = desc,
                    .profiles = profiles,
                    .dependent_on_models = dependent_on,
                });
            }
        }
        assert(metadata_models.items.len == fm_count);

        // --- baseVoltageMapping ---
        // EQ FullModel is always first in XML order; EQBD FullModel (if present) comes after.
        const eq_boundary: u32 = if (full_models.len >= 2)
            full_models[1].boundaries[full_models[1].object_tag_idx].start
        else
            std.math.maxInt(u32);

        const base_voltages = model.get_objects_by_type("BaseVoltage");
        var bv_list: std.ArrayListUnmanaged(iidm.BaseVoltage) = .empty;
        errdefer bv_list.deinit(gpa);
        try bv_list.ensureTotalCapacity(gpa, base_voltages.len);
        for (base_voltages) |bv| {
            const bv_mrid = try bv.getProperty("IdentifiedObject.mRID") orelse strip_underscore(bv.id);
            const nom_v_str = try bv.getProperty("BaseVoltage.nominalVoltage") orelse continue;
            const nom_v = std.fmt.parseFloat(f64, std.mem.trim(u8, nom_v_str, " \t\r\n")) catch continue;
            const xml_pos = bv.boundaries[bv.object_tag_idx].start;
            const source: []const u8 = if (xml_pos < eq_boundary) "IGM" else "BOUNDARY";
            bv_list.appendAssumeCapacity(.{ .nominal_voltageoltage = nom_v, .source = source, .id = bv_mrid });
        }
        // Sort BaseVoltages by nominalVoltage ascending (matches PyPowSyBl output order).
        std.mem.sort(iidm.BaseVoltage, bv_list.items, {}, struct {
            fn lessThan(_: void, a: iidm.BaseVoltage, b: iidm.BaseVoltage) bool {
                return a.nominal_voltageoltage < b.nominal_voltageoltage;
            }
        }.lessThan);

        // Emit one combined entry for all three global extensions.
        try network.extensions.append(gpa, .{
            .id = network.id,
            .cgmes_metadata_models = if (metadata_models.items.len > 0) .{ .models = metadata_models } else null,
            .base_voltage_mapping = if (bv_list.items.len > 0) .{ .base_voltages = bv_list } else null,
            .cim_characteristics = .{ .topology_kind = "NODE_BREAKER", .cim_version = 100 },
        });
        metadata_models = .empty; // ownership transferred
        bv_list = .empty; // ownership transferred

        if (fm_count > 0) try network.extension_versions.append(gpa, .{ .extension_name = "cgmesMetadataModels" });
        if (base_voltages.len > 0) try network.extension_versions.append(gpa, .{ .extension_name = "baseVoltageMapping" });
        try network.extension_versions.append(gpa, .{ .extension_name = "cimCharacteristics" });
    }

    assert(network.substations.items.len > 0);
    return network;
}

test "parse_iso8601_seconds: returns null for short strings" {
    try std.testing.expect(parse_iso8601_seconds("") == null);
    try std.testing.expect(parse_iso8601_seconds("2026-01-01") == null);
}

test "parse_iso8601_seconds: returns null for invalid month or day" {
    try std.testing.expect(parse_iso8601_seconds("2026-00-01T00:00:00Z") == null);
    try std.testing.expect(parse_iso8601_seconds("2026-13-01T00:00:00Z") == null);
}

test "parse_iso8601_seconds: same-day delta gives correct second count" {
    // 09:00 − 01:00 = 8 h = 28800 s on the same calendar day.
    const t09 = parse_iso8601_seconds("2026-01-01T09:00:00Z") orelse return error.TestFailed;
    const t01 = parse_iso8601_seconds("2026-01-01T01:00:00Z") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 28800), t09 - t01);
}

test "parse_iso8601_seconds: midnight rollover gives correct delta" {
    // 00:00 on Jan 2 − 23:00 on Jan 1 = 1 h = 3600 s.
    const t_jan2 = parse_iso8601_seconds("2026-01-02T00:00:00Z") orelse return error.TestFailed;
    const t_jan1 = parse_iso8601_seconds("2026-01-01T23:00:00Z") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 3600), t_jan2 - t_jan1);
}
