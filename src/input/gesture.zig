const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const ServerContext = @import("../server.zig");
const Config = @import("../config.zig");
const KeyboardContext = @import("keyboard.zig");
const View = @import("../view/view.zig");
const NodeData = @import("../view/utils/node_data.zig");
const Action = Config.Action;

const GestureContext = @This();

// libinput capability codes (LIBINPUT_DEVICE_CAP_*); used to tell
// touchscreens from touchpads so binds can target one or both.
const CAP_TOUCH: c_uint = 2;
const CAP_GESTURE: c_uint = 5;

extern fn libinput_device_has_capability(device: *anyopaque, cap: c_uint) c_int;

pointer: *wlroots.Pointer,
context: *ServerContext,
device_kind: Config.GestureDevice,

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
/// A repeat fired during the current gesture, so the end-of-gesture
/// dispatch is skipped (otherwise a scrub would fire once more on lift).
swipe_fired: bool = false,
pinch_fired: bool = false,
hold_fired: bool = false,
hold_timer: ?*wl.EventSource = null,

/// Set once deinit() runs. onDeviceDestroy and the shutdown loop both call
/// into teardown; without this guard a context freed at runtime could be
/// freed again at shutdown (double free -> the freed wl.Listener that
/// wlr_pointer_finish catches as a non-empty hold_end list).
freed: bool = false,

/// Touchscreen vs touchpad, from libinput caps. Touchscreens carry no
/// GESTURE cap (libinput doesn't interpret their gestures), so TOUCH is
/// checked first. Devices we can't classify match every bind.
pub fn classify(device: *wlroots.InputDevice) Config.GestureDevice {
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

    self.hold_timer = context.server.getEventLoop().addTimer(
        *GestureContext,
        onHoldTimer,
        self,
    ) catch null;

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
    if (self.freed) return;

    // Drop from the tracked list before freeing so shutdown cleanup
    // never re-visits (and re-frees) a context whose device already died.
    for (self.context.gesture_contexts.items, 0..) |gc, i| {
        if (gc == self) {
            _ = self.context.gesture_contexts.orderedRemove(i);
            break;
        }
    }

    self.deinit();
}

/// Detach every pointer signal listener and free the context. Called from
/// device teardown (onDeviceDestroy) or the shutdown path. Idempotent: the
/// second caller is a no-op, so a context freed at runtime is never freed
/// again at shutdown (which would corrupt the heap and leave a freed
/// wl.Listener linked into the pointer -> wlr_pointer_finish hold_end assert).
pub fn deinit(self: *GestureContext) void {
    if (self.freed) return;
    self.freed = true;

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
    if (self.hold_timer) |timer| timer.remove();

    std.heap.c_allocator.destroy(self);
}

/// First matching bind wins. A bind without `dir` matches any
/// direction; `on` must equal the classified device unless `.both`.
fn matchGesture(
    gestures: []const Config.CompiledGesture,
    fingers: u32,
    kind: Config.GestureKind,
    dir: ?Config.GestureDir,
    device_kind: Config.GestureDevice,
) ?Config.CompiledGesture {
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
    device_kind: Config.GestureDevice,
    fingers: u32,
    kind: Config.GestureKind,
    dir: ?Config.GestureDir,
    target_view: ?*View,
) bool {
    const g = matchGesture(
        context.gestures,
        fingers,
        kind,
        dir,
        device_kind,
    ) orelse {
        std.log.info("gesture: {d}-finger {s} dir={any} dev={s} matched=false", .{
            fingers,
            @tagName(kind),
            if (dir) |d| @tagName(d) else "any",
            @tagName(device_kind),
        });
        return false;
    };

    std.log.info("gesture: {d}-finger {s} dir={any} dev={s}", .{
        fingers,
        @tagName(kind),
        if (dir) |d| @tagName(d) else "any",
        @tagName(device_kind),
    });

    const tv: ?*View = if (g.target == .under_gesture) target_view else null;
    KeyboardContext.runAction(context, g.action, g.args, tv);
    return true;
}

/// Whether the bind this gesture would fire is labelled `repeat`, so a
/// caller can decide whether to keep re-firing while the gesture continues.
pub fn gestureRepeat(
    context: *ServerContext,
    device_kind: Config.GestureDevice,
    fingers: u32,
    kind: Config.GestureKind,
    dir: ?Config.GestureDir,
) bool {
    const g = matchGesture(context.gestures, fingers, kind, dir, device_kind) orelse
        return false;
    return g.repeat;
}

fn dispatch(
    self: *GestureContext,
    kind: Config.GestureKind,
    dir: ?Config.GestureDir,
) bool {
    return fire(self.context, self.device_kind, self.fingers, kind, dir, viewAtCursor(self.context));
}

fn dominantDir(dx: f64, dy: f64) Config.GestureDir {
    if (@abs(dx) > @abs(dy)) return if (dx < 0) .left else .right;
    return if (dy < 0) .up else .down;
}

/// Fixed interval between hold repeats. libinput emits no updates during
/// a hold, so the timer is the only repeat driver here.
const HOLD_REPEAT_MS: c_int = 100;

fn holdRepeat(self: *GestureContext) bool {
    return gestureRepeat(self.context, self.device_kind, self.fingers, .hold, null);
}

fn armHoldRepeat(self: *GestureContext) void {
    if (self.hold_timer) |timer| timer.timerUpdate(HOLD_REPEAT_MS) catch {};
}

fn onHoldTimer(data: *GestureContext) c_int {
    _ = data.dispatch(.hold, null);
    data.hold_fired = true;
    // Re-arm while the hold continues; onHoldEnd cancels it.
    if (data.holdRepeat()) data.armHoldRepeat();
    return 0;
}

fn viewAtCursor(context: *ServerContext) ?*View {
    const hit = NodeData.resolveAt(&context.scene.tree, context.cursor.x, context.cursor.y) orelse return null;
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
    self.swipe_fired = false;

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

    // Repeat: re-fire every swipe_min_px of travel so a continued swipe
    // scrubs instead of firing once on lift. Only binds labelled `repeat`;
    // `swipe_fired` just stops the end-of-gesture dispatch double-firing.
    const step = self.context.cfg.gestures.trackpad.swipe_min_px;
    if (@sqrt(self.dx * self.dx + self.dy * self.dy) > step) {
        const dir = dominantDir(self.dx, self.dy);
        const rep = gestureRepeat(self.context, self.device_kind, self.fingers, .swipe, dir);
        if ((!self.swipe_fired or rep) and self.dispatch(.swipe, dir)) {
            self.swipe_fired = true;
            if (@abs(self.dx) > @abs(self.dy)) {
                self.dx -= if (self.dx < 0) -step else step;
            } else {
                self.dy -= if (self.dy < 0) -step else step;
            }
        }
    }
}

fn onSwipeEnd(
    listener: *wl.Listener(*wlroots.Pointer.event.SwipeEnd),
    event: *wlroots.Pointer.event.SwipeEnd,
) void {
    const self: *GestureContext = @fieldParentPtr("swipe_end_listener", listener);

    // Dominant axis past the threshold names the direction; a too-short
    // swipe only matches binds that left `dir` unset.
    const dir: ?Config.GestureDir = blk: {
        const threshold = self.context.cfg.gestures.trackpad.swipe_min_px;
        if (@abs(self.dx) > threshold or @abs(self.dy) > threshold) {
            break :blk dominantDir(self.dx, self.dy);
        }
        break :blk null;
    };
    if (!event.cancelled and !self.swipe_fired) _ = self.dispatch(.swipe, dir);

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
    self.pinch_fired = false;

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

    // Repeat: re-fire each time the cumulative scale crosses pinch_scale,
    // then re-baseline so the next crossing fires again. Only binds
    // labelled `repeat`; `pinch_fired` just stops the end dispatch.
    const threshold = self.context.cfg.gestures.trackpad.pinch_scale;
    const dir: ?Config.GestureDir = if (self.scale > 1 + threshold)
        .out
    else if (self.scale < 1 - threshold)
        .in
    else
        null;
    if (dir) |d| {
        const rep = gestureRepeat(self.context, self.device_kind, self.fingers, .pinch, d);
        if ((!self.pinch_fired or rep) and self.dispatch(.pinch, d)) {
            self.pinch_fired = true;
            self.scale = 1;
        }
    }
}

fn onPinchEnd(
    listener: *wl.Listener(*wlroots.Pointer.event.PinchEnd),
    event: *wlroots.Pointer.event.PinchEnd,
) void {
    const self: *GestureContext = @fieldParentPtr("pinch_end_listener", listener);

    const dir: ?Config.GestureDir = blk: {
        const threshold = self.context.cfg.gestures.trackpad.pinch_scale;
        if (self.scale > 1 + threshold) break :blk .out;
        if (self.scale < 1 - threshold) break :blk .in;
        break :blk null;
    };
    if (!event.cancelled and !self.pinch_fired) _ = self.dispatch(.pinch, dir);

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
    self.hold_fired = false;
    // Repeat holds on a timer: libinput emits no updates while a hold
    // is active, so there is nothing else to drive the re-fire. Only
    // binds labelled `repeat`.
    if (self.holdRepeat()) self.armHoldRepeat();

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

    if (self.hold_timer) |timer| timer.timerUpdate(0) catch {};
    // Short hold that ended before the first repeat tick still fires once.
    if (!event.cancelled and !self.hold_fired) _ = self.dispatch(.hold, null);

    self.context.pointer_gestures.sendHoldEnd(
        self.context.seat,
        event.time_msec,
        event.cancelled,
    );
}

test "matchGesture fingers/kind/dir/device" {
    const gestures = [_]Config.CompiledGesture{
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
