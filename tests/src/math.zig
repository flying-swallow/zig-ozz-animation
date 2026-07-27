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
