const std = @import("std");
const flags = @import("flags");

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

    setup();
    run(if (options.@"startup-cmd") |cmd| cmd.ptr else null);
    cleanup();
}

extern fn setup() void;
extern fn run(startup_cmd: ?[*:0]const u8) void;
extern fn cleanup() void;
extern fn die(fmt: [*:0]const u8, ...) noreturn;
