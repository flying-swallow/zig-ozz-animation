# Ozz animation samples

All 17 upstream ozz-animation samples, ported to Zig. They live in a separate
package so rhi-zig, SDL, Slang, and the upstream media corpus are not dependencies
of the core library.

```sh
cd samples
zig build baseline
zig build run-playback
```

## Layout

```
shaders/          ambient, ambient_textured, skeleton (bone + joint), immediate
src/main.zig      thin entry point; build.zig binds one sample per executable
src/framework/    the Zig counterpart of upstream's samples/framework/
src/samples/      one file per sample, mirroring upstream's layout
```

`src/framework/` provides the pieces upstream's C++ framework does: an
`Application` loop with fixed update rate, time scaling and pause/step; an orbit
`Camera` with auto-framing; a `Renderer` with the full upstream draw set (posture
bones and joint circles, grid, axes, shaded/immediate boxes and spheres, lines,
vectors, binormals, points, meshes and skinned meshes); the upstream Dear ImGui
widget vocabulary (`doSlider` with its `pow` response, `doSlider2D`, `doGraph`)
remapped onto Dear ImGui proper; `PlaybackController`, mesh raycasting, motion
accumulators, profiling records, and TGA screenshot/video capture.

Skinning runs on the CPU through the library's `geometry.skinStrided`, exactly as
upstream does, so the samples exercise the real `SkinningJob`. Lighting, the
instanced posture pass and the procedural checkered texture run on the GPU.
`src/framework/API.md` documents the module contracts and the rhi-zig constraints
the renderer works around.

## Build steps

| step | what it does |
| --- | --- |
| `zig build` | install every executable |
| `zig build check` | compile all 17 without launching a window |
| `zig build test` | framework unit tests + every sample's headless tests |
| `zig build test-<name>` | one sample's tests |
| `zig build baseline` | `check` + `test` |
| `zig build smoke` | open each executable, render three frames, exit (needs a GPU) |
| `zig build run-<name>` | run one sample |

`check` and `test` are headless and need neither a GPU nor a display, which is
what CI runs.

The available `run-*` / `check-*` / `test-*` names are:

- `additive`, `blend`, and `partial_blend`
- `attach`, `user_channel`, and `skinning`
- `look_at`, `two_bone_ik`, and `foot_ik`
- `motion_playback`, `motion_blend`, and `motion_extraction`
- `playback`, `baked`, `optimize`, `multithread`, and `millipede`

## Controls

| input | action |
| --- | --- |
| Right drag | orbit |
| Shift + right drag, Shift + wheel | zoom |
| Alt or Ctrl + right drag | pan |
| Arrow keys | drive the camera |
| Space | pause / resume |
| `N` | pause, then advance exactly one update |
| `F1` | README help overlay (freezes time) |
| `S` / `V` | screenshot / toggle video capture, written as TGA |
| Escape | quit |

Panning is what disables auto-framing, matching upstream.

## Options

```sh
zig build run-skinning -- --resolution=8 --novsync
zig build run-playback -- --animation=/path/to/animation.ozz
zig build run-baked -- --frames=120 --screenshot=110
```

`--help` prints the full list. Beyond the asset overrides (`--skeleton`,
`--animation`, `--mesh`, `--floor`, `--track`, `--raw`) there are `--frames=N`,
`--screenshot=N`, `--max_idle_loops=N`, `--render` / `--norender`,
`--resolution=N`, `--fixed_update_rate=F`, and `--vsync` / `--novsync`.
`--norender` opens no window and only runs the sample's update, which is how a
sample can be driven without a GPU.

Assets are embedded directly from the pinned `ozz-animation` package, so the
installed executables need no media directory. Each sample's help overlay shows
that sample's upstream `README.md`, also embedded.

## Platforms

Vulkan on Linux and Windows. Everything here is developed and verified against
Vulkan.

The Apple/Metal target compiles but does not yet render correctly, because of
gaps in the pinned rhi revision rather than in this code: `Sampler.init` returns
`error.UnsupportedBackend`, `copy_texture_to_buffer` panics, `draw` ignores
`instance_count` and `first_instance`, and the Metal `Cmd.draw` hardcodes
triangle topology. So on Apple the checkered texture and capture are disabled and
the instanced paths fall back to per-object draws, but the skeleton posture pass
(which needs per-instance attributes) and every line/point draw — grid, axes,
joint circles, debug vectors, wireframe — are wrong. Dear ImGui is Vulkan-only
there too. Fixing this needs vertex-buffer bind offsets, honoured instance
parameters, and pipeline topology in rhi's Metal backend.

Dependencies are pinned, including SDL at
`018241066ffdae90d8b11f8bdc6242202f0f5451`. RHI is pinned one revision before its
current `main`; that revision has the same RHI source but retains the Vulkan
generator compatible with this repository's Zig 0.17 toolchain.
