const std = @import("std");
const iidm = @import("../iidm/model.zig");
const EQ = @import("../cgmes/eq.zig").EQ;
const cross_ref = @import("../topology/cross_ref.zig");
const utils = @import("../cgmes/ids.zig");
const topology = @import("../topology/resolve.zig");
const tag_index = @import("../cgmes/tag_index.zig");
const substation_conv = @import("substation.zig");
const voltage_level_conv = @import("voltage_level.zig");
const equipment_conv = @import("equipment.zig");
const transformer_conv = @import("transformer.zig");
const line_conv = @import("line.zig");
const bus_conv = @import("bus.zig");
const placement_conv = @import("placement.zig");
const SSH = @import("../cgmes/ssh.zig").SSH;
const TP = @import("../cgmes/tp.zig").TP;
const parse = @import("../cgmes/parse.zig");
const populate_internal_connections = @import("internal_connections.zig").populate_internal_connections;

const assert = std.debug.assert;

const strip_hash = utils.strip_hash;
const strip_underscore = utils.strip_underscore;

/// Decode XML character entities into a newly-allocated string.
/// Handles &lt; &gt; &amp; &quot; &apos; only (CGMES descriptions use these).
/// Every entity decodes to a single byte and every other byte is copied as-is,
/// so the output never exceeds `s.len`: one reservation up front makes every
/// append infallible (appendAssumeCapacity).
fn decode_xml_entities(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    try result.ensureTotalCapacity(gpa, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '&') {
            result.appendAssumeCapacity(s[i]);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, s[i..], "&lt;")) {
            result.appendAssumeCapacity('<');
            i += 4;
        } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
            result.appendAssumeCapacity('>');
            i += 4;
        } else if (std.mem.startsWith(u8, s[i..], "&amp;")) {
            result.appendAssumeCapacity('&');
            i += 5;
        } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
            result.appendAssumeCapacity('"');
            i += 6;
        } else if (std.mem.startsWith(u8, s[i..], "&apos;")) {
            result.appendAssumeCapacity('\'');
            i += 6;
        } else {
            result.appendAssumeCapacity(s[i]);
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

/// Map a CGMES profile URL to its IIDM subset identifier.
fn profile_to_subset(profile_url: []const u8) []const u8 {
    assert(profile_url.len > 0);
    if (std.mem.indexOf(u8, profile_url, "CoreEquipment") != null) return "EQUIPMENT";
    if (std.mem.indexOf(u8, profile_url, "SteadyStateHypothesis") != null) return "STEADY_STATE_HYPOTHESIS";
    return "UNKNOWN";
}

fn extension_version(extension_name: []const u8) []const u8 {
    if (std.mem.eql(u8, extension_name, "activePowerControl")) return "1.2";
    return "1.0";
}

/// Append one MetadataModel entry derived from a FullModel CimObjectView.
fn append_metadata_model(
    gpa: std.mem.Allocator,
    view: tag_index.CimObjectView,
    metadata_models: *std.ArrayListUnmanaged(iidm.MetadataModel),
) !void {
    assert(view.id.len > 0);
    assert(view.closing_tag_idx > view.object_tag_idx);
    const mas = try view.getProperty("Model.modelingAuthoritySet") orelse "";
    const raw_desc = try view.getProperty("Model.description") orelse "";
    const desc = try decode_xml_entities(gpa, raw_desc);
    const version = parse.int_or(u32, try view.getProperty("Model.version"), 0);

    var profiles: std.ArrayListUnmanaged(iidm.ModelProfile) = .empty;
    var dependent_on: std.ArrayListUnmanaged(iidm.DependentOnModel) = .empty;
    var subset: []const u8 = "UNKNOWN";
    for (view.boundaries[view.object_tag_idx + 1 .. view.closing_tag_idx], view.object_tag_idx + 1..) |tag, ti| {
        if (view.xml[tag.start + 1] == '/') continue; // skip closing tags
        const is_self_closing = view.xml[tag.end - 1] == '/';
        const tag_type = tag_index.extract_tag_type(view.xml, tag.start) catch continue;
        if (std.mem.eql(u8, tag_type, "Model.profile") and !is_self_closing) {
            const content = view.xml[tag.end + 1 .. view.boundaries[ti + 1].start];
            try profiles.append(gpa, .{ .content = content });
            const s = profile_to_subset(content);
            if (!std.mem.eql(u8, s, "UNKNOWN")) subset = s;
        } else if (std.mem.eql(u8, tag_type, "Model.DependentOn")) {
            const ref = tag_index.extract_rdf_resource(view.xml, tag.start) catch continue;
            if (ref) |r| try dependent_on.append(gpa, .{ .content = r });
        }
    }
    try metadata_models.append(gpa, .{
        .subset = subset,
        .modeling_authority_set = mas,
        .id = view.id,
        .version = version,
        .description = desc,
        .profiles = profiles,
        .dependent_on_models = dependent_on,
    });
}

/// Convert ControlArea + TieFlow CIM objects to IIDM Area objects.
/// Each ControlArea becomes one Area. Each TieFlow becomes one AreaBoundary:
///   boundary.id   = ConductingEquipment mRID of the TieFlow.Terminal
///   boundary.side = sequenceNumber of the TieFlow.Terminal (1→"ONE", 2→"TWO")
///   boundary.ac   = true (always, as all equipment is AC in EQ profiles)
fn convert_areas(gpa: std.mem.Allocator, model: *const EQ, ssh_opt: ?SSH, network: *iidm.Network) !void {
    const control_areas = model.get_objects_by_type("ControlArea");
    assert(network.areas.items.len == 0);
    if (control_areas.len == 0) return;

    try network.areas.ensureTotalCapacity(gpa, control_areas.len);

    // The TieFlow set is the same for every ControlArea; fetch it once rather
    // than re-looking-it-up per area.
    const tie_flows = model.get_objects_by_type("TieFlow");

    for (control_areas) |control_area| {
        const control_area_view = model.view(control_area);
        const control_area_mrid = try control_area_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(control_area.id);
        const control_area_name = try control_area_view.getProperty("IdentifiedObject.name") orelse control_area_mrid;

        // ControlArea.type is a rdf:resource; extract the fragment after '#'.
        const area_type: []const u8 = blk: {
            const raw = try control_area_view.getReference("ControlArea.type") orelse break :blk "ControlAreaTypeKind.Interchange";
            const hash = std.mem.lastIndexOfScalar(u8, raw, '#') orelse break :blk raw;
            break :blk raw[hash + 1 ..];
        };

        // Collect all TieFlow objects that reference this ControlArea.
        var boundaries: std.ArrayListUnmanaged(iidm.AreaBoundary) = .empty;
        errdefer boundaries.deinit(gpa);

        for (tie_flows) |tie_flow| {
            const tie_flow_view = model.view(tie_flow);
            const control_area_ref = try tie_flow_view.getReference("TieFlow.ControlArea") orelse continue;
            const control_area_id = strip_hash(control_area_ref);
            if (!std.mem.eql(u8, control_area_id, control_area.id) and !std.mem.eql(u8, control_area_id, control_area_mrid)) continue;

            const term_ref = try tie_flow_view.getReference("TieFlow.Terminal") orelse continue;
            const term_id = strip_hash(term_ref);
            const term_obj = model.getObjectById(term_id) orelse continue;

            const equipment_ref = try term_obj.getReference("Terminal.ConductingEquipment") orelse continue;
            const equipment_id = strip_hash(equipment_ref);
            const equipment = model.getObjectById(equipment_id) orelse continue;
            const eq_mrid = try equipment.getProperty("IdentifiedObject.mRID") orelse strip_underscore(equipment_id);

            const seq = parse.int_or(u32, try term_obj.getProperty("ACDCTerminal.sequenceNumber"), 1);
            const side: []const u8 = if (seq == 1) "ONE" else "TWO";

            try boundaries.append(gpa, .{ .id = eq_mrid, .side = side });
        }

        const interchange_target: ?f64 = if (ssh_opt) |ssh| blk: {
            const v = try ssh.getProperty(control_area_mrid, "ControlArea.netInterchange") orelse break :blk null;
            break :blk parse.float_opt(v);
        } else null;

        network.areas.appendAssumeCapacity(.{
            .id = control_area_mrid,
            .name = control_area_name,
            .area_type = area_type,
            .interchange_target = interchange_target,
            .boundaries = boundaries,
        });
    }
}

/// Convert a EQ into an IIDM Network.
/// Caller owns the returned network and must call network.deinit(gpa).
/// Default JIIDM output is node-breaker (matches pypowsybl). When `bus_branch`
/// is true, TP TopologicalNodes drive equipment placement onto buses and
/// voltageLevels are emitted in bus-breaker shape. `bus_branch` requires
/// `tp_opt` to be non-null (CLI enforces this).
pub fn convert(
    gpa: std.mem.Allocator,
    model: *const EQ,
    tp_opt: ?TP,
    ssh_opt: ?SSH,
    bus_branch: bool,
) !iidm.Network {
    assert(model.get_objects_by_type("Substation").len > 0);
    assert(!bus_branch or tp_opt != null);

    const boundary_ids: std.StringHashMapUnmanaged(void) = .empty;
    var index = try cross_ref.CrossRef.build(gpa, model, boundary_ids);
    defer index.deinit(gpa);

    var topology_data = try topology.Topology.build_with_options(gpa, model, &index, .{
        .include_reachable_busbar_section = !bus_branch,
    });
    defer topology_data.deinit(gpa);

    try cross_ref.build_voltage_limits(gpa, model, &index, &topology_data);

    // ---- FullModel metadata: id, caseDate, forecastDistance ----
    const full_models = model.get_objects_by_type("FullModel");
    const eq_full_model: ?tag_index.CimObjectView = if (full_models.len > 0) model.view(full_models[0]) else null;
    const network_id = if (eq_full_model) |full_model_view| full_model_view.id else "unknown";
    const scenario_time: ?[]const u8 = blk: {
        if (ssh_opt) |ssh| {
            if (try ssh.getFullModelProperty("Model.scenarioTime")) |st| break :blk st;
        }
        break :blk if (eq_full_model) |full_model_view|
            try full_model_view.getProperty("Model.scenarioTime")
        else
            null;
    };
    const created_time: ?[]const u8 = blk: {
        if (ssh_opt) |ssh| {
            if (try ssh.getFullModelProperty("Model.created")) |ct| break :blk ct;
        }
        break :blk if (eq_full_model) |full_model_view|
            try full_model_view.getProperty("Model.created")
        else
            null;
    };
    const forecast_distance: u32 = blk: {
        const st = scenario_time orelse break :blk 0;
        const ct = created_time orelse break :blk 0;
        const st_secs = parse_iso8601_seconds(std.mem.trim(u8, st, " \t\r\n")) orelse break :blk 0;
        const ct_secs = parse_iso8601_seconds(std.mem.trim(u8, ct, " \t\r\n")) orelse break :blk 0;
        const diff_secs = st_secs - ct_secs;
        if (diff_secs <= 0) break :blk 0;
        const minutes = @divTrunc(diff_secs, 60);
        if (minutes > std.math.maxInt(u32)) return error.ForecastDistanceTooLarge;
        break :blk @intCast(minutes);
    };

    var network = iidm.Network{
        .id = network_id,
        .case_date = scenario_time,
        .forecast_distance = forecast_distance,
        .minimum_validation_level = if (ssh_opt != null) "STEADY_STATE_HYPOTHESIS" else "EQUIPMENT",
        .substations = .empty,
        .lines = .empty,
        .hvdc_lines = .empty,
        .extensions = .empty,
    };
    errdefer network.deinit(gpa);

    var sub_id_map: std.StringHashMapUnmanaged(substation_conv.SubstationIndex) = .empty;
    defer sub_id_map.deinit(gpa);
    try substation_conv.convert_substations(gpa, model, &topology_data, &network, &sub_id_map);

    try voltage_level_conv.convert_voltage_levels(gpa, model, &index, &topology_data, &network, &sub_id_map);

    var substation_map: std.StringHashMapUnmanaged(*iidm.Substation) = .empty;
    defer substation_map.deinit(gpa);
    var voltage_level_map = try voltage_level_conv.build_voltage_level_map(gpa, model, &topology_data, &network, &sub_id_map, &substation_map);
    defer voltage_level_map.deinit(gpa);

    var tap_changer_info_map: transformer_conv.TapChangerInfoMap = .empty;
    defer transformer_conv.deinit_tap_changer_info_map(gpa, &tap_changer_info_map);
    const tap_changer_info_target: ?*transformer_conv.TapChangerInfoMap = if (bus_branch) null else &tap_changer_info_map;

    // Branch on output shape. Bus-branch derives placement from TP's
    // TopologicalNodes; node-breaker builds a NodeMap from EQ CNs + switches.
    // Node-breaker is the default even when TP is loaded (matches pypowsybl);
    // bus-branch is an opt-in alternative output mode (CLI flag).
    if (bus_branch) {
        const tp = tp_opt.?; // guaranteed by assert above
        var bus_map = try bus_conv.convert_buses(gpa, tp, &voltage_level_map);
        defer bus_map.deinit(gpa);

        const placer_uncached = placement_conv.TerminalPlacer{
            .mode = .{ .bus_branch = .{ .tp = tp, .bus_map = &bus_map } },
            .index = &index,
            .topology = &topology_data,
            .voltage_level_map = &voltage_level_map,
        };

        var placement_cache = try equipment_conv.pre_allocate_equipment(gpa, model, placer_uncached);
        defer placement_cache.deinit(gpa);
        var placer = placer_uncached;
        placer.placement_cache = &placement_cache;

        try equipment_conv.convert_loads(gpa, model, placer, ssh_opt);
        try equipment_conv.convert_shunts(gpa, model, placer, ssh_opt);
        try equipment_conv.convert_static_var_compensators(model, placer, ssh_opt);
        try equipment_conv.convert_generators(gpa, model, placer, ssh_opt);
        try transformer_conv.convert_transformers(gpa, model, &substation_map, placer, ssh_opt, tap_changer_info_target);
        try line_conv.convert_lines(gpa, model, &network, placer, ssh_opt);
    } else {
        var voltage_level_id_set: std.StringHashMapUnmanaged(void) = .empty;
        defer voltage_level_id_set.deinit(gpa);
        try voltage_level_id_set.ensureTotalCapacity(gpa, @intCast(voltage_level_map.count()));
        var voltage_level_id_it = voltage_level_map.keyIterator();
        while (voltage_level_id_it.next()) |k| voltage_level_id_set.putAssumeCapacity(k.*, {});

        var nm_result = try topology.build_node_map(gpa, model, &index, &topology_data, &voltage_level_id_set, ssh_opt);
        defer nm_result.deinit(gpa);
        try populate_internal_connections(gpa, model, &index, &topology_data, &voltage_level_map, ssh_opt, &nm_result);
        const node_map = &nm_result.node_map;

        const placer_uncached = placement_conv.TerminalPlacer{
            .mode = .{ .node_breaker = node_map },
            .index = &index,
            .topology = &topology_data,
            .voltage_level_map = &voltage_level_map,
        };

        var placement_cache = try equipment_conv.pre_allocate_equipment(gpa, model, placer_uncached);
        defer placement_cache.deinit(gpa);
        var placer = placer_uncached;
        placer.placement_cache = &placement_cache;

        try equipment_conv.convert_busbar_sections(gpa, model, placer);
        try equipment_conv.convert_switches(gpa, model, placer, ssh_opt);
        try equipment_conv.convert_fictitious_switches(gpa, model, placer, &nm_result.conn_node_has_switch, &nm_result.conn_node_other_count, ssh_opt);
        try equipment_conv.convert_loads(gpa, model, placer, ssh_opt);
        try equipment_conv.convert_shunts(gpa, model, placer, ssh_opt);
        try equipment_conv.convert_static_var_compensators(model, placer, ssh_opt);
        try equipment_conv.convert_generators(gpa, model, placer, ssh_opt);
        try transformer_conv.convert_transformers(gpa, model, &substation_map, placer, ssh_opt, tap_changer_info_target);
        try line_conv.convert_lines(gpa, model, &network, placer, ssh_opt);
    }
    try convert_areas(gpa, model, ssh_opt, &network);

    // -------------------------------------------------------------------------
    // Emit top-level extensions.
    // Order matches PyPowSyBl: cgmesTapChangers, detail, coordinatedReactiveControl,
    // cgmesMetadataModels, baseVoltageMapping, cimCharacteristics.
    //
    // -------------------------------------------------------------------------

    // cgmesTapChangers: one extension per transformer that has a RatioTapChanger
    // or PhaseTapChangerTabular. The extension ID is the PowerTransformer mRID.
    // step = TapChanger.normalStep.
    // Emitted for node-breaker JIIDM only; bus-branch output skips it.
    if (!bus_branch and tap_changer_info_map.count() > 0) {
        try network.extensions.ensureTotalCapacity(gpa, network.extensions.items.len + tap_changer_info_map.count());
        var it = tap_changer_info_map.iterator();
        while (it.next()) |entry| {
            network.extensions.appendAssumeCapacity(.{
                .id = entry.key_ptr.*,
                .cgmes_tap_changers = .{ .tap_changers = entry.value_ptr.* },
            });
            entry.value_ptr.* = .empty; // ownership transferred
        }
        try network.extension_versions.append(gpa, .{ .extension_name = "cgmesTapChangers", .version = extension_version("cgmesTapChangers") });
    }

    // detail extension: every load gets fixedActivePower/fixedReactivePower from EQ
    // (EnergyConsumer.pfixed/qfixed), and variableActivePower/variableReactivePower
    // computed as total (SSH p0/q0) minus fixed.
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
                            .fixed_active_power = load.fixed_active_power,
                            .fixed_reactive_power = load.fixed_reactive_power,
                            .variable_active_power = (load.p0 orelse load.fixed_active_power) - load.fixed_active_power,
                            .variable_reactive_power = (load.q0 orelse load.fixed_reactive_power) - load.fixed_reactive_power,
                        },
                    });
                }
            }
        }
        if (load_count > 0) {
            try network.extension_versions.append(gpa, .{ .extension_name = "detail", .version = extension_version("detail") });
        }
    }

    // Generator extensions: coordinatedReactiveControl (qPercent) and activePowerControl
    // (normalPF). Both are keyed by generator mRID and must be merged into a single Extension
    // entry per generator — pypowsybl emits one combined entry, not two separate ones.
    {
        var has_crc = false;
        var has_apc = false;
        var gen_ext_count: usize = 0;
        for (network.substations.items) |substation| {
            for (substation.voltage_levels.items) |voltage_level| {
                for (voltage_level.generators.items) |gen| {
                    if (gen.q_percent != null or gen.participation_factor != null) {
                        gen_ext_count += 1;
                        if (gen.q_percent != null) has_crc = true;
                        if (gen.participation_factor != null) has_apc = true;
                    }
                }
            }
        }
        if (gen_ext_count > 0) {
            try network.extensions.ensureTotalCapacity(gpa, network.extensions.items.len + gen_ext_count);
            for (network.substations.items) |substation| {
                for (substation.voltage_levels.items) |voltage_level| {
                    for (voltage_level.generators.items) |gen| {
                        if (gen.q_percent == null and gen.participation_factor == null) continue;
                        const crc: ?iidm.CoordinatedReactiveControl = if (gen.q_percent) |qp|
                            .{ .q_percent = qp }
                        else
                            null;
                        const apc: ?iidm.ActivePowerControl = if (gen.participation_factor) |pf|
                            .{ .participate = true, .participation_factor = pf }
                        else
                            null;
                        network.extensions.appendAssumeCapacity(.{
                            .id = gen.id,
                            .coordinated_reactive_control = crc,
                            .active_power_control = apc,
                        });
                    }
                }
            }
            if (has_crc) try network.extension_versions.append(gpa, .{ .extension_name = "coordinatedReactiveControl", .version = extension_version("coordinatedReactiveControl") });
            if (has_apc) try network.extension_versions.append(gpa, .{ .extension_name = "activePowerControl", .version = extension_version("activePowerControl") });
        }
    }

    // cgmesMetadataModels + baseVoltageMapping + cimCharacteristics:
    // PyPowSyBl combines all three into a single extension entry keyed by network ID.
    // Order of fields in the entry: cgmesMetadataModels, baseVoltageMapping, cimCharacteristics.
    {
        // --- cgmesMetadataModels ---
        // Order: dependencies (EQBD) first, then EQ, then SSH (which depends on EQ).
        // Subset derived from profile URL via profile_to_subset().
        var metadata_models: std.ArrayListUnmanaged(iidm.MetadataModel) = .empty;
        errdefer {
            for (metadata_models.items) |*m| m.deinit(gpa);
            metadata_models.deinit(gpa);
        }

        const full_model_count = full_models.len;
        const ssh_full_model_view: ?tag_index.CimObjectView = if (ssh_opt) |ssh| try ssh.getFullModelView() else null;
        const expected_model_count = full_model_count + @as(usize, if (ssh_full_model_view != null) 1 else 0);

        // full_models[0] is the EQ FullModel; full_models[1..] are dependency
        // FullModels (EQBD). Append dependencies first, then the EQ itself.
        if (full_model_count > 0) {
            for (full_models[1..]) |full_model| {
                try append_metadata_model(gpa, model.view(full_model), &metadata_models);
            }
            try append_metadata_model(gpa, model.view(full_models[0]), &metadata_models);
        }
        if (ssh_full_model_view) |view| {
            try append_metadata_model(gpa, view, &metadata_models);
        }
        assert(metadata_models.items.len == expected_model_count);

        // --- baseVoltageMapping ---
        // EQ FullModel is always first in XML order; EQBD FullModel (if present) comes after.
        const eq_boundary: u32 = if (full_models.len >= 2) blk: {
            const full_model_view = model.view(full_models[1]);
            break :blk full_model_view.boundaries[full_model_view.object_tag_idx].start;
        } else std.math.maxInt(u32);

        const base_voltages = model.get_objects_by_type("BaseVoltage");
        var base_voltage_list: std.ArrayListUnmanaged(iidm.BaseVoltage) = .empty;
        errdefer base_voltage_list.deinit(gpa);
        try base_voltage_list.ensureTotalCapacity(gpa, base_voltages.len);
        for (base_voltages) |base_voltage| {
            const base_voltage_view = model.view(base_voltage);
            const base_voltage_mrid = try base_voltage_view.getProperty("IdentifiedObject.mRID") orelse strip_underscore(base_voltage.id);
            const nom_v_str = try base_voltage_view.getProperty("BaseVoltage.nominalVoltage") orelse continue;
            const nom_v = parse.float_opt(nom_v_str) orelse continue;
            const xml_pos = base_voltage_view.boundaries[base_voltage_view.object_tag_idx].start;
            const source: []const u8 = if (xml_pos < eq_boundary) "IGM" else "BOUNDARY";
            base_voltage_list.appendAssumeCapacity(.{ .nominal_voltageoltage = nom_v, .source = source, .id = base_voltage_mrid });
        }
        // Sort BaseVoltages by nominalVoltage ascending (matches PyPowSyBl output order).
        std.mem.sort(iidm.BaseVoltage, base_voltage_list.items, {}, struct {
            fn lessThan(_: void, a: iidm.BaseVoltage, b: iidm.BaseVoltage) bool {
                return a.nominal_voltageoltage < b.nominal_voltageoltage;
            }
        }.lessThan);

        // Emit one combined entry for all three global extensions.
        try network.extensions.append(gpa, .{
            .id = network.id,
            .cgmes_metadata_models = if (metadata_models.items.len > 0) .{ .models = metadata_models } else null,
            .base_voltage_mapping = if (base_voltage_list.items.len > 0) .{ .base_voltages = base_voltage_list } else null,
            .cim_characteristics = .{
                // cimCharacteristics.topologyKind reflects the source CGMES shape,
                // not the IIDM output shape. EQ with ConnectivityNodes = NODE_BREAKER
                // even when TP is provided; matches pypowsybl.
                .topology_kind = "NODE_BREAKER",
                .cim_version = 100,
            },
        });
        metadata_models = .empty; // ownership transferred
        base_voltage_list = .empty; // ownership transferred

        if (expected_model_count > 0) try network.extension_versions.append(gpa, .{ .extension_name = "cgmesMetadataModels", .version = extension_version("cgmesMetadataModels") });
        if (base_voltages.len > 0) try network.extension_versions.append(gpa, .{ .extension_name = "baseVoltageMapping", .version = extension_version("baseVoltageMapping") });
        try network.extension_versions.append(gpa, .{ .extension_name = "cimCharacteristics", .version = extension_version("cimCharacteristics") });
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

// ── profile_to_subset ─────────────────────────────────────────────────────────

test "profile_to_subset: CoreEquipment URL → EQUIPMENT" {
    try std.testing.expectEqualStrings(
        "EQUIPMENT",
        profile_to_subset("http://iec.ch/TC57/ns/CIM/CoreEquipment-EU/3.0"),
    );
}

test "profile_to_subset: SteadyStateHypothesis URL → STEADY_STATE_HYPOTHESIS" {
    try std.testing.expectEqualStrings(
        "STEADY_STATE_HYPOTHESIS",
        profile_to_subset("http://iec.ch/TC57/ns/CIM/SteadyStateHypothesis-EU/3.0"),
    );
}

test "profile_to_subset: unknown URL → UNKNOWN" {
    try std.testing.expectEqualStrings(
        "UNKNOWN",
        profile_to_subset("http://example.com/SomeOtherProfile/1.0"),
    );
}

// ── extension_version ─────────────────────────────────────────────────────────

test "extension_version: activePowerControl → 1.2" {
    try std.testing.expectEqualStrings("1.2", extension_version("activePowerControl"));
}

test "extension_version: cgmesMetadataModels → 1.0" {
    try std.testing.expectEqualStrings("1.0", extension_version("cgmesMetadataModels"));
}

test "extension_version: unknown name → 1.0" {
    try std.testing.expectEqualStrings("1.0", extension_version("somethingElse"));
}

// ── append_metadata_model ─────────────────────────────────────────────────────

test "append_metadata_model: reads id/version/subset/profiles/DependentOn" {
    const gpa = std.testing.allocator;
    const xml =
        \\<rdf:RDF>
        \\  <md:FullModel rdf:about="urn:uuid:test-fm-1">
        \\    <md:Model.modelingAuthoritySet>http://example.com/mas</md:Model.modelingAuthoritySet>
        \\    <md:Model.version>003</md:Model.version>
        \\    <md:Model.profile>http://iec.ch/TC57/ns/CIM/SteadyStateHypothesis-EU/3.0</md:Model.profile>
        \\    <md:Model.DependentOn rdf:resource="urn:uuid:dep-1"/>
        \\  </md:FullModel>
        \\</rdf:RDF>
    ;
    var boundaries = try tag_index.find_tag_boundaries(gpa, xml);
    defer boundaries.deinit(gpa);

    // Find FullModel tag and its closing tag.
    var fm_tag_idx: u32 = 0;
    var fm_closing_idx: u32 = 0;
    for (boundaries.items, 0..) |tag, i| {
        const type_name = tag_index.extract_tag_type(xml, tag.start) catch continue;
        if (!std.mem.eql(u8, type_name, "FullModel")) continue;
        fm_tag_idx = @intCast(i);
        fm_closing_idx = try tag_index.find_closing_tag(xml, boundaries.items, fm_tag_idx);
        break;
    }

    const view = tag_index.CimObjectView{
        .xml = xml,
        .boundaries = boundaries.items,
        .object_tag_idx = fm_tag_idx,
        .closing_tag_idx = fm_closing_idx,
        .id = "urn:uuid:test-fm-1",
        .type_name = "FullModel",
    };

    var metadata_models: std.ArrayListUnmanaged(iidm.MetadataModel) = .empty;
    defer {
        for (metadata_models.items) |*m| m.deinit(gpa);
        metadata_models.deinit(gpa);
    }
    try append_metadata_model(gpa, view, &metadata_models);

    try std.testing.expectEqual(@as(usize, 1), metadata_models.items.len);
    const m = metadata_models.items[0];
    try std.testing.expectEqualStrings("urn:uuid:test-fm-1", m.id);
    try std.testing.expectEqualStrings("STEADY_STATE_HYPOTHESIS", m.subset);
    try std.testing.expectEqual(@as(u32, 3), m.version);
    try std.testing.expectEqualStrings("http://example.com/mas", m.modeling_authority_set);
    try std.testing.expectEqual(@as(usize, 1), m.profiles.items.len);
    try std.testing.expectEqualStrings(
        "http://iec.ch/TC57/ns/CIM/SteadyStateHypothesis-EU/3.0",
        m.profiles.items[0].content,
    );
    try std.testing.expectEqual(@as(usize, 1), m.dependent_on_models.items.len);
    try std.testing.expectEqualStrings("urn:uuid:dep-1", m.dependent_on_models.items[0].content);
}
