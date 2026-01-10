const std = @import("std");
const tokamak = @import("tokamak");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "use-llvm", "Use LLVM for compiling") orelse (optimize != .Debug);

    const frontend_step = compileFrontend(b, optimize, use_llvm);
    const backend_step, const backend_exe = compileBackend(b, target, optimize, use_llvm);
    backend_step.dependOn(frontend_step);

    b.getInstallStep().dependOn(backend_step);

    // 'run' step
    const run_cmd = b.addRunArtifact(backend_exe);
    run_cmd.setCwd(.{ .cwd_relative = b.getInstallPath(.prefix, "") });
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // 'check' step
    const exe_check = b.addExecutable(.{
        .name = "filisur-archive",
        .root_module = backend_exe.root_module,
    });

    const check = b.step("check", "Check for compilation errors");
    check.dependOn(&exe_check.step);
}

fn compileFrontend(b: *std.Build, optimize: std.builtin.OptimizeMode, use_llvm: bool) *std.Build.Step {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .web });

    const common_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("common/lib.zig"),
        .link_libc = false,
        .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
    });
    const frontend_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("frontend/main.zig"),
        .imports = &.{
            .{ .name = "common", .module = common_module },
            .{ .name = "dvui", .module = dvui_dep.module("dvui_web") },
        },
        .link_libc = false,
        .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
    });

    const wasm_exe = b.addExecutable(.{
        .name = "web",
        .root_module = frontend_module,
    });
    wasm_exe.entry = .disabled;
    // Self-hosted backend doesn't fully support WASM yet
    _ = use_llvm; // autofix
    // exe.use_llvm = use_llvm;
    // exe.use_lld = use_llvm;

    const install_dir: std.Build.InstallDir = .{ .custom = "dist" };
    const install_wasm = b.addInstallArtifact(wasm_exe, .{ .dest_dir = .{ .override = install_dir } });

    // Hash files to invalidate browser cache
    const cb = b.addExecutable(.{
        .name = "cacheBuster",
        .root_module = b.createModule(.{
            .root_source_file = dvui_dep.path("src/cacheBuster.zig"),
            .target = b.graph.host,
        }),
    });
    const cb_run = b.addRunArtifact(cb);
    cb_run.addFileArg(b.path("frontend/index.html"));
    cb_run.addFileArg(b.path("frontend/video.js"));
    cb_run.addFileArg(dvui_dep.path("src/backends/web.js"));
    cb_run.addFileArg(wasm_exe.getEmittedBin());
    const output = cb_run.captureStdOut();

    const install_noto = b.addInstallFileWithDir(dvui_dep.path("src/fonts/NotoSansKR-Regular.ttf"), install_dir, "NotoSansKR-Regular.ttf");

    const compile_step = b.step("frontend", "Compile frontend");

    compile_step.dependOn(&b.addInstallFileWithDir(output, install_dir, "index.html").step);
    compile_step.dependOn(&b.addInstallFileWithDir(dvui_dep.namedLazyPath("web.js"), install_dir, "web.js").step);
    compile_step.dependOn(&b.addInstallFileWithDir(b.path("frontend/video.js"), install_dir, "video.js").step);
    compile_step.dependOn(&b.addInstallFileWithDir(b.path("frontend/meta.js"), install_dir, "meta.js").step);

    compile_step.dependOn(&install_wasm.step);
    compile_step.dependOn(&install_noto.step);

    return compile_step;
}
fn compileBackend(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, use_llvm: bool) struct { *std.Build.Step, *std.Build.Step.Compile } {
    const tokamak_dep = b.dependency("tokamak", .{ .target = target, .optimize = optimize });
    const httpz_dep = tokamak_dep.builder.dependency("httpz", .{ .target = target, .optimize = optimize });
    const dotenv_dep = b.dependency("dotenv", .{ .target = target, .optimize = optimize });

    const common_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("common/lib.zig"),
        .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
    });
    const backend_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("backend/main.zig"),
        .imports = &.{
            .{ .name = "common", .module = common_module },
            .{ .name = "tokamak", .module = tokamak_dep.module("tokamak") },
            .{ .name = "httpz", .module = httpz_dep.module("httpz") },
            .{ .name = "dotenv", .module = dotenv_dep.module("dotenv") },
        },
        .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
    });

    const exe = b.addExecutable(.{
        .name = "filisur-archive",
        .root_module = backend_module,
    });
    exe.use_llvm = use_llvm;
    exe.use_lld = use_llvm;

    const install_dir: std.Build.InstallDir = .prefix;
    const install_exe = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = install_dir } });

    const compile_step = b.step("backend", "Compile backend");
    compile_step.dependOn(&install_exe.step);

    compile_step.dependOn(&b.addInstallFileWithDir(b.path(".env"), install_dir, ".env").step);

    return .{ compile_step, exe };
}
