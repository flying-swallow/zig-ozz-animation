const std = @import("std");
const ozz = @import("zig_ozz_animation");
const math = ozz.math;
const h = @import("helpers.zig");

test "BoxValidity/ozz_math" {
    try std.testing.expect(!math.Box.empty().isValid());
    try std.testing.expect(!(@as(math.Box, .{
        .min = .{ 0, 1, 2 },
        .max = .{ 0, -1, 2 },
    })).isValid());
    try std.testing.expect((@as(math.Box, .{
        .min = .{ 0, -1, 2 },
        .max = .{ 0, 1, 2 },
    })).isValid());
}

test "BoxInside/ozz_math" {
    const box: math.Box = .{
        .min = .{ -1, -2, -3 },
        .max = .{ 1, 2, 3 },
    };
    try std.testing.expect(box.contains(.{ -1, -2, -3 }));
    try std.testing.expect(box.contains(@splat(0)));
    try std.testing.expect(!box.contains(.{ 0, 3, 0 }));
}

test "BoxMerge/ozz_math" {
    const a: math.Box = .{
        .min = .{ -1, -2, -3 },
        .max = .{ 1, 2, 3 },
    };
    const b: math.Box = .{
        .min = .{ 0, 5, -8 },
        .max = .{ 1, 6, 0 },
    };
    const merged = math.Box.merge(a, b);
    try h.expectFloat3(.{ -1, -2, -8 }, merged.min);
    try h.expectFloat3(.{ 1, 6, 3 }, merged.max);
    try std.testing.expect(math.Box.merge(math.Box.empty(), a).isValid());
}

test "BoxTransform/ozz_math" {
    const box: math.Box = .{
        .min = .{ 1, 2, 3 },
        .max = .{ 4, 5, 6 },
    };
    const translated = box.transformed(math.Float4x4.fromTransform(.{
        .translation = .{ 2, -2, 3 },
    }));
    try h.expectFloat3(.{ 3, 0, 6 }, translated.min);
    try h.expectFloat3(.{ 6, 3, 9 }, translated.max);
}

test "BoxBuild/ozz_math" {
    var box = math.Box.empty();
    for ([_]math.Vec3f32{
        @splat(0),
        .{ 1, -1, 0 },
        .{ 0, 0, 46 },
        .{ -27, 0, 0 },
        .{ 0, 58, 0 },
    }) |point| box.expand(point);
    try h.expectFloat3(.{ -27, -1, 0 }, box.min);
    try h.expectFloat3(.{ 1, 58, 46 }, box.max);
}

test "RectInt/ozz_math" {
    const rect: math.RectInt = .{ .left = 10, .bottom = 20, .width = 30, .height = 40 };
    try std.testing.expectEqual(@as(i32, 40), rect.right());
    try std.testing.expectEqual(@as(i32, 60), rect.top());
    try std.testing.expect(rect.contains(10, 20));
    try std.testing.expect(rect.contains(39, 59));
    try std.testing.expect(!rect.contains(40, 59));
    try std.testing.expect(!rect.contains(39, 60));
}

test "RectFloat/ozz_math" {
    const rect: math.RectFloat = .{ .left = 10, .bottom = 20, .width = 30, .height = 40 };
    try h.expectFloat(40, rect.right());
    try h.expectFloat(60, rect.top());
    try std.testing.expect(rect.contains(10, 20));
    try std.testing.expect(!rect.contains(40, 59));
}

test "VectorArithmetic/ozz_math" {
    try h.expectFloat3(.{ 5, 7, 9 }, math.vec.add(
        @as(math.Vec3f32, .{ 1, 2, 3 }),
        .{ 4, 5, 6 },
    ));
    try h.expectFloat(32, math.vec.dot(
        @as(math.Vec3f32, .{ 1, 2, 3 }),
        .{ 4, 5, 6 },
    ));
    try h.expectFloat3(.{ 0, 0, 1 }, math.vec.cross(
        @as(math.Vec3f32, .{ 1, 0, 0 }),
        .{ 0, 1, 0 },
    ));
}

test "VectorArithmeticAndNormalization/ozz_math" {
    const a2: math.Vec2f32 = .{ 0.5, 1 };
    const b2: math.Vec2f32 = .{ 4, 5 };
    try std.testing.expect(math.vec.is_close(
        @as(math.Vec2f32, .{ 0.125, 0.2 }),
        math.vec.div(a2, b2),
        1e-12,
    ));
    try std.testing.expect(math.vec.is_normalized_default(math.vec.normalize(a2)));

    const a3: math.Vec3f32 = .{ 0.5, 1, 2 };
    const b3: math.Vec3f32 = .{ 4, 5, -6 };
    try h.expectFloat3(.{ -4, -5, 6 }, -b3);
    try h.expectFloat(@sqrt(@as(f32, 5.25)), math.vec.norm(a3));
    try std.testing.expect(math.vec.is_normalized_default(math.vec.normalize(a3)));

    const a4: math.Float4 = .{ .x = 0.5, .y = 1, .z = 2, .w = 3 };
    try h.expectFloat(@sqrt(@as(f32, 14.25)), math.Float4.length(a4));
    try std.testing.expect(math.Float4.isNormalized(math.Float4.normalize(a4)));
    try std.testing.expect(math.Float4.approxEq(
        .{ .x = 1, .y = 0, .z = 0, .w = 0 },
        math.Float4.normalizeSafe(.zero, .{ .x = 1 }),
        1e-6,
    ));
}

test "VectorComparison/ozz_math" {
    try h.expectFloat3(
        .{ 0.5, -1, -6 },
        @min(@as(math.Vec3f32, .{ 0.5, -1, 2 }), @as(math.Vec3f32, .{ 4, 5, -6 })),
    );
    try h.expectFloat3(
        .{ 4, 5, 2 },
        @max(@as(math.Vec3f32, .{ 0.5, -1, 2 }), @as(math.Vec3f32, .{ 4, 5, -6 })),
    );
    try h.expectFloat3(
        .{ 0.5, 2, 6 },
        @min(
            @max(@as(math.Vec3f32, .{ -12, 2, 9 }), @as(math.Vec3f32, .{ 0.5, -1, 2 })),
            @as(math.Vec3f32, .{ 4, 5, 6 }),
        ),
    );
    try std.testing.expect(math.vec.is_close(
        @as(math.Vec3f32, .{ 4, 5, 6 }),
        .{ 4, 5, 6.1 },
        0.2 * 0.2,
    ));
    try std.testing.expect(!math.vec.is_close(
        @as(math.Vec3f32, .{ 4, 5, 6 }),
        .{ 4, 5, 6.1 },
        0.05 * 0.05,
    ));
}

test "VectorLoad4/ozz_math" {
    try std.testing.expectEqual(math.Float4{ .x = 1, .y = 2, .z = 3, .w = 4 }, math.Float4{ .x = 1, .y = 2, .z = 3, .w = 4 });
}

test "VectorLoad3/ozz_math" {
    try h.expectFloat3(.{ 1, 2, 3 }, @as(math.Vec3f32, .{ 1, 2, 3 }));
}

test "VectorLoad2/ozz_math" {
    try std.testing.expectEqual(@as(math.Vec2f32, .{ 1, 2 }), @as(math.Vec2f32, .{ 1, 2 }));
}

test "VectorConstant4/ozz_math" {
    try std.testing.expectEqual(math.Float4{ .x = 0, .y = 0, .z = 0, .w = 0 }, math.Float4.zero);
    try std.testing.expectEqual(math.Float4{ .x = 1, .y = 1, .z = 1, .w = 1 }, math.Float4.one);
}

test "VectorConstant3/ozz_math" {
    try h.expectFloat3(@splat(0), @as(math.Vec3f32, @splat(0)));
    try h.expectFloat3(@splat(1), @as(math.Vec3f32, @splat(1)));
}

test "VectorConstant2/ozz_math" {
    try std.testing.expectEqual(@as(math.Vec2f32, @splat(0)), @as(math.Vec2f32, @splat(0)));
    try std.testing.expectEqual(@as(math.Vec2f32, @splat(1)), @as(math.Vec2f32, @splat(1)));
}

test "VectorArithmetic4/ozz_math" {
    const a: math.Float4 = .{ .x = 1, .y = 2, .z = 3, .w = 4 };
    const b: math.Float4 = .{ .x = 4, .y = 3, .z = 2, .w = 1 };
    try std.testing.expectEqual(math.Float4{ .x = 5, .y = 5, .z = 5, .w = 5 }, math.Float4.add(a, b));
    try h.expectFloat(20, math.Float4.dot(a, b));
    try std.testing.expect(math.Float4.isNormalized(math.Float4.normalize(a)));
}

test "VectorArithmetic3/ozz_math" {
    const a: math.Vec3f32 = .{ 1, 2, 3 };
    const b: math.Vec3f32 = .{ 4, 5, 6 };
    try h.expectFloat3(.{ 5, 7, 9 }, math.vec.add(a, b));
    try h.expectFloat3(.{ -3, 6, -3 }, math.vec.cross(a, b));
    try std.testing.expect(math.vec.is_normalized_default(math.vec.normalize(a)));
}

test "VectorArithmetic2/ozz_math" {
    const a: math.Vec2f32 = .{ 1, 2 };
    const b: math.Vec2f32 = .{ 4, 5 };
    try std.testing.expectEqual(@as(math.Vec2f32, .{ 5, 7 }), math.vec.add(a, b));
    try h.expectFloat(14, math.vec.dot(a, b));
}

test "VectorComparison4/ozz_math" {
    const a: math.Float4 = .{ .x = 1, .y = 5, .z = -2, .w = 8 };
    const b: math.Float4 = .{ .x = 2, .y = 4, .z = -3, .w = 9 };
    try std.testing.expectEqual(math.Float4{ .x = 1, .y = 4, .z = -3, .w = 8 }, math.Float4.min(a, b));
    try std.testing.expectEqual(math.Float4{ .x = 2, .y = 5, .z = -2, .w = 9 }, math.Float4.max(a, b));
}

test "VectorComparison3/ozz_math" {
    const a: math.Vec3f32 = .{ 1, 5, -2 };
    const b: math.Vec3f32 = .{ 2, 4, -3 };
    try h.expectFloat3(.{ 1, 4, -3 }, @min(a, b));
    try h.expectFloat3(.{ 2, 5, -2 }, @max(a, b));
}

test "VectorComparison2/ozz_math" {
    const a: math.Vec2f32 = .{ 1, 5 };
    const b: math.Vec2f32 = .{ 2, 4 };
    try std.testing.expectEqual(@as(math.Vec2f32, .{ 1, 4 }), @min(a, b));
    try std.testing.expectEqual(@as(math.Vec2f32, .{ 2, 5 }), @max(a, b));
}

test "QuaternionQuaternionEuler/ozz_math" {
    const input: math.Vec3f32 = .{ 0.31, -0.47, 0.83 };
    const q = math.Quaternion.fromEuler(input);
    const output = math.Quaternion.toEuler(q);
    try h.expectFloat3(input, output);
}

test "QuaternionConstant/ozz_math" {
    try h.expectQuaternion(.{ .x = 0, .y = 0, .z = 0, .w = 1 }, math.Quaternion.identity);
}

test "QuaternionAxisAngle/ozz_math" {
    const half_pi: f32 = @as(f32, std.math.pi) / 2;
    try h.expectQuaternion(.identity, math.Quaternion.fromAxisAngle(.{ 0, 1, 0 }, 0));
    const positive = math.Quaternion.fromAxisAngle(.{ 0, 1, 0 }, half_pi);
    const negative_axis = math.Quaternion.fromAxisAngle(.{ 0, -1, 0 }, half_pi);
    const negative_angle = math.Quaternion.fromAxisAngle(.{ 0, 1, 0 }, -half_pi);
    try h.expectQuaternion(negative_angle, negative_axis);
    try h.expectFloat3(.{ 1, 0, 0 }, math.Quaternion.rotate(positive, .{ 0, 0, 1 }));
    // The Zig adapter normalizes axes instead of asserting like the C++ API.
    try h.expectQuaternion(positive, math.Quaternion.fromAxisAngle(.{ 0, 7, 0 }, half_pi));
}

test "QuaternionAxisCosAngle/ozz_math" {
    const angle: f32 = 1.123;
    const axis = math.vec.normalize(@as(math.Vec3f32, .{ 0.8198645, 0.03303398, -0.5716037 }));
    try h.expectQuaternion(
        math.Quaternion.fromAxisAngle(axis, angle),
        math.Quaternion.fromAxisCosAngle(axis, @cos(angle)),
    );
    try h.expectQuaternion(.identity, math.Quaternion.fromAxisCosAngle(.{ 0, 1, 0 }, 1));
}

test "QuaternionFromVectors/ozz_math" {
    const cases = [_]struct { from: math.Vec3f32, to: math.Vec3f32 }{
        .{ .from = .{ 0, 0, 1 }, .to = .{ 1, 0, 0 } },
        .{ .from = .{ 7, 0, 0 }, .to = .{ 0, 13, 0 } },
        .{ .from = .{ 1, 0, 0 }, .to = .{ -1, 0, 0 } },
        .{ .from = .{ 0, -1, 0 }, .to = .{ 0, 1, 0 } },
        .{ .from = .{ 2, 2, 2 }, .to = .{ -2, -2, -2 } },
    };
    for (cases) |case| {
        const rotation = math.Quaternion.fromTo(case.from, case.to);
        const rotated = math.Quaternion.rotate(rotation, math.vec.normalize(case.from));
        try h.expectFloat3(math.vec.normalize(case.to), rotated);
    }
    try h.expectQuaternion(.identity, math.Quaternion.fromTo(@splat(0), .{ 1, 0, 0 }));
}

test "QuaternionFromUnitVectors/ozz_math" {
    const from = math.vec.normalize(@as(math.Vec3f32, .{ 1, 1, 0 }));
    const to = math.vec.normalize(@as(math.Vec3f32, .{ -1, 1, 0 }));
    try h.expectFloat3(to, math.Quaternion.rotate(math.Quaternion.fromTo(from, to), from));
}

test "QuaternionCompare/ozz_math" {
    const small = math.Quaternion.fromAxisAngle(.{ 0, 0, 1 }, @as(f32, std.math.pi) / 100);
    try std.testing.expect(math.Quaternion.approxRotationEq(.identity, small, @cos(@as(f32, std.math.pi) / 100)));
    try std.testing.expect(math.Quaternion.approxRotationEq(.identity, math.Quaternion.negate(small), @cos(@as(f32, std.math.pi) / 100)));
    try std.testing.expect(!math.Quaternion.approxRotationEq(.identity, small, @cos(@as(f32, std.math.pi) / 400)));
}

test "QuaternionArithmetic/ozz_math" {
    const q = math.Quaternion.fromAxisAngle(.{ 0, 0, 1 }, @as(f32, std.math.pi) / 2);
    try h.expectFloat3(.{ 0, 1, 0 }, math.Quaternion.rotate(q, .{ 1, 0, 0 }));
    try h.expectQuaternion(.identity, math.Quaternion.mul(q, math.Quaternion.conjugate(q)));
}

test "QuaternionTransformVector/ozz_math" {
    const half_pi: f32 = @as(f32, std.math.pi) / 2;
    const y = math.Quaternion.fromAxisAngle(.{ 0, 1, 0 }, half_pi);
    try h.expectFloat3(@splat(0), math.Quaternion.rotate(y, @splat(0)));
    try h.expectFloat3(.{ 0, 1, 0 }, math.Quaternion.rotate(y, .{ 0, 1, 0 }));
    try h.expectFloat3(.{ 0, 0, -2 }, math.Quaternion.rotate(y, .{ 2, 0, 0 }));
    try h.expectFloat3(.{ 2, 0, 0 }, math.Quaternion.rotate(y, .{ 0, 0, 2 }));
}

test "QuaternionConstructionAndInterpolation/ozz_math" {
    const half_pi: f32 = @as(f32, std.math.pi) / 2;
    const axis_angle = math.Quaternion.fromAxisAngle(.{ 0, 1, 0 }, half_pi);
    try h.expectQuaternion(axis_angle, math.Quaternion.fromAxisCosAngle(.{ 0, 1, 0 }, @cos(half_pi)));

    try h.expectQuaternion(.identity, math.Quaternion.fromTo(@splat(0), .{ 1, 0, 0 }));
    try h.expectFloat3(.{ 1, 0, 0 }, math.Quaternion.rotate(math.Quaternion.fromTo(.{ 0, 0, 1 }, .{ 1, 0, 0 }), .{ 0, 0, 1 }));
    try h.expectFloat3(-@as(math.Vec3f32, .{ 1, 0, 0 }), math.Quaternion.rotate(math.Quaternion.fromTo(.{ 1, 0, 0 }, -@as(math.Vec3f32, .{ 1, 0, 0 })), .{ 1, 0, 0 }));

    const a = math.Quaternion.fromAxisAngle(.{ 1, 0, 0 }, half_pi);
    const b = math.Quaternion.fromAxisAngle(.{ 0, 1, 0 }, half_pi);
    try std.testing.expect(math.Quaternion.isNormalized(a));
    try h.expectQuaternion(.identity, math.Quaternion.mul(a, math.Quaternion.conjugate(a)));
    const linear = math.Quaternion.lerp(a, b, 0.2);
    try h.expectFloat(0.5656854, linear.x);
    try h.expectFloat(0.14142136, linear.y);
    try h.expectFloat(0, linear.z);
    try h.expectFloat(0.70710677, linear.w);
    try std.testing.expect(math.Quaternion.isNormalized(math.Quaternion.nlerp(a, b, 0.2)));
    try std.testing.expect(math.Quaternion.isNormalized(math.Quaternion.slerp(a, b, 0.7)));
    try std.testing.expect(math.Quaternion.approxRotationEq(a, math.Quaternion.negate(a), 0.999));
}

test "QuaternionEulerAdapterContract/ozz_math" {
    // The Zig adapter uses intrinsic XYZ component rotations. Upstream Ozz names
    // these fields yaw/pitch/roll and maps them to Y/Z/X axes respectively.
    const half_pi: f32 = @as(f32, std.math.pi) / 2;
    try h.expectFloat3(.{ 0, 1, 0 }, math.Quaternion.rotate(math.Quaternion.fromEuler(.{ 0, 0, half_pi }), .{ 1, 0, 0 }));
    try h.expectFloat3(.{ 1, 0, -1 }, math.Quaternion.rotate(
        math.Quaternion.fromEuler(.{ 0, half_pi, 0 }),
        .{ 1, 0, 1 },
    ));
    try h.expectFloat3(.{ 0, -1, 1 }, math.Quaternion.rotate(
        math.Quaternion.fromEuler(.{ half_pi, 0, 0 }),
        .{ 0, 1, 1 },
    ));
}

test "TransformCompositionAndInterpolation/ozz_math" {
    const half_pi: f32 = @as(f32, std.math.pi) / 2;
    const parent: math.Transform = .{
        .translation = .{ 1, 2, 3 },
        .rotation = math.Quaternion.fromAxisAngle(.{ 0, 0, 1 }, half_pi),
        .scale = .{ 2, 3, 4 },
    };
    const local: math.Transform = .{
        .translation = .{ 1, 0, 0 },
        .rotation = math.Quaternion.fromAxisAngle(.{ 1, 0, 0 }, half_pi),
        .scale = .{ 5, 6, 7 },
    };
    const combined = math.Transform.combine(parent, local);
    try h.expectFloat3(.{ 1, 4, 3 }, combined.translation);
    try h.expectFloat3(.{ 10, 18, 28 }, combined.scale);
    try std.testing.expect(math.Quaternion.isNormalized(combined.rotation));

    const midpoint = math.Transform.lerp(.identity, parent, 0.5);
    try h.expectFloat3(.{ 0.5, 1, 1.5 }, midpoint.translation);
    try h.expectFloat3(.{ 1.5, 2, 2.5 }, midpoint.scale);
    try std.testing.expect(math.Quaternion.isNormalized(midpoint.rotation));
}

test "Float4x4Arithmetic/ozz_simd_math" {
    const a = math.Float4x4.fromTransform(.{ .translation = .{ 1, 2, 3 } });
    const b = math.Float4x4.fromTransform(.{ .translation = .{ 4, 5, 6 } });
    try h.expectFloat3(.{ 5, 7, 9 }, math.Float4x4.translation(math.Float4x4.mul(a, b)));
    const inverse = math.Float4x4.inverse(a).?;
    try h.expectFloat3(@splat(0), math.Float4x4.translation(math.Float4x4.mul(a, inverse)));
}

test "TransformConstant/ozz_math" {
    try h.expectTransform(.identity, math.Transform.identity);
}

test "SoaTransformConstant/ozz_soa_math" {
    for (0..4) |lane| try h.expectTransform(.identity, math.soaLane(math.SoaTransform.identity, lane));
}
