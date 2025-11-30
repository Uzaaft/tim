const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("messages", .{
        .root_source_file = b.path("messages.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("messages.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}
