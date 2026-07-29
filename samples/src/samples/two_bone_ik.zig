// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/two_bone_ik/sample_two_bone_ik.cc`.
//!
//! Two bone IK applied to a robot arm posed from the skeleton **rest pose** —
//! this sample loads no animation at all, which is what makes it a pure test
//! bed for every `IKTwoBoneJob` parameter (target, pole vector, mid axis,
//! weight, soften, twist angle).
//!
//! The per-frame flow mirrors upstream exactly:
//!
//! 1. `moveTarget` animates the target along a three-axis path.
//! 2. Local transforms are (optionally) reset to the rest pose, so the weight
//!    parameter always blends from a fixed reference instead of compounding.
//! 3. A full `localToModel` builds the model-space matrices.
//! 4. `twoBoneIk` produces two correction quaternions, which are multiplied
//!    into the SoA local rotations of the start and mid joints.
//! 5. A **partial** `localToModel` starting at the start joint refreshes only
//!    the sub-tree the corrections could have moved. This is a correctness
//!    requirement, not an optimization: re-running the whole hierarchy would
//!    also be correct, but stopping short of the start joint would not.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Vec3f32 = ozz.math.Vec3f32;
const Float4x4 = ozz.math.Float4x4;
const quat = ozz.math.quat;
const Quat4f32 = ozz.math.Quat4f32;
const vec = ozz.math.vec;

pub const name = "two_bone_ik";
pub const description = "Two-bone inverse kinematics";

/// The three joints of the robot arm, ordered start / mid / end. They only have
/// to belong to the same chain, they need not be consecutive.
const chain_names = [3][]const u8{ "shoulder", "forearm", "wrist" };

/// Radius of the sphere standing in for upstream's tiny target box.
const target_radius: f32 = 0.01;
/// Radius of the spheres drawn on the three chain joints.
const joint_radius: f32 = 0.009;
/// Length of the debug axes drawn on the chain joints.
const axes_scale: f32 = 0.1;

const radian_to_degree: f32 = 180.0 / std.math.pi;
const degree_to_radian: f32 = std.math.pi / 180.0;

/// The `mid_axis` choices offered by the GUI. Upstream hard-codes the z axis,
/// which stays the default here; the rig determines which one is correct.
const MidAxis = enum(i32) {
    x = 0,
    y = 1,
    z = 2,

    fn vector(self: MidAxis) Vec3f32 {
        return switch (self) {
            .x => .{ 1, 0, 0 },
            .y => .{ 0, 1, 0 },
            .z => .{ 0, 0, 1 },
        };
    }
};

pub const Sample = struct {
    allocator: std.mem.Allocator,

    /// Runtime skeleton; no animation is loaded by this sample.
    skeleton: ozz.animation.Skeleton,
    /// Local-space transforms, seeded from the skeleton rest pose.
    locals: []ozz.math.SoaTransform,
    /// Model-space matrices.
    models: []Float4x4,

    /// Indices of the relevant joints in the chain.
    start_joint: usize,
    mid_joint: usize,
    end_joint: usize,

    // -- IKTwoBoneJob parameters ---------------------------------------------

    /// Direction the mid joint should point to, in world space.
    pole_vector: Vec3f32 = .{ 0, 1, 0 },
    /// Rotation axis of the mid joint, fixed by the rig.
    mid_axis: MidAxis = .z,
    /// Blend from no correction (0) to the full IK correction (1).
    weight: f32 = 1,
    /// Ratio at which the chain starts falling behind the target, which avoids
    /// snapping into a fully extended pose.
    soften: f32 = 0.97,
    /// Rotation of the chain around the start-to-target vector, in radians.
    twist_angle: f32 = 0,

    /// `IKTwoBoneJob::reached` output of the last run.
    reached: bool = false,

    // -- sample options -------------------------------------------------------

    /// Restart IK from the rest pose every frame instead of from last frame's
    /// result. Required for the weight parameter to be meaningful.
    fix_initial_transform: bool = true,
    /// Master switch for the IK pass.
    two_bone_ik: bool = true,

    show_target: bool = true,
    show_joints: bool = false,
    show_pole_vector: bool = false,

    // -- root transformation --------------------------------------------------

    root_translation: Vec3f32 = .{ 0, 0, 0 },
    /// Pitch / yaw / roll in radians, applied as an intrinsic XYZ rotation.
    root_euler: Vec3f32 = .{ 0, 0, 0 },
    root_scale: f32 = 1,

    // -- target positioning and animation -------------------------------------

    /// Amplitude of the target's animated path; 0 pins it to `target_offset`.
    target_extent: f32 = 0.5,
    target_offset: Vec3f32 = .{ 0, 0.2, 0.1 },
    /// World-space target position, refreshed by `moveTarget`.
    target: Vec3f32 = .{ 0, 0, 0 },

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(@embedFile("robot_skeleton")),
        );
        errdefer skeleton.deinit();

        // Upstream fails outright when a joint is missing. The named lookup
        // already falls back to a case-insensitive substring match, and a
        // generic grandparent/parent/child triple keeps an arbitrary
        // `--skeleton=` override usable instead of aborting.
        const chain = fw.utils.findNamedChain3(skeleton, &chain_names) orelse
            fw.utils.findThreeJointChain(skeleton) orelse
            return error.MissingIkChain;

        const locals = try allocator.alloc(ozz.math.SoaTransform, skeleton.numSoaJoints());
        errdefer allocator.free(locals);
        const models = try allocator.alloc(Float4x4, skeleton.numJoints());
        errdefer allocator.free(models);

        @memcpy(locals, skeleton.rest_poses);

        return .{
            .allocator = allocator,
            .skeleton = skeleton,
            .locals = locals,
            .models = models,
            .start_joint = chain[0],
            .mid_joint = chain[1],
            .end_joint = chain[2],
        };
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.models);
        self.allocator.free(self.locals);
        self.skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = dt;

        self.moveTarget(time);

        // Restores the rest pose so IK always starts from a fixed reference.
        if (self.fix_initial_transform) @memcpy(self.locals, self.skeleton.rest_poses);

        // Model-space matrices from the current local-space setup. Everything
        // up to the end joint is needed by the IK job; joints after it would
        // have to be recomputed anyway.
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.locals,
        }, self.models);

        if (self.two_bone_ik) try self.applyTwoBoneIk();

        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        const root = self.rootTransform();

        // The target, coloured by whether the chain actually reached it.
        if (self.show_target and self.two_bone_ik) {
            try renderer.drawSphereIm(
                target_radius,
                Float4x4.fromTransform(.{ .translation = self.target }),
                if (self.reached) fw.color.green else fw.color.red,
            );
        }

        if (self.show_pole_vector) {
            const begin = Float4x4.transformPoint(root, self.models[self.mid_joint].translation());
            const line = [2]Vec3f32{ begin, vec.add(begin, self.pole_vector) };
            try renderer.drawLines(&line, fw.color.white, .identity);
        }

        if (self.show_joints) {
            const scale = Float4x4.fromTransform(.{ .scale = @splat(axes_scale) });
            for ([3]usize{ self.start_joint, self.mid_joint, self.end_joint }) |joint| {
                const transform = Float4x4.mul(root, self.models[joint]);
                try renderer.drawAxes(Float4x4.mul(transform, scale));
                try renderer.drawSphereIm(joint_radius, transform, fw.color.white);
            }
        }

        try renderer.drawPosture(self.skeleton, self.models, root, true);
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        var buffer: [64]u8 = undefined;

        _ = gui.doCheckBox("Fix initial transform", &self.fix_initial_transform, true);
        _ = gui.doCheckBox("Enable two bone ik", &self.two_bone_ik, true);
        gui.doLabel("Target {s}", .{if (self.reached) "reached" else "not reached"});

        if (gui.openClose("IK parameters", true)) {
            // Upstream gives soften a pow of 2 so the useful high end of the
            // range gets most of the slider travel.
            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "Soften: {d:.2}###soften", .{self.soften}),
                0,
                1,
                &self.soften,
                2,
                self.two_bone_ik,
            );
            _ = gui.doSlider(
                fw.im.formatZ(
                    &buffer,
                    "Twist angle: {d:.0}###twist_angle",
                    .{self.twist_angle * radian_to_degree},
                ),
                -std.math.pi,
                std.math.pi,
                &self.twist_angle,
                1,
                self.two_bone_ik,
            );
            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "Weight: {d:.2}###weight", .{self.weight}),
                0,
                1,
                &self.weight,
                1,
                self.two_bone_ik,
            );

            if (gui.openClose("Mid axis", false)) {
                var choice: i32 = @intFromEnum(self.mid_axis);
                var picked = gui.doRadioButton(0, "x", &choice, self.two_bone_ik);
                picked = gui.doRadioButton(1, "y", &choice, self.two_bone_ik) or picked;
                picked = gui.doRadioButton(2, "z", &choice, self.two_bone_ik) or picked;
                if (picked) self.mid_axis = @enumFromInt(choice);
            }

            if (gui.openClose("Pole vector", true)) {
                sliderVec3(gui, &buffer, "pole_vector", &self.pole_vector, -1, 1, self.two_bone_ik);
            }
        }

        if (gui.openClose("Target position", true)) {
            gui.doLabel("Target animation extent", .{});
            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "{d:.2}###target_extent", .{self.target_extent}),
                0,
                1,
                &self.target_extent,
                1,
                true,
            );

            gui.doLabel("Target offset", .{});
            sliderVec3(gui, &buffer, "target_offset", &self.target_offset, -1, 1, true);
        }

        if (gui.openClose("Root transformation", false)) {
            gui.doLabel("Translation", .{});
            sliderVec3(gui, &buffer, "root_translation", &self.root_translation, -1, 1, true);

            gui.doLabel("Rotation", .{});
            var euler: [3]f32 = vec.scale(self.root_euler, radian_to_degree);
            var moved = false;
            inline for (.{ "pitch", "yaw", "roll" }, 0..) |axis, index| {
                moved = gui.doSlider(
                    fw.im.formatZ(&buffer, axis ++ " {d:.0}###root_euler_" ++ axis, .{euler[index]}),
                    -180,
                    180,
                    &euler[index],
                    1,
                    true,
                ) or moved;
            }
            if (moved) self.root_euler = vec.scale(@as(Vec3f32, euler), degree_to_radian);

            gui.doLabel("Scale", .{});
            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "{d:.2}###root_scale", .{self.root_scale}),
                -1,
                1,
                &self.root_scale,
                1,
                true,
            );
        }

        if (gui.openClose("Display options", true)) {
            _ = gui.doCheckBox("Show target", &self.show_target, true);
            _ = gui.doCheckBox("Show joints", &self.show_joints, true);
            _ = gui.doCheckBox("Show pole vector", &self.show_pole_vector, true);
        }
    }

    /// Frames the volume the animated target sweeps through, like upstream's
    /// `GetSceneBounds`.
    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        const radius: Vec3f32 = @splat(self.target_extent * 0.5);
        return .{
            .min = vec.sub(self.target_offset, radius),
            .max = vec.add(self.target_offset, radius),
        };
    }

    // -- implementation -------------------------------------------------------

    /// Upstream's `MoveTarget`: a cosine sweep that walks one axis at a time,
    /// switching axis every full period.
    fn moveTarget(self: *Sample, time: f32) void {
        self.target = self.target_offset;
        if (!std.math.isFinite(time)) return;

        const anim_extent = (1 - @cos(time)) * 0.5 * self.target_extent;
        const periods = @abs(time) / std.math.tau;
        // The upstream cast is unguarded; clamping keeps a very large `time`
        // (or an unbounded one in a test) from being undefined behaviour.
        const index: usize = if (periods < 1e9) @intFromFloat(periods) else 0;
        // A `@Vector` cannot be indexed by a runtime value.
        var components: [3]f32 = self.target;
        components[index % 3] += anim_extent;
        self.target = components;
    }

    /// Model-space matrix of the character root.
    fn rootTransform(self: Sample) Float4x4 {
        return Float4x4.fromTransform(.{
            .translation = self.root_translation,
            .rotation = quat.fromEuler(self.root_euler),
            .scale = @splat(self.root_scale),
        });
    }

    /// Runs `IKTwoBoneJob` and folds its result back into the local pose.
    fn applyTwoBoneIk(self: *Sample) !void {
        // Target and pole are authored in world space, the job wants model
        // space. A zero root scale makes the root non-invertible; upstream's
        // `Invert` tolerates that through a `SimdInt4` flag, ours reports it by
        // returning null, in which case there is nothing meaningful to solve.
        const invert_root = Float4x4.inverse(self.rootTransform()) orelse {
            self.reached = false;
            return;
        };
        const target_ms = Float4x4.transformPoint(invert_root, self.target);
        const pole_vector_ms = Float4x4.transformVector(invert_root, self.pole_vector);

        const result = try ozz.animation.twoBoneIk(.{
            .target = target_ms,
            .pole_vector = pole_vector_ms,
            .mid_axis = self.mid_axis.vector(),
            .weight = self.weight,
            .soften = self.soften,
            .twist_angle = self.twist_angle,
            .start_joint = self.models[self.start_joint],
            .mid_joint = self.models[self.mid_joint],
            .end_joint = self.models[self.end_joint],
        });
        self.reached = result.reached;

        // Applies both corrections to their respective local-space rotations.
        fw.utils.multiplySoATransformQuaternion(
            self.start_joint,
            result.start_correction,
            self.locals,
        );
        fw.utils.multiplySoATransformQuaternion(
            self.mid_joint,
            result.mid_correction,
            self.locals,
        );

        // Only the start joint's sub-tree can have moved: local transforms
        // before it are untouched, so the update starts there and runs to the
        // end of the hierarchy.
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.locals,
            .from = self.start_joint,
        }, self.models);
    }
};

/// Three `x` / `y` / `z` sliders over a vector, the layout upstream repeats for
/// every `Float3` it exposes.
///
/// `key` distinguishes those repeats from each other: the axis labels alone are
/// identical, and Dear ImGui hashes labels into item ids.
fn sliderVec3(
    gui: *fw.Im,
    buffer: []u8,
    comptime key: []const u8,
    value: *Vec3f32,
    min: f32,
    max: f32,
    enabled: bool,
) void {
    // `Vec3f32` is a `@Vector`, whose components cannot be addressed directly.
    var components: [3]f32 = value.*;
    inline for (.{ "x", "y", "z" }, 0..) |axis, index| {
        _ = gui.doSlider(
            fw.im.formatZ(buffer, axis ++ " {d:.2}###" ++ key ++ "_" ++ axis, .{components[index]}),
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

/// Distance from the end effector to the (world-space) target.
fn endToTarget(sample: Sample) f32 {
    return vec.norm(vec.sub(sample.models[sample.end_joint].translation(), sample.target));
}

/// True when `ancestor` is on the parent chain of `joint`.
fn isAncestor(skeleton: ozz.animation.Skeleton, ancestor: usize, joint: usize) bool {
    var current = skeleton.parents[joint];
    while (current != ozz.animation.no_parent) : (current = skeleton.parents[@intCast(current)]) {
        if (@as(usize, @intCast(current)) == ancestor) return true;
    }
    return false;
}

test "sample loads the robot arm and finds its chain" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    try testing.expectEqualStrings("shoulder", sample.skeleton.names[sample.start_joint]);
    try testing.expectEqualStrings("forearm", sample.skeleton.names[sample.mid_joint]);
    try testing.expectEqualStrings("wrist", sample.skeleton.names[sample.end_joint]);
    // The three joints belong to the same chain, child to parent. They need not
    // be consecutive, which is exactly what the job supports.
    try testing.expect(isAncestor(sample.skeleton, sample.mid_joint, sample.end_joint));
    try testing.expect(isAncestor(sample.skeleton, sample.start_joint, sample.mid_joint));
    try testing.expectEqual(sample.skeleton.numSoaJoints(), sample.locals.len);
    try testing.expectEqual(sample.skeleton.numJoints(), sample.models.len);
}

test "ik moves the end effector onto a reachable target" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    // Pins the target: a static offset makes the assertions time independent.
    sample.target_extent = 0;

    // Rest pose reference, IK disabled.
    sample.two_bone_ik = false;
    sample.target_offset = .{ 0, 0, 0 };
    try testing.expect(try sample.onUpdate(0, 0));
    const rest_end = sample.models[sample.end_joint].translation();
    const start = sample.models[sample.start_joint].translation();

    // A target a little away from the rest position, well inside the chain's
    // reach: the solver must land the end effector on it.
    sample.target_offset = vec.add(rest_end, .{ 0.05, 0.05, 0 });
    sample.two_bone_ik = true;
    try testing.expect(try sample.onUpdate(0, 0));

    try testing.expect(sample.reached);
    try testing.expect(endToTarget(sample) < 1e-3);

    // The whole hierarchy below the start joint moved, the rest did not.
    try testing.expect(vec.norm(vec.sub(sample.models[sample.start_joint].translation(), start)) < 1e-6);
    try testing.expect(vec.norm(vec.sub(sample.models[sample.end_joint].translation(), rest_end)) > 1e-3);
}

test "reached flips at the reachable / unreachable boundary" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.target_extent = 0;
    sample.soften = 1;
    sample.two_bone_ik = false;
    sample.target_offset = .{ 0, 0, 0 };
    try testing.expect(try sample.onUpdate(0, 0));

    const start = sample.models[sample.start_joint].translation();
    const mid = sample.models[sample.mid_joint].translation();
    const end = sample.models[sample.end_joint].translation();
    const chain_length = vec.norm(vec.sub(mid, start)) + vec.norm(vec.sub(end, mid));
    try testing.expect(chain_length > 0);

    const direction: Vec3f32 = .{ 0, 1, 0 };
    sample.two_bone_ik = true;

    // Just inside the chain's reach.
    sample.target_offset = vec.add(start, vec.scale(direction, chain_length * 0.9));
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(sample.reached);
    const inside_error = endToTarget(sample);
    try testing.expect(inside_error < 1e-3);

    // Just outside it: the chain straightens out but cannot get there.
    sample.target_offset = vec.add(start, vec.scale(direction, chain_length * 1.1));
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(!sample.reached);
    try testing.expect(endToTarget(sample) > inside_error);
    // It still aims at the target: the end effector is roughly a full chain
    // length away from the start, along the target direction.
    const solved = vec.sub(sample.models[sample.end_joint].translation(), start);
    try testing.expectApproxEqAbs(chain_length, vec.norm(solved), 1e-2);
    try testing.expect(vec.dot(vec.normalize(solved), direction) > 0.99);

    // A weight of zero always reports "not reached", whatever the distance.
    sample.target_offset = vec.add(start, vec.scale(direction, chain_length * 0.5));
    sample.weight = 0;
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(!sample.reached);
}

test "weight blends between the rest pose and the full correction" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.target_extent = 0;
    sample.two_bone_ik = false;
    try testing.expect(try sample.onUpdate(0, 0));
    const rest_end = sample.models[sample.end_joint].translation();

    sample.target_offset = vec.add(rest_end, .{ 0.05, 0.05, 0 });
    sample.two_bone_ik = true;

    // `fix_initial_transform` is what makes weighting meaningful: every run
    // restarts from the same rest pose.
    try testing.expect(sample.fix_initial_transform);

    var previous: f32 = std.math.inf(f32);
    for ([_]f32{ 0, 0.25, 0.5, 0.75, 1 }) |weight| {
        sample.weight = weight;
        try testing.expect(try sample.onUpdate(0, 0));
        const distance = endToTarget(sample);
        try testing.expect(distance <= previous + 1e-5);
        previous = distance;
    }
    // Zero weight leaves the rest pose untouched.
    sample.weight = 0;
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(vec.norm(vec.sub(sample.models[sample.end_joint].translation(), rest_end)) < 1e-6);
}

test "the target path sweeps one axis per period" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.target_extent = 1;
    sample.target_offset = .{ 0, 0, 0 };

    // Half way through the first period the x axis carries the whole extent.
    sample.moveTarget(std.math.pi);
    try testing.expectApproxEqAbs(@as(f32, 1), sample.target[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), sample.target[1], 1e-5);

    // The next period drives y, then z.
    sample.moveTarget(std.math.tau + std.math.pi);
    try testing.expectApproxEqAbs(@as(f32, 1), sample.target[1], 1e-5);
    sample.moveTarget(2 * std.math.tau + std.math.pi);
    try testing.expectApproxEqAbs(@as(f32, 1), sample.target[2], 1e-5);

    // At the start of a period the target sits exactly on its offset.
    sample.target_offset = .{ 1, 2, 3 };
    sample.moveTarget(0);
    try testing.expectEqual(Vec3f32{ 1, 2, 3 }, sample.target);

    // A zero extent pins the target, and a non-finite time cannot escape it.
    sample.target_extent = 0;
    sample.moveTarget(12.5);
    try testing.expectEqual(Vec3f32{ 1, 2, 3 }, sample.target);
    sample.moveTarget(std.math.inf(f32));
    try testing.expectEqual(Vec3f32{ 1, 2, 3 }, sample.target);
}

test "the root transform maps the target into model space" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.target_extent = 0;
    sample.two_bone_ik = false;
    try testing.expect(try sample.onUpdate(0, 0));
    const rest_end = sample.models[sample.end_joint].translation();
    sample.target_offset = vec.add(rest_end, .{ 0.05, 0.05, 0 });
    sample.two_bone_ik = true;
    try testing.expect(try sample.onUpdate(0, 0));
    const solved = sample.models[sample.end_joint].translation();

    // Translating the root moves the world-space target with it, so the pose
    // the solver produces in model space is unchanged.
    sample.root_translation = .{ 1, 2, 3 };
    sample.target_offset = vec.add(sample.target_offset, sample.root_translation);
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(vec.norm(vec.sub(sample.models[sample.end_joint].translation(), solved)) < 1e-4);

    // A zero root scale is not invertible: IK is skipped rather than producing
    // NaNs, and the pose stays at the rest position.
    sample.root_scale = 0;
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(!sample.reached);
    try testing.expect(vec.norm(vec.sub(sample.models[sample.end_joint].translation(), rest_end)) < 1e-6);
}

test "gui and scene bounds run headless" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    var gui = fw.Im.init(false);
    sample.onGui(&gui);

    sample.target_offset = .{ 0, 0.2, 0.1 };
    sample.target_extent = 0.5;
    const bounds = sample.sceneBounds() orelse return error.MissingBounds;
    try testing.expect(bounds.isValid());
    try testing.expect(bounds.contains(sample.target_offset));
    try testing.expectApproxEqAbs(@as(f32, 0.5), bounds.max[0] - bounds.min[0], 1e-6);
}
