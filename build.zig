const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // b.standardTargetOptions resolves the target here, then the line
    // below pins its cpu to a baseline. standardTargetOptions runs the
    // native-SDK auto-detection for an empty query, and libc needs that
    // detection to link on macOS. An explicit default_target passed to it
    // skips the detection, and core_lib_mod below then fails to link.
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

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("core/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = translate_c.createModule() }},
    });

    const exe = b.addExecutable(.{ .name = "ffpw-probe", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the validation probe").dependOn(&run.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("core/src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run the core and TUI tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The oracle reads every fixture through core/src/sqlitedb.zig and again
    // through the system sqlite3, then compares the bytes. It links
    // libsqlite3 from the macOS SDK. The test binary runs on the host, so it
    // builds only when the target is the host and the host is macOS. The
    // Windows CI job passes -Doracle=false.
    const host_has_sqlite = builtin.os.tag == .macos and target.result.os.tag == builtin.os.tag;
    if (b.option(bool, "oracle", "Diff the SQLite reader against the system sqlite3") orelse host_has_sqlite) {
        const sqlite_c = b.addTranslateC(.{
            .root_source_file = b.path("core/test/sqlite.h"),
            .target = target,
            .optimize = optimize,
        });
        sqlite_c.linkSystemLibrary("sqlite3", .{});

        // A module rooted under core/test cannot import a file under
        // core/src by path, so the reader arrives as a named import.
        const oracle_mod = b.createModule(.{
            .root_source_file = b.path("core/test/oracle.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sqlite", .module = sqlite_c.createModule() },
                .{ .name = "sqlitedb", .module = b.createModule(.{
                    .root_source_file = b.path("core/src/sqlitedb.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        });
        oracle_mod.linkSystemLibrary("sqlite3", .{});
        const oracle = b.addTest(.{ .root_module = oracle_mod });
        test_step.dependOn(&b.addRunArtifact(oracle).step);
    }

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
    });

    const vaxis_dep = b.dependency("libvaxis", .{ .target = target, .optimize = optimize });

    const tui_mod = b.createModule(.{
        .root_source_file = b.path("tui/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
        },
    });

    // The TUI serves macOS and Linux. Windows gets the Win32 front end under
    // win/. tui/src/main.zig calls std.process.Args.Iterator.init, and that
    // function is a compile error on Windows. It also reads HOME and joins
    // the macOS profile path.
    const tui_exe = b.addExecutable(.{ .name = "ffpw", .root_module = tui_mod });
    if (target.result.os.tag != .windows) b.installArtifact(tui_exe);

    const run_tui = b.addRunArtifact(tui_exe);
    run_tui.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tui.addArgs(args);
    b.step("tui", "Run the TUI").dependOn(&run_tui.step);

    // The Windows front end's rules. win/src/model.zig imports core and std
    // only. This test runs on the host that builds the exe.
    const model_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("win/src/model.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core_mod }},
    }) });
    test_step.dependOn(&b.addRunArtifact(model_tests).step);

    // win/app.rc and win/src/ids.zig repeat the same resource ids. The test
    // in ids.zig reads win/src/resource.h and compares every value.
    const ids_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("win/src/ids.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(ids_tests).step);

    // The Win32 front end. It imports `core` directly, the way tui does. No
    // C ABI, no FFI, no libc.
    const win_mod = b.createModule(.{
        .root_source_file = b.path("win/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "args", .module = b.createModule(.{
                .root_source_file = b.path("tui/src/args.zig"),
                .target = target,
                .optimize = optimize,
            }) },
        },
    });
    for ([_][]const u8{ "user32", "comctl32", "gdi32", "dwmapi", "uxtheme", "advapi32" }) |lib| {
        win_mod.linkSystemLibrary(lib, .{});
    }
    // Zig bundles a .def file for each library above and generates the
    // import library from it, so this links with no Windows SDK.
    win_mod.addWin32ResourceFile(.{ .file = b.path("win/app.rc") });

    const win_exe = b.addExecutable(.{
        .name = "FirefoxPasswordView",
        .root_module = win_mod,
    });
    // The windows subsystem keeps a console window from opening behind the
    // app. Zig's WinStartup then calls `main` as declared in win/src/main.zig.
    win_exe.subsystem = .Windows;

    const win_step = b.step("win", "Build the Windows app");
    if (target.result.os.tag == .windows) {
        const install_win = b.addInstallArtifact(win_exe, .{});
        b.getInstallStep().dependOn(&install_win.step);
        win_step.dependOn(&install_win.step);
    } else {
        win_step.dependOn(&b.addFail(
            "the win step needs a Windows target, for example -Dtarget=aarch64-windows-gnu",
        ).step);
    }

    // C ABI static library. It shares `target` with everything else above,
    // so -Dtarget applies to it too. Releases ship a single aarch64-macos
    // slice, and no lipo step runs. core.zig calls c.getenv and allocates
    // through std.heap.c_allocator, and Swift links libc regardless.
    const core_lib_mod = b.createModule(.{
        .root_source_file = b.path("core/src/core.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = translate_c.createModule() }},
    });

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
    const smoke = b.addExecutable(.{ .name = "ffpw-smoke", .root_module = smoke_mod });
    b.installArtifact(smoke);

    const run_smoke = b.addRunArtifact(smoke);
    run_smoke.step.dependOn(b.getInstallStep());
    b.step("smoke", "Run the C ABI smoke test").dependOn(&run_smoke.step);
}
