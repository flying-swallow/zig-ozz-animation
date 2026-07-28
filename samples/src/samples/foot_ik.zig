// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/foot_ik/sample_foot_ik.cc`.
//!
//! Foot planting: the character's legs and ankles are corrected at run time so
//! the feet touch and adapt to a collision floor, and the pelvis is lowered so
//! the lowest foot can reach the ground while the other leg bends.
//!
//! One frame runs six steps, in this order (upstream's `OnUpdate`):
//!
//! 1. Sample the base animation and build model-space matrices.
//! 2. Raycast down at the root position to find the character's floor height.
//! 3. Raycast down from each ankle to find where each foot lands.
//! 4. Turn each hit into an ankle target, accounting for foot height *and*
//!    floor slope (the Thales construction in `updateAnklesTarget`).
//! 5. Offset the pelvis down by the largest required drop.
//! 6. Two bone IK per leg so the ankle reaches its target, then aim IK on the
//!    ankle so the foot lies flat on the floor.
//!
//! Step 6 relies on partial `localToModel` ranges: `hip -> ankle` between the
//! two IK passes (the ankle's siblings deliberately stay stale, they are about
//! to move again), then `hip -> end of hierarchy` once the ankle rotation is
//! final. Recomputing the whole skeleton in between would undo nothing, but
//! stopping short of the hip would feed the aim job a stale ankle matrix.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Vec3f32 = ozz.math.Vec3f32;
const Float4x4 = ozz.math.Float4x4;
const Quaternion = ozz.math.Quaternion;
const vec = ozz.math.vec;

pub const name = "foot_ik";
pub const description = "Foot inverse kinematics";

/// Hip / knee / ankle of each leg, rig dependent.
const left_joint_names = [3][]const u8{ "LeftUpLeg", "LeftLeg", "LeftFoot" };
const right_joint_names = [3][]const u8{ "RightUpLeg", "RightLeg", "RightFoot" };

/// Rotation axis of the knee, fixed by the rig.
const knee_axis: Vec3f32 = .{ 0, 0, 1 };
/// Forward and up vectors of the ankle, in its local space.
const ankle_forward: Vec3f32 = .{ -1, 0, 0 };
const ankle_up: Vec3f32 = .{ 0, 1, 0 };

const down: Vec3f32 = .{ 0, -1, 0 };
/// Height the character raycast starts above the root.
const character_ray_height_offset: Vec3f32 = .{ 0, 10, 0 };
/// Height each foot raycast starts above the ankle.
const foot_ray_height_offset: Vec3f32 = .{ 0, 0.5, 0 };

const leg_count = 2;
const left = 0;
const right = 1;

/// Length of the debug axes.
const axes_scale: f32 = 0.1;
/// Length of the normal drawn at a raycast hit.
const normal_length: f32 = 0.5;
/// Length of the ray drawn when the raycast misses the floor.
const miss_length: f32 = 10;
/// Radius of the ankle target sphere.
const target_radius: f32 = 0.02;

const radian_to_degree: f32 = 180.0 / std.math.pi;

/// Indices of one leg's three joints.
const Leg = struct { hip: usize, knee: usize, ankle: usize };

/// One downward foot raycast and what it found.
const LegRay = struct {
    start: Vec3f32 = .{ 0, 0, 0 },
    dir: Vec3f32 = down,
    hit: bool = false,
    hit_point: Vec3f32 = .{ 0, 0, 0 },
    hit_normal: Vec3f32 = .{ 0, 1, 0 },
};

pub const Sample = struct {
    allocator: std.mem.Allocator,

    controller: fw.PlaybackController = .{},
    skeleton: ozz.animation.Skeleton,
    /// Runtime animation, sampling context and local-space pose. IK writes back
    /// into `clip.pose`.
    clip: fw.utils.Clip,
    models: []Float4x4,
    skinning_matrices: []Float4x4,
    /// The skinned character meshes.
    meshes: []ozz.geometry.Mesh,
    /// The floor, used both for collision and for rendering.
    floors: []ozz.geometry.Mesh,

    legs: [leg_count]Leg,
    rays: [leg_count]LegRay = @splat(.{}),
    /// Ankle world positions before any correction.
    ankles_initial_ws: [leg_count]Vec3f32 = @splat(.{ 0, 0, 0 }),
    /// Ankle world positions the two bone IK aims for.
    ankles_target_ws: [leg_count]Vec3f32 = @splat(.{ 0, 0, 0 }),
    /// `IKTwoBoneJob::reached` of each leg's last run.
    reached: [leg_count]bool = @splat(false),

    /// Vertical correction applied to the whole character.
    pelvis_offset: Vec3f32 = .{ 0, 0, 0 },

    // -- root transformation --------------------------------------------------

    root_translation: Vec3f32 = .{ 2.17, 2, -2.06 },
    root_yaw: f32 = -2,

    // -- IK settings ----------------------------------------------------------

    /// Distance from the ankle joint down to the sole.
    foot_height: f32 = 0.12,
    /// Weight shared by the two bone and the aim passes.
    weight: f32 = 1,
    /// Two bone IK soften ratio.
    soften: f32 = 1,

    auto_character_height: bool = true,
    pelvis_correction: bool = true,
    two_bone_ik: bool = true,
    aim_ik: bool = true,

    // -- display options ------------------------------------------------------

    show_skin: bool = true,
    show_joints: bool = false,
    show_raycast: bool = false,
    show_ankle_target: bool = false,
    show_root: bool = false,
    show_offsetted_root: bool = false,

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(@embedFile("pab_skeleton")),
        );
        errdefer skeleton.deinit();

        const left_leg = setupLeg(skeleton, &left_joint_names) orelse return error.MissingLegChain;
        const right_leg = setupLeg(skeleton, &right_joint_names) orelse return error.MissingLegChain;

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

        const floors = try fw.mesh.decodeMeshes(
            allocator,
            assets.floorOr(@embedFile("floor_mesh")),
        );
        errdefer fw.mesh.deinitMeshes(allocator, floors);

        return .{
            .allocator = allocator,
            .skeleton = skeleton,
            .clip = clip,
            .models = models,
            .skinning_matrices = skinning_matrices,
            .meshes = meshes,
            .floors = floors,
            .legs = .{ left_leg, right_leg },
        };
    }

    pub fn deinit(self: *Sample) void {
        fw.mesh.deinitMeshes(self.allocator, self.floors);
        fw.mesh.deinitMeshes(self.allocator, self.meshes);
        self.allocator.free(self.skinning_matrices);
        self.allocator.free(self.models);
        self.clip.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;

        // 1. Base animation.
        try self.updateBaseAnimation(dt);
        // 2. Character height on the floor, evaluated at its root position.
        self.updateCharacterHeight();
        // 3. One downward raycast per foot.
        self.raycastLegs();
        // 4. Ankle targets, floor slope and foot height accounted for.
        self.updateAnklesTarget();
        // 5. Pelvis offset, so the lowest foot can reach its target.
        self.updatePelvisOffset();
        // 6. Two bone IK per leg, then aim IK on each ankle.
        try self.updateFootIk();

        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        const scale = Float4x4.fromTransform(.{ .scale = @splat(axes_scale) });
        const offsetted_root = self.offsettedRootTransform();

        for (self.floors) |floor| try renderer.drawMesh(floor, .identity, .{});

        if (self.show_skin) {
            for (self.meshes) |mesh| {
                for (mesh.joint_remaps, mesh.inverse_bind_poses, 0..) |remap, bind, index| {
                    self.skinning_matrices[index] = Float4x4.mul(self.models[remap], bind);
                }
                try renderer.drawSkinnedMesh(
                    mesh,
                    self.skinning_matrices[0..mesh.joint_remaps.len],
                    offsetted_root,
                    .{},
                );
            }
        } else {
            try renderer.drawPosture(self.skeleton, self.models, offsetted_root, true);
        }

        if (self.show_joints) {
            for (self.legs) |leg| {
                for ([3]usize{ leg.hip, leg.knee, leg.ankle }) |joint| {
                    const transform = Float4x4.mul(offsetted_root, self.models[joint]);
                    try renderer.drawAxes(Float4x4.mul(transform, scale));
                }
            }
        }

        if (self.show_raycast) {
            // Hit points and their normals go through `drawVectors`, so both
            // legs are one draw call; misses are drawn as a long ray instead.
            var points: [leg_count * 3]f32 = undefined;
            var normals: [leg_count * 3]f32 = undefined;
            var hits: usize = 0;
            for (self.rays) |ray| {
                if (ray.hit) {
                    const segment = [2]Vec3f32{ ray.start, ray.hit_point };
                    try renderer.drawLines(&segment, fw.color.green, .identity);
                    points[hits * 3 ..][0..3].* = ray.hit_point;
                    normals[hits * 3 ..][0..3].* = ray.hit_normal;
                    hits += 1;
                } else {
                    const segment = [2]Vec3f32{
                        ray.start,
                        vec.add(ray.start, vec.scale(ray.dir, miss_length)),
                    };
                    try renderer.drawLines(&segment, fw.color.white, .identity);
                }
            }
            if (hits != 0) {
                try renderer.drawVectors(
                    points[0 .. hits * 3],
                    3 * @sizeOf(f32),
                    normals[0 .. hits * 3],
                    3 * @sizeOf(f32),
                    hits,
                    normal_length,
                    fw.color.red,
                    .identity,
                );
            }
        }

        if (self.show_ankle_target) {
            for (self.rays, self.ankles_target_ws, self.reached) |ray, target, reached| {
                if (!ray.hit) continue;
                const transform = Float4x4.fromTransform(.{ .translation = target });
                try renderer.drawAxes(Float4x4.mul(transform, scale));
                try renderer.drawSphereIm(
                    target_radius,
                    transform,
                    if (reached) fw.color.green else fw.color.red,
                );
            }
        }

        if (self.show_root) try renderer.drawAxes(self.rootTransform());
        if (self.show_offsetted_root) try renderer.drawAxes(offsetted_root);
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        var buffer: [64]u8 = undefined;

        if (gui.openClose("Sample options", true)) {
            _ = gui.doCheckBox("Auto character height", &self.auto_character_height, true);
            _ = gui.doCheckBox("Pelvis correction", &self.pelvis_correction, true);
            _ = gui.doCheckBox("Two bone IK (legs)", &self.two_bone_ik, true);
            _ = gui.doCheckBox("Aim IK (ankles)", &self.aim_ik, true);
        }

        if (gui.openClose("Animation control", true)) {
            self.controller.onGui(gui, self.clip.duration(), true, true);
        }

        if (gui.openClose("IK settings", true)) {
            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "Foot height {d:.2}", .{self.foot_height}),
                0,
                0.3,
                &self.foot_height,
                1,
                true,
            );
            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "Weight {d:.2}", .{self.weight}),
                0,
                1,
                &self.weight,
                1,
                true,
            );
            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "Soften {d:.2}", .{self.soften}),
                0,
                1,
                &self.soften,
                1,
                self.two_bone_ik,
            );
        }

        if (gui.openClose("Root transformation", true)) {
            var moved = false;
            var translation: [3]f32 = self.root_translation;

            gui.doLabel("Translation", .{});
            moved = gui.doSlider(
                fw.im.formatZ(&buffer, "x {d:.2}", .{translation[0]}),
                -10,
                10,
                &translation[0],
                1,
                true,
            ) or moved;
            // The vertical position is driven by the floor raycast unless the
            // automatic height is switched off.
            moved = gui.doSlider(
                fw.im.formatZ(&buffer, "y {d:.2}", .{translation[1]}),
                0,
                5,
                &translation[1],
                1,
                !self.auto_character_height,
            ) or moved;
            moved = gui.doSlider(
                fw.im.formatZ(&buffer, "z {d:.2}", .{translation[2]}),
                -10,
                10,
                &translation[2],
                1,
                true,
            ) or moved;
            self.root_translation = translation;

            gui.doLabel("Rotation", .{});
            moved = gui.doSlider(
                fw.im.formatZ(&buffer, "yaw {d:.0}", .{self.root_yaw * radian_to_degree}),
                -std.math.pi,
                std.math.pi,
                &self.root_yaw,
                1,
                true,
            ) or moved;

            // The gui runs after the frame update, so moving the character here
            // would otherwise leave it hovering until the next frame. Upstream
            // re-enters `OnUpdate` for exactly this reason.
            if (moved and self.auto_character_height) {
                _ = self.onUpdate(0, 0) catch {};
            }
        }

        if (gui.openClose("Debug options", true)) {
            _ = gui.doCheckBox("Show skin", &self.show_skin, true);
            _ = gui.doCheckBox("Show joints", &self.show_joints, true);
            _ = gui.doCheckBox("Show raycasts", &self.show_raycast, true);
            _ = gui.doCheckBox("Show ankle target", &self.show_ankle_target, true);
            _ = gui.doCheckBox("Show root", &self.show_root, true);
            _ = gui.doCheckBox("Show offsetted root", &self.show_offsetted_root, true);
        }
    }

    /// Upstream publishes an invalid box so the camera never auto-frames the
    /// character; the initial setup below is what positions the view.
    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        _ = self;
        return null;
    }

    pub fn cameraInitialSetup(self: *Sample) ?fw.camera.Setup {
        _ = self;
        return .{
            .center = .{ 4.7, 2.3, -0.13 },
            .angles = .{ -0.14, -2.1 },
            .distance = 5.9,
        };
    }

    // -- implementation -------------------------------------------------------

    /// World transform of the character, before the pelvis correction.
    fn rootTransform(self: Sample) Float4x4 {
        return Float4x4.fromTransform(.{
            .translation = self.root_translation,
            .rotation = Quaternion.fromEuler(.{ 0, self.root_yaw, 0 }),
        });
    }

    /// World transform of the character, pelvis correction included.
    fn offsettedRootTransform(self: Sample) Float4x4 {
        if (!self.pelvis_correction) return self.rootTransform();
        return Float4x4.fromTransform(.{
            .translation = vec.add(self.pelvis_offset, self.root_translation),
            .rotation = Quaternion.fromEuler(.{ 0, self.root_yaw, 0 }),
        });
    }

    /// Step 1: samples the animation and builds model-space matrices.
    fn updateBaseAnimation(self: *Sample, dt: f32) !void {
        _ = self.controller.update(self.clip.duration(), dt);
        try self.clip.sample(self.controller.time_ratio);
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.clip.pose,
        }, self.models);
    }

    /// Step 2: drops the character onto the floor, straight below its root.
    fn updateCharacterHeight(self: *Sample) void {
        if (!self.auto_character_height) return;
        const origin = vec.add(self.root_translation, character_ray_height_offset);
        if (fw.utils.rayIntersectsMeshes(origin, down, self.floors)) |hit| {
            self.root_translation = hit.point;
        }
    }

    /// Step 3: one downward raycast per ankle. The pelvis offset is not known
    /// yet, so the *unoffsetted* root is deliberately used here.
    fn raycastLegs(self: *Sample) void {
        const root = self.rootTransform();
        for (&self.legs, &self.rays, &self.ankles_initial_ws) |leg, *ray, *initial| {
            initial.* = Float4x4.transformPoint(root, self.models[leg.ankle].translation());
            ray.start = vec.add(initial.*, foot_ray_height_offset);
            ray.dir = down;
            if (fw.utils.rayIntersectsMeshes(ray.start, ray.dir, self.floors)) |hit| {
                ray.hit = true;
                ray.hit_point = hit.point;
                ray.hit_normal = hit.normal;
            } else {
                ray.hit = false;
            }
        }
    }

    /// Step 4: ankle target (C) such that the tilted foot still rests on the
    /// floor. A sloped floor means the ankle cannot simply be lifted by the
    /// foot height along the normal, so H is found with Thales' theorem first.
    fn updateAnklesTarget(self: *Sample) void {
        for (self.rays, &self.ankles_target_ws) |ray, *target| {
            if (!ray.hit) continue;

            // Projection of AI (ray start to floor intersection) onto the floor
            // normal: the length of AB. `hit_normal` is already normalized.
            const ab_length = vec.dot(vec.sub(ray.start, ray.hit_point), ray.hit_normal);
            // Perpendicular ray and floor: nothing to correct.
            if (ab_length == 0) continue;

            const b = vec.sub(ray.start, vec.scale(ray.hit_normal, ab_length));
            const ib = vec.sub(b, ray.hit_point);
            const ib_length = vec.norm(ib);

            if (ib_length <= 0) {
                // B sits on the intersection: only the foot height applies.
                target.* = vec.add(ray.hit_point, vec.scale(ray.hit_normal, self.foot_height));
            } else {
                // HC is the foot height, so Thales gives IH, then H, then C.
                const ih_length = ib_length * self.foot_height / ab_length;
                const h = vec.add(ray.hit_point, vec.scale(ib, ih_length / ib_length));
                target.* = vec.add(h, vec.scale(ray.hit_normal, self.foot_height));
            }
        }
    }

    /// Step 5: moves the pelvis down the ray axis, far enough for the lowest
    /// foot (lowest relative to its animated position) to reach its target.
    /// The other leg is then bent by IK.
    fn updatePelvisOffset(self: *Sample) void {
        self.pelvis_offset = .{ 0, 0, 0 };
        if (!self.pelvis_correction) return;

        var max_dot = -std.math.floatMax(f32);
        for (self.rays, self.ankles_target_ws, self.ankles_initial_ws) |ray, target, initial| {
            if (!ray.hit) continue;
            const dot = vec.dot(vec.sub(target, initial), down);
            if (dot > max_dot) {
                max_dot = dot;
                self.pelvis_offset = vec.scale(down, dot);
            }
        }
    }

    /// Step 6: two bone IK on the leg, then aim IK on the ankle.
    fn updateFootIk(self: *Sample) !void {
        // The pelvis offset is part of the model-space conversion now, so the
        // *offsetted* root is the one to invert.
        const inv_root = Float4x4.inverse(self.offsettedRootTransform()) orelse return;

        for (&self.legs, self.rays, self.ankles_target_ws, &self.reached) |leg, ray, target, *reached| {
            if (!ray.hit) {
                reached.* = false;
                continue;
            }

            if (self.two_bone_ik) {
                reached.* = try self.applyLegTwoBoneIk(leg, target, inv_root);
            } else {
                reached.* = false;
            }

            // Refreshes the leg only. The ankle's siblings stay stale on
            // purpose: the aim pass below is about to change the ankle again.
            try ozz.animation.localToModel(.{
                .skeleton = &self.skeleton,
                .input = self.clip.pose,
                .from = leg.hip,
                .to = leg.ankle,
            }, self.models);

            // Aims the ankle up vector at the floor normal.
            if (self.aim_ik) {
                try self.applyAnkleAimIk(leg, vec.add(target, ray.hit_normal), inv_root);
            }

            // The ankle rotation is final: everything below the hip has to be
            // rebuilt, siblings included.
            try ozz.animation.localToModel(.{
                .skeleton = &self.skeleton,
                .input = self.clip.pose,
                .from = leg.hip,
            }, self.models);
        }
    }

    /// Two bone IK over hip / knee / ankle so the ankle reaches `target_ws`.
    /// Returns the job's `reached` output.
    fn applyLegTwoBoneIk(
        self: *Sample,
        leg: Leg,
        target_ws: Vec3f32,
        inv_root: Float4x4,
    ) !bool {
        const target_ms = Float4x4.transformPoint(inv_root, target_ws);
        // The knee's own Y axis polls the knee toward its animated direction.
        const pole_vector_ms = axis(self.models[leg.knee], 1);

        const result = try ozz.animation.twoBoneIk(.{
            .target = target_ms,
            .pole_vector = pole_vector_ms,
            .mid_axis = knee_axis,
            .weight = self.weight,
            .soften = self.soften,
            .start_joint = self.models[leg.hip],
            .mid_joint = self.models[leg.knee],
            .end_joint = self.models[leg.ankle],
        });

        fw.utils.multiplySoATransformQuaternion(leg.hip, result.start_correction, self.clip.pose);
        fw.utils.multiplySoATransformQuaternion(leg.knee, result.mid_correction, self.clip.pose);
        return result.reached;
    }

    /// Aim IK on the ankle: its up vector is aligned with the floor normal,
    /// while the pole vector keeps the foot pointing where the animation had it.
    fn applyAnkleAimIk(
        self: *Sample,
        leg: Leg,
        target_ws: Vec3f32,
        inv_root: Float4x4,
    ) !void {
        const target_ms = Float4x4.transformPoint(inv_root, target_ws);
        const result = try ozz.animation.aimIk(.{
            .target = target_ms,
            .joint = self.models[leg.ankle],
            .forward = ankle_forward,
            .up = ankle_up,
            .pole_vector = axis(self.models[leg.ankle], 1),
            .weight = self.weight,
        });
        fw.utils.multiplySoATransformQuaternion(leg.ankle, result.correction, self.clip.pose);
    }
};

/// One basis vector of a model-space matrix, i.e. upstream's `cols[index]` read
/// as a direction.
fn axis(matrix: Float4x4, index: usize) Vec3f32 {
    const column = matrix.cols[index];
    return .{ column[0], column[1], column[2] };
}

/// Upstream's `SetupLeg`, with the framework's name lookup so a differently
/// named rig supplied through `--skeleton=` still resolves.
fn setupLeg(skeleton: ozz.animation.Skeleton, names: []const []const u8) ?Leg {
    const chain = fw.utils.findNamedChain3(skeleton, names) orelse return null;
    return .{ .hip = chain[0], .knee = chain[1], .ankle = chain[2] };
}

// -----------------------------------------------------------------------------
// Tests — all headless, none of them touch the renderer.
// -----------------------------------------------------------------------------

const testing = std.testing;

/// World-space ankle position, pelvis correction included.
fn ankleWorld(sample: Sample, leg: usize) Vec3f32 {
    return Float4x4.transformPoint(
        sample.offsettedRootTransform(),
        sample.models[sample.legs[leg].ankle].translation(),
    );
}

/// Distance from the solved ankle to the target the raycast produced.
fn ankleError(sample: Sample, leg: usize) f32 {
    return vec.norm(vec.sub(ankleWorld(sample, leg), sample.ankles_target_ws[leg]));
}

/// World-space direction the aim job points at the floor normal. The job aims
/// the joint's `forward` vector at its target, and the target here is one floor
/// normal away from the ankle, so it is `ankle_forward` that ends up aligned
/// with the normal — `ankle_up` only feeds the pole/plane rotation.
fn ankleForwardWorld(sample: Sample, leg: usize) Vec3f32 {
    const joint = Float4x4.mul(
        sample.offsettedRootTransform(),
        sample.models[sample.legs[leg].ankle],
    );
    return vec.normalize(Float4x4.transformVector(joint, ankle_forward));
}

test "sample loads both legs, the character and the floor" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    try testing.expectEqualStrings("LeftUpLeg", sample.skeleton.names[sample.legs[left].hip]);
    try testing.expectEqualStrings("LeftFoot", sample.skeleton.names[sample.legs[left].ankle]);
    try testing.expectEqualStrings("RightUpLeg", sample.skeleton.names[sample.legs[right].hip]);
    for (sample.legs) |leg| {
        try testing.expectEqual(leg.hip, @as(usize, @intCast(sample.skeleton.parents[leg.knee])));
        try testing.expectEqual(leg.knee, @as(usize, @intCast(sample.skeleton.parents[leg.ankle])));
    }
    try testing.expect(sample.meshes.len > 0);
    try testing.expect(sample.floors.len > 0);
}

test "the character is dropped onto the floor and both feet raycast onto it" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.controller.play = false;
    // Starts well above the floor; the automatic height must pull it down.
    sample.root_translation = .{ 2.17, 5, -2.06 };
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(sample.root_translation[1] < 5);

    // The raycasts start above the ankles and hit the floor below them.
    for (sample.rays, sample.ankles_initial_ws) |ray, initial| {
        try testing.expect(ray.hit);
        try testing.expectApproxEqAbs(initial[1] + 0.5, ray.start[1], 1e-5);
        try testing.expect(ray.hit_point[1] < ray.start[1]);
        try testing.expectApproxEqAbs(@as(f32, 1), vec.norm(ray.hit_normal), 1e-4);
    }

    // Disabling the automatic height leaves the root exactly where it was put.
    sample.auto_character_height = false;
    sample.root_translation = .{ 2.17, 3, -2.06 };
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expectEqual(@as(f32, 3), sample.root_translation[1]);
}

test "ankle targets sit one foot height off the floor along its normal" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.controller.play = false;
    try testing.expect(try sample.onUpdate(0, 0));

    for (sample.rays, sample.ankles_target_ws) |ray, target| {
        try testing.expect(ray.hit);
        // C is exactly `foot_height` above the floor plane through I.
        const above = vec.dot(vec.sub(target, ray.hit_point), ray.hit_normal);
        try testing.expectApproxEqAbs(sample.foot_height, above, 1e-4);
    }

    // A taller foot pushes the target further up the normal.
    const previous = sample.ankles_target_ws[left];
    sample.foot_height = 0.25;
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expect(sample.ankles_target_ws[left][1] > previous[1]);
}

test "two bone ik brings each ankle onto its target" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.controller.play = false;

    // Without IK the ankles stay wherever the animation put them.
    sample.two_bone_ik = false;
    sample.aim_ik = false;
    try testing.expect(try sample.onUpdate(0, 0));
    const without = [leg_count]f32{ ankleError(sample, left), ankleError(sample, right) };
    try testing.expect(without[left] > 1e-3 or without[right] > 1e-3);

    // With it, both ankles land on their targets.
    sample.two_bone_ik = true;
    try testing.expect(try sample.onUpdate(0, 0));
    for (0..leg_count) |leg| {
        try testing.expect(ankleError(sample, leg) < without[leg] + 1e-6);
        try testing.expect(ankleError(sample, leg) < 1e-3);
    }

    // A zero weight is equivalent to switching the pass off.
    sample.weight = 0;
    try testing.expect(try sample.onUpdate(0, 0));
    for (0..leg_count) |leg| {
        try testing.expectApproxEqAbs(without[leg], ankleError(sample, leg), 1e-4);
        try testing.expect(!sample.reached[leg]);
    }
}

test "aim ik aligns the ankle with the floor normal" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.controller.play = false;

    sample.aim_ik = false;
    try testing.expect(try sample.onUpdate(0, 0));
    const without = vec.dot(ankleForwardWorld(sample, left), sample.rays[left].hit_normal);

    sample.aim_ik = true;
    try testing.expect(try sample.onUpdate(0, 0));
    const with = vec.dot(ankleForwardWorld(sample, left), sample.rays[left].hit_normal);

    try testing.expect(with > without);
    try testing.expect(with > 0.99);
}

test "pelvis correction drops the character by the lowest foot" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.controller.play = false;

    sample.pelvis_correction = false;
    try testing.expect(try sample.onUpdate(0, 0));
    try testing.expectEqual(Vec3f32{ 0, 0, 0 }, sample.pelvis_offset);
    const unoffsetted = sample.offsettedRootTransform().translation();

    sample.pelvis_correction = true;
    try testing.expect(try sample.onUpdate(0, 0));
    // The offset only ever moves the character along the ray axis.
    try testing.expectEqual(@as(f32, 0), sample.pelvis_offset[0]);
    try testing.expectEqual(@as(f32, 0), sample.pelvis_offset[2]);

    // It is the largest downward displacement any foot needs.
    var expected: f32 = -std.math.floatMax(f32);
    for (sample.rays, sample.ankles_target_ws, sample.ankles_initial_ws) |ray, target, initial| {
        if (!ray.hit) continue;
        expected = @max(expected, vec.dot(vec.sub(target, initial), down));
    }
    try testing.expectApproxEqAbs(-expected, sample.pelvis_offset[1], 1e-5);
    try testing.expectApproxEqAbs(
        unoffsetted[1] + sample.pelvis_offset[1],
        sample.offsettedRootTransform().translation()[1],
        1e-5,
    );
}

test "the partial local-to-model ranges leave the rest of the skeleton alone" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.controller.play = false;

    // Reference pose with every IK pass disabled.
    sample.two_bone_ik = false;
    sample.aim_ik = false;
    sample.pelvis_correction = false;
    try testing.expect(try sample.onUpdate(0, 0));
    const reference = try testing.allocator.dupe(Float4x4, sample.models);
    defer testing.allocator.free(reference);

    sample.two_bone_ik = true;
    sample.aim_ik = true;
    try testing.expect(try sample.onUpdate(0, 0));

    // Joints outside both legs' sub-trees must be untouched, and the leg
    // joints themselves must have moved.
    for (reference, sample.models, 0..) |before, after, joint| {
        const moved = vec.norm(vec.sub(before.translation(), after.translation())) > 1e-5;
        var in_leg = false;
        for (sample.legs) |leg| {
            if (isDescendant(sample.skeleton, joint, leg.hip)) in_leg = true;
        }
        if (!in_leg) try testing.expect(!moved);
    }
    try testing.expect(ankleError(sample, left) < 1e-3);
    try testing.expect(ankleError(sample, right) < 1e-3);
}

/// True when `joint` is `ancestor` or one of its descendants.
fn isDescendant(skeleton: ozz.animation.Skeleton, joint: usize, ancestor: usize) bool {
    var current: i16 = @intCast(joint);
    while (current != ozz.animation.no_parent) : (current = skeleton.parents[@intCast(current)]) {
        if (@as(usize, @intCast(current)) == ancestor) return true;
    }
    return false;
}

test "a character standing off the floor gets no hits and no correction" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    sample.controller.play = false;
    sample.auto_character_height = false;
    // Far outside the floor's extent: every raycast misses.
    sample.root_translation = .{ 1000, 2, 1000 };
    try testing.expect(try sample.onUpdate(0, 0));

    for (sample.rays, sample.reached) |ray, reached| {
        try testing.expect(!ray.hit);
        try testing.expect(!reached);
    }
    try testing.expectEqual(Vec3f32{ 0, 0, 0 }, sample.pelvis_offset);
}

test "gui runs headless and several frames of playback are stable" {
    var sample = try Sample.init(testing.allocator, .{});
    defer sample.deinit();

    var gui = fw.Im.init(false);
    sample.onGui(&gui);

    for (0..10) |_| {
        try testing.expect(try sample.onUpdate(1.0 / 60.0, 0));
        for (sample.rays, sample.ankles_target_ws) |ray, target| {
            if (!ray.hit) continue;
            const components: [3]f32 = target;
            for (components) |component| try testing.expect(std.math.isFinite(component));
        }
    }
    try testing.expect(sample.controller.time_ratio > 0);
    try testing.expect(sample.cameraInitialSetup() != null);
    try testing.expect(sample.sceneBounds() == null);
}
