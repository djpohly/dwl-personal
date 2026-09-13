const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) !void {
    const io = b.graph.io;

    // Get standard options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create config.h if needed
    const cwd: std.Io.Dir = .cwd();
    if (cwd.access(io, "config.h", .{})) {} else |err| switch (err) {
        error.FileNotFound => {
            try cwd.copyFile("config.def.h", cwd, "config.h", io, .{});
        },
        else => {
            return err;
        },
    }

    // Compile needs from the C library
    const c = b.addTranslateC(.{
        .root_source_file = b.path("internal.h"),
        .target = target,
        .optimize = optimize,
    });
    c.addSystemIncludePath(b.path("."));
    c.addSystemIncludePath(.{
        .cwd_relative = "/usr/include/wlroots-0.19",
    });
    c.addSystemIncludePath(.{
        .cwd_relative = "/usr/include/pixman-1",
    });
    c.defineCMacro("WLR_USE_UNSTABLE", "");

    // Build Wayland protocols
    const scanner: *Scanner = .create(b, .{});
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addCustomProtocol(b.path("protocols/wlr-output-power-management-unstable-v1.xml"));
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");

    // From wlroots
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 9);
    scanner.generate("zwp_tablet_manager_v2", 1);
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("zwlr_output_power_manager_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zxdg_decoration_manager_v1", 1);
    scanner.generate("xdg_wm_base", 1);
    scanner.generate("zwp_pointer_constraints_v1", 1);
    scanner.generate("ext_session_lock_manager_v1", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    // Dependencies
    const flags = b.dependency("flags", .{
        .target = target,
        .optimize = optimize,
    }).module("flags");
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("pixman", .{}).module("pixman");
    const wlroots = b.dependency("wlroots", .{}).module("wlroots");
    wlroots.resolved_target = target;
    wlroots.linkSystemLibrary("wlroots-0.19", .{});
    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);

    // Main executable module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("dwl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addIncludePath(b.path("."));

    // Imports
    exe_mod.addImport("flags", flags);
    exe_mod.addImport("wlroots", wlroots);
    exe_mod.addImport("wayland", wayland);
    exe_mod.addImport("xkbcommon", xkbcommon);
    exe_mod.addImport("C", c.createModule());

    exe_mod.linkSystemLibrary("wayland-server", .{});
    exe_mod.linkSystemLibrary("xkbcommon", .{});
    exe_mod.linkSystemLibrary("libinput", .{});
    exe_mod.linkSystemLibrary("wlroots-0.19", .{});

    // C sources
    exe_mod.addCSourceFiles(.{ .files = &.{
        "dwl.c",
        "util.c",
    }});
    exe_mod.addCMacro("WLR_USE_UNSTABLE", "");
    exe_mod.addCMacro("VERSION", "\"0.8-dev\"");

    inline for (.{
        .{"enum-header", "/usr/share/wayland-protocols/staging/cursor-shape/cursor-shape-v1.xml", "cursor-shape-v1-protocol.h"},
	.{"enum-header", "/usr/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml", "pointer-constraints-unstable-v1-protocol.h"},
        .{"enum-header", "protocols/wlr-layer-shell-unstable-v1.xml", "wlr-layer-shell-unstable-v1-protocol.h"},
        .{"server-header", "protocols/wlr-output-power-management-unstable-v1.xml", "wlr-output-power-management-unstable-v1-protocol.h"},
        .{"server-header", "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml", "xdg-shell-protocol.h"},
    }) |params| {
        const cmd, const protocol, const header = params;
        const run_scanner = b.addSystemCommand(&.{"wayland-scanner", cmd, protocol});
        const output = run_scanner.addOutputFileArg(header);
        exe_mod.addIncludePath(output.dirname());
    }

    // Build and install executable
    const exe = b.addExecutable(.{
        .name = "dwl",
        .root_module = exe_mod,
        .use_llvm = true,
    });
    b.installArtifact(exe);

    // Enable ZLS quick-checking
    const check_step = b.step("check", "Check build quickly, without generating artifacts");
    const check = b.addExecutable(.{
        .name = exe.name,
        .root_module = exe.root_module,
    });
    check_step.dependOn(&check.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
