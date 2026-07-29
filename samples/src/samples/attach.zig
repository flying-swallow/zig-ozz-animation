// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Port of `ozz-animation/samples/attach/sample_attach.cc`.
//!
//! Samples an animation, converts it to model-space matrices and attaches an
//! object to one of the skeleton's joints. The attachment transform is the
//! joint's model-space matrix concatenated with an offset translation, which is
//! exactly what a game would do to put a sword in a character's hand.
//!
//! Upstream draws the attached object with `DrawBoxIm`; this port uses the
//! shaded box instead so the object reads as a solid volume.

const std = @import("std");
const ozz = @import("zig_ozz_animation");
const fw = @import("framework");

const Float4x4 = ozz.math.Float4x4;

pub const name = "attach";
pub const description = "Joint attachments";

/// Joint the object is attached to when the rig exposes it, in upstream's order
/// of preference. `LeftHandMiddle1` is the joint upstream hard-codes.
const preferred_joints = [_][]const u8{ "LeftHandMiddle1", "LeftHand", "Hand" };

/// Half-thickness of the attached object, upstream's `thickness`.
const box_thickness: f32 = 0.01;
/// Length of the attached object along -Z, upstream's `length`.
const box_length: f32 = 0.5;

pub const Sample = struct {
    allocator: std.mem.Allocator,
    /// Runtime skeleton.
    skeleton: ozz.animation.Skeleton,
    /// Runtime animation plus its sampling context and local-space output.
    clip: fw.utils.Clip,
    /// Model-space matrices, one per joint.
    models: []Float4x4,
    /// Animation playback time / speed / loop control.
    controller: fw.PlaybackController = .{},
    /// Joint the object is attached to.
    attachment: i32 = 0,
    /// Translation of the attached object relative to the joint.
    offset: ozz.math.Vec3f32 = .{ -0.02, 0.03, 0.05 },

    pub fn init(allocator: std.mem.Allocator, assets: fw.Assets) !Sample {
        var skeleton = try fw.utils.decodeSkeleton(
            allocator,
            assets.skeletonOr(@embedFile("pab_skeleton")),
        );
        errdefer skeleton.deinit();

        var clip = try fw.utils.Clip.decode(
            allocator,
            assets.animationOr(@embedFile("pab_walk")),
        );
        errdefer clip.deinit();

        if (skeleton.numJoints() != clip.animation.numTracks()) {
            return error.SkeletonAnimationMismatch;
        }

        const models = try allocator.alloc(Float4x4, skeleton.numJoints());
        errdefer allocator.free(models);

        var self: Sample = .{
            .allocator = allocator,
            .skeleton = skeleton,
            .clip = clip,
            .models = models,
        };
        // Picks the attachment joint by name, exactly like upstream's
        // `FindJoint(skeleton_, "LeftHandMiddle1")`.
        _ = self.attachToJointNamed(&preferred_joints);

        // Fills `models` with the rest pose so the very first `sceneBounds` and
        // `onDisplay` see something sane even before an update ran.
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.skeleton.rest_poses,
        }, self.models);
        return self;
    }

    pub fn deinit(self: *Sample) void {
        self.allocator.free(self.models);
        self.clip.deinit();
        self.skeleton.deinit();
        self.* = undefined;
    }

    pub fn onUpdate(self: *Sample, dt: f32, time: f32) !bool {
        _ = time;
        _ = self.controller.update(self.clip.duration(), dt);
        try self.clip.sample(self.controller.time_ratio);
        try ozz.animation.localToModel(.{
            .skeleton = &self.skeleton,
            .input = self.clip.pose,
        }, self.models);
        return true;
    }

    pub fn onDisplay(self: *Sample, renderer: *fw.Renderer) !void {
        try renderer.drawPosture(self.skeleton, self.models, .identity, true);

        // A thin box pointing along -Z, so it reads like a stick held by the
        // joint it is attached to.
        const box: ozz.math.Box = .{
            .min = .{ -box_thickness, -box_thickness, -box_length },
            .max = .{ box_thickness, box_thickness, 0 },
        };
        const transform = self.attachmentTransform();
        try renderer.drawBoxShaded(box, &.{transform}, fw.color.red);
    }

    pub fn onGui(self: *Sample, gui: *fw.Im) void {
        var buffer: [128]u8 = undefined;

        if (gui.openClose("Animation control", true)) {
            self.controller.onGui(gui, self.clip.duration(), true, true);
        }

        if (gui.openClose("Attachment joint", true)) {
            const joint_count = self.skeleton.numJoints();
            if (joint_count == 0) return;

            gui.doLabel("Select joint:", .{});
            _ = gui.doSliderInt(
                fw.im.formatZ(&buffer, "{s} ({d})###attachment", .{
                    self.jointName(self.attachment),
                    self.attachment,
                }),
                0,
                @intCast(joint_count - 1),
                &self.attachment,
                1,
                true,
            );
            // The by-name path, so the hard-coded joint can be recovered after
            // the slider was dragged around.
            if (gui.doButton("Attach to hand", true)) {
                _ = self.attachToJointNamed(&preferred_joints);
            }

            gui.doLabel("Attachment offset:", .{});
            // `Vec3f32` is a `@Vector`, whose elements have no addressable
            // pointer, so the sliders drive a plain array copy.
            var offset: [3]f32 = self.offset;
            inline for (.{ "x", "y", "z" }, 0..) |axis, index| {
                _ = gui.doSlider(
                    fw.im.formatZ(&buffer, axis ++ ": {d:.2}###offset_" ++ axis, .{offset[index]}),
                    -1,
                    1,
                    &offset[index],
                    1,
                    true,
                );
            }
            self.offset = offset;
            if (gui.doButton("Reset offset", true)) {
                self.offset = .{ -0.02, 0.03, 0.05 };
            }
        }
    }

    pub fn sceneBounds(self: *Sample) ?ozz.math.Box {
        return fw.utils.computePostureBounds(self.models, null);
    }

    // -- feature path -------------------------------------------------------

    /// World transform of the attached object: the joint's model-space matrix
    /// concatenated with the offset translation (`sample_attach.cc:96`).
    pub fn attachmentTransform(self: Sample) Float4x4 {
        const joint = self.models[self.jointIndex()];
        return Float4x4.mul(joint, Float4x4.fromTransform(.{ .translation = self.offset }));
    }

    /// Attachment joint, clamped into the skeleton so a stale index from the
    /// gui can never index out of bounds.
    pub fn jointIndex(self: Sample) usize {
        const clamped = std.math.clamp(self.attachment, 0, @as(i32, @intCast(self.models.len)) - 1);
        return @intCast(@max(clamped, 0));
    }

    /// Attaches the object to the first joint matching one of `names`; returns
    /// false and leaves the attachment untouched when none matches.
    pub fn attachToJointNamed(self: *Sample, names: []const []const u8) bool {
        const joint = fw.utils.findNamedJoint(self.skeleton, names) orelse return false;
        self.attachment = @intCast(joint);
        return true;
    }

    /// Name of a joint, or `"<invalid>"` when the index is out of range.
    fn jointName(self: Sample, joint: i32) []const u8 {
        if (joint < 0 or joint >= self.skeleton.names.len) return "<invalid>";
        return self.skeleton.names[@intCast(joint)];
    }
};

/// Component-wise approximate comparison, so a matrix concatenation can be
/// checked against the equivalent point transform.
fn expectClose(expected: ozz.math.Vec3f32, found: ozz.math.Vec3f32) !void {
    inline for (0..3) |axis| {
        try std.testing.expectApproxEqAbs(expected[axis], found[axis], 1e-5);
    }
}

test "attaches to the named joint and follows it" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    // Upstream hard-codes this joint; the rig has it, so the name lookup must
    // resolve rather than fall back to joint 0.
    try std.testing.expect(sample.attachment > 0);
    try std.testing.expectEqualStrings(
        "LeftHandMiddle1",
        sample.skeleton.names[sample.jointIndex()],
    );

    // Attachment sits at the joint plus the offset, expressed in joint space.
    const joint = sample.models[sample.jointIndex()];
    const attached = sample.attachmentTransform();
    try expectClose(joint.transformPoint(sample.offset), attached.translation());

    // Sampling has to move the joint, and the attachment with it.
    const before = attached.translation();
    try std.testing.expect(try sample.onUpdate(0.3, 0.3));
    const after = sample.attachmentTransform().translation();
    try std.testing.expect(@reduce(.Or, before != after));
    try expectClose(
        sample.models[sample.jointIndex()].transformPoint(sample.offset),
        after,
    );
}

test "joint selection is clamped and by-name lookup can fail" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    sample.attachment = -5;
    try std.testing.expectEqual(@as(usize, 0), sample.jointIndex());
    sample.attachment = 100000;
    try std.testing.expectEqual(sample.models.len - 1, sample.jointIndex());

    const before = sample.attachment;
    try std.testing.expect(!sample.attachToJointNamed(&.{"no_such_joint"}));
    try std.testing.expectEqual(before, sample.attachment);
    try std.testing.expect(sample.attachToJointNamed(&preferred_joints));
}

test "posture bounds cover every joint" {
    const allocator = std.testing.allocator;
    var sample = try Sample.init(allocator, .{});
    defer sample.deinit();

    try std.testing.expect(try sample.onUpdate(1.0 / 60.0, 0));
    const bounds = sample.sceneBounds().?;
    try std.testing.expect(bounds.isValid());
    for (sample.models) |model| {
        try std.testing.expect(bounds.contains(model.translation()));
    }
}
