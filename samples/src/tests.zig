// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Cross-sample baseline: every sample must construct, update and expose its GUI
//! without a GPU. Each sample's own feature-path assertions live in its file and are
//! run by the per-sample test artifacts (`zig build test`).

const std = @import("std");
const fw = @import("framework");

const samples = .{
    .{ "additive", @import("additive") },
    .{ "attach", @import("attach") },
    .{ "baked", @import("baked") },
    .{ "blend", @import("blend") },
    .{ "foot_ik", @import("foot_ik") },
    .{ "look_at", @import("look_at") },
    .{ "millipede", @import("millipede") },
    .{ "motion_blend", @import("motion_blend") },
    .{ "motion_extraction", @import("motion_extraction") },
    .{ "motion_playback", @import("motion_playback") },
    .{ "multithread", @import("multithread") },
    .{ "optimize", @import("optimize") },
    .{ "partial_blend", @import("partial_blend") },
    .{ "playback", @import("playback") },
    .{ "skinning", @import("skinning") },
    .{ "two_bone_ik", @import("two_bone_ik") },
    .{ "user_channel", @import("user_channel") },
};

/// Drives one sample through the headless part of the application loop.
fn exercise(comptime module: type) !void {
    var sample = try module.Sample.init(std.testing.allocator, .{});
    defer sample.deinit();

    var gui = fw.Im.init(false);
    var time: f32 = 0;
    for (0..8) |_| {
        const dt = 1.0 / 60.0;
        time += dt;
        try std.testing.expect(try sample.onUpdate(dt, time));
        sample.onGui(&gui);
        if (@hasDecl(module.Sample, "onFloatingGui")) sample.onFloatingGui(&gui);
    }

    // A paused frame must be harmless.
    try std.testing.expect(try sample.onUpdate(0, time));
}

test "every sample runs headless" {
    inline for (samples) |entry| {
        exercise(entry[1]) catch |err| {
            std.debug.print("sample '{s}' failed: {t}\n", .{ entry[0], err });
            return err;
        };
    }
}

test "every sample satisfies the Application contract" {
    inline for (samples) |entry| {
        const module = entry[1];
        const Sample = module.Sample;
        comptime {
            std.debug.assert(@hasDecl(module, "name"));
            for (&[_][]const u8{ "init", "deinit", "onUpdate", "onDisplay", "onGui" }) |decl| {
                if (!@hasDecl(Sample, decl)) {
                    @compileError(entry[0] ++ " is missing required decl " ++ decl);
                }
            }
        }
        try std.testing.expectEqualStrings(entry[0], module.name);
    }
}

test "scene bounds, when published, are finite" {
    inline for (samples) |entry| {
        const module = entry[1];
        if (@hasDecl(module.Sample, "sceneBounds")) {
            var sample = try module.Sample.init(std.testing.allocator, .{});
            defer sample.deinit();
            try std.testing.expect(try sample.onUpdate(1.0 / 60.0, 1.0 / 60.0));

            if (sample.sceneBounds()) |box| {
                inline for (0..3) |axis| {
                    try std.testing.expect(std.math.isFinite(box.min[axis]));
                    try std.testing.expect(std.math.isFinite(box.max[axis]));
                    try std.testing.expect(box.min[axis] <= box.max[axis]);
                }
            }
        }
    }
}
