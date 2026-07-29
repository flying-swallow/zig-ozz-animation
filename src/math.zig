const std = @import("std");
const caliper = @import("caliper");

pub const epsilon: f32 = 1e-6;

pub const Vec2f32 = caliper.Vec2f32;
pub const Vec3f32 = caliper.Vec3f32;
pub const Vec4f32 = caliper.Vec4f32;
pub const vec = caliper.vec;
pub const approx = caliper.approx;

pub const Quat4f32 = caliper.Quat4f32;

/// Quaternion operations over `Quat4f32` (xyzw order, `@Vector(4, f32)`).
///
/// Note that `Quat4f32` and `Vec4f32` are the same Zig type, so a quaternion is not
/// distinguishable from a 4-vector by type alone. Code that must tell a rotation track from a
/// float4 track dispatches on `animation.ValueKind`, not on the value type.
pub const quat = struct {
    pub const identity: Quat4f32 = .{ 0, 0, 0, 1 };

    pub const mul = caliper.quat.mul;
    pub const conjugate = caliper.quat.conjugate;
    pub const inverse = caliper.quat.inverse;
    pub const lerp = caliper.quat.lerp;
    pub const nlerp = caliper.quat.nlerp;
    pub const slerp = caliper.quat.slerp;
    pub const normalize = caliper.quat.normalize_default;
    pub const toAxisAngle = caliper.quat.to_axis_angle;

    pub fn dot(a: Quat4f32, b: Quat4f32) f32 {
        return caliper.vec.dot(a, b);
    }
    pub fn negate(q: Quat4f32) Quat4f32 {
        return -q;
    }
    pub fn add(a: Quat4f32, b: Quat4f32) Quat4f32 {
        return a + b;
    }
    pub fn scale(q: Quat4f32, s: f32) Quat4f32 {
        return q * @as(Quat4f32, @splat(s));
    }
    pub fn isNormalized(q: Quat4f32) bool {
        return caliper.vec.is_normalized_default(q);
    }
    /// Compares rotations, treating q and -q as the same orientation.
    pub fn approxRotationEq(a: Quat4f32, b: Quat4f32, cosine_tolerance: f32) bool {
        return @abs(dot(a, b)) >= cosine_tolerance;
    }
    pub fn rotate(q: Quat4f32, v: Vec3f32) Vec3f32 {
        return caliper.quat.rotate_vector(q, v);
    }
    pub fn fromAxisAngle(axis_in: Vec3f32, angle: f32) Quat4f32 {
        const axis_length = vec.norm(axis_in);
        const axis: Vec3f32 = if (axis_length > epsilon)
            vec.scale(axis_in, 1 / axis_length)
        else
            @splat(0);
        return caliper.quat.from_rotation(axis, angle);
    }
    pub fn fromAxisCosAngle(axis: Vec3f32, cosine: f32) Quat4f32 {
        return fromAxisAngle(axis, std.math.acos(std.math.clamp(cosine, -1, 1)));
    }

    /// Builds a quaternion from intrinsic XYZ Euler rotations.
    ///
    /// Caliper also ships `from_eular_angles`, which composes in the opposite order
    /// (intrinsic ZYX); ozz authors its motion data in intrinsic XYZ, so this must stay the
    /// `_xyz_intrinsic` variant.
    pub fn fromEuler(euler: Vec3f32) Quat4f32 {
        return normalize(caliper.quat.from_euler_xyz_intrinsic(euler));
    }

    /// Returns intrinsic XYZ Euler rotations.
    pub fn toEuler(q: Quat4f32) Vec3f32 {
        return caliper.quat.to_euler_xyz_intrinsic(normalize(q));
    }

    pub fn fromTo(from: Vec3f32, to: Vec3f32) Quat4f32 {
        if (vec.norm_sqr(from) <= epsilon or vec.norm_sqr(to) <= epsilon) {
            return identity;
        }
        return caliper.quat.from_to(
            caliper.vec.normalize(from),
            caliper.vec.normalize(to),
        );
    }
};

pub const Transform = struct {
    translation: Vec3f32 = .{ 0, 0, 0 },
    rotation: Quat4f32 = quat.identity,
    scale: Vec3f32 = .{ 1, 1, 1 },

    pub const identity: Transform = .{};

    pub fn combine(parent: Transform, local: Transform) Transform {
        const scaled = vec.mul(parent.scale, local.translation);
        return .{
            .translation = vec.add(parent.translation, quat.rotate(parent.rotation, scaled)),
            .rotation = quat.normalize(quat.mul(parent.rotation, local.rotation)),
            .scale = vec.mul(parent.scale, local.scale),
        };
    }
    pub fn lerp(a: Transform, b: Transform, t: f32) Transform {
        return .{
            .translation = approx.lerp_exact(a.translation, b.translation, t),
            .rotation = quat.nlerp(a.rotation, b.rotation, t),
            .scale = approx.lerp_exact(a.scale, b.scale, t),
        };
    }
};

pub const SimdInt4 = @Vector(4, i32);

pub fn lane(v: Vec4f32, index: usize) f32 {
    const values: [4]f32 = @bitCast(v);
    return values[index];
}

pub fn setLane(v: *Vec4f32, index: usize, value: f32) void {
    var values: [4]f32 = @bitCast(v.*);
    values[index] = value;
    v.* = @bitCast(values);
}

pub const SoaFloat3 = struct {
    x: Vec4f32,
    y: Vec4f32,
    z: Vec4f32,

    pub fn splat(v: Vec3f32) SoaFloat3 {
        return .{
            .x = @splat(v[0]),
            .y = @splat(v[1]),
            .z = @splat(v[2]),
        };
    }
};

pub const SoaQuaternion = struct {
    x: Vec4f32,
    y: Vec4f32,
    z: Vec4f32,
    w: Vec4f32,

    pub fn splat(v: Quat4f32) SoaQuaternion {
        return .{ .x = @splat(v[0]), .y = @splat(v[1]), .z = @splat(v[2]), .w = @splat(v[3]) };
    }
};

pub const SoaTransform = struct {
    translation: SoaFloat3,
    rotation: SoaQuaternion,
    scale: SoaFloat3,

    pub const identity: SoaTransform = .{
        .translation = SoaFloat3.splat(.{ 0, 0, 0 }),
        .rotation = SoaQuaternion.splat(quat.identity),
        .scale = SoaFloat3.splat(.{ 1, 1, 1 }),
    };
};

pub fn aosToSoa(input: []const Transform, output: []SoaTransform) void {
    for (output, 0..) |*soa, group| {
        soa.* = SoaTransform.identity;
        for (0..4) |lane_index| {
            const index = group * 4 + lane_index;
            if (index >= input.len) break;
            const t = input[index];
            setLane(&soa.translation.x, lane_index, t.translation[0]);
            setLane(&soa.translation.y, lane_index, t.translation[1]);
            setLane(&soa.translation.z, lane_index, t.translation[2]);
            setLane(&soa.rotation.x, lane_index, t.rotation[0]);
            setLane(&soa.rotation.y, lane_index, t.rotation[1]);
            setLane(&soa.rotation.z, lane_index, t.rotation[2]);
            setLane(&soa.rotation.w, lane_index, t.rotation[3]);
            setLane(&soa.scale.x, lane_index, t.scale[0]);
            setLane(&soa.scale.y, lane_index, t.scale[1]);
            setLane(&soa.scale.z, lane_index, t.scale[2]);
        }
    }
}

pub fn soaLane(input: SoaTransform, index: usize) Transform {
    return .{
        .translation = .{
            lane(input.translation.x, index),
            lane(input.translation.y, index),
            lane(input.translation.z, index),
        },
        .rotation = .{
            lane(input.rotation.x, index),
            lane(input.rotation.y, index),
            lane(input.rotation.z, index),
            lane(input.rotation.w, index),
        },
        .scale = .{
            lane(input.scale.x, index),
            lane(input.scale.y, index),
            lane(input.scale.z, index),
        },
    };
}

pub fn setSoaLane(output: *SoaTransform, index: usize, t: Transform) void {
    setLane(&output.translation.x, index, t.translation[0]);
    setLane(&output.translation.y, index, t.translation[1]);
    setLane(&output.translation.z, index, t.translation[2]);
    setLane(&output.rotation.x, index, t.rotation[0]);
    setLane(&output.rotation.y, index, t.rotation[1]);
    setLane(&output.rotation.z, index, t.rotation[2]);
    setLane(&output.rotation.w, index, t.rotation[3]);
    setLane(&output.scale.x, index, t.scale[0]);
    setLane(&output.scale.y, index, t.scale[1]);
    setLane(&output.scale.z, index, t.scale[2]);
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
        const q = quat.normalize(t.rotation);
        const xx = q[0] * q[0];
        const yy = q[1] * q[1];
        const zz = q[2] * q[2];
        const xy = q[0] * q[1];
        const xz = q[0] * q[2];
        const yz = q[1] * q[2];
        const wx = q[3] * q[0];
        const wy = q[3] * q[1];
        const wz = q[3] * q[2];
        return .{ .cols = .{
            .{ (1 - 2 * (yy + zz)) * t.scale[0], (2 * (xy + wz)) * t.scale[0], (2 * (xz - wy)) * t.scale[0], 0 },
            .{ (2 * (xy - wz)) * t.scale[1], (1 - 2 * (xx + zz)) * t.scale[1], (2 * (yz + wx)) * t.scale[1], 0 },
            .{ (2 * (xz + wy)) * t.scale[2], (2 * (yz - wx)) * t.scale[2], (1 - 2 * (xx + yy)) * t.scale[2], 0 },
            .{ t.translation[0], t.translation[1], t.translation[2], 1 },
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

    pub fn transformPoint(m: Float4x4, p: Vec3f32) Vec3f32 {
        return .{
            m.cols[0][0] * p[0] + m.cols[1][0] * p[1] + m.cols[2][0] * p[2] + m.cols[3][0],
            m.cols[0][1] * p[0] + m.cols[1][1] * p[1] + m.cols[2][1] * p[2] + m.cols[3][1],
            m.cols[0][2] * p[0] + m.cols[1][2] * p[1] + m.cols[2][2] * p[2] + m.cols[3][2],
        };
    }

    pub fn transformVector(m: Float4x4, p: Vec3f32) Vec3f32 {
        return .{
            m.cols[0][0] * p[0] + m.cols[1][0] * p[1] + m.cols[2][0] * p[2],
            m.cols[0][1] * p[0] + m.cols[1][1] * p[1] + m.cols[2][1] * p[2],
            m.cols[0][2] * p[0] + m.cols[1][2] * p[1] + m.cols[2][2] * p[2],
        };
    }

    pub fn translation(m: Float4x4) Vec3f32 {
        return .{ m.cols[3][0], m.cols[3][1], m.cols[3][2] };
    }
};

pub const Box = struct {
    min: Vec3f32,
    max: Vec3f32,

    pub fn empty() Box {
        return .{
            .min = @splat(std.math.inf(f32)),
            .max = @splat(-std.math.inf(f32)),
        };
    }
    pub fn expand(self: *Box, p: Vec3f32) void {
        self.min = @min(self.min, p);
        self.max = @max(self.max, p);
    }

    pub fn isValid(self: Box) bool {
        return @reduce(.And, self.min <= self.max);
    }

    pub fn contains(self: Box, point: Vec3f32) bool {
        return self.isValid() and
            @reduce(.And, point >= self.min) and
            @reduce(.And, point <= self.max);
    }

    pub fn merge(a: Box, b: Box) Box {
        if (!a.isValid()) return b;
        if (!b.isValid()) return a;
        return .{
            .min = @min(a.min, b.min),
            .max = @max(a.max, b.max),
        };
    }

    pub fn transformed(self: Box, matrix: Float4x4) Box {
        if (!self.isValid()) return Box.empty();
        var result = Box.empty();
        for (0..8) |corner| {
            result.expand(Float4x4.transformPoint(matrix, .{
                if (corner & 1 != 0) self.max[0] else self.min[0],
                if (corner & 2 != 0) self.max[1] else self.min[1],
                if (corner & 4 != 0) self.max[2] else self.min[2],
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
        .translation = .{ 1, 2, 3 },
        .rotation = quat.fromAxisAngle(.{ 0, 0, 1 }, @as(f32, std.math.pi / 2.0)),
    };
    const child: Transform = .{ .translation = .{ 1, 0, 0 } };
    const combined = Transform.combine(parent, child);
    try std.testing.expectApproxEqAbs(@as(f32, 1), combined.translation[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3), combined.translation[1], 1e-5);

    var soa: [1]SoaTransform = undefined;
    aosToSoa(&.{ parent, child }, &soa);
    try std.testing.expectEqual(parent.translation[0], lane(soa[0].translation.x, 0));
    try std.testing.expectEqual(child.scale[2], lane(soa[0].scale.z, 1));
    try std.testing.expectEqual(@as(f32, 1), lane(soa[0].scale.z, 3));
}
