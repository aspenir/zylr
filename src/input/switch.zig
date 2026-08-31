const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const ServerContext = @import("../server.zig");
const config = @import("../config.zig");
const KeyboardContext = @import("keyboard.zig");

const SwitchContext = @This();

switch_device: *wlroots.Switch,
context: *ServerContext,

toggle_listener: wl.Listener(*wlroots.Switch.event.Toggle) = undefined,
destroy_listener: wl.Listener(*wlroots.InputDevice) = undefined,

pub fn init(context: *ServerContext, device: *wlroots.InputDevice) !*SwitchContext {
    const switch_device = device.toSwitch();

    const self = try std.heap.c_allocator.create(SwitchContext);
    self.* = .{
        .switch_device = switch_device,
        .context = context,
    };

    self.toggle_listener = wl.Listener(*wlroots.Switch.event.Toggle).init(onToggle);
    self.destroy_listener = wl.Listener(*wlroots.InputDevice).init(onDestroy);

    switch_device.events.toggle.add(&self.toggle_listener);
    device.events.destroy.add(&self.destroy_listener);

    return self;
}

fn onDestroy(listener: *wl.Listener(*wlroots.InputDevice), _: *wlroots.InputDevice) void {
    const self: *SwitchContext = @fieldParentPtr("destroy_listener", listener);
    self.toggle_listener.link.remove();
    self.destroy_listener.link.remove();
    std.heap.c_allocator.destroy(self);
}

fn onToggle(listener: *wl.Listener(*wlroots.Switch.event.Toggle), event: *wlroots.Switch.event.Toggle) void {
    const self: *SwitchContext = @fieldParentPtr("toggle_listener", listener);
    const st: config.SwitchType = switch (event.switch_type) {
        .lid => .lid,
        .tablet_mode => .tablet_mode,
    };
    const state: config.SwitchState = switch (event.switch_state) {
        .on => .on,
        .off => .off,
    };
    fire(self.context, st, state);
}

fn matchSwitch(switches: []const config.CompiledSwitch, switch_type: config.SwitchType, state: config.SwitchState) ?config.CompiledSwitch {
    for (switches) |s| {
        if (s.switch_type == switch_type and s.state == state) return s;
    }
    return null;
}

pub fn fire(context: *ServerContext, switch_type: config.SwitchType, state: config.SwitchState) void {
    const s = matchSwitch(context.switches, switch_type, state) orelse {
        std.log.debug("switch: {s} {s} no bind", .{ @tagName(switch_type), @tagName(state) });
        return;
    };
    std.log.info("switch: {s} {s} -> {s}", .{ @tagName(s.switch_type), @tagName(s.state), @tagName(s.action) });
    KeyboardContext.runAction(context, s.action, s.args, null);
}

test "matchSwitch lid/tablet_mode on/off" {
    const switches = [_]config.CompiledSwitch{
        .{ .switch_type = .lid, .state = .off, .action = .spawn, .args = &.{"lock"} },
        .{ .switch_type = .lid, .state = .on, .action = .spawn, .args = &.{"lock --off"} },
        .{ .switch_type = .tablet_mode, .state = .on, .action = .spawn, .args = &.{"notify"} },
    };
    try std.testing.expectEqual(config.Action.spawn, matchSwitch(&switches, .lid, .off).?.action);
    try std.testing.expectEqualStrings("lock", matchSwitch(&switches, .lid, .off).?.args[0]);
    try std.testing.expectEqual(config.Action.spawn, matchSwitch(&switches, .tablet_mode, .on).?.action);
    try std.testing.expectEqual(null, matchSwitch(&switches, .tablet_mode, .off));
}
