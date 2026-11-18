const std = @import("std");
const builtin = @import("builtin");
const epoch = std.time.epoch;
const us_per_s = std.time.us_per_s;
const seconds_per_day = 86_400;
const is_windows = builtin.os.tag == .windows;
const win_epoch_diff_s: i64 = 11_644_473_600;
const ticks_per_s: i64 = 10_000_000;

const LocalParts = struct {
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
};

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

// POSIX struct tm, including the local UTC offset provided by macOS and Linux.
const Tm = extern struct {
    second: c_int,
    minute: c_int,
    hour: c_int,
    day: c_int,
    month: c_int,
    year: c_int,
    weekday: c_int,
    year_day: c_int,
    is_dst: c_int,
    utc_offset: c_long,
    zone: ?[*:0]const u8,
};

const posix_api = if (!is_windows) struct {
    extern "c" fn tzset() void;
    extern "c" fn localtime_r(seconds: *const std.c.time_t, result: *Tm) ?*Tm;
    extern "c" fn gmtime_r(seconds: *const std.c.time_t, result: *Tm) ?*Tm;
} else struct {};

const win_api = if (is_windows) struct {
    extern "kernel32" fn FileTimeToSystemTime(lpFileTime: *const std.os.windows.FILETIME, lpSystemTime: *SYSTEMTIME) callconv(.winapi) c_int;
    extern "kernel32" fn SystemTimeToFileTime(lpSystemTime: *const SYSTEMTIME, lpFileTime: *std.os.windows.FILETIME) callconv(.winapi) c_int;
    extern "kernel32" fn SystemTimeToTzSpecificLocalTime(lpTimeZoneInformation: ?*const anyopaque, lpUniversalTime: *const SYSTEMTIME, lpLocalTime: *SYSTEMTIME) callconv(.winapi) c_int;
    extern "kernel32" fn TzSpecificLocalTimeToSystemTime(lpTimeZoneInformation: ?*const anyopaque, lpLocalTime: *const SYSTEMTIME, lpUniversalTime: *SYSTEMTIME) callconv(.winapi) c_int;
} else struct {};

pub const IsoTime = struct {
    civil_us: i64,
    offset_us: ?i64 = null,

    pub fn unixMicros(self: IsoTime) i64 {
        if (self.offset_us) |offset| return self.civil_us - offset;

        const civil = @divFloor(self.civil_us, us_per_s);
        if (is_windows) {
            const civil_ft = unixSecondsToFileTime(civil) orelse return self.civil_us;
            var civil_st: SYSTEMTIME = undefined;
            if (win_api.FileTimeToSystemTime(&civil_ft, &civil_st) == 0) return self.civil_us;
            var utc_st: SYSTEMTIME = undefined;
            if (win_api.TzSpecificLocalTimeToSystemTime(null, &civil_st, &utc_st) == 0) return self.civil_us;
            var utc_ft: std.os.windows.FILETIME = undefined;
            if (win_api.SystemTimeToFileTime(&utc_st, &utc_ft) == 0) return self.civil_us;
            return fileTimeToUnixSeconds(utc_ft) * us_per_s + @mod(self.civil_us, us_per_s);
        }

        // A local wall time can occur twice or be skipped when the offset changes.
        // Python's default fold selects the first occurrence or moves forward
        // across a gap.
        posix_api.tzset();
        const before = localTime(civil - seconds_per_day) orelse return self.civil_us;
        const after = localTime(civil + seconds_per_day) orelse return self.civil_us;
        const a = civil - before.utc_offset;
        const b = civil - after.utc_offset;
        const a_local = localTime(a) orelse return self.civil_us;
        const b_local = localTime(b) orelse return self.civil_us;
        const a_matches = a + a_local.utc_offset == civil;
        const b_matches = b + b_local.utc_offset == civil;
        const resolved = if (a_matches and b_matches)
            @min(a, b)
        else if (a_matches)
            a
        else if (b_matches)
            b
        else
            @max(a, b);
        return resolved * us_per_s + @mod(self.civil_us, us_per_s);
    }
};

fn unixSecondsToFileTime(unix_seconds: i64) ?std.os.windows.FILETIME {
    const shifted = std.math.add(i64, unix_seconds, win_epoch_diff_s) catch return null;
    if (shifted < 0) return null;
    const ticks = std.math.mul(i64, shifted, ticks_per_s) catch return null;
    const raw: u64 = @intCast(ticks);
    return .{
        .dwLowDateTime = @truncate(raw),
        .dwHighDateTime = @truncate(raw >> 32),
    };
}

fn fileTimeToUnixSeconds(ft: std.os.windows.FILETIME) i64 {
    const raw = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    return @as(i64, @intCast(raw / @as(u64, ticks_per_s))) - win_epoch_diff_s;
}

fn localTime(unix_seconds: i64) ?Tm {
    const stamp: std.c.time_t = @intCast(unix_seconds);
    var result: Tm = undefined;
    return if (posix_api.localtime_r(&stamp, &result) != null) result else null;
}

fn unixSecondsToLocalParts(unix_seconds: i64) ?LocalParts {
    if (is_windows) {
        const ft = unixSecondsToFileTime(unix_seconds) orelse return null;
        var utc_st: SYSTEMTIME = undefined;
        if (win_api.FileTimeToSystemTime(&ft, &utc_st) == 0) return null;
        var local_st: SYSTEMTIME = undefined;
        if (win_api.SystemTimeToTzSpecificLocalTime(null, &utc_st, &local_st) == 0) return null;
        return .{
            .month = @intCast(local_st.wMonth),
            .day = @intCast(local_st.wDay),
            .hour = @intCast(local_st.wHour),
            .minute = @intCast(local_st.wMinute),
        };
    }
    posix_api.tzset();
    const local = localTime(unix_seconds) orelse return null;
    return .{
        .month = @intCast(local.month + 1),
        .day = @intCast(local.day),
        .hour = @intCast(local.hour),
        .minute = @intCast(local.minute),
    };
}

pub fn formatReset(buffer: *[11]u8, now_us: i64, iso: []const u8, delay: ?f64) []const u8 {
    var parts: LocalParts = undefined;
    var short: bool = undefined;
    if (parseIso(iso)) |stamp| {
        const target = stamp.unixMicros();
        const delta = target - now_us;
        short = delta >= 0 and delta < seconds_per_day * us_per_s;
        parts = unixSecondsToLocalParts(@divFloor(target, us_per_s)) orelse return "";
    } else if (delay) |wait| {
        if (wait <= 0 or wait >= 0x1p38) return "";
        const wait_us: i64 = @intFromFloat(@round(wait * us_per_s));
        short = wait < seconds_per_day;
        if (is_windows) {
            parts = unixSecondsToLocalParts(@divFloor(now_us + wait_us, us_per_s)) orelse return "";
        } else {
            posix_api.tzset();
            const current = localTime(@divFloor(now_us, us_per_s)) orelse return "";
            // datetime.now().astimezone() carries the current fixed offset into the sum.
            const target: std.c.time_t = @intCast(@divFloor(now_us + wait_us, us_per_s) + current.utc_offset);
            var local: Tm = undefined;
            if (posix_api.gmtime_r(&target, &local) == null or local.year >= 8100) return "";
            parts = .{
                .month = @intCast(local.month + 1),
                .day = @intCast(local.day),
                .hour = @intCast(local.hour),
                .minute = @intCast(local.minute),
            };
        }
    } else return "";

    const hour = std.fmt.digits2(parts.hour);
    const minute = std.fmt.digits2(parts.minute);
    if (short) return std.fmt.bufPrint(buffer, "{s}:{s}", .{ hour, minute }) catch unreachable;
    const month = std.fmt.digits2(parts.month);
    const day = std.fmt.digits2(parts.day);
    return std.fmt.bufPrint(buffer, "{s}-{s} {s}:{s}", .{ month, day, hour, minute }) catch unreachable;
}

pub fn parseIso(text: []const u8) ?IsoTime {
    var rest = text;
    const year = digits(&rest, 4) orelse return null;
    if (year == 0) return null;
    const extended = take(&rest, '-');
    const days = if (take(&rest, 'W')) blk: {
        const week = digits(&rest, 2) orelse return null;
        const start = weekOne(year);
        if (week < 1 or start + (week - 1) * 7 >= weekOne(year + 1)) return null;
        const weekday = if (if (extended) take(&rest, '-') else isDigit(rest))
            digits(&rest, 1) orelse return null
        else
            1;
        if (weekday < 1 or weekday > 7) return null;
        break :blk start + (week - 1) * 7 + weekday - 1;
    } else blk: {
        const month = digits(&rest, 2) orelse return null;
        if (extended and !take(&rest, '-')) return null;
        const day = digits(&rest, 2) orelse return null;
        if (month < 1 or month > 12 or day < 1 or day > monthDays(year, month)) return null;
        var days = yearStart(year) + day - 1;
        for (1..@intCast(month)) |m| days += monthDays(year, @intCast(m));
        break :blk days;
    };
    if (days < yearStart(1) or days >= yearStart(10000)) return null;

    var result: IsoTime = .{ .civil_us = days * seconds_per_day * us_per_s };
    if (rest.len == 0) return result;
    const separator_len = std.unicode.utf8ByteSequenceLength(rest[0]) catch return null;
    if (rest.len < separator_len) return null;
    rest = rest[separator_len..];
    result.civil_us += parseClock(&rest, false) orelse return null;
    if (rest.len == 0) return result;
    if (std.mem.eql(u8, rest, "Z")) {
        result.offset_us = 0;
        return result;
    }
    const negative = take(&rest, '-');
    if (!negative and !take(&rest, '+')) return null;
    const offset = parseClock(&rest, true) orelse return null;
    if (rest.len != 0 or offset >= seconds_per_day * us_per_s) return null;
    result.offset_us = if (offset < us_per_s) 0 else if (negative) -offset else offset;
    return result;
}

fn parseClock(rest: *[]const u8, offset: bool) ?i64 {
    const hour = digits(rest, 2) orelse return null;
    var minute: i64 = 0;
    var second: i64 = 0;
    const extended = take(rest, ':');
    if (extended or isDigit(rest.*)) {
        minute = digits(rest, 2) orelse return null;
        if (if (extended) take(rest, ':') else isDigit(rest.*)) {
            second = digits(rest, 2) orelse return null;
        }
    }
    if (!offset and (hour >= 24 or minute >= 60 or second >= 60)) return null;

    var fraction: i64 = 0;
    if (take(rest, '.') or take(rest, ',')) {
        if (!isDigit(rest.*)) return null;
        var place: i64 = 100_000;
        while (isDigit(rest.*)) : (rest.* = rest.*[1..]) {
            fraction += (rest.*[0] - '0') * place;
            place = @divTrunc(place, 10);
        }
    }
    return (hour * 3600 + minute * 60 + second) * us_per_s + fraction;
}

fn isDigit(rest: []const u8) bool {
    return rest.len != 0 and std.ascii.isDigit(rest[0]);
}

fn digits(rest: *[]const u8, count: usize) ?i64 {
    if (rest.len < count) return null;
    var value: i64 = 0;
    for (rest.*[0..count]) |digit| {
        if (!std.ascii.isDigit(digit)) return null;
        value = value * 10 + (digit - '0');
    }
    rest.* = rest.*[count..];
    return value;
}

fn take(rest: *[]const u8, byte: u8) bool {
    if (rest.len == 0 or rest.*[0] != byte) return false;
    rest.* = rest.*[1..];
    return true;
}

fn monthDays(year: i64, month: i64) i64 {
    return epoch.getDaysInMonth(@intCast(year), @fromBackingInt(@intCast(month)));
}

fn yearStart(year: i64) i64 {
    const y = year - 1;
    return 365 * y + @divTrunc(y, 4) - @divTrunc(y, 100) + @divTrunc(y, 400) - 719_162;
}

fn weekOne(year: i64) i64 {
    // The first ISO week contains January 4. The Unix epoch was a Thursday.
    const january_fourth = yearStart(year) + 3;
    return january_fourth - @mod(january_fourth + 3, 7);
}
