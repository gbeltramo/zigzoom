//! Minimal PNG encoder/decoder. No dependencies, no I/O: bytes in, bytes out.
//!
//! Encode: 8-bit RGB, filter 0, uncompressed (stored) deflate blocks.
//! Decode: non-interlaced 8-bit gray / gray+alpha / RGB / RGBA, converted to RGB8.

const std = @import("std");

pub const Error = error{
    BadSignature,
    BadCrc,
    BadChecksum,
    BadHeader,
    BadData,
    BadCode,
    BadFilter,
    Truncated,
    UnexpectedEof,
    MissingChunk,
    UnsupportedFormat,
};

const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };


const crc_table = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*entry, n| {
        var c: u32 = @intCast(n);
        for (0..8) |_| c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        entry.* = c;
    }
    break :blk t;
};

fn crc32Update(crc: u32, data: []const u8) u32 {
    var c = crc;
    for (data) |b| c = crc_table[(c ^ b) & 0xFF] ^ (c >> 8);
    return c;
}

fn crc32(data: []const u8) u32 {
    return crc32Update(0xFFFFFFFF, data) ^ 0xFFFFFFFF;
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |x| {
        a = (a + x) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}


fn writeChunk(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    kind: *const [4]u8,
    data: []const u8,
) !void {
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, @intCast(data.len), .big);
    try out.appendSlice(gpa, &word);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);

    var crc: u32 = 0xFFFFFFFF;
    crc = crc32Update(crc, kind);
    crc = crc32Update(crc, data);
    std.mem.writeInt(u32, &word, crc ^ 0xFFFFFFFF, .big);
    try out.appendSlice(gpa, &word);
}

/// Appends a complete PNG file to `out`. `rgb` is width*height*3 bytes, row-major, top row first.
pub fn encodeRgb8(
    gpa: std.mem.Allocator,
    width: usize,
    height: usize,
    rgb: []const u8,
    out: *std.ArrayList(u8),
) !void {
    std.debug.assert(width > 0 and height > 0);
    std.debug.assert(rgb.len == width * height * 3);

    // Raw scanlines: one filter byte (0 = none) before each row.
    const stride = width * 3;
    const raw = try gpa.alloc(u8, height * (stride + 1));
    defer gpa.free(raw);
    for (0..height) |y| {
        raw[y * (stride + 1)] = 0;
        @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], rgb[y * stride ..][0..stride]);
    }

    // zlib stream made of stored (uncompressed) deflate blocks, max 65535 bytes each.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var pos: usize = 0;
    while (true) {
        const n = @min(raw.len - pos, 65535);
        const n16: u16 = @intCast(n);
        const is_final = pos + n == raw.len;
        try z.append(gpa, if (is_final) 1 else 0);
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u16, hdr[0..2], n16, .little);
        std.mem.writeInt(u16, hdr[2..4], ~n16, .little);
        try z.appendSlice(gpa, &hdr);
        try z.appendSlice(gpa, raw[pos..][0..n]);
        pos += n;
        if (is_final) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, adler32(raw), .big);
    try z.appendSlice(gpa, &adler);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // color type: RGB
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // no interlace

    try out.appendSlice(gpa, &signature);
    try writeChunk(gpa, out, "IHDR", &ihdr);
    try writeChunk(gpa, out, "IDAT", z.items);
    try writeChunk(gpa, out, "IEND", &.{});
}


const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    buf: u32 = 0,
    cnt: u32 = 0, // always <= 7 between calls

    fn bits(self: *BitReader, n: u5) !u32 {
        while (self.cnt < n) {
            if (self.pos >= self.data.len) return error.UnexpectedEof;
            self.buf |= @as(u32, self.data[self.pos]) << @intCast(self.cnt);
            self.pos += 1;
            self.cnt += 8;
        }
        const v = self.buf & ((@as(u32, 1) << n) - 1);
        self.buf >>= n;
        self.cnt -= n;
        return v;
    }
};

/// Canonical Huffman table, decoded bit by bit (same scheme as zlib's "puff").
const Huffman = struct {
    count: [16]u16 = @splat(0),
        symbol: [288]u16 = @splat(0),

        fn build(h: *Huffman, lengths: []const u8) void {
            h.count = @splat(0);
        for (lengths) |l| h.count[l] += 1;
        var offs: [16]u16 = undefined;
        offs[1] = 0;
        for (1..15) |i| offs[i + 1] = offs[i] + h.count[i];
        for (lengths, 0..) |l, sym| {
            if (l != 0) {
                h.symbol[offs[l]] = @intCast(sym);
                offs[l] += 1;
            }
        }
    }

    fn decode(h: *const Huffman, br: *BitReader) !u16 {
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        for (1..16) |len| {
            const bit = try br.bits(1);
            code |= @as(i32, @intCast(bit));
            const count: i32 = h.count[len];
            if (code - count < first) return h.symbol[@intCast(index + (code - first))];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.BadCode;
    }
};

const len_base = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [_]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [_]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const clen_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

fn inflateCodes(
    gpa: std.mem.Allocator,
    br: *BitReader,
    out: *std.ArrayList(u8),
    lit: *const Huffman,
    dist: *const Huffman,
) !void {
    while (true) {
        const sym = try lit.decode(br);
        if (sym < 256) {
            try out.append(gpa, @intCast(sym));
        } else if (sym == 256) {
            return;
        } else {
            const li = sym - 257;
            if (li >= len_base.len) return error.BadCode;
            const length: usize = len_base[li] + try br.bits(len_extra[li]);

            const ds = try dist.decode(br);
            if (ds >= dist_base.len) return error.BadCode;
            const distance: usize = dist_base[ds] + try br.bits(dist_extra[ds]);
            if (distance > out.items.len) return error.BadData;

            for (0..length) |_| {
                try out.append(gpa, out.items[out.items.len - distance]);
            }
        }
    }
}

/// Decompresses a raw deflate stream (no zlib wrapper) and appends to `out`.
fn inflate(gpa: std.mem.Allocator, data: []const u8, out: *std.ArrayList(u8)) !void {
    var br: BitReader = .{ .data = data };
    while (true) {
        const is_final = try br.bits(1);
        const kind = try br.bits(2);
        switch (kind) {
            0 => { // stored
                br.buf = 0;
                br.cnt = 0;
                if (br.pos + 4 > data.len) return error.UnexpectedEof;
                const len = std.mem.readInt(u16, data[br.pos..][0..2], .little);
                const nlen = std.mem.readInt(u16, data[br.pos + 2 ..][0..2], .little);
                if (len != ~nlen) return error.BadData;
                br.pos += 4;
                if (br.pos + len > data.len) return error.UnexpectedEof;
                try out.appendSlice(gpa, data[br.pos..][0..len]);
                br.pos += len;
            },
            1 => { // fixed Huffman
                var lengths: [288]u8 = undefined;
                for (0..144) |i| lengths[i] = 8;
                for (144..256) |i| lengths[i] = 9;
                for (256..280) |i| lengths[i] = 7;
                for (280..288) |i| lengths[i] = 8;
                var lit: Huffman = .{};
                lit.build(&lengths);
                const dist_lengths: [30]u8 = @splat(5);
                var dist: Huffman = .{};
                dist.build(&dist_lengths);
                try inflateCodes(gpa, &br, out, &lit, &dist);
            },
            2 => { // dynamic Huffman
                const hlit: usize = 257 + @as(usize, try br.bits(5));
                const hdist: usize = 1 + @as(usize, try br.bits(5));
                const hclen: usize = 4 + @as(usize, try br.bits(4));
                if (hlit > 286 or hdist > 30) return error.BadCode;

                var clens: [19]u8 = @splat(0);
                for (0..hclen) |i| clens[clen_order[i]] = @intCast(try br.bits(3));
                var clen_code: Huffman = .{};
                clen_code.build(&clens);

                var lengths: [320]u8 = @splat(0);
                var idx: usize = 0;
                while (idx < hlit + hdist) {
                    const sym = try clen_code.decode(&br);
                    if (sym < 16) {
                        lengths[idx] = @intCast(sym);
                        idx += 1;
                    } else {
                        var prev: u8 = 0;
                        var rep: usize = 0;
                        if (sym == 16) {
                            if (idx == 0) return error.BadCode;
                            prev = lengths[idx - 1];
                            rep = 3 + @as(usize, try br.bits(2));
                        } else if (sym == 17) {
                            rep = 3 + @as(usize, try br.bits(3));
                        } else {
                            rep = 11 + @as(usize, try br.bits(7));
                        }
                        if (idx + rep > hlit + hdist) return error.BadCode;
                        @memset(lengths[idx..][0..rep], prev);
                        idx += rep;
                    }
                }

                var lit: Huffman = .{};
                lit.build(lengths[0..hlit]);
                var dist: Huffman = .{};
                dist.build(lengths[hlit..][0..hdist]);
                try inflateCodes(gpa, &br, out, &lit, &dist);
            },
            else => return error.BadData,
        }
        if (is_final == 1) break;
    }
}


pub const Decoded = struct {
    width: usize,
    height: usize,
    /// width*height*3 bytes, row-major, top row first.
    rgb: []u8,

    pub fn deinit(self: *Decoded, gpa: std.mem.Allocator) void {
        gpa.free(self.rgb);
    }
};

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Decoded {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return error.BadSignature;

    var width: usize = 0;
    var height: usize = 0;
    var channels: usize = 0;
    var saw_ihdr = false;
    var saw_iend = false;

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    var pos: usize = 8;
    while (pos + 12 <= bytes.len) {
        const len: usize = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        if (pos + 12 + len > bytes.len) return error.Truncated;
        const kind = bytes[pos + 4 ..][0..4];
        const data = bytes[pos + 8 ..][0..len];

        const stored_crc = std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big);
        if (crc32(bytes[pos + 4 .. pos + 8 + len]) != stored_crc) return error.BadCrc;

        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.BadHeader;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (width == 0 or height == 0) return error.BadHeader;
            if (data[8] != 8 or data[12] != 0) return error.UnsupportedFormat;
            channels = switch (data[9]) {
                0 => 1, // gray
                2 => 3, // RGB
                4 => 2, // gray + alpha
                6 => 4, // RGBA
                else => return error.UnsupportedFormat,
            };
            saw_ihdr = true;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            saw_iend = true;
            break;
        }
        pos += 12 + len;
    }
    if (!saw_ihdr or !saw_iend or idat.items.len < 6) return error.MissingChunk;

    // zlib wrapper: 2-byte header, deflate data, 4-byte Adler-32.
    const z = idat.items;
    if ((z[0] & 0x0F) != 8 or (@as(u32, z[0]) * 256 + z[1]) % 31 != 0 or (z[1] & 0x20) != 0)
        return error.BadHeader;

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    try inflate(gpa, z[2 .. z.len - 4], &raw);
    if (adler32(raw.items) != std.mem.readInt(u32, z[z.len - 4 ..][0..4], .big))
        return error.BadChecksum;

    const stride = width * channels;
    if (raw.items.len != height * (stride + 1)) return error.BadData;

    // Undo per-row filters.
    const pixels = try gpa.alloc(u8, height * stride);
    defer gpa.free(pixels);
    for (0..height) |y| {
        const filter = raw.items[y * (stride + 1)];
        const src = raw.items[y * (stride + 1) + 1 ..][0..stride];
        const dst = pixels[y * stride ..][0..stride];
        for (0..stride) |x| {
            const a: u8 = if (x >= channels) dst[x - channels] else 0;
            const b: u8 = if (y > 0) pixels[(y - 1) * stride + x] else 0;
            const c: u8 = if (x >= channels and y > 0) pixels[(y - 1) * stride + x - channels] else 0;
            dst[x] = switch (filter) {
                0 => src[x],
                1 => src[x] +% a,
                2 => src[x] +% b,
                3 => src[x] +% @as(u8, @intCast((@as(u16, a) + @as(u16, b)) / 2)),
                4 => src[x] +% paeth(a, b, c),
                else => return error.BadFilter,
            };
        }
    }

    // Convert to RGB8 (alpha is dropped).
    const rgb = try gpa.alloc(u8, width * height * 3);
    errdefer gpa.free(rgb);
    for (0..width * height) |i| {
        const px = pixels[i * channels ..][0..channels];
        switch (channels) {
            1, 2 => {
                rgb[i * 3] = px[0];
                rgb[i * 3 + 1] = px[0];
                rgb[i * 3 + 2] = px[0];
            },
            else => {
                rgb[i * 3] = px[0];
                rgb[i * 3 + 1] = px[1];
                rgb[i * 3 + 2] = px[2];
            },
        }
    }
    return .{ .width = width, .height = height, .rgb = rgb };
}


test "crc32 known value" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
}

test "adler32 known value" {
    try std.testing.expectEqual(@as(u32, 0x11E60398), adler32("Wikipedia"));
}

test "png round trip small image" {
    const gpa = std.testing.allocator;
    const rgb = [_]u8{
        255, 0,   0,   0,   255, 0,   0,   0,   255,
        10,  20,  30,  40,  50,  60,  70,  80,  90,
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try encodeRgb8(gpa, 3, 2, &rgb, &out);

    try std.testing.expectEqualSlices(u8, &signature, out.items[0..8]);

    var img = try decode(gpa, out.items);
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), img.width);
    try std.testing.expectEqual(@as(usize, 2), img.height);
    try std.testing.expectEqualSlices(u8, &rgb, img.rgb);
}

test "png round trip needs multiple stored blocks" {
    const gpa = std.testing.allocator;
    const w = 300;
    const h = 100; // 90_100 raw bytes > 65_535
    const rgb = try gpa.alloc(u8, w * h * 3);
    defer gpa.free(rgb);
    for (rgb, 0..) |*b, i| b.* = @truncate(i *% 7);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try encodeRgb8(gpa, w, h, rgb, &out);

    var img = try decode(gpa, out.items);
    defer img.deinit(gpa);
    try std.testing.expectEqualSlices(u8, rgb, img.rgb);
}

test "decode rejects corrupted data" {
    const gpa = std.testing.allocator;
    const rgb = [_]u8{ 1, 2, 3 };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try encodeRgb8(gpa, 1, 1, &rgb, &out);

    out.items[20] ^= 0xFF; // inside IHDR, breaks its CRC
    try std.testing.expectError(error.BadCrc, decode(gpa, out.items));
    try std.testing.expectError(error.BadSignature, decode(gpa, "not a png"));
}
