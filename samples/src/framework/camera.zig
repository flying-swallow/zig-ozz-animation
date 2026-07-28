// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/framework/internal/camera.{h,cc}`.
//!
//! The orbit model, the navigation constants and the auto-framing rule are reproduced
//! exactly. Two things deliberately differ from upstream:
//!
//! * Input is a plain `Input` struct instead of direct `glfw*` polling, so the camera is
//!   unit-testable and carries no windowing dependency.
//! * The projection targets **Vulkan** clip space instead of OpenGL's. See `resize`.

const std = @import("std");
const ozz = @import("zig_ozz_animation");

const math = ozz.math;
const Float4x4 = math.Float4x4;
const Vec3f32 = math.Vec3f32;
const Box = math.Box;

/// Initial orbit parameters, published by a sample through `cameraInitialSetup`.
pub const Setup = struct {
    center: Vec3f32,
    /// `{pitch, yaw}` in radians.
    angles: [2]f32,
    distance: f32,
};

/// One frame worth of navigation input, gathered by `application.zig`.
///
/// `mouse_x`/`mouse_y` are absolute window pixels with a **top-down** y axis (SDL's and
/// GLFW's convention, which is what upstream feeds the camera).
pub const Input = struct {
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    /// Wheel notches accumulated during this frame (a delta, not a running total).
    wheel: i32 = 0,
    left_down: bool = false,
    middle_down: bool = false,
    right_down: bool = false,
    shift_down: bool = false,
    ctrl_down: bool = false,
    /// Upstream uses LEFT-ALT as the pan modifier. Window managers routinely swallow
    /// alt-drag, so `ctrl_down` is accepted as an equivalent; either one pans.
    alt_down: bool = false,
    key_left: bool = false,
    key_right: bool = false,
    key_up: bool = false,
    key_down: bool = false,
};

/// What the user did to the camera during a frame.
pub const Controls = struct {
    zooming: bool = false,
    zooming_wheel: bool = false,
    rotating: bool = false,
    panning: bool = false,
};

/// Orbit camera. Angles are `{pitch, yaw}` radians around the x and y axes of `center`,
/// the eye sits `distance` away along the rotated +Z axis.
pub const Camera = struct {
    projection: Float4x4 = .identity,
    projection_2d: Float4x4 = .identity,
    view: Float4x4 = .identity,
    view_proj: Float4x4 = .identity,
    center: Vec3f32 = default_center,
    angles: [2]f32 = default_angles,
    distance: f32 = default_distance,
    auto_framing: bool = true,

    /// Last seen mouse position, used to derive per-frame deltas.
    mouse_last_x: i32 = 0,
    mouse_last_y: i32 = 0,

    pub const default_distance: f32 = 8.0;
    pub const default_center: Vec3f32 = .{ 0, 0.5, 0 };
    pub const default_angles: [2]f32 = .{ -std.math.pi / 12.0, std.math.pi / 5.0 };
    pub const near_plane: f32 = 0.01;
    pub const far_plane: f32 = 1000.0;
    pub const fov_y: f32 = std.math.pi / 3.0;

    /// Radians of orbit per mouse pixel.
    pub const angle_factor: f32 = 0.01;
    /// Distance units per pixel of shift-drag.
    pub const distance_factor: f32 = 0.1;
    /// Multiplicative zoom per wheel notch.
    pub const scroll_factor: f32 = 0.03;
    /// World units per pixel of pan-drag.
    pub const pan_factor: f32 = 0.05;
    /// Pixel-equivalents per second synthesised by the arrow keys.
    pub const keyboard_factor: f32 = 100.0;
    /// Frame the scene 30% bigger than its bounding box.
    pub const frame_all_zoom_out: f32 = 1.3;

    pub fn init() Camera {
        return .{};
    }

    /// Updates framing and manual controls. `box` may be null when the sample publishes
    /// no bounds; an invalid (empty) box is ignored the same way.
    pub fn update(self: *Camera, box: ?Box, input: Input, dt: f32, first_frame: bool) void {
        self.frame(box, first_frame);

        const controls = self.updateControls(input, dt);

        // Panning is the only interaction that takes the camera out of auto-framing:
        // orbiting and zooming stay relative to the tracked scene center.
        self.auto_framing = self.auto_framing and !controls.panning;

        self.bind3d();
    }

    /// Camera-override variant of `update` (upstream `GetCameraOverride` path): derives
    /// the orbit parameters from an application supplied camera world transform so they
    /// stay coherent once the user takes over, and uses that transform as the view while
    /// auto-framing is still on.
    pub fn updateWithTransform(
        self: *Camera,
        transform: Float4x4,
        box: ?Box,
        input: Input,
        dt: f32,
        first_frame: bool,
    ) void {
        if (box) |b| {
            if (b.isValid() and (self.auto_framing or first_frame)) {
                // -Z is the camera forward axis.
                const camera_dir = -math.vec.normalize(Vec3f32{
                    transform.cols[2][0],
                    transform.cols[2][1],
                    transform.cols[2][2],
                });
                const camera_pos = transform.translation();
                const box_center = (b.max + b.min) * @as(Vec3f32, @splat(0.5));

                // Arbitrarily decides the focus point is the scene center.
                self.distance = math.vec.norm(box_center - camera_pos);
                self.center = camera_pos + camera_dir * @as(Vec3f32, @splat(self.distance));
                self.angles[0] = std.math.asin(std.math.clamp(camera_dir[1], -1, 1));
                self.angles[1] = std.math.atan2(-camera_dir[0], -camera_dir[2]);
            }
        }

        const controls = self.updateControls(input, dt);
        self.auto_framing = self.auto_framing and !controls.panning;

        if (self.auto_framing) {
            // Upstream inverts the supplied transform directly. That only works when
            // the transform is rigid: the baked sample hands us a joint matrix whose
            // scale track sizes the cuboid drawn for the camera (0.1 there), and that
            // scale would otherwise magnify the whole scene by its reciprocal. Rebuild
            // the basis orthonormally so only rotation and translation reach the view.
            self.view = Float4x4.inverse(rigid(transform)) orelse self.view;
        }

        self.bind3d();
    }

    /// Strips scale (and any shear) from a camera world transform, keeping its
    /// rotation and translation. A zero-length axis falls back to the identity axis,
    /// so a degenerate joint matrix cannot produce a NaN view.
    fn rigid(transform: Float4x4) Float4x4 {
        var result = transform;
        inline for (0..3) |axis| {
            const column = Vec3f32{
                transform.cols[axis][0],
                transform.cols[axis][1],
                transform.cols[axis][2],
            };
            const length = math.vec.norm(column);
            const unit = if (length > 1e-6)
                column / @as(Vec3f32, @splat(length))
            else blk: {
                var fallback = Vec3f32{ 0, 0, 0 };
                fallback[axis] = 1;
                break :blk fallback;
            };
            result.cols[axis] = .{ unit[0], unit[1], unit[2], 0 };
        }
        result.cols[3][3] = 1;
        return result;
    }

    /// Re-centers on `box`. `distance` is only derived on the first frame, `center`
    /// tracks the box every frame for as long as auto-framing is on.
    fn frame(self: *Camera, box: ?Box, first_frame: bool) void {
        const b = box orelse return;
        if (!b.isValid()) return;
        if (!self.auto_framing and !first_frame) return;

        self.center = (b.max + b.min) * @as(Vec3f32, @splat(0.5));
        if (first_frame) {
            const radius = math.vec.norm(b.max - b.min) * 0.5;
            self.distance = radius * frame_all_zoom_out / @tan(fov_y * 0.5);
        }
    }

    /// Applies mouse and keyboard navigation and rebuilds `view`.
    ///
    /// | Input                | Action |
    /// |----------------------|--------|
    /// | RMB drag             | orbit  |
    /// | Shift + RMB drag     | dolly  |
    /// | Alt/Ctrl + RMB drag  | pan    |
    /// | Shift + wheel        | zoom   |
    /// | Arrow keys           | synthesise a drag, same three modes |
    pub fn updateControls(self: *Camera, input: Input, dt: f32) Controls {
        var controls: Controls = .{};

        // Mouse wheel + SHIFT activates zoom.
        if (input.shift_down and input.wheel != 0) {
            controls.zooming_wheel = true;
            const dw: f32 = @floatFromInt(input.wheel);
            self.distance *= 1 + -dw * scroll_factor;
        }

        // Mouse movement since last frame.
        const mdx = input.mouse_x - self.mouse_last_x;
        const mdy = input.mouse_y - self.mouse_last_y;
        self.mouse_last_x = input.mouse_x;
        self.mouse_last_y = input.mouse_y;

        // Keyboard relative dx and dy commands.
        const timed = std.math.clamp(keyboard_factor * dt, 0, 1_000_000);
        const timed_factor: i32 = @max(1, @as(i32, @intFromFloat(timed)));
        const kdx = timed_factor * (@as(i32, @intFromBool(input.key_left)) -
            @as(i32, @intFromBool(input.key_right)));
        const kdy = timed_factor * (@as(i32, @intFromBool(input.key_down)) -
            @as(i32, @intFromBool(input.key_up)));
        const keyboard_interact = kdx != 0 or kdy != 0;

        const dx: f32 = @floatFromInt(mdx + kdx);
        const dy: f32 = @floatFromInt(mdy + kdy);

        if (keyboard_interact or input.right_down) {
            if (input.shift_down) {
                controls.zooming = true;
                self.distance += dy * distance_factor;
            } else if (input.alt_down or input.ctrl_down) {
                controls.panning = true;

                const dx_pan = -dx * pan_factor;
                const dy_pan = -dy * pan_factor;

                // The rows of the view matrix are the camera axes in world space.
                const right: Vec3f32 = .{ self.view.cols[0][0], self.view.cols[1][0], self.view.cols[2][0] };
                const up: Vec3f32 = .{ self.view.cols[0][1], self.view.cols[1][1], self.view.cols[2][1] };
                self.center += right * @as(Vec3f32, @splat(dx_pan)) +
                    up * @as(Vec3f32, @splat(dy_pan));
            } else {
                controls.rotating = true;
                // `@rem` matches C's `fmodf`: the result keeps the sign of the dividend.
                self.angles[0] = @rem(self.angles[0] - dy * angle_factor, std.math.tau);
                self.angles[1] = @rem(self.angles[1] - dx * angle_factor, std.math.tau);
            }
        }

        self.view = viewFromOrbit(self.center, self.angles, self.distance);
        return controls;
    }

    /// Rebuilds both projections for a new framebuffer size.
    ///
    /// **Vulkan clip-space convention.** Unlike upstream's OpenGL matrix this maps the
    /// near plane to `z_ndc = 0` and the far plane to `z_ndc = 1`, and negates the Y row
    /// so world +Y lands at negative clip Y — Vulkan's framebuffer origin is top-left.
    /// The flip lives *here only*: the viewport keeps a positive height and no winding
    /// is reversed anywhere else, so triangles keep upstream's CCW front faces.
    pub fn resize(self: *Camera, width: u32, height: u32) void {
        if (width == 0 or height == 0) {
            self.projection = .identity;
            self.projection_2d = .identity;
            self.view_proj = self.projection.mul(self.view);
            return;
        }

        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        const ratio = w / h;
        const focal = 1 / @tan(fov_y * 0.5);
        const range = near_plane - far_plane; // negative

        self.projection = .{
            .cols = .{
                .{ focal / ratio, 0, 0, 0 },
                .{ 0, -focal, 0, 0 }, // Y flip
                .{ 0, 0, far_plane / range, -1 }, // depth -> [0, 1]
                .{ 0, 0, far_plane * near_plane / range, 0 },
            },
        };

        // Pixel coordinates with a bottom-left origin -> Vulkan clip space. This is the
        // exact GL->Vulkan rewrite of upstream's 2D matrix: x is unchanged, y is
        // mirrored, and depth `-2z` becomes `0.5 - z` (the same ordering, remapped from
        // [-1, 1] to [0, 1]) so the GUI's z = -0.1 panel backgrounds still sit behind.
        self.projection_2d = .{ .cols = .{
            .{ 2 / w, 0, 0, 0 },
            .{ 0, -2 / h, 0, 0 },
            .{ 0, 0, -1, 0 },
            .{ -1, 1, 0.5, 1 },
        } };

        self.view_proj = self.projection.mul(self.view);
    }

    /// Resets center, angles and distance instantly (there are no timed transitions).
    pub fn reset(self: *Camera, setup: Setup) void {
        self.center = setup.center;
        self.angles = setup.angles;
        self.distance = setup.distance;
        self.view = viewFromOrbit(self.center, self.angles, self.distance);
        self.bind3d();
    }

    /// Selects the 3D projection and view for subsequent draws.
    pub fn bind3d(self: *Camera) void {
        self.view_proj = self.projection.mul(self.view);
    }

    /// Selects the 2D pixel-space projection (the view matrix is implicitly identity).
    pub fn bind2d(self: *Camera) void {
        self.view_proj = self.projection_2d;
    }

    /// Duck-typed on `*Im` so this module stays independent of `framework/im.zig`.
    pub fn onGui(self: *Camera, gui: anytype) void {
        gui.doLabel(
            \\-RMB: Rotate
            \\-Shift + Wheel: Zoom
            \\-Shift + RMB: Zoom
            \\-Alt + RMB: Pan
        , .{});
        _ = gui.doCheckBox("Automatic", &self.auto_framing, true);
    }
};

/// `Invert(Translation(center) * RotationY(yaw) * RotationX(pitch) * Translation(0,0,d))`.
fn viewFromOrbit(center: Vec3f32, angles: [2]f32, distance: f32) Float4x4 {
    const world = translation(center)
        .mul(rotationY(angles[1]))
        .mul(rotationX(angles[0]))
        .mul(translation(.{ 0, 0, distance }));
    return Float4x4.inverse(world) orelse Float4x4.identity;
}

fn translation(t: Vec3f32) Float4x4 {
    return .{ .cols = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ t[0], t[1], t[2], 1 },
    } };
}

fn rotationX(angle: f32) Float4x4 {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ .cols = .{
        .{ 1, 0, 0, 0 },
        .{ 0, c, s, 0 },
        .{ 0, -s, c, 0 },
        .{ 0, 0, 0, 1 },
    } };
}

fn rotationY(angle: f32) Float4x4 {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ .cols = .{
        .{ c, 0, -s, 0 },
        .{ 0, 1, 0, 0 },
        .{ s, 0, c, 0 },
        .{ 0, 0, 0, 1 },
    } };
}

/// Full homogeneous transform, unlike `Float4x4.transformPoint` which drops `w`.
fn transformVec4(m: Float4x4, v: [4]f32) [4]f32 {
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    for (0..4) |c| {
        for (0..4) |r| out[r] += m.cols[c][r] * v[c];
    }
    return out;
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "defaults match upstream constants" {
    const camera = Camera.init();
    try testing.expectEqual(@as(f32, 8), camera.distance);
    try testing.expectEqual(Vec3f32{ 0, 0.5, 0 }, camera.center);
    try testing.expectApproxEqAbs(@as(f32, -std.math.pi / 12.0), camera.angles[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 5.0), camera.angles[1], 1e-6);
    try testing.expect(camera.auto_framing);
}

test "first frame frames the box, later frames only track its center" {
    var camera = Camera.init();
    const box: Box = .{ .min = .{ -1, -1, -1 }, .max = .{ 1, 1, 1 } };

    camera.update(box, .{}, 1.0 / 60.0, true);

    const radius = @sqrt(12.0) * 0.5;
    const expected = radius * Camera.frame_all_zoom_out / @tan(Camera.fov_y * 0.5);
    try testing.expectApproxEqAbs(expected, camera.distance, 1e-4);
    try testing.expectEqual(Vec3f32{ 0, 0, 0 }, camera.center);

    // Moving the box on a later frame re-centers but leaves the distance alone.
    const moved: Box = .{ .min = .{ 9, 9, 9 }, .max = .{ 11, 11, 11 } };
    camera.update(moved, .{}, 1.0 / 60.0, false);
    try testing.expectEqual(Vec3f32{ 10, 10, 10 }, camera.center);
    try testing.expectApproxEqAbs(expected, camera.distance, 1e-4);
}

test "a null or invalid box leaves framing untouched" {
    var camera = Camera.init();
    camera.update(null, .{}, 1.0 / 60.0, true);
    try testing.expectEqual(Camera.default_distance, camera.distance);
    try testing.expectEqual(Camera.default_center, camera.center);

    camera.update(Box.empty(), .{}, 1.0 / 60.0, true);
    try testing.expectEqual(Camera.default_distance, camera.distance);
}

test "only panning disables auto framing" {
    const box: Box = .{ .min = .{ -1, -1, -1 }, .max = .{ 1, 1, 1 } };

    // Orbiting keeps auto-framing on.
    var camera = Camera.init();
    camera.update(box, .{ .right_down = true, .mouse_x = 40 }, 0.016, false);
    try testing.expect(camera.auto_framing);

    // So does dollying.
    camera.update(box, .{ .right_down = true, .shift_down = true, .mouse_y = 40 }, 0.016, false);
    try testing.expect(camera.auto_framing);

    // Panning does not.
    camera.update(box, .{ .right_down = true, .alt_down = true, .mouse_x = 80 }, 0.016, false);
    try testing.expect(!camera.auto_framing);

    // Ctrl stands in for alt.
    var ctrl_camera = Camera.init();
    ctrl_camera.update(box, .{ .right_down = true, .ctrl_down = true, .mouse_x = 20 }, 0.016, false);
    try testing.expect(!ctrl_camera.auto_framing);
}

test "orbit, dolly, pan and wheel mappings" {
    var camera = Camera.init();

    // RMB drag orbits: +x drag decreases yaw, +y drag decreases pitch.
    const pitch = camera.angles[0];
    const yaw = camera.angles[1];
    _ = camera.updateControls(.{ .right_down = true, .mouse_x = 100, .mouse_y = 50 }, 0.016);
    try testing.expectApproxEqAbs(pitch - 50 * Camera.angle_factor, camera.angles[0], 1e-5);
    try testing.expectApproxEqAbs(yaw - 100 * Camera.angle_factor, camera.angles[1], 1e-5);

    // Shift + RMB dollies.
    var dolly = Camera.init();
    _ = dolly.updateControls(.{ .right_down = true, .shift_down = true, .mouse_y = 10 }, 0.016);
    try testing.expectApproxEqAbs(
        Camera.default_distance + 10 * Camera.distance_factor,
        dolly.distance,
        1e-5,
    );

    // Alt + RMB pans along the camera axes, moving the center opposite to the drag.
    var pan = Camera.init();
    pan.reset(.{ .center = .{ 0, 0, 0 }, .angles = .{ 0, 0 }, .distance = 5 });
    _ = pan.updateControls(.{ .right_down = true, .alt_down = true, .mouse_x = 10 }, 0.016);
    try testing.expectApproxEqAbs(-10 * Camera.pan_factor, pan.center[0], 1e-5);

    // Shift + wheel zooms multiplicatively; without shift the wheel is ignored.
    var wheel = Camera.init();
    _ = wheel.updateControls(.{ .shift_down = true, .wheel = 1 }, 0.016);
    try testing.expectApproxEqAbs(
        Camera.default_distance * (1 - Camera.scroll_factor),
        wheel.distance,
        1e-5,
    );
    const zoomed = wheel.distance;
    _ = wheel.updateControls(.{ .wheel = 5 }, 0.016);
    try testing.expectEqual(zoomed, wheel.distance);

    // Arrow keys synthesise a drag even with no mouse button held.
    var keys = Camera.init();
    const key_yaw = keys.angles[1];
    _ = keys.updateControls(.{ .key_left = true }, 1.0);
    // timed_factor = max(1, int(100 * 1.0)) = 100, so dx = +100.
    try testing.expectApproxEqAbs(key_yaw - 100 * Camera.angle_factor, keys.angles[1], 1e-4);
}

test "orbit angles wrap into (-2pi, 2pi)" {
    var camera = Camera.init();
    // A very large drag: 10000 px * 0.01 rad = 100 rad of yaw.
    _ = camera.updateControls(.{ .right_down = true, .mouse_x = 10_000, .mouse_y = -10_000 }, 0.016);
    try testing.expect(@abs(camera.angles[0]) < std.math.tau);
    try testing.expect(@abs(camera.angles[1]) < std.math.tau);

    // Wrapping is `fmod`, i.e. it preserves the residue.
    const expected_yaw = @rem(Camera.default_angles[1] - 100.0, std.math.tau);
    try testing.expectApproxEqAbs(expected_yaw, camera.angles[1], 1e-3);
}

test "view places the eye at distance behind the center" {
    var camera = Camera.init();
    camera.reset(.{ .center = .{ 0, 0, 0 }, .angles = .{ 0, 0 }, .distance = 5 });

    // With zero angles the eye is at +Z, so the center lands at -distance in view space.
    const center_view = camera.view.transformPoint(.{ 0, 0, 0 });
    try testing.expectApproxEqAbs(@as(f32, 0), center_view[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), center_view[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -5), center_view[2], 1e-4);

    // The eye itself maps to the view-space origin.
    const eye = camera.view.transformPoint(.{ 0, 0, 5 });
    try testing.expectApproxEqAbs(@as(f32, 0), eye[2], 1e-4);
}

test "projection uses Vulkan clip space: depth [0,1] and flipped Y" {
    var camera = Camera.init();
    camera.resize(1280, 720);

    // View-space point on the near plane -> z_ndc == 0.
    const near = transformVec4(camera.projection, .{ 0, 0, -Camera.near_plane, 1 });
    try testing.expect(near[3] > 0);
    try testing.expectApproxEqAbs(@as(f32, 0), near[2] / near[3], 1e-5);

    // View-space point on the far plane -> z_ndc == 1.
    const far = transformVec4(camera.projection, .{ 0, 0, -Camera.far_plane, 1 });
    try testing.expect(far[3] > 0);
    try testing.expectApproxEqAbs(@as(f32, 1), far[2] / far[3], 1e-5);

    // A point in between stays in between, so depth grows with distance.
    const mid = transformVec4(camera.projection, .{ 0, 0, -10, 1 });
    const mid_z = mid[2] / mid[3];
    try testing.expect(mid_z > 0 and mid_z < 1);

    // +Y in view space maps to negative clip Y (Vulkan's top-left framebuffer origin).
    const up = transformVec4(camera.projection, .{ 0, 1, -10, 1 });
    try testing.expect(up[1] / up[3] < 0);

    // +X keeps its sign, and the aspect ratio squeezes x relative to y.
    const rightward = transformVec4(camera.projection, .{ 1, 0, -10, 1 });
    try testing.expect(rightward[0] / rightward[3] > 0);
    try testing.expect(@abs(rightward[0]) < @abs(up[1]));
}

test "world +Y is negative clip Y through the full view-projection" {
    var camera = Camera.init();
    camera.resize(800, 600);
    camera.reset(.{ .center = .{ 0, 0, 0 }, .angles = .{ 0, 0 }, .distance = 5 });

    const low = transformVec4(camera.view_proj, .{ 0, 0, 0, 1 });
    const high = transformVec4(camera.view_proj, .{ 0, 1, 0, 1 });
    try testing.expect(high[1] / high[3] < low[1] / low[3]);

    // And both are inside the [0, 1] depth range.
    try testing.expect(low[2] / low[3] > 0 and low[2] / low[3] < 1);
}

test "2d projection maps pixels with a bottom-left origin" {
    var camera = Camera.init();
    camera.resize(800, 600);
    camera.bind2d();
    try testing.expectEqual(camera.projection_2d, camera.view_proj);

    // Bottom-left pixel -> (-1, +1) in Vulkan clip space (y = +1 is the bottom).
    const bottom_left = transformVec4(camera.projection_2d, .{ 0, 0, 0, 1 });
    try testing.expectApproxEqAbs(@as(f32, -1), bottom_left[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), bottom_left[1], 1e-6);

    // Top-right pixel -> (+1, -1).
    const top_right = transformVec4(camera.projection_2d, .{ 800, 600, 0, 1 });
    try testing.expectApproxEqAbs(@as(f32, 1), top_right[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1), top_right[1], 1e-6);

    // z = 0 sits mid-range and the GUI's z = -0.1 panel backgrounds sit further away,
    // both inside [0, 1].
    const front = transformVec4(camera.projection_2d, .{ 0, 0, 0, 1 });
    const behind = transformVec4(camera.projection_2d, .{ 0, 0, -0.1, 1 });
    try testing.expectApproxEqAbs(@as(f32, 0.5), front[2], 1e-6);
    try testing.expect(behind[2] > front[2]);
    try testing.expect(behind[2] <= 1);
}

test "a degenerate resize falls back to identity" {
    var camera = Camera.init();
    camera.resize(640, 480);
    camera.resize(0, 480);
    try testing.expectEqual(Float4x4.identity, camera.projection);
    try testing.expectEqual(Float4x4.identity, camera.projection_2d);
}

test "camera override derives orbit parameters from the transform" {
    var camera = Camera.init();
    const box: Box = .{ .min = .{ -1, -1, -1 }, .max = .{ 1, 1, 1 } };

    // A camera 10 units down +Z looking back at the origin: -Z forward, identity basis.
    const transform: Float4x4 = .{ .cols = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 10, 1 },
    } };
    camera.updateWithTransform(transform, box, .{}, 0.016, true);

    try testing.expectApproxEqAbs(@as(f32, 10), camera.distance, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), camera.center[2], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), camera.angles[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), camera.angles[1], 1e-5);

    // While auto-framing, the view is the inverse of the supplied transform.
    const origin = camera.view.transformPoint(.{ 0, 0, 10 });
    try testing.expectApproxEqAbs(@as(f32, 0), origin[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), origin[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), origin[2], 1e-4);

    // Panning hands control back to the orbit view.
    camera.updateWithTransform(
        transform,
        box,
        .{ .right_down = true, .alt_down = true, .mouse_x = 30 },
        0.016,
        false,
    );
    try testing.expect(!camera.auto_framing);
}

test "reset applies a setup instantly" {
    var camera = Camera.init();
    camera.reset(.{ .center = .{ 1, 2, 3 }, .angles = .{ 0.25, -0.5 }, .distance = 12 });
    try testing.expectEqual(Vec3f32{ 1, 2, 3 }, camera.center);
    try testing.expectEqual([2]f32{ 0.25, -0.5 }, camera.angles);
    try testing.expectEqual(@as(f32, 12), camera.distance);
}

test "onGui only needs doLabel and doCheckBox" {
    const StubGui = struct {
        labels: usize = 0,
        checkboxes: usize = 0,

        fn doLabel(gui: *@This(), comptime fmt: []const u8, args: anytype) void {
            comptime std.debug.assert(fmt.len > 0);
            _ = args;
            gui.labels += 1;
        }

        fn doCheckBox(gui: *@This(), label: [:0]const u8, value: *bool, enabled: bool) bool {
            std.debug.assert(std.mem.eql(u8, label, "Automatic"));
            std.debug.assert(enabled);
            value.* = false;
            gui.checkboxes += 1;
            return true;
        }
    };

    var camera = Camera.init();
    var gui: StubGui = .{};
    camera.onGui(&gui);
    try testing.expectEqual(@as(usize, 1), gui.labels);
    try testing.expectEqual(@as(usize, 1), gui.checkboxes);
    try testing.expect(!camera.auto_framing);
}
