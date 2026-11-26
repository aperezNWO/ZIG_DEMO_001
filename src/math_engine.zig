const std = @import("std");

pub const MetricsInput = struct {
    vx: f64 = 5.0,
    vy: f64 = 0.0,
    mass: f64 = 1.0,
    gravity: f64 = 0.5,
    height: f64 = 200.0,
};

pub const StepInput = struct {
    x: f64 = 100.0,
    y: f64 = 100.0,
    vx: f64 = 5.0,
    vy: f64 = 0.0,
    radius: f64 = 15.0,
    mass: f64 = 1.0,
    gravity: f64 = 0.5,
    friction: f64 = 0.98,
    restitution: f64 = 0.8,
    canvas_width: f64 = 500.0,
    canvas_height: f64 = 300.0,
    collision_count: i32 = 0,
};

pub const PhysicsResult = struct {
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
    stopped: bool,
};

pub const MathEngine = struct {
    pub fn computeMetrics(input: MetricsInput) PhysicsResult {
        const speed = @sqrt(input.vx * input.vx + input.vy * input.vy);
        const ke = 0.5 * input.mass * speed * speed;
        const pe = input.mass * input.gravity * input.height;
        const total = ke + pe;
        const momentum = input.mass * speed;

        return .{
            .x = 0.0,
            .y = 0.0,
            .vx = input.vx,
            .vy = input.vy,
            .speed = speed,
            .kinetic_energy = ke,
            .potential_energy = pe,
            .total_energy = total,
            .momentum = momentum,
            .collision_count = 0,
            .stopped = @abs(input.vx) < 0.1 and @abs(input.vy) < 0.1,
        };
    }

    pub fn stepSimulation(input: StepInput) PhysicsResult {
        var next_vy = input.vy + input.gravity;
        var next_x = input.x + input.vx;
        var next_y = input.y + next_vy;
        var next_vx = input.vx;
        var next_collisions = input.collision_count;

        var horizontal_collision = false;
        var vertical_collision = false;

        if (next_x + input.radius > input.canvas_width) {
            next_x = input.canvas_width - input.radius;
            next_vx = -next_vx * input.restitution;
            if (@abs(next_vx) < 0.1) next_vx = 0.0;
            horizontal_collision = true;
        } else if (next_x - input.radius < 0.0) {
            next_x = input.radius;
            next_vx = -next_vx * input.restitution;
            if (@abs(next_vx) < 0.1) next_vx = 0.0;
            horizontal_collision = true;
        }

        if (next_y + input.radius > input.canvas_height) {
            next_y = input.canvas_height - input.radius;
            next_vy = -next_vy * input.restitution;
            next_vx *= input.friction;
            if (@abs(next_vy) < 0.1) next_vy = 0.0;
            vertical_collision = true;
        } else if (next_y - input.radius < 0.0) {
            next_y = input.radius;
            next_vy = -next_vy * input.restitution;
            if (@abs(next_vy) < 0.1) next_vy = 0.0;
            vertical_collision = true;
        }

        if (horizontal_collision or vertical_collision) {
            next_collisions += 1;
        }

        var stopped = false;
        if (@abs(next_vx) < 0.1 and @abs(next_vy) < 0.1) {
            next_vx = 0.0;
            next_vy = 0.0;
            stopped = true;
        }

        const height = input.canvas_height - next_y;
        const speed = @sqrt(next_vx * next_vx + next_vy * next_vy);
        const ke = 0.5 * input.mass * speed * speed;
        const pe = input.mass * input.gravity * height;
        const total = ke + pe;
        const momentum = input.mass * speed;

        return .{
            .x = next_x,
            .y = next_y,
            .vx = next_vx,
            .vy = next_vy,
            .speed = speed,
            .kinetic_energy = ke,
            .potential_energy = pe,
            .total_energy = total,
            .momentum = momentum,
            .collision_count = next_collisions,
            .stopped = stopped,
        };
    }

    pub fn toJson(allocator: std.mem.Allocator, res: PhysicsResult) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{{\"x\":{d},\"y\":{d},\"vx\":{d},\"vy\":{d},\"speed\":{d},\"kineticEnergy\":{d},\"potentialEnergy\":{d},\"totalEnergy\":{d},\"momentum\":{d},\"collisionCount\":{d},\"stopped\":{s}}}",
            .{
                res.x,
                res.y,
                res.vx,
                res.vy,
                res.speed,
                res.kinetic_energy,
                res.potential_energy,
                res.total_energy,
                res.momentum,
                res.collision_count,
                if (res.stopped) "true" else "false",
            },
        );
    }
};
