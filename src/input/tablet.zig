const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const ServerContext = @import("../server.zig");
const nd = @import("../view/utils/node_data.zig");

const View = @import("../view/view.zig");
const Layer = @import("../view/layer.zig");
const TabletContext = @This();

tablet: *wlroots.Tablet,
v2_tablet: *wlroots.TabletV2Tablet,
context: *ServerContext,

axis_listener: wl.Listener(*wlroots.Tablet.event.Axis) = undefined,
proximity_listener: wl.Listener(*wlroots.Tablet.event.Proximity) = undefined,
tip_listener: wl.Listener(*wlroots.Tablet.event.Tip) = undefined,
button_listener: wl.Listener(*wlroots.Tablet.event.Button) = undefined,
device_destroy_listener: wl.Listener(*wlroots.InputDevice) = undefined,

pub fn init(
    context: *ServerContext,
    device: *wlroots.InputDevice,
) !*TabletContext {
    const tablet = device.toTablet();

    const v2_tablet = try context.tablet_manager.createTabletV2Tablet(
        context.seat,
        device,
    );

    const self = std.heap.c_allocator.create(TabletContext) catch return error.OutOfMemory;
    self.* = .{
        .tablet = tablet,
        .v2_tablet = v2_tablet,
        .context = context,
    };

    self.axis_listener = wl.Listener(*wlroots.Tablet.event.Axis).init(onAxis);
    self.proximity_listener = wl.Listener(*wlroots.Tablet.event.Proximity).init(onProximity);
    self.tip_listener = wl.Listener(*wlroots.Tablet.event.Tip).init(onTip);
    self.button_listener = wl.Listener(*wlroots.Tablet.event.Button).init(onButton);
    self.device_destroy_listener = wl.Listener(*wlroots.InputDevice).init(onDeviceDestroy);

    tablet.events.axis.add(&self.axis_listener);
    tablet.events.proximity.add(&self.proximity_listener);
    tablet.events.tip.add(&self.tip_listener);
    tablet.events.button.add(&self.button_listener);
    device.events.destroy.add(&self.device_destroy_listener);

    return self;
}

fn onDeviceDestroy(
    listener: *wl.Listener(*wlroots.InputDevice),
    _: *wlroots.InputDevice,
) void {
    const self: *TabletContext =
        @fieldParentPtr("device_destroy_listener", listener);

    self.axis_listener.link.remove();
    self.proximity_listener.link.remove();
    self.tip_listener.link.remove();
    self.button_listener.link.remove();
    self.device_destroy_listener.link.remove();

    std.heap.c_allocator.destroy(self);
}

fn getTool(
    self: *TabletContext,
    wlr_tool: *wlroots.TabletTool,
) ?*wlroots.TabletV2TabletTool {
    if (wlr_tool.data) |data| {
        return @ptrCast(@alignCast(data));
    }

    const tool = self.context.tablet_manager.createTabletV2TabletTool(
        self.context.seat,
        wlr_tool,
    ) catch return null;
    wlr_tool.data = tool;
    return tool;
}

fn surfaceAt(
    context: *ServerContext,
    x: f64,
    y: f64,
) ?*wlroots.Surface {
    const hit = nd.resolveAt(&context.scene.tree, x, y) orelse return null;

    return switch (hit.data.*) {
        .view => |view| @as(*View, @ptrCast(@alignCast(view))).surface(),
        .layer => |layer| @as(*Layer, @ptrCast(@alignCast(layer))).layer_surface.surface,
        .im_popup => null,
        .popup => |popup| @as(*wlroots.XdgPopup, @ptrCast(@alignCast(popup))).base.surface,
    };
}

fn toolPosition(
    self: *TabletContext,
    x: f64,
    y: f64,
) struct { ox: f64, oy: f64 } {
    const output = self.context.output orelse return .{ .ox = 0, .oy = 0 };

    var ow: c_int = 0;
    var oh: c_int = 0;
    output.effectiveResolution(&ow, &oh);

    return .{
        .ox = x * @as(f64, @floatFromInt(ow)),
        .oy = y * @as(f64, @floatFromInt(oh)),
    };
}

pub fn onAxis(
    listener: *wl.Listener(*wlroots.Tablet.event.Axis),
    event: *wlroots.Tablet.event.Axis,
) void {
    const self: *TabletContext = @fieldParentPtr("axis_listener", listener);
    if (self.context.idle) |idle| idle.notifyActivity();

    const tool = self.getTool(event.tool) orelse return;

    const pos = self.toolPosition(event.x, event.y);
    wlroots.TabletV2TabletTool.notifyMotion(tool, pos.ox, pos.oy);

    if (event.updated_axes.pressure) {
        wlroots.TabletV2TabletTool.notifyPressure(tool, event.pressure);
    }
    if (event.updated_axes.distance) {
        wlroots.TabletV2TabletTool.notifyDistance(tool, event.distance);
    }
    if (event.updated_axes.tilt_x or event.updated_axes.tilt_y) {
        wlroots.TabletV2TabletTool.notifyTilt(tool, event.tilt_x, event.tilt_y);
    }
    if (event.updated_axes.rotation) {
        wlroots.TabletV2TabletTool.notifyRotation(tool, event.rotation);
    }
    if (event.updated_axes.slider) {
        wlroots.TabletV2TabletTool.notifySlider(tool, event.slider);
    }
    if (event.updated_axes.wheel) {
        wlroots.TabletV2TabletTool.notifyWheel(tool, event.wheel_delta, 0);
    }
}

pub fn onProximity(
    listener: *wl.Listener(*wlroots.Tablet.event.Proximity),
    event: *wlroots.Tablet.event.Proximity,
) void {
    const self: *TabletContext = @fieldParentPtr("proximity_listener", listener);

    const tool = self.getTool(event.tool) orelse return;

    if (event.state == .out) {
        wlroots.TabletV2TabletTool.notifyProximityOut(tool);
        return;
    }

    const pos = self.toolPosition(event.x, event.y);
    const surface = surfaceAt(self.context, pos.ox, pos.oy) orelse return;

    wlroots.TabletV2TabletTool.notifyProximityIn(tool, self.v2_tablet, surface);
}

pub fn onTip(
    listener: *wl.Listener(*wlroots.Tablet.event.Tip),
    event: *wlroots.Tablet.event.Tip,
) void {
    const self: *TabletContext = @fieldParentPtr("tip_listener", listener);
    if (self.context.idle) |idle| idle.notifyActivity();

    const tool = self.getTool(event.tool) orelse return;

    if (event.state == .down) {
        wlroots.TabletV2TabletTool.notifyDown(tool);
    } else {
        wlroots.TabletV2TabletTool.notifyUp(tool);
    }
}

pub fn onButton(
    listener: *wl.Listener(*wlroots.Tablet.event.Button),
    event: *wlroots.Tablet.event.Button,
) void {
    const self: *TabletContext = @fieldParentPtr("button_listener", listener);
    if (self.context.idle) |idle| idle.notifyActivity();

    const tool = self.getTool(event.tool) orelse return;

    wlroots.TabletV2TabletTool.notifyButton(tool, event.button, event.state);
}
