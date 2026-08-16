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
}
