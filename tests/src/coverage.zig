const std = @import("std");
const h = @import("helpers.zig");

const Status = enum { ported, adapted, not_applicable };

fn sourceStatus(path: []const u8) Status {
    if (std.mem.startsWith(u8, path, "animation/offline/fbx/") or
        std.mem.startsWith(u8, path, "base/containers/") or
        std.mem.startsWith(u8, path, "base/memory/") or
        std.mem.eql(u8, path, "base/log_tests.cc") or
        std.mem.eql(u8, path, "base/platform_tests.cc") or
        std.mem.eql(u8, path, "base/span_tests.cc") or
        std.mem.indexOf(u8, path, "options_registration") != null or
        std.mem.startsWith(u8, path, "sub/"))
    {
        return .not_applicable;
    }
    if (std.mem.startsWith(u8, path, "base/") or
        std.mem.startsWith(u8, path, "options/") or
        std.mem.indexOf(u8, path, "tools/") != null)
    {
        return .adapted;
    }
    return .ported;
}

test "upstream test inventory is pinned and completely classified" {
    const allocator = std.testing.allocator;
    const root = try h.fixturePath(allocator, "test");
    defer allocator.free(root);
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer directory.close(std.testing.io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();

    var source_count: usize = 0;
    var google_test_count: usize = 0;
    var ctest_count: usize = 0;
    var ported_sources: usize = 0;
    var adapted_sources: usize = 0;
    var excluded_sources: usize = 0;

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".cc") and
            !std.mem.eql(u8, entry.basename, "CMakeLists.txt"))
        {
            continue;
        }
        const bytes = try entry.dir.readFileAlloc(
            std.testing.io,
            entry.basename,
            allocator,
            .limited(2 * 1024 * 1024),
        );
        defer allocator.free(bytes);
        if (std.mem.endsWith(u8, entry.basename, ".cc")) {
            source_count += 1;
            google_test_count += std.mem.count(u8, bytes, "TEST(");
            switch (sourceStatus(entry.path)) {
                .ported => ported_sources += 1,
                .adapted => adapted_sources += 1,
                .not_applicable => excluded_sources += 1,
            }
        } else {
            ctest_count += std.mem.count(u8, bytes, "add_test(");
        }
    }

    try std.testing.expectEqual(@as(usize, 68), source_count);
    try std.testing.expectEqual(@as(usize, 386), google_test_count);
    try std.testing.expectEqual(@as(usize, 233), ctest_count);
    try std.testing.expectEqual(source_count, ported_sources + adapted_sources + excluded_sources);
    try std.testing.expect(ported_sources > 0);
    try std.testing.expect(adapted_sources > 0);
    try std.testing.expect(excluded_sources > 0);
}
