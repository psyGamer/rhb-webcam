const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "use-llvm", "Use LLVM for compiling") orelse (optimize != .Debug);

    const frontend_step = compileFrontend(b, optimize, use_llvm);
    const backend_step = compileBackend(b, target, optimize, use_llvm);
    backend_step.dependOn(frontend_step);

    b.getInstallStep().dependOn(backend_step);
}

fn compileFrontend(b: *std.Build, optimize: std.builtin.OptimizeMode, use_llvm: bool) *std.Build.Step {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .web });

    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("frontend/main.zig"),
        .imports = &.{
            .{ .name = "dvui", .module = dvui_dep.module("dvui_web") },
            .{ .name = "web-backend", .module = dvui_dep.module("web") },
        },
        .link_libc = false,
        .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
    });

    const wasm_exe = b.addExecutable(.{
        .name = "web",
        .root_module = module,
    });
    wasm_exe.entry = .disabled;
    // Self-hosted backend doesn't fully support WASM yet
    _ = use_llvm; // autofix
    // exe.use_llvm = use_llvm;
    // exe.use_lld = use_llvm;

    const install_dir: std.Build.InstallDir = .{ .custom = "dist" };
    const install_wasm = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = install_dir },
    });

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
    const video_js = b.path("frontend/video.js");
    compile_step.dependOn(&b.addInstallFileWithDir(video_js, install_dir, "video.js").step);
    b.addNamedLazyPath("video.js", video_js);
    const web_js = dvui_dep.path("src/backends/web.js");
    compile_step.dependOn(&b.addInstallFileWithDir(web_js, install_dir, "web.js").step);
    b.addNamedLazyPath("web.js", web_js);
    compile_step.dependOn(&install_wasm.step);
    compile_step.dependOn(&install_noto.step);

    return compile_step;
}
fn compileBackend(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, use_llvm: bool) *std.Build.Step {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("backend/main.zig"),
        .imports = &.{},
        .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
    });

    const exe = b.addExecutable(.{
        .name = "filisur-archive",
        .root_module = module,
    });
    exe.use_llvm = use_llvm;
    exe.use_lld = use_llvm;

    const install_exe = b.addInstallArtifact(exe, .{});

    const compile_step = b.step("backend", "Compile backend");
    compile_step.dependOn(&install_exe.step);

    return compile_step;
}
