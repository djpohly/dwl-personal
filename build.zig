const std = @import("std");
const Scanner = @import("zig-wayland").Scanner;

pub fn build(b: *std.Build) void {
    // Get standard options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Set up project build options
    const xwayland = b.option(bool, "xwayland", "Build with Xwayland support") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "xwayland", xwayland);

    // Build Wayland protocols
    // const scanner: *Scanner = .create(b, .{});
    // scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    // scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    // scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    // scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    // scanner.addCustomProtocol(b.path("protocols/wlr-output-power-management-unstable-v1.xml"));

    // scanner.generate("wl_compositor", 4);
    // scanner.generate("wl_subcompositor", 1);
    // scanner.generate("wl_shm", 2);
    // scanner.generate("wl_seat", 9);
    // scanner.generate("xdg_wm_base", 1);
    // scanner.generate("wp_cursor_shape_manager_v1", 1);
    //scanner.generate("zxdg_decoration_manager_v1", 1);
    //scanner.generate("zwp_pointer_gestures_v1", 3);
    //scanner.generate("wp_presentation", 1);
    //scanner.generate("zwp_tablet_manager_v2", 1);
    //scanner.generate("zwp_linux_dmabuf_v1", 4);
    //scanner.generate("zwp_relative_pointer_manager_v1", 1);
    //scanner.generate("wl_drm", 1);
    //scanner.generate("xdg_activation_v1", 1);
    //scanner.generate("wl_viewporter", 1);
    //scanner.generate("wp_linux_drm_syncobj_manager_v1", 1);

    // Build and install executable
    const exe = b.addExecutable(.{
        .name = "dwl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("dwl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    // exe.root_module.addImport("wayland", wayland);

    // C sources
    exe.addCSourceFile(.{ .file = b.path("dwl.c") });
    exe.addCSourceFile(.{ .file = b.path("util.c") });
    exe.root_module.addCMacro("WLR_USE_UNSTABLE", "");
    exe.root_module.addCMacro("VERSION", "\"0.8-dev\"");

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
        exe.addIncludePath(output.dirname());
    }

    exe.linkSystemLibrary("wayland-server");
    exe.linkSystemLibrary("xkbcommon");
    exe.linkSystemLibrary("libinput");
    exe.linkSystemLibrary("wlroots-0.19");
    if (xwayland) {
        exe.linkSystemLibrary("xwayland");
        exe.linkSystemLibrary("xcb");
    }
    exe.linkLibC();

    b.installArtifact(exe);
}
