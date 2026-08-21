const std = @import("std");

const assert = std.debug.assert;

pub const Diagnostics = struct {
    malformed_xml_offset: u32 = 0,
    malformed_xml_line: u64 = 0,
    malformed_xml_recorded: bool = false,
    duplicate_offset: u32 = 0,
    duplicate_line: u64 = 0,
    duplicate_id_len: u8 = 0,
    duplicate_id_truncated: bool = false,
    duplicate_id_recorded: bool = false,
    duplicate_id_buf: [128]u8 = undefined,

    pub fn record_malformed_xml(self: *Diagnostics, xml: []const u8, offset: u32) void {
        assert(offset <= xml.len);
        self.malformed_xml_offset = offset;
        self.malformed_xml_line = line_number_at(xml, offset);
        self.malformed_xml_recorded = true;
    }

    pub fn record_duplicate_id(self: *Diagnostics, xml: []const u8, id: []const u8, offset: u32) void {
        assert(offset <= xml.len);
        const len = @min(id.len, self.duplicate_id_buf.len);
        @memcpy(self.duplicate_id_buf[0..len], id[0..len]);
        self.duplicate_offset = offset;
        self.duplicate_line = line_number_at(xml, offset);
        self.duplicate_id_len = @intCast(len);
        self.duplicate_id_truncated = id.len > len;
        self.duplicate_id_recorded = true;
    }

    pub fn duplicate_id(self: *const Diagnostics) []const u8 {
        assert(self.duplicate_id_recorded);
        return self.duplicate_id_buf[0..self.duplicate_id_len];
    }
};

pub fn line_number_at(xml: []const u8, offset: u32) u64 {
    assert(offset <= xml.len);
    return @as(u64, @intCast(std.mem.count(u8, xml[0..offset], "\n"))) + 1;
}

test "Diagnostics remains valid when copied" {
    var original: Diagnostics = .{};
    original.record_malformed_xml("one\ntwo", 4);
    original.record_duplicate_id("one\ntwo", "_id", 4);
    const copy = original;
    try std.testing.expect(copy.malformed_xml_recorded);
    try std.testing.expectEqual(@as(u32, 4), copy.malformed_xml_offset);
    try std.testing.expectEqual(@as(u64, 2), copy.malformed_xml_line);
    try std.testing.expectEqualStrings("_id", copy.duplicate_id());
    try std.testing.expectEqual(@as(u64, 2), copy.duplicate_line);
}
