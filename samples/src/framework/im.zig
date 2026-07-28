// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Upstream `ozz-animation/samples/framework/imgui.h` widget vocabulary mapped
//! onto Dear ImGui, so sample code reads like the C++ originals
//! (`gui.doSlider("Weight", 0, 1, &weight, 1, true)`).
//!
//! The module must build with **no** Dear ImGui at all: `rhi.imgui_c` degrades
//! to `void` in a headless rhi build (what `zig build framework-test` uses) and
//! ImGui is disabled on Apple targets. Every entry point is therefore wrapped in
//! `if (has_imgui) { ... }`, whose body is not even semantically analysed when
//! the constant is false, and falls through to a no-op that returns `false` and
//! leaves the caller's value untouched.

const std = @import("std");
const rhi = @import("rhi");

/// True when this build links Dear ImGui.
///
/// `rhi.imgui_c` is a *type*: either the translated `cimgui` namespace or
/// literal `void` in a headless / Apple build.
pub const has_imgui = @TypeOf(rhi.imgui_c) == type and rhi.imgui_c != void;

/// Dear ImGui's C API, or an empty namespace when it is absent.
const ig = if (has_imgui) rhi.imgui_c else struct {};

// ---------------------------------------------------------------------------
// Upstream metrics (imgui_impl.cc:48-95). Kept so the custom widgets below
// preserve the original proportions.
// ---------------------------------------------------------------------------

/// Height of a standard widget row, in pixels.
pub const widget_height: f32 = 13;
/// Width of the slider cursor knob, in pixels.
pub const widget_cursor_width: f32 = 8;
/// Corner radius of slider rails and knobs.
pub const slider_round_rect_radius: f32 = 1;
/// A graph is this many widget rows tall.
pub const graph_height_factor: f32 = 3;
/// Digits reserved for the graph's numeric annotations.
pub const graph_label_digits: usize = 5;

// ---------------------------------------------------------------------------
// Upstream colours, packed the way `ImDrawList` wants them (IM_COL32).
// ---------------------------------------------------------------------------

/// Packs 8-bit components into Dear ImGui's `ImU32` (`0xAABBGGRR`).
pub fn col32(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | @as(u32, r);
}

/// Packs normalised float components into Dear ImGui's `ImU32`.
pub fn col32f(r: f32, g: f32, b: f32, a: f32) u32 {
    return col32(quantize(r), quantize(g), quantize(b), quantize(a));
}

fn quantize(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

/// Slider rail background.
pub const slider_background_color = col32f(0.12, 0.12, 0.12, 1);
/// Slider knob and cross-hair.
pub const slider_cursor_color = col32f(0.44, 0.44, 0.44, 1);
/// Slider knob while hovered.
pub const slider_cursor_hot_color = col32f(0.5, 0.5, 0.5, 1);
/// Widget outline.
pub const widget_border_color = col32f(0.44, 0.44, 0.44, 1);
/// Widget outline while hovered.
pub const widget_hot_border_color = col32f(0.78, 0.6, 0.26, 1);
/// Widget fill while held.
pub const widget_active_background_color = col32f(0.78, 0.6, 0.26, 1);
/// Widget outline while held.
pub const widget_active_border_color = col32f(0.19, 0.19, 0.19, 1);
/// Widget label.
pub const widget_text_color = col32f(0.8, 0.8, 0.8, 1);
/// Disabled widget fill.
pub const widget_disabled_background_color = col32f(0.19, 0.19, 0.19, 1);
/// Disabled widget outline.
pub const widget_disabled_border_color = col32f(0.31, 0.31, 0.31, 1);
/// Disabled widget label.
pub const widget_disabled_text_color = col32f(0.45, 0.45, 0.45, 1);

// ---------------------------------------------------------------------------
// Pure helpers — always compiled, always testable, ImGui or not.
// ---------------------------------------------------------------------------

/// Formats into `buffer`, truncating instead of failing, and returns a
/// NUL-terminated slice suitable for the C API. `buffer` must not be empty.
pub fn formatZ(buffer: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    std.debug.assert(buffer.len > 0);
    var writer: std.Io.Writer = .fixed(buffer[0 .. buffer.len - 1]);
    writer.print(fmt, args) catch {};
    const written = writer.buffered().len;
    buffer[written] = 0;
    return buffer[0..written :0];
}

/// Maps a value onto the `[0, 1]` slider position, inverting `sliderDenormalize`.
pub fn sliderNormalize(value: f32, min: f32, max: f32, pow: f32) f32 {
    const lo = @min(min, max);
    const hi = @max(min, max);
    const range = hi - lo;
    if (!(range > 0)) return 0;
    const linear = std.math.clamp((value - lo) / range, 0, 1);
    const exponent = if (pow > 0) pow else 1;
    if (exponent == 1) return linear;
    return std.math.pow(f32, linear, 1 / exponent);
}

/// Maps the `[0, 1]` slider position onto a value: `min + (max - min) * t^pow`.
///
/// This is the non-linear response upstream's `SliderControl` gives the widget;
/// `pow < 1` packs more resolution into the high end of the range (the 1..200
/// fps slider uses `pow = 0.5`). Deliberately *not* Dear ImGui's
/// `ImGuiSliderFlags_Logarithmic`, whose curve is a different shape.
pub fn sliderDenormalize(t: f32, min: f32, max: f32, pow: f32) f32 {
    const lo = @min(min, max);
    const hi = @max(min, max);
    const exponent = if (pow > 0) pow else 1;
    const clamped = std.math.clamp(t, 0, 1);
    const shaped = if (exponent == 1) clamped else std.math.pow(f32, clamped, exponent);
    return std.math.clamp(lo + (hi - lo) * shaped, lo, hi);
}

/// Upstream's `FindMax` (imgui_impl.cc:630): rounds a graph's upper bound up to
/// a stable value so the plot does not jitter every frame.
pub fn graphMax(value: f32) f32 {
    if (!(value > 0)) return 0;
    const exponent = @floor(std.math.log10(value));
    const magnitude = std.math.pow(f32, 10, exponent);
    return @ceil(value / magnitude) * 1.5 * magnitude;
}

// ---------------------------------------------------------------------------
// The binding itself.
// ---------------------------------------------------------------------------

/// Immediate-mode GUI facade handed to `Sample.onGui`.
pub const Im = struct {
    /// When false every method is a no-op. Always false without Dear ImGui.
    enabled: bool,
    /// Number of `beginForm` calls awaiting an `endForm`.
    form_depth: u32 = 0,

    /// Builds a facade. `enabled` is ANDed with `has_imgui`, so a headless or
    /// Apple build always yields an inert instance.
    pub fn init(enabled: bool) Im {
        return .{ .enabled = enabled and has_imgui };
    }

    // -- containers ---------------------------------------------------------

    /// Opens a top-level panel (upstream `Form`). Returns whether its contents
    /// are visible.
    ///
    /// `endForm` must be called even when this returns false, mirroring Dear
    /// ImGui's `Begin`/`End` contract; `defer gui.endForm();` is the idiom.
    pub fn beginForm(self: *Im, title: [:0]const u8) bool {
        if (has_imgui) {
            if (!self.enabled) return false;
            self.form_depth += 1;
            return ig.ImGui_Begin(title.ptr, null, 0);
        }
        return false;
    }

    /// Closes the panel opened by `beginForm`.
    pub fn endForm(self: *Im) void {
        if (has_imgui) {
            if (!self.enabled or self.form_depth == 0) return;
            self.form_depth -= 1;
            ig.ImGui_End();
        }
    }

    /// Collapsible section (upstream `OpenClose`). `open_by_default` seeds the
    /// state the first time the section is seen; afterwards Dear ImGui keeps
    /// the user's choice. Returns whether the section is expanded, so callers
    /// can skip building its contents.
    pub fn openClose(self: *Im, title: [:0]const u8, open_by_default: bool) bool {
        if (has_imgui) {
            if (!self.enabled) return false;
            ig.ImGui_SetNextItemOpen(open_by_default, ig.ImGuiCond_FirstUseEver);
            return ig.ImGui_CollapsingHeader(title.ptr, 0);
        }
        return false;
    }

    // -- widgets ------------------------------------------------------------

    /// Push button. Returns true on the frame it is released over the widget.
    pub fn doButton(self: *Im, label: [:0]const u8, enabled: bool) bool {
        if (has_imgui) {
            if (!self.enabled) return false;
            if (!enabled) ig.ImGui_BeginDisabled(true);
            defer if (!enabled) ig.ImGui_EndDisabled();
            return ig.ImGui_Button(label.ptr);
        }
        return false;
    }

    /// Horizontal slider with upstream's `pow` response curve, see
    /// `sliderDenormalize`. Returns true when the value changed — including
    /// when it was merely clamped back into `[min, max]`.
    ///
    /// A disabled slider leaves `value` completely untouched.
    pub fn doSlider(
        self: *Im,
        label: [:0]const u8,
        min: f32,
        max: f32,
        value: *f32,
        pow: f32,
        enabled: bool,
    ) bool {
        return self.rawSlider(label, min, max, value, pow, enabled, false);
    }

    /// Integer flavour of `doSlider`. The float result is rounded to nearest
    /// (upstream truncates, which biases negative ranges toward zero).
    pub fn doSliderInt(
        self: *Im,
        label: [:0]const u8,
        min: i32,
        max: i32,
        value: *i32,
        pow: f32,
        enabled: bool,
    ) bool {
        const lo: f32 = @floatFromInt(@min(min, max));
        const hi: f32 = @floatFromInt(@max(min, max));
        var scalar: f32 = @floatFromInt(value.*);
        if (!self.rawSlider(label, lo, hi, &scalar, pow, enabled, true)) return false;

        const next: i32 = @intFromFloat(@round(std.math.clamp(scalar, lo, hi)));
        const changed = next != value.*;
        value.* = next;
        return changed;
    }

    /// Square 2D pad (upstream `DoSlider2D`): a full-width invisible button
    /// with a hand-drawn box, cross-hair and knob. Dragging maps the cursor
    /// into the `[min, max]` box on both axes, Y pointing up like upstream.
    pub fn doSlider2D(
        self: *Im,
        label: [:0]const u8,
        min: [2]f32,
        max: [2]f32,
        value: *[2]f32,
        enabled: bool,
    ) bool {
        if (has_imgui) {
            if (!self.enabled) return false;
            const initial = value.*;

            // Upstream's `AddWidget(-1.f)`: as wide as the container, square.
            const available = ig.ImGui_GetContentRegionAvail();
            const side = @max(available.x, widget_height * 4);
            const origin = ig.ImGui_GetCursorScreenPos();

            _ = ig.ImGui_InvisibleButton(label.ptr, .{ .x = side, .y = side }, 0);
            const hot = ig.ImGui_IsItemHovered(0);
            const active = enabled and ig.ImGui_IsItemActive();

            if (enabled) {
                if (active) {
                    const mouse = ig.ImGui_GetMousePos();
                    const tx = std.math.clamp((mouse.x - origin.x) / side, 0, 1);
                    // Screen space is Y-down, the widget's box is Y-up.
                    const ty = 1 - std.math.clamp((mouse.y - origin.y) / side, 0, 1);
                    value[0] = sliderDenormalize(tx, min[0], max[0], 1);
                    value[1] = sliderDenormalize(ty, min[1], max[1], 1);
                } else {
                    // Clamping only happens while the widget is enabled.
                    value[0] = std.math.clamp(value[0], @min(min[0], max[0]), @max(min[0], max[0]));
                    value[1] = std.math.clamp(value[1], @min(min[1], max[1]), @max(min[1], max[1]));
                }
            }

            var knob_color = slider_cursor_color;
            var knob_border_color = widget_border_color;
            var background_color = slider_background_color;
            var border_color = widget_border_color;
            var text_color = widget_text_color;
            if (!enabled) {
                background_color = widget_disabled_background_color;
                border_color = widget_disabled_border_color;
                knob_color = widget_disabled_background_color;
                knob_border_color = widget_disabled_border_color;
                text_color = widget_disabled_text_color;
            } else if (hot) {
                if (active) {
                    knob_color = widget_active_background_color;
                    knob_border_color = widget_active_border_color;
                } else {
                    knob_color = slider_cursor_hot_color;
                    knob_border_color = widget_hot_border_color;
                }
            }

            const draw_list = ig.ImGui_GetWindowDrawList();
            const bottom_right: ig.ImVec2 = .{ .x = origin.x + side, .y = origin.y + side };
            ig.ImDrawList_AddRectFilledEx(
                draw_list,
                origin,
                bottom_right,
                background_color,
                slider_round_rect_radius,
                0,
            );
            ig.ImDrawList_AddRectEx(
                draw_list,
                origin,
                bottom_right,
                border_color,
                slider_round_rect_radius,
                1,
                0,
            );

            // Cross-hair through the current value, then the knob on top.
            const cursor_x = origin.x + sliderNormalize(value[0], min[0], max[0], 1) * side;
            const cursor_y = origin.y + (1 - sliderNormalize(value[1], min[1], max[1], 1)) * side;
            ig.ImDrawList_AddLine(
                draw_list,
                .{ .x = origin.x, .y = cursor_y },
                .{ .x = bottom_right.x, .y = cursor_y },
                knob_color,
            );
            ig.ImDrawList_AddLine(
                draw_list,
                .{ .x = cursor_x, .y = origin.y },
                .{ .x = cursor_x, .y = bottom_right.y },
                knob_color,
            );

            const half = widget_height / 2;
            const knob_min: ig.ImVec2 = .{ .x = cursor_x - half, .y = cursor_y - half };
            const knob_max: ig.ImVec2 = .{ .x = cursor_x + half, .y = cursor_y + half };
            ig.ImDrawList_AddRectFilledEx(
                draw_list,
                knob_min,
                knob_max,
                knob_color,
                slider_round_rect_radius,
                0,
            );
            ig.ImDrawList_AddRectEx(
                draw_list,
                knob_min,
                knob_max,
                knob_border_color,
                slider_round_rect_radius,
                1,
                0,
            );

            // Label centred over the pad, like upstream's `kMiddle` print.
            const text_size = ig.ImGui_CalcTextSize(label.ptr);
            ig.ImDrawList_AddText(
                draw_list,
                .{
                    .x = origin.x + (side - text_size.x) / 2,
                    .y = origin.y + (side - text_size.y) / 2,
                },
                text_color,
                label.ptr,
            );

            return initial[0] != value[0] or initial[1] != value[1];
        }
        return false;
    }

    /// Check box. Returns true on the frame it is toggled.
    pub fn doCheckBox(self: *Im, label: [:0]const u8, value: *bool, enabled: bool) bool {
        if (has_imgui) {
            if (!self.enabled) return false;
            if (!enabled) ig.ImGui_BeginDisabled(true);
            defer if (!enabled) ig.ImGui_EndDisabled();
            return ig.ImGui_Checkbox(label.ptr, value);
        }
        return false;
    }

    /// Radio button: sets `value.* = ref` when picked. Returns true on that frame.
    pub fn doRadioButton(
        self: *Im,
        ref: i32,
        label: [:0]const u8,
        value: *i32,
        enabled: bool,
    ) bool {
        if (has_imgui) {
            if (!self.enabled) return false;
            if (!enabled) ig.ImGui_BeginDisabled(true);
            defer if (!enabled) ig.ImGui_EndDisabled();
            var scratch: c_int = @intCast(value.*);
            const picked = ig.ImGui_RadioButtonIntPtr(label.ptr, &scratch, @intCast(ref));
            if (picked) value.* = @intCast(scratch);
            return picked;
        }
        return false;
    }

    /// Wrapped text line, formatted with Zig's `std.fmt` syntax. Long results
    /// are truncated rather than allocated.
    pub fn doLabel(self: *Im, comptime fmt: []const u8, args: anytype) void {
        if (has_imgui) {
            if (!self.enabled) return;
            var buffer: [512]u8 = undefined;
            ig.ImGui_TextUnformatted(formatZ(&buffer, fmt, args).ptr);
        }
    }

    /// Value plot with upstream's min / mean / max annotations.
    ///
    /// `values` is treated as a circular series and `cursor` is the index of
    /// its **newest** sample, which is exactly what `profile.Record.cursor()`
    /// returns for `profile.Record.values()`.
    pub fn doGraph(
        self: *Im,
        label: [:0]const u8,
        min: f32,
        max: f32,
        mean: f32,
        cursor: usize,
        values: []const f32,
    ) void {
        if (has_imgui) {
            if (!self.enabled or values.len == 0) return;

            // Dear ImGui wants the offset of the *oldest* sample.
            const offset: c_int = @intCast((cursor + 1) % values.len);
            var overlay: [96]u8 = undefined;
            const annotation = formatZ(
                &overlay,
                "min {d:.3} | mean {d:.3} | max {d:.3}",
                .{ min, mean, max },
            );
            const height = ig.ImGui_GetTextLineHeight() * graph_height_factor;
            ig.ImGui_PlotLinesEx(
                label.ptr,
                values.ptr,
                @intCast(values.len),
                offset,
                annotation.ptr,
                min,
                graphMax(max),
                .{ .x = 0, .y = height },
                @sizeOf(f32),
            );
        }
    }

    /// Horizontal rule between widget groups.
    pub fn separator(self: *Im) void {
        if (has_imgui) {
            if (!self.enabled) return;
            ig.ImGui_Separator();
        }
    }

    // -- internals ----------------------------------------------------------

    /// Shared body of `doSlider` / `doSliderInt`.
    ///
    /// Dear ImGui drives a normalised `[0, 1]` position; the pow curve and the
    /// value readout are applied by us so the response matches upstream rather
    /// than `ImGuiSliderFlags_Logarithmic`.
    fn rawSlider(
        self: *Im,
        label: [:0]const u8,
        min: f32,
        max: f32,
        value: *f32,
        pow: f32,
        enabled: bool,
        integral: bool,
    ) bool {
        if (has_imgui) {
            if (!self.enabled) return false;
            const initial = value.*;
            var position = sliderNormalize(initial, min, max, pow);

            // The rail shows the real value, not the normalised position. The
            // rendered number never contains a '%', so ImGui prints it as-is.
            var text: [40]u8 = undefined;
            const shown = sliderDenormalize(position, min, max, pow);
            const display = if (integral)
                formatZ(&text, "{d:.0}", .{@round(shown)})
            else
                formatZ(&text, "{d:.3}", .{shown});

            if (!enabled) ig.ImGui_BeginDisabled(true);
            defer if (!enabled) ig.ImGui_EndDisabled();

            const moved = ig.ImGui_SliderFloatEx(
                label.ptr,
                &position,
                0,
                1,
                display.ptr,
                ig.ImGuiSliderFlags_AlwaysClamp,
            );

            // A disabled slider never writes back, not even to clamp.
            if (!enabled) return false;
            value.* = if (moved)
                sliderDenormalize(position, min, max, pow)
            else
                std.math.clamp(initial, @min(min, max), @max(min, max));
            return value.* != initial;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Tests. All of these run headless; the `Im` ones additionally exercise the
// "ImGui present but disabled" path so they hold in either build.
// ---------------------------------------------------------------------------

test "col32 packs abgr" {
    try std.testing.expectEqual(@as(u32, 0xff0000ff), col32(255, 0, 0, 255));
    try std.testing.expectEqual(@as(u32, 0xff00ff00), col32(0, 255, 0, 255));
    try std.testing.expectEqual(@as(u32, 0xffff0000), col32(0, 0, 255, 255));
    try std.testing.expectEqual(@as(u32, 0x00000000), col32f(0, 0, 0, 0));
    try std.testing.expectEqual(@as(u32, 0xffffffff), col32f(1, 1, 1, 1));
    // Out-of-range components are clamped, not wrapped.
    try std.testing.expectEqual(@as(u32, 0xffffffff), col32f(2, 2, 2, 2));
    try std.testing.expectEqual(@as(u32, 0xff000000), col32f(-1, -1, -1, 1));
}

test "formatZ terminates and truncates" {
    var buffer: [16]u8 = undefined;
    const short = formatZ(&buffer, "{s}={d}", .{ "n", 42 });
    try std.testing.expectEqualStrings("n=42", short);
    try std.testing.expectEqual(@as(u8, 0), short.ptr[short.len]);

    const long = formatZ(&buffer, "{s}", .{"abcdefghijklmnopqrstuvwxyz"});
    try std.testing.expectEqual(@as(usize, 15), long.len);
    try std.testing.expectEqualStrings("abcdefghijklmno", long);
    try std.testing.expectEqual(@as(u8, 0), long.ptr[long.len]);
}

test "slider mapping is linear for pow 1" {
    try std.testing.expectApproxEqAbs(@as(f32, -2), sliderDenormalize(0, -2, 6, 1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2), sliderDenormalize(0.5, -2, 6, 1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6), sliderDenormalize(1, -2, 6, 1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sliderNormalize(2, -2, 6, 1), 1e-6);
}

test "slider mapping follows min + (max - min) * t^pow" {
    // pow = 2 pushes resolution toward the low end of the range.
    try std.testing.expectApproxEqAbs(
        @as(f32, 25),
        sliderDenormalize(0.5, 0, 100, 2),
        1e-4,
    );
    // pow = 0.5 pushes it toward the high end (upstream's fps slider).
    try std.testing.expectApproxEqAbs(
        @as(f32, 1 + 199 * @sqrt(0.5)),
        sliderDenormalize(0.5, 1, 200, 0.5),
        1e-3,
    );
}

test "slider normalize inverts denormalize" {
    const powers = [_]f32{ 0.25, 0.5, 1, 2, 3 };
    const positions = [_]f32{ 0, 0.1, 0.33, 0.5, 0.75, 1 };
    for (powers) |pow| {
        for (positions) |t| {
            const value = sliderDenormalize(t, 1, 200, pow);
            try std.testing.expectApproxEqAbs(t, sliderNormalize(value, 1, 200, pow), 1e-4);
        }
    }
}

test "slider mapping clamps and survives degenerate ranges" {
    try std.testing.expectEqual(@as(f32, 5), sliderDenormalize(-1, 5, 5, 1));
    try std.testing.expectEqual(@as(f32, 0), sliderNormalize(3, 5, 5, 1));
    try std.testing.expectEqual(@as(f32, 1), sliderNormalize(9, 0, 1, 1));
    try std.testing.expectEqual(@as(f32, 0), sliderNormalize(-9, 0, 1, 1));
    // A non-positive pow degrades to the linear curve instead of exploding.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sliderDenormalize(0.5, 0, 1, 0), 1e-6);
    // Reversed bounds are normalised rather than producing NaNs.
    try std.testing.expectApproxEqAbs(@as(f32, 5), sliderDenormalize(0.5, 10, 0, 1), 1e-6);
}

test "graphMax rounds the upper bound up" {
    try std.testing.expectEqual(@as(f32, 0), graphMax(0));
    try std.testing.expectEqual(@as(f32, 0), graphMax(-3));
    // 16.6 -> mexp 1, mpow 10, ceil(1.66) = 2 -> 2 * 1.5 * 10.
    try std.testing.expectApproxEqAbs(@as(f32, 30), graphMax(16.6), 1e-3);
    // 0.4 -> mexp -1, mpow 0.1, ceil(4) = 4 -> 4 * 1.5 * 0.1.
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), graphMax(0.4), 1e-4);
    // The bound is always at or above the value it was built from.
    for ([_]f32{ 0.001, 0.5, 1, 7, 33, 999 }) |value| {
        try std.testing.expect(graphMax(value) >= value);
    }
}

test "disabled Im is inert" {
    var gui = Im.init(false);
    try std.testing.expect(!gui.enabled);

    try std.testing.expect(!gui.beginForm("form"));
    gui.endForm();
    try std.testing.expect(!gui.openClose("section", true));
    try std.testing.expect(!gui.doButton("button", true));

    var scalar: f32 = 0.25;
    try std.testing.expect(!gui.doSlider("slider", 0, 1, &scalar, 1, true));
    try std.testing.expectEqual(@as(f32, 0.25), scalar);

    // Even an out-of-range value is left alone when the GUI is inert.
    var outside: f32 = 12;
    try std.testing.expect(!gui.doSlider("slider", 0, 1, &outside, 1, true));
    try std.testing.expectEqual(@as(f32, 12), outside);

    var integer: i32 = 3;
    try std.testing.expect(!gui.doSliderInt("int", 0, 10, &integer, 1, true));
    try std.testing.expectEqual(@as(i32, 3), integer);

    var pad: [2]f32 = .{ -1, 4 };
    try std.testing.expect(!gui.doSlider2D("pad", .{ 0, 0 }, .{ 1, 1 }, &pad, true));
    try std.testing.expectEqual([2]f32{ -1, 4 }, pad);

    var flag = true;
    try std.testing.expect(!gui.doCheckBox("check", &flag, true));
    try std.testing.expect(flag);

    var choice: i32 = 1;
    try std.testing.expect(!gui.doRadioButton(2, "radio", &choice, true));
    try std.testing.expectEqual(@as(i32, 1), choice);

    gui.doLabel("frame {d} at {d:.2}ms", .{ 7, 1.5 });
    gui.doGraph("graph", 0, 1, 0.5, 0, &.{ 0.1, 0.2 });
    gui.separator();
    try std.testing.expectEqual(@as(u32, 0), gui.form_depth);
}

test "Im.init cannot enable a build without ImGui" {
    const gui = Im.init(true);
    try std.testing.expectEqual(has_imgui, gui.enabled);
}
