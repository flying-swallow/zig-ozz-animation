# zig-ozz-animation

A native Zig port of the data-oriented runtime and offline animation pipeline
from [ozz-animation 0.16](https://github.com/guillaumeblanc/ozz-animation).
The public API uses slices, explicit allocators, error unions, and
[Caliper](https://github.com/flying-swallow/caliper) math types/conversions.
No C++ runtime is required.

Two- and three-component values use `ozz.math.Vec2f32` and
`ozz.math.Vec3f32`, which are direct aliases of Caliper's vector types. Access
their components by lane index. Archive serialization writes these vectors as
individual `f32` lanes without depending on their native SIMD layout.

The repository currently provides:

- owned runtime skeletons, animations, scalar/vector/quaternion tracks, cached
  sampling, hierarchy traversal, blending, local-to-model, motion blending,
  aim IK, two-bone IK, triggering, and CPU skinning;
- raw skeletons/animations/tracks, builders, additive animation generation,
  hierarchy-aware optimization with per-joint overrides, sampling, and
  time-point extraction;
- bounded, versioned, little-endian `.zozz` serialization;
- a pure-Zig converter for every tagged Ozz 0.16 archive type, in big- or
  little-endian form, including concatenated motion tracks and mesh streams,
  plus C++-compatible runtime skeleton output;
- glTF/GLB hierarchy, skin, and animation import through the pure-Zig `zgltf`
  package, including external and base64 data buffer URIs;
- native and WebAssembly-compatible core modules (graphical samples are a
  separate desktop concern).

## Build

The project tracks Zig `0.17.0-dev`; Caliper and zgltf are pinned by commit and
package hash.

```sh
zig build
zig build test
zig build check
```

The upstream semantic conformance suite is a separate package and command:

```sh
cd tests
zig build test
```

It fetches the pinned Ozz source and media fixtures into Zig's package cache on
demand. Root-package builds do not resolve that dependency.

Benchmarks are also a separate package:

```sh
cd bench
zig build run
```

Desktop samples are a third standalone package. Their RHI, SDL, Slang, and
upstream media dependencies are never resolved by a root build:

```sh
cd samples
zig build baseline
zig build run-playback
```

The package contains ports of all upstream Ozz samples, including blending,
IK, root motion, multithreaded sampling, optimization, attachments, user
channels, and CPU skinning. See [`samples/README.md`](samples/README.md) for
the complete target list.

The installed command is `zig-out/bin/ozz`.

```sh
ozz inspect walk.ozz
ozz migrate walk.ozz walk.zozz
ozz import character.glb --output generated
ozz import character.glb --output generated --sampling-rate 60
ozz config print
```

`migrate` accepts the current Ozz 0.16 schemas (Skeleton v2, Animation v7,
RawAnimation v3, and v1 raw skeleton/tracks/meshes). Older archived schemas
that Ozz 0.16 itself rejects are reported as unsupported instead of being
guessed.

`import` emits `raw_skeleton.zozz`, `skeleton.zozz`, and numbered raw/runtime
animation archives for every clip in the source. Skeleton-only conversion can
remain filesystem-independent by passing source bytes to `importSkeleton`;
`importAnimationsFile` accepts a path so the importer can resolve external
`.bin` buffers. STEP channels retain their discontinuities and CUBICSPLINE
channels are Hermite-sampled at 30 Hz by default, matching upstream Ozz; pass
`--sampling-rate` or use `importAnimationsFileWithOptions` to override it.

## Native archive

Every object starts with:

| Field | Encoding |
|---|---|
| magic | `ZOZZBIN\0` |
| container version | `u16`, little endian |
| object kind | `u16`, little endian |
| schema version | `u32`, little endian |
| payload length | `u64`, little endian |

Payloads contain no pointers, padding, native-width integers, or host-endian
data. Readers enforce configurable payload, string, and collection limits.
Multiple objects may be concatenated, matching Ozz mesh and motion-track
workflows.

## Library example

```zig
const ozz = @import("zig_ozz_animation");

var context = try ozz.animation.SamplingContext.init(allocator, animation.numTracks());
defer context.deinit();

const pose = try allocator.alloc(ozz.math.SoaTransform, animation.numSoaTracks());
defer allocator.free(pose);
try ozz.animation.sample(&animation, 0.5, &context, pose);
```

## Licensing

Runtime, offline, math, geometry, archive, glTF integration, and CLI code is
MIT licensed. See [NOTICE](NOTICE) for upstream attribution. The desktop
pose-rendering bridge under `samples/` remains GPL-2.0-only for combination
with `rhi-zig`.
