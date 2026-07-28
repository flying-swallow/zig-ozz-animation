//! Reader for the tagged binary archives produced by ozz-animation 0.16.
//!
//! This module is intentionally isolated from the native `.zozz` codec. Legacy
//! archives are host-object dumps with explicit endianness; native archives
//! have a bounded, stable schema.

const std = @import("std");
const math = @import("math.zig");
const serialization = @import("serialization.zig");
const animation = @import("animation.zig");
const offline = @import("offline.zig");
const geometry = @import("geometry.zig");
const native_io = @import("io.zig");

pub const Error = error{
    InvalidEndian,
    TruncatedArchive,
    UnknownTag,
    UnexpectedTag,
    UnsupportedVersion,
    InvalidLength,
    InvalidData,
    TrailingData,
};

pub const Limits = struct {
    max_string_bytes: u32 = 16 * 1024 * 1024,
    max_collection_items: u32 = 16 * 1024 * 1024,
    max_depth: u16 = 1024,
};

pub const WriteOptions = struct {
    endian: std.builtin.Endian = .little,
};

pub const Kind = enum {
    skeleton,
    animation,
    float_track,
    float2_track,
    float3_track,
    float4_track,
    quaternion_track,
    raw_skeleton,
    raw_animation,
    raw_float_track,
    raw_float2_track,
    raw_float3_track,
    raw_float4_track,
    raw_quaternion_track,
    sample_mesh_part,
    sample_mesh,

    pub fn nativeKind(self: Kind) native_io.ObjectKind {
        return switch (self) {
            .skeleton => .skeleton,
            .animation => .animation,
            .float_track => .float_track,
            .float2_track => .float2_track,
            .float3_track => .float3_track,
            .float4_track => .float4_track,
            .quaternion_track => .quaternion_track,
            .raw_skeleton => .raw_skeleton,
            .raw_animation => .raw_animation,
            .raw_float_track => .raw_float_track,
            .raw_float2_track => .raw_float2_track,
            .raw_float3_track => .raw_float3_track,
            .raw_float4_track => .raw_float4_track,
            .raw_quaternion_track => .raw_quaternion_track,
            .sample_mesh_part => .sample_mesh,
            .sample_mesh => .sample_mesh,
        };
    }
};

const Tag = struct { bytes: []const u8, kind: Kind };
const tags = [_]Tag{
    .{ .bytes = "ozz-skeleton\x00", .kind = .skeleton },
    .{ .bytes = "ozz-animation\x00", .kind = .animation },
    .{ .bytes = "ozz-float_track\x00", .kind = .float_track },
    .{ .bytes = "ozz-float2_track\x00", .kind = .float2_track },
    .{ .bytes = "ozz-float3_track\x00", .kind = .float3_track },
    .{ .bytes = "ozz-float4_track\x00", .kind = .float4_track },
    .{ .bytes = "ozz-quat_track\x00", .kind = .quaternion_track },
    .{ .bytes = "ozz-raw_skeleton\x00", .kind = .raw_skeleton },
    .{ .bytes = "ozz-raw_animation\x00", .kind = .raw_animation },
    .{ .bytes = "ozz-raw_float_track\x00", .kind = .raw_float_track },
    .{ .bytes = "ozz-raw_float2_track\x00", .kind = .raw_float2_track },
    .{ .bytes = "ozz-raw_float3_track\x00", .kind = .raw_float3_track },
    .{ .bytes = "ozz-raw_float4_track\x00", .kind = .raw_float4_track },
    .{ .bytes = "ozz-raw_quat_track\x00", .kind = .raw_quaternion_track },
    .{ .bytes = "ozz-sample-Mesh-Part\x00", .kind = .sample_mesh_part },
    .{ .bytes = "ozz-sample-Mesh\x00", .kind = .sample_mesh },
};

pub fn detect(bytes: []const u8) Error!Kind {
    if (bytes.len < 2 or bytes[0] > 1) return Error.InvalidEndian;
    for (tags) |tag| {
        if (bytes.len >= tag.bytes.len + 1 and
            std.mem.eql(u8, bytes[1 .. tag.bytes.len + 1], tag.bytes))
        {
            return tag.kind;
        }
    }
    return Error.UnknownTag;
}

const Reader = struct {
    stream: *std.Io.Reader,
    pos: usize = 0,
    endian: std.builtin.Endian,
    limits: Limits,

    fn init(stream: *std.Io.Reader, limits: Limits) !Reader {
        const endian_byte = stream.takeByte() catch |err| switch (err) {
            error.EndOfStream => return Error.TruncatedArchive,
            else => |e| return e,
        };
        const endian: std.builtin.Endian = switch (endian_byte) {
            0 => .big,
            1 => .little,
            else => return Error.InvalidEndian,
        };
        return .{ .stream = stream, .pos = 1, .endian = endian, .limits = limits };
    }

    fn readAll(self: *Reader, bytes: []u8) !void {
        self.stream.readSliceAll(bytes) catch |err| switch (err) {
            error.EndOfStream => return Error.TruncatedArchive,
            else => |e| return e,
        };
        self.pos += bytes.len;
    }

    fn readAlloc(self: *Reader, allocator: std.mem.Allocator, byte_count: usize) ![]u8 {
        const result = try allocator.alloc(u8, byte_count);
        errdefer allocator.free(result);
        try self.readAll(result);
        return result;
    }

    fn discard(self: *Reader, byte_count: usize) !void {
        self.stream.discardAll(byte_count) catch |err| switch (err) {
            error.EndOfStream => return Error.TruncatedArchive,
            else => |e| return e,
        };
        self.pos += byte_count;
    }

    fn expectTag(self: *Reader, expected: []const u8) !void {
        var actual: [32]u8 = undefined;
        std.debug.assert(expected.len <= actual.len);
        try self.readAll(actual[0..expected.len]);
        if (!std.mem.eql(u8, actual[0..expected.len], expected)) return Error.UnexpectedTag;
    }

    fn int(self: *Reader, comptime T: type) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.readAll(&bytes);
        return std.mem.readInt(T, &bytes, self.endian);
    }

    fn float(self: *Reader) !f32 {
        return @bitCast(try self.int(u32));
    }

    fn count(self: *Reader) !usize {
        const value = try self.int(u32);
        if (value > self.limits.max_collection_items) return Error.InvalidLength;
        return value;
    }

    fn string(self: *Reader, allocator: std.mem.Allocator) ![]u8 {
        const len = try self.int(u32);
        if (len > self.limits.max_string_bytes) return Error.InvalidLength;
        return self.readAlloc(allocator, len);
    }

    fn finish(self: *Reader) !void {
        _ = self.stream.peekByte() catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        return Error.TrailingData;
    }
};

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T, endian: std.builtin.Endian) !void {
    switch (endian) {
        .little => try writer.writeInt(T, value, .little),
        .big => try writer.writeInt(T, value, .big),
    }
}

fn writeFloat(writer: *std.Io.Writer, value: f32, endian: std.builtin.Endian) !void {
    try writeInt(writer, u32, @bitCast(value), endian);
}

/// Writes an Ozz 0.16 `Skeleton` archive (schema version 2) that can be read
/// by the upstream C++ runtime. Unlike the native `.zozz` codec, this format
/// intentionally follows Ozz's tagged, endian-selectable object layout.
pub fn writeSkeleton(
    writer: *std.Io.Writer,
    skeleton: animation.Skeleton,
    options: WriteOptions,
) !void {
    try writer.writeByte(if (options.endian == .little) 1 else 0);
    try writer.writeAll("ozz-skeleton\x00");
    try writeInt(writer, u32, 2, options.endian);
    try writeInt(writer, i32, @intCast(skeleton.numJoints()), options.endian);
    if (skeleton.numJoints() == 0) return;

    var chars_count: usize = 0;
    for (skeleton.names) |name| {
        chars_count = try std.math.add(usize, chars_count, name.len + 1);
    }
    try writeInt(writer, i32, @intCast(chars_count), options.endian);
    for (skeleton.names) |name| {
        try writer.writeAll(name);
        try writer.writeByte(0);
    }
    for (skeleton.parents) |parent| try writeInt(writer, i16, parent, options.endian);

    // Runtime rest poses are stored in the same SoA field/lane order as Ozz:
    // translation xyz, rotation xyzw, then scale xyz.
    for (skeleton.rest_poses) |pose| {
        inline for (.{
            pose.translation.x,
            pose.translation.y,
            pose.translation.z,
            pose.rotation.x,
            pose.rotation.y,
            pose.rotation.z,
            pose.rotation.w,
            pose.scale.x,
            pose.scale.y,
            pose.scale.z,
        }) |field| {
            for (0..4) |lane| try writeFloat(writer, math.lane(field, lane), options.endian);
        }
    }
}

fn readXyzw(comptime T: type, reader: *Reader) !T {
    return .{
        .x = try reader.float(),
        .y = try reader.float(),
        .z = try reader.float(),
        .w = try reader.float(),
    };
}

fn readVec2f32(reader: *Reader) !math.Vec2f32 {
    const value = serialization.readVec2f32(reader.stream, reader.endian) catch |err| switch (err) {
        error.EndOfStream => return Error.TruncatedArchive,
        else => |e| return e,
    };
    reader.pos += 2 * @sizeOf(f32);
    return value;
}

fn readVec3f32(reader: *Reader) !math.Vec3f32 {
    const value = serialization.readVec3f32(reader.stream, reader.endian) catch |err| switch (err) {
        error.EndOfStream => return Error.TruncatedArchive,
        else => |e| return e,
    };
    reader.pos += 3 * @sizeOf(f32);
    return value;
}

fn readTransform(reader: *Reader) !math.Transform {
    return .{
        .translation = try readVec3f32(reader),
        .rotation = try readXyzw(math.Quaternion, reader),
        .scale = try readVec3f32(reader),
    };
}

fn expectVersion(reader: *Reader, expected: u32) !void {
    if (try reader.int(u32) != expected) return Error.UnsupportedVersion;
}

pub fn readSkeleton(
    allocator: std.mem.Allocator,
    stream: *std.Io.Reader,
    limits: Limits,
) !animation.Skeleton {
    var reader = try Reader.init(stream, limits);
    try reader.expectTag("ozz-skeleton\x00");
    if (try reader.int(u32) != 2) return Error.UnsupportedVersion;
    const signed_count = try reader.int(i32);
    if (signed_count < 0 or signed_count > animation.max_joints) return Error.InvalidLength;
    const count: usize = @intCast(signed_count);
    if (count == 0) {
        try reader.finish();
        return animation.Skeleton.init(allocator, &.{});
    }
    const chars_count = try reader.int(i32);
    if (chars_count <= 0 or chars_count > limits.max_string_bytes) return Error.InvalidLength;
    const names_blob = try allocator.alloc(u8, @intCast(chars_count));
    defer allocator.free(names_blob);
    try reader.readAll(names_blob);

    const inputs = try allocator.alloc(animation.JointInput, count);
    defer allocator.free(inputs);
    var cursor: usize = 0;
    for (inputs) |*input| {
        const remaining = names_blob[cursor..];
        const end = std.mem.indexOfScalar(u8, remaining, 0) orelse return Error.InvalidData;
        input.* = .{ .name = remaining[0..end], .parent = 0 };
        cursor += end + 1;
    }
    if (cursor != names_blob.len) return Error.InvalidData;
    for (inputs) |*input| input.parent = try reader.int(i16);

    const soa_count = (count + 3) / 4;
    for (0..soa_count) |group| {
        var values: [40]f32 = undefined;
        for (&values) |*value| value.* = try reader.float();
        for (0..4) |lane| {
            const index = group * 4 + lane;
            if (index >= count) break;
            inputs[index].rest_pose = .{
                .translation = .{ values[lane], values[4 + lane], values[8 + lane] },
                .rotation = .{
                    .x = values[12 + lane],
                    .y = values[16 + lane],
                    .z = values[20 + lane],
                    .w = values[24 + lane],
                },
                .scale = .{ values[28 + lane], values[32 + lane], values[36 + lane] },
            };
        }
    }
    try reader.finish();
    return animation.Skeleton.init(allocator, inputs);
}

const LegacyCtrl = struct {
    allocator: std.mem.Allocator,
    time_indices: []u16,
    previouses: []u16,

    fn deinit(self: *LegacyCtrl) void {
        self.allocator.free(self.time_indices);
        self.allocator.free(self.previouses);
        self.* = undefined;
    }
};

fn readCtrl(
    allocator: std.mem.Allocator,
    reader: *Reader,
    key_count: usize,
    timepoint_count: usize,
    iframe_entries_count: usize,
    iframe_desc_count: usize,
) !LegacyCtrl {
    const time_indices = try allocator.alloc(u16, key_count);
    errdefer allocator.free(time_indices);
    if (timepoint_count <= std.math.maxInt(u8)) {
        for (time_indices) |*index| index.* = try reader.int(u8);
    } else {
        for (time_indices) |*index| index.* = try reader.int(u16);
    }
    const previouses = try allocator.alloc(u16, key_count);
    errdefer allocator.free(previouses);
    for (previouses) |*previous| previous.* = try reader.int(u16);
    try reader.discard(iframe_entries_count);
    for (0..iframe_desc_count) |_| _ = try reader.int(u32);
    _ = try reader.float();
    return .{
        .allocator = allocator,
        .time_indices = time_indices,
        .previouses = previouses,
    };
}

fn chainLength(ctrl: LegacyCtrl, track: usize) !usize {
    if (track >= ctrl.previouses.len) return Error.InvalidData;
    var count: usize = 1;
    var previous = track;
    for (track + 1..ctrl.previouses.len) |i| {
        if (ctrl.previouses[i] > i) return Error.InvalidData;
        if (i - ctrl.previouses[i] == previous) {
            count += 1;
            previous = i;
        }
    }
    return count;
}

fn nextInChain(ctrl: LegacyCtrl, previous: usize, start: usize) ?usize {
    for (start..ctrl.previouses.len) |i| {
        if (i - ctrl.previouses[i] == previous) return i;
    }
    return null;
}

fn timeRatio(ctrl: LegacyCtrl, timepoints: []const f32, index: usize) !f32 {
    const time_index = ctrl.time_indices[index];
    if (time_index >= timepoints.len) return Error.InvalidData;
    return timepoints[time_index];
}

fn halfToFloat(value: u16) f32 {
    const half: f16 = @bitCast(value);
    return @floatCast(half);
}

fn decompressQuaternion(values: [3]u16) math.Quaternion {
    const bits = @as(u64, values[0]) |
        (@as(u64, values[1]) << 16) |
        (@as(u64, values[2]) << 32);
    const largest: usize = @intCast(bits & 0x3);
    const negative = bits & 0x4 != 0;
    const scale = @sqrt(@as(f32, 2)) / 32767.0;
    const offset = -1.0 / @sqrt(@as(f32, 2));
    const compressed = [3]f32{
        @as(f32, @floatFromInt((bits >> 3) & 0x7fff)) * scale + offset,
        @as(f32, @floatFromInt((bits >> 18) & 0x7fff)) * scale + offset,
        @as(f32, @floatFromInt((bits >> 33) & 0x7fff)) * scale + offset,
    };
    var components = [4]f32{ 0, 0, 0, 0 };
    var source: usize = 0;
    for (&components, 0..) |*component, i| {
        if (i == largest) continue;
        component.* = compressed[source];
        source += 1;
    }
    var square_sum: f32 = 0;
    for (components) |component| square_sum += component * component;
    components[largest] = @sqrt(@max(1 - square_sum, 0));
    if (negative) components[largest] = -components[largest];
    return .{ .x = components[0], .y = components[1], .z = components[2], .w = components[3] };
}

fn decodeFloat3Tracks(
    allocator: std.mem.Allocator,
    ctrl: LegacyCtrl,
    values: []const [3]u16,
    timepoints: []const f32,
    track_count: usize,
) ![][]animation.Float3Key {
    if (values.len != ctrl.previouses.len) return Error.InvalidData;
    const tracks = try allocator.alloc([]animation.Float3Key, track_count);
    var initialized: usize = 0;
    errdefer {
        for (tracks[0..initialized]) |keys| allocator.free(keys);
        allocator.free(tracks);
    }
    for (tracks, 0..) |*keys, track| {
        keys.* = try allocator.alloc(animation.Float3Key, try chainLength(ctrl, track));
        initialized += 1;
        var index = track;
        for (keys.*, 0..) |*key, key_index| {
            key.* = .{
                .ratio = try timeRatio(ctrl, timepoints, index),
                .value = .{
                    halfToFloat(values[index][0]),
                    halfToFloat(values[index][1]),
                    halfToFloat(values[index][2]),
                },
            };
            if (key_index + 1 < keys.len) {
                index = nextInChain(ctrl, index, index + 1) orelse return Error.InvalidData;
            }
        }
    }
    return tracks;
}

fn decodeQuaternionTracks(
    allocator: std.mem.Allocator,
    ctrl: LegacyCtrl,
    values: []const [3]u16,
    timepoints: []const f32,
    track_count: usize,
) ![][]animation.QuaternionKey {
    if (values.len != ctrl.previouses.len) return Error.InvalidData;
    const tracks = try allocator.alloc([]animation.QuaternionKey, track_count);
    var initialized: usize = 0;
    errdefer {
        for (tracks[0..initialized]) |keys| allocator.free(keys);
        allocator.free(tracks);
    }
    for (tracks, 0..) |*keys, track| {
        keys.* = try allocator.alloc(animation.QuaternionKey, try chainLength(ctrl, track));
        initialized += 1;
        var index = track;
        for (keys.*, 0..) |*key, key_index| {
            key.* = .{
                .ratio = try timeRatio(ctrl, timepoints, index),
                .value = decompressQuaternion(values[index]),
            };
            if (key_index + 1 < keys.len) {
                index = nextInChain(ctrl, index, index + 1) orelse return Error.InvalidData;
            }
        }
    }
    return tracks;
}

fn freeNested(comptime T: type, allocator: std.mem.Allocator, values: [][]T) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn readPacked3(allocator: std.mem.Allocator, reader: *Reader, count: usize) ![][3]u16 {
    const values = try allocator.alloc([3]u16, count);
    errdefer allocator.free(values);
    for (values) |*value| {
        value[0] = try reader.int(u16);
        value[1] = try reader.int(u16);
        value[2] = try reader.int(u16);
    }
    return values;
}

pub fn readAnimation(
    allocator: std.mem.Allocator,
    stream: *std.Io.Reader,
    limits: Limits,
) !animation.Animation {
    var reader = try Reader.init(stream, limits);
    try reader.expectTag("ozz-animation\x00");
    try expectVersion(&reader, 7);
    const duration = try reader.float();
    const track_count = try reader.count();
    if (track_count > animation.max_joints) return Error.InvalidLength;
    const name_len = try reader.count();
    if (name_len > limits.max_string_bytes) return Error.InvalidLength;
    const timepoint_count = try reader.count();
    const translation_count = try reader.count();
    const rotation_count = try reader.count();
    const scale_count = try reader.count();
    const t_iframe_entries = try reader.count();
    const t_iframe_desc = try reader.count();
    const r_iframe_entries = try reader.count();
    const r_iframe_desc = try reader.count();
    const s_iframe_entries = try reader.count();
    const s_iframe_desc = try reader.count();
    const name = try reader.readAlloc(allocator, name_len);
    defer allocator.free(name);
    const timepoints = try allocator.alloc(f32, timepoint_count);
    defer allocator.free(timepoints);
    for (timepoints) |*timepoint| timepoint.* = try reader.float();

    var translation_ctrl = try readCtrl(
        allocator,
        &reader,
        translation_count,
        timepoint_count,
        t_iframe_entries,
        t_iframe_desc,
    );
    defer translation_ctrl.deinit();
    const translation_values = try readPacked3(allocator, &reader, translation_count);
    defer allocator.free(translation_values);
    var rotation_ctrl = try readCtrl(
        allocator,
        &reader,
        rotation_count,
        timepoint_count,
        r_iframe_entries,
        r_iframe_desc,
    );
    defer rotation_ctrl.deinit();
    const rotation_values = try readPacked3(allocator, &reader, rotation_count);
    defer allocator.free(rotation_values);
    var scale_ctrl = try readCtrl(
        allocator,
        &reader,
        scale_count,
        timepoint_count,
        s_iframe_entries,
        s_iframe_desc,
    );
    defer scale_ctrl.deinit();
    const scale_values = try readPacked3(allocator, &reader, scale_count);
    defer allocator.free(scale_values);
    try reader.finish();

    const translations = try decodeFloat3Tracks(
        allocator,
        translation_ctrl,
        translation_values,
        timepoints,
        track_count,
    );
    defer freeNested(animation.Float3Key, allocator, translations);
    const rotations = try decodeQuaternionTracks(
        allocator,
        rotation_ctrl,
        rotation_values,
        timepoints,
        track_count,
    );
    defer freeNested(animation.QuaternionKey, allocator, rotations);
    const scales = try decodeFloat3Tracks(
        allocator,
        scale_ctrl,
        scale_values,
        timepoints,
        track_count,
    );
    defer freeNested(animation.Float3Key, allocator, scales);
    const inputs = try allocator.alloc(animation.JointTrackInput, track_count);
    defer allocator.free(inputs);
    for (inputs, 0..) |*input, i| input.* = .{
        .translations = translations[i],
        .rotations = rotations[i],
        .scales = scales[i],
    };
    return animation.Animation.init(allocator, name, duration, inputs);
}

fn readRawJoint(
    allocator: std.mem.Allocator,
    reader: *Reader,
    depth: u16,
) !offline.RawJoint {
    if (depth > reader.limits.max_depth) return Error.InvalidLength;
    var result: offline.RawJoint = .{
        .name = try reader.string(allocator),
        .transform = .identity,
        .children = &.{},
    };
    errdefer allocator.free(result.name);
    result.transform = try readTransform(reader);
    const child_count = try reader.count();
    if (child_count == 0) return result;
    try expectVersion(reader, 1);
    result.children = try allocator.alloc(offline.RawJoint, child_count);
    var initialized: usize = 0;
    errdefer {
        for (result.children[0..initialized]) |*child| deinitRawJoint(allocator, child);
        allocator.free(result.children);
    }
    for (result.children) |*child| {
        child.* = try readRawJoint(allocator, reader, depth + 1);
        initialized += 1;
    }
    return result;
}

fn deinitRawJoint(allocator: std.mem.Allocator, joint: *offline.RawJoint) void {
    for (joint.children) |*child| deinitRawJoint(allocator, child);
    allocator.free(joint.children);
    allocator.free(joint.name);
}

pub fn readRawSkeleton(
    allocator: std.mem.Allocator,
    stream: *std.Io.Reader,
    limits: Limits,
) !offline.RawSkeleton {
    var reader = try Reader.init(stream, limits);
    try reader.expectTag("ozz-raw_skeleton\x00");
    try expectVersion(&reader, 1);
    const root_count = try reader.count();
    const roots = try allocator.alloc(offline.RawJoint, root_count);
    var initialized: usize = 0;
    errdefer {
        for (roots[0..initialized]) |*root| deinitRawJoint(allocator, root);
        allocator.free(roots);
    }
    if (root_count > 0) try expectVersion(&reader, 1);
    for (roots) |*root| {
        root.* = try readRawJoint(allocator, &reader, 1);
        initialized += 1;
    }
    try reader.finish();
    return .{ .allocator = allocator, .roots = roots };
}

fn readTimedValues(
    comptime Key: type,
    comptime Value: type,
    allocator: std.mem.Allocator,
    reader: *Reader,
) ![]Key {
    const count = try reader.count();
    const result = try allocator.alloc(Key, count);
    errdefer allocator.free(result);
    if (count > 0) try expectVersion(reader, 1);
    for (result) |*key| {
        key.* = .{ .time = try reader.float(), .value = try readValue(Value, reader) };
    }
    return result;
}

pub fn readRawAnimation(
    allocator: std.mem.Allocator,
    stream: *std.Io.Reader,
    limits: Limits,
) !offline.RawAnimation {
    var reader = try Reader.init(stream, limits);
    try reader.expectTag("ozz-raw_animation\x00");
    try expectVersion(&reader, 3);
    const duration = try reader.float();
    const track_count = try reader.count();
    if (track_count > animation.max_joints) return Error.InvalidLength;
    var result = try offline.RawAnimation.init(allocator, "", duration, track_count);
    errdefer result.deinit();
    if (track_count > 0) try expectVersion(&reader, 1);
    for (result.tracks) |*track| {
        track.translations = try readTimedValues(
            offline.TranslationKey,
            math.Vec3f32,
            allocator,
            &reader,
        );
        track.rotations = try readTimedValues(
            offline.RotationKey,
            math.Quaternion,
            allocator,
            &reader,
        );
        track.scales = try readTimedValues(
            offline.ScaleKey,
            math.Vec3f32,
            allocator,
            &reader,
        );
    }
    const name = try reader.string(allocator);
    allocator.free(result.name);
    result.name = name;
    try reader.finish();
    if (!result.validate()) return Error.InvalidData;
    return result;
}

fn valueTag(comptime T: type, raw: bool) []const u8 {
    if (T == f32) return if (raw) "ozz-raw_float_track\x00" else "ozz-float_track\x00";
    if (T == math.Vec2f32) return if (raw) "ozz-raw_float2_track\x00" else "ozz-float2_track\x00";
    if (T == math.Vec3f32) return if (raw) "ozz-raw_float3_track\x00" else "ozz-float3_track\x00";
    if (T == math.Float4) return if (raw) "ozz-raw_float4_track\x00" else "ozz-float4_track\x00";
    if (T == math.Quaternion) return if (raw) "ozz-raw_quat_track\x00" else "ozz-quat_track\x00";
    @compileError("unsupported track value");
}

fn readValue(comptime T: type, reader: *Reader) !T {
    if (T == f32) return reader.float();
    if (T == math.Vec2f32) return readVec2f32(reader);
    if (T == math.Vec3f32) return readVec3f32(reader);
    if (T == math.Float4 or T == math.Quaternion) return readXyzw(T, reader);
    @compileError("unsupported track value");
}

pub fn readTrack(
    comptime T: type,
    allocator: std.mem.Allocator,
    stream: *std.Io.Reader,
    limits: Limits,
) !animation.Track(T) {
    var reader = try Reader.init(stream, limits);
    var result = try readTrackBody(T, allocator, &reader);
    errdefer result.deinit();
    try reader.finish();
    return result;
}

/// Reads the first tagged runtime track in a legacy stream. `consumed` includes
/// the stream's initial endian byte, making it suitable for archive iteration.
pub fn readTrackPrefix(
    comptime T: type,
    allocator: std.mem.Allocator,
    stream: *std.Io.Reader,
    limits: Limits,
    consumed: *usize,
) !animation.Track(T) {
    var reader = try Reader.init(stream, limits);
    const result = try readTrackBody(T, allocator, &reader);
    consumed.* = reader.pos;
    return result;
}

fn readTrackBody(
    comptime T: type,
    allocator: std.mem.Allocator,
    reader: *Reader,
) !animation.Track(T) {
    try reader.expectTag(valueTag(T, false));
    try expectVersion(reader, 1);
    const count = try reader.count();
    const signed_name_len = try reader.int(i32);
    if (signed_name_len < 0 or signed_name_len > reader.limits.max_string_bytes) {
        return Error.InvalidLength;
    }
    const Key = animation.Track(T).Key;
    const keys = try allocator.alloc(Key, count);
    defer allocator.free(keys);
    for (keys) |*key| key.ratio = try reader.float();
    for (keys) |*key| key.value = try readValue(T, reader);
    const step_bytes = try reader.readAlloc(allocator, (count + 7) / 8);
    defer allocator.free(step_bytes);
    for (keys, 0..) |*key, i| {
        key.interpolation = if (step_bytes[i / 8] & (@as(u8, 1) << @intCast(i & 7)) != 0)
            .step
        else
            .linear;
    }
    const name = try reader.readAlloc(allocator, @intCast(signed_name_len));
    defer allocator.free(name);
    return animation.Track(T).initMixed(allocator, name, keys);
}

pub fn readRawTrack(
    comptime T: type,
    allocator: std.mem.Allocator,
    stream: *std.Io.Reader,
    limits: Limits,
) !offline.RawTrack(T) {
    var reader = try Reader.init(stream, limits);
    try reader.expectTag(valueTag(T, true));
    try expectVersion(&reader, 1);
    const count = try reader.count();
    const Key = offline.RawTrack(T).Key;
    const keys = try allocator.alloc(Key, count);
    defer allocator.free(keys);
    if (count > 0) try expectVersion(&reader, 1);
    for (keys) |*key| {
        key.interpolation = switch (try reader.int(u8)) {
            0 => .step,
            1 => .linear,
            else => return Error.InvalidData,
        };
        key.ratio = try reader.float();
        key.value = try readValue(T, &reader);
    }
    const name = try reader.string(allocator);
    defer allocator.free(name);
    try reader.finish();
    return offline.RawTrack(T).init(allocator, name, keys);
}

fn readLegacySlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    reader: *Reader,
) ![]T {
    const count = try reader.count();
    const values = try allocator.alloc(T, count);
    errdefer allocator.free(values);
    for (values) |*value| {
        value.* = if (T == u8)
            try reader.int(u8)
        else if (T == u16)
            try reader.int(u16)
        else if (T == f32)
            try reader.float()
        else
            @compileError("unsupported legacy mesh scalar");
    }
    return values;
}

fn deinitMeshPart(allocator: std.mem.Allocator, part: geometry.MeshPart) void {
    allocator.free(part.positions);
    allocator.free(part.normals);
    allocator.free(part.tangents);
    allocator.free(part.uvs);
    allocator.free(part.colors);
    allocator.free(part.joint_indices);
    allocator.free(part.joint_weights);
}

fn readMeshPartBody(allocator: std.mem.Allocator, reader: *Reader) !geometry.MeshPart {
    var part: geometry.MeshPart = .{};
    part.positions = try readLegacySlice(f32, allocator, reader);
    errdefer allocator.free(part.positions);
    part.normals = try readLegacySlice(f32, allocator, reader);
    errdefer allocator.free(part.normals);
    part.tangents = try readLegacySlice(f32, allocator, reader);
    errdefer allocator.free(part.tangents);
    part.uvs = try readLegacySlice(f32, allocator, reader);
    errdefer allocator.free(part.uvs);
    part.colors = try readLegacySlice(u8, allocator, reader);
    errdefer allocator.free(part.colors);
    part.joint_indices = try readLegacySlice(u16, allocator, reader);
    errdefer allocator.free(part.joint_indices);
    part.joint_weights = try readLegacySlice(f32, allocator, reader);
    return part;
}

pub fn readMeshPart(
    allocator: std.mem.Allocator,
    stream: *std.Io.Reader,
    limits: Limits,
) !geometry.MeshPart {
    var reader = try Reader.init(stream, limits);
    try reader.expectTag("ozz-sample-Mesh-Part\x00");
    try expectVersion(&reader, 1);
    const part = try readMeshPartBody(allocator, &reader);
    errdefer deinitMeshPart(allocator, part);
    try reader.finish();
    return part;
}

pub fn readMesh(
    allocator: std.mem.Allocator,
    stream: *std.Io.Reader,
    limits: Limits,
) !geometry.Mesh {
    var reader = try Reader.init(stream, limits);
    var result = try readMeshBody(allocator, &reader);
    errdefer result.deinit();
    try reader.finish();
    return result;
}

pub fn readMeshPrefix(
    allocator: std.mem.Allocator,
    stream: *std.Io.Reader,
    limits: Limits,
    consumed: *usize,
) !geometry.Mesh {
    var reader = try Reader.init(stream, limits);
    const result = try readMeshBody(allocator, &reader);
    consumed.* = reader.pos;
    return result;
}

fn readMeshBody(
    allocator: std.mem.Allocator,
    reader: *Reader,
) !geometry.Mesh {
    try reader.expectTag("ozz-sample-Mesh\x00");
    try expectVersion(reader, 1);
    const part_count = try reader.count();
    const parts = try allocator.alloc(geometry.MeshPart, part_count);
    @memset(parts, .{});
    var initialized: usize = 0;
    errdefer {
        for (parts[0..initialized]) |part| deinitMeshPart(allocator, part);
        allocator.free(parts);
    }
    if (part_count > 0) try expectVersion(reader, 1);
    for (parts) |*part| {
        part.* = try readMeshPartBody(allocator, reader);
        initialized += 1;
    }
    const triangle_indices = try readLegacySlice(u16, allocator, reader);
    errdefer allocator.free(triangle_indices);
    const joint_remaps = try readLegacySlice(u16, allocator, reader);
    errdefer allocator.free(joint_remaps);
    const matrix_count = try reader.count();
    const matrices = try allocator.alloc(math.Float4x4, matrix_count);
    errdefer allocator.free(matrices);
    for (matrices) |*matrix| for (0..4) |column| for (0..4) |lane_index| {
        matrix.cols[column][lane_index] = try reader.float();
    };
    const result: geometry.Mesh = .{
        .allocator = allocator,
        .parts = parts,
        .triangle_indices = triangle_indices,
        .joint_remaps = joint_remaps,
        .inverse_bind_poses = matrices,
    };
    return result;
}

test "legacy archive detection" {
    try std.testing.expectEqual(Kind.skeleton, try detect("\x01ozz-skeleton\x00"));
    try std.testing.expectEqual(Kind.raw_float3_track, try detect("\x00ozz-raw_float3_track\x00"));
    try std.testing.expectError(Error.UnknownTag, detect("\x01not-ozz\x00"));
}
