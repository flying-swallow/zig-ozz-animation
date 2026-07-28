// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Unit icosphere: a regular icosahedron subdivided twice, every vertex projected back
//! onto the unit sphere. Port of `ozz-animation/samples/framework/internal/icosphere.h`,
//! which ships the same mesh as a precomputed table rounded to three decimals; here it
//! is generated at comptime at full `f32` precision.
//!
//! Because the positions are unit length they double as normals, exactly like upstream's
//! `kVertices` (which `DrawSphereShaded` aliases as both attributes).
//!
//! Triangles are wound counter-clockwise when seen from outside the sphere.

const std = @import("std");

/// Subdivision levels applied to the base icosahedron.
pub const subdivisions = 2;

/// 10 * 4^n + 2 — matches upstream's 162 vertices (486 floats).
pub const vertex_count: usize = 10 * (@as(usize, 1) << (2 * subdivisions)) + 2;
/// 20 * 4^n — matches upstream's 320 triangles.
pub const triangle_count: usize = 20 * (@as(usize, 1) << (2 * subdivisions));
/// 960, matching upstream's `kNumIndices`.
pub const index_count: usize = triangle_count * 3;

const sphere = build();

/// Unit-length xyz triples, usable as positions *and* normals.
pub const vertices: []const f32 = &sphere.positions;
/// Triangle list into `vertices`.
pub const indices: []const u16 = &sphere.indices;

const Sphere = struct {
    positions: [vertex_count * 3]f32,
    indices: [index_count]u16,
};

/// Golden-ratio icosahedron, unnormalized.
const base_positions = [12][3]f32{
    .{ -1, phi, 0 }, .{ 1, phi, 0 }, .{ -1, -phi, 0 }, .{ 1, -phi, 0 },
    .{ 0, -1, phi }, .{ 0, 1, phi }, .{ 0, -1, -phi }, .{ 0, 1, -phi },
    .{ phi, 0, -1 }, .{ phi, 0, 1 }, .{ -phi, 0, -1 }, .{ -phi, 0, 1 },
};

const phi: f32 = 1.6180339887498949;

/// The 20 faces of the icosahedron, counter-clockwise seen from outside.
const base_faces = [20][3]u16{
    .{ 0, 11, 5 }, .{ 0, 5, 1 },  .{ 0, 1, 7 },   .{ 0, 7, 10 }, .{ 0, 10, 11 },
    .{ 1, 5, 9 },  .{ 5, 11, 4 }, .{ 11, 10, 2 }, .{ 10, 7, 6 }, .{ 7, 1, 8 },
    .{ 3, 9, 4 },  .{ 3, 4, 2 },  .{ 3, 2, 6 },   .{ 3, 6, 8 },  .{ 3, 8, 9 },
    .{ 4, 9, 5 },  .{ 2, 4, 11 }, .{ 6, 2, 10 },  .{ 8, 6, 7 },  .{ 9, 8, 1 },
};

/// Per-level midpoint cache. The deepest subdivision splits 80 faces, so it needs at
/// most 3 * 80 = 240 unique edges.
const max_edges = triangle_count * 3 / 4 + 1;

const Builder = struct {
    positions: [vertex_count][3]f32 = undefined,
    count: usize = 0,
    edge_lo: [max_edges]u16 = undefined,
    edge_hi: [max_edges]u16 = undefined,
    edge_mid: [max_edges]u16 = undefined,
    edges: usize = 0,

    fn push(self: *Builder, p: [3]f32) u16 {
        const index: u16 = @intCast(self.count);
        self.positions[self.count] = normalize(p);
        self.count += 1;
        return index;
    }

    /// Splits an edge, reusing the vertex when the neighbouring face already split it.
    fn midpoint(self: *Builder, a: u16, b: u16) u16 {
        const lo = @min(a, b);
        const hi = @max(a, b);
        for (0..self.edges) |i| {
            if (self.edge_lo[i] == lo and self.edge_hi[i] == hi) return self.edge_mid[i];
        }
        const pa = self.positions[a];
        const pb = self.positions[b];
        const index = self.push(.{
            (pa[0] + pb[0]) * 0.5,
            (pa[1] + pb[1]) * 0.5,
            (pa[2] + pb[2]) * 0.5,
        });
        self.edge_lo[self.edges] = lo;
        self.edge_hi[self.edges] = hi;
        self.edge_mid[self.edges] = index;
        self.edges += 1;
        return index;
    }
};

fn normalize(p: [3]f32) [3]f32 {
    const len = @sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
    return .{ p[0] / len, p[1] / len, p[2] / len };
}

fn build() Sphere {
    @setEvalBranchQuota(4_000_000);

    var builder: Builder = .{};
    for (base_positions) |p| _ = builder.push(p);

    var faces: [triangle_count][3]u16 = undefined;
    var face_count: usize = base_faces.len;
    for (base_faces, 0..) |f, i| faces[i] = f;

    for (0..subdivisions) |_| {
        // Edges are only shared within a level, so the cache resets each round.
        builder.edges = 0;

        var split: [triangle_count][3]u16 = undefined;
        var split_count: usize = 0;
        for (faces[0..face_count]) |f| {
            const a = builder.midpoint(f[0], f[1]);
            const b = builder.midpoint(f[1], f[2]);
            const c = builder.midpoint(f[2], f[0]);
            split[split_count + 0] = .{ f[0], a, c };
            split[split_count + 1] = .{ f[1], b, a };
            split[split_count + 2] = .{ f[2], c, b };
            split[split_count + 3] = .{ a, b, c };
            split_count += 4;
        }
        faces = split;
        face_count = split_count;
    }

    var sphere_data: Sphere = .{ .positions = undefined, .indices = undefined };
    for (builder.positions, 0..) |p, i| {
        sphere_data.positions[i * 3 + 0] = p[0];
        sphere_data.positions[i * 3 + 1] = p[1];
        sphere_data.positions[i * 3 + 2] = p[2];
    }
    for (faces, 0..) |f, i| {
        sphere_data.indices[i * 3 + 0] = f[0];
        sphere_data.indices[i * 3 + 1] = f[1];
        sphere_data.indices[i * 3 + 2] = f[2];
    }
    return sphere_data;
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "counts match upstream icosphere.h" {
    try testing.expectEqual(@as(usize, 162), vertex_count);
    try testing.expectEqual(@as(usize, 320), triangle_count);
    try testing.expectEqual(@as(usize, 960), index_count);
    try testing.expectEqual(@as(usize, 486), vertices.len);
    try testing.expectEqual(@as(usize, 960), indices.len);
}

test "every vertex is unit length" {
    var i: usize = 0;
    while (i < vertices.len) : (i += 3) {
        const x = vertices[i];
        const y = vertices[i + 1];
        const z = vertices[i + 2];
        try testing.expectApproxEqAbs(@as(f32, 1), @sqrt(x * x + y * y + z * z), 1e-6);
    }
}

test "every index is in range and every triangle is non-degenerate" {
    for (indices) |index| try testing.expect(index < vertex_count);

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        try testing.expect(indices[i] != indices[i + 1]);
        try testing.expect(indices[i + 1] != indices[i + 2]);
        try testing.expect(indices[i + 2] != indices[i]);
    }
}

test "every vertex is unique" {
    var i: usize = 0;
    while (i < vertex_count) : (i += 1) {
        var j: usize = i + 1;
        while (j < vertex_count) : (j += 1) {
            const dx = vertices[i * 3] - vertices[j * 3];
            const dy = vertices[i * 3 + 1] - vertices[j * 3 + 1];
            const dz = vertices[i * 3 + 2] - vertices[j * 3 + 2];
            try testing.expect(dx * dx + dy * dy + dz * dz > 1e-8);
        }
    }
}

test "every vertex is referenced by at least one triangle" {
    var used: [vertex_count]bool = @splat(false);
    for (indices) |index| used[index] = true;
    for (used) |u| try testing.expect(u);
}

test "triangles are wound counter-clockwise when seen from outside" {
    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const a = vertexAt(indices[i]);
        const b = vertexAt(indices[i + 1]);
        const c = vertexAt(indices[i + 2]);

        const ab = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const ac = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
        const n = [3]f32{
            ab[1] * ac[2] - ab[2] * ac[1],
            ab[2] * ac[0] - ab[0] * ac[2],
            ab[0] * ac[1] - ab[1] * ac[0],
        };
        // The centroid points outwards, so the face normal must agree with it.
        const centroid = [3]f32{ (a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3, (a[2] + b[2] + c[2]) / 3 };
        try testing.expect(n[0] * centroid[0] + n[1] * centroid[1] + n[2] * centroid[2] > 0);
    }
}

test "the sphere covers every octant" {
    var octants: [8]bool = @splat(false);
    var i: usize = 0;
    while (i < vertices.len) : (i += 3) {
        const slot: usize = @as(usize, @intFromBool(vertices[i] > 0)) |
            (@as(usize, @intFromBool(vertices[i + 1] > 0)) << 1) |
            (@as(usize, @intFromBool(vertices[i + 2] > 0)) << 2);
        octants[slot] = true;
    }
    for (octants) |o| try testing.expect(o);
}

fn vertexAt(index: u16) [3]f32 {
    return .{ vertices[index * 3], vertices[index * 3 + 1], vertices[index * 3 + 2] };
}
