const std = @import("std");
const builtin = @import("builtin");
const json = @import("json.zig");
const time = @import("time.zig");
const Io = std.Io;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const Value = json.Value;

const reset = "\x1b[0m";
const separator = "\x1b[37m | " ++ reset;
const usage_icon = "\u{f0a9e}";

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded = Io.Threaded.init(std.heap.c_allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();
    var input_buffer: [4096]u8 = undefined;
    var input = Io.File.stdin().readerStreaming(io, &input_buffer);
    const bytes = try input.interface.allocRemaining(allocator, .unlimited);
    const data = json.parse(allocator, bytes) orelse .null;

    var output_buffer: [4096]u8 = undefined;
    var output = Io.File.stdout().writerStreaming(io, &output_buffer);
    try buildLine(io, allocator, &output.interface, data);
    try output.interface.flush();
}

fn buildLine(io: Io, allocator: Allocator, out: *Writer, data: Value) !void {
    const width = json.get(data, "terminal_width");
    const compact = switch (width) {
        .integer => |n| n != 0 and n < 95,
        .number_string => |text| std.mem.findAny(u8, text, ".eE") == null and text[0] == '-',
        .bool => |flag| flag,
        else => false,
    };

    const model = json.get(data, "model");
    const model_id = json.string(json.get(model, "id"));
    const display_name = json.string(json.get(model, "display_name"));
    const model_name = if (display_name.len > 0) display_name else if (model_id.len > 0) model_id else "-";
    try segment(out, "\x1b[96m\u{f51b}", "\x1b[1;96m");
    try out.print("{s}" ++ reset, .{model_name});

    const cwd = json.orString(json.get(json.get(data, "workspace"), "current_dir"), json.string(json.get(data, "cwd")));
    if (cwd.len > 0) {
        const norm = try std.fs.path.resolveAlloc(allocator, &.{cwd});
        var name = std.fs.path.basename(norm);
        if (name.len == 0) {
            if (builtin.os.tag != .windows and std.mem.eql(u8, norm, "/") and std.mem.startsWith(u8, cwd, "//") and !std.mem.startsWith(u8, cwd, "///")) {
                name = "//";
            } else {
                name = norm;
            }
        }
        try out.writeAll(separator);
        try segment(out, "\x1b[93m\u{f024b}", "\x1b[1;92m");
        try out.print("{s}" ++ reset, .{name});
        try writeGit(io, allocator, out, cwd);
    }

    try out.writeAll(separator);
    try segment(out, "\x1b[95m\u{f49b}", "\x1b[1;95m");
    try writeContext(out, json.get(data, "context_window"), compact);
    try out.writeAll(reset);

    try writeQuota(io, out, json.get(data, "quota"), model_id, display_name, compact);
    try out.writeByte('\n');
}

fn segment(out: *Writer, comptime icon: []const u8, comptime color: []const u8) Writer.Error!void {
    try out.writeAll(icon ++ reset ++ " " ++ color);
}

fn writeGit(io: Io, allocator: Allocator, out: *Writer, cwd: []const u8) Writer.Error!void {
    if (std.mem.findScalar(u8, cwd, 0) != null) return;
    const info = Io.Dir.cwd().statFile(io, cwd, .{}) catch return;
    if (info.kind != .directory) return;

    var developer_git = findDeveloperGit(io, allocator);
    const branch = runGit(io, allocator, &developer_git, cwd, &.{ "symbolic-ref", "--short", "HEAD" }) orelse
        runGit(io, allocator, &developer_git, cwd, &.{ "rev-parse", "--short", "HEAD" }) orelse return;
    const dirty = runGit(io, allocator, &developer_git, cwd, &.{ "status", "--porcelain", "--untracked-files=normal" }) != null;
    try out.writeAll(separator);
    try segment(out, "\x1b[94m\u{f02a2}", "\x1b[1;94m");
    try out.print("{s} {s}" ++ reset, .{ branch, if (dirty) "●" else "✓" });
}

fn findDeveloperGit(io: Io, allocator: Allocator) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    // This also honors DEVELOPER_DIR and the standalone Command Line Tools.
    // Resolve once, since /usr/bin/git repeats tool selection on every call.
    const directory = (runCommand(io, allocator, &.{ "/usr/bin/xcode-select", "--print-path" }) catch null) orelse return null;
    if (!std.fs.path.isAbsolutePosix(directory)) return null;
    return std.fs.path.join(allocator, &.{ directory, "usr/bin/git" }) catch null;
}

fn runGit(io: Io, allocator: Allocator, developer_git: *?[]const u8, cwd: []const u8, comptime args: []const []const u8) ?[]const u8 {
    var argv = .{ developer_git.* orelse "git", "-C", cwd, "--no-optional-locks" } ++ args[0..args.len].*;
    return runCommand(io, allocator, &argv) catch |err| {
        if (developer_git.* == null) return null;
        switch (err) {
            error.FileNotFound,
            error.AccessDenied,
            error.PermissionDenied,
            error.InvalidExe,
            error.IsDir,
            error.NotDir,
            error.SymLinkLoop,
            error.FileSystem,
            error.FileBusy,
            error.NameTooLong,
            error.BadPathName,
            => {},
            else => return null,
        }
        developer_git.* = null;
        argv[0] = "git";
        return runCommand(io, allocator, &argv) catch null;
    };
}

fn runCommand(io: Io, allocator: Allocator, argv: []const []const u8) std.process.RunError!?[]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .timeout = .{ .deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(350), .clock = .awake }) },
    });
    if (!result.term.success()) return null;
    const text = std.mem.trimEnd(u8, result.stdout, "\n");
    return if (text.len > 0) text else null;
}

fn writeContext(out: *Writer, ctx: Value, compact: bool) Writer.Error!void {
    const used = json.number(json.get(ctx, "used_percentage")) orelse 0;
    const usage = json.get(ctx, "current_usage");
    const tokens = json.integer(json.get(usage, "input_tokens"), 0) +|
        json.integer(json.get(usage, "cache_read_input_tokens"), 0) +|
        json.integer(json.get(usage, "cache_creation_input_tokens"), 0) +|
        json.integer(json.get(usage, "output_tokens"), 0);

    if (tokens > 0) {
        if (used > 0 and compact) {
            try writeFixed(out, used, 0);
            try out.writeByte('%');
        } else {
            try writeTokens(out, tokens);
            if (used > 0) {
                try out.writeAll(" (");
                try writeFixed(out, used, 1);
                try out.writeAll("%)");
            } else try out.writeAll(" tokens");
        }
    } else if (used > 0) {
        try writeFixed(out, used, 1);
        try out.writeByte('%');
    } else try out.writeAll("- tokens");
}

fn writeTokens(out: *Writer, count: i128) Writer.Error!void {
    if (count >= 1_000_000) {
        try writeFixed(out, @as(f64, @floatFromInt(count)) / 1_000_000, 1);
        try out.writeByte('M');
    } else if (count >= 1_000) {
        try writeFixed(out, @as(f64, @floatFromInt(count)) / 1_000, 1);
        try out.writeByte('k');
    } else try out.print("{d}", .{count});
}

fn writeFixed(out: *Writer, value: f64, comptime places: u1) Writer.Error!void {
    // Widen before scaling to distinguish an exact half from a nearby float.
    // Zig's decimal formatter rounds ties up. Python rounds ties to even.
    const scale = if (places == 1) 10 else 1;
    const scaled = @as(f128, value) * scale;
    if (scaled >= 0x1p128) {
        const big = std.math.big.int;
        const capacity = comptime big.calcNonZeroTwosCompLimbCount(1025);
        var limbs: [capacity]std.math.big.Limb = undefined;
        var scratch: [big.calcToStringLimbsBufferLen(capacity, 10)]std.math.big.Limb = undefined;
        var digits: [311]u8 = undefined;
        var whole = big.Mutable.init(&limbs, 0);
        _ = whole.setFloat(value, .trunc);
        const len = whole.toConst().toString(&digits, 10, .lower, &scratch);
        try out.writeAll(digits[0..len]);
        if (places == 1) try out.writeAll(".0");
        return;
    }
    const floor: u128 = @intFromFloat(scaled);
    const fraction = scaled - @as(f128, @floatFromInt(floor));
    const rounded = floor + @intFromBool(fraction > 0.5 or (fraction == 0.5 and floor % 2 != 0));
    if (places == 1) return out.print("{d}.{d}", .{ rounded / 10, @as(u8, @intCast(rounded % 10)) });
    return out.print("{d}", .{rounded});
}

fn writeQuota(io: Io, out: *Writer, quota: Value, model_id: []const u8, display_name: []const u8, compact: bool) Writer.Error!void {
    if (quota != .object or quota.object.count() == 0) return;

    var third_party = false;
    for ([_][]const u8{ "claude", "gpt", "opus", "sonnet", "haiku" }) |word| {
        if (std.ascii.findIgnoreCase(model_id, word) != null or std.ascii.findIgnoreCase(display_name, word) != null) {
            third_party = true;
            break;
        }
    }
    const preferred: [2][]const u8 = if (third_party) .{ "3p-5h", "3p-weekly" } else .{ "gemini-5h", "gemini-weekly" };
    const now = if (compact) 0 else Io.Clock.real.now(io).toMicroseconds();
    var started = false;
    for (preferred) |key| try writeBucket(out, json.get(quota, key), compact, now, &started);
    if (!started) {
        for (quota.object.values()) |bucket| try writeBucket(out, bucket, compact, now, &started);
    }
    if (started) try out.writeAll(reset);
}

fn writeBucket(out: *Writer, bucket: Value, compact: bool, now: i64, started: *bool) Writer.Error!void {
    if (json.truthy(json.get(bucket, "disabled"))) return;
    const remaining = json.number(json.get(bucket, "remaining_fraction")) orelse return;
    const used = std.math.clamp((1.0 - remaining) * 100.0, 0.0, 100.0);

    if (started.*) {
        try out.writeAll(" │ " ++ usage_icon ++ " ");
    } else {
        started.* = true;
        try out.writeAll(separator);
        try segment(out, "\x1b[96m" ++ usage_icon, "\x1b[96m");
    }
    try writeFixed(out, used, 0);
    try out.writeByte('%');
    if (!compact) {
        var buffer: [11]u8 = undefined;
        const reset_time = time.formatReset(&buffer, now, json.string(json.get(bucket, "reset_time")), json.number(json.get(bucket, "reset_in_seconds")));
        if (reset_time.len > 0) try out.print(" · {s}", .{reset_time});
    }
}
