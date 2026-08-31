const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const ServerContext = @import("server.zig");
const Config = @import("config.zig");
const Spawner = @import("spawner.zig");

pub const Idle = @This();

const max_timers = 16;

const TimerEntry = struct {
    timeout_ticks: u32,
    command: []const u8,
    remaining: u32 = 0,
};

context: *ServerContext,
inhibit_manager: *wlr.IdleInhibitManagerV1,
notifier: *wlr.IdleNotifierV1,
power_manager: *wlr.OutputPowerManagerV1,

new_inhibitor_listener: wl.Listener(*wlr.IdleInhibitorV1) = undefined,
set_mode_listener: wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode) = undefined,

timers: [max_timers]TimerEntry = undefined,
timer_count: usize = 0,
outputs_off: bool = false,
poll_source: ?*wl.EventSource = null,
poll_ms: c_int = 1000,

pub fn init(context: *ServerContext, loop: *wl.EventLoop) !void {
    const self = try std.heap.c_allocator.create(Idle);
    self.* = .{
        .context = context,
        .inhibit_manager = try wlr.IdleInhibitManagerV1.create(context.server),
        .notifier = try wlr.IdleNotifierV1.create(context.server),
        .power_manager = try wlr.OutputPowerManagerV1.create(context.server),
    };

    self.new_inhibitor_listener = wl.Listener(*wlr.IdleInhibitorV1).init(onNewInhibitor);
    self.inhibit_manager.events.new_inhibitor.add(&self.new_inhibitor_listener);

    self.set_mode_listener = wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode).init(onSetMode);
    self.power_manager.events.set_mode.add(&self.set_mode_listener);

    self.loadTimers(context.cfg.idle);
    self.startPoll(loop);

    context.idle = self;
}

fn loadTimers(self: *Idle, config_timers: []const Config.IdleTimer) void {
    const count = @min(config_timers.len, max_timers);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const ct = config_timers[i];
        if (ct.command.len == 0) continue;
        const cmd = std.heap.page_allocator.dupe(u8, ct.command) catch continue;
        const is_dpms_off = std.mem.indexOf(u8, cmd, "off") != null;
        self.timers[self.timer_count] = .{
            .timeout_ticks = ct.timeout,
            .command = cmd,
            .remaining = ct.timeout,
        };
        if (is_dpms_off) self.context.dpms_off = true;
        self.timer_count += 1;
    }
}

fn startPoll(self: *Idle, loop: *wl.EventLoop) void {
    if (self.timer_count == 0) return;
    self.poll_source = wl.EventLoop.addTimer(
        loop,
        *ServerContext,
        onPoll,
        self.context,
    ) catch return;
    self.poll_source.?.timerUpdate(self.poll_ms) catch |err| { std.log.warn("failed to update idle timer: {}", .{err}); };
}

pub fn reloadTimers(self: *Idle, context: *ServerContext) void {
    var i: usize = 0;
    while (i < self.timer_count) : (i += 1) {
        std.heap.page_allocator.free(self.timers[i].command);
    }
    self.timer_count = 0;
    self.context.dpms_off = false;
    self.loadTimers(context.cfg.idle);
    // If timers appeared where there were none, the poll loop was never
    // started; arm it now.
    if (self.timer_count > 0 and self.poll_source == null) {
        self.startPoll(context.server.getEventLoop());
    }
}

/// A key release keeps idle timers reset but must NOT power-wake the
/// outputs: letting the very key that just turned the screens off wake
/// them again on lift-off makes dpms_off only take effect while held.
pub fn notifyKeyRelease(self: *Idle) void {
    // A key release keeps idle timers reset but must NOT power-wake the
    // outputs: letting the very key that turned them off wake them again
    // on lift-off makes dpms_off only take effect while held.
    self.notifier.notifyActivity(self.context.seat);
    self.resetTimers();
}

pub fn notifyActivity(self: *Idle) void {
    self.notifier.notifyActivity(self.context.seat);

    // Wake outputs if they were turned off by idle.
    if (self.outputs_off) {
        self.outputs_off = false;
        setOutputsPower(self.context, true);
    }
    self.resetTimers();
}

fn resetTimers(self: *Idle) void {
    var i: usize = 0;
    while (i < self.timer_count) : (i += 1) {
        self.timers[i].remaining = self.timers[i].timeout_ticks;
    }
}

pub fn setOutputsPower(context: *ServerContext, on: bool) void {
    var it = context.output_layout.outputs.iterator(.forward);
    while (it.next()) |layout_output| {
        var state = wlr.Output.State.init();
        defer state.finish();
        state.setEnabled(on);
        _ = layout_output.output.commitState(&state);
    }
}

fn hasActiveInhibitors(self: *Idle) bool {
    var it = self.inhibit_manager.inhibitors.iterator(.forward);
    while (it.next()) |inhibitor| {
        if (inhibitor.surface.mapped) return true;
    }
    return false;
}

fn onNewInhibitor(
    listener: *wl.Listener(*wlr.IdleInhibitorV1),
    _: *wlr.IdleInhibitorV1,
) void {
    const self: *Idle = @fieldParentPtr("new_inhibitor_listener", listener);
    self.notifier.setInhibited(true);
}

pub fn deinit(self: *Idle) void {
    self.new_inhibitor_listener.link.remove();
    self.set_mode_listener.link.remove();
    if (self.poll_source) |src| src.remove();
    var i: usize = 0;
    while (i < self.timer_count) : (i += 1) {
        std.heap.page_allocator.free(self.timers[i].command);
    }
    std.heap.c_allocator.destroy(self);
}

fn onSetMode(
    listener: *wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode),
    event: *wlr.OutputPowerManagerV1.event.SetMode,
) void {
    _ = listener;
    const on: bool = event.mode == .on;
    var state = wlr.Output.State.init();
    defer state.finish();
    state.setEnabled(on);
    _ = event.output.commitState(&state);
}

fn onPoll(context: *ServerContext) c_int {
    const self = context.idle orelse return 1;

    if (self.hasActiveInhibitors()) {
        self.poll_source.?.timerUpdate(self.poll_ms) catch |err| { std.log.warn("failed to update idle timer: {}", .{err}); };
        return 1;
    }

    var any_running = false;
    var i: usize = 0;
    while (i < self.timer_count) : (i += 1) {
        if (self.timers[i].remaining == 0) continue;
        self.timers[i].remaining -|= 1;
        any_running = true;
        if (self.timers[i].remaining == 0) {
            std.log.info("idle: running '{s}'", .{self.timers[i].command});
            Spawner.launchProgram(
                context,
                context.environ_map,
                &.{ "sh", "-c", self.timers[i].command },
            );
            if (self.context.dpms_off) self.outputs_off = true;
            // Re-arm so the timer keeps firing on subsequent idle
            // periods instead of being exhausted forever after firing once.
            self.timers[i].remaining = self.timers[i].timeout_ticks;
        }
    }

    self.poll_source.?.timerUpdate(self.poll_ms) catch |err| { std.log.warn("failed to update idle timer: {}", .{err}); };
    return 1;
}
