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

fn expectFloat4x4(expected: math.Float4x4, actual: math.Float4x4) !void {
    for (expected.cols, actual.cols) |expected_col, actual_col| {
        for (expected_col, actual_col) |expected_value, actual_value| {
            try h.expectFloat(expected_value, actual_value);
        }
    }
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

    const Visitor = struct {
        skeleton: *const animation.Skeleton,
        joints: *std.ArrayList(usize),
        allocator: std.mem.Allocator,

        pub fn visit(self: *@This(), joint: usize, parent: i16) void {
            std.testing.expectEqual(self.skeleton.parents[joint], parent) catch unreachable;
            self.joints.append(self.allocator, joint) catch unreachable;
        }
    };
    var joints: std.ArrayList(usize) = .empty;
    defer joints.deinit(std.testing.allocator);
    var visitor: Visitor = .{
        .skeleton = &skeleton,
        .joints = &joints,
        .allocator = std.testing.allocator,
    };

    animation.iterateJointsDF(skeleton, null, &visitor);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, joints.items);
    joints.clearRetainingCapacity();
    animation.iterateJointsDF(skeleton, 1, &visitor);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, joints.items);
    joints.clearRetainingCapacity();
    animation.iterateJointsDF(skeleton, 2, &visitor);
    try std.testing.expectEqualSlices(usize, &.{2}, joints.items);
    joints.clearRetainingCapacity();
    animation.iterateJointsDF(skeleton, 99, &visitor);
    try std.testing.expectEqual(@as(usize, 0), joints.items.len);
}

test "InterateDFReverse/SkeletonUtils" {
    var skeleton = try makeSkeleton(std.testing.allocator);
    defer skeleton.deinit();
    const Visitor = struct {
        visited: *[4]bool,
        order: *std.ArrayList(usize),
        allocator: std.mem.Allocator,

        pub fn visit(self: *@This(), joint: usize, parent: i16) void {
            // In reverse depth-first order a parent cannot have been visited
            // before any of its children.
            if (parent != animation.no_parent) {
                std.testing.expect(!self.visited[@intCast(parent)]) catch unreachable;
            }
            std.testing.expect(!self.visited[joint]) catch unreachable;
            self.visited[joint] = true;
            self.order.append(self.allocator, joint) catch unreachable;
        }
    };
    var visited = [_]bool{ false, false, false, false };
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(std.testing.allocator);
    var visitor: Visitor = .{
        .visited = &visited,
        .order = &order,
        .allocator = std.testing.allocator,
    };
    animation.iterateJointsDFReverse(skeleton, &visitor);
    try std.testing.expectEqualSlices(usize, &.{ 3, 2, 1, 0 }, order.items);
}

test "InterateDFEmpty/SkeletonUtils" {
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{});
    defer skeleton.deinit();
    const Visitor = struct {
        visited: *bool,
        pub fn visit(self: *@This(), _: usize, _: i16) void {
            self.visited.* = true;
        }
    };
    var visited = false;
    var visitor: Visitor = .{ .visited = &visited };
    animation.iterateJointsDF(skeleton, null, &visitor);
    animation.iterateJointsDFReverse(skeleton, &visitor);
    try std.testing.expect(!visited);
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

test "SamplingNoTrack/SamplingJob" {
    const empty: animation.Animation = .{
        .allocator = std.testing.allocator,
        .name = &.{},
        .duration = 0,
        .tracks = &.{},
    };
    var context = try animation.SamplingContext.init(std.testing.allocator, 0);
    defer context.deinit();
    const sentinel: math.SoaTransform = .{
        .translation = .{
            .x = @splat(46),
            .y = @splat(-1),
            .z = @splat(2),
        },
        .rotation = math.SoaTransform.identity.rotation,
        .scale = .{
            .x = @splat(3),
            .y = @splat(4),
            .z = @splat(5),
        },
    };
    var output = [_]math.SoaTransform{sentinel};
    try animation.sample(&empty, 0, &context, &output);
    try std.testing.expectEqual(sentinel, output[0]);
}

test "Sampling/SamplingJob" {
    var value = try animation.Animation.init(std.testing.allocator, "", 1, &.{
        .{ .translations = &.{.{ .ratio = 0.2, .value = .{ -1, 0, 0 } }} },
        .{},
        .{ .translations = &.{
            .{ .ratio = 0, .value = .{ 2, 0, 0 } },
            .{ .ratio = 0.2, .value = .{ 6, 0, 0 } },
            .{ .ratio = 0.4, .value = .{ 8, 0, 0 } },
            .{ .ratio = 0.6, .value = .{ 10, 0, 0 } },
            .{ .ratio = 1, .value = .{ 11, 0, 0 } },
        } },
        .{ .translations = &.{
            .{ .ratio = 0.2, .value = .{ 7, 0, 0 } },
            .{ .ratio = 0.6, .value = .{ 9, 0, 0 } },
        } },
    });
    defer value.deinit();
    var context = try animation.SamplingContext.init(std.testing.allocator, 4);
    defer context.deinit();
    var output: [1]math.SoaTransform = undefined;

    const cases = [_]struct { ratio: f32, expected: [4]f32 }{
        .{ .ratio = -0.2, .expected = .{ -1, 0, 2, 7 } },
        .{ .ratio = 0, .expected = .{ -1, 0, 2, 7 } },
        .{ .ratio = 0.0000001, .expected = .{ -1, 0, 2.000002, 7 } },
        .{ .ratio = 0.1, .expected = .{ -1, 0, 4, 7 } },
        .{ .ratio = 0.2, .expected = .{ -1, 0, 6, 7 } },
        .{ .ratio = 0.3, .expected = .{ -1, 0, 7, 7.5 } },
        .{ .ratio = 0.4, .expected = .{ -1, 0, 8, 8 } },
        .{ .ratio = 0.3999999, .expected = .{ -1, 0, 7.999999, 8 } },
        .{ .ratio = 0.4000001, .expected = .{ -1, 0, 8.000001, 8.000001 } },
        .{ .ratio = 0.5, .expected = .{ -1, 0, 9, 8.5 } },
        .{ .ratio = 0.6, .expected = .{ -1, 0, 10, 9 } },
        .{ .ratio = 0.9999999, .expected = .{ -1, 0, 11, 9 } },
        .{ .ratio = 1, .expected = .{ -1, 0, 11, 9 } },
        .{ .ratio = 1.000001, .expected = .{ -1, 0, 11, 9 } },
        // Deliberate backward seeks verify cache invalidation.
        .{ .ratio = 0.5, .expected = .{ -1, 0, 9, 8.5 } },
        .{ .ratio = 0.9999999, .expected = .{ -1, 0, 11, 9 } },
        .{ .ratio = 0.0000001, .expected = .{ -1, 0, 2.000002, 7 } },
    };
    for (cases) |case| {
        try animation.sample(&value, case.ratio, &context, &output);
        for (0..4) |lane| {
            const sampled = math.soaLane(output[0], lane);
            try h.expectFloat(case.expected[lane], sampled.translation[0]);
            try h.expectFloat3(.{ case.expected[lane], 0, 0 }, sampled.translation);
            try h.expectQuaternion(math.quat.identity, sampled.rotation);
            try h.expectFloat3(@splat(1), sampled.scale);
        }
    }
}

test "SamplingTranslationRotationScaleAndClamp/SamplingJob" {
    var value = try animation.Animation.init(std.testing.allocator, "", 1, &.{
        .{ .translations = &.{
            .{ .ratio = 0.5, .value = .{ 1, 2, 4 } },
            .{ .ratio = 0.8, .value = .{ 2, 4, 8 } },
        } },
        .{ .rotations = &.{
            .{ .ratio = 0, .value = math.quat.identity },
            .{ .ratio = 1, .value = .{ 0, 1, 0, 0 } },
        } },
        .{ .scales = &.{
            .{ .ratio = 0.5, .value = @splat(0) },
            .{ .ratio = 0.8, .value = .{ -1, -1, -1 } },
        } },
        .{ .translations = &.{
            .{ .ratio = 0, .value = .{ -1, -2, -4 } },
            .{ .ratio = 1, .value = .{ -2, -4, -8 } },
        } },
    });
    defer value.deinit();
    var context = try animation.SamplingContext.init(std.testing.allocator, 4);
    defer context.deinit();
    var output: [1]math.SoaTransform = undefined;

    try animation.sample(&value, -1, &context, &output);
    try h.expectTransform(.{
        .translation = .{ 1, 2, 4 },
    }, math.soaLane(output[0], 0));
    try h.expectTransform(.{
        .rotation = math.quat.identity,
    }, math.soaLane(output[0], 1));
    try h.expectTransform(.{
        .scale = @splat(0),
    }, math.soaLane(output[0], 2));
    try h.expectTransform(.{
        .translation = .{ -1, -2, -4 },
    }, math.soaLane(output[0], 3));

    try animation.sample(&value, 0.5, &context, &output);
    try h.expectQuaternion(.{ 0, 0.70710677, 0, 0.70710677 }, math.soaLane(output[0], 1).rotation);
    try h.expectFloat3(.{ -1.5, -3, -6 }, math.soaLane(output[0], 3).translation);

    try animation.sample(&value, 2, &context, &output);
    try h.expectFloat3(.{ 2, 4, 8 }, math.soaLane(output[0], 0).translation);
    try h.expectQuaternion(.{ 0, 1, 0, 0 }, math.soaLane(output[0], 1).rotation);
    try h.expectFloat3(.{ -1, -1, -1 }, math.soaLane(output[0], 2).scale);
    try h.expectFloat3(.{ -2, -4, -8 }, math.soaLane(output[0], 3).translation);
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
        .translations = &.{.{ .ratio = 0.46, .value = .{ 1, 2, 3 } }},
    }});
    defer value.deinit();
    var context = try animation.SamplingContext.init(std.testing.allocator, 1);
    defer context.deinit();
    var output: [1]math.SoaTransform = undefined;
    try animation.sample(&value, 0, &context, &output);
    try h.expectFloat3(.{ 1, 2, 3 }, math.soaLane(output[0], 0).translation);
}

test "Sampling1Track2Keys/SamplingJob" {
    var value = try animation.Animation.init(std.testing.allocator, "", 1, &.{.{
        .translations = &.{
            .{ .ratio = 0, .value = @splat(0) },
            .{ .ratio = 1, .value = .{ 2, 4, 6 } },
        },
    }});
    defer value.deinit();
    var context = try animation.SamplingContext.init(std.testing.allocator, 1);
    defer context.deinit();
    var output: [1]math.SoaTransform = undefined;
    try animation.sample(&value, 0.25, &context, &output);
    try h.expectFloat3(.{ 0.5, 1, 1.5 }, math.soaLane(output[0], 0).translation);
    try animation.sample(&value, 0.75, &context, &output);
    try animation.sample(&value, 0.1, &context, &output);
    try h.expectFloat(0.2, math.soaLane(output[0], 0).translation[0]);
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
        .{ .translation = .{ 1, 0, 0 } },
        .{ .translation = .{ 0, 2, 0 } },
        .{ .translation = .{ 0, 0, 3 } },
        .{ .translation = .{ 4, 0, 0 } },
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
    try h.expectFloat3(.{ 1, 2, 3 }, math.Float4x4.translation(output[2]));

    output[1] = math.Float4x4.fromTransform(.{ .translation = .{ 10, 0, 0 } });
    output[2] = math.Float4x4.identity;
    try animation.localToModel(.{
        .skeleton = &skeleton,
        .input = &input,
        .from = 1,
        .to = 2,
        .from_excluded = true,
    }, &output);
    try h.expectFloat3(.{ 10, 0, 3 }, math.Float4x4.translation(output[2]));
}

test "RangesAndExcludedRoot/LocalToModel" {
    var skeleton = try makeSkeleton(std.testing.allocator);
    defer skeleton.deinit();
    var local = [_]math.Transform{
        .{ .translation = .{ 1, 0, 0 } },
        .{ .translation = .{ 0, 2, 0 } },
        .{ .translation = .{ 0, 0, 3 } },
        .{ .translation = .{ 4, 0, 0 } },
    };
    var input: [1]math.SoaTransform = undefined;
    math.aosToSoa(&local, &input);

    const untouched = math.Float4x4.fromTransform(.{ .translation = .{ 99, 99, 99 } });
    var output = [_]math.Float4x4{ untouched, untouched, untouched, untouched };
    try animation.localToModel(.{
        .skeleton = &skeleton,
        .input = &input,
        .from = 0,
        .to = 1,
    }, &output);
    try h.expectFloat3(.{ 1, 0, 0 }, math.Float4x4.translation(output[0]));
    try h.expectFloat3(.{ 1, 2, 0 }, math.Float4x4.translation(output[1]));
    try h.expectFloat3(.{ 99, 99, 99 }, math.Float4x4.translation(output[2]));
    try h.expectFloat3(.{ 99, 99, 99 }, math.Float4x4.translation(output[3]));

    // Excluding `from` consumes its existing model matrix, allowing callers
    // to update descendants after an external parent/root update.
    output = .{ untouched, untouched, untouched, untouched };
    output[0] = math.Float4x4.fromTransform(.{
        .translation = .{ 10, 0, 0 },
        .scale = .{ 2, 2, 2 },
    });
    try animation.localToModel(.{
        .skeleton = &skeleton,
        .input = &input,
        .from = 0,
        .from_excluded = true,
    }, &output);
    try h.expectFloat3(.{ 10, 0, 0 }, math.Float4x4.translation(output[0]));
    try h.expectFloat3(.{ 10, 4, 0 }, math.Float4x4.translation(output[1]));
    try h.expectFloat3(.{ 10, 4, 6 }, math.Float4x4.translation(output[2]));
    try h.expectFloat3(.{ 18, 0, 0 }, math.Float4x4.translation(output[3]));

    // A subtree update does not touch the later sibling branch.
    output[1] = untouched;
    output[2] = untouched;
    output[3] = untouched;
    try animation.localToModel(.{
        .skeleton = &skeleton,
        .input = &input,
        .from = 1,
    }, &output);
    try h.expectFloat3(.{ 10, 4, 0 }, math.Float4x4.translation(output[1]));
    try h.expectFloat3(.{ 10, 4, 6 }, math.Float4x4.translation(output[2]));
    try h.expectFloat3(.{ 99, 99, 99 }, math.Float4x4.translation(output[3]));
}

test "Empty/LocalToModel" {
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{});
    defer skeleton.deinit();
    try animation.localToModel(.{ .skeleton = &skeleton, .input = &.{} }, &.{});
}

test "FullTRSAndRoot/LocalToModel" {
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{
        .{ .name = "j0", .parent = animation.no_parent },
        .{ .name = "j1", .parent = 0 },
        .{ .name = "j2", .parent = 1 },
        .{ .name = "j3", .parent = 0 },
        .{ .name = "j4", .parent = 3 },
        .{ .name = "j5", .parent = 3 },
    });
    defer skeleton.deinit();

    const sqrt_half: f32 = @sqrt(0.5);
    var local = [_]math.Transform{
        .{ .translation = .{ 2, 2, 2 } },
        .{
            .rotation = .{ 0, sqrt_half, 0, sqrt_half },
        },
        .{
            .translation = .{ 1, 2, 4 },
            .scale = .{ 10, 10, 10 },
        },
        .{
            .translation = .{ -2, -2, -2 },
            .scale = .{ 10, 10, 10 },
        },
        .{ .translation = .{ 12, 46, -12 } },
        .{ .scale = .{ -0.1, -0.1, -0.1 } },
    };
    var input: [2]math.SoaTransform = undefined;
    math.aosToSoa(&local, &input);
    var output: [6]math.Float4x4 = undefined;

    try animation.localToModel(.{ .skeleton = &skeleton, .input = &input }, &output);
    const expected = [_]math.Float4x4{
        .{ .cols = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 2, 2, 2, 1 } } },
        .{ .cols = .{ .{ 0, 0, -1, 0 }, .{ 0, 1, 0, 0 }, .{ 1, 0, 0, 0 }, .{ 2, 2, 2, 1 } } },
        .{ .cols = .{ .{ 0, 0, -10, 0 }, .{ 0, 10, 0, 0 }, .{ 10, 0, 0, 0 }, .{ 6, 4, 1, 1 } } },
        .{ .cols = .{ .{ 10, 0, 0, 0 }, .{ 0, 10, 0, 0 }, .{ 0, 0, 10, 0 }, .{ 0, 0, 0, 1 } } },
        .{ .cols = .{ .{ 10, 0, 0, 0 }, .{ 0, 10, 0, 0 }, .{ 0, 0, 10, 0 }, .{ 120, 460, -120, 1 } } },
        .{ .cols = .{ .{ -1, 0, 0, 0 }, .{ 0, -1, 0, 0 }, .{ 0, 0, -1, 0 }, .{ 0, 0, 0, 1 } } },
    };
    for (expected, output) |expected_matrix, actual_matrix| {
        try expectFloat4x4(expected_matrix, actual_matrix);
    }

    const root = math.Float4x4.fromTransform(.{ .translation = .{ 4, 3, 2 } });
    try animation.localToModel(.{
        .skeleton = &skeleton,
        .input = &input,
        .root = root,
    }, &output);
    for (expected, output) |expected_matrix, actual_matrix| {
        var rooted = expected_matrix;
        rooted.cols[3][0] += 4;
        rooted.cols[3][1] += 3;
        rooted.cols[3][2] += 2;
        try expectFloat4x4(rooted, actual_matrix);
    }
}

test "RangeBoundariesAndMultipleRoots/LocalToModel" {
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{
        .{ .name = "root-a", .parent = animation.no_parent },
        .{ .name = "a-child", .parent = 0 },
        .{ .name = "a-leaf", .parent = 1 },
        .{ .name = "root-b", .parent = animation.no_parent },
    });
    defer skeleton.deinit();
    var local = [_]math.Transform{
        .{ .translation = .{ 1, 0, 0 } },
        .{ .translation = .{ 0, 2, 0 } },
        .{ .translation = .{ 0, 0, 3 } },
        .{ .translation = .{ 4, 0, 0 } },
    };
    var input: [1]math.SoaTransform = undefined;
    math.aosToSoa(&local, &input);
    const sentinel = math.Float4x4.fromTransform(.{ .translation = .{ 99, 0, 0 } });
    var output = [_]math.Float4x4{ sentinel, sentinel, sentinel, sentinel };

    // A bounded update is inclusive and cannot escape the selected subtree.
    try animation.localToModel(.{
        .skeleton = &skeleton,
        .input = &input,
        .from = 0,
        .to = 99,
    }, &output);
    try h.expectFloat3(.{ 1, 2, 3 }, math.Float4x4.translation(output[2]));
    try h.expectFloat3(.{ 99, 0, 0 }, math.Float4x4.translation(output[3]));

    // `to` before `from`, and an out-of-range `from`, are successful no-ops.
    output = .{ sentinel, sentinel, sentinel, sentinel };
    try animation.localToModel(.{
        .skeleton = &skeleton,
        .input = &input,
        .from = 2,
        .to = 1,
    }, &output);
    try animation.localToModel(.{
        .skeleton = &skeleton,
        .input = &input,
        .from = 93,
    }, &output);
    for (output) |matrix| try expectFloat4x4(sentinel, matrix);

    // Selecting the second root updates it without consuming the first tree.
    try animation.localToModel(.{
        .skeleton = &skeleton,
        .input = &input,
        .from = 3,
    }, &output);
    try h.expectFloat3(.{ 4, 0, 0 }, math.Float4x4.translation(output[3]));
    for (output[0..3]) |matrix| try expectFloat4x4(sentinel, matrix);
}

test "JobValidityAndDefault/TrackSamplingJob" {
    // The Zig sampling API has no separately invalid job object: a track and
    // returned value are required by the function signature. An empty runtime
    // track is nevertheless valid and has the same default result as Ozz.
    var track = try animation.FloatTrack.init(std.testing.allocator, "", &.{}, .linear);
    defer track.deinit();
    try h.expectFloat(0, track.sampleAt(0.5));
}

test "Float/TrackSamplingJob" {
    var track = try animation.FloatTrack.initMixed(std.testing.allocator, "float", &.{
        .{ .ratio = 0, .value = 0 },
        .{ .ratio = 0.5, .value = 4.6, .interpolation = .step },
        .{ .ratio = 0.7, .value = 9.2 },
        .{ .ratio = 0.9, .value = 0 },
    });
    defer track.deinit();
    const cases = [_][2]f32{
        .{ 0, 0 },     .{ 0.25, 2.3 }, .{ 0.5, 4.6 },
        .{ 0.6, 4.6 }, .{ 0.7, 9.2 },  .{ 0.8, 4.6 },
        .{ 0.9, 0 },   .{ 1, 0 },
    };
    for (cases) |case| try h.expectFloat(case[1], track.sampleAt(case[0]));
}

test "Run/MotionBlendingJob" {
    const sqrt_half: f32 = @sqrt(0.5);
    const first: math.Transform = .{
        .translation = .{ 2, 0, 0 },
        .rotation = .{ sqrt_half, 0, 0, sqrt_half },
    };
    const second: math.Transform = .{
        .translation = .{ 0, 0, 3 },
        // Same hemisphere correction case as upstream: the negative
        // quaternion represents the intended positive-y rotation.
        .rotation = .{ 0, -sqrt_half, 0, -sqrt_half },
    };

    try h.expectTransform(.identity, animation.blendMotion(&.{}));
    try h.expectTransform(.identity, animation.blendMotion(&.{
        .{ .delta = first, .weight = 0 },
        .{ .delta = second, .weight = 0 },
    }));
    try h.expectTransform(first, animation.blendMotion(&.{
        .{ .delta = first, .weight = 0.8 },
        .{ .delta = second, .weight = -1 },
    }));

    const expected_blend: math.Transform = .{
        .translation = .{ 2.134313, 0, 0.533578 },
        .rotation = .{ 0.6172133, 0.1543033, 0, 0.7715167 },
    };
    try h.expectTransform(expected_blend, animation.blendMotion(&.{
        .{ .delta = first, .weight = 0.8 },
        .{ .delta = second, .weight = 0.2 },
    }));
    // Weight magnitude is normalized away.
    try h.expectTransform(expected_blend, animation.blendMotion(&.{
        .{ .delta = first, .weight = 8 },
        .{ .delta = second, .weight = 2 },
    }));
    try h.expectTransform(expected_blend, animation.blendMotion(&.{
        .{ .delta = first, .weight = 0.08 },
        .{ .delta = second, .weight = 0.02 },
    }));

    var zero_length = first;
    zero_length.translation = @splat(0);
    var z_motion = second;
    z_motion.translation = .{ 0, 0, 2 };
    const zero_result = animation.blendMotion(&.{
        .{ .delta = zero_length, .weight = 0.8 },
        .{ .delta = z_motion, .weight = 0.2 },
    });
    try h.expectFloat3(.{ 0, 0, 0.4 }, zero_result.translation);
    try h.expectQuaternion(expected_blend.rotation, zero_result.rotation);
    try h.expectFloat3(@splat(1), zero_result.scale);

    var backward = first;
    backward.translation = .{ 0, 0, -2 };
    const opposed = animation.blendMotion(&.{
        .{ .delta = backward, .weight = 1 },
        .{ .delta = z_motion, .weight = 1 },
    });
    try h.expectFloat3(@splat(0), opposed.translation);
    try h.expectQuaternion(
        .{ 0.408248, 0.408248, 0, 0.816496 },
        opposed.rotation,
    );
    try h.expectFloat3(@splat(1), opposed.scale);
}

test "Correction/IKAimJob" {
    const result = try animation.aimIk(.{
        .target = .{ 0, 1, 0 },
        .joint = .identity,
    });
    try std.testing.expect(result.reached);
    try h.expectFloat3(.{ 0, 1, 0 }, math.quat.rotate(result.correction, .{ 1, 0, 0 }));
}

test "Weight/IKAimJob" {
    const result = try animation.aimIk(.{
        .target = .{ 0, 1, 0 },
        .joint = .identity,
        .weight = 0,
    });
    try h.expectQuaternion(math.quat.identity, result.correction);
}

test "MidAxis/IKTwoBoneJob" {
    try std.testing.expectError(animation.Error.InvalidLayer, animation.twoBoneIk(.{
        .target = .{ 1, 0, 0 },
        .start_joint = .identity,
        .mid_joint = math.Float4x4.fromTransform(.{ .translation = .{ 1, 0, 0 } }),
        .end_joint = math.Float4x4.fromTransform(.{ .translation = .{ 2, 0, 0 } }),
        .mid_axis = .{ 2, 0, 0 },
    }));
}

test "Weight/IKTwoBoneJob" {
    const result = try animation.twoBoneIk(.{
        .target = .{ 1, 1, 0 },
        .start_joint = .identity,
        .mid_joint = math.Float4x4.fromTransform(.{ .translation = .{ 1, 0, 0 } }),
        .end_joint = math.Float4x4.fromTransform(.{ .translation = .{ 2, 0, 0 } }),
        .weight = 0,
    });
    try h.expectQuaternion(math.quat.identity, result.start_correction);
    try h.expectQuaternion(math.quat.identity, result.mid_correction);
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
    math.aosToSoa(&.{.{ .translation = .{ 1, 0, 0 }, .scale = .{ 2, 3, 4 } }}, &rest);
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{ .rest_pose = &rest, .layers = &.{} }, &output);
    try h.expectTransform(math.soaLane(rest[0], 0), math.soaLane(output[0], 0));
}

test "Weight/BlendingJob" {
    var positive: [1]math.SoaTransform = undefined;
    var negative: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{.{ .translation = .{ 4, 0, 0 } }}, &positive);
    math.aosToSoa(&.{.{ .translation = .{ -4, 0, 0 } }}, &negative);
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{
            .{ .transforms = &positive, .weight = 0.25 },
            .{ .transforms = &negative, .weight = 0.75 },
        },
    }, &output);
    try h.expectFloat(-2, math.soaLane(output[0], 0).translation[0]);
}

test "JointWeights/BlendingJob" {
    var pose: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{
        .{ .translation = .{ 2, 0, 0 } },
        .{ .translation = .{ 4, 0, 0 } },
    }, &pose);
    const weights: [1]math.Vec4f32 = .{.{ 1, 0, 0, 0 }};
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{.{ .transforms = &pose, .weight = 1, .joint_weights = &weights }},
    }, &output);
    try h.expectFloat(2, math.soaLane(output[0], 0).translation[0]);
    try h.expectFloat(0, math.soaLane(output[0], 1).translation[0]);
}

test "Normalize/BlendingJob" {
    var a: [1]math.SoaTransform = undefined;
    var b: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{.{ .translation = .{ 2, 0, 0 } }}, &a);
    math.aosToSoa(&.{.{ .translation = .{ 4, 0, 0 } }}, &b);
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{
            .{ .transforms = &a, .weight = 2 },
            .{ .transforms = &b, .weight = 3 },
        },
    }, &output);
    try h.expectFloat(3.2, math.soaLane(output[0], 0).translation[0]);
}

test "Threshold/BlendingJob" {
    var rest: [1]math.SoaTransform = undefined;
    var pose: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{.{ .translation = .{ 10, 0, 0 } }}, &rest);
    math.aosToSoa(&.{.{ .translation = @splat(0) }}, &pose);
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &rest,
        .layers = &.{.{ .transforms = &pose, .weight = 0.05 }},
        .threshold = 0.1,
    }, &output);
    try h.expectFloat(5, math.soaLane(output[0], 0).translation[0]);
}

test "AdditiveWeight/BlendingJob" {
    var additive: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{.{
        .translation = .{ 4, 0, 0 },
        .rotation = math.quat.fromAxisAngle(.{ 0, 0, 1 }, @as(f32, std.math.pi) / 2),
        .scale = .{ 2, 2, 2 },
    }}, &additive);
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{},
        .additive_layers = &.{.{ .transforms = &additive, .weight = 0.5 }},
    }, &output);
    const result = math.soaLane(output[0], 0);
    try h.expectFloat(2, result.translation[0]);
    try h.expectFloat(1.5, result.scale[0]);
    try h.expectFloat3(
        .{ @sqrt(@as(f32, 0.5)), @sqrt(@as(f32, 0.5)), 0 },
        math.quat.rotate(result.rotation, .{ 1, 0, 0 }),
    );
}

test "AdditiveJointWeight/BlendingJob" {
    var additive: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{
        .{ .translation = .{ 4, 0, 0 }, .scale = .{ 2, 2, 2 } },
        .{ .translation = .{ 8, 0, 0 }, .scale = .{ 4, 4, 4 } },
    }, &additive);
    const weights: [1]math.Vec4f32 = .{.{ 1, 0.5, 0, -1 }};
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{},
        .additive_layers = &.{.{ .transforms = &additive, .weight = 0.5, .joint_weights = &weights }},
    }, &output);
    try h.expectFloat(2, math.soaLane(output[0], 0).translation[0]);
    try h.expectFloat(2, math.soaLane(output[0], 1).translation[0]);
}

test "RotationScaleHemisphereAndNegativeAdditive/BlendingJob" {
    const quarter_turn = math.quat.fromAxisAngle(
        .{ 0, 0, 1 },
        @as(f32, std.math.pi) / 2,
    );
    var normal_a: [1]math.SoaTransform = undefined;
    var normal_b: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{.{
        .translation = .{ 2, 4, 6 },
        .rotation = quarter_turn,
        .scale = .{ 2, 3, 4 },
    }}, &normal_a);
    math.aosToSoa(&.{.{
        .translation = .{ 2, 4, 6 },
        .rotation = math.quat.negate(quarter_turn),
        .scale = .{ 2, 3, 4 },
    }}, &normal_b);
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{
            .{ .transforms = &normal_a, .weight = 0.25 },
            .{ .transforms = &normal_b, .weight = 0.75 },
        },
    }, &output);
    const normal = math.soaLane(output[0], 0);
    try h.expectFloat3(.{ 2, 4, 6 }, normal.translation);
    try h.expectQuaternion(quarter_turn, normal.rotation);
    try h.expectFloat3(.{ 2, 3, 4 }, normal.scale);

    var additive: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{.{
        .translation = .{ 4, 0, 0 },
        .rotation = quarter_turn,
        .scale = .{ 2, 2, 2 },
    }}, &additive);
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{},
        .additive_layers = &.{.{ .transforms = &additive, .weight = -0.5 }},
    }, &output);
    const subtracted = math.soaLane(output[0], 0);
    try h.expectFloat3(.{ -2, 0, 0 }, subtracted.translation);
    try h.expectFloat3(@splat(2.0 / 3.0), subtracted.scale);
    try h.expectFloat3(
        .{ @sqrt(@as(f32, 0.5)), -@sqrt(@as(f32, 0.5)), 0 },
        math.quat.rotate(subtracted.rotation, .{ 1, 0, 0 }),
    );
}

test "ExtendedAdditiveWeights/BlendingJob" {
    const rotation = math.quat.fromAxisAngle(.{ 0, 0, 1 }, @as(f32, std.math.pi) / 3);
    var additive: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{
        .{ .translation = .{ 2, 0, 0 }, .rotation = rotation, .scale = .{ 2, 3, 4 } },
        .{ .translation = .{ 4, 0, 0 }, .rotation = rotation, .scale = .{ 2, 3, 4 } },
        .{ .translation = .{ 8, 0, 0 }, .rotation = rotation, .scale = .{ 2, 3, 4 } },
        .{ .translation = .{ 16, 0, 0 }, .rotation = rotation, .scale = .{ 2, 3, 4 } },
    }, &additive);
    const joint_weights: [1]math.Vec4f32 = .{.{ 1, 0.5, -1, 2 }};
    var output: [1]math.SoaTransform = undefined;
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{},
        .additive_layers = &.{.{ .transforms = &additive, .weight = 2, .joint_weights = &joint_weights }},
    }, &output);
    try h.expectFloat3(.{ 4, 0, 0 }, math.soaLane(output[0], 0).translation);
    try h.expectFloat3(.{ 4, 0, 0 }, math.soaLane(output[0], 1).translation);
    try h.expectTransform(.identity, math.soaLane(output[0], 2));
    try h.expectFloat3(.{ 64, 0, 0 }, math.soaLane(output[0], 3).translation);

    var singular: [1]math.SoaTransform = undefined;
    math.aosToSoa(&.{.{ .scale = .{ -1, 0, 1 } }}, &singular);
    try animation.blend(.{
        .rest_pose = &.{math.SoaTransform.identity},
        .layers = &.{},
        .additive_layers = &.{.{ .transforms = &singular, .weight = -0.5 }},
    }, &output);
    const scale = math.soaLane(output[0], 0).scale;
    try std.testing.expect(std.math.isInf(scale[0]));
    try h.expectFloat(2, scale[1]);
    try h.expectFloat(1, scale[2]);
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
        .{ .translations = &.{ .{ .ratio = 0, .value = @splat(0) }, .{ .ratio = 1, .value = .{ 1, 0, 0 } } } },
        .{ .translations = &.{ .{ .ratio = 0, .value = @splat(0) }, .{ .ratio = 1, .value = .{ 2, 0, 0 } } } },
        .{ .translations = &.{ .{ .ratio = 0, .value = @splat(0) }, .{ .ratio = 1, .value = .{ 3, 0, 0 } } } },
        .{ .translations = &.{ .{ .ratio = 0, .value = @splat(0) }, .{ .ratio = 1, .value = .{ 4, 0, 0 } } } },
    });
    defer value.deinit();
    var context = try animation.SamplingContext.init(std.testing.allocator, 4);
    defer context.deinit();
    var output: [1]math.SoaTransform = undefined;
    try animation.sample(&value, 0.5, &context, &output);
    for (0..4) |lane| {
        try h.expectFloat(@as(f32, @floatFromInt(lane + 1)) * 0.5, math.soaLane(output[0], lane).translation[0]);
    }
}

test "Cache/SamplingJob" {
    var value = try animation.Animation.init(std.testing.allocator, "", 1, &.{.{
        .translations = &.{
            .{ .ratio = 0, .value = @splat(0) },
            .{ .ratio = 0.25, .value = .{ 1, 0, 0 } },
            .{ .ratio = 0.5, .value = .{ 2, 0, 0 } },
            .{ .ratio = 0.75, .value = .{ 3, 0, 0 } },
            .{ .ratio = 1, .value = .{ 4, 0, 0 } },
        },
    }});
    defer value.deinit();
    var context = try animation.SamplingContext.init(std.testing.allocator, 1);
    defer context.deinit();
    var output: [1]math.SoaTransform = undefined;
    for ([_]f32{ 0.1, 0.6, 0.9, 0.2 }) |ratio| {
        try animation.sample(&value, ratio, &context, &output);
        try h.expectFloat(ratio * 4, math.soaLane(output[0], 0).translation[0]);
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
                .{ .ratio = 0, .value = @splat(0) },
                .{ .ratio = 0.5, .value = @splat(0) },
                .{ .ratio = 1, .value = @splat(0) },
            },
            .rotations = &.{.{ .ratio = 0.7, .value = math.quat.identity }},
        },
        .{ .scales = &.{.{ .ratio = 0.1, .value = @splat(1) }} },
    });
    defer value.deinit();
    try std.testing.expectEqual(@as(usize, 3), animation.countTranslationKeyframes(value, null));
    try std.testing.expectEqual(@as(usize, 1), animation.countRotationKeyframes(value, null));
    try std.testing.expectEqual(@as(usize, 1), animation.countScaleKeyframes(value, null));
    try std.testing.expectEqual(@as(usize, 0), animation.countTranslationKeyframes(value, 1));
}

fn expectTrackValue(comptime kind: ozz.animation.ValueKind, expected: kind.Value(), actual: kind.Value()) !void {
    switch (kind) {
        .float2 => {
            try h.expectFloat(expected[0], actual[0]);
            try h.expectFloat(expected[1], actual[1]);
        },
        .float3 => try h.expectFloat3(expected, actual),
        .float4 => try h.expectFloat4(expected, actual),
        else => @compileError("unsupported test track type"),
    }
}

fn expectVectorTrackSampling(comptime kind: ozz.animation.ValueKind, key1: kind.Value(), key2: kind.Value(), first_midpoint: kind.Value(), last_midpoint: kind.Value()) !void {
    const zero: kind.Value() = @splat(0);
    var track = try animation.Track(kind).initMixed(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = zero },
        .{ .ratio = 0.5, .value = key1, .interpolation = .step },
        .{ .ratio = 0.7, .value = key2 },
        .{ .ratio = 0.9, .value = zero },
    });
    defer track.deinit();
    try expectTrackValue(kind, zero, track.sampleAt(0));
    try expectTrackValue(kind, first_midpoint, track.sampleAt(0.25));
    try expectTrackValue(kind, key1, track.sampleAt(0.5));
    try expectTrackValue(kind, key1, track.sampleAt(0.6));
    try expectTrackValue(kind, key2, track.sampleAt(0.7));
    try expectTrackValue(kind, last_midpoint, track.sampleAt(0.8));
    try expectTrackValue(kind, zero, track.sampleAt(0.9));
    try expectTrackValue(kind, zero, track.sampleAt(1));
}

test "Float2/TrackSamplingJob" {
    try expectVectorTrackSampling(.float2, .{ 2.3, 4.6 }, .{ 4.6, 9.2 }, .{ 1.15, 2.3 }, .{ 2.3, 4.6 });
}

test "Float3/TrackSamplingJob" {
    try expectVectorTrackSampling(.float3, .{ 0, 2.3, 4.6 }, .{ 0, 4.6, 9.2 }, .{ 0, 1.15, 2.3 }, .{ 0, 2.3, 4.6 });
}

test "Float4/TrackSamplingJob" {
    try expectVectorTrackSampling(.float4, .{ 0, 2.3, 0, 4.6 }, .{ 0, 4.6, 0, 9.2 }, .{ 0, 1.15, 0, 2.3 }, .{ 0, 2.3, 0, 4.6 });
}

test "Bounds/TrackSamplingJob" {
    var track = try animation.FloatTrack.initMixed(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = 0 },
        .{ .ratio = 0.5, .value = 46, .interpolation = .step },
        .{ .ratio = 0.7, .value = 0 },
    });
    defer track.deinit();
    for ([_][2]f32{
        .{ -0.0000001, 0 }, .{ 0, 0 },         .{ 0.5, 46 },
        .{ 1, 0 },          .{ 1.0000001, 0 }, .{ 1.5, 0 },
    }) |case| try h.expectFloat(case[1], track.sampleAt(case[0]));
}

test "Constant/TrackSamplingJob" {
    var track = try animation.FloatTrack.init(std.testing.allocator, "", &.{
        .{ .ratio = 0.46, .value = 93 },
    }, .linear);
    defer track.deinit();
    try h.expectFloat(93, track.sampleAt(0));
    try h.expectFloat(93, track.sampleAt(1));
}

test "Quaternion/TrackSamplingJob" {
    const qx: math.Quat4f32 = .{ 0.70710677, 0, 0, 0.70710677 };
    const qy: math.Quat4f32 = .{ 0, 0.70710677, 0, 0.70710677 };
    var track = try animation.QuaternionTrack.initMixed(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = qx },
        .{ .ratio = 0.5, .value = qy, .interpolation = .step },
        .{ .ratio = 0.7, .value = qx },
        .{ .ratio = 0.9, .value = math.quat.identity },
    });
    defer track.deinit();
    const cases = [_]struct { ratio: f32, expected: math.Quat4f32 }{
        .{ .ratio = 0, .expected = qx },
        .{ .ratio = 0.1, .expected = .{ 0.61721331, 0.15430345, 0, 0.77151674 } },
        .{ .ratio = 0.4999999, .expected = qy },
        .{ .ratio = 0.5, .expected = qy },
        .{ .ratio = 0.6, .expected = qy },
        .{ .ratio = 0.7, .expected = qx },
        .{ .ratio = 0.8, .expected = .{ 0.38268333, 0, 0, 0.92387962 } },
        .{ .ratio = 0.9, .expected = math.quat.identity },
        .{ .ratio = 1, .expected = math.quat.identity },
    };
    for (cases) |case| try h.expectQuaternion(case.expected, track.sampleAt(case.ratio));
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
    var track = try ozz.offline.buildTrack(.float, std.testing.allocator, raw);
    defer track.deinit();
    var iterator = animation.TrackEdgeIterator.init(&track, 0, 1, 0.5);
    try std.testing.expectEqual(@as(?animation.TrackEdge, null), iterator.next());
}

test "Twist/IKAimJob" {
    const result = try animation.aimIk(.{
        .target = .{ 1, 0, 0 },
        .joint = .identity,
        .twist_angle = @as(f32, std.math.pi) / 2,
    });
    try h.expectFloat3(.{ 0, 0, 1 }, math.quat.rotate(result.correction, .{ 0, 1, 0 }));
}

test "Offset/IKAimJob" {
    const result = try animation.aimIk(.{
        .target = .{ 2, 1, 0 },
        .joint = .identity,
        .offset = .{ 0, 1, 0 },
    });
    try std.testing.expect(result.reached);
}

test "TargetTooClose/IKAimJob" {
    const result = try animation.aimIk(.{
        .target = @splat(0),
        .joint = .identity,
    });
    try std.testing.expect(result.reached);
    try h.expectQuaternion(math.quat.identity, result.correction);
}

test "MatrixVariants/IKAimJob" {
    const pi: f32 = @floatCast(std.math.pi);
    const joints = [_]math.Float4x4{
        .identity,
        math.Float4x4.fromTransform(.{ .translation = .{ 0, 1, 0 } }),
        math.Float4x4.fromTransform(.{ .rotation = math.quat.fromAxisAngle(.{ 1, 0, 0 }, pi / 3) }),
        math.Float4x4.fromTransform(.{ .scale = .{ 2, 2, 2 } }),
        math.Float4x4.fromTransform(.{ .scale = .{ 1, 2, 1 } }),
        math.Float4x4.fromTransform(.{ .scale = .{ -3, -3, -3 } }),
    };
    const local_targets = [_]math.Vec3f32{
        .{ 1, 0, 0 },
        .{ -1, 0, 0 },
        .{ 0, 0, 1 },
        .{ 0, 0, -1 },
        .{ 1, 1, 0 },
        .{ 2, 2, 0 },
    };
    const expected = [_]math.Quat4f32{
        math.quat.identity,
        math.quat.fromAxisAngle(.{ 0, 1, 0 }, pi),
        math.quat.fromAxisAngle(.{ 0, 1, 0 }, -pi / 2),
        math.quat.fromAxisAngle(.{ 0, 1, 0 }, pi / 2),
        math.quat.fromAxisAngle(.{ 0, 0, 1 }, pi / 4),
        math.quat.fromAxisAngle(.{ 0, 0, 1 }, pi / 4),
    };
    for (joints) |joint| {
        const pole = math.Float4x4.transformVector(joint, .{ 0, 1, 0 });
        for (local_targets, expected) |target, expected_correction| {
            const result = try animation.aimIk(.{
                .target = math.Float4x4.transformPoint(joint, target),
                .joint = joint,
                .pole_vector = pole,
            });
            try std.testing.expect(result.reached);
            try h.expectQuaternion(expected_correction, result.correction);
        }
    }
}

test "Forward/IKAimJob" {
    const pi: f32 = @floatCast(std.math.pi);
    var options: animation.AimOptions = .{
        .target = .{ 1, 0, 0 },
        .joint = .identity,
    };

    options.forward = .{ -1, 0, 0 };
    try h.expectQuaternion(
        math.quat.fromAxisAngle(.{ 0, 1, 0 }, pi),
        (try animation.aimIk(options)).correction,
    );
    options.forward = .{ 0, 0, 1 };
    try h.expectQuaternion(
        math.quat.fromAxisAngle(.{ 0, 1, 0 }, pi / 2),
        (try animation.aimIk(options)).correction,
    );

    options.forward = .{ 1, 0, 0 };
    options.up = .{ 0, 0, 1 };
    try h.expectQuaternion(
        math.quat.fromAxisAngle(.{ 1, 0, 0 }, -pi / 2),
        (try animation.aimIk(options)).correction,
    );
    options.up = @splat(0);
    try h.expectQuaternion(math.quat.identity, (try animation.aimIk(options)).correction);

    options.up = .{ 0, 1, 0 };
    options.pole_vector = .{ 0, 0, 1 };
    try h.expectQuaternion(
        math.quat.fromAxisAngle(.{ 1, 0, 0 }, pi / 2),
        (try animation.aimIk(options)).correction,
    );

    options.target = .{ 0, 1, 0 };
    options.pole_vector = .{ 0, 1, 0 };
    try h.expectQuaternion(
        math.quat.fromAxisAngle(.{ 0, 0, 1 }, pi / 2),
        (try animation.aimIk(options)).correction,
    );
}

test "JobValidity/IKAimJob" {
    try std.testing.expectError(animation.Error.InvalidLayer, animation.aimIk(.{
        .target = .{ 1, 0, 0 },
        .joint = .identity,
        .forward = .{ 0.5, 0, 0 },
    }));
    try std.testing.expectError(animation.Error.InvalidLayer, animation.aimIk(.{
        .target = .{ 1, 0, 0 },
        .joint = .identity,
        .forward = @splat(0),
    }));
    try std.testing.expect((try animation.aimIk(.{
        .target = .{ 1, 0, 0 },
        .joint = .identity,
    })).reached);
}

test "Up/IKAimJob" {
    const pi: f32 = @floatCast(std.math.pi);
    const cases = [_]struct {
        up: math.Vec3f32,
        expected: math.Quat4f32,
    }{
        .{ .up = .{ 0, 1, 0 }, .expected = math.quat.identity },
        .{ .up = .{ 0, -1, 0 }, .expected = math.quat.fromAxisAngle(.{ 1, 0, 0 }, pi) },
        .{ .up = .{ 0, 0, 1 }, .expected = math.quat.fromAxisAngle(.{ 1, 0, 0 }, -pi / 2) },
        .{ .up = .{ 0, 0, 2 }, .expected = math.quat.fromAxisAngle(.{ 1, 0, 0 }, -pi / 2) },
        .{ .up = .{ 0, 0, 1e-9 }, .expected = math.quat.fromAxisAngle(.{ 1, 0, 0 }, -pi / 2) },
        .{ .up = @splat(0), .expected = math.quat.identity },
    };
    for (cases) |case| {
        try h.expectQuaternion(case.expected, (try animation.aimIk(.{
            .target = .{ 1, 0, 0 },
            .joint = .identity,
            .up = case.up,
        })).correction);
    }
}

test "Pole/IKAimJob" {
    const pi: f32 = @floatCast(std.math.pi);
    const cases = [_]struct {
        pole: math.Vec3f32,
        expected: math.Quat4f32,
    }{
        .{ .pole = .{ 0, 1, 0 }, .expected = math.quat.identity },
        .{ .pole = .{ 0, -1, 0 }, .expected = math.quat.fromAxisAngle(.{ 1, 0, 0 }, pi) },
        .{ .pole = .{ 0, 0, 1 }, .expected = math.quat.fromAxisAngle(.{ 1, 0, 0 }, pi / 2) },
        .{ .pole = .{ 0, 0, 2 }, .expected = math.quat.fromAxisAngle(.{ 1, 0, 0 }, pi / 2) },
        .{ .pole = .{ 0, 0, 1e-9 }, .expected = math.quat.fromAxisAngle(.{ 1, 0, 0 }, pi / 2) },
    };
    for (cases) |case| {
        try h.expectQuaternion(case.expected, (try animation.aimIk(.{
            .target = .{ 1, 0, 0 },
            .joint = .identity,
            .pole_vector = case.pole,
        })).correction);
    }
}

test "AlignedTargetUp/IKAimJob" {
    const pi: f32 = @floatCast(std.math.pi);
    const cases = [_]struct {
        target: math.Vec3f32,
        expected: math.Quat4f32,
    }{
        .{ .target = .{ 1, 0, 0 }, .expected = math.quat.identity },
        .{ .target = .{ 0, 1, 0 }, .expected = math.quat.fromAxisAngle(.{ 0, 0, 1 }, pi / 2) },
        .{ .target = .{ 0, 2, 0 }, .expected = math.quat.fromAxisAngle(.{ 0, 0, 1 }, pi / 2) },
        .{ .target = .{ 0, -2, 0 }, .expected = math.quat.fromAxisAngle(.{ 0, 0, 1 }, -pi / 2) },
    };
    for (cases) |case| {
        try h.expectQuaternion(case.expected, (try animation.aimIk(.{
            .target = case.target,
            .joint = .identity,
        })).correction);
    }
}

test "AlignedTargetPole/IKAimJob" {
    const pi: f32 = @floatCast(std.math.pi);
    try h.expectQuaternion(math.quat.identity, (try animation.aimIk(.{
        .target = .{ 1, 0, 0 },
        .joint = .identity,
    })).correction);
    try h.expectQuaternion(math.quat.fromAxisAngle(.{ 0, 0, 1 }, pi / 2), (try animation.aimIk(.{
        .target = .{ 0, 1, 0 },
        .joint = .identity,
        .pole_vector = .{ 0, 1, 0 },
    })).correction);
}

test "OffsetReachability/IKAimJob" {
    const pi: f32 = @floatCast(std.math.pi);
    const cases = [_]struct {
        offset: math.Vec3f32,
        expected: math.Quat4f32,
        reached: bool,
    }{
        .{ .offset = @splat(0), .expected = math.quat.identity, .reached = true },
        .{ .offset = .{ 0, std.math.sqrt(0.5), 0 }, .expected = math.quat.fromAxisAngle(.{ 0, 0, 1 }, -pi / 4), .reached = true },
        .{ .offset = .{ 0.5, 0.5, 0 }, .expected = math.quat.fromAxisAngle(.{ 0, 0, 1 }, -pi / 6), .reached = true },
        .{ .offset = .{ -0.5, 0.5, 0 }, .expected = math.quat.fromAxisAngle(.{ 0, 0, 1 }, -pi / 6), .reached = true },
        .{ .offset = .{ 0.5, 0, 0.5 }, .expected = math.quat.fromAxisAngle(.{ 0, 1, 0 }, pi / 6), .reached = true },
        .{ .offset = .{ 0, 1, 0 }, .expected = math.quat.fromAxisAngle(.{ 0, 0, 1 }, -pi / 2), .reached = true },
        .{ .offset = .{ 0, 2, 0 }, .expected = math.quat.identity, .reached = false },
    };
    for (cases) |case| {
        const result = try animation.aimIk(.{
            .target = .{ 1, 0, 0 },
            .joint = .identity,
            .offset = case.offset,
        });
        try std.testing.expectEqual(case.reached, result.reached);
        try h.expectQuaternion(case.expected, result.correction);
    }
}

test "ZeroLengthBoneChain/IKTwoBoneJob" {
    const result = try animation.twoBoneIk(.{
        .target = .{ 1, 0, 0 },
        .start_joint = .identity,
        .mid_joint = .identity,
        .end_joint = .identity,
    });
    try std.testing.expect(!result.reached);
}

test "ZeroLengthStartTarget/IKTwoBoneJob" {
    const result = try animation.twoBoneIk(.{
        .target = @splat(0),
        .start_joint = .identity,
        .mid_joint = math.Float4x4.fromTransform(.{
            .translation = .{ 0, 1, 0 },
            .rotation = math.quat.fromAxisAngle(
                .{ 0, 0, 1 },
                @as(f32, std.math.pi) / 2,
            ),
        }),
        .end_joint = math.Float4x4.fromTransform(.{
            .translation = .{ 1, 1, 0 },
        }),
    });
    try h.expectQuaternion(math.quat.identity, result.start_correction);
    try h.expectQuaternion(
        math.quat.fromAxisAngle(.{ 0, 0, 1 }, -@as(f32, std.math.pi) / 2),
        result.mid_correction,
    );
}

test "StartJointCorrection/IKTwoBoneJob" {
    const result = try animation.twoBoneIk(.{
        .target = .{ 1, 1, 0 },
        .start_joint = .identity,
        .mid_joint = math.Float4x4.fromTransform(.{ .translation = .{ 1, 0, 0 } }),
        .end_joint = math.Float4x4.fromTransform(.{ .translation = .{ 2, 0, 0 } }),
    });
    try std.testing.expect(math.quat.dot(math.quat.identity, result.start_correction) < 0.999);
}

fn bentIkOptions(target: math.Vec3f32) animation.TwoBoneOptions {
    return .{
        .target = target,
        .start_joint = .identity,
        .mid_joint = math.Float4x4.fromTransform(.{ .translation = .{ 0, 1, 0 } }),
        .end_joint = math.Float4x4.fromTransform(.{ .translation = .{ 1, 1, 0 } }),
        .mid_axis = .{ 0, 0, 1 },
        .pole_vector = .{ 0, 1, 0 },
    };
}

test "MidAxisAndZeroTarget/IKTwoBoneJob" {
    const unchanged = try animation.twoBoneIk(bentIkOptions(.{ 1, 1, 0 }));
    try h.expectQuaternion(math.quat.identity, unchanged.start_correction);
    try h.expectQuaternion(math.quat.identity, unchanged.mid_correction);
    try std.testing.expect(unchanged.reached);

    var reversed_options = bentIkOptions(.{ 1, 1, 0 });
    reversed_options.mid_axis = .{ 0, 0, -1 };
    const reversed = try animation.twoBoneIk(reversed_options);
    try h.expectQuaternion(
        math.quat.fromAxisAngle(.{ 0, 1, 0 }, @as(f32, std.math.pi)),
        reversed.start_correction,
    );
    try h.expectQuaternion(
        math.quat.fromAxisAngle(.{ 0, 0, 1 }, @as(f32, std.math.pi)),
        reversed.mid_correction,
    );

    const folded = try animation.twoBoneIk(bentIkOptions(@splat(0)));
    try h.expectQuaternion(math.quat.identity, folded.start_correction);
    try h.expectQuaternion(
        math.quat.fromAxisAngle(.{ 0, 0, 1 }, -@as(f32, std.math.pi) / 2),
        folded.mid_correction,
    );
    try std.testing.expect(!folded.reached);
}

test "JobValidity/IKTwoBoneJob" {
    var invalid = bentIkOptions(.{ 1, 1, 0 });
    invalid.mid_axis = .{ 0.5, 0, 0 };
    try std.testing.expectError(animation.Error.InvalidLayer, animation.twoBoneIk(invalid));

    const valid = try animation.twoBoneIk(bentIkOptions(.{ 1, 1, 0 }));
    try std.testing.expect(valid.reached);
    try h.expectQuaternion(math.quat.identity, valid.start_correction);
    try h.expectQuaternion(math.quat.identity, valid.mid_correction);
}

test "Soften/IKTwoBoneJob" {
    var options = bentIkOptions(.{ 1, 0, 0 });
    options.soften = 0.5;
    try std.testing.expect((try animation.twoBoneIk(options)).reached);
    options.target = .{ 1.2, 0, 0 };
    try std.testing.expect(!(try animation.twoBoneIk(options)).reached);
    options.target = .{ 3, 0, 0 };
    options.soften = 1;
    try std.testing.expect(!(try animation.twoBoneIk(options)).reached);
}

test "Twist/IKTwoBoneJob" {
    var twist_options = bentIkOptions(.{ 1, 1, 0 });
    twist_options.twist_angle = @as(f32, std.math.pi) / 2;
    const twisted = try animation.twoBoneIk(twist_options);
    try h.expectQuaternion(
        math.quat.fromAxisAngle(
            math.vec.normalize(@as(math.Vec3f32, .{ 1, 1, 0 })),
            @as(f32, std.math.pi) / 2,
        ),
        twisted.start_correction,
    );
    try h.expectQuaternion(math.quat.identity, twisted.mid_correction);
}

test "ZeroScale/IKTwoBoneJob" {
    const zero = math.Float4x4.fromTransform(.{ .scale = @splat(0) });
    const degenerate = try animation.twoBoneIk(.{
        .target = .{ 1, 0, 0 },
        .start_joint = zero,
        .mid_joint = zero,
        .end_joint = zero,
    });
    try h.expectQuaternion(math.quat.identity, degenerate.start_correction);
    try h.expectQuaternion(math.quat.identity, degenerate.mid_correction);
    try std.testing.expect(!degenerate.reached);
}

test "Pole/IKTwoBoneJob" {
    const pi: f32 = @floatCast(std.math.pi);
    const cases = [_]struct {
        pole: math.Vec3f32,
        target: math.Vec3f32,
        expected: math.Quat4f32,
    }{
        .{ .pole = .{ 0, 1, 0 }, .target = .{ 1, 1, 0 }, .expected = math.quat.identity },
        .{ .pole = .{ 0, 0, 1 }, .target = .{ 1, 0, 1 }, .expected = math.quat.fromAxisAngle(.{ 1, 0, 0 }, pi / 2) },
        .{ .pole = .{ 0, 0, -1 }, .target = .{ 1, 0, -1 }, .expected = math.quat.fromAxisAngle(.{ 1, 0, 0 }, -pi / 2) },
        .{ .pole = .{ 1, 0, 0 }, .target = .{ 1, -1, 0 }, .expected = math.quat.fromAxisAngle(.{ 0, 0, 1 }, -pi / 2) },
        .{ .pole = .{ -1, 0, 0 }, .target = .{ -1, 1, 0 }, .expected = math.quat.fromAxisAngle(.{ 0, 0, 1 }, pi / 2) },
    };
    for (cases) |case| {
        var options = bentIkOptions(case.target);
        options.pole_vector = case.pole;
        const result = try animation.twoBoneIk(options);
        try std.testing.expect(result.reached);
        try h.expectQuaternion(case.expected, result.start_correction);
        try h.expectQuaternion(math.quat.identity, result.mid_correction);
    }
}

test "PoleTargetAlignment/IKTwoBoneJob" {
    const sqrt_two = @sqrt(@as(f32, 2));
    var options = bentIkOptions(.{ 0, sqrt_two, 0 });
    const aligned = try animation.twoBoneIk(options);
    try std.testing.expect(aligned.reached);
    try h.expectQuaternion(math.quat.identity, aligned.mid_correction);

    options.target = .{ 0.001, sqrt_two, 0 };
    const offset = try animation.twoBoneIk(options);
    try std.testing.expect(offset.reached);
    try h.expectQuaternion(
        math.quat.fromAxisAngle(.{ 0, 0, 1 }, @as(f32, std.math.pi) / 4),
        offset.start_correction,
    );
    try h.expectQuaternion(math.quat.identity, offset.mid_correction);

    options.target = .{ 0, 3, 0 };
    const extended = try animation.twoBoneIk(options);
    try std.testing.expect(!extended.reached);
    try h.expectQuaternion(
        math.quat.fromAxisAngle(.{ 0, 0, 1 }, @as(f32, std.math.pi) / 2),
        extended.mid_correction,
    );
}

test "AlignedJointsAndTarget/IKTwoBoneJob" {
    const options: animation.TwoBoneOptions = .{
        .target = .{ 2, 0, 0 },
        .start_joint = .identity,
        .mid_joint = math.Float4x4.fromTransform(.{ .translation = .{ 1, 0, 0 } }),
        .end_joint = math.Float4x4.fromTransform(.{ .translation = .{ 2, 0, 0 } }),
    };
    const reachable = try animation.twoBoneIk(options);
    try std.testing.expect(reachable.reached);
    try h.expectQuaternion(math.quat.identity, reachable.start_correction);
    try h.expectQuaternion(math.quat.identity, reachable.mid_correction);

    var unreachable_options = options;
    unreachable_options.target = .{ 3, 0, 0 };
    const beyond_reach = try animation.twoBoneIk(unreachable_options);
    try std.testing.expect(!beyond_reach.reached);
    try h.expectQuaternion(math.quat.identity, beyond_reach.start_correction);
    try h.expectQuaternion(math.quat.identity, beyond_reach.mid_correction);
}

test "SoftenBoundariesAndWeightClamp/IKTwoBoneJob" {
    const cases = [_]struct {
        distance: f32,
        soften: f32,
        reached: bool,
    }{
        .{ .distance = 2, .soften = 1, .reached = true },
        .{ .distance = 1, .soften = 0.5, .reached = true },
        .{ .distance = 0.8, .soften = 0.5, .reached = true },
        .{ .distance = 1.2, .soften = 0.5, .reached = false },
        .{ .distance = 1.2, .soften = 0, .reached = false },
        .{ .distance = 2, .soften = 0.5, .reached = false },
        .{ .distance = 3, .soften = 1, .reached = false },
    };
    for (cases) |case| {
        var options = bentIkOptions(.{ case.distance, 0, 0 });
        options.soften = case.soften;
        try std.testing.expectEqual(case.reached, (try animation.twoBoneIk(options)).reached);
    }

    var options = bentIkOptions(.{ 2, 0, 0 });
    options.weight = 1.1;
    const above_one = try animation.twoBoneIk(options);
    try std.testing.expect(above_one.reached);
    options.weight = -0.1;
    const below_zero = try animation.twoBoneIk(options);
    try std.testing.expect(!below_zero.reached);
    try h.expectQuaternion(math.quat.identity, below_zero.start_correction);
    try h.expectQuaternion(math.quat.identity, below_zero.mid_correction);
    options.weight = 0.5;
    try std.testing.expect(!(try animation.twoBoneIk(options)).reached);
}

test "ParentScaleAndAlignedMid/IKTwoBoneJob" {
    const parents = [_]math.Transform{
        .{},
        .{ .translation = .{ 0, 1, 0 } },
        .{ .rotation = math.quat.fromAxisAngle(.{ 1, 0, 0 }, @as(f32, std.math.pi) / 3) },
        .{ .scale = .{ 2, 2, 2 } },
        .{ .scale = .{ 1, 2, 1 } },
        .{ .scale = .{ -3, -3, -3 } },
    };
    const base_mid = math.Float4x4.fromTransform(.{ .translation = .{ 0, 1, 0 } });
    const base_end = math.Float4x4.fromTransform(.{ .translation = .{ 1, 1, 0 } });
    for (parents) |parent_transform| {
        const parent = math.Float4x4.fromTransform(parent_transform);
        const result = try animation.twoBoneIk(.{
            .target = math.Float4x4.transformPoint(parent, .{ 1, 1, 0 }),
            .start_joint = parent,
            .mid_joint = math.Float4x4.mul(parent, base_mid),
            .end_joint = math.Float4x4.mul(parent, base_end),
            .pole_vector = math.Float4x4.transformVector(parent, .{ 0, 1, 0 }),
        });
        try std.testing.expect(result.reached);
        try h.expectQuaternion(math.quat.identity, result.start_correction);
        try h.expectQuaternion(math.quat.identity, result.mid_correction);
    }

    const aligned = try animation.twoBoneIk(.{
        .target = .{ 1, 1, 0 },
        .start_joint = .identity,
        .mid_joint = base_mid,
        .end_joint = math.Float4x4.fromTransform(.{ .translation = .{ 0, 2, 0 } }),
    });
    try std.testing.expect(aligned.reached);
    try h.expectQuaternion(math.quat.identity, aligned.start_correction);
    try h.expectQuaternion(
        math.quat.fromAxisAngle(.{ 0, 0, 1 }, -@as(f32, std.math.pi) / 2),
        aligned.mid_correction,
    );
}

test "ZeroScale/IKAimJob" {
    const result = try animation.aimIk(.{
        .target = .{ 1, 0, 0 },
        .joint = math.Float4x4.fromTransform(.{ .scale = @splat(0) }),
    });
    try h.expectQuaternion(math.quat.identity, result.correction);
    try std.testing.expect(!result.reached);
}

test "JointRestPose/SkeletonUtils" {
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &.{
        .{
            .name = "root",
            .parent = animation.no_parent,
            .rest_pose = .{ .translation = .{ 4, 5, 6 } },
        },
    });
    defer skeleton.deinit();
    try h.expectFloat3(.{ 4, 5, 6 }, skeleton.jointRestPose(0).translation);
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

test "ThresholdInclusion/TrackEdgeTriggerJob" {
    var step = try animation.FloatTrack.initMixed(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = -1, .interpolation = .step },
        .{ .ratio = 0.5, .value = 1, .interpolation = .step },
        .{ .ratio = 1, .value = -1, .interpolation = .step },
    });
    defer step.deinit();

    // The lower value is included in the edge predicate, while the upper
    // value is excluded. This matches the upstream [min, max) convention.
    const expected_step = [_]animation.TrackEdge{
        .{ .ratio = 0.5, .rising = true },
        .{ .ratio = 1, .rising = false },
    };
    try expectEdges(&step, 0, 1, -1, &expected_step);
    try expectEdges(&step, 0, 1, 0, &expected_step);
    try expectEdges(&step, 0, 1, 0.5, &expected_step);
    try expectEdges(&step, 0, 1, 1, &.{});
    try expectEdges(&step, 0, 1, 2, &.{});
    try expectEdges(&step, 0, 1, -2, &.{});

    var linear = try animation.FloatTrack.init(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = -1 },
        .{ .ratio = 0.5, .value = 1 },
        .{ .ratio = 1, .value = -1 },
    }, .linear);
    defer linear.deinit();
    try expectEdges(&linear, 0, 1, -1, &.{
        .{ .ratio = 0, .rising = true },
        .{ .ratio = 1, .rising = false },
    });
    try expectEdges(&linear, 0, 1, 0, &.{
        .{ .ratio = 0.25, .rising = true },
        .{ .ratio = 0.75, .rising = false },
    });
    try expectEdges(&linear, 0, 1, 0.5, &.{
        .{ .ratio = 0.375, .rising = true },
        .{ .ratio = 0.625, .rising = false },
    });
    try expectEdges(&linear, 0, 1, 1, &.{});
    try expectEdges(&linear, 0, 1, 2, &.{});
    try expectEdges(&linear, 0, 1, -2, &.{});
}

test "ConstantAndWrappedEndpoints/TrackEdgeTriggerJob" {
    var constant = try animation.FloatTrack.init(std.testing.allocator, "", &.{
        .{ .ratio = 0.5, .value = 46 },
    }, .linear);
    defer constant.deinit();
    try expectEdges(&constant, 0, 1, 0, &.{});
    try expectEdges(&constant, -46, 47, 46, &.{});

    // A non-looping-looking two-key track still has an edge between its last
    // and first key because triggering evaluates a repeating track.
    var open_step = try animation.FloatTrack.initMixed(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = 0, .interpolation = .step },
        .{ .ratio = 0.6, .value = 2, .interpolation = .step },
    });
    defer open_step.deinit();
    try expectEdges(&open_step, 0, 1, 1, &.{
        .{ .ratio = 0, .rising = false },
        .{ .ratio = 0.6, .rising = true },
    });
    try expectEdges(&open_step, 1, 0, 1, &.{
        .{ .ratio = 0.6, .rising = false },
        .{ .ratio = 0, .rising = true },
    });
}

test "IteratorRangeBoundaries/TrackEdgeTriggerJob" {
    var track = try animation.FloatTrack.initMixed(std.testing.allocator, "", &.{
        .{ .ratio = 0, .value = 0, .interpolation = .step },
        .{ .ratio = 0.2, .value = 2, .interpolation = .step },
        .{ .ratio = 0.3, .value = 0, .interpolation = .step },
        .{ .ratio = 0.4, .value = 1, .interpolation = .step },
        .{ .ratio = 0.5, .value = 0, .interpolation = .step },
    });
    defer track.deinit();

    const after_first = std.math.nextAfter(f32, 0.2, 1);
    const before_last = std.math.nextAfter(f32, 0.5, 0);
    const after_last = std.math.nextAfter(f32, 0.5, 1);
    try expectEdges(&track, 0, 0.2, 0, &.{});
    try expectEdges(&track, 0, after_first, 0, &.{
        .{ .ratio = 0.2, .rising = true },
    });
    try expectEdges(&track, after_first, 1, 0, &.{
        .{ .ratio = 0.3, .rising = false },
        .{ .ratio = 0.4, .rising = true },
        .{ .ratio = 0.5, .rising = false },
    });
    try expectEdges(&track, 0, before_last, 0, &.{
        .{ .ratio = 0.2, .rising = true },
        .{ .ratio = 0.3, .rising = false },
        .{ .ratio = 0.4, .rising = true },
    });
    try expectEdges(&track, 0, after_last, 0, &.{
        .{ .ratio = 0.2, .rising = true },
        .{ .ratio = 0.3, .rising = false },
        .{ .ratio = 0.4, .rising = true },
        .{ .ratio = 0.5, .rising = false },
    });

    // Reverse traversal yields the same edges in reverse order with polarity
    // inverted, including far positive and negative loop indices.
    try expectEdges(&track, std.math.nextAfter(f32, 46.5, 100), 46, 0, &.{
        .{ .ratio = 46.5, .rising = true },
        .{ .ratio = 46.4, .rising = false },
        .{ .ratio = 46.3, .rising = true },
        .{ .ratio = 46.2, .rising = false },
    });
    try expectEdges(&track, -46, std.math.nextAfter(f32, -45.5, 100), 0, &.{
        .{ .ratio = -45.8, .rising = true },
        .{ .ratio = -45.7, .rising = false },
        .{ .ratio = -45.6, .rising = true },
        .{ .ratio = -45.5, .rising = false },
    });
}
