const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const ServerContext = @import("../server.zig");
const NodeData = @import("../view/utils/node_data.zig");
const InputTransform = @import("input_transform.zig");

const View = @import("../view/view.zig");
const Layer = @import("../view/layer.zig");
/// Max plausible pen travel per report, normalized to the tablet (a hand
/// at full speed spans the tablet in ~10 reports, so 0.35 is ~3.5x beyond
/// physical motion). Events farther than this from the last good position
/// are transient out-of-range / border-clamped glitches.
const MAX_STEP: f64 = 0.35;
/// A pen legitimately at the screen edge reaches x=0 (or y=0) in small
/// steps and rests there, so consecutive near-zero events have tiny travel.
/// A coordinate reported AT the zero axis while arriving in one large step
/// from mid-screen is a phantom contact sample (this tablet's pen stream
/// collapses one axis to 0 every ~1s of writing; travel ~0.24-0.81, far
/// too big to be a real hand, and it was slipping under MAX_STEP).
const COLLAPSE_EPS: f64 = 0.005;
const COLLAPSE_JUMP: f64 = 0.15;

/// A slow stroke's position steps by ~0.001-0.005 normalized per report
/// with sensor-level back-and-forth wiggle: forwarded raw, the ink gets a
/// faint staircase. A light EMA on small steps rounds it off; fast steps
/// pass through untouched so a flick isn't lagged.
const SMOOTH_ALPHA: f64 = 0.30;
const SMOOTH_MAX_STEP: f64 = 0.18;

/// Velocity-forwarded prediction cancels the EMA position lag. Each event
/// the EMA state moves `SMOOTH_ALPHA` of the way toward the raw report, so a
/// constant-speed stroke trails by ~(1/alpha-1) report-intervals; emitting
/// the EMA position plus ~2 intervals of smoothed per-report velocity puts
/// the ink back on the nib instead of behind the hand.
const PRED_ALPHA: f64 = 0.6;
const PRED_LAG: f64 = 2.0;

/// True when a single axis of this report collapsed to ~0 while arriving
/// from far away. A real pen reaches an edge by small steps and rests
/// there, so this signature uniquely marks phantom contact samples (the
/// pen stream here zeroes one axis every few events).
fn isCollapse(x: f64, y: f64, sx: f64, sy: f64) bool {
    return (@abs(x) < COLLAPSE_EPS and @abs(x - sx) > COLLAPSE_JUMP) or
        (@abs(y) < COLLAPSE_EPS and @abs(y - sy) > COLLAPSE_JUMP);
}

const TabletContext = @This();

tablet: *wlroots.Tablet,
v2_tablet: *wlroots.TabletV2Tablet,
context: *ServerContext,

/// Last forwarded normalized axis position. Kept across proximity so the
/// first report after a re-contact is still bounded (no stroke-start
/// teleport). onAxis drops any report farther than `MAX_STEP` from it, so
/// a stray coordinate never yanks the stream across the screen.
has_pos: bool = false,
sx: f64 = 0,
sy: f64 = 0,
tip_down: bool = false,
    /// Set while a good sample waits behind a dropped phantom sample: the
    /// next good axis report re-emits an interpolated midpoint so point
    /// spacing stays uniform for the consumer.
    pending_gap: bool = false,
    /// Smoothed per-report velocity (raw deltas), used to cancel the EMA
    /// lag on the emitted position so the ink tracks the nib crisply.
    vx: f64 = 0,
    vy: f64 = 0,
    last_raw_x: f64 = 0,
    last_raw_y: f64 = 0,

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
    const hit = NodeData.resolveAt(&context.scene.tree, x, y) orelse return null;

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
) InputTransform.Point {
    const output = self.context.output orelse return .{ .ox = 0, .oy = 0 };
    return InputTransform.toLogical(output, x, y);
}

pub fn onAxis(
    listener: *wl.Listener(*wlroots.Tablet.event.Axis),
    event: *wlroots.Tablet.event.Axis,
) void {
    const self: *TabletContext = @fieldParentPtr("axis_listener", listener);
    if (self.context.idle) |idle| idle.notifyActivity();

    const tool = self.getTool(event.tool) orelse return;

    if (!self.tip_down) self.pending_gap = false;

    const x = event.x;
    const y = event.y;
    if (self.has_pos) {
        const dx = x - self.sx;
        const dy = y - self.sy;
        const imp = if (@abs(dx) > @abs(dy)) @abs(dx) else @abs(dy);
        if (self.tip_down) {
            // Inking: the stream must not jump. Drop teleports and
            // collapsed-axis phantom samples flat. The collapse rule is what
            // keeps this pen's frequent (0,y)/(x,0) junk off the stroke.
            if (imp > MAX_STEP or isCollapse(x, y, self.sx, self.sy)) {
                self.pending_gap = true;
                return;
            }
        } else {
            // Hover: no ink, so only drop collapsed-axis junk. In-proximity
            // repositions (pen lifted but still near the screen, big STAY
            // jumps) must track, or the anchor goes stale and the next
            // stroke starts from the wrong place.
            if (isCollapse(x, y, self.sx, self.sy)) {
                return;
            }
        }
    }

    if (self.pending_gap and self.tip_down) {
        // A dropped phantom sample skipped one report interval, so the next
        // good sample arrives a full double-step away from its neighbours.
        // Emit an interpolated midpoint first to keep point spacing uniform
        // (scratchy ink is uneven point density, not just jitter).
        self.pending_gap = false;
        self.emitMotion(tool, (self.sx + x) * 0.5, (self.sy + y) * 0.5, false);
    }
    self.emitMotion(tool, x, y, true);

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

fn emitMotion(
    self: *TabletContext,
    tool: *wlroots.TabletV2TabletTool,
    px: f64,
    py: f64,
    update_vel: bool,
) void {
    // EMA position state (also stays the filter and re-space anchor).
    var ex = px;
    var ey = py;
    if (self.tip_down) {
        const dx = px - self.sx;
        const dy = py - self.sy;
        const step = if (@abs(dx) > @abs(dy)) @abs(dx) else @abs(dy);
        if (step < SMOOTH_MAX_STEP) {
            ex = self.sx + SMOOTH_ALPHA * (px - self.sx);
            ey = self.sy + SMOOTH_ALPHA * (py - self.sy);
        }
    }
    if (update_vel) {
        self.vx = self.vx * (1 - PRED_ALPHA) + (px - self.last_raw_x) * PRED_ALPHA;
        self.vy = self.vy * (1 - PRED_ALPHA) + (py - self.last_raw_y) * PRED_ALPHA;
        self.last_raw_x = px;
        self.last_raw_y = py;
    }
    const out_x = if (self.tip_down) ex + PRED_LAG * self.vx else ex;
    const out_y = if (self.tip_down) ey + PRED_LAG * self.vy else ey;
    self.sx = ex;
    self.sy = ey;
    self.has_pos = true;

    const pos = self.toolPosition(out_x, out_y);
    wlroots.TabletV2TabletTool.notifyMotion(tool, pos.ox, pos.oy);
}

pub fn onProximity(
    listener: *wl.Listener(*wlroots.Tablet.event.Proximity),
    event: *wlroots.Tablet.event.Proximity,
) void {
    const self: *TabletContext = @fieldParentPtr("proximity_listener", listener);

    const tool = self.getTool(event.tool) orelse return;

    if (event.state == .out) {
        wlroots.TabletV2TabletTool.notifyProximityOut(tool);
        // Keep the position anchor across proximity: the first axis report
        // after a re-contact can still be stale or border-clamped, and the
        // onAxis clamp must be able to catch it (no first-event teleport).
        return;
    }

    // Anchor the stream to where the pen actually is now. Kept stale across
    // proximity before, every re-contact measured its first reports against
    // the PREVIOUS stroke's position: repositioning the pen for a new stroke
    // showed up as a jump (or was dropped flat), which read as jumpy ink.
    // The onAxis filter still guards the very first report, so a stale or
    // border-clamped coordinate after re-contact cannot teleport.
    self.sx = event.x;
    self.sy = event.y;
    self.has_pos = true;
    self.pending_gap = false;
    self.vx = 0;
    self.vy = 0;
    self.last_raw_x = event.x;
    self.last_raw_y = event.y;

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
        self.tip_down = true;
        // The position anchor stays (the pen is already there), but the
        // prediction velocity must not: hover reports feed the same EMA, so
        // a stroke begun right after moving the pen would start by
        // predicting along that hover motion and kick at the nib.
        self.vx = 0;
        self.vy = 0;
        wlroots.TabletV2TabletTool.notifyDown(tool);
    } else {
        self.tip_down = false;
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
