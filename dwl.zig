const std = @import("std");
const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const flags = @import("flags");
const C = @import("C");
const posix = std.posix;
const F = posix.F;
const SIG = posix.SIG;
const SA = posix.SA;
const O = std.os.linux.O;
const config = @import("config.zig");

var environ: std.process.EnvMap = undefined;
var child_proc: ?std.process.Child = null;

const Layer = enum {
    bg,
    bottom,
    tile,
    float,
    top,
    fs,
    overlay,
    block,
};

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    const options = flags.parseOrExit(args, "dwl", struct {
        @"startup-cmd": ?[:0]const u8 = null,
        debug: bool = false,
        version: bool = false,

        pub const switches = .{
            .@"startup-cmd" = 's',
            .debug = 'd',
            .version = 'v',
        };
    }, .{});

    if (std.c.getenv("XDG_RUNTIME_DIR") == null) die("XDG_RUNTIME_DIR must be set");

    environ = try std.process.getEnvMap(gpa.allocator());
    defer environ.deinit();

    try setup();
    try run(gpa.allocator(), options.@"startup-cmd");
    cleanup();
}

fn setup() !void {
    const sa: posix.Sigaction = .{
        .flags = SA.RESTART,
        .handler = .{ .handler = handlesig },
        .mask = posix.sigemptyset(),
    };
    inline for (&.{SIG.CHLD, SIG.INT, SIG.TERM, SIG.PIPE}) |sig| {
        posix.sigaction(sig, &sa, null);
    }

    wlroots.log.init(config.log_level, null);

    // The Wayland server ("display") is managed by libwayland. It handles accepting
    // clients from the Unix socket, managing Wayland globals, and so on.
    dpy = try .create();
    errdefer dpy.destroy();

    event_loop = dpy.getEventLoop();

    // The backend is a wlroots feature which abstracts the underlying input and
    // output hardware. The autocreate option will choose the most suitable
    // backend based on the current environment, such as opening an X11 window
    // if an X11 server is running.
    backend = try .autocreate(event_loop, &session);
    errdefer backend.destroy();

    // Initialize the scene graph used to lay out windows
    scene = try .create();
    errdefer scene.tree.node.destroy();

    root_bg = try scene.tree.createSceneRect(0, 0, config.rootcolor);
    errdefer root_bg.node.destroy();

    var init_layers: std.ArrayListUnmanaged(*wlroots.SceneTree) = .initBuffer(&layers);
    errdefer for (init_layers.items) |layer| layer.node.destroy();
    for (0..layers.len) |_| {
        init_layers.appendAssumeCapacity(try scene.tree.createSceneTree());
    }

    drag_icon = try scene.tree.createSceneTree();
    errdefer drag_icon.node.destroy();

    drag_icon.node.placeBelow(&layers[@intFromEnum(Layer.block)].node);

    // Autocreates a renderer, either Pixman, GLES2 or Vulkan for us. The user
    // can also specify a renderer using the WLR_RENDERER env var.
    // The renderer is responsible for defining the various pixel formats it
    // supports for shared memory, this configures that for clients.
    drw = try .autocreate(backend);
    drw.events.lost.add(&gpu_reset);

    // Create shm, drm and linux_dmabuf interfaces by ourselves.
    // The simplest way is to call:
    //      try drw.initServer(dpy);
    // but we need to create the linux_dmabuf interface manually to integrate it
    // with wlr_scene.
    try drw.initWlShm(dpy);

    if (drw.getTextureFormats(@intFromEnum(wlroots.BufferCap.dmabuf))) |_| {
        _ = try wlroots.Drm.create(dpy, drw);

        scene.setLinuxDmabufV1(try wlroots.LinuxDmabufV1.createWithRenderer(dpy, 5, drw));
    }

    const drm_fd = drw.getDrmFd();
    if (drm_fd >= 0 and drw.features.timeline and backend.features.timeline) {
        _ = wlroots.LinuxDrmSyncobjManagerV1.create(dpy, 1, drm_fd);
    }

    // Autocreates an allocator for us.
    // The allocator is the bridge between the renderer and the backend. It
    // handles the buffer creation, allowing wlroots to render onto the
    // screen
    alloc = try .autocreate(backend, drw);

    _setup();
}

extern fn _gpureset(listener: *wl.Listener(void), data: ?*anyopaque) void;
fn gpureset(listener: *wl.Listener(void)) void {
    _gpureset(listener, null);
}

fn run(gpa: std.mem.Allocator, startup_cmd: ?[:0]const u8) !void {
    // Add a Unix socket to the Wayland display.
    var sockname_buf: [11]u8 = undefined;
    const sockname = try dpy.addSocketAuto(&sockname_buf);
    try environ.put("WAYLAND_DISPLAY", sockname);

    var env_arena = std.heap.ArenaAllocator.init(gpa);
    defer env_arena.deinit();
    const env = try std.process.createEnvironFromMap(env_arena.allocator(), &environ, .{});
    _ = env;

    // Now that it has a socket to communicate with, run the startup command
    if (startup_cmd) |cmd| {
        var child: std.process.Child = .init(&.{ "/bin/sh", "-c", cmd }, gpa);
        child.env_map = &environ;
        child.stdin_behavior = .Pipe;
        child.expand_arg0 = .expand;

        try child.spawn();
        errdefer exit_child(&child);

        try posix.dup2(child.stdin.?.handle, posix.STDOUT_FILENO);
    }
    defer if (child_proc) |*child| exit_child(child);

    // Mark stdout as non-blocking to avoid the startup script
    // causing dwl to freeze when a user neither closes stdin
    // nor consumes standard input in his startup script
    const fd = posix.STDOUT_FILENO;
    _ = try posix.fcntl(fd, F.SETFL, try posix.fcntl(fd, F.GETFL, 0) | @as(u32, @bitCast(O{.NONBLOCK = true})));

    printstatus();

    // Start the backend. This will enumerate outputs and inputs, become the DRM
    // master, etc
    try wlroots.Backend.start(backend);

    // At this point the outputs are initialized, choose initial selmon based on
    // cursor position, and set default cursor image
    selmon = xytomon(cursor.x, cursor.y);

    // TODO hack to get cursor to display in its initial location (100, 100)
    // instead of (0, 0) and then jumping. still may not be fully
    // initialized, as the image/coordinates are not transformed for the
    // monitor when displayed here
    cursor.warpClosest(null, cursor.x, cursor.y);
    cursor.setXcursor(cursor_mgr, "default");

    // Run the Wayland event loop. This does not return until you exit the
    // compositor. Starting the backend rigged up all of the necessary event
    // loop configuration to listen to libinput events, DRM events, generate
    // frame events at the refresh rate, and so on.
    dpy.run();
}

export fn xytomon(x: f64, y: f64) ?*C.Monitor {
    return if (output_layout.outputAt(x, y)) |o| @alignCast(@ptrCast(o.data)) else null;
}

fn exit_child(child: *std.process.Child) void {
    _ = child.kill() catch |err| switch (err) {
        // We can get this if the child was already waited on by waitpid()
        error.AlreadyTerminated => {},
        else => std.log.err("failed to shut down child (pid {})", .{ child.id }),
    };
}

fn print_child(comptime fmt: []const u8, args: anytype) !void {
    try if (child_proc) |child| child.stdin.?.writer().print(fmt, args);
}

export var alloc: *wlroots.Allocator = undefined;
export var backend: *wlroots.Backend = undefined;
export var cursor: *wlroots.Cursor = undefined;
export var cursor_mgr: *wlroots.XcursorManager = undefined;
export var dpy: *wl.Server = undefined;
export var drag_icon: *wlroots.SceneTree = undefined;
export var drw: *wlroots.Renderer = undefined;
export var event_loop: *wl.EventLoop = undefined;
// TODO better way to represent layers?  EnumFieldStruct?  EnumArray?
extern var layers: [std.enums.values(Layer).len]*wlroots.SceneTree;
export var output_layout: *wlroots.OutputLayout = undefined;
export var root_bg: *wlroots.SceneRect = undefined;
export var scene: *wlroots.Scene = undefined;
export var selmon: ?*C.Monitor = null;
export var session: ?*wlroots.Session = null;

// Signal handlers
export var gpu_reset: wl.Listener(void) = .init(gpureset);

extern fn cleanup() void;
extern fn die(fmt: [*:0]const u8, ...) noreturn;
extern fn handlesig(signo: c_int) void;
extern fn printstatus() void;
extern fn _setup() void;
