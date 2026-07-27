# Ozz semantic conformance ledger

Upstream is pinned to `6cbdc790123aa4731d82e255df187b3a8a808256`.
The pinned tree contains 68 C++ test sources, 386 GoogleTest declarations, and
233 CTest registrations. The inventory test verifies those totals and requires
every source to match one of the classifications below. Applicable assertions
are consolidated into focused Zig behavior tests rather than reproducing
GoogleTest/CMake scaffolding one-for-one. `adapted` means behavior is tested
through the idiomatic Zig or Caliper API. Source classification is an inventory
guard, not a claim that every individual GoogleTest assertion has been ported.

| Upstream test source group | Status | Zig suite / reason |
| --- | --- | --- |
| `animation/runtime/*_tests.cc` | partial/adapted | `runtime.zig`, `archive.zig`; triggering loop/boundary behavior is ported, while complex IK degeneracies remain |
| `animation/offline/additive_animation_builder_tests.cc` | ported | `offline.zig` |
| `animation/offline/animation_builder_tests.cc` | partial | `offline.zig`; sorting and many-key stress cases remain |
| `animation/offline/animation_optimizer_tests.cc` | ported | `offline.zig` |
| `animation/offline/motion_extractor_tests.cc` | ported | `offline.zig` |
| `animation/offline/raw_*_tests.cc` | ported/adapted | `offline.zig`, `archive.zig` |
| `animation/offline/skeleton_builder_tests.cc` | partial | `offline.zig`; maximum-joint and traversal variants remain |
| `animation/offline/track_builder_tests.cc` | ported | `offline.zig` |
| `animation/offline/track_optimizer_tests.cc` | ported | `offline.zig` |
| `animation/offline/gltf/CMakeLists.txt` | adapted | `gltf.zig`; unified `ozz import` |
| `animation/offline/fbx/*` | N/A | FBX explicitly excluded |
| Collada/DAE importer registrations | N/A | Collada is deprecated and explicitly excluded |
| `animation/offline/tools/test2ozz.cc` fake importer behavior | N/A | C++ test-plugin plumbing |
| `animation/offline/tools/CMakeLists.txt` shared CLI behavior | adapted | Zig CLI tests |
| Scalar/vector/quaternion/transform/box/rect math behavior | adapted | `math.zig`; Caliper-backed Zig types |
| C++ SIMD/SoA instruction-level API and archive layout | N/A | replaced by Zig vectors and Caliper; runtime SoA behavior remains tested |
| `base/encode/group_varint_tests.cc` | N/A | No public Zig group-varint API |
| `base/endianness_tests.cc` | adapted | `archive.zig` |
| `base/io/archive_tests*.cc` | adapted | `archive.zig`; native and legacy readers |
| `base/io/stream_tests.cc` | N/A | Zig standard-library I/O is used |
| `base/containers/*` | N/A | C++ standard/intrusive container APIs |
| `base/memory/*` | N/A | C++ allocator and unique-pointer APIs |
| `base/log_tests.cc` | N/A | C++ logging implementation |
| `base/platform_tests.cc` | N/A | C++ compiler/platform macro layer |
| `base/span_tests.cc` | N/A | Zig slices replace `ozz::span` |
| `geometry/runtime/skinning_job_tests.cc` | partial | `geometry.zig`; exhaustive upstream result matrix remains |
| `options/options_tests.cc` | adapted | unified Zig CLI validation |
| `options/options_registration*_tests.cc` | N/A | C++ static option registration |
| `fuse/*` registrations | N/A | duplicate amalgamated-C++ coverage |
| `sub/test_sub_project.cc` | N/A | CMake subproject integration |

The `SkinningJob.Run` performance registration is maintained under
`zig build benchmark`, not the deterministic unit-test step.

`media.zig` exhaustively decodes all 39 top-level binary media fixtures,
including concatenated motion-track and mesh streams, samples runtime data,
and verifies lossless semantic migration through the native archive format.
`gltf.zig` imports all six glTF scenes, including external buffers and the
expected animation-free triangle case. FBX and Collada remain excluded because
those importers are not part of the Zig port.
