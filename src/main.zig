// SPDX-License-Identifier: MIT
const std = @import("std");
const ozz = @import("zig_ozz_animation");

const usage =
    \\usage:
    \\  ozz inspect <archive>
    \\  ozz migrate <legacy.ozz> <native.zozz>
    \\  ozz import <source.gltf|source.glb> --output <directory> [--sampling-rate <hz>]
    \\  ozz config print
    \\
;

const Command = union(enum) {
    help,
    inspect: []const u8,
    migrate: struct {
        input: []const u8,
        output: []const u8,
    },
    import: struct {
        input: []const u8,
        output: []const u8,
        sampling_rate: f32,
    },
    config_print,
};

fn parseCommand(args: []const []const u8) error{InvalidArguments}!Command {
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        if (args.len > 2) return error.InvalidArguments;
        return .help;
    }
    if (std.mem.eql(u8, args[1], "inspect")) {
        if (args.len != 3) return error.InvalidArguments;
        return .{ .inspect = args[2] };
    }
    if (std.mem.eql(u8, args[1], "migrate")) {
        if (args.len != 4) return error.InvalidArguments;
        return .{ .migrate = .{ .input = args[2], .output = args[3] } };
    }
    if (std.mem.eql(u8, args[1], "config")) {
        if (args.len != 3 or !std.mem.eql(u8, args[2], "print")) {
            return error.InvalidArguments;
        }
        return .config_print;
    }
    if (std.mem.eql(u8, args[1], "import")) {
        if ((args.len != 5 and args.len != 7) or !std.mem.eql(u8, args[3], "--output") or
            (args.len == 7 and !std.mem.eql(u8, args[5], "--sampling-rate")))
        {
            return error.InvalidArguments;
        }
        const sampling_rate = if (args.len == 7)
            std.fmt.parseFloat(f32, args[6]) catch return error.InvalidArguments
        else
            0;
        if (!std.math.isFinite(sampling_rate) or sampling_rate < 0) {
            return error.InvalidArguments;
        }
        return .{ .import = .{
            .input = args[2],
            .output = args[4],
            .sampling_rate = sampling_rate,
        } };
    }
    return error.InvalidArguments;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};

    const command = parseCommand(args) catch return fail("invalid arguments\n\n{s}", .{usage});
    switch (command) {
        .help => try stdout.writeAll(usage),
        .inspect => |path| return inspect(init.io, allocator, stdout, path),
        .migrate => |paths| return migrate(init.io, allocator, stdout, paths.input, paths.output),
        .import => |options| return importGltf(
            init.io,
            allocator,
            stdout,
            options.input,
            options.output,
            options.sampling_rate,
        ),
        .config_print => try stdout.writeAll(
            \\{"archive":{"magic":"ZOZZBIN\\u0000","container_version":1,"endianness":"little"},"limits":{"joints":1024},"math":"caliper","gltf":"zgltf","fbx":"disabled","rhi_samples":"disabled"}
            \\
        ),
    }
}

fn importGltf(
    io: std.Io,
    allocator: std.mem.Allocator,
    status: *std.Io.Writer,
    input_path: []const u8,
    output_dir: []const u8,
    sampling_rate: f32,
) !void {
    const bytes = try readInput(io, allocator, input_path);
    var raw = try ozz.gltf.importSkeleton(allocator, bytes, 0);
    defer raw.deinit();
    var skeleton = try ozz.offline.SkeletonBuilder.build(allocator, raw);
    defer skeleton.deinit();

    var raw_output: std.Io.Writer.Allocating = .init(allocator);
    defer raw_output.deinit();
    try ozz.io.writeRawSkeleton(allocator, &raw_output.writer, raw);
    var runtime_output: std.Io.Writer.Allocating = .init(allocator);
    defer runtime_output.deinit();
    try ozz.io.writeSkeleton(allocator, &runtime_output.writer, skeleton);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, output_dir);
    const raw_path = try std.fs.path.join(allocator, &.{ output_dir, "raw_skeleton.zozz" });
    const skeleton_path = try std.fs.path.join(allocator, &.{ output_dir, "skeleton.zozz" });
    try cwd.writeFile(io, .{ .sub_path = raw_path, .data = raw_output.writer.buffered() });
    try cwd.writeFile(io, .{ .sub_path = skeleton_path, .data = runtime_output.writer.buffered() });

    var animation_count: usize = 0;
    const animations_result = ozz.gltf.importAnimationsFileWithOptions(
        allocator,
        input_path,
        skeleton,
        .{ .sampling_rate = sampling_rate, .io = io },
    );
    if (animations_result) |animations| {
        defer ozz.gltf.deinitAnimations(allocator, animations);
        for (animations, 0..) |raw_animation, index| {
            var raw_animation_output: std.Io.Writer.Allocating = .init(allocator);
            defer raw_animation_output.deinit();
            try ozz.io.writeRawAnimation(allocator, &raw_animation_output.writer, raw_animation);
            const raw_animation_path = try std.fmt.allocPrint(
                allocator,
                "{s}/raw_animation_{d}.zozz",
                .{ output_dir, index },
            );
            try cwd.writeFile(io, .{
                .sub_path = raw_animation_path,
                .data = raw_animation_output.writer.buffered(),
            });

            var runtime_animation = try ozz.offline.AnimationBuilder.build(allocator, raw_animation);
            defer runtime_animation.deinit();
            var animation_output: std.Io.Writer.Allocating = .init(allocator);
            defer animation_output.deinit();
            try ozz.io.writeAnimation(allocator, &animation_output.writer, runtime_animation);
            const animation_path = try std.fmt.allocPrint(
                allocator,
                "{s}/animation_{d}.zozz",
                .{ output_dir, index },
            );
            try cwd.writeFile(io, .{
                .sub_path = animation_path,
                .data = animation_output.writer.buffered(),
            });
            animation_count += 1;
        }
    } else |err| switch (err) {
        ozz.gltf.Error.MissingAnimation => {},
        else => return err,
    }

    try status.print("imported {s}: {d} joints, {d} animation{s} -> {s}\n", .{
        input_path,
        skeleton.numJoints(),
        animation_count,
        if (animation_count == 1) "" else "s",
        output_dir,
    });
}

fn fail(comptime format: []const u8, args: anytype) error{InvalidArguments} {
    std.debug.print("ozz: " ++ format ++ "\n", args);
    return error.InvalidArguments;
}

fn readInput(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024 * 1024));
}

fn inspect(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    path: []const u8,
) !void {
    const bytes = try readInput(io, allocator, path);
    if (bytes.len >= ozz.io.magic.len and std.mem.eql(u8, bytes[0..ozz.io.magic.len], ozz.io.magic)) {
        var reader = std.Io.Reader.fixed(bytes);
        const header = try ozz.io.readHeader(&reader, .{});
        try writer.print("format: native\nkind: {s}\nschema: {d}\npayload: {d} bytes\n", .{
            @tagName(header.kind),
            header.schema_version,
            header.payload_len,
        });
    } else {
        const kind = try ozz.legacy.detect(bytes);
        try writer.print("format: legacy ozz\nkind: {s}\nnative-kind: {s}\n", .{
            @tagName(kind),
            @tagName(kind.nativeKind()),
        });
    }
}

fn migrate(
    io: std.Io,
    allocator: std.mem.Allocator,
    status: *std.Io.Writer,
    input_path: []const u8,
    output_path: []const u8,
) !void {
    const bytes = try readInput(io, allocator, input_path);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var offset: usize = 0;
    var object_count: usize = 0;
    var first_kind: ?ozz.legacy.Kind = null;
    while (offset < bytes.len) {
        const view = if (offset == 0) bytes else blk: {
            const prefixed = try allocator.alloc(u8, bytes.len - offset + 1);
            prefixed[0] = bytes[0];
            @memcpy(prefixed[1..], bytes[offset..]);
            break :blk prefixed;
        };
        const kind = try ozz.legacy.detect(view);
        first_kind = first_kind orelse kind;
        const consumed = try migrateOne(kind, allocator, view, &output.writer);
        if (consumed <= 1 or consumed > view.len) return error.InvalidLegacyArchive;
        offset += if (offset == 0) consumed else consumed - 1;
        object_count += 1;
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = output.writer.buffered() });
    try status.print("migrated {s} -> {s} ({s}, {d} object{s})\n", .{
        input_path,
        output_path,
        @tagName(first_kind.?),
        object_count,
        if (object_count == 1) "" else "s",
    });
}

fn migrateOne(
    kind: ozz.legacy.Kind,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    writer: *std.Io.Writer,
) !usize {
    var reader = std.Io.Reader.fixed(bytes);
    switch (kind) {
        .skeleton => {
            var value = try ozz.legacy.readSkeleton(allocator, &reader, .{});
            defer value.deinit();
            try ozz.io.writeSkeleton(allocator, writer, value);
        },
        .float_track => return migrateTrack(f32, allocator, bytes, writer),
        .float2_track => return migrateTrack(ozz.math.Vec2f32, allocator, bytes, writer),
        .float3_track => return migrateTrack(ozz.math.Vec3f32, allocator, bytes, writer),
        .float4_track => return migrateTrack(ozz.math.Float4, allocator, bytes, writer),
        .quaternion_track => return migrateTrack(ozz.math.Quaternion, allocator, bytes, writer),
        .raw_skeleton => {
            var value = try ozz.legacy.readRawSkeleton(allocator, &reader, .{});
            defer value.deinit();
            try ozz.io.writeRawSkeleton(allocator, writer, value);
        },
        .raw_animation => {
            var value = try ozz.legacy.readRawAnimation(allocator, &reader, .{});
            defer value.deinit();
            try ozz.io.writeRawAnimation(allocator, writer, value);
        },
        .raw_float_track => try migrateRawTrack(f32, allocator, bytes, writer),
        .raw_float2_track => try migrateRawTrack(ozz.math.Vec2f32, allocator, bytes, writer),
        .raw_float3_track => try migrateRawTrack(ozz.math.Vec3f32, allocator, bytes, writer),
        .raw_float4_track => try migrateRawTrack(ozz.math.Float4, allocator, bytes, writer),
        .raw_quaternion_track => try migrateRawTrack(ozz.math.Quaternion, allocator, bytes, writer),
        .animation => {
            var value = try ozz.legacy.readAnimation(allocator, &reader, .{});
            defer value.deinit();
            try ozz.io.writeAnimation(allocator, writer, value);
        },
        .sample_mesh => {
            var consumed: usize = 0;
            var value = try ozz.legacy.readMeshPrefix(allocator, &reader, .{}, &consumed);
            defer value.deinit();
            try ozz.io.writeMesh(allocator, writer, value);
            return consumed;
        },
        .sample_mesh_part => {
            const part = try ozz.legacy.readMeshPart(allocator, &reader, .{});
            const parts = try allocator.alloc(ozz.geometry.MeshPart, 1);
            parts[0] = part;
            var value: ozz.geometry.Mesh = .{
                .allocator = allocator,
                .parts = parts,
                .triangle_indices = try allocator.alloc(u16, 0),
                .joint_remaps = try allocator.alloc(u16, 0),
                .inverse_bind_poses = try allocator.alloc(ozz.math.Float4x4, 0),
            };
            defer value.deinit();
            try ozz.io.writeMesh(allocator, writer, value);
        },
    }
    return bytes.len;
}

fn migrateTrack(
    comptime T: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    writer: *std.Io.Writer,
) !usize {
    var consumed: usize = 0;
    var reader = std.Io.Reader.fixed(bytes);
    var value = try ozz.legacy.readTrackPrefix(T, allocator, &reader, .{}, &consumed);
    defer value.deinit();
    try ozz.io.writeTrack(T, allocator, writer, value);
    return consumed;
}

fn migrateRawTrack(
    comptime T: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    writer: *std.Io.Writer,
) !void {
    var reader = std.Io.Reader.fixed(bytes);
    var value = try ozz.legacy.readRawTrack(T, allocator, &reader, .{});
    defer value.deinit();
    try ozz.io.writeRawTrack(T, allocator, writer, value);
}

test "usage has the unified commands" {
    try std.testing.expect(std.mem.indexOf(u8, usage, "inspect") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "migrate") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "import") != null);
}

test "command parser recognizes help and all commands" {
    try std.testing.expect((try parseCommand(&.{"ozz"})) == .help);
    try std.testing.expect((try parseCommand(&.{ "ozz", "--help" })) == .help);
    try std.testing.expect((try parseCommand(&.{ "ozz", "-h" })) == .help);

    const inspect_command = try parseCommand(&.{ "ozz", "inspect", "input.zozz" });
    try std.testing.expectEqualStrings("input.zozz", inspect_command.inspect);

    const migrate_command = try parseCommand(&.{ "ozz", "migrate", "old.ozz", "new.zozz" });
    try std.testing.expectEqualStrings("old.ozz", migrate_command.migrate.input);
    try std.testing.expectEqualStrings("new.zozz", migrate_command.migrate.output);

    try std.testing.expect((try parseCommand(&.{ "ozz", "config", "print" })) == .config_print);
}

test "command parser validates required and duplicate arguments" {
    const invalid = [_][]const []const u8{
        &.{ "ozz", "--help", "extra" },
        &.{ "ozz", "inspect" },
        &.{ "ozz", "inspect", "one", "two" },
        &.{ "ozz", "migrate", "input" },
        &.{ "ozz", "migrate", "input", "output", "extra" },
        &.{ "ozz", "config" },
        &.{ "ozz", "config", "show" },
        &.{ "ozz", "unknown" },
        &.{ "ozz", "import", "input.gltf", "--output", "out", "--output", "other" },
        &.{ "ozz", "import", "input.gltf", "--sampling-rate", "30", "--output", "out" },
    };
    for (invalid) |args| {
        try std.testing.expectError(error.InvalidArguments, parseCommand(args));
    }
}

test "command parser validates import options and sampling rate" {
    const basic = try parseCommand(&.{ "ozz", "import", "input.gltf", "--output", "out" });
    try std.testing.expectEqualStrings("input.gltf", basic.import.input);
    try std.testing.expectEqualStrings("out", basic.import.output);
    try std.testing.expectEqual(@as(f32, 0), basic.import.sampling_rate);

    const sampled = try parseCommand(&.{
        "ozz", "import", "input.glb", "--output", "out", "--sampling-rate", "60.5",
    });
    try std.testing.expectEqual(@as(f32, 60.5), sampled.import.sampling_rate);

    const invalid_rates = [_][]const u8{ "abc", "-1", "nan", "inf", "-inf" };
    for (invalid_rates) |rate| {
        try std.testing.expectError(error.InvalidArguments, parseCommand(&.{
            "ozz", "import", "input.gltf", "--output", "out", "--sampling-rate", rate,
        }));
    }
}
