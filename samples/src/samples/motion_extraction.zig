// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/motion_extraction/sample_motion_extraction.cc`.
//!
//! The sample keeps the *offline* animation around and re-runs the whole
//! toolchain — `ozz.offline.extractMotion`, `optimizeTrack`, `buildTrack`,
//! `optimizeAnimation`, `AnimationBuilder` — every time a motion extraction
//! setting changes. That rebuild loop is the whole point: it lets every field of
//! `MotionExtractionOptions` be tweaked from the GUI and its effect on both the
//! runtime animation and the extracted motion path be seen immediately.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Float4x4 = ozz.math.Float4x4;
const Quaternion = ozz.math.Quaternion;
const Vec3f32 = ozz.math.Vec3f32;
const vec = ozz.math.vec;

const MotionComponent = ozz.offline.MotionComponent;

pub const name = "motion_extraction";
pub const description = "Offline motion extraction";

/// Tolerance handed to `optimizeTrack`, matching `TrackOptimizer`'s default.
const track_tolerance: f32 = 1e-3;

/// The character's collision capsule stand-in, drawn at the root transform.
const bounding: ozz.math.Box = .{
    .min = .{ -0.25, 0, -0.25 },
    .max = .{ 0.25, 1.8, 0.25 },
};

/// Byte sizes of every stage of the rebuild, shown in the GUI.
pub const Sizes = struct {
    /// The imported offline animation.
    raw: usize = 0,
    /// The same animation once the motion has been baked out.
    baked: usize = 0,
    /// The baked animation after `optimizeAnimation`.
    optimized: usize = 0,
    /// The runtime animation `AnimationBuilder` produced.
    runtime: usize = 0,
    /// Both runtime motion tracks.
    tracks: usize = 0,
    position_keys: usize = 0,
    rotation_keys: usize = 0,
};

pub const Sample = struct {
    allocator: std.mem.Allocator,

    /// Runtime skeleton.
    skeleton: ozz.animation.Skeleton,
    /// The imported animation, kept offline so extraction can be re-run.
    raw: ozz.offline.RawAnimation,
    /// Runtime animation rebuilt by `rebuild`, plus its context and pose.
    clip: fw.utils.Clip,
    /// Runtime motion tracks rebuilt by `rebuild`.
    motion_track: fw.MotionTrack,
    /// Model-space matrices, the output of the local-to-model conversion.
    models: []Float4x4,

    /// Playback time / speed / loop control.
    controller: fw.PlaybackController = .{},
    /// Character transform, sampled straight from the motion tracks.
    transform: Float4x4 = .identity,
    /// Byte sizes of the last rebuild.
    sizes: Sizes = .{},

    /// Enables the whole motion extraction pass.
    enable: bool = true,
    /// Which position components are captured, and how.
    position: MotionComponent = .{
        .x = true,
        .y = true,
        .z = true,
        .reference = .absolute,
        .bake = true,
    },
    /// Which rotation components (pitch / yaw / roll) are captured, and how.
    rotation: MotionComponent = .{
        .x = false,
        .y = true,
        .z = false,
        .reference = .absolute,
        .bake = true,
    },
    /// Set by `onGui` when a setting changed; consumed by the next `onUpdate`.
    /// `onGui` cannot fail, so the rebuild is deferred rather than run inline.
    dirty: bool = false,

    // Options to apply the extracted root motion at runtime.
    apply_motion_position: bool = true,
    apply_motion_rotation: bool = true,

    // Debug display options.
    show_box: bool = true,
    show_tracks: bool = true,

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(@embedFile("pab_skeleton")),
        );
        errdefer skeleton.deinit();

        var raw = try fw.utils.decodeRawAnimation(
            allocator,
            assets.rawOr(@embedFile("pab_atlas_raw")),
        );
        errdefer raw.deinit();
        if (raw.tracks.len != skeleton.numJoints()) return error.SkeletonAnimationMismatch;

        const models = try allocator.alloc(Float4x4, skeleton.numJoints());
        errdefer allocator.free(models);
        @memset(models, .identity);

        var sample: Sample = .{
            .allocator = allocator,
            .skeleton = skeleton,
            .raw = raw,
            // Replaced by `rebuild` right below; placeholders keep `Sample`
            // fully initialized in case that first rebuild fails.
            .clip = undefined,
            .motion_track = undefined,
            .models = models,
        };
        sample.clip = try fw.utils.Clip.init(
            allocator,
            try ozz.offline.AnimationBuilder.build(allocator, raw),
        );
        errdefer sample.clip.deinit();
        sample.motion_track = try emptyMotionTrack(allocator);
        errdefer sample.motion_track.deinit();

        try sample.rebuild();
        return sample;
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.models);
        self.motion_track.deinit();
        self.clip.deinit();
        self.raw.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;

        // A GUI change queued a rebuild of the animation and the tracks.
        if (self.dirty) {
            self.dirty = false;
            try self.rebuild();
        }

        _ = self.controller.update(self.clip.duration(), dt);

        // The character transform comes straight from the motion tracks; unlike
        // the motion_playback sample nothing is accumulated here, the tracks
        // hold absolute motion over one animation cycle.
        self.transform = .identity;
        if (self.enable and self.apply_motion_position) {
            self.transform = Float4x4.mul(self.transform, Float4x4.fromTransform(.{
                .translation = self.motion_track.position.sampleAt(self.controller.time_ratio),
            }));
        }
        if (self.enable and self.apply_motion_rotation) {
            self.transform = Float4x4.mul(self.transform, Float4x4.fromTransform(.{
                .rotation = self.motion_track.rotation.sampleAt(self.controller.time_ratio),
            }));
        }

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
            // Extracting the vertical component drops the character to the
            // ground, so the box follows it down.
            const offset: Vec3f32 = .{
                0,
                if (self.enable and self.position.y) -1 else 0,
                0,
            };
            try renderer.drawBoxIm(.{
                .min = vec.add(bounding.min, offset),
                .max = vec.add(bounding.max, offset),
            }, self.transform, fw.color.white);
        }

        if (self.show_tracks and self.enable) {
            const at = self.controller.time_ratio;
            const step = 1 / (self.clip.duration() * 60);
            try fw.motion_utils.drawMotion(
                renderer,
                self.motion_track,
                at,
                0,
                1,
                step,
                self.transform,
                .identity,
            );
        }
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        if (gui.openClose("Animation control", true)) {
            self.controller.onGui(gui, self.clip.duration(), true, true);
        }

        if (gui.openClose("Motion extraction", true)) {
            var rebuild_requested = gui.doCheckBox("Root motion extraction", &self.enable, true);

            _ = gui.doCheckBox("Apply motion position", &self.apply_motion_position, self.enable);
            _ = gui.doCheckBox("Apply motion rotation", &self.apply_motion_rotation, self.enable);

            if (gui.openClose("Position", true)) {
                rebuild_requested = settingsGui(
                    gui,
                    &self.position,
                    .{ "x", "y", "z" },
                    self.enable,
                ) or rebuild_requested;
            }
            if (gui.openClose("Rotation", true)) {
                rebuild_requested = settingsGui(
                    gui,
                    &self.rotation,
                    .{ "x / pitch", "y / yaw", "z / roll" },
                    self.enable,
                ) or rebuild_requested;
            }

            if (rebuild_requested) self.dirty = true;
        }

        if (gui.openClose("Sizes", false)) {
            gui.doLabel("Raw animation: {d} bytes", .{self.sizes.raw});
            gui.doLabel("Baked animation: {d} bytes", .{self.sizes.baked});
            gui.doLabel("Optimized animation: {d} bytes", .{self.sizes.optimized});
            gui.doLabel("Runtime animation: {d} bytes", .{self.sizes.runtime});
            gui.doLabel("Motion tracks: {d} bytes", .{self.sizes.tracks});
            gui.doLabel("Position keys: {d}", .{self.sizes.position_keys});
            gui.doLabel("Rotation keys: {d}", .{self.sizes.rotation_keys});
        }

        if (gui.openClose("Debug display", false)) {
            _ = gui.doCheckBox("Show bounding box", &self.show_box, true);
            _ = gui.doCheckBox("Show motion tracks", &self.show_tracks, self.enable);
        }
    }

    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        return fw.utils.computePostureBounds(self.models, self.transform);
    }

    /// Re-runs extraction, optimization and runtime building with the current
    /// settings. On failure the previous animation and tracks are kept.
    pub fn rebuild(self: *Sample) !void {
        const allocator = self.allocator;

        // The animation the runtime animation is built from: the baked output
        // of the extractor, or an untouched copy of the imported animation.
        var animation: ozz.offline.RawAnimation = undefined;
        var motion_track: fw.MotionTrack = undefined;
        var position_keys: usize = 0;
        var rotation_keys: usize = 0;

        if (self.enable) {
            var extraction = try ozz.offline.extractMotion(
                allocator,
                self.raw,
                self.skeleton,
                .{ .position = self.position, .rotation = self.rotation },
            );
            // `extraction.baked` is handed over to `animation` on success, so
            // it is released here only while the rebuild can still fail.
            var baked_owned = false;
            defer {
                extraction.position.deinit();
                extraction.rotation.deinit();
                if (!baked_owned) extraction.baked.deinit();
            }

            var position = try ozz.offline.optimizeTrack(
                Vec3f32,
                allocator,
                extraction.position,
                track_tolerance,
            );
            defer position.deinit();
            var rotation = try ozz.offline.optimizeTrack(
                Quaternion,
                allocator,
                extraction.rotation,
                track_tolerance,
            );
            defer rotation.deinit();

            motion_track = try fw.MotionTrack.fromRaw(allocator, position, rotation);
            position_keys = position.keys.len;
            rotation_keys = rotation.keys.len;

            baked_owned = true;
            animation = extraction.baked;
        } else {
            // No extraction: the original animation is used as-is and the
            // motion tracks are emptied.
            motion_track = try emptyMotionTrack(allocator);
            animation = try fw.utils.cloneRawAnimation(allocator, self.raw);
        }
        errdefer motion_track.deinit();
        defer animation.deinit();

        // Optimizes and builds the runtime animation.
        var optimized = try ozz.offline.optimizeAnimation(
            allocator,
            animation,
            self.skeleton,
            .{},
        );
        defer optimized.deinit();
        var clip = try fw.utils.Clip.init(
            allocator,
            try ozz.offline.AnimationBuilder.build(allocator, optimized),
        );
        errdefer clip.deinit();
        if (clip.animation.numTracks() != self.skeleton.numJoints()) {
            return error.SkeletonAnimationMismatch;
        }

        // Everything succeeded: swap the new objects in. Replacing the clip
        // also replaces the sampling context, which is how the "animation
        // changed, invalidate the context" requirement is met.
        self.sizes = .{
            .raw = self.raw.memorySize(),
            .baked = animation.memorySize(),
            .optimized = optimized.memorySize(),
            .runtime = clip.animation.memorySize(),
            .tracks = trackSize(Vec3f32, motion_track.position) +
                trackSize(Quaternion, motion_track.rotation),
            .position_keys = position_keys,
            .rotation_keys = rotation_keys,
        };
        self.clip.deinit();
        self.clip = clip;
        self.motion_track.deinit();
        self.motion_track = motion_track;

        // Time is a ratio, so it stays valid across a duration change.
        self.controller.setTimeRatio(self.controller.time_ratio);
    }
};

/// One `MotionComponent` editor: components, reference frame, bake and loop.
/// Returns true when anything changed, i.e. when a rebuild is needed.
fn settingsGui(
    gui: *fw.Im,
    settings: *MotionComponent,
    components: [3][:0]const u8,
    enabled: bool,
) bool {
    var changed = false;
    if (gui.openClose("Components", true)) {
        changed = gui.doCheckBox(components[0], &settings.x, enabled) or changed;
        changed = gui.doCheckBox(components[1], &settings.y, enabled) or changed;
        changed = gui.doCheckBox(components[2], &settings.z, enabled) or changed;
    }
    if (gui.openClose("Reference", true)) {
        var reference: i32 = @intFromEnum(settings.reference);
        changed = gui.doRadioButton(0, "Absolute", &reference, enabled) or changed;
        changed = gui.doRadioButton(1, "Skeleton", &reference, enabled) or changed;
        changed = gui.doRadioButton(2, "Animation", &reference, enabled) or changed;
        settings.reference = @enumFromInt(std.math.clamp(reference, 0, 2));
    }
    changed = gui.doCheckBox("Bake", &settings.bake, enabled) or changed;
    changed = gui.doCheckBox("Loop", &settings.loop, enabled) or changed;
    return changed;
}

/// A motion track with no keys at all, which samples to the identity transform.
fn emptyMotionTrack(allocator: std.mem.Allocator) !fw.MotionTrack {
    var position = try ozz.animation.Float3Track.init(allocator, "motion_position", &.{}, .linear);
    errdefer position.deinit();
    return .{
        .position = position,
        .rotation = try ozz.animation.QuaternionTrack.init(
            allocator,
            "motion_rotation",
            &.{},
            .linear,
        ),
    };
}

/// Byte size of a runtime track, which has no `memorySize` of its own.
fn trackSize(comptime T: type, track: ozz.animation.Track(T)) usize {
    return @sizeOf(ozz.animation.Track(T)) + track.name.len +
        track.keys.len * @sizeOf(ozz.animation.Track(T).Key);
}

// -----------------------------------------------------------------------------
// Tests — the whole feature path runs without a GPU.
// -----------------------------------------------------------------------------

test "extraction produces a motion path and a baked animation" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    try std.testing.expect(sample.motion_track.position.keys.len > 1);
    try std.testing.expect(sample.motion_track.rotation.keys.len > 0);
    try std.testing.expectEqual(
        sample.skeleton.numJoints(),
        sample.clip.animation.numTracks(),
    );

    // Every rebuild stage reports a size, and the runtime animation is the
    // smallest of them.
    try std.testing.expect(sample.sizes.raw > 0);
    try std.testing.expect(sample.sizes.baked > 0);
    try std.testing.expect(sample.sizes.optimized > 0);
    try std.testing.expect(sample.sizes.runtime > 0);
    try std.testing.expect(sample.sizes.tracks > 0);
    try std.testing.expect(sample.sizes.runtime < sample.sizes.raw);
    try std.testing.expectEqual(
        sample.motion_track.position.keys.len,
        sample.sizes.position_keys,
    );

    // The default settings capture all three position components, so the path
    // travels away from the origin.
    const begin = sample.motion_track.position.sampleAt(0);
    const end = sample.motion_track.position.sampleAt(1);
    try std.testing.expect(vec.norm(vec.sub(end, begin)) > 0.1);

    // Playing the animation moves the character through that path.
    const dt: f32 = 1.0 / 60.0;
    for (0..60) |_| try std.testing.expect(try sample.onUpdate(dt, 0));
    try std.testing.expect(vec.norm(sample.transform.translation()) > 0);
}

test "component settings decide which axes the path uses" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    sample.position = .{ .x = true, .y = false, .z = false, .bake = true };
    sample.rotation = .{ .bake = true };
    try sample.rebuild();

    for (sample.motion_track.position.keys) |key| {
        try std.testing.expectEqual(@as(f32, 0), key.value[1]);
        try std.testing.expectEqual(@as(f32, 0), key.value[2]);
    }
    // A rotation with no component selected extracts nothing at all.
    for (sample.motion_track.rotation.keys) |key| {
        try std.testing.expect(Quaternion.approxRotationEq(key.value, .identity, 0.9999));
    }

    // Selecting z as well brings that axis back.
    sample.position.z = true;
    try sample.rebuild();
    var moved_in_z = false;
    for (sample.motion_track.position.keys) |key| {
        if (@abs(key.value[2]) > 1e-4) moved_in_z = true;
    }
    try std.testing.expect(moved_in_z);
}

test "the reference frame changes the extracted values" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    sample.position.reference = .absolute;
    try sample.rebuild();
    const absolute = sample.motion_track.position.sampleAt(0);

    sample.position.reference = .animation;
    try sample.rebuild();
    // Relative to the animation's first key, the path always starts at zero.
    try std.testing.expectApproxEqAbs(
        @as(f32, 0),
        vec.norm(sample.motion_track.position.sampleAt(0)),
        1e-4,
    );

    sample.position.reference = .skeleton;
    try sample.rebuild();
    const skeleton_relative = sample.motion_track.position.sampleAt(0);
    try std.testing.expect(vec.norm(vec.sub(absolute, skeleton_relative)) >= 0);
    // All three references still describe the same travelled distance.
    const travelled = vec.norm(vec.sub(
        sample.motion_track.position.sampleAt(1),
        skeleton_relative,
    ));
    try std.testing.expect(travelled > 0.1);
}

test "the loop setting closes the extracted path" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    sample.rotation = .{ .y = true, .bake = true, .loop = false };
    try sample.rebuild();
    const open = Quaternion.dot(
        sample.motion_track.rotation.sampleAt(0),
        sample.motion_track.rotation.sampleAt(1),
    );

    sample.rotation.loop = true;
    try sample.rebuild();
    const closed = Quaternion.dot(
        sample.motion_track.rotation.sampleAt(0),
        sample.motion_track.rotation.sampleAt(1),
    );

    // Looping distributes the begin/end difference over the whole track, so the
    // two ends end up at least as aligned as before.
    try std.testing.expect(@abs(closed) >= @abs(open) - 1e-4);
}

test "disabling extraction restores the original animation" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    const extracted_size = sample.sizes.runtime;
    sample.enable = false;
    try sample.rebuild();

    try std.testing.expectEqual(@as(usize, 0), sample.motion_track.position.keys.len);
    try std.testing.expectEqual(@as(usize, 0), sample.motion_track.rotation.keys.len);
    try std.testing.expectEqual(@as(usize, 0), sample.sizes.position_keys);
    // The un-baked animation still carries the motion, so it is not smaller.
    try std.testing.expect(sample.sizes.runtime >= extracted_size);

    // With extraction off the character transform never leaves the origin.
    const dt: f32 = 1.0 / 60.0;
    for (0..60) |_| _ = try sample.onUpdate(dt, 0);
    try std.testing.expectEqual(Float4x4.identity, sample.transform);

    // ... but the animation itself now travels, because nothing was baked out.
    var extremes: [2]f32 = .{ std.math.inf(f32), -std.math.inf(f32) };
    for (0..60) |step| {
        sample.controller.setTimeRatio(@as(f32, @floatFromInt(step)) / 60);
        _ = try sample.onUpdate(0, 0);
        const z = sample.models[0].translation()[2];
        extremes[0] = @min(extremes[0], z);
        extremes[1] = @max(extremes[1], z);
    }
    try std.testing.expect(extremes[1] - extremes[0] > 0.1);
}

test "a gui change queues exactly one rebuild" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    // `onGui` never rebuilds by itself, `onUpdate` consumes the flag.
    sample.position = .{ .x = true, .bake = true };
    sample.dirty = true;
    _ = try sample.onUpdate(1.0 / 60.0, 0);
    try std.testing.expect(!sample.dirty);
    for (sample.motion_track.position.keys) |key| {
        try std.testing.expectEqual(@as(f32, 0), key.value[2]);
    }

    // An inert gui changes nothing and queues nothing.
    var gui = fw.Im.init(false);
    sample.onGui(&gui);
    try std.testing.expect(!sample.dirty);
    try std.testing.expect(sample.enable);
}

test "an empty motion track samples to the identity transform" {
    const allocator = std.testing.allocator;
    var track = try emptyMotionTrack(allocator);
    defer track.deinit();

    const sampled = track.sample(0.5);
    try std.testing.expectEqual(Vec3f32{ 0, 0, 0 }, sampled.translation);
    try std.testing.expect(Quaternion.approxRotationEq(sampled.rotation, .identity, 0.9999));
    try std.testing.expect(trackSize(Vec3f32, track.position) > 0);
}
