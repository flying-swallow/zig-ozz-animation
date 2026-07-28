// Immediate-mode (unlit) shader: lines, wireframes, grids, axes and points.
//
// Port of the ozz-animation sample framework's ImmediatePCShader
// (samples/framework/internal/shader.cc:185) and PointsShader (:327).
//
// Matrix convention matches ambient.slang: the push-constant `float4x4` is
// stored column-major (bytes 0..15 = column 0 = ozz::math::Float4x4::cols[0]),
// so `mul(m, v)` is GLSL's `m * v`.
//
// Vertex streams
// --------------
// vertexMain   (VertexPC):  loc0 float3 position, loc1 float4 color (rgba8_unorm)
// vertexPoints (DrawPoints): loc0 float3 position, loc1 float4 color (rgba8_unorm),
//                            loc2 float size, loc3 float screen_space

struct PushConstants {
    float4x4 mvp;
};

[[vk::push_constant]]
PushConstants pc;

struct VSInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float4 color : COLOR0;
};

struct PointsVSInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float4 color : COLOR0;
    [[vk::location(2)]] float size : TEXCOORD0;
    [[vk::location(3)]] float screen_space : TEXCOORD1;
};

struct VSOutput {
    float4 position : SV_Position;
    float4 color : COLOR0;
};

// `SV_PointSize` is the spelling this slangc (2026.11) accepts for the SPIR-V
// `PointSize` builtin; `[[vk::builtin("PointSize")]]` is rejected as an unknown
// attribute and silently degrades into an ordinary Location varying. On Metal
// it lowers to `[[point_size]]`.
struct PointsVSOutput {
    float4 position : SV_Position;
    float point_size : SV_PointSize;
    float4 color : COLOR0;
};

// ImmediatePCShader: pass-through colour, no lighting.
[shader("vertex")]
VSOutput vertexMain(VSInput input) {
    VSOutput o;
    o.position = mul(pc.mvp, float4(input.position, 1.0));
    o.color = input.color;
    return o;
}

// PointsShader: gl_PointSize = a_screen_space == 0. ? a_size / gl_Position.w
//                                                   : a_size;
[shader("vertex")]
PointsVSOutput vertexPoints(PointsVSInput input) {
    PointsVSOutput o;
    o.position = mul(pc.mvp, float4(input.position, 1.0));
    o.point_size = input.screen_space == 0.0 ? input.size / o.position.w : input.size;
    o.color = input.color;
    return o;
}

[shader("fragment")]
float4 fragmentMain(VSOutput input) : SV_Target {
    return input.color;
}
