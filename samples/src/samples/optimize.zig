// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/optimize/sample_optimize.cc`.
//!
//! The sample loads a runtime skeleton and the *raw*, unoptimized animation the
//! importer produced, then runs `offline.optimizeAnimation` +
//! `offline.AnimationBuilder` over it every time a tolerance changes. Both
//! animations are sampled each frame — the raw one through
//! `offline.sampleRawAnimation`, the optimized one through the normal runtime
//! sampling job — so the error the optimization introduces can be measured and
//! displayed.
//!
//! Deviation from upstream: `OnUpdate` sorts the per-joint squared errors and
//! then reads `errors_sq[joint_]`, which after the sort is the joint-th
//! *smallest* error rather than the error of the selected joint. Here the
//! selected joint's error is read before sorting, so the "Joint N error" graph
//! actually tracks joint N.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Vec3f32 = ozz.math.Vec3f32;
const Quaternion = ozz.math.Quaternion;
const Float4x4 = ozz.math.Float4x4;
const Transform = ozz.math.Transform;
const SoaTransform = ozz.math.SoaTransform;
const RawAnimation = ozz.offline.RawAnimation;

pub const name = "optimize";
pub const description = "Animation optimization";

/// Joint upstream selects by default for the per-joint tolerance override: a
/// finger tip, where the accumulated hierarchy error is largest.
const default_override_joint = "L Finger2Nub";

/// Length of the error history the graphs plot, matching upstream's `Record(64)`.
const ErrorRecord = fw.profile.Record(64);

/// Which posture `onDisplay` draws.
const DisplayMode = enum(i32) {
    /// The optimized, compressed runtime animation.
    runtime_animation = 0,
    /// The source raw animation, sampled offline.
    raw_animation = 1,
    /// The difference between the two, rebound onto the rest pose.
    absolute_error = 2,
    /// Runtime and raw postures next to each other.
    side_by_side = 3,
};

pub const Sample = struct {
    allocator: std.mem.Allocator,

    /// Runtime skeleton the animation is optimized against.
    skeleton: ozz.animation.Skeleton,
    /// Imported non-optimized animation.
    raw: RawAnimation,
    /// Optimizer output, kept alive for its memory-size readout.
    optimized: RawAnimation,
    /// Runtime animation built from `optimized`, its context and local output.
    clip: fw.utils.Clip,

    /// Model-space matrices sampled from the runtime animation.
    models_rt: []Float4x4,
    /// AoS scratch `sampleRawAnimation` writes into.
    locals_raw_aos: []Transform,
    /// `locals_raw_aos` transposed to SoA, the local-to-model input.
    locals_raw: []SoaTransform,
    /// Model-space matrices sampled from the raw animation.
    models_raw: []Float4x4,
    /// Runtime-minus-raw difference, rebound onto the rest pose.
    locals_diff: []SoaTransform,
    /// Model-space matrices of `locals_diff`.
    models_diff: []Float4x4,
    /// Per-joint squared model-space error, reused every frame.
    errors_sq: []f32,

    /// Playback time, speed and loop mode.
    controller: fw.PlaybackController = .{},
    /// Posture drawn by `onDisplay`.
    display: DisplayMode = .runtime_animation,
    /// Sideways offset of the raw posture in `side_by_side` mode, in metres.
    side_by_side_offset: f32 = 1,

    /// Whether the optimization pass runs at all.
    optimize_enabled: bool = true,
    /// Optimizer settings applied to every joint.
    setting: ozz.offline.OptimizationSetting = .{},
    /// Whether `joint` gets its own tolerance.
    joint_setting_enable: bool = true,
    /// Joint the override applies to, also the one the error graph tracks.
    joint: usize = 0,
    /// Optimizer settings for `joint` alone.
    joint_setting: ozz.offline.OptimizationSetting = .{},
    /// Whether the builder emits random-seek checkpoints.
    enable_iframes: bool = true,
    /// Seconds between two checkpoints.
    iframe_interval: f32 = 10,
    /// Set by `onGui`, consumed by the next `onUpdate`.
    dirty: bool = false,

    /// Bytes held by the source raw animation.
    raw_size: usize = 0,
    /// Bytes held by the optimized raw animation.
    optimized_size: usize = 0,
    /// Bytes held by the runtime animation.
    runtime_size: usize = 0,

    /// Median model-space error over the joints, in millimetres.
    error_median: ErrorRecord = .{},
    /// Largest model-space error over the joints, in millimetres.
    error_max: ErrorRecord = .{},
    /// Model-space error of `joint`, in millimetres.
    error_joint: ErrorRecord = .{},

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(@embedFile("pab_skeleton")),
        );
        errdefer skeleton.deinit();

        // Upstream reads `media/animation_raw.ozz`, which its CMakeLists copies
        // from `pab_atlas_raw.ozz`.
        var raw = try fw.utils.decodeRawAnimation(
            allocator,
            assets.rawOr(@embedFile("pab_atlas_raw")),
        );
        errdefer raw.deinit();
        if (raw.tracks.len != skeleton.numJoints()) return error.InvalidTrackCount;

        const joint_count = skeleton.numJoints();
        const soa_count = skeleton.numSoaJoints();

        const models_rt = try allocator.alloc(Float4x4, joint_count);
        errdefer allocator.free(models_rt);
        const locals_raw_aos = try allocator.alloc(Transform, joint_count);
        errdefer allocator.free(locals_raw_aos);
        const locals_raw = try allocator.alloc(SoaTransform, soa_count);
        errdefer allocator.free(locals_raw);
        const models_raw = try allocator.alloc(Float4x4, joint_count);
        errdefer allocator.free(models_raw);
        const locals_diff = try allocator.alloc(SoaTransform, soa_count);
        errdefer allocator.free(locals_diff);
        const models_diff = try allocator.alloc(Float4x4, joint_count);
        errdefer allocator.free(models_diff);
        const errors_sq = try allocator.alloc(f32, joint_count);
        errdefer allocator.free(errors_sq);

        var sample: Sample = .{
            .allocator = allocator,
            .skeleton = skeleton,
            .raw = raw,
            // Replaced by `build` below; a clone keeps `deinit` correct if it fails.
            .optimized = try fw.utils.cloneRawAnimation(allocator, raw),
            .clip = undefined,
            .models_rt = models_rt,
            .locals_raw_aos = locals_raw_aos,
            .locals_raw = locals_raw,
            .models_raw = models_raw,
            .locals_diff = locals_diff,
            .models_diff = models_diff,
            .errors_sq = errors_sq,
            .joint = fw.utils.findJointContaining(skeleton, default_override_joint) orelse 0,
        };
        errdefer sample.optimized.deinit();

        sample.clip = try fw.utils.Clip.init(
            allocator,
            try ozz.offline.AnimationBuilder.build(allocator, sample.optimized),
        );
        errdefer sample.clip.deinit();

        try sample.build();
        return sample;
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.errors_sq);
        self.allocator.free(self.models_diff);
        self.allocator.free(self.locals_diff);
        self.allocator.free(self.models_raw);
        self.allocator.free(self.locals_raw);
        self.allocator.free(self.locals_raw_aos);
        self.allocator.free(self.models_rt);
        self.clip.deinit();
        self.optimized.deinit();
        self.raw.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;
        if (self.dirty) try self.build();

        _ = self.controller.update(self.clip.duration(), dt);

        // Samples the optimized animation the usual way.
        try self.clip.sample(self.controller.time_ratio);

        // And the source animation straight from its offline key-frames, which
        // yields AoS transforms this sample has to transpose itself.
        try ozz.offline.sampleRawAnimation(
            self.raw,
            self.controller.time_ratio * self.raw.duration,
            self.locals_raw_aos,
        );
        ozz.math.aosToSoa(self.locals_raw_aos, self.locals_raw);

        // Difference between the two, rebound onto the rest pose so it can be
        // rendered as a posture.
        @memcpy(self.locals_diff, self.skeleton.rest_poses);
        for (0..self.skeleton.numJoints()) |joint| {
            const group = joint / 4;
            const lane = joint % 4;
            const runtime = ozz.math.soaLane(self.clip.pose[group], lane);
            const raw = ozz.math.soaLane(self.locals_raw[group], lane);
            const rest = ozz.math.soaLane(self.skeleton.rest_poses[group], lane);
            ozz.math.setSoaLane(&self.locals_diff[group], lane, .{
                .translation = rest.translation + (runtime.translation - raw.translation),
                .rotation = Quaternion.mul(
                    rest.rotation,
                    Quaternion.mul(runtime.rotation, Quaternion.conjugate(raw.rotation)),
                ),
                .scale = rest.scale * safeDiv(runtime.scale, raw.scale),
            });
        }

        try ozz.animation.localToModel(
            .{ .skeleton = &self.skeleton, .input = self.clip.pose },
            self.models_rt,
        );
        try ozz.animation.localToModel(
            .{ .skeleton = &self.skeleton, .input = self.locals_raw },
            self.models_raw,
        );
        try ozz.animation.localToModel(
            .{ .skeleton = &self.skeleton, .input = self.locals_diff },
            self.models_diff,
        );

        self.recordErrors();
        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        const transforms = self.models();
        try renderer.drawPosture(self.skeleton, transforms, .identity, true);

        if (self.display == .side_by_side) {
            // The raw posture, shifted sideways so both can be compared at once.
            try renderer.drawPosture(
                self.skeleton,
                self.models_raw,
                Float4x4.fromTransform(.{
                    .translation = .{ self.side_by_side_offset, 0, 0 },
                }),
                true,
            );
        }

        if (self.joint_setting_enable and self.joint < transforms.len) {
            // Axes scaled to the distance at which the joint's error is measured.
            try renderer.drawAxes(Float4x4.mul(
                transforms[self.joint],
                Float4x4.fromTransform(.{ .scale = @splat(self.joint_setting.distance) }),
            ));
        }
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        var buffer: [96]u8 = undefined;

        if (gui.openClose("Animation control", true)) {
            self.controller.onGui(gui, self.clip.duration(), true, true);
        }

        var rebuild = false;
        if (gui.openClose("Optimization tolerances", true)) {
            rebuild = gui.doCheckBox("Enable optimizations", &self.optimize_enabled, true) or
                rebuild;

            rebuild = gui.doSlider(
                fw.im.formatZ(&buffer, "Tolerance: {d:.2} mm", .{self.setting.tolerance * 1000}),
                0,
                0.1,
                &self.setting.tolerance,
                0.5,
                self.optimize_enabled,
            ) or rebuild;

            rebuild = gui.doSlider(
                fw.im.formatZ(&buffer, "Distance: {d:.2} mm", .{self.setting.distance * 1000}),
                0,
                1,
                &self.setting.distance,
                0.5,
                self.optimize_enabled,
            ) or rebuild;

            gui.separator();
            rebuild = gui.doCheckBox(
                "Enable joint setting",
                &self.joint_setting_enable,
                self.optimize_enabled,
            ) or rebuild;

            const joint_enabled = self.joint_setting_enable and self.optimize_enabled;
            var joint: i32 = @intCast(self.joint);
            if (gui.doSliderInt(
                fw.im.formatZ(&buffer, "{s} ({d})", .{ self.jointName(), joint }),
                0,
                @intCast(self.skeleton.numJoints() - 1),
                &joint,
                1,
                joint_enabled,
            )) {
                self.joint = @intCast(std.math.clamp(
                    joint,
                    0,
                    @as(i32, @intCast(self.skeleton.numJoints() - 1)),
                ));
                self.error_joint.clear();
                rebuild = true;
            }

            rebuild = gui.doSlider(
                fw.im.formatZ(
                    &buffer,
                    "Joint tolerance: {d:.2} mm",
                    .{self.joint_setting.tolerance * 1000},
                ),
                0,
                0.1,
                &self.joint_setting.tolerance,
                0.5,
                joint_enabled,
            ) or rebuild;

            rebuild = gui.doSlider(
                fw.im.formatZ(
                    &buffer,
                    "Joint distance: {d:.2} mm",
                    .{self.joint_setting.distance * 1000},
                ),
                0,
                1,
                &self.joint_setting.distance,
                0.5,
                joint_enabled,
            ) or rebuild;
        }

        if (gui.openClose("Builder settings", true)) {
            rebuild = gui.doCheckBox("Enable iframes", &self.enable_iframes, true) or rebuild;
            rebuild = gui.doSlider(
                fw.im.formatZ(&buffer, "Iframe interval: {d:.2} s", .{self.iframe_interval}),
                0.1,
                20,
                &self.iframe_interval,
                0.5,
                self.enable_iframes,
            ) or rebuild;
        }

        // `onGui` cannot fail, so the rebuild happens in the next `onUpdate`.
        if (rebuild) self.dirty = true;

        if (gui.openClose("Memory size", true)) {
            gui.doLabel("Raw: {d} bytes", .{self.raw_size});
            gui.doLabel("Optimized: {d} bytes ({d:.1}:1)", .{
                self.optimized_size,
                ratio(self.raw_size, self.optimized_size),
            });
            gui.doLabel("Runtime: {d} bytes ({d:.1}:1)", .{
                self.runtime_size,
                ratio(self.raw_size, self.runtime_size),
            });
        }

        if (gui.openClose("Display mode", true)) {
            var selected: i32 = @intFromEnum(self.display);
            _ = gui.doRadioButton(0, "Runtime animation", &selected, true);
            _ = gui.doRadioButton(1, "Raw animation", &selected, true);
            _ = gui.doRadioButton(2, "Absolute error", &selected, true);
            _ = gui.doRadioButton(3, "Side by side", &selected, true);
            self.display = @enumFromInt(selected);
            _ = gui.doSlider(
                fw.im.formatZ(&buffer, "Side by side offset: {d:.2} m", .{self.side_by_side_offset}),
                0,
                4,
                &self.side_by_side_offset,
                1,
                self.display == .side_by_side,
            );
        }

        if (gui.openClose("Absolute error", true)) {
            const median = self.error_median.statistics();
            gui.doGraph(
                fw.im.formatZ(&buffer, "Median error: {d:.2}mm", .{median.latest}),
                0,
                median.max,
                median.mean,
                self.error_median.cursor(),
                self.error_median.values(),
            );

            const maximum = self.error_max.statistics();
            gui.doGraph(
                fw.im.formatZ(&buffer, "Maximum error: {d:.2}mm", .{maximum.latest}),
                0,
                maximum.max,
                maximum.mean,
                self.error_max.cursor(),
                self.error_max.values(),
            );

            const per_joint = self.error_joint.statistics();
            gui.doGraph(
                fw.im.formatZ(
                    &buffer,
                    "Joint {d} error: {d:.2}mm",
                    .{ self.joint, per_joint.latest },
                ),
                0,
                per_joint.max,
                per_joint.mean,
                self.error_joint.cursor(),
                self.error_joint.values(),
            );
        }
    }

    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        var box = fw.utils.computePostureBounds(self.models(), null);
        if (self.display == .side_by_side) {
            box = ozz.math.Box.merge(box, fw.utils.computePostureBounds(
                self.models_raw,
                Float4x4.fromTransform(.{
                    .translation = .{ self.side_by_side_offset, 0, 0 },
                }),
            ));
        }
        return box;
    }

    /// Model-space matrices selected by the display mode (`models`,
    /// sample_optimize.cc:210). `side_by_side` draws the runtime posture plus a
    /// shifted raw one, so it reports the runtime matrices here.
    fn models(self: *Sample) []const Float4x4 {
        return switch (self.display) {
            .runtime_animation, .side_by_side => self.models_rt,
            .raw_animation => self.models_raw,
            .absolute_error => self.models_diff,
        };
    }

    /// Name of the joint the override and the error graph target.
    fn jointName(self: *Sample) []const u8 {
        if (self.joint >= self.skeleton.names.len) return "?";
        return self.skeleton.names[self.joint];
    }

    /// Runs the optimizer and the animation builder (`BuildAnimations`,
    /// sample_optimize.cc:437), then swaps the results in.
    fn build(self: *Sample) !void {
        self.dirty = false;

        const overrides = [_]ozz.offline.JointOptimizationSetting{.{
            .joint = @min(self.joint, self.skeleton.numJoints() - 1),
            .setting = self.joint_setting,
        }};

        var optimized = if (self.optimize_enabled)
            try ozz.offline.optimizeAnimation(self.allocator, self.raw, self.skeleton, .{
                .tolerance = self.setting.tolerance,
                .distance = self.setting.distance,
                .joint_overrides = if (self.joint_setting_enable) &overrides else &.{},
            })
        else
            // Without optimization the builder consumes the source animation.
            try fw.utils.cloneRawAnimation(self.allocator, self.raw);
        errdefer optimized.deinit();

        var clip = try fw.utils.Clip.init(
            self.allocator,
            try ozz.offline.AnimationBuilder.buildWithOptions(self.allocator, optimized, .{
                .iframe_interval = if (self.enable_iframes) self.iframe_interval else null,
            }),
        );
        errdefer clip.deinit();

        self.clip.deinit();
        self.optimized.deinit();
        self.clip = clip;
        self.optimized = optimized;

        self.raw_size = self.raw.memorySize();
        self.optimized_size = self.optimized.memorySize();
        self.runtime_size = self.clip.animation.memorySize();

        // The graphs describe the animation that just went away.
        self.error_median.clear();
        self.error_max.clear();
        self.error_joint.clear();
    }

    /// Absolute error, that is the model-space distance between the raw and the
    /// runtime joint positions (sample_optimize.cc:144).
    fn recordErrors(self: *Sample) void {
        const joint_count = self.skeleton.numJoints();
        if (joint_count == 0) return;

        for (self.errors_sq, self.models_rt, self.models_raw) |*error_sq, runtime, raw| {
            const delta = runtime.translation() - raw.translation();
            error_sq.* = @reduce(.Add, delta * delta);
        }

        // Read before the sort, so this really is the selected joint's error.
        const selected = self.errors_sq[@min(self.joint, joint_count - 1)];

        std.mem.sort(f32, self.errors_sq, {}, std.sort.asc(f32));
        self.error_median.push(@sqrt(self.errors_sq[joint_count / 2]) * 1000);
        self.error_max.push(@sqrt(self.errors_sq[joint_count - 1]) * 1000);
        self.error_joint.push(@sqrt(selected) * 1000);
    }
};

/// Component-wise division that leaves a zero divisor alone, so a degenerate
/// scale in the source animation cannot poison the difference posture.
fn safeDiv(a: Vec3f32, b: Vec3f32) Vec3f32 {
    const one: Vec3f32 = @splat(1);
    const zero: Vec3f32 = @splat(0);
    return a / @select(f32, b == zero, one, b);
}

/// Compression ratio of `size` against the source, guarded against a zero size.
fn ratio(source: usize, size: usize) f32 {
    if (size == 0) return 0;
    return @as(f32, @floatFromInt(source)) / @as(f32, @floatFromInt(size));
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

/// Largest model-space error, in metres, between the raw and the runtime
/// animation over `steps` evenly spaced samples.
fn measureMaxError(sample: *Sample, steps: usize) !f32 {
    var worst: f32 = 0;
    for (0..steps) |step| {
        sample.controller.setTimeRatio(@as(f32, @floatFromInt(step)) /
            @as(f32, @floatFromInt(steps - 1)));
        // dt = 0 keeps the ratio set above.
        try std.testing.expect(try sample.onUpdate(0, 0));
        worst = @max(worst, sample.error_max.statistics().latest / 1000);
    }
    return worst;
}

test "the raw animation matches the skeleton it is optimized against" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    try std.testing.expectEqual(sample.skeleton.numJoints(), sample.raw.tracks.len);
    try std.testing.expectEqual(sample.skeleton.numJoints(), sample.clip.animation.numTracks());
    try std.testing.expect(sample.raw.validate());
    // The default override joint exists in the pab skeleton.
    try std.testing.expect(sample.joint != 0);
    try std.testing.expect(fw.utils.containsIgnoreCase(
        sample.skeleton.names[sample.joint],
        default_override_joint,
    ));
}

test "optimization shrinks the animation" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    try std.testing.expect(sample.optimize_enabled);
    try std.testing.expect(sample.raw_size > 0);
    try std.testing.expect(sample.optimized_size < sample.raw_size);
    try std.testing.expect(sample.runtime_size < sample.raw_size);
    try std.testing.expect(ratio(sample.raw_size, sample.optimized_size) > 1);

    // Disabling the optimization gives the source animation back.
    sample.optimize_enabled = false;
    sample.dirty = true;
    try std.testing.expect(try sample.onUpdate(0, 0));
    try std.testing.expectEqual(sample.raw_size, sample.optimized_size);

    // A tighter tolerance keeps more key-frames than a loose one.
    sample.optimize_enabled = true;
    sample.setting.tolerance = 1e-3;
    sample.dirty = true;
    try std.testing.expect(try sample.onUpdate(0, 0));
    const tight = sample.optimized_size;

    sample.setting.tolerance = 5e-2;
    sample.dirty = true;
    try std.testing.expect(try sample.onUpdate(0, 0));
    try std.testing.expect(sample.optimized_size < tight);
}

test "the reported error tracks the requested tolerance" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    // The per-joint override is disabled so a single tolerance governs the
    // whole hierarchy, which is what the error is compared against.
    sample.joint_setting_enable = false;

    // ozz's tolerance bounds the error a *single* joint hierarchy may generate,
    // so the model-space error accumulated down a 60-joint chain legitimately
    // overshoots it. Measured overshoot on pab_atlas is 2.4x to 3.2x over this
    // range; upstream's optimizer behaves the same way.
    const overshoot = 4;
    for ([_]f32{ 1e-3, 1e-2, 5e-2 }) |tolerance| {
        sample.setting.tolerance = tolerance;
        sample.dirty = true;
        try std.testing.expect(try sample.onUpdate(0, 0));

        const worst = try measureMaxError(&sample, 32);
        try std.testing.expect(worst > 0);
        try std.testing.expect(worst <= tolerance * overshoot);
    }

    // A loose tolerance really does trade accuracy for size.
    sample.setting.tolerance = 1e-3;
    sample.dirty = true;
    try std.testing.expect(try sample.onUpdate(0, 0));
    const accurate = try measureMaxError(&sample, 32);

    sample.setting.tolerance = 5e-2;
    sample.dirty = true;
    try std.testing.expect(try sample.onUpdate(0, 0));
    try std.testing.expect(try measureMaxError(&sample, 32) > accurate);
}

test "every display mode produces a finite posture" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    try std.testing.expect(try sample.onUpdate(1.0 / 60.0, 0));
    for ([_]DisplayMode{ .runtime_animation, .raw_animation, .absolute_error, .side_by_side }) |mode| {
        sample.display = mode;
        const bounds = sample.sceneBounds().?;
        try std.testing.expect(bounds.isValid());
        for (sample.models()) |model| {
            const position = model.translation();
            try std.testing.expect(std.math.isFinite(position[0]));
            try std.testing.expect(std.math.isFinite(position[1]));
            try std.testing.expect(std.math.isFinite(position[2]));
        }
    }

    // With no optimization and no compression the difference posture is the
    // rest pose, so the error collapses to zero.
    sample.optimize_enabled = false;
    sample.enable_iframes = false;
    sample.dirty = true;
    try std.testing.expect(try sample.onUpdate(0, 0));
    sample.controller.setTimeRatio(0.37);
    try std.testing.expect(try sample.onUpdate(0, 0));
    try std.testing.expect(sample.error_max.statistics().latest < 1e-2);
}

test "iframes change the runtime size but not the pose" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    sample.controller.setTimeRatio(0.5);
    try std.testing.expect(try sample.onUpdate(0, 0));
    const with_iframes = sample.runtime_size;
    const reference = sample.models_rt[sample.joint].translation();

    sample.enable_iframes = false;
    sample.dirty = true;
    sample.controller.setTimeRatio(0.5);
    try std.testing.expect(try sample.onUpdate(0, 0));

    try std.testing.expect(sample.runtime_size < with_iframes);
    const without = sample.models_rt[sample.joint].translation();
    try std.testing.expect(@reduce(.And, @abs(without - reference) < @as(Vec3f32, @splat(1e-5))));
}
