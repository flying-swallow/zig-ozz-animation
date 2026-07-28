const std = @import("std");
const ozz = @import("zig_ozz_animation");
const h = @import("helpers.zig");

fn readFixture(allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    const path = try h.fixturePath(allocator, relative);
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(16 * 1024 * 1024));
}

test "Versioning/SkeletonSerialize little endian" {
    const bytes = try readFixture(std.testing.allocator, "media/bin/versioning/skeleton_v2_le.ozz");
    defer std.testing.allocator.free(bytes);
    var skeleton = try ozz.legacy.readSkeleton(std.testing.allocator, bytes, .{});
    defer skeleton.deinit();
    try std.testing.expectEqual(@as(usize, 67), skeleton.numJoints());
    try std.testing.expectEqualStrings("Hips", skeleton.names[0]);
}

test "Versioning/SkeletonSerialize big endian" {
    const bytes = try readFixture(std.testing.allocator, "media/bin/versioning/skeleton_v2_be.ozz");
    defer std.testing.allocator.free(bytes);
    var skeleton = try ozz.legacy.readSkeleton(std.testing.allocator, bytes, .{});
    defer skeleton.deinit();
    try std.testing.expectEqual(@as(usize, 67), skeleton.numJoints());
    try std.testing.expectEqualStrings("Hips", skeleton.names[0]);
}

test "Versioning/SkeletonSerialize unsupported" {
    const bytes = try readFixture(std.testing.allocator, "media/bin/versioning/skeleton_v1_le.ozz");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(
        ozz.legacy.Error.UnsupportedVersion,
        ozz.legacy.readSkeleton(std.testing.allocator, bytes, .{}),
    );
}

test "Write/SkeletonSerialize C++ compatible" {
    const allocator = std.testing.allocator;
    var skeleton = try ozz.animation.Skeleton.init(allocator, &.{
        .{
            .name = "root",
            .parent = ozz.animation.no_parent,
            .rest_pose = .{
                .translation = .{ .x = 1, .y = 2, .z = 3 },
                .rotation = ozz.math.Quaternion.fromAxisAngle(.y_axis, 0.7),
                .scale = .{ .x = 2, .y = 3, .z = 4 },
            },
        },
        .{ .name = "child", .parent = 0, .rest_pose = .{ .translation = .x_axis } },
    });
    defer skeleton.deinit();

    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
        var bytes: std.Io.Writer.Allocating = .init(allocator);
        defer bytes.deinit();
        try ozz.legacy.writeSkeleton(&bytes.writer, skeleton, .{ .endian = endian });
        try std.testing.expectEqual(ozz.legacy.Kind.skeleton, try ozz.legacy.detect(bytes.writer.buffered()));
        var decoded = try ozz.legacy.readSkeleton(allocator, bytes.writer.buffered(), .{});
        defer decoded.deinit();
        try std.testing.expectEqualSlices(i16, skeleton.parents, decoded.parents);
        for (skeleton.names, decoded.names) |expected, actual| {
            try std.testing.expectEqualStrings(expected, actual);
        }
        for (0..skeleton.numJoints()) |joint| {
            try h.expectTransform(skeleton.jointRestPose(joint), decoded.jointRestPose(joint));
        }
    }
}

test "Versioning/AnimationSerialize little endian" {
    const bytes = try readFixture(std.testing.allocator, "media/bin/versioning/animation_v7_le.ozz");
    defer std.testing.allocator.free(bytes);
    var animation = try ozz.legacy.readAnimation(std.testing.allocator, bytes, .{});
    defer animation.deinit();
    try std.testing.expectEqual(@as(usize, 67), animation.numTracks());
    try h.expectFloat(0.66666667, animation.duration);
    try std.testing.expectEqualStrings("run", animation.name);
}

test "Versioning/AnimationSerialize big endian" {
    const bytes = try readFixture(std.testing.allocator, "media/bin/versioning/animation_v7_be.ozz");
    defer std.testing.allocator.free(bytes);
    var animation = try ozz.legacy.readAnimation(std.testing.allocator, bytes, .{});
    defer animation.deinit();
    try std.testing.expectEqual(@as(usize, 67), animation.numTracks());
    try h.expectFloat(0.66666667, animation.duration);
    try std.testing.expectEqualStrings("run", animation.name);
}

test "Versioning/AnimationSerialize unsupported versions" {
    inline for (1..7) |version| {
        const relative = try std.fmt.allocPrint(
            std.testing.allocator,
            "media/bin/versioning/animation_v{d}_le.ozz",
            .{version},
        );
        defer std.testing.allocator.free(relative);
        const bytes = try readFixture(std.testing.allocator, relative);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectError(
            ozz.legacy.Error.UnsupportedVersion,
            ozz.legacy.readAnimation(std.testing.allocator, bytes, .{}),
        );
    }
}

test "Versioning/RawSkeletonSerialize" {
    inline for (.{ "raw_skeleton_v1_le.ozz", "raw_skeleton_v1_be.ozz" }) |name| {
        const relative = "media/bin/versioning/" ++ name;
        const bytes = try readFixture(std.testing.allocator, relative);
        defer std.testing.allocator.free(bytes);
        var skeleton = try ozz.legacy.readRawSkeleton(std.testing.allocator, bytes, .{});
        defer skeleton.deinit();
        try std.testing.expectEqual(@as(usize, 67), skeleton.numJoints());
        try std.testing.expectEqualStrings("Hips", skeleton.roots[0].name);
    }
}

test "Versioning/RawAnimationSerialize" {
    inline for (.{ "raw_animation_v3_le.ozz", "raw_animation_v3_be.ozz" }) |name| {
        const relative = "media/bin/versioning/" ++ name;
        const bytes = try readFixture(std.testing.allocator, relative);
        defer std.testing.allocator.free(bytes);
        var animation = try ozz.legacy.readRawAnimation(std.testing.allocator, bytes, .{});
        defer animation.deinit();
        try std.testing.expectEqual(@as(usize, 67), animation.tracks.len);
        try h.expectFloat(0.66666667, animation.duration);
        try std.testing.expectEqualStrings("run", animation.name);
    }
}

test "Empty/Filled native archive round trips" {
    const allocator = std.testing.allocator;
    var skeleton = try ozz.animation.Skeleton.init(allocator, &.{
        .{ .name = "root", .parent = ozz.animation.no_parent },
        .{ .name = "child", .parent = 0, .rest_pose = .{ .translation = .{ .x = 2 } } },
    });
    defer skeleton.deinit();

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();
    try ozz.io.writeSkeleton(allocator, &allocating.writer, skeleton);
    var reader = std.Io.Reader.fixed(allocating.writer.buffered());
    var decoded = try ozz.io.readSkeleton(allocator, &reader, .{});
    defer decoded.deinit();
    try std.testing.expectEqualSlices(i16, skeleton.parents, decoded.parents);
    for (skeleton.names, decoded.names) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    for (0..skeleton.numJoints()) |joint| {
        try h.expectTransform(skeleton.jointRestPose(joint), decoded.jointRestPose(joint));
    }
}

test "Empty native archive values round trip" {
    const allocator = std.testing.allocator;

    var skeleton = try ozz.animation.Skeleton.init(allocator, &.{});
    defer skeleton.deinit();
    var skeleton_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer skeleton_bytes.deinit();
    try ozz.io.writeSkeleton(allocator, &skeleton_bytes.writer, skeleton);
    var skeleton_reader = std.Io.Reader.fixed(skeleton_bytes.writer.buffered());
    var decoded_skeleton = try ozz.io.readSkeleton(allocator, &skeleton_reader, .{});
    defer decoded_skeleton.deinit();
    try std.testing.expectEqual(@as(usize, 0), decoded_skeleton.numJoints());

    var animation = try ozz.animation.Animation.init(allocator, "", 0, &.{});
    defer animation.deinit();
    var animation_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer animation_bytes.deinit();
    try ozz.io.writeAnimation(allocator, &animation_bytes.writer, animation);
    var animation_reader = std.Io.Reader.fixed(animation_bytes.writer.buffered());
    var decoded_animation = try ozz.io.readAnimation(allocator, &animation_reader, .{});
    defer decoded_animation.deinit();
    try std.testing.expectEqualStrings("", decoded_animation.name);
    try h.expectFloat(0, decoded_animation.duration);
    try std.testing.expectEqual(@as(usize, 0), decoded_animation.numTracks());

    var raw_animation = try ozz.offline.RawAnimation.init(allocator, "", 1, 0);
    defer raw_animation.deinit();
    var raw_animation_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer raw_animation_bytes.deinit();
    try ozz.io.writeRawAnimation(allocator, &raw_animation_bytes.writer, raw_animation);
    var raw_animation_reader = std.Io.Reader.fixed(raw_animation_bytes.writer.buffered());
    var decoded_raw_animation = try ozz.io.readRawAnimation(allocator, &raw_animation_reader, .{});
    defer decoded_raw_animation.deinit();
    try std.testing.expectEqualStrings("", decoded_raw_animation.name);
    try std.testing.expectEqual(@as(usize, 0), decoded_raw_animation.tracks.len);

    var raw_skeleton = ozz.offline.RawSkeleton{
        .allocator = allocator,
        .roots = try allocator.alloc(ozz.offline.RawJoint, 0),
    };
    defer raw_skeleton.deinit();
    var raw_skeleton_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer raw_skeleton_bytes.deinit();
    try ozz.io.writeRawSkeleton(allocator, &raw_skeleton_bytes.writer, raw_skeleton);
    var raw_skeleton_reader = std.Io.Reader.fixed(raw_skeleton_bytes.writer.buffered());
    var decoded_raw_skeleton = try ozz.io.readRawSkeleton(allocator, &raw_skeleton_reader, .{});
    defer decoded_raw_skeleton.deinit();
    try std.testing.expectEqual(@as(usize, 0), decoded_raw_skeleton.numJoints());
}

test "Native archive framing and payload rejection" {
    const allocator = std.testing.allocator;

    var bad_magic: [24]u8 = @splat(0);
    var bad_magic_reader = std.Io.Reader.fixed(&bad_magic);
    try std.testing.expectError(ozz.io.Error.BadMagic, ozz.io.readHeader(&bad_magic_reader, .{}));

    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try bytes.writer.writeAll(ozz.io.magic);
    try bytes.writer.writeInt(u16, ozz.io.container_version + 1, .little);
    try bytes.writer.writeInt(u16, @backingInt(ozz.io.ObjectKind.skeleton), .little);
    try bytes.writer.writeInt(u32, 1, .little);
    try bytes.writer.writeInt(u64, 0, .little);
    var version_reader = std.Io.Reader.fixed(bytes.writer.buffered());
    try std.testing.expectError(
        ozz.io.Error.UnsupportedContainerVersion,
        ozz.io.readHeader(&version_reader, .{}),
    );

    bytes.writer.end = 0;
    try ozz.io.writeHeader(&bytes.writer, .{
        .kind = .animation,
        .schema_version = 1,
        .payload_len = 0,
    });
    var kind_reader = std.Io.Reader.fixed(bytes.writer.buffered());
    try std.testing.expectError(
        ozz.io.Error.UnexpectedObjectKind,
        ozz.io.readSkeleton(allocator, &kind_reader, .{}),
    );

    bytes.writer.end = 0;
    try ozz.io.writeHeader(&bytes.writer, .{
        .kind = .skeleton,
        .schema_version = 2,
        .payload_len = 0,
    });
    var schema_reader = std.Io.Reader.fixed(bytes.writer.buffered());
    try std.testing.expectError(
        ozz.io.Error.UnsupportedSchemaVersion,
        ozz.io.readSkeleton(allocator, &schema_reader, .{}),
    );

    bytes.writer.end = 0;
    try ozz.io.writeHeader(&bytes.writer, .{
        .kind = .skeleton,
        .schema_version = 1,
        .payload_len = 5,
    });
    try bytes.writer.writeInt(u32, 0, .little);
    try bytes.writer.writeByte(0);
    var trailing_reader = std.Io.Reader.fixed(bytes.writer.buffered());
    try std.testing.expectError(
        ozz.io.Error.TrailingPayloadData,
        ozz.io.readSkeleton(allocator, &trailing_reader, .{}),
    );
}

test "Empty and named native tracks preserve names" {
    const allocator = std.testing.allocator;
    inline for (.{ "", "test name" }) |name| {
        var track = try ozz.animation.Track(f32).initMixed(allocator, name, &.{});
        defer track.deinit();
        var bytes: std.Io.Writer.Allocating = .init(allocator);
        defer bytes.deinit();
        try ozz.io.writeTrack(f32, allocator, &bytes.writer, track);
        var reader = std.Io.Reader.fixed(bytes.writer.buffered());
        var decoded = try ozz.io.readTrack(f32, allocator, &reader, .{});
        defer decoded.deinit();
        try std.testing.expectEqualStrings(name, decoded.name);
        try std.testing.expectEqual(@as(usize, 0), decoded.keys.len);
    }
}

fn roundTripTrack(comptime T: type, value: T) !void {
    const allocator = std.testing.allocator;
    var track = try ozz.animation.Track(T).initMixed(allocator, "track", &.{
        .{ .ratio = 0, .value = value, .interpolation = .step },
        .{ .ratio = 1, .value = value },
    });
    defer track.deinit();
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try ozz.io.writeTrack(T, allocator, &bytes.writer, track);
    var reader = std.Io.Reader.fixed(bytes.writer.buffered());
    var decoded = try ozz.io.readTrack(T, allocator, &reader, .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings("track", decoded.name);
    try std.testing.expectEqual(@as(usize, 2), decoded.keys.len);
    try std.testing.expectEqualSlices(ozz.animation.Track(T).Key, track.keys, decoded.keys);
}

test "FilledFloat/TrackSerialize" {
    try roundTripTrack(f32, 46);
}

test "FilledFloat2/TrackSerialize" {
    try roundTripTrack(ozz.math.Float2, .{ .x = 4, .y = 6 });
}

test "FilledFloat3/TrackSerialize" {
    try roundTripTrack(ozz.math.Float3, .{ .x = 4, .y = 6, .z = 8 });
}

test "FilledFloat4/TrackSerialize" {
    try roundTripTrack(ozz.math.Float4, .{ .x = 4, .y = 6, .z = 8, .w = 10 });
}

test "FilledQuaternion/TrackSerialize" {
    try roundTripTrack(ozz.math.Quaternion, ozz.math.Quaternion.fromAxisAngle(.y_axis, 0.7));
}

fn roundTripRawTrack(comptime T: type, value: T) !void {
    const allocator = std.testing.allocator;
    var track = try ozz.offline.RawTrack(T).init(allocator, "raw", &.{
        .{ .ratio = 0, .value = value, .interpolation = .linear },
        .{ .ratio = 1, .value = value, .interpolation = .step },
    });
    defer track.deinit();
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try ozz.io.writeRawTrack(T, allocator, &bytes.writer, track);
    var reader = std.Io.Reader.fixed(bytes.writer.buffered());
    var decoded = try ozz.io.readRawTrack(T, allocator, &reader, .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings("raw", decoded.name);
    try std.testing.expectEqual(@as(usize, 2), decoded.keys.len);
    try std.testing.expectEqualSlices(ozz.offline.RawTrack(T).Key, track.keys, decoded.keys);
}

test "Filled/RawAnimationSerialize float" {
    try roundTripRawTrack(f32, 46);
}

test "Float2/RawAnimationSerialize" {
    try roundTripRawTrack(ozz.math.Float2, .{ .x = 1, .y = 2 });
}

test "Float3/RawAnimationSerialize" {
    try roundTripRawTrack(ozz.math.Float3, .{ .x = 1, .y = 2, .z = 3 });
}

test "Float4/RawAnimationSerialize" {
    try roundTripRawTrack(ozz.math.Float4, .{ .x = 1, .y = 2, .z = 3, .w = 4 });
}

test "Quaternion/RawAnimationSerialize" {
    try roundTripRawTrack(ozz.math.Quaternion, ozz.math.Quaternion.fromAxisAngle(.x_axis, 0.4));
}
