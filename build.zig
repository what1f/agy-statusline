const std = @import("std");

pub fn build(b: *std.Build) void {
    const executable = b.addExecutable(.{
        .name = "statusline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
            .link_libc = true,
            .single_threaded = true,
        }),
    });
    b.installArtifact(executable);
}
