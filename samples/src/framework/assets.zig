// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Command-line asset overrides. Every sample embeds the upstream archives it needs,
//! but each can be replaced at run time with `--skeleton=`, `--animation=`, `--mesh=`,
//! `--floor=`, `--track=` or `--raw=`, matching the upstream `ozz::options` flags.

const std = @import("std");

pub const Assets = struct {
    skeleton: ?[]const u8 = null,
    animation: ?[]const u8 = null,
    mesh: ?[]const u8 = null,
    floor: ?[]const u8 = null,
    track: ?[]const u8 = null,
    raw: ?[]const u8 = null,

    pub fn skeletonOr(self: Assets, embedded: []const u8) []const u8 {
        return self.skeleton orelse embedded;
    }

    pub fn animationOr(self: Assets, embedded: []const u8) []const u8 {
        return self.animation orelse embedded;
    }

    pub fn meshOr(self: Assets, embedded: []const u8) []const u8 {
        return self.mesh orelse embedded;
    }

    pub fn floorOr(self: Assets, embedded: []const u8) []const u8 {
        return self.floor orelse embedded;
    }

    pub fn trackOr(self: Assets, embedded: []const u8) []const u8 {
        return self.track orelse embedded;
    }

    pub fn rawOr(self: Assets, embedded: []const u8) []const u8 {
        return self.raw orelse embedded;
    }
};

test "overrides fall back to the embedded archive" {
    const embedded = "embedded";
    const empty: Assets = .{};
    try std.testing.expectEqualStrings(embedded, empty.skeletonOr(embedded));

    const overridden: Assets = .{ .skeleton = "override" };
    try std.testing.expectEqualStrings("override", overridden.skeletonOr(embedded));
    try std.testing.expectEqualStrings(embedded, overridden.animationOr(embedded));
}
