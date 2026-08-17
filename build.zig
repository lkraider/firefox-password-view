const std = @import("std");

pub fn build(b: *std.Build) void {
    // b.standardTargetOptions resolves the target here, then the line
    // below pins its cpu to a baseline. standardTargetOptions runs the
    // native-SDK auto-detection for an empty query, and sqlite3 needs that
    // detection to link. An explicit default_target passed to it skips the
    // detection. core_lib_mod below hits the same link failure, for a
    // different reason.
    //
    // The baseline pin makes the binary reproducible across machines. A
    // "native" cpu resolves to the host's Apple Silicon generation, this
    // machine's M1 to apple_m1, and Zig picks its codegen from that.
    var target = b.standardTargetOptions(.{});
    target.result.cpu = std.Target.Cpu.baseline(target.result.cpu.arch, target.result.os);
    const optimize = b.standardOptimizeOption(.{});

    // Zig's macOS linker embeds an LC_UUID, and a code-signature hash that
    // covers it, derived from debug info that isn't otherwise deterministic.
    // Stripping removes that debug info, so two clean rebuilds of the same
    // source on the same machine produce identical bytes. Verified by
    // rebuilding ffpw twice and diffing. Zero bytes differ, and the output
    // filename matches. Debug keeps its symbols. That build exists for
    // debugging.
    const strip = optimize != .Debug;

    // @cImport is deprecated in 0.16. C translation belongs to the build system.
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
    const test_step = b.step("test", "Run the core and TUI tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The TUI's argument parser. The tui module would pull vaxis and
    // sqlite3 into the link. Rooting this at args.zig keeps both out.
    const args_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tui/src/args.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(args_tests).step);

    // TUI. core/src/root.zig is the module a front end imports
    // through. A relative import cannot cross from tui/src into core/src.
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
        .strip = strip,
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

    // C ABI static library. It shares `target` with everything else above,
    // so -Dtarget applies to it too. Releases ship a single aarch64-macos
    // slice, and no lipo step runs. Resolving a fresh target query here
    // would pass an explicit query, even one matching the host, and that
    // skips the native-SDK auto-detection sqlite3 needs to link.
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
        .strip = strip,
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
