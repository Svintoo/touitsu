const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag != .windows or target.result.cpu.arch != .x86_64)
        std.debug.panic("Touitsu requires an x86_64 Windows UI target; the x86 hooking backend is built automatically.", .{});

    const knots = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
    });

    // SQLite is bundled so dictionary lookup needs no separately installed runtime.
    const sqlite = b.addLibrary(.{
        .name = "touitsu_sqlite",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true }),
    });
    sqlite.root_module.addCSourceFile(.{
        .file = b.path("src/third_party/sqlite/sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0" },
    });
    const dictionary_tests = b.addTest(.{
        .name = "dictionary_tests",
        .root_module = componentModule(b, "components/dictionaries/dictionary.zig", .tests, .{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    dictionary_tests.root_module.addIncludePath(b.path("src/third_party/sqlite"));
    dictionary_tests.root_module.linkLibrary(sqlite);
    b.step("test-dictionary", "Test native dictionary import and lookup").dependOn(&b.addRunArtifact(dictionary_tests).step);

    const selection_tests = b.addTest(.{
        .name = "selection_tests",
        .root_module = componentModule(b, "components/reader/shift_selection.zig", .tests, .{
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ui", .module = knots.module("ui") }},
        }),
    });
    b.step("test-selection", "Test Shift selection gestures and glyph hit testing").dependOn(&b.addRunArtifact(selection_tests).step);

    const image_decoder = b.addLibrary(.{
        .name = "touitsu_images",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true }),
    });
    image_decoder.root_module.addCSourceFile(.{ .file = b.path("src/native/image_decode.cpp"), .flags = &.{"-std=c++17"} });
    image_decoder.root_module.linkSystemLibrary("ole32", .{});
    image_decoder.root_module.linkSystemLibrary("d2d1", .{});
    image_decoder.root_module.linkSystemLibrary("d3d11", .{});
    const anki_http = b.addLibrary(.{
        .name = "touitsu_anki_http",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true }),
    });
    anki_http.root_module.addCSourceFile(.{ .file = b.path("src/native/anki_http.cpp"), .flags = &.{"-std=c++17"} });
    anki_http.root_module.addCSourceFile(.{ .file = b.path("src/native/pronunciation.cpp"), .flags = &.{"-std=c++17"} });
    anki_http.root_module.linkSystemLibrary("winhttp", .{});
    anki_http.root_module.linkSystemLibrary("winmm", .{});
    const pronunciation_smoke = b.addExecutable(.{
        .name = "pronunciation_smoke",
        .root_module = componentModule(b, "checks/pronunciation_smoke.zig", .check, .{ .target = target, .optimize = optimize }),
    });
    pronunciation_smoke.root_module.linkLibrary(anki_http);
    b.step("check-pronunciation", "Fetch sample JapanesePod101 and Jisho MP3s without playing audio").dependOn(&b.addRunArtifact(pronunciation_smoke).step);
    const pronunciation_tests = b.addTest(.{
        .name = "pronunciation_tests",
        .root_module = componentModule(b, "components/pronunciation/audio_sources.zig", .tests, .{ .target = target, .optimize = optimize }),
    });
    b.step("test-pronunciation", "Test pronunciation source selection, validation, and fallback offline").dependOn(&b.addRunArtifact(pronunciation_tests).step);
    const anki_tests = b.addTest(.{
        .name = "anki_tests",
        .root_module = componentModule(b, "components/anki/anki_connect.zig", .tests, .{ .target = target, .optimize = optimize }),
    });
    anki_tests.root_module.linkLibrary(anki_http);
    b.step("test-anki", "Test Anki card mapping and protocol responses").dependOn(&b.addRunArtifact(anki_tests).step);
    const anki_settings_tests = b.addTest(.{
        .name = "anki_settings_tests",
        .root_module = componentModule(b, "components/anki/anki_settings.zig", .tests, .{
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ui", .module = knots.module("ui") }},
        }),
    });
    anki_settings_tests.root_module.linkLibrary(anki_http);
    anki_settings_tests.root_module.linkLibrary(sqlite);
    b.top_level_steps.get("test-anki").?.step.dependOn(&b.addRunArtifact(anki_settings_tests).step);
    const anki_smoke = b.addExecutable(.{
        .name = "anki_smoke",
        .root_module = componentModule(b, "checks/anki_smoke.zig", .check, .{ .target = target, .optimize = optimize }),
    });
    anki_smoke.root_module.linkLibrary(anki_http);
    const mock = b.addSystemCommand(&.{ "python", "src/testdata/anki_mock.py" });
    mock.addArtifactArg(anki_smoke);
    b.step("test-anki-http", "Test native HTTP card creation against an isolated mock AnkiConnect").dependOn(&mock.step);
    const dictionary_import_smoke = b.addExecutable(.{
        .name = "dictionary_import_smoke",
        .root_module = componentModule(b, "checks/dictionary_import_smoke.zig", .check, .{ .target = target, .optimize = optimize }),
    });
    dictionary_import_smoke.root_module.linkLibrary(sqlite);
    dictionary_import_smoke.root_module.linkLibrary(image_decoder);
    const run_dictionary_import = b.addRunArtifact(dictionary_import_smoke);
    run_dictionary_import.addPassthruArgs();
    b.step("check-dictionary-import", "Import ZIPs and decode assets in an explicitly specified verification database").dependOn(&run_dictionary_import.step);

    const image_tests = b.addTest(.{
        .name = "image_tests",
        .root_module = componentModule(b, "platform/image_decode.zig", .tests, .{ .target = target, .optimize = optimize }),
    });
    image_tests.root_module.linkLibrary(image_decoder);
    b.step("test-image", "Test native background image decoding").dependOn(&b.addRunArtifact(image_tests).step);

    const reading_tests = b.addTest(.{
        .name = "reading_tests",
        .root_module = componentModule(b, "components/reader/reading_layout.zig", .tests, .{ .target = target, .optimize = optimize }),
    });
    b.step("test-reading", "Test vertical UTF-8 layout and reading-axis scrolling").dependOn(&b.addRunArtifact(reading_tests).step);

    // A 64-bit UI keeps the native host in-process and delegates x86 to a helper.
    const shim = addShim(b, target, optimize);
    b.getInstallStep().dependOn(&b.addInstallArtifact(shim, .{ .implib_dir = .disabled, .pdb_dir = if (optimize == .debug) .default else .disabled }).step);
    const x86_target = b.resolveTargetQuery(.{ .cpu_arch = .x86, .os_tag = .windows, .abi = .gnu });
    const shim32 = addShim(b, x86_target, optimize);
    b.getInstallStep().dependOn(&b.addInstallArtifact(shim32, .{ .dest_sub_path = "x86/tx_shim.dll", .implib_dir = .disabled, .pdb_dir = .disabled }).step);
    const helper = b.addExecutable(.{ .name = "tx_helper", .root_module = b.createModule(.{ .target = x86_target, .optimize = optimize, .link_libc = true, .link_libcpp = true }) });
    helper.root_module.addCSourceFile(.{ .file = b.path("src/native/tx_helper.cpp"), .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE" } });
    helper.root_module.linkLibrary(shim32);
    helper.root_module.linkSystemLibrary("shell32", .{});
    b.getInstallStep().dependOn(&b.addInstallArtifact(helper, .{ .dest_sub_path = "x86/tx_helper.exe", .pdb_dir = .disabled }).step);

    // Build the injected DLLs with search lifetime fixes and private pipe names.
    inline for (.{ .{ "x64", "libs/texthook.dll", "texthook.dll" }, .{ "x86", "libs/texthook-x86.dll", "x86/texthook.dll" } }) |hook| {
        const patch = b.addSystemCommand(&.{ "python", "scripts/build_texthook.py", hook[0] });
        // CMake/Ninja track all upstream source/header dependencies. Consult them
        // on every install so a submodule update cannot reuse a stale injected DLL.
        patch.has_side_effects = true;
        const staged = patch.addOutputDirectoryArg("hook-backend");
        patch.addFileInput(b.path("src/native/tx_hookfinder.cpp"));
        patch.addFileInput(b.path("src/native/tx_hook_prefix.h"));
        patch.addFileInput(b.path("src/native/tx_pipe_names.h"));
        patch.addFileInput(b.path("src/native/hook_backend/CMakeLists.txt"));
        patch.addFileInput(b.path("scripts/build_texthook.py"));
        patch.addFileInput(b.path("src/third_party/Textractor/texthook/minhook/src/hook.c"));
        b.getInstallStep().dependOn(&b.addInstallBinFile(staged.path(b, "texthook.dll"), hook[2]).step);
    }

    const check_backends = b.step("test-backends", "Test concurrent x86/x64 injection and helper recovery using owned fixture processes");
    const dual_test = b.addExecutable(.{ .name = "tx_dual_test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true }) });
    dual_test.root_module.addCSourceFile(.{ .file = b.path("src/native/tx_dual_test.cpp"), .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE" } });
    dual_test.root_module.linkLibrary(shim);
    dual_test.root_module.linkSystemLibrary("shell32", .{});
    const install_dual_test = b.addInstallArtifact(dual_test, .{ .pdb_dir = if (optimize == .debug) .default else .disabled });
    const run_dual_test = b.addRunFile(.{ .relative = .{ .base = .install_bin, .sub_path = "tx_dual_test.exe" } });
    run_dual_test.step.dependOn(&install_dual_test.step);
    run_dual_test.step.dependOn(b.getInstallStep());
    inline for (.{ .{ "tx_fixture_x86", x86_target }, .{ "tx_fixture_x64", target } }) |fixture_info| {
        const fixture = b.addExecutable(.{ .name = fixture_info[0], .root_module = b.createModule(.{ .target = fixture_info[1], .optimize = optimize, .link_libc = true, .link_libcpp = true }) });
        fixture.root_module.addCSourceFile(.{ .file = b.path("src/native/tx_fixture.cpp"), .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE" } });
        const install_fixture = b.addInstallArtifact(fixture, .{ .dest_sub_path = "test-fixtures/" ++ fixture_info[0] ++ ".exe", .pdb_dir = if (optimize == .debug) .default else .disabled });
        run_dual_test.step.dependOn(&install_fixture.step);
        run_dual_test.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "test-fixtures/" ++ fixture_info[0] ++ ".exe" } });
    }
    check_backends.dependOn(&run_dual_test.step);

    b.getInstallStep().dependOn(&b.addInstallBinFile(b.path("src/third_party/Textractor/LICENSE"), "licenses/Textractor-LICENSE.txt").step);

    // // ---- console smoke test: zig build, then run zig-out\bin\tx_test.exe ----
    // const tx_test = b.addExecutable(.{
    //     .name = "tx_test",
    //     .root_module = componentModule(b, "checks/tx_test.zig", .check, .{
    //         .target = target,
    //         .optimize = optimize,
    //     }),
    // });
    // tx_test.root_module.linkLibrary(shim);
    // b.getInstallStep().dependOn(&b.addInstallArtifact(tx_test, .{ .pdb_dir = if (optimize == .debug) .default else .disabled }).step);

    // ---- your app ----
    const exe = b.addExecutable(.{
        .name = "Touitsu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "knots", .module = knots.module("knots") },
                .{ .name = "ui", .module = knots.module("ui") },
            },
        }),
    });
    // Stage both inputs together so ICO changes invalidate the resource cache,
    // including release artifacts built before the icon was replaced.
    const icon_resources = b.addWriteFiles();
    const icon_rc = icon_resources.addCopyFile(b.path("src/native/touitsu.rc"), "touitsu2.rc");
    _ = icon_resources.addCopyFile(b.path("src/icons/touitsu2.ico"), "touitsu2.ico");
    exe.root_module.addWin32ResourceFile(.{
        .file = icon_rc,
        .include_paths = &.{icon_resources.getDirectory()},
    });
    if (optimize != .debug) exe.subsystem = .windows;
    // Link the artifact directly (don't use linkSystemLibrary for it): Zig wires up the
    // import lib and build order for you.
    exe.root_module.linkLibrary(shim);
    exe.root_module.linkLibrary(sqlite);
    exe.root_module.linkLibrary(image_decoder);
    exe.root_module.linkLibrary(anki_http);
    exe.root_module.linkSystemLibrary("comctl32", .{});
    const window_check = b.addSystemCommand(&.{ "python", "scripts/test_window.py" });
    window_check.addArtifactArg(exe);
    window_check.addArtifactArg(shim);
    b.step("test-window", "Test real window icons, minimize/restore, and maximize using a disposable install").dependOn(&window_check.step);
    exe.root_module.addIncludePath(b.path("src/third_party/sqlite"));
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{ .pdb_dir = if (optimize == .debug) .default else .disabled }).step);

    const hook_preview_test = b.addTest(.{
        .name = "hook_preview_test",
        .root_module = exe.root_module,
        .filters = &.{"hook history preview"},
    });
    b.step("test-hook-preview", "Render hook history and growing reader state in all reading directions").dependOn(&b.addRunArtifact(hook_preview_test).step);

    const tests = b.addTest(.{
        .name = "touitsu_tests",
        .root_module = exe.root_module,
    });
    b.step("test", "Run all unit and UI interaction tests").dependOn(&b.addRunArtifact(tests).step);

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("src/fonts/jp.ttf"), .bin, "fonts/jp.ttf").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("docs/dicts-folder.txt"), .bin, "dicts/README.txt").step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the app").dependOn(&run_cmd.step);
}

// Component tests and checks share src as their import root, so they can use
// sibling components and bundled test assets just like the application does.
fn componentModule(
    b: *std.Build,
    source: []const u8,
    kind: enum { tests, check },
    options: std.Build.Module.CreateOptions,
) *std.Build.Module {
    var config = options;
    config.root_source_file = b.path(switch (kind) {
        .tests => "src/tests.zig",
        .check => "src/check.zig",
    });
    const module = b.createModule(config);
    const entrypoint = b.addOptions();
    entrypoint.addOption([]const u8, "source", source);
    module.addOptions("entrypoint", entrypoint);
    return module;
}

fn addShim(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const tx_root = "src/third_party/Textractor";

    const shim_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    // Stand-ins for MSVC-only headers (e.g. <concrt.h>). Must come first.
    shim_mod.addIncludePath(b.path("src/native/compat"));
    shim_mod.addIncludePath(b.path(tx_root ++ "/include"));
    shim_mod.addIncludePath(b.path(tx_root ++ "/host"));
    shim_mod.addIncludePath(b.path(tx_root));

    // Textractor force-includes a precompiled header into every file (CMake `pch` target).
    // Emulate that with clang's -include. Zig opens this path itself for cache tracking,
    // relative to the build root, so it must be a root-relative path (not a bare name).
    // If more headers are needed, add more "-include", tx_root ++ "/include/<name>.h" pairs.
    const flags = [_][]const u8{
        "-std=c++17",
        "-DUNICODE",
        "-DTX_SHIM_BUILD",
        "-DTOUITSU_PRIVATE_PIPES",
        "-D_UNICODE",
        "-DVERSION=\"embedded\"",
        "-DENGLISH", // text.cpp language selector
        "-fms-extensions",
        "-fno-sanitize=undefined", // Zig enables UBSan in Debug; noisy/unsafe for this code
        "-Wno-unused-command-line-argument",
        // Order matters: the prefix must come before common.h (which pulls in <Windows.h>).
        "-include",
        "src/native/compat/tx_prefix.h",
        "-include",
        tx_root ++ "/include/common.h",
    };

    // MSVC implicitly adapts Win32 lambdas to stdcall. Clang needs it explicit
    // on x86; stage the two small compatibility edits without changing vendor code.
    if (target.result.cpu.arch == .x86) {
        const patches = b.addWriteFiles();
        const host = std.mem.replaceOwned(u8, b.allocator, @embedFile("src/third_party/Textractor/host/host.cpp"), "[](int statusCode, WPARAM wParam, LPARAM lParam)", "[](int statusCode, WPARAM wParam, LPARAM lParam) __attribute__((stdcall))") catch @panic("OOM");
        const thread = std.mem.replaceOwned(u8, b.allocator, @embedFile("src/third_party/Textractor/host/textthread.cpp"), "[](void* This, auto)", "[](void* This, BOOLEAN) __attribute__((stdcall))") catch @panic("OOM");
        shim_mod.addCSourceFile(.{ .file = patches.add("host.cpp", host), .flags = &flags });
        shim_mod.addCSourceFile(.{ .file = patches.add("textthread.cpp", thread), .flags = &flags });
    } else {
        shim_mod.addCSourceFiles(.{ .root = b.path(tx_root), .files = &.{ "host/host.cpp", "host/textthread.cpp" }, .flags = &flags });
    }
    shim_mod.addCSourceFiles(.{ .root = b.path(tx_root), .files = &.{ "host/hookcode.cpp", "text.cpp" }, .flags = &flags });
    shim_mod.addCSourceFiles(.{
        .root = b.path("src/native"),
        .files = &.{ "tx_shim.cpp", "tx_find.cpp" },
        .flags = &flags,
    });

    if (target.result.cpu.arch == .x86_64) shim_mod.addCSourceFile(.{ .file = b.path("src/native/tx_bridge.cpp"), .flags = &flags });

    // MSVC's `#pragma comment(lib, ...)` is ignored by clang/MinGW, so list libs explicitly.
    // Add/remove based on linker errors.
    for ([_][]const u8{ "kernel32", "user32", "shell32", "shlwapi", "psapi", "advapi32", "ole32" }) |l| {
        shim_mod.linkSystemLibrary(l, .{});
    }

    const shim = b.addLibrary(.{
        .name = "tx_shim",
        .linkage = .dynamic,
        .root_module = shim_mod,
    });
    return shim;
}
