// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/additive/sample_additive.cc`.
//!
//! Additive blending superimposes a movement on top of a playing animation
//! instead of interpolating towards it: the base walk cycle is never altered,
//! the delta poses of the *curl* and *splay* hand animations are simply added on
//! top of it. Only the first frame of each additive clip is used, so the two
//! animations are sampled once at initialization and then dropped.
//!
//! `ozz.animation.blend` runs the additive layers after the normal blending
//! pass, with a different equation, and both kinds of layer accept the same
//! inputs: local-space transforms, a layer weight and an optional per-joint
//! weight mask. The base layer uses such a mask to remove the hands from the
//! walk cycle; the additive layers expose one too (see `mask_additive`), which
//! upstream does not surface.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const quat = ozz.math.quat;
const fw = @import("framework");

pub const name = "additive";
pub const description = "Additive animation blending";

/// Upstream's `media/skeleton.ozz`, replaceable with `--skeleton=`.
const default_skeleton = @embedFile("pab_skeleton");
/// Upstream's `media/animation_base.ozz`, replaceable with `--animation=`.
const default_animation = @embedFile("pab_walk");
/// Upstream's `media/animation_splay_additive.ozz`.
const default_splay_animation = @embedFile("pab_splay_additive");
/// Upstream's `media/animation_curl_additive.ozz`.
const default_curl_animation = @embedFile("pab_curl_additive");

/// The additive layer holding the splay pose, driven by the pad's X axis.
const splay = 0;
/// The additive layer holding the curl pose, driven by the pad's Y axis.
const curl = 1;
/// The number of additive layers to blend.
const num_layers = 2;

/// Joints whose sub-tree the base animation must not drive, so the additive
/// finger poses are the only thing moving the hands.
const masked_base_joints = [_][]const u8{ "Lefthand", "RightHand" };

/// Half-extent of the bounding box the camera frames around the hand.
const hand_extent: f32 = 0.15;

/// Visitor handed to `iterateJointsDF`, writing one weight per visited joint
/// into an SoA mask.
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

    /// Base animation, its sampling context and its local-space output.
    base: fw.utils.Clip,

    /// Main animation controller.
    controller: fw.PlaybackController = .{},

    /// Blending weight of the base animation layer.
    base_weight: f32 = 0,

    /// Per-joint weights of the base animation mask, removing the hands from
    /// the base animation.
    base_joint_weights: []ozz.math.Vec4f32,

    /// Whether the hands are masked out of the base layer. Upstream hard-codes
    /// this to true; the check box makes the mask observable.
    mask_base_hands: bool = true,

    /// Poses of local transforms sampled once from the curl and splay
    /// animations, which is all an additive layer needs.
    additive_locals: [num_layers][]ozz.math.SoaTransform,

    /// Blending weights of the additive animation layers.
    additive_weights: [num_layers]f32 = .{ 0.3, 0.9 },

    /// Per-joint weights shared by both additive layers. Not exposed upstream:
    /// it restricts curl and splay to the sub-tree of `additive_mask_root`.
    additive_joint_weights: []ozz.math.Vec4f32,

    /// Whether the additive layers go through `additive_joint_weights`.
    mask_additive: bool = false,

    /// Root of the sub-tree the additive layers are restricted to.
    additive_mask_root: i32 = 0,

    /// Automatically animates additive weights, so the hand moves on its own.
    auto_animate_weights: bool = true,

    /// Time accumulator driving `animateWeights`.
    weights_time: f32 = 0,

    /// Buffer of local transforms which stores the blending result.
    locals: []ozz.math.SoaTransform,

    /// Model-space matrices, computed after the blending stage.
    models: []ozz.math.Float4x4,

    /// The joint the camera frames, when the rig has a left hand.
    hand: ?usize,

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(default_skeleton),
        );
        errdefer skeleton.deinit();
        const soa_joints = skeleton.numSoaJoints();

        var base = try fw.utils.Clip.decode(
            allocator,
            assets.animationOr(default_animation),
        );
        errdefer base.deinit();
        if (skeleton.numJoints() != base.animation.numTracks()) {
            return error.SkeletonAnimationMismatch;
        }

        const base_joint_weights = try allocator.alloc(ozz.math.Vec4f32, soa_joints);
        errdefer allocator.free(base_joint_weights);
        const additive_joint_weights = try allocator.alloc(ozz.math.Vec4f32, soa_joints);
        errdefer allocator.free(additive_joint_weights);
        @memset(additive_joint_weights, @splat(1));

        // Reads and extracts the additive animations pose. The animations
        // themselves are dropped, only the first frame is needed.
        const archives = [num_layers][]const u8{
            default_splay_animation,
            default_curl_animation,
        };
        var additive_locals: [num_layers][]ozz.math.SoaTransform = undefined;
        var loaded: usize = 0;
        errdefer for (additive_locals[0..loaded]) |pose| allocator.free(pose);
        for (&additive_locals, archives) |*pose, archive| {
            var clip = try fw.utils.Clip.decode(allocator, archive);
            defer clip.deinit();
            if (skeleton.numJoints() != clip.animation.numTracks()) {
                return error.SkeletonAnimationMismatch;
            }
            // Only needs the first frame pose.
            try clip.sample(0);
            pose.* = try allocator.dupe(ozz.math.SoaTransform, clip.pose);
            loaded += 1;
        }

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

        const hand = fw.utils.findNamedJoint(skeleton, &.{masked_base_joints[0]});

        var sample: Sample = .{
            .allocator = allocator,
            .skeleton = skeleton,
            .base = base,
            .base_joint_weights = base_joint_weights,
            .additive_locals = additive_locals,
            .additive_joint_weights = additive_joint_weights,
            .additive_mask_root = @intCast(hand orelse 0),
            .locals = locals,
            .models = models,
            .hand = hand,
        };
        sample.setupJointWeights();
        return sample;
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.models);
        self.allocator.free(self.locals);
        for (self.additive_locals) |pose| self.allocator.free(pose);
        self.allocator.free(self.additive_joint_weights);
        self.allocator.free(self.base_joint_weights);
        self.base.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    /// The additive mask root, clamped into the skeleton (the gui slider and
    /// the `i32` storage both allow out-of-range values).
    pub fn additiveMaskRoot(self: Sample) usize {
        const joint_count = self.skeleton.numJoints();
        if (joint_count == 0) return 0;
        const clamped = std.math.clamp(
            self.additive_mask_root,
            0,
            @as(i32, @intCast(joint_count - 1)),
        );
        return @intCast(clamped);
    }

    /// Rebuilds both per-joint masks: the base one removes the hands from the
    /// walk cycle (`SetJointWeights` upstream), the additive one restricts curl
    /// and splay to a sub-tree.
    pub fn setupJointWeights(self: *Sample) void {
        // Allocates and sets base animation mask weights to one, then disables
        // the hand sub-trees.
        @memset(self.base_joint_weights, @splat(1));
        if (self.mask_base_hands) {
            for (masked_base_joints) |joint_name| {
                const joint = fw.utils.findNamedJoint(self.skeleton, &.{joint_name}) orelse
                    continue;
                ozz.animation.iterateJointsDF(self.skeleton, joint, WeightSetupIterator{
                    .weights = self.base_joint_weights,
                    .weight_setting = 0,
                });
            }
        }

        // The additive mask keeps the selected sub-tree only.
        const outside: f32 = if (self.mask_additive) 0 else 1;
        @memset(self.additive_joint_weights, @splat(outside));
        if (self.mask_additive) {
            ozz.animation.iterateJointsDF(
                self.skeleton,
                self.additiveMaskRoot(),
                WeightSetupIterator{
                    .weights = self.additive_joint_weights,
                    .weight_setting = 1,
                },
            );
        }
    }

    /// For the sample purpose, animates the additive weights automatically so
    /// the hand moves (`AnimateWeights`).
    fn animateWeights(self: *Sample, dt: f32) void {
        self.weights_time += dt;
        self.additive_weights = .{
            0.5 + @cos(self.weights_time * 1.7) * 0.5,
            0.5 + @cos(self.weights_time * 2.5) * 0.5,
        };
    }

    /// Samples the base animation, adds the two fixed poses on top of it and
    /// converts the result to model space.
    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;

        if (self.auto_animate_weights) self.animateWeights(dt);
        self.setupJointWeights();

        // Updates base animation time and samples it.
        _ = self.controller.update(self.base.duration(), dt);
        try self.base.sample(self.controller.time_ratio);

        // Main animation is used as-is, through its per-joint mask.
        const layers = [_]ozz.animation.BlendLayer{.{
            .transforms = self.base.pose,
            .weight = self.base_weight,
            .joint_weights = self.base_joint_weights,
        }};

        // The two additive layers (splay and curl) are blended on top of it.
        var additive_layers: [num_layers]ozz.animation.BlendLayer = undefined;
        for (&additive_layers, self.additive_locals, self.additive_weights) |*layer, pose, weight| {
            layer.* = .{
                .transforms = pose,
                .weight = weight,
                .joint_weights = if (self.mask_additive) self.additive_joint_weights else null,
            };
        }

        try ozz.animation.blend(.{
            .rest_pose = self.skeleton.rest_poses,
            .layers = &layers,
            .additive_layers = &additive_layers,
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
            gui.doLabel("Main layer:", .{});
            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "Layer weight: {d:.2}###base_weight", .{self.base_weight}),
                0,
                1,
                &self.base_weight,
                1,
                true,
            );

            gui.doLabel("Additive layer:", .{});
            _ = gui.doCheckBox("Animates weights", &self.auto_animate_weights, true);

            // The pad drives splay on X and curl on Y; a local copy keeps the
            // "user interacted" detection honest.
            var weights = self.additive_weights;
            if (gui.doSlider2D(
                fw.im.formatZ(
                    &buffer,
                    "Weights\nCurl: {d:.2}\nSplay: {d:.2}###weights_2d",
                    .{ self.additive_weights[curl], self.additive_weights[splay] },
                ),
                .{ 0, 0 },
                .{ 1, 1 },
                &weights,
                true,
            )) {
                // User interacted.
                self.auto_animate_weights = false;
                self.additive_weights = weights;
            }
        }

        // Per-joint masking of the layers. The base part reflects upstream's
        // hard-coded hand mask; the additive part is an addition.
        if (gui.openClose("Layer masks", false)) {
            _ = gui.doCheckBox("Mask hands out of base layer", &self.mask_base_hands, true);
            _ = gui.doCheckBox("Mask additive layers", &self.mask_additive, true);
            if (self.skeleton.numJoints() != 0) {
                gui.doLabel("Root of the additive layers:", .{});
                const root = self.additiveMaskRoot();
                _ = gui.doSliderInt(
                    fw.im.formatZ(&buffer, "{s} ({d})###additive_mask_root", .{ self.skeleton.names[root], root }),
                    0,
                    @intCast(self.skeleton.numJoints() - 1),
                    &self.additive_mask_root,
                    1,
                    self.mask_additive,
                );
            }
        }

        // Exposes base animation runtime playback controls.
        if (gui.openClose("Animation control", true)) {
            self.controller.onGui(gui, self.base.duration(), true, true);
        }
    }

    /// `GetSceneBounds`: a small box around the hand, so the camera frames the
    /// fingers the additive layers animate. Falls back to the whole posture on
    /// a rig without a left hand.
    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        if (self.hand) |joint| {
            const position = self.models[joint].translation();
            const extent: ozz.math.Vec3f32 = @splat(hand_extent);
            return .{
                .min = ozz.math.vec.sub(position, extent),
                .max = ozz.math.vec.add(position, extent),
            };
        }
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

test "the base mask removes the hands from the walk cycle" {
    var sample = try Sample.init(std.testing.allocator, .{});
    defer sample.deinit();

    const hand = sample.hand orelse return error.MissingHandJoint;
    const end = ozz.animation.subtreeEnd(sample.skeleton, hand);
    try std.testing.expect(end > hand + 1);

    for (0..sample.skeleton.numJoints()) |joint| {
        const inside = joint >= hand and joint < end;
        const weight = maskWeight(sample.base_joint_weights, joint);
        if (inside) {
            try std.testing.expectEqual(@as(f32, 0), weight);
        } else if (joint == 0) {
            try std.testing.expectEqual(@as(f32, 1), weight);
        }
    }

    // Toggling the mask off restores every joint.
    sample.mask_base_hands = false;
    _ = try sample.onUpdate(1.0 / 60.0, 0);
    for (0..sample.skeleton.numJoints()) |joint| {
        try std.testing.expectEqual(
            @as(f32, 1),
            maskWeight(sample.base_joint_weights, joint),
        );
    }
}

test "additive weights animate and drive the hand" {
    var sample = try Sample.init(std.testing.allocator, .{});
    defer sample.deinit();
    const hand = sample.hand orelse return error.MissingHandJoint;

    // Auto-animation starts both weights at their cosine peak.
    _ = try sample.onUpdate(0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), sample.additive_weights[splay], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), sample.additive_weights[curl], 1e-6);

    const opened = try std.testing.allocator.dupe(ozz.math.Float4x4, sample.models);
    defer std.testing.allocator.free(opened);

    for (0..4) |_| try std.testing.expect(try sample.onUpdate(1.0 / 30.0, 0));
    try std.testing.expect(sample.additive_weights[splay] < 1);
    for (sample.additive_weights) |weight| {
        try std.testing.expect(weight >= 0);
        try std.testing.expect(weight <= 1);
    }

    // The fingers, which only the additive layers drive, must have moved.
    var moved = false;
    for (hand..ozz.animation.subtreeEnd(sample.skeleton, hand)) |joint| {
        if (@reduce(.Or, opened[joint].translation() != sample.models[joint].translation())) {
            moved = true;
        }
    }
    try std.testing.expect(moved);

    // Turning both additive weights off leaves the blended pose alone.
    sample.auto_animate_weights = false;
    sample.additive_weights = .{ 0, 0 };
    _ = try sample.onUpdate(1.0 / 30.0, 0);
    const neutral = try std.testing.allocator.dupe(ozz.math.SoaTransform, sample.locals);
    defer std.testing.allocator.free(neutral);
    sample.additive_weights = .{ 1, 1 };
    _ = try sample.onUpdate(1.0 / 30.0, 0);
    var changed = false;
    for (neutral, sample.locals) |before, after| {
        if (@reduce(.Or, before.rotation.x != after.rotation.x)) changed = true;
    }
    try std.testing.expect(changed);
}

test "the additive mask restricts the layers to a sub-tree" {
    var sample = try Sample.init(std.testing.allocator, .{});
    defer sample.deinit();
    const hand = sample.hand orelse return error.MissingHandJoint;

    sample.auto_animate_weights = false;
    sample.additive_weights = .{ 1, 1 };
    sample.mask_additive = true;
    sample.additive_mask_root = @intCast(hand);
    _ = try sample.onUpdate(1.0 / 60.0, 0);

    const end = ozz.animation.subtreeEnd(sample.skeleton, hand);
    for (0..sample.skeleton.numJoints()) |joint| {
        const inside = joint >= hand and joint < end;
        try std.testing.expectEqual(
            @as(f32, if (inside) 1 else 0),
            maskWeight(sample.additive_joint_weights, joint),
        );
    }

    // Masked out joints now match the unmasked additive-free result.
    const masked = try std.testing.allocator.dupe(ozz.math.SoaTransform, sample.locals);
    defer std.testing.allocator.free(masked);
    sample.mask_additive = false;
    sample.additive_weights = .{ 0, 0 };
    _ = try sample.onUpdate(1.0 / 60.0, 0);
    for (0..sample.skeleton.numJoints()) |joint| {
        if (joint >= hand and joint < end) continue;
        const with_mask = ozz.math.soaLane(masked[joint / 4], joint % 4);
        const without = ozz.math.soaLane(sample.locals[joint / 4], joint % 4);
        try std.testing.expect(ozz.math.quat.approxRotationEq(
            with_mask.rotation,
            without.rotation,
            0.999,
        ));
    }
}

test "the camera frames the hand and the gui stays headless" {
    var sample = try Sample.init(std.testing.allocator, .{});
    defer sample.deinit();
    const hand = sample.hand orelse return error.MissingHandJoint;

    _ = try sample.onUpdate(1.0 / 60.0, 0);
    const box = sample.sceneBounds() orelse return error.MissingBounds;
    try std.testing.expect(box.isValid());
    try std.testing.expect(box.contains(sample.models[hand].translation()));
    try std.testing.expectApproxEqAbs(
        2 * hand_extent,
        box.max[1] - box.min[1],
        1e-5,
    );

    // Upstream defaults: the base layer is silent, the additive weights are not.
    var fresh = try Sample.init(std.testing.allocator, .{});
    defer fresh.deinit();
    try std.testing.expectEqual(@as(f32, 0), fresh.base_weight);
    try std.testing.expectEqual([num_layers]f32{ 0.3, 0.9 }, fresh.additive_weights);
    try std.testing.expect(fresh.auto_animate_weights);

    var gui = fw.Im.init(false);
    fresh.onGui(&gui);
}
