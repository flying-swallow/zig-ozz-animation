// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! The `cgltf` module root: exposes the translate-c bindings as `c` so consumers
//! call `@import("cgltf").c.cgltf_parse(...)`. The implementations are linked
//! from the `cgltf` static lib (see build.zig).

pub const c = @import("c");
