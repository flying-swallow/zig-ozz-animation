// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/framework/renderer.h`'s `Color` plus the
//! `kRed` / `kGreen` / ... constants.
//!
//! Upstream stores a colour as four `float`s in `[0,1]`. This port stores four
//! `u8` instead, because every vertex stream that carries a colour is declared
//! as an `rgba8_unorm` attribute (see `samples/shaders/*.slang`), so the packed
//! form is what actually reaches the GPU. `toFloats` / `fromFloats` convert
//! back and forth for the places that still want the normalized form.

const std = @import("std");

/// An RGBA colour, one byte per channel. `extern` so a slice of them can be
/// memcpy'd straight into a vertex buffer as `rgba8_unorm`.
pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    /// Expand to normalized `[0,1]` floats, the representation upstream uses.
    pub fn toFloats(self: Color) [4]f32 {
        return .{
            @as(f32, @floatFromInt(self.r)) / 255.0,
            @as(f32, @floatFromInt(self.g)) / 255.0,
            @as(f32, @floatFromInt(self.b)) / 255.0,
            @as(f32, @floatFromInt(self.a)) / 255.0,
        };
    }

    /// Quantize normalized `[0,1]` floats. Values outside the range are clamped
    /// rather than wrapped, and rounding is to-nearest so `1.0` maps to `255`.
    pub fn fromFloats(v: [4]f32) Color {
        return .{
            .r = quantize(v[0]),
            .g = quantize(v[1]),
            .b = quantize(v[2]),
            .a = quantize(v[3]),
        };
    }
};

fn quantize(value: f32) u8 {
    if (!(value > 0)) return 0; // also catches NaN
    if (value >= 1) return 255;
    return @intFromFloat(@round(value * 255.0));
}

pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
pub const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
pub const green: Color = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
pub const blue: Color = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
pub const yellow: Color = .{ .r = 255, .g = 255, .b = 0, .a = 255 };
pub const magenta: Color = .{ .r = 255, .g = 0, .b = 255, .a = 255 };
pub const cyan: Color = .{ .r = 0, .g = 255, .b = 255, .a = 255 };
pub const grey: Color = .{ .r = 128, .g = 128, .b = 128, .a = 255 };
/// Upstream's `kBlack` is `{.5f, .5f, .5f, 1}` — a copy/paste of `kGrey`. This
/// port uses an actual black, since nothing upstream relies on the bug.
pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

test "Color is four tightly packed bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Color));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Color, "r"));
    try std.testing.expectEqual(@as(usize, 3), @offsetOf(Color, "a"));
}

test "toFloats / fromFloats round-trip the canonical constants" {
    for ([_]Color{ white, red, green, blue, yellow, magenta, cyan, grey, black }) |color| {
        try std.testing.expectEqual(color, Color.fromFloats(color.toFloats()));
    }
}

test "fromFloats clamps and rounds" {
    try std.testing.expectEqual(white, Color.fromFloats(.{ 2, 1, 1.5, 1 }));
    try std.testing.expectEqual(black, Color.fromFloats(.{ -1, 0, -0.5, 1 }));
    // .5f -> 127.5 -> 128, matching the u8 spelling of upstream's kGrey.
    try std.testing.expectEqual(grey, Color.fromFloats(.{ 0.5, 0.5, 0.5, 1 }));
}

test "default alpha is opaque" {
    const c: Color = .{ .r = 1, .g = 2, .b = 3 };
    try std.testing.expectEqual(@as(u8, 255), c.a);
}
