const std = @import("std");
const h = @import("helpers.zig");

const Status = enum {
    ported,
    ported_adapted,
    partial_adapted,
    adapted,
    not_applicable,
};

const Source = struct {
    path: []const u8,
    tests: usize,
    status: Status,
};

// This is the machine-readable counterpart of CONFORMANCE.md. Keeping every
// source explicit makes an upstream addition, removal, rename, or reclassification
// fail the inventory guard instead of silently inheriting a broad path status.
const sources = [_]Source{
    .{ .path = "animation/offline/additive_animation_builder_tests.cc", .tests = 3, .status = .ported },
    .{ .path = "animation/offline/animation_builder_tests.cc", .tests = 6, .status = .ported_adapted },
    .{ .path = "animation/offline/animation_optimizer_tests.cc", .tests = 4, .status = .partial_adapted },
    .{ .path = "animation/offline/fbx/fuse_ozz_animation_fbx_tests.cc", .tests = 0, .status = .not_applicable },
    .{ .path = "animation/offline/motion_extractor_tests.cc", .tests = 2, .status = .partial_adapted },
    .{ .path = "animation/offline/raw_animation_archive_tests.cc", .tests = 3, .status = .ported_adapted },
    .{ .path = "animation/offline/raw_animation_archive_versioning_tests.cc", .tests = 1, .status = .ported_adapted },
    .{ .path = "animation/offline/raw_animation_utils_tests.cc", .tests = 6, .status = .ported_adapted },
    .{ .path = "animation/offline/raw_skeleton_archive_tests.cc", .tests = 3, .status = .ported_adapted },
    .{ .path = "animation/offline/raw_skeleton_archive_versioning_tests.cc", .tests = 1, .status = .ported_adapted },
    .{ .path = "animation/offline/raw_track_archive_tests.cc", .tests = 7, .status = .ported_adapted },
    .{ .path = "animation/offline/raw_track_utils_tests.cc", .tests = 6, .status = .ported_adapted },
    .{ .path = "animation/offline/skeleton_builder_tests.cc", .tests = 8, .status = .ported_adapted },
    .{ .path = "animation/offline/tools/test2ozz.cc", .tests = 0, .status = .not_applicable },
    .{ .path = "animation/offline/track_builder_tests.cc", .tests = 13, .status = .ported_adapted },
    .{ .path = "animation/offline/track_optimizer_tests.cc", .tests = 11, .status = .ported },
    .{ .path = "animation/runtime/animation_archive_tests.cc", .tests = 3, .status = .partial_adapted },
    .{ .path = "animation/runtime/animation_archive_versioning_tests.cc", .tests = 1, .status = .partial_adapted },
    .{ .path = "animation/runtime/animation_utils_tests.cc", .tests = 1, .status = .partial_adapted },
    .{ .path = "animation/runtime/blending_job_tests.cc", .tests = 9, .status = .partial_adapted },
    .{ .path = "animation/runtime/ik_aim_job_tests.cc", .tests = 12, .status = .partial_adapted },
    .{ .path = "animation/runtime/ik_two_bone_job_tests.cc", .tests = 12, .status = .partial_adapted },
    .{ .path = "animation/runtime/local_to_model_job_tests.cc", .tests = 5, .status = .partial_adapted },
    .{ .path = "animation/runtime/motion_blending_job_tests.cc", .tests = 3, .status = .partial_adapted },
    .{ .path = "animation/runtime/sampling_job_tests.cc", .tests = 9, .status = .partial_adapted },
    .{ .path = "animation/runtime/skeleton_archive_tests.cc", .tests = 3, .status = .partial_adapted },
    .{ .path = "animation/runtime/skeleton_archive_versioning_tests.cc", .tests = 1, .status = .partial_adapted },
    .{ .path = "animation/runtime/skeleton_utils_tests.cc", .tests = 6, .status = .partial_adapted },
    .{ .path = "animation/runtime/track_archive_tests.cc", .tests = 8, .status = .partial_adapted },
    .{ .path = "animation/runtime/track_sampling_job_tests.cc", .tests = 9, .status = .partial_adapted },
    .{ .path = "animation/runtime/track_triggering_job_tests.cc", .tests = 12, .status = .partial_adapted },
    .{ .path = "animation/runtime/track_triggering_job_trait_tests.cc", .tests = 1, .status = .partial_adapted },
    .{ .path = "base/containers/intrusive_list_tests.cc", .tests = 24, .status = .not_applicable },
    .{ .path = "base/containers/std_containers_archive_tests.cc", .tests = 3, .status = .not_applicable },
    .{ .path = "base/containers/std_containers_tests.cc", .tests = 13, .status = .not_applicable },
    .{ .path = "base/encode/group_varint_tests.cc", .tests = 6, .status = .not_applicable },
    .{ .path = "base/endianness_tests.cc", .tests = 2, .status = .adapted },
    .{ .path = "base/io/archive_tests.cc", .tests = 7, .status = .adapted },
    .{ .path = "base/io/archive_tests_objects.cc", .tests = 0, .status = .adapted },
    .{ .path = "base/io/stream_tests.cc", .tests = 2, .status = .not_applicable },
    .{ .path = "base/log_tests.cc", .tests = 4, .status = .not_applicable },
    .{ .path = "base/maths/box_tests.cc", .tests = 5, .status = .adapted },
    .{ .path = "base/maths/math_archive_tests.cc", .tests = 1, .status = .adapted },
    .{ .path = "base/maths/math_ex_tests.cc", .tests = 4, .status = .adapted },
    .{ .path = "base/maths/quaternion_tests.cc", .tests = 9, .status = .adapted },
    .{ .path = "base/maths/rect_tests.cc", .tests = 2, .status = .adapted },
    .{ .path = "base/maths/simd_float4x4_tests.cc", .tests = 11, .status = .not_applicable },
    .{ .path = "base/maths/simd_float_math_tests.cc", .tests = 19, .status = .not_applicable },
    .{ .path = "base/maths/simd_int_math_tests.cc", .tests = 13, .status = .not_applicable },
    .{ .path = "base/maths/simd_math_archive_tests.cc", .tests = 1, .status = .not_applicable },
    .{ .path = "base/maths/simd_math_transpose_tests.cc", .tests = 1, .status = .not_applicable },
    .{ .path = "base/maths/simd_quaternion_math_tests.cc", .tests = 7, .status = .not_applicable },
    .{ .path = "base/maths/soa_float4x4_tests.cc", .tests = 5, .status = .not_applicable },
    .{ .path = "base/maths/soa_float_tests.cc", .tests = 12, .status = .not_applicable },
    .{ .path = "base/maths/soa_math_archive_tests.cc", .tests = 1, .status = .not_applicable },
    .{ .path = "base/maths/soa_quaternion_tests.cc", .tests = 2, .status = .not_applicable },
    .{ .path = "base/maths/soa_transform_tests.cc", .tests = 1, .status = .not_applicable },
    .{ .path = "base/maths/transform_tests.cc", .tests = 1, .status = .adapted },
    .{ .path = "base/maths/vec_float_tests.cc", .tests = 12, .status = .adapted },
    .{ .path = "base/memory/allocator_tests.cc", .tests = 4, .status = .not_applicable },
    .{ .path = "base/memory/unique_ptr_tests.cc", .tests = 8, .status = .not_applicable },
    .{ .path = "base/platform_tests.cc", .tests = 8, .status = .not_applicable },
    .{ .path = "base/span_tests.cc", .tests = 5, .status = .not_applicable },
    .{ .path = "geometry/runtime/skinning_job_tests.cc", .tests = 3, .status = .ported_adapted },
    .{ .path = "options/options_registration_empty_tests.cc", .tests = 3, .status = .not_applicable },
    .{ .path = "options/options_registration_tests.cc", .tests = 3, .status = .not_applicable },
    .{ .path = "options/options_tests.cc", .tests = 15, .status = .adapted },
    .{ .path = "sub/test_sub_project.cc", .tests = 0, .status = .not_applicable },
};

fn findSource(path: []const u8) ?Source {
    for (sources) |source| {
        if (std.mem.eql(u8, path, source.path)) return source;
    }
    return null;
}

test "upstream test inventory is pinned and explicitly classified" {
    const allocator = std.testing.allocator;
    const root = try h.fixturePath(allocator, "test");
    defer allocator.free(root);
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer directory.close(std.testing.io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();

    var seen: [sources.len]bool = @splat(false);
    var source_count: usize = 0;
    var google_test_count: usize = 0;
    var ctest_count: usize = 0;
    var status_counts: [@typeInfo(Status).@"enum".field_names.len]usize = @splat(0);

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.basename, ".cc")) {
            const source = findSource(entry.path) orelse {
                std.debug.print("unclassified upstream source: {s}\n", .{entry.path});
                return error.UnclassifiedUpstreamSource;
            };
            const index = for (sources, 0..) |candidate, i| {
                if (std.mem.eql(u8, candidate.path, source.path)) break i;
            } else unreachable;
            if (seen[index]) return error.DuplicateUpstreamSource;
            seen[index] = true;

            const bytes = try entry.dir.readFileAlloc(
                std.testing.io,
                entry.basename,
                allocator,
                .limited(2 * 1024 * 1024),
            );
            defer allocator.free(bytes);
            const declarations = std.mem.count(u8, bytes, "TEST(");
            if (declarations != source.tests) {
                std.debug.print(
                    "upstream declaration count changed for {s}: expected {}, found {}\n",
                    .{ source.path, source.tests, declarations },
                );
                return error.UpstreamDeclarationCountChanged;
            }
            source_count += 1;
            google_test_count += declarations;
            status_counts[@backingInt(source.status)] += 1;
        } else if (std.mem.eql(u8, entry.basename, "CMakeLists.txt")) {
            const bytes = try entry.dir.readFileAlloc(
                std.testing.io,
                entry.basename,
                allocator,
                .limited(2 * 1024 * 1024),
            );
            defer allocator.free(bytes);
            ctest_count += std.mem.count(u8, bytes, "add_test(");
        }
    }

    for (sources, seen) |source, was_seen| {
        if (!was_seen) {
            std.debug.print("manifest source missing upstream: {s}\n", .{source.path});
            return error.ManifestSourceMissingUpstream;
        }
    }
    try std.testing.expectEqual(sources.len, source_count);
    try std.testing.expectEqual(@as(usize, 386), google_test_count);
    try std.testing.expectEqual(@as(usize, 233), ctest_count);
    for (status_counts) |count| try std.testing.expect(count > 0);
}
