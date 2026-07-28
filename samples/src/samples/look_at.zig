// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/look_at/sample_look_at.cc`.
//!
//! Procedural look-at: the character's head is aimed at a target on top of the
//! sampled animation, and the correction is spread over the head's ancestors so
//! the whole spine participates instead of the neck snapping around.
//!
//! The chain is walked from child to parent. Each pass runs `aimIk` on one
//! joint, and the next pass re-expresses the forward vector and the eyes offset
//! in the next joint's space, after applying the correction the previous pass
//! produced. Because the joints are ordered child to parent, the model-space
//! matrices do **not** need refreshing between passes — only once at the end,
//! and then only from the parent-most joint of the chain downwards.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Vec3f32 = ozz.math.Vec3f32;
const Float4x4 = ozz.math.Float4x4;
const Quaternion = ozz.math.Quaternion;
const vec = ozz.math.vec;

pub const name = "look_at";
pub const description = "Procedural look-at";

/// The IK chain, ordered child to parent. Every joint must be an ancestor of
/// the first one.
const chain_names = [_][]const u8{ "Head", "Spine3", "Spine2", "Spine1" };
/// Number of joints the chain can span.
pub const max_chain_length = chain_names.len;

/// Forward vector in head local-space, rig dependent.
const head_forward: Vec3f32 = .{ 0, 1, 0 };
/// Up vector of every joint of the chain, rig dependent.
const joint_up_vectors = [max_chain_length]Vec3f32{
    .{ 1, 0, 0 },
    .{ 1, 0, 0 },
    .{ 1, 0, 0 },
    .{ 1, 0, 0 },
};

/// Length of the debug axes drawn on joints and on the target.
const axes_scale: f32 = 0.1;
/// Radius of the debug spheres.
const sphere_radius: f32 = 0.02;
/// Length of the forward ray, long enough to visibly cross the target.
const forward_length: f32 = 10;
/// Length of the up vector drawn next to it.
const up_length: f32 = 0.25;

const radian_to_degree: f32 = 180.0 / std.math.pi;

pub const Sample = struct {
    allocator: std.mem.Allocator,

    /// Playback controller of the base animation.
    controller: fw.PlaybackController = .{},
    skeleton: ozz.animation.Skeleton,
    /// Runtime animation, its sampling context, and the local-space pose the
    /// two of them produce. IK is applied on top of `clip.pose`.
    clip: fw.utils.Clip,
    /// Model-space matrices.
    models: []Float4x4,
    /// Skinning matrices, `model * inverse_bind_pose` per mesh joint.
    skinning_matrices: []Float4x4,
    /// The skinned character meshes.
    meshes: []ozz.geometry.Mesh,

    /// Indices of the joints corrected by the look-at, child to parent.
    chain: [max_chain_length]usize,

    // -- target ---------------------------------------------------------------

    target_offset: Vec3f32 = .{ 0.2, 1.5, -0.3 },
    target_extent: f32 = 1,
    /// Model-space target, refreshed by `moveTarget`.
    target: Vec3f32 = .{ 0, 0, 0 },

    /// Look-at position in head local-space, i.e. where the eyes are.
    eyes_offset: Vec3f32 = .{ 0.07, 0.1, 0 },

    // -- IK settings ----------------------------------------------------------

    enable_ik: bool = true,
    /// Number of joints of the chain that get corrected, 0..max_chain_length.
    chain_length: i32 = max_chain_length,
    /// Weight given to every joint but the last, which always gets 1 so the
    /// target is guaranteed to be reached.
    joint_weight: f32 = 0.5,
    /// Weight of the whole look-at, for blending IK in and out.
    chain_weight: f32 = 1,
    /// Rotation around the joint-to-target axis. Upstream leaves
    /// `IKAimJob::twist_angle` at 0; it is exposed here as it tilts the head.
    twist_angle: f32 = 0,

    // -- display options ------------------------------------------------------

    show_skin: bool = true,
    show_joints: bool = false,
    show_target: bool = true,
    show_eyes_offset: bool = false,
    show_forward: bool = false,

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(@embedFile("pab_skeleton")),
        );
        errdefer skeleton.deinit();

        const chain = findChain(skeleton) orelse return error.MissingLookAtChain;

        var clip = try fw.utils.Clip.decode(
            allocator,
            assets.animationOr(@embedFile("pab_crossarms")),
        );
        errdefer clip.deinit();
        if (clip.animation.numTracks() != skeleton.numJoints()) return error.SkeletonMismatch;

        const models = try allocator.alloc(Float4x4, skeleton.numJoints());
        errdefer allocator.free(models);
        const skinning_matrices = try allocator.alloc(Float4x4, skeleton.numJoints());
        errdefer allocator.free(skinning_matrices);

        const meshes = try fw.mesh.decodeMeshes(
            allocator,
            assets.meshOr(@embedFile("arnaud_mesh")),
        );
        errdefer fw.mesh.deinitMeshes(allocator, meshes);
        for (meshes) |mesh| {
            if (skeleton.numJoints() < fw.mesh.highestJointIndex(mesh)) {
                return error.SkeletonMismatch;
            }
        }

        return .{
            .allocator = allocator,
            .skeleton = skeleton,
            .clip = clip,
            .models = models,
            .skinning_matrices = skinning_matrices,
            .meshes = meshes,
            .chain = chain,
        };
    }

    pub fn deinit(self: *Sample) void {
        fw.mesh.deinitMeshes(self.allocator, self.meshes);
        self.allocator.free(self.skinning_matrices);
        self.allocator.free(self.models);
        self.clip.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        self.moveTarget(time);

        _ = self.controller.update(self.clip.duration(), dt);
        try self.clip.sample(self.controller.time_ratio);

        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.clip.pose,
        }, self.models);

        if (self.enable_ik) try self.applyLookAt();

        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        const scale = Float4x4.fromTransform(.{ .scale = @splat(axes_scale) });

        if (self.show_skin) {
            for (self.meshes) |mesh| {
                // The mesh is skinned by a subset of the skeleton, reordered
                // through its own remapping table.
                for (mesh.joint_remaps, mesh.inverse_bind_poses, 0..) |remap, bind, index| {
                    self.skinning_matrices[index] = Float4x4.mul(self.models[remap], bind);
                }
                try renderer.drawSkinnedMesh(
                    mesh,
                    self.skinning_matrices[0..mesh.joint_remaps.len],
                    .identity,
                    .{},
                );
            }
        } else {
            try renderer.drawPosture(self.skeleton, self.models, .identity, true);
        }

        const count: usize = @intCast(std.math.clamp(self.chain_length, 0, max_chain_length));
        if (self.show_joints) {
            for (self.chain[0..count]) |joint| {
                const transform = self.models[joint];
                try renderer.drawAxes(Float4x4.mul(transform, scale));
                try renderer.drawSphereIm(sphere_radius, transform, fw.color.white);
            }
        }

        if (self.show_target) {
            const transform = Float4x4.fromTransform(.{ .translation = self.target });
            if (self.show_forward) {
                try renderer.drawAxes(Float4x4.mul(transform, scale));
            } else {
                try renderer.drawSphereIm(sphere_radius, transform, fw.color.green);
            }
        }

        if (self.show_eyes_offset or self.show_forward) {
            const head = self.chain[0];
            const offset = Float4x4.mul(
                self.models[head],
                Float4x4.fromTransform(.{ .translation = self.eyes_offset }),
            );
            if (self.show_eyes_offset) {
                try renderer.drawAxes(Float4x4.mul(offset, scale));
            }
            if (self.show_forward) {
                // Where the eyes point, and which way is up for the aim job.
                const eye: [3]f32 = offset.translation();
                const forward: [3]f32 = vec.normalize(
                    Float4x4.transformVector(offset, head_forward),
                );
                const up: [3]f32 = vec.normalize(
                    Float4x4.transformVector(offset, joint_up_vectors[0]),
                );
                try renderer.drawVectors(
                    &eye,
                    3 * @sizeOf(f32),
                    &forward,
                    3 * @sizeOf(f32),
                    1,
                    forward_length,
                    fw.color.white,
                    .identity,
                );
                try renderer.drawVectors(
                    &eye,
                    3 * @sizeOf(f32),
                    &up,
                    3 * @sizeOf(f32),
                    1,
                    up_length,
                    fw.color.cyan,
                    .identity,
                );
            }
        }
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        var buffer: [64]u8 = undefined;

        _ = gui.doCheckBox("Enable ik", &self.enable_ik, true);
        _ = gui.doSliderInt(
            fw.im.formatZ(&buffer, "IK chain length: {d}", .{self.chain_length}),
            0,
            max_chain_length,
            &self.chain_length,
            1,
            self.enable_ik,
        );
        _ = gui.doSlider(
            fw.im.formatZ(&buffer, "Joint weight {d:.2}", .{self.joint_weight}),
            0,
            1,
            &self.joint_weight,
            1,
            self.enable_ik,
        );
        _ = gui.doSlider(
            fw.im.formatZ(&buffer, "Chain weight {d:.2}", .{self.chain_weight}),
            0,
            1,
            &self.chain_weight,
            1,
            self.enable_ik,
        );
        _ = gui.doSlider(
            fw.im.formatZ(
                &buffer,
                "Twist angle: {d:.0}",
                .{self.twist_angle * radian_to_degree},
            ),
            -std.math.pi,
            std.math.pi,
            &self.twist_angle,
            1,
            self.enable_ik,
        );

        if (gui.openClose("Animation control", true)) {
            self.controller.onGui(gui, self.clip.duration(), true, true);
        }

        if (gui.openClose("Target offset", true)) {
            const range: f32 = 3;
            gui.doLabel("Animated extent", .{});
            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "{d:.2}", .{self.target_extent}),
                0,
                range,
                &self.target_extent,
                1,
                true,
            );
            sliderVec3(gui, &buffer, &self.target_offset, -range, range, true);
        }

        if (gui.openClose("Eyes offset", true)) {
            sliderVec3(gui, &buffer, &self.eyes_offset, -0.5, 0.5, true);
        }

        if (gui.openClose("Display options", true)) {
            _ = gui.doCheckBox("Show skin", &self.show_skin, true);
            _ = gui.doCheckBox("Show joints", &self.show_joints, true);
            _ = gui.doCheckBox("Show target", &self.show_target, true);
            _ = gui.doCheckBox("Show eyes offset", &self.show_eyes_offset, true);
            _ = gui.doCheckBox("Show forward", &self.show_forward, true);
        }
    }

    /// Frames the volume the target sweeps through, like upstream.
    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        const radius: Vec3f32 = @splat(self.target_extent * 0.8);
        return .{
            .min = vec.sub(self.target_offset, radius),
            .max = vec.add(self.target_offset, radius),
        };
    }

    // -- implementation -------------------------------------------------------

    /// Upstream's `MoveTarget`: three out-of-phase sinusoids around the offset.
    fn moveTarget(self: *Sample, time: f32) void {
        if (!std.math.isFinite(time)) {
            self.target = self.target_offset;
            return;
        }
        const animated: Vec3f32 = .{
            @sin(time * 0.5),
            @cos(time * 0.25),
            @cos(time) * 0.5 + 0.5,
        };
        self.target = vec.add(self.target_offset, vec.scale(animated, self.target_extent));
    }

    /// Iteratively aims the chain at `target`, from the head up to the
    /// parent-most joint.
    fn applyLookAt(self: *Sample) !void {
        const count: usize = @intCast(std.math.clamp(self.chain_length, 0, max_chain_length));
        if (count == 0) return;

        // The same correction is reused every pass, exactly like the single
        // `SimdQuaternion` upstream hands to the job.
        var correction: Quaternion = .identity;
        var forward = head_forward;
        var offset = self.eyes_offset;
        var previous_joint: usize = self.chain[0];

        for (self.chain[0..count], 0..) |joint, index| {
            if (index != 0) {
                // Applies the previous correction to "forward" and "offset",
                // then brings both back into this joint's local space.
                const corrected_forward_ms = Float4x4.transformVector(
                    self.models[previous_joint],
                    Quaternion.rotate(correction, forward),
                );
                const corrected_offset_ms = Float4x4.transformPoint(
                    self.models[previous_joint],
                    Quaternion.rotate(correction, offset),
                );
                const inv_joint = Float4x4.inverse(self.models[joint]) orelse break;
                // Upstream relies on the rig being scale-free to keep the
                // forward vector unit length; normalizing keeps a scaled rig
                // from tripping the job's "forward is normalized" check.
                forward = vec.normalize(
                    Float4x4.transformVector(inv_joint, corrected_forward_ms),
                );
                offset = Float4x4.transformPoint(inv_joint, corrected_offset_ms);
            }

            // The last joint of the chain always gets a full weight, which is
            // what guarantees the target ends up reached.
            const last = index + 1 == count;
            const weight = self.chain_weight * (if (last) @as(f32, 1) else self.joint_weight);

            const result = try ozz.animation.aimIk(.{
                .target = self.target,
                .joint = self.models[joint],
                .forward = forward,
                .offset = offset,
                .up = joint_up_vectors[index],
                .pole_vector = .{ 0, 1, 0 },
                .twist_angle = self.twist_angle,
                .weight = weight,
            });
            correction = result.correction;

            fw.utils.multiplySoATransformQuaternion(joint, correction, self.clip.pose);
            previous_joint = joint;
        }

        // Only the parent-most joint of the chain and its descendants moved.
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.clip.pose,
            .from = previous_joint,
        }, self.models);
    }
};

/// Resolves the look-at chain: the named joints when the rig is the upstream
/// one, otherwise the head's own ancestors so an arbitrary `--skeleton=` still
/// produces a valid, ordered chain.
fn findChain(skeleton: ozz.animation.Skeleton) ?[max_chain_length]usize {
    if (fw.utils.findNamedChain4(skeleton, &chain_names)) |named| {
        if (validateJointsOrder(skeleton, named)) return named;
    }
    const head = fw.utils.findNamedJoint(skeleton, &.{"Head"}) orelse
        fw.utils.findJointContaining(skeleton, "head") orelse
        return null;

    // Walks up the hierarchy, repeating the root once it is reached so the
    // chain always has `max_chain_length` entries (the extra passes are then
    // no-ops on an already-aimed joint).
    var chain: [max_chain_length]usize = @splat(head);
    var current = head;
    for (chain[1..]) |*joint| {
        const parent = skeleton.parents[current];
        if (parent != ozz.animation.no_parent) current = @intCast(parent);
        joint.* = current;
    }
    return chain;
}

/// Upstream's `ValidateJointsOrder`: every joint must be an ancestor of the
/// first one, listed from child to parent.
fn validateJointsOrder(skeleton: ozz.animation.Skeleton, joints: [max_chain_length]usize) bool {
    var matched: usize = 1;
    var joint = joints[0];
    while (matched != joints.len) {
        const parent = skeleton.parents[joint];
        if (parent == ozz.animation.no_parent) break;
        joint = @intCast(parent);
        if (joint == joints[matched]) matched += 1;
    }
    return matched == joints.len;
}

/// Three `x` / `y` / `z` sliders over a vector.
fn sliderVec3(
    gui: *fw.Im,
    buffer: []u8,
    value: *Vec3f32,
    min: f32,
    max: f32,
    enabled: bool,
) void {
    // `Vec3f32` is a `@Vector`, whose components cannot be addressed directly.
    var components: [3]f32 = value.*;
    inline for (.{ "x", "y", "z" }, 0..) |axis, index| {
        _ = gui.doSlider(
            fw.im.formatZ(buffer, axis ++ " {d:.2}", .{components[index]}),
            min,
            max,
            &components[index],
            1,
            enabled,
        );
    }
    value.* = components;
}

// -----------------------------------------------------------------------------
// Tests — all headless, none of them touch the renderer.
// -----------------------------------------------------------------------------

const testing = std.testing;

/// World-space position of the eyes, i.e. the point the aim job moves onto the
/// joint-to-target line.
fn eyePosition(sample: Sample) Vec3f32 {
    return Float4x4.transformPoint(sample.models[sample.chain[0]], sample.eyes_offset);
}

/// Cosine of the angle between the head forward vector and the direction from
/// the eyes to the target. 1 means the character looks exactly at the target.
fn lookAlignment(sample: Sample) f32 {
    const head = sample.models[sample.chain[0]];
    const forward = vec.normalize(Float4x4.transformVector(head, head_forward));
    const to_target = vec.sub(sample.target, eyePosition(sample));
    const length = vec.norm(to_target);
    if (length < 1e-6) return 1;
    return vec.dot(forward, vec.scale(to_target, 1 / length));
}

/// How far apart two model-space matrices point, measured on their basis.
fn rotationDelta(a: Float4x4, b: Float4x4) f32 {
    var total: f32 = 0;
    for (0..3) |column| {
        for (0..3) |row| {
            total += @abs(a.cols[column][row] - b.cols[column][row]);
        }
    }
    return total;
}

test "sample loads the pab rig and resolves an ordered chain" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    try testing.expectEqualStrings("Head", sample.skeleton.names[sample.chain[0]]);
    try testing.expect(validateJointsOrder(sample.skeleton, sample.chain));
    try testing.expectEqual(sample.skeleton.numJoints(), sample.models.len);
    try testing.expect(sample.clip.duration() > 0);
    try testing.expect(sample.meshes.len > 0);
}

test "aim ik points the head at the target" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    // Pins both the animation and the target so the assertions are stable.
    sample.controller.play = false;
    sample.target_extent = 0;
    sample.target_offset = .{ 1.5, 1.6, 1 };

    sample.enable_ik = false;
    try testing.expect(try sample.onUpdate(0, 0));
    const without_ik = lookAlignment(sample);

    sample.enable_ik = true;
    try testing.expect(try sample.onUpdate(0, 0));
    const with_ik = lookAlignment(sample);

    try testing.expect(with_ik > without_ik);
    // The last joint of the chain carries a full weight, so the target really
    // is reached rather than merely approached.
    try testing.expect(with_ik > 0.999);

    // And it tracks the target when it moves to the other side.
    sample.target_offset = .{ -1.5, 1.4, 1 };
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(lookAlignment(sample) > 0.999);
}

test "chain length spreads the correction over more joints" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.controller.play = false;
    sample.target_extent = 0;
    sample.target_offset = .{ 1.5, 1.6, 1 };

    // Reference spine position, no IK at all.
    sample.enable_ik = false;
    try testing.expect(try sample.onUpdate(0, 0));
    const spine = sample.chain[max_chain_length - 1];
    const rest_spine = sample.models[spine];

    // A chain of one only moves the head: the parent-most joint is untouched.
    sample.enable_ik = true;
    sample.chain_length = 1;
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(lookAlignment(sample) > 0.999);
    try testing.expect(rotationDelta(rest_spine, sample.models[spine]) < 1e-5);

    // The full chain with a partial joint weight makes every ancestor rotate.
    sample.chain_length = max_chain_length;
    sample.joint_weight = 0.5;
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(lookAlignment(sample) > 0.999);
    try testing.expect(rotationDelta(rest_spine, sample.models[spine]) > 1e-3);

    // A zero-length chain is a no-op, whatever the weights.
    sample.chain_length = 0;
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expectApproxEqAbs(
        @as(f32, 0),
        rotationDelta(rest_spine, sample.models[spine]),
        1e-6,
    );
}

test "chain weight blends the whole look-at in and out" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.controller.play = false;
    sample.target_extent = 0;
    sample.target_offset = .{ 1.5, 1.6, 1 };

    sample.enable_ik = false;
    try testing.expect(try sample.onUpdate(0, 0));
    const without_ik = lookAlignment(sample);
    const rest_head = sample.models[sample.chain[0]];

    sample.enable_ik = true;
    var previous = without_ik;
    for ([_]f32{ 0, 0.25, 0.5, 0.75, 1 }) |weight| {
        sample.chain_weight = weight;
        try testing.expect(try sample.onUpdate(0, 0));
        const alignment = lookAlignment(sample);
        try testing.expect(alignment >= previous - 1e-5);
        previous = alignment;
    }

    // A zero chain weight is indistinguishable from IK being disabled.
    sample.chain_weight = 0;
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(rotationDelta(rest_head, sample.models[sample.chain[0]]) < 1e-5);
}

test "eyes offset is what the aim job puts on the target line" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.controller.play = false;
    sample.target_extent = 0;
    sample.target_offset = .{ 0.8, 1.7, 1.2 };
    sample.eyes_offset = .{ 0, 0, 0 };
    try testing.expect(try sample.onUpdate(0, 0));
    const centred = lookAlignment(sample);

    // Moving the eyes off the joint changes the pose, and the aim is still
    // measured from the offset position rather than from the joint origin.
    sample.eyes_offset = .{ 0.07, 0.1, 0 };
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(lookAlignment(sample) > 0.999);
    try testing.expect(centred > 0.999);
    const eye = eyePosition(sample);
    const joint = sample.models[sample.chain[0]].translation();
    try testing.expect(vec.norm(vec.sub(eye, joint)) > 0.05);
}

test "the target path stays inside the published bounds" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.target_offset = .{ 0.2, 1.5, -0.3 };
    sample.target_extent = 1;
    const bounds = sample.sceneBounds() orelse return error.MissingBounds;
    try testing.expect(bounds.isValid());
    try testing.expect(bounds.contains(sample.target_offset));
    // Upstream frames 0.8 of the extent, deliberately tighter than the path.
    try testing.expectApproxEqAbs(@as(f32, 1.6), bounds.max[1] - bounds.min[1], 1e-6);

    // Every point of the path stays within one extent of the offset.
    var time: f32 = 0;
    while (time < 30) : (time += 0.37) {
        sample.moveTarget(time);
        const delta: [3]f32 = @abs(vec.sub(sample.target, sample.target_offset));
        for (delta) |component| try testing.expect(component <= sample.target_extent + 1e-5);
    }

    // A zero extent pins the target on its offset, and a non-finite time
    // cannot move it either.
    sample.target_extent = 0;
    sample.moveTarget(3.5);
    try testing.expectEqual(sample.target_offset, sample.target);
    sample.moveTarget(std.math.inf(f32));
    try testing.expectEqual(sample.target_offset, sample.target);
}

test "gui runs headless and the animation keeps playing" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    var gui = fw.Im.init(false);
    sample.onGui(&gui);

    // A handful of real frames, IK enabled, no assertions beyond "it runs".
    var time: f32 = 0;
    for (0..8) |_| {
        try testing.expect(try sample.onUpdate(1.0 / 60.0, time));
        time += 1.0 / 60.0;
    }
    try testing.expect(sample.controller.time_ratio > 0);
    // Skinning matrices are sized for the whole skeleton, whatever the mesh.
    for (sample.meshes) |mesh| {
        try testing.expect(mesh.joint_remaps.len <= sample.skinning_matrices.len);
    }
}
