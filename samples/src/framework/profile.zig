// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/framework/profile.{h,cc}`.
//!
//! `Record` keeps the most recent `capacity` samples in a circular buffer and
//! rejects the oldest ones, exactly like upstream's `ozz::sample::Record`.
//! `Profiler` is the RAII timer that feeds a record with milliseconds.

const std = @import("std");

/// Statistics of the values currently held by a `Record`.
///
/// The defaults are upstream's "no record" sentinels (`FLT_MAX` / `-FLT_MAX`),
/// so an empty record reports `min > max`.
pub const Statistics = struct {
    /// Smallest recorded value.
    min: f32 = std.math.floatMax(f32),
    /// Largest recorded value.
    max: f32 = -std.math.floatMax(f32),
    /// Arithmetic mean of the recorded values.
    mean: f32 = 0,
    /// Most recently pushed value.
    latest: f32 = 0,
};

/// Circular buffer of at most `capacity` `f32` samples.
///
/// The raw storage is circular; `values()` linearises it into an internal
/// scratch array so callers (graphs) always see the samples oldest-first.
pub fn Record(comptime capacity: usize) type {
    comptime std.debug.assert(capacity >= 1);
    return struct {
        const Self = @This();

        /// Maximum number of simultaneously recorded values.
        pub const max_records: usize = capacity;

        /// Circular storage. `head` is the slot the next `push` writes to.
        buffer: [capacity]f32 = @splat(0),
        /// Scratch used by `values()` to expose the samples oldest-first.
        ordered: [capacity]f32 = @splat(0),
        /// Number of valid samples, saturating at `capacity`.
        count: usize = 0,
        /// Index of the slot the next `push` writes to.
        head: usize = 0,

        /// Returns an empty record.
        pub fn init() Self {
            return .{};
        }

        /// Adds `value`, dropping the oldest sample once the buffer is full.
        pub fn push(self: *Self, value: f32) void {
            self.buffer[self.head] = value;
            self.head = (self.head + 1) % capacity;
            if (self.count < capacity) self.count += 1;
        }

        /// Forgets every recorded value.
        pub fn clear(self: *Self) void {
            self.count = 0;
            self.head = 0;
        }

        /// Number of samples currently recorded.
        pub fn len(self: Self) usize {
            return self.count;
        }

        /// Index of the newest sample **within the slice returned by
        /// `values()`** (that is `count - 1`, or 0 when the record is empty).
        ///
        /// This is the value `im.doGraph` expects for its `cursor` argument.
        pub fn cursor(self: Self) usize {
            return if (self.count == 0) 0 else self.count - 1;
        }

        /// Recorded samples, oldest first.
        ///
        /// The returned slice aliases an internal scratch buffer and is
        /// invalidated by the next call to `values()` on the same record.
        pub fn values(self: *Self) []const f32 {
            const start = self.oldestIndex();
            for (0..self.count) |index| {
                self.ordered[index] = self.buffer[(start + index) % capacity];
            }
            return self.ordered[0..self.count];
        }

        /// Min / max / mean / latest of the recorded samples.
        pub fn statistics(self: Self) Statistics {
            var result: Statistics = .{};
            if (self.count == 0) return result;

            const start = self.oldestIndex();
            var sum: f32 = 0;
            for (0..self.count) |index| {
                const value = self.buffer[(start + index) % capacity];
                if (value < result.min) result.min = value;
                if (value > result.max) result.max = value;
                sum += value;
            }
            result.mean = sum / @as(f32, @floatFromInt(self.count));
            result.latest = self.buffer[(start + self.count - 1) % capacity];
            return result;
        }

        /// Index of the oldest sample in the circular `buffer`.
        fn oldestIndex(self: Self) usize {
            return (self.head + capacity - self.count) % capacity;
        }
    };
}

/// The record type samples use for per-frame timings.
pub const FrameRecord = Record(128);

/// Scoped timer: `begin` starts the measure, `end` pushes the elapsed
/// milliseconds into the record it was started with.
///
/// Zig 0.17 moved the monotonic clock behind `std.Io`, so — unlike the API
/// sketch — `begin` takes the `io` it should read the clock from and stashes
/// it; `end` and `elapsedMs` need nothing else.
///
/// ```zig
/// var profiler = Profiler.begin(io, &self.update_time);
/// defer profiler.end();
/// ```
pub const Profiler = struct {
    /// Clock source, captured at `begin`.
    io: std.Io,
    /// Monotonic clock reading at `begin`, in nanoseconds.
    begin_ns: i96,
    /// Type-erased pointer to the destination `Record`.
    context: *anyopaque,
    /// Type-erased `Record.push`.
    push_fn: *const fn (*anyopaque, f32) void,
    /// Guards against a double `end` (explicit call plus a `defer`).
    stopped: bool = false,

    /// Clock the profiler measures against.
    pub const clock: std.Io.Clock = .awake;

    /// Starts a measure. `record` must be a mutable pointer to a `Record`.
    pub fn begin(io: std.Io, record: anytype) Profiler {
        const Pointer = @TypeOf(record);
        const Erased = struct {
            fn push(context: *anyopaque, value: f32) void {
                const typed: Pointer = @ptrCast(@alignCast(context));
                typed.push(value);
            }
        };
        return .{
            .io = io,
            .begin_ns = clock.now(io).nanoseconds,
            .context = @ptrCast(record),
            .push_fn = Erased.push,
        };
    }

    /// Ends the measure and pushes the elapsed milliseconds. Idempotent.
    pub fn end(self: *Profiler) void {
        if (self.stopped) return;
        self.stopped = true;
        self.push_fn(self.context, self.elapsedMs());
    }

    /// Milliseconds elapsed since `begin`, without ending the measure.
    pub fn elapsedMs(self: Profiler) f32 {
        const elapsed = clock.now(self.io).nanoseconds - self.begin_ns;
        const milliseconds = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms;
        return @floatCast(milliseconds);
    }
};

test "record starts empty" {
    var record = Record(4).init();
    try std.testing.expectEqual(@as(usize, 0), record.len());
    try std.testing.expectEqual(@as(usize, 0), record.values().len);
    try std.testing.expectEqual(@as(usize, 0), record.cursor());

    const stats = record.statistics();
    try std.testing.expectEqual(std.math.floatMax(f32), stats.min);
    try std.testing.expectEqual(-std.math.floatMax(f32), stats.max);
    try std.testing.expectEqual(@as(f32, 0), stats.mean);
    try std.testing.expectEqual(@as(f32, 0), stats.latest);
}

test "record values are oldest first before wrapping" {
    var record = Record(4).init();
    record.push(1);
    record.push(2);
    record.push(3);

    try std.testing.expectEqual(@as(usize, 3), record.len());
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, record.values());
    try std.testing.expectEqual(@as(usize, 2), record.cursor());
    try std.testing.expectEqual(@as(f32, 3), record.values()[record.cursor()]);
}

test "record values stay oldest first across a wrap" {
    var record = Record(4).init();
    // Push more than the capacity so the circular buffer wraps.
    for ([_]f32{ 1, 2, 3, 4, 5, 6 }) |value| record.push(value);

    try std.testing.expectEqual(@as(usize, 4), record.len());
    try std.testing.expectEqualSlices(f32, &.{ 3, 4, 5, 6 }, record.values());
    try std.testing.expectEqual(@as(usize, 3), record.cursor());
    try std.testing.expectEqual(@as(f32, 6), record.values()[record.cursor()]);

    // One more push rotates the window by exactly one sample.
    record.push(7);
    try std.testing.expectEqualSlices(f32, &.{ 4, 5, 6, 7 }, record.values());
}

test "record wraps exactly on a capacity boundary" {
    var record = Record(3).init();
    for ([_]f32{ 1, 2, 3 }) |value| record.push(value);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, record.values());
    record.push(4);
    try std.testing.expectEqualSlices(f32, &.{ 2, 3, 4 }, record.values());
    record.push(5);
    record.push(6);
    try std.testing.expectEqualSlices(f32, &.{ 4, 5, 6 }, record.values());
}

test "record statistics" {
    var record = Record(4).init();
    for ([_]f32{ 4, -2, 10, 0, 6 }) |value| record.push(value);

    // The oldest sample (4) has been rejected.
    try std.testing.expectEqualSlices(f32, &.{ -2, 10, 0, 6 }, record.values());
    const stats = record.statistics();
    try std.testing.expectEqual(@as(f32, -2), stats.min);
    try std.testing.expectEqual(@as(f32, 10), stats.max);
    try std.testing.expectEqual(@as(f32, 3.5), stats.mean);
    try std.testing.expectEqual(@as(f32, 6), stats.latest);
}

test "record of capacity one keeps the latest value" {
    var record = Record(1).init();
    record.push(11);
    record.push(22);
    try std.testing.expectEqualSlices(f32, &.{22}, record.values());
    try std.testing.expectEqual(@as(f32, 22), record.statistics().latest);
}

test "record clear" {
    var record = FrameRecord.init();
    record.push(1);
    record.push(2);
    record.clear();
    try std.testing.expectEqual(@as(usize, 0), record.len());
    try std.testing.expectEqual(@as(usize, 0), record.values().len);
}

test "profiler pushes a millisecond duration once" {
    var record = FrameRecord.init();
    var profiler = Profiler.begin(std.testing.io, &record);

    // Busy wait rather than sleep, so the test does not depend on the Io
    // implementation being able to suspend.
    var guard: usize = 0;
    while (profiler.elapsedMs() < 1 and guard < 100_000_000) : (guard += 1) {}

    profiler.end();
    profiler.end(); // idempotent

    try std.testing.expectEqual(@as(usize, 1), record.len());
    const stats = record.statistics();
    try std.testing.expect(stats.latest >= 1);
    try std.testing.expect(stats.latest < 60_000);
}
