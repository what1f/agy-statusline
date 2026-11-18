const std = @import("std");

pub const Value = std.json.Value;

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ?Value {
    return std.json.parseFromSliceLeaky(Value, allocator, bytes, .{
        .duplicate_field_behavior = .use_last,
    }) catch null;
}

pub fn get(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}

pub fn string(value: Value) []const u8 {
    return if (value == .string) value.string else "";
}

pub fn orString(value: Value, fallback: []const u8) []const u8 {
    const text = string(value);
    return if (text.len != 0) text else fallback;
}

pub fn number(value: Value) ?f64 {
    const result: f64 = switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch return null,
        .bool => |flag| @floatFromInt(@intFromBool(flag)),
        else => return null,
    };
    return if (std.math.isFinite(result)) result else null;
}

pub fn integer(value: Value, fallback: i128) i128 {
    switch (value) {
        .integer => |n| return n,
        .number_string, .string => |text| {
            if (std.fmt.parseInt(i128, std.mem.trim(u8, text, &std.ascii.whitespace), 10)) |n| {
                return n;
            } else |_| {}
        },
        else => {},
    }
    const n = number(value) orelse return fallback;
    if (n < -0x1p127 or n >= 0x1p127) return fallback;
    return @intFromFloat(n);
}

pub fn truthy(value: Value) bool {
    return switch (value) {
        .null => false,
        .string => |s| s.len > 0,
        .array => |a| a.items.len > 0,
        .object => |o| o.count() > 0,
        else => (number(value) orelse 0) != 0,
    };
}
