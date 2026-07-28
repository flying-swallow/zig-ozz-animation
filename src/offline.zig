const std = @import("std");
const math = @import("math.zig");
const runtime = @import("animation.zig");

pub const TranslationKey = struct { time: f32, value: math.Vec3f32 };
pub const RotationKey = struct { time: f32, value: math.Quaternion };
pub const ScaleKey = struct { time: f32, value: math.Vec3f32 };

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

    pub fn memorySize(self: RawAnimation) usize {
        var size = @sizeOf(RawAnimation) + self.name.len +
            self.tracks.len * @sizeOf(RawJointTrack);
        for (self.tracks) |track| {
            size += track.translations.len * @sizeOf(TranslationKey);
            size += track.rotations.len * @sizeOf(RotationKey);
            size += track.scales.len * @sizeOf(ScaleKey);
        }
        return size;
    }
};

fn validateTime(comptime Key: type, keys: []const Key, duration: f32) bool {
    var previous: f32 = -1;
    for (keys) |key| {
        if (!std.math.isFinite(key.time) or key.time <= previous or key.time < 0 or key.time > duration) {
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

    pub fn numJoints(self: RawSkeleton) usize {
        var count: usize = 0;
        for (self.roots) |root| countJoint(root, &count);
        return count;
    }

    pub fn validate(self: RawSkeleton) bool {
        return self.numJoints() <= runtime.max_joints;
    }

    pub fn deinit(self: *RawSkeleton) void {
        for (self.roots) |*root| deinitJoint(self.allocator, root);
        self.allocator.free(self.roots);
        self.* = undefined;
    }
};

fn countJoint(joint: RawJoint, count: *usize) void {
    count.* += 1;
    for (joint.children) |child| countJoint(child, count);
}

/// Visits parents before their children, preserving root and sibling order.
/// `visitor` must expose `visit(*const RawJoint, ?*const RawJoint)`.
pub fn iterateJointsDF(raw: RawSkeleton, visitor: anytype) void {
    for (raw.roots) |*root| iterateJointDF(root, null, visitor);
}

fn iterateJointDF(joint: *const RawJoint, parent: ?*const RawJoint, visitor: anytype) void {
    visitor.visit(joint, parent);
    for (joint.children) |*child| iterateJointDF(child, joint, visitor);
}

/// Visits the hierarchy breadth-first, preserving root and sibling order.
/// `visitor` must expose `visit(*const RawJoint, ?*const RawJoint)`.
pub fn iterateJointsBF(allocator: std.mem.Allocator, raw: RawSkeleton, visitor: anytype) !void {
    const Entry = struct {
        joint: *const RawJoint,
        parent: ?*const RawJoint,
    };
    var queue: std.ArrayList(Entry) = .empty;
    defer queue.deinit(allocator);
    for (raw.roots) |*root| try queue.append(allocator, .{ .joint = root, .parent = null });
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const entry = queue.items[cursor];
        visitor.visit(entry.joint, entry.parent);
        for (entry.joint.children) |*child| {
            try queue.append(allocator, .{ .joint = child, .parent = entry.joint });
        }
    }
}

fn deinitJoint(allocator: std.mem.Allocator, joint: *RawJoint) void {
    for (joint.children) |*child| deinitJoint(allocator, child);
    allocator.free(joint.children);
    allocator.free(joint.name);
}

pub const SkeletonBuilder = struct {
    pub fn build(allocator: std.mem.Allocator, raw: RawSkeleton) !runtime.Skeleton {
        if (!raw.validate()) return runtime.Error.TooManyJoints;
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
        return buildWithOptions(allocator, raw, .{});
    }

    pub fn buildWithOptions(
        allocator: std.mem.Allocator,
        raw: RawAnimation,
        options: runtime.AnimationBuildOptions,
    ) !runtime.Animation {
        if (!raw.validate()) return runtime.Error.InvalidKeyframe;
        var inputs = try allocator.alloc(runtime.JointTrackInput, raw.tracks.len);
        defer allocator.free(inputs);
        var translations: std.ArrayList(runtime.Float3Key) = .empty;
        defer translations.deinit(allocator);
        var rotations: std.ArrayList(runtime.QuaternionKey) = .empty;
        defer rotations.deinit(allocator);
        var scales: std.ArrayList(runtime.Float3Key) = .empty;
        defer scales.deinit(allocator);

        // Input slices below point into these lists. Reserve the final sizes up
        // front so later tracks cannot invalidate earlier slices by growing a
        // backing allocation.
        var translation_count: usize = 0;
        var rotation_count: usize = 0;
        var scale_count: usize = 0;
        for (raw.tracks) |track| {
            translation_count = try std.math.add(usize, translation_count, track.translations.len);
            rotation_count = try std.math.add(usize, rotation_count, track.rotations.len);
            scale_count = try std.math.add(usize, scale_count, track.scales.len);
        }
        try translations.ensureTotalCapacityPrecise(allocator, translation_count);
        try rotations.ensureTotalCapacityPrecise(allocator, rotation_count);
        try scales.ensureTotalCapacityPrecise(allocator, scale_count);

        for (raw.tracks, 0..) |track, i| {
            const t_start = translations.items.len;
            for (track.translations) |key| try translations.append(allocator, .{
                .ratio = key.time / raw.duration,
                .value = key.value,
            });
            const r_start = rotations.items.len;
            var previous_rotation = math.Quaternion.identity;
            for (track.rotations, 0..) |key, key_index| {
                var rotation = math.Quaternion.normalize(key.value);
                if ((key_index == 0 and rotation.w < 0) or
                    (key_index != 0 and math.Quaternion.dot(previous_rotation, rotation) < 0))
                {
                    rotation = .{
                        .x = -rotation.x,
                        .y = -rotation.y,
                        .z = -rotation.z,
                        .w = -rotation.w,
                    };
                }
                try rotations.append(allocator, .{
                    .ratio = key.time / raw.duration,
                    .value = rotation,
                });
                previous_rotation = rotation;
            }
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
        return runtime.Animation.initWithOptions(
            allocator,
            raw.name,
            raw.duration,
            inputs,
            options,
        );
    }
};

/// Samples a standalone raw joint track.
///
/// Unlike `RawAnimation`, a `RawJointTrack` has no constructor that can reject
/// malformed key arrays. Validate them at this API boundary, matching the
/// upstream `SampleTrack` failure contract.
pub fn sampleJointTrack(track: RawJointTrack, time: f32) !math.Transform {
    if (!validateSampleKeys(TranslationKey, track.translations) or
        !validateSampleKeys(RotationKey, track.rotations) or
        !validateSampleKeys(ScaleKey, track.scales))
    {
        return runtime.Error.InvalidKeyframe;
    }
    return .{
        .translation = sampleTimed(math.Vec3f32, TranslationKey, track.translations, time, @splat(0)),
        .rotation = sampleTimed(math.Quaternion, RotationKey, track.rotations, time, .identity),
        .scale = sampleTimed(math.Vec3f32, ScaleKey, track.scales, time, @splat(1)),
    };
}

fn validateSampleKeys(comptime Key: type, keys: []const Key) bool {
    var previous: f32 = -1;
    for (keys) |key| {
        if (!std.math.isFinite(key.time) or key.time < 0 or key.time <= previous) return false;
        previous = key.time;
    }
    return true;
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
    return math.approx.lerp_exact(keys[i].value, keys[i + 1].value, alpha);
}

pub fn sampleRawAnimation(raw: RawAnimation, time: f32, output: []math.Transform) !void {
    if (!raw.validate()) return runtime.Error.InvalidKeyframe;
    if (output.len < raw.tracks.len) return runtime.Error.OutputTooSmall;
    const clamped = std.math.clamp(time, 0, raw.duration);
    for (raw.tracks, 0..) |track, i| output[i] = try sampleJointTrack(track, clamped);
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
pub const RawFloat2Track = RawTrack(math.Vec2f32);
pub const RawFloat3Track = RawTrack(math.Vec3f32);
pub const RawFloat4Track = RawTrack(math.Float4);
pub const RawQuaternionTrack = RawTrack(math.Quaternion);

fn defaultTrackValue(comptime T: type) T {
    if (T == f32) return 0;
    if (T == math.Vec2f32) return @splat(0);
    if (T == math.Vec3f32) return @splat(0);
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
    const key_count: usize = if (raw.keys.len == 0)
        0
    else if (raw.keys.len == 1)
        2
    else
        raw.keys.len +
            @as(usize, @intFromBool(raw.keys[0].ratio != 0)) +
            @as(usize, @intFromBool(raw.keys[raw.keys.len - 1].ratio != 1));
    const keys = try allocator.alloc(RuntimeKey, key_count);
    defer allocator.free(keys);
    var output_index: usize = 0;
    if (raw.keys.len == 1) {
        keys[0] = .{
            .ratio = 0,
            .value = raw.keys[0].value,
            .interpolation = .linear,
        };
        keys[1] = .{
            .ratio = 1,
            .value = raw.keys[0].value,
            .interpolation = .linear,
        };
        output_index = 2;
    } else if (raw.keys.len != 0 and raw.keys[0].ratio != 0) {
        keys[output_index] = .{
            .ratio = 0,
            .value = raw.keys[0].value,
            .interpolation = .linear,
        };
        output_index += 1;
    }
    for (if (raw.keys.len == 1) raw.keys[0..0] else raw.keys) |key| {
        keys[output_index] = .{
            .ratio = key.ratio,
            .value = key.value,
            .interpolation = key.interpolation,
        };
        output_index += 1;
    }
    if (raw.keys.len > 1 and raw.keys[raw.keys.len - 1].ratio != 1) {
        keys[output_index] = .{
            .ratio = 1,
            .value = raw.keys[raw.keys.len - 1].value,
            .interpolation = .linear,
        };
    }
    if (T == math.Quaternion) {
        var previous = math.Quaternion.identity;
        for (keys, 0..) |*key, i| {
            var normalized = math.Quaternion.normalize(key.value);
            if ((i == 0 and normalized.w < 0) or
                (i != 0 and math.Quaternion.dot(previous, normalized) < 0))
            {
                normalized = .{
                    .x = -normalized.x,
                    .y = -normalized.y,
                    .z = -normalized.z,
                    .w = -normalized.w,
                };
            }
            key.value = normalized;
            previous = normalized;
        }
    }
    return runtime.Track(T).initMixed(allocator, raw.name, keys);
}

fn valueDistance(comptime T: type, a: T, b: T) f32 {
    if (T == f32) return @abs(a - b);
    if (T == math.Vec2f32) return math.vec.norm(math.vec.sub(a, b));
    if (T == math.Vec3f32) return math.vec.norm(math.vec.sub(a, b));
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
    if (T == math.Vec2f32) return math.approx.lerp_exact(a, b, t);
    if (T == math.Vec3f32) return math.approx.lerp_exact(a, b, t);
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
    const Key = RawTrack(T).Key;
    if (raw.keys.len == 0) return RawTrack(T).init(allocator, raw.name, raw.keys);
    if (raw.keys.len == 1) {
        const keys = if (valueDistance(T, defaultTrackValue(T), raw.keys[0].value) <= tolerance)
            raw.keys[0..0]
        else
            raw.keys;
        return RawTrack(T).init(allocator, raw.name, keys);
    }

    const Segment = struct { first: usize, last: usize };
    var segments: std.ArrayList(Segment) = .empty;
    defer segments.deinit(allocator);
    var included = try allocator.alloc(bool, raw.keys.len);
    defer allocator.free(included);
    @memset(included, false);

    try segments.append(allocator, .{ .first = 0, .last = raw.keys.len - 1 });
    included[0] = true;
    included[raw.keys.len - 1] = true;
    while (segments.pop()) |segment| {
        const left = raw.keys[segment.first];
        const right = raw.keys[segment.last];
        var maximum: f32 = -1;
        var candidate = segment.first;
        for (segment.first + 1..segment.last) |i| {
            const key = raw.keys[i];
            if (key.interpolation == .step) {
                candidate = i;
                break;
            }
            const alpha = (key.ratio - left.ratio) / (right.ratio - left.ratio);
            const distance = valueDistance(T, lerpValue(T, left.value, right.value, alpha), key.value);
            if (distance > tolerance and distance > maximum) {
                maximum = distance;
                candidate = i;
            }
        }
        if (candidate != segment.first) {
            included[candidate] = true;
            if (candidate - segment.first > 1) {
                try segments.append(allocator, .{ .first = segment.first, .last = candidate });
            }
            if (segment.last - candidate > 1) {
                try segments.append(allocator, .{ .first = candidate, .last = segment.last });
            }
        }
    }

    var output: std.ArrayList(Key) = .empty;
    defer output.deinit(allocator);
    for (raw.keys, included) |key, keep| if (keep) try output.append(allocator, key);

    // RDP always retains both endpoints. Upstream then removes redundant tail
    // keys so an identity track has no keys and a constant track has one.
    while (output.items.len != 0) {
        const last_key = output.items.len == 1;
        const back = output.items[output.items.len - 1];
        if (!last_key and back.interpolation == .step) break;
        const previous = if (last_key)
            defaultTrackValue(T)
        else
            output.items[output.items.len - 2].value;
        if (valueDistance(T, previous, back.value) > tolerance) break;
        _ = output.pop();
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

fn selected3(value: math.Vec3f32, component: MotionComponent) math.Vec3f32 {
    return .{
        if (component.x) value[0] else 0,
        if (component.y) value[1] else 0,
        if (component.z) value[2] else 0,
    };
}

fn positionReference(
    input: RawAnimation,
    skeleton: runtime.Skeleton,
    joint: usize,
    reference: MotionReference,
) math.Vec3f32 {
    return switch (reference) {
        .absolute => @splat(0),
        .skeleton => skeleton.jointRestPose(joint).translation,
        .animation => if (input.tracks[joint].translations.len > 0)
            input.tracks[joint].translations[0].value
        else
            @splat(0),
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
        const relative = math.vec.sub(key.value, position_ref);
        const extracted = selected3(relative, options.position);
        try position_keys.append(allocator, .{
            .interpolation = .linear,
            .ratio = key.time / input.duration,
            .value = extracted,
        });
        if (options.position.bake) {
            const remaining = math.vec.sub(relative, extracted);
            baked.tracks[options.root_joint].translations[i].value =
                math.vec.add(position_ref, remaining);
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

    if (options.position.loop and position.keys.len > 1) {
        const delta = math.vec.sub(position.keys[0].value, position.keys[position.keys.len - 1].value);
        const denominator: f32 = @floatFromInt(position.keys.len - 1);
        for (position.keys, 0..) |*key, i| {
            key.value = math.vec.add(
                key.value,
                math.vec.scale(delta, @as(f32, @floatFromInt(i)) / denominator),
            );
        }
    }
    if (options.rotation.loop and rotation.keys.len > 1) {
        const delta = math.Quaternion.mul(
            rotation.keys[0].value,
            math.Quaternion.conjugate(rotation.keys[rotation.keys.len - 1].value),
        );
        const denominator: f32 = @floatFromInt(rotation.keys.len - 1);
        for (rotation.keys, 0..) |*key, i| {
            const correction = math.Quaternion.nlerp(
                .identity,
                delta,
                @as(f32, @floatFromInt(i)) / denominator,
            );
            key.value = math.Quaternion.normalize(math.Quaternion.mul(correction, key.value));
        }
    }

    // Root motion is composed as rotation followed by translation. Once the
    // extracted rotation is applied outside the animation, the remaining
    // translation must be expressed in that rotating frame as well. Rotation
    // and translation keys can have different times, so sample the extracted
    // rotation track at each translation key, matching Ozz's extractor.
    if (options.rotation.bake) {
        for (baked.tracks[options.root_joint].translations, position.keys) |*joint_key, motion_key| {
            const motion_rotation = sampleTrack(math.Quaternion, rotation, motion_key.ratio);
            joint_key.value = math.Quaternion.rotate(
                math.Quaternion.conjugate(motion_rotation),
                joint_key.value,
            );
        }
    }
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
                .translation = if (track.translations.len > 0) track.translations[0].value else @splat(0),
                .rotation = if (track.rotations.len > 0) track.rotations[0].value else .identity,
                .scale = if (track.scales.len > 0) track.scales[0].value else @splat(1),
            };
        for (output.tracks[i].translations) |*key| {
            key.value = math.vec.sub(key.value, reference.translation);
        }
        const inv_rotation = math.Quaternion.conjugate(reference.rotation);
        for (output.tracks[i].rotations) |*key| {
            key.value = math.Quaternion.normalize(math.Quaternion.mul(inv_rotation, key.value));
        }
        for (output.tracks[i].scales) |*key| {
            key.value = .{
                if (reference.scale[0] != 0) key.value[0] / reference.scale[0] else 0,
                if (reference.scale[1] != 0) key.value[1] / reference.scale[1] else 0,
                if (reference.scale[2] != 0) key.value[2] / reference.scale[2] else 0,
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
    distance_scale: f32,
    comptime rotation_distance: bool,
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
                const interpolated = lerpValue(T, keys[anchor].value, keys[candidate].value, alpha);
                const distance = if (rotation_distance) blk: {
                    const dot = @abs(math.Quaternion.dot(middle.value, interpolated));
                    break :blk 2 * @sqrt(@max(1 - @min(1, dot * dot), 0)) * distance_scale;
                } else valueDistance(T, middle.value, interpolated) * distance_scale;
                if (distance > tolerance) {
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

pub const OptimizationSetting = struct {
    tolerance: f32 = 1e-3,
    distance: f32 = 1e-1,
};

pub const JointOptimizationSetting = struct {
    joint: usize,
    setting: OptimizationSetting,
};

pub const OptimizationSettings = struct {
    /// Component tolerances retained for source compatibility. Setting
    /// `tolerance` applies one upstream-compatible tolerance to all components.
    translation_tolerance: f32 = 1e-3,
    rotation_tolerance: f32 = 1e-3,
    scale_tolerance: f32 = 1e-3,
    tolerance: ?f32 = null,
    distance: f32 = 1e-1,
    joint_overrides: []const JointOptimizationSetting = &.{},
};

const HierarchySpec = struct {
    length: f32,
    scale: f32,
    translation_tolerance: f32,
    rotation_tolerance: f32,
    scale_tolerance: f32,
};

fn jointOverride(settings: OptimizationSettings, joint: usize) ?OptimizationSetting {
    for (settings.joint_overrides) |override| {
        if (override.joint == joint) return override.setting;
    }
    return null;
}

pub fn optimizeAnimation(
    allocator: std.mem.Allocator,
    input: RawAnimation,
    skeleton: runtime.Skeleton,
    settings: OptimizationSettings,
) !RawAnimation {
    if (!input.validate() or input.tracks.len != skeleton.numJoints()) {
        return runtime.Error.InvalidTrackCount;
    }
    const global_translation = settings.tolerance orelse settings.translation_tolerance;
    const global_rotation = settings.tolerance orelse settings.rotation_tolerance;
    const global_scale = settings.tolerance orelse settings.scale_tolerance;
    if (!std.math.isFinite(global_translation) or global_translation < 0 or
        !std.math.isFinite(global_rotation) or global_rotation < 0 or
        !std.math.isFinite(global_scale) or global_scale < 0 or
        !std.math.isFinite(settings.distance) or settings.distance < 0)
    {
        return runtime.Error.InvalidLayer;
    }

    const specs = try allocator.alloc(HierarchySpec, input.tracks.len);
    defer allocator.free(specs);
    for (input.tracks, 0..) |track, joint| {
        var max_scale: f32 = 1;
        if (track.scales.len != 0) {
            max_scale = 0;
            for (track.scales) |key| {
                max_scale = @max(max_scale, @reduce(.Max, @abs(key.value)));
            }
        }
        const parent = skeleton.parents[joint];
        const accumulated_scale = max_scale * if (parent == runtime.no_parent)
            @as(f32, 1)
        else
            specs[@intCast(parent)].scale;
        const override = jointOverride(settings, joint);
        if (override) |value| {
            if (!std.math.isFinite(value.tolerance) or value.tolerance < 0 or
                !std.math.isFinite(value.distance) or value.distance < 0)
            {
                return runtime.Error.InvalidLayer;
            }
        }
        specs[joint] = .{
            .length = (if (override) |value| value.distance else settings.distance) * accumulated_scale,
            .scale = accumulated_scale,
            .translation_tolerance = if (override) |value| value.tolerance else global_translation,
            .rotation_tolerance = if (override) |value| value.tolerance else global_rotation,
            .scale_tolerance = if (override) |value| value.tolerance else global_scale,
        };
    }
    var reverse = input.tracks.len;
    while (reverse > 0) {
        reverse -= 1;
        const parent = skeleton.parents[reverse];
        if (parent == runtime.no_parent) continue;
        var max_length_sq: f32 = 0;
        for (input.tracks[reverse].translations) |key| {
            max_length_sq = @max(max_length_sq, math.vec.norm_sqr(key.value));
        }
        const parent_index: usize = @intCast(parent);
        specs[parent_index].length = @max(
            specs[parent_index].length,
            specs[reverse].length + @sqrt(max_length_sq) * specs[parent_index].scale,
        );
        specs[parent_index].translation_tolerance = @min(
            specs[parent_index].translation_tolerance,
            specs[reverse].translation_tolerance,
        );
        specs[parent_index].rotation_tolerance = @min(
            specs[parent_index].rotation_tolerance,
            specs[reverse].rotation_tolerance,
        );
        specs[parent_index].scale_tolerance = @min(
            specs[parent_index].scale_tolerance,
            specs[reverse].scale_tolerance,
        );
    }

    var output = try RawAnimation.init(allocator, input.name, input.duration, input.tracks.len);
    errdefer output.deinit();
    for (input.tracks, 0..) |track, i| {
        output.tracks[i].translations = try decimateTimed(
            math.Vec3f32,
            TranslationKey,
            allocator,
            track.translations,
            specs[i].translation_tolerance,
            if (skeleton.parents[i] == runtime.no_parent)
                1
            else
                specs[@intCast(skeleton.parents[i])].scale,
            false,
        );
        output.tracks[i].rotations = try decimateTimed(
            math.Quaternion,
            RotationKey,
            allocator,
            track.rotations,
            specs[i].rotation_tolerance,
            specs[i].length,
            true,
        );
        output.tracks[i].scales = try decimateTimed(
            math.Vec3f32,
            ScaleKey,
            allocator,
            track.scales,
            specs[i].scale_tolerance,
            specs[i].length,
            false,
        );
    }
    return output;
}

test "raw sampling, additive building, and key reduction" {
    const allocator = std.testing.allocator;
    var raw = try RawAnimation.init(allocator, "raw", 1, 1);
    defer raw.deinit();
    raw.tracks[0].translations = try allocator.dupe(TranslationKey, &.{
        .{ .time = 0, .value = @splat(0) },
        .{ .time = 0.5, .value = .{ 1, 0, 0 } },
        .{ .time = 1, .value = .{ 2, 0, 0 } },
    });
    var sampled: [1]math.Transform = undefined;
    try sampleRawAnimation(raw, 0.25, &sampled);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sampled[0].translation[0], 1e-5);

    var additive = try buildAdditive(allocator, raw, null);
    defer additive.deinit();
    try std.testing.expectEqual(@as(f32, 2), additive.tracks[0].translations[2].value[0]);

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
