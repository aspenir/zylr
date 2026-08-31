const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const ServerContext = @import("../server.zig");

const TabletPadContext = @This();

pad: *wlroots.TabletPad,
v2_pad: *wlroots.TabletV2TabletPad,
context: *ServerContext,

button_listener: wl.Listener(*wlroots.TabletPad.event.Button) = undefined,
ring_listener: wl.Listener(*wlroots.TabletPad.event.Ring) = undefined,
strip_listener: wl.Listener(*wlroots.TabletPad.event.Strip) = undefined,
device_destroy_listener: wl.Listener(*wlroots.InputDevice) = undefined,

pub fn init(
    context: *ServerContext,
    device: *wlroots.InputDevice,
) !*TabletPadContext {
    const pad = device.toTabletPad();

    const v2_pad = try context.tablet_manager.createTabletV2TabletPad(
        context.seat,
        device,
    );

    const self = std.heap.c_allocator.create(TabletPadContext) catch return error.OutOfMemory;
    self.* = .{
        .pad = pad,
        .v2_pad = v2_pad,
        .context = context,
    };

    self.button_listener = wl.Listener(*wlroots.TabletPad.event.Button).init(onButton);
    self.ring_listener = wl.Listener(*wlroots.TabletPad.event.Ring).init(onRing);
    self.strip_listener = wl.Listener(*wlroots.TabletPad.event.Strip).init(onStrip);
    self.device_destroy_listener = wl.Listener(*wlroots.InputDevice).init(onDeviceDestroy);

    pad.events.button.add(&self.button_listener);
    pad.events.ring.add(&self.ring_listener);
    pad.events.strip.add(&self.strip_listener);
    device.events.destroy.add(&self.device_destroy_listener);

    return self;
}

fn onDeviceDestroy(
    listener: *wl.Listener(*wlroots.InputDevice),
    _: *wlroots.InputDevice,
) void {
    const self: *TabletPadContext =
        @fieldParentPtr("device_destroy_listener", listener);

    self.button_listener.link.remove();
    self.ring_listener.link.remove();
    self.strip_listener.link.remove();
    self.device_destroy_listener.link.remove();

    std.heap.c_allocator.destroy(self);
}

pub fn onButton(
    listener: *wl.Listener(*wlroots.TabletPad.event.Button),
    event: *wlroots.TabletPad.event.Button,
) void {
    const self: *TabletPadContext = @fieldParentPtr("button_listener", listener);
    if (self.context.idle) |idle| idle.notifyActivity();

    wlroots.TabletV2TabletPad.notifyButton(
        self.v2_pad,
        event.button,
        event.time_msec,
        event.state,
    );
}

pub fn onRing(
    listener: *wl.Listener(*wlroots.TabletPad.event.Ring),
    event: *wlroots.TabletPad.event.Ring,
) void {
    const self: *TabletPadContext = @fieldParentPtr("ring_listener", listener);

    wlroots.TabletV2TabletPad.notifyRing(
        self.v2_pad,
        event.ring,
        event.position,
        event.source == .finger,
        event.time_msec,
    );
}

pub fn onStrip(
    listener: *wl.Listener(*wlroots.TabletPad.event.Strip),
    event: *wlroots.TabletPad.event.Strip,
) void {
    const self: *TabletPadContext = @fieldParentPtr("strip_listener", listener);

    wlroots.TabletV2TabletPad.notifyStrip(
        self.v2_pad,
        event.strip,
        event.position,
        event.source == .finger,
        event.time_msec,
    );
}
