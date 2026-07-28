//! Layout-independent serialization for Caliper vector types.
//!
//! Vector lanes are encoded individually so native SIMD size, alignment, and
//! padding never become part of an on-disk format.

const std = @import("std");
const caliper = @import("caliper");

fn writeF32(
    writer: *std.Io.Writer,
    value: f32,
    endian: std.builtin.Endian,
) std.Io.Writer.Error!void {
    try writer.writeInt(u32, @bitCast(value), endian);
}

fn readF32(
    reader: *std.Io.Reader,
    endian: std.builtin.Endian,
) std.Io.Reader.Error!f32 {
    return @bitCast(try reader.takeInt(u32, endian));
}

pub fn writeVec2f32(
    writer: *std.Io.Writer,
    value: caliper.Vec2f32,
    endian: std.builtin.Endian,
) std.Io.Writer.Error!void {
    try writeF32(writer, value[0], endian);
    try writeF32(writer, value[1], endian);
}

pub fn readVec2f32(
    reader: *std.Io.Reader,
    endian: std.builtin.Endian,
) std.Io.Reader.Error!caliper.Vec2f32 {
    return .{
        try readF32(reader, endian),
        try readF32(reader, endian),
    };
}

pub fn writeVec3f32(
    writer: *std.Io.Writer,
    value: caliper.Vec3f32,
    endian: std.builtin.Endian,
) std.Io.Writer.Error!void {
    try writeF32(writer, value[0], endian);
    try writeF32(writer, value[1], endian);
    try writeF32(writer, value[2], endian);
}

pub fn readVec3f32(
    reader: *std.Io.Reader,
    endian: std.builtin.Endian,
) std.Io.Reader.Error!caliper.Vec3f32 {
    return .{
        try readF32(reader, endian),
        try readF32(reader, endian),
        try readF32(reader, endian),
    };
}

test "Vec2f32 and Vec3f32 round trip in both endiannesses" {
    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
        var bytes: [20]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        const expected2: caliper.Vec2f32 = .{ 1.25, -3.5 };
        const expected3: caliper.Vec3f32 = .{ 1, -2, 0.5 };
        try writeVec2f32(&writer, expected2, endian);
        try writeVec3f32(&writer, expected3, endian);

        var reader = std.Io.Reader.fixed(writer.buffered());
        try std.testing.expectEqual(expected2, try readVec2f32(&reader, endian));
        try std.testing.expectEqual(expected3, try readVec3f32(&reader, endian));
    }
}

test "Vec3f32 encoding is lane-based and endian-aware" {
    const value: caliper.Vec3f32 = .{ 1, -2, 0.5 };
    const expected_little = [_]u8{
        0x00, 0x00, 0x80, 0x3f,
        0x00, 0x00, 0x00, 0xc0,
        0x00, 0x00, 0x00, 0x3f,
    };
    const expected_big = [_]u8{
        0x3f, 0x80, 0x00, 0x00,
        0xc0, 0x00, 0x00, 0x00,
        0x3f, 0x00, 0x00, 0x00,
    };

    var little_bytes: [12]u8 = undefined;
    var little_writer = std.Io.Writer.fixed(&little_bytes);
    try writeVec3f32(&little_writer, value, .little);
    try std.testing.expectEqualSlices(u8, &expected_little, little_writer.buffered());

    var big_bytes: [12]u8 = undefined;
    var big_writer = std.Io.Writer.fixed(&big_bytes);
    try writeVec3f32(&big_writer, value, .big);
    try std.testing.expectEqualSlices(u8, &expected_big, big_writer.buffered());
}
