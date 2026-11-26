const math_engine = @import("math_engine.zig");

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

var state_snapshot: WasmPhysicsSnapshot = .{
    .x = 0.0,
    .y = 0.0,
    .vx = 0.0,
    .vy = 0.0,
    .speed = 0.0,
    .kinetic_energy = 0.0,
    .potential_energy = 0.0,
    .total_energy = 0.0,
    .momentum = 0.0,
    .collision_count = 0,
    .stopped = 0,
};

fn storeResult(res: math_engine.PhysicsResult) void {
    state_snapshot = .{
        .x = res.x,
        .y = res.y,
        .vx = res.vx,
        .vy = res.vy,
        .speed = res.speed,
        .kinetic_energy = res.kinetic_energy,
        .potential_energy = res.potential_energy,
        .total_energy = res.total_energy,
        .momentum = res.momentum,
        .collision_count = res.collision_count,
        .stopped = if (res.stopped) 1 else 0,
    };
}

export fn getStatePtr() [*]const u8 {
    return @ptrCast(&state_snapshot);
}

export fn computeMetrics(
    vx: f64,
    vy: f64,
    mass: f64,
    gravity: f64,
    height: f64,
) void {
    const res = math_engine.MathEngine.computeMetrics(.{
        .vx = vx,
        .vy = vy,
        .mass = mass,
        .gravity = gravity,
        .height = height,
    });
    storeResult(res);
}

export fn stepSimulation(
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    radius: f64,
    mass: f64,
    gravity: f64,
    friction: f64,
    restitution: f64,
    canvas_width: f64,
    canvas_height: f64,
    collision_count: i32,
) void {
    const res = math_engine.MathEngine.stepSimulation(.{
        .x = x,
        .y = y,
        .vx = vx,
        .vy = vy,
        .radius = radius,
        .mass = mass,
        .gravity = gravity,
        .friction = friction,
        .restitution = restitution,
        .canvas_width = canvas_width,
        .canvas_height = canvas_height,
        .collision_count = collision_count,
    });
    storeResult(res);
}
