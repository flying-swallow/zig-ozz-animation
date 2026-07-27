// SPDX-License-Identifier: GPL-2.0-only
//! glTF 2.0 skeleton import backed by flying-swallow/cglf.

const std = @import("std");
const cgltf = @import("cgltf");
const c = cgltf.c;
const math = @import("math.zig");
const offline = @import("offline.zig");

pub const Error = error{
    ParseFailed,
    BufferLoadFailed,
    MissingSkin,
    MissingAnimation,
    InvalidNode,
    InvalidHierarchy,
    InvalidAnimation,
};

const Parsed = struct {
    data: *c.cgltf_data,

    fn init(bytes: []const u8) !Parsed {
        var options: c.cgltf_options = std.mem.zeroes(c.cgltf_options);
        var data: ?*c.cgltf_data = null;
        const result = c.cgltf_parse(&options, bytes.ptr, bytes.len, &data);
        if (result != c.cgltf_result_success or data == null) return Error.ParseFailed;
        return .{ .data = data.? };
    }

    fn deinit(self: Parsed) void {
        c.cgltf_free(self.data);
    }
};

const ParsedFile = struct {
    data: *c.cgltf_data,

    fn init(allocator: std.mem.Allocator, path: []const u8) !ParsedFile {
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);
        var options: c.cgltf_options = std.mem.zeroes(c.cgltf_options);
        var data: ?*c.cgltf_data = null;
        if (c.cgltf_parse_file(&options, path_z.ptr, &data) != c.cgltf_result_success or data == null) {
            return Error.ParseFailed;
        }
        errdefer c.cgltf_free(data.?);
        if (c.cgltf_load_buffers(&options, data.?, path_z.ptr) != c.cgltf_result_success) {
            return Error.BufferLoadFailed;
        }
        return .{ .data = data.? };
    }

    fn deinit(self: ParsedFile) void {
        c.cgltf_free(self.data);
    }
};

fn decompose(m: [16]f32) math.Transform {
    const sx = @sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]);
    const sy = @sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6]);
    const sz = @sqrt(m[8] * m[8] + m[9] * m[9] + m[10] * m[10]);
    const r00 = if (sx != 0) m[0] / sx else 1;
    const r01 = if (sy != 0) m[4] / sy else 0;
    const r02 = if (sz != 0) m[8] / sz else 0;
    const r10 = if (sx != 0) m[1] / sx else 0;
    const r11 = if (sy != 0) m[5] / sy else 1;
    const r12 = if (sz != 0) m[9] / sz else 0;
    const r20 = if (sx != 0) m[2] / sx else 0;
    const r21 = if (sy != 0) m[6] / sy else 0;
    const r22 = if (sz != 0) m[10] / sz else 1;
    const trace = r00 + r11 + r22;
    var q: math.Quaternion = undefined;
    if (trace > 0) {
        const root = @sqrt(trace + 1) * 2;
        q = .{ .x = (r21 - r12) / root, .y = (r02 - r20) / root, .z = (r10 - r01) / root, .w = root * 0.25 };
    } else if (r00 > r11 and r00 > r22) {
        const root = @sqrt(1 + r00 - r11 - r22) * 2;
        q = .{ .x = root * 0.25, .y = (r01 + r10) / root, .z = (r02 + r20) / root, .w = (r21 - r12) / root };
    } else if (r11 > r22) {
        const root = @sqrt(1 + r11 - r00 - r22) * 2;
        q = .{ .x = (r01 + r10) / root, .y = root * 0.25, .z = (r12 + r21) / root, .w = (r02 - r20) / root };
    } else {
        const root = @sqrt(1 + r22 - r00 - r11) * 2;
        q = .{ .x = (r02 + r20) / root, .y = (r12 + r21) / root, .z = root * 0.25, .w = (r10 - r01) / root };
    }
    return .{
        .translation = .{ .x = m[12], .y = m[13], .z = m[14] },
        .rotation = math.Quaternion.normalize(q),
        .scale = .{ .x = sx, .y = sy, .z = sz },
    };
}

fn localTransform(node: [*c]const c.cgltf_node) math.Transform {
    var matrix: [16]c.cgltf_float = undefined;
    c.cgltf_node_transform_local(node, &matrix);
    return decompose(matrix);
}

fn deinitJoint(allocator: std.mem.Allocator, joint: *offline.RawJoint) void {
    for (joint.children) |*child| deinitJoint(allocator, child);
    allocator.free(joint.children);
    allocator.free(joint.name);
}

fn countParent(parents: []const i32, expected: i32) usize {
    var count: usize = 0;
    for (parents) |parent| if (parent == expected) {
        count += 1;
    };
    return count;
}

fn nodeName(allocator: std.mem.Allocator, node: [*c]const c.cgltf_node, index: usize) ![]u8 {
    if (node.*.name != null) return allocator.dupe(u8, std.mem.span(node.*.name));
    return std.fmt.allocPrint(allocator, "joint_{d}", .{index});
}

fn buildJoint(
    allocator: std.mem.Allocator,
    joints: []const [*c]c.cgltf_node,
    parents: []const i32,
    joint_index: usize,
) !offline.RawJoint {
    const children = try allocator.alloc(offline.RawJoint, countParent(parents, @intCast(joint_index)));
    var initialized: usize = 0;
    errdefer {
        for (children[0..initialized]) |*child| deinitJoint(allocator, child);
        allocator.free(children);
    }
    for (parents, 0..) |parent, child_index| {
        if (parent != joint_index) continue;
        children[initialized] = try buildJoint(allocator, joints, parents, child_index);
        initialized += 1;
    }
    return .{
        .name = try nodeName(allocator, joints[joint_index], joint_index),
        .transform = localTransform(joints[joint_index]),
        .children = children,
    };
}

pub fn importSkeleton(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    skin_index: usize,
) !offline.RawSkeleton {
    const parsed = try Parsed.init(source_bytes);
    defer parsed.deinit();
    const data = parsed.data;
    var all_nodes: ?[][*c]c.cgltf_node = null;
    defer if (all_nodes) |nodes| allocator.free(nodes);
    const joints: []const [*c]c.cgltf_node = if (data.skins_count == 0) fallback: {
        if (skin_index != 0 or data.nodes_count == 0) return Error.MissingSkin;
        const nodes = try allocator.alloc([*c]c.cgltf_node, data.nodes_count);
        for (nodes, 0..) |*node, i| node.* = &data.nodes[i];
        all_nodes = nodes;
        break :fallback nodes;
    } else skin: {
        if (skin_index >= data.skins_count) return Error.MissingSkin;
        const selected = &data.skins[skin_index];
        if (selected.joints_count == 0) return Error.MissingSkin;
        break :skin selected.joints[0..selected.joints_count];
    };

    const node_to_joint = try allocator.alloc(i32, data.nodes_count);
    defer allocator.free(node_to_joint);
    @memset(node_to_joint, -1);
    for (joints, 0..) |joint_node, joint_index| {
        const node_index = c.cgltf_node_index(data, joint_node);
        if (node_index >= data.nodes_count or node_to_joint[node_index] != -1) return Error.InvalidNode;
        node_to_joint[node_index] = @intCast(joint_index);
    }

    const parents = try allocator.alloc(i32, joints.len);
    defer allocator.free(parents);
    for (joints, 0..) |joint_node, joint_index| {
        var parent = joint_node.*.parent;
        while (parent != null) {
            const parent_index = c.cgltf_node_index(data, parent);
            if (parent_index >= data.nodes_count) return Error.InvalidHierarchy;
            if (node_to_joint[parent_index] >= 0) break;
            parent = parent.*.parent;
        }
        parents[joint_index] = if (parent != null)
            node_to_joint[c.cgltf_node_index(data, parent)]
        else
            -1;
    }

    const roots = try allocator.alloc(offline.RawJoint, countParent(parents, -1));
    var initialized: usize = 0;
    errdefer {
        for (roots[0..initialized]) |*root| deinitJoint(allocator, root);
        allocator.free(roots);
    }
    for (parents, 0..) |parent, joint_index| {
        if (parent != -1) continue;
        roots[initialized] = try buildJoint(allocator, joints, parents, joint_index);
        initialized += 1;
    }
    return .{ .allocator = allocator, .roots = roots };
}

fn readAccessor(accessor: [*c]const c.cgltf_accessor, index: usize, output: []f32) !void {
    if (c.cgltf_accessor_read_float(accessor, index, output.ptr, output.len) == 0) {
        return Error.InvalidAnimation;
    }
}

fn channelJoint(
    allocator: std.mem.Allocator,
    data: [*c]const c.cgltf_data,
    skeleton: @import("animation.zig").Skeleton,
    node: [*c]const c.cgltf_node,
) !?usize {
    if (node.*.name != null) {
        return @import("animation.zig").findJoint(skeleton, std.mem.span(node.*.name));
    }
    const node_index = c.cgltf_node_index(data, node);
    const generated = try std.fmt.allocPrint(allocator, "joint_{d}", .{node_index});
    defer allocator.free(generated);
    return @import("animation.zig").findJoint(skeleton, generated);
}

fn animationName(allocator: std.mem.Allocator, value: [*c]const c.cgltf_animation, index: usize) ![]u8 {
    if (value.*.name != null and std.mem.span(value.*.name).len != 0) {
        return allocator.dupe(u8, std.mem.span(value.*.name));
    }
    return std.fmt.allocPrint(allocator, "animation_{d}", .{index});
}

pub const AnimationImportOptions = struct {
    /// glTF has no scene frame rate. Upstream Ozz uses 30 Hz when automatic
    /// sampling is requested, so non-positive values select 30 Hz here too.
    sampling_rate: f32 = 0,
};

fn readChannelValue(comptime T: type, accessor: [*c]const c.cgltf_accessor, index: usize) !T {
    if (T == math.Float3) {
        var value: [3]f32 = undefined;
        try readAccessor(accessor, index, &value);
        return .{ .x = value[0], .y = value[1], .z = value[2] };
    }
    if (T == math.Quaternion) {
        var value: [4]f32 = undefined;
        try readAccessor(accessor, index, &value);
        return .{ .x = value[0], .y = value[1], .z = value[2], .w = value[3] };
    }
    @compileError("unsupported glTF animation channel type");
}

fn addValue(comptime T: type, a: T, b: T) T {
    if (T == math.Float3) return math.Float3.add(a, b);
    if (T == math.Quaternion) return .{
        .x = a.x + b.x,
        .y = a.y + b.y,
        .z = a.z + b.z,
        .w = a.w + b.w,
    };
    @compileError("unsupported glTF animation channel type");
}

fn scaleValue(comptime T: type, value: T, scale: f32) T {
    if (T == math.Float3) return math.Float3.scale(value, scale);
    if (T == math.Quaternion) return .{
        .x = value.x * scale,
        .y = value.y * scale,
        .z = value.z * scale,
        .w = value.w * scale,
    };
    @compileError("unsupported glTF animation channel type");
}

fn hermiteValue(comptime T: type, alpha: f32, p0: T, m0: T, p1: T, m1: T) T {
    const t2 = alpha * alpha;
    const t3 = t2 * alpha;
    return addValue(T, addValue(T, scaleValue(T, p0, 2 * t3 - 3 * t2 + 1), scaleValue(T, m0, t3 - 2 * t2 + alpha)), addValue(T, scaleValue(T, p1, -2 * t3 + 3 * t2), scaleValue(T, m1, t3 - t2)));
}

fn sampleChannel(
    comptime T: type,
    comptime Key: type,
    allocator: std.mem.Allocator,
    sampler: [*c]const c.cgltf_animation_sampler,
    sampling_rate: f32,
) ![]Key {
    const input = sampler.*.input orelse return Error.InvalidAnimation;
    const output = sampler.*.output orelse return Error.InvalidAnimation;
    const count = input.*.count;
    if (count == 0) return allocator.alloc(Key, 0);

    const timestamps = try allocator.alloc(f32, count);
    defer allocator.free(timestamps);
    for (timestamps, 0..) |*time, i| {
        var value: [1]f32 = undefined;
        try readAccessor(input, i, &value);
        time.* = value[0];
    }

    switch (sampler.*.interpolation) {
        c.cgltf_interpolation_type_linear => {
            if (output.*.count != count) return Error.InvalidAnimation;
            const keys = try allocator.alloc(Key, count);
            for (keys, 0..) |*key, i| key.* = .{
                .time = timestamps[i],
                .value = try readChannelValue(T, output, i),
            };
            return keys;
        },
        c.cgltf_interpolation_type_step => {
            if (output.*.count != count) return Error.InvalidAnimation;
            const keys = try allocator.alloc(Key, count * 2 - 1);
            for (0..count) |i| {
                const value = try readChannelValue(T, output, i);
                keys[i * 2] = .{ .time = timestamps[i], .value = value };
                if (i + 1 < count) {
                    keys[i * 2 + 1] = .{
                        .time = std.math.nextAfter(f32, timestamps[i + 1], 0),
                        .value = value,
                    };
                }
            }
            return keys;
        },
        c.cgltf_interpolation_type_cubic_spline => {
            if (count < 2 or output.*.count != count * 3) return Error.InvalidAnimation;
            const start = timestamps[0];
            const span = timestamps[count - 1] - start;
            const fixed = offline.FixedRateSamplingTime.init(span, sampling_rate) catch
                return Error.InvalidAnimation;
            const keys = try allocator.alloc(Key, fixed.numKeys());
            var left: usize = 0;
            for (keys, 0..) |*key, i| {
                const time = fixed.time(i) + start;
                while (left + 2 < count and timestamps[left + 1] < time) left += 1;
                const t0 = timestamps[left];
                const t1 = timestamps[left + 1];
                if (!(t1 > t0)) return Error.InvalidAnimation;
                const alpha = (time - t0) / (t1 - t0);
                const interval = t1 - t0;
                const p0 = try readChannelValue(T, output, left * 3 + 1);
                const m0 = scaleValue(T, try readChannelValue(T, output, left * 3 + 2), interval);
                const p1 = try readChannelValue(T, output, (left + 1) * 3 + 1);
                const m1 = scaleValue(T, try readChannelValue(T, output, (left + 1) * 3), interval);
                key.* = .{ .time = time, .value = hermiteValue(T, alpha, p0, m0, p1, m1) };
            }
            return keys;
        },
        else => return Error.InvalidAnimation,
    }
}

/// Imports all glTF animation clips from a file. Unlike `importSkeleton`, this
/// entry point accepts a path so cgltf can resolve external buffer URIs.
pub fn importAnimationsFile(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    skeleton: @import("animation.zig").Skeleton,
) ![]offline.RawAnimation {
    return importAnimationsFileWithOptions(allocator, source_path, skeleton, .{});
}

pub fn importAnimationsFileWithOptions(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    skeleton: @import("animation.zig").Skeleton,
    options: AnimationImportOptions,
) ![]offline.RawAnimation {
    const sampling_rate = if (options.sampling_rate > 0) options.sampling_rate else 30;
    if (!std.math.isFinite(sampling_rate)) return Error.InvalidAnimation;
    const parsed = try ParsedFile.init(allocator, source_path);
    defer parsed.deinit();
    const data = parsed.data;
    if (data.animations_count == 0) return Error.MissingAnimation;

    const output = try allocator.alloc(offline.RawAnimation, data.animations_count);
    var initialized: usize = 0;
    errdefer {
        for (output[0..initialized]) |*clip| clip.deinit();
        allocator.free(output);
    }

    for (data.animations[0..data.animations_count], 0..) |*gltf_animation, animation_index| {
        var duration: f32 = 0;
        for (gltf_animation.samplers[0..gltf_animation.samplers_count]) |sampler| {
            if (sampler.input == null or sampler.output == null) return Error.InvalidAnimation;
            for (0..sampler.input.*.count) |key| {
                var time: [1]f32 = undefined;
                try readAccessor(sampler.input, key, &time);
                if (!std.math.isFinite(time[0]) or time[0] < 0) return Error.InvalidAnimation;
                duration = @max(duration, time[0]);
            }
        }
        if (!(duration > 0)) duration = 1;
        const name = try animationName(allocator, gltf_animation, animation_index);
        defer allocator.free(name);
        output[initialized] = try offline.RawAnimation.init(
            allocator,
            name,
            duration,
            skeleton.numJoints(),
        );
        const clip = &output[initialized];
        initialized += 1;

        for (gltf_animation.channels[0..gltf_animation.channels_count]) |channel| {
            if (channel.sampler == null or channel.target_node == null) continue;
            const joint = try channelJoint(allocator, data, skeleton, channel.target_node) orelse continue;
            const sampler = channel.sampler;
            switch (channel.target_path) {
                c.cgltf_animation_path_type_translation => {
                    if (clip.tracks[joint].translations.len != 0) return Error.InvalidAnimation;
                    clip.tracks[joint].translations = try sampleChannel(
                        math.Float3,
                        offline.TranslationKey,
                        allocator,
                        sampler,
                        sampling_rate,
                    );
                },
                c.cgltf_animation_path_type_rotation => {
                    if (clip.tracks[joint].rotations.len != 0) return Error.InvalidAnimation;
                    clip.tracks[joint].rotations = try sampleChannel(
                        math.Quaternion,
                        offline.RotationKey,
                        allocator,
                        sampler,
                        sampling_rate,
                    );
                    for (clip.tracks[joint].rotations) |*key| {
                        key.value = math.Quaternion.normalize(key.value);
                    }
                },
                c.cgltf_animation_path_type_scale => {
                    if (clip.tracks[joint].scales.len != 0) return Error.InvalidAnimation;
                    clip.tracks[joint].scales = try sampleChannel(
                        math.Float3,
                        offline.ScaleKey,
                        allocator,
                        sampler,
                        sampling_rate,
                    );
                },
                else => {},
            }
        }
        for (clip.tracks, 0..) |*track, joint| {
            const rest = skeleton.jointRestPose(joint);
            if (track.translations.len == 0) {
                track.translations = try allocator.dupe(offline.TranslationKey, &.{
                    .{ .time = 0, .value = rest.translation },
                });
            }
            if (track.rotations.len == 0) {
                track.rotations = try allocator.dupe(offline.RotationKey, &.{
                    .{ .time = 0, .value = rest.rotation },
                });
            }
            if (track.scales.len == 0) {
                track.scales = try allocator.dupe(offline.ScaleKey, &.{
                    .{ .time = 0, .value = rest.scale },
                });
            }
        }
        if (!clip.validate()) return Error.InvalidAnimation;
    }
    return output;
}

pub fn deinitAnimations(allocator: std.mem.Allocator, animations: []offline.RawAnimation) void {
    for (animations) |*animation| animation.deinit();
    allocator.free(animations);
}

test "imports a glTF skin hierarchy through cglf" {
    const source =
        \\{"asset":{"version":"2.0"},"nodes":[{"name":"root","children":[1]},{"name":"hand","translation":[1,2,3]}],"skins":[{"joints":[0,1]}]}
    ;
    var skeleton = try importSkeleton(std.testing.allocator, source, 0);
    defer skeleton.deinit();
    try std.testing.expectEqual(@as(usize, 1), skeleton.roots.len);
    try std.testing.expectEqualStrings("hand", skeleton.roots[0].children[0].name);
    try std.testing.expectEqual(@as(f32, 2), skeleton.roots[0].children[0].transform.translation.y);
}
