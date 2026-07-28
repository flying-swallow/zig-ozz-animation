// Skeleton posture shader: bone "spikes" and joint circle-triples.
//
// Port of the ozz-animation sample framework's BoneShader and JointShader
// (samples/framework/internal/shader.cc:499 and :559), sharing the uber vertex
// shader and ambient fragment shader from ambient.slang.
//
// Matrix convention matches ambient.slang: push-constant `float4x4` is stored
// column-major (bytes 0..15 = column 0 = ozz::math::Float4x4::cols[0]), so
// `mul(m, v)` is GLSL's `m * v`.
//
// Vertex streams
// --------------
// stream 0 (per-vertex):   loc0 float3 position, loc1 float3 normal,
//                          loc2 float4 color (rgba8_unorm)
// stream 1 (per-instance): loc3..loc6 float4 = the packed 16-float "joint
//                          matrix" produced by DrawPosture_FillUniforms
//                          (renderer_impl.cc:451). Columns 0..2 hold the parent
//                          matrix basis, column 3 its translation, while the
//                          normally-zero fourth row carries extra payload:
//                            joint0.w / joint1.w / joint2.w = bone direction xyz
//                            joint3.w                       = is_bone flag
//                          Per instance in the source buffer that is floats
//                          [3], [7], [11] and [15].

struct PushConstants {
    float4x4 view_proj;
    float4x4 model;
};

[[vk::push_constant]]
PushConstants pc;

struct WorldMatrix {
    float4 c0;
    float4 c1;
    float4 c2;
    float4 c3;
};

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

// world = pc.model * local, column by column.
WorldMatrix applyModel(WorldMatrix local) {
    WorldMatrix w;
    w.c0 = mul(pc.model, local.c0);
    w.c1 = mul(pc.model, local.c1);
    w.c2 = mul(pc.model, local.c2);
    w.c3 = mul(pc.model, local.c3);
    return w;
}

struct VSInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float3 normal : NORMAL;
    [[vk::location(2)]] float4 color : COLOR0;
    [[vk::location(3)]] float4 joint0 : TEXCOORD1;
    [[vk::location(4)]] float4 joint1 : TEXCOORD2;
    [[vk::location(5)]] float4 joint2 : TEXCOORD3;
    [[vk::location(6)]] float4 joint3 : TEXCOORD4;
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

// BoneShader::GetWorldMatrix (shader.cc:559). The bone model spans x in [0, 1],
// so column 0 = the unnormalized bone vector stretches it exactly from the
// parent joint to the child; y/z are scaled by the bone length so the
// cross-section stays proportional. is_bone == 0 (a leaf) zeroes bone_dir and
// collapses the bone to nothing.
WorldMatrix boneWorldMatrix(VSInput input) {
    float is_bone = input.joint3.w;
    float3 bone_dir = float3(input.joint0.w, input.joint1.w, input.joint2.w) * is_bone;
    float bone_len = length(bone_dir);

    // Pick the parent basis axis least aligned with bone_dir as the binormal.
    float dot1 = dot(input.joint2.xyz, bone_dir);
    float dot2 = dot(input.joint0.xyz, bone_dir);
    float3 binormal = abs(dot1) < abs(dot2) ? input.joint2.xyz : input.joint0.xyz;

    WorldMatrix local;
    local.c0 = float4(bone_dir, 0.0);
    local.c1 = float4(bone_len * normalize(cross(binormal, bone_dir)), 0.0);
    local.c2 = float4(bone_len * normalize(cross(bone_dir, local.c1.xyz)), 0.0);
    local.c3 = float4(input.joint3.xyz, 1.0);
    return applyModel(local);
}

// JointShader::GetWorldMatrix (shader.cc:499). Rebuilds the joint matrix by
// renormalizing the three basis columns (dropping the packed bone_dir stored in
// their .w), keeps the translation, then scales uniformly by the bone length.
WorldMatrix jointWorldMatrix(VSInput input) {
    WorldMatrix joint_matrix;
    joint_matrix.c0 = float4(normalize(input.joint0.xyz), 0.0);
    joint_matrix.c1 = float4(normalize(input.joint1.xyz), 0.0);
    joint_matrix.c2 = float4(normalize(input.joint2.xyz), 0.0);
    joint_matrix.c3 = float4(input.joint3.xyz, 1.0);

    float3 bone_dir = float3(input.joint0.w, input.joint1.w, input.joint2.w);
    float bone_len = length(bone_dir);

    WorldMatrix local;
    local.c0 = joint_matrix.c0 * bone_len;
    local.c1 = joint_matrix.c1 * bone_len;
    local.c2 = joint_matrix.c2 * bone_len;
    local.c3 = joint_matrix.c3;
    return applyModel(local);
}

[shader("vertex")]
VSOutput vertexBone(VSInput input) {
    return shade(boneWorldMatrix(input), input.position, input.normal, input.color);
}

[shader("vertex")]
VSOutput vertexJoint(VSInput input) {
    return shade(jointWorldMatrix(input), input.position, input.normal, input.color);
}

// kShaderAmbientFS
[shader("fragment")]
float4 fragmentMain(VSOutput input) : SV_Target {
    return GetAmbient(input.world_normal) * input.color;
}
