// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/framework/application.{h,cc}`.
//!
//! Owns everything upstream's `Application` owns except the GPU itself: the SDL3
//! window, the RHI device / swapchain / command ring / timeline, Dear ImGui, the
//! camera, the framework GUI panels, the capture ring (`shooter.zig`) and the main
//! loop. `framework/renderer.zig` owns the depth buffer, the pipelines and the
//! per-frame geometry; the two meet only through the small interface documented in
//! `API.md` ("Renderer <-> Application boundary"), whose per-frame ordering `frame`
//! below follows literally.
//!
//! Differences from upstream worth knowing about:
//!
//! * GLFW is replaced by SDL3 and OpenGL by the RHI, so the anti-aliasing and
//!   swap-interval controls are gone; vertical sync is a swapchain property and
//!   toggling it recreates the swapchain.
//! * Upstream reads `README.md` from the working directory at start-up. Here the
//!   sample's own upstream README is embedded at build time and handed over in
//!   `Config.readme`; `parseReadme` turns that Markdown into the plain text the
//!   help overlay shows.
//! * Upstream has no explicit single-step: it is emulated with "freeze" plus a
//!   fixed update rate. This port keeps the freeze toggle but adds a real step
//!   request (the `N` key, or the "Step" button), which runs exactly one update.

const std = @import("std");
const builtin = @import("builtin");
const ozz = @import("zig_ozz_animation");
const rhi = @import("rhi");
const sdl = @import("sdl");

const assets_mod = @import("assets.zig");
const camera_mod = @import("camera.zig");
const im_mod = @import("im.zig");
const profile = @import("profile.zig");
const renderer_mod = @import("renderer.zig");
const shooter_mod = @import("shooter.zig");

const Assets = assets_mod.Assets;
const Camera = camera_mod.Camera;
const Im = im_mod.Im;
const Record = profile.FrameRecord;

/// True when this build both links Dear ImGui and runs on a backend the RHI's
/// ImGui layer supports (it is Vulkan-only; on Apple it is left out entirely,
/// exactly like `Sampler.init` and the capture path).
pub const enable_imgui = im_mod.has_imgui and
    builtin.os.tag != .macos and
    builtin.os.tag != .ios;

/// Dear ImGui's C API, or an empty namespace. Only used for window placement —
/// every widget goes through `framework/im.zig`.
const ig = if (enable_imgui) rhi.imgui_c else struct {};
/// Dear ImGui's SDL3 platform backend (keyboard, mouse, cursors, clipboard).
const imgui_sdl3 = if (enable_imgui) @import("imgui_sdl3.zig") else struct {};

/// Static description of a sample, filled in by `src/main.zig` from
/// `build.zig`'s sample table plus the embedded upstream README.
pub const Config = struct {
    name: [:0]const u8,
    description: [:0]const u8,
    readme: []const u8,
};

// ---------------------------------------------------------------------------
// Resolution presets (application.cc:69).
// ---------------------------------------------------------------------------

/// A window size, in pixels.
pub const Resolution = struct { width: u32, height: u32 };

/// Upstream's 17 presets, sorted by increasing area.
pub const resolution_presets = [_]Resolution{
    .{ .width = 640, .height = 360 },   .{ .width = 640, .height = 480 },
    .{ .width = 800, .height = 450 },   .{ .width = 800, .height = 600 },
    .{ .width = 1024, .height = 576 },  .{ .width = 1024, .height = 768 },
    .{ .width = 1280, .height = 720 },  .{ .width = 1280, .height = 800 },
    .{ .width = 1280, .height = 960 },  .{ .width = 1280, .height = 1024 },
    .{ .width = 1400, .height = 1050 }, .{ .width = 1440, .height = 900 },
    .{ .width = 1600, .height = 900 },  .{ .width = 1600, .height = 1200 },
    .{ .width = 1680, .height = 1050 }, .{ .width = 1920, .height = 1080 },
    .{ .width = 1920, .height = 1200 },
};

/// Upstream's `OPTIONS_resolution` default (1024x768).
pub const default_resolution = 5;

/// Upstream's `preset_lookup`: the index of the first preset that is at least as
/// large as `current`, so the GUI slider tracks a hand-resized window.
pub fn resolutionLookup(current: Resolution) usize {
    var index: usize = 0;
    while (index < resolution_presets.len - 1) : (index += 1) {
        const preset = resolution_presets[index];
        if (preset.width > current.width) break;
        if (preset.width == current.width and preset.height >= current.height) break;
    }
    return index;
}

// ---------------------------------------------------------------------------
// Command line.
// ---------------------------------------------------------------------------

/// Everything the command line can set. Asset fields hold *paths*; `run` reads
/// them into memory and publishes the bytes through `Assets`.
pub const Options = struct {
    help: bool = false,
    /// `--render` / `--norender`. When false no window, device or renderer is
    /// created and only `Sample.onUpdate` runs.
    render: bool = true,
    /// `--frames=N`: quit after N rendered frames. Used by `zig build smoke`.
    frames: ?u32 = null,
    /// `--max_idle_loops=N`: upstream's loop cap. Negative disables it.
    max_idle_loops: i64 = -1,
    /// `--screenshot=N`: write one TGA after frame N has been presented. Lets a
    /// headless CI run or a reviewer capture a frame without pressing `S`.
    screenshot_frame: ?u32 = null,
    /// `--resolution=N`, an index into `resolution_presets`.
    resolution: usize = default_resolution,
    /// True when `--fixed_update_rate=` was given.
    fix_update_rate: bool = false,
    fixed_update_rate: f32 = TimeControl.default_fixed_update_rate,
    vsync: bool = true,

    skeleton: ?[]const u8 = null,
    animation: ?[]const u8 = null,
    mesh: ?[]const u8 = null,
    floor: ?[]const u8 = null,
    track: ?[]const u8 = null,
    raw: ?[]const u8 = null,
};

/// Why a command line was rejected.
pub const OptionError = error{
    /// A flag this application does not know about.
    UnknownOption,
    /// A `--flag=` that needs a value was given an empty one.
    MissingValue,
    /// The value did not parse, or fell outside the accepted range.
    InvalidValue,
};

/// Parses `args` (which must **not** include the program name).
///
/// Only the `--flag=value` form is accepted, matching `ozz::options` and the
/// `--frames=3` the build's smoke step already passes. Anything unrecognised is an
/// error rather than being silently ignored, so a typo cannot quietly disable a
/// capture or an asset override.
pub fn parseOptions(args: []const []const u8) OptionError!Options {
    var options: Options = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--render")) {
            options.render = true;
        } else if (std.mem.eql(u8, arg, "--norender")) {
            options.render = false;
        } else if (std.mem.eql(u8, arg, "--vsync")) {
            options.vsync = true;
        } else if (std.mem.eql(u8, arg, "--novsync")) {
            options.vsync = false;
        } else if (value(arg, "--frames")) |text| {
            options.frames = std.fmt.parseInt(u32, text, 10) catch return error.InvalidValue;
        } else if (value(arg, "--screenshot")) |text| {
            options.screenshot_frame = std.fmt.parseInt(u32, text, 10) catch return error.InvalidValue;
        } else if (value(arg, "--max_idle_loops")) |text| {
            options.max_idle_loops = std.fmt.parseInt(i64, text, 10) catch return error.InvalidValue;
        } else if (value(arg, "--resolution")) |text| {
            const index = std.fmt.parseInt(usize, text, 10) catch return error.InvalidValue;
            if (index >= resolution_presets.len) return error.InvalidValue;
            options.resolution = index;
        } else if (value(arg, "--fixed_update_rate")) |text| {
            const rate = std.fmt.parseFloat(f32, text) catch return error.InvalidValue;
            if (!(rate >= 1) or !(rate <= 200)) return error.InvalidValue;
            options.fix_update_rate = true;
            options.fixed_update_rate = rate;
        } else if (value(arg, "--skeleton")) |text| {
            options.skeleton = try assetPath(text);
        } else if (value(arg, "--animation")) |text| {
            options.animation = try assetPath(text);
        } else if (value(arg, "--mesh")) |text| {
            options.mesh = try assetPath(text);
        } else if (value(arg, "--floor")) |text| {
            options.floor = try assetPath(text);
        } else if (value(arg, "--track")) |text| {
            options.track = try assetPath(text);
        } else if (value(arg, "--raw")) |text| {
            options.raw = try assetPath(text);
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

/// Returns the tail of `arg` when it is exactly `name=<something>`.
fn value(arg: []const u8, comptime name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, name ++ "=")) return null;
    return arg[name.len + 1 ..];
}

/// Rejects an empty asset-override path instead of failing later at open time.
fn assetPath(text: []const u8) OptionError![]const u8 {
    if (text.len == 0) return error.MissingValue;
    return text;
}

/// Renders the `--help` text for `config` into `writer`.
pub fn writeUsage(writer: *std.Io.Writer, config: Config) !void {
    try writer.print(
        \\ozz_{s} — {s}
        \\
        \\Usage: ozz_{s} [options]
        \\
        \\Options:
        \\  -h, --help                 Show this help and exit.
        \\  --frames=N                 Render N frames, then quit.
        \\  --max_idle_loops=N         Quit after N idle loops; negative disables (default -1).
        \\  --screenshot=N             Write one TGA once frame N has been presented.
        \\  --render, --norender       Enable or disable rendering. --norender opens no
        \\                             window and only runs the sample's update.
        \\  --resolution=N             Window size preset, 0..{d} (default {d}).
        \\  --fixed_update_rate=F      Run the update at a fixed F fps (1..200) instead of
        \\                             real time.
        \\  --vsync, --novsync         Vertical sync (default on).
        \\  --skeleton=PATH            Replace the embedded skeleton archive.
        \\  --animation=PATH           Replace the embedded animation archive.
        \\  --mesh=PATH                Replace the embedded mesh archive.
        \\  --floor=PATH               Replace the embedded floor mesh archive.
        \\  --track=PATH               Replace the embedded track archive.
        \\  --raw=PATH                 Replace the embedded raw-animation archive.
        \\
        \\Keys:
        \\  Escape                     Quit.
        \\  Space                      Pause / resume.
        \\  N                          Pause, then advance exactly one update.
        \\  F1                         Toggle the README help overlay (time is frozen
        \\                             while it is up).
        \\  S                          Write a screenshot (000000.tga, 000001.tga, ...).
        \\  V                          Toggle video capture (one TGA per frame).
        \\  Arrow keys                 Drive the camera, with the mouse modifiers below.
        \\
        \\Mouse:
        \\  Right drag                 Orbit.
        \\  Shift + right drag         Zoom.
        \\  Alt (or Ctrl) + right drag Pan.
        \\  Shift + wheel              Zoom.
        \\
    , .{
        config.name,
        config.description,
        config.name,
        @as(usize, resolution_presets.len - 1),
        @as(usize, default_resolution),
    });
}

// ---------------------------------------------------------------------------
// README -> help text.
// ---------------------------------------------------------------------------

/// Shown when a sample has no README (upstream's error message, verbatim).
pub const readme_fallback = "Unable to find README.md help file.";

/// Upstream's `ParseReadme`, adapted: the README is embedded rather than read
/// from disk, so the work left is turning Markdown into the flat text the help
/// overlay draws.
///
/// The transformation is deliberately conservative — the point is readability,
/// not a Markdown implementation:
///
/// * `#`-style heading markers are dropped (the text is kept).
/// * Fenced code blocks lose their ```` ``` ```` lines; their content is kept
///   verbatim, so an indented shell snippet still lines up.
/// * `**bold**`, `__bold__` and `` `code` `` markers are removed. Single `*`/`_`
///   are left alone so joint names like `two_bone_ik` survive intact.
/// * `[text](url)` and `![text](url)` collapse to `text`.
/// * A horizontal rule (`---`, `***`, `===`) becomes a blank line.
/// * Trailing whitespace and CR are stripped from every line.
///
/// The caller owns the result, which is NUL terminated so it can go straight to
/// Dear ImGui.
pub fn parseReadme(allocator: std.mem.Allocator, source: []const u8) ![:0]u8 {
    if (source.len == 0) return allocator.dupeSentinel(u8, readme_fallback, 0);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    var in_code_fence = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            in_code_fence = !in_code_fence;
            continue;
        }

        if (!first) try writer.writeByte('\n');
        first = false;

        if (in_code_fence) {
            try writer.writeAll(line);
            continue;
        }
        if (isHorizontalRule(trimmed)) continue;

        var body = line;
        if (std.mem.indexOfNone(u8, body, " \t")) |start| {
            if (body[start] == '#') {
                var cursor = start;
                while (cursor < body.len and body[cursor] == '#') cursor += 1;
                while (cursor < body.len and body[cursor] == ' ') cursor += 1;
                body = body[cursor..];
            }
        }
        try writeInline(writer, body);
    }

    return out.toOwnedSliceSentinel(0);
}

/// True for `---`, `***`, `___` and `===` rules of three characters or more.
fn isHorizontalRule(trimmed: []const u8) bool {
    if (trimmed.len < 3) return false;
    const marker = trimmed[0];
    if (marker != '-' and marker != '*' and marker != '_' and marker != '=') return false;
    for (trimmed) |character| {
        if (character != marker) return false;
    }
    return true;
}

/// Strips the inline Markdown decoration of a single line.
fn writeInline(writer: *std.Io.Writer, line: []const u8) !void {
    var index: usize = 0;
    while (index < line.len) {
        const rest = line[index..];
        if (std.mem.startsWith(u8, rest, "**") or std.mem.startsWith(u8, rest, "__")) {
            index += 2;
            continue;
        }
        if (rest[0] == '`') {
            index += 1;
            continue;
        }
        // `[text](url)` / `![text](url)` -> `text`.
        const link_start = if (rest[0] == '!' and rest.len > 1 and rest[1] == '[')
            @as(usize, 1)
        else if (rest[0] == '[')
            @as(usize, 0)
        else
            null;
        if (link_start) |offset| {
            const label = rest[offset + 1 ..];
            if (std.mem.indexOfScalar(u8, label, ']')) |close| {
                if (close + 1 < label.len and label[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, label, close + 1, ')')) |end| {
                        try writeInline(writer, label[0..close]);
                        index += offset + 1 + end + 1;
                        continue;
                    }
                }
            }
        }
        try writer.writeByte(rest[0]);
        index += 1;
    }
}

// ---------------------------------------------------------------------------
// Time control (application.cc:399, `Application::Idle`).
// ---------------------------------------------------------------------------

/// Upstream's freeze / fixed-update-rate / time-factor triple, plus a single-step
/// request. Pure, so the whole thing is unit tested without a window.
pub const TimeControl = struct {
    /// Upstream's `freeze_`: the update is fed `dt = 0`.
    freeze: bool = false,
    /// Upstream's `fix_update_rate`: ignore real time and step `1 / rate` seconds.
    fix_update_rate: bool = false,
    fixed_update_rate: f32 = default_fixed_update_rate,
    /// Upstream's `time_factor_`; negative values run the sample backwards.
    time_factor: f32 = default_time_factor,
    /// Accumulated application time handed to `Sample.onUpdate`.
    time: f32 = 0,
    /// One-shot: run a single update even though `freeze` is set.
    step: bool = false,

    pub const default_fixed_update_rate: f32 = 60;
    pub const default_time_factor: f32 = 1;
    /// Delta used for the very first frame, so initialisation time is not counted.
    pub const first_frame_delta: f32 = 1.0 / 60.0;

    /// Asks for exactly one update on the next `advance`, and pauses afterwards.
    pub fn requestStep(self: *TimeControl) void {
        self.freeze = true;
        self.step = true;
    }

    /// Consumes `delta` (real seconds since the previous frame) and returns the
    /// scaled `dt` the sample should be updated with, advancing `time` by it.
    pub fn advance(self: *TimeControl, delta: f32) f32 {
        const stepping = self.step;
        self.step = false;

        const update_delta: f32 = if (self.freeze and !stepping)
            0
        else if (self.fix_update_rate)
            self.time_factor / self.fixed_update_rate
        else
            delta * self.time_factor;

        self.time += update_delta;
        return update_delta;
    }
};

// ---------------------------------------------------------------------------
// The application itself.
// ---------------------------------------------------------------------------

/// Builds the runnable application for one sample type.
///
/// Every optional `Sample` declaration is probed with `@hasDecl`, so a sample that
/// only implements `init` / `deinit` / `onUpdate` / `onDisplay` / `onGui` works.
pub fn Application(comptime Sample: type) type {
    return struct {
        const Self = @This();

        const has_floating_gui = @hasDecl(Sample, "onFloatingGui");
        const has_scene_bounds = @hasDecl(Sample, "sceneBounds");
        const has_camera_setup = @hasDecl(Sample, "cameraInitialSetup");
        const has_camera_override = @hasDecl(Sample, "cameraOverride");

        const SwapchainRef = rhi.gpu_ref.GPURef(rhi.Swapchain, .heap);
        const Deferral = rhi.timline_deferral.TimelineDeferral(&.{*SwapchainRef});
        const CmdRing = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 3, .sync_primative = true });

        /// Handed to the `SDL_RunApp` trampoline, which cannot carry a closure.
        const Boot = struct {
            io: std.Io,
            gpa: std.mem.Allocator,
            config: Config,
            options: Options,
            assets: Assets,
            help: [:0]const u8,
            result: anyerror!void,
        };
        var boot: Boot = undefined;

        /// Runs the sample: parses the command line, then either opens a window and
        /// enters the main loop or, with `--norender`, updates headlessly.
        pub fn run(init: std.process.Init, config: Config) !void {
            const arena = init.arena.allocator();

            const args = try collectArgs(init, arena);
            const options = parseOptions(args) catch |err| {
                var buffer: [4096]u8 = undefined;
                var file = std.Io.File.stderr().writer(init.io, &buffer);
                file.interface.print("error: {t}\n\n", .{err}) catch {};
                writeUsage(&file.interface, config) catch {};
                file.interface.flush() catch {};
                return err;
            };

            if (options.help) {
                var buffer: [4096]u8 = undefined;
                var file = std.Io.File.stdout().writer(init.io, &buffer);
                defer file.interface.flush() catch {};
                return writeUsage(&file.interface, config);
            }

            const assets = try loadAssets(init.io, arena, options);
            const help = try parseReadme(arena, config.readme);

            if (!options.render) return runHeadless(init, config, options, assets);

            boot = .{
                .io = init.io,
                .gpa = init.gpa,
                .config = config,
                .options = options,
                .assets = assets,
                .help = help,
                .result = {},
            };

            // SDL_RunApp does the platform bootstrapping (it is what makes the
            // macOS/Windows entry points behave); the loop itself stays ours.
            var argv: [0:null]?[*:0]u8 = .{};
            _ = sdl.SDL_RunApp(argv.len, @ptrCast(&argv), sdlMain, null);
            return boot.result;
        }

        fn sdlMain(argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
            _ = argc;
            _ = argv;
            boot.result = runWindowed();
            if (boot.result) |_| {
                return 0;
            } else |err| {
                std.log.err("sample failed: {t}", .{err});
                return 1;
            }
        }

        /// `--norender`: upstream's "loop without any rendering initialization".
        fn runHeadless(
            init: std.process.Init,
            config: Config,
            options: Options,
            assets: Assets,
        ) !void {
            _ = config;
            var sample = try Sample.init(init.gpa, assets);
            defer sample.deinit();

            var time: TimeControl = .{
                .fix_update_rate = true,
                .fixed_update_rate = options.fixed_update_rate,
            };

            var loops: u64 = 0;
            while (true) : (loops += 1) {
                if (options.frames) |limit| {
                    if (loops >= limit) break;
                }
                if (options.max_idle_loops > 0 and loops > @as(u64, @intCast(options.max_idle_loops))) break;

                const dt = time.advance(TimeControl.first_frame_delta);
                if (!try sample.onUpdate(dt, time.time)) break;
            }
        }

        // -- window / device lifetime ---------------------------------------

        fn runWindowed() !void {
            const gpa = boot.gpa;
            const options = boot.options;

            if (!sdl.SDL_SetAppMetadata(boot.config.name.ptr, "0.0.0", "org.ozz.sample"))
                return error.SdlSetAppMetadataFailed;
            if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.SdlInitFailed;
            defer sdl.SDL_Quit();

            const preset = resolution_presets[options.resolution];
            const created = sdl.SDL_CreateWindow(
                boot.config.description.ptr,
                @intCast(preset.width),
                @intCast(preset.height),
                sdl.SDL_WINDOW_RESIZABLE,
            );
            if (created == null) return error.SdlCreateWindowFailed;
            const window = created.?;
            defer sdl.SDL_DestroyWindow(window);

            const handle = try windowHandle(window);

            try rhi.Renderer.init(gpa, switch (builtin.os.tag) {
                .macos, .ios => .{ .mtl = .{} },
                else => .{ .vk = .{
                    .app_name = "ozz-animation sample",
                    .enable_validation_layer = builtin.mode == .Debug,
                } },
            });
            defer rhi.Renderer.deinit();

            var adapters = try rhi.PhysicalAdapter.enumerate_adapters(gpa);
            defer adapters.deinit(gpa);
            if (adapters.items.len == 0) return error.NoGraphicsAdapter;
            const selected = rhi.PhysicalAdapter.default_select_adapter(adapters.items);

            var device = try rhi.Device.init(gpa, &adapters.items[selected]);
            defer device.deinit();

            const initial = try rhi.Swapchain.init(gpa, &device, .{
                .width = @intCast(preset.width),
                .height = @intCast(preset.height),
                .vsync = options.vsync,
                .queue = &device.graphics_queue,
                .source = .{ .window_handle = handle },
            });
            var swapchain = try SwapchainRef.create(gpa, &device, initial);

            var timeline = try rhi.Timeline.init(&device);
            var deferral = Deferral.init(gpa);
            var cmd_ring = try CmdRing.init(&device, &device.graphics_queue);

            var imgui: if (enable_imgui) rhi.ImGui else void = undefined;
            if (enable_imgui) {
                imgui = try rhi.ImGui.init(gpa, &device, &swapchain.inner);
                if (!imgui_sdl3.cImGui_ImplSDL3_InitForVulkan(window))
                    return error.ImGuiSdl3InitFailed;
            }

            var renderer = try renderer_mod.Renderer.init(gpa, &device, &swapchain.inner);
            var sample = try Sample.init(gpa, boot.assets);

            var app: App = .{
                .io = boot.io,
                .gpa = gpa,
                .window = window,
                .device = &device,
                .swapchain = swapchain,
                .timeline = &timeline,
                .deferral = &deferral,
                .cmd_ring = &cmd_ring,
                .imgui = &imgui,
                .renderer = &renderer,
                .sample = &sample,
                .shooter = shooter_mod.Shooter.init(boot.io),
                .options = options,
                .vsync = options.vsync,
                .resolution = preset,
                .time = .{
                    .fix_update_rate = options.fix_update_rate,
                    .fixed_update_rate = options.fixed_update_rate,
                },
            };
            if (has_camera_setup) {
                if (sample.cameraInitialSetup()) |setup| app.camera.reset(setup);
            }
            app.camera.resize(preset.width, preset.height);

            // Teardown mirrors construction; the GPU is idled first so every
            // in-flight readback and swapchain reference can be released.
            defer {
                device.graphics_queue.wait_queue_idle(&device) catch |err| {
                    std.log.err("failed to idle the graphics queue: {t}", .{err});
                };
                app.shooter.flush();
                app.shooter.deinit(&device);
                sample.deinit();
                renderer.deinit(&device);
                if (enable_imgui) {
                    imgui_sdl3.cImGui_ImplSDL3_Shutdown();
                    imgui.deinit(&device);
                }
                deferral.drain(timeline.pending());
                app.swapchain.deref();
                deferral.deinit();
                timeline.deinit(&device);
                cmd_ring.deinit(&device);
            }

            while (try app.oneLoop()) {}
        }

        // -- per-frame state --------------------------------------------------

        const App = struct {
            io: std.Io,
            gpa: std.mem.Allocator,
            window: *sdl.SDL_Window,
            device: *rhi.Device,
            swapchain: *SwapchainRef,
            timeline: *rhi.Timeline,
            deferral: *Deferral,
            cmd_ring: *CmdRing,
            imgui: *if (enable_imgui) rhi.ImGui else void,
            renderer: *renderer_mod.Renderer,
            sample: *Sample,
            shooter: shooter_mod.Shooter,
            options: Options,

            camera: Camera = .{},
            time: TimeControl = .{},

            fps: Record = .{},
            update_time: Record = .{},
            render_time: Record = .{},

            /// Monotonic frame counter handed to `Renderer.beginFrame`.
            frame_index: u32 = 0,
            /// Upstream's loop counter, compared against `--max_idle_loops`.
            loops: u64 = 0,
            /// Frames actually presented, compared against `--frames`.
            presented: u32 = 0,
            first_frame: bool = true,
            exit: bool = false,
            force_rebuild: bool = false,
            last_counter: u64 = 0,

            vsync: bool = true,
            resolution: Resolution,
            show_grid: bool = true,
            show_axes: bool = true,
            show_help: bool = false,
            capture_video: bool = false,
            capture_screenshot: bool = false,

            /// Wheel movement accumulated from events since the last camera
            /// update. Kept fractional so a high-resolution trackpad still adds
            /// up to whole notches instead of being truncated away every frame.
            wheel: f32 = 0,

            /// One iteration of upstream's `OneLoop`. Returns false to leave the
            /// main loop.
            fn oneLoop(self: *App) !bool {
                var frame_profiler = profile.Profiler.begin(self.io, &self.fps);
                defer frame_profiler.end();

                self.pumpEvents();
                if (self.exit) return false;
                if (self.options.max_idle_loops > 0 and
                    self.loops > @as(u64, @intCast(self.options.max_idle_loops))) return false;
                self.loops += 1;

                const completed = try self.timeline.completed(self.device);
                self.shooter.update(completed);
                self.deferral.drain(completed);
                try self.resizeIfNeeded();

                var image_index: u32 = undefined;
                switch (try self.swapchain.inner.acquire_next_image(self.device, &image_index)) {
                    .out_of_date => {
                        self.force_rebuild = true;
                        return true;
                    },
                    else => {},
                }
                try self.deferral.enqueue(self.swapchain);

                const delta = self.tick();
                try self.idle(delta);
                self.gui(delta);
                if (self.options.screenshot_frame) |frame| {
                    if (self.presented == frame) self.capture_screenshot = true;
                }
                try self.display(image_index);

                self.first_frame = false;
                self.presented += 1;
                if (self.options.frames) |limit| {
                    if (self.presented >= limit) return false;
                }
                return !self.exit;
            }

            /// Real seconds elapsed since the previous frame.
            fn tick(self: *App) f32 {
                const frequency = sdl.SDL_GetPerformanceFrequency();
                const counter = sdl.SDL_GetPerformanceCounter();
                defer self.last_counter = counter;
                if (self.first_frame or self.last_counter == 0 or frequency == 0)
                    return TimeControl.first_frame_delta;
                const elapsed: f64 = @floatFromInt(counter - self.last_counter);
                return @floatCast(elapsed / @as(f64, @floatFromInt(frequency)));
            }

            /// Upstream's `Application::Idle`: scale time, update the sample, then
            /// the camera — which always sees the *real* delta, never the scaled one.
            fn idle(self: *App, delta: f32) !void {
                if (self.show_help) {
                    // Time is frozen while the help is up, and so is the camera.
                    self.wheel = 0;
                    return;
                }

                const update_delta = self.time.advance(delta);
                {
                    var update_profiler = profile.Profiler.begin(self.io, &self.update_time);
                    defer update_profiler.end();
                    if (!try self.sample.onUpdate(update_delta, self.time.time)) self.exit = true;
                }

                const bounds: ?ozz.math.Box = if (has_scene_bounds)
                    self.sample.sceneBounds()
                else
                    null;
                const input = self.cameraInput();

                if (has_camera_override) {
                    if (self.sample.cameraOverride()) |transform| {
                        self.camera.updateWithTransform(transform, bounds, input, delta, self.first_frame);
                        return;
                    }
                }
                self.camera.update(bounds, input, delta, self.first_frame);
            }

            /// True while a Dear ImGui panel is under the pointer.
            fn guiWantsMouse(self: *App) bool {
                if (enable_imgui) return self.imgui.wantCaptureMouse();
                return false;
            }

            /// True while a Dear ImGui widget owns keyboard input.
            fn guiWantsKeyboard(self: *App) bool {
                if (enable_imgui) return self.imgui.wantCaptureKeyboard();
                return false;
            }

            /// Translates the live SDL keyboard / mouse state into `camera.Input`.
            fn cameraInput(self: *App) camera_mod.Input {
                var input: camera_mod.Input = .{};

                var x: f32 = 0;
                var y: f32 = 0;
                const buttons = sdl.SDL_GetMouseState(&x, &y);
                input.mouse_x = @intFromFloat(x);
                input.mouse_y = @intFromFloat(y);

                // Still track the pointer while a panel has it, so the first drag
                // after leaving the panel does not jump; just ignore the buttons.
                if (self.guiWantsMouse()) {
                    self.wheel = 0;
                    return input;
                }

                // Consume whole notches only; the remainder rides to next frame.
                const notches = @trunc(self.wheel);
                self.wheel -= notches;
                input.wheel = @intFromFloat(notches);

                input.left_down = buttons & mouseMask(sdl.SDL_BUTTON_LEFT) != 0;
                input.middle_down = buttons & mouseMask(sdl.SDL_BUTTON_MIDDLE) != 0;
                input.right_down = buttons & mouseMask(sdl.SDL_BUTTON_RIGHT) != 0;

                const modifiers: u32 = sdl.SDL_GetModState();
                input.shift_down = modifiers & shift_mask != 0;
                input.ctrl_down = modifiers & ctrl_mask != 0;
                input.alt_down = modifiers & alt_mask != 0;

                if (self.guiWantsKeyboard()) return input;

                var count: c_int = 0;
                const keys = sdl.SDL_GetKeyboardState(&count);
                if (keys != null and count > 0) {
                    const state = keys[0..@intCast(count)];
                    input.key_left = pressed(state, sdl.SDL_SCANCODE_LEFT);
                    input.key_right = pressed(state, sdl.SDL_SCANCODE_RIGHT);
                    input.key_up = pressed(state, sdl.SDL_SCANCODE_UP);
                    input.key_down = pressed(state, sdl.SDL_SCANCODE_DOWN);
                }
                return input;
            }

            /// Drains SDL's event queue, feeding Dear ImGui and the shortcut keys.
            fn pumpEvents(self: *App) void {
                var event: sdl.SDL_Event = undefined;
                while (sdl.SDL_PollEvent(&event)) {
                    if (enable_imgui) _ = imgui_sdl3.cImGui_ImplSDL3_ProcessEvent(&event);
                    switch (event.type) {
                        sdl.SDL_EVENT_QUIT, sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => self.exit = true,
                        sdl.SDL_EVENT_MOUSE_WHEEL => {
                            if (!self.guiWantsMouse()) self.wheel += event.wheel.y;
                        },
                        sdl.SDL_EVENT_KEY_DOWN => {
                            if (event.key.repeat) continue;
                            if (self.guiWantsKeyboard()) continue;
                            switch (event.key.scancode) {
                                sdl.SDL_SCANCODE_ESCAPE => self.exit = true,
                                sdl.SDL_SCANCODE_SPACE => self.time.freeze = !self.time.freeze,
                                sdl.SDL_SCANCODE_N => self.time.requestStep(),
                                sdl.SDL_SCANCODE_F1 => self.show_help = !self.show_help,
                                sdl.SDL_SCANCODE_S => self.capture_screenshot = true,
                                sdl.SDL_SCANCODE_V => self.capture_video = !self.capture_video,
                                else => {},
                            }
                        },
                        else => {},
                    }
                }
            }

            /// Rebuilds the swapchain when the window changed size, vertical sync
            /// was toggled, or a previous acquire/present reported `out_of_date`.
            fn resizeIfNeeded(self: *App) !void {
                var width: c_int = 0;
                var height: c_int = 0;
                if (!sdl.SDL_GetWindowSize(self.window, &width, &height)) return;
                if (width <= 0 or height <= 0) return;

                self.resolution = .{ .width = @intCast(width), .height = @intCast(height) };
                const same = self.swapchain.inner.width == @as(u16, @intCast(width)) and
                    self.swapchain.inner.height == @as(u16, @intCast(height));
                if (same and !self.force_rebuild) return;

                // The renderer's depth image is rebuilt below, so nothing may still
                // be reading it: idle the queue and release every parked reference.
                try self.device.graphics_queue.wait_queue_idle(self.device);
                self.deferral.drain(self.timeline.pending());

                const next = try rhi.Swapchain.init(self.gpa, self.device, .{
                    .width = @intCast(width),
                    .height = @intCast(height),
                    .vsync = self.vsync,
                    .queue = &self.device.graphics_queue,
                    .source = .{ .old_swapchain = &self.swapchain.inner },
                });
                if (next.isEmpty()) return;

                const box = try SwapchainRef.create(self.gpa, self.device, next);
                self.swapchain.deref();
                self.swapchain = box;
                self.force_rebuild = false;

                try self.renderer.resize(self.device, &self.swapchain.inner);
                self.camera.resize(@intCast(width), @intCast(height));
            }

            /// Upstream's `Application::Display`, following the per-frame ordering
            /// `API.md` pins down for the renderer boundary.
            fn display(self: *App, image_index: u32) !void {
                var render_profiler = profile.Profiler.begin(self.io, &self.render_time);
                defer render_profiler.end();

                const width = self.swapchain.inner.width;
                const height = self.swapchain.inner.height;

                self.cmd_ring.advance();
                var ring_element = self.cmd_ring.get(self.device, 1);
                try ring_element.wait(self.device);
                try ring_element.pool.reset(self.device);

                var cmd = &ring_element.cmds[0];
                try cmd.begin(self.device);

                var color = self.swapchain.inner.image(image_index);
                const view = self.swapchain.inner.image_view(image_index);

                cmd.resource_barrier(self.device, .{}, .{ .image_barriers = &.{
                    .{
                        .image = &color,
                        .before = .{},
                        .after = .{ .render_target = true },
                        .before_stages = .{ .color_attachment = true },
                    },
                    .{
                        .image = self.renderer.depthImage(),
                        .before = .{},
                        .after = .{ .depth_write = true },
                        .aspect = .depth,
                    },
                } });

                self.renderer.beginFrame(self.device, cmd, self.frame_index, self.camera.view_proj);
                self.frame_index +%= 1;

                cmd.begin_rendering(self.device, .{
                    .color_attachments = &.{.{
                        .view = view,
                        .load_op = .clear,
                        .store_op = .store,
                        // Upstream's clear colour (application.cc:349).
                        .clear_color = .{ 0.4, 0.42, 0.38, 1 },
                    }},
                    .depth_attachment = self.renderer.depthAttachment(),
                    .render_area = .{ .width = width, .height = height },
                });
                // Positive height: the Vulkan Y flip lives in the projection matrix.
                cmd.set_viewport(self.device, .{
                    .width = @floatFromInt(width),
                    .height = @floatFromInt(height),
                });
                cmd.set_scissor(self.device, .{ .width = width, .height = height });

                try self.sample.onDisplay(self.renderer);

                // Drawn last, like upstream: the grid is translucent.
                if (self.show_grid) try self.renderer.drawGrid(20, 1);
                if (self.show_axes) try self.renderer.drawAxes(.identity);

                try self.renderer.endFrame();
                cmd.end_rendering(self.device);

                // Dear ImGui goes into a second, colour-only pass.
                //
                // `API.md` puts `imgui.render` inside the 3D pass, but the RHI's
                // ImGui layer builds its pipeline with `depth_stencil_format = null`
                // (`rhi/src/imgui.zig:206`), and Vulkan requires a pipeline's
                // depth-attachment format to match the render pass it is used in.
                // Splitting the pass is the only fix that does not patch the RHI;
                // it changes nothing for the renderer, whose draws all still sit
                // between `beginFrame` and `endFrame`.
                if (enable_imgui) {
                    cmd.memory_barrier(self.device, .{
                        .before = .{ .render_target = true },
                        .after = .{ .render_target = true },
                    });
                    cmd.begin_rendering(self.device, .{
                        .color_attachments = &.{.{
                            .view = view,
                            .load_op = .load,
                            .store_op = .store,
                        }},
                        .render_area = .{ .width = width, .height = height },
                    });
                    try self.imgui.render(self.device, cmd);
                    cmd.end_rendering(self.device);
                }

                var captured = false;
                if (self.capture_video or self.capture_screenshot) {
                    captured = try self.shooter.capture(
                        self.device,
                        cmd,
                        &color,
                        width,
                        height,
                        shooter_mod.swapchainFormat(&self.swapchain.inner),
                    );
                    self.capture_screenshot = false;
                }

                cmd.image_barrier(self.device, .{
                    .image = &color,
                    .before = if (captured)
                        .{ .copy_src = true }
                    else
                        .{ .render_target = true },
                    .after = .{ .present = true },
                });

                const status = try self.swapchain.inner.frame_submit(
                    self.device,
                    &self.device.graphics_queue,
                    .{
                        .image_index = image_index,
                        .ring_element = &ring_element,
                        .cmd = cmd,
                        .timeline = self.timeline,
                    },
                );
                if (status == .out_of_date) self.force_rebuild = true;

                self.shooter.seal(self.timeline.pending());
                try self.deferral.seal(self.timeline.pending());
            }

            // -- GUI ----------------------------------------------------------

            /// Upstream's `Application::Gui`: a left "Framework" panel, a right
            /// "Sample" panel and a full-screen help overlay.
            fn gui(self: *App, delta: f32) void {
                // Comptime-false on a build without Dear ImGui, so nothing below
                // (which reaches into `ig` and the SDL3 backend) is even analysed.
                if (enable_imgui) {
                    imgui_sdl3.cImGui_ImplSDL3_NewFrame();
                    self.imgui.newFrame(
                        @floatFromInt(self.swapchain.inner.width),
                        @floatFromInt(self.swapchain.inner.height),
                        delta,
                    );

                    const margin: f32 = 8;
                    const form_width: f32 = 260;
                    const width: f32 = @floatFromInt(self.swapchain.inner.width);
                    const height: f32 = @floatFromInt(self.swapchain.inner.height);

                    var im = Im.init(true);

                    if (self.show_help) {
                        ig.ImGui_SetNextWindowPos(.{ .x = margin, .y = margin }, ig.ImGuiCond_Always);
                        ig.ImGui_SetNextWindowSize(.{
                            .x = @max(width - margin * 2, 1),
                            .y = @max(height - margin * 2, 1),
                        }, ig.ImGuiCond_Always);
                        if (im.beginForm("Help (F1)")) {
                            ig.ImGui_PushTextWrapPos(0);
                            ig.ImGui_TextUnformatted(boot.help.ptr);
                            ig.ImGui_PopTextWrapPos();
                        }
                        im.endForm();
                        return;
                    }

                    if (has_floating_gui) self.sample.onFloatingGui(&im);

                    ig.ImGui_SetNextWindowPos(.{ .x = margin, .y = margin }, ig.ImGuiCond_FirstUseEver);
                    ig.ImGui_SetNextWindowSize(.{
                        .x = form_width,
                        .y = @max(height - margin * 2, 1),
                    }, ig.ImGuiCond_FirstUseEver);
                    if (im.beginForm("Framework")) self.frameworkGui(&im);
                    im.endForm();

                    ig.ImGui_SetNextWindowPos(.{
                        .x = @max(width - form_width - margin, margin),
                        .y = margin,
                    }, ig.ImGuiCond_FirstUseEver);
                    ig.ImGui_SetNextWindowSize(.{
                        .x = form_width,
                        .y = @max(height - margin * 2, 1),
                    }, ig.ImGuiCond_FirstUseEver);
                    if (im.beginForm("Sample")) self.sample.onGui(&im);
                    im.endForm();
                }
            }

            /// Upstream's `Application::FrameworkGui` (application.cc:530).
            fn frameworkGui(self: *App, im: *Im) void {
                var label: [96]u8 = undefined;

                // 1. Statistics.
                if (im.openClose("Statistics###statistics", true)) {
                    const fps = self.fps.statistics();
                    const rate: f32 = if (fps.mean == 0) 0 else 1000 / fps.mean;
                    if (im.openClose(
                        im_mod.formatZ(&label, "FPS: {d:.0}###fps", .{rate}),
                        false,
                    )) {
                        var frame_label: [64]u8 = undefined;
                        im.doGraph(
                            im_mod.formatZ(&frame_label, "Frame: {d:.2} ms", .{fps.mean}),
                            0,
                            fps.max,
                            fps.latest,
                            self.fps.cursor(),
                            self.fps.values(),
                        );
                    }

                    // Open by default: this is the number that matters for ozz.
                    const update = self.update_time.statistics();
                    if (im.openClose(
                        im_mod.formatZ(&label, "Update: {d:.2} ms###update", .{update.mean}),
                        true,
                    )) {
                        im.doGraph(
                            "###update_graph",
                            0,
                            update.max,
                            update.latest,
                            self.update_time.cursor(),
                            self.update_time.values(),
                        );
                    }

                    const render = self.render_time.statistics();
                    if (im.openClose(
                        im_mod.formatZ(&label, "Render: {d:.2} ms###render", .{render.mean}),
                        false,
                    )) {
                        im.doGraph(
                            "###render_graph",
                            0,
                            render.max,
                            render.latest,
                            self.render_time.cursor(),
                            self.render_time.values(),
                        );
                    }
                }

                // 2. Time control.
                if (im.openClose("Time control###time", false)) {
                    _ = im.doCheckBox("Freeze (space)", &self.time.freeze, true);
                    if (im.doButton("Step (n)", true)) self.time.requestStep();
                    _ = im.doCheckBox("Fix update rate", &self.time.fix_update_rate, true);
                    if (!self.time.fix_update_rate) {
                        _ = im.doSlider(
                            im_mod.formatZ(&label, "Time factor: {d:.2}###factor", .{self.time.time_factor}),
                            -5,
                            5,
                            &self.time.time_factor,
                            1,
                            true,
                        );
                        if (im.doButton(
                            "Reset time factor",
                            self.time.time_factor != TimeControl.default_time_factor,
                        )) self.time.time_factor = TimeControl.default_time_factor;
                    } else {
                        _ = im.doSlider(
                            im_mod.formatZ(&label, "Update rate: {d:.0} fps###rate", .{self.time.fixed_update_rate}),
                            1,
                            200,
                            &self.time.fixed_update_rate,
                            0.5,
                            true,
                        );
                        if (im.doButton(
                            "Reset update rate",
                            self.time.fixed_update_rate != TimeControl.default_fixed_update_rate,
                        )) self.time.fixed_update_rate = TimeControl.default_fixed_update_rate;
                    }
                }

                // 3. Rendering options.
                if (im.openClose("Options###options", false)) {
                    _ = im.doCheckBox("Show grid", &self.show_grid, true);
                    _ = im.doCheckBox("Show axes", &self.show_axes, true);
                    if (im.doCheckBox("Vertical sync", &self.vsync, true)) self.force_rebuild = true;

                    var preset: i32 = @intCast(resolutionLookup(self.resolution));
                    if (im.doSliderInt(
                        im_mod.formatZ(&label, "Resolution: {d}x{d}###resolution", .{
                            self.resolution.width,
                            self.resolution.height,
                        }),
                        0,
                        @intCast(resolution_presets.len - 1),
                        &preset,
                        1,
                        true,
                    )) {
                        const wanted = resolution_presets[@intCast(preset)];
                        _ = sdl.SDL_SetWindowSize(
                            self.window,
                            @intCast(wanted.width),
                            @intCast(wanted.height),
                        );
                    }
                }

                // 4. Capture.
                if (im.openClose("Capture###capture", false)) {
                    if (!shooter_mod.supported) {
                        im.doLabel("Capture is unavailable on this backend.", .{});
                    } else {
                        _ = im.doCheckBox("Capture video (v)", &self.capture_video, true);
                        if (im.doButton("Capture screenshot (s)", !self.capture_video))
                            self.capture_screenshot = true;
                    }
                }

                // 5. Camera controls.
                if (im.openClose("Camera controls###camera", false)) self.camera.onGui(im);

                // 6. Help.
                _ = im.doCheckBox("Show help (F1)", &self.show_help, true);
            }
        };
    };
}

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

/// `1 << (button - 1)`, matching SDL3's `SDL_BUTTON_MASK` macro (which does not
/// survive translate-c as a usable constant).
fn mouseMask(comptime button: u32) u32 {
    return @as(u32, 1) << @intCast(button - 1);
}

/// SDL modifier masks, widened once so they can be ANDed with `SDL_GetModState`.
const shift_mask: u32 = sdl.SDL_KMOD_SHIFT;
const ctrl_mask: u32 = sdl.SDL_KMOD_CTRL;
const alt_mask: u32 = sdl.SDL_KMOD_ALT;

/// Reads one entry of `SDL_GetKeyboardState`'s array, bounds-checked.
fn pressed(state: []const bool, scancode: c_uint) bool {
    const index: usize = @intCast(scancode);
    return index < state.len and state[index];
}

/// Copies the process arguments (minus the program name) into `allocator`.
fn collectArgs(init: std.process.Init, allocator: std.mem.Allocator) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

    // `iterateAllocator` is the form that compiles on every target.
    var iterator = try init.minimal.args.iterateAllocator(init.gpa);
    defer iterator.deinit();
    _ = iterator.next(); // program name
    while (iterator.next()) |arg| try list.append(allocator, try allocator.dupe(u8, arg));

    return list.toOwnedSlice(allocator);
}

/// Turns the `--skeleton=` family of paths into the byte buffers `Assets` hands
/// to `Sample.init`.
fn loadAssets(io: std.Io, allocator: std.mem.Allocator, options: Options) !Assets {
    return .{
        .skeleton = try readAsset(io, allocator, options.skeleton),
        .animation = try readAsset(io, allocator, options.animation),
        .mesh = try readAsset(io, allocator, options.mesh),
        .floor = try readAsset(io, allocator, options.floor),
        .track = try readAsset(io, allocator, options.track),
        .raw = try readAsset(io, allocator, options.raw),
    };
}

/// Largest override archive accepted, a sanity bound rather than a real limit.
const asset_size_limit: std.Io.Limit = .limited(256 << 20);

fn readAsset(io: std.Io, allocator: std.mem.Allocator, path: ?[]const u8) !?[]const u8 {
    const wanted = path orelse return null;
    return std.Io.Dir.cwd().readFileAlloc(io, wanted, allocator, asset_size_limit) catch |err| {
        std.log.err("failed to read '{s}': {t}", .{ wanted, err });
        return err;
    };
}

/// SDL window -> `rhi.WindowHandle`, per platform.
fn windowHandle(window: *sdl.SDL_Window) !rhi.WindowHandle {
    const properties = sdl.SDL_GetWindowProperties(window);
    switch (builtin.os.tag) {
        .windows => return .{ .win32 = .{
            .hinstance = sdl.SDL_GetPointerProperty(
                properties,
                sdl.SDL_PROP_WINDOW_WIN32_HINSTANCE_POINTER,
                null,
            ) orelse return error.SdlNoWindowHandle,
            .hwnd = sdl.SDL_GetPointerProperty(
                properties,
                sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER,
                null,
            ) orelse return error.SdlNoWindowHandle,
        } },
        .linux => {
            const driver = std.mem.sliceTo(sdl.SDL_GetCurrentVideoDriver(), 0);
            if (std.mem.eql(u8, driver, "x11")) {
                return .{ .x11 = .{
                    .display = sdl.SDL_GetPointerProperty(
                        properties,
                        sdl.SDL_PROP_WINDOW_X11_DISPLAY_POINTER,
                        null,
                    ) orelse return error.SdlNoWindowHandle,
                    .window = @intCast(sdl.SDL_GetNumberProperty(
                        properties,
                        sdl.SDL_PROP_WINDOW_X11_WINDOW_NUMBER,
                        0,
                    )),
                } };
            }
            if (std.mem.eql(u8, driver, "wayland")) {
                return .{ .wayland = .{
                    .display = sdl.SDL_GetPointerProperty(
                        properties,
                        sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER,
                        null,
                    ) orelse return error.SdlNoWindowHandle,
                    .surface = sdl.SDL_GetPointerProperty(
                        properties,
                        sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER,
                        null,
                    ) orelse return error.SdlNoWindowHandle,
                    .shell_surface = null,
                } };
            }
            return error.SdlUnsupportedVideoDriver;
        },
        .macos, .ios => {
            const view = sdl.SDL_Metal_CreateView(window) orelse return error.SdlNoWindowHandle;
            const layer = sdl.SDL_Metal_GetLayer(view) orelse return error.SdlNoWindowHandle;
            return .{ .metal = .{ .layer = layer } };
        },
        else => return error.SdlUnsupportedPlatform,
    }
}

// ---------------------------------------------------------------------------
// Tests. Everything below is window-free.
// ---------------------------------------------------------------------------

test {
    _ = @import("shooter.zig");
}

/// A sample with only the mandatory declarations.
const MinimalSample = struct {
    pub fn init(allocator: std.mem.Allocator, assets: Assets) !MinimalSample {
        _ = allocator;
        _ = assets;
        return .{};
    }
    pub fn deinit(self: *MinimalSample) void {
        _ = self;
    }
    pub fn onUpdate(self: *MinimalSample, dt: f32, time: f32) !bool {
        _ = self;
        _ = dt;
        _ = time;
        return true;
    }
    pub fn onDisplay(self: *MinimalSample, renderer: *renderer_mod.Renderer) !void {
        _ = self;
        _ = renderer;
    }
    pub fn onGui(self: *MinimalSample, gui: *Im) void {
        _ = self;
        _ = gui;
    }
};

/// The same, plus every optional declaration `API.md` lists.
const FullSample = struct {
    pub fn init(allocator: std.mem.Allocator, assets: Assets) !FullSample {
        _ = allocator;
        _ = assets;
        return .{};
    }
    pub fn deinit(self: *FullSample) void {
        _ = self;
    }
    pub fn onUpdate(self: *FullSample, dt: f32, time: f32) !bool {
        _ = self;
        _ = dt;
        _ = time;
        return true;
    }
    pub fn onDisplay(self: *FullSample, renderer: *renderer_mod.Renderer) !void {
        _ = self;
        _ = renderer;
    }
    pub fn onGui(self: *FullSample, gui: *Im) void {
        _ = self;
        _ = gui;
    }
    pub fn onFloatingGui(self: *FullSample, gui: *Im) void {
        _ = self;
        _ = gui;
    }
    pub fn sceneBounds(self: *FullSample) ?ozz.math.Box {
        _ = self;
        return null;
    }
    pub fn cameraInitialSetup(self: *FullSample) ?camera_mod.Setup {
        _ = self;
        return null;
    }
    pub fn cameraOverride(self: *FullSample) ?ozz.math.Float4x4 {
        _ = self;
        return null;
    }
};

test "the windowed path type-checks for both the minimal and the full sample" {
    // Taking the address forces semantic analysis of `run` and, transitively, of
    // the whole main loop — the `@hasDecl` fallbacks included — without opening a
    // window or touching a device.
    //
    // Skipped (and not analysed) in a headless `rhi` build: `Renderer.deinit`
    // reaches into `rhi.Sampler`'s backend union, which is `void` there.
    if (comptime rhi.platform_api.len > 0) {
        _ = &Application(MinimalSample).run;
        _ = &Application(FullSample).run;
    } else return error.SkipZigTest;
}

test "default options match upstream" {
    const options = try parseOptions(&.{});
    try std.testing.expect(options.render);
    try std.testing.expect(options.vsync);
    try std.testing.expect(!options.help);
    try std.testing.expect(!options.fix_update_rate);
    try std.testing.expectEqual(@as(?u32, null), options.frames);
    try std.testing.expectEqual(@as(i64, -1), options.max_idle_loops);
    try std.testing.expectEqual(@as(usize, default_resolution), options.resolution);
    try std.testing.expectEqual(@as(?[]const u8, null), options.skeleton);
}

test "option parsing accepts every documented flag" {
    const options = try parseOptions(&.{
        "--frames=3",
        "--max_idle_loops=120",
        "--norender",
        "--novsync",
        "--resolution=0",
        "--fixed_update_rate=30",
        "--skeleton=a.ozz",
        "--animation=b.ozz",
        "--mesh=c.ozz",
        "--floor=d.ozz",
        "--track=e.ozz",
        "--raw=f.ozz",
    });
    try std.testing.expectEqual(@as(?u32, 3), options.frames);
    try std.testing.expectEqual(@as(i64, 120), options.max_idle_loops);
    try std.testing.expect(!options.render);
    try std.testing.expect(!options.vsync);
    try std.testing.expectEqual(@as(usize, 0), options.resolution);
    try std.testing.expect(options.fix_update_rate);
    try std.testing.expectEqual(@as(f32, 30), options.fixed_update_rate);
    try std.testing.expectEqualStrings("a.ozz", options.skeleton.?);
    try std.testing.expectEqualStrings("b.ozz", options.animation.?);
    try std.testing.expectEqualStrings("c.ozz", options.mesh.?);
    try std.testing.expectEqualStrings("d.ozz", options.floor.?);
    try std.testing.expectEqualStrings("e.ozz", options.track.?);
    try std.testing.expectEqualStrings("f.ozz", options.raw.?);
}

test "--render after --norender wins, and -h is --help" {
    const options = try parseOptions(&.{ "--norender", "--render" });
    try std.testing.expect(options.render);
    try std.testing.expect((try parseOptions(&.{"-h"})).help);
}

test "option parsing rejects bad input" {
    try std.testing.expectError(error.UnknownOption, parseOptions(&.{"--nope"}));
    // The bare, value-less form is not accepted, matching ozz::options.
    try std.testing.expectError(error.UnknownOption, parseOptions(&.{"--frames"}));
    try std.testing.expectError(error.UnknownOption, parseOptions(&.{"3"}));
    try std.testing.expectError(error.InvalidValue, parseOptions(&.{"--frames="}));
    try std.testing.expectError(error.InvalidValue, parseOptions(&.{"--frames=-1"}));
    try std.testing.expectError(error.InvalidValue, parseOptions(&.{"--frames=abc"}));
    try std.testing.expectError(error.InvalidValue, parseOptions(&.{"--resolution=17"}));
    try std.testing.expectError(error.InvalidValue, parseOptions(&.{"--fixed_update_rate=0"}));
    try std.testing.expectError(error.InvalidValue, parseOptions(&.{"--fixed_update_rate=201"}));
    try std.testing.expectError(error.MissingValue, parseOptions(&.{"--skeleton="}));
    try std.testing.expectError(error.MissingValue, parseOptions(&.{"--raw="}));
}

test "resolution presets are sorted and looked up like upstream" {
    for (resolution_presets[1..], 0..) |preset, index| {
        const previous = resolution_presets[index];
        try std.testing.expect(preset.width > previous.width or preset.height > previous.height);
    }
    try std.testing.expectEqual(@as(usize, 0), resolutionLookup(.{ .width = 320, .height = 200 }));
    try std.testing.expectEqual(@as(usize, 5), resolutionLookup(.{ .width = 1024, .height = 768 }));
    // Anything larger than the last preset clamps to it.
    try std.testing.expectEqual(
        resolution_presets.len - 1,
        resolutionLookup(.{ .width = 3840, .height = 2160 }),
    );
}

test "time control scales real time" {
    var time: TimeControl = .{};
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), time.advance(0.5), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), time.time, 1e-6);

    time.time_factor = 2;
    try std.testing.expectApproxEqAbs(@as(f32, 1), time.advance(0.5), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), time.time, 1e-6);

    // A negative factor runs the sample backwards, exactly like upstream's -5..5.
    time.time_factor = -1;
    try std.testing.expectApproxEqAbs(@as(f32, -0.25), time.advance(0.25), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), time.time, 1e-6);
}

test "the fixed update rate replaces the real delta" {
    var time: TimeControl = .{ .fix_update_rate = true, .fixed_update_rate = 50 };
    // 1 / 50, whatever the frame actually took.
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), time.advance(0.5), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), time.advance(0.001), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.04), time.time, 1e-6);

    // The time factor still applies on top of it.
    time.time_factor = 3;
    try std.testing.expectApproxEqAbs(@as(f32, 0.06), time.advance(1), 1e-6);
}

test "pause yields a zero dt and freezes application time" {
    var time: TimeControl = .{};
    _ = time.advance(0.25);
    const paused_at = time.time;

    time.freeze = true;
    try std.testing.expectEqual(@as(f32, 0), time.advance(0.25));
    try std.testing.expectEqual(@as(f32, 0), time.advance(1));
    try std.testing.expectEqual(paused_at, time.time);

    time.freeze = false;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), time.advance(0.5), 1e-6);
}

test "a single step advances exactly one update while paused" {
    var time: TimeControl = .{ .fix_update_rate = true, .fixed_update_rate = 60 };
    time.requestStep();
    try std.testing.expect(time.freeze);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 60.0), time.advance(0.5), 1e-6);
    // The request is one-shot: the next frame is frozen again.
    try std.testing.expectEqual(@as(f32, 0), time.advance(0.5));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 60.0), time.time, 1e-6);

    // Stepping without a fixed rate advances by the real delta instead.
    var real: TimeControl = .{};
    real.requestStep();
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), real.advance(0.125), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), real.advance(0.125));
}

test "readme parsing strips markdown decoration" {
    const allocator = std.testing.allocator;
    const help = try parseReadme(allocator,
        \\# Ozz-animation sample: playback
        \\
        \\## Description
        \\
        \\Loads a **skeleton** and an `animation`, then samples it.
        \\See [the docs](https://guillaumeblanc.github.io/ozz-animation/).
        \\
        \\---
        \\
        \\A joint named two_bone_ik keeps its underscores.
    );
    defer allocator.free(help);

    try std.testing.expectEqualStrings(
        \\Ozz-animation sample: playback
        \\
        \\Description
        \\
        \\Loads a skeleton and an animation, then samples it.
        \\See the docs.
        \\
        \\
        \\
        \\A joint named two_bone_ik keeps its underscores.
    , help);
    // The result is NUL terminated so it can go straight to Dear ImGui.
    try std.testing.expectEqual(@as(u8, 0), help.ptr[help.len]);
}

test "readme parsing keeps fenced code verbatim" {
    const allocator = std.testing.allocator;
    const help = try parseReadme(allocator,
        \\Run it:
        \\
        \\```bash
        \\  ozz_playback --frames=3
        \\```
    );
    defer allocator.free(help);
    try std.testing.expectEqualStrings(
        \\Run it:
        \\
        \\  ozz_playback --frames=3
    , help);
}

test "an empty readme falls back to upstream's message" {
    const allocator = std.testing.allocator;
    const help = try parseReadme(allocator, "");
    defer allocator.free(help);
    try std.testing.expectEqualStrings(readme_fallback, help);
}

test "usage mentions every flag" {
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeUsage(&writer, .{ .name = "playback", .description = "Animation playback", .readme = "" });
    const text = writer.buffered();
    for ([_][]const u8{
        "--help",     "--frames=N",    "--max_idle_loops=N",  "--norender",
        "--render",   "--resolution=", "--fixed_update_rate", "--novsync",
        "--skeleton", "--animation",   "--mesh",              "--floor",
        "--track",    "--raw",         "Escape",              "Space",
    }) |flag| {
        try std.testing.expect(std.mem.indexOf(u8, text, flag) != null);
    }
}
