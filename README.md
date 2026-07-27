# zig-ozz-animation

A native Zig port of the data-oriented runtime and offline animation pipeline
from [ozz-animation 0.16](https://github.com/guillaumeblanc/ozz-animation).
The public API uses slices, explicit allocators, error unions, and
[Caliper](https://github.com/flying-swallow/caliper) math types/conversions.
No C++ runtime is required.

The repository currently provides:

- owned runtime skeletons, animations, scalar/vector/quaternion tracks, cached
  sampling, blending, local-to-model, motion blending, aim IK, two-bone IK,
  triggering, and CPU skinning;
- raw skeletons/animations/tracks, builders, additive animation generation,
  optimization, sampling, and time-point extraction;
- bounded, versioned, little-endian `.zozz` serialization;
- a pure-Zig converter for every tagged Ozz 0.16 archive type, in big- or
  little-endian form, including concatenated motion tracks and mesh streams;
- glTF/GLB skin hierarchy import through the Zig `cglf` package;
- native and WebAssembly-compatible core modules (graphical samples are a
  separate desktop concern).

## Build

The project tracks Zig `0.17.0-dev`; Caliper and cglf are pinned by commit and
package hash.

```sh
zig build
zig build test
zig build benchmark
```

The installed command is `zig-out/bin/ozz`.

```sh
ozz inspect walk.ozz
ozz migrate walk.ozz walk.zozz
ozz import character.glb --output generated
ozz config print
```

`migrate` accepts the current Ozz 0.16 schemas (Skeleton v2, Animation v7,
RawAnimation v3, and v1 raw skeleton/tracks/meshes). Older archived schemas
that Ozz 0.16 itself rejects are reported as unsupported instead of being
guessed.

`import` currently emits `raw_skeleton.zozz` and `skeleton.zozz` for skin 0.
The glTF conversion API remains filesystem-independent and passes source bytes
to cglf, which handles JSON/GLB parsing and node transforms.

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

Runtime, offline, math, geometry, and archive code is MIT licensed. The cglf
wrapper is GPL-2.0-only, so the glTF integration and unified CLI build that
links it are GPL-2.0-only. See [NOTICE](NOTICE) for upstream attribution. The
desktop pose-rendering bridge under `samples/` is also GPL-2.0-only for
combination with `rhi-zig`.
