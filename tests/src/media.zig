const std = @import("std");
const ozz = @import("zig_ozz_animation");
const h = @import("helpers.zig");

const Fixture = struct {
    name: []const u8,
    kind: ozz.legacy.Kind,
    objects: usize = 1,
    following_kind: ?ozz.legacy.Kind = null,
};

const fixtures = [_]Fixture{
    .{ .name = "arnaud_mesh.ozz", .kind = .sample_mesh },
    .{ .name = "arnaud_mesh_4.ozz", .kind = .sample_mesh },
    .{ .name = "astro_max_animation.ozz", .kind = .animation },
    .{ .name = "astro_max_skeleton.ozz", .kind = .skeleton },
    .{ .name = "astro_maya_animation.ozz", .kind = .animation },
    .{ .name = "astro_maya_skeleton.ozz", .kind = .skeleton },
    .{ .name = "baked_animation.ozz", .kind = .animation },
    .{ .name = "baked_skeleton.ozz", .kind = .skeleton },
    .{ .name = "floor.ozz", .kind = .sample_mesh, .objects = 6 },
    .{ .name = "pab_atlas.ozz", .kind = .animation },
    .{ .name = "pab_atlas_motion_track.ozz", .kind = .float3_track, .objects = 2, .following_kind = .quaternion_track },
    .{ .name = "pab_atlas_no_motion.ozz", .kind = .animation },
    .{ .name = "pab_atlas_raw.ozz", .kind = .raw_animation },
    .{ .name = "pab_crackhead.ozz", .kind = .animation },
    .{ .name = "pab_crackhead_additive.ozz", .kind = .animation },
    .{ .name = "pab_crossarms.ozz", .kind = .animation },
    .{ .name = "pab_curl_additive.ozz", .kind = .animation },
    .{ .name = "pab_jog.ozz", .kind = .animation },
    .{ .name = "pab_jog_motion_track.ozz", .kind = .float3_track, .objects = 2, .following_kind = .quaternion_track },
    .{ .name = "pab_jog_no_motion.ozz", .kind = .animation },
    .{ .name = "pab_jog_raw.ozz", .kind = .raw_animation },
    .{ .name = "pab_run.ozz", .kind = .animation },
    .{ .name = "pab_run_motion_track.ozz", .kind = .float3_track, .objects = 2, .following_kind = .quaternion_track },
    .{ .name = "pab_run_no_motion.ozz", .kind = .animation },
    .{ .name = "pab_run_raw.ozz", .kind = .raw_animation },
    .{ .name = "pab_skeleton.ozz", .kind = .skeleton },
    .{ .name = "pab_splay_additive.ozz", .kind = .animation },
    .{ .name = "pab_walk.ozz", .kind = .animation },
    .{ .name = "pab_walk_motion_track.ozz", .kind = .float3_track, .objects = 2, .following_kind = .quaternion_track },
    .{ .name = "pab_walk_no_motion.ozz", .kind = .animation },
    .{ .name = "pab_walk_raw.ozz", .kind = .raw_animation },
    .{ .name = "robot_animation.ozz", .kind = .animation },
    .{ .name = "robot_skeleton.ozz", .kind = .skeleton },
    .{ .name = "robot_track_grasp.ozz", .kind = .float_track },
    .{ .name = "ruby_animation.ozz", .kind = .animation },
    .{ .name = "ruby_mesh.ozz", .kind = .sample_mesh, .objects = 10 },
    .{ .name = "ruby_skeleton.ozz", .kind = .skeleton },
    .{ .name = "seymour_animation.ozz", .kind = .animation },
    .{ .name = "seymour_skeleton.ozz", .kind = .skeleton },
};

fn readFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const relative = try std.fs.path.join(allocator, &.{ "media/bin", name });
    defer allocator.free(relative);
    const path = try h.fixturePath(allocator, relative);
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024 * 1024));
}

fn expectFloat(expected: f32, actual: f32) !void {
    try std.testing.expectApproxEqRel(expected, actual, 1e-5);
    try std.testing.expectApproxEqAbs(expected, actual, 1e-4);
}

fn expectTransform(expected: ozz.math.Transform, actual: ozz.math.Transform) !void {
    try h.expectFloat3(expected.translation, actual.translation);
    try h.expectQuaternion(expected.rotation, actual.rotation);
    try h.expectFloat3(expected.scale, actual.scale);
}

fn expectSkeleton(expected: ozz.animation.Skeleton, actual: ozz.animation.Skeleton) !void {
    try std.testing.expectEqualSlices(i16, expected.parents, actual.parents);
    try std.testing.expectEqual(expected.names.len, actual.names.len);
    for (expected.names, actual.names) |a, b| try std.testing.expectEqualStrings(a, b);
    for (0..expected.numJoints()) |joint| {
        try expectTransform(expected.jointRestPose(joint), actual.jointRestPose(joint));
    }
}

fn expectAnimation(expected: ozz.animation.Animation, actual: ozz.animation.Animation) !void {
    try std.testing.expectEqualStrings(expected.name, actual.name);
    try expectFloat(expected.duration, actual.duration);
    try std.testing.expectEqual(expected.tracks.len, actual.tracks.len);
    for (expected.tracks, actual.tracks) |a, b| {
        try std.testing.expectEqualSlices(ozz.animation.Float3Key, a.translations, b.translations);
        try std.testing.expectEqualSlices(ozz.animation.QuaternionKey, a.rotations, b.rotations);
        try std.testing.expectEqualSlices(ozz.animation.Float3Key, a.scales, b.scales);
    }
}

fn expectRawAnimation(expected: ozz.offline.RawAnimation, actual: ozz.offline.RawAnimation) !void {
    try std.testing.expectEqualStrings(expected.name, actual.name);
    try expectFloat(expected.duration, actual.duration);
    try std.testing.expectEqual(expected.tracks.len, actual.tracks.len);
    for (expected.tracks, actual.tracks) |a, b| {
        try std.testing.expectEqualSlices(ozz.offline.TranslationKey, a.translations, b.translations);
        try std.testing.expectEqualSlices(ozz.offline.RotationKey, a.rotations, b.rotations);
        try std.testing.expectEqualSlices(ozz.offline.ScaleKey, a.scales, b.scales);
    }
}

fn expectMesh(expected: ozz.geometry.Mesh, actual: ozz.geometry.Mesh) !void {
    try std.testing.expectEqual(expected.parts.len, actual.parts.len);
    for (expected.parts, actual.parts) |a, b| {
        try std.testing.expectEqualSlices(f32, a.positions, b.positions);
        try std.testing.expectEqualSlices(f32, a.normals, b.normals);
        try std.testing.expectEqualSlices(f32, a.tangents, b.tangents);
        try std.testing.expectEqualSlices(f32, a.uvs, b.uvs);
        try std.testing.expectEqualSlices(u8, a.colors, b.colors);
        try std.testing.expectEqualSlices(u16, a.joint_indices, b.joint_indices);
        try std.testing.expectEqualSlices(f32, a.joint_weights, b.joint_weights);
    }
    try std.testing.expectEqualSlices(u16, expected.triangle_indices, actual.triangle_indices);
    try std.testing.expectEqualSlices(u16, expected.joint_remaps, actual.joint_remaps);
    try std.testing.expectEqualSlices(ozz.math.Float4x4, expected.inverse_bind_poses, actual.inverse_bind_poses);
}

fn nativeSkeletonRoundTrip(allocator: std.mem.Allocator, value: ozz.animation.Skeleton) !void {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try ozz.io.writeSkeleton(allocator, &bytes.writer, value);
    var reader = std.Io.Reader.fixed(bytes.writer.buffered());
    var decoded = try ozz.io.readSkeleton(allocator, &reader, .{});
    defer decoded.deinit();
    try expectSkeleton(value, decoded);
    try std.testing.expectEqual(@as(usize, 0), reader.bufferedLen());
}

fn nativeAnimationRoundTrip(allocator: std.mem.Allocator, value: ozz.animation.Animation) !void {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try ozz.io.writeAnimation(allocator, &bytes.writer, value);
    var reader = std.Io.Reader.fixed(bytes.writer.buffered());
    var decoded = try ozz.io.readAnimation(allocator, &reader, .{});
    defer decoded.deinit();
    try expectAnimation(value, decoded);
    try std.testing.expectEqual(@as(usize, 0), reader.bufferedLen());
}

fn nativeRawAnimationRoundTrip(allocator: std.mem.Allocator, value: ozz.offline.RawAnimation) !void {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try ozz.io.writeRawAnimation(allocator, &bytes.writer, value);
    var reader = std.Io.Reader.fixed(bytes.writer.buffered());
    var decoded = try ozz.io.readRawAnimation(allocator, &reader, .{});
    defer decoded.deinit();
    try expectRawAnimation(value, decoded);
    try std.testing.expectEqual(@as(usize, 0), reader.bufferedLen());
}

fn nativeMeshRoundTrip(allocator: std.mem.Allocator, value: ozz.geometry.Mesh) !void {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try ozz.io.writeMesh(allocator, &bytes.writer, value);
    var reader = std.Io.Reader.fixed(bytes.writer.buffered());
    var decoded = try ozz.io.readMesh(allocator, &reader, .{});
    defer decoded.deinit();
    try expectMesh(value, decoded);
    try std.testing.expectEqual(@as(usize, 0), reader.bufferedLen());
}

fn nativeTrackRoundTrip(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: ozz.animation.Track(T),
) !void {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try ozz.io.writeTrack(T, allocator, &bytes.writer, value);
    var reader = std.Io.Reader.fixed(bytes.writer.buffered());
    var decoded = try ozz.io.readTrack(T, allocator, &reader, .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings(value.name, decoded.name);
    try std.testing.expectEqualSlices(ozz.animation.Track(T).Key, value.keys, decoded.keys);
    try std.testing.expectEqual(@as(usize, 0), reader.bufferedLen());
}

fn prefixedView(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    offset: usize,
) ![]const u8 {
    if (offset == 0) return bytes;
    const view = try allocator.alloc(u8, bytes.len - offset + 1);
    view[0] = bytes[0];
    @memcpy(view[1..], bytes[offset..]);
    return view;
}

fn freePrefixed(allocator: std.mem.Allocator, allocated: bool, view: []const u8) void {
    if (allocated) allocator.free(@constCast(view));
}

fn validateFixture(fixture: Fixture) !void {
    const allocator = std.testing.allocator;
    const bytes = try readFixture(allocator, fixture.name);
    defer allocator.free(bytes);
    try std.testing.expectEqual(fixture.kind, try ozz.legacy.detect(bytes));

    var offset: usize = 0;
    var object_count: usize = 0;
    while (offset < bytes.len) {
        const allocated_view = offset != 0;
        const view = try prefixedView(allocator, bytes, offset);
        defer freePrefixed(allocator, allocated_view, view);
        const kind = try ozz.legacy.detect(view);
        const expected_kind = if (object_count == 0)
            fixture.kind
        else
            fixture.following_kind orelse fixture.kind;
        try std.testing.expectEqual(expected_kind, kind);
        var consumed = view.len;
        switch (kind) {
            .skeleton => {
                var value = try ozz.legacy.readSkeleton(allocator, view, .{});
                defer value.deinit();
                try std.testing.expect(value.numJoints() > 0);
                try nativeSkeletonRoundTrip(allocator, value);
            },
            .animation => {
                var value = try ozz.legacy.readAnimation(allocator, view, .{});
                defer value.deinit();
                try std.testing.expect(value.duration > 0);
                var context = try ozz.animation.SamplingContext.init(allocator, value.numTracks());
                defer context.deinit();
                const pose = try allocator.alloc(ozz.math.SoaTransform, value.numSoaTracks());
                defer allocator.free(pose);
                try ozz.animation.sample(&value, 0.5, &context, pose);
                try nativeAnimationRoundTrip(allocator, value);
            },
            .raw_animation => {
                var value = try ozz.legacy.readRawAnimation(allocator, view, .{});
                defer value.deinit();
                try std.testing.expect(value.validate());
                var runtime = try ozz.offline.AnimationBuilder.build(allocator, value);
                defer runtime.deinit();
                try nativeRawAnimationRoundTrip(allocator, value);
            },
            .float_track => {
                var value = try ozz.legacy.readTrackPrefix(f32, allocator, view, .{}, &consumed);
                defer value.deinit();
                _ = value.sampleAt(0.5);
                try nativeTrackRoundTrip(f32, allocator, value);
            },
            .float3_track => {
                var value = try ozz.legacy.readTrackPrefix(ozz.math.Float3, allocator, view, .{}, &consumed);
                defer value.deinit();
                if (value.keys.len != 0) {
                    const sample = value.sampleAt(0.5);
                    try std.testing.expect(std.math.isFinite(sample.x));
                }
                try nativeTrackRoundTrip(ozz.math.Float3, allocator, value);
            },
            .quaternion_track => {
                var value = try ozz.legacy.readTrackPrefix(ozz.math.Quaternion, allocator, view, .{}, &consumed);
                defer value.deinit();
                if (value.keys.len != 0) {
                    const sample = value.sampleAt(0.5);
                    try std.testing.expect(std.math.isFinite(sample.w));
                }
                try nativeTrackRoundTrip(ozz.math.Quaternion, allocator, value);
            },
            .sample_mesh => {
                var value = try ozz.legacy.readMeshPrefix(allocator, view, .{}, &consumed);
                defer value.deinit();
                try std.testing.expect(value.vertexCount() > 0);
                try nativeMeshRoundTrip(allocator, value);
            },
            else => return error.UnexpectedFixtureKind,
        }
        try std.testing.expect(consumed > 1 and consumed <= view.len);
        offset += if (offset == 0) consumed else consumed - 1;
        object_count += 1;
    }
    try std.testing.expectEqual(bytes.len, offset);
    try std.testing.expectEqual(fixture.objects, object_count);
}

test "all upstream binary media decode and round trip semantically" {
    inline for (fixtures) |fixture| try validateFixture(fixture);
}

test "binary media manifest exactly covers the pinned fixture corpus" {
    const allocator = std.testing.allocator;
    const root = try h.fixturePath(allocator, "media/bin");
    defer allocator.free(root);
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ozz")) continue;
        count += 1;
        var found = false;
        for (fixtures) |fixture| {
            if (std.mem.eql(u8, fixture.name, entry.name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(fixtures.len, count);
}

fn validateSkinnedFixture(
    skeleton_name: []const u8,
    animation_name: []const u8,
    mesh_name: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const skeleton_bytes = try readFixture(allocator, skeleton_name);
    defer allocator.free(skeleton_bytes);
    var skeleton = try ozz.legacy.readSkeleton(allocator, skeleton_bytes, .{});
    defer skeleton.deinit();

    const animation_bytes = try readFixture(allocator, animation_name);
    defer allocator.free(animation_bytes);
    var animation = try ozz.legacy.readAnimation(allocator, animation_bytes, .{});
    defer animation.deinit();
    try std.testing.expectEqual(skeleton.numJoints(), animation.numTracks());

    const mesh_bytes = try readFixture(allocator, mesh_name);
    defer allocator.free(mesh_bytes);
    var consumed: usize = 0;
    var mesh = try ozz.legacy.readMeshPrefix(allocator, mesh_bytes, .{}, &consumed);
    defer mesh.deinit();
    try std.testing.expect(consumed > 0);

    var context = try ozz.animation.SamplingContext.init(allocator, animation.numTracks());
    defer context.deinit();
    const pose = try allocator.alloc(ozz.math.SoaTransform, animation.numSoaTracks());
    defer allocator.free(pose);
    try ozz.animation.sample(&animation, 0.5, &context, pose);
    const models = try allocator.alloc(ozz.math.Float4x4, skeleton.numJoints());
    defer allocator.free(models);
    try ozz.animation.localToModel(.{ .skeleton = &skeleton, .input = pose }, models);

    try std.testing.expectEqual(mesh.joint_remaps.len, mesh.inverse_bind_poses.len);
    const skinning_matrices = try allocator.alloc(ozz.math.Float4x4, mesh.joint_remaps.len);
    defer allocator.free(skinning_matrices);
    for (skinning_matrices, mesh.joint_remaps, mesh.inverse_bind_poses) |*matrix, joint, inverse_bind| {
        try std.testing.expect(joint < models.len);
        matrix.* = ozz.math.Float4x4.mul(models[joint], inverse_bind);
    }

    const part = mesh.parts[0];
    const influences = part.influencesCount();
    try std.testing.expect(influences > 0);
    const input = [_]ozz.math.Float3{.{
        .x = part.positions[0],
        .y = part.positions[1],
        .z = part.positions[2],
    }};
    const weight_count = if (part.joint_weights.len == part.vertexCount() * influences)
        influences
    else
        influences - 1;
    var output: [1]ozz.math.Float3 = undefined;
    try ozz.geometry.skin(.{
        .joint_matrices = skinning_matrices,
        .joint_indices = part.joint_indices[0..influences],
        .joint_weights = part.joint_weights[0..weight_count],
        .input_positions = &input,
        .output_positions = &output,
        .influences_count = influences,
    });
    try std.testing.expect(std.math.isFinite(output[0].x));
    try std.testing.expect(std.math.isFinite(output[0].y));
    try std.testing.expect(std.math.isFinite(output[0].z));
}

test "upstream character assets sample through local-to-model and skinning" {
    try validateSkinnedFixture("pab_skeleton.ozz", "pab_walk.ozz", "arnaud_mesh.ozz");
    try validateSkinnedFixture("ruby_skeleton.ozz", "ruby_animation.ozz", "ruby_mesh.ozz");
}

test "representative upstream media truncation is rejected" {
    inline for (.{
        "pab_skeleton.ozz",
        "pab_walk.ozz",
        "robot_track_grasp.ozz",
        "arnaud_mesh.ozz",
    }) |name| {
        const bytes = try readFixture(std.testing.allocator, name);
        defer std.testing.allocator.free(bytes);
        const truncated = bytes[0 .. bytes.len - 1];
        const kind = try ozz.legacy.detect(truncated);
        switch (kind) {
            .skeleton => try std.testing.expectError(
                ozz.legacy.Error.TruncatedArchive,
                ozz.legacy.readSkeleton(std.testing.allocator, truncated, .{}),
            ),
            .animation => try std.testing.expectError(
                ozz.legacy.Error.TruncatedArchive,
                ozz.legacy.readAnimation(std.testing.allocator, truncated, .{}),
            ),
            .float_track => try std.testing.expectError(
                ozz.legacy.Error.TruncatedArchive,
                ozz.legacy.readTrack(f32, std.testing.allocator, truncated, .{}),
            ),
            .sample_mesh => try std.testing.expectError(
                ozz.legacy.Error.TruncatedArchive,
                ozz.legacy.readMesh(std.testing.allocator, truncated, .{}),
            ),
            else => unreachable,
        }
    }
}
