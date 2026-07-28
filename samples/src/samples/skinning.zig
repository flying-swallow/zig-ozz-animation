// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/skinning/sample_skinning.cc`.
//!
//! Playback plus skinning: the sampled model-space matrices are combined with
//! the mesh's inverse bind poses into skinning matrices, and the renderer runs
//! `ozz::geometry::SkinningJob` over them. This is the sample that exercises
//! every `fw.RenderOptions` flag, so all of them are exposed in the gui.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Float4x4 = ozz.math.Float4x4;

pub const name = "skinning";
pub const description = "CPU mesh skinning";

pub const Sample = struct {
    allocator: std.mem.Allocator,
    /// Runtime skeleton.
    skeleton: ozz.animation.Skeleton,
    /// Runtime animation plus its sampling context and local-space output.
    clip: fw.utils.Clip,
    /// Model-space matrices, one per joint.
    models: []Float4x4,
    /// Skinning matrices, sized for the mesh with the most joints. A mesh is
    /// skinned by a subset of the skeleton only, so this is usually shorter
    /// than `models`.
    skinning_matrices: []Float4x4,
    /// Every mesh of the archive; the import tool keeps the dcc mesh split.
    meshes: []ozz.geometry.Mesh,
    /// Animation playback time / speed / loop control.
    controller: fw.PlaybackController = .{},
    /// Skeleton bounds, computed once from the rest pose like upstream's
    /// `GetSceneBounds`.
    bounds: ozz.math.Box,
    /// Statistics shown by the gui, gathered once at load time.
    stats: Stats,

    draw_skeleton: bool = false,
    draw_mesh: bool = true,
    /// The full upstream render-option set, every flag exposed in the gui.
    render_options: fw.RenderOptions = .{},

    /// Mesh statistics upstream prints in its "Model statisitics" panel.
    pub const Stats = struct {
        joints: usize = 0,
        influences: usize = 0,
        vertices: usize = 0,
        indices: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(@embedFile("ruby_skeleton")),
        );
        errdefer skeleton.deinit();

        var clip = try fw.utils.Clip.decode(
            allocator,
            assets.animationOr(@embedFile("ruby_animation")),
        );
        errdefer clip.deinit();

        // Skeleton and animation must match, upstream refuses to start otherwise.
        if (skeleton.numJoints() != clip.animation.numTracks()) {
            return error.SkeletonAnimationMismatch;
        }

        const models = try allocator.alloc(Float4x4, skeleton.numJoints());
        errdefer allocator.free(models);

        const meshes = try fw.mesh.decodeMeshes(
            allocator,
            assets.meshOr(@embedFile("ruby_mesh")),
        );
        errdefer fw.mesh.deinitMeshes(allocator, meshes);

        // The number of skinning matrices is the longest `joint_remaps`, not
        // the joint count: a mesh is only skinned by the joints it uses.
        var stats: Stats = .{ .joints = skeleton.numJoints() };
        var matrix_count: usize = 0;
        for (meshes) |mesh| {
            if (mesh.joint_remaps.len != mesh.inverse_bind_poses.len) {
                return error.InvalidMeshArchive;
            }
            // The mesh must not expect more joints than the skeleton has.
            if (mesh.joint_remaps.len != 0 and
                fw.mesh.highestJointIndex(mesh) >= skeleton.numJoints())
            {
                return error.SkeletonMeshMismatch;
            }
            matrix_count = @max(matrix_count, mesh.joint_remaps.len);
            stats.influences = @max(stats.influences, fw.mesh.maxInfluences(mesh));
            stats.vertices += fw.mesh.vertexCount(mesh);
            stats.indices += fw.mesh.triangleIndexCount(mesh);
        }

        const skinning_matrices = try allocator.alloc(Float4x4, matrix_count);
        errdefer allocator.free(skinning_matrices);

        var self: Sample = .{
            .allocator = allocator,
            .skeleton = skeleton,
            .clip = clip,
            .models = models,
            .skinning_matrices = skinning_matrices,
            .meshes = meshes,
            .bounds = try fw.utils.computeSkeletonBounds(skeleton, allocator),
            .stats = stats,
        };
        // Rest pose, so the first frame has valid matrices even before an update.
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.skeleton.rest_poses,
        }, self.models);
        return self;
    }

    pub fn deinit(self: *Sample) void {
        fw.mesh.deinitMeshes(self.allocator, self.meshes);
        self.allocator.free(self.skinning_matrices);
        self.allocator.free(self.models);
        self.clip.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;
        _ = self.controller.update(self.clip.duration(), dt);
        try self.clip.sample(self.controller.time_ratio);
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.clip.pose,
        }, self.models);
        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        const transform: Float4x4 = .identity;

        if (self.draw_skeleton) {
            try renderer.drawPosture(self.skeleton, self.models, transform, true);
        }

        if (self.draw_mesh) {
            for (self.meshes) |mesh| {
                const matrices = try self.buildSkinningMatrices(mesh);
                try renderer.drawSkinnedMesh(mesh, matrices, transform, self.render_options);
            }
        }
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        if (gui.openClose("Model statistics", true)) {
            gui.doLabel("{d} animated joints", .{self.stats.joints});
            gui.doLabel("{d} influences (max)", .{self.stats.influences});
            gui.doLabel("{d:.1}K vertices", .{
                @as(f32, @floatFromInt(self.stats.vertices)) / 1000.0,
            });
            gui.doLabel("{d:.1}K triangles", .{
                @as(f32, @floatFromInt(self.stats.indices)) / 3000.0,
            });
        }

        if (gui.openClose("Animation control", true)) {
            self.controller.onGui(gui, self.clip.duration(), true, true);
        }

        if (gui.openClose("Display options", true)) {
            _ = gui.doCheckBox("Draw skeleton", &self.draw_skeleton, true);
            _ = gui.doCheckBox("Draw mesh", &self.draw_mesh, true);

            if (gui.openClose("Rendering options", false)) {
                const options = &self.render_options;
                _ = gui.doCheckBox("Show triangles", &options.triangles, self.draw_mesh);
                _ = gui.doCheckBox("Show texture", &options.texture, self.draw_mesh);
                _ = gui.doCheckBox("Show vertices", &options.vertices, self.draw_mesh);
                _ = gui.doCheckBox("Show normals", &options.normals, self.draw_mesh);
                _ = gui.doCheckBox("Show tangents", &options.tangents, self.draw_mesh);
                _ = gui.doCheckBox("Show binormals", &options.binormals, self.draw_mesh);
                _ = gui.doCheckBox("Show colors", &options.colors, self.draw_mesh);
                _ = gui.doCheckBox("Wireframe", &options.wireframe, self.draw_mesh);
                _ = gui.doCheckBox("Skip skinning", &options.skip_skinning, self.draw_mesh);
            }
        }
    }

    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        return self.bounds;
    }

    // -- feature path -------------------------------------------------------

    /// Fills `skinning_matrices` for one mesh: `models[joint_remaps[i]] *
    /// inverse_bind_poses[i]`, which brings a vertex into the joint's space
    /// before the joint's animated transform is applied.
    pub fn buildSkinningMatrices(self: *Sample, mesh: ozz.geometry.Mesh) ![]const Float4x4 {
        if (mesh.joint_remaps.len != mesh.inverse_bind_poses.len or
            mesh.joint_remaps.len > self.skinning_matrices.len)
        {
            return error.InvalidMeshArchive;
        }
        const matrices = self.skinning_matrices[0..mesh.joint_remaps.len];
        for (matrices, mesh.joint_remaps, mesh.inverse_bind_poses) |*matrix, joint, inverse_bind| {
            if (joint >= self.models.len) return error.InvalidMeshArchive;
            matrix.* = Float4x4.mul(self.models[joint], inverse_bind);
        }
        return matrices;
    }
};

test "skinning matrices are the model-space matrix times the inverse bind pose" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    try std.testing.expect(sample.meshes.len > 0);
    try std.testing.expect(sample.stats.vertices > 0);
    try std.testing.expect(sample.stats.influences > 0);
    try std.testing.expect(try sample.onUpdate(0.25, 0.25));

    for (sample.meshes) |mesh| {
        const matrices = try sample.buildSkinningMatrices(mesh);
        try std.testing.expectEqual(mesh.joint_remaps.len, matrices.len);
        for (matrices, mesh.joint_remaps, mesh.inverse_bind_poses) |found, joint, inverse_bind| {
            const expected = Float4x4.mul(sample.models[joint], inverse_bind);
            try std.testing.expectEqual(expected.cols, found.cols);
        }
    }
}

test "skinning a part produces finite, displaced positions" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();
    try std.testing.expect(try sample.onUpdate(0.1, 0.1));

    const mesh = sample.meshes[0];
    const matrices = try sample.buildSkinningMatrices(mesh);
    const part = mesh.parts[0];
    const vertices = part.vertexCount();
    const influences = part.influencesCount();
    try std.testing.expect(influences > 0);

    const output = try allocator.alloc(ozz.math.Vec3f32, vertices);
    defer allocator.free(output);

    try ozz.geometry.skinStrided(.{
        .vertex_count = vertices,
        .influences_count = influences,
        .joint_matrices = matrices,
        .joint_indices = std.mem.sliceAsBytes(part.joint_indices),
        .joint_indices_stride = influences * @sizeOf(u16),
        .joint_weights = std.mem.sliceAsBytes(part.joint_weights),
        .joint_weights_stride = (influences - 1) * @sizeOf(f32),
        .input_positions = std.mem.sliceAsBytes(part.positions),
        .input_positions_stride = 3 * @sizeOf(f32),
        .output_positions = std.mem.sliceAsBytes(output),
        .output_positions_stride = @sizeOf(ozz.math.Vec3f32),
    });

    var moved = false;
    for (output, 0..) |position, index| {
        inline for (0..3) |axis| try std.testing.expect(std.math.isFinite(position[axis]));
        const rest: ozz.math.Vec3f32 = .{
            part.positions[index * 3],
            part.positions[index * 3 + 1],
            part.positions[index * 3 + 2],
        };
        if (@reduce(.Or, @abs(position - rest) > @as(ozz.math.Vec3f32, @splat(1e-4)))) {
            moved = true;
        }
    }
    // The animation is not the bind pose, so skinning has to displace vertices.
    try std.testing.expect(moved);
}

test "render options default to upstream's initial state" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    try std.testing.expect(!sample.draw_skeleton);
    try std.testing.expect(sample.draw_mesh);
    try std.testing.expect(sample.render_options.triangles);
    try std.testing.expect(sample.render_options.colors);
    try std.testing.expect(!sample.render_options.skip_skinning);
    try std.testing.expect(!sample.render_options.wireframe);
    try std.testing.expect(sample.bounds.isValid());
}
