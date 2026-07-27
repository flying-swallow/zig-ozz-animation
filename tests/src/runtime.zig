const std = @import("std");
const ozz = @import("zig_ozz_animation");
const animation = ozz.animation;
const math = ozz.math;
const h = @import("helpers.zig");

fn makeSkeleton(allocator: std.mem.Allocator) !animation.Skeleton {
    return animation.Skeleton.init(allocator, &.{
        .{ .name = "root", .parent = animation.no_parent },
        .{ .name = "left", .parent = 0 },
        .{ .name = "leaf", .parent = 1 },
        .{ .name = "right", .parent = 0 },
    });
}

test "Name/SkeletonUtils" {
    var skeleton = try makeSkeleton(std.testing.allocator);
    defer skeleton.deinit();
    try std.testing.expectEqual(@as(?usize, 2), animation.findJoint(skeleton, "leaf"));
    try std.testing.expectEqual(@as(?usize, null), animation.findJoint(skeleton, "missing"));
}

test "IsLeaf/SkeletonUtils" {
    var skeleton = try makeSkeleton(std.testing.allocator);
    defer skeleton.deinit();
    try std.testing.expect(!animation.isLeaf(skeleton, 0));
    try std.testing.expect(!animation.isLeaf(skeleton, 1));
    try std.testing.expect(animation.isLeaf(skeleton, 2));
    try std.testing.expect(animation.isLeaf(skeleton, 3));
}

test "InterateDF/SkeletonUtils" {
    var skeleton = try makeSkeleton(std.testing.allocator);
    defer skeleton.deinit();
    try std.testing.expectEqual(@as(usize, 3), animation.subtreeEnd(skeleton, 1));
    try std.testing.expectEqual(@as(usize, 4), animation.subtreeEnd(skeleton, 0));
    try std.testing.expectEqual(@as(usize, 2), try animation.jointDepth(skeleton, 2));
}

test "JobValidity/SamplingJob" {
    var animation_value = try animation.Animation.init(std.testing.allocator, "", 1, &.{.{}});
    defer animation_value.deinit();
    var small_context = try animation.SamplingContext.init(std.testing.allocator, 0);
    defer small_context.deinit();
    var output: [1]math.SoaTransform = undefined;
    try std.testing.expectError(
        animation.Error.ContextTooSmall,
        animation.sample(&animation_value, 0, &small_context, &output),
    );
}

test "Sampling1Track0Key/SamplingJob" {
    var value = try animation.Animation.init(std.testing.allocator, "", 1, &.{.{}});
    defer value.deinit();
    var context = try animation.SamplingContext.init(std.testing.allocator, 1);
    defer context.deinit();
    var output: [1]math.SoaTransform = undefined;
    try animation.sample(&value, 0.5, &context, &output);
    try h.expectTransform(.identity, math.soaLane(output[0], 0));
}

test "Sampling1Track1Key/SamplingJob" {
    var value = try animation.Animation.init(std.testing.allocator, "", 1, &.{.{
        .translations = &.{.{ .ratio = 0.46, .value = .{ .x = 1, .y = 2, .z = 3 } }},
    }});
    defer value.deinit();
    var context = try animation.SamplingContext.init(std.testing.allocator, 1);
    defer context.deinit();
    var output: [1]math.SoaTransform = undefined;
    try animation.sample(&value, 0, &context, &output);
    try h.expectFloat3(.{ .x = 1, .y = 2, .z = 3 }, math.soaLane(output[0], 0).translation);
}

test "Sampling1Track2Keys/SamplingJob" {
    var value = try animation.Animation.init(std.testing.allocator, "", 1, &.{.{
        .translations = &.{
            .{ .ratio = 0, .value = .zero },
            .{ .ratio = 1, .value = .{ .x = 2, .y = 4, .z = 6 } },
        },
    }});
    defer value.deinit();
    var context = try animation.SamplingContext.init(std.testing.allocator, 1);
    defer context.deinit();
    var output: [1]math.SoaTransform = undefined;
    try animation.sample(&value, 0.25, &context, &output);
    try h.expectFloat3(.{ .x = 0.5, .y = 1, .z = 1.5 }, math.soaLane(output[0], 0).translation);
    try animation.sample(&value, 0.75, &context, &output);
    try animation.sample(&value, 0.1, &context, &output);
    try h.expectFloat(0.2, math.soaLane(output[0], 0).translation.x);
}

test "JobValidity/LocalToModel" {
    var skeleton = try makeSkeleton(std.testing.allocator);
    defer skeleton.deinit();
    var input: [1]math.SoaTransform = .{math.SoaTransform.identity};
    var small: [3]math.Float4x4 = undefined;
    try std.testing.expectError(animation.Error.OutputTooSmall, animation.localToModel(.{
        .skeleton = &skeleton,
        .input = &input,
    }, &small));
}

test "TransformationFromTo/LocalToModel" {
    var skeleton = try makeSkeleton(std.testing.allocator);
    defer skeleton.deinit();
    var aos = [_]math.Transform{
        .{ .translation = .{ .x = 1 } },
        .{ .translation = .{ .y = 2 } },
        .{ .translation = .{ .z = 3 } },
        .{ .translation = .{ .x = 4 } },
    };
    var input: [1]math.SoaTransform = undefined;
    math.aosToSoa(&aos, &input);
    var output = [_]math.Float4x4{
        math.Float4x4.identity,
        math.Float4x4.identity,
        math.Float4x4.identity,
        math.Float4x4.identity,
    };
    try animation.localToModel(.{ .skeleton = &skeleton, .input = &input }, &output);
    try h.expectFloat3(.{ .x = 1, .y = 2, .z = 3 }, math.Float4x4.translation(output[2]));

    output[1] = math.Float4x4.fromTransform(.{ .translation = .{ .x = 10 } });
    output[2] = math.Float4x4.identity;
    try animation.localToModel(.{
        .skeleton = &skeleton,
        .input = &input,
        .from = 1,
        .to = 2,
        .from_excluded = true,
    }, &output);
    try h.expectFloat3(.{ .x = 10, .z = 3 }, math.Float4x4.translation(output[2]));
}

test "Empty/LocalToModel" {
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{});
    defer skeleton.deinit();
    try animation.localToModel(.{ .skeleton = &skeleton, .input = &.{} }, &.{});
}

test "Float/TrackSamplingJob" {
    var track = try animation.FloatTrack.initMixed(std.testing.allocator, "float", &.{
        .{ .ratio = 0, .value = 0 },
        .{ .ratio = 0.5, .value = 2, .interpolation = .step },
        .{ .ratio = 1, .value = 4 },
    });
    defer track.deinit();
    try h.expectFloat(1, track.sampleAt(0.25));
    try h.expectFloat(2, track.sampleAt(0.75));
}

test "Quaternion/TrackSamplingJob" {
    const end = math.Quaternion.fromAxisAngle(.z_axis, @as(f32, std.math.pi) / 2);
    var track = try animation.QuaternionTrack.init(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = .identity },
        .{ .ratio = 1, .value = end },
    }, .linear);
    defer track.deinit();
    const rotated = math.Quaternion.rotate(track.sampleAt(0.5), .x_axis);
    const sqrt_half: f32 = @sqrt(0.5);
    try h.expectFloat3(.{ .x = sqrt_half, .y = sqrt_half }, rotated);
}

test "Run/MotionBlendingJob" {
    const result = animation.blendMotion(&.{
        .{ .delta = .{ .translation = .{ .x = 2 } }, .weight = 0.5 },
        .{ .delta = .{ .translation = .{ .y = 4 } }, .weight = 0.5 },
    });
    try h.expectFloat(3, math.Float3.length(result.translation));
}

test "Correction/IKAimJob" {
    const result = try animation.aimIk(.{
        .target = .{ .y = 1 },
        .joint = .identity,
    });
    try std.testing.expect(result.reached);
    try h.expectFloat3(.y_axis, math.Quaternion.rotate(result.correction, .x_axis));
}

test "Weight/IKAimJob" {
    const result = try animation.aimIk(.{
        .target = .{ .y = 1 },
        .joint = .identity,
        .weight = 0,
    });
    try h.expectQuaternion(.identity, result.correction);
}

test "MidAxis/IKTwoBoneJob" {
    try std.testing.expectError(animation.Error.InvalidLayer, animation.twoBoneIk(.{
        .target = .{ .x = 1 },
        .start_joint = .identity,
        .mid_joint = math.Float4x4.fromTransform(.{ .translation = .{ .x = 1 } }),
        .end_joint = math.Float4x4.fromTransform(.{ .translation = .{ .x = 2 } }),
        .mid_axis = .{ .x = 2 },
    }));
}

test "Weight/IKTwoBoneJob" {
    const result = try animation.twoBoneIk(.{
        .target = .{ .x = 1, .y = 1 },
        .start_joint = .identity,
        .mid_joint = math.Float4x4.fromTransform(.{ .translation = .{ .x = 1 } }),
        .end_joint = math.Float4x4.fromTransform(.{ .translation = .{ .x = 2 } }),
        .weight = 0,
    });
    try h.expectQuaternion(.identity, result.start_correction);
    try h.expectQuaternion(.identity, result.mid_correction);
}

test "Linear/TrackEdgeTriggerJob" {
    var track = try animation.FloatTrack.init(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = 0 },
        .{ .ratio = 1, .value = 1 },
    }, .linear);
    defer track.deinit();
    var iterator = animation.TrackEdgeIterator.init(&track, 0, 1, 0.5);
    const falling = iterator.next().?;
    try h.expectFloat(0, falling.ratio);
    try std.testing.expect(!falling.rising);
    const rising = iterator.next().?;
    try h.expectFloat(0.5, rising.ratio);
    try std.testing.expect(rising.rising);
    try std.testing.expectEqual(@as(?animation.TrackEdge, null), iterator.next());
}

test "JobValidity/BlendingJob" {
    var output: [1]math.SoaTransform = undefined;
    try std.testing.expectError(animation.Error.InvalidThreshold, animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{},
        .threshold = 0,
    }, &output));
    try std.testing.expectError(animation.Error.OutputTooSmall, animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{},
    }, &.{}));
}

test "Empty/BlendingJob" {
    var rest: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{.{ .translation = .{ .x = 1 }, .scale = .{ .x = 2, .y = 3, .z = 4 } }}, &rest);
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{ .rest_pose = &rest, .layers = &.{} }, &output);
    try h.expectTransform(math.soaLane(rest[0], 0), math.soaLane(output[0], 0));
}

test "Weight/BlendingJob" {
    var positive: [1]math.SoaTransform = undefined;
    var negative: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{.{ .translation = .{ .x = 4 } }}, &positive);
    math.aosToSoa(&.{.{ .translation = .{ .x = -4 } }}, &negative);
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{
            .{ .transforms = &positive, .weight = 0.25 },
            .{ .transforms = &negative, .weight = 0.75 },
        },
    }, &output);
    try h.expectFloat(-2, math.soaLane(output[0], 0).translation.x);
}

test "JointWeights/BlendingJob" {
    var pose: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{
        .{ .translation = .{ .x = 2 } },
        .{ .translation = .{ .x = 4 } },
    }, &pose);
    const weights: [1]math.SimdFloat4 = .{.{ 1, 0, 0, 0 }};
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{.{ .transforms = &pose, .weight = 1, .joint_weights = &weights }},
    }, &output);
    try h.expectFloat(2, math.soaLane(output[0], 0).translation.x);
    try h.expectFloat(0, math.soaLane(output[0], 1).translation.x);
}

test "Normalize/BlendingJob" {
    var a: [1]math.SoaTransform = undefined;
    var b: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{.{ .translation = .{ .x = 2 } }}, &a);
    math.aosToSoa(&.{.{ .translation = .{ .x = 4 } }}, &b);
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{
            .{ .transforms = &a, .weight = 2 },
            .{ .transforms = &b, .weight = 3 },
        },
    }, &output);
    try h.expectFloat(3.2, math.soaLane(output[0], 0).translation.x);
}

test "Threshold/BlendingJob" {
    var rest: [1]math.SoaTransform = undefined;
    var pose: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{.{ .translation = .{ .x = 10 } }}, &rest);
    math.aosToSoa(&.{.{ .translation = .zero }}, &pose);
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &rest,
        .layers = &.{.{ .transforms = &pose, .weight = 0.05 }},
        .threshold = 0.1,
    }, &output);
    try h.expectFloat(5, math.soaLane(output[0], 0).translation.x);
}

test "AdditiveWeight/BlendingJob" {
    var additive: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{.{
        .translation = .{ .x = 4 },
        .rotation = math.Quaternion.fromAxisAngle(.z_axis, @as(f32, std.math.pi) / 2),
        .scale = .{ .x = 2, .y = 2, .z = 2 },
    }}, &additive);
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{},
        .additive_layers = &.{.{ .transforms = &additive, .weight = 0.5 }},
    }, &output);
    const result = math.soaLane(output[0], 0);
    try h.expectFloat(2, result.translation.x);
    try h.expectFloat(1.5, result.scale.x);
    try h.expectFloat3(
        .{ .x = @sqrt(@as(f32, 0.5)), .y = @sqrt(@as(f32, 0.5)) },
        math.Quaternion.rotate(result.rotation, .x_axis),
    );
}

test "AdditiveJointWeight/BlendingJob" {
    var additive: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{
        .{ .translation = .{ .x = 4 }, .scale = .{ .x = 2, .y = 2, .z = 2 } },
        .{ .translation = .{ .x = 8 }, .scale = .{ .x = 4, .y = 4, .z = 4 } },
    }, &additive);
    const weights: [1]math.SimdFloat4 = .{.{ 1, 0.5, 0, -1 }};
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{},
        .additive_layers = &.{.{ .transforms = &additive, .weight = 0.5, .joint_weights = &weights }},
    }, &output);
    try h.expectFloat(2, math.soaLane(output[0], 0).translation.x);
    try h.expectFloat(2, math.soaLane(output[0], 1).translation.x);
}

test "JobValidityAdditive/BlendingJob" {
    var output: [1]math.SoaTransform = undefined;
    try std.testing.expectError(animation.Error.InvalidLayer, animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{},
        .additive_layers = &.{.{ .transforms = &.{}, .weight = 1 }},
    }, &output));
}

test "Sampling4Track2Keys/SamplingJob" {
    var value = try animation.Animation.init(std.testing.allocator, "", 1, &.{
        .{ .translations = &.{ .{ .ratio = 0, .value = .zero }, .{ .ratio = 1, .value = .{ .x = 1 } } } },
        .{ .translations = &.{ .{ .ratio = 0, .value = .zero }, .{ .ratio = 1, .value = .{ .x = 2 } } } },
        .{ .translations = &.{ .{ .ratio = 0, .value = .zero }, .{ .ratio = 1, .value = .{ .x = 3 } } } },
        .{ .translations = &.{ .{ .ratio = 0, .value = .zero }, .{ .ratio = 1, .value = .{ .x = 4 } } } },
    });
    defer value.deinit();
    var context = try animation.SamplingContext.init(std.testing.allocator, 4);
    defer context.deinit();
    var output: [1]math.SoaTransform = undefined;
    try animation.sample(&value, 0.5, &context, &output);
    for (0..4) |lane| {
        try h.expectFloat(@as(f32, @floatFromInt(lane + 1)) * 0.5, math.soaLane(output[0], lane).translation.x);
    }
}

test "Cache/SamplingJob" {
    var value = try animation.Animation.init(std.testing.allocator, "", 1, &.{.{
        .translations = &.{
            .{ .ratio = 0, .value = .zero },
            .{ .ratio = 0.25, .value = .{ .x = 1 } },
            .{ .ratio = 0.5, .value = .{ .x = 2 } },
            .{ .ratio = 0.75, .value = .{ .x = 3 } },
            .{ .ratio = 1, .value = .{ .x = 4 } },
        },
    }});
    defer value.deinit();
    var context = try animation.SamplingContext.init(std.testing.allocator, 1);
    defer context.deinit();
    var output: [1]math.SoaTransform = undefined;
    for ([_]f32{ 0.1, 0.6, 0.9, 0.2 }) |ratio| {
        try animation.sample(&value, ratio, &context, &output);
        try h.expectFloat(ratio * 4, math.soaLane(output[0], 0).translation.x);
    }
}

test "CacheResize/SamplingJob" {
    var context = try animation.SamplingContext.init(std.testing.allocator, 1);
    defer context.deinit();
    try context.resize(8);
    try std.testing.expectEqual(@as(usize, 8), context.translation_keys.len);
    try context.resize(0);
    try std.testing.expectEqual(@as(usize, 0), context.rotation_keys.len);
}

test "CountKeyframes/AnimationUtils" {
    var value = try animation.Animation.init(std.testing.allocator, "", 1, &.{
        .{
            .translations = &.{
                .{ .ratio = 0, .value = .zero },
                .{ .ratio = 0.5, .value = .zero },
                .{ .ratio = 1, .value = .zero },
            },
            .rotations = &.{.{ .ratio = 0.7, .value = .identity }},
        },
        .{ .scales = &.{.{ .ratio = 0.1, .value = .one }} },
    });
    defer value.deinit();
    try std.testing.expectEqual(@as(usize, 3), animation.countTranslationKeyframes(value, null));
    try std.testing.expectEqual(@as(usize, 1), animation.countRotationKeyframes(value, null));
    try std.testing.expectEqual(@as(usize, 1), animation.countScaleKeyframes(value, null));
    try std.testing.expectEqual(@as(usize, 0), animation.countTranslationKeyframes(value, 1));
}

fn expectTrackSample(comptime T: type, a: T, b: T) !void {
    var track = try animation.Track(T).init(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = a },
        .{ .ratio = 1, .value = b },
    }, .linear);
    defer track.deinit();
    _ = track.sampleAt(0.5);
    try std.testing.expectEqual(a, track.sampleAt(-1));
    try std.testing.expectEqual(b, track.sampleAt(2));
}

test "Float2/TrackSamplingJob" {
    try expectTrackSample(math.Float2, .zero, .one);
}

test "Float3/TrackSamplingJob" {
    try expectTrackSample(math.Float3, .zero, .one);
}

test "Float4/TrackSamplingJob" {
    try expectTrackSample(math.Float4, .zero, .one);
}

test "Bounds/TrackSamplingJob" {
    var track = try animation.FloatTrack.init(std.testing.allocator, "", &.{
        .{ .ratio = 0.25, .value = 1 },
        .{ .ratio = 0.75, .value = 2 },
    }, .linear);
    defer track.deinit();
    try h.expectFloat(1, track.sampleAt(-46));
    try h.expectFloat(2, track.sampleAt(93));
}

test "Constant/TrackSamplingJob" {
    var track = try animation.FloatTrack.init(std.testing.allocator, "", &.{
        .{ .ratio = 0.46, .value = 93 },
    }, .linear);
    defer track.deinit();
    try h.expectFloat(93, track.sampleAt(0));
    try h.expectFloat(93, track.sampleAt(1));
}

test "SquareStep/TrackEdgeTriggerJob" {
    var track = try animation.FloatTrack.initMixed(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = 0, .interpolation = .step },
        .{ .ratio = 0.25, .value = 1, .interpolation = .step },
        .{ .ratio = 0.75, .value = 0, .interpolation = .step },
    });
    defer track.deinit();
    var iterator = animation.TrackEdgeIterator.init(&track, 0, 1, 0.5);
    const rising = iterator.next().?;
    const falling = iterator.next().?;
    try h.expectFloat(0.25, rising.ratio);
    try std.testing.expect(rising.rising);
    try h.expectFloat(0.75, falling.ratio);
    try std.testing.expect(!falling.rising);
}

test "NoRange/TrackEdgeTriggerJob" {
    var track = try animation.FloatTrack.init(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = 0 },
        .{ .ratio = 1, .value = 1 },
    }, .linear);
    defer track.deinit();
    var iterator = animation.TrackEdgeIterator.init(&track, 0.5, 0.5, 0.5);
    try std.testing.expectEqual(@as(?animation.TrackEdge, null), iterator.next());
}

test "Empty/TrackEdgeTriggerJob" {
    // Runtime tracks cannot be sampled empty, but triggering treats them as an
    // empty range without dereferencing a key.
    var raw = try ozz.offline.RawFloatTrack.init(std.testing.allocator, "", &.{});
    defer raw.deinit();
    var track = try ozz.offline.buildTrack(f32, std.testing.allocator, raw);
    defer track.deinit();
    var iterator = animation.TrackEdgeIterator.init(&track, 0, 1, 0.5);
    try std.testing.expectEqual(@as(?animation.TrackEdge, null), iterator.next());
}

test "Twist/IKAimJob" {
    const result = try animation.aimIk(.{
        .target = .x_axis,
        .joint = .identity,
        .twist_angle = @as(f32, std.math.pi) / 2,
    });
    try h.expectFloat3(.z_axis, math.Quaternion.rotate(result.correction, .y_axis));
}

test "Offset/IKAimJob" {
    const result = try animation.aimIk(.{
        .target = .{ .x = 2, .y = 1 },
        .joint = .identity,
        .offset = .y_axis,
    });
    try std.testing.expect(result.reached);
}

test "TargetTooClose/IKAimJob" {
    const result = try animation.aimIk(.{
        .target = .zero,
        .joint = .identity,
    });
    try std.testing.expect(!result.reached);
    try h.expectQuaternion(.identity, result.correction);
}

test "ZeroLengthBoneChain/IKTwoBoneJob" {
    const result = try animation.twoBoneIk(.{
        .target = .x_axis,
        .start_joint = .identity,
        .mid_joint = .identity,
        .end_joint = .identity,
    });
    try std.testing.expect(!result.reached);
}

test "StartJointCorrection/IKTwoBoneJob" {
    const result = try animation.twoBoneIk(.{
        .target = .{ .x = 1, .y = 1 },
        .start_joint = .identity,
        .mid_joint = math.Float4x4.fromTransform(.{ .translation = .x_axis }),
        .end_joint = math.Float4x4.fromTransform(.{ .translation = .{ .x = 2 } }),
    });
    try std.testing.expect(math.Quaternion.dot(.identity, result.start_correction) < 0.999);
}

fn bentIkOptions(target: math.Float3) animation.TwoBoneOptions {
    return .{
        .target = target,
        .start_joint = .identity,
        .mid_joint = math.Float4x4.fromTransform(.{ .translation = .y_axis }),
        .end_joint = math.Float4x4.fromTransform(.{ .translation = .{ .x = 1, .y = 1 } }),
        .mid_axis = .z_axis,
        .pole_vector = .y_axis,
    };
}

test "MidAxisAndZeroTarget/IKTwoBoneJob" {
    const unchanged = try animation.twoBoneIk(bentIkOptions(.{ .x = 1, .y = 1 }));
    try h.expectQuaternion(.identity, unchanged.start_correction);
    try h.expectQuaternion(.identity, unchanged.mid_correction);
    try std.testing.expect(unchanged.reached);

    var reversed_options = bentIkOptions(.{ .x = 1, .y = 1 });
    reversed_options.mid_axis = .{ .z = -1 };
    const reversed = try animation.twoBoneIk(reversed_options);
    try h.expectQuaternion(
        math.Quaternion.fromAxisAngle(.y_axis, @as(f32, std.math.pi)),
        reversed.start_correction,
    );
    try h.expectQuaternion(
        math.Quaternion.fromAxisAngle(.z_axis, @as(f32, std.math.pi)),
        reversed.mid_correction,
    );

    const folded = try animation.twoBoneIk(bentIkOptions(.zero));
    try h.expectQuaternion(.identity, folded.start_correction);
    try h.expectQuaternion(
        math.Quaternion.fromAxisAngle(.z_axis, -@as(f32, std.math.pi) / 2),
        folded.mid_correction,
    );
    try std.testing.expect(!folded.reached);
}

test "SoftenReachability/IKTwoBoneJob" {
    var options = bentIkOptions(.{ .x = 1 });
    options.soften = 0.5;
    try std.testing.expect((try animation.twoBoneIk(options)).reached);
    options.target = .{ .x = 1.2 };
    try std.testing.expect(!(try animation.twoBoneIk(options)).reached);
    options.target = .{ .x = 3 };
    options.soften = 1;
    try std.testing.expect(!(try animation.twoBoneIk(options)).reached);
}

test "TwistAndZeroScale/IKTwoBoneJob" {
    var twist_options = bentIkOptions(.{ .x = 1, .y = 1 });
    twist_options.twist_angle = @as(f32, std.math.pi) / 2;
    const twisted = try animation.twoBoneIk(twist_options);
    try h.expectQuaternion(
        math.Quaternion.fromAxisAngle(
            math.Float3.normalize(.{ .x = 1, .y = 1 }),
            @as(f32, std.math.pi) / 2,
        ),
        twisted.start_correction,
    );
    try h.expectQuaternion(.identity, twisted.mid_correction);

    const zero = math.Float4x4.fromTransform(.{ .scale = .zero });
    const degenerate = try animation.twoBoneIk(.{
        .target = .x_axis,
        .start_joint = zero,
        .mid_joint = zero,
        .end_joint = zero,
    });
    try h.expectQuaternion(.identity, degenerate.start_correction);
    try h.expectQuaternion(.identity, degenerate.mid_correction);
    try std.testing.expect(!degenerate.reached);
}

test "ZeroScale/IKAimJob" {
    const result = try animation.aimIk(.{
        .target = .x_axis,
        .joint = math.Float4x4.fromTransform(.{ .scale = .zero }),
    });
    try h.expectQuaternion(.identity, result.correction);
    try std.testing.expect(!result.reached);
}

test "JointRestPose/SkeletonUtils" {
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{
        .{
            .name = "root",
            .parent = animation.no_parent,
            .rest_pose = .{ .translation = .{ .x = 4, .y = 5, .z = 6 } },
        },
    });
    defer skeleton.deinit();
    try h.expectFloat3(.{ .x = 4, .y = 5, .z = 6 }, skeleton.jointRestPose(0).translation);
}

fn expectEdges(
    track: *const animation.FloatTrack,
    from: f32,
    to: f32,
    threshold: f32,
    expected: []const animation.TrackEdge,
) !void {
    var iterator = animation.TrackEdgeIterator.init(track, from, to, threshold);
    for (expected) |edge| {
        const actual = iterator.next() orelse return error.MissingEdge;
        try h.expectFloat(edge.ratio, actual.ratio);
        try std.testing.expectEqual(edge.rising, actual.rising);
    }
    try std.testing.expectEqual(@as(?animation.TrackEdge, null), iterator.next());
}

test "LoopReverseAndBoundary/TrackEdgeTriggerJob" {
    var track = try animation.FloatTrack.initMixed(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = 0, .interpolation = .step },
        .{ .ratio = 0.5, .value = 2, .interpolation = .step },
        .{ .ratio = 1, .value = 0, .interpolation = .step },
    });
    defer track.deinit();

    try expectEdges(&track, 0, 3, 1, &.{
        .{ .ratio = 0.5, .rising = true },
        .{ .ratio = 1, .rising = false },
        .{ .ratio = 1.5, .rising = true },
        .{ .ratio = 2, .rising = false },
        .{ .ratio = 2.5, .rising = true },
        .{ .ratio = 3, .rising = false },
    });
    try expectEdges(&track, 3, 0, 1, &.{
        .{ .ratio = 3, .rising = true },
        .{ .ratio = 2.5, .rising = false },
        .{ .ratio = 2, .rising = true },
        .{ .ratio = 1.5, .rising = false },
        .{ .ratio = 1, .rising = true },
        .{ .ratio = 0.5, .rising = false },
    });
    try expectEdges(&track, -1, 1, 1, &.{
        .{ .ratio = -0.5, .rising = true },
        .{ .ratio = 0, .rising = false },
        .{ .ratio = 0.5, .rising = true },
        .{ .ratio = 1, .rising = false },
    });
    try expectEdges(&track, 0, 0.5, 1, &.{});
    try expectEdges(&track, 0, std.math.nextAfter(f32, 0.5, 1), 1, &.{
        .{ .ratio = 0.5, .rising = true },
    });
}

test "MixedInterpolation/TrackEdgeTriggerJob" {
    var track = try animation.FloatTrack.initMixed(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = 0, .interpolation = .step },
        .{ .ratio = 0.5, .value = 2, .interpolation = .linear },
        .{ .ratio = 1, .value = 0, .interpolation = .linear },
    });
    defer track.deinit();
    try expectEdges(&track, 0, 1, 1, &.{
        .{ .ratio = 0.5, .rising = true },
        .{ .ratio = 0.75, .rising = false },
    });
}
