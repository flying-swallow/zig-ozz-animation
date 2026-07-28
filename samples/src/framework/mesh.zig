// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Thin helpers over `ozz.geometry.Mesh` / `ozz.geometry.MeshPart`, mirroring the
//! accessors upstream declares inline in `samples/framework/mesh.h`. The library
//! type already owns the vertex streams, so nothing here duplicates storage: the
//! module only re-exports, wraps, and decodes.

const std = @import("std");
const ozz = @import("zig_ozz_animation");

/// Re-exported so samples can spell `mesh.Mesh` instead of reaching into the library.
pub const Mesh = ozz.geometry.Mesh;
pub const MeshPart = ozz.geometry.MeshPart;

/// Component counts of each vertex stream (`mesh.h` `kXxxCpnts`).
pub const position_components = 3;
pub const normal_components = 3;
pub const tangent_components = 4;
pub const uv_components = 2;
pub const color_components = 4;

/// Number of joints influencing every vertex of `part`.
/// Wraps `MeshPart.influencesCount` — `joint_indices` has this stride, and
/// `joint_weights` has a stride of `influences - 1` (the last weight is derived).
pub fn influencesCount(part: MeshPart) usize {
    return part.influencesCount();
}

/// Vertex count of a single part. Wraps `MeshPart.vertexCount`.
pub fn partVertexCount(part: MeshPart) usize {
    return part.vertexCount();
}

/// Vertex count of every part concatenated. Wraps `Mesh.vertexCount`.
pub fn vertexCount(mesh: Mesh) usize {
    return mesh.vertexCount();
}

/// Number of indices in the triangle list (always a multiple of three).
pub fn triangleIndexCount(mesh: Mesh) usize {
    return mesh.triangle_indices.len;
}

/// Largest per-vertex influence count across every part; 0 for a rigid mesh.
pub fn maxInfluences(mesh: Mesh) usize {
    var result: usize = 0;
    for (mesh.parts) |part| result = @max(result, part.influencesCount());
    return result;
}

/// True when at least one part carries skinning influences. Wraps `Mesh.skinned`.
pub fn skinned(mesh: Mesh) bool {
    return mesh.skinned();
}

/// Number of joints the mesh is bound to, i.e. the inverse bind-pose count.
pub fn numJoints(mesh: Mesh) usize {
    return mesh.inverse_bind_poses.len;
}

/// Highest skeleton joint index referenced by `joint_remaps`, 0 when unskinned.
/// `joint_remaps` is sorted, so upstream simply reads the last entry.
pub fn highestJointIndex(mesh: Mesh) u16 {
    return if (mesh.joint_remaps.len == 0) 0 else mesh.joint_remaps[mesh.joint_remaps.len - 1];
}

/// Position of a vertex addressed by its index in the concatenation of every
/// part, which is how `triangle_indices` addresses vertices. Returns null when
/// the index is out of range or the part's position stream is malformed.
pub fn vertexPosition(mesh: Mesh, global_index: usize) ?ozz.math.Vec3f32 {
    var base: usize = 0;
    for (mesh.parts) |part| {
        const count = part.vertexCount();
        if (global_index < base + count) {
            const index = global_index - base;
            if ((index + 1) * position_components > part.positions.len) return null;
            return .{
                part.positions[index * 3],
                part.positions[index * 3 + 1],
                part.positions[index * 3 + 2],
            };
        }
        base += count;
    }
    return null;
}

/// Gathers every part's positions into one caller-owned array, in the order
/// `triangle_indices` addresses them.
pub fn positions(allocator: std.mem.Allocator, mesh: Mesh) ![]ozz.math.Vec3f32 {
    const output = try allocator.alloc(ozz.math.Vec3f32, mesh.vertexCount());
    errdefer allocator.free(output);
    var cursor: usize = 0;
    for (mesh.parts) |part| {
        if (part.positions.len != part.vertexCount() * position_components) {
            return error.InvalidMeshArchive;
        }
        for (0..part.vertexCount()) |vertex| {
            output[cursor] = .{
                part.positions[vertex * 3],
                part.positions[vertex * 3 + 1],
                part.positions[vertex * 3 + 2],
            };
            cursor += 1;
        }
    }
    return output;
}

/// Decodes every mesh stored back-to-back in an upstream `.ozz` archive, the way
/// `ozz::sample::LoadMeshes` loops `TestTag<Mesh>()`. The legacy reader always
/// expects the archive header, so continuation reads are prefixed with the
/// original endianness byte.
pub fn decodeMeshes(allocator: std.mem.Allocator, bytes: []const u8) ![]Mesh {
    var meshes: std.ArrayList(Mesh) = .empty;
    errdefer {
        for (meshes.items) |*mesh| mesh.deinit();
        meshes.deinit(allocator);
    }
    var offset: usize = 0;
    while (offset < bytes.len) {
        const owned_view = if (offset == 0)
            null
        else blk: {
            const view = try allocator.alloc(u8, bytes.len - offset + 1);
            view[0] = bytes[0];
            @memcpy(view[1..], bytes[offset..]);
            break :blk view;
        };
        defer if (owned_view) |view| allocator.free(view);
        const view: []const u8 = owned_view orelse bytes;
        if (try ozz.legacy.detect(view) != .sample_mesh) return error.InvalidMeshArchive;
        var consumed: usize = 0;
        var reader = std.Io.Reader.fixed(view);
        var mesh = try ozz.legacy.readMeshPrefix(allocator, &reader, .{}, &consumed);
        meshes.append(allocator, mesh) catch |failure| {
            mesh.deinit();
            return failure;
        };
        if (consumed <= 1 or consumed > view.len) return error.InvalidMeshArchive;
        offset += if (offset == 0) consumed else consumed - 1;
    }
    return meshes.toOwnedSlice(allocator);
}

/// Releases a slice returned by `decodeMeshes`.
pub fn deinitMeshes(allocator: std.mem.Allocator, meshes: []Mesh) void {
    for (meshes) |*mesh| mesh.deinit();
    allocator.free(meshes);
}

test "floor mesh decodes as a rigid mesh" {
    const allocator = std.testing.allocator;
    const meshes = try decodeMeshes(allocator, @embedFile("floor_mesh"));
    defer deinitMeshes(allocator, meshes);

    try std.testing.expect(meshes.len >= 1);
    for (meshes) |mesh| {
        try std.testing.expect(vertexCount(mesh) > 0);
        try std.testing.expectEqual(@as(usize, 0), triangleIndexCount(mesh) % 3);
        try std.testing.expect(!skinned(mesh));
        try std.testing.expectEqual(@as(usize, 0), maxInfluences(mesh));
        try std.testing.expectEqual(@as(usize, 0), numJoints(mesh));
        try std.testing.expectEqual(@as(u16, 0), highestJointIndex(mesh));
        for (mesh.parts) |part| {
            try std.testing.expectEqual(
                part.vertexCount() * position_components,
                part.positions.len,
            );
            try std.testing.expectEqual(@as(usize, 0), influencesCount(part));
        }
    }
}

test "arnaud mesh decodes as a skinned mesh" {
    const allocator = std.testing.allocator;
    const meshes = try decodeMeshes(allocator, @embedFile("arnaud_mesh"));
    defer deinitMeshes(allocator, meshes);

    try std.testing.expect(meshes.len >= 1);
    var total: usize = 0;
    for (meshes) |mesh| {
        total += vertexCount(mesh);
        try std.testing.expect(skinned(mesh));
        try std.testing.expect(maxInfluences(mesh) > 0);
        try std.testing.expectEqual(mesh.joint_remaps.len, numJoints(mesh));
        try std.testing.expect(highestJointIndex(mesh) > 0);
        // joint_remaps is sorted, so its last entry really is the maximum.
        for (mesh.joint_remaps) |remap| {
            try std.testing.expect(remap <= highestJointIndex(mesh));
        }
        for (mesh.parts) |part| {
            const influences = influencesCount(part);
            try std.testing.expect(influences > 0);
            try std.testing.expectEqual(
                partVertexCount(part) * influences,
                part.joint_indices.len,
            );
            try std.testing.expectEqual(
                partVertexCount(part) * (influences - 1),
                part.joint_weights.len,
            );
        }
    }
    try std.testing.expect(total > 0);
}

test "vertexPosition matches the gathered position array" {
    const allocator = std.testing.allocator;
    const meshes = try decodeMeshes(allocator, @embedFile("floor_mesh"));
    defer deinitMeshes(allocator, meshes);

    const mesh = meshes[0];
    const gathered = try positions(allocator, mesh);
    defer allocator.free(gathered);
    try std.testing.expectEqual(vertexCount(mesh), gathered.len);
    for (gathered, 0..) |expected, index| {
        const found = vertexPosition(mesh, index) orelse return error.MissingVertex;
        try std.testing.expectEqual(expected, found);
    }
    try std.testing.expectEqual(
        @as(?ozz.math.Vec3f32, null),
        vertexPosition(mesh, gathered.len),
    );
}

test "decodeMeshes rejects a non-mesh archive" {
    try std.testing.expectError(
        error.InvalidMeshArchive,
        decodeMeshes(std.testing.allocator, @embedFile("pab_skeleton")),
    );
}
