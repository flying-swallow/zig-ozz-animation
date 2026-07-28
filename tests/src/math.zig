const std = @import("std");
const ozz = @import("zig_ozz_animation");
const math = ozz.math;
const h = @import("helpers.zig");

test "BoxValidity/ozz_math" {
    try std.testing.expect(!math.Box.empty().isValid());
    try std.testing.expect(!(@as(math.Box, .{
        .min = .{ .x = 0, .y = 1, .z = 2 },
        .max = .{ .x = 0, .y = -1, .z = 2 },
    })).isValid());
    try std.testing.expect((@as(math.Box, .{
        .min = .{ .x = 0, .y = -1, .z = 2 },
        .max = .{ .x = 0, .y = 1, .z = 2 },
    })).isValid());
}

test "BoxInside/ozz_math" {
    const box: math.Box = .{
        .min = .{ .x = -1, .y = -2, .z = -3 },
        .max = .{ .x = 1, .y = 2, .z = 3 },
    };
    try std.testing.expect(box.contains(.{ .x = -1, .y = -2, .z = -3 }));
    try std.testing.expect(box.contains(.zero));
    try std.testing.expect(!box.contains(.{ .y = 3 }));
}

test "BoxMerge/ozz_math" {
    const a: math.Box = .{
        .min = .{ .x = -1, .y = -2, .z = -3 },
        .max = .{ .x = 1, .y = 2, .z = 3 },
    };
    const b: math.Box = .{
        .min = .{ .x = 0, .y = 5, .z = -8 },
        .max = .{ .x = 1, .y = 6, .z = 0 },
    };
    const merged = math.Box.merge(a, b);
    try h.expectFloat3(.{ .x = -1, .y = -2, .z = -8 }, merged.min);
    try h.expectFloat3(.{ .x = 1, .y = 6, .z = 3 }, merged.max);
    try std.testing.expect(math.Box.merge(math.Box.empty(), a).isValid());
}

test "BoxTransform/ozz_math" {
    const box: math.Box = .{
        .min = .{ .x = 1, .y = 2, .z = 3 },
        .max = .{ .x = 4, .y = 5, .z = 6 },
    };
    const translated = box.transformed(math.Float4x4.fromTransform(.{
        .translation = .{ .x = 2, .y = -2, .z = 3 },
    }));
    try h.expectFloat3(.{ .x = 3, .y = 0, .z = 6 }, translated.min);
    try h.expectFloat3(.{ .x = 6, .y = 3, .z = 9 }, translated.max);
}

test "BoxBuild/ozz_math" {
    var box = math.Box.empty();
    for ([_]math.Float3{
        .zero,
        .{ .x = 1, .y = -1 },
        .{ .z = 46 },
        .{ .x = -27 },
        .{ .y = 58 },
    }) |point| box.expand(point);
    try h.expectFloat3(.{ .x = -27, .y = -1, .z = 0 }, box.min);
    try h.expectFloat3(.{ .x = 1, .y = 58, .z = 46 }, box.max);
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
    try h.expectFloat3(.{ .x = 5, .y = 7, .z = 9 }, math.Float3.add(
        .{ .x = 1, .y = 2, .z = 3 },
        .{ .x = 4, .y = 5, .z = 6 },
    ));
    try h.expectFloat(32, math.Float3.dot(
        .{ .x = 1, .y = 2, .z = 3 },
        .{ .x = 4, .y = 5, .z = 6 },
    ));
    try h.expectFloat3(.{ .x = 0, .y = 0, .z = 1 }, math.Float3.cross(.x_axis, .y_axis));
}

test "VectorArithmeticAndNormalization/ozz_math" {
    const a2: math.Float2 = .{ .x = 0.5, .y = 1 };
    const b2: math.Float2 = .{ .x = 4, .y = 5 };
    try std.testing.expect(math.Float2.approxEq(.{ .x = 0.125, .y = 0.2 }, math.Float2.div(a2, b2), 1e-6));
    try std.testing.expect(math.Float2.isNormalized(math.Float2.normalize(a2)));
    try std.testing.expect(math.Float2.approxEq(.{ .x = 1 }, math.Float2.normalizeSafe(.zero, .{ .x = 1 }), 1e-6));

    const a3: math.Float3 = .{ .x = 0.5, .y = 1, .z = 2 };
    const b3: math.Float3 = .{ .x = 4, .y = 5, .z = -6 };
    try h.expectFloat3(.{ .x = -4, .y = -5, .z = 6 }, math.Float3.negate(b3));
    try h.expectFloat(@sqrt(@as(f32, 5.25)), math.Float3.length(a3));
    try std.testing.expect(math.Float3.isNormalized(math.Float3.normalize(a3)));
    try h.expectFloat3(.x_axis, math.Float3.normalizeSafe(.zero, .x_axis));

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
        .{ .x = 0.5, .y = -1, .z = -6 },
        math.Float3.min(.{ .x = 0.5, .y = -1, .z = 2 }, .{ .x = 4, .y = 5, .z = -6 }),
    );
    try h.expectFloat3(
        .{ .x = 4, .y = 5, .z = 2 },
        math.Float3.max(.{ .x = 0.5, .y = -1, .z = 2 }, .{ .x = 4, .y = 5, .z = -6 }),
    );
    try h.expectFloat3(
        .{ .x = 0.5, .y = 2, .z = 6 },
        math.Float3.clamp(
            .{ .x = -12, .y = 2, .z = 9 },
            .{ .x = 0.5, .y = -1, .z = 2 },
            .{ .x = 4, .y = 5, .z = 6 },
        ),
    );
    try std.testing.expect(math.Float3.approxEq(
        .{ .x = 4, .y = 5, .z = 6 },
        .{ .x = 4, .y = 5, .z = 6.1 },
        0.2,
    ));
    try std.testing.expect(!math.Float3.approxEq(
        .{ .x = 4, .y = 5, .z = 6 },
        .{ .x = 4, .y = 5, .z = 6.1 },
        0.05,
    ));
}

test "QuaternionQuaternionEuler/ozz_math" {
    const input: math.Float3 = .{ .x = 0.31, .y = -0.47, .z = 0.83 };
    const q = math.Quaternion.fromEuler(input);
    const output = math.Quaternion.toEuler(q);
    try h.expectFloat3(input, output);
}

test "QuaternionArithmetic/ozz_math" {
    const q = math.Quaternion.fromAxisAngle(.z_axis, @as(f32, std.math.pi) / 2);
    try h.expectFloat3(.y_axis, math.Quaternion.rotate(q, .x_axis));
    try h.expectQuaternion(.identity, math.Quaternion.mul(q, math.Quaternion.conjugate(q)));
}

test "QuaternionConstructionAndInterpolation/ozz_math" {
    const half_pi: f32 = @as(f32, std.math.pi) / 2;
    const axis_angle = math.Quaternion.fromAxisAngle(.y_axis, half_pi);
    try h.expectQuaternion(axis_angle, math.Quaternion.fromAxisCosAngle(.y_axis, @cos(half_pi)));

    try h.expectQuaternion(.identity, math.Quaternion.fromTo(.zero, .x_axis));
    try h.expectFloat3(.x_axis, math.Quaternion.rotate(math.Quaternion.fromTo(.z_axis, .x_axis), .z_axis));
    try h.expectFloat3(math.Float3.negate(.x_axis), math.Quaternion.rotate(math.Quaternion.fromTo(.x_axis, math.Float3.negate(.x_axis)), .x_axis));

    const a = math.Quaternion.fromAxisAngle(.x_axis, half_pi);
    const b = math.Quaternion.fromAxisAngle(.y_axis, half_pi);
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
    try h.expectFloat3(.y_axis, math.Quaternion.rotate(math.Quaternion.fromEuler(.{ .z = half_pi }), .x_axis));
    try h.expectFloat3(.{ .x = 1, .z = -1 }, math.Quaternion.rotate(
        math.Quaternion.fromEuler(.{ .y = half_pi }),
        .{ .x = 1, .z = 1 },
    ));
    try h.expectFloat3(.{ .y = -1, .z = 1 }, math.Quaternion.rotate(
        math.Quaternion.fromEuler(.{ .x = half_pi }),
        .{ .y = 1, .z = 1 },
    ));
}

test "TransformCompositionAndInterpolation/ozz_math" {
    const half_pi: f32 = @as(f32, std.math.pi) / 2;
    const parent: math.Transform = .{
        .translation = .{ .x = 1, .y = 2, .z = 3 },
        .rotation = math.Quaternion.fromAxisAngle(.z_axis, half_pi),
        .scale = .{ .x = 2, .y = 3, .z = 4 },
    };
    const local: math.Transform = .{
        .translation = .{ .x = 1 },
        .rotation = math.Quaternion.fromAxisAngle(.x_axis, half_pi),
        .scale = .{ .x = 5, .y = 6, .z = 7 },
    };
    const combined = math.Transform.combine(parent, local);
    try h.expectFloat3(.{ .x = 1, .y = 4, .z = 3 }, combined.translation);
    try h.expectFloat3(.{ .x = 10, .y = 18, .z = 28 }, combined.scale);
    try std.testing.expect(math.Quaternion.isNormalized(combined.rotation));

    const midpoint = math.Transform.lerp(.identity, parent, 0.5);
    try h.expectFloat3(.{ .x = 0.5, .y = 1, .z = 1.5 }, midpoint.translation);
    try h.expectFloat3(.{ .x = 1.5, .y = 2, .z = 2.5 }, midpoint.scale);
    try std.testing.expect(math.Quaternion.isNormalized(midpoint.rotation));
}

test "Float4x4Arithmetic/ozz_simd_math" {
    const a = math.Float4x4.fromTransform(.{ .translation = .{ .x = 1, .y = 2, .z = 3 } });
    const b = math.Float4x4.fromTransform(.{ .translation = .{ .x = 4, .y = 5, .z = 6 } });
    try h.expectFloat3(.{ .x = 5, .y = 7, .z = 9 }, math.Float4x4.translation(math.Float4x4.mul(a, b)));
    const inverse = math.Float4x4.inverse(a).?;
    try h.expectFloat3(.zero, math.Float4x4.translation(math.Float4x4.mul(a, inverse)));
}

test "TransformConstant/ozz_math" {
    try h.expectTransform(.identity, math.Transform.identity);
}

test "SoaTransformConstant/ozz_soa_math" {
    for (0..4) |lane| try h.expectTransform(.identity, math.soaLane(math.SoaTransform.identity, lane));
}
