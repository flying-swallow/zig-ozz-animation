const std = @import("std");
const ozz = @import("zig_ozz_animation");
const geometry = ozz.geometry;
const math = ozz.math;
const h = @import("helpers.zig");

test "JobValidity/SkinningJob" {
    var output: [1]math.Float3 = undefined;
    try std.testing.expectError(geometry.SkinningError.InvalidInfluenceCount, geometry.skin(.{
        .joint_matrices = &.{math.Float4x4.identity},
        .joint_indices = &.{},
        .joint_weights = &.{},
        .input_positions = &.{.zero},
        .output_positions = &output,
        .influences_count = 0,
    }));
}

test "Run/SkinningJob" {
    const matrices = [_]math.Float4x4{
        math.Float4x4.fromTransform(.{ .translation = .{ .x = 1 } }),
        math.Float4x4.fromTransform(.{ .translation = .{ .y = 2 } }),
        math.Float4x4.fromTransform(.{ .translation = .{ .z = 3 } }),
    };
    var positions: [1]math.Float3 = undefined;
    var normals: [1]math.Float3 = undefined;
    var tangents: [1]math.Float3 = undefined;
    try geometry.skin(.{
        .joint_matrices = &matrices,
        .joint_indices = &.{ 0, 1, 2 },
        .joint_weights = &.{ 0.2, 0.3 },
        .input_positions = &.{.{ .x = 1, .y = 1, .z = 1 }},
        .input_normals = &.{math.Float3.y_axis},
        .input_tangents = &.{math.Float3.x_axis},
        .output_positions = &positions,
        .output_normals = &normals,
        .output_tangents = &tangents,
        .influences_count = 3,
    });
    try h.expectFloat3(.{ .x = 1.2, .y = 1.6, .z = 2.5 }, positions[0]);
    try h.expectFloat3(.y_axis, normals[0]);
    try h.expectFloat3(.x_axis, tangents[0]);
}

test "RunInverseTranspose/SkinningJob" {
    const matrix = math.Float4x4.fromTransform(.{ .scale = .{ .x = 2, .y = 3, .z = 4 } });
    const inverse_transpose: math.Float4x4 = .{ .cols = .{
        .{ 0.5, 0, 0, 0 },
        .{ 0, 1.0 / 3.0, 0, 0 },
        .{ 0, 0, 0.25, 0 },
        .{ 0, 0, 0, 1 },
    } };
    var positions: [1]math.Float3 = undefined;
    var normals: [1]math.Float3 = undefined;
    try geometry.skin(.{
        .joint_matrices = &.{matrix},
        .joint_inverse_transpose_matrices = &.{inverse_transpose},
        .joint_indices = &.{0},
        .joint_weights = &.{},
        .input_positions = &.{.one},
        .input_normals = &.{.x_axis},
        .output_positions = &positions,
        .output_normals = &normals,
        .influences_count = 1,
    });
    try h.expectFloat3(.{ .x = 2, .y = 3, .z = 4 }, positions[0]);
    try h.expectFloat3(.{ .x = 0.5 }, normals[0]);
}

test "RunStrided/SkinningJob" {
    const PaddedFloat3 = extern struct {
        value: math.Float3,
        padding: f32 = 93,
    };
    const Indices = extern struct {
        value: [2]u16,
        padding: u32 = 46,
    };
    const Weights = extern struct {
        value: f32,
        padding: f32 = 58,
    };
    const matrices = [_]math.Float4x4{
        math.Float4x4.identity,
        math.Float4x4.fromTransform(.{ .translation = .{ .x = 2 } }),
    };
    var inputs = [_]PaddedFloat3{
        .{ .value = .{ .x = 1 } },
        .{ .value = .{ .x = 3 } },
    };
    var indices = [_]Indices{
        .{ .value = .{ 0, 1 } },
        .{ .value = .{ 1, 0 } },
    };
    var weights = [_]Weights{
        .{ .value = 0.25 },
        .{ .value = 0.5 },
    };
    var outputs: [2]PaddedFloat3 = undefined;
    try geometry.skinStrided(.{
        .vertex_count = 2,
        .influences_count = 2,
        .joint_matrices = &matrices,
        .joint_indices = std.mem.sliceAsBytes(&indices),
        .joint_indices_stride = @sizeOf(Indices),
        .joint_weights = std.mem.sliceAsBytes(&weights),
        .joint_weights_stride = @sizeOf(Weights),
        .input_positions = std.mem.sliceAsBytes(&inputs),
        .input_positions_stride = @sizeOf(PaddedFloat3),
        .output_positions = std.mem.sliceAsBytes(&outputs),
        .output_positions_stride = @sizeOf(PaddedFloat3),
    });
    try h.expectFloat3(.{ .x = 2.5 }, outputs[0].value);
    try h.expectFloat3(.{ .x = 4 }, outputs[1].value);
}
