// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! The sample framework, imported as `framework` by `src/main.zig` and by every
//! `src/samples/<name>.zig`. It is the Zig counterpart of upstream's
//! `ozz-animation/samples/framework/`.

pub const application = @import("application.zig");
pub const assets = @import("assets.zig");
pub const camera = @import("camera.zig");
pub const color = @import("color.zig");
pub const icosphere = @import("icosphere.zig");
pub const im = @import("im.zig");
pub const image = @import("image.zig");
pub const mesh = @import("mesh.zig");
pub const motion_utils = @import("motion_utils.zig");
pub const profile = @import("profile.zig");
pub const renderer = @import("renderer.zig");
pub const utils = @import("utils.zig");

// The types samples name most often, hoisted for convenience.
pub const Application = application.Application;
pub const Assets = assets.Assets;
pub const Camera = camera.Camera;
pub const Color = color.Color;
pub const Im = im.Im;
pub const Mesh = mesh.Mesh;
pub const MotionTrack = motion_utils.MotionTrack;
pub const PlaybackController = utils.PlaybackController;
pub const Renderer = renderer.Renderer;
pub const RenderOptions = renderer.Options;

test {
    _ = @import("tests.zig");
}
