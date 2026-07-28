# samples/src/framework — module contracts

Binding contract for the parallel port of the ozz-animation samples. Every module below
is owned by exactly one implementer. Do not edit files you do not own. Do not change a
signature published here without saying so in your final report.

Conventions:

- `const ozz = @import("zig_ozz_animation");` — `ozz.math.Vec3f32` is `@Vector(3, f32)`,
  `ozz.math.Float4x4` is column-major with `.translation()`, `.transformPoint()`,
  `.transformVector()`, `.fromTransform()`, `.identity`.
- Zig 0.17-dev, new IO API (`std.Io.Reader/Writer`, `std.Io.Dir`).
- License header on every new file:
  ```
  // Copyright 2026 Michael Pollind
  // SPDX-License-Identifier: GPL-2.0-only
  ```
- Every module gets at least one `test` block that runs without a GPU.

---

## `framework/color.zig` (owner: renderer)

```zig
pub const Color = extern struct {
    r: u8, g: u8, b: u8, a: u8 = 255,
    pub fn toFloats(self: Color) [4]f32;
    pub fn fromFloats(v: [4]f32) Color;
};
pub const white: Color; pub const red: Color; pub const green: Color;
pub const blue: Color;  pub const yellow: Color; pub const magenta: Color;
pub const cyan: Color;  pub const grey: Color;   pub const black: Color;
```

## `framework/camera.zig` (owner: agent A1)

Port of `ozz-animation/samples/framework/internal/camera.{h,cc}`. No rhi/SDL imports —
input arrives as a plain struct so it is unit-testable.

```zig
pub const Setup = struct {
    center: ozz.math.Vec3f32,
    angles: [2]f32,     // {pitch, yaw} radians
    distance: f32,
};

pub const Input = struct {
    mouse_x: i32 = 0, mouse_y: i32 = 0,
    wheel: i32 = 0,                    // accumulated notches this frame
    left_down: bool = false, middle_down: bool = false, right_down: bool = false,
    shift_down: bool = false, ctrl_down: bool = false,
    key_left: bool = false, key_right: bool = false,
    key_up: bool = false, key_down: bool = false,
};

pub const Controls = struct { zooming: bool, zooming_wheel: bool, rotating: bool, panning: bool };

pub const Camera = struct {
    projection: ozz.math.Float4x4,
    projection_2d: ozz.math.Float4x4,
    view: ozz.math.Float4x4,
    view_proj: ozz.math.Float4x4,
    center: ozz.math.Vec3f32,
    angles: [2]f32,
    distance: f32,
    auto_framing: bool = true,

    pub const default_distance: f32 = 8.0;
    pub const default_center: ozz.math.Vec3f32 = .{ 0, 0.5, 0 };
    pub const default_angles: [2]f32 = .{ -std.math.pi / 12.0, std.math.pi / 5.0 };
    pub const near_plane: f32 = 0.01;
    pub const far_plane: f32 = 1000.0;
    pub const fov_y: f32 = std.math.pi / 3.0;

    pub fn init() Camera;
    /// `box` may be null when the sample publishes no bounds.
    pub fn update(self: *Camera, box: ?ozz.math.Box, input: Input, dt: f32, first_frame: bool) void;
    /// Camera-override variant (`GetCameraOverride`): derives orbit params from a world transform.
    pub fn updateWithTransform(self: *Camera, transform: ozz.math.Float4x4, box: ?ozz.math.Box, input: Input, dt: f32, first_frame: bool) void;
    pub fn resize(self: *Camera, width: u32, height: u32) void;
    pub fn reset(self: *Camera, setup: Setup) void;
    pub fn onGui(self: *Camera, gui: anytype) void;   // duck-typed, takes *Im
};
```

Constants and the exact control mapping are in the reference notes §1 (see
`REFERENCE` below). **Projection must target Vulkan clip space: depth range [0,1] and
Y-down.** Build it directly (do not port the GL `[-1,1]` matrix and patch it later);
`updateWithTransform` and `resize` are the only places projection is written.

## `framework/icosphere.zig` (owner: agent A1)

```zig
pub const vertices: []const f32;   // xyz triples, unit length — usable as positions AND normals
pub const indices: []const u16;
```

Generate at comptime: icosahedron + 2 subdivision levels, each vertex normalized. Must
match the upstream count (`ozz-animation/samples/framework/internal/icosphere.h`) closely
enough to look identical; exact vertex order does not matter.

## `framework/profile.zig` (owner: agent A2)

Port of `samples/framework/profile.{h,cc}`.

```zig
pub const Statistics = struct { min: f32, max: f32, mean: f32, latest: f32 };
pub fn Record(comptime capacity: usize) type {  // circular buffer of f32
    pub fn push(self: *@This(), value: f32) void;
    pub fn statistics(self: @This()) Statistics;
    pub fn values(self: @This()) []const f32;    // oldest-first, into an internal ordered scratch
    pub fn cursor(self: @This()) usize;
};
pub const FrameRecord = Record(128);
pub const Profiler = struct {          // RAII, milliseconds
    pub fn begin(record: anytype) Profiler;
    pub fn end(self: *Profiler) void;
};
```

## `framework/image.zig` (owner: agent A2)

Port of `samples/framework/image.{h,cc}` — TGA writer only.

```zig
pub const Format = enum { rgb, bgr, rgba, bgra };
pub fn writeTga(io: std.Io, path: []const u8, width: u32, height: u32,
                format: Format, pixels: []const u8, flip_y: bool) !void;
```

## `framework/im.zig` (owner: agent A2)

Upstream `imgui.h` widget semantics (reference notes §5) mapped onto Dear ImGui via
`rhi.imgui_c`. **Must compile when ImGui is absent**: the struct holds
`enabled: bool`, and every method is a no-op returning `false`/leaving values untouched
when `!enabled`. That is what keeps the headless tests and the Metal build working.

```zig
pub const Im = struct {
    enabled: bool,
    pub fn init(enabled: bool) Im;

    pub fn beginForm(self: *Im, title: [:0]const u8) bool;   // pairs with endForm
    pub fn endForm(self: *Im) void;
    pub fn openClose(self: *Im, title: [:0]const u8, open_by_default: bool) bool;

    pub fn doButton(self: *Im, label: [:0]const u8, enabled: bool) bool;
    pub fn doSlider(self: *Im, label: [:0]const u8, min: f32, max: f32,
                    value: *f32, pow: f32, enabled: bool) bool;
    pub fn doSliderInt(self: *Im, label: [:0]const u8, min: i32, max: i32,
                       value: *i32, pow: f32, enabled: bool) bool;
    pub fn doSlider2D(self: *Im, label: [:0]const u8, min: [2]f32, max: [2]f32,
                      value: *[2]f32, enabled: bool) bool;
    pub fn doCheckBox(self: *Im, label: [:0]const u8, value: *bool, enabled: bool) bool;
    pub fn doRadioButton(self: *Im, ref: i32, label: [:0]const u8, value: *i32, enabled: bool) bool;
    pub fn doLabel(self: *Im, comptime fmt: []const u8, args: anytype) void;
    pub fn doGraph(self: *Im, label: [:0]const u8, min: f32, max: f32, mean: f32,
                   cursor: usize, values: []const f32) void;
    pub fn separator(self: *Im) void;
};
```

`doSlider`'s `pow` reproduces upstream's non-linear response: the normalized slider
position `t` maps to `min + (max-min) * pow(t, pow)`. Do not substitute ImGui's
logarithmic flag. `doSlider2D` is a custom widget: an `ImGui_InvisibleButton` rect with a
drawn handle, dragging maps to the `min`/`max` box.

## `framework/mesh.zig` (owner: agent A3)

Thin helpers over `ozz.geometry.Mesh` / `ozz.geometry.MeshPart` (the library type already
carries positions/normals/tangents/uvs/colors/joint_indices/joint_weights/joint_remaps/
inverse_bind_poses — read `src/geometry.zig` before adding anything).

```zig
pub const position_components = 3;
pub const normal_components = 3;
pub const tangent_components = 4;
pub const uv_components = 2;
pub const color_components = 4;

pub fn influencesCount(part: ozz.geometry.MeshPart) usize;
pub fn partVertexCount(part: ozz.geometry.MeshPart) usize;
pub fn vertexCount(mesh: ozz.geometry.Mesh) usize;
pub fn maxInfluences(mesh: ozz.geometry.Mesh) usize;
pub fn numJoints(mesh: ozz.geometry.Mesh) usize;
pub fn highestJointIndex(mesh: ozz.geometry.Mesh) u16;
/// Decode every mesh in an upstream `.ozz` archive (moved from demo.zig `decodeMeshes`).
pub fn decodeMeshes(allocator: std.mem.Allocator, bytes: []const u8) ![]ozz.geometry.Mesh;
pub fn deinitMeshes(allocator: std.mem.Allocator, meshes: []ozz.geometry.Mesh) void;
```

## `framework/utils.zig` (owner: agent A3)

Port of `samples/framework/utils.{h,cc}` plus the shared helpers currently sitting in
`samples/src/demo.zig` (migrate, do not rewrite).

```zig
pub const PlaybackController = struct {   // supersedes framework/playback.zig
    time_ratio: f32 = 0, previous_time_ratio: f32 = 0,
    playback_speed: f32 = 1, play: bool = true, loop: bool = true,
    pub fn update(self: *PlaybackController, duration: f32, dt: f32) i32;  // returns loop count
    pub fn setTimeRatio(self: *PlaybackController, ratio: f32) void;
    pub fn reset(self: *PlaybackController) void;
    pub fn onGui(self: *PlaybackController, gui: *Im, duration: f32, enabled: bool, allow_set_time: bool) void;
};

pub fn computeSkeletonBounds(skeleton: ozz.animation.Skeleton, allocator: std.mem.Allocator) !ozz.math.Box;
pub fn computePostureBounds(matrices: []const ozz.math.Float4x4, transform: ?ozz.math.Float4x4) ozz.math.Box;
pub fn multiplySoATransformQuaternion(index: usize, quat: ozz.math.Quaternion,
                                      transforms: []ozz.math.SoaQuaternion) void;

pub const RayHit = struct { point: ozz.math.Vec3f32, normal: ozz.math.Vec3f32 };
pub fn rayIntersectsMesh(ray_origin: ozz.math.Vec3f32, ray_direction: ozz.math.Vec3f32,
                         mesh: ozz.geometry.Mesh) ?RayHit;
pub fn rayIntersectsMeshes(ray_origin: ozz.math.Vec3f32, ray_direction: ozz.math.Vec3f32,
                           meshes: []const ozz.geometry.Mesh) ?RayHit;

// migrated from demo.zig — keep behaviour identical
pub const Clip = struct { ... };              // animation + sampling context + local output
pub fn decodeSkeleton(allocator, bytes) !ozz.animation.Skeleton;
pub fn decodeRawAnimation(allocator, bytes) !ozz.offline.RawAnimation;
pub fn cloneRawAnimation(allocator, source) !ozz.offline.RawAnimation;
pub fn findNamedJoint(skeleton, names: []const []const u8) ?usize;
pub fn findJointContaining(skeleton, needle: []const u8) ?usize;
pub fn findNamedChain3(skeleton, names: []const []const u8) ?[3]usize;
pub fn findNamedChain4(skeleton, names: []const []const u8) ?[4]usize;
pub fn findThreeJointChain(skeleton) ?[3]usize;

pub const RawSkeletonEditor = struct {
    pub fn onGui(self: *RawSkeletonEditor, raw: *ozz.offline.RawSkeleton, gui: *Im) bool;
};
```

## `framework/motion_utils.zig` (owner: agent A3)

Port of `samples/framework/motion_utils.{h,cc}`, absorbing `MotionTrack`,
`inverseMotion`, `motionDifference` and the accumulator logic from `demo.zig`.

```zig
pub const MotionTrack = struct {
    position: ozz.animation.Float3Track,
    rotation: ozz.animation.QuaternionTrack,
    pub fn decode(allocator, bytes) !MotionTrack;
    pub fn fromRaw(allocator, raw_position, raw_rotation) !MotionTrack;
    pub fn deinit(self: *MotionTrack) void;
    pub fn sample(self: MotionTrack, ratio: f32) ozz.math.Transform;
};
pub fn sampleMotion(track: MotionTrack, ratio: f32) ozz.math.Transform;

pub const MotionDeltaAccumulator = struct { ... };   // upstream semantics, reference §7
pub const MotionAccumulator = struct { ... };
pub const MotionSampler = struct { ... };

/// Path visualization; `renderer` is duck-typed (*Renderer) so this module stays GPU-free
/// for tests — it only calls `drawLineStrip`.
pub fn drawMotion(renderer: anytype, track: MotionTrack, at: f32, from: f32, to: f32,
                  step: f32, transform: ozz.math.Float4x4,
                  delta_rotation: ozz.math.Quaternion) !void;
```

## `framework/renderer.zig` (owner: main thread)

Owns the GPU. Samples only ever call the methods below; nothing else in the framework
touches rhi except `application.zig` and `shooter.zig`.

```zig
pub const Options = struct {
    triangles: bool = true, texture: bool = false, vertices: bool = false,
    normals: bool = false, tangents: bool = false, binormals: bool = false,
    colors: bool = true, wireframe: bool = false, skip_skinning: bool = false,
};

pub const Renderer = struct {
    pub fn drawAxes(self: *Renderer, transform: ozz.math.Float4x4) !void;
    pub fn drawGrid(self: *Renderer, cell_count: u32, cell_size: f32) !void;
    pub fn drawSkeleton(self: *Renderer, skeleton: ozz.animation.Skeleton,
                        transform: ozz.math.Float4x4, draw_joints: bool) !void;
    pub fn drawPosture(self: *Renderer, skeleton: ozz.animation.Skeleton,
                       matrices: []const ozz.math.Float4x4,
                       transform: ozz.math.Float4x4, draw_joints: bool) !void;
    pub fn drawPoints(self: *Renderer, positions: []const f32, position_stride: usize,
                      sizes: []const f32, colors: []const Color,
                      transform: ozz.math.Float4x4, screen_space: bool) !void;
    pub fn drawBoxIm(self: *Renderer, box: ozz.math.Box, transform: ozz.math.Float4x4, color: Color) !void;
    pub fn drawBoxShaded(self: *Renderer, box: ozz.math.Box,
                         transforms: []const ozz.math.Float4x4, color: Color) !void;
    pub fn drawSphereIm(self: *Renderer, radius: f32, transform: ozz.math.Float4x4, color: Color) !void;
    pub fn drawSphereShaded(self: *Renderer, radius: f32,
                            transforms: []const ozz.math.Float4x4, color: Color) !void;
    pub fn drawLines(self: *Renderer, points: []const ozz.math.Vec3f32, color: Color,
                     transform: ozz.math.Float4x4) !void;
    pub fn drawLineStrip(self: *Renderer, points: []const ozz.math.Vec3f32, color: Color,
                         transform: ozz.math.Float4x4) !void;
    pub fn drawVectors(self: *Renderer, positions: []const f32, position_stride: usize,
                       directions: []const f32, direction_stride: usize, count: usize,
                       length: f32, color: Color, transform: ozz.math.Float4x4) !void;
    pub fn drawBinormals(self: *Renderer, positions: []const f32, position_stride: usize,
                         normals: []const f32, normal_stride: usize,
                         tangents: []const f32, tangent_stride: usize, count: usize,
                         length: f32, color: Color, transform: ozz.math.Float4x4) !void;
    pub fn drawMesh(self: *Renderer, mesh: ozz.geometry.Mesh,
                    transform: ozz.math.Float4x4, options: Options) !void;
    pub fn drawSkinnedMesh(self: *Renderer, mesh: ozz.geometry.Mesh,
                           skinning_matrices: []const ozz.math.Float4x4,
                           transform: ozz.math.Float4x4, options: Options) !void;
};
```

## `framework/application.zig` (owner: application agent)

```zig
pub const Config = struct { name: [:0]const u8, description: [:0]const u8, readme: []const u8 };
pub fn Application(comptime Sample: type) type {
    return struct { pub fn run(init: std.process.Init, config: Config) !void; };
}
```

Also owns `framework/shooter.zig` (screenshot / video capture).

---

## Renderer ↔ Application boundary

The renderer owns the depth buffer, all pipelines, the checkered texture and the
per-frame geometry ring. The application owns the window, the device, the swapchain, the
command ring, the timeline, ImGui, the camera and the main loop. This is the only
interface between them:

```zig
pub fn init(allocator: std.mem.Allocator, device: *rhi.Device, swapchain: *rhi.Swapchain) !Renderer;
pub fn deinit(self: *Renderer, device: *rhi.Device) void;

/// Recreate size-dependent resources (the depth image/view). Call after the
/// application has replaced the swapchain.
pub fn resize(self: *Renderer, device: *rhi.Device, swapchain: *rhi.Swapchain) !void;

/// The depth attachment the application must pass to `cmd.begin_rendering`.
pub fn depthAttachment(self: *Renderer) rhi.Cmd.DepthAttachment;
/// The depth image the application must barrier to `.depth_write` (`.aspect = .depth`)
/// before `begin_rendering`.
pub fn depthImage(self: *Renderer) *rhi.Image;

/// Latch the frame state. Called after `cmd.begin` and before `begin_rendering`;
/// `frame_index` is the monotonically increasing frame counter that
/// `rpi.Program.bindDescriptors` expects.
pub fn beginFrame(self: *Renderer, device: *rhi.Device, cmd: *rhi.Cmd,
                  frame_index: u32, view_proj: ozz.math.Float4x4) void;

/// Flush anything still buffered. Called after the sample's `onDisplay`, before the
/// ImGui pass and `end_rendering`.
pub fn endFrame(self: *Renderer) !void;
```

Ordering the application must follow, per frame:

```
acquire_next_image
cmd.begin
resource_barrier: color -> .render_target, renderer.depthImage() -> .depth_write (.aspect = .depth)
renderer.beginFrame(&device, cmd, frame_index, camera.view_proj)
cmd.begin_rendering(.{ .color_attachments = ..., .depth_attachment = renderer.depthAttachment(), ... })
cmd.set_viewport / cmd.set_scissor        // positive height; the Y flip is in the projection
sample.onDisplay(&renderer)
renderer.endFrame()
cmd.end_rendering
// Second, colour-only pass for ImGui: rhi's ImGui layer builds its pipeline with
// depth_stencil_format = null (rhi/src/imgui.zig:206), so drawing it into a pass that
// has a depth attachment is a hard validation error.
memory_barrier
cmd.begin_rendering(.{ .color_attachments = ... load_op = .load ... })   // no depth
imgui.render(&device, cmd)
cmd.end_rendering
barrier -> .present, frame_submit
```

`frame_index` must be strictly monotonic for the process lifetime (not `frame %
frames_in_flight`) — the renderer's geometry ring reclaims by frame age and assumes at
most 4 frames in flight. `rhi.Timeline.wait` does not compile at the pinned revision;
use `wait_queue_idle` instead.

Draw calls write into persistently-mapped per-frame-in-flight buffers and record
immediately, so no upload barrier is needed inside the render pass.

Both sides must go through `rhi.rpi.Program` + `rpi.GraphicsPipelineDesc`, **not**
`rhi.Pipeline.init_graphics` — the latter cannot bind descriptor sets, set topology,
enable blending, or use a per-instance vertex stream. See the constraints section at the
bottom of this file.

## Optional sample decls

`Application` must tolerate a `Sample` that omits any optional decl — probe with
`@hasDecl` and fall back:

| decl | fallback when absent |
|---|---|
| `onFloatingGui` | not called |
| `sceneBounds` | camera keeps its default framing |
| `cameraInitialSetup` | upstream defaults |
| `cameraOverride` | user-controlled camera |

---

## Sample contract — `src/samples/<name>.zig` (owners: agents C*)

Each sample file exports a single public struct named `Sample`:

```zig
pub const name = "playback";
pub const description = "Animation playback";

pub const Sample = struct {
    pub fn init(allocator: std.mem.Allocator, assets: Assets) !Sample;
    pub fn deinit(self: *Sample) void;
    /// Returns false to request application shutdown. `dt` is already time-scaled and
    /// is 0 while paused.
    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool;
    pub fn onDisplay(self: *Sample, renderer: *Renderer) !void;
    pub fn onGui(self: *Sample, gui: *Im) void;

    // all optional — omit the decl entirely if unused
    pub fn onFloatingGui(self: *Sample, gui: *Im) void;
    pub fn sceneBounds(self: *Sample) ?ozz.math.Box;
    pub fn cameraInitialSetup(self: *Sample) ?Camera.Setup;
    pub fn cameraOverride(self: *Sample) ?ozz.math.Float4x4;
};
```

`Assets` (from `framework/assets.zig`, owner: main thread) carries the embedded upstream
archives plus any `--skeleton/--animation/--mesh/--floor/--track/--raw` override:

```zig
pub const Assets = struct {
    skeleton: ?[]const u8 = null, animation: ?[]const u8 = null,
    mesh: ?[]const u8 = null, floor: ?[]const u8 = null,
    track: ?[]const u8 = null, raw: ?[]const u8 = null,
    pub fn skeletonOr(self: Assets, embedded: []const u8) []const u8;
    pub fn animationOr(self: Assets, embedded: []const u8) []const u8;
    pub fn meshOr(self: Assets, embedded: []const u8) []const u8;
    pub fn floorOr(self: Assets, embedded: []const u8) []const u8;
    pub fn trackOr(self: Assets, embedded: []const u8) []const u8;
    pub fn rawOr(self: Assets, embedded: []const u8) []const u8;
};
```

Embedded archives stay available as `@import("pab_skeleton")` etc. — the exact names are
listed in `samples/build.zig`'s `assets` array.

A sample must be constructible and updatable **without a GPU**: `init`/`onUpdate`/`onGui`
must never touch the renderer. `src/tests.zig` relies on this.

---

## rhi-zig constraints (pinned rev `0532ce8`)

Verified against `samples/zig-pkg/rhi-0.0.0-o2tdaNmSGABsVElDCxQB6_Yvy7jbw8ylRVUe8t2D1fXl/`.

- `rhi.Pipeline.init_graphics` is a dead end: triangle-list only, no cull, no blending,
  one vertex stream, vertex-stage push constants, and `set_layout_count = 0` so it can
  bind no descriptors. Use `rhi.rpi.Program` + `rpi.GraphicsPipelineDesc` for everything.
  Worked example: `/home/michaelpollind/projects/rhi-zig/examples/04SVT.zig`.
- No depth in the swapchain. Create `rhi.Image.init(.{ .format = .d32_sfloat, .usage =
  .{ .depth_stencil_attachment = true }, .memory_usage = .prefer_device })` +
  `rhi.ImageView.init(.{ .format = .d32_sfloat, .aspect = .depth })`, rebuilt on resize.
  Worked example: `/home/michaelpollind/projects/rhi-zig/examples/02Mesh.zig:97-161`.
- No `polygon_mode = .line` in any working code path. Emulate the `wireframe` render
  option by expanding triangle indices into a `line_list` on the CPU.
- `ResourceLoader` does not compile (`format.GetProps` is broken). For texture upload
  copy the staging-blit in `rhi/src/imgui.zig:380-406`.
- Apple: `rhi.Sampler.init` returns `error.UnsupportedBackend`, `copy_texture_to_buffer`
  panics, and `draw` ignores `instance_count`. Vulkan is the first-class target; on Metal
  disable texturing and capture, and fall back to a per-object draw loop instead of
  instancing. ImGui is already `null` there.
- Matrix layout: slangc stores a `float4x4` push constant column-major, byte-identical to
  `ozz.math.Float4x4`. Upload ozz matrices verbatim, no transpose.
- The projection matrix carries the Vulkan Y-flip and the `[0,1]` depth range (see
  `camera.zig`). Use a positive-height viewport and keep CCW front faces (verified on
  hardware — see the `front_counter_clockwise` comment in `renderer.zig`); do not flip in
  shaders.

## REFERENCE

Detailed notes on the upstream framework — camera constants, bone/joint geometry, the
ambient lighting formula, the bone/joint vertex-shader algorithms, widget semantics,
`PlaybackController`, `ComputeSkeletonBounds`, `RayIntersectsMesh`, the motion
accumulators and `DrawMotion` — are at:

`/tmp/claude-1000/-home-michaelpollind-projects-zig-ozz-animation/cb8fa890-bccb-4bbc-ad12-b9f115a7e66b/scratchpad/framework.md`

Upstream C++ sources: `/home/michaelpollind/projects/ozz-animation/samples/`.
