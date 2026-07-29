const std = @import("std");
const ozz = @import("zig_ozz_animation");

pub const epsilon: f32 = 1e-5;

pub fn expectFloat(expected: f32, actual: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, epsilon);
}

pub fn expectFloat3(expected: ozz.math.Vec3f32, actual: ozz.math.Vec3f32) !void {
    try expectFloat(expected[0], actual[0]);
    try expectFloat(expected[1], actual[1]);
    try expectFloat(expected[2], actual[2]);
}

pub fn expectFloat4(expected: ozz.math.Vec4f32, actual: ozz.math.Vec4f32) !void {
    try expectFloat(expected[0], actual[0]);
    try expectFloat(expected[1], actual[1]);
    try expectFloat(expected[2], actual[2]);
    try expectFloat(expected[3], actual[3]);
}

pub fn expectQuaternion(expected: ozz.math.Quat4f32, actual: ozz.math.Quat4f32) !void {
    const dot = @abs(ozz.math.quat.dot(expected, actual));
    try std.testing.expectApproxEqAbs(@as(f32, 1), dot, 2e-4);
}

pub fn expectTransform(expected: ozz.math.Transform, actual: ozz.math.Transform) !void {
    try expectFloat3(expected.translation, actual.translation);
    try expectQuaternion(expected.rotation, actual.rotation);
    try expectFloat3(expected.scale, actual.scale);
}

pub fn fixturePath(allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    const options = @import("fixture_options");
    const upstream_root = std.fs.path.dirname(options.upstream_marker) orelse
        return error.InvalidFixtureRoot;
    return std.fs.path.join(allocator, &.{ upstream_root, relative });
}
