const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const ServerContext = @import("../server.zig");
const config = @import("../config.zig");
const GestureContext = @import("gesture.zig");
const nd = @import("../view/utils/node_data.zig");
const FocusManager = @import("../view/focus.zig");
const ViewManager = @import("../view/view_manager.zig");
const LayerView = @import("../view/layer.zig");
const View = @import("../view/view.zig");

const TouchContext = @This();

const max_points = 5;

const Point = struct { id: i32 = -1, x: f64 = 0, y: f64 = 0, down_at: u32 = 0 };

touch: *wlroots.Touch,
context: *ServerContext,

// Touchscreen gesture tracking.
gesture_fingers: u32 = 0, // max simultaneous fingers this gesture
blip_lifts: u32 = 0, // fingers that tapped & lifted mid-gesture
swipe_dx: f64 = 0, // centroid displacement in output px
swipe_dy: f64 = 0,
swipe_started: bool = false, // a 1-finger flick in progress
last_cx: f64 = 0,
last_cy: f64 = 0,
down_time: u32 = 0,

// Multi-touch gesture detection. libinput refuses to interpret
// touchscreen gestures, so pinch/hold/swipe binds are matched here from
// raw touch points and dispatched through the same gesture table.
device_kind: config.GestureDevice = .both,
points: [max_points]Point = @splat(.{}),
baselines: [max_points]Point = @splat(.{}),
pinch_active: bool = false,
scale_start: f64 = 0, // mean finger distance at pinch start (normalized)
pinch_fired: bool = false,
hold_pending: bool = false,
hold_timer: ?*wl.EventSource = null,

down_listener: wl.Listener(*wlroots.Touch.event.Down) = undefined,
up_listener: wl.Listener(*wlroots.Touch.event.Up) = undefined,
motion_listener: wl.Listener(*wlroots.Touch.event.Motion) = undefined,
cancel_listener: wl.Listener(*wlroots.Touch.event.Cancel) = undefined,
frame_listener: wl.Listener(void) = undefined,
device_destroy_listener: wl.Listener(*wlroots.InputDevice) = undefined,

pub fn init(
    context: *ServerContext,
    device: *wlroots.InputDevice,
) !*TouchContext {
    const touch = device.toTouch();

    const self = std.heap.c_allocator.create(TouchContext) catch return error.OutOfMemory;
    self.* = .{
        .touch = touch,
        .context = context,
    };

    self.down_listener = wl.Listener(*wlroots.Touch.event.Down).init(onDown);
    self.up_listener = wl.Listener(*wlroots.Touch.event.Up).init(onUp);
    self.motion_listener = wl.Listener(*wlroots.Touch.event.Motion).init(onMotion);
    self.cancel_listener = wl.Listener(*wlroots.Touch.event.Cancel).init(onCancel);
    self.frame_listener = wl.Listener(void).init(onFrame);
    self.device_destroy_listener = wl.Listener(*wlroots.InputDevice).init(onDeviceDestroy);

    self.device_kind = GestureContext.classify(device);
    self.hold_timer = context.server.getEventLoop().addTimer(
        *TouchContext,
        onHoldTimer,
        self,
    ) catch null;

    touch.events.down.add(&self.down_listener);
    touch.events.up.add(&self.up_listener);
    touch.events.motion.add(&self.motion_listener);
    touch.events.cancel.add(&self.cancel_listener);
    touch.events.frame.add(&self.frame_listener);
    device.events.destroy.add(&self.device_destroy_listener);

    return self;
}

fn onDeviceDestroy(
    listener: *wl.Listener(*wlroots.InputDevice),
    _: *wlroots.InputDevice,
) void {
    const self: *TouchContext =
        @fieldParentPtr("device_destroy_listener", listener);

    self.down_listener.link.remove();
    self.up_listener.link.remove();
    self.motion_listener.link.remove();
    self.cancel_listener.link.remove();
    self.frame_listener.link.remove();
    self.device_destroy_listener.link.remove();
    if (self.hold_timer) |timer| timer.remove();

    std.heap.c_allocator.destroy(self);
}

fn pointIndex(self: *TouchContext, id: i32) ?usize {
    for (&self.points, 0..) |*p, i| {
        if (p.id == id) return i;
    }
    return null;
}

fn freeSlot(self: *TouchContext) ?usize {
    for (&self.points, 0..) |*p, i| {
        if (p.id == -1) return i;
    }
    return null;
}

/// Fingers actually taking part: max simultaneous count minus blips.
fn activeFingers(self: *TouchContext) u32 {
    return self.gesture_fingers -| self.blip_lifts;
}

fn swipeMagPx(self: *TouchContext) f64 {
    return @sqrt(self.swipe_dx * self.swipe_dx + self.swipe_dy * self.swipe_dy);
}

fn minDimPx(self: *TouchContext) f64 {
    const output = self.context.output orelse return 1;
    var ow: c_int = 0;
    var oh: c_int = 0;
    output.effectiveResolution(&ow, &oh);
    return @floatFromInt(@max(1, @min(ow, oh)));
}

/// Pinch span change in output px, comparable to centroid motion px.
fn spanChangePx(self: *TouchContext, ratio: f64) f64 {
    return @abs(ratio - 1) * self.scale_start * self.minDimPx();
}

fn countPoints(self: *TouchContext) u32 {
    var n: u32 = 0;
    for (&self.points) |*p| {
        if (p.id != -1) n += 1;
    }
    return n;
}

/// Centroid of the active touch points, in normalized coords.
/// Branchless 8-lane gather: inactive slots carry zero coords (set by
/// onUp/onCancel) so they contribute nothing, then a vector reduce
/// divides by the active count.
fn centroid(self: *TouchContext) Point {
    const n = self.countPoints();
    if (n == 0) return .{};
    const Vec = @Vector(8, f64);
    var vx: Vec = @splat(0);
    var vy: Vec = @splat(0);
    comptime var i: usize = 0;
    inline while (i < max_points) : (i += 1) {
        vx[i] = self.points[i].x;
        vy[i] = self.points[i].y;
    }
    const denom: f64 = @floatFromInt(n);
    return .{ .x = @reduce(.Add, vx) / denom, .y = @reduce(.Add, vy) / denom };
}

/// Mean distance of the active points from their centroid, normalized.
/// Ratios of this are scale-invariant, so normalization is fine, and it
/// works for any finger count (2, 3, ...).
fn meanDist(self: *TouchContext) f64 {
    const n = self.countPoints();
    if (n == 0) return 0;
    const c = self.centroid();
    const Vec = @Vector(8, f64);
    var vx: Vec = @splat(0);
    var vy: Vec = @splat(0);
    // Empty slots must not contribute: they sit at (0,0), which is not
    // at the centroid, so their distance to it is nonzero garbage.
    var mask: Vec = @splat(0);
    comptime var i: usize = 0;
    inline while (i < max_points) : (i += 1) {
        vx[i] = self.points[i].x - c.x;
        vy[i] = self.points[i].y - c.y;
        mask[i] = if (self.points[i].id == -1) 0.0 else 1.0;
    }
    const d: Vec = @sqrt(vx * vx + vy * vy) * mask;
    return @reduce(.Add, d) / @as(f64, @floatFromInt(n));
}

fn armHold(self: *TouchContext) void {
    self.baselines = self.points;
    self.hold_pending = true;
    if (self.hold_timer) |timer| {
        timer.timerUpdate(@intCast(self.context.cfg.gestures.touch.hold_ms)) catch {};
    }
}

fn cancelHold(self: *TouchContext) void {
    self.hold_pending = false;
    if (self.hold_timer) |timer| {
        timer.timerUpdate(0) catch {};
    }
}

fn onHoldTimer(data: *TouchContext) c_int {
    data.hold_pending = false;
    GestureContext.fire(data.context, data.device_kind, data.countPoints(), .hold, null, null);
    return 0;
}

fn position(
    self: *TouchContext,
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

fn surfaceAt(
    context: *ServerContext,
    x: f64,
    y: f64,
) ?struct { surface: *wlroots.Surface, sx: f64, sy: f64, view: ?*View } {
    const hit = nd.resolveAt(&context.scene.tree, x, y) orelse return null;

    switch (hit.data.*) {
        .view => |view| {
            const view_ptr: *View = @ptrCast(@alignCast(view));
            return .{
                .surface = hit.surface orelse view_ptr.surface(),
                .sx = hit.sx,
                .sy = hit.sy,
                .view = view_ptr,
            };
        },
        .layer => |layer| {
            const layer_ptr: *LayerView = @ptrCast(@alignCast(layer));
            return .{
                .surface = layer_ptr.layer_surface.surface,
                .sx = hit.sx,
                .sy = hit.sy,
                .view = null,
            };
        },
        .im_popup => |popup_raw| {
            const popup: *wlroots.InputPopupSurfaceV2 = @ptrCast(@alignCast(popup_raw));
            return .{
                .surface = popup.surface,
                .sx = hit.sx,
                .sy = hit.sy,
                .view = null,
            };
        },
        .popup => |popup_raw| {
            const popup: *wlroots.XdgPopup = @ptrCast(@alignCast(popup_raw));
            return .{
                .surface = popup.base.surface,
                .sx = hit.sx,
                .sy = hit.sy,
                .view = null,
            };
        },
    }
}

pub fn onDown(
    listener: *wl.Listener(*wlroots.Touch.event.Down),
    event: *wlroots.Touch.event.Down,
) void {
    const self: *TouchContext = @fieldParentPtr("down_listener", listener);
    if (self.context.idle) |idle| idle.notifyActivity();

    const pos = self.position(event.x, event.y);
    const hit = surfaceAt(self.context, pos.ox, pos.oy) orelse return;

    // Focus the touched view so keyboard bindings (Mod+Q etc.) target it.
    if (hit.view) |view| {
        FocusManager.setFocus(self.context, .{
            .view = .{
                .view = view,
                .surface = hit.surface,
                .sx = hit.sx,
                .sy = hit.sy,
            },
        });
        // Touching a window hanging off-screen brings it in.
        ViewManager.scrollIntoView(self.context, view);
    }

    self.cancelHold();

    if (self.pointIndex(event.touch_id) == null) {
        if (self.freeSlot()) |slot| {
            self.points[slot] = .{ .id = event.touch_id, .x = event.x, .y = event.y, .down_at = event.time_msec };
        }
    }
    const n = self.countPoints();
    if (n > self.gesture_fingers) self.gesture_fingers = n;

    if (n == 1) {
        // 1-finger: track a potential flick or slow window drag.
        self.swipe_started = true;
        self.swipe_dx = 0;
        self.swipe_dy = 0;
        self.last_cx = pos.ox;
        self.last_cy = pos.oy;
        self.down_time = event.time_msec;
    } else {
        // Multi-finger: start pinch tracking on transition to n >= 2.
        self.swipe_started = false;
        if (!self.pinch_active) {
            self.pinch_active = true;
            self.scale_start = self.meanDist();
            self.pinch_fired = false;
            self.swipe_dx = 0;
            self.swipe_dy = 0;
            self.last_cx = pos.ox;
            self.last_cy = pos.oy;
        } else {
            // Another finger landed mid-gesture: re-baseline the span so
            // the finger count that settles (3rd/4th arriving late)
            // defines the pinch, not the interim 2-finger span.
            self.scale_start = self.meanDist();
        }
    }
    self.armHold();

    _ = self.context.seat.touchNotifyDown(
        hit.surface,
        event.time_msec,
        event.touch_id,
        hit.sx,
        hit.sy,
    );
}

pub fn onUp(
    listener: *wl.Listener(*wlroots.Touch.event.Up),
    event: *wlroots.Touch.event.Up,
) void {
    const self: *TouchContext = @fieldParentPtr("up_listener", listener);

    var blip = false;
    if (self.pointIndex(event.touch_id)) |i| {
        if (event.time_msec - self.points[i].down_at < self.context.cfg.gestures.touch.blip_ms) blip = true;
        self.points[i] = .{};
    }
    const remaining = self.countPoints();
    self.cancelHold();
    // A quick tap while the gesture continues is noise; exclude it.
    if (blip and remaining >= 1) self.blip_lifts +|= 1;

    if (remaining == 0) {
        // Gesture finished: all fingers up.
        const fingers = self.activeFingers();
        const touch_cfg = self.context.cfg.gestures.touch;
        const threshold = touch_cfg.swipe_min_px;
        const move_px = self.swipeMagPx();
        const ratio = if (self.scale_start > 0) self.meanDist() / self.scale_start else 1;
        const span_px = self.spanChangePx(ratio);

        if (self.swipe_started and fingers == 1) {
            // A fast flick (<250ms) is a configurable 1-finger swipe bind;
            // a slower drag already moved the window live in onMotion.
            const elapsed = event.time_msec - self.down_time;
            if (elapsed < touch_cfg.flick_max_ms and move_px > threshold) {
                const dir: ?config.GestureDir = blk: {
                    if (@abs(self.swipe_dx) > @abs(self.swipe_dy)) {
                        break :blk if (self.swipe_dx < 0) .left else .right;
                    }
                    break :blk if (self.swipe_dy < 0) .up else .down;
                };
                GestureContext.fire(self.context, self.device_kind, 1, .swipe, dir, null);
            }
        } else if (self.pinch_active) {
            // Swipe vs pinch: whichever signal dominates wins. A pinch
            // that stayed below the fire threshold still counts if its
            // span change dominates centroid motion.
            if (!self.pinch_fired and (ratio >= touch_cfg.pinch_ratio or ratio <= 1 / touch_cfg.pinch_ratio) and span_px >= move_px) {
                GestureContext.fire(self.context, self.device_kind, fingers, .pinch, if (ratio > 1) .out else .in, null);
            } else if (move_px > threshold and move_px > span_px) {
                // Multi-finger swipe that never became a pinch.
                const dir: ?config.GestureDir = blk: {
                    if (@abs(self.swipe_dx) > @abs(self.swipe_dy)) {
                        break :blk if (self.swipe_dx < 0) .left else .right;
                    }
                    break :blk if (self.swipe_dy < 0) .up else .down;
                };
                GestureContext.fire(self.context, self.device_kind, fingers, .swipe, dir, null);
            }
        }

        self.pinch_active = false;
        self.swipe_started = false;
        self.gesture_fingers = 0;
        self.blip_lifts = 0;
    } else if (remaining >= 1) {
        // Fingers still down: keep/set hold for the remaining count.
        self.armHold();
    }

    _ = self.context.seat.touchNotifyUp(
        event.time_msec,
        event.touch_id,
    );
}

pub fn onMotion(
    listener: *wl.Listener(*wlroots.Touch.event.Motion),
    event: *wlroots.Touch.event.Motion,
) void {
    const self: *TouchContext = @fieldParentPtr("motion_listener", listener);
    if (self.context.idle) |idle| idle.notifyActivity();

    const pos = self.position(event.x, event.y);

    if (self.pointIndex(event.touch_id)) |i| {
        const p = &self.points[i];
        p.x = event.x;
        p.y = event.y;

        // Any finger wandering off its baseline kills a pending hold.
        if (self.hold_pending) {
            for (&self.baselines, &self.points) |*b, *q| {
                if (b.id != q.id) continue;
                if (@abs(q.x - b.x) > self.context.cfg.gestures.touch.hold_move_eps or @abs(q.y - b.y) > self.context.cfg.gestures.touch.hold_move_eps) {
                    self.cancelHold();
                    break;
                }
            }
        }
    }

    const n = self.countPoints();
    if (n >= 1) {
        // Accumulate centroid displacement (output px) for swipe
        // detection. Track the gesture centroid, not the moving finger's
        // absolute position: touch events arrive per-finger, so comparing
        // one finger's x to the previous (different) finger's x summed
        // the spread between fingers instead of the motion.
        const c = self.centroid();
        const cc = self.position(c.x, c.y);
        self.swipe_dx += cc.ox - self.last_cx;
        self.swipe_dy += cc.oy - self.last_cy;
        self.last_cx = cc.ox;
        self.last_cy = cc.oy;
    }

    if (self.pinch_active and n >= 2 and self.scale_start > 0) {
        const touch_cfg = self.context.cfg.gestures.touch;
        const ratio = self.meanDist() / self.scale_start;
        // A translation must not read as a pinch: only fire when the span
        // change dominates the centroid motion.
        const span_px = self.spanChangePx(ratio);
        if (span_px >= self.swipeMagPx() and (ratio >= touch_cfg.pinch_ratio or ratio <= 1 / touch_cfg.pinch_ratio)) {
            if (!self.pinch_fired or self.context.gesture_repeat.enabled) {
                const rep = self.context.gesture_repeat;
                const now = self.context.nowMs();
                if (rep.cooldown_ms == 0 or (now - self.context.last_gesture_fire_ms) >= rep.cooldown_ms) {
                    self.pinch_fired = true;
                    self.context.last_gesture_fire_ms = now;
                    GestureContext.fire(self.context, self.device_kind, self.activeFingers(), .pinch, if (ratio > 1) .out else .in, null);
                }
            }
        }
    }

    const hit = surfaceAt(self.context, pos.ox, pos.oy) orelse return;

    self.context.seat.touchNotifyMotion(
        event.time_msec,
        event.touch_id,
        hit.sx,
        hit.sy,
    );
}

pub fn onCancel(
    listener: *wl.Listener(*wlroots.Touch.event.Cancel),
    event: *wlroots.Touch.event.Cancel,
) void {
    const self: *TouchContext = @fieldParentPtr("cancel_listener", listener);

    if (self.context.seat.touchGetPoint(event.touch_id)) |point| {
        self.context.seat.touchNotifyCancel(point.client);
    }

    for (&self.points) |*p| p.* = .{};
    self.cancelHold();
    self.pinch_active = false;
    self.swipe_started = false;
    self.gesture_fingers = 0;
    self.blip_lifts = 0;
    self.swipe_dx = 0;
    self.swipe_dy = 0;
}

pub fn onFrame(
    listener: *wl.Listener(void),
) void {
    const self: *TouchContext = @fieldParentPtr("frame_listener", listener);

    self.context.seat.touchNotifyFrame();
}
