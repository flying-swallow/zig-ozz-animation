const std = @import("std");
const math = @import("math.zig");

pub const max_joints = 1024;
pub const no_parent: i16 = -1;

pub const Error = error{
    TooManyJoints,
    InvalidHierarchy,
    InvalidRestPose,
    InvalidDuration,
    InvalidTrackCount,
    InvalidKeyframe,
    ContextTooSmall,
    OutputTooSmall,
    InvalidThreshold,
    InvalidLayer,
};

fn finite3(v: math.Vec3f32) bool {
    return std.math.isFinite(v[0]) and std.math.isFinite(v[1]) and std.math.isFinite(v[2]);
}

fn finiteQuat(v: math.Quat4f32) bool {
    return std.math.isFinite(v[0]) and std.math.isFinite(v[1]) and
        std.math.isFinite(v[2]) and std.math.isFinite(v[3]);
}

pub const JointInput = struct {
    name: []const u8,
    parent: i16,
    rest_pose: math.Transform = .identity,
};

pub const Skeleton = struct {
    allocator: std.mem.Allocator,
    parents: []i16,
    names: [][]u8,
    rest_poses: []math.SoaTransform,

    pub fn init(allocator: std.mem.Allocator, joints: []const JointInput) !Skeleton {
        if (joints.len > max_joints) return Error.TooManyJoints;
        var parents = try allocator.alloc(i16, joints.len);
        errdefer allocator.free(parents);
        var names = try allocator.alloc([]u8, joints.len);
        errdefer allocator.free(names);
        var initialized_names: usize = 0;
        errdefer for (names[0..initialized_names]) |name| allocator.free(name);

        const soa_count = (joints.len + 3) / 4;
        const rest_poses = try allocator.alloc(math.SoaTransform, soa_count);
        errdefer allocator.free(rest_poses);
        var aos = try allocator.alloc(math.Transform, joints.len);
        defer allocator.free(aos);

        for (joints, 0..) |joint, i| {
            if (joint.parent < no_parent or joint.parent >= @as(i16, @intCast(i))) {
                return Error.InvalidHierarchy;
            }
            if (!finite3(joint.rest_pose.translation) or !finiteQuat(joint.rest_pose.rotation) or
                !finite3(joint.rest_pose.scale))
            {
                return Error.InvalidRestPose;
            }
            parents[i] = joint.parent;
            names[i] = try allocator.dupe(u8, joint.name);
            initialized_names += 1;
            aos[i] = joint.rest_pose;
        }
        math.aosToSoa(aos, rest_poses);
        return .{ .allocator = allocator, .parents = parents, .names = names, .rest_poses = rest_poses };
    }

    pub fn deinit(self: *Skeleton) void {
        for (self.names) |name| self.allocator.free(name);
        self.allocator.free(self.names);
        self.allocator.free(self.parents);
        self.allocator.free(self.rest_poses);
        self.* = undefined;
    }

    pub fn numJoints(self: Skeleton) usize {
        return self.parents.len;
    }

    pub fn numSoaJoints(self: Skeleton) usize {
        return self.rest_poses.len;
    }

    pub fn jointRestPose(self: Skeleton, index: usize) math.Transform {
        return math.soaLane(self.rest_poses[index / 4], index % 4);
    }
};

pub const Float3Key = struct {
    ratio: f32,
    value: math.Vec3f32,
};

pub const QuaternionKey = struct {
    ratio: f32,
    value: math.Quat4f32,
};

pub const JointTrackInput = struct {
    translations: []const Float3Key = &.{},
    rotations: []const QuaternionKey = &.{},
    scales: []const Float3Key = &.{},
};

pub const JointTrack = struct {
    translations: []Float3Key,
    rotations: []QuaternionKey,
    scales: []Float3Key,
};

pub const AnimationBuildOptions = struct {
    /// Interval, in seconds, between random-seek lookup checkpoints.
    /// `null` disables checkpoint generation.
    iframe_interval: ?f32 = 10,
};

const TrackIframes = struct {
    translations: []u32 = &.{},
    rotations: []u32 = &.{},
    scales: []u32 = &.{},
};

fn validateKeys(comptime Key: type, keys: []const Key) bool {
    var previous: f32 = -1;
    for (keys) |key| {
        if (!std.math.isFinite(key.ratio) or key.ratio < 0 or key.ratio > 1 or key.ratio < previous) {
            return false;
        }
        previous = key.ratio;
        if (Key == Float3Key) {
            if (!finite3(key.value)) return false;
        } else if (!finiteQuat(key.value)) return false;
    }
    return true;
}

pub const Animation = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    duration: f32,
    tracks: []JointTrack,
    iframe_interval: ?f32 = null,
    iframes: []TrackIframes = &.{},

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        duration: f32,
        inputs: []const JointTrackInput,
    ) !Animation {
        return initWithOptions(allocator, name, duration, inputs, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        name: []const u8,
        duration: f32,
        inputs: []const JointTrackInput,
        options: AnimationBuildOptions,
    ) !Animation {
        // Match Ozz's default runtime Animation: an empty animation may have a
        // zero duration. Populated animations still require positive time.
        if (!std.math.isFinite(duration) or duration < 0 or
            (duration == 0 and inputs.len != 0))
        {
            return Error.InvalidDuration;
        }
        if (options.iframe_interval) |interval| {
            if (!std.math.isFinite(interval) or interval <= 0) {
                return Error.InvalidDuration;
            }
        }
        if (inputs.len > max_joints) return Error.InvalidTrackCount;
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        var tracks = try allocator.alloc(JointTrack, inputs.len);
        errdefer allocator.free(tracks);
        var initialized: usize = 0;
        errdefer for (tracks[0..initialized]) |track| {
            allocator.free(track.translations);
            allocator.free(track.rotations);
            allocator.free(track.scales);
        };

        for (inputs, 0..) |input, i| {
            if (!validateKeys(Float3Key, input.translations) or
                !validateKeys(QuaternionKey, input.rotations) or
                !validateKeys(Float3Key, input.scales))
            {
                return Error.InvalidKeyframe;
            }
            tracks[i] = .{
                .translations = try allocator.dupe(Float3Key, input.translations),
                .rotations = &.{},
                .scales = &.{},
            };
            errdefer allocator.free(tracks[i].translations);
            tracks[i].rotations = try allocator.dupe(QuaternionKey, input.rotations);
            errdefer allocator.free(tracks[i].rotations);
            tracks[i].scales = try allocator.dupe(Float3Key, input.scales);
            initialized += 1;
        }

        var iframes: []TrackIframes = &.{};
        if (options.iframe_interval != null and inputs.len != 0) {
            iframes = try allocator.alloc(TrackIframes, inputs.len);
            @memset(iframes, .{});
            var iframe_initialized: usize = 0;
            errdefer {
                for (iframes[0..iframe_initialized]) |track| {
                    allocator.free(track.translations);
                    allocator.free(track.rotations);
                    allocator.free(track.scales);
                }
                allocator.free(iframes);
            }
            for (tracks, iframes) |track, *iframe| {
                iframe.translations = try buildIframes(
                    Float3Key,
                    allocator,
                    track.translations,
                    duration,
                    options.iframe_interval.?,
                );
                errdefer allocator.free(iframe.translations);
                iframe.rotations = try buildIframes(
                    QuaternionKey,
                    allocator,
                    track.rotations,
                    duration,
                    options.iframe_interval.?,
                );
                errdefer allocator.free(iframe.rotations);
                iframe.scales = try buildIframes(
                    Float3Key,
                    allocator,
                    track.scales,
                    duration,
                    options.iframe_interval.?,
                );
                iframe_initialized += 1;
            }
        }
        return .{
            .allocator = allocator,
            .name = owned_name,
            .duration = duration,
            .tracks = tracks,
            .iframe_interval = options.iframe_interval,
            .iframes = iframes,
        };
    }

    pub fn deinit(self: *Animation) void {
        for (self.iframes) |track| {
            self.allocator.free(track.translations);
            self.allocator.free(track.rotations);
            self.allocator.free(track.scales);
        }
        self.allocator.free(self.iframes);
        for (self.tracks) |track| {
            self.allocator.free(track.translations);
            self.allocator.free(track.rotations);
            self.allocator.free(track.scales);
        }
        self.allocator.free(self.tracks);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn numTracks(self: Animation) usize {
        return self.tracks.len;
    }

    pub fn numSoaTracks(self: Animation) usize {
        return (self.tracks.len + 3) / 4;
    }

    pub fn memorySize(self: Animation) usize {
        var size = @sizeOf(Animation) + self.name.len +
            self.tracks.len * @sizeOf(JointTrack) +
            self.iframes.len * @sizeOf(TrackIframes);
        for (self.tracks) |track| {
            size += track.translations.len * @sizeOf(Float3Key);
            size += track.rotations.len * @sizeOf(QuaternionKey);
            size += track.scales.len * @sizeOf(Float3Key);
        }
        for (self.iframes) |track| {
            size += track.translations.len * @sizeOf(u32);
            size += track.rotations.len * @sizeOf(u32);
            size += track.scales.len * @sizeOf(u32);
        }
        return size;
    }
};

fn buildIframes(
    comptime Key: type,
    allocator: std.mem.Allocator,
    keys: []const Key,
    duration: f32,
    interval: f32,
) ![]u32 {
    if (keys.len < 2 or duration <= 0) return allocator.alloc(u32, 0);
    const count = @as(usize, @intFromFloat(@floor(duration / interval))) + 1;
    const output = try allocator.alloc(u32, count);
    var key: usize = 0;
    for (output, 0..) |*entry, iframe| {
        const ratio = @min(
            @as(f32, @floatFromInt(iframe)) * interval / duration,
            1,
        );
        while (key + 1 < keys.len - 1 and keys[key + 1].ratio <= ratio) : (key += 1) {}
        entry.* = @intCast(key);
    }
    return output;
}

pub const SamplingContext = struct {
    allocator: std.mem.Allocator,
    animation: ?*const Animation = null,
    ratio: f32 = -1,
    translation_keys: []u32,
    rotation_keys: []u32,
    scale_keys: []u32,

    pub fn init(allocator: std.mem.Allocator, max_tracks: usize) !SamplingContext {
        const translations = try allocator.alloc(u32, max_tracks);
        errdefer allocator.free(translations);
        const rotations = try allocator.alloc(u32, max_tracks);
        errdefer allocator.free(rotations);
        const scales = try allocator.alloc(u32, max_tracks);
        @memset(translations, 0);
        @memset(rotations, 0);
        @memset(scales, 0);
        return .{
            .allocator = allocator,
            .translation_keys = translations,
            .rotation_keys = rotations,
            .scale_keys = scales,
        };
    }

    pub fn deinit(self: *SamplingContext) void {
        self.allocator.free(self.translation_keys);
        self.allocator.free(self.rotation_keys);
        self.allocator.free(self.scale_keys);
        self.* = undefined;
    }

    pub fn invalidate(self: *SamplingContext) void {
        self.animation = null;
        self.ratio = -1;
        @memset(self.translation_keys, 0);
        @memset(self.rotation_keys, 0);
        @memset(self.scale_keys, 0);
    }

    pub fn resize(self: *SamplingContext, max_tracks: usize) !void {
        if (max_tracks == self.translation_keys.len) {
            self.invalidate();
            return;
        }
        const translations = try self.allocator.alloc(u32, max_tracks);
        errdefer self.allocator.free(translations);
        const rotations = try self.allocator.alloc(u32, max_tracks);
        errdefer self.allocator.free(rotations);
        const scales = try self.allocator.alloc(u32, max_tracks);
        self.allocator.free(self.translation_keys);
        self.allocator.free(self.rotation_keys);
        self.allocator.free(self.scale_keys);
        self.translation_keys = translations;
        self.rotation_keys = rotations;
        self.scale_keys = scales;
        self.invalidate();
    }
};

fn keyIndex(
    comptime Key: type,
    keys: []const Key,
    ratio: f32,
    cached: *u32,
    forward: bool,
    seed: u32,
) usize {
    if (keys.len < 2) return 0;
    var index: usize = @min(if (forward) cached.* else seed, keys.len - 2);
    while (index + 1 < keys.len - 1 and keys[index + 1].ratio <= ratio) : (index += 1) {}
    cached.* = @intCast(index);
    return index;
}

fn sampleFloat3(
    keys: []const Float3Key,
    ratio: f32,
    cache: *u32,
    fallback: math.Vec3f32,
    forward: bool,
    seed: u32,
) math.Vec3f32 {
    if (keys.len == 0) return fallback;
    if (keys.len == 1 or ratio <= keys[0].ratio) return keys[0].value;
    if (ratio >= keys[keys.len - 1].ratio) return keys[keys.len - 1].value;
    const i = keyIndex(Float3Key, keys, ratio, cache, forward, seed);
    const a = keys[i];
    const b = keys[i + 1];
    const alpha = (ratio - a.ratio) / (b.ratio - a.ratio);
    return math.approx.lerp_exact(a.value, b.value, alpha);
}

fn sampleQuaternion(
    keys: []const QuaternionKey,
    ratio: f32,
    cache: *u32,
    fallback: math.Quat4f32,
    forward: bool,
    seed: u32,
) math.Quat4f32 {
    if (keys.len == 0) return fallback;
    if (keys.len == 1 or ratio <= keys[0].ratio) return keys[0].value;
    if (ratio >= keys[keys.len - 1].ratio) return keys[keys.len - 1].value;
    const i = keyIndex(QuaternionKey, keys, ratio, cache, forward, seed);
    const a = keys[i];
    const b = keys[i + 1];
    const alpha = (ratio - a.ratio) / (b.ratio - a.ratio);
    return math.quat.nlerp(a.value, b.value, alpha);
}

pub fn sample(
    animation: *const Animation,
    ratio_in: f32,
    context: *SamplingContext,
    output: []math.SoaTransform,
) !void {
    if (context.translation_keys.len < animation.tracks.len or
        context.rotation_keys.len < animation.tracks.len or
        context.scale_keys.len < animation.tracks.len)
    {
        return Error.ContextTooSmall;
    }
    if (output.len < animation.numSoaTracks()) return Error.OutputTooSmall;
    const ratio = std.math.clamp(ratio_in, 0, 1);
    const forward = context.animation == animation and ratio >= context.ratio;
    if (context.animation != animation or !forward) context.invalidate();
    context.animation = animation;
    @memset(output[0..animation.numSoaTracks()], math.SoaTransform.identity);

    for (animation.tracks, 0..) |track, i| {
        const fallback = math.Transform.identity;
        const iframe = if (animation.iframes.len == animation.tracks.len)
            animation.iframes[i]
        else
            TrackIframes{};
        const iframe_index = if (!forward and animation.iframe_interval != null)
            @as(usize, @intFromFloat(@floor(
                ratio * animation.duration / animation.iframe_interval.?,
            )))
        else
            0;
        const sampled: math.Transform = .{
            .translation = sampleFloat3(
                track.translations,
                ratio,
                &context.translation_keys[i],
                fallback.translation,
                forward,
                if (iframe.translations.len == 0)
                    0
                else
                    iframe.translations[@min(iframe_index, iframe.translations.len - 1)],
            ),
            .rotation = sampleQuaternion(
                track.rotations,
                ratio,
                &context.rotation_keys[i],
                fallback.rotation,
                forward,
                if (iframe.rotations.len == 0)
                    0
                else
                    iframe.rotations[@min(iframe_index, iframe.rotations.len - 1)],
            ),
            .scale = sampleFloat3(
                track.scales,
                ratio,
                &context.scale_keys[i],
                fallback.scale,
                forward,
                if (iframe.scales.len == 0)
                    0
                else
                    iframe.scales[@min(iframe_index, iframe.scales.len - 1)],
            ),
        };
        math.setSoaLane(&output[i / 4], i % 4, sampled);
    }
    context.ratio = ratio;
}

pub fn findJoint(skeleton: Skeleton, name: []const u8) ?usize {
    for (skeleton.names, 0..) |joint_name, i| {
        if (std.mem.eql(u8, joint_name, name)) return i;
    }
    return null;
}

pub fn countTranslationKeyframes(value: Animation, track: ?usize) usize {
    if (track) |index| return if (index < value.tracks.len) value.tracks[index].translations.len else 0;
    var count: usize = 0;
    for (value.tracks) |joint_track| count += joint_track.translations.len;
    return count;
}

pub fn countRotationKeyframes(value: Animation, track: ?usize) usize {
    if (track) |index| return if (index < value.tracks.len) value.tracks[index].rotations.len else 0;
    var count: usize = 0;
    for (value.tracks) |joint_track| count += joint_track.rotations.len;
    return count;
}

pub fn countScaleKeyframes(value: Animation, track: ?usize) usize {
    if (track) |index| return if (index < value.tracks.len) value.tracks[index].scales.len else 0;
    var count: usize = 0;
    for (value.tracks) |joint_track| count += joint_track.scales.len;
    return count;
}

pub fn isLeaf(skeleton: Skeleton, joint: usize) bool {
    if (joint >= skeleton.numJoints()) return false;
    return joint + 1 == skeleton.numJoints() or skeleton.parents[joint + 1] != @as(i16, @intCast(joint));
}

/// Returns the exclusive end of a joint's depth-first subtree.
pub fn subtreeEnd(skeleton: Skeleton, joint: usize) usize {
    if (joint >= skeleton.numJoints()) return skeleton.numJoints();
    var end = joint + 1;
    while (end < skeleton.numJoints() and skeleton.parents[end] >= @as(i16, @intCast(joint))) : (end += 1) {}
    return end;
}

pub fn jointDepth(skeleton: Skeleton, joint: usize) !usize {
    if (joint >= skeleton.numJoints()) return Error.InvalidHierarchy;
    var depth: usize = 0;
    var current = skeleton.parents[joint];
    while (current != no_parent) {
        depth += 1;
        current = skeleton.parents[@intCast(current)];
    }
    return depth;
}

/// Visits joints in depth-first storage order. A null `from` visits every
/// root; otherwise only `from` and its descendants are visited.
/// `visitor` must expose `visit(usize, i16)`.
pub fn iterateJointsDF(skeleton: Skeleton, from: ?usize, visitor: anytype) void {
    const begin = from orelse 0;
    if (begin >= skeleton.numJoints()) return;
    const end = if (from) |joint| subtreeEnd(skeleton, joint) else skeleton.numJoints();
    for (begin..end) |joint| visitor.visit(joint, skeleton.parents[joint]);
}

/// Visits all joints in reverse depth-first order, ensuring every child is
/// visited before its parent. `visitor` must expose `visit(usize, i16)`.
pub fn iterateJointsDFReverse(skeleton: Skeleton, visitor: anytype) void {
    var joint = skeleton.numJoints();
    while (joint > 0) {
        joint -= 1;
        visitor.visit(joint, skeleton.parents[joint]);
    }
}

pub const BlendLayer = struct {
    transforms: []const math.SoaTransform,
    weight: f32,
    joint_weights: ?[]const math.Vec4f32 = null,
};

pub const BlendOptions = struct {
    rest_pose: []const math.SoaTransform,
    layers: []const BlendLayer,
    additive_layers: []const BlendLayer = &.{},
    threshold: f32 = 0.1,
};

pub fn blend(options: BlendOptions, output: []math.SoaTransform) !void {
    if (!(options.threshold > 0)) return Error.InvalidThreshold;
    if (output.len < options.rest_pose.len) return Error.OutputTooSmall;
    for (options.layers) |layer| {
        if (layer.transforms.len < options.rest_pose.len or
            (layer.joint_weights != null and layer.joint_weights.?.len < options.rest_pose.len))
        {
            return Error.InvalidLayer;
        }
    }
    for (options.additive_layers) |layer| {
        if (layer.transforms.len < options.rest_pose.len or
            (layer.joint_weights != null and layer.joint_weights.?.len < options.rest_pose.len))
        {
            return Error.InvalidLayer;
        }
    }

    for (options.rest_pose, 0..) |rest_soa, soa_i| {
        for (0..4) |lane| {
            const rest = math.soaLane(rest_soa, lane);
            var translation = @as(math.Vec3f32, @splat(0));
            var scale = @as(math.Vec3f32, @splat(0));
            var rotation: math.Quat4f32 = @splat(0);
            var total: f32 = 0;
            for (options.layers) |layer| {
                var weight = @max(layer.weight, 0);
                if (layer.joint_weights) |jw| weight *= @max(math.lane(jw[soa_i], lane), 0);
                if (weight == 0) continue;
                const t = math.soaLane(layer.transforms[soa_i], lane);
                translation = math.vec.add(translation, math.vec.scale(t.translation, weight));
                scale = math.vec.add(scale, math.vec.scale(t.scale, weight));
                var q = t.rotation;
                if (total > 0 and math.quat.dot(rotation, q) < 0) {
                    q = -q;
                }
                rotation += q * @as(math.Quat4f32, @splat(weight));
                total += weight;
            }
            if (total < options.threshold) {
                const rest_weight = options.threshold - total;
                translation = math.vec.add(translation, math.vec.scale(rest.translation, rest_weight));
                scale = math.vec.add(scale, math.vec.scale(rest.scale, rest_weight));
                rotation += rest.rotation * @as(math.Quat4f32, @splat(rest_weight));
                total = options.threshold;
            }
            var result: math.Transform = .{
                .translation = math.vec.scale(translation, 1 / total),
                .rotation = math.quat.normalize(rotation),
                .scale = math.vec.scale(scale, 1 / total),
            };
            for (options.additive_layers) |layer| {
                var weight = layer.weight;
                if (layer.joint_weights) |jw| weight *= @max(math.lane(jw[soa_i], lane), 0);
                if (weight == 0) continue;
                const add = math.soaLane(layer.transforms[soa_i], lane);
                result.translation = math.vec.add(result.translation, math.vec.scale(add.translation, weight));
                if (weight > 0) {
                    result.scale = math.vec.mul(
                        result.scale,
                        math.approx.lerp_exact(@as(math.Vec3f32, @splat(1)), add.scale, weight),
                    );
                    result.rotation = math.quat.mul(
                        result.rotation,
                        math.quat.nlerp(math.quat.identity, add.rotation, weight),
                    );
                } else {
                    const weighted_scale = math.approx.lerp_exact(
                        @as(math.Vec3f32, @splat(1)),
                        add.scale,
                        -weight,
                    );
                    result.scale = math.vec.mul(
                        result.scale,
                        .{
                            1 / weighted_scale[0],
                            1 / weighted_scale[1],
                            1 / weighted_scale[2],
                        },
                    );
                    result.rotation = math.quat.mul(
                        result.rotation,
                        math.quat.nlerp(math.quat.identity, math.quat.conjugate(add.rotation), -weight),
                    );
                }
            }
            math.setSoaLane(&output[soa_i], lane, result);
        }
    }
}

pub const LocalToModelOptions = struct {
    skeleton: *const Skeleton,
    input: []const math.SoaTransform,
    root: math.Float4x4 = .identity,
    /// Null updates the whole skeleton. A joint index limits the update to its
    /// depth-first subtree.
    from: ?usize = null,
    /// Inclusive final joint, matching ozz's LocalToModelJob.
    to: ?usize = null,
    from_excluded: bool = false,
};

pub fn localToModel(options: LocalToModelOptions, output: []math.Float4x4) !void {
    const joint_count = options.skeleton.numJoints();
    if (options.input.len < options.skeleton.numSoaJoints() or output.len < joint_count) {
        return Error.OutputTooSmall;
    }
    if (joint_count == 0) return;
    const from = options.from orelse 0;
    if (from >= joint_count) return;
    const subtree_end = if (options.from != null)
        subtreeEnd(options.skeleton.*, from)
    else
        joint_count;
    const requested_end = if (options.to) |to|
        @min(to +| 1, joint_count)
    else
        joint_count;
    const end = @min(subtree_end, requested_end);
    const begin = from + @intFromBool(options.from != null and options.from_excluded);
    if (begin >= end) return;
    for (begin..end) |i| {
        const local = math.Float4x4.fromTransform(math.soaLane(options.input[i / 4], i % 4));
        const parent = options.skeleton.parents[i];
        output[i] = if (parent == no_parent)
            math.Float4x4.mul(options.root, local)
        else
            math.Float4x4.mul(output[@intCast(parent)], local);
    }
}

pub const Interpolation = enum(u8) { step, linear };

/// Discriminates what a track's samples *mean*, which the value type cannot.
///
/// `math.Vec4f32` and `math.Quat4f32` are the same Zig type (`@Vector(4, f32)`), so a float4
/// track and a rotation track are indistinguishable by `T` alone — yet they differ in archive
/// tag, identity value, interpolation, and distance metric. Every such decision keys off this
/// enum instead of the value type.
pub const ValueKind = enum {
    float,
    float2,
    float3,
    float4,
    quaternion,

    pub fn Value(comptime self: ValueKind) type {
        return switch (self) {
            .float => f32,
            .float2 => math.Vec2f32,
            .float3 => math.Vec3f32,
            .float4 => math.Vec4f32,
            .quaternion => math.Quat4f32,
        };
    }
};

pub fn Track(comptime kind: ValueKind) type {
    return struct {
        const Self = @This();
        const T = kind.Value();
        pub const Value = T;
        pub const value_kind = kind;
        pub const Key = struct {
            ratio: f32,
            value: T,
            interpolation: Interpolation = .linear,
        };

        allocator: std.mem.Allocator,
        name: []u8,
        keys: []Key,

        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            keys: []const Key,
            interpolation: Interpolation,
        ) !Self {
            const result = try initMixed(allocator, name, keys);
            for (result.keys) |*key| key.interpolation = interpolation;
            return result;
        }

        pub fn initMixed(
            allocator: std.mem.Allocator,
            name: []const u8,
            keys: []const Key,
        ) !Self {
            var previous: f32 = -1;
            for (keys) |key| {
                if (!std.math.isFinite(key.ratio) or key.ratio < previous or key.ratio < 0 or key.ratio > 1) {
                    return Error.InvalidKeyframe;
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
        pub fn sampleAt(self: Self, ratio_in: f32) T {
            // Ozz runtime tracks are valid in their default/empty state and
            // sampling them returns the policy identity value.
            if (self.keys.len == 0) return trackIdentity(kind);
            const ratio = std.math.clamp(ratio_in, 0, 1);
            if (ratio <= self.keys[0].ratio) return self.keys[0].value;
            if (ratio >= self.keys[self.keys.len - 1].ratio) return self.keys[self.keys.len - 1].value;
            var i: usize = 0;
            while (i + 1 < self.keys.len and self.keys[i + 1].ratio <= ratio) : (i += 1) {}
            if (self.keys[i].interpolation == .step) return self.keys[i].value;
            const a = self.keys[i];
            const b = self.keys[i + 1];
            const t = (ratio - a.ratio) / (b.ratio - a.ratio);
            return interpolate(kind, a.value, b.value, t);
        }
    };
}

fn trackIdentity(comptime kind: ValueKind) kind.Value() {
    if (kind == .quaternion) return math.quat.identity;
    return std.mem.zeroes(kind.Value());
}

fn interpolate(comptime kind: ValueKind, a: kind.Value(), b: kind.Value(), t: f32) kind.Value() {
    return switch (kind) {
        .float => a + (b - a) * t,
        .float2, .float3, .float4 => math.approx.lerp_exact(a, b, t),
        .quaternion => math.quat.nlerp(a, b, t),
    };
}

pub const FloatTrack = Track(.float);
pub const Float2Track = Track(.float2);
pub const Float3Track = Track(.float3);
pub const Float4Track = Track(.float4);
pub const QuaternionTrack = Track(.quaternion);

pub const MotionLayer = struct {
    delta: math.Transform,
    weight: f32,
};

pub fn blendMotion(layers: []const MotionLayer) math.Transform {
    var accumulated_weight: f32 = 0;
    var weighted_length: f32 = 0;
    var direction = @as(math.Vec3f32, @splat(0));
    var rotation: math.Quat4f32 = @splat(0);
    for (layers) |layer| {
        if (layer.weight <= 0) continue;
        const len = math.vec.norm(layer.delta.translation);
        weighted_length += len * layer.weight;
        if (len > 0) {
            direction = math.vec.add(
                direction,
                math.vec.scale(layer.delta.translation, layer.weight / len),
            );
        }
        var q = layer.delta.rotation;
        if (math.quat.dot(rotation, q) < 0) {
            q = -q;
        }
        rotation += q * @as(math.Quat4f32, @splat(layer.weight));
        accumulated_weight += layer.weight;
    }
    const denom = math.vec.norm(direction) * accumulated_weight;
    return .{
        .translation = if (denom > 0) math.vec.scale(direction, weighted_length / denom) else @splat(0),
        .rotation = math.quat.normalize(rotation),
        .scale = @splat(1),
    };
}

pub const AimOptions = struct {
    target: math.Vec3f32,
    joint: math.Float4x4,
    forward: math.Vec3f32 = .{ 1, 0, 0 },
    offset: math.Vec3f32 = .{ 0, 0, 0 },
    up: math.Vec3f32 = .{ 0, 1, 0 },
    pole_vector: math.Vec3f32 = .{ 0, 1, 0 },
    twist_angle: f32 = 0,
    weight: f32 = 1,
};

pub const AimResult = struct {
    correction: math.Quat4f32,
    reached: bool,
};

pub fn aimIk(options: AimOptions) !AimResult {
    if (@abs(math.vec.norm_sqr(options.forward) - 1) > 1e-3) {
        return Error.InvalidLayer;
    }
    const inverse = math.Float4x4.inverse(options.joint) orelse
        return .{ .correction = math.quat.identity, .reached = false };
    const target = math.Float4x4.transformPoint(inverse, options.target);
    const forward_projection = math.vec.dot(options.forward, options.offset);
    const perpendicular_sq = math.vec.norm_sqr(options.offset) -
        forward_projection * forward_projection;
    const target_sq = math.vec.norm_sqr(target);
    if (perpendicular_sq > target_sq) {
        return .{ .correction = math.quat.identity, .reached = false };
    }
    // Ozz reports offset reachability independently from whether the target
    // direction can be resolved. A target at the joint is therefore reached,
    // but produces no correction.
    if (target_sq == 0) return .{ .correction = math.quat.identity, .reached = true };
    const intersection = @sqrt(@max(target_sq - perpendicular_sq, 0));
    const offset_forward = math.vec.add(
        options.offset,
        math.vec.scale(options.forward, intersection - forward_projection),
    );
    const aim_rotation = math.quat.fromTo(offset_forward, target);
    const corrected_up = math.quat.rotate(aim_rotation, options.up);
    const pole_local = math.Float4x4.transformVector(inverse, options.pole_vector);
    const axis = math.vec.normalize(target);
    const current_normal_raw = math.vec.cross(corrected_up, axis);
    const desired_normal_raw = math.vec.cross(pole_local, axis);
    const current_normal_sq = math.vec.norm_sqr(current_normal_raw);
    const desired_normal_sq = math.vec.norm_sqr(desired_normal_raw);
    var plane_rotation = math.quat.identity;
    if (current_normal_sq != 0 and desired_normal_sq != 0) {
        // Plane directions are meaningful at any non-zero magnitude. In
        // particular, ozz deliberately accepts very small up and pole vectors.
        const current_normal = math.vec.scale(current_normal_raw, 1 / @sqrt(current_normal_sq));
        const desired_normal = math.vec.scale(desired_normal_raw, 1 / @sqrt(desired_normal_sq));
        const cosine = std.math.clamp(math.vec.dot(current_normal, desired_normal), -1, 1);
        var angle = std.math.acos(cosine);
        if (math.vec.dot(math.vec.cross(current_normal, desired_normal), axis) < 0) angle = -angle;
        plane_rotation = math.quat.fromAxisAngle(axis, angle);
    }
    const twist = if (options.twist_angle != 0)
        math.quat.fromAxisAngle(axis, options.twist_angle)
    else
        math.quat.identity;
    const full = math.quat.normalize(math.quat.mul(twist, math.quat.mul(plane_rotation, aim_rotation)));
    return .{
        .correction = math.quat.nlerp(math.quat.identity, full, std.math.clamp(options.weight, 0, 1)),
        .reached = true,
    };
}

pub const TwoBoneOptions = struct {
    target: math.Vec3f32,
    start_joint: math.Float4x4,
    mid_joint: math.Float4x4,
    end_joint: math.Float4x4,
    mid_axis: math.Vec3f32 = .{ 0, 0, 1 },
    pole_vector: math.Vec3f32 = .{ 0, 1, 0 },
    twist_angle: f32 = 0,
    soften: f32 = 1,
    weight: f32 = 1,
};

pub const TwoBoneResult = struct {
    start_correction: math.Quat4f32,
    mid_correction: math.Quat4f32,
    reached: bool,
};

pub fn twoBoneIk(options: TwoBoneOptions) !TwoBoneResult {
    if (@abs(math.vec.norm_sqr(options.mid_axis) - 1) > 1e-3) {
        return Error.InvalidLayer;
    }
    const weight = std.math.clamp(options.weight, 0, 1);
    if (weight == 0) return .{ .start_correction = math.quat.identity, .mid_correction = math.quat.identity, .reached = false };

    const inv_start = math.Float4x4.inverse(options.start_joint) orelse
        return .{ .start_correction = math.quat.identity, .mid_correction = math.quat.identity, .reached = false };
    const inv_mid = math.Float4x4.inverse(options.mid_joint) orelse
        return .{ .start_correction = math.quat.identity, .mid_correction = math.quat.identity, .reached = false };

    const start_position = math.Float4x4.translation(options.start_joint);
    const mid_position = math.Float4x4.translation(options.mid_joint);
    const end_position = math.Float4x4.translation(options.end_joint);
    const start_mid_ms = math.vec.scale(math.Float4x4.transformPoint(inv_mid, start_position), -1);
    const mid_end_ms = math.Float4x4.transformPoint(inv_mid, end_position);
    const start_mid_ss = math.Float4x4.transformPoint(inv_start, mid_position);
    const end_ss = math.Float4x4.transformPoint(inv_start, end_position);
    const mid_end_ss = math.vec.sub(end_ss, start_mid_ss);
    const l1_sq = math.vec.norm_sqr(start_mid_ss);
    const l2_sq = math.vec.norm_sqr(mid_end_ss);
    if (l1_sq <= math.epsilon or l2_sq <= math.epsilon) {
        return .{ .start_correction = math.quat.identity, .mid_correction = math.quat.identity, .reached = false };
    }

    const l1 = @sqrt(l1_sq);
    const l2 = @sqrt(l2_sq);
    const chain_length = l1 + l2;
    const minimum_length = @abs(l1 - l2);
    const soften_distance = chain_length * std.math.clamp(options.soften, 0, 1);
    const soften_range = chain_length - soften_distance;
    const original_target_ss = math.Float4x4.transformPoint(inv_start, options.target);
    const original_target_length = math.vec.norm(original_target_ss);
    var target_ss = original_target_ss;
    var target_length = original_target_length;
    if (original_target_length > soften_distance and original_target_length > 0 and soften_range > 0) {
        const alpha = (original_target_length - soften_distance) / soften_range;
        const ratio = 1 - 81 / std.math.pow(f32, alpha + 3, 4);
        target_length = soften_distance + soften_range * ratio;
        target_ss = math.vec.scale(original_target_ss, target_length / original_target_length);
    }
    const reached = original_target_length <= soften_distance and original_target_length > minimum_length and weight >= 1;

    const corrected_cos = std.math.clamp(
        (l1_sq + l2_sq - target_length * target_length) / (2 * l1 * l2),
        -1,
        1,
    );
    const initial_cos = std.math.clamp(
        (l1_sq + l2_sq - math.vec.norm_sqr(end_ss)) / (2 * l1 * l2),
        -1,
        1,
    );
    const bent_reference = math.vec.cross(start_mid_ms, options.mid_axis);
    const initial_sign: f32 = if (math.vec.dot(bent_reference, mid_end_ms) < 0) -1 else 1;
    const initial_angle = std.math.acos(initial_cos) * initial_sign;
    const mid_full = math.quat.fromAxisAngle(
        options.mid_axis,
        std.math.acos(corrected_cos) - initial_angle,
    );

    const rotated_mid_end_ms = math.quat.rotate(mid_full, mid_end_ms);
    const rotated_mid_end_model = math.Float4x4.transformVector(options.mid_joint, rotated_mid_end_ms);
    const rotated_mid_end_ss = math.Float4x4.transformVector(inv_start, rotated_mid_end_model);
    const solved_end_ss = math.vec.add(start_mid_ss, rotated_mid_end_ss);
    const end_to_target = math.quat.fromTo(solved_end_ss, target_ss);
    var start_full = end_to_target;

    if (math.vec.norm_sqr(target_ss) > math.epsilon) {
        const pole_ss = math.Float4x4.transformVector(inv_start, options.pole_vector);
        const reference_normal = math.vec.cross(target_ss, pole_ss);
        const mid_axis_model = math.Float4x4.transformVector(options.mid_joint, options.mid_axis);
        const mid_axis_ss = math.Float4x4.transformVector(inv_start, mid_axis_model);
        const joint_normal = math.quat.rotate(end_to_target, mid_axis_ss);
        if (math.vec.norm_sqr(reference_normal) > math.epsilon and
            math.vec.norm_sqr(joint_normal) > math.epsilon)
        {
            const reference_unit = math.vec.normalize(reference_normal);
            const joint_unit = math.vec.normalize(joint_normal);
            const cosine = std.math.clamp(math.vec.dot(reference_unit, joint_unit), -1, 1);
            var axis = math.vec.normalize(target_ss);
            if (math.vec.dot(joint_normal, pole_ss) < 0) axis = math.vec.scale(axis, -1);
            const plane = math.quat.fromAxisAngle(axis, std.math.acos(cosine));
            start_full = math.quat.mul(plane, end_to_target);
        }
        if (options.twist_angle != 0) {
            const twist = math.quat.fromAxisAngle(math.vec.normalize(target_ss), options.twist_angle);
            start_full = math.quat.mul(twist, start_full);
        }
    }

    return .{
        .start_correction = math.quat.nlerp(math.quat.identity, math.quat.normalize(start_full), weight),
        .mid_correction = math.quat.nlerp(math.quat.identity, mid_full, weight),
        .reached = reached,
    };
}

pub const TrackEdge = struct {
    ratio: f32,
    rising: bool,
};

pub const TrackEdgeIterator = struct {
    track: *const FloatTrack,
    from: f32,
    to: f32,
    threshold: f32,
    loop: i64,
    key: isize,
    done: bool = false,

    pub fn init(track: *const FloatTrack, from: f32, to: f32, threshold: f32) TrackEdgeIterator {
        const forward = to >= from;
        return .{
            .track = track,
            .from = from,
            .to = to,
            .threshold = threshold,
            .loop = @intFromFloat(@floor(from)),
            .key = if (forward) 0 else @intCast(track.keys.len -| 1),
            .done = from == to or track.keys.len == 0,
        };
    }

    pub fn next(self: *TrackEdgeIterator) ?TrackEdge {
        if (self.done) return null;
        const forward = self.to > self.from;
        while (if (forward) @as(f32, @floatFromInt(self.loop)) < self.to else @as(f32, @floatFromInt(self.loop + 1)) > self.to) {
            while (if (forward) self.key < self.track.keys.len else self.key >= 0) {
                const current: usize = @intCast(self.key);
                const previous = if (current == 0) self.track.keys.len - 1 else current - 1;
                const a = self.track.keys[previous];
                const b = self.track.keys[current];
                const rising_forward = a.value <= self.threshold and b.value > self.threshold;
                const falling_forward = a.value > self.threshold and b.value <= self.threshold;
                self.key += if (forward) 1 else -1;
                if (!rising_forward and !falling_forward) continue;
                const local_ratio = if (a.interpolation == .step or current == 0)
                    b.ratio
                else
                    a.ratio + (b.ratio - a.ratio) * ((self.threshold - a.value) / (b.value - a.value));
                const global_ratio = @as(f32, @floatFromInt(self.loop)) + local_ratio;
                const in_range = if (forward)
                    global_ratio >= self.from and
                        (global_ratio < self.to or self.to >= @as(f32, @floatFromInt(self.loop + 1)))
                else
                    global_ratio >= self.to and
                        (global_ratio < self.from or self.from >= @as(f32, @floatFromInt(self.loop + 1)));
                if (in_range) return .{
                    .ratio = global_ratio,
                    .rising = if (forward) rising_forward else !rising_forward,
                };
            }
            self.loop += if (forward) 1 else -1;
            self.key = if (forward) 0 else @intCast(self.track.keys.len - 1);
        }
        self.done = true;
        return null;
    }
};

test "skeleton, sampling, blending, and local-to-model" {
    const allocator = std.testing.allocator;
    var skeleton = try Skeleton.init(allocator, &.{
        .{ .name = "root", .parent = no_parent },
        .{ .name = "child", .parent = 0, .rest_pose = .{ .translation = .{ 2, 0, 0 } } },
    });
    defer skeleton.deinit();
    try std.testing.expectEqual(@as(?usize, 1), findJoint(skeleton, "child"));
    try std.testing.expect(isLeaf(skeleton, 1));
    try std.testing.expectEqual(@as(usize, 2), subtreeEnd(skeleton, 0));
    var animation = try Animation.init(allocator, "move", 1, &.{
        .{ .translations = &.{
            .{ .ratio = 0, .value = @splat(0) },
            .{ .ratio = 1, .value = .{ 2, 0, 0 } },
        } },
        .{},
    });
    defer animation.deinit();
    var context = try SamplingContext.init(allocator, animation.numTracks());
    defer context.deinit();
    var pose: [1]math.SoaTransform = .{math.SoaTransform.identity};
    try sample(&animation, 0.5, &context, &pose);
    try std.testing.expectApproxEqAbs(@as(f32, 1), math.lane(pose[0].translation.x, 0), 1e-5);

    var model: [2]math.Float4x4 = undefined;
    try localToModel(.{ .skeleton = &skeleton, .input = &pose }, &model);
    try std.testing.expectApproxEqAbs(@as(f32, 1), model[0].cols[3][0], 1e-5);
}

test "motion blending, IK, and triggering" {
    const motion = blendMotion(&.{
        .{ .delta = .{ .translation = .{ 2, 0, 0 } }, .weight = 1 },
        .{ .delta = .{ .translation = .{ 0, 2, 0 } }, .weight = 1 },
    });
    try std.testing.expectApproxEqAbs(@as(f32, 2), math.vec.norm(motion.translation), 1e-4);

    const aim = try aimIk(.{
        .target = .{ 0, 1, 0 },
        .joint = .identity,
    });
    const aimed = math.quat.rotate(aim.correction, .{ 1, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), aimed[1], 1e-4);

    const two_bone = try twoBoneIk(.{
        .target = .{ 1, 1, 0 },
        .start_joint = .identity,
        .mid_joint = math.Float4x4.fromTransform(.{ .translation = .{ 1, 0, 0 } }),
        .end_joint = math.Float4x4.fromTransform(.{ .translation = .{ 2, 0, 0 } }),
    });
    try std.testing.expect(two_bone.reached);

    var track = try FloatTrack.init(std.testing.allocator, "signal", &.{
        .{ .ratio = 0, .value = 0 },
        .{ .ratio = 0.5, .value = 1 },
        .{ .ratio = 1, .value = 0 },
    }, .linear);
    defer track.deinit();
    var edges = TrackEdgeIterator.init(&track, 0, 1, 0.5);
    const rising = edges.next().?;
    const falling = edges.next().?;
    try std.testing.expect(rising.rising);
    try std.testing.expect(!falling.rising);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), rising.ratio, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), falling.ratio, 1e-5);
}

test "animation iframe checkpoints preserve random-seek results" {
    const keys = [_]Float3Key{
        .{ .ratio = 0, .value = .{ 0, 0, 0 } },
        .{ .ratio = 0.2, .value = .{ 1, 0, 0 } },
        .{ .ratio = 0.4, .value = .{ 2, 0, 0 } },
        .{ .ratio = 0.6, .value = .{ 3, 0, 0 } },
        .{ .ratio = 0.8, .value = .{ 4, 0, 0 } },
        .{ .ratio = 1, .value = .{ 5, 0, 0 } },
    };
    var checkpointed = try Animation.initWithOptions(
        std.testing.allocator,
        "checkpointed",
        10,
        &.{.{ .translations = &keys }},
        .{ .iframe_interval = 1 },
    );
    defer checkpointed.deinit();
    var linear = try Animation.initWithOptions(
        std.testing.allocator,
        "linear",
        10,
        &.{.{ .translations = &keys }},
        .{ .iframe_interval = null },
    );
    defer linear.deinit();
    try std.testing.expect(checkpointed.memorySize() > linear.memorySize());

    var checkpoint_context = try SamplingContext.init(std.testing.allocator, 1);
    defer checkpoint_context.deinit();
    var linear_context = try SamplingContext.init(std.testing.allocator, 1);
    defer linear_context.deinit();
    var checkpoint_pose = [_]math.SoaTransform{math.SoaTransform.identity};
    var linear_pose = [_]math.SoaTransform{math.SoaTransform.identity};
    for ([_]f32{ 0.91, 0.13, 0.77, 0.31, 0.99, 0.01 }) |ratio| {
        try sample(&checkpointed, ratio, &checkpoint_context, &checkpoint_pose);
        try sample(&linear, ratio, &linear_context, &linear_pose);
        try std.testing.expectApproxEqAbs(
            math.lane(linear_pose[0].translation.x, 0),
            math.lane(checkpoint_pose[0].translation.x, 0),
            1e-6,
        );
    }
}
