const math = @import("math.zig");

pub const MeshPart = struct {
    positions: []f32 = &.{},
    normals: []f32 = &.{},
    tangents: []f32 = &.{},
    uvs: []f32 = &.{},
    colors: []u8 = &.{},
    joint_indices: []u16 = &.{},
    joint_weights: []f32 = &.{},

    pub fn vertexCount(self: MeshPart) usize {
        return self.positions.len / 3;
    }

    pub fn influencesCount(self: MeshPart) usize {
        const vertices = self.vertexCount();
        return if (vertices == 0) 0 else self.joint_indices.len / vertices;
    }
};

pub const Mesh = struct {
    allocator: std.mem.Allocator,
    parts: []MeshPart,
    triangle_indices: []u16,
    joint_remaps: []u16,
    inverse_bind_poses: []math.Float4x4,

    pub fn deinit(self: *Mesh) void {
        for (self.parts) |part| {
            self.allocator.free(part.positions);
            self.allocator.free(part.normals);
            self.allocator.free(part.tangents);
            self.allocator.free(part.uvs);
            self.allocator.free(part.colors);
            self.allocator.free(part.joint_indices);
            self.allocator.free(part.joint_weights);
        }
        self.allocator.free(self.parts);
        self.allocator.free(self.triangle_indices);
        self.allocator.free(self.joint_remaps);
        self.allocator.free(self.inverse_bind_poses);
        self.* = undefined;
    }

    pub fn vertexCount(self: Mesh) usize {
        var count: usize = 0;
        for (self.parts) |part| count += part.vertexCount();
        return count;
    }

    pub fn skinned(self: Mesh) bool {
        return self.inverse_bind_poses.len != 0;
    }
};

pub const SkinningError = error{
    InvalidVertexCount,
    InvalidInfluenceCount,
    BufferTooSmall,
    JointOutOfRange,
};

/// Inputs are tightly packed per vertex. Every vertex has `influences_count`
/// joint indices and weights; weights need not be pre-normalized.
pub const SkinningOptions = struct {
    joint_matrices: []const math.Float4x4,
    joint_inverse_transpose_matrices: ?[]const math.Float4x4 = null,
    joint_indices: []const u16,
    /// Either all influences, or N-1 weights per vertex. In the latter form
    /// the final weight is restored as `1 - sum(previous)`.
    joint_weights: []const f32,
    input_positions: []const math.Float3,
    input_normals: ?[]const math.Float3 = null,
    input_tangents: ?[]const math.Float3 = null,
    output_positions: []math.Float3,
    output_normals: ?[]math.Float3 = null,
    output_tangents: ?[]math.Float3 = null,
    influences_count: usize,
};

pub fn skin(options: SkinningOptions) !void {
    if (options.influences_count == 0) return SkinningError.InvalidInfluenceCount;
    const vertex_count = options.input_positions.len;
    const influence_len = std.math.mul(usize, vertex_count, options.influences_count) catch
        return SkinningError.InvalidVertexCount;
    const explicit_weight_len = if (options.influences_count > 0)
        vertex_count * (options.influences_count - 1)
    else
        0;
    const has_full_weights = options.joint_weights.len >= influence_len;
    if (options.joint_indices.len < influence_len or
        (!has_full_weights and options.joint_weights.len < explicit_weight_len) or
        options.output_positions.len < vertex_count)
    {
        return SkinningError.BufferTooSmall;
    }
    if (options.input_normals) |normals| {
        if (normals.len < vertex_count or options.output_normals == null or
            options.output_normals.?.len < vertex_count)
        {
            return SkinningError.BufferTooSmall;
        }
    }
    if (options.input_tangents) |tangents| {
        if (tangents.len < vertex_count or options.output_tangents == null or
            options.output_tangents.?.len < vertex_count)
        {
            return SkinningError.BufferTooSmall;
        }
    }
    if (options.joint_inverse_transpose_matrices) |matrices| {
        if (matrices.len < options.joint_matrices.len) return SkinningError.BufferTooSmall;
    }

    for (options.input_positions, 0..) |position, vertex| {
        var out_position = math.Float3.zero;
        var out_normal = math.Float3.zero;
        var out_tangent = math.Float3.zero;
        var previous_weight: f32 = 0;
        const base = vertex * options.influences_count;
        for (0..options.influences_count) |influence| {
            const joint = options.joint_indices[base + influence];
            if (joint >= options.joint_matrices.len) return SkinningError.JointOutOfRange;
            const weight_index = if (has_full_weights)
                base + influence
            else
                vertex * (options.influences_count - 1) + influence;
            const weight = if (!has_full_weights and influence + 1 == options.influences_count)
                1 - previous_weight
            else
                options.joint_weights[weight_index];
            if (weight == 0) continue;
            const matrix = options.joint_matrices[joint];
            out_position = math.Float3.add(
                out_position,
                math.Float3.scale(math.Float4x4.transformPoint(matrix, position), weight),
            );
            if (options.input_normals) |normals| {
                const n = normals[vertex];
                const normal_matrix = if (options.joint_inverse_transpose_matrices) |matrices|
                    matrices[joint]
                else
                    matrix;
                const transformed = math.Float4x4.transformVector(normal_matrix, n);
                out_normal = math.Float3.add(out_normal, math.Float3.scale(transformed, weight));
            }
            if (options.input_tangents) |tangents| {
                const transformed = math.Float4x4.transformVector(matrix, tangents[vertex]);
                out_tangent = math.Float3.add(out_tangent, math.Float3.scale(transformed, weight));
            }
            previous_weight += weight;
        }
        options.output_positions[vertex] = out_position;
        if (options.output_normals) |normals| normals[vertex] = out_normal;
        if (options.output_tangents) |tangents| tangents[vertex] = out_tangent;
    }
}

const std = @import("std");

test "linear blend skinning" {
    const matrices = [_]math.Float4x4{
        math.Float4x4.identity,
        math.Float4x4.fromTransform(.{ .translation = .{ .x = 2 } }),
    };
    var output: [1]math.Float3 = undefined;
    try skin(.{
        .joint_matrices = &matrices,
        .joint_indices = &.{ 0, 1 },
        .joint_weights = &.{ 0.25, 0.75 },
        .input_positions = &.{.{ .x = 1 }},
        .output_positions = &output,
        .influences_count = 2,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), output[0].x, 1e-5);
}
