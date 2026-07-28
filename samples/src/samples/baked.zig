// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/baked/sample_baked.cc`.
//!
//! A physics simulation baked into an animation: the scene's >1000 cuboids were
//! imported as skeleton joints, so replaying the animation replays the
//! simulation. Every joint is drawn as a unit cube, and the animation's scale
//! track restores each cuboid's original size. The scene's camera is a joint
//! too, and its matrix is forwarded to the framework camera.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Float4x4 = ozz.math.Float4x4;

pub const name = "baked";
pub const description = "Baked simulation playback";

/// Half-extent of the unit cube drawn for every joint (upstream's `size`).
const cube_half_size: f32 = 0.5;

pub const Sample = struct {
    allocator: std.mem.Allocator,
    /// Runtime skeleton: one joint per simulated rigid body, plus the camera.
    skeleton: ozz.animation.Skeleton,
    /// Runtime animation plus its sampling context and local-space output.
    clip: fw.utils.Clip,
    /// Model-space matrices, one per joint. Each carries the joint's animated
    /// scale, which is what restores the original cuboid size.
    models: []Float4x4,
    /// Animation playback time / speed / loop control.
    controller: fw.PlaybackController = .{},
    /// Index of the joint named "camera", null when the scene has none.
    camera_joint: ?usize = null,
    /// Whether the baked camera drives the view.
    animated_camera: bool = true,

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(@embedFile("baked_skeleton")),
        );
        errdefer skeleton.deinit();

        var clip = try fw.utils.Clip.decode(
            allocator,
            assets.animationOr(@embedFile("baked_animation")),
        );
        errdefer clip.deinit();

        if (skeleton.numJoints() != clip.animation.numTracks()) {
            return error.SkeletonAnimationMismatch;
        }

        const models = try allocator.alloc(Float4x4, skeleton.numJoints());
        errdefer allocator.free(models);

        var self: Sample = .{
            .allocator = allocator,
            .skeleton = skeleton,
            .clip = clip,
            .models = models,
            // Upstream scans for the first joint whose name contains "camera".
            .camera_joint = fw.utils.findJointContaining(skeleton, "camera"),
        };
        // Rest pose, so the first `sceneBounds` / `cameraOverride` are valid.
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.skeleton.rest_poses,
        }, self.models);
        return self;
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.models);
        self.clip.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;
        _ = self.controller.update(self.clip.duration(), dt);
        try self.clip.sample(self.controller.time_ratio);
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.clip.pose,
        }, self.models);
        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        // One instanced draw for the whole scene: a unit cube per joint,
        // scaled and placed by that joint's model-space matrix.
        try renderer.drawBoxShaded(cubeBox(), self.models, fw.color.white);
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        if (gui.openClose("Animation control", true)) {
            self.controller.onGui(gui, self.clip.duration(), true, true);
        }

        if (gui.openClose("Baked scene", true)) {
            gui.doLabel("{d} rigid bodies", .{self.models.len});
            if (self.camera_joint) |joint| {
                gui.doLabel("camera joint: {s} ({d})", .{ self.skeleton.names[joint], joint });
                _ = gui.doCheckBox("Animated camera", &self.animated_camera, true);
            } else {
                gui.doLabel("no camera joint in the scene", .{});
            }
        }
    }

    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        return fw.utils.computePostureBounds(self.models, null);
    }

    /// Forwards the baked camera joint's matrix to the framework camera
    /// (`GetCameraOverride`). Null hands control back to the user.
    pub fn cameraOverride(self: *Sample) ?Float4x4 {
        if (!self.animated_camera) return null;
        const joint = self.camera_joint orelse return null;
        return self.models[joint];
    }

    // -- feature path -------------------------------------------------------

    /// The unit cube every joint is drawn with. The joint matrix supplies the
    /// scale, so the box itself is always 1m wide.
    pub fn cubeBox() ozz.math.Box {
        return .{
            .min = @splat(-cube_half_size),
            .max = @splat(cube_half_size),
        };
    }
};

/// Length of a matrix column, i.e. the scale the joint applies on that axis.
fn axisScale(matrix: Float4x4, axis: usize) f32 {
    const column = matrix.cols[axis];
    return @sqrt(column[0] * column[0] + column[1] * column[1] + column[2] * column[2]);
}

test "the baked scene is a large flat list of animated rigid bodies" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    // The README advertises "more than 1000 cuboids".
    try std.testing.expect(sample.models.len > 1000);
    // There is no real hierarchy in a baked scene: the objects are roots.
    var roots: usize = 0;
    for (sample.skeleton.parents) |parent| {
        if (parent == ozz.animation.no_parent) roots += 1;
    }
    try std.testing.expect(roots > 1000);
    try std.testing.expect(sample.clip.duration() > 0);
}

test "the scale track drives the cube size" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();
    try std.testing.expect(try sample.onUpdate(0.5, 0.5));

    var scaled: usize = 0;
    for (sample.models) |model| {
        for (0..3) |axis| {
            const scale = axisScale(model, axis);
            try std.testing.expect(std.math.isFinite(scale));
            if (@abs(scale - 1) > 1e-3) scaled += 1;
        }
    }
    // Cuboids of different sizes are the whole point of the scale track.
    try std.testing.expect(scaled > 100);

    const box = Sample.cubeBox();
    try std.testing.expectEqual(@as(f32, -0.5), box.min[0]);
    try std.testing.expectEqual(@as(f32, 0.5), box.max[0]);
}

test "the camera joint drives the camera override" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    const joint = sample.camera_joint orelse return error.MissingCameraJoint;
    try std.testing.expect(fw.utils.containsIgnoreCase(sample.skeleton.names[joint], "camera"));

    try std.testing.expect(try sample.onUpdate(0.25, 0.25));
    const override = sample.cameraOverride() orelse return error.MissingCameraOverride;
    try std.testing.expectEqual(sample.models[joint].cols, override.cols);

    // The animation moves the camera.
    const before = override.translation();
    try std.testing.expect(try sample.onUpdate(0.5, 0.75));
    try std.testing.expect(@reduce(.Or, before != sample.cameraOverride().?.translation()));

    sample.animated_camera = false;
    try std.testing.expectEqual(@as(?Float4x4, null), sample.cameraOverride());
}

test "posture bounds cover the whole scene" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();
    try std.testing.expect(try sample.onUpdate(1.0 / 60.0, 0));

    const bounds = sample.sceneBounds().?;
    try std.testing.expect(bounds.isValid());
    for (sample.models) |model| {
        try std.testing.expect(bounds.contains(model.translation()));
    }
}
