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
