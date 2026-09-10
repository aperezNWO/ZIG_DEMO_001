const std = @import("std");
const builtin = @import("builtin");
const fractal_engine = @import("fractal_engine.zig");
const algorithm_manager = @import("algorithm_manager.zig");

const RouteHandler = struct {
    path: []const u8,
    handler: *const fn (allocator: std.mem.Allocator, target: []const u8, request: *std.http.Server.Request) anyerror!void,
};

fn getQueryParam(uri: []const u8, key: []const u8) ?[]const u8 {
    const q_idx = std.mem.indexOf(u8, uri, "?") orelse return null;
    const query = uri[q_idx + 1 ..];

    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const k = kv.next() orelse continue;
        const v = kv.next() orelse continue;
        if (std.mem.eql(u8, k, key)) {
            return v;
        }
    }
    return null;
}

// Standard CORS headers configuration
const cors_headers = &[_]std.http.Header{
    .{ .name = "Access-Control-Allow-Origin", .value = "https://apereznwo.github.io" },
    .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
    .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
};

fn handleFractals(allocator: std.mem.Allocator, target: []const u8, request: *std.http.Server.Request) !void {
    const kind_str = getQueryParam(target, "kind") orelse "1";
    const kind_int = std.fmt.parseInt(i32, kind_str, 10) catch 1;
    const kind = fractal_engine.FractalKind.fromValue(kind_int) orelse .mandelbrot;

    const xMin = std.fmt.parseFloat(f64, getQueryParam(target, "xMin") orelse "-2.0") catch -2.0;
    const xMax = std.fmt.parseFloat(f64, getQueryParam(target, "xMax") orelse "1.0") catch 1.0;
    const yMin = std.fmt.parseFloat(f64, getQueryParam(target, "yMin") orelse "-1.5") catch -1.5;
    const yMax = std.fmt.parseFloat(f64, getQueryParam(target, "yMax") orelse "1.5") catch 1.5;
    const maxIter = std.fmt.parseInt(u32, getQueryParam(target, "maxIterations") orelse "500", 10) catch 500;

    const bounds = fractal_engine.Bounds{
        .xMin = xMin,
        .xMax = xMax,
        .yMin = yMin,
        .yMax = yMax,
    };
    
    const points = try fractal_engine.FractalEngine.getFractal(allocator, kind, bounds, maxIter);
    defer allocator.free(points);

    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();
    try std.json.Stringify.value(points, .{}, &allocating_writer.writer);
    const json_slice = try allocating_writer.toOwnedSlice();
    defer allocator.free(json_slice);

    try request.respond(json_slice, .{
        .status = .ok,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Access-Control-Allow-Origin", .value = "https://apereznwo.github.io" },
            .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
            .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
        },
    });
}

fn handleZigVersion(allocator: std.mem.Allocator, _: []const u8, request: *std.http.Server.Request) !void {
    const version_obj = .{ .zigVersion = builtin.zig_version_string };
    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();
    try std.json.Stringify.value(version_obj, .{}, &allocating_writer.writer);
    const json_slice = try allocating_writer.toOwnedSlice();
    defer allocator.free(json_slice);

    try request.respond(json_slice, .{
        .status = .ok,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Access-Control-Allow-Origin", .value = "https://apereznwo.github.io" },
            .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
            .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
        },
    });
}

fn handleWebServerVersion(allocator: std.mem.Allocator, _: []const u8, request: *std.http.Server.Request) !void {
    const server_obj = .{ .webServerVersion = "0.16.0-http" };
    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();
    try std.json.Stringify.value(server_obj, .{}, &allocating_writer.writer);
    const json_slice = try allocating_writer.toOwnedSlice();
    defer allocator.free(json_slice);

    try request.respond(json_slice, .{
        .status = .ok,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Access-Control-Allow-Origin", .value = "https://apereznwo.github.io" },
            .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
            .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
        },
    });
}

fn handleRandomVertex(allocator: std.mem.Allocator, _: []const u8, request: *std.http.Server.Request) !void {
    const result_str = try algorithm_manager.AlgorithmManager.runRandomDijkstra(allocator);
    defer allocator.free(result_str);

    try request.respond(result_str, .{
        .status = .ok,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
            .{ .name = "Access-Control-Allow-Origin", .value = "https://apereznwo.github.io" },
            .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
            .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
        },
    });
}

fn handlePing(_: std.mem.Allocator, _: []const u8, request: *std.http.Server.Request) !void {
    try request.respond("", .{ .status = .no_content, .extra_headers = cors_headers });
}

fn handleDefault(_: std.mem.Allocator, _: []const u8, request: *std.http.Server.Request) !void {
    try request.respond("It works!", .{
        .status = .ok,
        .extra_headers = cors_headers,
    });
}

const routes = [_]RouteHandler{
    .{ .path = "/api/fractals/generate", .handler = handleFractals },
    .{ .path = "/api/zigversion", .handler = handleZigVersion },
    .{ .path = "/api/zigVersion", .handler = handleZigVersion },
    .{ .path = "/api/getZigVersion", .handler = handleZigVersion },
    .{ .path = "/api/webserverversion", .handler = handleWebServerVersion },
    .{ .path = "/api/webServerVersion", .handler = handleWebServerVersion },
    .{ .path = "/api/getZigWebServerVersion", .handler = handleWebServerVersion },
    .{ .path = "/api/generaterandomvertex_springboot", .handler = handleRandomVertex },
    .{ .path = "/api/GenerateRandomVertex_SpringBoot", .handler = handleRandomVertex },
    .{ .path = "/ping", .handler = handlePing },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.page_allocator;

    const address = try std.Io.net.IpAddress.parse("0.0.0.0", 8080);
    var server = try address.listen(io, .{
        .reuse_address = true,
    });
    defer server.deinit(io);

    std.debug.print("Zig HTTP Server running on http://0.0.0.0:8080\n", .{});

    while (true) {
        var conn = server.accept(io) catch continue;
        defer conn.close(io);

        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var stream_reader = conn.reader(io, &read_buffer);
        var stream_writer = conn.writer(io, &write_buffer);
        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        
        var request = http_server.receiveHead() catch continue;

        // Handle preflight OPTIONS requests immediately
        if (request.head.method == .OPTIONS) {
            request.respond("", .{
                .status = .no_content,
                .extra_headers = cors_headers,
            }) catch continue;
            continue;
        }

        const target = request.head.target;
        const path = if (std.mem.indexOf(u8, target, "?")) |idx| target[0..idx] else target;

        var matched = false;
        for (routes) |route| {
            if (std.mem.eql(u8, path, route.path)) {
                route.handler(allocator, target, &request) catch {
                    request.respond("Internal Server Error", .{ 
                        .status = .internal_server_error,
                        .extra_headers = cors_headers,
                    }) catch {};
                };
                matched = true;
                break;
            }
        }

        if (!matched) {
            handleDefault(allocator, target, &request) catch continue;
        }
    }
}