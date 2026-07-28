// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/framework/internal/renderer_impl.{h,cc}` onto
//! `rhi` / `rhi.rpi`.
//!
//! The renderer owns every GPU object the samples need: the depth buffer, one
//! `rpi.Program` per shader pair (each with its own hash-keyed pipeline cache),
//! the generated checkered texture, a small static vertex buffer holding the
//! bone and joint models, and a growable, persistently-mapped geometry ring that
//! every immediate-mode draw sub-allocates from.
//!
//! Draw calls write straight into the mapped ring and record their draw
//! immediately, so nothing needs flushing and no upload barrier is required
//! inside the render pass. `endFrame` exists only to keep the boundary in
//! `API.md` stable.
//!
//! Everything under `--- geometry ---` is pure CPU geometry generation: it needs
//! no device and is unit-tested at the bottom of this file.

const std = @import("std");
const builtin = @import("builtin");
const rhi = @import("rhi");
const rpi = rhi.rpi;
const ozz = @import("zig_ozz_animation");

const color_mod = @import("color.zig");
const icosphere = @import("icosphere.zig");
const mesh_mod = @import("mesh.zig");

pub const Color = color_mod.Color;

const Float4x4 = ozz.math.Float4x4;
const Vec3f32 = ozz.math.Vec3f32;

/// Apple ships neither `rhi.Sampler.init` nor `Program.bindDescriptors`, and its
/// `Cmd.draw` drops `instance_count` / `first_instance`. Every degraded path is
/// gated on this.
const is_apple = builtin.os.tag == .macos or builtin.os.tag == .ios;

/// Instanced draws need `first_instance` + `instance_count`.
const supports_instancing = !is_apple;
/// Name-resolved descriptor sets (and therefore texturing) are Vulkan-only.
const supports_textures = !is_apple;

const depth_format: rhi.Format = .d32_sfloat;

/// Front-face winding. Upstream's geometry is counter-clockwise-front and stays
/// that way here.
///
/// The Y negation `camera.zig` puts in the projection does flip the sign of the
/// signed area Vulkan computes in framebuffer coordinates, which suggests the
/// winding should invert — but `rpi` lowers `front_counter_clockwise` to
/// `VkPipelineRasterizationStateCreateInfo.frontFace`, which is resolved against
/// the same flipped coordinates, so the two cancel.
///
/// Measured on an RX 7800 XT rather than derived: with `false`, the baked sample
/// (whose camera sits inside the cuboid drawn for its own joint) culls every
/// exterior face and shows only that cuboid's interior, filling the screen. With
/// `true` it renders the scene, and every other sample is unchanged.
const front_counter_clockwise = true;

/// Back-face culling, as upstream. This is not merely a fill-rate optimization:
/// the baked sample places the camera inside the cuboid drawn for the camera
/// joint, so without culling the cube's interior fills the whole screen.
/// Upstream disables culling only for the grid quad, which this renderer draws
/// through the immediate path with `.cull = .none`.
const default_cull: rpi.pipeline_desc.CullMode = .back;

/// Frames the geometry ring keeps a segment alive before reclaiming it. Must be
/// >= the application's frames-in-flight.
const ring_segments: u16 = 4;
const ring_initial_bytes: usize = 4 * 1024 * 1024;

/// `renderer.h`'s `Renderer::Options`.
pub const Options = struct {
    triangles: bool = true,
    texture: bool = false,
    vertices: bool = false,
    normals: bool = false,
    tangents: bool = false,
    binormals: bool = false,
    colors: bool = true,
    wireframe: bool = false,
    skip_skinning: bool = false,
};

// ---------------------------------------------------------------------------
// Vertex + push-constant layouts
//
// These mirror `renderer_impl.h`'s `VertexPC` / `VertexPNC` and the vertex
// stream declarations at the top of every `samples/shaders/*.slang` file.
//
// Upstream lays mesh attributes out *planar* (one contiguous block per
// attribute). This port interleaves them instead, because
// `rhi.Cmd.bind_vertex_buffer` always binds at byte offset 0 and only
// `first_vertex` can move the read cursor — which shifts every vertex-rate
// stream by the same element index. Interleaving is the one layout that
// survives that constraint.
// ---------------------------------------------------------------------------

/// `immediate.slang: vertexMain` — position + colour. 16 bytes.
pub const VertexPC = extern struct {
    pos: [3]f32,
    color: Color,
};

/// `ambient.slang` / `skeleton.slang` — position + normal + colour. 28 bytes.
pub const VertexPNC = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    color: Color,
};

/// `ambient_textured.slang` — `VertexPNC` plus a uv. 36 bytes. Used for every
/// mesh draw, textured or not; the untextured pipeline simply declares no
/// attribute at offset 28.
pub const VertexMesh = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    color: Color,
    uv: [2]f32,
};

/// `immediate.slang: vertexPoints`. 24 bytes.
pub const VertexPoint = extern struct {
    pos: [3]f32,
    color: Color,
    size: f32,
    screen_space: f32,
};

/// One per-instance "matrix": either a real model matrix (`ambient.slang`'s
/// `vertexMainInstanced`) or the packed posture payload of
/// `DrawPosture_FillUniforms` (`skeleton.slang`). 64 bytes.
pub const InstanceMatrix = extern struct {
    m: [16]f32,
};

/// `ambient.slang` / `ambient_textured.slang` / `skeleton.slang` push constants.
const AmbientPC = extern struct {
    view_proj: Float4x4,
    model: Float4x4,
};

/// `immediate.slang` push constants.
const ImmediatePC = extern struct {
    mvp: Float4x4,
};

comptime {
    std.debug.assert(@sizeOf(VertexPC) == 16);
    std.debug.assert(@sizeOf(VertexPNC) == 28);
    std.debug.assert(@sizeOf(VertexMesh) == 36);
    std.debug.assert(@sizeOf(VertexPoint) == 24);
    std.debug.assert(@sizeOf(InstanceMatrix) == 64);
    std.debug.assert(@sizeOf(AmbientPC) == 128);
    std.debug.assert(@sizeOf(ImmediatePC) == 64);
}

// ---------------------------------------------------------------------------
// --- geometry --------------------------------------------------------------
// Pure, device-free geometry generation. Everything here is exercised by the
// tests at the bottom of the file.
// ---------------------------------------------------------------------------

/// `InitPostureRendering`'s `kInter`: where the bone spike's waist sits along
/// its length, and the joint model's radius.
pub const bone_inter: f32 = 0.2;

/// The bone model is 24 vertices drawn as a triangle list.
pub const bone_vertex_count = 24;

/// The joint model is three circles walked as one 68-point line strip.
pub const joint_slices = 20;
pub const joint_points_per_circle = joint_slices + 1;
pub const joint_points_yz = joint_points_per_circle;
pub const joint_points_xy = joint_points_per_circle + joint_points_per_circle / 4;
pub const joint_points_xz = joint_points_per_circle;
pub const joint_vertex_count = joint_points_xy + joint_points_xz + joint_points_yz;

comptime {
    std.debug.assert(joint_vertex_count == 68);
}

fn v3sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn v3cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn v3normalize(a: [3]f32) [3]f32 {
    const len = @sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    if (len == 0) return .{ 0, 0, 0 };
    return .{ a[0] / len, a[1] / len, a[2] / len };
}

/// The 6 positions of the elongated octahedron: tip at `+X`, base at the origin,
/// waist at `x = kInter` (`renderer_impl.cc:286`).
pub const bone_positions = [6][3]f32{
    .{ 1, 0, 0 },
    .{ bone_inter, 0.1, 0.1 },
    .{ bone_inter, 0.1, -0.1 },
    .{ bone_inter, -0.1, -0.1 },
    .{ bone_inter, -0.1, 0.1 },
    .{ 0, 0, 0 },
};

/// The 8 face normals, transcribed operand-for-operand from
/// `renderer_impl.cc:292`. The `pos[a] - pos[b]` operand choices look odd but
/// are reproduced verbatim — they are what makes the shading match upstream.
pub fn boneNormals() [8][3]f32 {
    const p = bone_positions;
    return .{
        v3normalize(v3cross(v3sub(p[2], p[1]), v3sub(p[2], p[0]))),
        v3normalize(v3cross(v3sub(p[1], p[2]), v3sub(p[1], p[5]))),
        v3normalize(v3cross(v3sub(p[3], p[2]), v3sub(p[3], p[0]))),
        v3normalize(v3cross(v3sub(p[2], p[3]), v3sub(p[2], p[5]))),
        v3normalize(v3cross(v3sub(p[4], p[3]), v3sub(p[4], p[0]))),
        v3normalize(v3cross(v3sub(p[3], p[4]), v3sub(p[3], p[5]))),
        v3normalize(v3cross(v3sub(p[1], p[4]), v3sub(p[1], p[0]))),
        v3normalize(v3cross(v3sub(p[4], p[1]), v3sub(p[4], p[5]))),
    };
}

/// `(position index, normal index)` pairs for the 24 bone vertices, in the order
/// `renderer_impl.cc:302` writes them.
const bone_index_table = [bone_vertex_count][2]u8{
    .{ 0, 0 }, .{ 2, 0 }, .{ 1, 0 }, .{ 5, 1 }, .{ 1, 1 }, .{ 2, 1 },
    .{ 0, 2 }, .{ 3, 2 }, .{ 2, 2 }, .{ 5, 3 }, .{ 2, 3 }, .{ 3, 3 },
    .{ 0, 4 }, .{ 4, 4 }, .{ 3, 4 }, .{ 5, 5 }, .{ 3, 5 }, .{ 4, 5 },
    .{ 0, 6 }, .{ 1, 6 }, .{ 4, 6 }, .{ 5, 7 }, .{ 4, 7 }, .{ 1, 7 },
};

/// The bone model: 24 white `VertexPNC`, drawn as a triangle list.
pub fn boneVertices() [bone_vertex_count]VertexPNC {
    const normals = boneNormals();
    var out: [bone_vertex_count]VertexPNC = undefined;
    for (bone_index_table, 0..) |entry, i| {
        out[i] = .{
            .pos = bone_positions[entry[0]],
            .normal = normals[entry[1]],
            .color = color_mod.white,
        };
    }
    return out;
}

/// The joint model: three circles (YZ red, XY blue, XZ green) emitted as one
/// 68-point line strip. The XY circle carries 5 extra points, which is the walk
/// from the end of one circle to the start of the next (`renderer_impl.cc:331`).
pub fn jointVertices() [joint_vertex_count]VertexPNC {
    const radius = bone_inter;
    const two_pi: f32 = std.math.tau;
    var out: [joint_vertex_count]VertexPNC = undefined;
    var index: usize = 0;

    const yz_color = Color.fromFloats(.{ 1, 0.3, 0.3, 1 });
    for (0..joint_points_yz) |j| {
        const angle: f32 = @as(f32, @floatFromInt(j)) * two_pi / joint_slices;
        const s = @sin(angle);
        const c = @cos(angle);
        out[index] = .{
            .pos = .{ 0, c * radius, s * radius },
            .normal = .{ 0, c, s },
            .color = yz_color,
        };
        index += 1;
    }

    const xy_color = Color.fromFloats(.{ 0.3, 0.3, 1, 1 });
    for (0..joint_points_xy) |j| {
        const angle: f32 = @as(f32, @floatFromInt(j)) * two_pi / joint_slices;
        const s = @sin(angle);
        const c = @cos(angle);
        out[index] = .{
            .pos = .{ s * radius, c * radius, 0 },
            .normal = .{ s, c, 0 },
            .color = xy_color,
        };
        index += 1;
    }

    const xz_color = Color.fromFloats(.{ 0.3, 1, 0.3, 1 });
    for (0..joint_points_xz) |j| {
        const angle: f32 = @as(f32, @floatFromInt(j)) * two_pi / joint_slices;
        const s = @sin(angle);
        const c = @cos(angle);
        out[index] = .{
            .pos = .{ c * radius, 0, -s * radius },
            .normal = .{ c, 0, -s },
            .color = xz_color,
        };
        index += 1;
    }

    std.debug.assert(index == joint_vertex_count);
    return out;
}

/// Upper bound on the instances `fillPostureInstances` can emit: one per
/// non-root joint plus one more per leaf.
pub fn maxPostureInstances(joint_count: usize) usize {
    return joint_count * 2;
}

/// Port of `DrawPosture_FillUniforms` (`renderer_impl.cc:451`).
///
/// Each instance is a 16-float block that is *not* a plain matrix: columns 0..2
/// hold the parent's basis and column 3 its translation, while the normally-zero
/// fourth row is repurposed — floats `[3]`, `[7]`, `[11]` carry the bone
/// direction (child translation minus parent translation) and `[15]` is the
/// is-bone flag. Leaves emit a second instance anchored on the joint itself with
/// the flag cleared, which collapses the bone and leaves only the joint circles.
///
/// Returns the number of instances written. `out` should hold at least
/// `maxPostureInstances(skeleton.numJoints())` entries; a shorter buffer simply
/// truncates.
pub fn fillPostureInstances(
    skeleton: ozz.animation.Skeleton,
    matrices: []const Float4x4,
    out: []InstanceMatrix,
) usize {
    var count: usize = 0;
    const joint_count = @min(skeleton.numJoints(), matrices.len);
    for (0..joint_count) |i| {
        const parent_id = skeleton.parents[i];
        if (parent_id == ozz.animation.no_parent) continue;
        const parent_index: usize = @intCast(parent_id);
        if (parent_index >= matrices.len) continue;
        if (count == out.len) break;

        const parent = matrices[parent_index];
        const current = matrices[i];

        const bone_dir = [3]f32{
            current.cols[3][0] - parent.cols[3][0],
            current.cols[3][1] - parent.cols[3][1],
            current.cols[3][2] - parent.cols[3][2],
        };

        out[count] = .{ .m = flatten(parent) };
        out[count].m[3] = bone_dir[0];
        out[count].m[7] = bone_dir[1];
        out[count].m[11] = bone_dir[2];
        out[count].m[15] = 1.0;
        count += 1;

        if (ozz.animation.isLeaf(skeleton, i)) {
            if (count == out.len) break;
            out[count] = .{ .m = flatten(current) };
            out[count].m[3] = bone_dir[0];
            out[count].m[7] = bone_dir[1];
            out[count].m[11] = bone_dir[2];
            out[count].m[15] = 0.0;
            count += 1;
        }
    }
    return count;
}

fn flatten(m: Float4x4) [16]f32 {
    return @bitCast(m.cols);
}

/// `DrawAxes` (`renderer_impl.cc:153`): three unit segments from the origin,
/// `+X` red, `+Y` green, `+Z` blue.
pub fn axesVertices() [6]VertexPC {
    return .{
        .{ .pos = .{ 0, 0, 0 }, .color = color_mod.red },
        .{ .pos = .{ 1, 0, 0 }, .color = color_mod.red },
        .{ .pos = .{ 0, 0, 0 }, .color = color_mod.green },
        .{ .pos = .{ 0, 1, 0 }, .color = color_mod.green },
        .{ .pos = .{ 0, 0, 0 }, .color = color_mod.blue },
        .{ .pos = .{ 0, 0, 1 }, .color = color_mod.blue },
    };
}

pub const grid_fill_color = Color.fromFloats(.{ 0.5, 0.75, 0.8, 0.7 });
pub const grid_line_color = Color.fromFloats(.{ 0.32, 0.33, 0.30, 1.0 });

/// The translucent ground quad of `DrawGrid`, as a 4-vertex triangle strip.
pub fn gridQuadVertices(cell_count: u32, cell_size: f32) [4]VertexPC {
    const extent = @as(f32, @floatFromInt(cell_count)) * cell_size;
    const half = extent * 0.5;
    const cx = -half;
    const cy: f32 = 0;
    const cz = -half;
    return .{
        .{ .pos = .{ cx, cy, cz }, .color = grid_fill_color },
        .{ .pos = .{ cx, cy, cz + extent }, .color = grid_fill_color },
        .{ .pos = .{ cx + extent, cy, cz }, .color = grid_fill_color },
        .{ .pos = .{ cx + extent, cy, cz + extent }, .color = grid_fill_color },
    };
}

/// Vertex count of `fillGridLines`: `cell_count + 1` lines along X plus the same
/// along Z, two vertices each.
pub fn gridLineVertexCount(cell_count: u32) usize {
    return 4 * (@as(usize, cell_count) + 1);
}

/// The grid's line list. `out` must hold `gridLineVertexCount(cell_count)`
/// vertices. Returns the number written.
pub fn fillGridLines(cell_count: u32, cell_size: f32, out: []VertexPC) usize {
    const extent = @as(f32, @floatFromInt(cell_count)) * cell_size;
    const half = extent * 0.5;
    const corner = [3]f32{ -half, 0, -half };

    var n: usize = 0;
    // Lines along X, stepping Z.
    var begin = VertexPC{ .pos = corner, .color = grid_line_color };
    var end = begin;
    end.pos[0] += extent;
    for (0..cell_count + 1) |_| {
        out[n] = begin;
        out[n + 1] = end;
        n += 2;
        begin.pos[2] += cell_size;
        end.pos[2] += cell_size;
    }
    // Lines along Z, stepping X.
    begin = .{ .pos = corner, .color = grid_line_color };
    end = begin;
    end.pos[2] += extent;
    for (0..cell_count + 1) |_| {
        out[n] = begin;
        out[n + 1] = end;
        n += 2;
        begin.pos[0] += cell_size;
        end.pos[0] += cell_size;
    }
    return n;
}

/// `DrawBoxIm`'s wireframe (`renderer_impl.cc:696`): 12 edges as 24 line-list
/// vertices — the `z = min` face, then the `z = max` face, then the 4 links.
pub fn boxWireframeVertices(box: ozz.math.Box, col: Color) [24]VertexPC {
    const lo = box.min;
    const hi = box.max;
    var out: [24]VertexPC = undefined;
    var n: usize = 0;
    var v = VertexPC{ .pos = .{ 0, 0, 0 }, .color = col };

    // First face (z = min).
    v.pos = .{ lo[0], lo[1], lo[2] };
    out[n] = v;
    n += 1;
    v.pos[1] = hi[1];
    out[n] = v;
    out[n + 1] = v;
    n += 2;
    v.pos[0] = hi[0];
    out[n] = v;
    out[n + 1] = v;
    n += 2;
    v.pos[1] = lo[1];
    out[n] = v;
    out[n + 1] = v;
    n += 2;
    v.pos[0] = lo[0];
    out[n] = v;
    n += 1;

    // Second face (z = max).
    v.pos[2] = hi[2];
    out[n] = v;
    n += 1;
    v.pos[1] = hi[1];
    out[n] = v;
    out[n + 1] = v;
    n += 2;
    v.pos[0] = hi[0];
    out[n] = v;
    out[n + 1] = v;
    n += 2;
    v.pos[1] = lo[1];
    out[n] = v;
    out[n + 1] = v;
    n += 2;
    v.pos[0] = lo[0];
    out[n] = v;
    n += 1;

    // Link the two faces.
    out[n] = v;
    n += 1;
    v.pos[2] = lo[2];
    out[n] = v;
    n += 1;
    v.pos[1] = hi[1];
    out[n] = v;
    n += 1;
    v.pos[2] = hi[2];
    out[n] = v;
    n += 1;
    v.pos[0] = hi[0];
    out[n] = v;
    n += 1;
    v.pos[2] = lo[2];
    out[n] = v;
    n += 1;
    v.pos[1] = lo[1];
    out[n] = v;
    n += 1;
    v.pos[2] = hi[2];
    out[n] = v;
    n += 1;

    std.debug.assert(n == 24);
    return out;
}

/// `DrawBoxShaded`'s 36 `VertexPNC` (`renderer_impl.cc:811`): 8 corners, 6 axis
/// normals, 12 triangles, with the exact winding upstream uses.
pub fn boxShadedVertices(box: ozz.math.Box, col: Color) [36]VertexPNC {
    const lo = box.min;
    const hi = box.max;
    const pos = [8][3]f32{
        .{ lo[0], lo[1], lo[2] },
        .{ hi[0], lo[1], lo[2] },
        .{ hi[0], hi[1], lo[2] },
        .{ lo[0], hi[1], lo[2] },
        .{ lo[0], lo[1], hi[2] },
        .{ hi[0], lo[1], hi[2] },
        .{ hi[0], hi[1], hi[2] },
        .{ lo[0], hi[1], hi[2] },
    };
    const normals = box_shaded_normals;
    const table = [36][2]u8{
        .{ 0, 4 }, .{ 3, 4 }, .{ 1, 4 }, .{ 3, 4 }, .{ 2, 4 }, .{ 1, 4 },
        .{ 2, 3 }, .{ 3, 3 }, .{ 7, 3 }, .{ 7, 3 }, .{ 6, 3 }, .{ 2, 3 },
        .{ 5, 5 }, .{ 6, 5 }, .{ 7, 5 }, .{ 5, 5 }, .{ 7, 5 }, .{ 4, 5 },
        .{ 0, 2 }, .{ 1, 2 }, .{ 4, 2 }, .{ 4, 2 }, .{ 1, 2 }, .{ 5, 2 },
        .{ 0, 0 }, .{ 4, 0 }, .{ 3, 0 }, .{ 4, 0 }, .{ 7, 0 }, .{ 3, 0 },
        .{ 5, 1 }, .{ 1, 1 }, .{ 2, 1 }, .{ 5, 1 }, .{ 2, 1 }, .{ 6, 1 },
    };
    var out: [36]VertexPNC = undefined;
    for (table, 0..) |entry, i| {
        out[i] = .{
            .pos = pos[entry[0]],
            .normal = normals[entry[1]],
            .color = col,
        };
    }
    return out;
}

const box_shaded_normals = [6][3]f32{
    .{ -1, 0, 0 }, .{ 1, 0, 0 },  .{ 0, -1, 0 },
    .{ 0, 1, 0 },  .{ 0, 0, -1 }, .{ 0, 0, 1 },
};

/// Index count `expandWireframeIndices` produces: two indices per triangle edge.
pub fn wireframeIndexCount(triangle_index_count: usize) usize {
    return (triangle_index_count / 3) * 6;
}

/// `rhi` exposes no `polygon_mode = .line`, so the `wireframe` render option is
/// emulated by turning each triangle into its three edges on the CPU. Returns
/// the number of indices written.
pub fn expandWireframeIndices(triangles: []const u16, out: []u16) usize {
    var n: usize = 0;
    var t: usize = 0;
    while (t + 3 <= triangles.len) : (t += 3) {
        if (n + 6 > out.len) break;
        const a = triangles[t];
        const b = triangles[t + 1];
        const c = triangles[t + 2];
        out[n + 0] = a;
        out[n + 1] = b;
        out[n + 2] = b;
        out[n + 3] = c;
        out[n + 4] = c;
        out[n + 5] = a;
        n += 6;
    }
    return n;
}

/// `ozz::math::Scale(matrix, (s, s, s, 1))` — columns 0..2 scaled, translation
/// left alone. Used by both sphere draws.
pub fn scaleUniform(m: Float4x4, s: f32) Float4x4 {
    var out = m;
    for (0..3) |c| {
        for (0..4) |r| out.cols[c][r] = m.cols[c][r] * s;
    }
    return out;
}

/// `InitCheckeredTexture` (`renderer_impl.cc:388`), widened from RGB to RGBA
/// because `r8g8b8_unorm` is not a portable sampled format. Writes
/// `level_width * level_width * 4` bytes.
pub fn fillCheckeredLevel(level_width: u32, out: []u8) void {
    const cases: usize = 64;
    const width: usize = level_width;
    if (width >= cases) {
        const case_width = width / cases;
        for (0..width) |j| {
            const cpntj = (j / case_width) & 1;
            for (0..cases) |i| {
                const cpnti = i & 1;
                const white_case = (cpnti ^ cpntj) != 0;
                const r: u8 = if (white_case) 0xff else @truncate(j * 255 / width);
                const g: u8 = if (white_case) 0xff else @truncate(i * 255 / cases);
                const b: u8 = if (white_case) 0xff else 0;
                const case_start = j * width + i * case_width;
                for (case_start..case_start + case_width) |k| {
                    out[k * 4 + 0] = r;
                    out[k * 4 + 1] = g;
                    out[k * 4 + 2] = b;
                    out[k * 4 + 3] = 0xff;
                }
            }
        }
    } else {
        // Mip levels narrower than the case count collapse to flat grey.
        for (0..width * width) |k| {
            out[k * 4 + 0] = 0x7f;
            out[k * 4 + 1] = 0x7f;
            out[k * 4 + 2] = 0x7f;
            out[k * 4 + 3] = 0xff;
        }
    }
}

// ---------------------------------------------------------------------------
// Vertex layouts fed to `rpi.GraphicsPipelineDesc`
// ---------------------------------------------------------------------------

const VertexLayout = enum(u8) {
    /// position + colour (`immediate.slang: vertexMain`).
    pc,
    /// position + colour + size + screen-space flag (`vertexPoints`).
    point,
    /// position + normal + colour (`ambient.slang: vertexMain`).
    pnc,
    /// `pnc` plus a per-instance 4x4 (`vertexMainInstanced`, `vertexBone`,
    /// `vertexJoint`).
    pnc_instanced,
    /// Interleaved mesh vertex, uv attribute omitted.
    mesh,
    /// Interleaved mesh vertex including the uv (`ambient_textured.slang`).
    mesh_uv,
};

const attrs_pc = [_]rpi.pipeline_desc.VertexAttribute{
    .{ .location = 0, .binding = 0, .format = .rgb32_sfloat, .offset = 0 },
    .{ .location = 1, .binding = 0, .format = .rgba8_unorm, .offset = 12 },
};
const streams_pc = [_]rpi.pipeline_desc.VertexStream{
    .{ .binding = 0, .stride = @sizeOf(VertexPC) },
};

const attrs_point = [_]rpi.pipeline_desc.VertexAttribute{
    .{ .location = 0, .binding = 0, .format = .rgb32_sfloat, .offset = 0 },
    .{ .location = 1, .binding = 0, .format = .rgba8_unorm, .offset = 12 },
    .{ .location = 2, .binding = 0, .format = .r32_sfloat, .offset = 16 },
    .{ .location = 3, .binding = 0, .format = .r32_sfloat, .offset = 20 },
};
const streams_point = [_]rpi.pipeline_desc.VertexStream{
    .{ .binding = 0, .stride = @sizeOf(VertexPoint) },
};

const attrs_pnc = [_]rpi.pipeline_desc.VertexAttribute{
    .{ .location = 0, .binding = 0, .format = .rgb32_sfloat, .offset = 0 },
    .{ .location = 1, .binding = 0, .format = .rgb32_sfloat, .offset = 12 },
    .{ .location = 2, .binding = 0, .format = .rgba8_unorm, .offset = 24 },
};
const streams_pnc = [_]rpi.pipeline_desc.VertexStream{
    .{ .binding = 0, .stride = @sizeOf(VertexPNC) },
};

const attrs_pnc_instanced = attrs_pnc ++ [_]rpi.pipeline_desc.VertexAttribute{
    .{ .location = 3, .binding = 1, .format = .rgba32_sfloat, .offset = 0 },
    .{ .location = 4, .binding = 1, .format = .rgba32_sfloat, .offset = 16 },
    .{ .location = 5, .binding = 1, .format = .rgba32_sfloat, .offset = 32 },
    .{ .location = 6, .binding = 1, .format = .rgba32_sfloat, .offset = 48 },
};
const streams_pnc_instanced = [_]rpi.pipeline_desc.VertexStream{
    .{ .binding = 0, .stride = @sizeOf(VertexPNC) },
    .{ .binding = 1, .stride = @sizeOf(InstanceMatrix), .per_instance = true },
};

const attrs_mesh = [_]rpi.pipeline_desc.VertexAttribute{
    .{ .location = 0, .binding = 0, .format = .rgb32_sfloat, .offset = 0 },
    .{ .location = 1, .binding = 0, .format = .rgb32_sfloat, .offset = 12 },
    .{ .location = 2, .binding = 0, .format = .rgba8_unorm, .offset = 24 },
};
const attrs_mesh_uv = attrs_mesh ++ [_]rpi.pipeline_desc.VertexAttribute{
    .{ .location = 3, .binding = 0, .format = .rg32_sfloat, .offset = 28 },
};
const streams_mesh = [_]rpi.pipeline_desc.VertexStream{
    .{ .binding = 0, .stride = @sizeOf(VertexMesh) },
};

const LayoutDesc = struct {
    streams: []const rpi.pipeline_desc.VertexStream,
    attrs: []const rpi.pipeline_desc.VertexAttribute,
};

fn layoutDesc(layout: VertexLayout) LayoutDesc {
    return switch (layout) {
        .pc => .{ .streams = &streams_pc, .attrs = &attrs_pc },
        .point => .{ .streams = &streams_point, .attrs = &attrs_point },
        .pnc => .{ .streams = &streams_pnc, .attrs = &attrs_pnc },
        .pnc_instanced => .{ .streams = &streams_pnc_instanced, .attrs = &attrs_pnc_instanced },
        .mesh => .{ .streams = &streams_mesh, .attrs = &attrs_mesh },
        .mesh_uv => .{ .streams = &streams_mesh, .attrs = &attrs_mesh_uv },
    };
}

/// The subset of `GraphicsPipelineDesc` that varies between this renderer's
/// draws. Everything in here feeds the pipeline-cache key.
const PipeState = struct {
    layout: VertexLayout,
    topology: rpi.pipeline_desc.Topology = .triangle_list,
    blend: bool = false,
    depth_write: bool = true,
    cull: rpi.pipeline_desc.CullMode = default_cull,
};

// ---------------------------------------------------------------------------
// Programs
// ---------------------------------------------------------------------------

const ProgramId = enum(u8) {
    ambient,
    ambient_instanced,
    textured,
    bone,
    joint,
    immediate,
    points,

    const count = @typeInfo(ProgramId).@"enum".field_names.len;
};

// ---------------------------------------------------------------------------
// Geometry ring
// ---------------------------------------------------------------------------

/// A single persistently-mapped buffer, sub-allocated per frame through
/// `rhi.SegmentAlloc` and grown — with the old buffer retired for
/// `ring_segments` frames — whenever a draw does not fit.
///
/// The allocator's element is 4 bytes. `bind_vertex_buffer` can only bind at
/// offset 0, so every draw addresses its data through `first_vertex` /
/// `first_index` / `first_instance`, which means each sub-allocation must land
/// on a multiple of its own element stride. Requests therefore ask for enough
/// slack to align the returned byte offset upwards.
const Ring = struct {
    const Retired = struct { buffer: rhi.Buffer, frame: u64 };

    buffer: rhi.Buffer = .{},
    capacity: usize = 0,
    alloc: rhi.SegmentAlloc = undefined,
    retired: std.ArrayListUnmanaged(Retired) = .empty,

    fn init(device: *rhi.Device, capacity: usize) !Ring {
        return .{
            .buffer = try createRingBuffer(device, capacity),
            .capacity = capacity,
            .alloc = newSegmentAlloc(capacity),
        };
    }

    fn deinit(self: *Ring, allocator: std.mem.Allocator, device: *rhi.Device) void {
        for (self.retired.items) |*entry| entry.buffer.deinit(device);
        self.retired.deinit(allocator);
        if (!self.buffer.isEmpty()) self.buffer.deinit(device);
        self.* = .{};
    }

    fn newSegmentAlloc(capacity: usize) rhi.SegmentAlloc {
        return .init(.{
            .max_elements = @intCast(capacity / 4),
            .element_stride = 4,
            .num_segments = ring_segments,
        });
    }

    fn createRingBuffer(device: *rhi.Device, capacity: usize) !rhi.Buffer {
        return rhi.Buffer.init_general(device, .{
            .size = capacity,
            .persistant_map = true,
            .buffer_usage = .prefer_host,
            .usage = .{ .vertex_buffer = true, .index_buffer = true },
        });
    }

    /// Drop retired buffers the GPU can no longer be reading from.
    fn collect(self: *Ring, device: *rhi.Device, frame: u64) void {
        var i: usize = 0;
        while (i < self.retired.items.len) {
            if (frame >= self.retired.items[i].frame + ring_segments) {
                var entry = self.retired.swapRemove(i);
                entry.buffer.deinit(device);
            } else {
                i += 1;
            }
        }
    }

    fn grow(
        self: *Ring,
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        frame: u64,
        needed: usize,
    ) !void {
        var capacity = @max(self.capacity, ring_initial_bytes);
        while (capacity < needed) capacity *= 2;
        capacity *= 2;

        var buffer = try createRingBuffer(device, capacity);
        errdefer buffer.deinit(device);
        try self.retired.append(allocator, .{ .buffer = self.buffer, .frame = frame });
        self.buffer = buffer;
        self.capacity = capacity;
        self.alloc = newSegmentAlloc(capacity);
    }

    const Region = struct { offset: usize, bytes: []u8 };

    /// Sub-allocate `size` bytes starting on a multiple of `alignment` (itself a
    /// non-zero multiple of 4).
    fn allocBytes(
        self: *Ring,
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        frame: u64,
        size: usize,
        alignment: usize,
    ) !Region {
        std.debug.assert(alignment != 0 and alignment % 4 == 0);
        const slack = alignment / 4 - 1;
        const elements = (size + 3) / 4 + slack;

        var attempts: usize = 0;
        while (true) : (attempts += 1) {
            if (self.alloc.alloc(frame, elements)) |req| {
                // Round up manually: `alignment` is the vertex stride, which is a
                // multiple of 4 but not necessarily a power of two (VertexPNC is 28
                // bytes, VertexMesh 36), so `std.mem.alignForward` would assert.
                // The offset must stay a multiple of the stride because callers
                // divide it to derive `first_vertex`.
                const raw = @as(usize, req.element_offset) * 4;
                const offset = ((raw + alignment - 1) / alignment) * alignment;
                const region = self.buffer.mapped_region orelse return error.BufferNotMapped;
                return .{ .offset = offset, .bytes = region[offset .. offset + size] };
            }
            if (attempts >= 2) return error.OutOfGeometryRing;
            try self.grow(allocator, device, frame, elements * 4);
        }
    }
};

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

/// Static-buffer layout: the bone model, then the joint model.
const static_bone_first: u32 = 0;
const static_joint_first: u32 = bone_vertex_count;
const static_vertex_count = bone_vertex_count + joint_vertex_count;

const empty_image: rhi.Image = .{ .cookie = 0, .backend = undefined };
const empty_view: rhi.ImageView = .{ .backend = undefined, .cookie = 0 };

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    device: *rhi.Device,

    color_format: rhi.Format = .rgba8_unorm,
    width: u32 = 0,
    height: u32 = 0,

    depth_image: rhi.Image = empty_image,
    depth_view: rhi.ImageView = empty_view,

    programs: [ProgramId.count]rpi.Program = undefined,
    program_count: usize = 0,

    /// The generated checkered texture. Null when the backend cannot bind
    /// descriptor sets or create a sampler (Metal), in which case
    /// `Options.texture` degrades to the plain ambient shader.
    checkered_image: ?rhi.Image = null,
    checkered_view: ?rhi.ImageView = null,
    checkered_sampler: ?rhi.Sampler = null,

    /// Bone + joint models, uploaded once.
    static_vb: rhi.Buffer = .{},

    ring: Ring = .{},

    // Latched per-frame state (see `beginFrame`).
    cmd: ?*rhi.Cmd = null,
    frame_index: u64 = 0,
    view_proj: Float4x4 = .identity,

    // CPU scratch, reused across frames.
    scratch: std.ArrayListUnmanaged(u8) = .empty,
    matrices: std.ArrayListUnmanaged(Float4x4) = .empty,
    instances: std.ArrayListUnmanaged(InstanceMatrix) = .empty,

    // -- Lifecycle ----------------------------------------------------------

    pub fn init(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        swapchain: *rhi.Swapchain,
    ) !Renderer {
        var self = Renderer{ .allocator = allocator, .device = device };
        self.color_format = swapchainColorFormat(swapchain);
        errdefer self.deinit(device);

        try self.createDepth(device, swapchain);
        try self.createPrograms(device);
        try self.createStaticGeometry(device);
        self.ring = try Ring.init(device, ring_initial_bytes);
        try self.createCheckeredTexture(device);

        return self;
    }

    pub fn deinit(self: *Renderer, device: *rhi.Device) void {
        self.scratch.deinit(self.allocator);
        self.matrices.deinit(self.allocator);
        self.instances.deinit(self.allocator);

        self.ring.deinit(self.allocator, device);
        if (!self.static_vb.isEmpty()) self.static_vb.deinit(device);

        if (self.checkered_sampler) |*sampler| sampler.deinit(device);
        if (self.checkered_view) |*view| view.deinit(device);
        if (self.checkered_image) |*image| image.deinit(device);
        self.checkered_sampler = null;
        self.checkered_view = null;
        self.checkered_image = null;

        for (self.programs[0..self.program_count]) |*prog| prog.deinit(device);
        self.program_count = 0;

        self.destroyDepth(device);
    }

    /// Recreate the size-dependent resources. Call after the application has
    /// replaced the swapchain.
    pub fn resize(self: *Renderer, device: *rhi.Device, swapchain: *rhi.Swapchain) !void {
        self.destroyDepth(device);
        self.color_format = swapchainColorFormat(swapchain);
        try self.createDepth(device, swapchain);
    }

    fn createDepth(self: *Renderer, device: *rhi.Device, swapchain: *rhi.Swapchain) !void {
        self.width = @max(1, @as(u32, swapchain.width));
        self.height = @max(1, @as(u32, swapchain.height));
        self.depth_image = try rhi.Image.init(device, .{
            .format = depth_format,
            .width = self.width,
            .height = self.height,
            .usage = .{ .depth_stencil_attachment = true },
            .memory_usage = .prefer_device,
        });
        errdefer self.depth_image.deinit(device);
        self.depth_view = try rhi.ImageView.init(device, &self.depth_image, .{
            .view_type = .depth_stencil_attachment,
            .format = depth_format,
            .aspect = .depth,
        });
    }

    fn destroyDepth(self: *Renderer, device: *rhi.Device) void {
        if (!self.depth_view.isEmpty()) {
            self.depth_view.deinit(device);
            self.depth_view = empty_view;
        }
        if (!self.depth_image.isEmpty()) {
            self.depth_image.deinit(device);
            self.depth_image = empty_image;
        }
    }

    /// The depth attachment the application must hand to `cmd.begin_rendering`.
    pub fn depthAttachment(self: *Renderer) rhi.Cmd.DepthAttachment {
        return .{
            .view = self.depth_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_depth = 1.0,
        };
    }

    /// The depth image the application must barrier to `.depth_write` with
    /// `.aspect = .depth` before `begin_rendering`.
    pub fn depthImage(self: *Renderer) *rhi.Image {
        return &self.depth_image;
    }

    /// Latch the frame state. Called after `cmd.begin` and before
    /// `begin_rendering`.
    pub fn beginFrame(
        self: *Renderer,
        device: *rhi.Device,
        cmd: *rhi.Cmd,
        frame_index: u32,
        view_proj: Float4x4,
    ) void {
        self.device = device;
        self.cmd = cmd;
        self.frame_index = frame_index;
        self.view_proj = view_proj;
        self.ring.collect(device, self.frame_index);
    }

    /// Flush anything still buffered. Draws record immediately, so this only
    /// drops the latched command buffer.
    pub fn endFrame(self: *Renderer) !void {
        self.cmd = null;
    }

    fn getProgram(self: *Renderer, id: ProgramId) *rpi.Program {
        return &self.programs[@intFromEnum(id)];
    }

    // -- Program + resource creation ----------------------------------------

    fn addProgram(
        self: *Renderer,
        device: *rhi.Device,
        id: ProgramId,
        modules: []const rpi.ModuleStage,
        layout: rpi.Layout,
    ) !void {
        std.debug.assert(@intFromEnum(id) == self.program_count);
        self.programs[@intFromEnum(id)] =
            try rpi.Program.initialize(self.allocator, device, modules, layout);
        self.program_count += 1;
    }

    fn createPrograms(self: *Renderer, device: *rhi.Device) !void {
        // SPIR-V must be word-aligned; `@embedFile` alone only guarantees byte
        // alignment, so each blob is re-declared through an `align(4)` copy. The
        // embeds live inside this function so `renderer.zig` still parses in
        // builds that wire no shader modules (the headless framework tests).
        const spv = struct {
            const ambient_vs align(4) = @embedFile("shader_ambient_vs").*;
            const ambient_instanced_vs align(4) = @embedFile("shader_ambient_instanced_vs").*;
            const ambient_fs align(4) = @embedFile("shader_ambient_fs").*;
            const textured_vs align(4) = @embedFile("shader_textured_vs").*;
            const textured_fs align(4) = @embedFile("shader_textured_fs").*;
            const bone_vs align(4) = @embedFile("shader_bone_vs").*;
            const joint_vs align(4) = @embedFile("shader_joint_vs").*;
            const skeleton_fs align(4) = @embedFile("shader_skeleton_fs").*;
            const immediate_vs align(4) = @embedFile("shader_immediate_vs").*;
            const points_vs align(4) = @embedFile("shader_points_vs").*;
            const immediate_fs align(4) = @embedFile("shader_immediate_fs").*;
        };

        const ambient_pc: rpi.PushConstantRange = .{
            .stages = .{ .vertex = true },
            .size = @sizeOf(AmbientPC),
        };
        const immediate_pc: rpi.PushConstantRange = .{
            .stages = .{ .vertex = true },
            .size = @sizeOf(ImmediatePC),
        };

        try self.addProgram(device, .ambient, &.{
            .{ .stage = .vertex, .data = &spv.ambient_vs, .entry_point = entryPoint("vertexMain") },
            .{ .stage = .fragment, .data = &spv.ambient_fs, .entry_point = entryPoint("fragmentMain") },
        }, .{ .push_constant = ambient_pc });

        try self.addProgram(device, .ambient_instanced, &.{
            .{ .stage = .vertex, .data = &spv.ambient_instanced_vs, .entry_point = entryPoint("vertexMainInstanced") },
            .{ .stage = .fragment, .data = &spv.ambient_fs, .entry_point = entryPoint("fragmentMain") },
        }, .{ .push_constant = ambient_pc });

        try self.addProgram(device, .textured, &.{
            .{ .stage = .vertex, .data = &spv.textured_vs, .entry_point = entryPoint("vertexMain") },
            .{ .stage = .fragment, .data = &spv.textured_fs, .entry_point = entryPoint("fragmentMain") },
        }, .{
            .bindings = &.{
                .{ .name = "u_texture", .set = 0, .binding = 0, .descriptor_type = .sampled_image, .stages = .{ .fragment = true } },
                .{ .name = "u_sampler", .set = 0, .binding = 1, .descriptor_type = .sampler, .stages = .{ .fragment = true } },
            },
            .push_constant = ambient_pc,
        });

        try self.addProgram(device, .bone, &.{
            .{ .stage = .vertex, .data = &spv.bone_vs, .entry_point = entryPoint("vertexBone") },
            .{ .stage = .fragment, .data = &spv.skeleton_fs, .entry_point = entryPoint("fragmentMain") },
        }, .{ .push_constant = ambient_pc });

        try self.addProgram(device, .joint, &.{
            .{ .stage = .vertex, .data = &spv.joint_vs, .entry_point = entryPoint("vertexJoint") },
            .{ .stage = .fragment, .data = &spv.skeleton_fs, .entry_point = entryPoint("fragmentMain") },
        }, .{ .push_constant = ambient_pc });

        try self.addProgram(device, .immediate, &.{
            .{ .stage = .vertex, .data = &spv.immediate_vs, .entry_point = entryPoint("vertexMain") },
            .{ .stage = .fragment, .data = &spv.immediate_fs, .entry_point = entryPoint("fragmentMain") },
        }, .{ .push_constant = immediate_pc });

        try self.addProgram(device, .points, &.{
            .{ .stage = .vertex, .data = &spv.points_vs, .entry_point = entryPoint("vertexPoints") },
            .{ .stage = .fragment, .data = &spv.immediate_fs, .entry_point = entryPoint("fragmentMain") },
        }, .{ .push_constant = immediate_pc });
    }

    fn createStaticGeometry(self: *Renderer, device: *rhi.Device) !void {
        const size = static_vertex_count * @sizeOf(VertexPNC);
        self.static_vb = try rhi.Buffer.init_general(device, .{
            .size = size,
            .persistant_map = true,
            .buffer_usage = .prefer_host,
            .usage = .{ .vertex_buffer = true },
        });
        const map = self.static_vb.mapped_region orelse return error.BufferNotMapped;
        const bones = boneVertices();
        const joints = jointVertices();
        const bones_bytes = std.mem.asBytes(&bones);
        const joints_bytes = std.mem.asBytes(&joints);
        @memcpy(map[0..bones_bytes.len], bones_bytes);
        @memcpy(map[bones_bytes.len..][0..joints_bytes.len], joints_bytes);
    }

    /// Build the 1024x1024 checkered texture with a full hand-generated mip
    /// pyramid and upload it through a one-shot blocking submission — the same
    /// staging blit `rhi/src/imgui.zig` uses, because `ResourceLoader` does not
    /// compile in this rev.
    fn createCheckeredTexture(self: *Renderer, device: *rhi.Device) !void {
        // Vulkan-only: gated at comptime so the `submit(.{ .vk = ... })` payload
        // below is never analyzed on a backend where that field is `void`.
        if (comptime supports_textures and rhi.platform_has_api(.vk)) {
            if (!rhi.is_target_selected(.vk)) return;

            const base_width: u32 = 1024;
            const mip_levels = std.math.log2_int(u32, base_width) + 1;

            var total: usize = 0;
            var offsets: [16]usize = @splat(0);
            for (0..mip_levels) |level| {
                offsets[level] = total;
                const w = base_width >> @intCast(level);
                total += @as(usize, w) * @as(usize, w) * 4;
            }

            var staging = try rhi.Buffer.init_general(device, .{
                .size = total,
                .persistant_map = true,
                .sequential_access = true,
                .buffer_usage = .prefer_host,
                .usage = .{ .transfer_src = true },
            });
            defer staging.deinit(device);
            const map = staging.mapped_region orelse return error.BufferNotMapped;

            for (0..mip_levels) |level| {
                const w = base_width >> @intCast(level);
                const bytes = @as(usize, w) * @as(usize, w) * 4;
                fillCheckeredLevel(w, map[offsets[level]..][0..bytes]);
            }

            var image = try rhi.Image.init(device, .{
                .format = .rgba8_unorm,
                .width = base_width,
                .height = base_width,
                .mip_levels = mip_levels,
                .usage = .{ .sampled = true, .transfer_dst = true },
                .memory_usage = .prefer_device,
            });
            errdefer image.deinit(device);

            var pool = try rhi.Pool.init(device, &device.graphics_queue);
            defer pool.deinit(device);
            var cmd = try rhi.Cmd.init(device, &pool);
            defer cmd.deinit(device, &pool);

            try cmd.begin(device);
            cmd.image_barrier(device, .{
                .image = &image,
                .before = .{},
                .after = .{ .copy_dst = true },
            });
            for (0..mip_levels) |level| {
                const w = base_width >> @intCast(level);
                cmd.copy_buffer_to_texture(device, .{
                    .src = &staging,
                    .dst = &image,
                    .buffer_offset = offsets[level],
                    .mip_level = @intCast(level),
                    .width = w,
                    .height = w,
                });
            }
            cmd.image_barrier(device, .{
                .image = &image,
                .before = .{ .copy_dst = true },
                .after = .{ .shader_resource = true },
            });
            try cmd.end(device);
            try device.graphics_queue.submit(device, .{ .vk = .{ .cmds = &.{&cmd} } });
            try device.graphics_queue.wait_queue_idle(device);

            var view = try rhi.ImageView.init(device, &image, .{
                .view_type = .shader_resource_2d,
                .format = .rgba8_unorm,
                .mip_num = mip_levels,
            });
            errdefer view.deinit(device);

            // A sampler failure only disables texturing; it must not fail init.
            const sampler = rhi.Sampler.init(device, .{
                .min_filter = .linear,
                .mag_filter = .linear,
                .mip_map_mode = .linear,
                .address_u = .repeat,
                .address_v = .repeat,
                .address_w = .repeat,
                .mip_lod_bias = 0,
                .set_lod_range = false,
                .min_lod = 0,
                .max_lod = 0,
                .max_anisotropy = 1,
                .compare_func = .never,
            }) catch {
                view.deinit(device);
                image.deinit(device);
                return;
            };

            self.checkered_image = image;
            self.checkered_view = view;
            self.checkered_sampler = sampler;
        }
    }

    fn texturingAvailable(self: *Renderer) bool {
        return supports_textures and self.checkered_view != null and self.checkered_sampler != null;
    }

    // -- Pipeline binding ---------------------------------------------------

    fn bindPipe(
        self: *Renderer,
        cmd: *rhi.Cmd,
        prog: *rpi.Program,
        name: [*:0]const u8,
        state: PipeState,
    ) !void {
        const layout = layoutDesc(state.layout);
        const colors = [_]rpi.pipeline_desc.ColorAttachment{.{
            .format = self.color_format,
            .blend_enabled = state.blend,
            .src_color = .src_alpha,
            .dst_color = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha = .one,
            .dst_alpha = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .write_mask = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        }};

        // The key must fully determine the descriptor: `bindPipeline` only
        // consults `desc` the first time a key is seen.
        var key: u64 = @intFromEnum(state.topology);
        key |= @as(u64, @intFromEnum(state.layout)) << 8;
        key |= @as(u64, @intFromEnum(state.cull)) << 16;
        key |= @as(u64, @intFromBool(state.blend)) << 24;
        key |= @as(u64, @intFromBool(state.depth_write)) << 25;
        key |= @as(u64, @intFromEnum(self.color_format)) << 32;

        try prog.bindPipeline(self.device, cmd, key, name, .{
            .topology = state.topology,
            .cull_mode = state.cull,
            .front_counter_clockwise = front_counter_clockwise,
            .depth_test_enable = true,
            .depth_write_enable = state.depth_write,
            .depth_compare_op = .less_equal,
            .depth_stencil_format = depth_format,
            .colors = &colors,
            .vertex_streams = layout.streams,
            .vertex_attributes = layout.attrs,
        });
    }

    // -- Ring helpers -------------------------------------------------------

    fn Allocation(comptime T: type) type {
        return struct { first: u32, items: []T };
    }

    /// Sub-allocate `count` `T`s from the ring. `first` is the value to pass as
    /// `first_vertex` / `first_instance`.
    fn allocTyped(self: *Renderer, comptime T: type, count: usize) !Allocation(T) {
        const region = try self.ring.allocBytes(
            self.allocator,
            self.device,
            self.frame_index,
            count * @sizeOf(T),
            @sizeOf(T),
        );
        return .{
            .first = @intCast(region.offset / @sizeOf(T)),
            .items = @alignCast(std.mem.bytesAsSlice(T, region.bytes)),
        };
    }

    fn allocIndices(self: *Renderer, count: usize) !Allocation(u16) {
        const region = try self.ring.allocBytes(
            self.allocator,
            self.device,
            self.frame_index,
            count * @sizeOf(u16),
            4,
        );
        return .{
            .first = @intCast(region.offset / @sizeOf(u16)),
            .items = @alignCast(std.mem.bytesAsSlice(u16, region.bytes)),
        };
    }

    // -- Immediate-mode primitives ------------------------------------------

    /// One `ImmediatePCShader` draw over `count` `VertexPC` already written into
    /// the ring at `first`.
    fn drawImmediate(
        self: *Renderer,
        cmd: *rhi.Cmd,
        topology: rpi.pipeline_desc.Topology,
        first: u32,
        count: usize,
        mvp: Float4x4,
        blend: bool,
        depth_write: bool,
    ) !void {
        const prog = self.getProgram(.immediate);
        try self.bindPipe(cmd, prog, "ozz.immediate", .{
            .layout = .pc,
            .topology = topology,
            .blend = blend,
            .depth_write = depth_write,
            // Immediate geometry is lines, points and the two-sided grid quad;
            // upstream draws all of it with culling off.
            .cull = .none,
        });
        const pc = ImmediatePC{ .mvp = mvp };
        prog.pushConstants(self.device, cmd, std.mem.asBytes(&pc), 0);
        cmd.bind_vertex_buffer(self.device, &self.ring.buffer, 0);
        cmd.draw(self.device, .{ .vertex_count = @intCast(count), .first_vertex = first });
    }

    /// Push `vertices` into the ring and draw them with the immediate shader.
    fn pushImmediate(
        self: *Renderer,
        topology: rpi.pipeline_desc.Topology,
        vertices: []const VertexPC,
        mvp: Float4x4,
        blend: bool,
        depth_write: bool,
    ) !void {
        const cmd = self.cmd orelse return;
        if (vertices.len == 0) return;
        const region = try self.allocTyped(VertexPC, vertices.len);
        @memcpy(region.items, vertices);
        try self.drawImmediate(cmd, topology, region.first, vertices.len, mvp, blend, depth_write);
    }

    // -- Public draw API ----------------------------------------------------

    /// `DrawAxes` — three unit segments from the transform's origin.
    pub fn drawAxes(self: *Renderer, transform: Float4x4) !void {
        const vertices = axesVertices();
        try self.pushImmediate(
            .line_list,
            &vertices,
            Float4x4.mul(self.view_proj, transform),
            false,
            true,
        );
    }

    /// `DrawGrid` — a translucent ground quad plus the cell lines. Neither pass
    /// writes depth (upstream brackets the whole function in
    /// `DepthMask(FALSE)`), and the quad disables culling.
    pub fn drawGrid(self: *Renderer, cell_count: u32, cell_size: f32) !void {
        const cmd = self.cmd orelse return;
        if (cell_count == 0) return;

        {
            const quad = gridQuadVertices(cell_count, cell_size);
            const region = try self.allocTyped(VertexPC, quad.len);
            @memcpy(region.items, &quad);
            const prog = self.getProgram(.immediate);
            try self.bindPipe(cmd, prog, "ozz.grid.quad", .{
                .layout = .pc,
                .topology = .triangle_strip,
                .blend = true,
                .depth_write = false,
                .cull = .none,
            });
            const pc = ImmediatePC{ .mvp = self.view_proj };
            prog.pushConstants(self.device, cmd, std.mem.asBytes(&pc), 0);
            cmd.bind_vertex_buffer(self.device, &self.ring.buffer, 0);
            cmd.draw(self.device, .{ .vertex_count = quad.len, .first_vertex = region.first });
        }

        {
            const count = gridLineVertexCount(cell_count);
            const region = try self.allocTyped(VertexPC, count);
            const written = fillGridLines(cell_count, cell_size, region.items);
            try self.drawImmediate(cmd, .line_list, region.first, written, self.view_proj, false, false);
        }
    }

    /// `DrawSkeleton` — resolve the rest pose to model space and forward to
    /// `drawPosture`.
    pub fn drawSkeleton(
        self: *Renderer,
        skeleton: ozz.animation.Skeleton,
        transform: Float4x4,
        draw_joints: bool,
    ) !void {
        const joint_count = skeleton.numJoints();
        if (joint_count == 0) return;
        try self.matrices.resize(self.allocator, joint_count);
        try ozz.animation.localToModel(.{
            .skeleton = &skeleton,
            .input = skeleton.rest_poses,
        }, self.matrices.items);
        try self.drawPosture(skeleton, self.matrices.items, transform, draw_joints);
    }

    /// `DrawPosture` — one bone (and optionally one joint) per non-root joint,
    /// packed by `fillPostureInstances` and fed to `skeleton.slang` as an
    /// instance stream. The bone and joint models are the same instance array
    /// drawn twice, exactly as upstream does.
    pub fn drawPosture(
        self: *Renderer,
        skeleton: ozz.animation.Skeleton,
        matrices: []const Float4x4,
        transform: Float4x4,
        draw_joints: bool,
    ) !void {
        const cmd = self.cmd orelse return;
        const joint_count = skeleton.numJoints();
        if (joint_count == 0 or matrices.len == 0) return;

        try self.instances.resize(self.allocator, maxPostureInstances(joint_count));
        const count = fillPostureInstances(skeleton, matrices, self.instances.items);
        if (count == 0) return;

        const region = try self.allocTyped(InstanceMatrix, count);
        @memcpy(region.items, self.instances.items[0..count]);

        const pc = AmbientPC{ .view_proj = self.view_proj, .model = transform };

        {
            const prog = self.getProgram(.bone);
            try self.bindPipe(cmd, prog, "ozz.bone", .{
                .layout = .pnc_instanced,
                .topology = .triangle_list,
                .cull = default_cull,
            });
            prog.pushConstants(self.device, cmd, std.mem.asBytes(&pc), 0);
            cmd.bind_vertex_buffer(self.device, &self.static_vb, 0);
            cmd.bind_vertex_buffer(self.device, &self.ring.buffer, 1);
            self.drawInstanced(cmd, bone_vertex_count, static_bone_first, @intCast(count), region.first);
        }

        if (draw_joints) {
            const prog = self.getProgram(.joint);
            try self.bindPipe(cmd, prog, "ozz.joint", .{
                .layout = .pnc_instanced,
                .topology = .line_strip,
                .cull = .none,
            });
            prog.pushConstants(self.device, cmd, std.mem.asBytes(&pc), 0);
            cmd.bind_vertex_buffer(self.device, &self.static_vb, 0);
            cmd.bind_vertex_buffer(self.device, &self.ring.buffer, 1);
            self.drawInstanced(cmd, joint_vertex_count, static_joint_first, @intCast(count), region.first);
        }
    }

    /// One instanced draw, or `instance_count` single-instance draws where the
    /// backend cannot instance.
    fn drawInstanced(
        self: *Renderer,
        cmd: *rhi.Cmd,
        vertex_count: u32,
        first_vertex: u32,
        instance_count: u32,
        first_instance: u32,
    ) void {
        if (comptime supports_instancing) {
            cmd.draw(self.device, .{
                .vertex_count = vertex_count,
                .instance_count = instance_count,
                .first_vertex = first_vertex,
                .first_instance = first_instance,
            });
        } else {
            for (0..instance_count) |i| {
                cmd.draw(self.device, .{
                    .vertex_count = vertex_count,
                    .instance_count = 1,
                    .first_vertex = first_vertex,
                    .first_instance = first_instance + @as(u32, @intCast(i)),
                });
            }
        }
    }

    /// `DrawPoints` — `sizes` and `colors` must be empty, of length 1, or of
    /// length `count`. `screen_space` selects a fixed pixel size over one that
    /// shrinks with distance (the divide happens in `immediate.slang`).
    pub fn drawPoints(
        self: *Renderer,
        positions: []const f32,
        position_stride: usize,
        sizes: []const f32,
        colors: []const Color,
        transform: Float4x4,
        screen_space: bool,
    ) !void {
        const cmd = self.cmd orelse return;
        const stride = if (position_stride == 0) 3 * @sizeOf(f32) else position_stride;
        const count = stridedCount(positions.len * @sizeOf(f32), stride, 3 * @sizeOf(f32));
        if (count == 0) return;
        if (sizes.len > 1 and sizes.len != count) return error.InvalidPointSizes;
        if (colors.len > 1 and colors.len != count) return error.InvalidPointColors;

        const region = try self.allocTyped(VertexPoint, count);
        const bytes = std.mem.sliceAsBytes(positions);
        const flag: f32 = if (screen_space) 1 else 0;
        for (0..count) |i| {
            region.items[i] = .{
                .pos = readVec3(bytes, i, stride),
                .color = if (colors.len == 0) color_mod.white else colors[if (colors.len == 1) 0 else i],
                .size = if (sizes.len == 0) 1 else sizes[if (sizes.len == 1) 0 else i],
                .screen_space = flag,
            };
        }

        const prog = self.getProgram(.points);
        try self.bindPipe(cmd, prog, "ozz.points", .{
            .layout = .point,
            .topology = .point_list,
            .cull = .none,
        });
        const pc = ImmediatePC{ .mvp = Float4x4.mul(self.view_proj, transform) };
        prog.pushConstants(self.device, cmd, std.mem.asBytes(&pc), 0);
        cmd.bind_vertex_buffer(self.device, &self.ring.buffer, 0);
        cmd.draw(self.device, .{ .vertex_count = @intCast(count), .first_vertex = region.first });
    }

    /// `DrawBoxIm` — the 12-edge wireframe.
    pub fn drawBoxIm(self: *Renderer, box: ozz.math.Box, transform: Float4x4, col: Color) !void {
        const vertices = boxWireframeVertices(box, col);
        try self.pushImmediate(
            .line_list,
            &vertices,
            Float4x4.mul(self.view_proj, transform),
            col.a < 255,
            true,
        );
    }

    /// `DrawBoxShaded` — 12 ambient-lit triangles, one instance per transform.
    pub fn drawBoxShaded(
        self: *Renderer,
        box: ozz.math.Box,
        transforms: []const Float4x4,
        col: Color,
    ) !void {
        if (transforms.len == 0) return;
        const vertices = boxShadedVertices(box, col);
        try self.drawShadedInstanced(&vertices, transforms, "ozz.box_shaded");
    }

    /// `DrawSphereIm` — the icosphere expanded to a flat-coloured triangle list
    /// and pushed through the immediate shader (no normals, no lighting).
    pub fn drawSphereIm(self: *Renderer, radius: f32, transform: Float4x4, col: Color) !void {
        const cmd = self.cmd orelse return;
        const count = icosphere.indices.len;
        const region = try self.allocTyped(VertexPC, count);
        for (icosphere.indices, 0..) |index, i| {
            const base = @as(usize, index) * 3;
            region.items[i] = .{
                .pos = .{
                    icosphere.vertices[base + 0],
                    icosphere.vertices[base + 1],
                    icosphere.vertices[base + 2],
                },
                .color = col,
            };
        }
        try self.drawImmediate(
            cmd,
            .triangle_list,
            region.first,
            count,
            Float4x4.mul(self.view_proj, scaleUniform(transform, radius)),
            col.a < 255,
            true,
        );
    }

    /// `DrawSphereShaded` — the icosphere with positions doubling as normals,
    /// one instance per transform, each scaled by `radius`.
    ///
    /// The mesh is expanded to a non-indexed triangle list rather than kept
    /// indexed, because `rhi.Cmd.draw_indexed` exposes no `first_instance` and
    /// the instance stream can only be reached through it.
    pub fn drawSphereShaded(
        self: *Renderer,
        radius: f32,
        transforms: []const Float4x4,
        col: Color,
    ) !void {
        if (transforms.len == 0) return;

        const count = icosphere.indices.len;
        try self.scratch.resize(self.allocator, count * @sizeOf(VertexPNC));
        const vertices: []VertexPNC = @alignCast(std.mem.bytesAsSlice(VertexPNC, self.scratch.items));
        for (icosphere.indices, 0..) |index, i| {
            const base = @as(usize, index) * 3;
            const p = [3]f32{
                icosphere.vertices[base + 0],
                icosphere.vertices[base + 1],
                icosphere.vertices[base + 2],
            };
            vertices[i] = .{ .pos = p, .normal = p, .color = col };
        }

        // Upstream scales each transform by the radius rather than the mesh.
        try self.matrices.resize(self.allocator, transforms.len);
        for (transforms, self.matrices.items) |source, *scaled| scaled.* = scaleUniform(source, radius);

        try self.drawShadedInstanced(vertices, self.matrices.items, "ozz.sphere_shaded");
    }

    /// Shared body of `drawBoxShaded` / `drawSphereShaded`: upload the mesh, then
    /// either one instanced draw (Vulkan) or one push-constant draw per transform
    /// through the non-instanced ambient program (Metal).
    fn drawShadedInstanced(
        self: *Renderer,
        vertices: []const VertexPNC,
        transforms: []const Float4x4,
        name: [*:0]const u8,
    ) !void {
        const cmd = self.cmd orelse return;
        if (vertices.len == 0) return;
        const vertex_region = try self.allocTyped(VertexPNC, vertices.len);
        @memcpy(vertex_region.items, vertices);

        if (comptime supports_instancing) {
            const instance_region = try self.allocTyped(InstanceMatrix, transforms.len);
            for (transforms, instance_region.items) |source, *slot| slot.* = .{ .m = flatten(source) };

            const prog = self.getProgram(.ambient_instanced);
            try self.bindPipe(cmd, prog, name, .{
                .layout = .pnc_instanced,
                .topology = .triangle_list,
                .cull = default_cull,
            });
            // `vertexMainInstanced` ignores `pc.model`; the world matrix arrives
            // through the instance stream.
            const pc = AmbientPC{ .view_proj = self.view_proj, .model = .identity };
            prog.pushConstants(self.device, cmd, std.mem.asBytes(&pc), 0);
            cmd.bind_vertex_buffer(self.device, &self.ring.buffer, 0);
            cmd.bind_vertex_buffer(self.device, &self.ring.buffer, 1);
            cmd.draw(self.device, .{
                .vertex_count = @intCast(vertices.len),
                .instance_count = @intCast(transforms.len),
                .first_vertex = vertex_region.first,
                .first_instance = instance_region.first,
            });
        } else {
            const prog = self.getProgram(.ambient);
            try self.bindPipe(cmd, prog, name, .{
                .layout = .pnc,
                .topology = .triangle_list,
                .cull = default_cull,
            });
            cmd.bind_vertex_buffer(self.device, &self.ring.buffer, 0);
            for (transforms) |transform| {
                const pc = AmbientPC{ .view_proj = self.view_proj, .model = transform };
                prog.pushConstants(self.device, cmd, std.mem.asBytes(&pc), 0);
                cmd.draw(self.device, .{
                    .vertex_count = @intCast(vertices.len),
                    .first_vertex = vertex_region.first,
                });
            }
        }
    }

    /// `DrawLines` — a line list. Early-out under two points; blended when the
    /// colour is translucent.
    pub fn drawLines(self: *Renderer, points: []const Vec3f32, col: Color, transform: Float4x4) !void {
        try self.drawLinePrimitive(.line_list, points, col, transform);
    }

    /// `DrawLineStrip` — the same, as one connected strip.
    pub fn drawLineStrip(self: *Renderer, points: []const Vec3f32, col: Color, transform: Float4x4) !void {
        try self.drawLinePrimitive(.line_strip, points, col, transform);
    }

    fn drawLinePrimitive(
        self: *Renderer,
        topology: rpi.pipeline_desc.Topology,
        points: []const Vec3f32,
        col: Color,
        transform: Float4x4,
    ) !void {
        const cmd = self.cmd orelse return;
        if (points.len < 2) return;
        const region = try self.allocTyped(VertexPC, points.len);
        for (points, region.items) |p, *vertex| {
            vertex.* = .{ .pos = .{ p[0], p[1], p[2] }, .color = col };
        }
        try self.drawImmediate(
            cmd,
            topology,
            region.first,
            points.len,
            Float4x4.mul(self.view_proj, transform),
            col.a < 255,
            true,
        );
    }

    /// `DrawVectors` — a segment from every position along the matching
    /// direction, scaled by `length`. Strides are in bytes.
    pub fn drawVectors(
        self: *Renderer,
        positions: []const f32,
        position_stride: usize,
        directions: []const f32,
        direction_stride: usize,
        count: usize,
        length: f32,
        col: Color,
        transform: Float4x4,
    ) !void {
        try self.drawVectorsBytes(
            std.mem.sliceAsBytes(positions),
            position_stride,
            std.mem.sliceAsBytes(directions),
            direction_stride,
            count,
            length,
            col,
            transform,
        );
    }

    fn drawVectorsBytes(
        self: *Renderer,
        positions: []const u8,
        position_stride: usize,
        directions: []const u8,
        direction_stride: usize,
        count: usize,
        length: f32,
        col: Color,
        transform: Float4x4,
    ) !void {
        const cmd = self.cmd orelse return;
        if (count == 0) return;
        // Upstream validates that the strided walk stays inside both spans.
        if (!strideFits(positions.len, position_stride, count)) return error.InvalidVectorSpan;
        if (!strideFits(directions.len, direction_stride, count)) return error.InvalidVectorSpan;

        const region = try self.allocTyped(VertexPC, count * 2);
        for (0..count) |i| {
            const p = readVec3(positions, i, position_stride);
            const d = readVec3(directions, i, direction_stride);
            region.items[i * 2] = .{ .pos = p, .color = col };
            region.items[i * 2 + 1] = .{
                .pos = .{ p[0] + d[0] * length, p[1] + d[1] * length, p[2] + d[2] * length },
                .color = col,
            };
        }
        try self.drawImmediate(
            cmd,
            .line_list,
            region.first,
            count * 2,
            Float4x4.mul(self.view_proj, transform),
            col.a < 255,
            true,
        );
    }

    /// `DrawBinormals` — `cross(normal, tangent) * handedness`, where the
    /// handedness is the tangent's `w` (3 floats into each tangent record).
    pub fn drawBinormals(
        self: *Renderer,
        positions: []const f32,
        position_stride: usize,
        normals: []const f32,
        normal_stride: usize,
        tangents: []const f32,
        tangent_stride: usize,
        count: usize,
        length: f32,
        col: Color,
        transform: Float4x4,
    ) !void {
        const tangent_bytes = std.mem.sliceAsBytes(tangents);
        const skip = 3 * @sizeOf(f32);
        const handedness = if (tangent_bytes.len >= skip)
            tangent_bytes[skip..]
        else
            tangent_bytes[tangent_bytes.len..];
        try self.drawBinormalsSplit(
            std.mem.sliceAsBytes(positions),
            position_stride,
            std.mem.sliceAsBytes(normals),
            normal_stride,
            tangent_bytes,
            tangent_stride,
            handedness,
            tangent_stride,
            count,
            length,
            col,
            transform,
        );
    }

    /// Binormals with the handedness read from a separate span. The skinned path
    /// needs this: its tangent *directions* come from the skinning output
    /// (float3, stride 12) while the handedness stays in the unskinned source
    /// tangents (float4, stride 16) — exactly what upstream passes.
    fn drawBinormalsSplit(
        self: *Renderer,
        positions: []const u8,
        position_stride: usize,
        normals: []const u8,
        normal_stride: usize,
        tangents: []const u8,
        tangent_stride: usize,
        handedness: []const u8,
        handedness_stride: usize,
        count: usize,
        length: f32,
        col: Color,
        transform: Float4x4,
    ) !void {
        const cmd = self.cmd orelse return;
        if (count == 0) return;
        if (!strideFits(positions.len, position_stride, count)) return error.InvalidVectorSpan;
        if (!strideFits(normals.len, normal_stride, count)) return error.InvalidVectorSpan;
        if (!strideFits(tangents.len, tangent_stride, count)) return error.InvalidVectorSpan;

        const region = try self.allocTyped(VertexPC, count * 2);
        for (0..count) |i| {
            const p = readVec3(positions, i, position_stride);
            const n = readVec3(normals, i, normal_stride);
            const t = readVec3(tangents, i, tangent_stride);
            const h = readFloat(handedness, i, handedness_stride) orelse 1;
            const b = v3cross(n, t);
            region.items[i * 2] = .{ .pos = p, .color = col };
            region.items[i * 2 + 1] = .{
                .pos = .{
                    p[0] + b[0] * h * length,
                    p[1] + b[1] * h * length,
                    p[2] + b[2] * h * length,
                },
                .color = col,
            };
        }
        try self.drawImmediate(
            cmd,
            .line_list,
            region.first,
            count * 2,
            Float4x4.mul(self.view_proj, transform),
            col.a < 255,
            true,
        );
    }

    /// `DrawMesh` — the unskinned path. Vertices are interleaved into the ring,
    /// missing normals / colours / uvs fall back to upstream's default arrays,
    /// and the debug overlays run afterwards.
    pub fn drawMesh(
        self: *Renderer,
        m: ozz.geometry.Mesh,
        transform: Float4x4,
        options: Options,
    ) !void {
        const cmd = self.cmd orelse return;
        const vertex_count = mesh_mod.vertexCount(m);
        if (vertex_count == 0) return;

        if (options.triangles) {
            const region = try self.allocTyped(VertexMesh, vertex_count);
            var offset: usize = 0;
            for (m.parts) |part| {
                const part_count = part.vertexCount();
                if (part_count == 0) continue;
                fillMeshVertices(part, options, region.items[offset..][0..part_count]);
                offset += part_count;
            }
            try self.drawMeshGeometry(cmd, region.first, m.triangle_indices, transform, options);
        }

        if (options.vertices) {
            const size = [_]f32{2};
            const white = [_]Color{color_mod.white};
            for (m.parts) |part| {
                if (part.positions.len == 0) continue;
                try self.drawPoints(part.positions, 3 * @sizeOf(f32), &size, &white, transform, true);
            }
        }
        if (options.normals) {
            for (m.parts) |part| {
                if (part.normals.len == 0) continue;
                try self.drawVectors(
                    part.positions,
                    3 * @sizeOf(f32),
                    part.normals,
                    3 * @sizeOf(f32),
                    part.vertexCount(),
                    0.03,
                    color_mod.green,
                    transform,
                );
            }
        }
        if (options.tangents) {
            for (m.parts) |part| {
                if (part.normals.len == 0 or part.tangents.len == 0) continue;
                try self.drawVectors(
                    part.positions,
                    3 * @sizeOf(f32),
                    part.tangents,
                    4 * @sizeOf(f32),
                    part.vertexCount(),
                    0.03,
                    color_mod.red,
                    transform,
                );
            }
        }
        if (options.binormals) {
            for (m.parts) |part| {
                if (part.normals.len == 0 or part.tangents.len == 0) continue;
                try self.drawBinormals(
                    part.positions,
                    3 * @sizeOf(f32),
                    part.normals,
                    3 * @sizeOf(f32),
                    part.tangents,
                    4 * @sizeOf(f32),
                    part.vertexCount(),
                    0.03,
                    color_mod.blue,
                    transform,
                );
            }
        }
    }

    /// `DrawSkinnedMesh` — CPU skinning through `ozz.geometry.skinStrided`, one
    /// job per mesh part, into a host scratch buffer laid out exactly like
    /// upstream's (`positions | normals | tangents`, each a block of float3).
    /// The debug overlays read the skinned output; colours and uvs are copied
    /// unskinned.
    pub fn drawSkinnedMesh(
        self: *Renderer,
        m: ozz.geometry.Mesh,
        skinning_matrices: []const Float4x4,
        transform: Float4x4,
        options: Options,
    ) !void {
        if (options.skip_skinning or !m.skinned()) {
            return self.drawMesh(m, transform, options);
        }
        const cmd = self.cmd orelse return;
        const vertex_count = mesh_mod.vertexCount(m);
        if (vertex_count == 0) return;

        const stride = 3 * @sizeOf(f32);
        const block = vertex_count * stride;
        const positions_offset: usize = 0;
        const normals_offset = block;
        const tangents_offset = 2 * block;
        try self.scratch.resize(self.allocator, 3 * block);
        const scratch = self.scratch.items;

        var processed: usize = 0;
        for (m.parts) |part| {
            const part_count = part.vertexCount();
            if (part_count == 0) continue;
            const influences = part.influencesCount();
            if (influences == 0) return error.InvalidMeshInfluences;

            const out_positions = scratch[positions_offset + processed * stride ..][0 .. part_count * stride];
            const out_normals = scratch[normals_offset + processed * stride ..][0 .. part_count * stride];
            const out_tangents = scratch[tangents_offset + processed * stride ..][0 .. part_count * stride];

            const has_normals = part.normals.len / 3 == part_count;
            const has_tangents = has_normals and part.tangents.len / 4 == part_count;

            // Upstream fills the untouched blocks with its default patterns.
            if (!has_normals) fillVec3(out_normals, stride, part_count, .{ 0, 1, 0 });
            if (!has_tangents) fillVec3(out_tangents, stride, part_count, .{ 1, 0, 0 });

            try ozz.geometry.skinStrided(.{
                .vertex_count = part_count,
                .influences_count = influences,
                .joint_matrices = skinning_matrices,
                .joint_indices = std.mem.sliceAsBytes(part.joint_indices),
                .joint_indices_stride = @sizeOf(u16) * influences,
                .joint_weights = if (influences > 1) std.mem.sliceAsBytes(part.joint_weights) else &.{},
                .joint_weights_stride = if (influences > 1) @sizeOf(f32) * (influences - 1) else 0,
                .input_positions = std.mem.sliceAsBytes(part.positions),
                .input_positions_stride = stride,
                .input_normals = if (has_normals) std.mem.sliceAsBytes(part.normals) else null,
                .input_normals_stride = if (has_normals) stride else 0,
                .input_tangents = if (has_tangents) std.mem.sliceAsBytes(part.tangents) else null,
                .input_tangents_stride = if (has_tangents) 4 * @sizeOf(f32) else 0,
                .output_positions = out_positions,
                .output_positions_stride = stride,
                .output_normals = if (has_normals) out_normals else null,
                .output_normals_stride = if (has_normals) stride else 0,
                .output_tangents = if (has_tangents) out_tangents else null,
                .output_tangents_stride = if (has_tangents) stride else 0,
            });

            if (options.normals and has_normals) {
                try self.drawVectorsBytes(
                    out_positions,
                    stride,
                    out_normals,
                    stride,
                    part_count,
                    0.03,
                    color_mod.green,
                    transform,
                );
            }
            if (options.tangents and has_tangents) {
                try self.drawVectorsBytes(
                    out_positions,
                    stride,
                    out_tangents,
                    stride,
                    part_count,
                    0.03,
                    color_mod.red,
                    transform,
                );
            }
            if (options.binormals and has_normals and has_tangents) {
                const source = std.mem.sliceAsBytes(part.tangents);
                try self.drawBinormalsSplit(
                    out_positions,
                    stride,
                    out_normals,
                    stride,
                    out_tangents,
                    stride,
                    source[3 * @sizeOf(f32) ..],
                    4 * @sizeOf(f32),
                    part_count,
                    0.03,
                    color_mod.blue,
                    transform,
                );
            }

            processed += part_count;
        }

        if (options.triangles) {
            const region = try self.allocTyped(VertexMesh, vertex_count);
            var offset: usize = 0;
            for (m.parts) |part| {
                const part_count = part.vertexCount();
                if (part_count == 0) continue;
                fillSkinnedVertices(
                    part,
                    options,
                    scratch[positions_offset + offset * stride ..],
                    scratch[normals_offset + offset * stride ..],
                    stride,
                    region.items[offset..][0..part_count],
                );
                offset += part_count;
            }
            try self.drawMeshGeometry(cmd, region.first, m.triangle_indices, transform, options);
        }

        if (options.vertices) {
            const size = [_]f32{2};
            const white = [_]Color{color_mod.white};
            const positions: []const f32 = @alignCast(std.mem.bytesAsSlice(
                f32,
                scratch[positions_offset..][0..block],
            ));
            try self.drawPoints(positions, stride, &size, &white, transform, true);
        }
    }

    /// The shared triangle (or emulated wireframe) draw of `drawMesh` /
    /// `drawSkinnedMesh`.
    fn drawMeshGeometry(
        self: *Renderer,
        cmd: *rhi.Cmd,
        first_vertex: u32,
        triangle_indices: []const u16,
        transform: Float4x4,
        options: Options,
    ) !void {
        if (triangle_indices.len == 0) return;
        const textured = options.texture and self.texturingAvailable();

        const index_count = if (options.wireframe)
            wireframeIndexCount(triangle_indices.len)
        else
            triangle_indices.len;
        if (index_count == 0) return;

        const indices = try self.allocIndices(index_count);
        if (options.wireframe) {
            _ = expandWireframeIndices(triangle_indices, indices.items);
        } else {
            @memcpy(indices.items, triangle_indices);
        }

        const prog = if (textured) self.getProgram(.textured) else self.getProgram(.ambient);
        try self.bindPipe(cmd, prog, if (textured) "ozz.mesh.textured" else "ozz.mesh", .{
            .layout = if (textured) .mesh_uv else .mesh,
            .topology = if (options.wireframe) .line_list else .triangle_list,
            .cull = if (options.wireframe) .none else default_cull,
        });
        const pc = AmbientPC{ .view_proj = self.view_proj, .model = transform };
        prog.pushConstants(self.device, cmd, std.mem.asBytes(&pc), 0);
        if (textured) {
            try prog.bindDescriptors(self.device, cmd, @truncate(self.frame_index), &.{
                rpi.DescriptorBinding.init(
                    "u_texture",
                    rhi.Descriptor.sampledImage(self.device, &self.checkered_view.?),
                    0,
                ),
                rpi.DescriptorBinding.init(
                    "u_sampler",
                    rhi.Descriptor.sampler(self.device, &self.checkered_sampler.?),
                    0,
                ),
            }, .graphics);
        }
        cmd.bind_vertex_buffer(self.device, &self.ring.buffer, 0);
        cmd.bind_index_buffer(self.device, &self.ring.buffer, .uint16);
        cmd.draw_indexed(self.device, .{
            .index_count = @intCast(index_count),
            .first_index = indices.first,
            .vertex_offset = @intCast(first_vertex),
        });
    }
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// slangc emits a single SPIR-V entry point per module, always named `main`; the
/// Metal backend keeps the source entry-point name instead.
fn entryPoint(comptime name: []const u8) []const u8 {
    return if (is_apple) name else "main";
}

fn swapchainColorFormat(swapchain: *rhi.Swapchain) rhi.Format {
    if (comptime rhi.platform_has_api(.vk)) {
        if (rhi.is_target_selected(.vk)) {
            return switch (swapchain.backend.vk.format) {
                .r8g8b8a8_unorm => .rgba8_unorm,
                .b8g8r8a8_unorm => .bgra8_unorm,
                .r16g16b16a16_sfloat => .rgba16_sfloat,
                .a2b10g10r10_unorm_pack32 => .r10_g10_b10_a2_unorm,
                else => .rgba8_unorm,
            };
        }
    }
    // Metal's swapchain layer is created as BGRA8; headless never builds a
    // pipeline at all.
    return .bgra8_unorm;
}

/// How many strided records of `element` bytes fit in `bytes`.
fn stridedCount(bytes: usize, stride: usize, element: usize) usize {
    if (stride == 0 or bytes < element) return 0;
    return (bytes - element) / stride + 1;
}

/// Upstream's span validation: `begin + stride * count` must stay in range.
fn strideFits(bytes: usize, stride: usize, count: usize) bool {
    if (count == 0) return true;
    if (stride < 3 * @sizeOf(f32)) return false;
    return (count - 1) * stride + 3 * @sizeOf(f32) <= bytes;
}

fn readVec3(bytes: []const u8, index: usize, stride: usize) [3]f32 {
    const offset = index * stride;
    return .{
        std.mem.bytesToValue(f32, bytes[offset..][0..4]),
        std.mem.bytesToValue(f32, bytes[offset + 4 ..][0..4]),
        std.mem.bytesToValue(f32, bytes[offset + 8 ..][0..4]),
    };
}

fn readFloat(bytes: []const u8, index: usize, stride: usize) ?f32 {
    const offset = index * stride;
    if (offset + 4 > bytes.len) return null;
    return std.mem.bytesToValue(f32, bytes[offset..][0..4]);
}

fn fillVec3(bytes: []u8, stride: usize, count: usize, value: [3]f32) void {
    for (0..count) |i| {
        @memcpy(bytes[i * stride ..][0..12], std.mem.asBytes(&value));
    }
}

/// `DrawMesh`'s per-part interleave, including upstream's default-array
/// fallbacks: `{0,1,0}` normals, opaque white colours, `{0,0}` uvs. Colours also
/// fall back to white whenever `options.colors` is off.
fn fillMeshVertices(part: ozz.geometry.MeshPart, options: Options, out: []VertexMesh) void {
    const count = out.len;
    const has_normals = part.normals.len / 3 == count;
    const has_colors = options.colors and part.colors.len / 4 == count;
    const has_uvs = options.texture and part.uvs.len / 2 == count;
    for (0..count) |i| {
        out[i] = .{
            .pos = .{ part.positions[i * 3], part.positions[i * 3 + 1], part.positions[i * 3 + 2] },
            .normal = if (has_normals)
                .{ part.normals[i * 3], part.normals[i * 3 + 1], part.normals[i * 3 + 2] }
            else
                .{ 0, 1, 0 },
            .color = if (has_colors) .{
                .r = part.colors[i * 4],
                .g = part.colors[i * 4 + 1],
                .b = part.colors[i * 4 + 2],
                .a = part.colors[i * 4 + 3],
            } else color_mod.white,
            .uv = if (has_uvs) .{ part.uvs[i * 2], part.uvs[i * 2 + 1] } else .{ 0, 0 },
        };
    }
}

/// The same interleave, but taking positions and normals from the skinning
/// output rather than the source part.
fn fillSkinnedVertices(
    part: ozz.geometry.MeshPart,
    options: Options,
    positions: []const u8,
    normals: []const u8,
    stride: usize,
    out: []VertexMesh,
) void {
    const count = out.len;
    const has_colors = options.colors and part.colors.len / 4 == count;
    const has_uvs = options.texture and part.uvs.len / 2 == count;
    for (0..count) |i| {
        out[i] = .{
            .pos = readVec3(positions, i, stride),
            .normal = readVec3(normals, i, stride),
            .color = if (has_colors) .{
                .r = part.colors[i * 4],
                .g = part.colors[i * 4 + 1],
                .b = part.colors[i * 4 + 2],
                .a = part.colors[i * 4 + 3],
            } else color_mod.white,
            .uv = if (has_uvs) .{ part.uvs[i * 2], part.uvs[i * 2 + 1] } else .{ 0, 0 },
        };
    }
}

// ---------------------------------------------------------------------------
// Tests — pure geometry only; none of these need a device.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "bone model geometry matches InitPostureRendering" {
    const positions = bone_positions;
    try testing.expectEqual([3]f32{ 1, 0, 0 }, positions[0]);
    try testing.expectEqual([3]f32{ 0, 0, 0 }, positions[5]);
    for (positions[1..5]) |p| try testing.expectEqual(bone_inter, p[0]);

    const normals = boneNormals();
    for (normals) |n| {
        const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        try testing.expectApproxEqAbs(@as(f32, 1), len, 1e-5);
        // Every face of the spike leans off the X axis.
        try testing.expect(n[1] != 0 or n[2] != 0);
    }

    const vertices = boneVertices();
    try testing.expectEqual(@as(usize, 24), vertices.len);
    for (vertices) |v| try testing.expectEqual(color_mod.white, v.color);

    // Triangle 0 is (pos0, pos2, pos1), all sharing normal 0.
    try testing.expectEqual(positions[0], vertices[0].pos);
    try testing.expectEqual(positions[2], vertices[1].pos);
    try testing.expectEqual(positions[1], vertices[2].pos);
    try testing.expectEqual(normals[0], vertices[0].normal);
    try testing.expectEqual(normals[0], vertices[2].normal);
    // The last triangle closes the base fan on normal 7.
    try testing.expectEqual(positions[5], vertices[21].pos);
    try testing.expectEqual(normals[7], vertices[23].normal);

    // Each of the 8 normals is used by exactly one triangle.
    for (normals) |n| {
        var uses: usize = 0;
        for (vertices) |v| {
            if (std.meta.eql(v.normal, n)) uses += 1;
        }
        try testing.expectEqual(@as(usize, 3), uses);
    }
    // Tip triangles use pos[0]; base triangles use pos[5]; never both.
    var t: usize = 0;
    while (t < 24) : (t += 3) {
        const uses_tip = std.meta.eql(vertices[t].pos, positions[0]);
        const uses_base = std.meta.eql(vertices[t].pos, positions[5]);
        try testing.expect(uses_tip != uses_base);
    }
}

test "joint model is 68 points across three radius-0.2 circles" {
    try testing.expectEqual(@as(usize, 21), joint_points_yz);
    try testing.expectEqual(@as(usize, 26), joint_points_xy);
    try testing.expectEqual(@as(usize, 21), joint_points_xz);

    const vertices = jointVertices();
    try testing.expectEqual(@as(usize, 68), vertices.len);

    const red_tint = Color.fromFloats(.{ 1, 0.3, 0.3, 1 });
    for (vertices[0..joint_points_yz]) |v| {
        try testing.expectEqual(@as(f32, 0), v.pos[0]);
        const r = @sqrt(v.pos[1] * v.pos[1] + v.pos[2] * v.pos[2]);
        try testing.expectApproxEqAbs(bone_inter, r, 1e-5);
        try testing.expectEqual(red_tint, v.color);
    }
    // The circle closes: point 20 comes back to point 0.
    try testing.expectApproxEqAbs(vertices[0].pos[1], vertices[joint_slices].pos[1], 1e-5);
    try testing.expectApproxEqAbs(vertices[0].pos[2], vertices[joint_slices].pos[2], 1e-5);

    const blue_tint = Color.fromFloats(.{ 0.3, 0.3, 1, 1 });
    for (vertices[joint_points_yz..][0..joint_points_xy]) |v| {
        try testing.expectEqual(@as(f32, 0), v.pos[2]);
        try testing.expectEqual(blue_tint, v.color);
    }
    const green_tint = Color.fromFloats(.{ 0.3, 1, 0.3, 1 });
    for (vertices[joint_points_yz + joint_points_xy ..]) |v| {
        try testing.expectEqual(@as(f32, 0), v.pos[1]);
        try testing.expectEqual(green_tint, v.color);
    }
    // The XY block's 5 extra points keep sweeping the same circle (angle 21
    // lands back on angle 1), which is how the strip walks to the next circle.
    const extra = vertices[joint_points_yz + joint_points_per_circle];
    try testing.expectApproxEqAbs(vertices[joint_points_yz + 1].pos[0], extra.pos[0], 1e-5);
    try testing.expectApproxEqAbs(vertices[joint_points_yz + 1].pos[1], extra.pos[1], 1e-5);
}

fn testSkeleton(allocator: std.mem.Allocator) !ozz.animation.Skeleton {
    // root -> a -> b (b is a leaf); c is a second child of root and also a leaf.
    return ozz.animation.Skeleton.init(allocator, &.{
        .{ .name = "root", .parent = ozz.animation.no_parent },
        .{ .name = "a", .parent = 0 },
        .{ .name = "b", .parent = 1 },
        .{ .name = "c", .parent = 0 },
    });
}

test "posture instance packing carries bone direction and the is-bone flag" {
    var skeleton = try testSkeleton(testing.allocator);
    defer skeleton.deinit();

    var matrices: [4]Float4x4 = @splat(.identity);
    matrices[0].cols[3] = .{ 0, 0, 0, 1 };
    matrices[1].cols[3] = .{ 1, 0, 0, 1 };
    matrices[2].cols[3] = .{ 1, 2, 0, 1 };
    matrices[3].cols[3] = .{ 0, 0, 3, 1 };

    var out: [8]InstanceMatrix = undefined;
    const count = fillPostureInstances(skeleton, &matrices, &out);

    // 3 non-root joints; joints 2 and 3 are leaves, adding one instance each.
    try testing.expectEqual(@as(usize, 5), count);

    // Instance 0: bone root -> a, anchored on the parent.
    try testing.expectEqual(@as(f32, 1), out[0].m[15]);
    try testing.expectEqual(@as(f32, 1), out[0].m[3]);
    try testing.expectEqual(@as(f32, 0), out[0].m[7]);
    try testing.expectEqual(@as(f32, 0), out[0].m[11]);
    try testing.expectEqual(@as(f32, 0), out[0].m[12]);

    // Instance 1: bone a -> b, direction (0, 2, 0), anchored on a.
    try testing.expectEqual(@as(f32, 1), out[1].m[15]);
    try testing.expectEqual(@as(f32, 0), out[1].m[3]);
    try testing.expectEqual(@as(f32, 2), out[1].m[7]);
    try testing.expectEqual(@as(f32, 1), out[1].m[12]);

    // Instance 2: b's leaf copy — same direction, flag cleared, anchored on b.
    try testing.expectEqual(@as(f32, 0), out[2].m[15]);
    try testing.expectEqual(@as(f32, 2), out[2].m[7]);
    try testing.expectEqual(@as(f32, 1), out[2].m[12]);
    try testing.expectEqual(@as(f32, 2), out[2].m[13]);

    // Instances 3/4: bone root -> c and c's leaf copy.
    try testing.expectEqual(@as(f32, 1), out[3].m[15]);
    try testing.expectEqual(@as(f32, 3), out[3].m[11]);
    try testing.expectEqual(@as(f32, 0), out[4].m[15]);
    try testing.expectEqual(@as(f32, 3), out[4].m[11]);

    // The basis columns are copied verbatim from the source matrix.
    try testing.expectEqual(@as(f32, 1), out[0].m[0]);
    try testing.expectEqual(@as(f32, 1), out[0].m[5]);
    try testing.expectEqual(@as(f32, 1), out[0].m[10]);
}

test "posture packing never overruns the caller's buffer" {
    var skeleton = try testSkeleton(testing.allocator);
    defer skeleton.deinit();
    const matrices: [4]Float4x4 = @splat(.identity);

    var out: [2]InstanceMatrix = undefined;
    try testing.expectEqual(@as(usize, 2), fillPostureInstances(skeleton, &matrices, &out));

    var none: [0]InstanceMatrix = undefined;
    try testing.expectEqual(@as(usize, 0), fillPostureInstances(skeleton, &matrices, &none));

    // Fewer matrices than joints must not read out of bounds.
    try testing.expectEqual(@as(usize, 0), fillPostureInstances(skeleton, matrices[0..1], &out));
}

test "posture upper bound covers the worst case" {
    try testing.expect(maxPostureInstances(4) >= 5);
    try testing.expectEqual(@as(usize, 0), maxPostureInstances(0));
}

test "box wireframe walks 12 distinct edges" {
    const box = ozz.math.Box{ .min = .{ -1, -2, -3 }, .max = .{ 1, 2, 3 } };
    const vertices = boxWireframeVertices(box, color_mod.yellow);
    try testing.expectEqual(@as(usize, 24), vertices.len);
    for (vertices) |v| {
        try testing.expectEqual(color_mod.yellow, v.color);
        try testing.expect(v.pos[0] == -1 or v.pos[0] == 1);
        try testing.expect(v.pos[1] == -2 or v.pos[1] == 2);
        try testing.expect(v.pos[2] == -3 or v.pos[2] == 3);
    }
    // Every segment moves along exactly one axis.
    var i: usize = 0;
    while (i < vertices.len) : (i += 2) {
        var differing: usize = 0;
        for (0..3) |axis| {
            if (vertices[i].pos[axis] != vertices[i + 1].pos[axis]) differing += 1;
        }
        try testing.expectEqual(@as(usize, 1), differing);
    }
    // The 12 edges are distinct (unordered endpoint comparison).
    var edges: [12][2][3]f32 = undefined;
    for (0..12) |e| edges[e] = .{ vertices[e * 2].pos, vertices[e * 2 + 1].pos };
    for (0..12) |a| {
        for (a + 1..12) |b| {
            const same = (std.meta.eql(edges[a][0], edges[b][0]) and std.meta.eql(edges[a][1], edges[b][1])) or
                (std.meta.eql(edges[a][0], edges[b][1]) and std.meta.eql(edges[a][1], edges[b][0]));
            try testing.expect(!same);
        }
    }
}

test "box shaded geometry is 12 triangles with outward axis normals" {
    const box = ozz.math.Box{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
    const vertices = boxShadedVertices(box, color_mod.cyan);
    try testing.expectEqual(@as(usize, 36), vertices.len);

    for (box_shaded_normals) |n| {
        var uses: usize = 0;
        for (vertices) |v| {
            if (std.meta.eql(v.normal, n)) uses += 1;
        }
        try testing.expectEqual(@as(usize, 6), uses);
    }
    for (vertices) |v| {
        try testing.expectEqual(color_mod.cyan, v.color);
        for (0..3) |axis| try testing.expect(v.pos[axis] == 0 or v.pos[axis] == 1);
    }
    // Every triangle lies in the plane its normal points at, on the correct side.
    var t: usize = 0;
    while (t < 36) : (t += 3) {
        const n = vertices[t].normal;
        const axis: usize = if (n[0] != 0) 0 else if (n[1] != 0) 1 else 2;
        const plane = vertices[t].pos[axis];
        try testing.expectEqual(plane, vertices[t + 1].pos[axis]);
        try testing.expectEqual(plane, vertices[t + 2].pos[axis]);
        try testing.expectEqual(if (n[axis] > 0) @as(f32, 1) else @as(f32, 0), plane);
    }
}

test "grid quad and lines" {
    const quad = gridQuadVertices(20, 1.0);
    try testing.expectEqual([3]f32{ -10, 0, -10 }, quad[0].pos);
    try testing.expectEqual([3]f32{ -10, 0, 10 }, quad[1].pos);
    try testing.expectEqual([3]f32{ 10, 0, -10 }, quad[2].pos);
    try testing.expectEqual([3]f32{ 10, 0, 10 }, quad[3].pos);
    for (quad) |v| try testing.expectEqual(grid_fill_color, v.color);

    try testing.expectEqual(@as(usize, 84), gridLineVertexCount(20));
    var lines: [84]VertexPC = undefined;
    try testing.expectEqual(@as(usize, 84), fillGridLines(20, 1.0, &lines));
    for (lines) |v| {
        try testing.expectEqual(grid_line_color, v.color);
        try testing.expectEqual(@as(f32, 0), v.pos[1]);
    }
    // 21 lines along X at increasing z...
    try testing.expectEqual([3]f32{ -10, 0, -10 }, lines[0].pos);
    try testing.expectEqual([3]f32{ 10, 0, -10 }, lines[1].pos);
    try testing.expectEqual([3]f32{ -10, 0, -9 }, lines[2].pos);
    try testing.expectEqual([3]f32{ -10, 0, 10 }, lines[40].pos);
    // ...then 21 along Z at increasing x.
    try testing.expectEqual([3]f32{ -10, 0, -10 }, lines[42].pos);
    try testing.expectEqual([3]f32{ -10, 0, 10 }, lines[43].pos);
    try testing.expectEqual([3]f32{ 10, 0, -10 }, lines[82].pos);
}

test "wireframe index expansion" {
    const triangles = [_]u16{ 0, 1, 2, 2, 1, 3 };
    try testing.expectEqual(@as(usize, 12), wireframeIndexCount(triangles.len));

    var out: [12]u16 = undefined;
    try testing.expectEqual(@as(usize, 12), expandWireframeIndices(&triangles, &out));
    try testing.expectEqualSlices(u16, &.{ 0, 1, 1, 2, 2, 0, 2, 1, 1, 3, 3, 2 }, &out);

    // A short output buffer stops on a triangle boundary.
    var small: [6]u16 = undefined;
    try testing.expectEqual(@as(usize, 6), expandWireframeIndices(&triangles, &small));
    // A trailing partial triangle is ignored.
    const ragged = [_]u16{ 0, 1, 2, 3 };
    try testing.expectEqual(@as(usize, 6), expandWireframeIndices(&ragged, &out));
    try testing.expectEqual(@as(usize, 0), wireframeIndexCount(2));
}

test "scaleUniform scales the basis and leaves the translation" {
    var m = Float4x4.identity;
    m.cols[3] = .{ 5, 6, 7, 1 };
    const s = scaleUniform(m, 3);
    try testing.expectEqual(@as(f32, 3), s.cols[0][0]);
    try testing.expectEqual(@as(f32, 3), s.cols[1][1]);
    try testing.expectEqual(@as(f32, 3), s.cols[2][2]);
    try testing.expectEqual([4]f32{ 5, 6, 7, 1 }, s.cols[3]);
}

test "checkered texture level generation" {
    const width: u32 = 128; // 64 cases, 2 texels each
    var pixels: [128 * 128 * 4]u8 = undefined;
    fillCheckeredLevel(width, &pixels);
    // Case (0,0) is coloured (0 ^ 0 == 0); case (1,0) is white.
    try testing.expectEqual(@as(u8, 0), pixels[2]);
    try testing.expectEqual(@as(u8, 0xff), pixels[2 * 4 + 2]);
    // Each case spans `case_width` texels.
    try testing.expectEqual(pixels[0], pixels[4]);
    // Alpha is always opaque.
    try testing.expectEqual(@as(u8, 0xff), pixels[3]);
    // Row 1 keeps the same parity as row 0 (case_width == 2).
    try testing.expectEqual(pixels[2], pixels[(width + 0) * 4 + 2]);

    // Levels narrower than the case count are flat grey.
    var small: [32 * 32 * 4]u8 = undefined;
    fillCheckeredLevel(32, &small);
    for (0..32 * 32) |i| {
        try testing.expectEqual(@as(u8, 0x7f), small[i * 4]);
        try testing.expectEqual(@as(u8, 0xff), small[i * 4 + 3]);
    }
}

test "vertex layouts match the shader declarations" {
    try testing.expectEqual(@as(usize, 12), @offsetOf(VertexPC, "color"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(VertexPNC, "normal"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(VertexPNC, "color"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(VertexMesh, "uv"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(VertexPoint, "size"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(VertexPoint, "screen_space"));

    // Attribute offsets in the pipeline descriptors track the structs.
    try testing.expectEqual(@as(u32, @offsetOf(VertexPC, "color")), attrs_pc[1].offset);
    try testing.expectEqual(@as(u32, @offsetOf(VertexPNC, "color")), attrs_pnc[2].offset);
    try testing.expectEqual(@as(u32, @offsetOf(VertexMesh, "uv")), attrs_mesh_uv[3].offset);
    try testing.expectEqual(@as(u32, @offsetOf(VertexPoint, "screen_space")), attrs_point[3].offset);
    // The instance stream is a full 4x4 in four float4 slots at locations 3..6.
    try testing.expectEqual(@as(u32, 3), attrs_pnc_instanced[3].location);
    try testing.expectEqual(@as(u32, 48), attrs_pnc_instanced[6].offset);
    try testing.expect(streams_pnc_instanced[1].per_instance);
    try testing.expect(!streams_pnc_instanced[0].per_instance);

    // Every sub-allocation stride is a multiple of the ring's 4-byte element.
    inline for (.{ VertexPC, VertexPNC, VertexMesh, VertexPoint, InstanceMatrix }) |T| {
        try testing.expectEqual(@as(usize, 0), @sizeOf(T) % 4);
    }
}

test "strided span helpers" {
    try testing.expectEqual(@as(usize, 4), stridedCount(4 * 12, 12, 12));
    try testing.expectEqual(@as(usize, 3), stridedCount(3 * 16 - 4, 16, 12));
    try testing.expectEqual(@as(usize, 0), stridedCount(8, 12, 12));

    try testing.expect(strideFits(4 * 12, 12, 4));
    try testing.expect(!strideFits(4 * 12, 12, 5));
    try testing.expect(strideFits(3 * 16 - 4, 16, 3));
    try testing.expect(!strideFits(100, 8, 2)); // stride narrower than a float3
    try testing.expect(strideFits(0, 12, 0));
}

test "flatten keeps ozz's column-major order" {
    var m = Float4x4.identity;
    m.cols[0] = .{ 1, 2, 3, 4 };
    m.cols[3] = .{ 13, 14, 15, 16 };
    const flat = flatten(m);
    try testing.expectEqual(@as(f32, 1), flat[0]);
    try testing.expectEqual(@as(f32, 4), flat[3]);
    try testing.expectEqual(@as(f32, 13), flat[12]);
    try testing.expectEqual(@as(f32, 16), flat[15]);
}

test "axes are unit segments in R/G/B" {
    const v = axesVertices();
    try testing.expectEqual([3]f32{ 0, 0, 0 }, v[0].pos);
    try testing.expectEqual([3]f32{ 1, 0, 0 }, v[1].pos);
    try testing.expectEqual(color_mod.red, v[1].color);
    try testing.expectEqual([3]f32{ 0, 1, 0 }, v[3].pos);
    try testing.expectEqual(color_mod.green, v[3].color);
    try testing.expectEqual([3]f32{ 0, 0, 1 }, v[5].pos);
    try testing.expectEqual(color_mod.blue, v[5].color);
}
