//! Versioned native `.zozz` serialization.
//!
//! The payload codec is intentionally explicit. No pointer, padding, native
//! integer width, or host endianness is ever written to disk.

const std = @import("std");
const math = @import("math.zig");
const serialization = @import("serialization.zig");
const animation = @import("animation.zig");
const offline = @import("offline.zig");
const geometry = @import("geometry.zig");

pub const magic = "ZOZZBIN\x00";
pub const container_version: u16 = 1;

pub const ObjectKind = enum(u16) {
    skeleton = 1,
    animation = 2,
    float_track = 3,
    float2_track = 4,
    float3_track = 5,
    float4_track = 6,
    quaternion_track = 7,
    raw_skeleton = 8,
    raw_animation = 9,
    raw_float_track = 10,
    raw_float2_track = 11,
    raw_float3_track = 12,
    raw_float4_track = 13,
    raw_quaternion_track = 14,
    sample_mesh = 15,
};

pub const Header = struct {
    kind: ObjectKind,
    schema_version: u32,
    payload_len: u64,
};

pub const ReadLimits = struct {
    max_payload_bytes: u64 = 1024 * 1024 * 1024,
    max_string_bytes: u32 = 16 * 1024 * 1024,
    max_collection_items: u32 = 16 * 1024 * 1024,
};

pub const Error = error{
    BadMagic,
    UnsupportedContainerVersion,
    UnsupportedObjectKind,
    PayloadTooLarge,
    InvalidLength,
    UnexpectedObjectKind,
    UnsupportedSchemaVersion,
    TrailingPayloadData,
};

pub fn writeHeader(writer: *std.Io.Writer, header: Header) !void {
    try writer.writeAll(magic);
    try writer.writeInt(u16, container_version, .little);
    try writer.writeInt(u16, @intFromEnum(header.kind), .little);
    try writer.writeInt(u32, header.schema_version, .little);
    try writer.writeInt(u64, header.payload_len, .little);
}

pub fn readHeader(reader: *std.Io.Reader, limits: ReadLimits) !Header {
    var actual_magic: [magic.len]u8 = undefined;
    try reader.readSliceAll(&actual_magic);
    if (!std.mem.eql(u8, &actual_magic, magic)) return Error.BadMagic;
    if (try reader.takeInt(u16, .little) != container_version) {
        return Error.UnsupportedContainerVersion;
    }
    const kind = std.enums.fromInt(ObjectKind, try reader.takeInt(u16, .little)) orelse
        return Error.UnsupportedObjectKind;
    const schema_version = try reader.takeInt(u32, .little);
    const payload_len = try reader.takeInt(u64, .little);
    if (payload_len > limits.max_payload_bytes) return Error.PayloadTooLarge;
    return .{ .kind = kind, .schema_version = schema_version, .payload_len = payload_len };
}

fn writeF32(writer: *std.Io.Writer, value: f32) !void {
    try writer.writeInt(u32, @bitCast(value), .little);
}

fn readF32(reader: *std.Io.Reader) !f32 {
    return @bitCast(try reader.takeInt(u32, .little));
}

fn writeFloat3(writer: *std.Io.Writer, value: math.Vec3f32) !void {
    try serialization.writeVec3f32(writer, value, .little);
}

fn readFloat3(reader: *std.Io.Reader) !math.Vec3f32 {
    return serialization.readVec3f32(reader, .little);
}

fn writeXyzw(writer: *std.Io.Writer, value: anytype) !void {
    try writeF32(writer, value.x);
    try writeF32(writer, value.y);
    try writeF32(writer, value.z);
    try writeF32(writer, value.w);
}

fn readXyzw(comptime T: type, reader: *std.Io.Reader) !T {
    return .{
        .x = try readF32(reader),
        .y = try readF32(reader),
        .z = try readF32(reader),
        .w = try readF32(reader),
    };
}

fn writeTransform(writer: *std.Io.Writer, value: math.Transform) !void {
    try writeFloat3(writer, value.translation);
    try writeXyzw(writer, value.rotation);
    try writeFloat3(writer, value.scale);
}

fn readTransform(reader: *std.Io.Reader) !math.Transform {
    return .{
        .translation = try readFloat3(reader),
        .rotation = try readXyzw(math.Quaternion, reader),
        .scale = try readFloat3(reader),
    };
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    if (value.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try writer.writeInt(u32, @intCast(value.len), .little);
    try writer.writeAll(value);
}

fn readString(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) ![]u8 {
    const len = try reader.takeInt(u32, .little);
    if (len > limits.max_string_bytes) return Error.InvalidLength;
    const result = try allocator.alloc(u8, len);
    errdefer allocator.free(result);
    try reader.readSliceAll(result);
    return result;
}

fn finishPayload(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    kind: ObjectKind,
    schema_version: u32,
    payload: *std.Io.Writer.Allocating,
) !void {
    const bytes = payload.writer.buffered();
    try writeHeader(output, .{
        .kind = kind,
        .schema_version = schema_version,
        .payload_len = bytes.len,
    });
    try output.writeAll(bytes);
    _ = allocator;
}

fn readPayload(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    expected_kind: ObjectKind,
    expected_schema: u32,
    limits: ReadLimits,
) ![]u8 {
    const header = try readHeader(reader, limits);
    if (header.kind != expected_kind) return Error.UnexpectedObjectKind;
    if (header.schema_version != expected_schema) return Error.UnsupportedSchemaVersion;
    if (header.payload_len > std.math.maxInt(usize)) return Error.PayloadTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(header.payload_len));
    errdefer allocator.free(bytes);
    try reader.readSliceAll(bytes);
    return bytes;
}

pub fn writeSkeleton(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    skeleton: animation.Skeleton,
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    if (skeleton.numJoints() > std.math.maxInt(u32)) return Error.InvalidLength;
    try payload.writer.writeInt(u32, @intCast(skeleton.numJoints()), .little);
    for (skeleton.parents) |parent| try payload.writer.writeInt(i16, parent, .little);
    for (skeleton.names) |name| try writeString(&payload.writer, name);
    for (0..skeleton.numJoints()) |i| try writeTransform(&payload.writer, skeleton.jointRestPose(i));
    try finishPayload(allocator, writer, .skeleton, 1, &payload);
}

pub fn readSkeleton(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) !animation.Skeleton {
    const bytes = try readPayload(allocator, reader, .skeleton, 1, limits);
    defer allocator.free(bytes);
    var payload = std.Io.Reader.fixed(bytes);
    const count = try payload.takeInt(u32, .little);
    if (count > animation.max_joints or count > limits.max_collection_items) {
        return Error.InvalidLength;
    }
    const joints = try allocator.alloc(animation.JointInput, count);
    defer allocator.free(joints);
    for (joints) |*joint| joint.* = .{ .name = &.{}, .parent = animation.no_parent };
    for (joints) |*joint| joint.parent = try payload.takeInt(i16, .little);
    var names_initialized: usize = 0;
    defer for (joints[0..names_initialized]) |joint| allocator.free(joint.name);
    for (joints) |*joint| {
        joint.name = try readString(allocator, &payload, limits);
        names_initialized += 1;
    }
    for (joints) |*joint| joint.rest_pose = try readTransform(&payload);
    if (payload.bufferedLen() != 0) return Error.TrailingPayloadData;
    return animation.Skeleton.init(allocator, joints);
}

fn writeFloat3Keys(writer: *std.Io.Writer, keys: []const animation.Float3Key) !void {
    if (keys.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try writer.writeInt(u32, @intCast(keys.len), .little);
    for (keys) |key| {
        try writeF32(writer, key.ratio);
        try writeFloat3(writer, key.value);
    }
}

fn writeQuaternionKeys(writer: *std.Io.Writer, keys: []const animation.QuaternionKey) !void {
    if (keys.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try writer.writeInt(u32, @intCast(keys.len), .little);
    for (keys) |key| {
        try writeF32(writer, key.ratio);
        try writeXyzw(writer, key.value);
    }
}

pub fn writeAnimation(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: animation.Animation,
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try writeString(&payload.writer, value.name);
    try writeF32(&payload.writer, value.duration);
    if (value.tracks.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try payload.writer.writeInt(u32, @intCast(value.tracks.len), .little);
    for (value.tracks) |track| {
        try writeFloat3Keys(&payload.writer, track.translations);
        try writeQuaternionKeys(&payload.writer, track.rotations);
        try writeFloat3Keys(&payload.writer, track.scales);
    }
    try finishPayload(allocator, writer, .animation, 1, &payload);
}

fn readFloat3Keys(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) ![]animation.Float3Key {
    const count = try reader.takeInt(u32, .little);
    if (count > limits.max_collection_items) return Error.InvalidLength;
    const keys = try allocator.alloc(animation.Float3Key, count);
    errdefer allocator.free(keys);
    for (keys) |*key| key.* = .{ .ratio = try readF32(reader), .value = try readFloat3(reader) };
    return keys;
}

fn readQuaternionKeys(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) ![]animation.QuaternionKey {
    const count = try reader.takeInt(u32, .little);
    if (count > limits.max_collection_items) return Error.InvalidLength;
    const keys = try allocator.alloc(animation.QuaternionKey, count);
    errdefer allocator.free(keys);
    for (keys) |*key| {
        key.* = .{ .ratio = try readF32(reader), .value = try readXyzw(math.Quaternion, reader) };
    }
    return keys;
}

const TempTrack = struct {
    translations: []animation.Float3Key,
    rotations: []animation.QuaternionKey,
    scales: []animation.Float3Key,
};

pub fn readAnimation(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) !animation.Animation {
    const bytes = try readPayload(allocator, reader, .animation, 1, limits);
    defer allocator.free(bytes);
    var payload = std.Io.Reader.fixed(bytes);
    const name = try readString(allocator, &payload, limits);
    defer allocator.free(name);
    const duration = try readF32(&payload);
    const count = try payload.takeInt(u32, .little);
    if (count > animation.max_joints or count > limits.max_collection_items) {
        return Error.InvalidLength;
    }
    const temp = try allocator.alloc(TempTrack, count);
    defer allocator.free(temp);
    var initialized: usize = 0;
    defer for (temp[0..initialized]) |track| {
        allocator.free(track.translations);
        allocator.free(track.rotations);
        allocator.free(track.scales);
    };
    const inputs = try allocator.alloc(animation.JointTrackInput, count);
    defer allocator.free(inputs);
    for (temp, 0..) |*track, i| {
        track.translations = try readFloat3Keys(allocator, &payload, limits);
        errdefer allocator.free(track.translations);
        track.rotations = try readQuaternionKeys(allocator, &payload, limits);
        errdefer allocator.free(track.rotations);
        track.scales = try readFloat3Keys(allocator, &payload, limits);
        initialized += 1;
        inputs[i] = .{
            .translations = track.translations,
            .rotations = track.rotations,
            .scales = track.scales,
        };
    }
    if (payload.bufferedLen() != 0) return Error.TrailingPayloadData;
    return animation.Animation.init(allocator, name, duration, inputs);
}

fn trackKind(comptime T: type, raw: bool) ObjectKind {
    if (T == f32) return if (raw) .raw_float_track else .float_track;
    if (T == math.Vec2f32) return if (raw) .raw_float2_track else .float2_track;
    if (T == math.Vec3f32) return if (raw) .raw_float3_track else .float3_track;
    if (T == math.Float4) return if (raw) .raw_float4_track else .float4_track;
    if (T == math.Quaternion) return if (raw) .raw_quaternion_track else .quaternion_track;
    @compileError("unsupported track value type");
}

fn writeValue(comptime T: type, writer: *std.Io.Writer, value: T) !void {
    if (T == f32) return writeF32(writer, value);
    if (T == math.Vec2f32) return serialization.writeVec2f32(writer, value, .little);
    if (T == math.Vec3f32) return writeFloat3(writer, value);
    if (T == math.Float4) {
        try writeXyzw(writer, value);
        return;
    }
    if (T == math.Quaternion) return writeXyzw(writer, value);
    @compileError("unsupported track value type");
}

fn readValue(comptime T: type, reader: *std.Io.Reader) !T {
    if (T == f32) return readF32(reader);
    if (T == math.Vec2f32) return serialization.readVec2f32(reader, .little);
    if (T == math.Vec3f32) return readFloat3(reader);
    if (T == math.Float4 or T == math.Quaternion) return readXyzw(T, reader);
    @compileError("unsupported track value type");
}

pub fn writeTrack(
    comptime T: type,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    track: animation.Track(T),
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try writeString(&payload.writer, track.name);
    if (track.keys.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try payload.writer.writeInt(u32, @intCast(track.keys.len), .little);
    for (track.keys) |key| {
        try payload.writer.writeByte(@intFromEnum(key.interpolation));
        try writeF32(&payload.writer, key.ratio);
        try writeValue(T, &payload.writer, key.value);
    }
    try finishPayload(allocator, writer, trackKind(T, false), 1, &payload);
}

pub fn readTrack(
    comptime T: type,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) !animation.Track(T) {
    const bytes = try readPayload(allocator, reader, trackKind(T, false), 1, limits);
    defer allocator.free(bytes);
    var payload = std.Io.Reader.fixed(bytes);
    const name = try readString(allocator, &payload, limits);
    defer allocator.free(name);
    const count = try payload.takeInt(u32, .little);
    if (count > limits.max_collection_items) return Error.InvalidLength;
    const Key = animation.Track(T).Key;
    const keys = try allocator.alloc(Key, count);
    defer allocator.free(keys);
    for (keys) |*key| key.* = .{
        .interpolation = std.enums.fromInt(animation.Interpolation, try payload.takeByte()) orelse
            return Error.InvalidLength,
        .ratio = try readF32(&payload),
        .value = try readValue(T, &payload),
    };
    if (payload.bufferedLen() != 0) return Error.TrailingPayloadData;
    return animation.Track(T).initMixed(allocator, name, keys);
}

pub fn writeRawTrack(
    comptime T: type,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    track: offline.RawTrack(T),
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try writeString(&payload.writer, track.name);
    if (track.keys.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try payload.writer.writeInt(u32, @intCast(track.keys.len), .little);
    for (track.keys) |key| {
        try payload.writer.writeByte(@intFromEnum(key.interpolation));
        try writeF32(&payload.writer, key.ratio);
        try writeValue(T, &payload.writer, key.value);
    }
    try finishPayload(allocator, writer, trackKind(T, true), 1, &payload);
}

pub fn readRawTrack(
    comptime T: type,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) !offline.RawTrack(T) {
    const bytes = try readPayload(allocator, reader, trackKind(T, true), 1, limits);
    defer allocator.free(bytes);
    var payload = std.Io.Reader.fixed(bytes);
    const name = try readString(allocator, &payload, limits);
    defer allocator.free(name);
    const count = try payload.takeInt(u32, .little);
    if (count > limits.max_collection_items) return Error.InvalidLength;
    const Key = offline.RawTrack(T).Key;
    const keys = try allocator.alloc(Key, count);
    defer allocator.free(keys);
    for (keys) |*key| key.* = .{
        .interpolation = std.enums.fromInt(animation.Interpolation, try payload.takeByte()) orelse
            return Error.InvalidLength,
        .ratio = try readF32(&payload),
        .value = try readValue(T, &payload),
    };
    if (payload.bufferedLen() != 0) return Error.TrailingPayloadData;
    return offline.RawTrack(T).init(allocator, name, keys);
}

fn writeSlice(
    comptime T: type,
    writer: *std.Io.Writer,
    values: []const T,
) !void {
    if (values.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try writer.writeInt(u32, @intCast(values.len), .little);
    for (values) |value| {
        if (T == u8) try writer.writeByte(value) else if (T == u16)
            try writer.writeInt(u16, value, .little)
        else if (T == f32)
            try writeF32(writer, value)
        else
            @compileError("unsupported mesh scalar");
    }
}

fn readSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) ![]T {
    const count = try reader.takeInt(u32, .little);
    if (count > limits.max_collection_items) return Error.InvalidLength;
    const values = try allocator.alloc(T, count);
    errdefer allocator.free(values);
    for (values) |*value| {
        value.* = if (T == u8)
            try reader.takeByte()
        else if (T == u16)
            try reader.takeInt(u16, .little)
        else if (T == f32)
            try readF32(reader)
        else
            @compileError("unsupported mesh scalar");
    }
    return values;
}

pub fn writeMesh(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    mesh: geometry.Mesh,
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    if (mesh.parts.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try payload.writer.writeInt(u32, @intCast(mesh.parts.len), .little);
    for (mesh.parts) |part| {
        try writeSlice(f32, &payload.writer, part.positions);
        try writeSlice(f32, &payload.writer, part.normals);
        try writeSlice(f32, &payload.writer, part.tangents);
        try writeSlice(f32, &payload.writer, part.uvs);
        try writeSlice(u8, &payload.writer, part.colors);
        try writeSlice(u16, &payload.writer, part.joint_indices);
        try writeSlice(f32, &payload.writer, part.joint_weights);
    }
    try writeSlice(u16, &payload.writer, mesh.triangle_indices);
    try writeSlice(u16, &payload.writer, mesh.joint_remaps);
    if (mesh.inverse_bind_poses.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try payload.writer.writeInt(u32, @intCast(mesh.inverse_bind_poses.len), .little);
    for (mesh.inverse_bind_poses) |matrix| {
        for (matrix.cols) |column| for (0..4) |lane_index| {
            try writeF32(&payload.writer, column[lane_index]);
        };
    }
    try finishPayload(allocator, writer, .sample_mesh, 1, &payload);
}

pub fn readMesh(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) !geometry.Mesh {
    const bytes = try readPayload(allocator, reader, .sample_mesh, 1, limits);
    defer allocator.free(bytes);
    var payload = std.Io.Reader.fixed(bytes);
    const part_count = try payload.takeInt(u32, .little);
    if (part_count > limits.max_collection_items) return Error.InvalidLength;
    const parts = try allocator.alloc(geometry.MeshPart, part_count);
    @memset(parts, .{});
    var initialized: usize = 0;
    errdefer {
        for (parts[0..initialized]) |part| {
            allocator.free(part.positions);
            allocator.free(part.normals);
            allocator.free(part.tangents);
            allocator.free(part.uvs);
            allocator.free(part.colors);
            allocator.free(part.joint_indices);
            allocator.free(part.joint_weights);
        }
        allocator.free(parts);
    }
    for (parts) |*part| {
        part.positions = try readSlice(f32, allocator, &payload, limits);
        errdefer allocator.free(part.positions);
        part.normals = try readSlice(f32, allocator, &payload, limits);
        errdefer allocator.free(part.normals);
        part.tangents = try readSlice(f32, allocator, &payload, limits);
        errdefer allocator.free(part.tangents);
        part.uvs = try readSlice(f32, allocator, &payload, limits);
        errdefer allocator.free(part.uvs);
        part.colors = try readSlice(u8, allocator, &payload, limits);
        errdefer allocator.free(part.colors);
        part.joint_indices = try readSlice(u16, allocator, &payload, limits);
        errdefer allocator.free(part.joint_indices);
        part.joint_weights = try readSlice(f32, allocator, &payload, limits);
        initialized += 1;
    }
    const triangle_indices = try readSlice(u16, allocator, &payload, limits);
    errdefer allocator.free(triangle_indices);
    const joint_remaps = try readSlice(u16, allocator, &payload, limits);
    errdefer allocator.free(joint_remaps);
    const matrix_count = try payload.takeInt(u32, .little);
    if (matrix_count > limits.max_collection_items) return Error.InvalidLength;
    const matrices = try allocator.alloc(math.Float4x4, matrix_count);
    errdefer allocator.free(matrices);
    for (matrices) |*matrix| for (0..4) |column| for (0..4) |lane_index| {
        matrix.cols[column][lane_index] = try readF32(&payload);
    };
    if (payload.bufferedLen() != 0) return Error.TrailingPayloadData;
    return .{
        .allocator = allocator,
        .parts = parts,
        .triangle_indices = triangle_indices,
        .joint_remaps = joint_remaps,
        .inverse_bind_poses = matrices,
    };
}

fn writeTimedFloat3(comptime Key: type, writer: *std.Io.Writer, keys: []const Key) !void {
    if (keys.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try writer.writeInt(u32, @intCast(keys.len), .little);
    for (keys) |key| {
        try writeF32(writer, key.time);
        try writeFloat3(writer, key.value);
    }
}

fn writeTimedQuaternion(writer: *std.Io.Writer, keys: []const offline.RotationKey) !void {
    if (keys.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try writer.writeInt(u32, @intCast(keys.len), .little);
    for (keys) |key| {
        try writeF32(writer, key.time);
        try writeXyzw(writer, key.value);
    }
}

pub fn writeRawAnimation(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: offline.RawAnimation,
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try writeString(&payload.writer, value.name);
    try writeF32(&payload.writer, value.duration);
    if (value.tracks.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try payload.writer.writeInt(u32, @intCast(value.tracks.len), .little);
    for (value.tracks) |track| {
        try writeTimedFloat3(offline.TranslationKey, &payload.writer, track.translations);
        try writeTimedQuaternion(&payload.writer, track.rotations);
        try writeTimedFloat3(offline.ScaleKey, &payload.writer, track.scales);
    }
    try finishPayload(allocator, writer, .raw_animation, 1, &payload);
}

fn readTimedFloat3(
    comptime Key: type,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) ![]Key {
    const count = try reader.takeInt(u32, .little);
    if (count > limits.max_collection_items) return Error.InvalidLength;
    const keys = try allocator.alloc(Key, count);
    errdefer allocator.free(keys);
    for (keys) |*key| key.* = .{ .time = try readF32(reader), .value = try readFloat3(reader) };
    return keys;
}

fn readTimedQuaternion(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) ![]offline.RotationKey {
    const count = try reader.takeInt(u32, .little);
    if (count > limits.max_collection_items) return Error.InvalidLength;
    const keys = try allocator.alloc(offline.RotationKey, count);
    errdefer allocator.free(keys);
    for (keys) |*key| {
        key.* = .{ .time = try readF32(reader), .value = try readXyzw(math.Quaternion, reader) };
    }
    return keys;
}

pub fn readRawAnimation(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) !offline.RawAnimation {
    const bytes = try readPayload(allocator, reader, .raw_animation, 1, limits);
    defer allocator.free(bytes);
    var payload = std.Io.Reader.fixed(bytes);
    const name = try readString(allocator, &payload, limits);
    defer allocator.free(name);
    const duration = try readF32(&payload);
    const count = try payload.takeInt(u32, .little);
    if (count > animation.max_joints or count > limits.max_collection_items) {
        return Error.InvalidLength;
    }
    var result = try offline.RawAnimation.init(allocator, name, duration, count);
    errdefer result.deinit();
    for (result.tracks) |*track| {
        track.translations = try readTimedFloat3(offline.TranslationKey, allocator, &payload, limits);
        track.rotations = try readTimedQuaternion(allocator, &payload, limits);
        track.scales = try readTimedFloat3(offline.ScaleKey, allocator, &payload, limits);
    }
    if (payload.bufferedLen() != 0) return Error.TrailingPayloadData;
    if (!result.validate()) return animation.Error.InvalidKeyframe;
    return result;
}

fn writeRawJoint(writer: *std.Io.Writer, joint: offline.RawJoint) !void {
    try writeString(writer, joint.name);
    try writeTransform(writer, joint.transform);
    if (joint.children.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try writer.writeInt(u32, @intCast(joint.children.len), .little);
    for (joint.children) |child| try writeRawJoint(writer, child);
}

pub fn writeRawSkeleton(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: offline.RawSkeleton,
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    if (value.roots.len > std.math.maxInt(u32)) return Error.InvalidLength;
    try payload.writer.writeInt(u32, @intCast(value.roots.len), .little);
    for (value.roots) |root| try writeRawJoint(&payload.writer, root);
    try finishPayload(allocator, writer, .raw_skeleton, 1, &payload);
}

fn readRawJoint(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
    remaining: *u32,
) !offline.RawJoint {
    if (remaining.* == 0) return Error.InvalidLength;
    remaining.* -= 1;
    const name = try readString(allocator, reader, limits);
    errdefer allocator.free(name);
    const transform = try readTransform(reader);
    const child_count = try reader.takeInt(u32, .little);
    if (child_count > remaining.*) return Error.InvalidLength;
    const children = try allocator.alloc(offline.RawJoint, child_count);
    errdefer allocator.free(children);
    var initialized: usize = 0;
    errdefer for (children[0..initialized]) |*child| deinitRawJoint(allocator, child);
    for (children) |*child| {
        child.* = try readRawJoint(allocator, reader, limits, remaining);
        initialized += 1;
    }
    return .{ .name = name, .transform = transform, .children = children };
}

fn deinitRawJoint(allocator: std.mem.Allocator, joint: *offline.RawJoint) void {
    for (joint.children) |*child| deinitRawJoint(allocator, child);
    allocator.free(joint.children);
    allocator.free(joint.name);
}

pub fn readRawSkeleton(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: ReadLimits,
) !offline.RawSkeleton {
    const bytes = try readPayload(allocator, reader, .raw_skeleton, 1, limits);
    defer allocator.free(bytes);
    var payload = std.Io.Reader.fixed(bytes);
    const root_count = try payload.takeInt(u32, .little);
    if (root_count > limits.max_collection_items) return Error.InvalidLength;
    const roots = try allocator.alloc(offline.RawJoint, root_count);
    errdefer allocator.free(roots);
    var initialized: usize = 0;
    errdefer for (roots[0..initialized]) |*root| deinitRawJoint(allocator, root);
    var remaining: u32 = @min(limits.max_collection_items, @as(u32, animation.max_joints));
    for (roots) |*root| {
        root.* = try readRawJoint(allocator, &payload, limits, &remaining);
        initialized += 1;
    }
    if (payload.bufferedLen() != 0) return Error.TrailingPayloadData;
    return .{ .allocator = allocator, .roots = roots };
}

test "native header round trip" {
    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writeHeader(&writer, .{ .kind = .animation, .schema_version = 1, .payload_len = 42 });
    var reader = std.Io.Reader.fixed(writer.buffered());
    const header = try readHeader(&reader, .{});
    try std.testing.expectEqual(ObjectKind.animation, header.kind);
    try std.testing.expectEqual(@as(u64, 42), header.payload_len);
}

test "native skeleton and animation round trip" {
    const allocator = std.testing.allocator;
    var skeleton = try animation.Skeleton.init(allocator, &.{
        .{ .name = "root", .parent = animation.no_parent },
        .{ .name = "child", .parent = 0, .rest_pose = .{ .translation = .{ 0, 2, 0 } } },
    });
    defer skeleton.deinit();
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try writeSkeleton(allocator, &bytes.writer, skeleton);
    var skeleton_reader = std.Io.Reader.fixed(bytes.writer.buffered());
    var loaded_skeleton = try readSkeleton(allocator, &skeleton_reader, .{});
    defer loaded_skeleton.deinit();
    try std.testing.expectEqualStrings("child", loaded_skeleton.names[1]);
    try std.testing.expectEqual(@as(i16, 0), loaded_skeleton.parents[1]);

    var value = try animation.Animation.init(allocator, "clip", 2, &.{
        .{ .translations = &.{
            .{ .ratio = 0, .value = @splat(0) },
            .{ .ratio = 1, .value = .{ 3, 0, 0 } },
        } },
    });
    defer value.deinit();
    var animation_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer animation_bytes.deinit();
    try writeAnimation(allocator, &animation_bytes.writer, value);
    var animation_reader = std.Io.Reader.fixed(animation_bytes.writer.buffered());
    var loaded_animation = try readAnimation(allocator, &animation_reader, .{});
    defer loaded_animation.deinit();
    try std.testing.expectEqualStrings("clip", loaded_animation.name);
    try std.testing.expectEqual(@as(usize, 2), loaded_animation.tracks[0].translations.len);

    var track = try animation.Float3Track.init(allocator, "position", &.{
        .{ .ratio = 0, .value = @splat(0) },
        .{ .ratio = 0.5, .value = .{ 0, 0, 4 } },
        .{ .ratio = 1, .value = @splat(0) },
    }, .linear);
    track.keys[1].interpolation = .step;
    defer track.deinit();
    var track_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer track_bytes.deinit();
    try writeTrack(math.Vec3f32, allocator, &track_bytes.writer, track);
    var track_reader = std.Io.Reader.fixed(track_bytes.writer.buffered());
    var loaded_track = try readTrack(math.Vec3f32, allocator, &track_reader, .{});
    defer loaded_track.deinit();
    try std.testing.expectEqualStrings("position", loaded_track.name);
    try std.testing.expectEqual(animation.Interpolation.step, loaded_track.keys[1].interpolation);
    try std.testing.expectEqual(@as(f32, 4), loaded_track.sampleAt(0.75)[2]);

    var raw_track = try offline.RawFloatTrack.init(allocator, "raw", &.{
        .{ .interpolation = .linear, .ratio = 0, .value = 1 },
        .{ .interpolation = .step, .ratio = 1, .value = 2 },
    });
    defer raw_track.deinit();
    var raw_track_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer raw_track_bytes.deinit();
    try writeRawTrack(f32, allocator, &raw_track_bytes.writer, raw_track);
    var raw_track_reader = std.Io.Reader.fixed(raw_track_bytes.writer.buffered());
    var loaded_raw_track = try readRawTrack(f32, allocator, &raw_track_reader, .{});
    defer loaded_raw_track.deinit();
    try std.testing.expectEqual(animation.Interpolation.step, loaded_raw_track.keys[1].interpolation);

    var raw_animation = try offline.RawAnimation.init(allocator, "source", 1, 1);
    defer raw_animation.deinit();
    raw_animation.tracks[0].translations = try allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = @splat(0) },
        .{ .time = 1, .value = .{ 2, 0, 0 } },
    });
    var raw_animation_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer raw_animation_bytes.deinit();
    try writeRawAnimation(allocator, &raw_animation_bytes.writer, raw_animation);
    var raw_animation_reader = std.Io.Reader.fixed(raw_animation_bytes.writer.buffered());
    var loaded_raw_animation = try readRawAnimation(allocator, &raw_animation_reader, .{});
    defer loaded_raw_animation.deinit();
    try std.testing.expectEqual(@as(f32, 2), loaded_raw_animation.tracks[0].translations[1].value[0]);

    const roots = try allocator.alloc(offline.RawJoint, 1);
    roots[0] = .{
        .name = try allocator.dupe(u8, "root"),
        .children = try allocator.alloc(offline.RawJoint, 0),
    };
    var raw_skeleton: offline.RawSkeleton = .{ .allocator = allocator, .roots = roots };
    defer raw_skeleton.deinit();
    var raw_skeleton_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer raw_skeleton_bytes.deinit();
    try writeRawSkeleton(allocator, &raw_skeleton_bytes.writer, raw_skeleton);
    var raw_skeleton_reader = std.Io.Reader.fixed(raw_skeleton_bytes.writer.buffered());
    var loaded_raw_skeleton = try readRawSkeleton(allocator, &raw_skeleton_reader, .{});
    defer loaded_raw_skeleton.deinit();
    try std.testing.expectEqualStrings("root", loaded_raw_skeleton.roots[0].name);
}

test "native mesh round trip" {
    const allocator = std.testing.allocator;
    const parts = try allocator.alloc(geometry.MeshPart, 1);
    parts[0] = .{
        .positions = try allocator.dupe(f32, &.{ 0, 0, 0, 1, 0, 0, 0, 1, 0 }),
        .normals = try allocator.dupe(f32, &.{ 0, 0, 1, 0, 0, 1, 0, 0, 1 }),
        .colors = try allocator.dupe(u8, &.{ 255, 0, 0, 255 }),
        .joint_indices = try allocator.dupe(u16, &.{ 0, 0, 0 }),
        .joint_weights = try allocator.dupe(f32, &.{ 1, 1, 1 }),
    };
    var mesh: geometry.Mesh = .{
        .allocator = allocator,
        .parts = parts,
        .triangle_indices = try allocator.dupe(u16, &.{ 0, 1, 2 }),
        .joint_remaps = try allocator.dupe(u16, &.{0}),
        .inverse_bind_poses = try allocator.dupe(math.Float4x4, &.{math.Float4x4.identity}),
    };
    defer mesh.deinit();
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try writeMesh(allocator, &bytes.writer, mesh);
    var reader = std.Io.Reader.fixed(bytes.writer.buffered());
    var loaded = try readMesh(allocator, &reader, .{});
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 3), loaded.parts[0].vertexCount());
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, loaded.triangle_indices);
    try std.testing.expectEqual(@as(f32, 1), loaded.inverse_bind_poses[0].cols[3][3]);
}
