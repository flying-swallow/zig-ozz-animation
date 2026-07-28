// Ambient-lit geometry shader.
//
// Port of the ozz-animation sample framework's "uber" vertex shader plus the
// ambient lighting function and fragment shader
// (samples/framework/internal/shader.cc: kShaderUberVS, kShaderAmbientFct,
// kShaderAmbientFS, AmbientShader and AmbientShaderInstanced).
//
// Matrix convention
// ----------------
// slangc stores a `float4x4` inside a uniform/push-constant block column-major:
// bytes 0..15 are column 0, 16..31 column 1, and so on. That is byte-for-byte
// `ozz::math::Float4x4 { Float4 cols[4] }`, and it means `mul(m, v)` here is
// exactly GLSL's `m * v`. Slang's `m[i]` indexes a *row*, so columns are taken
// via `transpose()`.
//
// Vertex streams
// --------------
// stream 0 (per-vertex):   loc0 float3 position, loc1 float3 normal,
//                          loc2 float4 color (fed by an rgba8_unorm attribute)
// stream 1 (per-instance,  `vertexMainInstanced` only):
//                          loc3..loc6 float4 = columns 0..3 of the model matrix

struct PushConstants {
    float4x4 view_proj;
    float4x4 model;
};

[[vk::push_constant]]
PushConstants pc;

// A world matrix held as its four columns, matching the GLSL `mat4[i]` indexing
// of the original shaders.
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

// Inverse-transpose via the cofactor matrix, so non-uniform scale still yields
// correct normals. Verbatim from kShaderUberVS.
float3 transformNormal(WorldMatrix w, float3 n) {
    float3 cross0 = cross(w.c1.xyz, w.c2.xyz);
    float3 cross1 = cross(w.c2.xyz, w.c0.xyz);
    float3 cross2 = cross(w.c0.xyz, w.c1.xyz);
    float invdet = 1.0 / dot(cross2, w.c2.xyz);
    return (cross0 * n.x + cross1 * n.y + cross2 * n.z) * invdet;
}

// kShaderAmbientFct: a hemispherical gradient, ground -> sky by the up
// component, with slight lateral tinting from normal.x / normal.z.
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
};

struct VSInstancedInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float3 normal : NORMAL;
    [[vk::location(2)]] float4 color : COLOR0;
    [[vk::location(3)]] float4 model0 : TEXCOORD1;
    [[vk::location(4)]] float4 model1 : TEXCOORD2;
    [[vk::location(5)]] float4 model2 : TEXCOORD3;
    [[vk::location(6)]] float4 model3 : TEXCOORD4;
};

struct VSOutput {
    float4 position : SV_Position;
    float3 world_normal : NORMAL;
    float4 color : COLOR0;
};

VSOutput shade(WorldMatrix world, float3 position, float3 normal, float4 color) {
    VSOutput o;
    o.position = mul(pc.view_proj, transformPoint(world, position));
    o.world_normal = transformNormal(world, normal);
    o.color = color;
    return o;
}

// AmbientShader: GetWorldMatrix() { return u_model; }
[shader("vertex")]
VSOutput vertexMain(VSInput input) {
    return shade(columnsOf(pc.model), input.position, input.normal, input.color);
}

// AmbientShaderInstanced: GetWorldMatrix() { return a_m; } -- pc.model is unused.
[shader("vertex")]
VSOutput vertexMainInstanced(VSInstancedInput input) {
    WorldMatrix world;
    world.c0 = input.model0;
    world.c1 = input.model1;
    world.c2 = input.model2;
    world.c3 = input.model3;
    return shade(world, input.position, input.normal, input.color);
}

// kShaderAmbientFS
[shader("fragment")]
float4 fragmentMain(VSOutput input) : SV_Target {
    return GetAmbient(input.world_normal) * input.color;
}
