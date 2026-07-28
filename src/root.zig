//! A native Zig port of Ozz Animation 0.16.
//!
//! The package keeps Ozz's data-oriented runtime model while exposing explicit
//! allocators, slices, and error unions.  The public namespaces are intentionally
//! small; implementation details stay in their subsystem modules.

pub const math = @import("math.zig");
pub const serialization = @import("serialization.zig");
pub const animation = @import("animation.zig");
pub const geometry = @import("geometry.zig");
pub const offline = @import("offline.zig");
pub const io = @import("io.zig");
pub const legacy = @import("legacy.zig");
pub const gltf = @import("gltf.zig");

test {
    _ = math;
    _ = serialization;
    _ = animation;
    _ = geometry;
    _ = offline;
    _ = io;
    _ = legacy;
    _ = gltf;
}
