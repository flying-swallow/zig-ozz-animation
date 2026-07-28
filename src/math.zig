const std = @import("std");
const caliper = @import("caliper");

pub const epsilon: f32 = 1e-6;

pub const Float2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero: Float2 = .{};
    pub const one: Float2 = .{ .x = 1, .y = 1 };

    pub fn add(a: Float2, b: Float2) Float2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Float2, b: Float2) Float2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn mul(a: Float2, b: Float2) Float2 {
        return .{ .x = a.x * b.x, .y = a.y * b.y };
    }
    pub fn div(a: Float2, b: Float2) Float2 {
        return .{ .x = a.x / b.x, .y = a.y / b.y };
    }
    pub fn negate(v: Float2) Float2 {
        return .{ .x = -v.x, .y = -v.y };
    }
    pub fn scale(v: Float2, s: f32) Float2 {
        return .{ .x = v.x * s, .y = v.y * s };
    }
    pub fn lengthSquared(v: Float2) f32 {
        return dot(v, v);
    }
    pub fn length(v: Float2) f32 {
        return @sqrt(lengthSquared(v));
    }
    pub fn normalize(v: Float2) Float2 {
        const len = length(v);
        return if (len > epsilon) scale(v, 1 / len) else zero;
    }
    pub fn normalizeSafe(v: Float2, fallback: Float2) Float2 {
        return if (lengthSquared(v) > epsilon) normalize(v) else fallback;
    }
    pub fn isNormalized(v: Float2) bool {
        return @abs(lengthSquared(v) - 1) <= epsilon;
    }
    pub fn min(a: Float2, b: Float2) Float2 {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) };
    }
    pub fn max(a: Float2, b: Float2) Float2 {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) };
    }
    pub fn clamp(v: Float2, lower: Float2, upper: Float2) Float2 {
        return min(max(v, lower), upper);
    }
    pub fn approxEq(a: Float2, b: Float2, tolerance: f32) bool {
        return @abs(a.x - b.x) <= tolerance and @abs(a.y - b.y) <= tolerance;
    }
    pub fn dot(a: Float2, b: Float2) f32 {
        return a.x * b.x + a.y * b.y;
    }
    pub fn lerp(a: Float2, b: Float2, t: f32) Float2 {
        return add(a, scale(.{ .x = b.x - a.x, .y = b.y - a.y }, t));
    }
};

pub const Float3 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const zero: Float3 = .{};
    pub const one: Float3 = .{ .x = 1, .y = 1, .z = 1 };
    pub const x_axis: Float3 = .{ .x = 1 };
    pub const y_axis: Float3 = .{ .y = 1 };
    pub const z_axis: Float3 = .{ .z = 1 };

    pub fn add(a: Float3, b: Float3) Float3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: Float3, b: Float3) Float3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn mul(a: Float3, b: Float3) Float3 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }
    pub fn div(a: Float3, b: Float3) Float3 {
        return .{ .x = a.x / b.x, .y = a.y / b.y, .z = a.z / b.z };
    }
    pub fn negate(v: Float3) Float3 {
        return .{ .x = -v.x, .y = -v.y, .z = -v.z };
    }
    pub fn scale(v: Float3, s: f32) Float3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }
    pub fn dot(a: Float3, b: Float3) f32 {
        return caliper.vec.dot(asVec(a), asVec(b));
    }
    pub fn cross(a: Float3, b: Float3) Float3 {
        return fromVec(caliper.vec.cross(asVec(a), asVec(b)));
    }
    pub fn lengthSquared(v: Float3) f32 {
        return dot(v, v);
    }
    pub fn length(v: Float3) f32 {
        return caliper.vec.norm(asVec(v));
    }
    pub fn normalize(v: Float3) Float3 {
        const len = length(v);
        return if (len > epsilon) fromVec(caliper.vec.normalize(asVec(v))) else zero;
    }
    pub fn normalizeSafe(v: Float3, fallback: Float3) Float3 {
        return if (lengthSquared(v) > epsilon) normalize(v) else fallback;
    }
    pub fn isNormalized(v: Float3) bool {
        return @abs(lengthSquared(v) - 1) <= epsilon;
    }
    pub fn min(a: Float3, b: Float3) Float3 {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y), .z = @min(a.z, b.z) };
    }
    pub fn max(a: Float3, b: Float3) Float3 {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y), .z = @max(a.z, b.z) };
    }
    pub fn clamp(v: Float3, lower: Float3, upper: Float3) Float3 {
        return min(max(v, lower), upper);
    }
    pub fn approxEq(a: Float3, b: Float3, tolerance: f32) bool {
        return @abs(a.x - b.x) <= tolerance and @abs(a.y - b.y) <= tolerance and
            @abs(a.z - b.z) <= tolerance;
    }
    pub fn lerp(a: Float3, b: Float3, t: f32) Float3 {
        return add(a, scale(sub(b, a), t));
    }

    pub fn asVec(v: Float3) caliper.Vec3f32 {
        return .{ v.x, v.y, v.z };
    }

    pub fn fromVec(v: caliper.Vec3f32) Float3 {
        return .{ .x = v[0], .y = v[1], .z = v[2] };
    }
};

pub const Float4 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 0,

    pub const zero: Float4 = .{};
    pub const one: Float4 = .{ .x = 1, .y = 1, .z = 1, .w = 1 };

    pub fn add(a: Float4, b: Float4) Float4 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z, .w = a.w + b.w };
    }
    pub fn sub(a: Float4, b: Float4) Float4 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z, .w = a.w - b.w };
    }
    pub fn mul(a: Float4, b: Float4) Float4 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z, .w = a.w * b.w };
    }
    pub fn div(a: Float4, b: Float4) Float4 {
        return .{ .x = a.x / b.x, .y = a.y / b.y, .z = a.z / b.z, .w = a.w / b.w };
    }
    pub fn negate(v: Float4) Float4 {
        return .{ .x = -v.x, .y = -v.y, .z = -v.z, .w = -v.w };
    }
    pub fn scale(v: Float4, s: f32) Float4 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s, .w = v.w * s };
    }
    pub fn dot(a: Float4, b: Float4) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }
    pub fn lengthSquared(v: Float4) f32 {
        return dot(v, v);
    }
    pub fn length(v: Float4) f32 {
        return @sqrt(lengthSquared(v));
    }
    pub fn normalize(v: Float4) Float4 {
        const len = length(v);
        return if (len > epsilon) scale(v, 1 / len) else zero;
    }
    pub fn normalizeSafe(v: Float4, fallback: Float4) Float4 {
        return if (lengthSquared(v) > epsilon) normalize(v) else fallback;
    }
    pub fn isNormalized(v: Float4) bool {
        return @abs(lengthSquared(v) - 1) <= epsilon;
    }
    pub fn min(a: Float4, b: Float4) Float4 {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y), .z = @min(a.z, b.z), .w = @min(a.w, b.w) };
    }
    pub fn max(a: Float4, b: Float4) Float4 {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y), .z = @max(a.z, b.z), .w = @max(a.w, b.w) };
    }
    pub fn clamp(v: Float4, lower: Float4, upper: Float4) Float4 {
        return min(max(v, lower), upper);
    }
    pub fn approxEq(a: Float4, b: Float4, tolerance: f32) bool {
        return @abs(a.x - b.x) <= tolerance and @abs(a.y - b.y) <= tolerance and
            @abs(a.z - b.z) <= tolerance and @abs(a.w - b.w) <= tolerance;
    }
    pub fn lerp(a: Float4, b: Float4, t: f32) Float4 {
        return .{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
            .z = a.z + (b.z - a.z) * t,
            .w = a.w + (b.w - a.w) * t,
        };
    }
};

pub const Quaternion = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub const identity: Quaternion = .{};

    pub fn dot(a: Quaternion, b: Quaternion) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }
    pub fn conjugate(q: Quaternion) Quaternion {
        return .{ .x = -q.x, .y = -q.y, .z = -q.z, .w = q.w };
    }
    pub fn negate(q: Quaternion) Quaternion {
        return .{ .x = -q.x, .y = -q.y, .z = -q.z, .w = -q.w };
    }
    pub fn add(a: Quaternion, b: Quaternion) Quaternion {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z, .w = a.w + b.w };
    }
    pub fn scale(q: Quaternion, s: f32) Quaternion {
        return .{ .x = q.x * s, .y = q.y * s, .z = q.z * s, .w = q.w * s };
    }
    pub fn isNormalized(q: Quaternion) bool {
        return @abs(dot(q, q) - 1) <= epsilon;
    }
    /// Compares rotations, treating q and -q as the same orientation.
    pub fn approxRotationEq(a: Quaternion, b: Quaternion, cosine_tolerance: f32) bool {
        return @abs(dot(a, b)) >= cosine_tolerance;
    }
    pub fn normalize(q: Quaternion) Quaternion {
        const len_sq = dot(q, q);
        if (len_sq <= epsilon) return identity;
        const inv = 1 / @sqrt(len_sq);
        return .{ .x = q.x * inv, .y = q.y * inv, .z = q.z * inv, .w = q.w * inv };
    }
    pub fn mul(a: Quaternion, b: Quaternion) Quaternion {
        return fromVec(caliper.quat.mul(asVec(a), asVec(b)));
    }
    pub fn rotate(q: Quaternion, v: Float3) Float3 {
        return Float3.fromVec(caliper.quat.rotate_vector(asVec(q), Float3.asVec(v)));
    }
    pub fn nlerp(a: Quaternion, b_in: Quaternion, t: f32) Quaternion {
        var b = b_in;
        if (dot(a, b) < 0) b = .{ .x = -b.x, .y = -b.y, .z = -b.z, .w = -b.w };
        return normalize(.{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
            .z = a.z + (b.z - a.z) * t,
            .w = a.w + (b.w - a.w) * t,
        });
    }
    pub fn lerp(a: Quaternion, b: Quaternion, t: f32) Quaternion {
        return .{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
            .z = a.z + (b.z - a.z) * t,
            .w = a.w + (b.w - a.w) * t,
        };
    }
    pub fn slerp(a: Quaternion, b: Quaternion, t: f32) Quaternion {
        var cos_angle = std.math.clamp(dot(a, b), -1, 1);
        if (@abs(cos_angle) > 0.9995) return normalize(lerp(a, b, t));
        const angle = std.math.acos(cos_angle);
        const sin_angle = @sin(angle);
        cos_angle = @sin((1 - t) * angle) / sin_angle;
        const b_weight = @sin(t * angle) / sin_angle;
        return add(scale(a, cos_angle), scale(b, b_weight));
    }
    pub fn fromAxisAngle(axis_in: Float3, angle: f32) Quaternion {
        const axis = Float3.normalize(axis_in);
        return fromVec(caliper.quat.from_rotation(Float3.asVec(axis), angle));
    }
    pub fn fromAxisCosAngle(axis: Float3, cosine: f32) Quaternion {
        return fromAxisAngle(axis, std.math.acos(std.math.clamp(cosine, -1, 1)));
    }

    /// Builds a quaternion from intrinsic XYZ Euler rotations.
    pub fn fromEuler(euler: Float3) Quaternion {
        const hx = euler.x * 0.5;
        const hy = euler.y * 0.5;
        const hz = euler.z * 0.5;
        const sx = @sin(hx);
        const cx = @cos(hx);
        const sy = @sin(hy);
        const cy = @cos(hy);
        const sz = @sin(hz);
        const cz = @cos(hz);
        return normalize(.{
            .x = sx * cy * cz + cx * sy * sz,
            .y = cx * sy * cz - sx * cy * sz,
            .z = cx * cy * sz + sx * sy * cz,
            .w = cx * cy * cz - sx * sy * sz,
        });
    }

    /// Returns intrinsic XYZ Euler rotations.
    pub fn toEuler(q_in: Quaternion) Float3 {
        const q = normalize(q_in);
        const sin_x = 2 * (q.w * q.x - q.y * q.z);
        const cos_x = 1 - 2 * (q.x * q.x + q.y * q.y);
        const sin_y = std.math.clamp(2 * (q.w * q.y + q.z * q.x), -1, 1);
        const sin_z = 2 * (q.w * q.z - q.x * q.y);
        const cos_z = 1 - 2 * (q.y * q.y + q.z * q.z);
        return .{
            .x = std.math.atan2(sin_x, cos_x),
            .y = std.math.asin(sin_y),
            .z = std.math.atan2(sin_z, cos_z),
        };
    }

    pub fn asVec(q: Quaternion) caliper.Quat4f32 {
        return .{ q.x, q.y, q.z, q.w };
    }

    pub fn fromVec(q: caliper.Quat4f32) Quaternion {
        return .{ .x = q[0], .y = q[1], .z = q[2], .w = q[3] };
    }

    pub fn fromTo(from: Float3, to: Float3) Quaternion {
        if (Float3.lengthSquared(from) <= epsilon or Float3.lengthSquared(to) <= epsilon) {
            return identity;
        }
        return fromVec(caliper.quat.from_to(
            caliper.vec.normalize(Float3.asVec(from)),
            caliper.vec.normalize(Float3.asVec(to)),
        ));
    }
};

pub const Transform = extern struct {
    translation: Float3 = .zero,
    rotation: Quaternion = .identity,
    scale: Float3 = .one,

    pub const identity: Transform = .{};

    pub fn combine(parent: Transform, local: Transform) Transform {
        const scaled = Float3.mul(parent.scale, local.translation);
        return .{
            .translation = Float3.add(parent.translation, Quaternion.rotate(parent.rotation, scaled)),
            .rotation = Quaternion.normalize(Quaternion.mul(parent.rotation, local.rotation)),
            .scale = Float3.mul(parent.scale, local.scale),
        };
    }
    pub fn lerp(a: Transform, b: Transform, t: f32) Transform {
        return .{
            .translation = Float3.lerp(a.translation, b.translation, t),
            .rotation = Quaternion.nlerp(a.rotation, b.rotation, t),
            .scale = Float3.lerp(a.scale, b.scale, t),
        };
    }
};

pub const SimdFloat4 = @Vector(4, f32);
pub const SimdInt4 = @Vector(4, i32);

pub fn lane(v: SimdFloat4, index: usize) f32 {
    const values: [4]f32 = @bitCast(v);
    return values[index];
}

pub fn setLane(v: *SimdFloat4, index: usize, value: f32) void {
    var values: [4]f32 = @bitCast(v.*);
    values[index] = value;
    v.* = @bitCast(values);
}

pub const SoaFloat3 = struct {
    x: SimdFloat4,
    y: SimdFloat4,
    z: SimdFloat4,

    pub fn splat(v: Float3) SoaFloat3 {
        return .{
            .x = @splat(v.x),
            .y = @splat(v.y),
            .z = @splat(v.z),
        };
    }
};

pub const SoaQuaternion = struct {
    x: SimdFloat4,
    y: SimdFloat4,
    z: SimdFloat4,
    w: SimdFloat4,

    pub fn splat(v: Quaternion) SoaQuaternion {
        return .{ .x = @splat(v.x), .y = @splat(v.y), .z = @splat(v.z), .w = @splat(v.w) };
    }
};

pub const SoaTransform = struct {
    translation: SoaFloat3,
    rotation: SoaQuaternion,
    scale: SoaFloat3,

    pub const identity: SoaTransform = .{
        .translation = SoaFloat3.splat(.zero),
        .rotation = SoaQuaternion.splat(.identity),
        .scale = SoaFloat3.splat(.one),
    };
};

pub fn aosToSoa(input: []const Transform, output: []SoaTransform) void {
    for (output, 0..) |*soa, group| {
        soa.* = SoaTransform.identity;
        for (0..4) |lane_index| {
            const index = group * 4 + lane_index;
            if (index >= input.len) break;
            const t = input[index];
            setLane(&soa.translation.x, lane_index, t.translation.x);
            setLane(&soa.translation.y, lane_index, t.translation.y);
            setLane(&soa.translation.z, lane_index, t.translation.z);
            setLane(&soa.rotation.x, lane_index, t.rotation.x);
            setLane(&soa.rotation.y, lane_index, t.rotation.y);
            setLane(&soa.rotation.z, lane_index, t.rotation.z);
            setLane(&soa.rotation.w, lane_index, t.rotation.w);
            setLane(&soa.scale.x, lane_index, t.scale.x);
            setLane(&soa.scale.y, lane_index, t.scale.y);
            setLane(&soa.scale.z, lane_index, t.scale.z);
        }
    }
}

pub fn soaLane(input: SoaTransform, index: usize) Transform {
    return .{
        .translation = .{
            .x = lane(input.translation.x, index),
            .y = lane(input.translation.y, index),
            .z = lane(input.translation.z, index),
        },
        .rotation = .{
            .x = lane(input.rotation.x, index),
            .y = lane(input.rotation.y, index),
            .z = lane(input.rotation.z, index),
            .w = lane(input.rotation.w, index),
        },
        .scale = .{
            .x = lane(input.scale.x, index),
            .y = lane(input.scale.y, index),
            .z = lane(input.scale.z, index),
        },
    };
}

pub fn setSoaLane(output: *SoaTransform, index: usize, t: Transform) void {
    setLane(&output.translation.x, index, t.translation.x);
    setLane(&output.translation.y, index, t.translation.y);
    setLane(&output.translation.z, index, t.translation.z);
    setLane(&output.rotation.x, index, t.rotation.x);
    setLane(&output.rotation.y, index, t.rotation.y);
    setLane(&output.rotation.z, index, t.rotation.z);
    setLane(&output.rotation.w, index, t.rotation.w);
    setLane(&output.scale.x, index, t.scale.x);
    setLane(&output.scale.y, index, t.scale.y);
    setLane(&output.scale.z, index, t.scale.z);
}

pub const Float4x4 = extern struct {
    cols: [4][4]f32,

    pub const identity: Float4x4 = .{ .cols = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };

    pub fn fromTransform(t: Transform) Float4x4 {
        const q = Quaternion.normalize(t.rotation);
        const xx = q.x * q.x;
        const yy = q.y * q.y;
        const zz = q.z * q.z;
        const xy = q.x * q.y;
        const xz = q.x * q.z;
        const yz = q.y * q.z;
        const wx = q.w * q.x;
        const wy = q.w * q.y;
        const wz = q.w * q.z;
        return .{ .cols = .{
            .{ (1 - 2 * (yy + zz)) * t.scale.x, (2 * (xy + wz)) * t.scale.x, (2 * (xz - wy)) * t.scale.x, 0 },
            .{ (2 * (xy - wz)) * t.scale.y, (1 - 2 * (xx + zz)) * t.scale.y, (2 * (yz + wx)) * t.scale.y, 0 },
            .{ (2 * (xz + wy)) * t.scale.z, (2 * (yz - wx)) * t.scale.z, (1 - 2 * (xx + yy)) * t.scale.z, 0 },
            .{ t.translation.x, t.translation.y, t.translation.z, 1 },
        } };
    }

    pub fn mul(a: Float4x4, b: Float4x4) Float4x4 {
        const am: caliper.Mat4f32 = .{ .items = a.cols };
        const bm: caliper.Mat4f32 = .{ .items = b.cols };
        return .{ .cols = am.mul(bm).items };
    }

    pub fn inverse(m: Float4x4) ?Float4x4 {
        const cm: caliper.Mat4f32 = .{ .items = m.cols };
        const det = cm.determinant();
        if (!std.math.isFinite(det) or @abs(det) <= epsilon) return null;
        return .{ .cols = cm.inverse().items };
    }

    pub fn transformPoint(m: Float4x4, p: Float3) Float3 {
        return .{
            .x = m.cols[0][0] * p.x + m.cols[1][0] * p.y + m.cols[2][0] * p.z + m.cols[3][0],
            .y = m.cols[0][1] * p.x + m.cols[1][1] * p.y + m.cols[2][1] * p.z + m.cols[3][1],
            .z = m.cols[0][2] * p.x + m.cols[1][2] * p.y + m.cols[2][2] * p.z + m.cols[3][2],
        };
    }

    pub fn transformVector(m: Float4x4, p: Float3) Float3 {
        return .{
            .x = m.cols[0][0] * p.x + m.cols[1][0] * p.y + m.cols[2][0] * p.z,
            .y = m.cols[0][1] * p.x + m.cols[1][1] * p.y + m.cols[2][1] * p.z,
            .z = m.cols[0][2] * p.x + m.cols[1][2] * p.y + m.cols[2][2] * p.z,
        };
    }

    pub fn translation(m: Float4x4) Float3 {
        return .{ .x = m.cols[3][0], .y = m.cols[3][1], .z = m.cols[3][2] };
    }
};

pub const Box = extern struct {
    min: Float3,
    max: Float3,

    pub fn empty() Box {
        return .{
            .min = .{ .x = std.math.inf(f32), .y = std.math.inf(f32), .z = std.math.inf(f32) },
            .max = .{ .x = -std.math.inf(f32), .y = -std.math.inf(f32), .z = -std.math.inf(f32) },
        };
    }
    pub fn expand(self: *Box, p: Float3) void {
        self.min.x = @min(self.min.x, p.x);
        self.min.y = @min(self.min.y, p.y);
        self.min.z = @min(self.min.z, p.z);
        self.max.x = @max(self.max.x, p.x);
        self.max.y = @max(self.max.y, p.y);
        self.max.z = @max(self.max.z, p.z);
    }

    pub fn isValid(self: Box) bool {
        return self.min.x <= self.max.x and self.min.y <= self.max.y and self.min.z <= self.max.z;
    }

    pub fn contains(self: Box, point: Float3) bool {
        return self.isValid() and
            point.x >= self.min.x and point.x <= self.max.x and
            point.y >= self.min.y and point.y <= self.max.y and
            point.z >= self.min.z and point.z <= self.max.z;
    }

    pub fn merge(a: Box, b: Box) Box {
        if (!a.isValid()) return b;
        if (!b.isValid()) return a;
        return .{
            .min = .{
                .x = @min(a.min.x, b.min.x),
                .y = @min(a.min.y, b.min.y),
                .z = @min(a.min.z, b.min.z),
            },
            .max = .{
                .x = @max(a.max.x, b.max.x),
                .y = @max(a.max.y, b.max.y),
                .z = @max(a.max.z, b.max.z),
            },
        };
    }

    pub fn transformed(self: Box, matrix: Float4x4) Box {
        if (!self.isValid()) return Box.empty();
        var result = Box.empty();
        for (0..8) |corner| {
            result.expand(Float4x4.transformPoint(matrix, .{
                .x = if (corner & 1 != 0) self.max.x else self.min.x,
                .y = if (corner & 2 != 0) self.max.y else self.min.y,
                .z = if (corner & 4 != 0) self.max.z else self.min.z,
            }));
        }
        return result;
    }
};

pub fn Rect(comptime T: type) type {
    return extern struct {
        const Self = @This();
        left: T,
        bottom: T,
        width: T,
        height: T,

        pub fn right(self: Self) T {
            return self.left + self.width;
        }

        pub fn top(self: Self) T {
            return self.bottom + self.height;
        }

        /// Rectangles are half-open on their right and top edges.
        pub fn contains(self: Self, x: T, y: T) bool {
            return x >= self.left and x < self.right() and
                y >= self.bottom and y < self.top();
        }
    };
}

pub const RectInt = Rect(i32);
pub const RectFloat = Rect(f32);

test "transform composition and soa transpose" {
    const parent: Transform = .{
        .translation = .{ .x = 1, .y = 2, .z = 3 },
        .rotation = Quaternion.fromAxisAngle(.z_axis, @as(f32, std.math.pi / 2.0)),
    };
    const child: Transform = .{ .translation = .{ .x = 1 } };
    const combined = Transform.combine(parent, child);
    try std.testing.expectApproxEqAbs(@as(f32, 1), combined.translation.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3), combined.translation.y, 1e-5);

    var soa: [1]SoaTransform = undefined;
    aosToSoa(&.{ parent, child }, &soa);
    try std.testing.expectEqual(parent.translation.x, lane(soa[0].translation.x, 0));
    try std.testing.expectEqual(child.scale.z, lane(soa[0].scale.z, 1));
    try std.testing.expectEqual(@as(f32, 1), lane(soa[0].scale.z, 3));
}
