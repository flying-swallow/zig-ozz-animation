// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/framework/utils.{h,cc}` plus the shared sample
//! helpers that used to live in `samples/src/demo.zig`.
//!
//! Everything here is GPU-free: the only GUI dependency is the duck-typed `gui`
//! parameter, which the application passes as a `*Im` (see `framework/im.zig`).

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const mesh_utils = @import("mesh.zig");

const Vec3f32 = ozz.math.Vec3f32;
const Quaternion = ozz.math.Quaternion;
const Float4x4 = ozz.math.Float4x4;
const Transform = ozz.math.Transform;
const vec = ozz.math.vec;

const radian_to_degree: f32 = 180.0 / std.math.pi;
const degree_to_radian: f32 = std.math.pi / 180.0;

// -----------------------------------------------------------------------------
// PlaybackController
// -----------------------------------------------------------------------------

/// Utility to control animation playback: time, speed, looping and pause.
/// Time is always expressed as a ratio in the unit interval, matching
/// `ozz::sample::PlaybackController` (utils.cc:54-140). Supersedes the earlier
/// `framework/playback.zig` controller.
pub const PlaybackController = struct {
    /// Current time ratio in the unit interval [0, 1].
    time_ratio: f32 = 0,
    /// Time ratio of the previous update, before wrapping.
    previous_time_ratio: f32 = 0,
    /// Playback speed, negative values play the animation backwards.
    playback_speed: f32 = 1,
    /// Animation play mode: play/pause.
    play: bool = true,
    /// Animation loop mode.
    loop: bool = true,
    /// Set by `onGui` when the time slider was moved this frame. Upstream returns
    /// this from `OnGui`; the API contract declares `onGui` as `void`, so the flag
    /// is published as a field instead.
    time_changed: bool = false,

    /// Advances the time by `dt` seconds over an animation of `duration` seconds
    /// and returns the number of loops completed this frame, negative when playing
    /// backwards. Always refreshes `previous_time_ratio`, even while paused.
    pub fn update(self: *PlaybackController, duration: f32, dt: f32) i32 {
        var new_ratio = self.time_ratio;
        // Upstream divides unconditionally; guarding keeps a degenerate
        // zero-length animation from producing NaN.
        if (self.play and duration > 0) {
            new_ratio = self.time_ratio + dt * self.playback_speed / duration;
        }
        return self.applyTimeRatio(new_ratio);
    }

    /// Sets the current time ratio, wrapping or clamping it depending on `loop`.
    pub fn setTimeRatio(self: *PlaybackController, ratio: f32) void {
        _ = self.applyTimeRatio(ratio);
    }

    /// `setTimeRatio` returning the number of loops `ratio` spans, which is what
    /// `MotionSampler.update` consumes.
    pub fn applyTimeRatio(self: *PlaybackController, ratio: f32) i32 {
        self.previous_time_ratio = self.time_ratio;
        if (self.loop) {
            // Wraps into the unit interval [0, 1].
            const loops = @floor(ratio);
            self.time_ratio = ratio - loops;
            // Upstream casts straight to int; guard against a non-finite or
            // absurd ratio so the cast stays defined.
            if (!std.math.isFinite(loops) or @abs(loops) > 1e9) return 0;
            return @intFromFloat(loops);
        }
        // Clamps into the unit interval [0, 1].
        self.time_ratio = std.math.clamp(ratio, 0, 1);
        return 0;
    }

    /// Resets time, speed and play state. Deliberately leaves `loop` untouched,
    /// exactly like `PlaybackController::Reset`.
    pub fn reset(self: *PlaybackController) void {
        self.previous_time_ratio = 0;
        self.time_ratio = 0;
        self.playback_speed = 1;
        self.play = true;
        self.time_changed = false;
    }

    /// Exposes time, speed, loop and play through the immediate-mode gui.
    /// `duration` is the animation duration in seconds, used for the time label.
    pub fn onGui(
        self: *PlaybackController,
        gui: anytype,
        duration: f32,
        enabled: bool,
        allow_set_time: bool,
    ) void {
        self.time_changed = false;

        if (gui.doButton(if (self.play) "Pause" else "Play", enabled)) {
            self.play = !self.play;
        }
        _ = gui.doCheckBox("Loop", &self.loop, enabled);

        var buffer: [64]u8 = undefined;

        // Uses a local copy so that the change goes through `setTimeRatio`,
        // otherwise `previous_time_ratio` would be wrong.
        var ratio = self.time_ratio;
        if (gui.doSlider(
            label(&buffer, "Animation time: {d:.2}", .{ratio * duration}),
            0,
            1,
            &ratio,
            1,
            enabled and allow_set_time,
        )) {
            self.setTimeRatio(ratio);
            // Pauses playback when the slider is moved.
            self.play = false;
            self.time_changed = true;
        }

        _ = gui.doSlider(
            label(&buffer, "Playback speed: {d:.2}", .{self.playback_speed}),
            -3,
            3,
            &self.playback_speed,
            1,
            enabled,
        );
        if (gui.doButton("Reset playback speed", self.playback_speed != 1 and enabled)) {
            self.playback_speed = 1;
        }
    }
};

/// Formats a zero-terminated widget label into `buffer`, truncating instead of
/// failing when the formatted text does not fit.
fn label(buffer: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    return std.mem.printSentinel(buffer, fmt, args, 0) catch {
        buffer[buffer.len - 1] = 0;
        return buffer[0 .. buffer.len - 1 :0];
    };
}

// -----------------------------------------------------------------------------
// Bounds
// -----------------------------------------------------------------------------

/// Runs `localToModel` over the skeleton rest pose and unions the resulting joint
/// translations. Returns an invalid (empty) box for an empty skeleton, matching
/// `ComputeSkeletonBounds` (utils.cc:209).
pub fn computeSkeletonBounds(
    skeleton: ozz.animation.Skeleton,
    allocator: std.mem.Allocator,
) !ozz.math.Box {
    const joint_count = skeleton.numJoints();
    if (joint_count == 0) return ozz.math.Box.empty();

    const models = try allocator.alloc(Float4x4, joint_count);
    defer allocator.free(models);

    const local = skeleton;
    try ozz.animation.localToModel(.{
        .skeleton = &local,
        .input = skeleton.rest_poses,
    }, models);
    return computePostureBounds(models, null);
}

/// Unions the translations of model-space matrices, optionally pre-multiplied by
/// `transform`. Only joint positions are considered, exactly like
/// `ComputePostureBounds` (utils.cc:239).
pub fn computePostureBounds(
    matrices: []const Float4x4,
    transform: ?Float4x4,
) ozz.math.Box {
    var box = ozz.math.Box.empty();
    if (matrices.len == 0) return box;
    for (matrices) |current| {
        const world = if (transform) |t| Float4x4.mul(t, current) else current;
        box.expand(world.translation());
    }
    return box;
}

// -----------------------------------------------------------------------------
// SoA helpers
// -----------------------------------------------------------------------------

/// Right-multiplies the rotation of a single SoA lane by `quat`, converting the
/// lane to AoS and back like `MultiplySoATransformQuaternion` (utils.cc:269).
/// `transforms` may be a `[]ozz.math.SoaTransform` or a `[]ozz.math.SoaQuaternion`.
pub fn multiplySoATransformQuaternion(
    index: usize,
    quat: Quaternion,
    transforms: anytype,
) void {
    // Derived from the element rather than the container so slices,
    // pointers-to-array and arrays are all accepted.
    const Element = @TypeOf(transforms[index / 4]);
    // The dead branch is dropped because the condition is comptime known.
    if (comptime Element == ozz.math.SoaTransform) {
        multiplySoaQuaternion(index, quat, &transforms[index / 4].rotation);
    } else {
        multiplySoaQuaternion(index, quat, &transforms[index / 4]);
    }
}

/// Right-multiplies one lane of an SoA quaternion by `quat`.
fn multiplySoaQuaternion(
    index: usize,
    quat: Quaternion,
    rotation: *ozz.math.SoaQuaternion,
) void {
    const lane_index = index & 3;
    const current: Quaternion = .{
        .x = ozz.math.lane(rotation.x, lane_index),
        .y = ozz.math.lane(rotation.y, lane_index),
        .z = ozz.math.lane(rotation.z, lane_index),
        .w = ozz.math.lane(rotation.w, lane_index),
    };
    const result = Quaternion.mul(current, quat);
    ozz.math.setLane(&rotation.x, lane_index, result.x);
    ozz.math.setLane(&rotation.y, lane_index, result.y);
    ozz.math.setLane(&rotation.z, lane_index, result.z);
    ozz.math.setLane(&rotation.w, lane_index, result.w);
}

// -----------------------------------------------------------------------------
// Ray casting
// -----------------------------------------------------------------------------

/// Closest ray/triangle intersection: world-space hit point and the triangle's
/// geometric normal.
pub const RayHit = struct {
    point: Vec3f32,
    normal: Vec3f32,
};

const ray_epsilon: f32 = 1e-7;

/// Möller-Trumbore ray/triangle intersection (utils.cc:462). `direction` need not
/// be normalized; hits strictly behind the origin are rejected.
pub fn rayIntersectsTriangle(
    ray_origin: Vec3f32,
    ray_direction: Vec3f32,
    p0: Vec3f32,
    p1: Vec3f32,
    p2: Vec3f32,
) ?RayHit {
    const edge1 = vec.sub(p1, p0);
    const edge2 = vec.sub(p2, p0);
    const h = vec.cross(ray_direction, edge2);

    const a = vec.dot(edge1, h);
    // The ray is parallel to the triangle.
    if (a > -ray_epsilon and a < ray_epsilon) return null;

    const inv_a = 1 / a;
    const s = vec.sub(ray_origin, p0);
    const u = vec.dot(s, h) * inv_a;
    if (u < 0 or u > 1) return null;

    const q = vec.cross(s, edge1);
    const v = vec.dot(ray_direction, q) * inv_a;
    if (v < 0 or u + v > 1) return null;

    const t = vec.dot(edge2, q) * inv_a;
    // A line intersection behind the origin is not a ray intersection.
    if (t <= ray_epsilon) return null;

    return .{
        .point = vec.add(ray_origin, vec.scale(ray_direction, t)),
        .normal = vec.normalize(vec.cross(edge1, edge2)),
    };
}

/// Closest intersection of a ray with a mesh's triangle list. Unlike upstream,
/// which asserts a single unskinned part and indexes `parts[0]` directly, this
/// resolves indices across every part so multi-part rigid meshes also work.
pub fn rayIntersectsMesh(
    ray_origin: Vec3f32,
    ray_direction: Vec3f32,
    mesh: ozz.geometry.Mesh,
) ?RayHit {
    var best: ?RayHit = null;
    var best_distance: f32 = 0;

    var index: usize = 0;
    while (index + 2 < mesh.triangle_indices.len) : (index += 3) {
        const p0 = mesh_utils.vertexPosition(mesh, mesh.triangle_indices[index]) orelse continue;
        const p1 = mesh_utils.vertexPosition(mesh, mesh.triangle_indices[index + 1]) orelse continue;
        const p2 = mesh_utils.vertexPosition(mesh, mesh.triangle_indices[index + 2]) orelse continue;
        const hit = rayIntersectsTriangle(ray_origin, ray_direction, p0, p1, p2) orelse continue;
        const distance = vec.norm_sqr(vec.sub(hit.point, ray_origin));
        if (best == null or distance < best_distance) {
            best = hit;
            best_distance = distance;
        }
    }
    return best;
}

/// Closest intersection of a ray across several meshes (utils.cc:552).
pub fn rayIntersectsMeshes(
    ray_origin: Vec3f32,
    ray_direction: Vec3f32,
    meshes: []const ozz.geometry.Mesh,
) ?RayHit {
    var best: ?RayHit = null;
    var best_distance: f32 = 0;
    for (meshes) |mesh| {
        const hit = rayIntersectsMesh(ray_origin, ray_direction, mesh) orelse continue;
        const distance = vec.norm_sqr(vec.sub(hit.point, ray_origin));
        if (best == null or distance < best_distance) {
            best = hit;
            best_distance = distance;
        }
    }
    return best;
}

// -----------------------------------------------------------------------------
// Loaders (migrated from demo.zig)
// -----------------------------------------------------------------------------

/// A runtime animation together with its sampling context and local-space output,
/// which is the trio every sample needs to play one clip.
pub const Clip = struct {
    animation: ozz.animation.Animation,
    context: ozz.animation.SamplingContext,
    pose: []ozz.math.SoaTransform,

    /// Decodes a runtime animation from an upstream `.ozz` archive.
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Clip {
        var reader = std.Io.Reader.fixed(bytes);
        const animation = try ozz.legacy.readAnimation(allocator, &reader, .{});
        return init(allocator, animation);
    }

    /// Takes ownership of `animation`, allocating its sampling context and pose.
    pub fn init(allocator: std.mem.Allocator, animation: ozz.animation.Animation) !Clip {
        errdefer {
            var value = animation;
            value.deinit();
        }
        const context = try ozz.animation.SamplingContext.init(allocator, animation.numTracks());
        errdefer {
            var value = context;
            value.deinit();
        }
        const pose = try allocator.alloc(ozz.math.SoaTransform, animation.numSoaTracks());
        return .{ .animation = animation, .context = context, .pose = pose };
    }

    pub fn deinit(self: *Clip) void {
        const allocator = self.animation.allocator;
        allocator.free(self.pose);
        self.context.deinit();
        self.animation.deinit();
        self.* = undefined;
    }

    /// Samples the animation at `ratio` into `pose`.
    pub fn sample(self: *Clip, ratio: f32) !void {
        try ozz.animation.sample(&self.animation, ratio, &self.context, self.pose);
    }

    /// Animation duration in seconds.
    pub fn duration(self: Clip) f32 {
        return self.animation.duration;
    }
};

/// Decodes a runtime skeleton from an upstream `.ozz` archive.
pub fn decodeSkeleton(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !ozz.animation.Skeleton {
    var reader = std.Io.Reader.fixed(bytes);
    return ozz.legacy.readSkeleton(allocator, &reader, .{});
}

/// Decodes an offline raw animation from an upstream `.ozz` archive.
pub fn decodeRawAnimation(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !ozz.offline.RawAnimation {
    var reader = std.Io.Reader.fixed(bytes);
    return ozz.legacy.readRawAnimation(allocator, &reader, .{});
}

/// Deep-copies a raw animation so the source can be optimized repeatedly.
pub fn cloneRawAnimation(
    allocator: std.mem.Allocator,
    source: ozz.offline.RawAnimation,
) !ozz.offline.RawAnimation {
    var clone = try ozz.offline.RawAnimation.init(
        allocator,
        source.name,
        source.duration,
        source.tracks.len,
    );
    errdefer clone.deinit();
    for (source.tracks, clone.tracks) |input, *output| {
        output.translations = try allocator.dupe(
            ozz.offline.TranslationKey,
            input.translations,
        );
        output.rotations = try allocator.dupe(
            ozz.offline.RotationKey,
            input.rotations,
        );
        output.scales = try allocator.dupe(
            ozz.offline.ScaleKey,
            input.scales,
        );
    }
    return clone;
}

// -----------------------------------------------------------------------------
// Joint lookup (migrated from demo.zig)
// -----------------------------------------------------------------------------

/// True when `needle` appears anywhere in `haystack`, ignoring ASCII case.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |offset| {
        if (std.ascii.eqlIgnoreCase(haystack[offset..][0..needle.len], needle)) {
            return true;
        }
    }
    return false;
}

/// Finds the first joint matching any of `names` exactly, then falls back to a
/// case-insensitive substring search so ports of differently-named rigs still work.
pub fn findNamedJoint(skeleton: ozz.animation.Skeleton, names: []const []const u8) ?usize {
    for (names) |name| if (ozz.animation.findJoint(skeleton, name)) |joint| return joint;
    for (skeleton.names, 0..) |joint_name, joint| {
        for (names) |name| {
            if (containsIgnoreCase(joint_name, name)) return joint;
        }
    }
    return null;
}

/// Finds the first joint whose name contains `needle`, ignoring ASCII case.
pub fn findJointContaining(skeleton: ozz.animation.Skeleton, needle: []const u8) ?usize {
    for (skeleton.names, 0..) |name, joint| {
        if (containsIgnoreCase(name, needle)) return joint;
    }
    return null;
}

/// Resolves three joints by name; null when `names` is short or any name misses.
pub fn findNamedChain3(
    skeleton: ozz.animation.Skeleton,
    names: []const []const u8,
) ?[3]usize {
    if (names.len < 3) return null;
    var result: [3]usize = undefined;
    for (names[0..3], &result) |name, *joint| {
        joint.* = findNamedJoint(skeleton, &.{name}) orelse return null;
    }
    return result;
}

/// Resolves four joints by name; null when `names` is short or any name misses.
pub fn findNamedChain4(
    skeleton: ozz.animation.Skeleton,
    names: []const []const u8,
) ?[4]usize {
    if (names.len < 4) return null;
    var result: [4]usize = undefined;
    for (names[0..4], &result) |name, *joint| {
        joint.* = findNamedJoint(skeleton, &.{name}) orelse return null;
    }
    return result;
}

/// Returns the first grandchild/child/parent triple found in the hierarchy, used
/// as a generic two-bone IK chain when no named chain matches.
pub fn findThreeJointChain(skeleton: ozz.animation.Skeleton) ?[3]usize {
    for (skeleton.parents, 0..) |end_parent, end| {
        if (end_parent == ozz.animation.no_parent) continue;
        const mid: usize = @intCast(end_parent);
        const start_parent = skeleton.parents[mid];
        if (start_parent == ozz.animation.no_parent) continue;
        return .{ @intCast(start_parent), mid, end };
    }
    return null;
}

// -----------------------------------------------------------------------------
// RawSkeletonEditor
// -----------------------------------------------------------------------------

/// Immediate-mode editor for an offline `RawSkeleton` (utils.cc:143-205).
/// Upstream keeps a `vector<bool>` of open/close states; `Im.openClose` owns that
/// state on our side, so the editor itself is stateless.
pub const RawSkeletonEditor = struct {
    /// Whether joint sub-trees start expanded.
    open_by_default: bool = false,

    /// Returns true when any joint transform was modified, so the caller knows it
    /// has to rebuild the runtime skeleton.
    pub fn onGui(
        self: *RawSkeletonEditor,
        raw: *ozz.offline.RawSkeleton,
        gui: anytype,
    ) bool {
        return editJoints(raw.roots, gui, self.open_by_default);
    }
};

fn editJoints(joints: []ozz.offline.RawJoint, gui: anytype, open_by_default: bool) bool {
    var modified = false;
    var buffer: [128]u8 = undefined;
    for (joints) |*joint| {
        const title = label(&buffer, "{s}", .{joint.name});
        if (!gui.openClose(title, open_by_default)) continue;

        // Translation. `Vec3f32` is a `@Vector`, whose elements cannot be
        // addressed, so each component round-trips through a plain array.
        gui.doLabel("Translation", .{});
        var translation: [3]f32 = joint.transform.translation;
        inline for (.{ "x", "y", "z" }, 0..) |axis, component| {
            modified = gui.doSlider(
                label(&buffer, axis ++ " {d:.2}", .{translation[component]}),
                -1,
                1,
                &translation[component],
                1,
                true,
            ) or modified;
        }
        joint.transform.translation = translation;

        // Rotation, edited in degrees through an Euler decomposition.
        gui.doLabel("Rotation", .{});
        var euler: [3]f32 = vec.scale(
            Quaternion.toEuler(joint.transform.rotation),
            radian_to_degree,
        );
        var euler_modified = false;
        inline for (.{ "x", "y", "z" }, 0..) |axis, component| {
            euler_modified = gui.doSlider(
                label(&buffer, axis ++ " {d:.3}", .{euler[component]}),
                -180,
                180,
                &euler[component],
                1,
                true,
            ) or euler_modified;
        }
        if (euler_modified) {
            modified = true;
            joint.transform.rotation = Quaternion.fromEuler(
                vec.scale(@as(Vec3f32, euler), degree_to_radian),
            );
        }

        // Scale, forced uniform and never exactly zero.
        gui.doLabel("Scale", .{});
        var scale: f32 = joint.transform.scale[0];
        if (gui.doSlider(label(&buffer, "{d:.2}", .{scale}), -1, 1, &scale, 1, true)) {
            modified = true;
            joint.transform.scale = @splat(if (scale != 0) scale else 0.01);
        }

        modified = editJoints(joint.children, gui, open_by_default) or modified;
    }
    return modified;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

/// Headless stand-in for `framework/im.zig`'s `Im`, exercising the duck-typed gui
/// calls without ImGui. `slider_delta` simulates the user dragging every slider.
const TestGui = struct {
    buttons: usize = 0,
    checkboxes: usize = 0,
    sliders: usize = 0,
    labels: usize = 0,
    open: bool = true,
    click_next_button: bool = false,
    slider_delta: f32 = 0,

    fn beginForm(self: *TestGui, title: [:0]const u8) bool {
        _ = title;
        _ = self;
        return true;
    }
    fn endForm(self: *TestGui) void {
        _ = self;
    }
    fn openClose(self: *TestGui, title: [:0]const u8, open_by_default: bool) bool {
        _ = title;
        _ = open_by_default;
        return self.open;
    }
    fn doButton(self: *TestGui, label_text: [:0]const u8, enabled: bool) bool {
        _ = label_text;
        self.buttons += 1;
        return enabled and self.click_next_button;
    }
    fn doCheckBox(self: *TestGui, label_text: [:0]const u8, value: *bool, enabled: bool) bool {
        _ = label_text;
        _ = value;
        _ = enabled;
        self.checkboxes += 1;
        return false;
    }
    fn doSlider(
        self: *TestGui,
        label_text: [:0]const u8,
        min: f32,
        max: f32,
        value: *f32,
        pow: f32,
        enabled: bool,
    ) bool {
        _ = label_text;
        _ = pow;
        self.sliders += 1;
        if (!enabled or self.slider_delta == 0) return false;
        value.* = std.math.clamp(value.* + self.slider_delta, min, max);
        return true;
    }
    fn doLabel(self: *TestGui, comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
        self.labels += 1;
    }
    fn separator(self: *TestGui) void {
        _ = self;
    }
};

test "playback controller wraps and reports loop counts" {
    var controller: PlaybackController = .{ .time_ratio = 0.9 };

    try std.testing.expectEqual(@as(i32, 1), controller.applyTimeRatio(1.2));
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), controller.time_ratio, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), controller.previous_time_ratio, 1e-6);

    try std.testing.expectEqual(@as(i32, -1), controller.applyTimeRatio(-0.1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), controller.time_ratio, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), controller.previous_time_ratio, 1e-6);

    // Several loops in one step.
    try std.testing.expectEqual(@as(i32, 3), controller.applyTimeRatio(3.25));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), controller.time_ratio, 1e-6);
}

test "playback controller clamps when not looping" {
    var controller: PlaybackController = .{ .loop = false };
    try std.testing.expectEqual(@as(i32, 0), controller.applyTimeRatio(2));
    try std.testing.expectEqual(@as(f32, 1), controller.time_ratio);

    controller.playback_speed = -1;
    _ = controller.update(1, 2);
    try std.testing.expectEqual(@as(f32, 0), controller.time_ratio);
    try std.testing.expectEqual(@as(f32, 1), controller.previous_time_ratio);
}

test "playback controller update honours play, speed and reset" {
    var controller: PlaybackController = .{};
    // Half a second into a two second animation is a quarter of the way through.
    try std.testing.expectEqual(@as(i32, 0), controller.update(2, 0.5));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), controller.time_ratio, 1e-6);

    // Paused updates still refresh previous_time_ratio but freeze time.
    controller.play = false;
    _ = controller.update(2, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), controller.time_ratio, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), controller.previous_time_ratio, 1e-6);

    // Speed scales the advance.
    controller.play = true;
    controller.playback_speed = 2;
    _ = controller.update(2, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), controller.time_ratio, 1e-6);

    controller.loop = false;
    controller.reset();
    try std.testing.expectEqual(@as(f32, 0), controller.time_ratio);
    try std.testing.expectEqual(@as(f32, 0), controller.previous_time_ratio);
    try std.testing.expectEqual(@as(f32, 1), controller.playback_speed);
    try std.testing.expect(controller.play);
    // Reset does not restore the loop mode.
    try std.testing.expect(!controller.loop);

    // A zero-length animation must not produce NaN.
    controller.loop = true;
    _ = controller.update(0, 0.5);
    try std.testing.expectEqual(@as(f32, 0), controller.time_ratio);
}

test "playback controller gui pauses when the time slider moves" {
    var controller: PlaybackController = .{ .time_ratio = 0.5 };
    var gui: TestGui = .{ .slider_delta = 0.1 };
    controller.onGui(&gui, 2, true, true);

    try std.testing.expect(controller.time_changed);
    try std.testing.expect(!controller.play);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), controller.time_ratio, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), controller.previous_time_ratio, 1e-6);
    // Play/Pause + Reset playback speed, one loop check box, two sliders.
    try std.testing.expectEqual(@as(usize, 2), gui.buttons);
    try std.testing.expectEqual(@as(usize, 1), gui.checkboxes);
    try std.testing.expectEqual(@as(usize, 2), gui.sliders);

    // A disabled gui leaves everything alone.
    var untouched: PlaybackController = .{ .time_ratio = 0.5 };
    var disabled: TestGui = .{ .slider_delta = 0.1 };
    untouched.onGui(&disabled, 2, false, false);
    try std.testing.expect(!untouched.time_changed);
    try std.testing.expect(untouched.play);
    try std.testing.expectEqual(@as(f32, 0.5), untouched.time_ratio);
}

test "gui entry points accept the concrete Im facade" {
    // `gui` is declared `anytype` so the behavioural tests above can drive a
    // stub, but the published contract is `*Im`; this pins that down.
    const Im = @import("im.zig").Im;
    var gui = Im.init(false);

    var controller: PlaybackController = .{};
    controller.onGui(&gui, 1, true, true);
    try std.testing.expect(!controller.time_changed);

    var raw: ozz.offline.RawSkeleton = .{ .allocator = std.testing.allocator, .roots = &.{} };
    var editor: RawSkeletonEditor = .{};
    try std.testing.expect(!editor.onGui(&raw, &gui));
}

test "skeleton bounds cover the rest pose" {
    const allocator = std.testing.allocator;
    var skeleton = try decodeSkeleton(allocator, @embedFile("pab_skeleton"));
    defer skeleton.deinit();

    const box = try computeSkeletonBounds(skeleton, allocator);
    try std.testing.expect(box.isValid());
    // The pab character is roughly 1.7m tall and stands around the origin.
    try std.testing.expect(box.max[1] - box.min[1] > 1);
    try std.testing.expect(box.max[1] - box.min[1] < 3);
    try std.testing.expect(box.contains(skeleton.jointRestPose(0).translation));

    // Every rest-pose joint position must sit inside the box.
    const models = try allocator.alloc(Float4x4, skeleton.numJoints());
    defer allocator.free(models);
    try ozz.animation.localToModel(.{
        .skeleton = &skeleton,
        .input = skeleton.rest_poses,
    }, models);
    for (models) |model| try std.testing.expect(box.contains(model.translation()));

    // And the posture bounds of that same pose must match exactly.
    const posture = computePostureBounds(models, null);
    try std.testing.expectEqual(box.min, posture.min);
    try std.testing.expectEqual(box.max, posture.max);
}

test "posture bounds apply the optional transform" {
    const matrices = [_]Float4x4{
        Float4x4.fromTransform(.{ .translation = .{ -1, 0, 2 } }),
        Float4x4.fromTransform(.{ .translation = .{ 3, 4, -5 } }),
    };
    const plain = computePostureBounds(&matrices, null);
    try std.testing.expectEqual(Vec3f32{ -1, 0, -5 }, plain.min);
    try std.testing.expectEqual(Vec3f32{ 3, 4, 2 }, plain.max);

    const offset = Float4x4.fromTransform(.{ .translation = .{ 10, 0, 0 } });
    const moved = computePostureBounds(&matrices, offset);
    try std.testing.expectEqual(Vec3f32{ 9, 0, -5 }, moved.min);
    try std.testing.expectEqual(Vec3f32{ 13, 4, 2 }, moved.max);

    try std.testing.expect(!computePostureBounds(&.{}, null).isValid());
}

test "multiplySoATransformQuaternion touches a single lane" {
    const quarter_turn = Quaternion.fromAxisAngle(.{ 0, 1, 0 }, std.math.pi / 2.0);
    var transforms = [_]ozz.math.SoaTransform{ozz.math.SoaTransform.identity};

    multiplySoATransformQuaternion(2, quarter_turn, transforms[0..]);
    for (0..4) |index| {
        const rotation = ozz.math.soaLane(transforms[0], index).rotation;
        if (index == 2) {
            try std.testing.expect(Quaternion.approxRotationEq(rotation, quarter_turn, 0.9999));
        } else {
            try std.testing.expect(Quaternion.approxRotationEq(rotation, .identity, 0.9999));
        }
    }

    // The same helper accepts a plain SoaQuaternion array.
    var rotations = [_]ozz.math.SoaQuaternion{ozz.math.SoaQuaternion.splat(.identity)};
    multiplySoATransformQuaternion(1, quarter_turn, rotations[0..]);
    try std.testing.expectApproxEqAbs(
        quarter_turn.y,
        ozz.math.lane(rotations[0].y, 1),
        1e-6,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 0), ozz.math.lane(rotations[0].y, 0), 1e-6);
}

test "ray triangle intersection follows Moller-Trumbore" {
    const p0: Vec3f32 = .{ 0, 0, 0 };
    const p1: Vec3f32 = .{ 1, 0, 0 };
    const p2: Vec3f32 = .{ 0, 0, 1 };
    const down: Vec3f32 = .{ 0, -1, 0 };

    const hit = rayIntersectsTriangle(.{ 0.2, 5, 0.2 }, down, p0, p1, p2) orelse
        return error.ExpectedHit;
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), hit.point[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), hit.point[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), hit.point[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), @abs(hit.normal[1]), 1e-5);

    // Outside the triangle.
    try std.testing.expectEqual(
        @as(?RayHit, null),
        rayIntersectsTriangle(.{ 0.9, 5, 0.9 }, down, p0, p1, p2),
    );
    // Behind the ray origin.
    try std.testing.expectEqual(
        @as(?RayHit, null),
        rayIntersectsTriangle(.{ 0.2, -5, 0.2 }, down, p0, p1, p2),
    );
    // Parallel to the triangle plane.
    try std.testing.expectEqual(
        @as(?RayHit, null),
        rayIntersectsTriangle(.{ 0.2, 5, 0.2 }, .{ 1, 0, 0 }, p0, p1, p2),
    );
    // An arbitrary direction still works, and the hit uses the ray parameter.
    const oblique = rayIntersectsTriangle(
        .{ 0, 1, 0 },
        vec.normalize(Vec3f32{ 0.25, -1, 0.25 }),
        p0,
        p1,
        p2,
    ) orelse return error.ExpectedHit;
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), oblique.point[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), oblique.point[2], 1e-5);
}

test "raycasting the floor mesh returns the closest upward facing hit" {
    const allocator = std.testing.allocator;
    const meshes = try mesh_utils.decodeMeshes(allocator, @embedFile("floor_mesh"));
    defer mesh_utils.deinitMeshes(allocator, meshes);

    // The foot_ik sample fires straight down from above the character.
    const origin: Vec3f32 = .{ 2.17, 10, -2.06 };
    const down: Vec3f32 = .{ 0, -1, 0 };
    const hit = rayIntersectsMeshes(origin, down, meshes) orelse return error.ExpectedFloorHit;

    try std.testing.expectApproxEqAbs(origin[0], hit.point[0], 1e-4);
    try std.testing.expectApproxEqAbs(origin[2], hit.point[2], 1e-4);
    try std.testing.expect(hit.point[1] < origin[1]);
    // A floor is wound so its geometric normal points up.
    try std.testing.expect(hit.normal[1] > 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), vec.norm(hit.normal), 1e-5);

    // Single-mesh and multi-mesh paths agree for a one-mesh archive.
    if (meshes.len == 1) {
        const single = rayIntersectsMesh(origin, down, meshes[0]) orelse
            return error.ExpectedFloorHit;
        try std.testing.expectEqual(hit.point, single.point);
    }

    // Casting upwards from the same point must miss the floor entirely.
    try std.testing.expectEqual(
        @as(?RayHit, null),
        rayIntersectsMeshes(origin, .{ 0, 1, 0 }, meshes),
    );
    // So must a ray far outside the floor extents.
    try std.testing.expectEqual(
        @as(?RayHit, null),
        rayIntersectsMeshes(.{ 1000, 10, 1000 }, down, meshes),
    );
}

test "skeleton decoding and joint lookup" {
    const allocator = std.testing.allocator;
    var skeleton = try decodeSkeleton(allocator, @embedFile("pab_skeleton"));
    defer skeleton.deinit();

    try std.testing.expect(skeleton.numJoints() > 0);
    try std.testing.expect(findNamedJoint(skeleton, &.{"Head"}) != null);
    try std.testing.expect(findNamedJoint(skeleton, &.{"definitely_absent"}) == null);
    // The substring fallback is case insensitive.
    try std.testing.expectEqual(
        findNamedJoint(skeleton, &.{"Head"}),
        findJointContaining(skeleton, "hea"),
    );

    const leg = findNamedChain3(skeleton, &.{ "LeftUpLeg", "LeftLeg", "LeftFoot" }) orelse
        return error.MissingLegChain;
    try std.testing.expectEqual(leg[0], @as(usize, @intCast(skeleton.parents[leg[1]])));
    try std.testing.expectEqual(leg[1], @as(usize, @intCast(skeleton.parents[leg[2]])));

    try std.testing.expect(findNamedChain3(skeleton, &.{ "Head", "Head" }) == null);
    try std.testing.expect(findNamedChain4(
        skeleton,
        &.{ "Head", "Spine3", "Spine2", "Spine1" },
    ) != null);

    const generic = findThreeJointChain(skeleton) orelse return error.MissingChain;
    try std.testing.expectEqual(generic[0], @as(usize, @intCast(skeleton.parents[generic[1]])));
    try std.testing.expectEqual(generic[1], @as(usize, @intCast(skeleton.parents[generic[2]])));

    try std.testing.expect(containsIgnoreCase("LeftFoot", "foot"));
    try std.testing.expect(!containsIgnoreCase("Foot", "LeftFoot"));
}

test "clip decodes and samples an animation" {
    const allocator = std.testing.allocator;
    var skeleton = try decodeSkeleton(allocator, @embedFile("pab_skeleton"));
    defer skeleton.deinit();
    var clip = try Clip.decode(allocator, @embedFile("pab_walk"));
    defer clip.deinit();

    try std.testing.expect(clip.duration() > 0);
    try std.testing.expectEqual(skeleton.numJoints(), clip.animation.numTracks());
    try std.testing.expect(clip.pose.len >= skeleton.numSoaJoints());

    try clip.sample(0);
    const snapshot = try allocator.dupe(ozz.math.SoaTransform, clip.pose);
    defer allocator.free(snapshot);
    try clip.sample(0.5);
    var changed = false;
    for (snapshot, clip.pose) |before, after| {
        if (@reduce(.Or, before.rotation.x != after.rotation.x) or
            @reduce(.Or, before.translation.y != after.translation.y))
        {
            changed = true;
        }
    }
    try std.testing.expect(changed);
}

test "cloneRawAnimation deep copies every track" {
    const allocator = std.testing.allocator;
    var raw = try decodeRawAnimation(allocator, @embedFile("pab_walk_raw"));
    defer raw.deinit();
    var clone = try cloneRawAnimation(allocator, raw);
    defer clone.deinit();

    try std.testing.expectEqual(raw.duration, clone.duration);
    try std.testing.expectEqual(raw.tracks.len, clone.tracks.len);
    for (raw.tracks, clone.tracks) |source, copy| {
        try std.testing.expectEqualSlices(
            ozz.offline.TranslationKey,
            source.translations,
            copy.translations,
        );
        try std.testing.expectEqualSlices(
            ozz.offline.RotationKey,
            source.rotations,
            copy.rotations,
        );
        try std.testing.expectEqualSlices(ozz.offline.ScaleKey, source.scales, copy.scales);
        // Distinct storage.
        if (source.translations.len != 0) {
            try std.testing.expect(source.translations.ptr != copy.translations.ptr);
        }
    }
}

test "raw skeleton editor reports modifications" {
    const allocator = std.testing.allocator;
    const child_name = try allocator.dupe(u8, "child");
    const root_name = try allocator.dupe(u8, "root");
    const children = try allocator.alloc(ozz.offline.RawJoint, 1);
    children[0] = .{ .name = child_name };
    const roots = try allocator.alloc(ozz.offline.RawJoint, 1);
    roots[0] = .{ .name = root_name, .children = children };
    var raw: ozz.offline.RawSkeleton = .{ .allocator = allocator, .roots = roots };
    defer raw.deinit();

    var editor: RawSkeletonEditor = .{};

    // A gui that never moves a slider reports no modification.
    var idle: TestGui = .{};
    try std.testing.expect(!editor.onGui(&raw, &idle));
    try std.testing.expect(idle.sliders > 0);
    try std.testing.expectEqual(@as(usize, 6), idle.labels); // 3 labels per joint

    // Collapsed joints are not recursed into and never edited.
    var collapsed: TestGui = .{ .open = false, .slider_delta = 0.5 };
    try std.testing.expect(!editor.onGui(&raw, &collapsed));
    try std.testing.expectEqual(@as(usize, 0), collapsed.sliders);

    // Dragging every slider edits translation, rotation and (uniform) scale.
    var dragging: TestGui = .{ .slider_delta = 0.25 };
    try std.testing.expect(editor.onGui(&raw, &dragging));
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.25),
        raw.roots[0].transform.translation[0],
        1e-6,
    );
    const scale = raw.roots[0].transform.scale;
    try std.testing.expectEqual(scale[0], scale[1]);
    try std.testing.expectEqual(scale[0], scale[2]);
    // The rotation sliders work in degrees and round-trip through Euler angles.
    const euler: [3]f32 = vec.scale(
        Quaternion.toEuler(raw.roots[0].transform.rotation),
        radian_to_degree,
    );
    for (euler) |angle| try std.testing.expectApproxEqAbs(@as(f32, 0.25), angle, 1e-3);
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.25),
        raw.roots[0].children[0].transform.translation[0],
        1e-6,
    );
}
