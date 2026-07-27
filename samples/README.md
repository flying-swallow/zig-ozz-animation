# Desktop sample layer

Files in this directory are GPL-2.0-only so they can be combined with
`rhi-zig` without changing the MIT license of the core library and CLI.

`pose_geometry.zig` is the animation-to-render bridge used by a desktop
adapter: sample an animation, run local-to-model, call `buildBoneLines`, upload
the returned line-list vertices to an `rhi.Buffer`, and issue a line-list draw.
The swapchain/device loop should follow rhi-zig's `02Mesh` sample, which already
selects Vulkan on Linux, Direct3D/Vulkan on Windows, and the local Metal path on
macOS.

The sample layer is intentionally not built for WebAssembly; the runtime,
offline, geometry, archive, and glTF modules remain portable.
