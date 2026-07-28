// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/framework/internal/shooter.{h,cc}` — screenshot
//! and video capture.
//!
//! Upstream keeps a small ring of pixel-buffer objects so `glMapBuffer` is delayed
//! two frames and the capture never stalls the frame it was requested in. The same
//! shape is reproduced here on top of the RHI: a ring of host-visible readback
//! buffers, each filled by a `copy_texture_to_buffer` recorded into the frame's
//! command buffer and written out only once the timeline says that frame's GPU work
//! has retired.
//!
//! **Metal is a no-op.** `rhi.Cmd.copy_texture_to_buffer` `@panic`s on the Metal
//! backend, so the whole module short-circuits on Apple targets and logs a single
//! warning the first time a capture is asked for. `capture` then returns `false`,
//! which tells the application to keep its usual `render_target -> present`
//! barrier.

const std = @import("std");
const builtin = @import("builtin");
const rhi = @import("rhi");

const image = @import("image.zig");

/// False on Apple targets, where `copy_texture_to_buffer` panics.
pub const supported = builtin.os.tag != .macos and builtin.os.tag != .ios;

/// Number of readback buffers kept in flight. Upstream uses two (its PBO map is
/// delayed exactly two frames); three matches this backend's frames-in-flight so a
/// continuous video capture never has to drop a frame.
pub const num_shots = 3;

/// Bytes per captured pixel. Every swapchain format this framework asks for is an
/// 8-bit 4-channel one.
pub const bytes_per_pixel = 4;

var warned_unsupported: bool = false;

/// Logs the "capture is unavailable" notice at most once per process.
fn warnUnsupported() void {
    if (warned_unsupported) return;
    warned_unsupported = true;
    std.log.warn(
        "screen capture is disabled: rhi's copy_texture_to_buffer is not implemented on the Metal backend",
        .{},
    );
}

/// Builds upstream's `"%06d.tga"` file name into `buffer`.
pub fn shotFileName(buffer: []u8, number: u32) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print("{d:0>6}.tga", .{number}) catch {};
    return writer.buffered();
}

/// Index of the first shot that is not waiting on the GPU, or null when every
/// readback in the ring is still in flight (the frame is then simply not captured,
/// exactly like upstream's "no shot with `cooldown == 0`" case).
pub fn pickSlot(busy: [num_shots]bool) ?usize {
    for (busy, 0..) |in_flight, index| {
        if (!in_flight) return index;
    }
    return null;
}

/// Maps the swapchain's colour format onto the TGA writer's source layout.
///
/// The RHI does not publish the swapchain format neutrally, so this reaches into
/// the Vulkan backend field (guarded at comptime); anything unrecognised falls back
/// to RGBA, which is what upstream does when the GL implementation refuses to
/// report a preferred read-back format.
pub fn swapchainFormat(swapchain: *rhi.Swapchain) image.Format {
    if (comptime rhi.platform_has_api(.vk)) {
        if (rhi.is_target_selected(.vk)) {
            return switch (swapchain.backend.vk.image_format) {
                .b8g8r8a8_unorm, .b8g8r8a8_srgb => .bgra,
                else => .rgba,
            };
        }
    }
    return .rgba;
}

/// One in-flight readback: a host-visible buffer plus the timeline value that has
/// to retire before its contents may be read.
const Shot = struct {
    buffer: rhi.Buffer = .{},
    /// Bytes the buffer was created with (0 when it has none yet).
    capacity: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: image.Format = .rgba,
    /// A copy was recorded this frame but the submit has not happened yet.
    armed: bool = false,
    /// Timeline value that must complete before the pixels are readable
    /// (0 when the shot is idle).
    wait_value: u64 = 0,

    fn busy(self: Shot) bool {
        return self.armed or self.wait_value != 0;
    }
};

/// Screenshot / video capture ring.
pub const Shooter = struct {
    /// Clock- and file-system-carrying `std.Io`, used by `image.writeTga`.
    io: std.Io,
    shots: [num_shots]Shot = @splat(.{}),
    /// Incrementing number used to name the files, like upstream's `shot_number_`.
    shot_number: u32 = 0,

    pub fn init(io: std.Io) Shooter {
        return .{ .io = io };
    }

    pub fn deinit(self: *Shooter, device: *rhi.Device) void {
        if (comptime !supported) return;
        for (&self.shots) |*shot| {
            if (!shot.buffer.isEmpty()) shot.buffer.deinit(device);
            shot.* = .{};
        }
    }

    /// Records the read-back of `source` into a free ring slot.
    ///
    /// Must be called **after** `cmd.end_rendering`. On success the image is left in
    /// the `.copy_src` state, which is what the caller has to use as the `before`
    /// state of its `.present` barrier; when this returns `false` nothing was
    /// recorded and the image is untouched.
    pub fn capture(
        self: *Shooter,
        device: *rhi.Device,
        cmd: *rhi.Cmd,
        source: *rhi.Image,
        width: u32,
        height: u32,
        format: image.Format,
    ) !bool {
        if (comptime !supported) {
            warnUnsupported();
            return false;
        }
        if (width == 0 or height == 0) return false;

        var busy: [num_shots]bool = undefined;
        for (self.shots, &busy) |shot, *flag| flag.* = shot.busy();
        const slot = pickSlot(busy) orelse return false;
        const shot = &self.shots[slot];

        const needed = @as(usize, width) * @as(usize, height) * bytes_per_pixel;
        if (shot.capacity < needed) {
            // The slot is idle, so its previous copy has already retired and the
            // buffer can be replaced without synchronising.
            if (!shot.buffer.isEmpty()) shot.buffer.deinit(device);
            shot.buffer = try rhi.Buffer.init_general(device, .{
                .size = needed,
                .persistant_map = true,
                .sequential_access = false,
                .usage = .{},
                .buffer_usage = .prefer_host,
            });
            shot.capacity = needed;
        }
        shot.width = width;
        shot.height = height;
        shot.format = format;

        cmd.image_barrier(device, .{
            .image = source,
            .before = .{ .render_target = true },
            .after = .{ .copy_src = true },
        });
        cmd.copy_texture_to_buffer(device, .{
            .src = source,
            .dst = &shot.buffer,
            .width = width,
            .height = height,
        });
        cmd.buffer_barrier(device, .{
            .buffer = &shot.buffer,
            .before = .{ .copy_dst = true },
            .after = .{ .host_read = true },
        });

        shot.armed = true;
        return true;
    }

    /// Binds every copy recorded since the last `seal` to the timeline value the
    /// frame's submit signalled. Call right after `Swapchain.frame_submit`.
    pub fn seal(self: *Shooter, pending: u64) void {
        if (comptime !supported) return;
        for (&self.shots) |*shot| {
            if (!shot.armed) continue;
            shot.armed = false;
            shot.wait_value = pending;
        }
    }

    /// Writes out every readback whose frame the GPU has finished, mirroring
    /// upstream's `Shooter::Update` / `Process`.
    pub fn update(self: *Shooter, completed: u64) void {
        if (comptime !supported) return;
        for (&self.shots) |*shot| {
            if (shot.armed or shot.wait_value == 0) continue;
            if (completed < shot.wait_value) continue;
            shot.wait_value = 0;
            self.write(shot);
        }
    }

    /// Drains the ring on shutdown (upstream's `ProcessAll`).
    ///
    /// **The caller must have idled the queue first.** `rhi.Timeline.wait` does not
    /// compile at the pinned revision (`timeline.zig:86` passes a single pointer
    /// where a many-pointer is expected), so there is no way to block on an
    /// individual value here; `application.zig` calls `wait_queue_idle` immediately
    /// before this.
    pub fn flush(self: *Shooter) void {
        if (comptime !supported) return;
        for (&self.shots) |*shot| {
            if (shot.armed or shot.wait_value == 0) continue;
            shot.wait_value = 0;
            self.write(shot);
        }
    }

    /// Number of readbacks still waiting on the GPU.
    pub fn inFlight(self: Shooter) usize {
        var count: usize = 0;
        for (self.shots) |shot| {
            if (shot.busy()) count += 1;
        }
        return count;
    }

    fn write(self: *Shooter, shot: *Shot) void {
        const mapped = shot.buffer.mapped_region orelse return;
        const needed = @as(usize, shot.width) * @as(usize, shot.height) * bytes_per_pixel;
        if (mapped.len < needed) return;

        var name_buffer: [32]u8 = undefined;
        const name = shotFileName(&name_buffer, self.shot_number);
        self.shot_number += 1;

        // A Vulkan read-back hands back the top row first; TGA stores rows
        // bottom-up, hence `flip_y = true` (upstream reads an OpenGL framebuffer,
        // which is already bottom-up, and passes false).
        image.writeTga(
            self.io,
            name,
            shot.width,
            shot.height,
            shot.format,
            mapped[0..needed],
            true,
        ) catch |err| {
            std.log.err("failed to write screenshot '{s}': {t}", .{ name, err });
        };
    }
};

// ---------------------------------------------------------------------------
// Tests — the ring bookkeeping and the file naming are pure and run headless.
// ---------------------------------------------------------------------------

test "shot file names match upstream's %06d.tga" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("000000.tga", shotFileName(&buffer, 0));
    try std.testing.expectEqualStrings("000042.tga", shotFileName(&buffer, 42));
    try std.testing.expectEqualStrings("123456.tga", shotFileName(&buffer, 123456));
    // More digits than the pad simply widens the name instead of truncating it.
    try std.testing.expectEqualStrings("1234567.tga", shotFileName(&buffer, 1234567));
}

test "pickSlot returns the first idle readback" {
    try std.testing.expectEqual(@as(?usize, 0), pickSlot(@splat(false)));
    try std.testing.expectEqual(@as(?usize, null), pickSlot(@splat(true)));

    var busy: [num_shots]bool = @splat(true);
    busy[num_shots - 1] = false;
    try std.testing.expectEqual(@as(?usize, num_shots - 1), pickSlot(busy));
}

test "a shot is busy from the moment it is armed until the timeline retires it" {
    var shot: Shot = .{};
    try std.testing.expect(!shot.busy());

    shot.armed = true;
    try std.testing.expect(shot.busy());

    // `seal` moves it from "recorded" to "waiting on this timeline value".
    shot.armed = false;
    shot.wait_value = 7;
    try std.testing.expect(shot.busy());

    shot.wait_value = 0;
    try std.testing.expect(!shot.busy());
}

test "seal only claims the shots recorded this frame" {
    var shooter: Shooter = .{ .io = undefined };
    shooter.shots[0].armed = true;
    shooter.shots[2].wait_value = 3;

    shooter.seal(11);
    if (comptime supported) {
        try std.testing.expectEqual(@as(u64, 11), shooter.shots[0].wait_value);
        try std.testing.expect(!shooter.shots[0].armed);
        // An older, already-sealed shot keeps its own value.
        try std.testing.expectEqual(@as(u64, 3), shooter.shots[2].wait_value);
        try std.testing.expectEqual(@as(usize, 2), shooter.inFlight());
    }
}
