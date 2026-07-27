// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only
//
// The single translation unit that instantiates cgltf's implementation. The
// `cgltf` Zig module gets the declarations via translate-c of the same header;
// this object supplies the definitions, linked as a static lib.
#define CGLTF_IMPLEMENTATION
#include "cgltf.h"
