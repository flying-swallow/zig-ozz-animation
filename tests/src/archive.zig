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
    try std.testing.expect(skeleton.numJoints() > 0);
}

test "Versioning/SkeletonSerialize big endian" {
    const bytes = try readFixture(std.testing.allocator, "media/bin/versioning/skeleton_v2_be.ozz");
    defer std.testing.allocator.free(bytes);
    var skeleton = try ozz.legacy.readSkeleton(std.testing.allocator, bytes, .{});
    defer skeleton.deinit();
    try std.testing.expect(skeleton.numJoints() > 0);
}

test "Versioning/SkeletonSerialize unsupported" {
    const bytes = try readFixture(std.testing.allocator, "media/bin/versioning/skeleton_v1_le.ozz");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(
        ozz.legacy.Error.UnsupportedVersion,
        ozz.legacy.readSkeleton(std.testing.allocator, bytes, .{}),
    );
}

test "Versioning/AnimationSerialize little endian" {
    const bytes = try readFixture(std.testing.allocator, "media/bin/versioning/animation_v7_le.ozz");
    defer std.testing.allocator.free(bytes);
    var animation = try ozz.legacy.readAnimation(std.testing.allocator, bytes, .{});
    defer animation.deinit();
    try std.testing.expect(animation.duration > 0);
}

test "Versioning/AnimationSerialize big endian" {
    const bytes = try readFixture(std.testing.allocator, "media/bin/versioning/animation_v7_be.ozz");
    defer std.testing.allocator.free(bytes);
    var animation = try ozz.legacy.readAnimation(std.testing.allocator, bytes, .{});
    defer animation.deinit();
    try std.testing.expect(animation.duration > 0);
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
        try std.testing.expect(skeleton.roots.len > 0);
    }
}

test "Versioning/RawAnimationSerialize" {
    inline for (.{ "raw_animation_v3_le.ozz", "raw_animation_v3_be.ozz" }) |name| {
        const relative = "media/bin/versioning/" ++ name;
        const bytes = try readFixture(std.testing.allocator, relative);
        defer std.testing.allocator.free(bytes);
        var animation = try ozz.legacy.readRawAnimation(std.testing.allocator, bytes, .{});
        defer animation.deinit();
        try std.testing.expect(animation.duration > 0);
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
    try std.testing.expectEqualStrings("child", decoded.names[1]);
    try h.expectFloat(2, decoded.jointRestPose(1).translation.x);
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
    try std.testing.expectEqual(ozz.animation.Interpolation.step, decoded.keys[0].interpolation);
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
