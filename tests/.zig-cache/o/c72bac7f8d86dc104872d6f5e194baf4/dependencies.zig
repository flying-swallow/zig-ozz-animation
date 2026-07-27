pub const packages = struct {
    pub const @".." = struct {
        pub const build_root = "..";
        pub const build_zig = @import("..");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "caliper", "caliper-0.3.0-8IlxzRUTBQBMCz2U1zCq4w8ZJwtZ06G0ZaMdl0bgDJnF" },
            .{ "cgltf", "cgltf-0.0.0-_u0gmmUjAwD70w42oAPXXQTA3CYs3j_pVD68iZGy2bd1" },
        };
    };
    pub const @"N-V-__8AALzdDQYWiXSN9v7KwFtPIDpb_OgQryHPPlXmKIyn" = struct {
        pub const build_root = "zig-pkg/N-V-__8AALzdDQYWiXSN9v7KwFtPIDpb_OgQryHPPlXmKIyn";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"caliper-0.3.0-8IlxzRUTBQBMCz2U1zCq4w8ZJwtZ06G0ZaMdl0bgDJnF" = struct {
        pub const build_root = "zig-pkg/caliper-0.3.0-8IlxzRUTBQBMCz2U1zCq4w8ZJwtZ06G0ZaMdl0bgDJnF";
        pub const build_zig = @import("caliper-0.3.0-8IlxzRUTBQBMCz2U1zCq4w8ZJwtZ06G0ZaMdl0bgDJnF");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zbench", "zbench-0.14.1-YTdc781OAQCR6wxqkgAwm9bG4TnFGzm8c9aE-ZPiTAU1" },
        };
    };
    pub const @"cgltf-0.0.0-_u0gmmUjAwD70w42oAPXXQTA3CYs3j_pVD68iZGy2bd1" = struct {
        pub const build_root = "zig-pkg/cgltf-0.0.0-_u0gmmUjAwD70w42oAPXXQTA3CYs3j_pVD68iZGy2bd1";
        pub const build_zig = @import("cgltf-0.0.0-_u0gmmUjAwD70w42oAPXXQTA3CYs3j_pVD68iZGy2bd1");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zbench-0.14.1-YTdc781OAQCR6wxqkgAwm9bG4TnFGzm8c9aE-ZPiTAU1" = struct {
        pub const available = false;
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "zig_ozz_animation", ".." },
    .{ "ozz_animation_upstream", "N-V-__8AALzdDQYWiXSN9v7KwFtPIDpb_OgQryHPPlXmKIyn" },
};
