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

test "Build0Keys/TrackBuilder" {
    var raw = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{});
    defer raw.deinit();
    var track = try offline.buildTrack(f32, std.testing.allocator, raw);
    defer track.deinit();
    try std.testing.expectEqual(@as(usize, 0), track.keys.len);
}

test "BuildLinear/TrackBuilder" {
    var raw = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{
        .{ .interpolation = .linear, .ratio = 0, .value = 0 },
        .{ .interpolation = .linear, .ratio = 1, .value = 2 },
    });
    defer raw.deinit();
    var track = try offline.buildTrack(f32, std.testing.allocator, raw);
    defer track.deinit();
    try h.expectFloat(1, track.sampleAt(0.5));
}

test "BuildStep/TrackBuilder" {
    var raw = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{
        .{ .interpolation = .step, .ratio = 0, .value = 0 },
        .{ .interpolation = .linear, .ratio = 1, .value = 2 },
    });
    defer raw.deinit();
    var track = try offline.buildTrack(f32, std.testing.allocator, raw);
    defer track.deinit();
    try h.expectFloat(0, track.sampleAt(0.5));
}

fn expectBuildType(comptime T: type, a: T, b: T) !void {
    var raw = try offline.RawTrack(T).init(std.testing.allocator, "typed", &.{
        .{ .interpolation = .linear, .ratio = 0, .value = a },
        .{ .interpolation = .linear, .ratio = 1, .value = b },
    });
    defer raw.deinit();
    var track = try offline.buildTrack(T, std.testing.allocator, raw);
    defer track.deinit();
    try std.testing.expectEqualStrings("typed", track.name);
    try std.testing.expectEqual(@as(usize, 2), track.keys.len);
}

test "Float/TrackBuilder" {
    try expectBuildType(f32, 0, 1);
}

test "Float2/TrackBuilder" {
    try expectBuildType(math.Float2, .zero, .one);
}

test "Float3/TrackBuilder" {
    try expectBuildType(math.Float3, .zero, .one);
}

test "Float4/TrackBuilder" {
    try expectBuildType(math.Float4, .zero, .one);
}

test "Quaternion/TrackBuilder" {
    try expectBuildType(math.Quaternion, .identity, math.Quaternion.fromAxisAngle(.x_axis, 1));
}

fn expectOptimizeType(comptime T: type, a: T, middle: T, b: T) !void {
    var raw = try offline.RawTrack(T).init(std.testing.allocator, "optimized", &.{
        .{ .interpolation = .linear, .ratio = 0, .value = a },
        .{ .interpolation = .linear, .ratio = 0.5, .value = middle },
        .{ .interpolation = .linear, .ratio = 1, .value = b },
    });
    defer raw.deinit();
    var result = try offline.optimizeTrack(T, std.testing.allocator, raw, 1e-4);
    defer result.deinit();
    try std.testing.expectEqualStrings("optimized", result.name);
    try std.testing.expectEqual(@as(usize, 2), result.keys.len);
}

test "float/TrackOptimizer" {
    try expectOptimizeType(f32, 0, 0.5, 1);
}

test "Float2/TrackOptimizer" {
    try expectOptimizeType(math.Float2, .zero, .{ .x = 0.5, .y = 0.5 }, .one);
}

test "Float3/TrackOptimizer" {
    try expectOptimizeType(math.Float3, .zero, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, .one);
}

test "Float4/TrackOptimizer" {
    try expectOptimizeType(
        math.Float4,
        .zero,
        .{ .x = 0.5, .y = 0.5, .z = 0.5, .w = 0.5 },
        .one,
    );
}

test "Quaternion/TrackOptimizer" {
    const end = math.Quaternion.fromAxisAngle(.x_axis, 1);
    try expectOptimizeType(math.Quaternion, .identity, math.Quaternion.nlerp(.identity, end, 0.5), end);
}

test "OptimizeSteps/TrackOptimizer" {
    var raw = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{
        .{ .interpolation = .step, .ratio = 0, .value = 0 },
        .{ .interpolation = .step, .ratio = 0.5, .value = 0 },
        .{ .interpolation = .linear, .ratio = 1, .value = 0 },
    });
    defer raw.deinit();
    var result = try offline.optimizeTrack(f32, std.testing.allocator, raw, 1);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.keys.len);
}

test "SampleFloat2/RawTrackUtils" {
    var track = try offline.RawFloat2Track.init(std.testing.allocator, "", &.{});
    defer track.deinit();
    try std.testing.expectEqual(math.Float2.zero, offline.sampleTrack(math.Float2, track, 0.5));
}

test "SampleFloat3/RawTrackUtils" {
    var track = try offline.RawFloat3Track.init(std.testing.allocator, "", &.{});
    defer track.deinit();
    try std.testing.expectEqual(math.Float3.zero, offline.sampleTrack(math.Float3, track, 0.5));
}

test "SampleFloat4/RawTrackUtils" {
    var track = try offline.RawFloat4Track.init(std.testing.allocator, "", &.{});
    defer track.deinit();
    try std.testing.expectEqual(math.Float4.zero, offline.sampleTrack(math.Float4, track, 0.5));
}

test "Invalid/RawTrackUtils" {
    try std.testing.expectError(animation.Error.InvalidKeyframe, offline.RawFloatTrack.init(
        std.testing.allocator,
        "",
        &.{.{ .interpolation = .linear, .ratio = 99, .value = 0 }},
    ));
}

test "BuildRefPose/AdditiveAnimationBuilder" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "", 1, 1);
    defer raw.deinit();
    raw.tracks[0].translations = try std.testing.allocator.dupe(
        offline.TranslationKey,
        &.{.{ .time = 0, .value = .{ .x = 5 } }},
    );
    var result = try offline.buildAdditive(std.testing.allocator, raw, &.{
        .{ .translation = .{ .x = 2 } },
    });
    defer result.deinit();
    try h.expectFloat(3, result.tracks[0].translations[0].value.x);
}

test "Error/AdditiveAnimationBuilder" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "", 1, 1);
    defer raw.deinit();
    try std.testing.expectError(
        animation.Error.OutputTooSmall,
        offline.buildAdditive(std.testing.allocator, raw, &.{}),
    );
}

test "SamplingAnimation/Utils" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "", 1, 2);
    defer raw.deinit();
    var output: [2]math.Transform = undefined;
    try offline.sampleRawAnimation(raw, 0.5, &output);
    try h.expectTransform(.identity, output[0]);
    try h.expectTransform(.identity, output[1]);
}

test "MultiRoots/SkeletonBuilder" {
    const allocator = std.testing.allocator;
    var roots = try allocator.alloc(offline.RawJoint, 2);
    roots[0] = .{ .name = try allocator.dupe(u8, "a") };
    roots[1] = .{ .name = try allocator.dupe(u8, "b") };
    var raw: offline.RawSkeleton = .{ .allocator = allocator, .roots = roots };
    defer raw.deinit();
    var skeleton = try offline.SkeletonBuilder.build(allocator, raw);
    defer skeleton.deinit();
    try std.testing.expectEqualSlices(i16, &.{ animation.no_parent, animation.no_parent }, skeleton.parents);
}

test "RestPose/SkeletonBuilder" {
    const allocator = std.testing.allocator;
    var roots = try allocator.alloc(offline.RawJoint, 1);
    roots[0] = .{
        .name = try allocator.dupe(u8, "root"),
        .transform = .{ .translation = .{ .x = 1, .y = 2, .z = 3 } },
    };
    var raw: offline.RawSkeleton = .{ .allocator = allocator, .roots = roots };
    defer raw.deinit();
    var skeleton = try offline.SkeletonBuilder.build(allocator, raw);
    defer skeleton.deinit();
    try h.expectFloat3(.{ .x = 1, .y = 2, .z = 3 }, skeleton.jointRestPose(0).translation);
}

test "Name/AnimationOptimizer" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "Test_Animation", 1, 0);
    defer raw.deinit();
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{});
    defer skeleton.deinit();
    var optimized = try offline.optimizeAnimation(std.testing.allocator, raw, skeleton, .{});
    defer optimized.deinit();
    try std.testing.expectEqualStrings("Test_Animation", optimized.name);
}

test "Error/AnimationOptimizer" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "", 1, 1);
    defer raw.deinit();
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{});
    defer skeleton.deinit();
    try std.testing.expectError(
        animation.Error.InvalidTrackCount,
        offline.optimizeAnimation(std.testing.allocator, raw, skeleton, .{}),
    );
}

test "Optimize/AnimationOptimizer" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "", 1, 1);
    defer raw.deinit();
    raw.tracks[0].translations = try std.testing.allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = .zero },
        .{ .time = 0.5, .value = .{ .x = 0.5 } },
        .{ .time = 1, .value = .{ .x = 1 } },
    });
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{
        .{ .name = "root", .parent = animation.no_parent },
    });
    defer skeleton.deinit();
    var optimized = try offline.optimizeAnimation(std.testing.allocator, raw, skeleton, .{});
    defer optimized.deinit();
    try std.testing.expectEqual(@as(usize, 2), optimized.tracks[0].translations.len);
}

test "Error/MotionExtractor" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "", 1, 1);
    defer raw.deinit();
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{
        .{ .name = "root", .parent = animation.no_parent },
    });
    defer skeleton.deinit();
    try std.testing.expectError(animation.Error.InvalidTrackCount, offline.extractMotion(
        std.testing.allocator,
        raw,
        skeleton,
        .{ .root_joint = 93 },
    ));
}
