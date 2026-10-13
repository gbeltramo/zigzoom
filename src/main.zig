const std = @import("std");
const zz = @import("zigzoom");

const Vec3 = zz.math.Vec3;
const Ray = zz.math.Ray;

const image_width = 800;
const image_height = 450; // 16:9

fn rayColor(ray: Ray, s: zz.sphere.Sphere) Vec3 {
    if (s.hit(ray)) |t| {
        // Normal at the hit point, mapped from [-1,1] to [0,1] as a color.
        const n = ray.at(t).sub(s.center).unit();
        return Vec3.init(n.x + 1, n.y + 1, n.z + 1).scale(0.5);
    }
    // Sky: white at the horizon blending to blue at the top.
    const unit_dir = ray.direction.unit();
    const a = 0.5 * (unit_dir.y + 1.0);
    return Vec3.init(1, 1, 1).scale(1.0 - a).add(Vec3.init(0.5, 0.7, 1.0).scale(a));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const sphere: zz.sphere.Sphere = .{ .center = Vec3.init(0, 0, -1), .radius = 0.5 };

    // Camera at the origin looking down -z, viewport 2 units tall, focal length 1.
    const aspect: f32 = @as(f32, image_width) / @as(f32, image_height);
    const viewport_height: f32 = 2.0;
    const viewport_width: f32 = viewport_height * aspect;
    const focal_length: f32 = 1.0;
    const origin = Vec3.init(0, 0, 0);

    var img = try zz.image.Image.init(gpa, image_width, image_height);
    defer img.deinit(gpa);

    for (0..image_height) |j| {
        for (0..image_width) |i| {
            const u = @as(f32, @floatFromInt(i)) / (image_width - 1);
            const v = @as(f32, @floatFromInt(j)) / (image_height - 1);
            // j = 0 is the top row, so y runs from +half height down to -half.
            const dir = Vec3.init(
                (2 * u - 1) * viewport_width / 2,
                (1 - 2 * v) * viewport_height / 2,
                -focal_length,
            );
            img.set(i, j, rayColor(.{ .origin = origin, .direction = dir }, sphere));
        }
    }

    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try img.writePng(gpa, &png_bytes);

    // Write the PNG to stdout; redirect it to a file when you run.
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try stdout.interface.writeAll(png_bytes.items);
    try stdout.interface.flush();
}
