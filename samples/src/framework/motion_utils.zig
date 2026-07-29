// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/framework/motion_utils.{h,cc}`, absorbing the
//! `MotionTrack` helpers that used to live in `samples/src/demo.zig`.
//!
//! `drawMotion` takes a duck-typed renderer and only ever calls `drawLineStrip`,
//! which keeps this module GPU-free and unit-testable.

const std = @import("std");
const ozz = @import("zig_ozz_animation");

const Vec3f32 = ozz.math.Vec3f32;
const quat = ozz.math.quat;
const Quat4f32 = ozz.math.Quat4f32;
const Float4x4 = ozz.math.Float4x4;
const Transform = ozz.math.Transform;
const vec = ozz.math.vec;

// -----------------------------------------------------------------------------
// MotionTrack
// -----------------------------------------------------------------------------

/// The pair of tracks describing a character's root motion: a position track and
/// a rotation track, stored back-to-back in that order in a single archive.
pub const MotionTrack = struct {
    position: ozz.animation.Float3Track,
    rotation: ozz.animation.QuaternionTrack,

    /// Decodes both tracks from one upstream `.ozz` archive. The legacy reader
    /// always expects the archive header, so the rotation read is prefixed with
    /// the original endianness byte.
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !MotionTrack {
        var consumed: usize = 0;
        var position_reader = std.Io.Reader.fixed(bytes);
        var position = try ozz.legacy.readTrackPrefix(.float3,
            allocator,
            &position_reader,
            .{},
            &consumed,
        );
        errdefer position.deinit();
        const rotation_bytes = try allocator.alloc(u8, bytes.len - consumed + 1);
        defer allocator.free(rotation_bytes);
        rotation_bytes[0] = bytes[0];
        @memcpy(rotation_bytes[1..], bytes[consumed..]);
        var rotation_reader = std.Io.Reader.fixed(rotation_bytes);
        return .{
            .position = position,
            .rotation = try ozz.legacy.readTrack(.quaternion,
                allocator,
                &rotation_reader,
                .{},
            ),
        };
    }

    /// Builds the runtime tracks from the raw tracks produced by
    /// `ozz.offline.extractMotion`.
    pub fn fromRaw(
        allocator: std.mem.Allocator,
        raw_position: ozz.offline.RawFloat3Track,
        raw_rotation: ozz.offline.RawQuaternionTrack,
    ) !MotionTrack {
        var position = try ozz.offline.buildTrack(.float3, allocator, raw_position);
        errdefer position.deinit();
        return .{
            .position = position,
            .rotation = try ozz.offline.buildTrack(.quaternion, allocator, raw_rotation),
        };
    }

    pub fn deinit(self: *MotionTrack) void {
        self.position.deinit();
        self.rotation.deinit();
        self.* = undefined;
    }

    /// Samples both tracks at `ratio`; scale is always one.
    pub fn sample(self: MotionTrack, ratio: f32) Transform {
        return .{
            .translation = self.position.sampleAt(ratio),
            .rotation = self.rotation.sampleAt(ratio),
        };
    }

    /// Motion accumulated between two ratios of the same loop, wrapping through
    /// the track end when `current` is behind `previous`.
    pub fn delta(self: MotionTrack, previous: f32, current: f32) Transform {
        if (current >= previous) {
            return motionDifference(self.sample(previous), self.sample(current));
        }
        return Transform.combine(
            motionDifference(self.sample(previous), self.sample(1)),
            motionDifference(self.sample(0), self.sample(current)),
        );
    }

    /// Motion accumulated between two unwrapped ratios, i.e. ratios whose integer
    /// part counts completed loops. Handles playing backwards.
    pub fn deltaRange(self: MotionTrack, from: f32, to: f32) Transform {
        if (to < from) return inverseMotion(self.deltaRange(to, from));
        const from_loop = @floor(from);
        const to_loop = @floor(to);
        const from_ratio = from - from_loop;
        const to_ratio = to - to_loop;
        if (from_loop == to_loop) return self.delta(from_ratio, to_ratio);

        var result = self.delta(from_ratio, 1);
        var loop = from_loop + 1;
        const full = self.delta(0, 1);
        while (loop < to_loop) : (loop += 1) {
            result = Transform.combine(result, full);
        }
        return Transform.combine(result, self.delta(0, to_ratio));
    }
};

/// Free-function form of `MotionTrack.sample`, mirroring upstream `SampleMotion`.
pub fn sampleMotion(track: MotionTrack, ratio: f32) Transform {
    return track.sample(ratio);
}

/// Inverse of a rigid motion delta.
pub fn inverseMotion(value: Transform) Transform {
    const rotation = quat.conjugate(value.rotation);
    return .{
        .translation = quat.rotate(rotation, vec.scale(value.translation, -1)),
        .rotation = rotation,
    };
}

/// Motion required to go from `from` to `to`: a plain translation difference and
/// a relative rotation.
pub fn motionDifference(from: Transform, to: Transform) Transform {
    return .{
        .translation = vec.sub(to.translation, from.translation),
        .rotation = quat.normalize(quat.mul(
            quat.conjugate(from.rotation),
            to.rotation,
        )),
    };
}

// -----------------------------------------------------------------------------
// Accumulators
// -----------------------------------------------------------------------------

/// Accumulates motion deltas that are already expressed as deltas
/// (motion_utils.cc:106). `rotation_accum` is the accumulated steering rotation;
/// it is applied to incoming translation deltas so the path curves.
pub const MotionDeltaAccumulator = struct {
    /// Accumulated transform.
    current: Transform = .identity,
    /// Delta applied by the last `update`.
    delta: Transform = .identity,
    /// Accumulated steering rotation.
    rotation_accum: Quat4f32 = quat.identity,

    /// Applies `delta_transform`, additionally steered by `extra_rotation`. Pass
    /// `.identity` for `extra_rotation` to reproduce the single-argument
    /// upstream overload.
    pub fn update(
        self: *MotionDeltaAccumulator,
        delta_transform: Transform,
        extra_rotation: Quat4f32,
    ) void {
        // Remembers the previous transform so the frame delta can be computed.
        const previous = self.current;

        // Accumulates rotation.
        self.rotation_accum = quat.normalize(
            quat.mul(self.rotation_accum, extra_rotation),
        );

        // Updates the current transform.
        self.current.translation = vec.add(
            self.current.translation,
            quat.rotate(self.rotation_accum, delta_transform.translation),
        );
        self.current.rotation = quat.normalize(quat.mul(
            quat.mul(self.current.rotation, delta_transform.rotation),
            extra_rotation,
        ));

        // Computes the motion delta.
        self.delta.translation = vec.sub(self.current.translation, previous.translation);
        self.delta.rotation = quat.mul(
            quat.conjugate(previous.rotation),
            self.current.rotation,
        );
    }

    /// Moves the accumulator to a new origin, clearing the delta and the
    /// accumulated steering rotation.
    pub fn teleport(self: *MotionDeltaAccumulator, origin: Transform) void {
        self.current = origin;
        self.delta = .identity;
        self.rotation_accum = quat.identity;
    }
};

/// Turns absolute motion samples into deltas before accumulating them
/// (motion_utils.cc:138). `base` is the "inherited" `MotionDeltaAccumulator`.
pub const MotionAccumulator = struct {
    base: MotionDeltaAccumulator = .{},
    /// Last absolute sample, the origin the next delta is computed from.
    last: Transform = .identity,

    /// Accumulated transform.
    pub fn current(self: MotionAccumulator) Transform {
        return self.base.current;
    }

    /// Delta applied by the last `update`.
    pub fn delta(self: MotionAccumulator) Transform {
        return self.base.delta;
    }

    /// Accumulates `new - last`, steered by `delta_rotation`.
    pub fn update(
        self: *MotionAccumulator,
        new: Transform,
        delta_rotation: Quat4f32,
    ) void {
        const animated_delta: Transform = .{
            .translation = vec.sub(new.translation, self.last.translation),
            .rotation = quat.mul(quat.conjugate(self.last.rotation), new.rotation),
        };
        self.base.update(animated_delta, delta_rotation);
        self.last = new;
    }

    /// Restarts delta computation from `origin`, used when the animation loops.
    pub fn resetOrigin(self: *MotionAccumulator, origin: Transform) void {
        self.last = origin;
    }

    /// Teleports and restarts delta computation from the new position.
    pub fn teleport(self: *MotionAccumulator, origin: Transform) void {
        self.base.teleport(origin);
        self.last = self.base.current;
    }
};

/// Samples a `MotionTrack` and accumulates it, taking animation loops into
/// account (motion_utils.cc:168).
pub const MotionSampler = struct {
    accumulator: MotionAccumulator = .{},

    /// Accumulated transform.
    pub fn current(self: MotionSampler) Transform {
        return self.accumulator.base.current;
    }

    /// Delta applied by the last `update`.
    pub fn delta(self: MotionSampler) Transform {
        return self.accumulator.base.delta;
    }

    /// `loops` is exactly the value returned by `PlaybackController.update`:
    /// negative when playing backwards, zero when the animation did not wrap.
    pub fn update(
        self: *MotionSampler,
        motion: MotionTrack,
        ratio: f32,
        loops: i32,
        delta_rotation: Quat4f32,
    ) void {
        if (loops != 0) {
            // While looping, the motion done during the loop(s) matters, so it is
            // accumulated locally first.
            var local: MotionAccumulator = .{};
            local.teleport(self.accumulator.last);

            var remaining = loops;
            while (remaining != 0) {
                const forward = remaining > 0;
                // Motion up to the track end (or begin when playing backwards).
                local.update(sampleMotion(motion, if (forward) 1 else 0), quat.identity);
                // Motion restarts from the new origin.
                local.resetOrigin(sampleMotion(motion, if (forward) 0 else 1));
                remaining += if (forward) -1 else 1;
            }

            // Motion since the loop end.
            const sample = sampleMotion(motion, ratio);
            local.update(sample, quat.identity);

            // Applies the steering rotation to the whole span, loops included.
            self.accumulator.update(local.base.current, delta_rotation);
            self.accumulator.resetOrigin(sample);
        } else {
            self.accumulator.update(sampleMotion(motion, ratio), delta_rotation);
        }
    }

    /// Restarts delta computation from `origin`.
    pub fn resetOrigin(self: *MotionSampler, origin: Transform) void {
        self.accumulator.resetOrigin(origin);
    }

    /// Teleports the sampler to `origin`.
    pub fn teleport(self: *MotionSampler, origin: Transform) void {
        self.accumulator.teleport(origin);
    }
};

// -----------------------------------------------------------------------------
// Path visualization
// -----------------------------------------------------------------------------

/// Maximum number of points a single `drawMotion` line strip can hold. Upstream
/// grows a vector; a fixed buffer keeps this function allocation-free, which is
/// what lets it keep the published signature.
pub const max_motion_points = 1024;

/// Draws the past (green) and future (white) motion path around `at`, by
/// re-running a `MotionSampler` over `[from, to]` in `step` increments. This is
/// also a good exercise of `MotionSampler`/`MotionAccumulator`.
///
/// `renderer` is duck-typed: only `drawLineStrip(points, color, transform)` is
/// used, so no GPU type leaks into this module.
pub fn drawMotion(
    renderer: anytype,
    track: MotionTrack,
    at: f32,
    from: f32,
    to: f32,
    step: f32,
    transform: Float4x4,
    delta_rotation: Quat4f32,
) !void {
    if (step <= 0 or to <= from) return;

    // Places the world-space path relative to the character's current sample.
    const at_transform = sampleMotion(track, at);
    const inverse = Float4x4.inverse(Float4x4.fromTransform(at_transform)) orelse return;
    const path_transform = Float4x4.mul(transform, inverse);

    var sampler: MotionSampler = .{};
    var points: [max_motion_points]Vec3f32 = undefined;
    var count: usize = 0;

    // Present to past, -step by -step, steered by the inverse rotation so the
    // trail curves consistently in reverse.
    const inverse_rotation = quat.conjugate(delta_rotation);
    sampler.teleport(at_transform);
    {
        var t: f32 = at;
        var previous: f32 = at;
        while (t > from - step and count < points.len) {
            appendSample(&sampler, track, @max(t, from), previous, inverse_rotation, &points, &count);
            previous = t;
            t -= step;
        }
    }
    try renderer.drawLineStrip(
        points[0..count],
        .{ .r = 0, .g = 255, .b = 0, .a = 255 },
        path_transform,
    );

    // Present to future, step by step.
    count = 0;
    sampler.teleport(at_transform);
    {
        var t: f32 = at;
        var previous: f32 = at;
        while (t < to + step and count < points.len) {
            appendSample(&sampler, track, @min(t, to), previous, delta_rotation, &points, &count);
            previous = t;
            t += step;
        }
    }
    try renderer.drawLineStrip(
        points[0..count],
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        path_transform,
    );
}

fn appendSample(
    sampler: *MotionSampler,
    track: MotionTrack,
    t: f32,
    previous: f32,
    rotation: Quat4f32,
    points: []Vec3f32,
    count: *usize,
) void {
    const loops: i32 = @intFromFloat(@floor(t) - @floor(previous));
    sampler.update(track, t - @floor(t), loops, rotation);
    points[count.*] = sampler.current().translation;
    count.* += 1;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

/// Records every line strip so `drawMotion` can be checked without a GPU.
const TestRenderer = struct {
    const Color = extern struct { r: u8, g: u8, b: u8, a: u8 = 255 };
    const Strip = struct {
        points: std.ArrayList(Vec3f32) = .empty,
        color: Color = .{ .r = 0, .g = 0, .b = 0 },
        transform: Float4x4 = .identity,
    };

    allocator: std.mem.Allocator,
    strips: std.ArrayList(Strip) = .empty,

    fn deinit(self: *TestRenderer) void {
        for (self.strips.items) |*strip| strip.points.deinit(self.allocator);
        self.strips.deinit(self.allocator);
    }

    fn drawLineStrip(
        self: *TestRenderer,
        points: []const Vec3f32,
        color: Color,
        transform: Float4x4,
    ) !void {
        var strip: Strip = .{ .color = color, .transform = transform };
        try strip.points.appendSlice(self.allocator, points);
        try self.strips.append(self.allocator, strip);
    }
};

/// A straight two-metre walk along +Z with no rotation, built without any asset.
fn syntheticTrack(allocator: std.mem.Allocator) !MotionTrack {
    var position = try ozz.animation.Float3Track.init(allocator, "position", &.{
        .{ .ratio = 0, .value = .{ 0, 0, 0 } },
        .{ .ratio = 1, .value = .{ 0, 0, 2 } },
    }, .linear);
    errdefer position.deinit();
    return .{
        .position = position,
        .rotation = try ozz.animation.QuaternionTrack.init(allocator, "rotation", &.{
            .{ .ratio = 0, .value = quat.identity },
            .{ .ratio = 1, .value = quat.identity },
        }, .linear),
    };
}

test "motion track decodes both tracks from one archive" {
    const allocator = std.testing.allocator;
    var track = try MotionTrack.decode(allocator, @embedFile("pab_walk_motion"));
    defer track.deinit();

    try std.testing.expect(track.position.keys.len > 0);
    // `pab_walk` moves straight ahead, so its rotation track is empty. An empty
    // runtime track is valid and samples to the identity rotation.
    try std.testing.expectEqual(@as(usize, 0), track.rotation.keys.len);

    const begin = track.sample(0);
    const end = track.sample(1);
    // A walk cycle moves the character.
    try std.testing.expect(vec.norm(vec.sub(end.translation, begin.translation)) > 0.1);
    try std.testing.expectEqual(Vec3f32{ 1, 1, 1 }, begin.scale);
    try std.testing.expect(quat.isNormalized(end.rotation));

    // sampleMotion is the free-function spelling of the same thing.
    try std.testing.expectEqual(begin.translation, sampleMotion(track, 0).translation);
}

test "motion track deltas compose over loops" {
    const allocator = std.testing.allocator;
    var track = try syntheticTrack(allocator);
    defer track.deinit();

    const half = track.delta(0, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), half.translation[2], 1e-5);

    // Wrapping through the track end.
    const wrapped = track.delta(0.75, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 1), wrapped.translation[2], 1e-5);

    // Two whole loops plus a half.
    const range = track.deltaRange(0, 2.5);
    try std.testing.expectApproxEqAbs(@as(f32, 5), range.translation[2], 1e-4);

    // Playing backwards inverts the motion.
    const backwards = track.deltaRange(2.5, 0);
    try std.testing.expectApproxEqAbs(@as(f32, -5), backwards.translation[2], 1e-4);

    // inverseMotion round-trips.
    const round_trip = Transform.combine(range, inverseMotion(range));
    try std.testing.expectApproxEqAbs(@as(f32, 0), vec.norm(round_trip.translation), 1e-4);
}

test "motion delta accumulator steers translations" {
    var accumulator: MotionDeltaAccumulator = .{};
    const forward: Transform = .{ .translation = .{ 0, 0, 1 } };

    accumulator.update(forward, quat.identity);
    try std.testing.expectApproxEqAbs(@as(f32, 1), accumulator.current.translation[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), accumulator.delta.translation[2], 1e-5);

    // A quarter turn about Y steers the *next* delta into -X (right handed).
    const quarter = quat.fromAxisAngle(.{ 0, 1, 0 }, std.math.pi / 2.0);
    accumulator.update(forward, quarter);
    try std.testing.expectApproxEqAbs(@as(f32, 1), accumulator.current.translation[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), accumulator.current.translation[2], 1e-5);
    try std.testing.expect(!quat.approxRotationEq(
        accumulator.rotation_accum,
        quat.identity,
        0.9999,
    ));

    accumulator.teleport(.{ .translation = .{ 5, 0, 5 } });
    try std.testing.expectEqual(Vec3f32{ 5, 0, 5 }, accumulator.current.translation);
    try std.testing.expectEqual(Vec3f32{ 0, 0, 0 }, accumulator.delta.translation);
    try std.testing.expect(quat.approxRotationEq(
        accumulator.rotation_accum,
        quat.identity,
        0.9999,
    ));
}

test "motion accumulator converts absolute samples into deltas" {
    var accumulator: MotionAccumulator = .{};
    accumulator.update(.{ .translation = .{ 0, 0, 1 } }, quat.identity);
    accumulator.update(.{ .translation = .{ 0, 0, 3 } }, quat.identity);
    try std.testing.expectApproxEqAbs(@as(f32, 3), accumulator.current().translation[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), accumulator.delta().translation[2], 1e-5);

    // Resetting the origin makes the next sample a fresh delta.
    accumulator.resetOrigin(.{ .translation = .{ 0, 0, 0 } });
    accumulator.update(.{ .translation = .{ 0, 0, 1 } }, quat.identity);
    try std.testing.expectApproxEqAbs(@as(f32, 4), accumulator.current().translation[2], 1e-5);

    // Teleporting also moves the origin, so the very next identical sample is a
    // no-op rather than a jump.
    accumulator.teleport(.{ .translation = .{ 10, 0, 0 } });
    try std.testing.expectEqual(accumulator.current(), accumulator.last);
}

test "motion sampler accumulates across loops" {
    const allocator = std.testing.allocator;
    var track = try syntheticTrack(allocator);
    defer track.deinit();

    var sampler: MotionSampler = .{};
    sampler.teleport(sampleMotion(track, 0));

    // Half a loop.
    sampler.update(track, 0.5, 0, quat.identity);
    try std.testing.expectApproxEqAbs(@as(f32, 1), sampler.current().translation[2], 1e-5);

    // Wrap: 0.5 -> 1.25 crosses the track end once.
    sampler.update(track, 0.25, 1, quat.identity);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), sampler.current().translation[2], 1e-4);

    // Stepping ratio by ratio without any loop is monotonic.
    var stepped: MotionSampler = .{};
    stepped.teleport(sampleMotion(track, 0));
    var ratio: f32 = 0;
    var previous: f32 = 0;
    while (ratio <= 1.0001) : (ratio += 0.1) {
        stepped.update(track, @min(ratio, 1), 0, quat.identity);
        try std.testing.expect(stepped.current().translation[2] >= previous - 1e-5);
        previous = stepped.current().translation[2];
    }
    try std.testing.expectApproxEqAbs(@as(f32, 2), previous, 1e-4);

    // Playing backwards over a loop boundary moves the other way.
    var reverse: MotionSampler = .{};
    reverse.teleport(sampleMotion(track, 0.25));
    reverse.resetOrigin(sampleMotion(track, 0.25));
    reverse.update(track, 0.75, -1, quat.identity);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), reverse.current().translation[2], 1e-4);
}

test "drawMotion emits a past and a future line strip" {
    const allocator = std.testing.allocator;
    var track = try syntheticTrack(allocator);
    defer track.deinit();

    var renderer: TestRenderer = .{ .allocator = allocator };
    defer renderer.deinit();

    try drawMotion(&renderer, track, 0.5, -1, 1, 0.1, .identity, quat.identity);
    try std.testing.expectEqual(@as(usize, 2), renderer.strips.items.len);

    const past = renderer.strips.items[0];
    const future = renderer.strips.items[1];
    try std.testing.expectEqual(@as(u8, 255), past.color.g);
    try std.testing.expectEqual(@as(u8, 0), past.color.r);
    try std.testing.expectEqual(@as(u8, 255), future.color.r);
    // [-1, 0.5] stepped by 0.1 walks 16 points back, [0.5, 1] walks 6 forward.
    try std.testing.expectEqual(@as(usize, 16), past.points.items.len);
    try std.testing.expectEqual(@as(usize, 6), future.points.items.len);

    // Both strips start at the sample point, i.e. at the current transform.
    const at_translation = sampleMotion(track, 0.5).translation;
    try std.testing.expectApproxEqAbs(
        at_translation[2],
        past.points.items[0][2],
        1e-4,
    );
    try std.testing.expectApproxEqAbs(
        at_translation[2],
        future.points.items[0][2],
        1e-4,
    );
    // The past walks backwards and the future forwards along +Z.
    try std.testing.expect(past.points.items[past.points.items.len - 1][2] <
        past.points.items[0][2]);
    try std.testing.expect(future.points.items[future.points.items.len - 1][2] >
        future.points.items[0][2]);

    // Invalid inputs draw nothing at all.
    var ignored: TestRenderer = .{ .allocator = allocator };
    defer ignored.deinit();
    try drawMotion(&ignored, track, 0.5, 1, -1, 0.1, .identity, quat.identity);
    try drawMotion(&ignored, track, 0.5, -1, 1, 0, .identity, quat.identity);
    try std.testing.expectEqual(@as(usize, 0), ignored.strips.items.len);
}

test "motion track builds from raw extraction tracks" {
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(@embedFile("pab_skeleton"));
    var skeleton = try ozz.legacy.readSkeleton(allocator, &reader, .{});
    defer skeleton.deinit();

    var raw_reader = std.Io.Reader.fixed(@embedFile("pab_walk_raw"));
    var raw = try ozz.legacy.readRawAnimation(allocator, &raw_reader, .{});
    defer raw.deinit();

    var extraction = try ozz.offline.extractMotion(allocator, raw, skeleton, .{
        .position = .{ .x = true, .z = true, .bake = true },
        .rotation = .{ .y = true, .bake = true },
    });
    defer extraction.deinit();

    var track = try MotionTrack.fromRaw(allocator, extraction.position, extraction.rotation);
    defer track.deinit();

    const begin = track.sample(0);
    const end = track.sample(1);
    try std.testing.expect(vec.norm(vec.sub(end.translation, begin.translation)) > 0.1);
}
