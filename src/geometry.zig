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
    InvalidStride,
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

pub const StridedSkinningOptions = struct {
    vertex_count: usize,
    influences_count: usize,
    joint_matrices: []const math.Float4x4,
    joint_inverse_transpose_matrices: ?[]const math.Float4x4 = null,
    joint_indices: []const u8,
    joint_indices_stride: usize,
    /// Stores N-1 weights per vertex. The final influence is implicit.
    joint_weights: []const u8 = &.{},
    joint_weights_stride: usize = 0,
    input_positions: []const u8,
    input_positions_stride: usize,
    input_normals: ?[]const u8 = null,
    input_normals_stride: usize = 0,
    input_tangents: ?[]const u8 = null,
    input_tangents_stride: usize = 0,
    output_positions: []u8,
    output_positions_stride: usize,
    output_normals: ?[]u8 = null,
    output_normals_stride: usize = 0,
    output_tangents: ?[]u8 = null,
    output_tangents_stride: usize = 0,
};

fn requiredBytes(count: usize, stride: usize, element_size: usize) !usize {
    if (count == 0) return 0;
    const preceding = std.math.mul(usize, count - 1, stride) catch
        return SkinningError.InvalidVertexCount;
    return std.math.add(usize, preceding, element_size) catch
        return SkinningError.InvalidVertexCount;
}

fn readStrided(comptime T: type, bytes: []const u8, index: usize, stride: usize) T {
    const offset = index * stride;
    return std.mem.bytesToValue(T, bytes[offset..][0..@sizeOf(T)]);
}

fn writeStrided(comptime T: type, bytes: []u8, index: usize, stride: usize, value: T) void {
    const offset = index * stride;
    @memcpy(bytes[offset..][0..@sizeOf(T)], std.mem.asBytes(&value));
}

/// Ozz-compatible strided CPU skinning. Positions, normals, and tangents are
/// float3 values; joint indices are u16 and weights are f32.
pub fn skinStrided(options: StridedSkinningOptions) !void {
    if (options.influences_count == 0) return SkinningError.InvalidInfluenceCount;
    const index_size = options.influences_count * @sizeOf(u16);
    const weight_size = (options.influences_count - 1) * @sizeOf(f32);
    if (options.joint_indices_stride < index_size or
        (options.influences_count > 1 and options.joint_weights_stride < weight_size) or
        options.input_positions_stride < @sizeOf(math.Float3) or
        options.output_positions_stride < @sizeOf(math.Float3))
    {
        return SkinningError.InvalidStride;
    }
    if (options.joint_indices.len < try requiredBytes(options.vertex_count, options.joint_indices_stride, index_size) or
        options.joint_weights.len < try requiredBytes(options.vertex_count, options.joint_weights_stride, weight_size) or
        options.input_positions.len < try requiredBytes(options.vertex_count, options.input_positions_stride, @sizeOf(math.Float3)) or
        options.output_positions.len < try requiredBytes(options.vertex_count, options.output_positions_stride, @sizeOf(math.Float3)))
    {
        return SkinningError.BufferTooSmall;
    }
    if (options.input_normals) |input| {
        if (options.input_normals_stride < @sizeOf(math.Float3) or
            options.output_normals == null or
            options.output_normals_stride < @sizeOf(math.Float3) or
            input.len < try requiredBytes(options.vertex_count, options.input_normals_stride, @sizeOf(math.Float3)) or
            options.output_normals.?.len < try requiredBytes(options.vertex_count, options.output_normals_stride, @sizeOf(math.Float3)))
        {
            return SkinningError.BufferTooSmall;
        }
    }
    if (options.input_tangents) |input| {
        if (options.input_tangents_stride < @sizeOf(math.Float3) or
            options.output_tangents == null or
            options.output_tangents_stride < @sizeOf(math.Float3) or
            input.len < try requiredBytes(options.vertex_count, options.input_tangents_stride, @sizeOf(math.Float3)) or
            options.output_tangents.?.len < try requiredBytes(options.vertex_count, options.output_tangents_stride, @sizeOf(math.Float3)))
        {
            return SkinningError.BufferTooSmall;
        }
    }
    if (options.joint_inverse_transpose_matrices) |matrices| {
        if (matrices.len < options.joint_matrices.len) return SkinningError.BufferTooSmall;
    }

    for (0..options.vertex_count) |vertex| {
        const input_position = readStrided(math.Float3, options.input_positions, vertex, options.input_positions_stride);
        const input_normal = if (options.input_normals) |input|
            readStrided(math.Float3, input, vertex, options.input_normals_stride)
        else
            math.Float3.zero;
        const input_tangent = if (options.input_tangents) |input|
            readStrided(math.Float3, input, vertex, options.input_tangents_stride)
        else
            math.Float3.zero;
        var output_position = math.Float3.zero;
        var output_normal = math.Float3.zero;
        var output_tangent = math.Float3.zero;
        var accumulated_weight: f32 = 0;
        const index_base = vertex * options.joint_indices_stride;
        const weight_base = vertex * options.joint_weights_stride;
        for (0..options.influences_count) |influence| {
            const joint = std.mem.bytesToValue(
                u16,
                options.joint_indices[index_base + influence * @sizeOf(u16) ..][0..@sizeOf(u16)],
            );
            if (joint >= options.joint_matrices.len) return SkinningError.JointOutOfRange;
            const weight = if (influence + 1 == options.influences_count)
                1 - accumulated_weight
            else
                std.mem.bytesToValue(
                    f32,
                    options.joint_weights[weight_base + influence * @sizeOf(f32) ..][0..@sizeOf(f32)],
                );
            accumulated_weight += weight;
            const matrix = options.joint_matrices[joint];
            output_position = math.Float3.add(
                output_position,
                math.Float3.scale(math.Float4x4.transformPoint(matrix, input_position), weight),
            );
            if (options.input_normals != null) {
                const normal_matrix = if (options.joint_inverse_transpose_matrices) |matrices|
                    matrices[joint]
                else
                    matrix;
                output_normal = math.Float3.add(
                    output_normal,
                    math.Float3.scale(math.Float4x4.transformVector(normal_matrix, input_normal), weight),
                );
            }
            if (options.input_tangents != null) {
                output_tangent = math.Float3.add(
                    output_tangent,
                    math.Float3.scale(math.Float4x4.transformVector(matrix, input_tangent), weight),
                );
            }
        }
        writeStrided(math.Float3, options.output_positions, vertex, options.output_positions_stride, output_position);
        if (options.output_normals) |output| {
            writeStrided(math.Float3, output, vertex, options.output_normals_stride, output_normal);
        }
        if (options.output_tangents) |output| {
            writeStrided(math.Float3, output, vertex, options.output_tangents_stride, output_tangent);
        }
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
