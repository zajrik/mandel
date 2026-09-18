const std = @import("std");
const Allocator = std.mem.Allocator;
const Complex = std.math.complex.Complex;
const Group = std.Io.Group;
const Io = std.Io;
const WindowIterator = std.mem.WindowIterator;

const assert = std.debug.assert;
const window = std.mem.window;

const img = @import("zigimg");
const Image = img.Image;

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const io: Io = init.io;

    // The view-plane of the mandelbrot subset we're rendering.
    const view: Plane = .{
        .dim = .init(4000, 3000),
        .ul = .init(-1.20, 0.35),
        .lr = .init(-1, 0.20),
    };

    // Allocate buffer on the heap in case the dimensions make it too large for the stack
    const render_buffer: []u8 = try gpa.alloc(u8, view.size());
    defer gpa.free(render_buffer);

    // Split buffer into chunks for concurrent rendering
    const count: u8 = 8;
    const lines: usize = view.dim.y / count + 1;
    const size: usize = view.dim.x * lines;
    var chunks: WindowIterator(u8) = window(u8, render_buffer, size, size);

    var tasks: Group = .init;
    defer tasks.cancel(io);

    // Spawn tasks to render each chunk of the image
    var i: usize = 0;
    while (chunks.next()) |chunk| : (i += 1) {
        const top: usize = lines * i;
        const height: usize = chunk.len / view.dim.x;

        const chunk_plane: Plane = .{
            .dim = .init(view.dim.x, height),
            .ul = view.plot(.init(0, top)),
            .lr = view.plot(.init(view.dim.x, top + height)),
        };

        // Notes:
        // - Group.concurrent guarantees concurrency but errors on single-threaded targets
        // - Group.async can fall back to synchronous-execution if concurrency is unavailable

        // try tasks.concurrent(io, Plane.render, .{ chunk_plane, @constCast(it) });
        tasks.async(io, Plane.render, .{ chunk_plane, @constCast(chunk) });
    }

    // Wait for tasks to finish
    try tasks.await(io);

    // Allocate image on the heap from the rendered buffer
    var image: Image = try .fromRawPixels(gpa, view.dim.x, view.dim.y, render_buffer, .grayscale8);
    defer image.deinit(gpa);

    // Write image to file
    var write_buffer: [4096]u8 = undefined;
    try image.writeToFilePath(gpa, io, "mandel.png", &write_buffer, .{ .png = .{} });
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

/// A subset of the cartesian plane of complex numbers, mapped to specific pixel
/// dimensions.
const Plane = struct {
    /// The dimensions of this plane in pixels.
    dim: Vector(usize),

    /// The complex number defining the upper-left corner of the plane.
    ul: Complex(f64),

    /// The complex number defining the lower-right corner of the plane.
    lr: Complex(f64),

    /// Returns the buffer size needed for rendering this plane.
    fn size(self: *const Plane) usize {
        return self.dim.x * self.dim.y;
    }

    /// Plot the given `pixel` on the plane, translating its position from pixel
    /// coordinates to a complex point.
    ///
    /// Returns the position of the given pixel on the complex plane.
    fn plot(self: *const Plane, pixel: Vector(usize)) Complex(f64) {
        const width, const height = .{
            self.lr.re - self.ul.re,
            self.ul.im - self.lr.im,
        };

        const bx, const by = self.dim.float();
        const px, const py = pixel.float();

        return .init(
            self.ul.re + px * width / bx,
            self.ul.im - py * height / by,
        );
    }

    /// Write grayscale mandelbrot set data for this plane subset to the given `pixel_buffer`.
    ///
    /// Each pixel within the bounds of the dimensions of this `Plane` represents
    /// a point on the cartesian plane of complex numbers and will be shaded according
    /// to its presence in the mandelbrot set.
    fn render(self: Plane, pixel_buffer: []u8) void {
        assert(pixel_buffer.len == self.dim.x * self.dim.y);

        for (0..self.dim.y) |row| {
            for (0..self.dim.x) |col| {
                const point: Complex(f64) = self.plot(.init(col, row));
                const shade: u8 = if (mandel(point)) |t| 255 - t else 0;
                pixel_buffer[row * self.dim.x + col] = shade;
            }
        }
    }
};

/// Determine whether the given complex number `c` is in the mandelbrot set.
///
/// Returns the number of iterations it took to determine `c` is not in the set,
/// or `null` if `c` is assumed to be in the set.
fn mandel(c: Complex(f64)) ?u8 {
    var z: Complex(f64) = .init(0, 0);

    return for (0..255) |i| {
        z = z.mul(z).add(c);
        if (z.squaredMagnitude() > 4) break @intCast(i);
    } else null;
}
