// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/playback/sample_playback.cc`.
//!
//! Loads a skeleton and an animation from ozz binary archives, samples the
//! animation every frame (`ozz.animation.sample`), converts the local-space
//! result to model-space matrices (`ozz.animation.localToModel`) and renders the
//! resulting posture. This is the smallest complete runtime pipeline; every
//! other sample builds on it.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

pub const name = "playback";
pub const description = "Animation playback";

/// Upstream's `media/skeleton.ozz`, replaceable with `--skeleton=`.
const default_skeleton = @embedFile("pab_skeleton");
/// Upstream's `media/animation.ozz`, replaceable with `--animation=`.
const default_animation = @embedFile("pab_walk");

pub const Sample = struct {
    allocator: std.mem.Allocator,

    /// Utility that owns playback time, speed, loop and pause.
    controller: fw.PlaybackController = .{},

    /// Runtime skeleton.
    skeleton: ozz.animation.Skeleton,

    /// Runtime animation, its sampling context and its local-space output.
    clip: fw.utils.Clip,

    /// Model-space matrices, the output of the local-to-model stage.
    models: []ozz.math.Float4x4,

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(default_skeleton),
        );
        errdefer skeleton.deinit();

        var clip = try fw.utils.Clip.decode(
            allocator,
            assets.animationOr(default_animation),
        );
        errdefer clip.deinit();

        // Skeleton and animation need to match, exactly like `OnInitialize`.
        if (skeleton.numJoints() != clip.animation.numTracks()) {
            return error.SkeletonAnimationMismatch;
        }

        const models = try allocator.alloc(ozz.math.Float4x4, skeleton.numJoints());
        errdefer allocator.free(models);

        // The application may frame the camera from `sceneBounds` before the
        // first `onUpdate`, so the rest pose seeds the model-space buffer.
        try ozz.animation.localToModel(.{
            .skeleton = &skeleton,
            .input = skeleton.rest_poses,
        }, models);

        return .{
            .allocator = allocator,
            .skeleton = skeleton,
            .clip = clip,
            .models = models,
        };
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.models);
        self.clip.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    /// Advances animation time, samples it and converts the pose to model space.
    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;

        // Updates current animation time.
        _ = self.controller.update(self.clip.duration(), dt);

        // Samples the animation at t = time_ratio.
        try self.clip.sample(self.controller.time_ratio);

        // Converts from local space to model space matrices.
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.clip.pose,
        }, self.models);

        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        try renderer.drawPosture(self.skeleton, self.models, .identity, true);
    }

    /// Exposes animation runtime playback controls: play/pause, loop, time and
    /// playback speed (which may be negative to play backwards).
    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        if (gui.openClose("Animation control", true)) {
            self.controller.onGui(gui, self.clip.duration(), true, true);
        }
    }

    /// `GetSceneBounds`: the camera auto-frames the animated posture.
    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        const box = fw.utils.computePostureBounds(self.models, null);
        return if (box.isValid()) box else null;
    }
};

// -----------------------------------------------------------------------------
// Tests. GPU-free: `init`, `onUpdate` and `onGui` never touch the renderer.
// -----------------------------------------------------------------------------

test "playback samples the animation and moves the posture" {
    var sample = try Sample.init(std.testing.allocator, .{});
    defer sample.deinit();

    try std.testing.expectEqual(
        sample.skeleton.numJoints(),
        sample.clip.animation.numTracks(),
    );
    try std.testing.expect(sample.clip.duration() > 0);

    const rest = try std.testing.allocator.dupe(ozz.math.Float4x4, sample.models);
    defer std.testing.allocator.free(rest);

    // A few steps at 60Hz.
    for (0..3) |_| try std.testing.expect(try sample.onUpdate(1.0 / 60.0, 0));

    // Time advanced by dt / duration per step.
    try std.testing.expectApproxEqAbs(
        3 * (1.0 / 60.0) / sample.clip.duration(),
        sample.controller.time_ratio,
        1e-5,
    );

    // And the joints actually moved away from the rest pose.
    var moved = false;
    for (rest, sample.models) |before, after| {
        if (@reduce(.Or, before.translation() != after.translation())) moved = true;
    }
    try std.testing.expect(moved);
}

test "playback publishes posture bounds and honours the controller" {
    var sample = try Sample.init(std.testing.allocator, .{});
    defer sample.deinit();

    _ = try sample.onUpdate(0.1, 0);
    const box = sample.sceneBounds() orelse return error.MissingBounds;
    try std.testing.expect(box.isValid());
    for (sample.models) |model| try std.testing.expect(box.contains(model.translation()));

    // Pausing freezes time, and the loop wraps back into the unit interval.
    sample.controller.play = false;
    const frozen = sample.controller.time_ratio;
    _ = try sample.onUpdate(0.5, 0);
    try std.testing.expectEqual(frozen, sample.controller.time_ratio);

    sample.controller.play = true;
    _ = try sample.onUpdate(sample.clip.duration() * 2, 0);
    try std.testing.expect(sample.controller.time_ratio >= 0);
    try std.testing.expect(sample.controller.time_ratio <= 1);

    // The gui path is inert without ImGui and must not touch the renderer.
    var gui = fw.Im.init(false);
    sample.onGui(&gui);
}
