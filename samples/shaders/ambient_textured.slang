// Ambient-lit, textured geometry shader.
//
// Port of the ozz-animation sample framework's AmbientTexturedShader
// (samples/framework/internal/shader.cc): the same uber vertex shader as
// ambient.slang plus the kPassUv chunk, and kShaderAmbientTexturedFS.
//
// Matrix convention matches ambient.slang: push-constant `float4x4` is stored
// column-major (bytes 0..15 = column 0 = ozz::math::Float4x4::cols[0]), so
// `mul(m, v)` is GLSL's `m * v`.
//
// Vertex stream 0 (per-vertex): loc0 float3 position, loc1 float3 normal,
//                               loc2 float4 color (rgba8_unorm), loc3 float2 uv

struct PushConstants {
    float4x4 view_proj;
    float4x4 model;
};

[[vk::push_constant]]
PushConstants pc;

// Separate texture + sampler, matching the RHI descriptor model.
[[vk::binding(0, 0)]] Texture2D<float4> u_texture;
[[vk::binding(1, 0)]] SamplerState u_sampler;

struct WorldMatrix {
    float4 c0;
    float4 c1;
    float4 c2;
    float4 c3;
};

WorldMatrix columnsOf(float4x4 m) {
    float4x4 t = transpose(m);
    WorldMatrix w;
    w.c0 = t[0];
    w.c1 = t[1];
    w.c2 = t[2];
    w.c3 = t[3];
    return w;
}

float4 transformPoint(WorldMatrix w, float3 p) {
    return w.c0 * p.x + w.c1 * p.y + w.c2 * p.z + w.c3;
}

// Cofactor inverse-transpose, verbatim from kShaderUberVS.
float3 transformNormal(WorldMatrix w, float3 n) {
    float3 cross0 = cross(w.c1.xyz, w.c2.xyz);
    float3 cross1 = cross(w.c2.xyz, w.c0.xyz);
    float3 cross2 = cross(w.c0.xyz, w.c1.xyz);
    float invdet = 1.0 / dot(cross2, w.c2.xyz);
    return (cross0 * n.x + cross1 * n.y + cross2 * n.z) * invdet;
}

// kShaderAmbientFct
float4 GetAmbient(float3 world_normal) {
    float3 normal = normalize(world_normal);
    float3 alpha = (normal + 1.0) * 0.5;
    float2 bt = lerp(float2(0.3, 0.7), float2(0.4, 0.8), alpha.xz);
    float3 ambient = lerp(float3(bt.x, 0.3, bt.x), float3(bt.y, 0.8, bt.y), alpha.y);
    return float4(ambient, 1.0);
}

struct VSInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float3 normal : NORMAL;
    [[vk::location(2)]] float4 color : COLOR0;
    [[vk::location(3)]] float2 uv : TEXCOORD0;
};

struct VSOutput {
    float4 position : SV_Position;
    float3 world_normal : NORMAL;
    float4 color : COLOR0;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
VSOutput vertexMain(VSInput input) {
    WorldMatrix world = columnsOf(pc.model);
    VSOutput o;
    o.position = mul(pc.view_proj, transformPoint(world, input.position));
    o.world_normal = transformNormal(world, input.normal);
    o.color = input.color;
    o.uv = input.uv;
    return o;
}

// kShaderAmbientTexturedFS
[shader("fragment")]
float4 fragmentMain(VSOutput input) : SV_Target {
    return GetAmbient(input.world_normal) * input.color *
           u_texture.Sample(u_sampler, input.uv);
}
