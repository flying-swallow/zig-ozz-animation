// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Aggregates the GPU-free framework modules so `zig build framework-test`
//! type-checks and exercises them without a window or a device.

test {
    _ = @import("application.zig");
    _ = @import("assets.zig");
    _ = @import("camera.zig");
    _ = @import("color.zig");
    _ = @import("renderer.zig");
    _ = @import("shooter.zig");
    _ = @import("icosphere.zig");
    _ = @import("im.zig");
    _ = @import("image.zig");
    _ = @import("mesh.zig");
    _ = @import("motion_utils.zig");
    _ = @import("profile.zig");
    _ = @import("utils.zig");
}
