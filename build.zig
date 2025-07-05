const std = @import("std");

pub fn build(b: *std.Build) void {
    // Get standard options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Set up project build options
    const xwayland = b.option(bool, "xwayland", "Build with Xwayland support") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "xwayland", xwayland);

    // Dependencies
    const flags = b.dependency("flags", .{}).module("flags");

    // Main executable module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("dwl.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Imports
    exe_mod.addOptions("build_options", options);
    exe_mod.addImport("flags", flags);

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
