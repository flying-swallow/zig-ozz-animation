const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const caliper = b.dependency("caliper", .{
        .target = target,
        .optimize = optimize,
    });
    const zgltf = b.dependency("zgltf", .{
        .target = target,
        .optimize = optimize,
    });
    const ozz = b.addModule("zig_ozz_animation", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "caliper", .module = caliper.module("caliper") },
            .{ .name = "zgltf", .module = zgltf.module("zgltf") },
        },
    });

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zig_ozz_animation", .module = ozz }},
    });
    const cli = b.addExecutable(.{
        .name = "ozz",
        .root_module = cli_module,
    });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    run_cli.addPassthruArgs();
    b.step("run", "Run the app").dependOn(&run_cli.step);

    const module_tests = b.addTest(.{ .root_module = ozz });
    const cli_tests = b.addTest(.{ .root_module = cli_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    const check_step = b.step("check", "Compile all tests without running them");
    check_step.dependOn(&module_tests.step);
    check_step.dependOn(&cli_tests.step);
}
