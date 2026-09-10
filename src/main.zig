const std = @import("std");
const builtin = @import("builtin");
const fractal_engine = @import("fractal_engine.zig");
const algorithm_manager = @import("algorithm_manager.zig");

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
        
        if (std.mem.startsWith(u8, request.head.target, "/api/fractals/generate")) {
            const kind_str = getQueryParam(request.head.target, "kind") orelse "1";
            const kind_int = std.fmt.parseInt(i32, kind_str, 10) catch 1;
            const kind = fractal_engine.FractalKind.fromValue(kind_int) orelse .mandelbrot;

            const xMin = std.fmt.parseFloat(f64, getQueryParam(request.head.target, "xMin") orelse "-2.0") catch -2.0;
            const xMax = std.fmt.parseFloat(f64, getQueryParam(request.head.target, "xMax") orelse "1.0") catch 1.0;
            const yMin = std.fmt.parseFloat(f64, getQueryParam(request.head.target, "yMin") orelse "-1.5") catch -1.5;
            const yMax = std.fmt.parseFloat(f64, getQueryParam(request.head.target, "yMax") orelse "1.5") catch 1.5;
            const maxIter = std.fmt.parseInt(u32, getQueryParam(request.head.target, "maxIterations") orelse "500", 10) catch 500;

            const bounds = fractal_engine.Bounds{
                .xMin = xMin,
                .xMax = xMax,
                .yMin = yMin,
                .yMax = yMax,
            };
            
            const points = fractal_engine.FractalEngine.getFractal(allocator, kind, bounds, maxIter) catch {
                try request.respond("Internal Server Error", .{ .status = .internal_server_error });
                continue;
            };
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
                },
            });
        } else if (std.mem.startsWith(u8, request.head.target, "/api/zigVersion")) {
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
                },
            });
        } else if (std.mem.startsWith(u8, request.head.target, "/api/webServerVersion")) {
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
                },
            });
        } else if (std.mem.startsWith(u8, request.head.target, "/GenerateRandomVertex_SpringBoot")) {
            const result_str = algorithm_manager.AlgorithmManager.runRandomDijkstra(allocator) catch {
                try request.respond("Internal Server Error", .{ .status = .internal_server_error });
                continue;
            };
            defer allocator.free(result_str);

            try request.respond(result_str, .{
                .status = .ok,
                .extra_headers = &[_]std.http.Header{
                    .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                    .{ .name = "Access-Control-Allow-Origin", .value = "https://apereznwo.github.io" },
                },
            });
        } else if (std.mem.eql(u8, request.head.target, "/ping")) {
            try request.respond("", .{ .status = .no_content });
        } else {
            try request.respond("It works!", .{
                .status = .ok,
                .extra_headers = &[_]std.http.Header{
                    .{ .name = "Access-Control-Allow-Origin", .value = "https://apereznwo.github.io" },
                },
            });
        }
    }
}