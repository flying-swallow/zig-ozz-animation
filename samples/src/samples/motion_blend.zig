// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/motion_blend/sample_motion_blend.cc`.
//!
//! Extends the `blend` sample to root motion: three locomotion clips (walk, jog,
//! run) are blended by a single "blend ratio", and the *root motion* of the same
//! three clips is blended by the very same weights through
//! `ozz.animation.blendMotion`. The blended per-frame delta then feeds a
//! `MotionDeltaAccumulator`, which is what actually drives the character around.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Float4x4 = ozz.math.Float4x4;
const Quaternion = ozz.math.Quaternion;
const Vec3f32 = ozz.math.Vec3f32;
const vec = ozz.math.vec;

pub const name = "motion_blend";
pub const description = "Motion-aware animation blending";

/// The number of animation / motion layers blended together.
pub const layer_count = 3;

/// The character's collision capsule stand-in, drawn at the root transform.
const bounding: ozz.math.Box = .{
    .min = .{ -0.25, 0, -0.25 },
    .max = .{ 0.25, 1.8, 0.25 },
};

/// Half of pi, the bound upstream uses for the angular velocity slider.
const half_pi: f32 = std.math.pi / 2.0;

/// Everything needed to sample one animation and its root motion.
const Layer = struct {
    /// Playback time / speed / loop control.
    controller: fw.PlaybackController = .{},
    /// Blending weight, shared by the animation and the motion blend.
    weight: f32 = 1,
    /// Runtime animation, sampling context and local-space output.
    clip: fw.utils.Clip,
    /// Position and rotation motion tracks of that same animation.
    motion_track: fw.MotionTrack,
    /// Per-layer motion accumulator; its `delta` is the motion blend input.
    motion_sampler: fw.motion_utils.MotionSampler = .{},

    fn deinit(self: *Layer) void {
        self.motion_track.deinit();
        self.clip.deinit();
    }
};

/// Blending weights for `ratio`: the triangular curve the `blend` sample uses,
/// where each layer peaks at its own interval centre and falls off linearly.
///
/// Migrated verbatim from `demo.zig`'s `blendWeights`; it is algebraically the
/// same as upstream's `UpdateRuntimeParameters` weight loop for three layers.
pub fn blendWeights(ratio: f32) [layer_count]f32 {
    const value = std.math.clamp(ratio, 0, 1);
    return .{
        @max(0, 1 - @abs(value) * 2),
        @max(0, 1 - @abs(value - 0.5) * 2),
        @max(0, 1 - @abs(value - 1) * 2),
    };
}

pub const Sample = struct {
    allocator: std.mem.Allocator,

    /// Runtime skeleton, shared by the three layers.
    skeleton: ozz.animation.Skeleton,
    layers: [layer_count]Layer,
    /// Local-space output of the animation blending stage.
    output: []ozz.math.SoaTransform,
    /// Model-space matrices, the output of the local-to-model conversion.
    models: []Float4x4,

    /// Character motion accumulator, fed with the *blended* motion delta.
    accumulator: fw.motion_utils.MotionDeltaAccumulator = .{},
    /// Character transform, driven by the accumulator.
    transform: Float4x4 = .identity,

    /// Global blend ratio: 0 gives full weight to the first animation, 1 to the
    /// last. Also synchronizes the playback speeds.
    blend_ratio: f32 = 0.3,
    /// Bypasses the automatic weighting and synchronization.
    manual: bool = false,
    /// Steering deformation applied to the accumulated path, in rad/s.
    angular_velocity: f32 = std.math.pi / 4.0,

    // Debug display options.
    show_box: bool = true,
    show_motion: bool = true,

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(@embedFile("pab_skeleton")),
        );
        errdefer skeleton.deinit();

        // The animations have their root motion baked out; the matching motion
        // tracks carry it instead.
        const animations = [layer_count][]const u8{
            assets.animationOr(@embedFile("pab_walk_no_motion")),
            @embedFile("pab_jog_no_motion"),
            @embedFile("pab_run_no_motion"),
        };
        const motions = [layer_count][]const u8{
            assets.trackOr(@embedFile("pab_walk_motion")),
            @embedFile("pab_jog_motion"),
            @embedFile("pab_run_motion"),
        };

        var layers: [layer_count]Layer = undefined;
        var built: usize = 0;
        errdefer for (layers[0..built]) |*layer| layer.deinit();
        for (&layers, animations, motions) |*layer, animation, motion| {
            var clip = try fw.utils.Clip.decode(allocator, animation);
            errdefer clip.deinit();
            if (skeleton.numJoints() != clip.animation.numTracks()) {
                return error.SkeletonAnimationMismatch;
            }
            // Every layer is sampled once so a zero-weighted layer never hands
            // uninitialized transforms to the blending job.
            try clip.sample(0);
            layer.* = .{
                .clip = clip,
                .motion_track = try fw.MotionTrack.decode(allocator, motion),
            };
            built += 1;
        }

        const output = try allocator.alloc(
            ozz.math.SoaTransform,
            skeleton.numSoaJoints(),
        );
        errdefer allocator.free(output);
        const models = try allocator.alloc(Float4x4, skeleton.numJoints());
        errdefer allocator.free(models);
        @memset(models, .identity);

        return .{
            .allocator = allocator,
            .skeleton = skeleton,
            .layers = layers,
            .output = output,
            .models = models,
        };
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.models);
        self.allocator.free(self.output);
        for (&self.layers) |*layer| layer.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;

        // Updates blending parameters and synchronizes animations unless the
        // user took manual control.
        if (!self.manual) self.updateRuntimeParameters();

        for (&self.layers) |*layer| {
            const loops = layer.controller.update(layer.clip.duration(), dt);

            // Motion always has to be accumulated, even for an irrelevant
            // layer: the accumulator needs consistent last/current transforms
            // so it stays usable the moment the layer regains weight.
            layer.motion_sampler.update(
                layer.motion_track,
                layer.controller.time_ratio,
                loops,
                .identity,
            );

            // Sampling however can be skipped for an irrelevant layer.
            if (layer.weight <= 0) continue;
            try layer.clip.sample(layer.controller.time_ratio);
        }

        // Blends the per-layer motion deltas with the animation weights, then
        // applies the result — steered by the frame rotation — to the character
        // accumulator.
        var motion_layers: [layer_count]ozz.animation.MotionLayer = undefined;
        for (&motion_layers, &self.layers) |*motion_layer, *layer| {
            motion_layer.* = .{
                .delta = layer.motion_sampler.delta(),
                .weight = layer.weight,
            };
        }
        self.accumulator.update(
            ozz.animation.blendMotion(&motion_layers),
            self.frameRotation(dt),
        );
        self.transform = Float4x4.fromTransform(self.accumulator.current);

        // Blends the local-space transforms sampled above.
        var blend_layers: [layer_count]ozz.animation.BlendLayer = undefined;
        for (&blend_layers, &self.layers) |*blend_layer, *layer| {
            blend_layer.* = .{ .transforms = layer.clip.pose, .weight = layer.weight };
        }
        try ozz.animation.blend(.{
            .rest_pose = self.skeleton.rest_poses,
            .layers = &blend_layers,
        }, self.output);

        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.output,
        }, self.models);

        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        try renderer.drawPosture(self.skeleton, self.models, self.transform, true);

        if (self.show_box) {
            try renderer.drawBoxIm(bounding, self.transform, fw.color.white);
        }

        if (self.show_motion) {
            const step: f32 = 1.0 / 60.0;
            for (&self.layers) |*layer| {
                // Upstream fades each path with its blending weight; the
                // framework's `drawMotion` has no alpha parameter, so a layer
                // that contributes nothing is simply skipped instead.
                if (layer.weight <= 0) continue;
                const at = layer.controller.time_ratio;
                try fw.motion_utils.drawMotion(
                    renderer,
                    layer.motion_track,
                    at,
                    at - 1,
                    at + 1,
                    step,
                    self.transform,
                    self.frameRotation(step * layer.clip.duration()),
                );
            }
        }
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        var buffer: [64]u8 = undefined;

        if (gui.openClose("Blending parameters", true)) {
            if (gui.doCheckBox("Manual settings", &self.manual, true) and !self.manual) {
                // Leaving manual mode restarts every controller so the
                // automatic synchronization has a clean slate.
                for (&self.layers) |*layer| layer.controller.reset();
            }

            _ = gui.doSlider(
                label(&buffer, "Blend ratio: {d:.2}", .{self.blend_ratio}),
                0,
                1,
                &self.blend_ratio,
                1,
                !self.manual,
            );

            for (&self.layers, 0..) |*layer, index| {
                _ = gui.doSlider(
                    label(&buffer, "Weight {d}: {d:.2}", .{ index, layer.weight }),
                    0,
                    1,
                    &layer.weight,
                    1,
                    self.manual,
                );
            }
        }

        if (gui.openClose("Animation control", false)) {
            const titles = [layer_count][:0]const u8{
                "Animation 1",
                "Animation 2",
                "Animation 3",
            };
            for (&self.layers, titles) |*layer, title| {
                if (gui.openClose(title, true)) {
                    // Only reachable in manual mode: the automatic mode owns
                    // both the weights and the playback speeds.
                    layer.controller.onGui(gui, layer.clip.duration(), self.manual, true);
                }
            }
        }

        if (gui.openClose("Motion control", true)) {
            _ = gui.doSlider(
                label(&buffer, "Angular vel: {d:.0} deg/s", .{
                    self.angular_velocity * 180 / std.math.pi,
                }),
                -half_pi,
                half_pi,
                &self.angular_velocity,
                1,
                true,
            );
            if (gui.doButton("Teleport", true)) self.teleport();
        }

        if (gui.openClose("Motion display", true)) {
            _ = gui.doCheckBox("Show box", &self.show_box, true);
            _ = gui.doCheckBox("Show motion", &self.show_motion, true);
        }
    }

    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        return fw.utils.computePostureBounds(self.models, self.transform);
    }

    /// Restarts every layer and the character accumulator at the origin, which
    /// is what upstream's "Teleport" button does.
    pub fn teleport(self: *Sample) void {
        for (&self.layers) |*layer| {
            layer.controller.setTimeRatio(0);
            layer.motion_sampler.teleport(.identity);
        }
        self.accumulator.teleport(.identity);
    }

    /// Computes the blending weights and synchronizes the playback speeds so
    /// every layer completes its cycle at the same time.
    fn updateRuntimeParameters(self: *Sample) void {
        const weights = blendWeights(self.blend_ratio);
        for (&self.layers, weights) |*layer, weight| layer.weight = weight;

        // Interpolates the durations of the two layers framing `blend_ratio` to
        // find the cycle duration that matches it.
        const clamped = std.math.clamp(self.blend_ratio, 0, 0.999);
        const lower: usize = @intFromFloat(clamped * (layer_count - 1));
        const loop_duration =
            self.layers[lower].clip.duration() * self.layers[lower].weight +
            self.layers[lower + 1].clip.duration() * self.layers[lower + 1].weight;
        if (!(loop_duration > 0)) return;

        const inverse_loop_duration = 1 / loop_duration;
        for (&self.layers) |*layer| {
            layer.controller.playback_speed = layer.clip.duration() * inverse_loop_duration;
        }
    }

    /// Rotation to apply for `duration` seconds of steering.
    fn frameRotation(self: Sample, duration: f32) Quaternion {
        // Upstream spells this `Quaternion::FromEuler({angle, 0, 0})`, whose
        // first component is the yaw; here that is an explicit rotation about Y.
        return Quaternion.fromAxisAngle(.{ 0, 1, 0 }, self.angular_velocity * duration);
    }
};

/// Formats a zero-terminated widget label, truncating instead of failing.
fn label(buffer: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    return std.mem.printSentinel(buffer, fmt, args, 0) catch {
        buffer[buffer.len - 1] = 0;
        return buffer[0 .. buffer.len - 1 :0];
    };
}

// -----------------------------------------------------------------------------
// Tests — the whole feature path runs without a GPU.
// -----------------------------------------------------------------------------

test "blend weights follow the triangular curve" {
    try std.testing.expectEqual([layer_count]f32{ 1, 0, 0 }, blendWeights(0));
    try std.testing.expectEqual([layer_count]f32{ 0, 1, 0 }, blendWeights(0.5));
    try std.testing.expectEqual([layer_count]f32{ 0, 0, 1 }, blendWeights(1));

    // Anywhere in between exactly two layers are active and sum to one.
    for ([_]f32{ 0.1, 0.25, 0.4, 0.6, 0.75, 0.9 }) |ratio| {
        const weights = blendWeights(ratio);
        var sum: f32 = 0;
        var active: usize = 0;
        for (weights) |weight| {
            try std.testing.expect(weight >= 0);
            sum += weight;
            if (weight > 0) active += 1;
        }
        try std.testing.expectApproxEqAbs(@as(f32, 1), sum, 1e-6);
        try std.testing.expectEqual(@as(usize, 2), active);
    }

    // Out of range ratios are clamped rather than producing negative weights.
    try std.testing.expectEqual(blendWeights(0), blendWeights(-1));
    try std.testing.expectEqual(blendWeights(1), blendWeights(2));
}

test "blended motion advances and survives loops" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();
    sample.angular_velocity = 0;

    const dt: f32 = 1.0 / 60.0;
    var previous = sample.accumulator.current.translation;
    var travelled: f32 = 0;
    var loops: usize = 0;
    for (0..360) |_| {
        const before = sample.layers[0].controller.time_ratio;
        try std.testing.expect(try sample.onUpdate(dt, 0));
        if (sample.layers[0].controller.time_ratio < before) loops += 1;

        const current = sample.accumulator.current.translation;
        const step = vec.norm(vec.sub(current, previous));
        // A loop must never snap the character back to the track origin.
        try std.testing.expect(step < 0.5);
        travelled += step;
        previous = current;
    }

    try std.testing.expect(loops >= 2);
    try std.testing.expect(travelled > 1);
    try std.testing.expectApproxEqAbs(
        sample.accumulator.current.translation[2],
        sample.transform.translation()[2],
        1e-5,
    );

    sample.teleport();
    try std.testing.expectEqual(
        Vec3f32{ 0, 0, 0 },
        sample.accumulator.current.translation,
    );
    for (&sample.layers) |*layer| {
        try std.testing.expectEqual(@as(f32, 0), layer.controller.time_ratio);
    }
}

test "a higher blend ratio travels further" {
    const allocator = std.testing.allocator;

    var distances: [3]f32 = undefined;
    for ([_]f32{ 0, 0.5, 1 }, &distances) |ratio, *distance| {
        var sample = try Sample.init(allocator, .{});
        defer sample.deinit();
        sample.blend_ratio = ratio;
        sample.angular_velocity = 0;

        const dt: f32 = 1.0 / 60.0;
        for (0..180) |_| _ = try sample.onUpdate(dt, 0);
        distance.* = vec.norm(sample.accumulator.current.translation);

        // Automatic synchronization keeps every layer in phase.
        const reference = sample.layers[0].controller.time_ratio;
        for (sample.layers[1..]) |layer| {
            try std.testing.expectApproxEqAbs(reference, layer.controller.time_ratio, 1e-3);
        }
    }

    // Walking covers less ground than jogging, which covers less than running.
    try std.testing.expect(distances[0] < distances[1]);
    try std.testing.expect(distances[1] < distances[2]);
}

test "layer weights follow the blend ratio and drive the motion blend" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();
    sample.blend_ratio = 0;
    _ = try sample.onUpdate(1.0 / 60.0, 0);

    try std.testing.expectEqual(@as(f32, 1), sample.layers[0].weight);
    try std.testing.expectEqual(@as(f32, 0), sample.layers[1].weight);
    try std.testing.expectEqual(@as(f32, 0), sample.layers[2].weight);

    // With a single active layer the blended delta is that layer's own delta.
    const blended = ozz.animation.blendMotion(&.{
        .{ .delta = sample.layers[0].motion_sampler.delta(), .weight = 1 },
        .{ .delta = sample.layers[1].motion_sampler.delta(), .weight = 0 },
        .{ .delta = sample.layers[2].motion_sampler.delta(), .weight = 0 },
    });
    try std.testing.expectApproxEqAbs(
        vec.norm(sample.layers[0].motion_sampler.delta().translation),
        vec.norm(blended.translation),
        1e-6,
    );

    // Manual mode leaves the weights alone.
    sample.manual = true;
    sample.layers[2].weight = 0.75;
    _ = try sample.onUpdate(1.0 / 60.0, 0);
    try std.testing.expectEqual(@as(f32, 0.75), sample.layers[2].weight);
}

test "steering curves the blended path" {
    const allocator = std.testing.allocator;
    var straight = try Sample.init(allocator, .{});
    defer straight.deinit();
    straight.angular_velocity = 0;

    var curved = try Sample.init(allocator, .{});
    defer curved.deinit();
    curved.angular_velocity = std.math.pi / 2.0;

    const dt: f32 = 1.0 / 60.0;
    for (0..120) |_| {
        _ = try straight.onUpdate(dt, 0);
        _ = try curved.onUpdate(dt, 0);
    }
    try std.testing.expect(vec.norm(vec.sub(
        straight.accumulator.current.translation,
        curved.accumulator.current.translation,
    )) > 0.1);
}

test "an inert gui leaves every option untouched" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    var gui = fw.Im.init(false);
    sample.onGui(&gui);
    try std.testing.expectEqual(@as(f32, 0.3), sample.blend_ratio);
    try std.testing.expect(!sample.manual);
    try std.testing.expect(sample.show_motion);
}
