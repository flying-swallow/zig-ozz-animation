// SPDX-License-Identifier: MIT
//! glTF 2.0 skeleton and animation import backed by flying-swallow/zgltf.

const std = @import("std");
const Gltf = @import("zgltf").Gltf;
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

const max_file_size = 1024 * 1024 * 1024;
const glb_magic: u32 = 0x46546c67;
const glb_json_chunk: u32 = 0x4e4f534a;
const glb_bin_chunk: u32 = 0x004e4942;

const GlbParts = struct {
    json: []align(4) const u8,
    binary: ?[]align(4) const u8,
};

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn splitGlb(source: []align(4) const u8) !?GlbParts {
    if (source.len < 4 or readU32(source, 0) != glb_magic) return null;
    if (source.len < 20 or readU32(source, 4) != 2) return Error.ParseFailed;
    const total_length: usize = readU32(source, 8);
    if (total_length != source.len) return Error.ParseFailed;

    var json: ?[]align(4) const u8 = null;
    var binary: ?[]align(4) const u8 = null;
    var offset: usize = 12;
    var chunk_index: usize = 0;
    while (offset < total_length) : (chunk_index += 1) {
        if (total_length - offset < 8) return Error.ParseFailed;
        const chunk_length: usize = readU32(source, offset);
        const chunk_type = readU32(source, offset + 4);
        const start = offset + 8;
        if (chunk_length > total_length - start) return Error.ParseFailed;
        const end = start + chunk_length;
        if (end % 4 != 0) return Error.ParseFailed;
        const chunk: []align(4) const u8 = @alignCast(source[start..end]);
        if (chunk_index == 0 and chunk_type != glb_json_chunk) return Error.ParseFailed;
        switch (chunk_type) {
            glb_json_chunk => {
                if (json != null or chunk.len < 4) return Error.ParseFailed;
                json = chunk;
            },
            glb_bin_chunk => {
                if (binary != null) return Error.ParseFailed;
                binary = chunk;
            },
            else => {},
        }
        offset = end;
    }
    return .{ .json = json orelse return Error.ParseFailed, .binary = binary };
}

const Parsed = struct {
    allocator: std.mem.Allocator,
    source: []align(4) u8,
    gltf: Gltf,
    glb_binary: ?[]align(4) const u8,

    fn init(allocator: std.mem.Allocator, bytes: []const u8) !Parsed {
        if (bytes.len < 4) return Error.ParseFailed;
        const source = try allocator.alignedAlloc(u8, .@"4", bytes.len);
        errdefer allocator.free(source);
        @memcpy(source, bytes);

        const parts = try splitGlb(source);
        const json_source: []align(4) const u8 = if (parts) |glb| glb.json else source;
        var gltf = Gltf.init(allocator);
        errdefer gltf.deinit();
        gltf.parse(json_source) catch return Error.ParseFailed;
        return .{
            .allocator = allocator,
            .source = source,
            .gltf = gltf,
            .glb_binary = if (parts) |glb| glb.binary else null,
        };
    }

    fn deinit(self: *Parsed) void {
        self.gltf.deinit();
        self.allocator.free(self.source);
    }
};

const LoadedBuffer = struct {
    bytes: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: LoadedBuffer, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
    }
};

fn decodeDataUri(allocator: std.mem.Allocator, uri: []const u8) !LoadedBuffer {
    const comma = std.mem.indexOfScalar(u8, uri, ',') orelse return Error.BufferLoadFailed;
    const metadata = uri["data:".len..comma];
    if (!std.mem.endsWith(u8, metadata, ";base64")) return Error.BufferLoadFailed;
    const encoded = uri[comma + 1 ..];
    const decoder = if (encoded.len % 4 == 0)
        std.base64.standard.Decoder
    else
        std.base64.standard_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch
        return Error.BufferLoadFailed;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    decoder.decode(decoded, encoded) catch return Error.BufferLoadFailed;
    return .{ .bytes = decoded, .owned = decoded };
}

fn loadExternalBuffer(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    uri: []const u8,
) !LoadedBuffer {
    const decoded_storage = try allocator.dupe(u8, uri);
    defer allocator.free(decoded_storage);
    const decoded = std.Uri.percentDecodeInPlace(decoded_storage);
    if (std.mem.indexOf(u8, decoded, "://") != null or
        std.mem.startsWith(u8, decoded, "//"))
    {
        return Error.BufferLoadFailed;
    }

    const full_path = if (std.fs.path.isAbsolute(decoded))
        try allocator.dupe(u8, decoded)
    else
        try std.fs.path.join(allocator, &.{ std.fs.path.dirname(source_path) orelse ".", decoded });
    defer allocator.free(full_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        full_path,
        allocator,
        .limited(max_file_size),
    ) catch return Error.BufferLoadFailed;
    return .{ .bytes = bytes, .owned = bytes };
}

fn loadBuffer(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    glb_binary: ?[]align(4) const u8,
    buffer_index: usize,
    buffer: Gltf.Buffer,
) !LoadedBuffer {
    var loaded = if (buffer.uri) |uri|
        if (std.mem.startsWith(u8, uri, "data:"))
            try decodeDataUri(allocator, uri)
        else
            try loadExternalBuffer(allocator, io, source_path, uri)
    else if (glb_binary) |binary| glb: {
        if (buffer_index != 0) return Error.BufferLoadFailed;
        break :glb LoadedBuffer{ .bytes = binary };
    } else return Error.BufferLoadFailed;
    errdefer loaded.deinit(allocator);
    if (loaded.bytes.len < buffer.byte_length) return Error.BufferLoadFailed;
    loaded.bytes = loaded.bytes[0..buffer.byte_length];
    return loaded;
}

const ParsedFile = struct {
    allocator: std.mem.Allocator,
    parsed: Parsed,
    buffers: []LoadedBuffer,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) !ParsedFile {
        const bytes = std.Io.Dir.cwd().readFileAllocOptions(
            io,
            path,
            allocator,
            .limited(max_file_size),
            .@"4",
            null,
        ) catch return Error.ParseFailed;
        defer allocator.free(bytes);
        var parsed = try Parsed.init(allocator, bytes);
        errdefer parsed.deinit();

        const buffers = try allocator.alloc(LoadedBuffer, parsed.gltf.data.buffers.len);
        var initialized: usize = 0;
        errdefer {
            for (buffers[0..initialized]) |buffer| buffer.deinit(allocator);
            allocator.free(buffers);
        }
        for (parsed.gltf.data.buffers, 0..) |buffer, index| {
            buffers[index] = try loadBuffer(
                allocator,
                io,
                path,
                parsed.glb_binary,
                index,
                buffer,
            );
            initialized += 1;
        }
        return .{ .allocator = allocator, .parsed = parsed, .buffers = buffers };
    }

    fn deinit(self: *ParsedFile) void {
        for (self.buffers) |buffer| buffer.deinit(self.allocator);
        self.allocator.free(self.buffers);
        self.parsed.deinit();
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
        .translation = .{ m[12], m[13], m[14] },
        .rotation = math.Quaternion.normalize(q),
        .scale = .{ sx, sy, sz },
    };
}

fn localTransform(node: Gltf.Node) math.Transform {
    if (node.matrix) |matrix| return decompose(matrix);
    return .{
        .translation = .{ node.translation[0], node.translation[1], node.translation[2] },
        .rotation = math.Quaternion.normalize(.{
            .x = node.rotation[0],
            .y = node.rotation[1],
            .z = node.rotation[2],
            .w = node.rotation[3],
        }),
        .scale = .{ node.scale[0], node.scale[1], node.scale[2] },
    };
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

fn nodeName(allocator: std.mem.Allocator, node: Gltf.Node, index: usize) ![]u8 {
    if (node.name) |name| return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "joint_{d}", .{index});
}

fn buildJoint(
    allocator: std.mem.Allocator,
    data: *const Gltf.Data,
    joints: []const usize,
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
        children[initialized] = try buildJoint(allocator, data, joints, parents, child_index);
        initialized += 1;
    }
    const node_index = joints[joint_index];
    return .{
        .name = try nodeName(allocator, data.nodes[node_index], node_index),
        .transform = localTransform(data.nodes[node_index]),
        .children = children,
    };
}

fn nodeParents(allocator: std.mem.Allocator, data: *const Gltf.Data) ![]i32 {
    if (data.nodes.len > std.math.maxInt(i32)) return Error.InvalidNode;
    const parents = try allocator.alloc(i32, data.nodes.len);
    errdefer allocator.free(parents);
    @memset(parents, -1);
    for (data.nodes, 0..) |node, parent_index| {
        for (node.children) |child_index| {
            if (child_index >= data.nodes.len or parents[child_index] != -1) {
                return Error.InvalidHierarchy;
            }
            parents[child_index] = @intCast(parent_index);
        }
    }
    return parents;
}

pub fn importSkeleton(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    skin_index: usize,
) !offline.RawSkeleton {
    var parsed = try Parsed.init(allocator, source_bytes);
    defer parsed.deinit();
    const data = &parsed.gltf.data;

    var all_nodes: ?[]usize = null;
    defer if (all_nodes) |nodes| allocator.free(nodes);
    const joints: []const usize = if (data.skins.len == 0) fallback: {
        if (skin_index != 0 or data.nodes.len == 0) return Error.MissingSkin;
        const nodes = try allocator.alloc(usize, data.nodes.len);
        for (nodes, 0..) |*node, i| node.* = i;
        all_nodes = nodes;
        break :fallback nodes;
    } else skin: {
        if (skin_index >= data.skins.len) return Error.MissingSkin;
        const selected = data.skins[skin_index];
        if (selected.joints.len == 0) return Error.MissingSkin;
        break :skin selected.joints;
    };

    const node_parents = try nodeParents(allocator, data);
    defer allocator.free(node_parents);
    const node_to_joint = try allocator.alloc(i32, data.nodes.len);
    defer allocator.free(node_to_joint);
    @memset(node_to_joint, -1);
    for (joints, 0..) |node_index, joint_index| {
        if (node_index >= data.nodes.len or node_to_joint[node_index] != -1) {
            return Error.InvalidNode;
        }
        node_to_joint[node_index] = @intCast(joint_index);
    }

    const parents = try allocator.alloc(i32, joints.len);
    defer allocator.free(parents);
    for (joints, 0..) |node_index, joint_index| {
        var parent_index = node_parents[node_index];
        var hops: usize = 0;
        while (parent_index >= 0 and node_to_joint[@intCast(parent_index)] < 0) {
            if (hops >= data.nodes.len) return Error.InvalidHierarchy;
            hops += 1;
            parent_index = node_parents[@intCast(parent_index)];
        }
        if (hops >= data.nodes.len) return Error.InvalidHierarchy;
        parents[joint_index] = if (parent_index >= 0)
            node_to_joint[@intCast(parent_index)]
        else
            -1;
    }
    for (0..joints.len) |joint_index| {
        var ancestor: i32 = @intCast(joint_index);
        var hops: usize = 0;
        while (ancestor >= 0) : (hops += 1) {
            if (hops >= joints.len) return Error.InvalidHierarchy;
            ancestor = parents[@intCast(ancestor)];
        }
    }

    const root_count = countParent(parents, -1);
    if (root_count == 0) return Error.InvalidHierarchy;
    const roots = try allocator.alloc(offline.RawJoint, root_count);
    var initialized: usize = 0;
    errdefer {
        for (roots[0..initialized]) |*root| deinitJoint(allocator, root);
        allocator.free(roots);
    }
    for (parents, 0..) |parent, joint_index| {
        if (parent != -1) continue;
        roots[initialized] = try buildJoint(allocator, data, joints, parents, joint_index);
        initialized += 1;
    }
    return .{ .allocator = allocator, .roots = roots };
}

fn componentFloat(
    component_type: Gltf.ComponentType,
    normalized: bool,
    bytes: []const u8,
) f32 {
    return switch (component_type) {
        .byte => value: {
            const raw: i8 = @bitCast(bytes[0]);
            const result: f32 = @floatFromInt(raw);
            break :value if (normalized) @max(result / 127, -1) else result;
        },
        .unsigned_byte => value: {
            const result: f32 = @floatFromInt(bytes[0]);
            break :value if (normalized) result / 255 else result;
        },
        .short => value: {
            const raw: i16 = @bitCast(std.mem.readInt(u16, bytes[0..2], .little));
            const result: f32 = @floatFromInt(raw);
            break :value if (normalized) @max(result / 32767, -1) else result;
        },
        .unsigned_short => value: {
            const result: f32 = @floatFromInt(std.mem.readInt(u16, bytes[0..2], .little));
            break :value if (normalized) result / 65535 else result;
        },
        .unsigned_integer => value: {
            const result: f32 = @floatFromInt(std.mem.readInt(u32, bytes[0..4], .little));
            break :value if (normalized) result / 4294967295.0 else result;
        },
        .float => @bitCast(std.mem.readInt(u32, bytes[0..4], .little)),
    };
}

fn readAccessor(
    data: *const Gltf.Data,
    buffers: []const LoadedBuffer,
    accessor_index: usize,
    index: usize,
    output: []f32,
) !void {
    if (accessor_index >= data.accessors.len) return Error.InvalidAnimation;
    const accessor = data.accessors[accessor_index];
    if (index >= accessor.count or output.len != accessor.type.componentCount()) {
        return Error.InvalidAnimation;
    }
    const view_index = accessor.buffer_view orelse return Error.InvalidAnimation;
    if (view_index >= data.buffer_views.len) return Error.InvalidAnimation;
    const view = data.buffer_views[view_index];
    if (view.buffer >= buffers.len) return Error.InvalidAnimation;
    const bytes = buffers[view.buffer].bytes;
    if (view.byte_offset > bytes.len or view.byte_length > bytes.len - view.byte_offset) {
        return Error.InvalidAnimation;
    }

    const component_size = accessor.component_type.byteSize();
    const component_count = accessor.type.componentCount();
    if (component_count > std.math.maxInt(usize) / component_size) {
        return Error.InvalidAnimation;
    }
    const element_size = component_count * component_size;
    const stride = view.byte_stride orelse element_size;
    if (stride < element_size or accessor.byte_offset > view.byte_length) {
        return Error.InvalidAnimation;
    }
    const available = view.byte_length - accessor.byte_offset;
    if (element_size > available or index > (available - element_size) / stride) {
        return Error.InvalidAnimation;
    }
    const start = view.byte_offset + accessor.byte_offset + index * stride;
    for (output, 0..) |*value, component| {
        const component_start = start + component * component_size;
        value.* = componentFloat(
            accessor.component_type,
            accessor.normalized,
            bytes[component_start..][0..component_size],
        );
    }
}

fn channelJoint(
    allocator: std.mem.Allocator,
    data: *const Gltf.Data,
    skeleton: @import("animation.zig").Skeleton,
    node_index: usize,
) !?usize {
    if (node_index >= data.nodes.len) return Error.InvalidAnimation;
    if (data.nodes[node_index].name) |name| {
        return @import("animation.zig").findJoint(skeleton, name);
    }
    const generated = try std.fmt.allocPrint(allocator, "joint_{d}", .{node_index});
    defer allocator.free(generated);
    return @import("animation.zig").findJoint(skeleton, generated);
}

fn animationName(allocator: std.mem.Allocator, value: Gltf.Animation, index: usize) ![]u8 {
    if (value.name) |name| {
        if (name.len != 0) return allocator.dupe(u8, name);
    }
    return std.fmt.allocPrint(allocator, "animation_{d}", .{index});
}

pub const AnimationImportOptions = struct {
    /// glTF has no scene frame rate. Upstream Ozz uses 30 Hz when automatic
    /// sampling is requested, so non-positive values select 30 Hz here too.
    sampling_rate: f32 = 0,
    /// Uses a process-wide blocking implementation when omitted.
    io: ?std.Io = null,
};

fn readChannelValue(
    comptime T: type,
    data: *const Gltf.Data,
    buffers: []const LoadedBuffer,
    accessor_index: usize,
    index: usize,
) !T {
    if (T == math.Vec3f32) {
        var value: [3]f32 = undefined;
        try readAccessor(data, buffers, accessor_index, index, &value);
        return .{ value[0], value[1], value[2] };
    }
    if (T == math.Quaternion) {
        var value: [4]f32 = undefined;
        try readAccessor(data, buffers, accessor_index, index, &value);
        return .{ .x = value[0], .y = value[1], .z = value[2], .w = value[3] };
    }
    @compileError("unsupported glTF animation channel type");
}

fn addValue(comptime T: type, a: T, b: T) T {
    if (T == math.Vec3f32) return math.vec.add(a, b);
    if (T == math.Quaternion) return .{
        .x = a.x + b.x,
        .y = a.y + b.y,
        .z = a.z + b.z,
        .w = a.w + b.w,
    };
    @compileError("unsupported glTF animation channel type");
}

fn scaleValue(comptime T: type, value: T, scale: f32) T {
    if (T == math.Vec3f32) return math.vec.scale(value, scale);
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
    data: *const Gltf.Data,
    buffers: []const LoadedBuffer,
    sampler: Gltf.AnimationSampler,
    sampling_rate: f32,
) ![]Key {
    if (sampler.input >= data.accessors.len or sampler.output >= data.accessors.len) {
        return Error.InvalidAnimation;
    }
    const input = data.accessors[sampler.input];
    const output = data.accessors[sampler.output];
    const count = input.count;
    if (count == 0) return allocator.alloc(Key, 0);

    const timestamps = try allocator.alloc(f32, count);
    defer allocator.free(timestamps);
    for (timestamps, 0..) |*time, i| {
        var value: [1]f32 = undefined;
        try readAccessor(data, buffers, sampler.input, i, &value);
        time.* = value[0];
    }

    switch (sampler.interpolation) {
        .linear => {
            if (output.count != count) return Error.InvalidAnimation;
            const keys = try allocator.alloc(Key, count);
            for (keys, 0..) |*key, i| key.* = .{
                .time = timestamps[i],
                .value = try readChannelValue(T, data, buffers, sampler.output, i),
            };
            return keys;
        },
        .step => {
            if (output.count != count or count > std.math.maxInt(usize) / 2 + 1) {
                return Error.InvalidAnimation;
            }
            const keys = try allocator.alloc(Key, count * 2 - 1);
            for (0..count) |i| {
                const value = try readChannelValue(T, data, buffers, sampler.output, i);
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
        .cubicspline => {
            if (count < 2 or count > std.math.maxInt(usize) / 3 or output.count != count * 3) {
                return Error.InvalidAnimation;
            }
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
                const p0 = try readChannelValue(T, data, buffers, sampler.output, left * 3 + 1);
                const m0 = scaleValue(T, try readChannelValue(T, data, buffers, sampler.output, left * 3 + 2), interval);
                const p1 = try readChannelValue(T, data, buffers, sampler.output, (left + 1) * 3 + 1);
                const m1 = scaleValue(T, try readChannelValue(T, data, buffers, sampler.output, (left + 1) * 3), interval);
                key.* = .{ .time = time, .value = hermiteValue(T, alpha, p0, m0, p1, m1) };
            }
            return keys;
        },
    }
}

/// Imports all glTF animation clips from a file. The path is used to resolve
/// external buffer URIs relative to the source asset.
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
    const io = options.io orelse std.Io.Threaded.global_single_threaded.io();
    var parsed = try ParsedFile.init(allocator, io, source_path);
    defer parsed.deinit();
    const data = &parsed.parsed.gltf.data;
    if (data.animations.len == 0) return Error.MissingAnimation;

    const output = try allocator.alloc(offline.RawAnimation, data.animations.len);
    var initialized: usize = 0;
    errdefer {
        for (output[0..initialized]) |*clip| clip.deinit();
        allocator.free(output);
    }

    for (data.animations, 0..) |gltf_animation, animation_index| {
        var duration: f32 = 0;
        for (gltf_animation.samplers) |sampler| {
            if (sampler.input >= data.accessors.len or sampler.output >= data.accessors.len) {
                return Error.InvalidAnimation;
            }
            for (0..data.accessors[sampler.input].count) |key| {
                var time: [1]f32 = undefined;
                try readAccessor(data, parsed.buffers, sampler.input, key, &time);
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

        for (gltf_animation.channels) |channel| {
            if (channel.sampler >= gltf_animation.samplers.len) return Error.InvalidAnimation;
            const joint = try channelJoint(
                allocator,
                data,
                skeleton,
                channel.target.node,
            ) orelse continue;
            const sampler = gltf_animation.samplers[channel.sampler];
            switch (channel.target.property) {
                .translation => {
                    if (clip.tracks[joint].translations.len != 0) return Error.InvalidAnimation;
                    clip.tracks[joint].translations = try sampleChannel(
                        math.Vec3f32,
                        offline.TranslationKey,
                        allocator,
                        data,
                        parsed.buffers,
                        sampler,
                        sampling_rate,
                    );
                },
                .rotation => {
                    if (clip.tracks[joint].rotations.len != 0) return Error.InvalidAnimation;
                    clip.tracks[joint].rotations = try sampleChannel(
                        math.Quaternion,
                        offline.RotationKey,
                        allocator,
                        data,
                        parsed.buffers,
                        sampler,
                        sampling_rate,
                    );
                    for (clip.tracks[joint].rotations) |*key| {
                        key.value = math.Quaternion.normalize(key.value);
                    }
                },
                .scale => {
                    if (clip.tracks[joint].scales.len != 0) return Error.InvalidAnimation;
                    clip.tracks[joint].scales = try sampleChannel(
                        math.Vec3f32,
                        offline.ScaleKey,
                        allocator,
                        data,
                        parsed.buffers,
                        sampler,
                        sampling_rate,
                    );
                },
                .weights => {},
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

test "imports a glTF skin hierarchy through zgltf" {
    const source =
        \\{"asset":{"version":"2.0"},"nodes":[{"name":"root","children":[1]},{"name":"hand","translation":[1,2,3]}],"skins":[{"joints":[0,1]}]}
    ;
    var skeleton = try importSkeleton(std.testing.allocator, source, 0);
    defer skeleton.deinit();
    try std.testing.expectEqual(@as(usize, 1), skeleton.roots.len);
    try std.testing.expectEqualStrings("hand", skeleton.roots[0].children[0].name);
    try std.testing.expectEqual(@as(f32, 2), skeleton.roots[0].children[0].transform.translation[1]);
}
