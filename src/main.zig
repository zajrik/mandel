const std = @import("std");
const assert = std.debug.assert;
const window = std.mem.window;
const Allocator = std.mem.Allocator;
const Complex = std.math.complex.Complex;
const Io = std.Io;
const Thread = std.Thread;
const WindowIterator = std.mem.WindowIterator;

const img = @import("zigimg");
const Image = img.Image;

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const io: Io = init.io;

    // Dimensions of the output image in pixels
    const dim: Vector(usize) = comptime .init(4000, 3000);

    // Upper-left and lower-right corners of the complex plane viewport
    const view_ul: Complex(f64) = .init(-1.20, 0.35);
    const view_lr: Complex(f64) = .init(-1, 0.20);

    // Allocate buffer on the heap in case the dimensions make it too large for the stack
    const render_buffer: []u8 = try gpa.alloc(u8, dim.x * dim.y);
    defer gpa.free(render_buffer);

    // Split buffer into chunks for multithreaded rendering
    const thread_count: u8 = 8;
    const chunk_rows: usize = dim.y / thread_count + 1;
    const chunk_size: usize = dim.x * chunk_rows;
    var chunks: [thread_count][]u8 = undefined;
    var chunk_iter: WindowIterator(u8) = window(u8, render_buffer, chunk_size, chunk_size);
    for (&chunks) |*it| it.* = @constCast(chunk_iter.next().?);

    // Spawn threads to render each chunk of the image
    var threads: [thread_count]Thread = undefined;
    for (chunks, 0..) |chunk, i| {
        const chunk_top: usize = chunk_rows * i;
        const chunk_height: usize = chunk.len / dim.x;
        const chunk_dim: Vector(usize) = .init(dim.x, chunk_height);
        const chunk_ul: Complex(f64) = plot(.init(0, chunk_top), dim, view_ul, view_lr);
        const chunk_lr: Complex(f64) = plot(.init(dim.x, chunk_top + chunk_height), dim, view_ul, view_lr);

        threads[i] = try .spawn(.{}, render, .{ chunks[i], chunk_dim, chunk_ul, chunk_lr });
    }

    // Wait for threads to finish
    for (threads) |t| t.join();

    // Allocate image on the heap from the rendered buffer
    var image: Image = try .fromRawPixels(gpa, dim.x, dim.y, render_buffer, .grayscale8);
    defer image.deinit(gpa);

    // Write image to file
    var write_buffer: [4096]u8 = undefined;
    try image.writeToFilePath(gpa, io, "mandel.png", write_buffer[0..], .{ .png = .{} });
}

/// Represents a point in 2-dimensional space.
fn Vector(comptime T: type) type {
    comptime assert(@typeInfo(T) == .int);
    return struct {
        const Self = @This();

        x: T,
        y: T,

        fn init(x: T, y: T) Self {
            return .{ .x = x, .y = y };
        }

        fn float(self: *const Self) struct { f64, f64 } {
            return .{ @floatFromInt(self.x), @floatFromInt(self.y) };
        }
    };
}

/// Determine whether the given complex number `c` is in the mandelbrot set.
///
/// Returns the number of iterations it took to determine `c` is not in the set,
/// or `null` if `c` is assumed to be in the set.
fn escapeTime(c: Complex(f64), limit: u8) ?u8 {
    var z: Complex(f64) = .init(0, 0);

    return for (0..limit) |i| {
        z = z.mul(z).add(c);
        if (z.squaredMagnitude() > 4) break @intCast(i);
    } else null;
}

/// Map a given pixel to a point on the cartesian plane of complex numbers defined
/// by the given `upper_left` and `lower_right` points of the plane.
///
/// The complex plane itself is bound to pixel dimensions specified by `bounds`.
fn plot(
    pixel: Vector(usize),
    bounds: Vector(usize),
    upper_left: Complex(f64),
    lower_right: Complex(f64),
) Complex(f64) {
    const width, const height = .{
        lower_right.re - upper_left.re,
        upper_left.im - lower_right.im,
    };

    const bx, const by = bounds.float();
    const px, const py = pixel.float();

    return .init(
        upper_left.re + px * width / bx,
        upper_left.im - py * height / by,
    );
}

test "plot" {
    try std.testing.expectEqual(
        plot(.init(25, 75), .init(100, 100), .init(-1, 1), .init(1, -1)),
        Complex(f64).init(-0.5, -0.5),
    );
}

/// Write grayscale mandelbrot set pixel data to the given `pixel_buffer`.
///
/// Each pixel represents a point on the cartesian plane of complex numbers and
/// will be shaded according to its presence in the mandelbrot set.
fn render(
    pixel_buffer: []u8,
    bounds: Vector(usize),
    upper_left: Complex(f64),
    lower_right: Complex(f64),
) void {
    assert(pixel_buffer.len == bounds.x * bounds.y);

    for (0..bounds.y) |row| {
        for (0..bounds.x) |col| {
            const point: Complex(f64) = plot(.init(col, row), bounds, upper_left, lower_right);
            const shade: u8 = if (escapeTime(point, 255)) |t| 255 - t else 0;
            pixel_buffer[row * bounds.x + col] = shade;
        }
    }
}
