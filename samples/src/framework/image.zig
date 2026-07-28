// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/framework/image.{h,cc}` — TGA writing only.
//!
//! Unlike upstream this writer emits *uncompressed* true-colour TARGA (image
//! type 2) rather than RLE (image type 10): screenshots are written once and
//! read by tools, so the packet loop buys nothing and the flat layout keeps the
//! writer allocation-free.

const std = @import("std");

/// Byte layout of a source pixel.
pub const Format = enum {
    rgb,
    bgr,
    rgba,
    bgra,

    /// Number of bytes per source pixel.
    pub fn stride(self: Format) usize {
        return switch (self) {
            .rgb, .bgr => 3,
            .rgba, .bgra => 4,
        };
    }

    /// Whether the source carries an alpha channel.
    pub fn hasAlpha(self: Format) bool {
        return switch (self) {
            .rgb, .bgr => false,
            .rgba, .bgra => true,
        };
    }

    /// Bits per pixel written to the TGA file: 24 without alpha, 32 with.
    pub fn depth(self: Format) u8 {
        return if (self.hasAlpha()) 32 else 24;
    }
};

/// Errors `writeTga` can raise on top of the file-system ones.
pub const Error = error{
    /// `pixels` is smaller than `width * height * format.stride()`.
    InvalidPixelBuffer,
    /// `width` or `height` does not fit in the 16-bit TGA header fields.
    ImageTooLarge,
};

/// Size of the TARGA header, in bytes.
pub const header_size = 18;

/// Writes `pixels` as an uncompressed TARGA file at `path`, relative to the
/// current working directory.
///
/// `pixels` holds `height` rows of `width` pixels in `format`, first row first.
/// TGA stores rows bottom-up, so pass `flip_y = true` when the source rows run
/// top-down (a Vulkan/D3D readback) and `flip_y = false` when they already run
/// bottom-up (an OpenGL readback, which is what upstream feeds it).
pub fn writeTga(
    io: std.Io,
    path: []const u8,
    width: u32,
    height: u32,
    format: Format,
    pixels: []const u8,
    flip_y: bool,
) !void {
    return writeTgaDir(io, .cwd(), path, width, height, format, pixels, flip_y);
}

/// `writeTga` against an explicit directory handle. Handy for tests and for
/// samples that dump screenshots into a chosen folder.
pub fn writeTgaDir(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    width: u32,
    height: u32,
    format: Format,
    pixels: []const u8,
    flip_y: bool,
) !void {
    if (width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) {
        return Error.ImageTooLarge;
    }
    const stride = format.stride();
    const pitch = @as(usize, width) * stride;
    if (pixels.len < pitch * height) return Error.InvalidPixelBuffer;

    var file = try dir.createFile(io, sub_path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;

    try writer.writeAll(&header(width, height, format));

    // Nothing else to store for a degenerate image.
    if (width == 0 or height == 0) {
        try writer.flush();
        return;
    }

    for (0..height) |row| {
        const source_row = if (flip_y) height - 1 - row else row;
        const line = pixels[source_row * pitch ..][0..pitch];
        switch (format) {
            // Already in TGA's BGR / BGRA order: blit the whole row.
            .bgr, .bgra => try writer.writeAll(line),
            .rgb => {
                var offset: usize = 0;
                while (offset < line.len) : (offset += 3) {
                    try writer.writeAll(&[_]u8{
                        line[offset + 2],
                        line[offset + 1],
                        line[offset + 0],
                    });
                }
            },
            .rgba => {
                var offset: usize = 0;
                while (offset < line.len) : (offset += 4) {
                    try writer.writeAll(&[_]u8{
                        line[offset + 2],
                        line[offset + 1],
                        line[offset + 0],
                        line[offset + 3],
                    });
                }
            },
        }
    }

    try writer.flush();
}

/// Builds the 18-byte TARGA header for an uncompressed true-colour image.
pub fn header(width: u32, height: u32, format: Format) [header_size]u8 {
    const depth = format.depth();
    return .{
        0, // ID length.
        0, // Colour map type: none.
        2, // Image type: uncompressed true-colour.
        0, 0, 0, 0, 0, // Colour map specification: unused.
        0, 0, // X origin.
        0,                 0, // Y origin.
        @truncate(width),  @truncate(width >> 8),
        @truncate(height), @truncate(height >> 8),
        depth,
        // Image descriptor: attribute bit count, bottom-left origin.
                    if (format.hasAlpha()) 8 else 0,
    };
}

test "format traits" {
    try std.testing.expectEqual(@as(usize, 3), Format.rgb.stride());
    try std.testing.expectEqual(@as(usize, 3), Format.bgr.stride());
    try std.testing.expectEqual(@as(usize, 4), Format.rgba.stride());
    try std.testing.expectEqual(@as(usize, 4), Format.bgra.stride());
    try std.testing.expect(!Format.rgb.hasAlpha());
    try std.testing.expect(!Format.bgr.hasAlpha());
    try std.testing.expect(Format.rgba.hasAlpha());
    try std.testing.expect(Format.bgra.hasAlpha());
    try std.testing.expectEqual(@as(u8, 24), Format.bgr.depth());
    try std.testing.expectEqual(@as(u8, 32), Format.bgra.depth());
}

test "header encodes dimensions little endian" {
    const bytes = header(640, 480, .rgb);
    try std.testing.expectEqual(@as(u8, 2), bytes[2]);
    try std.testing.expectEqual(@as(u16, 640), std.mem.readInt(u16, bytes[12..14], .little));
    try std.testing.expectEqual(@as(u16, 480), std.mem.readInt(u16, bytes[14..16], .little));
    try std.testing.expectEqual(@as(u8, 24), bytes[16]);
    try std.testing.expectEqual(@as(u8, 0), bytes[17]);

    const alpha = header(1, 2, .bgra);
    try std.testing.expectEqual(@as(u8, 32), alpha[16]);
    try std.testing.expectEqual(@as(u8, 8), alpha[17]);
}

test "writeTga rejects short buffers and oversized images" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const short: [8]u8 = @splat(0);
    try std.testing.expectError(
        Error.InvalidPixelBuffer,
        writeTgaDir(std.testing.io, tmp.dir, "short.tga", 2, 2, .rgb, &short, false),
    );
    try std.testing.expectError(
        Error.ImageTooLarge,
        writeTgaDir(std.testing.io, tmp.dir, "big.tga", 70000, 1, .rgb, &short, false),
    );
}

test "writeTga round trip rgba" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // 2x2 RGBA source, rows top-down: red, green / blue, translucent white.
    const pixels = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 128,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTgaDir(io, tmp.dir, "rgba.tga", 2, 2, .rgba, &pixels, true);

    const bytes = try tmp.dir.readFileAlloc(io, "rgba.tga", allocator, .limited(4096));
    defer allocator.free(bytes);

    // Header.
    try std.testing.expectEqual(@as(usize, header_size + 2 * 2 * 4), bytes.len);
    try std.testing.expectEqual(@as(u8, 0), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0), bytes[1]);
    try std.testing.expectEqual(@as(u8, 2), bytes[2]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[12..14], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[14..16], .little));
    try std.testing.expectEqual(@as(u8, 32), bytes[16]);
    try std.testing.expectEqual(@as(u8, 8), bytes[17]);

    // `flip_y` means the last source row is stored first, and the components
    // are swizzled from RGBA to BGRA.
    const body = bytes[header_size..];
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, body[0..4]); // blue
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 128 }, body[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, body[8..12]); // red
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, body[12..16]); // green
}

test "writeTga round trip rgb without flip" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // 3x2 RGB source.
    const pixels = [_]u8{
        1,  2,  3,  4,  5,  6,  7,  8,  9,
        10, 11, 12, 13, 14, 15, 16, 17, 18,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTgaDir(io, tmp.dir, "rgb.tga", 3, 2, .rgb, &pixels, false);

    const bytes = try tmp.dir.readFileAlloc(io, "rgb.tga", allocator, .limited(4096));
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, header_size + 3 * 2 * 3), bytes.len);
    try std.testing.expectEqual(@as(u8, 24), bytes[16]);
    try std.testing.expectEqual(@as(u8, 0), bytes[17]);

    const body = bytes[header_size..];
    // Row order preserved, RGB swizzled to BGR.
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1 }, body[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 6, 5, 4 }, body[3..6]);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7 }, body[6..9]);
    try std.testing.expectEqualSlices(u8, &.{ 12, 11, 10 }, body[9..12]);
    try std.testing.expectEqualSlices(u8, &.{ 18, 17, 16 }, body[15..18]);
}

test "writeTga blits bgr rows verbatim" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6 };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTgaDir(io, tmp.dir, "bgr.tga", 2, 1, .bgr, &pixels, false);

    const bytes = try tmp.dir.readFileAlloc(io, "bgr.tga", allocator, .limited(4096));
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &pixels, bytes[header_size..]);
}

test "writeTga writes a header only image for empty dimensions" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTgaDir(io, tmp.dir, "empty.tga", 0, 0, .rgb, &.{}, false);

    const bytes = try tmp.dir.readFileAlloc(io, "empty.tga", allocator, .limited(4096));
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, header_size), bytes.len);
}
