// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/partial_blend/sample_partial_blend.cc`.
//!
//! Partial blending animates the lower and the upper part of the skeleton with
//! two different clips. It is the same `ozz.animation.blend` as the "blend"
//! sample, with one addition: every layer carries a per-joint weight mask, an
//! SoA array of `Vec4f32` in skeleton joint order, which modulates the layer
//! weight joint by joint.
//!
//! The masks are built by walking the sub-tree of a selectable "upper body root"
//! joint with `ozz.animation.iterateJointsDF`. The two masks hold opposed values
//! so each layer selects exactly the joints the other one rejects.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const quat = ozz.math.quat;
const fw = @import("framework");

pub const name = "partial_blend";
pub const description = "Per-joint partial blending";

/// Upstream's `media/skeleton.ozz`, replaceable with `--skeleton=`.
const default_skeleton = @embedFile("pab_skeleton");
/// Upstream's `media/animation_base.ozz`, replaceable with `--animation=`.
const default_lower_body_animation = @embedFile("pab_walk");
/// Upstream's `media/animation_partial.ozz`.
const default_upper_body_animation = @embedFile("pab_crossarms");

/// The layer whose mask covers everything outside the upper body sub-tree.
const lower_body = 0;
/// The layer whose mask covers the upper body sub-tree.
const upper_body = 1;
/// The number of layers to blend.
const num_layers = 2;

/// `ozz::animation::BlendingJob().threshold`, the rest-pose fallback threshold.
const default_threshold: f32 = blk: {
    const defaults: ozz.animation.BlendOptions = .{ .rest_pose = &.{}, .layers = &.{} };
    break :blk defaults.threshold;
};

/// Everything required to sample one animation and mask it into the blend.
const Sampler = struct {
    /// Playback time, speed, loop and pause for this clip.
    controller: fw.PlaybackController = .{},
    /// Blending weight of the whole layer.
    weight_setting: f32 = 1,
    /// Weight given to the joints this layer's mask selects.
    joint_weight_setting: f32 = 1,
    /// Runtime animation, sampling context and local-space output.
    clip: fw.utils.Clip,
    /// Per-joint weights defining the partial animation mask. Soa structure:
    /// one `Vec4f32` per four joints, in skeleton order.
    joint_weights: []ozz.math.Vec4f32,
};

/// Visitor handed to `iterateJointsDF`, writing one weight per visited joint
/// into the SoA mask (upstream's `WeightSetupIterator`).
const WeightSetupIterator = struct {
    weights: []ozz.math.Vec4f32,
    weight_setting: f32,

    pub fn visit(self: WeightSetupIterator, joint: usize, parent: i16) void {
        _ = parent;
        ozz.math.setLane(&self.weights[joint / 4], joint % 4, self.weight_setting);
    }
};

pub const Sample = struct {
    allocator: std.mem.Allocator,

    /// Runtime skeleton.
    skeleton: ozz.animation.Skeleton,

    /// The lower and upper body layers.
    samplers: [num_layers]Sampler,

    /// Index of the joint at the base of the upper body hierarchy.
    upper_body_root: i32 = 0,

    /// Derives every blending parameter from `upper_body_weight`.
    automatic: bool = true,

    /// Single coefficient driving both masks in automatic mode: all power to
    /// the partial (upper body) animation at 1.
    upper_body_weight: f32 = 1,

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
        const soa_joints = skeleton.numSoaJoints();

        // Only `--animation=` exists in the framework's asset overrides, so it
        // replaces the lower body clip; upstream has one flag per layer.
        const archives = [num_layers][]const u8{
            assets.animationOr(default_lower_body_animation),
            default_upper_body_animation,
        };

        var samplers: [num_layers]Sampler = undefined;
        var loaded: usize = 0;
        errdefer for (samplers[0..loaded]) |*sampler| {
            allocator.free(sampler.joint_weights);
            sampler.clip.deinit();
        };
        for (&samplers, archives) |*sampler, archive| {
            var clip = try fw.utils.Clip.decode(allocator, archive);
            // Ownership only moves into `samplers` once the sampler is fully
            // built, so exactly one of the two errdefers can ever free a clip.
            errdefer clip.deinit();
            if (skeleton.numJoints() != clip.animation.numTracks()) {
                return error.SkeletonAnimationMismatch;
            }
            const joint_weights = try allocator.alloc(ozz.math.Vec4f32, soa_joints);
            sampler.* = .{ .clip = clip, .joint_weights = joint_weights };
            loaded += 1;
        }

        // Default weight settings: both layers fully active, the lower body one
        // rejecting the upper body sub-tree and vice versa.
        samplers[lower_body].weight_setting = 1;
        samplers[lower_body].joint_weight_setting = 0;
        samplers[upper_body].weight_setting = 1;
        samplers[upper_body].joint_weight_setting = 1;

        const locals = try allocator.alloc(ozz.math.SoaTransform, soa_joints);
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

        // Finds the "Spine1" joint in the joint hierarchy.
        const root = fw.utils.findNamedJoint(skeleton, &.{"Spine1"}) orelse
            return error.MissingUpperBodyRoot;

        var sample: Sample = .{
            .allocator = allocator,
            .skeleton = skeleton,
            .samplers = samplers,
            .upper_body_root = @intCast(root),
            .locals = locals,
            .models = models,
        };
        sample.setupPerJointWeights();
        return sample;
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.models);
        self.allocator.free(self.locals);
        for (&self.samplers) |*sampler| {
            self.allocator.free(sampler.joint_weights);
            sampler.clip.deinit();
        }
        self.skeleton.deinit();
        self.* = undefined;
    }

    /// The upper body root, clamped into the skeleton (the gui slider and the
    /// `i32` storage both allow out-of-range values).
    pub fn upperBodyRoot(self: Sample) usize {
        const joint_count = self.skeleton.numJoints();
        if (joint_count == 0) return 0;
        const clamped = std.math.clamp(self.upper_body_root, 0, @as(i32, @intCast(joint_count - 1)));
        return @intCast(clamped);
    }

    /// Sets up the partial animation masks: a weight per joint, 0 for the
    /// joints a layer must ignore and 1 (scaled by the layer's joint weight
    /// setting) for those it drives. Lower and upper body masks hold opposed
    /// values so a layer selects the joints the other one rejects.
    pub fn setupPerJointWeights(self: *Sample) void {
        // Disables all joints of the upper body layer, enables all of the lower
        // body one.
        @memset(self.samplers[lower_body].joint_weights, @splat(1));
        @memset(self.samplers[upper_body].joint_weights, @splat(0));

        // Sets the weight setting of all the joints children of the upper body
        // root. Note that they are stored in SoA format.
        const root = self.upperBodyRoot();
        ozz.animation.iterateJointsDF(self.skeleton, root, WeightSetupIterator{
            .weights = self.samplers[lower_body].joint_weights,
            .weight_setting = self.samplers[lower_body].joint_weight_setting,
        });
        ozz.animation.iterateJointsDF(self.skeleton, root, WeightSetupIterator{
            .weights = self.samplers[upper_body].joint_weights,
            .weight_setting = self.samplers[upper_body].joint_weight_setting,
        });
    }

    /// Forces the blending values in automatic mode: the upper body weight
    /// drives both masks, the lower body getting one minus that coefficient.
    fn applyAutomaticSettings(self: *Sample) void {
        if (!self.automatic) return;
        self.samplers[lower_body].weight_setting = 1;
        self.samplers[lower_body].joint_weight_setting = 1 - self.upper_body_weight;
        self.samplers[upper_body].weight_setting = 1;
        self.samplers[upper_body].joint_weight_setting = self.upper_body_weight;
    }

    /// Samples both clips at their own speed (they do not need to be
    /// synchronized), blends them through their masks and converts the result
    /// to model space.
    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;

        // Upstream refreshes the settings and the masks from `OnGui`; doing it
        // here instead keeps the feature path identical without a gui.
        self.applyAutomaticSettings();
        self.setupPerJointWeights();

        // Updates and samples both animations to their respective local space
        // transform buffers.
        for (&self.samplers) |*sampler| {
            _ = sampler.controller.update(sampler.clip.duration(), dt);
            try sampler.clip.sample(sampler.controller.time_ratio);
        }

        // Prepares blending layers, with per-joint weights for both partially
        // blended layers.
        var layers: [num_layers]ozz.animation.BlendLayer = undefined;
        for (&layers, &self.samplers) |*layer, *sampler| {
            layer.* = .{
                .transforms = sampler.clip.pose,
                .weight = sampler.weight_setting,
                .joint_weights = sampler.joint_weights,
            };
        }

        try ozz.animation.blend(.{
            .rest_pose = self.skeleton.rest_poses,
            .layers = &layers,
            .threshold = self.threshold,
        }, self.locals);

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
        var buffer: [96]u8 = undefined;

        // Exposes blending parameters.
        if (gui.openClose("Blending parameters", true)) {
            _ = gui.doCheckBox("Use automatic blending settings", &self.automatic, true);

            _ = gui.doSlider(
                fw.im.formatZ(
                    &buffer,
                    "Upper body weight: {d:.2}###upper_body_weight",
                    .{self.upper_body_weight},
                ),
                0,
                1,
                &self.upper_body_weight,
                1,
                self.automatic,
            );

            // Automatic mode owns the four settings below; applying it here as
            // well keeps the sliders showing the values that will be used.
            self.applyAutomaticSettings();

            gui.doLabel("Manual settings:", .{});
            const titles = [num_layers][]const u8{ "Lower body layer:", "Upper body layer:" };
            for (&self.samplers, titles, 0..) |*sampler, title, index| {
                gui.doLabel("{s}", .{title});
                gui.pushId(index);
                defer gui.popId();
                _ = gui.doSlider(
                    fw.im.formatZ(
                        &buffer,
                        "Layer weight: {d:.2}###weight_setting",
                        .{sampler.weight_setting},
                    ),
                    0,
                    1,
                    &sampler.weight_setting,
                    1,
                    !self.automatic,
                );
                _ = gui.doSlider(
                    fw.im.formatZ(
                        &buffer,
                        "Joints weight: {d:.2}###joint_weight_setting",
                        .{sampler.joint_weight_setting},
                    ),
                    0,
                    1,
                    &sampler.joint_weight_setting,
                    1,
                    !self.automatic,
                );
            }

            gui.doLabel("Global settings:", .{});
            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "Threshold: {d:.2}###threshold", .{self.threshold}),
                0.01,
                1,
                &self.threshold,
                1,
                true,
            );

            self.setupPerJointWeights();
        }

        // Exposes selection of the root of the partial blending hierarchy.
        if (gui.openClose("Root", true) and self.skeleton.numJoints() != 0) {
            gui.doLabel("Root of the upper body hierarchy:", .{});
            const root = self.upperBodyRoot();
            if (gui.doSliderInt(
                fw.im.formatZ(&buffer, "{s} ({d})###upper_body_root", .{ self.skeleton.names[root], root }),
                0,
                @intCast(self.skeleton.numJoints() - 1),
                &self.upper_body_root,
                1,
                true,
            )) {
                self.setupPerJointWeights();
            }
        }

        // Exposes animations runtime playback controls.
        if (gui.openClose("Animation control", true)) {
            const titles = [num_layers][:0]const u8{
                "Lower body animation",
                "Upper body animation",
            };
            for (&self.samplers, titles, 0..) |*sampler, title, index| {
                if (!gui.openClose(title, true)) continue;
                gui.pushId(index);
                defer gui.popId();
                sampler.controller.onGui(gui, sampler.clip.duration(), true, true);
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

/// Reads one joint's weight out of an SoA mask.
fn maskWeight(weights: []const ozz.math.Vec4f32, joint: usize) f32 {
    return ozz.math.lane(weights[joint / 4], joint % 4);
}

test "the masks split the skeleton at the upper body root" {
    var sample = try Sample.init(std.testing.allocator, .{});
    defer sample.deinit();

    const root = sample.upperBodyRoot();
    try std.testing.expectEqualStrings("Spine1", sample.skeleton.names[root]);

    // Automatic mode with all the power to the partial animation.
    sample.upper_body_weight = 1;
    _ = try sample.onUpdate(1.0 / 60.0, 0);

    const end = ozz.animation.subtreeEnd(sample.skeleton, root);
    try std.testing.expect(end > root + 1);
    for (0..sample.skeleton.numJoints()) |joint| {
        const inside = joint >= root and joint < end;
        const lower = maskWeight(sample.samplers[lower_body].joint_weights, joint);
        const upper = maskWeight(sample.samplers[upper_body].joint_weights, joint);
        // The two masks are always opposed.
        try std.testing.expectApproxEqAbs(@as(f32, 1), lower + upper, 1e-6);
        try std.testing.expectApproxEqAbs(
            @as(f32, if (inside) 0 else 1),
            lower,
            1e-6,
        );
    }

    // Half the coefficient splits the influence over the upper body.
    sample.upper_body_weight = 0.25;
    _ = try sample.onUpdate(1.0 / 60.0, 0);
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.25),
        maskWeight(sample.samplers[upper_body].joint_weights, root),
        1e-6,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.75),
        maskWeight(sample.samplers[lower_body].joint_weights, root),
        1e-6,
    );
}

test "moving the root joint moves the mask boundary" {
    var sample = try Sample.init(std.testing.allocator, .{});
    defer sample.deinit();

    sample.upper_body_root = 0;
    sample.upper_body_weight = 1;
    _ = try sample.onUpdate(1.0 / 60.0, 0);
    // Rooted at joint 0 the whole skeleton belongs to the upper body.
    for (0..sample.skeleton.numJoints()) |joint| {
        try std.testing.expectApproxEqAbs(
            @as(f32, 1),
            maskWeight(sample.samplers[upper_body].joint_weights, joint),
            1e-6,
        );
    }

    // Out-of-range indices are clamped rather than trapping.
    sample.upper_body_root = 1_000_000;
    _ = try sample.onUpdate(1.0 / 60.0, 0);
    try std.testing.expectEqual(sample.skeleton.numJoints() - 1, sample.upperBodyRoot());
}

test "the blend follows one clip per body part" {
    var sample = try Sample.init(std.testing.allocator, .{});
    defer sample.deinit();

    sample.upper_body_weight = 1;
    for (0..3) |_| try std.testing.expect(try sample.onUpdate(1.0 / 60.0, 0));

    const root = sample.upperBodyRoot();
    const end = ozz.animation.subtreeEnd(sample.skeleton, root);

    // Inside the sub-tree the blend must reproduce the upper body clip, outside
    // it the lower body one.
    for (0..sample.skeleton.numJoints()) |joint| {
        const source = if (joint >= root and joint < end)
            sample.samplers[upper_body].clip.pose
        else
            sample.samplers[lower_body].clip.pose;
        const expected = ozz.math.soaLane(source[joint / 4], joint % 4);
        const blended = ozz.math.soaLane(sample.locals[joint / 4], joint % 4);
        try std.testing.expectApproxEqAbs(
            expected.translation[1],
            blended.translation[1],
            1e-4,
        );
        try std.testing.expect(
            ozz.math.quat.approxRotationEq(expected.rotation, blended.rotation, 0.999),
        );
    }

    // The posture keeps moving and stays framable.
    const before = sample.models[root].translation();
    for (0..30) |_| _ = try sample.onUpdate(1.0 / 60.0, 0);
    try std.testing.expect(@reduce(.Or, before != sample.models[root].translation()));
    try std.testing.expect((sample.sceneBounds() orelse return error.MissingBounds).isValid());

    // The gui path is inert without ImGui and must not touch the renderer.
    var gui = fw.Im.init(false);
    sample.onGui(&gui);
}
