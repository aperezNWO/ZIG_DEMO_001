const std = @import("std");
const builtin = @import("builtin");
const fractal_engine = @import("fractal_engine.zig");
const algorithm_manager = @import("algorithm_manager.zig");

const EndpointInfo = struct {
    path: []const u8,
    description: []const u8,
    handler: *const fn (allocator: std.mem.Allocator, target: []const u8, request: *std.http.Server.Request) anyerror!void,
};

const EndpointEntry = struct {
    key: []const u8,
    info: EndpointInfo,
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

fn handleHealth(allocator: std.mem.Allocator, _: []const u8, request: *std.http.Server.Request) !void {
    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();
    const writer = &allocating_writer.writer;

    try writer.writeAll("{\n  \"server\": \"Zig 'HTTP Server - v[0.16.0-http]' Working! \",\n  \"endpoints\": [\n");

    for (endpointDictionary, 0..) |entry, i| {
        try writer.print("    {{\n      \"key\": \"{s}\",\n      \"path\": \"{s}\",\n      \"description\": \"{s}\"\n    }}", .{ entry.key, entry.info.path, entry.info.description });
        if (i + 1 < endpointDictionary.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("  ]\n}");

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

fn handleAppVersion(_: std.mem.Allocator, _: []const u8, request: *std.http.Server.Request) !void {
    try request.respond("v[1.0.1]", .{
        .status = .ok,
        .extra_headers = cors_headers,
    });
}

const endpointDictionary = [_]EndpointEntry{
    .{ .key = "HEALTH_ENDPOINT", .info = .{ .path = "/health", .description = "Print all endpoints and server status", .handler = handleHealth } },
    .{ .key = "PING_ENDPOINT", .info = .{ .path = "/ping", .description = "Render workaround", .handler = handlePing } },
    .{ .key = "ZIG_VERSION_ENDPOINT", .info = .{ .path = "/api/server/getZigVersion", .description = "Get Zig Version", .handler = handleZigVersion } },
    .{ .key = "SERVER_VERSION_ENDPOINT", .info = .{ .path = "/api/server/getZigWebServerVersion", .description = "Get Http Server Version", .handler = handleWebServerVersion } },
    .{ .key = "APP_VERSION_ENDPOINT", .info = .{ .path = "/api/server/getZigAppVersion", .description = "Get App Version", .handler = handleAppVersion } },
    .{ .key = "FRACTAL_ENDPOINT", .info = .{ .path = "/api/fractals/generate", .description = "Fractal Generation Endpoint", .handler = handleFractals } },
    .{ .key = "DIJKSTRA_ENDPOINT", .info = .{ .path = "/api/Algorithm/GenerateRandomVertex_Zig", .description = "Generate Random Vertex via Dijkstra", .handler = handleRandomVertex } },
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
        for (endpointDictionary) |entry| {
            if (std.mem.eql(u8, path, entry.info.path)) {
                entry.info.handler(allocator, target, &request) catch {
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
