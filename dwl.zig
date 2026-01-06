const build_options = @import("build_options");
const std = @import("std");
const wlroots = @import("wlroots");
const wayland = @import("wayland");
const xkb = @import("xkbcommon");
const wl = wayland.server.wl;
const flags = @import("flags");
const C = @import("C");
const posix = std.posix;
const F = posix.F;
const SIG = posix.SIG;
const SA = posix.SA;
const O = std.os.linux.O;
const assert = std.debug.assert;
const config = @import("config.zig");
const XdgServerDecorationManager = @import("XdgServerDecorationManager.zig");
const abi = @import("abi.zig");

var environ: std.process.EnvMap = undefined;
var child_proc: ?std.process.Child = null;

// Allocator to use for allocating objects/listeners
// c_allocator is compatible with malloc/free
const global_alloc = std.heap.c_allocator;

const Layer = enum(c_uint) {
    comptime { abi.checkEnum(@This(), C.Layer, C, "Lyr"); }

    bg,
    bottom,
    tile,
    float,
    top,
    fs,
    overlay,
    block,
};

const CursorMode = enum(c_uint) {
    comptime { abi.checkEnum(@This(), C.CursorMode, C, "Cur"); }

    normal,
    pressed,
    move,
    resize,
};

const Monitor = extern struct {
    comptime { abi.ensureEquivalentAbiFlat(@This(), C.Monitor); }

    const Layout = extern struct {
        comptime { abi.ensureEquivalentAbi(@This(), C.Layout); }

        symbol: [*:0]const u8,
        arrange: ?*const fn (*Monitor) callconv(.c) void,
    };

    const Rule = extern struct {
        comptime { abi.ensureEquivalentAbi(@This(), C.MonitorRule); }

        name: ?[*:0]const u8,
        mfact: f32,
        nmaster: c_int,
        scale: f32,
        lt: ?*const Layout,
        rr: wl.Output.Transform,
        x: c_int,
        y: c_int,
    };

    link: wl.list.Link,
    wlr_output: *wlroots.Output,
    scene_output: *wlroots.SceneOutput,
    // See createmon() for info
    fullscreen_bg: *wlroots.SceneRect,
    frame: wl.Listener(*wlroots.Output),
    destroy: wl.Listener(*wlroots.Output),
    request_state: wl.Listener(*wlroots.Output.event.RequestState),
    destroy_lock_surface: wl.Listener(void),
    lock_surface: *wlroots.SessionLockSurfaceV1,
    // monitor area, layout-relative
    m: wlroots.Box,
    // window area, layout-relative
    w: wlroots.Box,
    // LayerSurface.link
    layers: [4]wl.list.Link,
    lt: [2]*const Layout,
    seltags: c_uint,
    sellt: c_uint,
    tagset: [2]u32,
    mfact: f32,
    gamma_lut_changed: c_int,
    nmaster: c_int,
    ltsymbol: [16]u8,
    asleep: c_int,

    pub fn at(x: f64, y: f64) ?*Monitor {
        const output = output_layout.outputAt(x, y) orelse return null;
        return @alignCast(@ptrCast(output.data));
    }
    export fn xytomon(x: f64, y: f64) ?*Monitor { return Monitor.at(x, y); }
};

const Client = extern struct {
    comptime { abi.ensureEquivalentAbi(@This(), C.Client); }

    const Type = enum(c_uint) {
        comptime { abi.checkEnum(@This(), C.ClientType, C, ""); }

        xdg_shell,
        layer_shell,
    };

    // Must keep this field first (match ABI for LayerShell)
    type: Type = .xdg_shell,

    mon: ?*Monitor,
    scene: *wlroots.SceneTree,
    // top, bottom, left, right
    border: [4]*wlroots.SceneRect,
    scene_surface: *wlroots.SceneTree,
    link: wl.list.Link,
    flink: wl.list.Link,
    // layout-relative, includes border
    geom: wlroots.Box,
    // layout-relative, includes border
    prev: wlroots.Box,
    // only width and height are used
    bounds: wlroots.Box,
    surface: *wlroots.XdgSurface,
    decoration: ?*wlroots.XdgToplevelDecorationV1,
    commit: wl.Listener(*wlroots.Surface),
    map: wl.Listener(void),
    maximize: wl.Listener(void),
    unmap: wl.Listener(void),
    destroy: wl.Listener(void),
    set_title: wl.Listener(void),
    fullscreen: wl.Listener(void),
    set_decoration_mode: wl.Listener(*wlroots.XdgToplevelDecorationV1),
    destroy_decoration: wl.Listener(*wlroots.XdgToplevelDecorationV1),
    bw: c_uint,
    tags: u32,
    isfloating: c_int,
    isurgent: c_int,
    isfullscreen: c_int,
    resize_serial: u32,

    export fn client_surface(self: *Client) *wlroots.Surface {
        return self.surface.surface;
    }

    fn toplevel(self: Client) *wlroots.XdgToplevel {
        const xdg: *wlroots.XdgSurface = self.surface;
        assert(xdg.role == .toplevel);
        return xdg.role_data.toplevel.?;
    }

    fn setBorderColor(self: *Client, color: [4]f32) void {
        for (0..4) |i| {
            self.border[i].setColor(&color);
        }
    }
    export fn client_set_border_color(self: *Client, color: *const [4]f32) void { self.setBorderColor(color.*); }

    fn setFloating(self: *Client, floating: bool) void {
        self.isfloating = @intFromBool(floating);
	// If in floating layout do not change the client's layer
        const mon: *Monitor = self.mon orelse return;
        if (!self.surface.surface.mapped or mon.lt[mon.sellt].*.arrange == null) {
            return;
        }
        const parent = self.getParent();
        const selfFs = self.isfullscreen != 0;
        const selfFloat = self.isfloating != 0;
        const parentFs = if (parent) |p| p.isfullscreen != 0 else false;
        const layer: Layer =
            if (selfFs or parentFs)
                .fs
            else if (selfFloat)
                .float
            else
                .tile;

        self.scene.node.reparent(layers[@intFromEnum(layer)]);
        arrange(self.mon);
        printstatus();
    }
    export fn setfloating(self: *Client, floating: c_int) void { self.setFloating(floating != 0); }

    fn applyBounds(self: *Client, bbox: wlroots.Box) void {
        // set minimum possible
        const min_dim = 1 + 2 * self.bw;
        const geom = &self.geom;
        geom.width = @intCast(@max(min_dim, geom.width));
        geom.height = @intCast(@max(min_dim, geom.height));

        if (geom.x >= bbox.x + bbox.width)
            geom.x = bbox.x + bbox.width - geom.width;
        if (geom.y >= bbox.y + bbox.height)
            geom.y = bbox.y + bbox.height - geom.height;
        if (geom.x + geom.width <= bbox.x)
            geom.x = bbox.x;
        if (geom.y + geom.height <= bbox.y)
            geom.y = bbox.y;
    }
    export fn applybounds(self: *Client, bbox: *wlroots.Box) void { self.applyBounds(bbox.*); }

    fn setBounds(self: *Client, width: u31, height: u31) u32 {
        if (self.surface.surface.resource.getVersion() < C.XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION or
            (self.bounds.width == width and self.bounds.height == height))
        {
            return 0;
        }
        self.bounds.width = width;
        self.bounds.height = height;
        return self.toplevel().setBounds(width, height);
    }

    fn getAppId(self: *const Client) [:0]const u8 {
        return std.mem.span(self.getAppIdZ());
    }
    fn getAppIdZ(self: *const Client) [*:0]const u8 {
        return self.toplevel().app_id orelse "broken";
    }
    export fn client_get_appid(self: *Client) [*:0]const u8 { return self.getAppIdZ(); }

    fn getTitle(self: *const Client) [:0]const u8 {
        return std.mem.span(self.getTitleZ());
    }
    fn getTitleZ(self: *const Client) [*:0]const u8 {
        return self.toplevel().title orelse "broken";
    }
    export fn client_get_title(self: *Client) [*:0]const u8 { return self.getTitleZ(); }

    fn getClip(self: *const Client) wlroots.Box {
        const xdg = self.surface;
        const bw: c_int = @intCast(self.bw);
        return .{
            .x = xdg.geometry.x,
            .y = xdg.geometry.y,
            .width = self.geom.width - bw,
            .height = self.geom.height - bw,
        };
    }

    fn getGeometry(self: Client) wlroots.Box {
        return self.surface.geometry;
    }
    export fn client_get_geometry(self: *Client, geom: *wlroots.Box) void { geom.* = self.getGeometry(); }

    fn sendClose(self: Client) void {
        self.toplevel().sendClose();
    }
    export fn client_send_close(self: *Client) void { self.sendClose(); }

    fn setFullscreen(self: Client, fullscreen: bool) void {
        _ = self.toplevel().setFullscreen(fullscreen);
    }
    export fn client_set_fullscreen(self: *Client, fullscreen: c_int) void { self.setFullscreen(fullscreen != 0); }

    fn setSuspended(self: Client, suspended: bool) void {
        _ = self.toplevel().setSuspended(suspended);
    }
    export fn client_set_suspended(self: *Client, suspended: c_int) void { self.setSuspended(suspended != 0); }

    fn wantsFullscreen(self: Client) bool {
        return self.toplevel().requested.fullscreen;
    }
    export fn client_wants_fullscreen(self: *Client) c_int { return @intFromBool(self.wantsFullscreen()); }

    fn getParent(self: Client) ?*Client {
        const parent = self.toplevel().parent orelse return null;
        return toplevel_from_wlr_surface(parent.base.surface).client;
    }
    export fn client_get_parent(self: *Client) ?*Client { return self.getParent(); }

    fn setSize(self: Client, width: u31, height: u31) u32 {
        const tl = self.toplevel();
        if (width == tl.current.width and height == tl.current.height) {
            return 0;
        }
        return tl.setSize(width, height);
    }

    fn hasChildren(self: Client) bool {
        const head: *wl.list.Head(wlroots.XdgSurface, .link) = @ptrCast(&self.surface.link);
	// surface.xdg->link is never empty because it always contains at least the
	// surface itself.
        return head.length() > 1;
    }
    export fn client_has_children(self: *Client) c_int { return @intFromBool(self.hasChildren()); }

    fn isFloatType(self: Client) bool {
        const tl = self.toplevel();
        const state = tl.current;
        return tl.parent != null or (
            state.min_width != 0 and state.min_height != 0 and 
            state.min_width == state.max_width and
            state.min_height == state.max_height);
    }
    export fn client_is_float_type(self: *Client) c_int { return @intFromBool(self.isFloatType()); }

    fn isRenderedOn(self: Client, mon: *const Monitor) bool {
        // This is needed for when you don't want to check formal assignment,
        // but rather actual displaying of the pixels.  Usually VISIBLEON
        // suffices and is also faster.
        var dummy: c_int = undefined;
        if (!self.scene.node.coords(&dummy, &dummy)) {
            return false;
        }

        // Check the client's current outputs to see if any is the target
        const target_output = mon.wlr_output;
        var it = self.surface.surface.current_outputs.iterator(.forward);
        while (it.next()) |s| {
            if (s.output == target_output) {
                return true;
            }
        }

        return false;
    }
    export fn client_is_rendered_on_mon(self: *Client, m: *Monitor) c_int { return @intFromBool(self.isRenderedOn(m)); }

    fn setTiled(self: Client, edges: wlroots.Edges) void {
        const tl = self.toplevel();
        if (tl.resource.getVersion() < C.XDG_TOPLEVEL_STATE_TILED_RIGHT_SINCE_VERSION) {
            // Fallback approach
            _ = tl.setMaximized(edges != wlroots.Edges{});
            return;
        }
        _ = tl.setTiled(edges);
    }
    export fn client_set_tiled(self: *Client, edges: u32) void { self.setTiled(@bitCast(edges)); }

    fn resize(self: *Client, geo: wlroots.Box, interactive: bool) void {
        const mon: *Monitor = self.mon orelse return;
        if (!self.surface.surface.mapped) {
            return;
        }

        const bbox: wlroots.Box = if (interactive) sgeom else @bitCast(mon.w);
        _ = self.setBounds(@intCast(geo.width), @intCast(geo.height));
        self.geom = @bitCast(geo);
        self.applyBounds(bbox);

	// Update scene-graph, including borders
        const cw: u31 = @intCast(self.geom.width);
        const ch: u31 = @intCast(self.geom.height);
        const bw: u31 = @intCast(self.bw);

        self.scene.node.setPosition(self.geom.x, self.geom.y);

        // Position borders
        const top: *wlroots.SceneRect = self.border[0];
        top.setSize(cw, bw);
        // Top border stays at (0, 0)
        const bottom: *wlroots.SceneRect = self.border[1];
        bottom.setSize(cw, bw);
        bottom.node.setPosition(0, ch - bw);
        const left: *wlroots.SceneRect = self.border[2];
        left.setSize(bw, ch - 2 * bw);
        left.node.setPosition(0, bw);
        const right: *wlroots.SceneRect = self.border[3];
        right.setSize(bw, ch - 2 * bw);
        right.node.setPosition(cw - bw, bw);

	// this is a no-op if size hasn't changed
        self.resize_serial = self.setSize(cw - 2 * bw, ch - 2 * bw);
        const clip = self.getClip();
        self.scene_surface.node.setPosition(bw, bw);
        self.scene_surface.node.subsurfaceTreeSetClip(&clip);
    }
    fn _resize(self: *Client, geo: C.wlr_box, interact: c_int) callconv(.c) void { self.resize(@bitCast(geo), interact != 0); }
    comptime { @export(&_resize, .{ .name = "resize" }); }
};

fn client_notify_enter(s: *wlroots.Surface, kb: ?*wlroots.Keyboard) void {
    if (kb) |keyboard| {
        seat.keyboardNotifyEnter(s, keyboard.keycodes[0..keyboard.num_keycodes], &keyboard.modifiers);
    } else {
        seat.keyboardNotifyEnter(s, &.{}, null);
    }
}
fn c_client_notify_enter(s: *C.wlr_surface, kb: ?*C.wlr_keyboard) callconv(.c) void { client_notify_enter(@ptrCast(s), @ptrCast(kb)); }
comptime { @export(&c_client_notify_enter, .{ .name = "client_notify_enter" }); }

fn client_set_scale(s: *wlroots.Surface, scale: f32) void {
    wlroots.FractionalScaleManagerV1.notifyScale(s, scale);
    s.setPreferredBufferScale(@intFromFloat(@ceil(scale)));
}
fn c_client_set_scale(s: *C.wlr_surface, scale: f32) callconv(.c) void { client_set_scale(@ptrCast(s), scale); }
comptime { @export(&c_client_set_scale, .{ .name = "client_set_scale" }); }

fn client_activate_surface(s: *wlroots.Surface, activated: bool) void {
    if (wlroots.XdgSurface.tryFromWlrSurface(s)) |xdg_surface| {
        if (xdg_surface.role != .toplevel) {
            return;
        }
        _ = xdg_surface.role_data.toplevel.?.setActivated(activated);
    }
}
fn c_client_activate_surface(s: *C.wlr_surface, activated: c_int) callconv(.c) void { client_activate_surface(@ptrCast(s), activated != 0); }
comptime { @export(&c_client_activate_surface, .{ .name = "client_activate_surface" }); }

const KeyboardGroup = extern struct {
    wlr_group: *wlroots.KeyboardGroup,

    nsyms: c_int,
    keysyms: [*]const xkb.Keysym,  // invalid if nsyms == 0
    mods: u32,  // invalid if nsyms == 0
    key_repeat_source: *wl.EventSource,

    modifiers: wl.Listener(*wlroots.Keyboard),
    key: wl.Listener(*wlroots.Keyboard.event.Key),
    destroy: wl.Listener(*wlroots.InputDevice),
};

export fn chvt(arg: *C.Arg) void {
    session.?.changeVt(arg.ui) catch |err| {
        std.log.warn("chvt() failed: {t}", .{err});
        return;
    };
}

pub fn main() !void {
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

    root_bg = try scene.tree.createSceneRect(0, 0, &config.rootcolor);
    errdefer root_bg.node.destroy();

    var init_layers: std.ArrayListUnmanaged(*wlroots.SceneTree) = .initBuffer(&layers);
    errdefer for (init_layers.items) |layer| layer.node.destroy();
    for (0..layers.len) |_| {
        init_layers.appendAssumeCapacity(try scene.tree.createSceneTree());
    }

    locked_bg = try layers[@intFromEnum(Layer.block)].createSceneRect(0, 0, &.{0.1, 0.1, 0.1, 1.0});
    errdefer locked_bg.node.destroy();
    locked_bg.node.setEnabled(false);

    drag_icon = try scene.tree.createSceneTree();
    errdefer drag_icon.node.destroy();
    drag_icon.node.placeBelow(&layers[@intFromEnum(Layer.block)].node);

    // Autocreates a renderer, either Pixman, GLES2 or Vulkan for us. The user
    // can also specify a renderer using the WLR_RENDERER env var.
    // The renderer is responsible for defining the various pixel formats it
    // supports for shared memory, this configures that for clients.
    drw = try .autocreate(backend);
    errdefer drw.destroy();

    drw.events.lost.add(&Listeners.gpu_reset);
    errdefer Listeners.gpu_reset.link.remove();

    // Create shm, drm and linux_dmabuf interfaces by ourselves.
    // The simplest way is to call:
    //      try drw.initServer(dpy);
    // but we need to create the linux_dmabuf interface manually to integrate it
    // with wlr_scene.
    try drw.initWlShm(dpy);

    if (drw.getTextureFormats(@intFromEnum(wlroots.BufferCap.dmabuf))) |_| {
        _ = try wlroots.Drm.create(dpy, drw);

        scene.setLinuxDmabufV1(try .createWithRenderer(dpy, 5, drw));
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
    errdefer alloc.destroy();

    // This creates some hands-off wlroots interfaces. The compositor is
    // necessary for clients to allocate surfaces and the data device manager
    // handles the clipboard. Each of these wlroots interfaces has room for you
    // to dig your fingers in and play with their behavior if you want. Note that
    // the clients cannot set the selection directly without compositor approval,
    // see the setsel() function.
    compositor = try .create(dpy, 6, drw);
    _ = try wlroots.Subcompositor.create(dpy);
    _ = try wlroots.DataDeviceManager.create(dpy);
    _ = try wlroots.ExportDmabufManagerV1.create(dpy);
    _ = try wlroots.ScreencopyManagerV1.create(dpy);
    _ = try wlroots.DataControlManagerV1.create(dpy);
    _ = try wlroots.PrimarySelectionDeviceManagerV1.create(dpy);
    _ = try wlroots.Viewporter.create(dpy);
    _ = try wlroots.SinglePixelBufferManagerV1.create(dpy);
    _ = try wlroots.FractionalScaleManagerV1.create(dpy, 1);
    _ = try wlroots.Presentation.create(dpy, backend, 2);
    _ = try wlroots.AlphaModifierV1.create(dpy);

    // Initializes the interface used to implement urgency hints
    activation = try .create(dpy);
    activation.events.request_activate.add(&Listeners.request_activate);
    errdefer Listeners.request_activate.link.remove();

    scene.setGammaControlManagerV1(try .create(dpy));

    power_mgr = try .create(dpy);
    power_mgr.events.set_mode.add(&Listeners.output_power_mgr_set_mode);
    errdefer Listeners.output_power_mgr_set_mode.link.remove();

    // Creates an output layout, which is a wlroots utility for working with an
    // arrangement of screens in a physical layout.
    output_layout = try .create(dpy);
    output_layout.events.change.add(&Listeners.layout_change);
    errdefer Listeners.layout_change.link.remove();

    _ = try wlroots.XdgOutputManagerV1.create(dpy, output_layout);

    // Set up our client lists, the xdg-shell and the
    // layer-shell, as well as the monitor list
    clients.init();
    fstack.init();
    mons.init();

    // Configure a listener to be notified when new outputs are available on the
    // backend.
    backend.events.new_output.add(&Listeners.new_output);
    errdefer Listeners.new_output.link.remove();

    xdg_shell = try .create(dpy, 6);
    xdg_shell.events.new_toplevel.add(&Listeners.new_xdg_toplevel);
    errdefer Listeners.new_xdg_toplevel.link.remove();
    xdg_shell.events.new_popup.add(&Listeners.new_xdg_popup);
    errdefer Listeners.new_xdg_popup.link.remove();

    layer_shell = try .create(dpy, 3);
    layer_shell.events.new_surface.add(&Listeners.new_layer_surface);
    errdefer Listeners.new_layer_surface.link.remove();

    idle_notifier = try .create(dpy);
    idle_inhibit_mgr = try .create(dpy);
    idle_inhibit_mgr.events.new_inhibitor.add(&Listeners.new_idle_inhibitor);
    errdefer Listeners.new_idle_inhibitor.link.remove();

    session_lock_mgr = try .create(dpy);
    session_lock_mgr.events.new_lock.add(&Listeners.new_session_lock);
    errdefer Listeners.new_session_lock.link.remove();

    // Use decoration protocols to negotiate server-side decorations.
    const server_decoration_mgr: XdgServerDecorationManager = try .create(dpy);
    server_decoration_mgr.setDefaultMode(.server);
    xdg_decoration_mgr = try .create(dpy);
    xdg_decoration_mgr.events.new_toplevel_decoration.add(&Listeners.new_xdg_decoration);
    errdefer Listeners.new_xdg_decoration.link.remove();

    pointer_constraints = try .create(dpy);
    pointer_constraints.events.new_constraint.add(&Listeners.new_pointer_constraint);
    errdefer Listeners.new_pointer_constraint.link.remove();

    relative_pointer_mgr = try .create(dpy);

    // Creates a cursor, which is a wlroots utility for tracking the cursor
    // image shown on screen.
    cursor = try .create();
    errdefer cursor.destroy();
    cursor.attachOutputLayout(output_layout);

    // Creates an xcursor manager, another wlroots utility which loads up
    // Xcursor themes to source cursor images from and makes sure that cursor
    // images are available at all scale factors on the screen (necessary for
    // HiDPI support). Scaled cursors will be loaded with each output.
    cursor_mgr = try .create(null, 24);
    _ = C.setenv("XCURSOR_SIZE", "24", 1);

    // wlr_cursor *only* displays an image on screen. It does not move around
    // when the pointer moves. However, we can attach input devices to it, and
    // it will generate aggregate events for all of them. In these events, we
    // can choose how we want to process them, forwarding them to clients and
    // moving the cursor around.
    cursor.events.motion.add(&Listeners.cursor_motion);
    errdefer Listeners.cursor_motion.link.remove();
    cursor.events.motion_absolute.add(&Listeners.cursor_motion_absolute);
    errdefer Listeners.cursor_motion_absolute.link.remove();
    cursor.events.button.add(&Listeners.cursor_button);
    errdefer Listeners.cursor_button.link.remove();
    cursor.events.axis.add(&Listeners.cursor_axis);
    errdefer Listeners.cursor_axis.link.remove();
    cursor.events.frame.add(&Listeners.cursor_frame);
    errdefer Listeners.cursor_frame.link.remove();

    cursor_shape_mgr = try .create(dpy, 1);
    cursor_shape_mgr.events.request_set_shape.add(&Listeners.request_set_cursor_shape);
    errdefer Listeners.request_set_cursor_shape.link.remove();

    // Configures a seat, which is a single "seat" at which a user sits and
    // operates the computer. This conceptually includes up to one keyboard,
    // pointer, touch, and drawing tablet device. We also rig up a listener to
    // let us know when new input devices are available on the backend.
    backend.events.new_input.add(&Listeners.new_input_device);
    errdefer Listeners.new_input_device.link.remove();

    // Setup for virtual input devices
    virtual_keyboard_mgr = try .create(dpy);
    virtual_keyboard_mgr.events.new_virtual_keyboard.add(&Listeners.new_virtual_keyboard);
    errdefer Listeners.new_virtual_keyboard.link.remove();
    virtual_pointer_mgr = try .create(dpy);
    virtual_pointer_mgr.events.new_virtual_pointer.add(&Listeners.new_virtual_pointer);
    errdefer Listeners.new_virtual_pointer.link.remove();

    seat = try .create(dpy, "seat0");
    errdefer seat.destroy();
    seat.events.request_set_cursor.add(&Listeners.request_cursor);
    errdefer Listeners.request_cursor.link.remove();
    seat.events.request_set_selection.add(&Listeners.request_set_sel);
    errdefer Listeners.request_set_sel.link.remove();
    seat.events.request_set_primary_selection.add(&Listeners.request_set_psel);
    errdefer Listeners.request_set_psel.link.remove();
    seat.events.request_start_drag.add(&Listeners.request_start_drag);
    errdefer Listeners.request_start_drag.link.remove();
    seat.events.start_drag.add(&Listeners.start_drag);
    errdefer Listeners.start_drag.link.remove();

    kb_group = createkeyboardgroup();
    kb_group.destroy.link.init();

    output_mgr = try .create(dpy);
    output_mgr.events.apply.add(&Listeners.output_mgr_apply);
    errdefer Listeners.output_mgr_apply.link.remove();
    output_mgr.events.@"test".add(&Listeners.output_mgr_test);
    errdefer Listeners.output_mgr_test.link.remove();

    // Make sure XWayland clients don't connect to the parent X server,
    // e.g when running in the x11 backend or the wayland backend and the
    // compositor has Xwayland support
    environ.remove("DISPLAY");
}

fn cleanup() void {
    Listeners.cleanup();
    dpy.destroyClients();
    if (child_proc) |*child| {
        _ = child.kill() catch |err| {
            std.log.warn("could not kill child process: {t}", .{err});
        };
    }
    cursor_mgr.destroy();

    destroykeyboardgroup(&kb_group.destroy, undefined);

    // If it's not destroyed manually, it will cause a use-after-free of wlr_seat.
    // Destroy it until it's fixed on the wlroots side
    backend.destroy();

    dpy.destroy();

    // Destroy after the wayland display (when the monitors are already destroyed)
    // to avoid destroying them with an invalid scene output.
    scene.tree.node.destroy();
}

export fn quit(_: ?*C.Arg) void {
    dpy.terminate();
}

fn _spawn(argv: [*:null]const ?[*:0]const u8) !void {
    if (try posix.fork() == 0) {
        try posix.dup2(posix.STDERR_FILENO, posix.STDOUT_FILENO);
        _ = try posix.setsid();
        posix.execvpeZ(argv[0].?, argv, std.c.environ) catch {
            die("dwl: execvp %s failed:", argv[0]);
        };
    }
}

export fn spawn(arg: *C.Arg) void {
    _spawn(@alignCast(@ptrCast(arg.v))) catch |err| {
        std.log.warn("error {t} in spawn", .{err});
    };
}

fn createkeyboard(keyboard: *wlroots.Keyboard) void {
    // Set the keymap to match the group keymap
    _ = keyboard.setKeymap(kb_group.wlr_group.keyboard.keymap);

    // Add the new keyboard to the group
    _ = kb_group.wlr_group.addKeyboard(keyboard);
}

fn setcursor(_: *wl.Listener(*wlroots.Seat.event.RequestSetCursor), event: *wlroots.Seat.event.RequestSetCursor) void {
    // This event is raised by the seat when a client provides a cursor image.
    // If we're "grabbing" the cursor, don't use the client's image, we will
    // restore it after "grabbing" sending a leave event, followed by a enter
    // event, which will result in the client requesting set the cursor surface
    switch (@as(CursorMode, @enumFromInt(cursor_mode))) {
        .normal, .pressed => {
            if (event.seat_client == seat.pointer_state.focused_client) {
                cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
            }
        },
        .move, .resize => {},
    }
}

fn virtualkeyboard(_: *wl.Listener(*wlroots.VirtualKeyboardV1), kb: *wlroots.VirtualKeyboardV1) void {
    // virtual keyboards shouldn't share keyboard group
    const group = createkeyboardgroup();
    // Set the keymap to match the group keymap
    _ = kb.keyboard.setKeymap(group.wlr_group.keyboard.keymap);

    group.destroy.setNotify(_destroykeyboardgroup);
    kb.keyboard.base.events.destroy.add(&group.destroy);
    errdefer group.destroy.link.remove();

    // Add the new keyboard to the group
    _ = group.wlr_group.addKeyboard(&kb.keyboard);
}

extern fn destroykeyboardgroup(listener: *wl.Listener(*wlroots.InputDevice), device: *wlroots.InputDevice) void;
fn _destroykeyboardgroup(l: *wl.Listener(*wlroots.InputDevice), event: *wlroots.InputDevice) void { destroykeyboardgroup(l, event); }

fn virtualpointer(_: *wl.Listener(*wlroots.VirtualPointerManagerV1.event.NewPointer), event: *wlroots.VirtualPointerManagerV1.event.NewPointer) void {
    const device = &event.new_pointer.pointer.base;

    cursor.attachInputDevice(device);
    if (event.suggested_output) |output| {
        cursor.mapInputToOutput(device, output);
    }
}

fn gpureset(_: *wl.Listener(void)) void {
    const new_drw = wlroots.Renderer.autocreate(backend) catch |err| {
        std.log.err("Error creating Renderer: {s}", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(null);
        return;
    };
    errdefer new_drw.destroy();

    const new_alloc = wlroots.Allocator.autocreate(backend, drw) catch |err| {
        std.log.err("Error creating Renderer: {s}", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(null);
        return;
    };
    errdefer new_alloc.destroy();

    // Remove from old drw, add to new
    Listeners.gpu_reset.link.remove();
    new_drw.events.lost.add(&Listeners.gpu_reset);

    compositor.setRenderer(new_drw);

    var it = mons.iterator(.forward);
    while (it.next()) |m| {
        _ = m.wlr_output.initRender(new_alloc, new_drw);
    }

    const old_drw = drw;
    drw = new_drw;
    defer old_drw.destroy();

    const old_alloc = alloc;
    alloc = new_alloc;
    defer old_alloc.destroy();
}

fn run(gpa: std.mem.Allocator, startup_cmd: ?[:0]const u8) !void {
    // Add a Unix socket to the Wayland display.
    var sockname_buf: [11]u8 = undefined;
    const sockname = try dpy.addSocketAuto(&sockname_buf);
    try environ.put("WAYLAND_DISPLAY", sockname);
    _ = C.setenv("WAYLAND_DISPLAY", sockname, 1);

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
    try backend.start();

    // At this point the outputs are initialized, choose initial selmon based on
    // cursor position, and set default cursor image
    selmon = .at(cursor.x, cursor.y);

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

fn powermgrsetmode(_: *wl.Listener(*wlroots.OutputPowerManagerV1.event.SetMode), event: *wlroots.OutputPowerManagerV1.event.SetMode) void {
    var state: wlroots.Output.State = .init();

    if (@as(?*C.Monitor, @alignCast(@ptrCast(event.output.data)))) |m| {
        comptime assert(@TypeOf(m.wlr_output) == [*c]C.wlr_output); // remove @ptrCast
        const output: *wlroots.Output = @ptrCast(m.wlr_output);
        m.gamma_lut_changed = 1;
        state.setEnabled(event.mode != .off);
        _ = output.commitState(&state);

        m.asleep = @intFromBool(event.mode == .off);
        updatemons(null, null);
    }
}

const ToplevelResult = union(enum) {
    none: void,
    client: *Client,
    layer: *C.LayerSurface,
};

fn toplevel_from_wlr_surface(s: ?*wlroots.Surface) ToplevelResult {
    const surface = s orelse return .none;
    const root_surface = surface.getRootSurface();
    if (wlroots.LayerSurfaceV1.tryFromWlrSurface(root_surface)) |layer_surface| {
        return .{ .layer = @alignCast(@ptrCast(layer_surface.data)) };
    }

    var cur_surface = wlroots.XdgSurface.tryFromWlrSurface(root_surface);
    while (cur_surface) |xdg_surface| {
        switch (xdg_surface.role) {
            .none => return .none,
            .toplevel => return .{ .client = @alignCast(@ptrCast(xdg_surface.data)) },
            .popup => {
                const popup = xdg_surface.role_data.popup orelse return .none;
                const parent = popup.parent orelse return .none;
                if (wlroots.XdgSurface.tryFromWlrSurface(parent)) |parent_surface| {
                    cur_surface = parent_surface;
                } else {
                    return toplevel_from_wlr_surface(parent);
                }
            },
        }
    }
    return .none;
}

fn c_toplevel_from_wlr_surface(s: ?*wlroots.Surface, pc: ?*?*Client, pl: ?*?*C.LayerSurface) callconv(.c) c_int {
    const c, const l, const t: c_int = switch (toplevel_from_wlr_surface(s)) {
        .none => .{ null, null, -1 },
        .client => |c| .{ c, null, @intCast(C.XdgShell) },
        .layer => |l| .{ null, l, @intCast(C.LayerShell) },
    };
    if (pc) |p| p.* = c;
    if (pl) |p| p.* = l;
    return t;
}
comptime { @export(&c_toplevel_from_wlr_surface, .{ .name = "toplevel_from_wlr_surface" }); }

fn urgent(_: *wl.Listener(*wlroots.XdgActivationV1.event.RequestActivate), event: *wlroots.XdgActivationV1.event.RequestActivate) void {
    switch (toplevel_from_wlr_surface(event.surface)) {
        .client => |c| {
            if (c == focustop(selmon)) {
                return;
            }

            c.isurgent = 1;
            printstatus();

            if (c.surface.surface.mapped) {
                c.setBorderColor(config.urgentcolor);
            }
        },
        else => return,
    }
}

fn createidleinhibitor(_: *wl.Listener(*wlroots.IdleInhibitorV1), idle_inhibitor: *wlroots.IdleInhibitorV1) void {
    idle_inhibitor.events.destroy.add(&struct {
        var static_listener: wl.Listener(*wlroots.Surface) = .init(destroyidleinhibitor);
    }.static_listener);

    checkidleinhibitor(null);
}

fn destroyidleinhibitor(l: *wl.Listener(*wlroots.Surface), surface: *wlroots.Surface) void {
    // `surface` is the wlr_surface of the idle inhibitor being destroyed,
    // at this point the idle inhibitor is still in the list of the manager
    checkidleinhibitor(surface.getRootSurface());
    l.link.remove();
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

var activation: *wlroots.XdgActivationV1 = undefined;
export var active_constraint: ?*wlroots.PointerConstraintV1 = null;
export var alloc: *wlroots.Allocator = undefined;
export var backend: *wlroots.Backend = undefined;
export var clients: wl.list.Head(Client, .link) = undefined;
var compositor: *wlroots.Compositor = undefined;
export var cur_lock: ?*wlroots.SessionLockV1 = null;
export var cursor: *wlroots.Cursor = undefined;
export var cursor_mgr: *wlroots.XcursorManager = undefined;
export var cursor_mode: c_uint = 0;
var cursor_shape_mgr: *wlroots.CursorShapeManagerV1 = undefined;
export var dpy: *wl.Server = undefined;
export var drag_icon: *wlroots.SceneTree = undefined;
export var drw: *wlroots.Renderer = undefined;
export var event_loop: *wl.EventLoop = undefined;
export var fstack: wl.list.Head(Client, .flink) = undefined;
export var grabc: ?*Client = null;
export var grabcx: c_int = 0;
export var grabcy: c_int = 0;
export var idle_inhibit_mgr: *wlroots.IdleInhibitManagerV1 = undefined;
export var idle_notifier: *wlroots.IdleNotifierV1 = undefined;
export var kb_group: *KeyboardGroup = undefined;
var layer_shell: *wlroots.LayerShellV1 = undefined;
export var locked_bg: *wlroots.SceneRect = undefined;
export var mons: wl.list.Head(Monitor, .link) = undefined;
export var output_layout: *wlroots.OutputLayout = undefined;
export var output_mgr: *wlroots.OutputManagerV1 = undefined;
export var pointer_constraints: *wlroots.PointerConstraintsV1 = undefined;
var power_mgr: *wlroots.OutputPowerManagerV1 = undefined;
export var relative_pointer_mgr: *wlroots.RelativePointerManagerV1 = undefined;
export var root_bg: *wlroots.SceneRect = undefined;
export var scene: *wlroots.Scene = undefined;
export var seat: *wlroots.Seat = undefined;
export var selmon: ?*Monitor = null;
export var session: ?*wlroots.Session = null;
var session_lock_mgr: *wlroots.SessionLockManagerV1 = undefined;
export var sgeom: wlroots.Box = undefined;
export var virtual_keyboard_mgr: *wlroots.VirtualKeyboardManagerV1 = undefined;
export var virtual_pointer_mgr: *wlroots.VirtualPointerManagerV1 = undefined;
var xdg_decoration_mgr: *wlroots.XdgDecorationManagerV1 = undefined;
var xdg_shell: *wlroots.XdgShell = undefined;

// TODO better way to represent layers?  EnumFieldStruct?  EnumArray?
extern var layers: [std.enums.values(Layer).len]*wlroots.SceneTree;

// Signal handlers
const Listeners = struct {
    pub export var cursor_axis: wl.Listener(*wlroots.Pointer.event.Axis) = .init(axisnotify);
    pub export var cursor_button: wl.Listener(*wlroots.Pointer.event.Button) = .init(_buttonpress);
    pub export var cursor_frame: wl.Listener(*wlroots.Cursor) = .init(cursorframe);
    pub export var cursor_motion: wl.Listener(*wlroots.Pointer.event.Motion) = .init(motionrelative);
    pub export var cursor_motion_absolute: wl.Listener(*wlroots.Pointer.event.MotionAbsolute) = .init(motionabsolute);
    pub export var gpu_reset: wl.Listener(void) = .init(gpureset);
    pub export var layout_change: wl.Listener(*wlroots.OutputLayout) = .init(_updatemons);
    pub export var new_idle_inhibitor: wl.Listener(*wlroots.IdleInhibitorV1) = .init(createidleinhibitor);
    pub export var new_input_device: wl.Listener(*wlroots.InputDevice) = .init(inputdevice);
    pub export var new_layer_surface: wl.Listener(*wlroots.LayerSurfaceV1) = .init(_createlayersurface);
    pub export var new_output: wl.Listener(*wlroots.Output) = .init(_createmon);
    pub export var new_pointer_constraint: wl.Listener(*wlroots.PointerConstraintV1) = .init(_createpointerconstraint);
    pub export var new_session_lock: wl.Listener(*wlroots.SessionLockV1) = .init(_locksession);
    pub export var new_virtual_keyboard: wl.Listener(*wlroots.VirtualKeyboardV1) = .init(virtualkeyboard);
    pub export var new_virtual_pointer: wl.Listener(*wlroots.VirtualPointerManagerV1.event.NewPointer) = .init(virtualpointer);
    pub export var new_xdg_decoration: wl.Listener(*wlroots.XdgToplevelDecorationV1) = .init(createdecoration);
    pub export var new_xdg_popup: wl.Listener(*wlroots.XdgPopup) = .init(_createpopup);
    pub export var new_xdg_toplevel: wl.Listener(*wlroots.XdgToplevel) = .init(_createnotify);
    pub export var output_mgr_apply: wl.Listener(*wlroots.OutputConfigurationV1) = .init(_outputmgrapply);
    pub export var output_mgr_test: wl.Listener(*wlroots.OutputConfigurationV1) = .init(_outputmgrtest);
    pub export var output_power_mgr_set_mode: wl.Listener(*wlroots.OutputPowerManagerV1.event.SetMode) = .init(powermgrsetmode);
    pub export var request_activate: wl.Listener(*wlroots.XdgActivationV1.event.RequestActivate) = .init(urgent);
    pub export var request_cursor: wl.Listener(*wlroots.Seat.event.RequestSetCursor) = .init(setcursor);
    pub export var request_set_cursor_shape: wl.Listener(*wlroots.CursorShapeManagerV1.event.RequestSetShape) = .init(_setcursorshape);
    pub export var request_set_psel: wl.Listener(*wlroots.Seat.event.RequestSetPrimarySelection) = .init(setpsel);
    pub export var request_set_sel: wl.Listener(*wlroots.Seat.event.RequestSetSelection) = .init(setsel);
    pub export var request_start_drag: wl.Listener(*wlroots.Seat.event.RequestStartDrag) = .init(requeststartdrag);
    pub export var start_drag: wl.Listener(*wlroots.Drag) = .init(startdrag);

    fn cleanup() void {
        inline for (@typeInfo(Listeners).@"struct".decls) |decl| {
            @field(Listeners, decl.name).link.remove();
        }
    }
};


fn requeststartdrag(_: *wl.Listener(*wlroots.Seat.event.RequestStartDrag), event: *wlroots.Seat.event.RequestStartDrag) void {
    if (seat.validatePointerGrabSerial(event.origin, event.serial)) {
        seat.startPointerDrag(event.drag, event.serial);
    } else {
        event.drag.source.?.destroy();
    }
}

fn _startdrag(_: *wl.Listener(*wlroots.Drag), drag: *wlroots.Drag) !void {
    if (drag.icon) |icon| {
        icon.data = &(try drag_icon.createSceneDragIcon(icon)).node;
        try allocListen(*wlroots.Drag.Icon, &icon.events.destroy, destroydragicon);
    }
}

fn startdrag(listener: *wl.Listener(*wlroots.Drag), drag: *wlroots.Drag) void {
    _startdrag(listener, drag) catch |err| {
        std.log.err("Error in startdrag: {t}", .{err});
        return;
    };
}

fn allocListen(comptime T: type, signal: *wl.Signal(T), handler: wl.Listener(T).NotifyFn) !void {
    const listener = try global_alloc.create(wl.Listener(T));
    listener.* = .init(handler);
    signal.add(listener);
}

fn destroydragicon(listener: *wl.Listener(*wlroots.Drag.Icon), _: *wlroots.Drag.Icon) void {
    // Focus enter isn't sent during drag, so refocus the focused node.
    focusclient(focustop(selmon), 1);
    motionnotify(0, null, 0, 0, 0, 0);
    listener.link.remove();
    std.heap.c_allocator.destroy(listener);
}
extern fn motionnotify(time: u32, device: ?*wlroots.InputDevice, sx: f64, sy: f64, sx_unaccel: f64, sy_unaccel: f64) void;

fn motionabsolute(_: *wl.Listener(*wlroots.Pointer.event.MotionAbsolute), event: *wlroots.Pointer.event.MotionAbsolute) void {
    if (event.time_msec == 0) {
        cursor.warpAbsolute(event.device, event.x, event.y);
    }
    var lx: f64 = undefined;
    var ly: f64 = undefined;
    cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);
    const dx = lx - cursor.x;
    const dy = ly - cursor.y;
    motionnotify(event.time_msec, event.device, dx, dy, dx, dy);
}

fn motionrelative(_: *wl.Listener(*wlroots.Pointer.event.Motion), event: *wlroots.Pointer.event.Motion) void {
    // This event is forwarded by the cursor when a pointer emits a _relative_
    // pointer motion event (i.e. a delta)

    // The cursor doesn't move unless we tell it to. The cursor automatically
    // handles constraining the motion to the output layout, as well as any
    // special configuration applied for the specific input device which
    // generated the event. You can pass NULL for the device if you want to move
    // the cursor around without any input.
    motionnotify(event.time_msec, event.device, event.delta_x, event.delta_y, event.unaccel_dx, event.unaccel_dy);
}

fn setsel(_: *wl.Listener(*wlroots.Seat.event.RequestSetSelection), event: *wlroots.Seat.event.RequestSetSelection) void {
    // This event is raised by the seat when a client wants to set the selection,
    // usually when the user copies something. wlroots allows compositors to
    // ignore such requests if they so choose, but in dwl we always honor them
    seat.setSelection(event.source, event.serial);
}

fn setpsel(_: *wl.Listener(*wlroots.Seat.event.RequestSetPrimarySelection), event: *wlroots.Seat.event.RequestSetPrimarySelection) void {
    // This event is raised by the seat when a client wants to set the selection,
    // usually when the user copies something. wlroots allows compositors to
    // ignore such requests if they so choose, but in dwl we always honor them
    seat.setPrimarySelection(event.source, event.serial);
}

fn axisnotify(_: *wl.Listener(*wlroots.Pointer.event.Axis), event: *wlroots.Pointer.event.Axis) void {
    // This event is forwarded by the cursor when a pointer emits an axis event,
    // for example when you move the scroll wheel.
    idle_notifier.notifyActivity(seat);

    // TODO: allow usage of scroll wheel for mousebindings, it can be implemented
    // by checking the event's orientation and the delta of the event
    // Notify the client with pointer focus of the axis event.
    seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
        event.relative_direction,
    );
}

fn cursorframe(_: *wl.Listener(*wlroots.Cursor), _: *wlroots.Cursor) void {
    // This event is forwarded by the cursor when a pointer emits a frame
    // event. Frame events are sent after regular pointer events to group
    // multiple events together. For instance, two axis events may happen at the
    // same time, in which case a frame event won't be sent in between.
    // Notify the client with pointer focus of the frame event.
    seat.pointerNotifyFrame();
}

fn inputdevice(_: *wl.Listener(*wlroots.InputDevice), device: *wlroots.InputDevice) void {
    // This event is raised by the backend when a new input device becomes
    // available.
    switch (device.type) {
        .keyboard => createkeyboard(device.toKeyboard()),
        .pointer => createpointer(device.toPointer()),
        // TODO handle other input device types
        else => {},
    }

    // We need to let the wlr_seat know what our capabilities are, which is
    // communiciated to the client. In dwl we always have a cursor, even if
    // there are no pointer devices, so we always include that capability.
    // TODO do we actually require a cursor?
    seat.setCapabilities(.{
        .pointer = true,
        .keyboard = (kb_group.wlr_group.devices.next != &kb_group.wlr_group.devices),
    });
}

fn createdecoration(_: *wl.Listener(*wlroots.XdgToplevelDecorationV1), deco: *wlroots.XdgToplevelDecorationV1) void {
    const c: *Client = @alignCast(@ptrCast(deco.toplevel.base.data));
    c.decoration = deco;

    const mode_listener: *wl.Listener(*wlroots.XdgToplevelDecorationV1) = &c.set_decoration_mode;
    mode_listener.setNotify(requestdecorationmode);
    deco.events.request_mode.add(mode_listener);
    errdefer mode_listener.link.remove();

    const destroy_listener: *wl.Listener(*wlroots.XdgToplevelDecorationV1) = &c.destroy_decoration;
    destroy_listener.setNotify(destroydecoration);
    deco.events.destroy.add(destroy_listener);
    errdefer destroy_listener.link.remove();

    requestdecorationmode(mode_listener, deco);
}

fn requestdecorationmode(listener: *wl.Listener(*wlroots.XdgToplevelDecorationV1), _: *wlroots.XdgToplevelDecorationV1) void {
    const c: *Client = @fieldParentPtr("set_decoration_mode", listener);
    if (!c.surface.initialized) {
        return;
    }
    const deco: *wlroots.XdgToplevelDecorationV1 = c.decoration.?;
    _ = deco.setMode(.server_side);
}
fn _requestdecorationmode(listener: *C.wl_listener, data: *anyopaque) callconv(.c) void { requestdecorationmode(@ptrCast(listener), @alignCast(@ptrCast(data))); }
comptime { @export(&_requestdecorationmode, .{ .name = "requestdecorationmode" }); }

fn destroydecoration(listener: *wl.Listener(*wlroots.XdgToplevelDecorationV1), _: *wlroots.XdgToplevelDecorationV1) void {
    const client: *Client = @fieldParentPtr("destroy_decoration", listener);
    client.destroy_decoration.link.remove();
    client.set_decoration_mode.link.remove();
}


const XyToNodeResult = union(enum) {
    none: void,
    client: struct {
        c: *Client,
        surface: ?*wlroots.Surface,
        nx: f64,
        ny: f64,
    },
    layer: struct {
        l: *C.LayerSurface,
        surface: ?*wlroots.Surface,
        nx: f64,
        ny: f64,
    },
};

fn _xytonode(
    x: f64,
    y: f64,
) XyToNodeResult {
    var nx: f64 = undefined;
    var ny: f64 = undefined;

    // Search topmost layers first
    var it = std.mem.reverseIterator(&layers);
    while (it.next()) |layer| {
        const node = layer.node.at(x, y, &nx, &ny) orelse continue;
        const surface = if (node.type == .buffer) wlroots.SceneSurface.tryFromBuffer(wlroots.SceneBuffer.fromNode(node)).?.*.surface else null;

        // Walk the tree to find a node that knows the client
        var pnode: ?*wlroots.SceneNode = node;
        while (pnode) |current| {
            if (current.data) |client| {
                return switch (@as(*Client, @alignCast(@ptrCast(client))).type) {
                    .layer_shell => .{ .layer = .{
                        .l = @alignCast(@ptrCast(client)),
                        .surface = surface,
                        .nx = nx,
                        .ny = ny,
                    }},
                    else => .{ .client = .{
                        .c = @alignCast(@ptrCast(client)),
                        .surface = surface,
                        .nx = nx,
                        .ny = ny,
                    }},
                };
            }
            pnode = if (current.parent) |p| &p.node else null;
        }
    }
    return .none;
}

export fn xytonode(
    x: f64,
    y: f64,
    psurface: ?*?*wlroots.Surface,
    pc: ?*?*Client,
    pl: ?*?*C.LayerSurface,
    nx: ?*f64,
    ny: ?*f64,
) void {
    switch (_xytonode(x, y)) {
        .none => {
            if (psurface) |p| p.* = null;
            if (pc) |p| p.* = null;
            if (pl) |p| p.* = null;
        },
        .client => |result| {
            if (psurface) |p| p.* = result.surface;
            if (pc) |p| p.* = result.c;
            if (pl) |p| p.* = null;
            if (nx) |p| p.* = result.nx;
            if (ny) |p| p.* = result.ny;
        },
        .layer => |result| {
            if (psurface) |p| p.* = result.surface;
            if (pc) |p| p.* = null;
            if (pl) |p| p.* = result.l;
            if (nx) |p| p.* = result.nx;
            if (ny) |p| p.* = result.ny;
        },
    }
}

extern fn arrange(m: ?*Monitor) void;
extern fn buttonpress(*wl.Listener(*wlroots.Pointer.event.Button), *wlroots.Pointer.event.Button) void;
fn _buttonpress(l: *wl.Listener(*wlroots.Pointer.event.Button), event: *wlroots.Pointer.event.Button) void { buttonpress(l, event); }
extern fn checkidleinhibitor(exclude: ?*wlroots.Surface) void;
extern fn createkeyboardgroup() *KeyboardGroup;
extern fn createlayersurface(*wl.Listener(*wlroots.LayerSurfaceV1), *wlroots.LayerSurfaceV1) void;
fn _createlayersurface(l: *wl.Listener(*wlroots.LayerSurfaceV1), event: *wlroots.LayerSurfaceV1) void { createlayersurface(l, event); }
extern fn createmon(*wl.Listener(*wlroots.Output), *wlroots.Output) void;
fn _createmon(l: *wl.Listener(*wlroots.Output), event: *wlroots.Output) void { createmon(l, event); }
extern fn createnotify(*wl.Listener(*wlroots.XdgToplevel), *wlroots.XdgToplevel) void;
fn _createnotify(l: *wl.Listener(*wlroots.XdgToplevel), event: *wlroots.XdgToplevel) void { createnotify(l, event); }
extern fn createpointer(*wlroots.Pointer) void;
extern fn createpointerconstraint(*wl.Listener(*wlroots.PointerConstraintV1), *wlroots.PointerConstraintV1) void;
fn _createpointerconstraint(l: *wl.Listener(*wlroots.PointerConstraintV1), event: *wlroots.PointerConstraintV1) void { createpointerconstraint(l, event); }
extern fn createpopup(*wl.Listener(*wlroots.XdgPopup), *wlroots.XdgPopup) void;
fn _createpopup(l: *wl.Listener(*wlroots.XdgPopup), event: *wlroots.XdgPopup) void { createpopup(l, event); }
extern fn die(fmt: [*:0]const u8, ...) noreturn;
extern fn focusclient(c: ?*Client, lift: c_int) void;
extern fn focustop(mon: ?*Monitor) ?*Client;
extern fn handlesig(signo: c_int) void;
extern fn locksession(*wl.Listener(*wlroots.SessionLockV1), *wlroots.SessionLockV1) void;
fn _locksession(l: *wl.Listener(*wlroots.SessionLockV1), event: *wlroots.SessionLockV1) void { locksession(l, event); }
extern fn outputmgrapply(*wl.Listener(*wlroots.OutputConfigurationV1), *wlroots.OutputConfigurationV1) void;
fn _outputmgrapply(l: *wl.Listener(*wlroots.OutputConfigurationV1), output_config: *wlroots.OutputConfigurationV1) void { outputmgrapply(l, output_config); }
extern fn outputmgrtest(*wl.Listener(*wlroots.OutputConfigurationV1), *wlroots.OutputConfigurationV1) void;
fn _outputmgrtest(l: *wl.Listener(*wlroots.OutputConfigurationV1), config_head: *wlroots.OutputConfigurationV1) void { outputmgrtest(l, config_head); }
extern fn printstatus() void;
extern fn setcursorshape(*wl.Listener(*wlroots.CursorShapeManagerV1.event.RequestSetShape), *wlroots.CursorShapeManagerV1.event.RequestSetShape) void;
fn _setcursorshape(l: *wl.Listener(*wlroots.CursorShapeManagerV1.event.RequestSetShape), event: *wlroots.CursorShapeManagerV1.event.RequestSetShape) void { setcursorshape(l, event); }
extern fn updatemons(_: ?*wl.Listener(*wlroots.OutputLayout), event: ?*wlroots.OutputLayout) void;
fn _updatemons(l: *wl.Listener(*wlroots.OutputLayout), event: *wlroots.OutputLayout) void { updatemons(l, event); }
