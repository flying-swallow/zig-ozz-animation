const std = @import("std");
const ozz = @import("zig_ozz_animation");
const geometry = ozz.geometry;
const math = ozz.math;
const h = @import("helpers.zig");

test "JobValidity/SkinningJob" {
    var output: [1]math.Vec3f32 = undefined;
    try std.testing.expectError(geometry.SkinningError.InvalidInfluenceCount, geometry.skin(.{
        .joint_matrices = &.{math.Float4x4.identity},
        .joint_indices = &.{},
        .joint_weights = &.{},
        .input_positions = &.{@as(math.Vec3f32, @splat(0))},
        .output_positions = &output,
        .influences_count = 0,
    }));
}

test "JobValidityBufferMatrix/SkinningJob" {
    var indices = [_]u16{ 0, 0, 0, 0 };
    var weights = [_]f32{ 0, 0 };
    var positions = [_]math.Vec3f32{ @splat(0), @splat(0) };
    var outputs: [2]math.Vec3f32 = undefined;

    const valid: geometry.StridedSkinningOptions = .{
        .vertex_count = 2,
        .influences_count = 2,
        .joint_matrices = &.{math.Float4x4.identity},
        .joint_indices = std.mem.sliceAsBytes(&indices),
        .joint_indices_stride = 2 * @sizeOf(u16),
        .joint_weights = std.mem.sliceAsBytes(&weights),
        .joint_weights_stride = @sizeOf(f32),
        .input_positions = std.mem.sliceAsBytes(&positions),
        .input_positions_stride = @sizeOf(math.Vec3f32),
        .output_positions = std.mem.sliceAsBytes(&outputs),
        .output_positions_stride = @sizeOf(math.Vec3f32),
    };
    try geometry.skinStrided(valid);

    var invalid = valid;
    invalid.joint_matrices = &.{};
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skinStrided(invalid));

    invalid = valid;
    invalid.joint_indices = &.{};
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skinStrided(invalid));
    invalid.joint_indices = std.mem.sliceAsBytes(&indices)[0 .. 3 * @sizeOf(u16)];
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skinStrided(invalid));
    invalid = valid;
    invalid.joint_indices_stride = std.mem.sliceAsBytes(&indices).len + 1;
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skinStrided(invalid));

    invalid = valid;
    invalid.joint_weights = &.{};
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skinStrided(invalid));
    invalid.joint_weights = std.mem.sliceAsBytes(&weights)[0..@sizeOf(f32)];
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skinStrided(invalid));
    invalid = valid;
    invalid.joint_weights_stride = std.mem.sliceAsBytes(&weights).len + 1;
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skinStrided(invalid));

    invalid = valid;
    invalid.input_positions = &.{};
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skinStrided(invalid));
    invalid = valid;
    invalid.output_positions = &.{};
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skinStrided(invalid));

    var normals = [_]math.Vec3f32{ @splat(0), @splat(0) };
    var normal_outputs: [2]math.Vec3f32 = undefined;
    invalid = valid;
    invalid.input_normals = std.mem.sliceAsBytes(&normals);
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skinStrided(invalid));
    invalid.output_normals = std.mem.sliceAsBytes(&normal_outputs);
    invalid.input_normals_stride = @sizeOf(math.Vec3f32);
    invalid.output_normals_stride = @sizeOf(math.Vec3f32);
    try geometry.skinStrided(invalid);

    var tangents = [_]math.Vec3f32{ @splat(0), @splat(0) };
    var tangent_outputs: [2]math.Vec3f32 = undefined;
    invalid.input_tangents = std.mem.sliceAsBytes(&tangents);
    invalid.input_tangents_stride = @sizeOf(math.Vec3f32);
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skinStrided(invalid));
    invalid.output_tangents = std.mem.sliceAsBytes(&tangent_outputs);
    invalid.output_tangents_stride = @sizeOf(math.Vec3f32);
    try geometry.skinStrided(invalid);

    invalid = valid;
    invalid.input_tangents = std.mem.sliceAsBytes(&tangents);
    invalid.input_tangents_stride = @sizeOf(math.Vec3f32);
    invalid.output_tangents = std.mem.sliceAsBytes(&tangent_outputs);
    invalid.output_tangents_stride = @sizeOf(math.Vec3f32);
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skinStrided(invalid));
}

test "JobValidityZeroVerticesAndReusableRecords/SkinningJob" {
    var output: [1]math.Vec3f32 = undefined;
    try geometry.skinStrided(.{
        .vertex_count = 0,
        .influences_count = 1,
        .joint_matrices = &.{math.Float4x4.identity},
        .joint_indices = &.{},
        .joint_indices_stride = 0,
        .input_positions = &.{},
        .input_positions_stride = 0,
        .output_positions = std.mem.sliceAsBytes(&output),
        .output_positions_stride = 0,
    });

    var index: u16 = 0;
    var position = @as(math.Vec3f32, @splat(0));
    var outputs: [2]math.Vec3f32 = undefined;
    try geometry.skinStrided(.{
        .vertex_count = 2,
        .influences_count = 1,
        .joint_matrices = &.{math.Float4x4.identity},
        .joint_indices = std.mem.asBytes(&index),
        .joint_indices_stride = 0,
        .input_positions = std.mem.asBytes(&position),
        .input_positions_stride = 0,
        .output_positions = std.mem.sliceAsBytes(&outputs),
        .output_positions_stride = @sizeOf(math.Vec3f32),
    });
}

test "Run/SkinningJob" {
    const matrices = [_]math.Float4x4{
        math.Float4x4.fromTransform(.{ .translation = .{ 1, 0, 0 } }),
        math.Float4x4.fromTransform(.{ .translation = .{ 0, 2, 0 } }),
        math.Float4x4.fromTransform(.{ .translation = .{ 0, 0, 3 } }),
    };
    var positions: [1]math.Vec3f32 = undefined;
    var normals: [1]math.Vec3f32 = undefined;
    var tangents: [1]math.Vec3f32 = undefined;
    try geometry.skin(.{
        .joint_matrices = &matrices,
        .joint_indices = &.{ 0, 1, 2 },
        .joint_weights = &.{ 0.2, 0.3 },
        .input_positions = &.{.{ 1, 1, 1 }},
        .input_normals = &.{@as(math.Vec3f32, .{ 0, 1, 0 })},
        .input_tangents = &.{@as(math.Vec3f32, .{ 1, 0, 0 })},
        .output_positions = &positions,
        .output_normals = &normals,
        .output_tangents = &tangents,
        .influences_count = 3,
    });
    try h.expectFloat3(.{ 1.2, 1.6, 2.5 }, positions[0]);
    try h.expectFloat3(.{ 0, 1, 0 }, normals[0]);
    try h.expectFloat3(.{ 1, 0, 0 }, tangents[0]);
}

test "RunInverseTranspose/SkinningJob" {
    const matrix = math.Float4x4.fromTransform(.{ .scale = .{ 2, 3, 4 } });
    const inverse_transpose: math.Float4x4 = .{ .cols = .{
        .{ 0.5, 0, 0, 0 },
        .{ 0, 1.0 / 3.0, 0, 0 },
        .{ 0, 0, 0.25, 0 },
        .{ 0, 0, 0, 1 },
    } };
    var positions: [1]math.Vec3f32 = undefined;
    var normals: [1]math.Vec3f32 = undefined;
    var tangents: [1]math.Vec3f32 = undefined;
    try geometry.skin(.{
        .joint_matrices = &.{matrix},
        .joint_inverse_transpose_matrices = &.{inverse_transpose},
        .joint_indices = &.{0},
        .joint_weights = &.{},
        .input_positions = &.{@as(math.Vec3f32, @splat(1))},
        .input_normals = &.{.{ 1, 0, 0 }},
        .input_tangents = &.{.{ 1, 0, 0 }},
        .output_positions = &positions,
        .output_normals = &normals,
        .output_tangents = &tangents,
        .influences_count = 1,
    });
    try h.expectFloat3(.{ 2, 3, 4 }, positions[0]);
    try h.expectFloat3(.{ 0.5, 0, 0 }, normals[0]);
    try h.expectFloat3(.{ 0.5, 0, 0 }, tangents[0]);
}

test "TangentsRequireNormals/SkinningJob" {
    var positions: [1]math.Vec3f32 = undefined;
    var tangents: [1]math.Vec3f32 = undefined;
    try std.testing.expectError(geometry.SkinningError.BufferTooSmall, geometry.skin(.{
        .joint_matrices = &.{math.Float4x4.identity},
        .joint_indices = &.{0},
        .joint_weights = &.{},
        .input_positions = &.{@as(math.Vec3f32, @splat(0))},
        .input_tangents = &.{.{ 1, 0, 0 }},
        .output_positions = &positions,
        .output_tangents = &tangents,
        .influences_count = 1,
    }));
}

test "RunStrided/SkinningJob" {
    const PaddedFloat3 = struct {
        value: math.Vec3f32,
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
        math.Float4x4.fromTransform(.{ .translation = .{ 2, 0, 0 } }),
    };
    var inputs = [_]PaddedFloat3{
        .{ .value = .{ 1, 0, 0 } },
        .{ .value = .{ 3, 0, 0 } },
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
    try h.expectFloat3(.{ 2.5, 0, 0 }, outputs[0].value);
    try h.expectFloat3(.{ 4, 0, 0 }, outputs[1].value);
}

test "PackedFloat3Layout/SkinningJob" {
    const matrices = [_]math.Float4x4{
        math.Float4x4.fromTransform(.{ .translation = .{ 2, 0, 0 } }),
    };
    var indices = [_]u16{0};
    var input = [_]f32{ 1, 2, 3 };
    var output: [3]f32 = undefined;

    try geometry.skinStrided(.{
        .vertex_count = 1,
        .influences_count = 1,
        .joint_matrices = &matrices,
        .joint_indices = std.mem.sliceAsBytes(&indices),
        .joint_indices_stride = @sizeOf(u16),
        .input_positions = std.mem.sliceAsBytes(&input),
        .input_positions_stride = 3 * @sizeOf(f32),
        .output_positions = std.mem.sliceAsBytes(&output),
        .output_positions_stride = 3 * @sizeOf(f32),
    });

    try std.testing.expectEqualSlices(f32, &.{ 3, 2, 3 }, &output);
}

test "OverlappingInfluenceRecords/SkinningJob" {
    const matrices = [_]math.Float4x4{
        math.Float4x4.identity,
        math.Float4x4.fromTransform(.{ .translation = .{ 2, 0, 0 } }),
        math.Float4x4.fromTransform(.{ .translation = .{ 0, 4, 0 } }),
        math.Float4x4.fromTransform(.{ .translation = .{ 0, 0, 8 } }),
    };
    // Vertex 0 reads 0,1,2,3. Vertex 1 advances by two indices and reads
    // 2,3,0,1, matching the sliding layout accepted by Ozz.
    var indices = [_]u16{ 0, 1, 2, 3, 0, 1 };
    // Three explicit weights per vertex, with records overlapping by one
    // weight. The fourth weight is implicit.
    var weights = [_]f32{ 0.1, 0.2, 0.3, 0.1, 0.2 };
    var inputs = [_]math.Vec3f32{ @splat(0), @splat(0) };
    var outputs: [2]math.Vec3f32 = undefined;
    try geometry.skinStrided(.{
        .vertex_count = 2,
        .influences_count = 4,
        .joint_matrices = &matrices,
        .joint_indices = std.mem.sliceAsBytes(&indices),
        .joint_indices_stride = 2 * @sizeOf(u16),
        .joint_weights = std.mem.sliceAsBytes(&weights),
        .joint_weights_stride = 2 * @sizeOf(f32),
        .input_positions = std.mem.sliceAsBytes(&inputs),
        .input_positions_stride = @sizeOf(math.Vec3f32),
        .output_positions = std.mem.sliceAsBytes(&outputs),
        .output_positions_stride = @sizeOf(math.Vec3f32),
    });
    try h.expectFloat3(.{ 0.4, 1.2, 3.2 }, outputs[0]);
    try h.expectFloat3(.{ 0.8, 1.2, 0.8 }, outputs[1]);
}
