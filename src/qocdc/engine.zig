//! The fused grid-model validation pass.
//!
//! One outer sweep visits every applicable object. Rules share one child walk
//! through value slots. Type filters cost one `type_id` lookup plus bit tests
//! per group (not per object), and no rule makes its own sweep over the model.
//!
//! Phase H resolves the header once. Later phases (traits, harvested
//! columns, relational passes) extend this file.

const std = @import("std");
const assert = std.debug.assert;

const cim = @import("../cim/cim.zig");
const rules = @import("rules.zig");
const report_mod = @import("report.zig");

const Report = report_mod.Report;
const Rule = rules.Rule;
const RuleMask = rules.RuleMask;

/// All grid-model rules, header classification included.
pub fn validate_model(
    report: *Report,
    gpa: std.mem.Allocator,
    model: *const cim.CimDocument,
) error{OutOfMemory}!void {
    return validate_model_rules(report, gpa, model, RuleMask.initFull());
}

/// Grid-model rules restricted to `requested`. Dependencies of a requested
/// rule (header classification, harvested columns) are enabled internally,
/// but diagnostics are only ever emitted for rules in the request -- the
/// isolation the focused tests rely on.
pub fn validate_model_rules(
    report: *Report,
    gpa: std.mem.Allocator,
    model: *const cim.CimDocument,
    requested: RuleMask,
) error{OutOfMemory}!void {
    var slots: rules.Slots = @splat(.{});
    var ctx: rules.Ctx = .{
        .gpa = gpa,
        .report = report,
        .model = model,
        .slots = &slots,
    };

    // Phase H: resolve the header once, only when a requested rule needs it.
    var resolved: ?Resolved = null;
    if (header_needed(requested)) {
        resolved = try classify_header(gpa, model);
        if (resolved == null and requested.contains(.TooManyProfileParts)) {
            try report.add(gpa, .{
                .rule = .TooManyProfileParts,
                .offset = report_mod.no_offset,
                .object_id = "",
                .detail = "",
            });
        }
        if (resolved) |header| ctx.version = header.header.version;
    }

    // Which table entries can run at all this run: requested and gate-open.
    // An unresolved header opens only `.always` gates.
    var enabled: u64 = 0;
    inline for (rules.object_rules, 0..) |entry, i| {
        if (requested.contains(entry.rule) and gate_active(entry.gate, resolved)) {
            enabled |= 1 << i;
        }
    }
    // Harvesters active this run: the dependency closure of the request. A
    // rule verdict may live entirely in Phase B (the count rules), so an
    // empty `enabled` alone does not end the run.
    var harvest_enabled: u8 = 0;
    inline for (rules.harvesters, 0..) |harvester, i| {
        inline for (harvester.rules) |rule| {
            if (requested.contains(rule)) harvest_enabled |= 1 << i;
        }
    }
    if (enabled == 0 and harvest_enabled == 0) return;

    // Phase 0: traits column and reference resolution, only when an enabled
    // entry resolves references. One trait computation per type name,
    // @memset over the type's contiguous index range.
    var traits: ?[]rules.TargetTraits = null;
    defer if (traits) |column| gpa.free(column);
    var ref_index: ?cim.ReferenceIndex = null;
    defer if (ref_index) |*index| index.deinit();
    if (resolution_needed(enabled) or harvest_enabled != 0) {
        const column = try gpa.alloc(rules.TargetTraits, model.object_count());
        traits = column;
        var trait_groups = model.type_groups();
        while (trait_groups.next()) |group| {
            const group_traits = rules.compute_traits(group.type_name);
            @memset(column[group.start .. group.start + group.objects.len], group_traits);
        }
        ref_index = try cim.ReferenceIndex.init(gpa, model);
        ctx.traits = column;
        ctx.ref_index = &ref_index.?;
    }

    // Harvest sinks for the relational rules.
    var columns: ?rules.Columns = null;
    defer if (columns) |*sinks| sinks.deinit(gpa);
    if (relational_needed(requested)) {
        columns = try rules.Columns.init(gpa, model.object_count());
        ctx.columns = &columns.?;
    }

    // Phase A: the fused sweep.
    var groups = model.type_groups();
    while (groups.next()) |group| {
        ctx.group_type_name = group.type_name;
        ctx.group_tid = cim.cim_types.type_id(group.type_name);
        ctx.group_v3_units = null;

        // Active entries and the union of their needed (name, channels)
        // pairs, computed once per group.
        var active: u64 = 0;
        var needed: [rules.prop_count]NeededName = undefined;
        var needed_len: u32 = 0;
        inline for (rules.object_rules, 0..) |entry, i| {
            if (enabled & (1 << i) != 0 and
                rules.filter_matches(entry.filter, ctx.group_tid, group.type_name))
            {
                const group_ok = if (entry.group_gate) |group_gate| group_gate(&ctx) else true;
                if (group_ok) {
                    active |= 1 << i;
                    for (entry.needs) |need| add_need(&needed, &needed_len, need);
                }
            }
        }
        var active_harvest: u8 = 0;
        inline for (rules.harvesters, 0..) |harvester, i| {
            if (harvest_enabled & (1 << i) != 0 and
                rules.filter_matches(harvester.filter, ctx.group_tid, group.type_name))
            {
                active_harvest |= 1 << i;
                for (harvester.needs) |need| add_need(&needed, &needed_len, need);
            }
        }
        if (active == 0 and active_harvest == 0) continue;

        for (group.objects, 0..) |obj, offset_in_group| {
            ctx.object_index = group.start + @as(u32, @intCast(offset_in_group));
            fill_slots(&slots, needed[0..needed_len], obj);
            inline for (rules.object_rules, 0..) |entry, i| {
                if (active & (@as(u64, 1) << i) != 0) try entry.check(&ctx, obj);
            }
            inline for (rules.harvesters, 0..) |harvester, i| {
                if (active_harvest & (@as(u8, 1) << i) != 0) try harvester.harvest(&ctx, obj);
            }
        }
    }

    // Phase B: relational verdicts over the harvested columns. Pure array
    // work; the XML is never touched again.
    if (columns) |*sinks| {
        try run_phase_b(report, gpa, model, requested, ctx.traits.?, sinks);
    }
}

/// Sentinels shared with the harvest rows.
const none_index = rules.none_index;

fn run_phase_b(
    report: *Report,
    gpa: std.mem.Allocator,
    model: *const cim.CimDocument,
    requested: RuleMask,
    traits: []const rules.TargetTraits,
    columns: *rules.Columns,
) error{OutOfMemory}!void {
    const emit = struct {
        fn at(
            rep: *Report,
            allocator: std.mem.Allocator,
            document: *const cim.CimDocument,
            rule: Rule,
            object_index: u32,
        ) error{OutOfMemory}!void {
            const obj = document.object_at(object_index);
            try rep.add(allocator, .{
                .rule = rule,
                .offset = obj.xml_offset(),
                .object_id = obj.id(),
                .detail = "",
            });
        }
    }.at;

    // B1: MutualCoupling. First mark every independently resolvable end's
    // line as coupled -- TerminalSeqNum's gate counts a line as coupled even
    // when the MutualCoupling fails another MCFirstSecond condition -- then
    // evaluate the pair.
    for (columns.mutual_couplings.items) |row| {
        for ([_]u32{ row.first, row.second }) |end| {
            if (end == none_index) continue;
            if (!columns.terminal_exact_ce.isSet(end)) continue;
            columns.coupled.set(columns.terminal_equipment[end]);
        }
    }
    if (requested.contains(.MCFirstSecond)) {
        rows: for (columns.mutual_couplings.items) |row| {
            if (row.incomplete) {
                try emit(report, gpa, model, .MCFirstSecond, row.object_index);
                continue;
            }
            var lines: [2]u32 = undefined;
            for ([_]u32{ row.first, row.second }, 0..) |end, i| {
                if (!traits[end].terminal) {
                    try emit(report, gpa, model, .MCFirstSecond, row.object_index);
                    continue :rows;
                }
                const line = columns.terminal_equipment[end];
                if (line == none_index or !traits[line].ac_line_segment) {
                    try emit(report, gpa, model, .MCFirstSecond, row.object_index);
                    continue :rows;
                }
                lines[i] = line;
            }
            if (lines[0] == lines[1]) {
                try emit(report, gpa, model, .MCFirstSecond, row.object_index);
            }
        }
    }

    // B2: terminal cardinality over the dense count column.
    if (requested.contains(.TerminalCount1) or requested.contains(.TerminalCount2)) {
        const check_count1 = requested.contains(.TerminalCount1);
        const check_count2 = requested.contains(.TerminalCount2);
        for (traits, columns.terminal_count, 0..) |object_traits, count, index| {
            if (check_count1 and object_traits.count1 and count != 1) {
                try emit(report, gpa, model, .TerminalCount1, @intCast(index));
            }
            if (check_count2 and object_traits.count2 and count != 2) {
                try emit(report, gpa, model, .TerminalCount2, @intCast(index));
            }
        }
    }

    // B3: sequence numbers. Group terminal rows by equipment, then judge
    // each equipment's terminals.
    if (requested.contains(.TerminalSeqNum) or requested.contains(.TerminalSeqNumOrder)) {
        std.mem.sort(rules.TerminalRow, columns.terminals.items, {}, struct {
            fn less_than(_: void, a: rules.TerminalRow, b: rules.TerminalRow) bool {
                return a.equipment_index < b.equipment_index;
            }
        }.less_than);

        var ordered: std.ArrayList(u32) = .empty;
        defer ordered.deinit(gpa);

        const items = columns.terminals.items;
        var start: usize = 0;
        while (start < items.len) {
            const equipment = items[start].equipment_index;
            var end = start;
            while (end < items.len and items[end].equipment_index == equipment) end += 1;
            const run = items[start..end];
            start = end;

            // TerminalSeqNum: terminals of an EquivalentBranch, or of an
            // ACLineSegment with MutualCoupling, must carry a valid
            // sequenceNumber. Exact-Terminal edges only, as before.
            if (requested.contains(.TerminalSeqNum) and
                (traits[equipment].equivalent_branch or
                    (traits[equipment].ac_line_segment and columns.coupled.isSet(equipment))))
            {
                for (run) |row| {
                    if (!row.flags.exact_terminal or !row.flags.via_terminal_ce) continue;
                    if (row.seq == rules.seq_absent or row.seq == rules.seq_invalid) {
                        try emit(report, gpa, model, .TerminalSeqNum, row.terminal_index);
                    }
                }
            }

            // TerminalSeqNumOrder: where sequence numbers are provided for a
            // (DC)ConductingEquipment's terminals, they must be exactly 1..k.
            // An unparseable number violates on the terminal; a broken order
            // violates on the equipment.
            if (requested.contains(.TerminalSeqNumOrder) and traits[equipment].ce_or_dcce) {
                ordered.clearRetainingCapacity();
                var run_ok = true;
                for (run) |row| {
                    if (row.seq == rules.seq_absent) continue;
                    if (row.seq == rules.seq_invalid) {
                        try emit(report, gpa, model, .TerminalSeqNumOrder, row.terminal_index);
                        run_ok = false;
                        continue;
                    }
                    try ordered.append(gpa, row.seq);
                }
                if (run_ok) {
                    std.mem.sort(u32, ordered.items, {}, std.sort.asc(u32));
                    for (ordered.items, 1..) |sequence_number, expected| {
                        if (sequence_number != expected) {
                            try emit(report, gpa, model, .TerminalSeqNumOrder, equipment);
                            break;
                        }
                    }
                }
            }
        }
    }

    // B4: PowerTransformerEnd consistency.
    if (requested.contains(.PTTerminalConsistency)) {
        for (columns.pt_ends.items) |row| {
            const equipment = columns.terminal_equipment[row.terminal_index];
            if (equipment == none_index or
                equipment != row.transformer_index or
                !traits[equipment].power_transformer)
            {
                try emit(report, gpa, model, .PTTerminalConsistency, row.object_index);
            }
        }
    }

    // B5: Measurement.Terminal against Measurement.PowerSystemResource.
    if (requested.contains(.MeasTerminal)) {
        for (columns.measurements.items) |row| {
            if (!traits[row.terminal_index].terminal) {
                try emit(report, gpa, model, .MeasTerminal, row.object_index);
                continue;
            }
            const equipment = columns.terminal_equipment[row.terminal_index];
            if (equipment == none_index or
                !traits[equipment].equipment or
                equipment != row.psr_index)
            {
                try emit(report, gpa, model, .MeasTerminal, row.object_index);
            }
        }
    }

    // B6: ConductingEquipment BaseVoltage, resolved through the container
    // chain (VoltageLevel directly, Bay via its VoltageLevel).
    if (requested.contains(.CEBaseVoltage)) {
        for (columns.ce_bv.items) |row| {
            const container = row.container_index;
            const in_voltage_level_or_bay = container != none_index and
                (traits[container].voltage_level or traits[container].bay);

            if (row.base_voltage_id == null and !in_voltage_level_or_bay) {
                try emit(report, gpa, model, .CEBaseVoltage, row.object_index);
                continue;
            }
            if (row.base_voltage_id) |equipment_voltage| {
                const container_voltage = container_base_voltage(traits, columns, container) orelse continue;
                if (!std.mem.eql(u8, equipment_voltage, container_voltage)) {
                    try emit(report, gpa, model, .CEBaseVoltage, row.object_index);
                }
            }
        }
    }
}

/// The containing VoltageLevel's declared BaseVoltage id, following a Bay to
/// its parent VoltageLevel; null when there is no such container or it
/// declares none.
fn container_base_voltage(
    traits: []const rules.TargetTraits,
    columns: *const rules.Columns,
    container: u32,
) ?[]const u8 {
    if (container == none_index) return null;
    if (traits[container].voltage_level) {
        const row = find_vl_row(columns.vl_rows.items, container) orelse return null;
        return row.base_voltage_id;
    }
    if (traits[container].bay) {
        const bay = find_bay_row(columns.bay_rows.items, container) orelse return null;
        const voltage_level = bay.voltage_level_index;
        if (voltage_level == none_index or !traits[voltage_level].voltage_level) return null;
        const row = find_vl_row(columns.vl_rows.items, voltage_level) orelse return null;
        return row.base_voltage_id;
    }
    return null;
}

/// Rows are appended in ascending object-index order (contiguous type
/// ranges), so lookup is a binary search.
fn find_vl_row(row_list: []const rules.VlRow, object_index: u32) ?rules.VlRow {
    var low: usize = 0;
    var high: usize = row_list.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (row_list[mid].object_index < object_index) low = mid + 1 else high = mid;
    }
    if (low < row_list.len and row_list[low].object_index == object_index) return row_list[low];
    return null;
}

fn find_bay_row(row_list: []const rules.BayRow, object_index: u32) ?rules.BayRow {
    var low: usize = 0;
    var high: usize = row_list.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (row_list[mid].object_index < object_index) low = mid + 1 else high = mid;
    }
    if (low < row_list.len and row_list[low].object_index == object_index) return row_list[low];
    return null;
}

const Resolved = struct {
    kind: cim.profile.Kind,
    header: cim.profile.Header,
};

/// The header's single recognized profile kind, or null when the header is
/// absent, malformed, ambiguous, or of an unknown profile URI -- the four
/// causes TooManyProfileParts reports.
fn classify_header(
    gpa: std.mem.Allocator,
    model: *const cim.CimDocument,
) error{OutOfMemory}!?Resolved {
    const header = cim.profile.classify(gpa, model.source()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return switch (header.profile) {
        .known => |kind| .{ .kind = kind, .header = header },
        .unknown, .absent => null,
    };
}

fn gate_active(comptime gate: rules.Gate, resolved: ?Resolved) bool {
    const header = resolved orelse return gate == .always;
    return switch (gate) {
        .always => true,
        .eqbd => header.kind == .eqbd,
        .eq => header.kind == .eq,
        .eq_operations => header.header.has_profile(.equipment_operation) or
            (header.header.version == .v3_0 and header.kind == .eq),
    };
}

/// Whether any requested rule requires the header to be classified.
fn header_needed(requested: RuleMask) bool {
    if (requested.contains(.TooManyProfileParts)) return true;
    inline for (rules.object_rules) |entry| {
        if ((entry.gate != .always or entry.uses_version) and requested.contains(entry.rule)) {
            return true;
        }
    }
    return false;
}

/// Whether any enabled entry resolves references (traits + ReferenceIndex).
fn resolution_needed(enabled: u64) bool {
    inline for (rules.object_rules, 0..) |entry, i| {
        if (entry.needs_resolution and enabled & (1 << i) != 0) return true;
    }
    return false;
}

/// Whether any requested rule consumes harvested columns.
fn relational_needed(requested: RuleMask) bool {
    inline for (rules.relational_rules) |rule| {
        if (requested.contains(rule)) return true;
    }
    return false;
}

const NeededName = struct {
    prop: rules.Prop,
    name: []const u8,
    channels: rules.Channels,
};

/// Merge a need into the group's deduplicated list; two rules sharing a prop
/// union their channels.
fn add_need(needed: *[rules.prop_count]NeededName, needed_len: *u32, need: rules.Need) void {
    for (needed[0..needed_len.*]) |*existing| {
        if (existing.prop == need.prop) {
            existing.channels.text = existing.channels.text or need.channels.text;
            existing.channels.ref = existing.channels.ref or need.channels.ref;
            existing.channels.declared = existing.channels.declared or need.channels.declared;
            return;
        }
    }
    assert(needed_len.* < needed.len);
    needed[needed_len.*] = .{
        .prop = need.prop,
        .name = rules.prop_name(need.prop),
        .channels = need.channels,
    };
    needed_len.* += 1;
}

/// The one child walk per object: fill every needed slot's channels,
/// first-match per channel, early exit when every needed channel is settled.
///
/// Channel semantics mirror the CimObject query trio exactly (see
/// tag_index.zig): `text` takes the first expanded `.property` child --
/// including one whose rdf:resource was malformed, as `property()` does;
/// `ref` takes the first `.reference` child, or poisons on a malformed
/// resource as `reference()`'s error does; `declared` is any occurrence.
fn fill_slots(slots: *rules.Slots, needed: []const NeededName, obj: cim.CimObject) void {
    var remaining: u32 = @intCast(needed.len);
    for (needed) |entry| slots[@intFromEnum(entry.prop)] = .{};

    var it = obj.children();
    while (remaining > 0) {
        const child = it.next() orelse break;
        for (needed) |entry| {
            if (child.name.len != entry.name.len) continue;
            if (!std.mem.eql(u8, child.name, entry.name)) continue;

            const slot = &slots[@intFromEnum(entry.prop)];
            const settled_before = rules.slot_settled(slot.*, entry.channels);
            slot.declared = true;
            switch (child.kind) {
                .property => {
                    if (child.malformed_resource and slot.reference == .absent) {
                        slot.reference = .malformed;
                    }
                    if (!child.self_closing and slot.text == null) {
                        slot.text = child.value;
                    }
                },
                .reference => {
                    if (slot.reference == .absent) {
                        slot.reference = .{ .value = child.value };
                    }
                },
            }
            if (!settled_before and rules.slot_settled(slot.*, entry.channels)) {
                remaining -= 1;
            }
            break;
        }
    }
}
