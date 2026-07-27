const std = @import("std");
const ozz = @import("zig_ozz_animation");
const offline = ozz.offline;
const animation = ozz.animation;
const math = ozz.math;
const h = @import("helpers.zig");

test "Error/AnimationBuilder" {
    try std.testing.expectError(
        animation.Error.InvalidDuration,
        offline.RawAnimation.init(std.testing.allocator, "", 0, 0),
    );
}

test "Build/AnimationBuilder" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "test", 2, 1);
    defer raw.deinit();
    raw.tracks[0].translations = try std.testing.allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = .zero },
        .{ .time = 2, .value = .{ .x = 4 } },
    });
    var built = try offline.AnimationBuilder.build(std.testing.allocator, raw);
    defer built.deinit();
    try std.testing.expectEqualStrings("test", built.name);
    try h.expectFloat(1, built.tracks[0].translations[1].ratio);
}

test "Error/SkeletonBuilder" {
    try std.testing.expectError(animation.Error.InvalidHierarchy, animation.Skeleton.init(
        std.testing.allocator,
        &.{.{ .name = "bad", .parent = 0 }},
    ));
}

test "JointOrder/SkeletonBuilder" {
    const allocator = std.testing.allocator;
    var children = try allocator.alloc(offline.RawJoint, 2);
    children[0] = .{ .name = try allocator.dupe(u8, "a") };
    children[1] = .{ .name = try allocator.dupe(u8, "b") };
    var roots = try allocator.alloc(offline.RawJoint, 1);
    roots[0] = .{ .name = try allocator.dupe(u8, "root"), .children = children };
    var raw: offline.RawSkeleton = .{ .allocator = allocator, .roots = roots };
    defer raw.deinit();
    var skeleton = try offline.SkeletonBuilder.build(allocator, raw);
    defer skeleton.deinit();
    try std.testing.expectEqualStrings("root", skeleton.names[0]);
    try std.testing.expectEqualStrings("a", skeleton.names[1]);
    try std.testing.expectEqualStrings("b", skeleton.names[2]);
}

test "SamplingTrackEmpty/Utils" {
    try h.expectTransform(.identity, offline.sampleJointTrack(.{}, 0.5));
}

test "SamplingTrack/Utils" {
    const track: offline.RawJointTrack = .{
        .translations = @constCast(&[_]offline.TranslationKey{
            .{ .time = 0, .value = .zero },
            .{ .time = 1, .value = .{ .x = 2 } },
        }),
    };
    try h.expectFloat(0.5, offline.sampleJointTrack(track, 0.25).translation.x);
}

test "FixedRateSamplingTime/Utils" {
    const sampling = try offline.FixedRateSamplingTime.init(1.001, 30);
    try std.testing.expectEqual(@as(usize, 32), sampling.numKeys());
    try h.expectFloat(1.0 / 30.0, sampling.time(1));
    try h.expectFloat(1.001, sampling.time(31));
}

test "TimePoints/Utils" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "", 2, 2);
    defer raw.deinit();
    raw.tracks[0].translations = try std.testing.allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = .zero },
        .{ .time = 0.2, .value = .zero },
        .{ .time = 2, .value = .zero },
    });
    raw.tracks[1].scales = try std.testing.allocator.dupe(offline.ScaleKey, &.{
        .{ .time = 0.2, .value = .one },
        .{ .time = 1, .value = .one },
    });
    const points = try offline.extractTimePoints(std.testing.allocator, raw);
    defer std.testing.allocator.free(points);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0.2, 1, 2 }, points);
}

test "SampleFloat/RawTrackUtils" {
    var track = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{
        .{ .interpolation = .linear, .ratio = 0, .value = 1 },
        .{ .interpolation = .step, .ratio = 0.2, .value = 2 },
        .{ .interpolation = .linear, .ratio = 0.5, .value = 3 },
        .{ .interpolation = .linear, .ratio = 0.75, .value = 3 },
    });
    defer track.deinit();
    try h.expectFloat(1.5, offline.sampleTrack(f32, track, 0.1));
    try h.expectFloat(2, offline.sampleTrack(f32, track, 0.25));
}

test "SampleQauternion/RawTrackUtils" {
    var track = try offline.RawQuaternionTrack.init(std.testing.allocator, "", &.{
        .{ .interpolation = .linear, .ratio = 0, .value = .{ .x = 0.70710677, .w = 0.70710677 } },
        .{ .interpolation = .linear, .ratio = 1, .value = .{ .y = 0.70710677, .w = 0.70710677 } },
    });
    defer track.deinit();
    try h.expectQuaternion(
        .{ .x = 0.6172133, .y = 0.1543033, .w = 0.7715167 },
        offline.sampleTrack(math.Quaternion, track, 0.2),
    );
}

test "BuildMixed/TrackBuilder" {
    var raw = try offline.RawFloatTrack.init(std.testing.allocator, "mixed", &.{
        .{ .interpolation = .step, .ratio = 0, .value = 1 },
        .{ .interpolation = .linear, .ratio = 1, .value = 2 },
    });
    defer raw.deinit();
    var built = try offline.buildTrack(f32, std.testing.allocator, raw);
    defer built.deinit();
    try h.expectFloat(1, built.sampleAt(0.5));
    try std.testing.expectEqualStrings("mixed", built.name);
}

test "OptimizeInterpolate/TrackOptimizer" {
    var raw = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{
        .{ .interpolation = .linear, .ratio = 0, .value = 0 },
        .{ .interpolation = .linear, .ratio = 0.5, .value = 0.5 },
        .{ .interpolation = .linear, .ratio = 1, .value = 1 },
    });
    defer raw.deinit();
    var optimized = try offline.optimizeTrack(f32, std.testing.allocator, raw, 1e-5);
    defer optimized.deinit();
    try std.testing.expectEqual(@as(usize, 2), optimized.keys.len);
}

test "Build/AdditiveAnimationBuilder" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "", 1, 1);
    defer raw.deinit();
    raw.tracks[0].translations = try std.testing.allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = .{ .x = 2 } },
        .{ .time = 1, .value = .{ .x = 5 } },
    });
    var additive = try offline.buildAdditive(std.testing.allocator, raw, null);
    defer additive.deinit();
    try h.expectFloat(0, additive.tracks[0].translations[0].value.x);
    try h.expectFloat(3, additive.tracks[0].translations[1].value.x);
}

test "Extract/MotionExtractor" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "motion", 2, 1);
    defer raw.deinit();
    raw.tracks[0].translations = try std.testing.allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = .{ .x = 1, .y = 2, .z = 3 } },
        .{ .time = 2, .value = .{ .x = 4, .y = 5, .z = 6 } },
    });
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{
        .{ .name = "root", .parent = animation.no_parent },
    });
    defer skeleton.deinit();
    var result = try offline.extractMotion(std.testing.allocator, raw, skeleton, .{
        .position = .{ .x = true, .bake = true },
    });
    defer result.deinit();
    try h.expectFloat3(.{ .x = 1 }, result.position.keys[0].value);
    try h.expectFloat3(.{ .y = 2, .z = 3 }, result.baked.tracks[0].translations[0].value);
}
