const std = @import("std");
const Vec3 = @import("math.zig").Vec3;

/// Linear RGB, one Vec3 per pixel (x=r, y=g, z=b), row-major, top row first.
pub const Image = struct {
    width: usize,
    height: usize,
    pixels: []Vec3,

    pub fn init(gpa: std.mem.Allocator, width: usize, height: usize) !Image {
        const pixels = try gpa.alloc(Vec3, width * height);
        @memset(pixels, Vec3.init(0, 0, 0));
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }

    pub fn set(self: *Image, x: usize, y: usize, color: Vec3) void {
        self.pixels[y * self.width + x] = color;
    }

    /// Appends the image as ASCII PPM (P3) to `out`. No file I/O here,
    /// so this stays pure and testable.
    pub fn writePpm(self: Image, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.print(gpa, "P3\n{d} {d}\n255\n", .{ self.width, self.height });
        for (self.pixels) |p| {
            try out.print(gpa, "{d} {d} {d}\n", .{ toByte(p.x), toByte(p.y), toByte(p.z) });
        }
    }
};

fn toByte(v: f32) u8 {
    const clamped = std.math.clamp(v, 0.0, 1.0);
    return @intFromFloat(255.999 * clamped);
}

test "ppm header and one pixel" {
    const gpa = std.testing.allocator;
    var img = try Image.init(gpa, 1, 1);
    defer img.deinit(gpa);
    img.set(0, 0, Vec3.init(1, 0, 0.5));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try img.writePpm(gpa, &out);

    try std.testing.expectEqualStrings("P3\n1 1\n255\n255 0 127\n", out.items);
}
