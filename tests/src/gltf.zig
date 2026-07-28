const std = @import("std");
const ozz = @import("zig_ozz_animation");
const h = @import("helpers.zig");

fn readFixture(allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    const path = try h.fixturePath(allocator, relative);
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(32 * 1024 * 1024));
}

fn writeF32(bytes: []u8, offset: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], @bitCast(value), .little);
}

fn testAnimationBinary(bytes: []u8) void {
    @memset(bytes, 0);
    writeF32(bytes, 0, 0);
    writeF32(bytes, 4, 1);
    writeF32(bytes, 8, 0);
    writeF32(bytes, 12, 0);
    writeF32(bytes, 16, 0);
    writeF32(bytes, 20, 1);
    writeF32(bytes, 24, 2);
    writeF32(bytes, 28, 3);
}

fn makeTestGlb(allocator: std.mem.Allocator) ![]u8 {
    const json =
        \\{"asset":{"version":"2.0"},"nodes":[{"name":"root"}],"skins":[{"joints":[0]}],"buffers":[{"byteLength":32}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":8},{"buffer":0,"byteOffset":8,"byteLength":24}],"accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"SCALAR"},{"bufferView":1,"componentType":5126,"count":2,"type":"VEC3"}],"animations":[{"name":"move","samplers":[{"input":0,"output":1}],"channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    ;
    const json_len = std.mem.alignForward(usize, json.len, 4);
    const total_len = 12 + 8 + json_len + 8 + 32;
    const glb = try allocator.alloc(u8, total_len);
    @memset(glb, 0);
    std.mem.writeInt(u32, glb[0..4], 0x46546c67, .little);
    std.mem.writeInt(u32, glb[4..8], 2, .little);
    std.mem.writeInt(u32, glb[8..12], @intCast(total_len), .little);
    std.mem.writeInt(u32, glb[12..16], @intCast(json_len), .little);
    std.mem.writeInt(u32, glb[16..20], 0x4e4f534a, .little);
    @memset(glb[20 .. 20 + json_len], ' ');
    @memcpy(glb[20 .. 20 + json.len], json);
    const bin_header = 20 + json_len;
    std.mem.writeInt(u32, glb[bin_header..][0..4], 32, .little);
    std.mem.writeInt(u32, glb[bin_header + 4 ..][0..4], 0x004e4942, .little);
    testAnimationBinary(glb[bin_header + 8 ..][0..32]);
    return glb;
}

test "gltf2ozz_bad_content" {
    try std.testing.expectError(
        ozz.gltf.Error.ParseFailed,
        ozz.gltf.importSkeleton(std.testing.allocator, "bad content", 0),
    );
}

test "gltf2ozz_glb_animation" {
    const allocator = std.testing.allocator;
    const glb = try makeTestGlb(allocator);
    defer allocator.free(glb);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "animation.glb", .data = glb });
    const path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/animation.glb",
        .{&tmp.sub_path},
    );
    defer allocator.free(path);

    var raw = try ozz.gltf.importSkeleton(allocator, glb, 0);
    defer raw.deinit();
    var skeleton = try ozz.offline.SkeletonBuilder.build(allocator, raw);
    defer skeleton.deinit();
    const animations = try ozz.gltf.importAnimationsFileWithOptions(
        allocator,
        path,
        skeleton,
        .{ .io = std.testing.io },
    );
    defer ozz.gltf.deinitAnimations(allocator, animations);
    try std.testing.expectEqual(@as(usize, 1), animations.len);
    try std.testing.expectEqualStrings("move", animations[0].name);
    const joint = ozz.animation.findJoint(skeleton, "root").?;
    try std.testing.expectEqual(@as(usize, 2), animations[0].tracks[joint].translations.len);
    try h.expectFloat3(
        .{ 1, 2, 3 },
        animations[0].tracks[joint].translations[1].value,
    );
}

test "gltf2ozz_missing_external_buffer" {
    const allocator = std.testing.allocator;
    const source =
        \\{"asset":{"version":"2.0"},"nodes":[{"name":"root"}],"skins":[{"joints":[0]}],"buffers":[{"byteLength":32,"uri":"missing.bin"}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":8},{"buffer":0,"byteOffset":8,"byteLength":24}],"accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"SCALAR"},{"bufferView":1,"componentType":5126,"count":2,"type":"VEC3"}],"animations":[{"samplers":[{"input":0,"output":1}],"channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "missing.gltf", .data = source });
    const path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/missing.gltf",
        .{&tmp.sub_path},
    );
    defer allocator.free(path);

    var raw = try ozz.gltf.importSkeleton(allocator, source, 0);
    defer raw.deinit();
    var skeleton = try ozz.offline.SkeletonBuilder.build(allocator, raw);
    defer skeleton.deinit();
    try std.testing.expectError(
        ozz.gltf.Error.BufferLoadFailed,
        ozz.gltf.importAnimationsFileWithOptions(
            allocator,
            path,
            skeleton,
            .{ .io = std.testing.io },
        ),
    );
}

test "gltf2ozz_skel_simple" {
    const bytes = try readFixture(std.testing.allocator, "media/gltf/khronos/interpolation_test.gltf");
    defer std.testing.allocator.free(bytes);
    var raw = try ozz.gltf.importSkeleton(std.testing.allocator, bytes, 0);
    defer raw.deinit();
    try std.testing.expect(raw.roots.len > 0);
    var skeleton = try ozz.offline.SkeletonBuilder.build(std.testing.allocator, raw);
    defer skeleton.deinit();
    try std.testing.expect(skeleton.numJoints() > 0);
}

test "gltf2ozz_skel_triangle_node_hierarchy" {
    const bytes = try readFixture(std.testing.allocator, "media/gltf/khronos/triangle.gltf");
    defer std.testing.allocator.free(bytes);
    var raw = try ozz.gltf.importSkeleton(std.testing.allocator, bytes, 0);
    defer raw.deinit();
    try std.testing.expect(raw.roots.len > 0);
}

test "gltf2ozz_skel_cesium" {
    const bytes = try readFixture(std.testing.allocator, "media/gltf/khronos/cesium_man.gltf");
    defer std.testing.allocator.free(bytes);
    var raw = try ozz.gltf.importSkeleton(std.testing.allocator, bytes, 0);
    defer raw.deinit();
    var skeleton = try ozz.offline.SkeletonBuilder.build(std.testing.allocator, raw);
    defer skeleton.deinit();
    try std.testing.expect(skeleton.numJoints() > 1);
}

fn importFixtureAnimations(relative: []const u8) !void {
    const allocator = std.testing.allocator;
    const path = try h.fixturePath(allocator, relative);
    defer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(32 * 1024 * 1024),
    );
    defer allocator.free(bytes);
    var raw_skeleton = try ozz.gltf.importSkeleton(allocator, bytes, 0);
    defer raw_skeleton.deinit();
    var skeleton = try ozz.offline.SkeletonBuilder.build(allocator, raw_skeleton);
    defer skeleton.deinit();
    const animations = try ozz.gltf.importAnimationsFile(allocator, path, skeleton);
    defer ozz.gltf.deinitAnimations(allocator, animations);
    try std.testing.expect(animations.len > 0);
    for (animations) |raw_animation| {
        try std.testing.expect(raw_animation.validate());
        var runtime_animation = try ozz.offline.AnimationBuilder.build(allocator, raw_animation);
        defer runtime_animation.deinit();
        var context = try ozz.animation.SamplingContext.init(allocator, runtime_animation.numTracks());
        defer context.deinit();
        const output = try allocator.alloc(ozz.math.SoaTransform, runtime_animation.numSoaTracks());
        defer allocator.free(output);
        try ozz.animation.sample(&runtime_animation, 0.5, &context, output);
    }
}

test "gltf2ozz_animation_multiple" {
    try importFixtureAnimations("media/gltf/khronos/interpolation_test.gltf");
}

test "gltf2ozz preserves step, samples cubic, and pads rest pose channels" {
    const allocator = std.testing.allocator;
    const path = try h.fixturePath(allocator, "media/gltf/khronos/interpolation_test.gltf");
    defer allocator.free(path);
    const bytes = try readFixture(allocator, "media/gltf/khronos/interpolation_test.gltf");
    defer allocator.free(bytes);
    var raw_skeleton = try ozz.gltf.importSkeleton(allocator, bytes, 0);
    defer raw_skeleton.deinit();
    var skeleton = try ozz.offline.SkeletonBuilder.build(allocator, raw_skeleton);
    defer skeleton.deinit();

    const animations = try ozz.gltf.importAnimationsFileWithOptions(
        allocator,
        path,
        skeleton,
        .{ .sampling_rate = 30 },
    );
    defer ozz.gltf.deinitAnimations(allocator, animations);
    try std.testing.expectEqual(@as(usize, 9), animations.len);

    const step_joint = ozz.animation.findJoint(skeleton, "Cube").?;
    const cubic_joint = ozz.animation.findJoint(skeleton, "Cube.008").?;
    const linear_joint = ozz.animation.findJoint(skeleton, "Cube.009").?;
    var step_clip: ?*const ozz.offline.RawAnimation = null;
    var cubic_clip: ?*const ozz.offline.RawAnimation = null;
    var linear_clip: ?*const ozz.offline.RawAnimation = null;
    for (animations) |*clip| {
        if (std.mem.eql(u8, clip.name, "Step Scale")) step_clip = clip;
        if (std.mem.eql(u8, clip.name, "CubicSpline Translation")) cubic_clip = clip;
        if (std.mem.eql(u8, clip.name, "Linear Translation")) linear_clip = clip;
    }

    const step_keys = step_clip.?.tracks[step_joint].scales;
    try std.testing.expectEqual(@as(usize, 9), step_keys.len);
    try h.expectFloat3(step_keys[0].value, step_keys[1].value);
    try std.testing.expect(step_keys[1].time < step_keys[2].time);
    try std.testing.expectEqual(
        std.math.nextAfter(f32, step_keys[2].time, 0),
        step_keys[1].time,
    );

    // ceil(1.6666667 * 30) + the final duration key.
    try std.testing.expectEqual(@as(usize, 51), cubic_clip.?.tracks[cubic_joint].translations.len);
    try std.testing.expectEqual(@as(usize, 5), linear_clip.?.tracks[linear_joint].translations.len);

    const unrelated_joint = ozz.animation.findJoint(skeleton, "Cube.001").?;
    const padded = step_clip.?.tracks[unrelated_joint];
    try std.testing.expectEqual(@as(usize, 1), padded.translations.len);
    try std.testing.expectEqual(@as(usize, 1), padded.rotations.len);
    try std.testing.expectEqual(@as(usize, 1), padded.scales.len);
    try h.expectTransform(skeleton.jointRestPose(unrelated_joint), .{
        .translation = padded.translations[0].value,
        .rotation = padded.rotations[0].value,
        .scale = padded.scales[0].value,
    });
}

test "gltf2ozz_box_animation" {
    try importFixtureAnimations("media/gltf/khronos/box_animated.gltf");
}

test "gltf2ozz_cesium_animation" {
    try importFixtureAnimations("media/gltf/khronos/cesium_man.gltf");
}

test "gltf2ozz_rigged_simple_animation" {
    try importFixtureAnimations("media/gltf/khronos/rigged_simple.gltf");
}

test "gltf2ozz_ruby_animation" {
    try importFixtureAnimations("media/gltf/sketchfab/ruby/scene.gltf");
}

test "gltf2ozz_triangle_has_no_animation" {
    const allocator = std.testing.allocator;
    const relative = "media/gltf/khronos/triangle.gltf";
    const path = try h.fixturePath(allocator, relative);
    defer allocator.free(path);
    const bytes = try readFixture(allocator, relative);
    defer allocator.free(bytes);
    var raw = try ozz.gltf.importSkeleton(allocator, bytes, 0);
    defer raw.deinit();
    var skeleton = try ozz.offline.SkeletonBuilder.build(allocator, raw);
    defer skeleton.deinit();
    try std.testing.expectError(
        ozz.gltf.Error.MissingAnimation,
        ozz.gltf.importAnimationsFile(allocator, path, skeleton),
    );
}
