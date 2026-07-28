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
        .{ .time = 0, .value = @splat(0) },
        .{ .time = 2, .value = .{ 4, 0, 0 } },
    });
    var built = try offline.AnimationBuilder.build(std.testing.allocator, raw);
    defer built.deinit();
    try std.testing.expectEqualStrings("test", built.name);
    try h.expectFloat(1, built.tracks[0].translations[1].ratio);
}

test "DefaultAndValidation/AnimationBuilder" {
    const allocator = std.testing.allocator;
    var empty = try offline.RawAnimation.init(allocator, "", 1, 0);
    defer empty.deinit();
    var built = try offline.AnimationBuilder.build(allocator, empty);
    defer built.deinit();
    try std.testing.expectEqual(@as(usize, 0), built.tracks.len);
    try std.testing.expectEqualStrings("", built.name);

    var duplicate = try offline.RawAnimation.init(allocator, "", 1, 1);
    defer duplicate.deinit();
    duplicate.tracks[0].translations = try allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0.5, .value = @splat(0) },
        .{ .time = 0.5, .value = @splat(1) },
    });
    try std.testing.expect(!duplicate.validate());
    try std.testing.expectError(
        animation.Error.InvalidKeyframe,
        offline.AnimationBuilder.build(allocator, duplicate),
    );
}

test "QuaternionFixup/AnimationBuilder" {
    const allocator = std.testing.allocator;
    var raw = try offline.RawAnimation.init(allocator, "", 1, 1);
    defer raw.deinit();
    raw.tracks[0].rotations = try allocator.dupe(offline.RotationKey, &.{
        .{ .time = 0, .value = .{ .x = -2, .w = -2 } },
        .{ .time = 1, .value = .{ .x = 2, .w = 2 } },
    });
    var built = try offline.AnimationBuilder.build(allocator, raw);
    defer built.deinit();
    const expected: math.Quaternion = .{ .x = 0.70710677, .w = 0.70710677 };
    try h.expectQuaternion(expected, built.tracks[0].rotations[0].value);
    try h.expectQuaternion(expected, built.tracks[0].rotations[1].value);
}

test "SortAndManyKeys/AnimationBuilder" {
    const allocator = std.testing.allocator;
    const key_count = 65_500;
    var raw = try offline.RawAnimation.init(allocator, "many_keys", 1, 4);
    defer raw.deinit();
    raw.tracks[0].translations = try allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = @splat(0) },
        .{ .time = 0.001, .value = .{ 10, 10, 10 } },
        .{ .time = 0.98, .value = .{ 20, 20, 20 } },
    });
    raw.tracks[1].translations = try allocator.alloc(offline.TranslationKey, key_count);
    raw.tracks[2].translations = try allocator.alloc(offline.TranslationKey, key_count);
    const denominator: f32 = @floatFromInt(key_count);
    for (0..key_count) |i| {
        const ratio = @as(f32, @floatFromInt(i)) / denominator;
        raw.tracks[1].translations[i] = .{ .time = ratio, .value = @splat(0) };
        const cosine = @cos(@as(f32, std.math.pi) * ratio);
        raw.tracks[2].translations[i] = .{
            .time = ratio,
            .value = .{ cosine, cosine, cosine },
        };
    }
    raw.tracks[3].translations = try allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = @splat(0) },
        .{ .time = 0.001, .value = @splat(1) },
        .{ .time = 0.9, .value = .{ 2, 2, 2 } },
        .{ .time = 0.91, .value = .{ 3, 3, 3 } },
    });

    var built = try offline.AnimationBuilder.build(allocator, raw);
    defer built.deinit();
    try std.testing.expectEqual(@as(usize, key_count), built.tracks[1].translations.len);
    try std.testing.expectEqual(@as(usize, key_count), built.tracks[2].translations.len);
    var context = try animation.SamplingContext.init(allocator, 4);
    defer context.deinit();
    var output: [1]math.SoaTransform = undefined;

    const Case = struct {
        ratio: f32,
        expected_x: [4]f32,
    };
    const cases = [_]Case{
        .{ .ratio = 0, .expected_x = .{ 0, 0, 1, 0 } },
        .{ .ratio = 0.99, .expected_x = .{ 20, 0, -0.9995, 3 } },
        // Sampling backwards also verifies cache invalidation.
        .{ .ratio = 0.5, .expected_x = .{ 15.096, 0, 0, 1.555 } },
        .{ .ratio = 1, .expected_x = .{ 20, 0, -1, 3 } },
    };
    for (cases) |case| {
        try animation.sample(&built, case.ratio, &context, &output);
        for (case.expected_x, 0..) |expected, lane| {
            const actual = math.soaLane(output[0], lane);
            try std.testing.expectApproxEqAbs(expected, actual.translation[0], 2e-3);
            try h.expectQuaternion(.identity, actual.rotation);
            try h.expectFloat3(@splat(1), actual.scale);
        }
    }
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

test "MaxJoints/SkeletonBuilder" {
    const allocator = std.testing.allocator;

    {
        const roots = try allocator.alloc(offline.RawJoint, animation.max_joints);
        for (roots) |*root| {
            root.* = .{ .name = try allocator.dupe(u8, "") };
        }
        var raw: offline.RawSkeleton = .{ .allocator = allocator, .roots = roots };
        defer raw.deinit();

        try std.testing.expect(raw.validate());
        try std.testing.expectEqual(@as(usize, animation.max_joints), raw.numJoints());

        var skeleton = try offline.SkeletonBuilder.build(allocator, raw);
        defer skeleton.deinit();
        try std.testing.expectEqual(@as(usize, animation.max_joints), skeleton.numJoints());
    }

    {
        const roots = try allocator.alloc(offline.RawJoint, animation.max_joints + 1);
        for (roots) |*root| {
            root.* = .{ .name = try allocator.dupe(u8, "") };
        }
        var raw: offline.RawSkeleton = .{ .allocator = allocator, .roots = roots };
        defer raw.deinit();

        try std.testing.expect(!raw.validate());
        try std.testing.expectEqual(@as(usize, animation.max_joints + 1), raw.numJoints());
        try std.testing.expectError(
            animation.Error.TooManyJoints,
            offline.SkeletonBuilder.build(allocator, raw),
        );
    }

    const inputs = try allocator.alloc(animation.JointInput, animation.max_joints + 1);
    defer allocator.free(inputs);
    @memset(inputs, .{ .name = "", .parent = animation.no_parent });
    try std.testing.expectError(
        animation.Error.TooManyJoints,
        animation.Skeleton.init(allocator, inputs),
    );
}

test "SamplingTrackEmpty/Utils" {
    try h.expectTransform(.identity, try offline.sampleJointTrack(.{}, 0.5));
}

test "SamplingTrack/Utils" {
    const track: offline.RawJointTrack = .{
        .translations = @constCast(&[_]offline.TranslationKey{
            .{ .time = 0, .value = @splat(0) },
            .{ .time = 1, .value = .{ 2, 0, 0 } },
        }),
    };
    try h.expectFloat(0.5, (try offline.sampleJointTrack(track, 0.25)).translation[0]);
}

test "SamplingTrackInvalid/Utils" {
    const unordered: offline.RawJointTrack = .{
        .translations = @constCast(&[_]offline.TranslationKey{
            .{ .time = 0.9, .value = .{ 1, 2, 4 } },
            .{ .time = 0.1, .value = .{ 2, 4, 8 } },
        }),
    };
    try std.testing.expectError(
        animation.Error.InvalidKeyframe,
        offline.sampleJointTrack(unordered, 0),
    );

    const negative_time: offline.RawJointTrack = .{
        .translations = @constCast(&[_]offline.TranslationKey{
            .{ .time = -1, .value = .{ 1, 2, 4 } },
        }),
    };
    try std.testing.expectError(
        animation.Error.InvalidKeyframe,
        offline.sampleJointTrack(negative_time, 0),
    );
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
        .{ .time = 0, .value = @splat(0) },
        .{ .time = 0.2, .value = @splat(0) },
        .{ .time = 2, .value = @splat(0) },
    });
    raw.tracks[1].scales = try std.testing.allocator.dupe(offline.ScaleKey, &.{
        .{ .time = 0.2, .value = @splat(1) },
        .{ .time = 1, .value = @splat(1) },
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

test "Identity/TrackOptimizer" {
    var raw = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{
        .{ .interpolation = .linear, .ratio = 0.5, .value = 0 },
        .{ .interpolation = .linear, .ratio = 0.7, .value = 0 },
        .{ .interpolation = .linear, .ratio = 0.8, .value = 0 },
    });
    defer raw.deinit();

    var optimized = try offline.optimizeTrack(f32, std.testing.allocator, raw, 1e-3);
    defer optimized.deinit();
    try std.testing.expectEqual(@as(usize, 0), optimized.keys.len);

    raw.keys[1].interpolation = .step;
    var stepped = try offline.optimizeTrack(f32, std.testing.allocator, raw, 1e-3);
    defer stepped.deinit();
    try std.testing.expectEqual(@as(usize, 2), stepped.keys.len);
    try std.testing.expectEqual(raw.keys[0], stepped.keys[0]);
    try std.testing.expectEqual(raw.keys[1], stepped.keys[1]);

    var single = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{
        .{ .interpolation = .step, .ratio = 0.5, .value = 0 },
    });
    defer single.deinit();
    var single_optimized = try offline.optimizeTrack(f32, std.testing.allocator, single, 1e-3);
    defer single_optimized.deinit();
    try std.testing.expectEqual(@as(usize, 0), single_optimized.keys.len);
}

test "Constant/TrackOptimizer" {
    var raw = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{
        .{ .interpolation = .linear, .ratio = 0.5, .value = 46 },
        .{ .interpolation = .linear, .ratio = 0.7, .value = 46 },
        .{ .interpolation = .linear, .ratio = 0.8, .value = 46 },
    });
    defer raw.deinit();

    var optimized = try offline.optimizeTrack(f32, std.testing.allocator, raw, 1e-3);
    defer optimized.deinit();
    try std.testing.expectEqual(@as(usize, 1), optimized.keys.len);
    try std.testing.expectEqual(raw.keys[0], optimized.keys[0]);

    raw.keys[2].interpolation = .step;
    var stepped = try offline.optimizeTrack(f32, std.testing.allocator, raw, 1e-3);
    defer stepped.deinit();
    try std.testing.expectEqual(@as(usize, 2), stepped.keys.len);
    try std.testing.expectEqual(raw.keys[0], stepped.keys[0]);
    try std.testing.expectEqual(raw.keys[2], stepped.keys[1]);
}

test "Build/AdditiveAnimationBuilder" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "", 1, 1);
    defer raw.deinit();
    raw.tracks[0].translations = try std.testing.allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = .{ 2, 0, 0 } },
        .{ .time = 1, .value = .{ 5, 0, 0 } },
    });
    var additive = try offline.buildAdditive(std.testing.allocator, raw, null);
    defer additive.deinit();
    try h.expectFloat(0, additive.tracks[0].translations[0].value[0]);
    try h.expectFloat(3, additive.tracks[0].translations[1].value[0]);
}

test "Extract/MotionExtractor" {
    var raw = try offline.RawAnimation.init(std.testing.allocator, "motion", 2, 1);
    defer raw.deinit();
    raw.tracks[0].translations = try std.testing.allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = .{ 1, 2, 3 } },
        .{ .time = 2, .value = .{ 4, 5, 6 } },
    });
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{
        .{ .name = "root", .parent = animation.no_parent },
    });
    defer skeleton.deinit();
    var result = try offline.extractMotion(std.testing.allocator, raw, skeleton, .{
        .position = .{ .x = true, .bake = true },
    });
    defer result.deinit();
    try h.expectFloat3(.{ 1, 0, 0 }, result.position.keys[0].value);
    try h.expectFloat3(.{ 0, 2, 3 }, result.baked.tracks[0].translations[0].value);
}

test "ExtractPositionAndYaw/MotionExtractor" {
    const allocator = std.testing.allocator;
    const half_pi: f32 = @as(f32, std.math.pi) / 2;
    var raw = try offline.RawAnimation.init(allocator, "motion", 2, 1);
    defer raw.deinit();
    raw.tracks[0].translations = try allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = .{ 1, 2, 3 } },
        .{ .time = 2, .value = .{ 4, 5, 6 } },
    });
    raw.tracks[0].rotations = try allocator.dupe(offline.RotationKey, &.{
        .{ .time = 0, .value = math.Quaternion.fromEuler(.{ half_pi, half_pi, 0 }) },
        .{ .time = 2, .value = math.Quaternion.fromEuler(.{ half_pi, half_pi, 0 }) },
    });
    var skeleton = try animation.Skeleton.init(allocator, &.{
        .{ .name = "root", .parent = animation.no_parent },
    });
    defer skeleton.deinit();

    var result = try offline.extractMotion(allocator, raw, skeleton, .{
        .position = .{ .x = true, .bake = true },
        .rotation = .{ .y = true, .bake = true },
    });
    defer result.deinit();

    try h.expectFloat3(.{ -3, 2, 0 }, result.baked.tracks[0].translations[0].value);
    try h.expectFloat3(.{ -6, 5, 0 }, result.baked.tracks[0].translations[1].value);
}

test "ReferenceLoopAndJoint/MotionExtractor" {
    const allocator = std.testing.allocator;
    var raw = try offline.RawAnimation.init(allocator, "motion", 2, 2);
    defer raw.deinit();
    raw.tracks[1].translations = try allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = .{ 11, 0, 0 } },
        .{ .time = 2, .value = .{ 15, 0, 0 } },
    });
    raw.tracks[1].rotations = try allocator.dupe(offline.RotationKey, &.{
        .{ .time = 0, .value = .identity },
        .{ .time = 2, .value = math.Quaternion.fromAxisAngle(.{ 0, 1, 0 }, 1) },
    });
    var skeleton = try animation.Skeleton.init(allocator, &.{
        .{ .name = "root", .parent = animation.no_parent },
        .{
            .name = "motion",
            .parent = 0,
            .rest_pose = .{ .translation = .{ 10, 0, 0 } },
        },
    });
    defer skeleton.deinit();

    var result = try offline.extractMotion(allocator, raw, skeleton, .{
        .root_joint = 1,
        .position = .{
            .x = true,
            .reference = .skeleton,
            .bake = false,
            .loop = true,
        },
        .rotation = .{ .y = true, .bake = false, .loop = true },
    });
    defer result.deinit();

    try h.expectFloat3(.{ 1, 0, 0 }, result.position.keys[0].value);
    try h.expectFloat3(result.position.keys[0].value, result.position.keys[1].value);
    try h.expectQuaternion(result.rotation.keys[0].value, result.rotation.keys[1].value);
    try h.expectFloat3(.{ 11, 0, 0 }, result.baked.tracks[1].translations[0].value);
    try h.expectFloat3(.{ 15, 0, 0 }, result.baked.tracks[1].translations[1].value);
    try std.testing.expectEqual(@as(usize, 0), result.baked.tracks[0].translations.len);
}

test "Build0Keys/TrackBuilder" {
    var raw = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{});
    defer raw.deinit();
    var track = try offline.buildTrack(f32, std.testing.allocator, raw);
    defer track.deinit();
    try std.testing.expectEqual(@as(usize, 0), track.keys.len);
}

test "BoundaryKeys/TrackBuilder" {
    var raw = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{
        .{ .interpolation = .step, .ratio = 0.25, .value = 46 },
        .{ .interpolation = .linear, .ratio = 0.75, .value = 0 },
    });
    defer raw.deinit();
    var track = try offline.buildTrack(f32, std.testing.allocator, raw);
    defer track.deinit();
    try std.testing.expectEqual(@as(usize, 4), track.keys.len);
    try h.expectFloat(0, track.keys[0].ratio);
    try h.expectFloat(1, track.keys[3].ratio);
    try h.expectFloat(46, track.sampleAt(-1));
    try h.expectFloat(0, track.sampleAt(2));

    var singleton_raw = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{
        .{ .interpolation = .step, .ratio = 0.5, .value = 23 },
    });
    defer singleton_raw.deinit();
    var singleton = try offline.buildTrack(f32, std.testing.allocator, singleton_raw);
    defer singleton.deinit();
    try std.testing.expectEqual(@as(usize, 2), singleton.keys.len);
    try h.expectFloat(0, singleton.keys[0].ratio);
    try h.expectFloat(1, singleton.keys[1].ratio);
    try h.expectFloat(23, singleton.sampleAt(0.5));
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
    try expectBuildType(math.Vec2f32, @splat(0), @splat(1));
}

test "Float3/TrackBuilder" {
    try expectBuildType(math.Vec3f32, @splat(0), @splat(1));
}

test "Float4/TrackBuilder" {
    try expectBuildType(math.Float4, .zero, .one);
}

test "Quaternion/TrackBuilder" {
    try expectBuildType(math.Quaternion, .identity, math.Quaternion.fromAxisAngle(.{ 1, 0, 0 }, 1));

    var raw = try offline.RawQuaternionTrack.init(std.testing.allocator, "", &.{
        .{
            .interpolation = .linear,
            .ratio = 0.5,
            .value = .{ .x = -2, .w = -2 },
        },
        .{
            .interpolation = .linear,
            .ratio = 0.7,
            .value = .{ .y = 2, .w = 2 },
        },
        .{
            .interpolation = .linear,
            .ratio = 0.8,
            .value = .{ .y = -2, .w = -2 },
        },
    });
    defer raw.deinit();
    var track = try offline.buildTrack(math.Quaternion, std.testing.allocator, raw);
    defer track.deinit();
    try h.expectQuaternion(
        .{ .x = 0.70710677, .w = 0.70710677 },
        track.sampleAt(0),
    );
    try h.expectQuaternion(
        .{ .y = 0.70710677, .w = 0.70710677 },
        track.sampleAt(0.8),
    );
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
    try expectOptimizeType(math.Vec2f32, @splat(0), .{ 0.5, 0.5 }, @splat(1));
}

test "Float3/TrackOptimizer" {
    try expectOptimizeType(math.Vec3f32, @splat(0), .{ 0.5, 0.5, 0.5 }, @splat(1));
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
    const end = math.Quaternion.fromAxisAngle(.{ 1, 0, 0 }, 1);
    try expectOptimizeType(math.Quaternion, .identity, math.Quaternion.nlerp(.identity, end, 0.5), end);
}

test "OptimizeSteps/TrackOptimizer" {
    var raw = try offline.RawFloatTrack.init(std.testing.allocator, "", &.{
        .{ .interpolation = .step, .ratio = 0, .value = 0 },
        .{ .interpolation = .step, .ratio = 0.5, .value = 0 },
        .{ .interpolation = .step, .ratio = 1, .value = 0 },
    });
    defer raw.deinit();
    var result = try offline.optimizeTrack(f32, std.testing.allocator, raw, 1);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.keys.len);
}

test "SampleFloat2/RawTrackUtils" {
    var track = try offline.RawFloat2Track.init(std.testing.allocator, "", &.{});
    defer track.deinit();
    try std.testing.expectEqual(@as(math.Vec2f32, @splat(0)), offline.sampleTrack(math.Vec2f32, track, 0.5));
}

test "SampleFloat3/RawTrackUtils" {
    var track = try offline.RawFloat3Track.init(std.testing.allocator, "", &.{});
    defer track.deinit();
    try std.testing.expectEqual(@as(math.Vec3f32, @splat(0)), offline.sampleTrack(math.Vec3f32, track, 0.5));
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
        &.{.{ .time = 0, .value = .{ 5, 0, 0 } }},
    );
    var result = try offline.buildAdditive(std.testing.allocator, raw, &.{
        .{ .translation = .{ 2, 0, 0 } },
    });
    defer result.deinit();
    try h.expectFloat(3, result.tracks[0].translations[0].value[0]);
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
        .transform = .{ .translation = .{ 1, 2, 3 } },
    };
    var raw: offline.RawSkeleton = .{ .allocator = allocator, .roots = roots };
    defer raw.deinit();
    var skeleton = try offline.SkeletonBuilder.build(allocator, raw);
    defer skeleton.deinit();
    try h.expectFloat3(.{ 1, 2, 3 }, skeleton.jointRestPose(0).translation);
}

test "Iterate/SkeletonBuilder" {
    const allocator = std.testing.allocator;
    var roots = try allocator.alloc(offline.RawJoint, 1);
    roots[0] = .{
        .name = try allocator.dupe(u8, "root"),
        .children = try allocator.alloc(offline.RawJoint, 3),
    };
    roots[0].children[0] = .{ .name = try allocator.dupe(u8, "j0") };
    roots[0].children[1] = .{
        .name = try allocator.dupe(u8, "j1"),
        .children = try allocator.alloc(offline.RawJoint, 2),
    };
    roots[0].children[1].children[0] = .{ .name = try allocator.dupe(u8, "j2") };
    roots[0].children[1].children[1] = .{ .name = try allocator.dupe(u8, "j3") };
    roots[0].children[2] = .{ .name = try allocator.dupe(u8, "j4") };
    var raw: offline.RawSkeleton = .{ .allocator = allocator, .roots = roots };
    defer raw.deinit();

    const Visitor = struct {
        names: *std.ArrayList([]const u8),
        parents: *std.ArrayList(?[]const u8),
        allocator: std.mem.Allocator,

        pub fn visit(self: *@This(), joint: *const offline.RawJoint, parent: ?*const offline.RawJoint) void {
            self.names.append(self.allocator, joint.name) catch unreachable;
            self.parents.append(self.allocator, if (parent) |value| value.name else null) catch unreachable;
        }
    };
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var parents: std.ArrayList(?[]const u8) = .empty;
    defer parents.deinit(allocator);
    var visitor: Visitor = .{ .names = &names, .parents = &parents, .allocator = allocator };

    try std.testing.expect(raw.validate());
    try std.testing.expectEqual(@as(usize, 6), raw.numJoints());
    offline.iterateJointsDF(raw, &visitor);
    const expected_df = [_][]const u8{ "root", "j0", "j1", "j2", "j3", "j4" };
    for (expected_df, names.items) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expect(parents.items[0] == null);
    try std.testing.expectEqualStrings("root", parents.items[1].?);
    try std.testing.expectEqualStrings("j1", parents.items[3].?);

    names.clearRetainingCapacity();
    parents.clearRetainingCapacity();
    try offline.iterateJointsBF(allocator, raw, &visitor);
    const expected_bf = [_][]const u8{ "root", "j0", "j1", "j4", "j2", "j3" };
    for (expected_bf, names.items) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqualStrings("root", parents.items[3].?);
    try std.testing.expectEqualStrings("j1", parents.items[4].?);
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
        .{ .time = 0, .value = @splat(0) },
        .{ .time = 0.5, .value = .{ 0.5, 0, 0 } },
        .{ .time = 1, .value = .{ 1, 0, 0 } },
    });
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{
        .{ .name = "root", .parent = animation.no_parent },
    });
    defer skeleton.deinit();
    var optimized = try offline.optimizeAnimation(std.testing.allocator, raw, skeleton, .{});
    defer optimized.deinit();
    try std.testing.expectEqual(@as(usize, 2), optimized.tracks[0].translations.len);
}

test "OptimizeHierarchyAndOverrides/AnimationOptimizer" {
    const allocator = std.testing.allocator;
    var skeleton = try animation.Skeleton.init(allocator, &.{
        .{ .name = "root", .parent = animation.no_parent },
        .{ .name = "mid", .parent = 0 },
        .{ .name = "leaf", .parent = 1 },
    });
    defer skeleton.deinit();
    var raw = try offline.RawAnimation.init(allocator, "hierarchy", 1, 3);
    defer raw.deinit();
    raw.tracks[2].translations = try allocator.dupe(offline.TranslationKey, &.{
        .{ .time = 0, .value = .{ 5, 0, 0 } },
        .{ .time = 0.1, .value = .{ 6, 0, 0 } },
        .{ .time = 0.2, .value = .{ 7.1, 0, 0 } },
        .{ .time = 0.3, .value = .{ 8, 0, 0 } },
    });

    var loose = try offline.optimizeAnimation(allocator, raw, skeleton, .{
        .tolerance = 0.1,
        .distance = 0,
    });
    defer loose.deinit();
    try std.testing.expectEqual(@as(usize, 2), loose.tracks[2].translations.len);

    raw.tracks[0].scales = try allocator.dupe(offline.ScaleKey, &.{
        .{ .time = 0, .value = .{ 10, 10, 10 } },
    });
    var scaled = try offline.optimizeAnimation(allocator, raw, skeleton, .{
        .tolerance = 0.1,
        .distance = 0,
    });
    defer scaled.deinit();
    try std.testing.expectEqual(@as(usize, 4), scaled.tracks[2].translations.len);

    var overridden = try offline.optimizeAnimation(allocator, raw, skeleton, .{
        .tolerance = 1,
        .distance = 0,
        .joint_overrides = &.{.{
            .joint = 2,
            .setting = .{ .tolerance = 0.01, .distance = 0 },
        }},
    });
    defer overridden.deinit();
    try std.testing.expectEqual(@as(usize, 4), overridden.tracks[2].translations.len);

    allocator.free(raw.tracks[0].scales);
    raw.tracks[0].scales = try allocator.alloc(offline.ScaleKey, 0);
    raw.tracks[0].rotations = try allocator.dupe(offline.RotationKey, &.{
        .{ .time = 0, .value = math.Quaternion.fromEuler(@splat(0)) },
        .{
            .time = 0.1,
            .value = math.Quaternion.fromEuler(.{ @as(f32, std.math.pi) / 4 + 2.5e-3, 0, 0 }),
        },
        .{ .time = 0.2, .value = math.Quaternion.fromEuler(.{ @as(f32, std.math.pi) / 2, 0, 0 }) },
    });
    var rotation_loose = try offline.optimizeAnimation(allocator, raw, skeleton, .{
        .tolerance = 0.3,
        .distance = 40,
    });
    defer rotation_loose.deinit();
    try std.testing.expectEqual(@as(usize, 2), rotation_loose.tracks[0].rotations.len);
    var rotation_strict = try offline.optimizeAnimation(allocator, raw, skeleton, .{
        .tolerance = 0.05,
        .distance = 40,
    });
    defer rotation_strict.deinit();
    try std.testing.expectEqual(@as(usize, 3), rotation_strict.tracks[0].rotations.len);
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
