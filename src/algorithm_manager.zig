const std = @import("std");

pub const AlgorithmManager = struct {
    pub fn runRandomDijkstra(allocator: std.mem.Allocator) ![]u8 {
        const vertex_size = 9;
        const sample_size = 23;
        const source_point = 0;
        const sample_size_adj = sample_size - 2;

        var vertex_x = try allocator.alloc(i32, sample_size_adj);
        defer allocator.free(vertex_x);
        var vertex_y = try allocator.alloc(i32, sample_size_adj);
        defer allocator.free(vertex_y);

        var i: usize = 0;
        while (i < sample_size_adj) : (i += 1) {
            vertex_x[i] = @as(i32, @intCast(i + 1));
            vertex_y[i] = @as(i32, @intCast(i + 1));
        }

        const SeedGen = struct {
            var counter: u64 = 0;
        };
        SeedGen.counter +%= 1;
        const seed = SeedGen.counter +% @intFromPtr(&SeedGen.counter);
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        fisherYates(vertex_x, rand);
        fisherYates(vertex_y, rand);

        var vertex_array = try allocator.alloc([]u8, vertex_size);
        defer {
            for (vertex_array) |v| allocator.free(v);
            allocator.free(vertex_array);
        }

        var vertex_array_list: std.ArrayList(u8) = .empty;
        defer vertex_array_list.deinit(allocator);

        for (0..vertex_size) |idx| {
            const sep = if (idx < vertex_size - 1) "|" else "";
            const formatted = try std.fmt.allocPrint(allocator, "[{},{}]{s}", .{ vertex_x[idx], vertex_y[idx], sep });
            vertex_array[idx] = formatted;
            try vertex_array_list.appendSlice(allocator, formatted);
        }
        const vertex_array_string = try vertex_array_list.toOwnedSlice(allocator);
        defer allocator.free(vertex_array_string);

        var graph = try allocator.alloc([]i32, vertex_size);
        defer {
            for (graph) |row| allocator.free(row);
            allocator.free(graph);
        }
        for (0..vertex_size) |r| {
            graph[r] = try allocator.alloc(i32, vertex_size);
            @memset(graph[r], 0);
        }

        const vertex_matrix = try generateRandomMatrix(allocator, vertex_array, graph, vertex_size, rand);
        defer allocator.free(vertex_matrix);

        const vertex_list = try dijkstraCore(allocator, vertex_array, graph, vertex_size, source_point);
        defer allocator.free(vertex_list);

        const sorted_list_encoded = try replaceAll(allocator, vertex_list, ",", "<br/>");
        defer allocator.free(sorted_list_encoded);
        const sorted_list_encoded_2 = try replaceAll(allocator, sorted_list_encoded, "\t", "&nbsp;");
        defer allocator.free(sorted_list_encoded_2);

        return try std.fmt.allocPrint(allocator, "{s}■{s}■{s}", .{ vertex_array_string, vertex_matrix, sorted_list_encoded_2 });
    }

    fn fisherYates(deck: []i32, rand: std.Random) void {
        var idx: usize = deck.len;
        while (idx > 1) {
            idx -= 1;
            const j = rand.intRangeAtMost(usize, 0, idx);
            const temp = deck[idx];
            deck[idx] = deck[j];
            deck[j] = temp;
        }
    }

    fn generateRandomMatrix(allocator: std.mem.Allocator, vertex_string: [][]u8, graph: [][]i32, vertex_size: usize, rand: std.Random) ![]u8 {
        for (0..vertex_size) |x| {
            for ((x + 1)..vertex_size) |y| {
                const val = if (rand.boolean()) @as(i32, @intFromFloat(getHypotenuse(vertex_string, x, y))) else 0;
                graph[x][y] = val;
                graph[y][x] = val;
            }
        }

        for (0..vertex_size) |x| {
            var zero_count: usize = 0;
            for (0..vertex_size) |y| {
                if (x != y and graph[x][y] == 0) {
                    zero_count += 1;
                    if (zero_count == vertex_size - 1) {
                        const hyp = @as(i32, @intFromFloat(getHypotenuse(vertex_string, x, y)));
                        graph[x][y] = hyp;
                        graph[y][x] = hyp;
                    }
                }
            }
        }

        var rows: std.ArrayList([]u8) = .empty;
        defer {
            for (rows.items) |row| allocator.free(row);
            rows.deinit(allocator);
        }

        for (graph) |row| {
            var row_strs: std.ArrayList([]u8) = .empty;
            defer {
                for (row_strs.items) |s| allocator.free(s);
                row_strs.deinit(allocator);
            }
            for (row) |v| {
                const v_str = try std.fmt.allocPrint(allocator, "{d}", .{v});
                try row_strs.append(allocator, v_str);
            }
            const joined_row = try std.mem.join(allocator, ",", row_strs.items);
            defer allocator.free(joined_row);
            const wrapped_row = try std.fmt.allocPrint(allocator, "{{{s}}}", .{joined_row});
            try rows.append(allocator, wrapped_row);
        }

        return std.mem.join(allocator, "|", rows.items);
    }

    fn getHypotenuse(vertex_string: [][]u8, index_x: usize, index_y: usize) f64 {
        const parseCoord = struct {
            fn parse(s: []u8) struct { x: f64, y: f64 } {
                var x_val: f64 = 0.0;
                var y_val: f64 = 0.0;
                
                var start: usize = 0;
                while (start < s.len and (s[start] == '[' or s[start] == '|')) start += 1;
                
                var end = s.len;
                while (end > start and (s[end - 1] == ']' or s[end - 1] == '|')) end -= 1;
                
                const core = s[start..end];
                var it = std.mem.splitScalar(u8, core, ',');
                if (it.next()) |x_str| {
                    x_val = std.fmt.parseFloat(f64, std.mem.trim(u8, x_str, " ")) catch 0.0;
                }
                if (it.next()) |y_str| {
                    y_val = std.fmt.parseFloat(f64, std.mem.trim(u8, y_str, " ")) catch 0.0;
                }
                return .{ .x = x_val, .y = y_val };
            }
        }.parse;

        const c1 = parseCoord(vertex_string[index_y]);
        const c2 = parseCoord(vertex_string[index_x]);

        return std.math.sqrt(std.math.pow(f64, c2.x - c1.x, 2.0) + std.math.pow(f64, c2.y - c1.y, 2.0));
    }

    fn dijkstraCore(allocator: std.mem.Allocator, vertex: [][]u8, graph: [][]i32, vertex_size: usize, src: usize) ![]u8 {
        var dist = try allocator.alloc(i32, vertex_size);
        defer allocator.free(dist);
        @memset(dist, std.math.maxInt(i32));

        var visited = try allocator.alloc(bool, vertex_size);
        defer allocator.free(visited);
        @memset(visited, false);

        var previous = try allocator.alloc(?usize, vertex_size);
        defer allocator.free(previous);
        @memset(previous, null);

        dist[src] = 0;

        for (0..vertex_size) |_| {
            var min_dist: i32 = std.math.maxInt(i32);
            var u: ?usize = null;

            for (0..vertex_size) |i| {
                if (!visited[i] and dist[i] < min_dist) {
                    min_dist = dist[i];
                    u = i;
                }
            }

            const current_u = u orelse break;
            visited[current_u] = true;

            for (0..vertex_size) |v| {
                const weight = graph[current_u][v];
                if (!visited[v] and weight > 0 and dist[current_u] != std.math.maxInt(i32)) {
                    const new_dist = dist[current_u] + weight;
                    if (new_dist < dist[v]) {
                        dist[v] = new_dist;
                        previous[v] = current_u;
                    }
                }
            }
        }

        var result_rows: std.ArrayList([]u8) = .empty;
        defer {
            for (result_rows.items) |row| allocator.free(row);
            result_rows.deinit(allocator);
        }

        for (0..vertex_size) |v| {
            var d = dist[v];
            if (d == std.math.maxInt(i32)) {
                d = 0;
            }

            var path_str_list: std.ArrayList(u8) = .empty;
            defer path_str_list.deinit(allocator);

            if (v != src and dist[v] != std.math.maxInt(i32)) {
                var steps: std.ArrayList(usize) = .empty;
                defer steps.deinit(allocator);

                var curr: ?usize = v;
                while (curr) |c| {
                    try steps.append(allocator, c);
                    if (c == src) break;
                    curr = previous[c];
                }

                std.mem.reverse(usize, steps.items);

                if (steps.items.len > 0 and steps.items[0] == src) {
                    for (0..steps.items.len - 1) |i| {
                        const step_str = try std.fmt.allocPrint(allocator, "[{};{}]≡", .{ steps.items[i], steps.items[i + 1] });
                        defer allocator.free(step_str);
                        try path_str_list.appendSlice(allocator, step_str);
                    }
                }
            }
            const path_str = try path_str_list.toOwnedSlice(allocator);
            defer allocator.free(path_str);

            const v_clean = try replaceAll(allocator, vertex[v], ",", ";");
            defer allocator.free(v_clean);
            const v_clean_2 = try replaceAll(allocator, v_clean, "|", "");
            defer allocator.free(v_clean_2);

            const formatted_row = try std.fmt.allocPrint(allocator, "{:02}<{s}>-{:02}-{s}", .{ v, v_clean_2, d, path_str });
            try result_rows.append(allocator, formatted_row);
        }

        return std.mem.join(allocator, ",", result_rows.items);
    }

    fn replaceAll(allocator: std.mem.Allocator, input: []const u8, sub: []const u8, replacement: []const u8) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);

        var it = std.mem.splitSequence(u8, input, sub);
        var first = true;
        while (it.next()) |chunk| {
            if (!first) {
                try list.appendSlice(allocator, replacement);
            }
            try list.appendSlice(allocator, chunk);
            first = false;
        }
        return list.toOwnedSlice(allocator);
    }
};