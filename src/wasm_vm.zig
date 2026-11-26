const std = @import("std");

pub const WasmPhysicsSnapshot = extern struct {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    speed: f64,
    kinetic_energy: f64,
    potential_energy: f64,
    total_energy: f64,
    momentum: f64,
    collision_count: i32,
    stopped: i32,
};

const Val = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
};

const FuncType = struct {
    params: []const u8,
    results: []const u8,
};

const GlobalVar = struct {
    val: Val,
};

const FuncBody = struct {
    type_idx: u32,
    locals: []const u8,
    code: []const u8,
};

const ControlFrame = struct {
    opcode: u8, // 0x02 block, 0x03 loop, 0x04 if
    start_pc: usize,
    else_pc: ?usize,
    end_pc: usize,
    stack_height: usize,
    has_result: bool,
};

pub const SimulationRunResult = struct {
    passed: bool,
    steps: [10]WasmPhysicsSnapshot,
    unsupported_opcode: ?u8 = null,
    unsupported_sub_opcode: ?u32 = null,
};

fn readU32Leb(bytes: []const u8, pos: *usize) !u32 {
    var res: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (pos.* >= bytes.len) return error.UnexpectedEof;
        const b = bytes[pos.*];
        pos.* += 1;
        res |= @as(u32, b & 0x7f) << shift;
        if ((b & 0x80) == 0) break;
        if (shift >= 28) return error.InvalidLeb128;
        shift += 7;
    }
    return res;
}

fn readI32Leb(bytes: []const u8, pos: *usize) !i32 {
    var res: i32 = 0;
    var shift: u5 = 0;
    var b: u8 = 0;
    while (true) {
        if (pos.* >= bytes.len) return error.UnexpectedEof;
        b = bytes[pos.*];
        pos.* += 1;
        res |= @as(i32, b & 0x7f) << shift;
        shift +|= 7;
        if ((b & 0x80) == 0) break;
    }
    if (shift < 32 and (b & 0x40) != 0) {
        res |= (~@as(i32, 0)) << shift;
    }
    return res;
}

fn readI64Leb(bytes: []const u8, pos: *usize) !i64 {
    var res: i64 = 0;
    var shift: u6 = 0;
    var b: u8 = 0;
    while (true) {
        if (pos.* >= bytes.len) return error.UnexpectedEof;
        b = bytes[pos.*];
        pos.* += 1;
        res |= @as(i64, b & 0x7f) << shift;
        shift +|= 7;
        if ((b & 0x80) == 0) break;
    }
    if (shift < 64 and (b & 0x40) != 0) {
        res |= (~@as(i64, 0)) << shift;
    }
    return res;
}

fn skipConstExpr(bytes: []const u8, pos: *usize) !Val {
    var val: Val = .{ .i32 = 0 };
    while (pos.* < bytes.len) {
        const op = bytes[pos.*];
        pos.* += 1;
        switch (op) {
            0x0b => return val,
            0x41 => val = .{ .i32 = try readI32Leb(bytes, pos) },
            0x42 => val = .{ .i64 = try readI64Leb(bytes, pos) },
            0x43 => {
                val = .{ .f32 = @bitCast(std.mem.readInt(u32, bytes[pos.*..][0..4], .little)) };
                pos.* += 4;
            },
            0x44 => {
                val = .{ .f64 = @bitCast(std.mem.readInt(u64, bytes[pos.*..][0..8], .little)) };
                pos.* += 8;
            },
            else => return error.UnsupportedConstExpr,
        }
    }
    return error.UnexpectedEof;
}

pub const WasmInstance = struct {
    allocator: std.mem.Allocator,
    types: []FuncType,
    funcs: []FuncBody,
    globals: []GlobalVar,
    memory: []u8,
    exports: std.StringHashMap(u32),
    last_unsupported_opcode: ?u8 = null,
    last_unsupported_sub_opcode: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, wasm_bytes: []const u8) !WasmInstance {
        if (wasm_bytes.len < 8 or !std.mem.eql(u8, wasm_bytes[0..4], "\x00asm")) {
            return error.InvalidWasmBinary;
        }

        var types = std.ArrayList(FuncType).empty;
        var func_type_indices = std.ArrayList(u32).empty;
        var globals = std.ArrayList(GlobalVar).empty;
        var bodies = std.ArrayList(FuncBody).empty;
        var exports = std.StringHashMap(u32).init(allocator);
        var initial_pages: usize = 1;
        var memory: []u8 = &.{};

        var pos: usize = 8;
        while (pos < wasm_bytes.len) {
            const sec_id = wasm_bytes[pos];
            pos += 1;
            const sec_len: usize = @intCast(try readU32Leb(wasm_bytes, &pos));
            const sec = wasm_bytes[pos .. pos + sec_len];
            pos += sec_len;

            var sp: usize = 0;
            switch (sec_id) {
                1 => { // Type section
                    const count = try readU32Leb(sec, &sp);
                    var i: u32 = 0;
                    while (i < count) : (i += 1) {
                        const form = sec[sp];
                        sp += 1;
                        if (form != 0x60) return error.InvalidFuncType;
                        const p_len: usize = @intCast(try readU32Leb(sec, &sp));
                        const params = sec[sp .. sp + p_len];
                        sp += p_len;
                        const r_len: usize = @intCast(try readU32Leb(sec, &sp));
                        const results = sec[sp .. sp + r_len];
                        sp += r_len;
                        try types.append(allocator, .{ .params = params, .results = results });
                    }
                },
                3 => { // Function section
                    const count = try readU32Leb(sec, &sp);
                    var i: u32 = 0;
                    while (i < count) : (i += 1) {
                        try func_type_indices.append(allocator, try readU32Leb(sec, &sp));
                    }
                },
                5 => { // Memory section
                    const count = try readU32Leb(sec, &sp);
                    if (count > 0) {
                        const flags = try readU32Leb(sec, &sp);
                        initial_pages = @intCast(try readU32Leb(sec, &sp));
                        if ((flags & 1) != 0) _ = try readU32Leb(sec, &sp);
                    }
                    memory = try allocator.alloc(u8, @max(initial_pages, 1) * 65536);
                    @memset(memory, 0);
                },
                6 => { // Global section
                    const count = try readU32Leb(sec, &sp);
                    var i: u32 = 0;
                    while (i < count) : (i += 1) {
                        _ = sec[sp]; // valtype
                        _ = sec[sp + 1]; // mutability
                        sp += 2;
                        const init_val = try skipConstExpr(sec, &sp);
                        try globals.append(allocator, .{ .val = init_val });
                    }
                },
                7 => { // Export section
                    const count = try readU32Leb(sec, &sp);
                    var i: u32 = 0;
                    while (i < count) : (i += 1) {
                        const name_len: usize = @intCast(try readU32Leb(sec, &sp));
                        const name = sec[sp .. sp + name_len];
                        sp += name_len;
                        const kind = sec[sp];
                        sp += 1;
                        const idx = try readU32Leb(sec, &sp);
                        if (kind == 0) { // function export
                            try exports.put(name, idx);
                        }
                    }
                },
                10 => { // Code section
                    const count = try readU32Leb(sec, &sp);
                    var i: u32 = 0;
                    while (i < count) : (i += 1) {
                        const body_size: usize = @intCast(try readU32Leb(sec, &sp));
                        const body_end = sp + body_size;
                        const local_decl_count = try readU32Leb(sec, &sp);
                        var local_types = std.ArrayList(u8).empty;
                        var l: u32 = 0;
                        while (l < local_decl_count) : (l += 1) {
                            const n = try readU32Leb(sec, &sp);
                            const vt = sec[sp];
                            sp += 1;
                            var k: u32 = 0;
                            while (k < n) : (k += 1) {
                                try local_types.append(allocator, vt);
                            }
                        }
                        try bodies.append(allocator, .{
                            .type_idx = func_type_indices.items[i],
                            .locals = try local_types.toOwnedSlice(allocator),
                            .code = sec[sp..body_end],
                        });
                        sp = body_end;
                    }
                },
                11 => { // Data section
                    if (memory.len == 0) {
                        memory = try allocator.alloc(u8, 65536);
                        @memset(memory, 0);
                    }
                    const count = try readU32Leb(sec, &sp);
                    var i: u32 = 0;
                    while (i < count) : (i += 1) {
                        const mode = try readU32Leb(sec, &sp);
                        if (mode == 0) {
                            const offset_val = try skipConstExpr(sec, &sp);
                            const offset: usize = @intCast(offset_val.i32);
                            const data_len: usize = @intCast(try readU32Leb(sec, &sp));
                            @memcpy(memory[offset .. offset + data_len], sec[sp .. sp + data_len]);
                            sp += data_len;
                        } else {
                            return error.UnsupportedDataSegment;
                        }
                    }
                },
                else => {},
            }
        }

        return .{
            .allocator = allocator,
            .types = try types.toOwnedSlice(allocator),
            .funcs = try bodies.toOwnedSlice(allocator),
            .globals = try globals.toOwnedSlice(allocator),
            .memory = memory,
            .exports = exports,
        };
    }

    pub fn deinit(self: *WasmInstance) void {
        for (self.funcs) |f| self.allocator.free(f.locals);
        self.allocator.free(self.funcs);
        self.allocator.free(self.types);
        self.allocator.free(self.globals);
        if (self.memory.len > 0) self.allocator.free(self.memory);
        self.exports.deinit();
    }

    fn scanStructure(code: []const u8, start: usize) !struct { else_pc: ?usize, end_pc: usize } {
        var pc = start;
        var depth: usize = 1;
        var else_pc: ?usize = null;
        while (pc < code.len) {
            const op = code[pc];
            pc += 1;
            switch (op) {
                0x02, 0x03, 0x04 => {
                    _ = try readI32Leb(code, &pc); // blocktype
                    depth += 1;
                },
                0x05 => {
                    if (depth == 1) else_pc = pc;
                },
                0x0b => {
                    depth -= 1;
                    if (depth == 0) return .{ .else_pc = else_pc, .end_pc = pc };
                },
                0x0c, 0x0d, 0x10, 0x20, 0x21, 0x22, 0x23, 0x24 => _ = try readU32Leb(code, &pc),
                0x0e => {
                    const n = try readU32Leb(code, &pc);
                    var i: u32 = 0;
                    while (i <= n) : (i += 1) _ = try readU32Leb(code, &pc);
                },
                0x11 => {
                    _ = try readU32Leb(code, &pc);
                    _ = try readU32Leb(code, &pc);
                },
                0x28...0x3e => {
                    _ = try readU32Leb(code, &pc);
                    _ = try readU32Leb(code, &pc);
                },
                0x3f, 0x40 => pc += 1,
                0x41 => _ = try readI32Leb(code, &pc),
                0x42 => _ = try readI64Leb(code, &pc),
                0x43 => pc += 4,
                0x44 => pc += 8,
                0xfc => {
                    _ = try readU32Leb(code, &pc);
                },
                else => {},
            }
        }
        return error.UnclosedBlock;
    }

    pub fn callExport(self: *WasmInstance, name: []const u8, args: []const Val) !?Val {
        const func_idx = self.exports.get(name) orelse return error.ExportNotFound;
        return self.execFunc(func_idx, args);
    }

    fn execFunc(self: *WasmInstance, func_idx: u32, args: []const Val) anyerror!?Val {
        const body = self.funcs[func_idx];
        const ftype = self.types[body.type_idx];

        var locals = try self.allocator.alloc(Val, ftype.params.len + body.locals.len);
        defer self.allocator.free(locals);

        for (args, 0..) |a, idx| locals[idx] = a;
        for (body.locals, 0..) |lt, idx| {
            locals[ftype.params.len + idx] = switch (lt) {
                0x7f => .{ .i32 = 0 },
                0x7e => .{ .i64 = 0 },
                0x7d => .{ .f32 = 0.0 },
                0x7c => .{ .f64 = 0.0 },
                else => .{ .i32 = 0 },
            };
        }

        var stack = std.ArrayList(Val).empty;
        defer stack.deinit(self.allocator);

        var frames = std.ArrayList(ControlFrame).empty;
        defer frames.deinit(self.allocator);

        try frames.append(self.allocator, .{
            .opcode = 0x02,
            .start_pc = 0,
            .else_pc = null,
            .end_pc = body.code.len,
            .stack_height = 0,
            .has_result = ftype.results.len > 0,
        });

        var pc: usize = 0;
        while (pc < body.code.len) {
            const op = body.code[pc];
            pc += 1;

            switch (op) {
                0x00 => return error.WasmUnreachableTrap,
                0x01 => {}, // nop
                0x02, 0x03 => { // block, loop
                    const bt = try readI32Leb(body.code, &pc);
                    const bounds = try scanStructure(body.code, pc);
                    try frames.append(self.allocator, .{
                        .opcode = op,
                        .start_pc = pc,
                        .else_pc = bounds.else_pc,
                        .end_pc = bounds.end_pc,
                        .stack_height = stack.items.len,
                        .has_result = bt != -64,
                    });
                },
                0x04 => { // if
                    const bt = try readI32Leb(body.code, &pc);
                    const bounds = try scanStructure(body.code, pc);
                    const cond = stack.pop().?.i32;
                    try frames.append(self.allocator, .{
                        .opcode = 0x04,
                        .start_pc = pc,
                        .else_pc = bounds.else_pc,
                        .end_pc = bounds.end_pc,
                        .stack_height = stack.items.len,
                        .has_result = bt != -64,
                    });
                    if (cond == 0) {
                        if (bounds.else_pc) |ep| {
                            pc = ep;
                        } else {
                            _ = frames.pop();
                            pc = bounds.end_pc;
                        }
                    }
                },
                0x05 => { // else (reached only from true branch; jump to end and let 0x0b pop the frame)
                    if (frames.items.len > 0) {
                        pc = frames.items[frames.items.len - 1].end_pc;
                    }
                },
                0x0b => { // end
                    if (frames.items.len > 0) {
                        _ = frames.pop();
                    }
                    if (frames.items.len == 0) break;
                },
                0x0c, 0x0d => { // br, br_if
                    const label = try readU32Leb(body.code, &pc);
                    const take = if (op == 0x0c) true else (stack.pop().?.i32 != 0);
                    if (take) {
                        const target_idx = frames.items.len - 1 - label;
                        const target = frames.items[target_idx];
                        const ret_val: ?Val = if (target.has_result and target.opcode != 0x03) stack.pop() else null;
                        stack.shrinkRetainingCapacity(target.stack_height);
                        if (ret_val) |rv| try stack.append(self.allocator, rv);
                        if (target.opcode == 0x03) {
                            frames.shrinkRetainingCapacity(target_idx + 1);
                            pc = target.start_pc;
                        } else {
                            // Keep target frame until the 0x0b at target.end_pc pops it
                            frames.shrinkRetainingCapacity(target_idx + 1);
                            pc = target.end_pc;
                        }
                    }
                },
                0x0f => { // return
                    if (ftype.results.len > 0 and stack.items.len > 0) {
                        return stack.items[stack.items.len - 1];
                    }
                    return null;
                },
                0x10 => { // call
                    const callee = try readU32Leb(body.code, &pc);
                    const callee_type = self.types[self.funcs[callee].type_idx];
                    const n_params = callee_type.params.len;
                    const call_args = try self.allocator.alloc(Val, n_params);
                    defer self.allocator.free(call_args);
                    var k: usize = n_params;
                    while (k > 0) {
                        k -= 1;
                        call_args[k] = stack.pop().?;
                    }
                    if (try self.execFunc(callee, call_args)) |res| {
                        try stack.append(self.allocator, res);
                    }
                },
                0x1a => _ = stack.pop(), // drop
                0x1b => { // select
                    const c = stack.pop().?.i32;
                    const v2 = stack.pop().?;
                    const v1 = stack.pop().?;
                    try stack.append(self.allocator, if (c != 0) v1 else v2);
                },
                0x20 => {
                    const idx = try readU32Leb(body.code, &pc);
                    try stack.append(self.allocator, locals[idx]);
                },
                0x21 => {
                    const idx = try readU32Leb(body.code, &pc);
                    locals[idx] = stack.pop().?;
                },
                0x22 => {
                    const idx = try readU32Leb(body.code, &pc);
                    locals[idx] = stack.items[stack.items.len - 1];
                },
                0x23 => {
                    const idx = try readU32Leb(body.code, &pc);
                    try stack.append(self.allocator, self.globals[idx].val);
                },
                0x24 => {
                    const idx = try readU32Leb(body.code, &pc);
                    self.globals[idx].val = stack.pop().?;
                },
                0x28 => { // i32.load
                    _ = try readU32Leb(body.code, &pc);
                    const offset: usize = @intCast(try readU32Leb(body.code, &pc));
                    const base: usize = @intCast(@as(u32, @bitCast(stack.pop().?.i32)));
                    const v = std.mem.readInt(i32, self.memory[base + offset ..][0..4], .little);
                    try stack.append(self.allocator, .{ .i32 = v });
                },
                0x2a => { // f32.load
                    _ = try readU32Leb(body.code, &pc);
                    const offset: usize = @intCast(try readU32Leb(body.code, &pc));
                    const base: usize = @intCast(@as(u32, @bitCast(stack.pop().?.i32)));
                    const bits = std.mem.readInt(u32, self.memory[base + offset ..][0..4], .little);
                    try stack.append(self.allocator, .{ .f64 = @floatCast(@as(f32, @bitCast(bits))) });
                },
                0x2b => { // f64.load
                    _ = try readU32Leb(body.code, &pc);
                    const offset: usize = @intCast(try readU32Leb(body.code, &pc));
                    const base: usize = @intCast(@as(u32, @bitCast(stack.pop().?.i32)));
                    const bits = std.mem.readInt(u64, self.memory[base + offset ..][0..8], .little);
                    try stack.append(self.allocator, .{ .f64 = @bitCast(bits) });
                },
                0x36 => { // i32.store
                    _ = try readU32Leb(body.code, &pc);
                    const offset: usize = @intCast(try readU32Leb(body.code, &pc));
                    const val = stack.pop().?.i32;
                    const base: usize = @intCast(@as(u32, @bitCast(stack.pop().?.i32)));
                    std.mem.writeInt(i32, self.memory[base + offset ..][0..4], val, .little);
                },
                0x38 => { // f32.store
                    _ = try readU32Leb(body.code, &pc);
                    const offset: usize = @intCast(try readU32Leb(body.code, &pc));
                    const val: f32 = @floatCast(stack.pop().?.f64);
                    const base: usize = @intCast(@as(u32, @bitCast(stack.pop().?.i32)));
                    std.mem.writeInt(u32, self.memory[base + offset ..][0..4], @bitCast(val), .little);
                },
                0x39 => { // f64.store
                    _ = try readU32Leb(body.code, &pc);
                    const offset: usize = @intCast(try readU32Leb(body.code, &pc));
                    const val = stack.pop().?.f64;
                    const base: usize = @intCast(@as(u32, @bitCast(stack.pop().?.i32)));
                    std.mem.writeInt(u64, self.memory[base + offset ..][0..8], @bitCast(val), .little);
                },
                0x41 => try stack.append(self.allocator, .{ .i32 = try readI32Leb(body.code, &pc) }),
                0x42 => try stack.append(self.allocator, .{ .i64 = try readI64Leb(body.code, &pc) }),
                0x43 => { // f32.const
                    const bits = std.mem.readInt(u32, body.code[pc..][0..4], .little);
                    pc += 4;
                    try stack.append(self.allocator, .{ .f32 = @bitCast(bits) });
                },
                0x44 => {
                    const bits = std.mem.readInt(u64, body.code[pc..][0..8], .little);
                    pc += 8;
                    try stack.append(self.allocator, .{ .f64 = @bitCast(bits) });
                },
                0x45 => {
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .i32 = if (a == 0) 1 else 0 });
                },
                0x46 => {
                    const b = stack.pop().?.i32;
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .i32 = if (a == b) 1 else 0 });
                },
                0x47 => {
                    const b = stack.pop().?.i32;
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .i32 = if (a != b) 1 else 0 });
                },
                0x48 => {
                    const b = stack.pop().?.i32;
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .i32 = if (a < b) 1 else 0 });
                },
                0x49 => {
                    const b: u32 = @bitCast(stack.pop().?.i32);
                    const a: u32 = @bitCast(stack.pop().?.i32);
                    try stack.append(self.allocator, .{ .i32 = if (a < b) 1 else 0 });
                },
                0x4a => {
                    const b = stack.pop().?.i32;
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .i32 = if (a > b) 1 else 0 });
                },
                0x4b => {
                    const b: u32 = @bitCast(stack.pop().?.i32);
                    const a: u32 = @bitCast(stack.pop().?.i32);
                    try stack.append(self.allocator, .{ .i32 = if (a > b) 1 else 0 });
                },
                0x4c => {
                    const b = stack.pop().?.i32;
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .i32 = if (a <= b) 1 else 0 });
                },
                0x4e => {
                    const b = stack.pop().?.i32;
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .i32 = if (a >= b) 1 else 0 });
                },
                0x4f => {
                    const b: u32 = @bitCast(stack.pop().?.i32);
                    const a: u32 = @bitCast(stack.pop().?.i32);
                    try stack.append(self.allocator, .{ .i32 = if (a >= b) 1 else 0 });
                },
                0x61 => {
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .i32 = if (a == b) 1 else 0 });
                },
                0x62 => {
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .i32 = if (a != b) 1 else 0 });
                },
                0x63 => {
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .i32 = if (a < b) 1 else 0 });
                },
                0x64 => {
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .i32 = if (a > b) 1 else 0 });
                },
                0x65 => {
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .i32 = if (a <= b) 1 else 0 });
                },
                0x66 => {
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .i32 = if (a >= b) 1 else 0 });
                },
                0x6a => {
                    const b = stack.pop().?.i32;
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .i32 = a +% b });
                },
                0x6b => {
                    const b = stack.pop().?.i32;
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .i32 = a -% b });
                },
                0x71 => {
                    const b = stack.pop().?.i32;
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .i32 = a & b });
                },
                0x72 => {
                    const b = stack.pop().?.i32;
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .i32 = a | b });
                },
                0x73 => {
                    const b = stack.pop().?.i32;
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .i32 = a ^ b });
                },
                0x99 => { // f64.abs
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .f64 = @abs(a) });
                },
                0x9a => { // f64.neg
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .f64 = -a });
                },
                0x9b => { // f64.copysign
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    const mag = @abs(a);
                    const signed = if (std.math.signbit(b)) -mag else mag;
                    try stack.append(self.allocator, .{ .f64 = signed });
                },
                0x9f => { // f64.sqrt
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .f64 = @sqrt(a) });
                },
                0xa0 => { // f64.add
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .f64 = a + b });
                },
                0xa1 => { // f64.sub
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .f64 = a - b });
                },
                0xa2 => { // f64.mul
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .f64 = a * b });
                },
                0xa3 => { // f64.div
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .f64 = a / b });
                },
                0xa4 => { // f64.min
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .f64 = @min(a, b) });
                },
                0xa5 => { // f64.max
                    const b = stack.pop().?.f64;
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .f64 = @max(a, b) });
                },
                0xaa => { // i32.trunc_f64_s
                    const a = stack.pop().?.f64;
                    try stack.append(self.allocator, .{ .i32 = @intFromFloat(@trunc(a)) });
                },
                0xb7 => { // f64.convert_i32_s
                    const a = stack.pop().?.i32;
                    try stack.append(self.allocator, .{ .f64 = @floatFromInt(a) });
                },
                0xbb => { // f64.convert_i32_u
                    const a: u32 = @bitCast(stack.pop().?.i32);
                    try stack.append(self.allocator, .{ .f64 = @floatFromInt(a) });
                },
                0xfc => { // saturating truncations & bulk memory ops
                    const sub_op = try readU32Leb(body.code, &pc);
                    if (sub_op == 0) { // i32.trunc_sat_f64_s
                        const a = stack.pop().?.f64;
                        const clamped = std.math.clamp(a, @as(f64, @floatFromInt(std.math.minInt(i32))), @as(f64, @floatFromInt(std.math.maxInt(i32))));
                        try stack.append(self.allocator, .{ .i32 = @intFromFloat(@trunc(clamped)) });
                    } else if (sub_op == 1) { // i32.trunc_sat_f64_u
                        const a = stack.pop().?.f64;
                        const clamped = std.math.clamp(a, 0.0, @as(f64, @floatFromInt(std.math.maxInt(u32))));
                        try stack.append(self.allocator, .{ .i32 = @bitCast(@as(u32, @intFromFloat(@trunc(clamped)))) });
                    } else if (sub_op == 10) { // memory.copy
                        _ = body.code[pc];
                        _ = body.code[pc + 1];
                        pc += 2;
                        const n: usize = @intCast(@as(u32, @bitCast(stack.pop().?.i32)));
                        const src: usize = @intCast(@as(u32, @bitCast(stack.pop().?.i32)));
                        const dst: usize = @intCast(@as(u32, @bitCast(stack.pop().?.i32)));
                        std.mem.copyForwards(u8, self.memory[dst .. dst + n], self.memory[src .. src + n]);
                    } else if (sub_op == 11) { // memory.fill
                        _ = body.code[pc];
                        pc += 1;
                        const n: usize = @intCast(@as(u32, @bitCast(stack.pop().?.i32)));
                        const val: u8 = @truncate(@as(u32, @bitCast(stack.pop().?.i32)));
                        const dst: usize = @intCast(@as(u32, @bitCast(stack.pop().?.i32)));
                        @memset(self.memory[dst .. dst + n], val);
                    } else {
                        self.last_unsupported_opcode = 0xfc;
                        self.last_unsupported_sub_opcode = sub_op;
                        std.debug.print("[WASM VM] Unsupported 0xfc sub-opcode: 0x{x} in func={d}\n", .{ sub_op, func_idx });
                        return error.UnsupportedBulkMemoryOp;
                    }
                },
                else => {
                    self.last_unsupported_opcode = op;
                    self.last_unsupported_sub_opcode = null;
                    std.debug.print("[WASM VM] Unsupported opcode: 0x{x} at pc={d} in func={d}\n", .{ op, pc - 1, func_idx });
                    return error.UnsupportedWasmOpcode;
                },
            }
        }

        if (ftype.results.len > 0 and stack.items.len > 0) {
            return stack.pop().?;
        }
        return null;
    }

    pub fn readSnapshot(self: *const WasmInstance, ptr: i32) !WasmPhysicsSnapshot {
        const offset: usize = @intCast(@as(u32, @bitCast(ptr)));
        if (offset + @sizeOf(WasmPhysicsSnapshot) > self.memory.len) {
            return error.SnapshotOutOfBounds;
        }
        const snap_ptr: *const WasmPhysicsSnapshot = @ptrCast(@alignCast(self.memory.ptr + offset));
        return snap_ptr.*;
    }
};

pub fn runTenStepSimulationTest(allocator: std.mem.Allocator, wasm_bytes: []const u8) !SimulationRunResult {
    var vm = try WasmInstance.init(allocator, wasm_bytes);
    defer vm.deinit();

    var x: f64 = 100.0;
    var y: f64 = 100.0;
    var vx: f64 = 5.0;
    var vy: f64 = 0.0;
    var cols: i32 = 0;

    var steps: [10]WasmPhysicsSnapshot = undefined;

    for (0..10) |i| {
        const step_args = [_]Val{
            .{ .f64 = x },
            .{ .f64 = y },
            .{ .f64 = vx },
            .{ .f64 = vy },
            .{ .f64 = 15.0 },
            .{ .f64 = 1.0 },
            .{ .f64 = 0.5 },
            .{ .f64 = 0.98 },
            .{ .f64 = 0.8 },
            .{ .f64 = 500.0 },
            .{ .f64 = 300.0 },
            .{ .i32 = cols },
        };
        _ = vm.callExport("stepSimulation", &step_args) catch {
            return .{
                .passed = false,
                .steps = steps,
                .unsupported_opcode = vm.last_unsupported_opcode,
                .unsupported_sub_opcode = vm.last_unsupported_sub_opcode,
            };
        };
        const ptr_val = (try vm.callExport("getStatePtr", &.{})).?.i32;
        const off: usize = @intCast(@as(u32, @bitCast(ptr_val)));
        const preview_end = @min(off + 16, vm.memory.len);
        std.debug.print(
            "[WASM VM] step={d} ptr={d} mem_len={d} first16={x}\n",
            .{ i + 1, ptr_val, vm.memory.len, vm.memory[off..preview_end] },
        );
        const snap = try vm.readSnapshot(ptr_val);
        steps[i] = snap;

        x = snap.x;
        y = snap.y;
        vx = snap.vx;
        vy = snap.vy;
        cols = snap.collision_count;
    }

    const s1 = steps[0];
    const s10 = steps[9];

    const passed =
        @abs(s1.x - 105.0) < 1e-9 and
        @abs(s1.y - 100.5) < 1e-9 and
        @abs(s1.vy - 0.5) < 1e-9 and
        @abs(s10.x - 150.0) < 1e-9 and
        @abs(s10.y - 127.5) < 1e-9 and
        @abs(s10.vx - 5.0) < 1e-9 and
        @abs(s10.vy - 5.0) < 1e-9 and
        @abs(s10.kinetic_energy - 25.0) < 1e-9 and
        @abs(s10.potential_energy - 86.25) < 1e-9 and
        @abs(s10.total_energy - 111.25) < 1e-9 and
        s10.collision_count == 0 and
        s10.stopped == 0;

    return .{ .passed = passed, .steps = steps };
}
