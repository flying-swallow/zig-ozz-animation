const sdl = @import("sdl");

pub extern fn cImGui_ImplSDL3_InitForVulkan(window: *sdl.SDL_Window) bool;
pub extern fn cImGui_ImplSDL3_Shutdown() void;
pub extern fn cImGui_ImplSDL3_NewFrame() void;
pub extern fn cImGui_ImplSDL3_ProcessEvent(event: *const sdl.SDL_Event) bool;
