// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Entry point shared by every sample executable. `build.zig` binds the `sample`
//! import to one `src/samples/<name>.zig`; everything else lives in the framework.

const std = @import("std");
const fw = @import("framework");
const options = @import("sample_options");
const sample = @import("sample");

const readme = @embedFile("sample_readme");

pub fn main(init: std.process.Init) !void {
    try fw.Application(sample.Sample).run(init, .{
        .name = options.name,
        .description = options.description,
        .readme = readme,
    });
}
