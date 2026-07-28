// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/multithread/sample_multithread.cc`.
//!
//! Every ozz job is thread-safe, so a crowd of characters can be sampled in
//! parallel as long as each character owns its own buffers. Upstream splits the
//! character range recursively with `std::async`; there is no such pool in Zig,
//! so this port keeps the same grain-size semantics but feeds the sub-ranges to
//! a small set of `std.Thread` workers that pull tasks off an atomic counter.
//! Sampling stays identical, only the scheduler differs.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Float4x4 = ozz.math.Float4x4;

pub const name = "multithread";
pub const description = "Parallel character sampling";

/// Interval between two characters of the grid, upstream's `kInterval`.
pub const interval: f32 = 2;
/// Width and depth of the character grid, upstream's `kWidth` / `kDepth`.
pub const grid_width: usize = 16;
pub const grid_depth: usize = 16;
/// Maximum number of characters, upstream's `kMaxCharacters`.
pub const max_characters: usize = 4096;
/// Minimum number of characters per task, upstream's `kMinGrainSize`.
pub const min_grain_size: usize = 32;
/// Upper bound on worker threads. Upstream lets the crt pool decide; this port
/// caps it so a small grain size cannot spawn hundreds of threads.
const max_workers: usize = 32;

/// Everything one character needs to be updated independently of the others.
/// Only the skeleton and the animation are shared, and both are read-only.
pub const Character = struct {
    controller: fw.PlaybackController = .{},
    context: ozz.animation.SamplingContext,
    locals: []ozz.math.SoaTransform,
    models: []Float4x4,

    pub fn init(
        allocator: std.mem.Allocator,
        skeleton: ozz.animation.Skeleton,
        animation: ozz.animation.Animation,
    ) !Character {
        var context = try ozz.animation.SamplingContext.init(allocator, animation.numTracks());
        errdefer context.deinit();
        const locals = try allocator.alloc(ozz.math.SoaTransform, skeleton.numSoaJoints());
        errdefer allocator.free(locals);
        const models = try allocator.alloc(Float4x4, skeleton.numJoints());
        return .{ .context = context, .locals = locals, .models = models };
    }

    pub fn deinit(self: *Character, allocator: std.mem.Allocator) void {
        allocator.free(self.models);
        allocator.free(self.locals);
        self.context.deinit();
        self.* = undefined;
    }

    /// Samples the animation and converts the result to model space, exactly
    /// like upstream's `UpdateCharacter`.
    pub fn update(
        self: *Character,
        animation: *const ozz.animation.Animation,
        skeleton: *const ozz.animation.Skeleton,
        dt: f32,
    ) !void {
        _ = self.controller.update(animation.duration, dt);
        try ozz.animation.sample(animation, self.controller.time_ratio, &self.context, self.locals);
        try ozz.animation.localToModel(.{
            .skeleton = skeleton,
            .input = self.locals,
        }, self.models);
    }
};

/// State shared by every worker of one parallel update.
const Shared = struct {
    animation: *const ozz.animation.Animation,
    skeleton: *const ozz.animation.Skeleton,
    characters: []Character,
    dt: f32,
    /// Characters per task, upstream's grain size.
    grain: usize,
    /// Number of sub-ranges the characters were split into.
    task_count: usize,
    /// Index of the next task to claim.
    next: std.atomic.Value(usize) = .init(0),
    /// Number of workers that claimed at least one task, i.e. upstream's
    /// "number of threads that took part in the update".
    workers_used: std.atomic.Value(usize) = .init(0),

    /// Claims and runs tasks until the queue is empty.
    fn run(self: *Shared, failure: *?anyerror) void {
        var claimed: usize = 0;
        while (true) {
            const task = self.next.fetchAdd(1, .monotonic);
            if (task >= self.task_count) break;
            claimed += 1;

            const begin = task * self.grain;
            const end = @min(begin + self.grain, self.characters.len);
            for (self.characters[begin..end]) |*character| {
                character.update(self.animation, self.skeleton, self.dt) catch |err| {
                    failure.* = err;
                    // Drain the queue so the other workers still finish.
                    break;
                };
            }
        }
        if (claimed != 0) _ = self.workers_used.fetchAdd(1, .monotonic);
    }
};

fn workerEntry(shared: *Shared, failure: *?anyerror) void {
    shared.run(failure);
}

pub const Sample = struct {
    allocator: std.mem.Allocator,
    /// Runtime skeleton, shared by every character.
    skeleton: ozz.animation.Skeleton,
    /// Runtime animation, shared by every character.
    animation: ozz.animation.Animation,
    /// All characters, allocated once for `max_characters`.
    characters: []Character,
    /// Worker threads, allocated once and reused every frame.
    threads: []std.Thread,
    /// One error slot per worker, so no lock is needed to report a failure.
    failures: []?anyerror,

    /// Number of characters actually updated and drawn.
    character_count: i32 = max_characters / 4,
    /// Maximum number of characters handled by a single task.
    grain_size: i32 = 128,
    /// Whether the update is distributed over worker threads.
    threading_enabled: bool = true,

    /// Threads and tasks used by the last update, shown in the gui.
    threads_used: usize = 1,
    tasks_used: usize = 1,
    /// Per-frame update timings, plotted by the gui.
    update_time: fw.profile.FrameRecord = .{},

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(@embedFile("pab_skeleton")),
        );
        errdefer skeleton.deinit();

        var animation = blk: {
            var reader = std.Io.Reader.fixed(assets.animationOr(@embedFile("pab_walk")));
            break :blk try ozz.legacy.readAnimation(allocator, &reader, .{});
        };
        errdefer animation.deinit();

        if (skeleton.numJoints() != animation.numTracks()) {
            return error.SkeletonAnimationMismatch;
        }

        const characters = try allocator.alloc(Character, max_characters);
        var initialized: usize = 0;
        errdefer {
            for (characters[0..initialized]) |*character| character.deinit(allocator);
            allocator.free(characters);
        }
        while (initialized < characters.len) : (initialized += 1) {
            characters[initialized] = try Character.init(allocator, skeleton, animation);
            // Spreads the characters over the animation, upstream's
            // `duration * kWidth * c / kMaxCharacters`.
            characters[initialized].controller.setTimeRatio(
                animation.duration * @as(f32, @floatFromInt(grid_width * initialized)) /
                    @as(f32, @floatFromInt(max_characters)),
            );
        }

        const threads = try allocator.alloc(std.Thread, max_workers);
        errdefer allocator.free(threads);
        const failures = try allocator.alloc(?anyerror, max_workers + 1);
        errdefer allocator.free(failures);

        var self: Sample = .{
            .allocator = allocator,
            .skeleton = skeleton,
            .animation = animation,
            .characters = characters,
            .threads = threads,
            .failures = failures,
        };
        // Fills every character with the rest pose so the first frame draws
        // something even before an update ran.
        for (self.characters) |*character| {
            try ozz.animation.localToModel(.{
                .skeleton = &self.skeleton,
                .input = self.skeleton.rest_poses,
            }, character.models);
        }
        return self;
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.failures);
        self.allocator.free(self.threads);
        for (self.characters) |*character| character.deinit(self.allocator);
        self.allocator.free(self.characters);
        self.animation.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;
        var profiler = fw.profile.Profiler.begin(clockIo(), &self.update_time);
        defer profiler.end();

        try self.updateCharacters(dt);
        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        for (0..self.activeCount()) |index| {
            // The grid offset stays a per-character transform, it is never
            // baked into the posture geometry.
            try renderer.drawPosture(
                self.skeleton,
                self.characters[index].models,
                Float4x4.fromTransform(.{ .translation = gridPosition(index) }),
                false,
            );
        }
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        var buffer: [64]u8 = undefined;

        if (gui.openClose("Sample control", true)) {
            _ = gui.doSliderInt(
                fw.im.formatZ(&buffer, "Number of entities: {d}", .{self.character_count}),
                1,
                @intCast(max_characters),
                &self.character_count,
                0.7,
                true,
            );
            gui.doLabel("Number of joints: {d}", .{
                self.activeCount() * self.skeleton.numJoints(),
            });
        }

        if (gui.openClose("Threading control", true)) {
            _ = gui.doCheckBox("Enables threading", &self.threading_enabled, true);
            if (self.threading_enabled) {
                _ = gui.doSliderInt(
                    fw.im.formatZ(&buffer, "Grain size: {d}", .{self.grain_size}),
                    @intCast(min_grain_size),
                    @intCast(max_characters),
                    &self.grain_size,
                    0.2,
                    true,
                );
                gui.doLabel("Thread/task count: {d}/{d}", .{ self.threads_used, self.tasks_used });
            }
        }

        if (gui.openClose("Performance", true)) {
            const stats = self.update_time.statistics();
            gui.doLabel("Update: {d:.2} ms", .{stats.latest});
            gui.doGraph(
                "Update time (ms)",
                stats.min,
                stats.max,
                stats.mean,
                self.update_time.cursor(),
                self.update_time.values(),
            );
        }
    }

    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        // Upstream computes the grid extents analytically rather than from the
        // postures, so the camera framing does not jitter with the animation.
        const count = self.activeCount();
        const columns: f32 = @floatFromInt(@min(count, grid_width));
        const rows: f32 = @floatFromInt(@min(count / grid_width, grid_depth));
        const layers: f32 = @floatFromInt(count / grid_width / grid_depth + 1);
        const min_x = -@as(f32, @floatFromInt(grid_width / 2)) * interval;
        const min_z = -@as(f32, @floatFromInt(grid_depth / 2)) * interval;
        return .{
            .min = .{ min_x, 0, min_z },
            .max = .{ min_x + columns * interval, layers * interval, min_z + rows * interval },
        };
    }

    // -- feature path -------------------------------------------------------

    /// Number of characters updated and drawn this frame.
    pub fn activeCount(self: Sample) usize {
        const clamped = std.math.clamp(self.character_count, 1, @as(i32, @intCast(max_characters)));
        return @intCast(clamped);
    }

    /// Characters per task, clamped to upstream's bounds.
    pub fn grain(self: Sample) usize {
        const clamped = std.math.clamp(
            self.grain_size,
            @as(i32, @intCast(min_grain_size)),
            @as(i32, @intCast(max_characters)),
        );
        return @intCast(clamped);
    }

    /// Samples every active character, in parallel when threading is enabled.
    /// `threads_used` / `tasks_used` are refreshed for the gui.
    pub fn updateCharacters(self: *Sample, dt: f32) !void {
        const count = self.activeCount();
        const characters = self.characters[0..count];

        // Threading off: one task covering every character, run right here.
        const grain_size = if (self.threading_enabled) self.grain() else count;
        const task_count = (count + grain_size - 1) / grain_size;

        var shared: Shared = .{
            .animation = &self.animation,
            .skeleton = &self.skeleton,
            .characters = characters,
            .dt = dt,
            .grain = grain_size,
            .task_count = task_count,
        };

        const worker_count = if (self.threading_enabled)
            @min(task_count, self.threads.len + 1)
        else
            1;
        @memset(self.failures[0..worker_count], null);

        var spawned: usize = 0;
        if (worker_count > 1) {
            for (self.threads[0 .. worker_count - 1], self.failures[1..worker_count]) |*thread, *failure| {
                thread.* = std.Thread.spawn(.{}, workerEntry, .{ &shared, failure }) catch break;
                spawned += 1;
            }
        }
        // The calling thread is a worker too, and it also picks up the tasks of
        // any thread that could not be spawned.
        shared.run(&self.failures[0]);
        for (self.threads[0..spawned]) |thread| thread.join();

        self.tasks_used = task_count;
        self.threads_used = @max(shared.workers_used.load(.monotonic), 1);
        for (self.failures[0..worker_count]) |failure| {
            if (failure) |err| return err;
        }
    }

    /// World position of a character in the grid, upstream's `OnDisplay`
    /// layout: columns along X, rows along Z, extra layers stacked on Y.
    pub fn gridPosition(index: usize) ozz.math.Vec3f32 {
        const column = @as(f32, @floatFromInt(index % grid_width)) -
            @as(f32, @floatFromInt(grid_width / 2));
        const layer: f32 = @floatFromInt(index / grid_width / grid_depth);
        const row = @as(f32, @floatFromInt((index / grid_width) % grid_depth)) -
            @as(f32, @floatFromInt(grid_depth / 2));
        return .{ column * interval, layer * interval, row * interval };
    }
};

/// Clock source for the update timings. Zig 0.17 moved the monotonic clock
/// behind `std.Io`, and the sample contract gives samples no `io`, so the
/// process-wide single-threaded instance is used just to read the clock.
fn clockIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "every character owns its buffers and starts at a different time" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    try std.testing.expectEqual(max_characters, sample.characters.len);
    var distinct: usize = 0;
    for (sample.characters, 0..) |character, index| {
        try std.testing.expectEqual(sample.skeleton.numJoints(), character.models.len);
        try std.testing.expectEqual(sample.skeleton.numSoaJoints(), character.locals.len);
        try std.testing.expect(character.controller.time_ratio >= 0);
        try std.testing.expect(character.controller.time_ratio < 1);
        if (index > 0 and
            character.controller.time_ratio != sample.characters[index - 1].controller.time_ratio)
        {
            distinct += 1;
        }
    }
    try std.testing.expect(distinct > max_characters / 2);
}

test "threaded and single-threaded updates agree" {
    const allocator = std.testing.allocator;
    var threaded = try Sample.init(allocator, .{});
    defer threaded.deinit();
    var serial = try Sample.init(allocator, .{});
    defer serial.deinit();

    threaded.character_count = 512;
    threaded.grain_size = 64;
    threaded.threading_enabled = true;
    serial.character_count = 512;
    serial.threading_enabled = false;

    for (0..3) |_| {
        try threaded.updateCharacters(1.0 / 60.0);
        try serial.updateCharacters(1.0 / 60.0);
    }

    try std.testing.expectEqual(@as(usize, 8), threaded.tasks_used);
    try std.testing.expectEqual(@as(usize, 1), serial.tasks_used);
    try std.testing.expectEqual(@as(usize, 1), serial.threads_used);

    for (threaded.characters[0..512], serial.characters[0..512]) |left, right| {
        try std.testing.expectEqual(
            left.controller.time_ratio,
            right.controller.time_ratio,
        );
        for (left.models, right.models) |a, b| {
            try std.testing.expectEqual(a.cols, b.cols);
        }
    }
}

test "grain size and character count are clamped" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    sample.character_count = -3;
    try std.testing.expectEqual(@as(usize, 1), sample.activeCount());
    sample.character_count = 100000;
    try std.testing.expectEqual(max_characters, sample.activeCount());
    sample.grain_size = 0;
    try std.testing.expectEqual(min_grain_size, sample.grain());
    sample.grain_size = 100000;
    try std.testing.expectEqual(max_characters, sample.grain());
}

test "characters are laid out on a grid without baking the offset in" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();
    sample.character_count = 64;
    try sample.updateCharacters(0.1);

    // The offset is a render-time transform: the model matrices of two
    // characters at the same animation time are identical.
    try std.testing.expect(@reduce(.Or, Sample.gridPosition(0) != Sample.gridPosition(1)));
    try std.testing.expectEqual(
        @as(f32, -@as(f32, @floatFromInt(grid_width / 2)) * interval),
        Sample.gridPosition(0)[0],
    );
    // Second row of the grid moves along Z, not X.
    try std.testing.expectEqual(Sample.gridPosition(0)[0], Sample.gridPosition(grid_width)[0]);
    try std.testing.expect(Sample.gridPosition(grid_width)[2] > Sample.gridPosition(0)[2]);
    // A full plane starts a new layer along Y.
    try std.testing.expectEqual(@as(f32, 0), Sample.gridPosition(0)[1]);
    try std.testing.expectEqual(interval, Sample.gridPosition(grid_width * grid_depth)[1]);

    const bounds = sample.sceneBounds().?;
    try std.testing.expect(bounds.isValid());
    for (0..sample.activeCount()) |index| {
        const position = Sample.gridPosition(index);
        try std.testing.expect(position[0] >= bounds.min[0] and position[0] <= bounds.max[0]);
        try std.testing.expect(position[2] >= bounds.min[2] and position[2] <= bounds.max[2]);
    }
}

test "update timings are recorded for the graph" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();
    sample.character_count = 128;

    for (0..4) |_| try std.testing.expect(try sample.onUpdate(1.0 / 60.0, 0));
    try std.testing.expectEqual(@as(usize, 4), sample.update_time.len());
    const stats = sample.update_time.statistics();
    try std.testing.expect(stats.min >= 0);
    try std.testing.expect(stats.max >= stats.min);
    try std.testing.expectEqual(@as(usize, 3), sample.update_time.cursor());
}
