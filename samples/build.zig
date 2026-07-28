const std = @import("std");

const Sample = struct {
    name: []const u8,
    description: []const u8,
};

const samples = [_]Sample{
    .{ .name = "additive", .description = "Additive animation blending" },
    .{ .name = "attach", .description = "Joint attachments" },
    .{ .name = "baked", .description = "Baked simulation playback" },
    .{ .name = "blend", .description = "Animation blending" },
    .{ .name = "foot_ik", .description = "Foot inverse kinematics" },
    .{ .name = "look_at", .description = "Procedural look-at" },
    .{ .name = "millipede", .description = "Procedural offline skeleton and animation" },
    .{ .name = "motion_blend", .description = "Motion-aware animation blending" },
    .{ .name = "motion_extraction", .description = "Offline motion extraction" },
    .{ .name = "motion_playback", .description = "Root motion playback" },
    .{ .name = "multithread", .description = "Parallel character sampling" },
    .{ .name = "optimize", .description = "Animation optimization" },
    .{ .name = "partial_blend", .description = "Per-joint partial blending" },
    .{ .name = "playback", .description = "Animation playback" },
    .{ .name = "skinning", .description = "CPU mesh skinning" },
    .{ .name = "two_bone_ik", .description = "Two-bone inverse kinematics" },
    .{ .name = "user_channel", .description = "Animation user channels" },
};

/// Every shader entry point the renderer binds, compiled to SPIR-V (or Metal on Apple)
/// and handed to the sample module under `import`.
const shaders = [_]struct {
    source: []const u8,
    entry: []const u8,
    stage: []const u8,
    import: []const u8,
}{
    .{ .source = "ambient", .entry = "vertexMain", .stage = "vertex", .import = "shader_ambient_vs" },
    .{ .source = "ambient", .entry = "vertexMainInstanced", .stage = "vertex", .import = "shader_ambient_instanced_vs" },
    .{ .source = "ambient", .entry = "fragmentMain", .stage = "fragment", .import = "shader_ambient_fs" },
    .{ .source = "ambient_textured", .entry = "vertexMain", .stage = "vertex", .import = "shader_textured_vs" },
    .{ .source = "ambient_textured", .entry = "fragmentMain", .stage = "fragment", .import = "shader_textured_fs" },
    .{ .source = "skeleton", .entry = "vertexBone", .stage = "vertex", .import = "shader_bone_vs" },
    .{ .source = "skeleton", .entry = "vertexJoint", .stage = "vertex", .import = "shader_joint_vs" },
    .{ .source = "skeleton", .entry = "fragmentMain", .stage = "fragment", .import = "shader_skeleton_fs" },
    .{ .source = "immediate", .entry = "vertexMain", .stage = "vertex", .import = "shader_immediate_vs" },
    .{ .source = "immediate", .entry = "vertexPoints", .stage = "vertex", .import = "shader_points_vs" },
    .{ .source = "immediate", .entry = "fragmentMain", .stage = "fragment", .import = "shader_immediate_fs" },
};

const assets = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = "pab_skeleton", .path = "media/bin/pab_skeleton.ozz" },
    .{ .name = "pab_walk", .path = "media/bin/pab_walk.ozz" },
    .{ .name = "pab_jog", .path = "media/bin/pab_jog.ozz" },
    .{ .name = "pab_run", .path = "media/bin/pab_run.ozz" },
    .{ .name = "pab_walk_no_motion", .path = "media/bin/pab_walk_no_motion.ozz" },
    .{ .name = "pab_jog_no_motion", .path = "media/bin/pab_jog_no_motion.ozz" },
    .{ .name = "pab_run_no_motion", .path = "media/bin/pab_run_no_motion.ozz" },
    .{ .name = "pab_crossarms", .path = "media/bin/pab_crossarms.ozz" },
    .{ .name = "pab_curl_additive", .path = "media/bin/pab_curl_additive.ozz" },
    .{ .name = "pab_splay_additive", .path = "media/bin/pab_splay_additive.ozz" },
    .{ .name = "pab_walk_raw", .path = "media/bin/pab_walk_raw.ozz" },
    .{ .name = "pab_atlas_raw", .path = "media/bin/pab_atlas_raw.ozz" },
    .{ .name = "pab_walk_motion", .path = "media/bin/pab_walk_motion_track.ozz" },
    .{ .name = "pab_jog_motion", .path = "media/bin/pab_jog_motion_track.ozz" },
    .{ .name = "pab_run_motion", .path = "media/bin/pab_run_motion_track.ozz" },
    .{ .name = "robot_skeleton", .path = "media/bin/robot_skeleton.ozz" },
    .{ .name = "robot_animation", .path = "media/bin/robot_animation.ozz" },
    .{ .name = "robot_grasp", .path = "media/bin/robot_track_grasp.ozz" },
    .{ .name = "baked_skeleton", .path = "media/bin/baked_skeleton.ozz" },
    .{ .name = "baked_animation", .path = "media/bin/baked_animation.ozz" },
    .{ .name = "ruby_skeleton", .path = "media/bin/ruby_skeleton.ozz" },
    .{ .name = "ruby_animation", .path = "media/bin/ruby_animation.ozz" },
    .{ .name = "ruby_mesh", .path = "media/bin/ruby_mesh.ozz" },
    .{ .name = "arnaud_mesh", .path = "media/bin/arnaud_mesh.ozz" },
    .{ .name = "floor_mesh", .path = "media/bin/floor.ozz" },
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ozz_dependency = b.dependency("zig_ozz_animation", .{
        .target = target,
        .optimize = optimize,
    });
    const rhi_dependency = b.dependency("rhi", .{
        .target = target,
        .optimize = optimize,
    });
    const sdl_dependency = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    const cimgui_dependency = b.dependency("cimgui_zig", .{
        .no_renderer = true,
        .no_platform = true,
    });
    const upstream = b.dependency("ozz_animation_upstream", .{});

    const sdl_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/framework/sdl_includes.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_translate.addIncludePath(sdl_dependency.path("include"));
    const sdl_module = sdl_translate.createModule();

    const imgui_sdl3_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    imgui_sdl3_module.addIncludePath(cimgui_dependency.path("dcimgui/master"));
    imgui_sdl3_module.addIncludePath(cimgui_dependency.path("dcimgui/master/backends"));
    imgui_sdl3_module.addIncludePath(sdl_dependency.path("include"));
    imgui_sdl3_module.addCSourceFiles(.{
        .root = cimgui_dependency.path("dcimgui/master/backends"),
        .files = &.{
            "imgui_impl_sdl3.cpp",
            "dcimgui_impl_sdl3.cpp",
        },
        .flags = &.{"-DIMGUI_USE_LEGACY_CRC32_ADLER=1"},
    });
    const imgui_sdl3_backend = b.addLibrary(.{
        .name = "imgui_sdl3_backend",
        .linkage = .static,
        .root_module = imgui_sdl3_module,
    });

    const rhi_package = b.lazyImport(@This(), "rhi") orelse return;
    const slangc = rhi_package.getSlangc(b, rhi_dependency) orelse return;
    const is_apple = target.result.os.tag == .macos or target.result.os.tag == .ios;

    var compiled_shaders: [shaders.len]std.Build.LazyPath = undefined;
    for (shaders, &compiled_shaders) |shader, *compiled| {
        compiled.* = try compileShader(
            b,
            slangc,
            is_apple,
            shader.source,
            shader.entry,
            shader.stage,
            shader.import,
        );
    }

    // One shared framework module: `src/main.zig` and every `src/samples/<name>.zig`
    // import it as `framework`, which is also what lets sample files live in their own
    // module while still reaching the framework sources.
    const framework_module = b.createModule(.{
        .root_source_file = b.path("src/framework/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "zig_ozz_animation", .module = ozz_dependency.module("zig_ozz_animation") },
            .{ .name = "rhi", .module = rhi_dependency.module("rhi") },
            .{ .name = "sdl", .module = sdl_module },
        },
    });
    for (shaders, compiled_shaders) |shader, compiled| {
        framework_module.addAnonymousImport(shader.import, .{ .root_source_file = compiled });
    }
    for (assets) |asset| {
        framework_module.addAnonymousImport(asset.name, .{
            .root_source_file = upstream.path(asset.path),
        });
    }
    framework_module.linkLibrary(imgui_sdl3_backend);

    // The same framework built against a headless `rhi` (so `rhi.imgui_c` degrades to
    // `void`, exactly as the Metal build sees it). Everything test-related hangs off
    // this, which is what keeps the test suite runnable without a GPU or a window.
    const headless_rhi = b.dependency("rhi", .{
        .target = target,
        .optimize = optimize,
        .headless = true,
    });
    const framework_headless = b.createModule(.{
        .root_source_file = b.path("src/framework/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig_ozz_animation", .module = ozz_dependency.module("zig_ozz_animation") },
            .{ .name = "rhi", .module = headless_rhi.module("rhi") },
            .{ .name = "sdl", .module = sdl_module },
        },
    });
    for (shaders, compiled_shaders) |shader, compiled| {
        framework_headless.addAnonymousImport(shader.import, .{ .root_source_file = compiled });
    }
    for (assets) |asset| {
        framework_headless.addAnonymousImport(asset.name, .{
            .root_source_file = upstream.path(asset.path),
        });
    }

    const check = b.step("check", "Compile every desktop sample");
    const smoke = b.step("smoke", "Open each sample for three rendered frames");
    const test_step = b.step("test", "Run every sample's headless feature-path tests");
    var previous_smoke: ?*std.Build.Step = null;

    // Collected so `src/tests.zig` can import all 17 samples at once.
    var sample_test_imports: [samples.len]std.Build.Module.Import = undefined;

    for (samples, &sample_test_imports) |sample, *test_import| {
        const options = b.addOptions();
        options.addOption(
            [:0]const u8,
            "name",
            try b.allocator.dupeSentinel(u8, sample.name, 0),
        );
        options.addOption(
            [:0]const u8,
            "description",
            try b.allocator.dupeSentinel(u8, sample.description, 0),
        );

        // Each executable is `src/main.zig` bound to one `src/samples/<name>.zig`
        // through the `sample` import, mirroring upstream's one-file-per-sample layout.
        const sample_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/samples/{s}.zig", .{sample.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_ozz_animation", .module = ozz_dependency.module("zig_ozz_animation") },
                .{ .name = "rhi", .module = rhi_dependency.module("rhi") },
                .{ .name = "framework", .module = framework_module },
            },
        });
        for (assets) |asset| {
            sample_module.addAnonymousImport(asset.name, .{
                .root_source_file = upstream.path(asset.path),
            });
        }

        const module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "zig_ozz_animation", .module = ozz_dependency.module("zig_ozz_animation") },
                .{ .name = "rhi", .module = rhi_dependency.module("rhi") },
                .{ .name = "sdl", .module = sdl_module },
                .{ .name = "framework", .module = framework_module },
                .{ .name = "sample_options", .module = options.createModule() },
                .{ .name = "sample", .module = sample_module },
            },
        });
        // The in-app help overlay shows the upstream sample's own README.
        module.addAnonymousImport("sample_readme", .{
            .root_source_file = upstream.path(
                b.fmt("samples/{s}/README.md", .{sample.name}),
            ),
        });
        module.linkLibrary(imgui_sdl3_backend);

        const executable = b.addExecutable(.{
            .name = b.fmt("ozz_{s}", .{sample.name}),
            .root_module = module,
        });
        executable.root_module.linkLibrary(sdl_dependency.artifact("SDL3"));
        b.installArtifact(executable);
        check.dependOn(&executable.step);

        const check_step = b.step(
            b.fmt("check-{s}", .{sample.name}),
            b.fmt("Compile the {s} sample", .{sample.description}),
        );
        check_step.dependOn(&executable.step);

        const run = b.addRunArtifact(executable);
        run.addPassthruArgs();
        const run_step = b.step(
            b.fmt("run-{s}", .{sample.name}),
            b.fmt("Run the {s} sample", .{sample.description}),
        );
        run_step.dependOn(&run.step);
        const smoke_run = b.addRunArtifact(executable);
        smoke_run.addArg("--frames=3");
        if (previous_smoke) |previous| smoke_run.step.dependOn(previous);
        previous_smoke = &smoke_run.step;

        // A second copy of the sample against the headless framework, so the tests
        // inside `src/samples/<name>.zig` actually run.
        const sample_test_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/samples/{s}.zig", .{sample.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_ozz_animation", .module = ozz_dependency.module("zig_ozz_animation") },
                .{ .name = "rhi", .module = headless_rhi.module("rhi") },
                .{ .name = "framework", .module = framework_headless },
            },
        });
        for (assets) |asset| {
            sample_test_module.addAnonymousImport(asset.name, .{
                .root_source_file = upstream.path(asset.path),
            });
        }
        test_import.* = .{ .name = sample.name, .module = sample_test_module };

        const sample_tests = b.addTest(.{ .root_module = sample_test_module });
        const run_sample_tests = b.addRunArtifact(sample_tests);
        test_step.dependOn(&run_sample_tests.step);

        const sample_test_step = b.step(
            b.fmt("test-{s}", .{sample.name}),
            b.fmt("Run the {s} sample's tests", .{sample.description}),
        );
        sample_test_step.dependOn(&run_sample_tests.step);
    }
    if (previous_smoke) |last| smoke.dependOn(last);

    // GPU-free type-check + unit tests for the shared framework modules.
    const framework_tests = b.addTest(.{ .root_module = framework_headless });
    const framework_test_step = b.step(
        "framework-test",
        "Type-check and unit test the GPU-free framework modules",
    );
    const run_framework_tests = b.addRunArtifact(framework_tests);
    framework_test_step.dependOn(&run_framework_tests.step);
    test_step.dependOn(&run_framework_tests.step);

    // The cross-sample baseline: every sample constructs, updates and draws its GUI
    // headlessly, and satisfies the Application contract.
    var baseline_imports: [samples.len + 1]std.Build.Module.Import = undefined;
    @memcpy(baseline_imports[0..samples.len], &sample_test_imports);
    baseline_imports[samples.len] = .{ .name = "framework", .module = framework_headless };
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &baseline_imports,
    });
    const tests = b.addTest(.{ .root_module = test_module });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const baseline = b.step(
        "baseline",
        "Compile all samples and run every headless feature-path test",
    );
    baseline.dependOn(check);
    baseline.dependOn(test_step);
}

fn compileShader(
    b: *std.Build,
    slangc: std.Build.LazyPath,
    is_apple: bool,
    source: []const u8,
    entry: []const u8,
    stage: []const u8,
    output_name: []const u8,
) !std.Build.LazyPath {
    const command = std.Build.Step.Run.create(
        b,
        b.fmt("compile {s}:{s}", .{ source, entry }),
    );
    command.addFileArg(slangc);
    command.addFileArg(b.path(b.fmt("shaders/{s}.slang", .{source})));
    command.addArgs(&.{
        "-target",
        if (is_apple) "metal" else "spirv",
        "-entry",
        entry,
        "-stage",
        stage,
        "-o",
    });
    return command.addOutputFileArg(if (is_apple)
        b.fmt("{s}.metal", .{output_name})
    else
        b.fmt("{s}.spv", .{output_name}));
}
