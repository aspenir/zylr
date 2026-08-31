const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const ServerContext = @import("../server.zig");
const config = @import("../config.zig");
const KeyboardContext = @import("keyboard.zig");
const View = @import("../view/view.zig");
const nd = @import("../view/utils/node_data.zig");
const Action = config.Action;

const GestureContext = @This();

// libinput capability codes (LIBINPUT_DEVICE_CAP_*); used to tell
// touchscreens from touchpads so binds can target one or both.
const CAP_TOUCH: c_uint = 2;
const CAP_GESTURE: c_uint = 5;

extern fn libinput_device_has_capability(device: *anyopaque, cap: c_uint) c_int;

pointer: *wlroots.Pointer,
context: *ServerContext,
device_kind: config.GestureDevice,

swipe_begin_listener: wl.Listener(*wlroots.Pointer.event.SwipeBegin) = undefined,
swipe_update_listener: wl.Listener(*wlroots.Pointer.event.SwipeUpdate) = undefined,
swipe_end_listener: wl.Listener(*wlroots.Pointer.event.SwipeEnd) = undefined,
pinch_begin_listener: wl.Listener(*wlroots.Pointer.event.PinchBegin) = undefined,
pinch_update_listener: wl.Listener(*wlroots.Pointer.event.PinchUpdate) = undefined,
pinch_end_listener: wl.Listener(*wlroots.Pointer.event.PinchEnd) = undefined,
hold_begin_listener: wl.Listener(*wlroots.Pointer.event.HoldBegin) = undefined,
hold_end_listener: wl.Listener(*wlroots.Pointer.event.HoldEnd) = undefined,
device_destroy_listener: wl.Listener(*wlroots.InputDevice) = undefined,

fingers: u32 = 0,
dx: f64 = 0,
dy: f64 = 0,
scale: f64 = 1,

/// Touchscreen vs touchpad, from libinput caps. Touchscreens carry no
/// GESTURE cap (libinput doesn't interpret their gestures), so TOUCH is
/// checked first. Devices we can't classify match every bind.
pub fn classify(device: *wlroots.InputDevice) config.GestureDevice {
    const handle = device.getLibinputDevice() orelse return .both;
    const h: *anyopaque = @ptrCast(handle);
    if (libinput_device_has_capability(h, CAP_TOUCH) != 0) return .touch;
    if (libinput_device_has_capability(h, CAP_GESTURE) != 0) return .trackpad;
    return .both;
}

pub fn init(
    context: *ServerContext,
    device: *wlroots.InputDevice,
) !*GestureContext {
    const pointer = device.toPointer();

    const self = std.heap.c_allocator.create(GestureContext) catch return error.OutOfMemory;
    self.* = .{
        .pointer = pointer,
        .context = context,
        .device_kind = classify(device),
    };

    self.swipe_begin_listener = .init(onSwipeBegin);
    self.swipe_update_listener = .init(onSwipeUpdate);
    self.swipe_end_listener = .init(onSwipeEnd);
    self.pinch_begin_listener = .init(onPinchBegin);
    self.pinch_update_listener = .init(onPinchUpdate);
    self.pinch_end_listener = .init(onPinchEnd);
    self.hold_begin_listener = .init(onHoldBegin);
    self.hold_end_listener = .init(onHoldEnd);
    self.device_destroy_listener = .init(onDeviceDestroy);

    pointer.events.swipe_begin.add(&self.swipe_begin_listener);
    pointer.events.swipe_update.add(&self.swipe_update_listener);
    pointer.events.swipe_end.add(&self.swipe_end_listener);
    pointer.events.pinch_begin.add(&self.pinch_begin_listener);
    pointer.events.pinch_update.add(&self.pinch_update_listener);
    pointer.events.pinch_end.add(&self.pinch_end_listener);
    pointer.events.hold_begin.add(&self.hold_begin_listener);
    pointer.events.hold_end.add(&self.hold_end_listener);
    device.events.destroy.add(&self.device_destroy_listener);

    return self;
}

fn onDeviceDestroy(
    listener: *wl.Listener(*wlroots.InputDevice),
    _: *wlroots.InputDevice,
) void {
    const self: *GestureContext =
        @fieldParentPtr("device_destroy_listener", listener);

    // wlroots asserts the pointer event listener lists are empty at
    // finish time, so remove our listeners before the device dies.
    inline for (.{
        &self.swipe_begin_listener,
        &self.swipe_update_listener,
        &self.swipe_end_listener,
        &self.pinch_begin_listener,
        &self.pinch_update_listener,
        &self.pinch_end_listener,
        &self.hold_begin_listener,
        &self.hold_end_listener,
        &self.device_destroy_listener,
    }) |l| l.link.remove();

    std.heap.c_allocator.destroy(self);
}

/// First matching bind wins. A bind without `dir` matches any
/// direction; `on` must equal the classified device unless `.both`.
fn matchGesture(
    gestures: []const config.CompiledGesture,
    fingers: u32,
    kind: config.GestureKind,
    dir: ?config.GestureDir,
    device_kind: config.GestureDevice,
) ?config.CompiledGesture {
    for (gestures) |g| {
        if (g.fingers != fingers or g.kind != kind) continue;
        if (g.dir) |d| {
            if (dir != d) continue;
        }
        if (g.on != .both and g.on != device_kind) continue;
        return g;
    }
    return null;
}

/// Look up and run the first bind matching this completed gesture.
/// Shared by the libinput-gesture path and the raw-touchscreen detector.
pub fn fire(
    context: *ServerContext,
    device_kind: config.GestureDevice,
    fingers: u32,
    kind: config.GestureKind,
    dir: ?config.GestureDir,
    target_view: ?*View,
) void {
    // Cooldown between consecutive firings (config.gesture_repeat).
    if (context.gesture_repeat.cooldown_ms > 0) {
        const now = context.nowMs();
        if (now - context.last_gesture_fire_ms < context.gesture_repeat.cooldown_ms) return;
        context.last_gesture_fire_ms = now;
    }

    std.log.info("gesture: {d}-finger {s} dir={any} dev={s}", .{
        fingers,
        @tagName(kind),
        if (dir) |d| @tagName(d) else "any",
        @tagName(device_kind),
    });

    const g = matchGesture(
        context.gestures,
        fingers,
        kind,
        dir,
        device_kind,
    ) orelse return;
    const tv: ?*View = if (g.target == .under_gesture) target_view else null;
    KeyboardContext.runAction(context, g.action, g.args, tv);
}

fn dispatch(
    self: *GestureContext,
    kind: config.GestureKind,
    dir: ?config.GestureDir,
) void {
    fire(self.context, self.device_kind, self.fingers, kind, dir, viewAtCursor(self.context));
}

fn viewAtCursor(context: *ServerContext) ?*View {
    const hit = nd.resolveAt(&context.scene.tree, context.cursor.x, context.cursor.y) orelse return null;
    return switch (hit.data.*) {
        .view => |view| @as(*View, @ptrCast(@alignCast(view))),
        .layer => null,
        .im_popup => null,
        .popup => null,
    };
}

fn onSwipeBegin(
    listener: *wl.Listener(*wlroots.Pointer.event.SwipeBegin),
    event: *wlroots.Pointer.event.SwipeBegin,
) void {
    const self: *GestureContext = @fieldParentPtr("swipe_begin_listener", listener);

    self.fingers = event.fingers;
    self.dx = 0;
    self.dy = 0;

    self.context.pointer_gestures.sendSwipeBegin(
        self.context.seat,
        event.time_msec,
        event.fingers,
    );
}

fn onSwipeUpdate(
    listener: *wl.Listener(*wlroots.Pointer.event.SwipeUpdate),
    event: *wlroots.Pointer.event.SwipeUpdate,
) void {
    const self: *GestureContext = @fieldParentPtr("swipe_update_listener", listener);

    self.context.pointer_gestures.sendSwipeUpdate(
        self.context.seat,
        event.time_msec,
        event.dx,
        event.dy,
    );

    self.dx += event.dx;
    self.dy += event.dy;
}

fn onSwipeEnd(
    listener: *wl.Listener(*wlroots.Pointer.event.SwipeEnd),
    event: *wlroots.Pointer.event.SwipeEnd,
) void {
    const self: *GestureContext = @fieldParentPtr("swipe_end_listener", listener);

    // Dominant axis past the threshold names the direction; a too-short
    // swipe only matches binds that left `dir` unset.
    const dir: ?config.GestureDir = blk: {
        const threshold = self.context.cfg.gestures.trackpad.swipe_min_px;
        if (@abs(self.dx) > threshold or @abs(self.dy) > threshold) {
            if (@abs(self.dx) > @abs(self.dy)) {
                break :blk if (self.dx < 0) .left else .right;
            }
            break :blk if (self.dy < 0) .up else .down;
        }
        break :blk null;
    };
    if (!event.cancelled) self.dispatch(.swipe, dir);

    self.context.pointer_gestures.sendSwipeEnd(
        self.context.seat,
        event.time_msec,
        event.cancelled,
    );
}

fn onPinchBegin(
    listener: *wl.Listener(*wlroots.Pointer.event.PinchBegin),
    event: *wlroots.Pointer.event.PinchBegin,
) void {
    const self: *GestureContext = @fieldParentPtr("pinch_begin_listener", listener);

    self.fingers = event.fingers;
    self.scale = 1;

    self.context.pointer_gestures.sendPinchBegin(
        self.context.seat,
        event.time_msec,
        event.fingers,
    );
}

fn onPinchUpdate(
    listener: *wl.Listener(*wlroots.Pointer.event.PinchUpdate),
    event: *wlroots.Pointer.event.PinchUpdate,
) void {
    const self: *GestureContext = @fieldParentPtr("pinch_update_listener", listener);

    self.context.pointer_gestures.sendPinchUpdate(
        self.context.seat,
        event.time_msec,
        event.dx,
        event.dy,
        event.scale,
        event.rotation,
    );

    self.scale *= event.scale;
}

fn onPinchEnd(
    listener: *wl.Listener(*wlroots.Pointer.event.PinchEnd),
    event: *wlroots.Pointer.event.PinchEnd,
) void {
    const self: *GestureContext = @fieldParentPtr("pinch_end_listener", listener);

    const dir: ?config.GestureDir = blk: {
        const threshold = self.context.cfg.gestures.trackpad.pinch_scale;
        if (self.scale > 1 + threshold) break :blk .out;
        if (self.scale < 1 - threshold) break :blk .in;
        break :blk null;
    };
    if (!event.cancelled) self.dispatch(.pinch, dir);

    self.context.pointer_gestures.sendPinchEnd(
        self.context.seat,
        event.time_msec,
        event.cancelled,
    );
}

fn onHoldBegin(
    listener: *wl.Listener(*wlroots.Pointer.event.HoldBegin),
    event: *wlroots.Pointer.event.HoldBegin,
) void {
    const self: *GestureContext = @fieldParentPtr("hold_begin_listener", listener);

    self.fingers = event.fingers;

    self.context.pointer_gestures.sendHoldBegin(
        self.context.seat,
        event.time_msec,
        event.fingers,
    );
}

fn onHoldEnd(
    listener: *wl.Listener(*wlroots.Pointer.event.HoldEnd),
    event: *wlroots.Pointer.event.HoldEnd,
) void {
    const self: *GestureContext = @fieldParentPtr("hold_end_listener", listener);

    if (!event.cancelled) self.dispatch(.hold, null);

    self.context.pointer_gestures.sendHoldEnd(
        self.context.seat,
        event.time_msec,
        event.cancelled,
    );
}

test "matchGesture fingers/kind/dir/device" {
    const gestures = [_]config.CompiledGesture{
        .{ .fingers = 3, .kind = .swipe, .dir = .left, .on = .both, .action = .focus_right },
        .{ .fingers = 2, .kind = .pinch, .dir = null, .on = .trackpad, .action = .close },
        .{ .fingers = 4, .kind = .swipe, .dir = .down, .on = .touch, .action = .shrink },
    };

    // exact hit
    try std.testing.expectEqual(Action.focus_right, matchGesture(&gestures, 3, .swipe, .left, .trackpad).?.action);
    // wrong direction misses a directed bind
    try std.testing.expectEqual(null, matchGesture(&gestures, 3, .swipe, .up, .trackpad));
    // dir-less bind matches any direction, but only its device
    try std.testing.expectEqual(Action.close, matchGesture(&gestures, 2, .pinch, .out, .trackpad).?.action);
    try std.testing.expectEqual(null, matchGesture(&gestures, 2, .pinch, .out, .touch));
    // touch-only bind ignores trackpads
    try std.testing.expectEqual(null, matchGesture(&gestures, 4, .swipe, .down, .trackpad));
    try std.testing.expectEqual(Action.shrink, matchGesture(&gestures, 4, .swipe, .down, .touch).?.action);
}
