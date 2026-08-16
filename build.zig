const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // @cImport is deprecated in 0.16; C translation belongs to the build system.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("core/src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("sqlite3", .{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("core/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = translate_c.createModule() }},
    });
    exe_mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{ .name = "ffpw-probe", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the validation probe").dependOn(&run.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("core/src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = translate_c.createModule() }},
    });
    test_mod.linkSystemLibrary("sqlite3", .{});
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run the core tests").dependOn(&b.addRunArtifact(tests).step);

    // TUI. core/src/root.zig is the module boundary a front end imports
    // through; a relative import cannot cross from tui/src into core/src.
    const core_mod = b.createModule(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = translate_c.createModule() }},
    });
    core_mod.linkSystemLibrary("sqlite3", .{});

    const vaxis_dep = b.dependency("libvaxis", .{ .target = target, .optimize = optimize });

    const tui_mod = b.createModule(.{
        .root_source_file = b.path("tui/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
        },
    });

    const tui_exe = b.addExecutable(.{ .name = "ffpw", .root_module = tui_mod });
    b.installArtifact(tui_exe);

    const run_tui = b.addRunArtifact(tui_exe);
    run_tui.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tui.addArgs(args);
    b.step("tui", "Run the TUI").dependOn(&run_tui.step);

    // C ABI static library. Built for aarch64-macos, the only target this
    // project supports; a universal binary earns its lipo step only once a
    // second architecture is in scope, and none is yet. It shares `target`
    // with everything else above rather than resolving its own target query,
    // because an explicit query (even one matching the host) skips the
    // native-SDK auto-detection standardTargetOptions gets, and sqlite3
    // fails to link without it.
    const lib_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("core/src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    lib_translate_c.linkSystemLibrary("sqlite3", .{});

    const core_lib_mod = b.createModule(.{
        .root_source_file = b.path("core/src/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = lib_translate_c.createModule() }},
    });
    core_lib_mod.linkSystemLibrary("sqlite3", .{});

    const core_lib = b.addLibrary(.{
        .name = "ffpw",
        .root_module = core_lib_mod,
        .linkage = .static,
    });
    core_lib.installHeader(b.path("core/include/ffpw.h"), "ffpw.h");
    b.installArtifact(core_lib);

    // C smoke test, exercising the static library the way Swift will.
    const smoke_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_mod.addCSourceFile(.{ .file = b.path("core/test/smoke.c") });
    smoke_mod.addIncludePath(b.path("core/include"));
    smoke_mod.linkLibrary(core_lib);
    smoke_mod.linkSystemLibrary("sqlite3", .{});
    const smoke = b.addExecutable(.{ .name = "ffpw-smoke", .root_module = smoke_mod });
    b.installArtifact(smoke);

    const run_smoke = b.addRunArtifact(smoke);
    run_smoke.step.dependOn(b.getInstallStep());
    b.step("smoke", "Run the C ABI smoke test").dependOn(&run_smoke.step);
}
