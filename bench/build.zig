const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = std.builtin.OptimizeMode.ReleaseFast;

    const ozz = b.dependency("zig_ozz_animation", .{
        .target = target,
        .optimize = optimize,
    }).module("zig_ozz_animation");
    const zbench = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    }).module("zbench");

    const benches = [_]struct {
        name: []const u8,
        source: []const u8,
        step: []const u8,
        description: []const u8,
    }{
        .{
            .name = "ozz_sampling_benchmark",
            .source = "sampling.zig",
            .step = "run-sampling",
            .description = "Benchmark runtime sampling",
        },
    };

    const run_all = b.step("run", "Run all benchmarks");
    for (benches) |bench| {
        const executable = b.addExecutable(.{
            .name = bench.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bench.source),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zig_ozz_animation", .module = ozz },
                    .{ .name = "zbench", .module = zbench },
                },
            }),
        });
        b.installArtifact(executable);

        const run = b.addRunArtifact(executable);
        b.step(bench.step, bench.description).dependOn(&run.step);
        run_all.dependOn(&run.step);
    }
}
