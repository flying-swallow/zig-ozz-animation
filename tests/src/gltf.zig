const std = @import("std");
const ozz = @import("zig_ozz_animation");
const h = @import("helpers.zig");

fn readFixture(allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    const path = try h.fixturePath(allocator, relative);
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(32 * 1024 * 1024));
}

test "gltf2ozz_bad_content" {
    try std.testing.expectError(
        ozz.gltf.Error.ParseFailed,
        ozz.gltf.importSkeleton(std.testing.allocator, "bad content", 0),
    );
}

test "gltf2ozz_skel_simple" {
    const bytes = try readFixture(std.testing.allocator, "media/gltf/khronos/interpolation_test.gltf");
    defer std.testing.allocator.free(bytes);
    var raw = try ozz.gltf.importSkeleton(std.testing.allocator, bytes, 0);
    defer raw.deinit();
    try std.testing.expect(raw.roots.len > 0);
    var skeleton = try ozz.offline.SkeletonBuilder.build(std.testing.allocator, raw);
    defer skeleton.deinit();
    try std.testing.expect(skeleton.numJoints() > 0);
}

test "gltf2ozz_skel_triangle_node_hierarchy" {
    const bytes = try readFixture(std.testing.allocator, "media/gltf/khronos/triangle.gltf");
    defer std.testing.allocator.free(bytes);
    var raw = try ozz.gltf.importSkeleton(std.testing.allocator, bytes, 0);
    defer raw.deinit();
    try std.testing.expect(raw.roots.len > 0);
}

test "gltf2ozz_skel_cesium" {
    const bytes = try readFixture(std.testing.allocator, "media/gltf/khronos/cesium_man.gltf");
    defer std.testing.allocator.free(bytes);
    var raw = try ozz.gltf.importSkeleton(std.testing.allocator, bytes, 0);
    defer raw.deinit();
    var skeleton = try ozz.offline.SkeletonBuilder.build(std.testing.allocator, raw);
    defer skeleton.deinit();
    try std.testing.expect(skeleton.numJoints() > 1);
}

fn importFixtureAnimations(relative: []const u8) !void {
    const allocator = std.testing.allocator;
    const path = try h.fixturePath(allocator, relative);
    defer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(32 * 1024 * 1024),
    );
    defer allocator.free(bytes);
    var raw_skeleton = try ozz.gltf.importSkeleton(allocator, bytes, 0);
    defer raw_skeleton.deinit();
    var skeleton = try ozz.offline.SkeletonBuilder.build(allocator, raw_skeleton);
    defer skeleton.deinit();
    const animations = try ozz.gltf.importAnimationsFile(allocator, path, skeleton);
    defer ozz.gltf.deinitAnimations(allocator, animations);
    try std.testing.expect(animations.len > 0);
    for (animations) |raw_animation| {
        try std.testing.expect(raw_animation.validate());
        var runtime_animation = try ozz.offline.AnimationBuilder.build(allocator, raw_animation);
        defer runtime_animation.deinit();
        var context = try ozz.animation.SamplingContext.init(allocator, runtime_animation.numTracks());
        defer context.deinit();
        const output = try allocator.alloc(ozz.math.SoaTransform, runtime_animation.numSoaTracks());
        defer allocator.free(output);
        try ozz.animation.sample(&runtime_animation, 0.5, &context, output);
    }
}

test "gltf2ozz_animation_multiple" {
    try importFixtureAnimations("media/gltf/khronos/interpolation_test.gltf");
}

test "gltf2ozz_box_animation" {
    try importFixtureAnimations("media/gltf/khronos/box_animated.gltf");
}

test "gltf2ozz_cesium_animation" {
    try importFixtureAnimations("media/gltf/khronos/cesium_man.gltf");
}
