//! CRC-32/ISO-HDLC, the checksum ZIP entries carry.
//!
//! `std.hash.Crc32` walks one byte at a time through a single 256-entry table,
//! so each byte depends on the previous one and it sustains roughly 0.6 GB/s:
//! verifying a 36 MB EQ profile at that rate costs more than the rest of the
//! conversion. Two faster paths produce the same value -- AArch64 CRC32
//! instructions where the target has them, and slicing-by-8 (eight bytes per
//! iteration from eight tables) everywhere else.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const polynomial: u32 = 0xEDB88320;
const slices = 8;

/// AArch64 CRC32 instructions implement exactly this polynomial. Apple Silicon
/// and every ARMv8.1+ core has them; the table path stays for everything else.
const hardware = builtin.cpu.arch == .aarch64 and
    std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc);

const tables: [slices][256]u32 = blk: {
    @setEvalBranchQuota(100_000);
    var result: [slices][256]u32 = undefined;
    for (0..256) |index| {
        var crc: u32 = @intCast(index);
        for (0..8) |_| {
            crc = (crc >> 1) ^ (polynomial * @as(u32, @intFromBool(crc & 1 != 0)));
        }
        result[0][index] = crc;
    }
    for (0..256) |index| {
        var crc: u32 = result[0][index];
        for (1..slices) |slice| {
            crc = result[0][crc & 0xFF] ^ (crc >> 8);
            result[slice][index] = crc;
        }
    }
    break :blk result;
};

/// The CRC-32 of `bytes`, identical to `std.hash.Crc32.hash`.
pub fn hash(bytes: []const u8) u32 {
    assert(bytes.len <= std.math.maxInt(u32));
    return if (hardware) hash_hardware(bytes) else hash_tables(bytes);
}

fn hash_hardware(bytes: []const u8) u32 {
    comptime assert(hardware);
    assert(bytes.len <= std.math.maxInt(u32));

    var crc: u32 = 0xFFFFFFFF;
    var rest = bytes;
    while (rest.len >= 8) {
        const word = std.mem.readInt(u64, rest[0..8], .little);
        crc = asm ("crc32x %[out:w], %[crc:w], %[word]"
            : [out] "=r" (-> u32),
            : [crc] "r" (crc),
              [word] "r" (word),
        );
        rest = rest[8..];
    }
    assert(rest.len < 8);
    for (rest) |byte| {
        crc = asm ("crc32b %[out:w], %[crc:w], %[byte:w]"
            : [out] "=r" (-> u32),
            : [crc] "r" (crc),
              [byte] "r" (byte),
        );
    }
    return ~crc;
}

fn hash_tables(bytes: []const u8) u32 {
    assert(bytes.len <= std.math.maxInt(u32));

    var crc: u32 = 0xFFFFFFFF;
    var rest = bytes;
    while (rest.len >= slices) {
        const low = std.mem.readInt(u32, rest[0..4], .little) ^ crc;
        const high = std.mem.readInt(u32, rest[4..8], .little);
        crc = tables[7][low & 0xFF] ^
            tables[6][(low >> 8) & 0xFF] ^
            tables[5][(low >> 16) & 0xFF] ^
            tables[4][low >> 24] ^
            tables[3][high & 0xFF] ^
            tables[2][(high >> 8) & 0xFF] ^
            tables[1][(high >> 16) & 0xFF] ^
            tables[0][high >> 24];
        rest = rest[slices..];
    }
    assert(rest.len < slices);
    for (rest) |byte| crc = tables[0][(crc ^ byte) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

test "matches std.hash.Crc32 across lengths and alignments" {
    var data: [512]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x1D_C6E5);
    prng.random().bytes(&data);

    for (0..data.len + 1) |len| {
        const head = data[0..len];
        const tail = data[data.len - len ..];
        try std.testing.expectEqual(std.hash.Crc32.hash(head), hash(head));
        try std.testing.expectEqual(std.hash.Crc32.hash(tail), hash(tail));
        // The fallback must agree with the accelerated path it replaces.
        try std.testing.expectEqual(std.hash.Crc32.hash(head), hash_tables(head));
    }
}

test "matches std.hash.Crc32 on known vectors" {
    try std.testing.expectEqual(@as(u32, 0), hash(""));
    try std.testing.expectEqual(@as(u32, 0xCBF43926), hash("123456789"));
    try std.testing.expectEqual(std.hash.Crc32.hash("<rdf:RDF/>"), hash("<rdf:RDF/>"));
}
