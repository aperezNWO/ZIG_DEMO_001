const std = @import("std");
const builtin = @import("builtin");
const fractal_engine = @import("fractal_engine.zig");
const algorithm_manager = @import("algorithm_manager.zig");
const math_engine = @import("math_engine.zig");
const wasm_vm = @import("wasm_vm.zig");

const EndpointInfo = struct {
    path: []const u8,
    description: []const u8,
    handler: *const fn (allocator: std.mem.Allocator, io: std.Io, target: []const u8, request: *std.http.Server.Request) anyerror!void,
};

const EndpointEntry = struct {
    key: []const u8,
    info: EndpointInfo,
};

const allowed_origins = &[_][]const u8{
    "https://apereznwo.github.io",
    "http://localhost:4200",
    "http://localhost",
};

const cors_methods = "GET, POST, OPTIONS";
const cors_headers_allow = "Origin, Content-Type, Accept, Authorization";

const external_wasm_candidates = &[_][]const u8{
    "collision_engine.wasm",
    "../zig-out/bin/collision_engine.wasm",
    //"../PWA_DEMO_ENV_PROD/public/wasm/collision_engine.wasm",
    //"../../PWA_DEMO_ENV_PROD/public/wasm/collision_engine.wasm",
    "public/wasm/collision_engine.wasm",
    "wasm/collision_engine.wasm",
};

const ExternalWasmReport = struct {
    found: bool,
    valid_header: bool,
    wasm_version: u32,
    file_size: usize,
    section_count: usize,
    export_count: usize,
    has_memory: bool,
    has_get_state_ptr: bool,
    has_compute_metrics: bool,
    has_step_simulation: bool,
    resolved_path: []const u8,
};

fn readLeb128U32(bytes: []const u8, pos: *usize) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (pos.* >= bytes.len) return error.UnexpectedEof;
        const b = bytes[pos.*];
        pos.* += 1;
        const low7: u32 = b & 0x7f;
        result |= low7 << shift;
        if ((b & 0x80) == 0) break;
        if (shift >= 28) return error.InvalidLeb128;
        shift += 7;
    }
    return result;
}

fn inspectExternalWasmBytes(path: []const u8, bytes: []const u8) !ExternalWasmReport {
    var report = ExternalWasmReport{
        .found = true,
        .valid_header = false,
        .wasm_version = 0,
        .file_size = bytes.len,
        .section_count = 0,
        .export_count = 0,
        .has_memory = false,
        .has_get_state_ptr = false,
        .has_compute_metrics = false,
        .has_step_simulation = false,
        .resolved_path = path,
    };

    if (bytes.len < 8) return error.WasmTooShort;
    if (!std.mem.eql(u8, bytes[0..4], "\x00asm")) return error.InvalidWasmMagic;

    report.valid_header = true;
    report.wasm_version = std.mem.readInt(u32, bytes[4..8], .little);
    if (report.wasm_version != 1) return error.UnsupportedWasmVersion;

    var pos: usize = 8;
    while (pos < bytes.len) {
        const section_id = bytes[pos];
        pos += 1;
        const payload_len: usize = @intCast(try readLeb128U32(bytes, &pos));
        if (pos + payload_len > bytes.len) return error.SectionOutOfBounds;

        const payload = bytes[pos .. pos + payload_len];
        pos += payload_len;
        report.section_count += 1;

        // Section ID 7 = Export section
        if (section_id == 7) {
            var exp_pos: usize = 0;
            const count = try readLeb128U32(payload, &exp_pos);
            report.export_count = @intCast(count);

            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const name_len: usize = @intCast(try readLeb128U32(payload, &exp_pos));
                if (exp_pos + name_len > payload.len) return error.InvalidExportName;
                const export_name = payload[exp_pos .. exp_pos + name_len];
                exp_pos += name_len;

                if (exp_pos >= payload.len) return error.InvalidExportDesc;
                _ = payload[exp_pos]; // external kind byte
                exp_pos += 1;
                _ = try readLeb128U32(payload, &exp_pos); // export index

                if (std.mem.eql(u8, export_name, "memory")) report.has_memory = true;
                if (std.mem.eql(u8, export_name, "getStatePtr")) report.has_get_state_ptr = true;
                if (std.mem.eql(u8, export_name, "computeMetrics")) report.has_compute_metrics = true;
                if (std.mem.eql(u8, export_name, "stepSimulation")) report.has_step_simulation = true;
            }
        }
    }

    return report;
}

fn handleTestWasm(allocator: std.mem.Allocator, io: std.Io, target: []const u8, request: *std.http.Server.Request) !void {
    const requested_path = getQueryParam(target, "path");

    var chosen_path: []const u8 = "";
    var wasm_bytes_opt: ?[]u8 = null;

    if (requested_path) |p| {
        if (p.len > 0) {
            if (std.Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(16 * 1024 * 1024))) |bytes| {
                chosen_path = p;
                wasm_bytes_opt = bytes;
            } else |_| {}
        }
    } else {
        for (external_wasm_candidates) |candidate| {
            if (std.Io.Dir.cwd().readFileAlloc(io, candidate, allocator, .limited(16 * 1024 * 1024))) |bytes| {
                chosen_path = candidate;
                wasm_bytes_opt = bytes;
                break;
            } else |_| {}
        }
    }

    const wasm_bytes = wasm_bytes_opt orelse {
        try respondWithHeaders(request, .not_found, "{\"passed\":false,\"error\":\"ExternalWasmNotFound\"}", "application/json; charset=utf-8");
        return;
    };
    defer allocator.free(wasm_bytes);

    const report = inspectExternalWasmBytes(chosen_path, wasm_bytes) catch |err| {
        const err_json = try std.fmt.allocPrint(allocator, "{{\"passed\":false,\"error\":\"{s}\"}}", .{@errorName(err)});
        defer allocator.free(err_json);
        try respondWithHeaders(request, .unprocessable_entity, err_json, "application/json; charset=utf-8");
        return;
    };

    const sim = wasm_vm.runTenStepSimulationTest(allocator, wasm_bytes) catch |err| {
        const err_json = try std.fmt.allocPrint(allocator, "{{\"passed\":false,\"wasmPath\":\"{s}\",\"vmError\":\"{s}\"}}", .{ chosen_path, @errorName(err) });
        defer allocator.free(err_json);
        try respondWithHeaders(request, .unprocessable_entity, err_json, "application/json; charset=utf-8");
        return;
    };

    const all_exports_present =
        report.has_memory and
        report.has_get_state_ptr and
        report.has_compute_metrics and
        report.has_step_simulation;

    const passed = report.valid_header and report.wasm_version == 1 and all_exports_present and sim.passed;

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.print(
        "{{\"passed\":{s},\"wasmPath\":\"{s}\",\"fileSize\":{d},\"wasmVersion\":{d},\"sectionCount\":{d},\"exportCount\":{d},\"exports\":{{\"memory\":{s},\"getStatePtr\":{s},\"computeMetrics\":{s},\"stepSimulation\":{s}}},\"steps\":[",
        .{
            if (passed) "true" else "false",
            report.resolved_path,
            report.file_size,
            report.wasm_version,
            report.section_count,
            report.export_count,
            if (report.has_memory) "true" else "false",
            if (report.has_get_state_ptr) "true" else "false",
            if (report.has_compute_metrics) "true" else "false",
            if (report.has_step_simulation) "true" else "false",
        },
    );

    for (sim.steps, 0..) |s, idx| {
        try w.print(
            "{{\"step\":{d},\"x\":{d},\"y\":{d},\"vx\":{d},\"vy\":{d},\"speed\":{d},\"kineticEnergy\":{d},\"potentialEnergy\":{d},\"totalEnergy\":{d},\"momentum\":{d},\"collisionCount\":{d},\"stopped\":{s}}}",
            .{
                idx + 1,
                s.x,
                s.y,
                s.vx,
                s.vy,
                s.speed,
                s.kinetic_energy,
                s.potential_energy,
                s.total_energy,
                s.momentum,
                s.collision_count,
                if (s.stopped != 0) "true" else "false",
            },
        );
        if (idx + 1 < sim.steps.len) try w.writeAll(",");
    }
    try w.writeAll("]}");

    const body = try out.toOwnedSlice();
    defer allocator.free(body);

    const status: std.http.Status = if (passed) .ok else .unprocessable_entity;
    try respondWithHeaders(request, status, body, "application/json; charset=utf-8");
}

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

fn parseQueryF64(uri: []const u8, key: []const u8, default_val: f64) f64 {
    const raw = getQueryParam(uri, key) orelse return default_val;
    return std.fmt.parseFloat(f64, raw) catch default_val;
}

fn parseQueryI32(uri: []const u8, key: []const u8, default_val: i32) i32 {
    const raw = getQueryParam(uri, key) orelse return default_val;
    return std.fmt.parseInt(i32, raw, 10) catch default_val;
}

fn findRequestOrigin(request: *std.http.Server.Request) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Origin")) {
            return header.value;
        }
    }
    return null;
}

fn resolveAllowedOrigin(request: *std.http.Server.Request) ?[]const u8 {
    const origin = findRequestOrigin(request) orelse return null;
    for (allowed_origins) |allowed| {
        if (std.mem.eql(u8, origin, allowed)) {
            return origin;
        }
    }
    return null;
}

const ResponseHeaderSet = struct {
    buf: [6]std.http.Header = undefined,
    len: usize = 0,

    pub fn slice(self: *const ResponseHeaderSet) []const std.http.Header {
        return self.buf[0..self.len];
    }
};

fn buildResponseHeaders(
    request: *std.http.Server.Request,
    content_type: ?[]const u8,
) ResponseHeaderSet {
    var set = ResponseHeaderSet{};

    if (content_type) |ct| {
        set.buf[set.len] = .{ .name = "Content-Type", .value = ct };
        set.len += 1;
    }

    set.buf[set.len] = .{ .name = "Access-Control-Allow-Methods", .value = cors_methods };
    set.len += 1;

    set.buf[set.len] = .{ .name = "Access-Control-Allow-Headers", .value = cors_headers_allow };
    set.len += 1;

    if (resolveAllowedOrigin(request)) |matched_origin| {
        set.buf[set.len] = .{ .name = "Access-Control-Allow-Origin", .value = matched_origin };
        set.len += 1;

        set.buf[set.len] = .{ .name = "Vary", .value = "Origin" };
        set.len += 1;
    }

    return set;
}

fn respondWithHeaders(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    content_type: ?[]const u8,
) !void {
    const headers = buildResponseHeaders(request, content_type);
    try request.respond(body, .{
        .status = status,
        .extra_headers = headers.slice(),
    });
}

fn handleFractals(allocator: std.mem.Allocator, _: std.Io, target: []const u8, request: *std.http.Server.Request) !void {
    const kind_str = getQueryParam(target, "kind") orelse "1";
    const kind_int = std.fmt.parseInt(i32, kind_str, 10) catch 1;
    const kind = fractal_engine.FractalKind.fromValue(kind_int) orelse .mandelbrot;

    const xMin = parseQueryF64(target, "xMin", -2.0);
    const xMax = parseQueryF64(target, "xMax", 1.0);
    const yMin = parseQueryF64(target, "yMin", -1.5);
    const yMax = parseQueryF64(target, "yMax", 1.5);
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

    try respondWithHeaders(request, .ok, json_slice, "application/json");
}

fn handleCollisionMetrics(allocator: std.mem.Allocator, _: std.Io, target: []const u8, request: *std.http.Server.Request) !void {
    const input = math_engine.MetricsInput{
        .vx = parseQueryF64(target, "vx", 5.0),
        .vy = parseQueryF64(target, "vy", 0.0),
        .mass = parseQueryF64(target, "mass", 1.0),
        .gravity = parseQueryF64(target, "gravity", 0.5),
        .height = parseQueryF64(target, "height", 200.0),
    };

    const res = math_engine.MathEngine.computeMetrics(input);
    const body = try math_engine.MathEngine.toJson(allocator, res);
    defer allocator.free(body);

    try respondWithHeaders(request, .ok, body, "application/json; charset=utf-8");
}

fn handleCollisionStep(allocator: std.mem.Allocator, _: std.Io, target: []const u8, request: *std.http.Server.Request) !void {
    const input = math_engine.StepInput{
        .x = parseQueryF64(target, "x", 100.0),
        .y = parseQueryF64(target, "y", 100.0),
        .vx = parseQueryF64(target, "vx", 5.0),
        .vy = parseQueryF64(target, "vy", 0.0),
        .radius = parseQueryF64(target, "radius", 15.0),
        .mass = parseQueryF64(target, "mass", 1.0),
        .gravity = parseQueryF64(target, "gravity", 0.5),
        .friction = parseQueryF64(target, "friction", 0.98),
        .restitution = parseQueryF64(target, "restitution", 0.8),
        .canvas_width = parseQueryF64(target, "canvasWidth", 500.0),
        .canvas_height = parseQueryF64(target, "canvasHeight", 300.0),
        .collision_count = parseQueryI32(target, "collisionCount", 0),
    };

    const res = math_engine.MathEngine.stepSimulation(input);
    const body = try math_engine.MathEngine.toJson(allocator, res);
    defer allocator.free(body);

    try respondWithHeaders(request, .ok, body, "application/json; charset=utf-8");
}

fn handleZigVersion(allocator: std.mem.Allocator, _: std.Io, _: []const u8, request: *std.http.Server.Request) !void {
    const version_obj = .{ .zigVersion = builtin.zig_version_string };
    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();
    try std.json.Stringify.value(version_obj, .{}, &allocating_writer.writer);
    const json_slice = try allocating_writer.toOwnedSlice();
    defer allocator.free(json_slice);

    try respondWithHeaders(request, .ok, json_slice, "application/json");
}

fn handleWebServerVersion(allocator: std.mem.Allocator, _: std.Io, _: []const u8, request: *std.http.Server.Request) !void {
    const server_obj = .{ .webServerVersion = "0.16.0-http" };
    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();
    try std.json.Stringify.value(server_obj, .{}, &allocating_writer.writer);
    const json_slice = try allocating_writer.toOwnedSlice();
    defer allocator.free(json_slice);

    try respondWithHeaders(request, .ok, json_slice, "application/json");
}

fn handleHealth(allocator: std.mem.Allocator, _: std.Io, _: []const u8, request: *std.http.Server.Request) !void {
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

    try respondWithHeaders(request, .ok, json_slice, "application/json");
}

fn handleRandomVertex(allocator: std.mem.Allocator, _: std.Io, _: []const u8, request: *std.http.Server.Request) !void {
    const result_str = try algorithm_manager.AlgorithmManager.runRandomDijkstra(allocator);
    defer allocator.free(result_str);

    try respondWithHeaders(request, .ok, result_str, "text/plain; charset=utf-8");
}

fn handlePing(_: std.mem.Allocator, _: std.Io, _: []const u8, request: *std.http.Server.Request) !void {
    try respondWithHeaders(request, .no_content, "", null);
}

fn handleDefault(_: std.mem.Allocator, _: std.Io, _: []const u8, request: *std.http.Server.Request) !void {
    try respondWithHeaders(request, .ok, "It works!", null);
}

fn handleAppVersion(_: std.mem.Allocator, _: std.Io, _: []const u8, request: *std.http.Server.Request) !void {
    try respondWithHeaders(request, .ok, "v[1.0.5]", null);
}

const endpointDictionary = [_]EndpointEntry{
    .{ .key = "HEALTH_ENDPOINT", .info = .{ .path = "/health", .description = "Print all endpoints and server status", .handler = handleHealth } },
    .{ .key = "PING_ENDPOINT", .info = .{ .path = "/ping", .description = "Render workaround", .handler = handlePing } },
    .{ .key = "ZIG_VERSION_ENDPOINT", .info = .{ .path = "/api/server/getZigVersion", .description = "Get Zig Version", .handler = handleZigVersion } },
    .{ .key = "SERVER_VERSION_ENDPOINT", .info = .{ .path = "/api/server/getZigWebServerVersion", .description = "Get Http Server Version", .handler = handleWebServerVersion } },
    .{ .key = "APP_VERSION_ENDPOINT", .info = .{ .path = "/api/server/getZigAppVersion", .description = "Get App Version", .handler = handleAppVersion } },
    .{ .key = "FRACTAL_ENDPOINT", .info = .{ .path = "/api/fractals/generate", .description = "Fractal Generation Endpoint", .handler = handleFractals } },
    .{ .key = "DIJKSTRA_ENDPOINT", .info = .{ .path = "/api/Algorithm/GenerateRandomVertex_Zig", .description = "Generate Random Vertex via Dijkstra", .handler = handleRandomVertex } },
    .{ .key = "COLLISION_METRICS_ENDPOINT", .info = .{ .path = "/api/Algorithm/CollisionMetrics", .description = "Compute collision physics metrics", .handler = handleCollisionMetrics } },
    .{ .key = "COLLISION_STEP_ENDPOINT", .info = .{ .path = "/api/Algorithm/CollisionStep", .description = "Step collision physics simulation", .handler = handleCollisionStep } },
    .{ .key = "TEST_WASM_ENDPOINT", .info = .{ .path = "/api/Algorithm/TestWasm", .description = "Inspect and execute 10-step simulation on external collision_engine.wasm", .handler = handleTestWasm } },
};

fn httpIntercept(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
) void {
    const target = request.head.target;
    const path = if (std.mem.indexOf(u8, target, "?")) |idx| target[0..idx] else target;
    const origin = findRequestOrigin(request) orelse "-";

    std.debug.print("[HTTP IN]  {s} {s} (Origin: {s})\n", .{ @tagName(request.head.method), path, origin });

    if (request.head.method == .OPTIONS) {
        respondWithHeaders(request, .no_content, "", null) catch {
            std.debug.print("[HTTP OUT] {s} {s} -> 500 (OPTIONS failed)\n", .{ @tagName(request.head.method), path });
            return;
        };
        std.debug.print("[HTTP OUT] {s} {s} -> 204\n", .{ @tagName(request.head.method), path });
        return;
    }

    for (endpointDictionary) |entry| {
        if (std.mem.eql(u8, path, entry.info.path)) {
            entry.info.handler(allocator, io, target, request) catch |err| {
                std.debug.print("[HTTP ERR] {s} {s} -> {s}\n", .{ @tagName(request.head.method), path, @errorName(err) });
                respondWithHeaders(request, .internal_server_error, "Internal Server Error", "text/plain; charset=utf-8") catch {};
                std.debug.print("[HTTP OUT] {s} {s} -> 500\n", .{ @tagName(request.head.method), path });
                return;
            };
            std.debug.print("[HTTP OUT] {s} {s} -> 200\n", .{ @tagName(request.head.method), path });
            return;
        }
    }

    handleDefault(allocator, io, target, request) catch {
        std.debug.print("[HTTP OUT] {s} {s} -> 500\n", .{ @tagName(request.head.method), path });
        return;
    };
    std.debug.print("[HTTP OUT] {s} {s} -> 200 (default)\n", .{ @tagName(request.head.method), path });
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
        httpIntercept(allocator, io, &request);
    }
}
