const std = @import("std");
const wl = @import("wayland").server.wl;
const ServerContext = @import("server.zig");
const Spawner = @import("spawner.zig");

const c = @cImport({
    @cInclude("systemd/sd-bus.h");
});

/// lock_before_suspend: listens for logind's PrepareForSleep signal on the
/// system bus and runs the configured lock_command before the system
/// suspends, so a password prompt is on screen when it wakes.
pub const SuspendContext = @This();

context: *ServerContext,
bus: ?*c.sd_bus = null,
match_slot: ?*c.sd_bus_slot = null,
bus_source: ?*wl.EventSource = null,

pub fn init(context: *ServerContext) void {
    const self = std.heap.c_allocator.create(SuspendContext) catch {
        std.log.err("suspend: OOM, lock-before-suspend disabled", .{});
        return;
    };
    self.* = .{ .context = context };

    if (c.sd_bus_default_system(&self.bus) < 0) {
        std.log.err("suspend: cannot reach system bus, lock-before-suspend disabled", .{});
        return;
    }

    const match = "sender='org.freedesktop.login1',type='signal'," ++
        "interface='org.freedesktop.login1.Manager',member='PrepareForSleep'," ++
        "path='/org/freedesktop/login1'";
    if (c.sd_bus_add_match(self.bus, &self.match_slot, match, onPrepareForSleep, self) < 0) {
        std.log.err("suspend: sd_bus_add_match failed, lock-before-suspend disabled", .{});
        return;
    }

    const fd = c.sd_bus_get_fd(self.bus);
    if (fd < 0) {
        std.log.err("suspend: sd_bus_get_fd failed", .{});
        return;
    }
    self.bus_source = wl.EventLoop.addFd(
        context.server.getEventLoop(),
        *SuspendContext,
        fd,
        .{ .readable = true },
        onBusFd,
        self,
    ) catch {
        std.log.err("suspend: cannot add bus fd to event loop", .{});
        return;
    };
    std.log.info("suspend: watching login1 PrepareForSleep", .{});
}

fn onPrepareForSleep(
    message: ?*c.sd_bus_message,
    userdata: ?*anyopaque,
    err: ?*c.sd_bus_error,
) callconv(.c) c_int {
    _ = err;
    const self: *SuspendContext = @ptrCast(@alignCast(userdata orelse return 0));

    var sleeping: c_int = 0;
    if (c.sd_bus_message_read(message, "b", &sleeping) < 0) return 0;
    if (sleeping == 0) return 0;

    const cmd = self.context.cfg.lock_command;
    if (cmd.len == 0) return 0;

    std.log.info("system suspending; running lock_command", .{});
    Spawner.launchProgram(self.context, self.context.environ_map, cmd);
    return 0;
}

fn onBusFd(fd: c_int, mask: wl.EventMask, data: *SuspendContext) c_int {
    _ = fd;
    _ = mask;
    const self = data;
    while (c.sd_bus_process(self.bus, null) > 0) {}
    return 0;
}
