const std = @import("std");
const ozz = @import("zig_ozz_animation");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const track_count = 256;
    const inputs = try allocator.alloc(ozz.animation.JointTrackInput, track_count);
    const translation_keys = try allocator.alloc([3]ozz.animation.Float3Key, track_count);
    const rotation_keys = try allocator.alloc([3]ozz.animation.QuaternionKey, track_count);
    const scale_keys = try allocator.alloc([2]ozz.animation.Float3Key, track_count);
    for (inputs, 0..) |*input, i| {
        translation_keys[i] = .{
            .{ .ratio = 0, .value = .zero },
            .{ .ratio = 0.5, .value = .{ .x = @floatFromInt(i % 11), .y = 1 } },
            .{ .ratio = 1, .value = .zero },
        };
        rotation_keys[i] = .{
            .{ .ratio = 0, .value = .identity },
            .{ .ratio = 0.5, .value = ozz.math.Quaternion.fromAxisAngle(.y_axis, 1) },
            .{ .ratio = 1, .value = .identity },
        };
        scale_keys[i] = .{
            .{ .ratio = 0, .value = .one },
            .{ .ratio = 1, .value = .one },
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

    const iterations = 20_000;
    for (0..100) |i| try ozz.animation.sample(
        &animation,
        @as(f32, @floatFromInt(i)) / 100,
        &context,
        output,
    );
    const start = std.Io.Clock.real.now(init.io);
    for (0..iterations) |i| try ozz.animation.sample(
        &animation,
        @as(f32, @floatFromInt(i % 1000)) / 1000,
        &context,
        output,
    );
    const elapsed = start.durationTo(std.Io.Clock.real.now(init.io));
    const ns_per_sample = @as(f64, @floatFromInt(elapsed.nanoseconds)) / iterations;
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print(
        "sampling: {d:.1} ns/sample ({d} tracks, {d} iterations)\n",
        .{ ns_per_sample, track_count, iterations },
    );
    try stdout.interface.flush();
    std.mem.doNotOptimizeAway(output[0]);
}
