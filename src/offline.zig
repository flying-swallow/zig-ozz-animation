const std = @import("std");
const math = @import("math.zig");
const runtime = @import("animation.zig");

pub const TranslationKey = struct { time: f32, value: math.Float3 };
pub const RotationKey = struct { time: f32, value: math.Quaternion };
pub const ScaleKey = struct { time: f32, value: math.Float3 };

pub const RawJointTrack = struct {
    translations: []TranslationKey = &.{},
    rotations: []RotationKey = &.{},
    scales: []ScaleKey = &.{},
};

pub const RawAnimation = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    duration: f32,
    tracks: []RawJointTrack,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, duration: f32, track_count: usize) !RawAnimation {
        if (!std.math.isFinite(duration) or duration <= 0) return runtime.Error.InvalidDuration;
        const tracks = try allocator.alloc(RawJointTrack, track_count);
        errdefer allocator.free(tracks);
        @memset(tracks, .{});
        const owned_name = try allocator.dupe(u8, name);
        return .{
            .allocator = allocator,
            .name = owned_name,
            .duration = duration,
            .tracks = tracks,
        };
    }

    pub fn deinit(self: *RawAnimation) void {
        for (self.tracks) |track| {
            self.allocator.free(track.translations);
            self.allocator.free(track.rotations);
            self.allocator.free(track.scales);
        }
        self.allocator.free(self.tracks);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn validate(self: RawAnimation) bool {
        if (!(self.duration > 0) or self.tracks.len > runtime.max_joints) return false;
        for (self.tracks) |track| {
            if (!validateTime(TranslationKey, track.translations, self.duration) or
                !validateTime(RotationKey, track.rotations, self.duration) or
                !validateTime(ScaleKey, track.scales, self.duration))
            {
                return false;
            }
        }
        return true;
    }
};

fn validateTime(comptime Key: type, keys: []const Key, duration: f32) bool {
    var previous: f32 = -1;
    for (keys) |key| {
        if (!std.math.isFinite(key.time) or key.time < previous or key.time < 0 or key.time > duration) {
            return false;
        }
        previous = key.time;
    }
    return true;
}

pub const RawJoint = struct {
    name: []u8,
    transform: math.Transform = .identity,
    children: []RawJoint = &.{},
};

pub const RawSkeleton = struct {
    allocator: std.mem.Allocator,
    roots: []RawJoint,

    pub fn deinit(self: *RawSkeleton) void {
        for (self.roots) |*root| deinitJoint(self.allocator, root);
        self.allocator.free(self.roots);
        self.* = undefined;
    }
};

fn deinitJoint(allocator: std.mem.Allocator, joint: *RawJoint) void {
    for (joint.children) |*child| deinitJoint(allocator, child);
    allocator.free(joint.children);
    allocator.free(joint.name);
}

pub const SkeletonBuilder = struct {
    pub fn build(allocator: std.mem.Allocator, raw: RawSkeleton) !runtime.Skeleton {
        var inputs: std.ArrayList(runtime.JointInput) = .empty;
        defer inputs.deinit(allocator);
        for (raw.roots) |root| try flattenJoint(allocator, &inputs, root, runtime.no_parent);
        return runtime.Skeleton.init(allocator, inputs.items);
    }
};

fn flattenJoint(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(runtime.JointInput),
    joint: RawJoint,
    parent: i16,
) !void {
    const index: i16 = @intCast(list.items.len);
    try list.append(allocator, .{ .name = joint.name, .parent = parent, .rest_pose = joint.transform });
    for (joint.children) |child| try flattenJoint(allocator, list, child, index);
}

pub const AnimationBuilder = struct {
    pub fn build(allocator: std.mem.Allocator, raw: RawAnimation) !runtime.Animation {
        if (!raw.validate()) return runtime.Error.InvalidKeyframe;
        var inputs = try allocator.alloc(runtime.JointTrackInput, raw.tracks.len);
        defer allocator.free(inputs);
        var translations: std.ArrayList(runtime.Float3Key) = .empty;
        defer translations.deinit(allocator);
        var rotations: std.ArrayList(runtime.QuaternionKey) = .empty;
        defer rotations.deinit(allocator);
        var scales: std.ArrayList(runtime.Float3Key) = .empty;
        defer scales.deinit(allocator);

        for (raw.tracks, 0..) |track, i| {
            const t_start = translations.items.len;
            for (track.translations) |key| try translations.append(allocator, .{
                .ratio = key.time / raw.duration,
                .value = key.value,
            });
            const r_start = rotations.items.len;
            for (track.rotations) |key| try rotations.append(allocator, .{
                .ratio = key.time / raw.duration,
                .value = key.value,
            });
            const s_start = scales.items.len;
            for (track.scales) |key| try scales.append(allocator, .{
                .ratio = key.time / raw.duration,
                .value = key.value,
            });
            inputs[i] = .{
                .translations = translations.items[t_start..],
                .rotations = rotations.items[r_start..],
                .scales = scales.items[s_start..],
            };
        }
        return runtime.Animation.init(allocator, raw.name, raw.duration, inputs);
    }
};

pub fn sampleJointTrack(track: RawJointTrack, time: f32) math.Transform {
    return .{
        .translation = sampleTimed(math.Float3, TranslationKey, track.translations, time, .zero),
        .rotation = sampleTimed(math.Quaternion, RotationKey, track.rotations, time, .identity),
        .scale = sampleTimed(math.Float3, ScaleKey, track.scales, time, .one),
    };
}

fn sampleTimed(
    comptime T: type,
    comptime Key: type,
    keys: []const Key,
    time: f32,
    fallback: T,
) T {
    if (keys.len == 0) return fallback;
    if (keys.len == 1 or time <= keys[0].time) return keys[0].value;
    if (time >= keys[keys.len - 1].time) return keys[keys.len - 1].value;
    var i: usize = 0;
    while (i + 1 < keys.len and keys[i + 1].time <= time) : (i += 1) {}
    const alpha = (time - keys[i].time) / (keys[i + 1].time - keys[i].time);
    if (T == math.Quaternion) return math.Quaternion.nlerp(keys[i].value, keys[i + 1].value, alpha);
    return math.Float3.lerp(keys[i].value, keys[i + 1].value, alpha);
}

pub fn sampleRawAnimation(raw: RawAnimation, time: f32, output: []math.Transform) !void {
    if (!raw.validate()) return runtime.Error.InvalidKeyframe;
    if (output.len < raw.tracks.len) return runtime.Error.OutputTooSmall;
    const clamped = std.math.clamp(time, 0, raw.duration);
    for (raw.tracks, 0..) |track, i| output[i] = sampleJointTrack(track, clamped);
}

pub fn extractTimePoints(allocator: std.mem.Allocator, raw: RawAnimation) ![]f32 {
    if (!raw.validate()) return allocator.alloc(f32, 0);
    var values: std.ArrayList(f32) = .empty;
    defer values.deinit(allocator);
    for (raw.tracks) |track| {
        for (track.translations) |key| try values.append(allocator, key.time);
        for (track.rotations) |key| try values.append(allocator, key.time);
        for (track.scales) |key| try values.append(allocator, key.time);
    }
    std.mem.sort(f32, values.items, {}, std.sort.asc(f32));
    var write: usize = 0;
    for (values.items) |value| {
        if (write == 0 or values.items[write - 1] != value) {
            values.items[write] = value;
            write += 1;
        }
    }
    return allocator.dupe(f32, values.items[0..write]);
}

pub const FixedRateSamplingTime = struct {
    duration: f32,
    frequency: f32,
    key_count: usize,

    pub fn init(duration: f32, frequency: f32) !FixedRateSamplingTime {
        if (!(duration > 0) or !(frequency > 0) or
            !std.math.isFinite(duration) or !std.math.isFinite(frequency))
        {
            return runtime.Error.InvalidDuration;
        }
        return .{
            .duration = duration,
            .frequency = frequency,
            .key_count = @as(usize, @intFromFloat(@ceil(duration * frequency))) + 1,
        };
    }

    pub fn numKeys(self: FixedRateSamplingTime) usize {
        return self.key_count;
    }

    pub fn time(self: FixedRateSamplingTime, key: usize) f32 {
        std.debug.assert(key < self.key_count);
        if (key + 1 == self.key_count) return self.duration;
        return @as(f32, @floatFromInt(key)) / self.frequency;
    }
};

pub fn RawTrack(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Key = struct {
            interpolation: runtime.Interpolation,
            ratio: f32,
            value: T,
        };

        allocator: std.mem.Allocator,
        name: []u8,
        keys: []Key,

        pub fn init(allocator: std.mem.Allocator, name: []const u8, keys: []const Key) !Self {
            var previous: f32 = -1;
            for (keys) |key| {
                if (!std.math.isFinite(key.ratio) or key.ratio < 0 or key.ratio > 1 or
                    key.ratio <= previous)
                {
                    return runtime.Error.InvalidKeyframe;
                }
                previous = key.ratio;
            }
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            return .{
                .allocator = allocator,
                .name = owned_name,
                .keys = try allocator.dupe(Key, keys),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.name);
            self.allocator.free(self.keys);
            self.* = undefined;
        }
    };
}

pub const RawFloatTrack = RawTrack(f32);
pub const RawFloat2Track = RawTrack(math.Float2);
pub const RawFloat3Track = RawTrack(math.Float3);
pub const RawFloat4Track = RawTrack(math.Float4);
pub const RawQuaternionTrack = RawTrack(math.Quaternion);

fn defaultTrackValue(comptime T: type) T {
    if (T == f32) return 0;
    if (T == math.Float2) return .zero;
    if (T == math.Float3) return .zero;
    if (T == math.Float4) return .zero;
    if (T == math.Quaternion) return .identity;
    @compileError("unsupported track value type");
}

pub fn sampleTrack(comptime T: type, raw: RawTrack(T), ratio_in: f32) T {
    if (raw.keys.len == 0) return defaultTrackValue(T);
    const ratio = std.math.clamp(ratio_in, 0, 1);
    if (raw.keys.len == 1 or ratio <= raw.keys[0].ratio) return raw.keys[0].value;
    if (ratio >= raw.keys[raw.keys.len - 1].ratio) return raw.keys[raw.keys.len - 1].value;
    var i: usize = 0;
    while (i + 1 < raw.keys.len and raw.keys[i + 1].ratio <= ratio) : (i += 1) {}
    if (raw.keys[i].interpolation == .step) return raw.keys[i].value;
    const alpha = (ratio - raw.keys[i].ratio) / (raw.keys[i + 1].ratio - raw.keys[i].ratio);
    return lerpValue(T, raw.keys[i].value, raw.keys[i + 1].value, alpha);
}

pub fn buildTrack(
    comptime T: type,
    allocator: std.mem.Allocator,
    raw: RawTrack(T),
) !runtime.Track(T) {
    const RuntimeKey = runtime.Track(T).Key;
    const keys = try allocator.alloc(RuntimeKey, raw.keys.len);
    defer allocator.free(keys);
    for (raw.keys, 0..) |key, i| {
        keys[i] = .{
            .ratio = key.ratio,
            .value = key.value,
            .interpolation = key.interpolation,
        };
    }
    return runtime.Track(T).initMixed(allocator, raw.name, keys);
}

fn valueDistance(comptime T: type, a: T, b: T) f32 {
    if (T == f32) return @abs(a - b);
    if (T == math.Float2) {
        const x = a.x - b.x;
        const y = a.y - b.y;
        return @sqrt(x * x + y * y);
    }
    if (T == math.Float3) return math.Float3.length(math.Float3.sub(a, b));
    if (T == math.Float4) {
        const x = a.x - b.x;
        const y = a.y - b.y;
        const z = a.z - b.z;
        const w = a.w - b.w;
        return @sqrt(x * x + y * y + z * z + w * w);
    }
    if (T == math.Quaternion) {
        const d = std.math.clamp(@abs(math.Quaternion.dot(a, b)), 0, 1);
        return 2 * @sqrt(@max(1 - d * d, 0));
    }
    @compileError("unsupported track value type");
}

fn lerpValue(comptime T: type, a: T, b: T, t: f32) T {
    if (T == f32) return a + (b - a) * t;
    if (T == math.Float2) return math.Float2.lerp(a, b, t);
    if (T == math.Float3) return math.Float3.lerp(a, b, t);
    if (T == math.Float4) return math.Float4.lerp(a, b, t);
    if (T == math.Quaternion) return math.Quaternion.nlerp(a, b, t);
    @compileError("unsupported track value type");
}

pub fn optimizeTrack(
    comptime T: type,
    allocator: std.mem.Allocator,
    raw: RawTrack(T),
    tolerance: f32,
) !RawTrack(T) {
    if (raw.keys.len <= 2) return RawTrack(T).init(allocator, raw.name, raw.keys);
    var output: std.ArrayList(RawTrack(T).Key) = .empty;
    defer output.deinit(allocator);
    try output.append(allocator, raw.keys[0]);
    var anchor: usize = 0;
    while (anchor + 1 < raw.keys.len) {
        var candidate = anchor + 2;
        var best = anchor + 1;
        while (candidate < raw.keys.len) : (candidate += 1) {
            const left = raw.keys[anchor];
            const right = raw.keys[candidate];
            var valid = left.interpolation == .linear;
            if (valid) for (raw.keys[anchor + 1 .. candidate]) |middle| {
                if (middle.interpolation != .linear) {
                    valid = false;
                    break;
                }
                const alpha = (middle.ratio - left.ratio) / (right.ratio - left.ratio);
                if (valueDistance(T, middle.value, lerpValue(T, left.value, right.value, alpha)) > tolerance) {
                    valid = false;
                    break;
                }
            };
            if (!valid) break;
            best = candidate;
        }
        try output.append(allocator, raw.keys[best]);
        anchor = best;
    }
    return RawTrack(T).init(allocator, raw.name, output.items);
}

fn cloneRawAnimation(allocator: std.mem.Allocator, input: RawAnimation) !RawAnimation {
    var result = try RawAnimation.init(allocator, input.name, input.duration, input.tracks.len);
    errdefer result.deinit();
    for (input.tracks, 0..) |track, i| {
        result.tracks[i] = .{
            .translations = try allocator.dupe(TranslationKey, track.translations),
            .rotations = try allocator.dupe(RotationKey, track.rotations),
            .scales = try allocator.dupe(ScaleKey, track.scales),
        };
    }
    return result;
}

pub const MotionReference = enum {
    absolute,
    skeleton,
    animation,
};

pub const MotionComponent = struct {
    x: bool = false,
    y: bool = false,
    z: bool = false,
    reference: MotionReference = .absolute,
    bake: bool = true,
    loop: bool = false,
};

pub const MotionExtractionOptions = struct {
    root_joint: usize = 0,
    position: MotionComponent = .{},
    rotation: MotionComponent = .{},
};

pub const MotionExtraction = struct {
    position: RawFloat3Track,
    rotation: RawQuaternionTrack,
    baked: RawAnimation,

    pub fn deinit(self: *MotionExtraction) void {
        self.position.deinit();
        self.rotation.deinit();
        self.baked.deinit();
        self.* = undefined;
    }
};

fn selected3(value: math.Float3, component: MotionComponent) math.Float3 {
    return .{
        .x = if (component.x) value.x else 0,
        .y = if (component.y) value.y else 0,
        .z = if (component.z) value.z else 0,
    };
}

fn positionReference(
    input: RawAnimation,
    skeleton: runtime.Skeleton,
    joint: usize,
    reference: MotionReference,
) math.Float3 {
    return switch (reference) {
        .absolute => .zero,
        .skeleton => skeleton.jointRestPose(joint).translation,
        .animation => if (input.tracks[joint].translations.len > 0)
            input.tracks[joint].translations[0].value
        else
            .zero,
    };
}

fn rotationReference(
    input: RawAnimation,
    skeleton: runtime.Skeleton,
    joint: usize,
    reference: MotionReference,
) math.Quaternion {
    return switch (reference) {
        .absolute => .identity,
        .skeleton => skeleton.jointRestPose(joint).rotation,
        .animation => if (input.tracks[joint].rotations.len > 0)
            input.tracks[joint].rotations[0].value
        else
            .identity,
    };
}

/// Extracts selected root-motion components and optionally removes them from
/// the returned raw animation. Key times and interpolation remain unchanged.
pub fn extractMotion(
    allocator: std.mem.Allocator,
    input: RawAnimation,
    skeleton: runtime.Skeleton,
    options: MotionExtractionOptions,
) !MotionExtraction {
    if (!input.validate()) return runtime.Error.InvalidKeyframe;
    if (input.tracks.len != skeleton.numJoints() or options.root_joint >= input.tracks.len) {
        return runtime.Error.InvalidTrackCount;
    }

    var baked = try cloneRawAnimation(allocator, input);
    errdefer baked.deinit();
    const source = input.tracks[options.root_joint];
    const position_ref = positionReference(input, skeleton, options.root_joint, options.position.reference);
    const rotation_ref = rotationReference(input, skeleton, options.root_joint, options.rotation.reference);

    var position_keys: std.ArrayList(RawFloat3Track.Key) = .empty;
    defer position_keys.deinit(allocator);
    for (source.translations, 0..) |key, i| {
        const relative = math.Float3.sub(key.value, position_ref);
        const extracted = selected3(relative, options.position);
        try position_keys.append(allocator, .{
            .interpolation = .linear,
            .ratio = key.time / input.duration,
            .value = extracted,
        });
        if (options.position.bake) {
            const remaining = math.Float3.sub(relative, extracted);
            baked.tracks[options.root_joint].translations[i].value =
                math.Float3.add(position_ref, remaining);
        }
    }

    var rotation_keys: std.ArrayList(RawQuaternionTrack.Key) = .empty;
    defer rotation_keys.deinit(allocator);
    const inverse_reference = math.Quaternion.conjugate(rotation_ref);
    for (source.rotations, 0..) |key, i| {
        const relative = math.Quaternion.normalize(math.Quaternion.mul(inverse_reference, key.value));
        const extracted_euler = selected3(math.Quaternion.toEuler(relative), options.rotation);
        const extracted = math.Quaternion.fromEuler(extracted_euler);
        try rotation_keys.append(allocator, .{
            .interpolation = .linear,
            .ratio = key.time / input.duration,
            .value = extracted,
        });
        if (options.rotation.bake) {
            const remaining = math.Quaternion.mul(math.Quaternion.conjugate(extracted), relative);
            baked.tracks[options.root_joint].rotations[i].value =
                math.Quaternion.normalize(math.Quaternion.mul(rotation_ref, remaining));
        }
    }

    var position = try RawFloat3Track.init(allocator, "motion_position", position_keys.items);
    errdefer position.deinit();
    var rotation = try RawQuaternionTrack.init(allocator, "motion_rotation", rotation_keys.items);
    errdefer rotation.deinit();
    return .{ .position = position, .rotation = rotation, .baked = baked };
}

pub fn buildAdditive(
    allocator: std.mem.Allocator,
    input: RawAnimation,
    reference_pose: ?[]const math.Transform,
) !RawAnimation {
    if (!input.validate()) return runtime.Error.InvalidKeyframe;
    if (reference_pose != null and reference_pose.?.len < input.tracks.len) {
        return runtime.Error.OutputTooSmall;
    }
    var output = try cloneRawAnimation(allocator, input);
    errdefer output.deinit();
    for (input.tracks, 0..) |track, i| {
        const reference: math.Transform = if (reference_pose) |pose|
            pose[i]
        else
            .{
                .translation = if (track.translations.len > 0) track.translations[0].value else .zero,
                .rotation = if (track.rotations.len > 0) track.rotations[0].value else .identity,
                .scale = if (track.scales.len > 0) track.scales[0].value else .one,
            };
        for (output.tracks[i].translations) |*key| {
            key.value = math.Float3.sub(key.value, reference.translation);
        }
        const inv_rotation = math.Quaternion.conjugate(reference.rotation);
        for (output.tracks[i].rotations) |*key| {
            key.value = math.Quaternion.normalize(math.Quaternion.mul(inv_rotation, key.value));
        }
        for (output.tracks[i].scales) |*key| {
            key.value = .{
                .x = if (reference.scale.x != 0) key.value.x / reference.scale.x else 0,
                .y = if (reference.scale.y != 0) key.value.y / reference.scale.y else 0,
                .z = if (reference.scale.z != 0) key.value.z / reference.scale.z else 0,
            };
        }
    }
    return output;
}

fn decimateTimed(
    comptime T: type,
    comptime Key: type,
    allocator: std.mem.Allocator,
    keys: []const Key,
    tolerance: f32,
) ![]Key {
    if (keys.len <= 2) return allocator.dupe(Key, keys);
    var output: std.ArrayList(Key) = .empty;
    defer output.deinit(allocator);
    try output.append(allocator, keys[0]);
    var anchor: usize = 0;
    while (anchor + 1 < keys.len) {
        var candidate = anchor + 2;
        var best = anchor + 1;
        while (candidate < keys.len) : (candidate += 1) {
            var valid = true;
            for (keys[anchor + 1 .. candidate]) |middle| {
                const alpha = (middle.time - keys[anchor].time) /
                    (keys[candidate].time - keys[anchor].time);
                if (valueDistance(T, middle.value, lerpValue(T, keys[anchor].value, keys[candidate].value, alpha)) > tolerance) {
                    valid = false;
                    break;
                }
            }
            if (!valid) break;
            best = candidate;
        }
        try output.append(allocator, keys[best]);
        anchor = best;
    }
    return allocator.dupe(Key, output.items);
}

pub const OptimizationSettings = struct {
    translation_tolerance: f32 = 1e-3,
    rotation_tolerance: f32 = 1e-3,
    scale_tolerance: f32 = 1e-3,
};

pub fn optimizeAnimation(
    allocator: std.mem.Allocator,
    input: RawAnimation,
    skeleton: runtime.Skeleton,
    settings: OptimizationSettings,
) !RawAnimation {
    if (!input.validate() or input.tracks.len != skeleton.numJoints()) {
        return runtime.Error.InvalidTrackCount;
    }
    var output = try RawAnimation.init(allocator, input.name, input.duration, input.tracks.len);
    errdefer output.deinit();
    for (input.tracks, 0..) |track, i| {
        output.tracks[i].translations = try decimateTimed(
            math.Float3,
            TranslationKey,
            allocator,
            track.translations,
            settings.translation_tolerance,
        );
        output.tracks[i].rotations = try decimateTimed(
            math.Quaternion,
            RotationKey,
            allocator,
            track.rotations,
            settings.rotation_tolerance,
        );
        output.tracks[i].scales = try decimateTimed(
            math.Float3,
            ScaleKey,
            allocator,
            track.scales,
            settings.scale_tolerance,
        );
    }
    return output;
}

test "raw sampling, additive building, and key reduction" {
    const allocator = std.testing.allocator;
    var raw = try RawAnimation.init(allocator, "raw", 1, 1);
    defer raw.deinit();
    raw.tracks[0].translations = try allocator.dupe(TranslationKey, &.{
        .{ .time = 0, .value = .zero },
        .{ .time = 0.5, .value = .{ .x = 1 } },
        .{ .time = 1, .value = .{ .x = 2 } },
    });
    var sampled: [1]math.Transform = undefined;
    try sampleRawAnimation(raw, 0.25, &sampled);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sampled[0].translation.x, 1e-5);

    var additive = try buildAdditive(allocator, raw, null);
    defer additive.deinit();
    try std.testing.expectEqual(@as(f32, 2), additive.tracks[0].translations[2].value.x);

    var skeleton = try runtime.Skeleton.init(allocator, &.{
        .{ .name = "root", .parent = runtime.no_parent },
    });
    defer skeleton.deinit();
    var optimized = try optimizeAnimation(allocator, raw, skeleton, .{});
    defer optimized.deinit();
    try std.testing.expectEqual(@as(usize, 2), optimized.tracks[0].translations.len);

    var raw_track = try RawFloatTrack.init(allocator, "weight", &.{
        .{ .interpolation = .linear, .ratio = 0, .value = 0 },
        .{ .interpolation = .linear, .ratio = 0.5, .value = 0.5 },
        .{ .interpolation = .linear, .ratio = 1, .value = 1 },
    });
    defer raw_track.deinit();
    var optimized_track = try optimizeTrack(f32, allocator, raw_track, 1e-4);
    defer optimized_track.deinit();
    try std.testing.expectEqual(@as(usize, 2), optimized_track.keys.len);
}
