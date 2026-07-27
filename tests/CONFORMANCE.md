# Ozz semantic conformance ledger

Upstream is pinned to `6cbdc790123aa4731d82e255df187b3a8a808256`.
Every GoogleTest in a `ported` or `adapted` source is represented by the Zig
suite named in the last column. `adapted` means the behavior is tested through
the idiomatic Zig API rather than reproducing a C++ job or container API.

| Upstream test source group | Status | Zig suite / reason |
| --- | --- | --- |
| `animation/runtime/*_tests.cc` | ported/adapted | `runtime.zig`, `archive.zig` |
| `animation/offline/additive_animation_builder_tests.cc` | ported | `offline.zig` |
| `animation/offline/animation_builder_tests.cc` | ported | `offline.zig` |
| `animation/offline/animation_optimizer_tests.cc` | ported | `offline.zig` |
| `animation/offline/motion_extractor_tests.cc` | ported | `offline.zig` |
| `animation/offline/raw_*_tests.cc` | ported/adapted | `offline.zig`, `archive.zig` |
| `animation/offline/skeleton_builder_tests.cc` | ported | `offline.zig` |
| `animation/offline/track_builder_tests.cc` | ported | `offline.zig` |
| `animation/offline/track_optimizer_tests.cc` | ported | `offline.zig` |
| `animation/offline/gltf/CMakeLists.txt` | adapted | `gltf.zig`; unified `ozz import` |
| `animation/offline/fbx/*` | N/A | FBX explicitly excluded |
| Collada/DAE importer registrations | N/A | Collada is deprecated and explicitly excluded |
| `animation/offline/tools/test2ozz.cc` fake importer behavior | N/A | C++ test-plugin plumbing |
| `animation/offline/tools/CMakeLists.txt` shared CLI behavior | adapted | Zig CLI tests |
| `base/maths/*_tests.cc` | adapted | `math.zig`; Caliper-backed Zig types |
| `base/encode/group_varint_tests.cc` | N/A | No public Zig group-varint API |
| `base/endianness_tests.cc` | adapted | `archive.zig` |
| `base/io/archive_tests*.cc` | adapted | `archive.zig`; native and legacy readers |
| `base/io/stream_tests.cc` | N/A | Zig standard-library I/O is used |
| `base/containers/*` | N/A | C++ standard/intrusive container APIs |
| `base/memory/*` | N/A | C++ allocator and unique-pointer APIs |
| `base/log_tests.cc` | N/A | C++ logging implementation |
| `base/platform_tests.cc` | N/A | C++ compiler/platform macro layer |
| `base/span_tests.cc` | N/A | Zig slices replace `ozz::span` |
| `geometry/runtime/skinning_job_tests.cc` | ported | `geometry.zig` |
| `options/options_tests.cc` | adapted | unified Zig CLI validation |
| `options/options_registration*_tests.cc` | N/A | C++ static option registration |
| `fuse/*` registrations | N/A | duplicate amalgamated-C++ coverage |
| `sub/test_sub_project.cc` | N/A | CMake subproject integration |

The `SkinningJob.Run` performance registration is maintained under
`zig build benchmark`, not the deterministic unit-test step.
