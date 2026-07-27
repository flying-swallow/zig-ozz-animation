// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Renderer-neutral geometry stage for the rhi-zig desktop samples.
//! Upload the returned vertices to a line-list vertex buffer and draw
//! `2 * skeleton.numJoints()` vertices.

const std = @import("std");
const ozz = @import("zig_ozz_animation");

pub const Vertex = extern struct {
    position: [3]f32,
    color: [4]f32,
};

pub fn requiredVertexCount(skeleton: ozz.animation.Skeleton) usize {
    return skeleton.numJoints() * 2;
}

pub fn buildBoneLines(
    skeleton: ozz.animation.Skeleton,
    models: []const ozz.math.Float4x4,
    output: []Vertex,
) ![]Vertex {
    if (models.len < skeleton.numJoints() or output.len < requiredVertexCount(skeleton)) {
        return error.BufferTooSmall;
    }
    for (skeleton.parents, 0..) |parent, joint| {
        const child_position = models[joint].translation();
        const parent_position = if (parent == ozz.animation.no_parent)
            child_position
        else
            models[@intCast(parent)].translation();
        const depth_color: f32 = @as(f32, @floatFromInt(joint % 7)) / 7;
        const color = [4]f32{ 0.2 + depth_color, 0.8 - depth_color * 0.5, 1, 1 };
        output[joint * 2] = .{
            .position = .{ parent_position.x, parent_position.y, parent_position.z },
            .color = color,
        };
        output[joint * 2 + 1] = .{
            .position = .{ child_position.x, child_position.y, child_position.z },
            .color = color,
        };
    }
    return output[0..requiredVertexCount(skeleton)];
}

test "builds one line per joint" {
    var skeleton = try ozz.animation.Skeleton.init(std.testing.allocator, &.{
        .{ .name = "root", .parent = ozz.animation.no_parent },
        .{ .name = "child", .parent = 0 },
    });
    defer skeleton.deinit();
    const models = [_]ozz.math.Float4x4{
        ozz.math.Float4x4.identity,
        ozz.math.Float4x4.fromTransform(.{ .translation = .{ .y = 2 } }),
    };
    var vertices: [4]Vertex = undefined;
    const lines = try buildBoneLines(skeleton, &models, &vertices);
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqual(@as(f32, 2), lines[3].position[1]);
}
