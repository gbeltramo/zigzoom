const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Ray = math.Ray;

pub const Sphere = struct {
    center: Vec3,
    radius: f32,

    /// Nearest positive hit distance along the ray, or null if it misses.
    /// Solves |origin + t*dir - center|^2 = r^2 using the book's half-b form:
    ///   a*t^2 - 2*h*t + c = 0, with h = dir . (center - origin)
    pub fn hit(self: Sphere, ray: Ray) ?f32 {
        const oc = self.center.sub(ray.origin);
        const a = ray.direction.dot(ray.direction);
        const h = ray.direction.dot(oc);
        const c = oc.dot(oc) - self.radius * self.radius;
        const discriminant = h * h - a * c;
        if (discriminant < 0) return null;
        const t = (h - @sqrt(discriminant)) / a;
        if (t < 0) return null;
        return t;
    }
};

test "ray hits sphere in front" {
    const s: Sphere = .{ .center = Vec3.init(0, 0, -1), .radius = 0.5 };
    const r: Ray = .{ .origin = Vec3.init(0, 0, 0), .direction = Vec3.init(0, 0, -1) };
    try std.testing.expectApproxEqAbs(0.5, s.hit(r).?, 1e-6);
}

test "ray misses sphere" {
    const s: Sphere = .{ .center = Vec3.init(0, 0, -1), .radius = 0.5 };
    const r: Ray = .{ .origin = Vec3.init(0, 0, 0), .direction = Vec3.init(0, 1, 0) };
    try std.testing.expect(s.hit(r) == null);
}

test "sphere behind the ray is not hit" {
    const s: Sphere = .{ .center = Vec3.init(0, 0, 1), .radius = 0.5 };
    const r: Ray = .{ .origin = Vec3.init(0, 0, 0), .direction = Vec3.init(0, 0, -1) };
    try std.testing.expect(s.hit(r) == null);
}
