// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Local package wrapping vendored cgltf (`cgltf.h`, v1.15, MIT), following the
//! rhi-zig deps/vma pattern: translate-c of the header is the `c` import of the
//! `cgltf` module, and a static lib built from the local impl TU (`cgltf_impl.c`,
//! which `#define CGLTF_IMPLEMENTATION`s the header) supplies the definitions.
//!
//! Consumed by core's `distill` build tool: it imports the `cgltf` module and
//! links the `cgltf` static lib to cook `.gltf`/`.glb` into ZCSM at build time.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("cgltf.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_module = translate_c.createModule();

    const module = b.addModule("cgltf", .{ .root_source_file = b.path("main.zig") });
    module.addImport("c", c_module);

    const root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addCSourceFile(.{ .file = b.path("cgltf_impl.c") });
    root_module.addIncludePath(b.path("."));
    const lib = b.addLibrary(.{
        .name = "cgltf",
        .root_module = root_module,
        .linkage = .static,
    });

    b.installArtifact(lib);
}
