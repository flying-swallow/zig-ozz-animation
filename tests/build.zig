const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const port = b.dependency("zig_ozz_animation", .{
        .target = target,
        .optimize = optimize,
    });
    const upstream = b.dependency("ozz_animation_upstream", .{});

    const fixture_options = b.addOptions();
    fixture_options.addOptionPath("upstream_marker", upstream.path("README.md"));

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_ozz_animation", .module = port.module("zig_ozz_animation") },
                .{ .name = "fixture_options", .module = fixture_options.createModule() },
            },
        }),
    });

    const test_step = b.step("test", "Run upstream semantic conformance tests");
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    const check_step = b.step("check", "Compile upstream semantic conformance tests");
    check_step.dependOn(&tests.step);
}
