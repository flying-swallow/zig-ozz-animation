// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/motion_playback/sample_motion_playback.cc`.
//!
//! The animation has had its root motion baked out offline, so the character
//! plays "in place". The extracted position/rotation tracks are sampled every
//! frame and accumulated by `fw.motion_utils.MotionSampler`, which is what makes
//! the character keep travelling when the animation loops. An extra steering
//! rotation (angular velocity) is fed to the same accumulator so the user can
//! curve the path, exactly like upstream's `FrameRotation`.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Float4x4 = ozz.math.Float4x4;
const quat = ozz.math.quat;
const Quat4f32 = ozz.math.Quat4f32;
const Vec3f32 = ozz.math.Vec3f32;
const vec = ozz.math.vec;

pub const name = "motion_playback";
pub const description = "Root motion playback";

/// The character's collision capsule stand-in, drawn at the root transform.
const bounding: ozz.math.Box = .{
    .min = .{ -0.3, 0, -0.2 },
    .max = .{ 0.3, 1.8, 0.2 },
};

/// Storage for the position trace, and the upper bound of its GUI slider.
const max_trace_size = 2000;

/// Half of pi, the bound upstream uses for the angular velocity slider.
const half_pi: f32 = std.math.pi / 2.0;

pub const Sample = struct {
    allocator: std.mem.Allocator,

    /// Runtime skeleton.
    skeleton: ozz.animation.Skeleton,
    /// Runtime animation, its sampling context and local-space output.
    clip: fw.utils.Clip,
    /// Position and rotation motion tracks.
    motion_track: fw.MotionTrack,
    /// Model-space matrices, the output of the local-to-model conversion.
    models: []Float4x4,
    /// Ring-free trace of the last accumulated positions, oldest first.
    trace: []Vec3f32,
    trace_len: usize = 0,

    /// Playback time / speed / loop control.
    controller: fw.PlaybackController = .{},
    /// Motion accumulator, which is what handles animation loops.
    motion_sampler: fw.motion_utils.MotionSampler = .{},
    /// Character transform, driven by the accumulator.
    transform: Float4x4 = .identity,

    // GUI options to apply root motion.
    apply_motion_position: bool = true,
    apply_motion_rotation: bool = true,
    /// Steering deformation applied to the accumulated path, in rad/s.
    angular_velocity: f32 = std.math.pi / 4.0,

    // Debug display options.
    show_box: bool = true,
    show_trace: bool = true,
    trace_size: i32 = 500,
    show_motion: bool = true,
    /// Display the motion path around the current time instead of begin-to-end.
    floating_display: bool = true,
    floating_before: f32 = 0.3,
    floating_after: f32 = 1.0,

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(@embedFile("pab_skeleton")),
        );
        errdefer skeleton.deinit();

        var clip = try fw.utils.Clip.decode(
            allocator,
            assets.animationOr(@embedFile("pab_jog_no_motion")),
        );
        errdefer clip.deinit();

        // Skeleton and animation need to match.
        if (skeleton.numJoints() != clip.animation.numTracks()) {
            return error.SkeletonAnimationMismatch;
        }

        var motion_track = try fw.MotionTrack.decode(
            allocator,
            assets.trackOr(@embedFile("pab_jog_motion")),
        );
        errdefer motion_track.deinit();

        const models = try allocator.alloc(Float4x4, skeleton.numJoints());
        errdefer allocator.free(models);
        @memset(models, .identity);

        const trace = try allocator.alloc(Vec3f32, max_trace_size);
        errdefer allocator.free(trace);

        return .{
            .allocator = allocator,
            .skeleton = skeleton,
            .clip = clip,
            .motion_track = motion_track,
            .models = models,
            .trace = trace,
        };
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.trace);
        self.allocator.free(self.models);
        self.motion_track.deinit();
        self.clip.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;

        // Updates current animation time.
        const loops = self.controller.update(self.clip.duration(), dt);

        // Updates the motion accumulator, steered by the frame rotation. The
        // accumulator is what carries the character across animation loops.
        const rotation = self.frameRotation(
            dt * self.controller.playback_speed *
                @as(f32, if (self.controller.play) 1 else 0),
        );
        self.motion_sampler.update(
            self.motion_track,
            self.controller.time_ratio,
            loops,
            rotation,
        );

        // Updates the character transform matrix, dropping whichever motion
        // component the user disabled.
        const current = self.motion_sampler.current();
        self.transform = Float4x4.fromTransform(.{
            .translation = if (self.apply_motion_position)
                current.translation
            else
                @splat(0),
            .rotation = if (self.apply_motion_rotation) current.rotation else quat.identity,
            .scale = current.scale,
        });

        if (self.controller.play) self.pushTrace(current.translation);

        // Samples the animation and converts it to model space. The animation
        // itself is motion-free, the travelling is entirely in `transform`.
        try self.clip.sample(self.controller.time_ratio);
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.clip.pose,
        }, self.models);

        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        try renderer.drawPosture(self.skeleton, self.models, self.transform, true);

        if (self.show_box) {
            try renderer.drawBoxIm(bounding, self.transform, fw.color.white);
        }

        if (self.show_trace and self.trace_len > 1) {
            try renderer.drawLineStrip(
                self.trace[0..self.trace_len],
                fw.color.red,
                .identity,
            );
        }

        if (self.show_motion) {
            // One point per rendered frame of a 60fps playback.
            const duration = self.clip.duration();
            const step = 1 / (duration * 60);
            const at = self.controller.time_ratio;
            const from = if (self.floating_display) at - self.floating_before else 0;
            const to = if (self.floating_display) at + self.floating_after else 1;
            try fw.motion_utils.drawMotion(
                renderer,
                self.motion_track,
                at,
                from,
                to,
                step,
                self.transform,
                self.frameRotation(step * duration),
            );
        }
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        var buffer: [64]u8 = undefined;

        if (gui.openClose("Animation control", true)) {
            self.controller.onGui(gui, self.clip.duration(), true, true);
        }

        if (gui.openClose("Motion control", true)) {
            _ = gui.doCheckBox("Apply motion position", &self.apply_motion_position, true);
            _ = gui.doCheckBox("Apply motion rotation", &self.apply_motion_rotation, true);
            _ = gui.doSlider(
                label(&buffer, "Angular vel: {d:.0} deg/s###angular_velocity", .{
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

            _ = gui.doCheckBox("Show trace", &self.show_trace, true);
            _ = gui.doSliderInt(
                label(&buffer, "Trace size: {d}###trace_size", .{self.trace_size}),
                100,
                max_trace_size,
                &self.trace_size,
                2,
                true,
            );

            _ = gui.doCheckBox("Show motion", &self.show_motion, true);
            _ = gui.doCheckBox("Floating display", &self.floating_display, self.show_motion);

            const floating = self.floating_display and self.show_motion;
            _ = gui.doSlider(
                label(&buffer, "Motion before: {d:.0}%###floating_before", .{self.floating_before * 100}),
                0,
                3,
                &self.floating_before,
                1,
                floating,
            );
            _ = gui.doSlider(
                label(&buffer, "Motion after: {d:.0}%###floating_after", .{self.floating_after * 100}),
                0,
                3,
                &self.floating_after,
                1,
                floating,
            );
        }
    }

    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        return transformBox(self.transform, bounding);
    }

    /// Restarts the accumulation at the origin and forgets the trace, which is
    /// what upstream's "Teleport" button does.
    pub fn teleport(self: *Sample) void {
        self.motion_sampler.teleport(.identity);
        self.trace_len = 0;
    }

    /// Rotation to apply for `duration` seconds of steering.
    fn frameRotation(self: Sample, duration: f32) Quat4f32 {
        // Upstream spells this `Quaternion::FromEuler({angle, 0, 0})`, whose
        // first component is the yaw; here that is an explicit rotation about Y.
        return quat.fromAxisAngle(.{ 0, 1, 0 }, self.angular_velocity * duration);
    }

    /// Appends one accumulated position, dropping the oldest samples so the
    /// trace never holds more than `trace_size` points.
    fn pushTrace(self: *Sample, point: Vec3f32) void {
        const limit = @min(
            @as(usize, @intCast(@max(self.trace_size, 1))),
            self.trace.len,
        );
        if (self.trace_len >= limit) {
            const drop = self.trace_len - limit + 1;
            std.mem.copyForwards(
                Vec3f32,
                self.trace[0 .. self.trace_len - drop],
                self.trace[drop..self.trace_len],
            );
            self.trace_len -= drop;
        }
        self.trace[self.trace_len] = point;
        self.trace_len += 1;
    }
};

/// Upstream `TransformBox`: the axis-aligned bounds of a transformed box.
fn transformBox(transform: Float4x4, box: ozz.math.Box) ozz.math.Box {
    var result = ozz.math.Box.empty();
    for (0..8) |corner| {
        result.expand(transform.transformPoint(.{
            if (corner & 1 != 0) box.max[0] else box.min[0],
            if (corner & 2 != 0) box.max[1] else box.min[1],
            if (corner & 4 != 0) box.max[2] else box.min[2],
        }));
    }
    return result;
}

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

test "root motion keeps travelling across animation loops" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    // A straight path makes the assertions independent of the steering.
    sample.angular_velocity = 0;

    const dt: f32 = 1.0 / 60.0;
    const steps: usize = @intFromFloat(@ceil(sample.clip.duration() / dt * 3));
    try std.testing.expect(steps > 10);

    var previous = sample.motion_sampler.current().translation;
    var travelled: f32 = 0;
    var loops: usize = 0;
    for (0..steps) |_| {
        const before = sample.controller.time_ratio;
        try std.testing.expect(try sample.onUpdate(dt, 0));
        if (sample.controller.time_ratio < before) loops += 1;

        const current = sample.motion_sampler.current().translation;
        const step = vec.norm(vec.sub(current, previous));
        // The accumulator must never snap back to the track origin on a loop.
        try std.testing.expect(step < 0.5);
        travelled += step;
        previous = current;
    }

    // Three durations of a jog cycle wrap at least twice and cover ground.
    try std.testing.expect(loops >= 2);
    try std.testing.expect(travelled > 1);
    try std.testing.expect(vec.norm(sample.motion_sampler.current().translation) > 1);

    // The character transform follows the accumulator.
    try std.testing.expectApproxEqAbs(
        sample.motion_sampler.current().translation[2],
        sample.transform.translation()[2],
        1e-5,
    );

    // Teleporting resets the accumulation and the trace.
    sample.teleport();
    try std.testing.expectEqual(@as(usize, 0), sample.trace_len);
    try std.testing.expectEqual(
        Vec3f32{ 0, 0, 0 },
        sample.motion_sampler.current().translation,
    );
}

test "steering curves the accumulated path" {
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

    const a = straight.motion_sampler.current();
    const b = curved.motion_sampler.current();
    try std.testing.expect(vec.norm(vec.sub(a.translation, b.translation)) > 0.1);
    // Steering also shows up in the accumulated orientation.
    try std.testing.expect(!quat.approxRotationEq(a.rotation, b.rotation, 0.999));
}

test "disabling motion components freezes the character transform" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();
    sample.apply_motion_position = false;
    sample.apply_motion_rotation = false;

    const dt: f32 = 1.0 / 60.0;
    for (0..120) |_| _ = try sample.onUpdate(dt, 0);

    // Motion is still accumulated, it is simply not applied.
    try std.testing.expect(vec.norm(sample.motion_sampler.current().translation) > 0.1);
    try std.testing.expectEqual(Vec3f32{ 0, 0, 0 }, sample.transform.translation());

    sample.apply_motion_position = true;
    _ = try sample.onUpdate(dt, 0);
    try std.testing.expect(vec.norm(sample.transform.translation()) > 0.1);
}

test "the position trace is bounded by its gui size" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();
    sample.trace_size = 8;

    const dt: f32 = 1.0 / 60.0;
    for (0..64) |_| _ = try sample.onUpdate(dt, 0);
    try std.testing.expectEqual(@as(usize, 8), sample.trace_len);

    // The newest sample is always last, and it is the current position.
    try std.testing.expectEqual(
        sample.motion_sampler.current().translation,
        sample.trace[sample.trace_len - 1],
    );

    // Growing the limit resumes appending rather than reallocating.
    sample.trace_size = 12;
    _ = try sample.onUpdate(dt, 0);
    try std.testing.expectEqual(@as(usize, 9), sample.trace_len);

    // A paused controller stops feeding the trace.
    sample.controller.play = false;
    _ = try sample.onUpdate(0, 0);
    try std.testing.expectEqual(@as(usize, 9), sample.trace_len);
}

test "scene bounds follow the character" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    const initial = sample.sceneBounds() orelse return error.MissingBounds;
    try std.testing.expect(initial.isValid());
    try std.testing.expect(initial.contains(.{ 0, 0.9, 0 }));

    const dt: f32 = 1.0 / 60.0;
    for (0..120) |_| _ = try sample.onUpdate(dt, 0);
    const moved = sample.sceneBounds() orelse return error.MissingBounds;
    try std.testing.expect(vec.norm(vec.sub(moved.min, initial.min)) > 0.1);
}

test "an inert gui leaves every option untouched" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    var gui = fw.Im.init(false);
    sample.onGui(&gui);
    try std.testing.expect(sample.apply_motion_position);
    try std.testing.expect(sample.apply_motion_rotation);
    try std.testing.expectEqual(@as(i32, 500), sample.trace_size);
}
