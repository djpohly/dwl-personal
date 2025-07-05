const std = @import("std");
const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const flags = @import("flags");
const C = @import("C");
const posix = std.posix;
const F = posix.F;
const O = std.os.linux.O;

var environ: std.process.EnvMap = undefined;
var child_proc: ?std.process.Child = null;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const args = try std.process.argsAlloc(arena.allocator());

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

    environ = try std.process.getEnvMap(arena.allocator());
    defer environ.deinit();

    setup();
    try run(arena.allocator(), options.@"startup-cmd");
    cleanup();
}

fn run(alloc: std.mem.Allocator, startup_cmd: ?[:0]const u8) !void {
    // Add a Unix socket to the Wayland display.
    var sockname_buf: [11]u8 = undefined;
    const sockname = try dpy.addSocketAuto(&sockname_buf);
    try environ.put("WAYLAND_DISPLAY", sockname);
    std.c.environ = try std.process.createEnvironFromMap(alloc, &environ, .{});

    // Start the backend. This will enumerate outputs and inputs, become the DRM
    // master, etc
    try wlroots.Backend.start(backend);

    // Now that the socket exists and the backend is started, run the startup command
    if (startup_cmd) |cmd| {
        var child: std.process.Child = .init(&.{ "/bin/sh", "-c", cmd }, alloc);
        child.env_map = &environ;
        child.stdin_behavior = .Pipe;
        child.expand_arg0 = .expand;

        try child.spawn();
        errdefer exit_child(&child);

        child_proc = child;
    }
    defer if (child_proc) |*child| exit_child(child);

    // Mark stdout as non-blocking to avoid the startup script
    // causing dwl to freeze when a user neither closes stdin
    // nor consumes standard input in his startup script
    const fd = posix.STDOUT_FILENO;
    _ = try posix.fcntl(fd, F.SETFL, try posix.fcntl(fd, F.GETFL, 0) | @as(u32, @bitCast(O{.NONBLOCK = true})));

    printstatus();

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

extern var backend: *wlroots.Backend;
extern var cursor: *wlroots.Cursor;
extern var cursor_mgr: *wlroots.XcursorManager;
extern var dpy: *wl.Server;
extern var output_layout: *wlroots.OutputLayout;
extern var selmon: ?*C.Monitor;

extern fn setup() void;
extern fn cleanup() void;
extern fn die(fmt: [*:0]const u8, ...) noreturn;
extern fn printstatus() void;
