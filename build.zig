const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("ZIG_DEMO_001", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "ZIG_DEMO_001",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ZIG_DEMO_001", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    // --- Freestanding WebAssembly collision engine (wasm32-freestanding) ---
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm_collision.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const wasm_exe = b.addExecutable(.{
        .name = "collision_engine",
        .root_module = wasm_mod,
    });

    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    const wasm_step = b.step("wasm", "Build freestanding WebAssembly collision engine");

    // 1. Install into zig-out/bin/collision_engine.wasm for local inspection/testing
    const install_wasm_bin = b.addInstallArtifact(wasm_exe, .{});
    wasm_step.dependOn(&install_wasm_bin.step);

    // 2. Copy directly into Angular's public/wasm folder so ng serve & ng build serve it locally
    const install_wasm_to_angular = b.addInstallFile(
        wasm_exe.getEmittedBin(),
        "../PWA_DEMO_ENV_PROD/public/wasm/collision_engine.wasm",
    );
    wasm_step.dependOn(&install_wasm_to_angular.step);

    // --- Run step ---
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // --- Test step ---
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
