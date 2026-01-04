// KDE server decoration has no zig-wlroots binding

const XdgServerDecorationManager = @This();
const C = @import("C");
const wlroots = @import("wlroots");
const wl = @import("wayland").server.wl;

handle: *C.wlr_server_decoration_manager,

pub const Mode = enum(u32) {
    none = C.WLR_SERVER_DECORATION_MANAGER_MODE_NONE,
    server = C.WLR_SERVER_DECORATION_MANAGER_MODE_SERVER,
    client = C.WLR_SERVER_DECORATION_MANAGER_MODE_CLIENT,
};

pub fn create(server: *wl.Server) !XdgServerDecorationManager {
    const dpy: *C.wl_display = @ptrCast(server);
    return .{
        .handle = C.wlr_server_decoration_manager_create(dpy) orelse return error.OutOfMemory,
    };
}

pub fn setDefaultMode(self: XdgServerDecorationManager, default_mode: Mode) void {
    C.wlr_server_decoration_manager_set_default_mode(self.handle, @intFromEnum(default_mode));
}
