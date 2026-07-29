const std = @import("std");
const ozz = @import("zig_ozz_animation");
const zbench = @import("zbench");

const SamplingBenchmark = struct {
    animation: *const ozz.animation.Animation,
    context: *ozz.animation.SamplingContext,
    output: []ozz.math.SoaTransform,
    iteration: *usize,

    pub fn run(self: *SamplingBenchmark, allocator: std.mem.Allocator) void {
        _ = allocator;
        const iteration = self.iteration.*;
        self.iteration.* +%= 1;
        ozz.animation.sample(
            self.animation,
            @as(f32, @floatFromInt(iteration % 1000)) / 1000,
            self.context,
            self.output,
        ) catch |err| std.debug.panic("sampling failed: {t}", .{err});
        std.mem.doNotOptimizeAway(self.output[0]);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const track_count = 256;
    const inputs = try allocator.alloc(ozz.animation.JointTrackInput, track_count);
    const translation_keys = try allocator.alloc([3]ozz.animation.Float3Key, track_count);
    const rotation_keys = try allocator.alloc([3]ozz.animation.QuaternionKey, track_count);
    const scale_keys = try allocator.alloc([2]ozz.animation.Float3Key, track_count);
    for (inputs, 0..) |*input, i| {
        translation_keys[i] = .{
            .{ .ratio = 0, .value = @splat(0) },
            .{ .ratio = 0.5, .value = .{ @floatFromInt(i % 11), 1, 0 } },
            .{ .ratio = 1, .value = @splat(0) },
        };
        rotation_keys[i] = .{
            .{ .ratio = 0, .value = ozz.math.quat.identity },
            .{ .ratio = 0.5, .value = ozz.math.quat.fromAxisAngle(.{ 0, 1, 0 }, 1) },
            .{ .ratio = 1, .value = ozz.math.quat.identity },
        };
        scale_keys[i] = .{
            .{ .ratio = 0, .value = @splat(1) },
            .{ .ratio = 1, .value = @splat(1) },
        };
        input.* = .{
            .translations = &translation_keys[i],
            .rotations = &rotation_keys[i],
            .scales = &scale_keys[i],
        };
    }
    var animation = try ozz.animation.Animation.init(allocator, "benchmark", 1, inputs);
    defer animation.deinit();
    var context = try ozz.animation.SamplingContext.init(allocator, track_count);
    defer context.deinit();
    const output = try allocator.alloc(ozz.math.SoaTransform, animation.numSoaTracks());

    for (0..100) |i| try ozz.animation.sample(
        &animation,
        @as(f32, @floatFromInt(i)) / 100,
        &context,
        output,
    );

    var iteration: usize = 0;
    const sampling = SamplingBenchmark{
        .animation = &animation,
        .context = &context,
        .output = output,
        .iteration = &iteration,
    };
    var benchmark = zbench.Benchmark.init(allocator, .{});
    defer benchmark.deinit();
    try benchmark.addParam("sample (256 tracks)", &sampling, .{
        .items_per_run = track_count,
    });
    try benchmark.run(init.io, .stdout());
}
