pub fn strip_hash(s: []const u8) []const u8 {
    return if (s.len > 0 and s[0] == '#') s[1..] else s;
}

pub fn strip_underscore(s: []const u8) []const u8 {
    return if (s.len > 0 and s[0] == '_') s[1..] else s;
}
