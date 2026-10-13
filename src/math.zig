const std = @import("std");

pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return init(a.x + b.x, a.y + b.y, a.z + b.z);
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return init(a.x - b.x, a.y - b.y, a.z - b.z);
    }

    pub fn scale(a: Vec3, s: f32) Vec3 {
        return init(a.x * s, a.y * s, a.z * s);
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn length(a: Vec3) f32 {
        return @sqrt(a.dot(a));
    }

    pub fn unit(a: Vec3) Vec3 {
        return a.scale(1.0 / a.length());
    }
};

pub const Ray = struct {
    origin: Vec3,
    direction: Vec3,

    pub fn at(self: Ray, t: f32) Vec3 {
        return self.origin.add(self.direction.scale(t));
    }
};

test "unit vector has length 1" {
    const v = Vec3.init(3, 4, 12).unit();
    try std.testing.expectApproxEqAbs(1.0, v.length(), 1e-6);
}

test "ray at t" {
    const r: Ray = .{ .origin = Vec3.init(1, 0, 0), .direction = Vec3.init(0, 2, 0) };
    const p = r.at(3);
    try std.testing.expectEqual(@as(f32, 6), p.y);
    try std.testing.expectEqual(@as(f32, 1), p.x);
}
