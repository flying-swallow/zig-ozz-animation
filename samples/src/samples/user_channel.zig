// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/user_channel/sample_user_channel.cc`.
//!
//! A user-channel `FloatTrack`, authored in a DCC tool alongside the animation,
//! drives whether a box is grasped by the robot's finger. The track is consumed
//! both ways upstream demonstrates, selectable from the GUI:
//!
//! - **Sampling** (`FloatTrack.sampleAt`) reads the channel once per frame, so
//!   the attachment transform is captured at frame time and accumulates error.
//! - **Edge triggering** (`ozz.animation.TrackEdgeIterator`) walks every rising
//!   and falling edge between the previous and the current time, and captures
//!   the attachment transform at the *exact* crossing ratio. That makes it frame
//!   rate independent and lets it survive arbitrary jumps in time.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Float4x4 = ozz.math.Float4x4;
const Vec3f32 = ozz.math.Vec3f32;
const vec = ozz.math.vec;

pub const name = "user_channel";
pub const description = "Animation user channels";

/// The grasped box, in its own local space.
pub const box: ozz.math.Box = .{
    .min = .{ -0.01, -0.1, -0.05 },
    .max = .{ 0.01, 0.1, 0.05 },
};

/// Where the box rests before it is grasped for the first time.
pub const box_initial_position: Vec3f32 = .{ 0, 0.1, 0.3 };

/// How the user-channel track is consumed. Stored as an `i32` because that is
/// what `Im.doRadioButton` drives.
pub const method_sampling: i32 = 0;
pub const method_triggering: i32 = 1;

pub const Sample = struct {
    allocator: std.mem.Allocator,

    /// Runtime skeleton.
    skeleton: ozz.animation.Skeleton,
    /// Runtime animation, its sampling context and local-space output.
    clip: fw.utils.Clip,
    /// The user-channel track: whether the box should be attached.
    track: ozz.animation.FloatTrack,
    /// Model-space matrices, the output of the local-to-model conversion.
    models: []Float4x4,
    /// Index of the joint the box is attached to (the robot's thumb).
    attach_joint: usize,

    /// Playback time / speed / loop control.
    controller: fw.PlaybackController = .{},

    /// Track access method, `method_sampling` or `method_triggering`.
    method: i32 = method_triggering,
    /// The channel value above which the box counts as grasped. Upstream hard
    /// codes 0; it is exposed here so the two methods can be compared on any
    /// threshold.
    threshold: f32 = 0,

    /// Whether the box is currently grasped.
    attached: bool = false,
    /// Last sampled channel value, for the GUI read-out.
    channel_value: f32 = 0,
    /// Box transform in world space.
    box_world: Float4x4 = .identity,
    /// Box transform relative to the attachment joint.
    box_local: Float4x4 = .identity,

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(@embedFile("robot_skeleton")),
        );
        errdefer skeleton.deinit();

        var clip = try fw.utils.Clip.decode(
            allocator,
            assets.animationOr(@embedFile("robot_animation")),
        );
        errdefer clip.deinit();
        if (skeleton.numJoints() != clip.animation.numTracks()) {
            return error.SkeletonAnimationMismatch;
        }

        var track_reader = std.Io.Reader.fixed(assets.trackOr(@embedFile("robot_grasp")));
        var track = try ozz.legacy.readTrack(.float, allocator, &track_reader, .{});
        errdefer track.deinit();

        const models = try allocator.alloc(Float4x4, skeleton.numJoints());
        errdefer allocator.free(models);
        @memset(models, .identity);

        var sample: Sample = .{
            .allocator = allocator,
            .skeleton = skeleton,
            .clip = clip,
            .track = track,
            .models = models,
            // The box hangs off the finger; if the joint is missing, joint 0 is
            // used, exactly like upstream.
            .attach_joint = fw.utils.findJointContaining(skeleton, "thumb2") orelse 0,
        };
        sample.resetState();
        // Model-space matrices must be valid before the first `onDisplay`.
        try sample.updateJoints(0);
        return sample;
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.models);
        self.track.deinit();
        self.clip.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;

        // The GUI moved the time slider. Triggering can absorb an arbitrary
        // jump, because every edge in the crossed range is processed; the range
        // has to be consumed before `update` overwrites `previous_time_ratio`.
        // There is no point doing this for the sampling method.
        if (self.controller.time_changed) {
            self.controller.time_changed = false;
            if (self.method == method_triggering) {
                try self.processEdges(
                    self.controller.previous_time_ratio,
                    self.controller.time_ratio,
                );
            }
        }

        const loops = self.controller.update(self.clip.duration(), dt);

        if (self.method == method_sampling) {
            try self.updateSampling();
        } else {
            try self.updateTriggering(loops);
        }

        // Updates the box transform from the attachment state; a detached box
        // is simply left where it was released.
        if (self.attached) {
            self.box_world = Float4x4.mul(self.models[self.attach_joint], self.box_local);
        }

        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        // The box, at the position computed during update.
        //
        // Upstream draws it shaded, i.e.
        //     try renderer.drawBoxShaded(box, &.{self.box_world}, fw.color.grey);
        // but `Renderer.drawShadedInstanced` currently panics: it passes
        // `@sizeOf(VertexPNC)` (28, not a power of two) as the alignment of a
        // ring allocation, and `Ring.allocBytes` feeds that straight to
        // `std.mem.alignForward`, which asserts a valid alignment. Restore the
        // line above once `framework/renderer.zig` aligns to `@alignOf(T)`.
        try renderer.drawBoxIm(box, self.box_world, fw.color.grey);

        // A sphere at the hand, showing the "attached" flag status.
        try renderer.drawSphereIm(
            0.01,
            self.models[self.attach_joint],
            if (self.attached) fw.color.green else fw.color.white,
        );

        try renderer.drawPosture(self.skeleton, self.models, .identity, true);
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        var buffer: [64]u8 = undefined;

        if (gui.openClose("Track access method", true)) {
            var changed = gui.doRadioButton(method_sampling, "Sampling", &self.method, true);
            changed = gui.doRadioButton(
                method_triggering,
                "Triggering",
                &self.method,
                true,
            ) or changed;
            if (changed) self.resetState();

            // Not exposed upstream, where the threshold is hard coded to 0.
            _ = gui.doSlider(
                label(&buffer, "Threshold: {d:.2}###threshold", .{self.threshold}),
                0,
                1,
                &self.threshold,
                1,
                true,
            );
            gui.doLabel("Channel value: {d:.3}", .{self.channel_value});
            gui.doLabel("Grasped: {s}", .{if (self.attached) "yes" else "no"});
            if (gui.doButton("Reset", true)) self.resetState();
        }

        if (gui.openClose("Animation control", true)) {
            self.controller.onGui(gui, self.clip.duration(), true, true);
        }
    }

    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        return fw.utils.computePostureBounds(self.models, null);
    }

    /// Resets everything to its initial state, like upstream's `ResetState`.
    pub fn resetState(self: *Sample) void {
        self.controller.setTimeRatio(0);
        self.controller.time_changed = false;
        self.attached = false;
        self.channel_value = 0;
        self.box_local = .identity;
        self.box_world = Float4x4.fromTransform(.{ .translation = box_initial_position });
    }

    /// Frame-time sampling: reads the channel once, at the current time.
    fn updateSampling(self: *Sample) !void {
        try self.updateJoints(self.controller.time_ratio);

        // Tracks have a unit length duration, so they are sampled with the same
        // ratio as the animation they belong to.
        self.channel_value = self.track.sampleAt(self.controller.time_ratio);

        const previously_attached = self.attached;
        self.attached = self.channel_value > self.threshold;

        // The box is being grasped: capture its transform relative to the joint.
        if (self.attached and !previously_attached) {
            try self.captureLocal();
        }
    }

    /// Edge triggering: walks every state change since the last update.
    fn updateTriggering(self: *Sample, loops: i32) !void {
        // The exact previous time matters here: recomputing it could cover a
        // slightly different range and miss or repeat edges. `to` is unwrapped
        // with the loop count so a wrapping frame is still one forward range.
        try self.processEdges(
            self.controller.previous_time_ratio,
            self.controller.time_ratio + @as(f32, @floatFromInt(loops)),
        );

        // Finally updates the joints at the current frame time.
        try self.updateJoints(self.controller.time_ratio);
        self.channel_value = self.track.sampleAt(self.controller.time_ratio);
    }

    /// Applies every edge in the `[from, to]` range, capturing the attachment
    /// transform at the exact ratio each edge crosses the threshold.
    fn processEdges(self: *Sample, from: f32, to: f32) !void {
        var edges = ozz.animation.TrackEdgeIterator.init(
            &self.track,
            from,
            to,
            self.threshold,
        );
        while (edges.next()) |edge| {
            // The triggering job guarantees rising/falling symmetry.
            self.attached = edge.rising;

            // Knowing the exact edge ratio, the joints are re-sampled so the
            // attachment is computed at the precise moment of the state change.
            // Sampling is cached, so these intermediate updates are cheap.
            try self.updateJoints(edge.ratio - @floor(edge.ratio));

            if (edge.rising) {
                try self.captureLocal();
            } else {
                // Released: freeze the box where it was at that exact instant.
                self.box_world = Float4x4.mul(self.models[self.attach_joint], self.box_local);
            }
        }
    }

    /// Stores the box transform relative to the attachment joint.
    fn captureLocal(self: *Sample) !void {
        const inverse = Float4x4.inverse(self.models[self.attach_joint]) orelse
            return error.NonInvertibleJoint;
        self.box_local = Float4x4.mul(inverse, self.box_world);
    }

    /// Samples the animation at `ratio` and converts it to model space.
    fn updateJoints(self: *Sample, ratio: f32) !void {
        try self.clip.sample(ratio);
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.clip.pose,
        }, self.models);
    }
};

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

test "the user channel track drives a grasp and a release" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    try std.testing.expect(sample.track.keys.len > 1);
    try std.testing.expect(sample.attach_joint != 0);
    try std.testing.expect(!sample.attached);
    try std.testing.expectEqual(
        box_initial_position,
        sample.box_world.translation(),
    );

    const dt: f32 = 1.0 / 60.0;
    const steps: usize = @intFromFloat(@ceil(sample.clip.duration() / dt));
    var grasped = false;
    var released = false;
    for (0..steps) |_| {
        const before = sample.attached;
        try std.testing.expect(try sample.onUpdate(dt, 0));
        if (!before and sample.attached) grasped = true;
        if (before and !sample.attached) released = true;
    }
    try std.testing.expect(grasped);
    try std.testing.expect(released);

    // The box has been carried somewhere else by the arm.
    try std.testing.expect(vec.norm(vec.sub(
        sample.box_world.translation(),
        box_initial_position,
    )) > 1e-3);

    sample.resetState();
    try std.testing.expect(!sample.attached);
    try std.testing.expectEqual(box_initial_position, sample.box_world.translation());
    try std.testing.expectEqual(@as(f32, 0), sample.controller.time_ratio);
}

test "sampling and triggering agree on when the box is grasped" {
    const allocator = std.testing.allocator;
    var sampling = try Sample.init(allocator, .{});
    defer sampling.deinit();
    sampling.method = method_sampling;

    var triggering = try Sample.init(allocator, .{});
    defer triggering.deinit();
    triggering.method = method_triggering;

    // Both start detached, which requires the channel to start below the
    // threshold; otherwise triggering would have no rising edge to observe.
    try std.testing.expect(sampling.track.sampleAt(0) <= sampling.threshold);

    const dt: f32 = 1.0 / 60.0;
    const steps: usize = @intFromFloat(@ceil(sampling.clip.duration() / dt * 2));
    var transitions: usize = 0;
    for (0..steps) |_| {
        const before = sampling.attached;
        _ = try sampling.onUpdate(dt, 0);
        _ = try triggering.onUpdate(dt, 0);
        if (sampling.attached != before) transitions += 1;

        // The two methods must always report the same attachment state.
        try std.testing.expectEqual(sampling.attached, triggering.attached);
        // And the same channel value, since both sample at the frame time.
        try std.testing.expectApproxEqAbs(
            sampling.channel_value,
            triggering.channel_value,
            1e-6,
        );
    }
    // Two full animation cycles must contain several state changes.
    try std.testing.expect(transitions >= 2);
}

test "triggering captures the attachment at the exact edge ratio" {
    const allocator = std.testing.allocator;

    // Two frame rates that never land on the same times. Triggering is frame
    // rate independent, so the grasp offset it captures must match; sampling
    // captures at frame time and therefore drifts.
    var fast = try Sample.init(allocator, .{});
    defer fast.deinit();
    var slow = try Sample.init(allocator, .{});
    defer slow.deinit();

    const target = fast.clip.duration() * 0.75;
    var elapsed: f32 = 0;
    while (elapsed < target) : (elapsed += 1.0 / 240.0) _ = try fast.onUpdate(1.0 / 240.0, 0);
    elapsed = 0;
    while (elapsed < target) : (elapsed += 1.0 / 24.0) _ = try slow.onUpdate(1.0 / 24.0, 0);

    if (fast.attached and slow.attached) {
        // The relative transform is captured at the crossing ratio, so both
        // frame rates agree on it to within the track's own resolution.
        for (0..4) |column| {
            for (0..4) |row| {
                try std.testing.expectApproxEqAbs(
                    fast.box_local.cols[column][row],
                    slow.box_local.cols[column][row],
                    1e-3,
                );
            }
        }
    }
}

test "triggering absorbs a jump in time" {
    const allocator = std.testing.allocator;
    var jumped = try Sample.init(allocator, .{});
    defer jumped.deinit();
    var stepped = try Sample.init(allocator, .{});
    defer stepped.deinit();

    // Walking to 60% of the animation frame by frame...
    const dt: f32 = 1.0 / 60.0;
    while (stepped.controller.time_ratio < 0.6) _ = try stepped.onUpdate(dt, 0);

    // ... must end in the same attachment state as jumping straight there,
    // because every edge in the crossed range is processed.
    jumped.controller.setTimeRatio(stepped.controller.time_ratio);
    jumped.controller.time_changed = true;
    jumped.controller.play = false;
    _ = try jumped.onUpdate(0, 0);

    try std.testing.expectEqual(stepped.attached, jumped.attached);
    try std.testing.expectApproxEqAbs(
        stepped.channel_value,
        jumped.channel_value,
        1e-6,
    );
}

test "the threshold moves the grasp window" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();
    sample.method = method_sampling;

    // A threshold above every key value can never be crossed.
    var maximum: f32 = 0;
    for (sample.track.keys) |key| maximum = @max(maximum, key.value);
    sample.threshold = maximum + 1;

    const dt: f32 = 1.0 / 60.0;
    const steps: usize = @intFromFloat(@ceil(sample.clip.duration() / dt));
    for (0..steps) |_| {
        _ = try sample.onUpdate(dt, 0);
        try std.testing.expect(!sample.attached);
    }

    // Edge triggering agrees: no crossing means no edge at all.
    var edges = ozz.animation.TrackEdgeIterator.init(&sample.track, 0, 1, sample.threshold);
    try std.testing.expectEqual(@as(?ozz.animation.TrackEdge, null), edges.next());
}

test "an inert gui leaves the method and threshold untouched" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    var gui = fw.Im.init(false);
    sample.onGui(&gui);
    try std.testing.expectEqual(method_triggering, sample.method);
    try std.testing.expectEqual(@as(f32, 0), sample.threshold);
}
