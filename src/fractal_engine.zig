const std = @import("std");

pub const FractalPoint = struct {
    x: f64,
    y: f64,
    intensity: u32,
};

pub const Bounds = struct {
    xMin: f64,
    xMax: f64,
    yMin: f64,
    yMax: f64,
};

pub const FractalKind = enum(i32) {
    mandelbrot = 1,
    julia = 2,
    leaf = 3,

    pub fn fromValue(val: i32) ?FractalKind {
        return switch (val) {
            1 => .mandelbrot,
            2 => .julia,
            3 => .leaf,
            else => null,
        };
    }
};

pub const FractalEngine = struct {
    pub const canvasWidth = 800;
    pub const canvasHeight = 600;

    fn encodeIntensity(iter: u32, max_iterations: u32) u32 {
        return if (iter == max_iterations) 0 else @as(u32, @intCast((iter * 255) / max_iterations));
    }

    pub fn getFractal(allocator: std.mem.Allocator, kind: FractalKind, bounds: Bounds, max_iterations: u32) ![]FractalPoint {
        return switch (kind) {
            .mandelbrot => generateMandelbrot(allocator, bounds, max_iterations),
            .julia => generateJulia(allocator, bounds, max_iterations),
            .leaf => generateLeaf(allocator),
        };
    }

    pub fn generateMandelbrot(allocator: std.mem.Allocator, bounds: Bounds, max_iterations: u32) ![]FractalPoint {
        var points: std.ArrayList(FractalPoint) = .empty;
        defer points.deinit(allocator);

        const xRange = bounds.xMax - bounds.xMin;
        const yRange = bounds.yMax - bounds.yMin;

        var screenY: usize = 0;
        while (screenY < canvasHeight) : (screenY += 1) {
            var screenX: usize = 0;
            while (screenX < canvasWidth) : (screenX += 1) {
                const cRe = bounds.xMin + (@as(f64, @floatFromInt(screenX)) * xRange / @as(f64, @floatFromInt(canvasWidth)));
                const cIm = bounds.yMin + (@as(f64, @floatFromInt(screenY)) * yRange / @as(f64, @floatFromInt(canvasHeight)));

                var zRe: f64 = 0.0;
                var zIm: f64 = 0.0;
                var iter: u32 = 0;

                while (zRe * zRe + zIm * zIm <= 4.0 and iter < max_iterations) {
                    const nextRe = zRe * zRe - zIm * zIm + cRe;
                    const nextIm = 2.0 * zRe * zIm + cIm;
                    zRe = nextRe;
                    zIm = nextIm;
                    iter += 1;
                }

                try points.append(allocator, .{
                    .x = @as(f64, @floatFromInt(screenX)),
                    .y = @as(f64, @floatFromInt(screenY)),
                    .intensity = encodeIntensity(iter, max_iterations),
                });
            }
        }
        return try points.toOwnedSlice(allocator);
    }

    pub fn generateJulia(allocator: std.mem.Allocator, bounds: Bounds, max_iterations: u32) ![]FractalPoint {
        var points: std.ArrayList(FractalPoint) = .empty;
        defer points.deinit(allocator);

        const xRange = bounds.xMax - bounds.xMin;
        const yRange = bounds.yMax - bounds.yMin;
        const cRe: f64 = -0.400;
        const cIm: f64 = 0.600;

        var screenY: usize = 0;
        while (screenY < canvasHeight) : (screenY += 1) {
            var screenX: usize = 0;
            while (screenX < canvasWidth) : (screenX += 1) {
                var zRe: f64 = bounds.xMin + (@as(f64, @floatFromInt(screenX)) * xRange / @as(f64, @floatFromInt(canvasWidth)));
                var zIm: f64 = bounds.yMin + (@as(f64, @floatFromInt(screenY)) * yRange / @as(f64, @floatFromInt(canvasHeight)));
                var iter: u32 = 0;

                while (zRe * zRe + zIm * zIm <= 4.0 and iter < max_iterations) {
                    const nextRe = zRe * zRe - zIm * zIm + cRe;
                    const nextIm = 2.0 * zRe * zIm + cIm;
                    zRe = nextRe;
                    zIm = nextIm;
                    iter += 1;
                }

                try points.append(allocator, .{
                    .x = @as(f64, @floatFromInt(screenX)),
                    .y = @as(f64, @floatFromInt(screenY)),
                    .intensity = encodeIntensity(iter, max_iterations),
                });
            }
        }
        return try points.toOwnedSlice(allocator);
    }

    pub fn generateLeaf(allocator: std.mem.Allocator) ![]FractalPoint {
        var points: std.ArrayList(FractalPoint) = .empty;
        defer points.deinit(allocator);

        var pixelGrid = try allocator.alloc([]u32, canvasWidth);
        for (pixelGrid, 0..) |_, i| {
            pixelGrid[i] = try allocator.alloc(u32, canvasHeight);
            @memset(pixelGrid[i], 0);
        }
        defer {
            for (pixelGrid, 0..) |_, i| {
                allocator.free(pixelGrid[i]);
            }
            allocator.free(pixelGrid);
        }

        var x: f64 = 0.0;
        var y: f64 = 0.0;
        const totalPoints = 150_000;
        var prng = std.Random.DefaultPrng.init(42);
        const rand = prng.random();

        var i: usize = 0;
        while (i < totalPoints) : (i += 1) {
            const r = rand.intRangeAtMost(usize, 0, 99);

            const nextX: f64, const nextY: f64 = if (r < 1)
                .{ 0.0, 0.16 * y }
            else if (r < 86)
                .{ 0.85 * x + 0.04 * y, -0.04 * x + 0.85 * y + 1.6 }
            else if (r < 93)
                .{ 0.20 * x - 0.26 * y, 0.23 * x + 0.22 * y + 1.6 }
            else
                .{ -0.15 * x + 0.28 * y, 0.26 * x + 0.24 * y + 0.44 };

            x = nextX;
            y = nextY;

            const screenX = @as(usize, @intFromFloat(@round((x + 2.182) * @as(f64, @floatFromInt(canvasWidth - 1)) / (2.655 + 2.182))));
            const screenY = @as(usize, @intFromFloat(@round((9.96 - y) * @as(f64, @floatFromInt(canvasHeight - 1)) / 9.96)));

            if (screenX < canvasWidth and screenY < canvasHeight) {
                pixelGrid[screenX][screenY] = 200;
            }
        }

        var px: usize = 0;
        while (px < canvasWidth) : (px += 1) {
            var py: usize = 0;
            while (py < canvasHeight) : (py += 1) {
                if (pixelGrid[px][py] > 0) {
                    try points.append(allocator, .{
                        .x = @as(f64, @floatFromInt(px)),
                        .y = @as(f64, @floatFromInt(py)),
                        .intensity = pixelGrid[px][py],
                    });
                }
            }
        }

        return try points.toOwnedSlice(allocator);
    }
};