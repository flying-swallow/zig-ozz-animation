// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/millipede/sample_millipede.cc`.
//!
//! Everything this sample displays is generated at run time: a `RawSkeleton` and
//! a `RawAnimation` are built procedurally, then converted to their runtime
//! counterparts with `SkeletonBuilder` / `AnimationBuilder`. No asset is loaded.
//!
//! A millipede slice is two legs and a vertebra, 7 joints organised as:
//! ```
//!          * root
//!             |
//!           spine                                   spine
//!         |       |                                   |
//!     left_up    right_up        left_down - left_u - . - right_u - right_down
//!       |           |                  |                                    |
//!   left_down     right_down     left_foot         * root            right_foot
//!     |               |
//! left_foot        right_foot
//! ```
//!
//! Deviation from upstream: `CreateAnimation` hard-codes the very transforms
//! `CreateSkeleton` wrote into the raw skeleton. Here each track is instead
//! seeded from the built skeleton's rest pose, which is bit-for-bit the same
//! for a freshly generated skeleton but lets `fw.utils.RawSkeletonEditor` edits
//! survive the rebuild. The editor is the reason rotation and scale keys are
//! emitted for every joint, where upstream only writes the few it needs.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Vec3f32 = ozz.math.Vec3f32;
const quat = ozz.math.quat;
const Quat4f32 = ozz.math.Quat4f32;
const Float4x4 = ozz.math.Float4x4;
const Transform = ozz.math.Transform;
const RawJoint = ozz.offline.RawJoint;
const RawSkeleton = ozz.offline.RawSkeleton;
const RawAnimation = ozz.offline.RawAnimation;

pub const name = "millipede";
pub const description = "Procedural offline skeleton and animation";

// -----------------------------------------------------------------------------
// Skeleton constants (sample_millipede.cc:73-86)
// -----------------------------------------------------------------------------

/// Local translation of the upper leg joints.
const trans_up: Vec3f32 = .{ 0, 0, 0 };
/// Local translation of the lower leg joints.
const trans_down: Vec3f32 = .{ 0, 0, 1 };
/// Local translation of the foot joints.
const trans_foot: Vec3f32 = .{ 1, 0, 0 };

/// Rest rotation of a left upper leg joint.
fn rotLeftUp() Quat4f32 {
    return quat.fromAxisAngle(.{ 0, 1, 0 }, -std.math.pi / 2.0);
}

/// Rest rotation of a left lower leg joint.
fn rotLeftDown() Quat4f32 {
    return quat.mul(
        quat.fromAxisAngle(.{ 1, 0, 0 }, std.math.pi / 2.0),
        quat.fromAxisAngle(.{ 0, 1, 0 }, -std.math.pi / 2.0),
    );
}

/// Rest rotation of a right upper leg joint.
fn rotRightUp() Quat4f32 {
    return quat.fromAxisAngle(.{ 0, 1, 0 }, std.math.pi / 2.0);
}

/// Rest rotation of a right lower leg joint. Upstream deliberately reuses the
/// left rotation here; the mirroring happens in the animation keys.
fn rotRightDown() Quat4f32 {
    return rotLeftDown();
}

// -----------------------------------------------------------------------------
// Animation constants (sample_millipede.cc:88-112)
// -----------------------------------------------------------------------------

/// Duration of the generated walk cycle, in seconds.
const duration: f32 = 6;
/// Distance between two vertebrae.
const spin_length: f32 = 0.5;
/// Distance covered by a single leg cycle.
const walk_cycle_length: f32 = 2;
/// Number of leg cycles played over `duration`.
const walk_cycle_count: i32 = 4;
/// Number of slices a leg phase shift wraps over.
const spin_loop: f32 = 2 * @as(f32, walk_cycle_count) * walk_cycle_length / spin_length;

/// Number of joints per slice: two legs of three joints plus a vertebra.
const joints_per_slice = 7;

/// Smallest joint count the GUI slider exposes, one slice.
const min_joints: i32 = 8;

/// One leg's key-frames, in the joint's own space, before the per-slice phase
/// shift is applied.
const PrecomputedKey = struct { time: f32, value: Vec3f32 };

const precomputed_keys = [_]PrecomputedKey{
    .{ .time = 0.0 * duration, .value = .{ 0.25 * walk_cycle_length, 0, 0 } },
    .{ .time = 0.125 * duration, .value = .{ -0.25 * walk_cycle_length, 0, 0 } },
    .{ .time = 0.145 * duration, .value = .{ -0.17 * walk_cycle_length, 0.3, 0 } },
    .{ .time = 0.23 * duration, .value = .{ 0.17 * walk_cycle_length, 0.3, 0 } },
    .{ .time = 0.25 * duration, .value = .{ 0.25 * walk_cycle_length, 0, 0 } },
    .{ .time = 0.375 * duration, .value = .{ -0.25 * walk_cycle_length, 0, 0 } },
    .{ .time = 0.395 * duration, .value = .{ -0.17 * walk_cycle_length, 0.3, 0 } },
    .{ .time = 0.48 * duration, .value = .{ 0.17 * walk_cycle_length, 0.3, 0 } },
    .{ .time = 0.5 * duration, .value = .{ 0.25 * walk_cycle_length, 0, 0 } },
    .{ .time = 0.625 * duration, .value = .{ -0.25 * walk_cycle_length, 0, 0 } },
    .{ .time = 0.645 * duration, .value = .{ -0.17 * walk_cycle_length, 0.3, 0 } },
    .{ .time = 0.73 * duration, .value = .{ 0.17 * walk_cycle_length, 0.3, 0 } },
    .{ .time = 0.75 * duration, .value = .{ 0.25 * walk_cycle_length, 0, 0 } },
    .{ .time = 0.875 * duration, .value = .{ -0.25 * walk_cycle_length, 0, 0 } },
    .{ .time = 0.895 * duration, .value = .{ -0.17 * walk_cycle_length, 0.3, 0 } },
    .{ .time = 0.98 * duration, .value = .{ 0.17 * walk_cycle_length, 0.3, 0 } },
};

// -----------------------------------------------------------------------------
// Raw skeleton generation
// -----------------------------------------------------------------------------

/// Zero-length placeholder name, so a joint is safe to free the instant its
/// storage exists. `Allocator.free` ignores empty slices.
var no_name_storage: [0]u8 = .{};
const no_name: []u8 = &no_name_storage;

/// Attaches `count` blank children to `joint`. The children are valid (and
/// therefore destroyable) before the function returns, which is what keeps a
/// half-built hierarchy safe to hand to `RawSkeleton.deinit`.
fn addChildren(
    allocator: std.mem.Allocator,
    joint: *RawJoint,
    count: usize,
) ![]RawJoint {
    std.debug.assert(joint.children.len == 0);
    const children = try allocator.alloc(RawJoint, count);
    @memset(children, .{ .name = no_name });
    joint.children = children;
    return children;
}

/// Replaces a joint's placeholder name with a formatted one.
fn setName(
    allocator: std.mem.Allocator,
    joint: *RawJoint,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch unreachable;
    const owned = try allocator.dupe(u8, text);
    allocator.free(joint.name);
    joint.name = owned;
}

/// Builds the offline millipede hierarchy: one root followed by `slice_count`
/// slices of two legs and a vertebra (`CreateSkeleton`, sample_millipede.cc:209).
pub fn buildRawSkeleton(allocator: std.mem.Allocator, slice_count: usize) !RawSkeleton {
    const roots = try allocator.alloc(RawJoint, 1);
    @memset(roots, .{ .name = no_name });
    var skeleton: RawSkeleton = .{ .allocator = allocator, .roots = roots };
    errdefer skeleton.deinit();

    var root: *RawJoint = &skeleton.roots[0];
    try setName(allocator, root, "root", .{});
    root.transform = .{
        .translation = .{ 0, 1, -@as(f32, @floatFromInt(slice_count)) * spin_length },
    };

    for (0..slice_count) |slice| {
        const children = try addChildren(allocator, root, 3);

        // Left leg.
        const lu = &children[0];
        try setName(allocator, lu, "lu{d}", .{slice});
        lu.transform = .{ .translation = trans_up, .rotation = rotLeftUp() };

        const ld = &(try addChildren(allocator, lu, 1))[0];
        try setName(allocator, ld, "ld{d}", .{slice});
        ld.transform = .{ .translation = trans_down, .rotation = rotLeftDown() };

        const lf = &(try addChildren(allocator, ld, 1))[0];
        try setName(allocator, lf, "lf{d}", .{slice});
        lf.transform = .{ .translation = trans_foot };

        // Right leg.
        const ru = &children[1];
        try setName(allocator, ru, "ru{d}", .{slice});
        ru.transform = .{ .translation = trans_up, .rotation = rotRightUp() };

        const rd = &(try addChildren(allocator, ru, 1))[0];
        try setName(allocator, rd, "rd{d}", .{slice});
        rd.transform = .{ .translation = trans_down, .rotation = rotRightDown() };

        const rf = &(try addChildren(allocator, rd, 1))[0];
        try setName(allocator, rf, "rf{d}", .{slice});
        rf.transform = .{ .translation = trans_foot };

        // Vertebra, which becomes the parent of the next slice.
        const sp = &children[2];
        try setName(allocator, sp, "sp{d}", .{slice});
        sp.transform = .{ .translation = .{ 0, 0, spin_length } };

        root = sp;
    }

    return skeleton;
}

// -----------------------------------------------------------------------------
// Raw animation generation
// -----------------------------------------------------------------------------

/// Component-wise linear interpolation, matching `ozz::math::Lerp(Float3)`.
fn lerp3(a: Vec3f32, b: Vec3f32, t: f32) Vec3f32 {
    return a + (b - a) * @as(Vec3f32, @splat(t));
}

/// True when `needle` appears anywhere in `haystack`, the Zig spelling of the
/// `strstr` dispatch upstream uses to recognise a joint by name.
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Builds the procedural walk cycle for `skeleton` (`CreateAnimation`,
/// sample_millipede.cc:284). Every track is seeded from the joint's rest pose,
/// so a skeleton edited through `RawSkeletonEditor` animates around its new
/// pose instead of snapping back to the generated one.
pub fn buildRawAnimation(
    allocator: std.mem.Allocator,
    skeleton: ozz.animation.Skeleton,
    slice_count: usize,
) !RawAnimation {
    var animation = try RawAnimation.init(
        allocator,
        "millipede",
        duration,
        skeleton.numJoints(),
    );
    errdefer animation.deinit();

    var keys: std.ArrayList(ozz.offline.TranslationKey) = .empty;
    defer keys.deinit(allocator);

    for (animation.tracks, 0..) |*track, joint| {
        const base: Transform = skeleton.jointRestPose(joint);
        const joint_name = skeleton.names[joint];
        keys.clearRetainingCapacity();

        if (contains(joint_name, "ld") or contains(joint_name, "rd")) {
            // A lower leg: replay the precomputed cycle, phase-shifted by the
            // slice this leg belongs to so the millipede ripples.
            const left = joint_name[0] == 'l';
            const slice = std.fmt.parseInt(i32, joint_name[2..], 10) catch 0;
            const offset = duration *
                @as(f32, @floatFromInt(@as(i32, @intCast(slice_count)) - slice)) / spin_loop;
            const phase = @mod(offset, duration);

            // Finds the first key at or after the phase, which becomes the key
            // played at t = 0.
            var start: usize = 0;
            while (start < precomputed_keys.len and precomputed_keys[start].time < phase) {
                start += 1;
            }

            try keys.ensureTotalCapacity(allocator, precomputed_keys.len + 2);
            for (0..precomputed_keys.len) |index| {
                const key = precomputed_keys[(start + index) % precomputed_keys.len];
                var time = key.time - phase;
                if (time < 0) time = duration - phase + key.time;
                const value: Vec3f32 = if (left) base.translation + key.value else .{
                    base.translation[0] - key.value[0],
                    base.translation[1] + key.value[1],
                    base.translation[2] + key.value[2],
                };
                keys.appendAssumeCapacity(.{ .time = time, .value = value });
            }
        } else if (contains(joint_name, "root")) {
            // The root walks forward over the whole animation.
            try keys.append(allocator, .{ .time = 0, .value = base.translation });
            try keys.append(allocator, .{ .time = duration, .value = .{
                base.translation[0],
                base.translation[1],
                @as(f32, @floatFromInt(walk_cycle_count)) * walk_cycle_length +
                    base.translation[2],
            } });
        } else {
            // Upper legs, feet and vertebrae simply hold their rest pose.
            try keys.append(allocator, .{ .time = 0, .value = base.translation });
        }

        // Makes sure the first and last keys are looping.
        if (keys.items[0].time != 0) {
            const front = keys.items[0];
            const back = keys.items[keys.items.len - 1];
            const ratio = front.time / (front.time + duration - back.time);
            try keys.insert(allocator, 0, .{
                .time = 0,
                .value = lerp3(front.value, back.value, ratio),
            });
        }
        if (keys.items[keys.items.len - 1].time != duration) {
            const front = keys.items[0];
            const back = keys.items[keys.items.len - 1];
            const ratio = (duration - back.time) / (front.time + duration - back.time);
            try keys.append(allocator, .{
                .time = duration,
                .value = lerp3(back.value, front.value, ratio),
            });
        }

        track.translations = try allocator.dupe(ozz.offline.TranslationKey, keys.items);
        track.rotations = try allocator.dupe(ozz.offline.RotationKey, &.{
            .{ .time = 0, .value = base.rotation },
        });
        track.scales = try allocator.dupe(ozz.offline.ScaleKey, &.{
            .{ .time = 0, .value = base.scale },
        });
    }

    return animation;
}

// -----------------------------------------------------------------------------
// Sample
// -----------------------------------------------------------------------------

/// What the next `onUpdate` has to regenerate. `onGui` cannot fail, so it only
/// records the intent and the rebuild happens on the update side.
const Rebuild = enum {
    /// Nothing to do.
    none,
    /// The joint count changed: regenerate the raw skeleton from scratch.
    slices,
    /// The raw skeleton was edited: keep it, rebuild the runtime objects.
    runtime,
};

pub const Sample = struct {
    allocator: std.mem.Allocator,

    /// Offline skeleton, kept alive so `RawSkeletonEditor` can edit it.
    raw_skeleton: RawSkeleton,
    /// Runtime skeleton built from `raw_skeleton`.
    skeleton: ozz.animation.Skeleton,
    /// Runtime animation, its sampling context and its local-space output.
    clip: fw.utils.Clip,
    /// Model-space matrices, the local-to-model output.
    models: []Float4x4,

    /// Playback time, speed and loop mode.
    controller: fw.PlaybackController = .{},
    /// Number of millipede slices, 7 joints each.
    slice_count: usize = 26,
    /// Immediate-mode editor for `raw_skeleton`.
    editor: fw.utils.RawSkeletonEditor = .{},
    /// Work `onGui` deferred to the next `onUpdate`.
    rebuild: Rebuild = .none,

    /// Default slice count, straight from upstream.
    pub const default_slice_count: usize = 26;

    /// Largest slice count that still fits the runtime joint limit.
    pub const max_slice_count: usize = (ozz.animation.max_joints - 1) / joints_per_slice;

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        // Fully procedural: the sample loads no asset at all.
        _ = assets;

        var raw_skeleton = try buildRawSkeleton(allocator, default_slice_count);
        errdefer raw_skeleton.deinit();

        var skeleton = try ozz.offline.SkeletonBuilder.build(allocator, raw_skeleton);
        errdefer skeleton.deinit();

        var clip = try buildClip(allocator, skeleton, default_slice_count);
        errdefer clip.deinit();

        const models = try allocator.alloc(Float4x4, skeleton.numJoints());

        return .{
            .allocator = allocator,
            .raw_skeleton = raw_skeleton,
            .skeleton = skeleton,
            .clip = clip,
            .models = models,
        };
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.models);
        self.clip.deinit();
        self.skeleton.deinit();
        self.raw_skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;

        switch (self.rebuild) {
            .none => {},
            .slices => try self.build(true),
            .runtime => try self.build(false),
        }

        _ = self.controller.update(self.clip.duration(), dt);
        try self.clip.sample(self.controller.time_ratio);
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.clip.pose,
        }, self.models);
        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        try renderer.drawPosture(self.skeleton, self.models, .identity, true);
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        var buffer: [64]u8 = undefined;

        // Joint count. Upstream drives the slice count through the joint count
        // so the label reads naturally, with an exponential response to keep
        // precision at the low end.
        var joints: i32 = @intCast(self.skeleton.numJoints());
        if (gui.doSliderInt(
            fw.im.formatZ(&buffer, "Joints count: {d}###joints_count", .{joints}),
            min_joints,
            ozz.animation.max_joints,
            &joints,
            0.3,
            true,
        )) {
            // The slider works on floats, so re-derive the slice count and only
            // rebuild when it really changed.
            const slices: usize = @intCast(@divTrunc(
                @max(joints, min_joints) - 1,
                @as(i32, joints_per_slice),
            ));
            if (slices != self.slice_count) {
                self.slice_count = std.math.clamp(slices, 1, max_slice_count);
                self.rebuild = .slices;
            }
        }

        gui.separator();
        self.controller.onGui(gui, self.clip.duration(), true, true);

        // The generated hierarchy is editable in place. Only the root is drawn
        // until it is expanded, so a 1023-joint millipede stays cheap.
        gui.separator();
        if (gui.openClose("Skeleton editor", false)) {
            if (self.editor.onGui(&self.raw_skeleton, gui) and self.rebuild == .none) {
                self.rebuild = .runtime;
            }
        }
    }

    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        return fw.utils.computePostureBounds(self.models, null);
    }

    /// Rebuilds the runtime skeleton, the animation and every buffer sized
    /// after them (`Build`, sample_millipede.cc:173). `regenerate` also throws
    /// the offline hierarchy away, which is what a joint count change needs.
    fn build(self: *Sample, regenerate: bool) !void {
        self.rebuild = .none;

        var raw_skeleton = if (regenerate)
            try buildRawSkeleton(self.allocator, self.slice_count)
        else
            self.raw_skeleton;
        errdefer if (regenerate) raw_skeleton.deinit();

        var skeleton = try ozz.offline.SkeletonBuilder.build(self.allocator, raw_skeleton);
        errdefer skeleton.deinit();

        var clip = try buildClip(self.allocator, skeleton, self.slice_count);
        errdefer clip.deinit();

        const models = try self.allocator.alloc(Float4x4, skeleton.numJoints());

        // Everything is built, the old state can go.
        self.allocator.free(self.models);
        self.clip.deinit();
        self.skeleton.deinit();
        if (regenerate) self.raw_skeleton.deinit();

        self.raw_skeleton = raw_skeleton;
        self.skeleton = skeleton;
        self.clip = clip;
        self.models = models;
    }
};

/// Generates the walk animation for `skeleton` and wraps its runtime build in a
/// ready-to-sample `Clip`.
fn buildClip(
    allocator: std.mem.Allocator,
    skeleton: ozz.animation.Skeleton,
    slice_count: usize,
) !fw.utils.Clip {
    var raw_animation = try buildRawAnimation(allocator, skeleton, slice_count);
    defer raw_animation.deinit();
    return fw.utils.Clip.init(
        allocator,
        try ozz.offline.AnimationBuilder.build(allocator, raw_animation),
    );
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "raw skeleton has 7 joints per slice plus a root" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 1, 3, 26 }) |slices| {
        var raw = try buildRawSkeleton(allocator, slices);
        defer raw.deinit();
        try std.testing.expectEqual(slices * joints_per_slice + 1, raw.numJoints());
        try std.testing.expect(raw.validate());
        try std.testing.expectEqualStrings("root", raw.roots[0].name);
        try std.testing.expectEqual(@as(usize, 3), raw.roots[0].children.len);
    }
}

test "the runtime skeleton is a depth-first flattening of the slices" {
    const allocator = std.testing.allocator;
    var raw = try buildRawSkeleton(allocator, 2);
    defer raw.deinit();

    var skeleton = try ozz.offline.SkeletonBuilder.build(allocator, raw);
    defer skeleton.deinit();

    try std.testing.expectEqual(@as(usize, 15), skeleton.numJoints());
    const expected = [_][]const u8{
        "root", "lu0", "ld0", "lf0", "ru0", "rd0", "rf0", "sp0",
        "lu1",  "ld1", "lf1", "ru1", "rd1", "rf1", "sp1",
    };
    for (expected, skeleton.names) |want, got| try std.testing.expectEqualStrings(want, got);
    // The root is pushed back so the millipede is centred on the origin.
    try std.testing.expectEqual(@as(f32, -1), skeleton.jointRestPose(0).translation[2]);
}

test "the generated animation is valid and buildable at every size" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 1, 2, 26 }) |slices| {
        var raw_skeleton = try buildRawSkeleton(allocator, slices);
        defer raw_skeleton.deinit();
        var skeleton = try ozz.offline.SkeletonBuilder.build(allocator, raw_skeleton);
        defer skeleton.deinit();

        var raw_animation = try buildRawAnimation(allocator, skeleton, slices);
        defer raw_animation.deinit();

        try std.testing.expect(raw_animation.validate());
        try std.testing.expectEqual(skeleton.numJoints(), raw_animation.tracks.len);
        try std.testing.expectEqual(duration, raw_animation.duration);

        // Every track is closed on both ends so the clip loops seamlessly.
        for (raw_animation.tracks) |track| {
            try std.testing.expect(track.translations.len >= 2);
            try std.testing.expectEqual(@as(f32, 0), track.translations[0].time);
            try std.testing.expectEqual(
                duration,
                track.translations[track.translations.len - 1].time,
            );
            try std.testing.expectEqual(@as(usize, 1), track.rotations.len);
            try std.testing.expectEqual(@as(usize, 1), track.scales.len);
        }

        // Lower legs are the only animated joints: 16 cycle keys plus the two
        // loop-closing ones at most.
        var animated: usize = 0;
        for (skeleton.names, raw_animation.tracks) |joint_name, track| {
            if (contains(joint_name, "ld") or contains(joint_name, "rd")) {
                animated += 1;
                try std.testing.expect(track.translations.len >= precomputed_keys.len);
            }
        }
        try std.testing.expectEqual(slices * 2, animated);

        var animation = try ozz.offline.AnimationBuilder.build(allocator, raw_animation);
        defer animation.deinit();
        try std.testing.expectEqual(skeleton.numJoints(), animation.numTracks());
    }
}

test "a rebuild produces the joint count the slider asked for" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    try std.testing.expectEqual(
        Sample.default_slice_count * joints_per_slice + 1,
        sample.skeleton.numJoints(),
    );
    try std.testing.expect(try sample.onUpdate(1.0 / 60.0, 0));

    // Same path the joint count slider takes, up and down.
    for ([_]usize{ 1, 12, Sample.max_slice_count, 4 }) |slices| {
        sample.slice_count = slices;
        sample.rebuild = .slices;
        try std.testing.expect(try sample.onUpdate(1.0 / 60.0, 0));

        const joints = slices * joints_per_slice + 1;
        try std.testing.expectEqual(joints, sample.skeleton.numJoints());
        try std.testing.expectEqual(joints, sample.clip.animation.numTracks());
        try std.testing.expectEqual(joints, sample.models.len);
        try std.testing.expectEqual(joints, sample.raw_skeleton.numJoints());
        try std.testing.expect(joints <= ozz.animation.max_joints);

        // The pose has to be finite everywhere, and the millipede is long.
        const bounds = sample.sceneBounds().?;
        try std.testing.expect(bounds.isValid());
        for (sample.models) |model| {
            try std.testing.expect(std.math.isFinite(model.translation()[0]));
            try std.testing.expect(std.math.isFinite(model.translation()[1]));
            try std.testing.expect(std.math.isFinite(model.translation()[2]));
        }
    }
}

test "editing the raw skeleton survives a runtime rebuild" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    // What `RawSkeletonEditor` does to a joint: move it.
    sample.raw_skeleton.roots[0].transform.translation = .{ 1, 2, 3 };
    sample.rebuild = .runtime;
    try std.testing.expect(try sample.onUpdate(0, 0));

    try std.testing.expectEqual(
        Vec3f32{ 1, 2, 3 },
        sample.skeleton.jointRestPose(0).translation,
    );
    // The animation is seeded from the rest pose, so the edit reaches the
    // sampled root key too (the root track starts exactly on its rest pose).
    try std.testing.expectEqual(
        Vec3f32{ 1, 2, 3 },
        ozz.math.soaLane(sample.clip.pose[0], 0).translation,
    );

    // A slice change regenerates the hierarchy and drops the edit.
    sample.slice_count = 3;
    sample.rebuild = .slices;
    try std.testing.expect(try sample.onUpdate(0, 0));
    try std.testing.expectEqual(
        @as(f32, -1.5),
        sample.skeleton.jointRestPose(0).translation[2],
    );
}

test "legs are phase shifted from one slice to the next" {
    const allocator = std.testing.allocator;
    var raw_skeleton = try buildRawSkeleton(allocator, 4);
    defer raw_skeleton.deinit();
    var skeleton = try ozz.offline.SkeletonBuilder.build(allocator, raw_skeleton);
    defer skeleton.deinit();
    var raw_animation = try buildRawAnimation(allocator, skeleton, 4);
    defer raw_animation.deinit();

    var transforms: [64]ozz.math.Transform = undefined;
    try ozz.offline.sampleRawAnimation(
        raw_animation,
        duration * 0.25,
        transforms[0..skeleton.numJoints()],
    );

    // "ld0" and "ld1" are the same joint one slice apart: their local
    // translations must differ, which is what makes the millipede ripple.
    var ld0: ?usize = null;
    var ld1: ?usize = null;
    for (skeleton.names, 0..) |joint_name, joint| {
        if (std.mem.eql(u8, joint_name, "ld0")) ld0 = joint;
        if (std.mem.eql(u8, joint_name, "ld1")) ld1 = joint;
    }
    const a = transforms[ld0.?].translation;
    const b = transforms[ld1.?].translation;
    try std.testing.expect(@reduce(.Or, @abs(a - b) > @as(Vec3f32, @splat(1e-3))));
}
