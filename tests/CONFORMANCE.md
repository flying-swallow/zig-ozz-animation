# Ozz semantic conformance ledger

Upstream is pinned to `6cbdc790123aa4731d82e255df187b3a8a808256`.
The pinned tree contains 68 C++ test sources, 386 GoogleTest declarations, and
233 CTest registrations. The inventory test contains an explicit manifest of
every source, its declaration count, and its classification below. It fails on
an added, removed, renamed, or declaration-count-changed source; new sources
cannot silently inherit a broad path classification. Classification changes
are explicit manifest edits. Sources classified as `ported`, plus the directly
mapped box, rect, vector, quaternion, and transform math adapters, additionally
require an exact `Suite/Name` Zig test declaration for every upstream
GoogleTest declaration. Applicable assertions in other adapted suites are
consolidated into focused Zig behavior tests rather than reproducing
GoogleTest/CMake scaffolding one-for-one. `adapted` means behavior is tested
through the idiomatic Zig or Caliper API. `partial/adapted`,
`ported/adapted`, and `N/A` are distinct machine-readable statuses. Source
classification is an inventory guard, not a claim that every individual
GoogleTest assertion has been ported.

## Parity boundary

This ledger measures semantic parity for the Zig library and its `ozz` CLI,
not source, ABI, build-system, or product parity with the whole C++ repository.
Items marked `N/A` are intentional non-goals and do not become remaining work
when all `ported`, `ported/adapted`, `partial/adapted`, and `adapted` items are
complete:

- FBX and Collada/DAE importing are excluded formats. glTF is the supported
  interchange importer; accepting or reproducing FBX/DAE output is not required.
- Group-varint encoding, C++ streams and generic archives, containers,
  allocators/unique pointers, logging, platform macros, spans, and static option
  registration are C++ support APIs with no public Zig counterpart. Zig
  standard-library facilities or typed codecs are the replacement boundary.
- Fuse targets validate generated amalgamated C++ translation units, and the
  subproject target validates CMake consumption. Neither applies to a Zig
  package.
- The upstream interactive desktop applications and sample framework are
  product examples, not conformance inputs. All 17 of them are nonetheless
  ported, in the separate `samples/` package: `samples/src/samples/<name>.zig`
  against a Zig framework (`samples/src/framework/`) built on SDL3, rhi-zig and
  Slang instead of GLFW/OpenGL, with the upstream Dear ImGui widget vocabulary
  remapped onto Dear ImGui proper. Those samples carry their own headless tests
  (`cd samples && zig build test`) but are exercised as product examples, not as
  conformance evidence: pixel-level equivalence with the upstream OpenGL
  renderer is not claimed or measured.

Adding any of these capabilities later is a scope expansion, not closure of a
current conformance gap. Conversely, behavior exposed by the Zig public API or
CLI is not excludable merely because its implementation uses Zig or Caliper.

| Upstream test source group | Status | Zig suite / reason |
| --- | --- | --- |
| `animation/runtime/*_tests.cc` | partial/adapted | `runtime.zig`, `archive.zig`; skeleton traversal, ranged/excluded local-to-model, motion blending, triggering, and aim/two-bone IK cases are ported |
| `animation/offline/additive_animation_builder_tests.cc` | ported | `offline.zig`; translation, rotation, scale, first-key and supplied reference poses, metadata, and invalid reference sizes |
| `animation/offline/animation_builder_tests.cc` | ported/adapted | `offline.zig`; observable cross-track ordering and 65,500-key sampling stress coverage |
| `animation/offline/animation_optimizer_tests.cc` | ported/adapted | `offline.zig`; upstream RDP reduction, identity/constant endpoint pruning, positive/negative/downstream hierarchy scale, rotation distance, and root/leaf override propagation |
| `animation/offline/motion_extractor_tests.cc` | ported/adapted | `offline.zig`; component masks, absolute/skeleton/animation references, independent baking and looping, irregular keys, invalid roots, non-commuting rotations, and coupled position/yaw correction |
| `animation/offline/raw_*_tests.cc` | ported/adapted | `offline.zig`, `archive.zig` |
| `animation/offline/skeleton_builder_tests.cc` | ported/adapted | `offline.zig`; hierarchy traversal, ordering, rest pose, multiple roots, and joint-count limits |
| `animation/offline/track_builder_tests.cc` | ported/adapted | `offline.zig`; boundary keys, interpolation, supported types, and quaternion fixup are covered; C++ move ownership is N/A |
| `animation/offline/track_optimizer_tests.cc` | ported | `offline.zig` |
| `animation/offline/gltf/CMakeLists.txt` | adapted | `gltf.zig`; unified `ozz import` |
| `animation/offline/fbx/*` and `fbx2ozz` registrations | N/A | FBX SDK importer, conversion behavior, and CLI are an excluded format |
| Collada/DAE importer registrations | N/A | DAE handling is supplied only through the excluded FBX importer |
| `animation/offline/tools/test2ozz.cc` fake importer behavior | N/A | C++ test-plugin plumbing |
| `animation/offline/tools/CMakeLists.txt` shared CLI behavior | adapted | Zig CLI tests |
| Scalar/vector/quaternion/transform/box/rect math behavior | adapted | `math.zig`; Caliper-backed Zig types, with exact upstream declaration evidence for the directly mapped vector/quaternion/transform/box/rect suites |
| C++ SIMD/SoA instruction-level API and archive layout | N/A | Zig publicly exposes smaller vector/SoA carrier types used by its runtime, with their own adapter tests; it does not expose the upstream instruction-level function set or binary archive contract |
| `base/encode/group_varint_tests.cc` | N/A | Internal C++ codec has no public or storage-format role in the Zig port |
| `base/endianness_tests.cc` | adapted | `archive.zig` |
| `base/io/archive_tests*.cc` | adapted | `archive.zig`; object/array encoding is replaced by typed native codecs; empty values, names, framing/version rejection, all legacy readers, and the endian-selectable Ozz v2 skeleton writer are tested |
| C++ archive `AlreadyInitialized` cases | N/A | C++ extraction mutates and replaces an existing object; Zig readers return a newly constructed owned value, so there is no initialized destination state |
| C++ archive primitive/class/tag API | N/A | Zig exposes typed codecs rather than the generic C++ `OArchive`/`IArchive` operator API; native framing and trailing-data rejection test the applicable boundary |
| `base/io/stream_tests.cc` | N/A | Zig standard-library readers/writers replace C++ `File`/`MemoryStream`; API/seek/error parity is not promised |
| `base/containers/*` | N/A | C++ standard/intrusive container and container-archive APIs; Zig collections are not compatibility shims |
| `base/memory/*` | N/A | C++ allocator override and unique-pointer APIs; Zig allocator injection/ownership is the public contract |
| `base/log_tests.cc` | N/A | C++ stream-routing and log-level implementation; no public Zig logging facade |
| `base/platform_tests.cc` | N/A | C++ compiler, architecture, endianness, and assertion macro layer |
| `base/span_tests.cc` | N/A | Zig slices replace `ozz::span` |
| `geometry/runtime/skinning_job_tests.cc` | ported/adapted | `geometry.zig`; packed and strided 1-N influence paths, explicit and reconstructed final weights, zero weights, overlapping records, normals, tangents, and inverse-transpose matrices |
| `options/options_tests.cc` | adapted | fixed unified Zig CLI parsing and validation; generic C++ option registration, repeat parsing, validators, and built-path APIs are outside the replacement boundary |
| `options/options_registration*_tests.cc` | N/A | C++ global/static registration and duplicate-registration semantics; Zig uses explicit command parsing |
| `fuse/*` registrations | N/A | generated single-file C++ build/link checks, not additional runtime behavior |
| `sub/test_sub_project.cc` and `test_sub_fbx2ozz` | N/A | CMake `add_subdirectory` consumption and an excluded FBX executable check |
| Upstream `samples/*` and sample framework | N/A | interactive C++ OpenGL/ImGui products; only the renderer-neutral Zig pose-geometry bridge is in scope |

The `SkinningJob.Run` performance registration is maintained under
`zig build benchmark`, not the deterministic unit-test step.

`media.zig` exhaustively decodes all 39 top-level binary media fixtures,
including concatenated motion-track and mesh streams, samples runtime data,
and verifies lossless semantic migration through the native archive format.
`gltf.zig` imports all six glTF scenes, including external buffers and the
expected animation-free triangle case. FBX and Collada remain excluded because
those importers are not part of the Zig port.
