// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/blend/sample_blend.cc`.
//!
//! Composition blending: three locomotion clips (walk, jog, run) are blended
//! into a single pose driven by one "blend ratio" (aka speed) coefficient. Two
//! things make the result usable, and both are the point of the sample:
//!
//! - the weight curve, a hat function per layer so the ratio walks from the
//!   first clip to the last through the intermediate one, and
//! - playback-speed synchronization, which stretches every clip onto a common
//!   loop duration so foot steps stay in sync while they are blended.
//!
//! A manual mode bypasses both and exposes the per-layer weights and speeds.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

pub const name = "blend";
pub const description = "Animation blending";

/// Upstream's `media/skeleton.ozz`, replaceable with `--skeleton=`.
const default_skeleton = @embedFile("pab_skeleton");
/// Upstream's `media/animation1.ozz`, replaceable with `--animation=`.
const default_animation1 = @embedFile("pab_walk");
/// Upstream's `media/animation2.ozz`.
const default_animation2 = @embedFile("pab_jog");
/// Upstream's `media/animation3.ozz`.
const default_animation3 = @embedFile("pab_run");

/// The number of layers to blend.
const num_layers = 3;

/// `ozz::animation::BlendingJob().threshold`, the rest-pose fallback threshold.
const default_threshold: f32 = blk: {
    const defaults: ozz.animation.BlendOptions = .{ .rest_pose = &.{}, .layers = &.{} };
    break :blk defaults.threshold;
};

/// Everything required to sample a single animation and weight it in the blend.
const Sampler = struct {
    /// Playback time, speed, loop and pause for this clip.
    controller: fw.PlaybackController = .{},
    /// Blending weight for the layer.
    weight: f32 = 1,
    /// Runtime animation, sampling context and local-space output.
    clip: fw.utils.Clip,
};

pub const Sample = struct {
    allocator: std.mem.Allocator,

    /// Runtime skeleton.
    skeleton: ozz.animation.Skeleton,

    /// The `num_layers` animations to blend.
    samplers: [num_layers]Sampler,

    /// Global blend ratio in range [0, 1] that controls all blend parameters and
    /// synchronizes playback speeds. 0 gives full weight to the first animation,
    /// 1 to the last.
    blend_ratio: f32 = 0.3,

    /// Switch to manual control of animations and blending parameters.
    manual: bool = false,

    /// Blending job rest pose threshold.
    threshold: f32 = default_threshold,

    /// Buffer of local transforms which stores the blending result.
    locals: []ozz.math.SoaTransform,

    /// Model-space matrices, computed after the blending stage.
    models: []ozz.math.Float4x4,

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(default_skeleton),
        );
        errdefer skeleton.deinit();

        // Only `--animation=` exists in the framework's asset overrides, so it
        // replaces the first clip; upstream has one flag per layer.
        const archives = [num_layers][]const u8{
            assets.animationOr(default_animation1),
            default_animation2,
            default_animation3,
        };

        var samplers: [num_layers]Sampler = undefined;
        var loaded: usize = 0;
        errdefer for (samplers[0..loaded]) |*sampler| sampler.clip.deinit();
        for (&samplers, archives) |*sampler, archive| {
            sampler.* = .{ .clip = try fw.utils.Clip.decode(allocator, archive) };
            loaded += 1;
            if (skeleton.numJoints() != sampler.clip.animation.numTracks()) {
                return error.SkeletonAnimationMismatch;
            }
        }

        const locals = try allocator.alloc(ozz.math.SoaTransform, skeleton.numSoaJoints());
        errdefer allocator.free(locals);
        @memcpy(locals, skeleton.rest_poses);

        const models = try allocator.alloc(ozz.math.Float4x4, skeleton.numJoints());
        errdefer allocator.free(models);

        // Seeds the model-space buffer so `sceneBounds` is usable before the
        // first update.
        try ozz.animation.localToModel(.{
            .skeleton = &skeleton,
            .input = locals,
        }, models);

        return .{
            .allocator = allocator,
            .skeleton = skeleton,
            .samplers = samplers,
            .locals = locals,
            .models = models,
        };
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.models);
        self.allocator.free(self.locals);
        for (&self.samplers) |*sampler| sampler.clip.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    /// Computes the blending weights and synchronizes playback speeds when the
    /// "manual" option is off (`UpdateRuntimeParameters`).
    pub fn updateRuntimeParameters(self: *Sample) void {
        // Computes weight parameters for all samplers: a hat function centred on
        // each layer's own ratio, `1 / intervals` wide on both sides.
        const intervals: f32 = num_layers - 1;
        const interval = 1 / intervals;
        for (&self.samplers, 0..) |*sampler, index| {
            const med = @as(f32, @floatFromInt(index)) * interval;
            const x = self.blend_ratio - med;
            const y = ((if (x < 0) x else -x) + interval) * intervals;
            sampler.weight = @max(0, y);
        }

        // Selects the 2 samplers that define the interval containing the ratio.
        const clamped_ratio = std.math.clamp(self.blend_ratio, 0, 0.999);
        const lower: usize = @intFromFloat(clamped_ratio * intervals);
        const sampler_l = &self.samplers[lower];
        const sampler_r = &self.samplers[lower + 1];

        // Interpolates animation durations using their respective weights, to
        // find the loop cycle duration that matches the blend ratio.
        const loop_duration =
            sampler_l.clip.duration() * sampler_l.weight +
            sampler_r.clip.duration() * sampler_r.weight;

        // Upstream divides unconditionally; guarding keeps a degenerate clip
        // from turning every playback speed into a NaN.
        if (!(loop_duration > 0)) return;

        // Finally finds the speed coefficient for all samplers.
        const inv_loop_duration = 1 / loop_duration;
        for (&self.samplers) |*sampler| {
            sampler.controller.playback_speed = sampler.clip.duration() * inv_loop_duration;
        }
    }

    /// Samples every layer, blends them and converts the result to model space.
    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;

        // Updates blending parameters and synchronizes animations if the control
        // mode is not manual.
        if (!self.manual) self.updateRuntimeParameters();

        // Updates and samples all animations to their respective local space
        // transform buffers.
        for (&self.samplers) |*sampler| {
            _ = sampler.controller.update(sampler.clip.duration(), dt);

            // Early out if this sampler weight makes it irrelevant during
            // blending; the blend skips zero-weight layers as well.
            if (sampler.weight <= 0) continue;

            try sampler.clip.sample(sampler.controller.time_ratio);
        }

        // Prepares blending layers.
        var layers: [num_layers]ozz.animation.BlendLayer = undefined;
        for (&layers, &self.samplers) |*layer, *sampler| {
            layer.* = .{ .transforms = sampler.clip.pose, .weight = sampler.weight };
        }

        // Blends, falling back to the rest pose below `threshold`.
        try ozz.animation.blend(.{
            .rest_pose = self.skeleton.rest_poses,
            .layers = &layers,
            .threshold = self.threshold,
        }, self.locals);

        // Converts the blended local space transforms to model space matrices.
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.locals,
        }, self.models);

        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        try renderer.drawPosture(self.skeleton, self.models, .identity, true);
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        var buffer: [64]u8 = undefined;

        // Exposes blending parameters.
        if (gui.openClose("Blending parameters", true)) {
            if (gui.doCheckBox("Manual settings", &self.manual, true) and !self.manual) {
                // Check-box state was changed, reset parameters.
                for (&self.samplers) |*sampler| sampler.controller.reset();
            }

            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "Blend ratio: {d:.2}###blend_ratio", .{self.blend_ratio}),
                0,
                1,
                &self.blend_ratio,
                1,
                !self.manual,
            );

            for (&self.samplers, 0..) |*sampler, index| {
                _ = gui.doSlider(
                    fw.im.formatZ(
                        &buffer,
                        "Weight {0d}: {1d:.2}###weight{0d}",
                        .{ index, sampler.weight },
                    ),
                    0,
                    1,
                    &sampler.weight,
                    1,
                    self.manual,
                );
            }

            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "Threshold: {d:.2}###threshold", .{self.threshold}),
                0.01,
                1,
                &self.threshold,
                1,
                true,
            );
        }

        // Exposes animations runtime playback controls. They are only editable
        // in manual mode, since synchronization owns the playback speed
        // otherwise.
        if (gui.openClose("Animation control", true)) {
            const titles = [num_layers][:0]const u8{
                "Animation 1",
                "Animation 2",
                "Animation 3",
            };
            for (&self.samplers, titles, 0..) |*sampler, title, index| {
                if (!gui.openClose(title, true)) continue;
                gui.pushId(index);
                defer gui.popId();
                sampler.controller.onGui(gui, sampler.clip.duration(), self.manual, true);
            }
        }
    }

    /// `GetSceneBounds`: the camera auto-frames the blended posture.
    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        const box = fw.utils.computePostureBounds(self.models, null);
        return if (box.isValid()) box else null;
    }
};

// -----------------------------------------------------------------------------
// Tests. GPU-free: `init`, `onUpdate` and `onGui` never touch the renderer.
// -----------------------------------------------------------------------------

test "the weight curve is a partition of unity over the blend ratio" {
    var sample = try Sample.init(std.testing.allocator, .{});
    defer sample.deinit();

    var ratio: f32 = 0;
    while (ratio <= 1.0001) : (ratio += 0.05) {
        sample.blend_ratio = ratio;
        sample.updateRuntimeParameters();

        var total: f32 = 0;
        var non_zero: usize = 0;
        for (sample.samplers) |sampler| {
            try std.testing.expect(sampler.weight >= 0);
            try std.testing.expect(sampler.weight <= 1.0001);
            total += sampler.weight;
            if (sampler.weight > 0) non_zero += 1;
        }
        // At most two neighbouring layers contribute at any ratio.
        try std.testing.expect(non_zero <= 2);
        try std.testing.expectApproxEqAbs(@as(f32, 1), total, 1e-5);
    }

    // The extremes select a single clip each.
    sample.blend_ratio = 0;
    sample.updateRuntimeParameters();
    try std.testing.expectApproxEqAbs(@as(f32, 1), sample.samplers[0].weight, 1e-6);
    try std.testing.expectEqual(@as(f32, 0), sample.samplers[2].weight);

    sample.blend_ratio = 1;
    sample.updateRuntimeParameters();
    try std.testing.expectEqual(@as(f32, 0), sample.samplers[0].weight);
    try std.testing.expectApproxEqAbs(@as(f32, 1), sample.samplers[2].weight, 1e-6);
}

test "playback speeds synchronize the loop durations" {
    var sample = try Sample.init(std.testing.allocator, .{});
    defer sample.deinit();

    // Halfway between walk and jog: both clips must take the same wall-clock
    // time to complete one loop.
    sample.blend_ratio = 0.25;
    sample.updateRuntimeParameters();

    const loop_0 = sample.samplers[0].clip.duration() /
        sample.samplers[0].controller.playback_speed;
    const loop_1 = sample.samplers[1].clip.duration() /
        sample.samplers[1].controller.playback_speed;
    try std.testing.expectApproxEqAbs(loop_0, loop_1, 1e-4);

    // That common duration is the weighted mix of the two active clips.
    const expected = sample.samplers[0].clip.duration() * sample.samplers[0].weight +
        sample.samplers[1].clip.duration() * sample.samplers[1].weight;
    try std.testing.expectApproxEqAbs(expected, loop_0, 1e-4);

    // A ratio in the upper half picks the jog/run pair instead.
    sample.blend_ratio = 0.75;
    sample.updateRuntimeParameters();
    const upper = sample.samplers[1].clip.duration() * sample.samplers[1].weight +
        sample.samplers[2].clip.duration() * sample.samplers[2].weight;
    try std.testing.expectApproxEqAbs(
        upper,
        sample.samplers[2].clip.duration() / sample.samplers[2].controller.playback_speed,
        1e-4,
    );
}

test "blending three clips produces a moving posture" {
    var sample = try Sample.init(std.testing.allocator, .{});
    defer sample.deinit();

    const rest = try std.testing.allocator.dupe(ozz.math.Float4x4, sample.models);
    defer std.testing.allocator.free(rest);

    for (0..4) |_| try std.testing.expect(try sample.onUpdate(1.0 / 60.0, 0));

    var moved = false;
    for (rest, sample.models) |before, after| {
        if (@reduce(.Or, before.translation() != after.translation())) moved = true;
    }
    try std.testing.expect(moved);

    const box = sample.sceneBounds() orelse return error.MissingBounds;
    try std.testing.expect(box.isValid());

    // Manual mode leaves the weights and speeds exactly where the user put them.
    sample.manual = true;
    sample.samplers[0].weight = 1;
    sample.samplers[1].weight = 0;
    sample.samplers[2].weight = 0;
    sample.samplers[0].controller.playback_speed = 2;
    _ = try sample.onUpdate(1.0 / 60.0, 0);
    try std.testing.expectEqual(@as(f32, 1), sample.samplers[0].weight);
    try std.testing.expectEqual(@as(f32, 0), sample.samplers[2].weight);
    try std.testing.expectEqual(@as(f32, 2), sample.samplers[0].controller.playback_speed);

    // With a single layer at full weight the blend must reproduce that clip.
    for (sample.samplers[0].clip.pose, sample.locals) |source, blended| {
        try std.testing.expectApproxEqAbs(
            ozz.math.lane(source.translation.y, 0),
            ozz.math.lane(blended.translation.y, 0),
            1e-4,
        );
    }

    // The gui path is inert without ImGui and must not touch the renderer.
    var gui = fw.Im.init(false);
    sample.onGui(&gui);
}
