const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) !void {
    // Get standard options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Set up project build options
    const xwayland = b.option(bool, "xwayland", "Build with Xwayland support") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "xwayland", xwayland);

    const c = b.addTranslateC(.{
        .root_source_file = b.path("c.h"),
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

    // From wlroots
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 9);
    scanner.generate("zwp_tablet_manager_v2", 1);

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

    // C interop
    const c_step = b.addTranslateC(.{
        .root_source_file = b.path("c.h"),
        .target = target,
        .optimize = optimize,
    });
    try c_step.include_dirs.append(.{ .path_system = .{ .src_path = .{
        .owner = b,
        .sub_path = "/usr/include/wlroots-0.19",
    }}});
    try c_step.include_dirs.append(.{ .path_system = .{ .src_path = .{
        .owner = b,
        .sub_path = "/usr/include/pixman-1",
    }}});
    c_step.defineCMacro("WLR_USE_UNSTABLE", "");

    // Main executable module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("dwl.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addIncludePath(b.path("."));

    // Imports
    exe_mod.addOptions("build_options", options);
    exe_mod.addImport("C", c_step.createModule());
    exe_mod.addImport("flags", flags);
    exe_mod.addImport("wlroots", wlroots);
    exe_mod.addImport("wayland", wayland);
    exe_mod.addImport("C", c.createModule());

    // C sources
    exe_mod.addCSourceFiles(.{ .files = &.{
        "dwl.c",
        "util.c",
    }});
    exe_mod.addCMacro("WLR_USE_UNSTABLE", "");
    exe_mod.addCMacro("VERSION", "\"0.8-dev\"");
    if (xwayland) exe_mod.addCMacro("XWAYLAND", "1");

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
    });

    exe.linkSystemLibrary("wayland-server");
    exe.linkSystemLibrary("xkbcommon");
    exe.linkSystemLibrary("libinput");
    exe.linkSystemLibrary("wlroots-0.19");
    if (xwayland) {
        exe.linkSystemLibrary("xcb");
        exe.linkSystemLibrary("xcb-icccm");
    }
    exe.linkLibC();

    b.installArtifact(exe);
}
