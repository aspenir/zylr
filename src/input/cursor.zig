const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlroots = @import("wlroots");
const std = @import("std");

const ServerContext = @import("../server.zig");
const nd = @import("../view/utils/node_data.zig");
const FocusManager = @import("../view/focus.zig");
const ViewManager = @import("../view/view_manager.zig");
const LayerView = @import("../view/layer.zig");
const View = @import("../view/view.zig");
const ResizeEdge = @import("../server.zig").ResizeEdge;
const PointerConstraints = @import("pointer_constraints.zig");
pub fn onCursorMotion(
    listener: *wl.Listener(*wlroots.Pointer.event.Motion),
    event: *wlroots.Pointer.event.Motion,
) void {
    const context: *ServerContext =
        @fieldParentPtr("cursor_motion_listener", listener);

    switch (PointerConstraints.relativeMotion(context, event.delta_x, event.delta_y)) {
        .locked => {
            PointerConstraints.sendLockedMotion(context, event.time_msec, event.delta_x, event.delta_y);
            if (context.idle) |idle| idle.notifyActivity();
            return;
        },
        .move => |m| {
            context.cursor.move(event.device, m.dx, m.dy);
        },
    }

    if (context.idle) |idle| idle.notifyActivity();

    if (context.locked) {
        context.seat.pointerNotifyMotion(
            event.time_msec,
            context.cursor.x,
            context.cursor.y,
        );
        return;
    }

    if (context.resize_active) {
        updateResize(context);
    } else if (context.drag_active) {
        updateDrag(context);
    } else {
        updateCursorShape(context);
    }

    onPointerHit(context, event.time_msec);
}

pub fn onCursorMotionAbsolute(
    listener: *wl.Listener(*wlroots.Pointer.event.MotionAbsolute),
    event: *wlroots.Pointer.event.MotionAbsolute,
) void {
    const context: *ServerContext =
        @fieldParentPtr("cursor_motion_absolute_listener", listener);

    var target_x = event.x;
    var target_y = event.y;
    if (PointerConstraints.absoluteMotion(context, &target_x, &target_y)) {
        context.cursor.warpAbsolute(event.device, target_x, target_y);
    }

    if (context.idle) |idle| idle.notifyActivity();

    if (context.resize_active) {
        updateResize(context);
    } else {
        updateCursorShape(context);
    }

    onPointerHit(context, event.time_msec);
}

/// Pointer-focus path shared by relative and absolute motion: resolve the
/// surface under the cursor, enter/move the pointer, and optionally move
/// keyboard focus (focus-follows-mouse). Keyboard focus is deliberately
/// kept while the cursor is over a gap — only pointer focus clears.
fn onPointerHit(context: *ServerContext, time_msec: u32) void {
    const hit = nd.resolveAt(&context.scene.tree, context.cursor.x, context.cursor.y) orelse {
        context.seat.pointerClearFocus();
        context.focused_surface = null;
        PointerConstraints.onPointerFocus(context, null);
        return;
    };

    switch (hit.data.*) {
        .view => |view| {
            const view_ptr: *View = @ptrCast(@alignCast(view));
            if (view_ptr.backend == .xwayland) {
                const xw = view_ptr.backend.xwayland;
                std.log.warn("PTR xwl win=0x{x} ored={} cl={?s} in={?s} tt={?s} hit={?*} sx={d:.0} sy={d:.0} cur=({d:.0},{d:.0})", .{ xw.window_id, xw.override_redirect, xw.class, xw.instance, xw.title, hit.surface, hit.sx, hit.sy, context.cursor.x, context.cursor.y });
            }
            const surface = hit.surface orelse view_ptr.surface();

            const first_enter = context.focused_surface != surface;
            if (first_enter) {
                context.seat.pointerNotifyEnter(surface, hit.sx, hit.sy);
                context.focused_surface = surface;
            }

            // Focus-follows-mouse: keyboard focus tracks the hovered view
            // instead of only clicking. setFocus also updates borders, the
            // MRU history and the toplevel handles. Never for popups
            // (unmanaged); stealing activation from Steam mid-menu closes
            // the menu. Pointer focus was already set above.
            if (context.cfg.focus_follows_mouse and
                context.focused_view != view_ptr and
                !view_ptr.isOrWindow())
            {
                FocusManager.setFocus(context, .{
                    .view = .{ .view = view_ptr, .surface = hit.surface orelse view_ptr.surface(), .sx = hit.sx, .sy = hit.sy },
                });
            }

            context.seat.pointerNotifyMotion(time_msec, hit.sx, hit.sy);
            // Xwayland only dispatches pointer motion on a wl_pointer.frame
            // (wl_pointer v5+). Sending one right after the motion over an
            // X window removes any cadence gap between the cursor's frame
            // event and the motion, so the X pointer cannot freeze mid-window.
            if (!first_enter) {
                context.seat.pointerNotifyFrame();
            }
        },
        .layer => |layer| {
            const layer_ptr: *LayerView = @ptrCast(@alignCast(layer));
            if (context.focused_layer != layer_ptr) {
                FocusManager.setFocus(context, .{
                    .layer = .{ .layer = layer_ptr, .sx = hit.sx, .sy = hit.sy },
                });
            }
            context.seat.pointerNotifyMotion(time_msec, hit.sx, hit.sy);
        },
        .im_popup => |popup_raw| {
            const popup: *wlroots.InputPopupSurfaceV2 = @ptrCast(@alignCast(popup_raw));
            const surface = popup.surface;
            if (context.focused_surface != surface) {
                context.seat.pointerNotifyEnter(surface, hit.sx, hit.sy);
                context.focused_surface = surface;
            }
            context.seat.pointerNotifyMotion(time_msec, hit.sx, hit.sy);
        },
        .popup => |popup_raw| {
            const popup: *wlroots.XdgPopup = @ptrCast(@alignCast(popup_raw));
            const surface = popup.base.surface;
            if (context.focused_surface != surface) {
                context.seat.pointerNotifyEnter(surface, hit.sx, hit.sy);
                context.focused_surface = surface;
            }
            context.seat.pointerNotifyMotion(time_msec, hit.sx, hit.sy);
        },
    }

    // Constraint activation after focus is established, so clients never see
    // an 'confined'/'locked' event before the matching pointer enter.
    PointerConstraints.onPointerFocus(context, hit.node);
}
fn superHeld(context: *ServerContext) bool {
    if (context.keyboards.items.len == 0) return false;
    const modifiers = context.keyboards.items[0].keyboard.modifiers;
    return (modifiers.depressed & (1 << 6)) != 0;
}

fn startDrag(context: *ServerContext, _: *wlroots.Pointer.event.Button) void {
    if (!superHeld(context)) return;
    if (context.focused_view == null) return;

    context.drag_active = true;
    context.drag_view = context.focused_view;
    updateCursorShape(context);
}

fn updateDrag(context: *ServerContext) void {
    const view = context.drag_view orelse return;
    ViewManager.moveViewToSlot(context, view, context.cursor.x);
}

fn endDrag(context: *ServerContext) void {
    context.drag_active = false;
    context.drag_view = null;
    updateCursorShape(context);
}

/// First tiled-column slot whose left edge is at or after `c`, given
/// slot lefts sorted ascending. Pure for testing.
fn firstSlotAtOrAfter(lefts: []const f64, c: f64) usize {
    var lo: usize = 0;
    var hi: usize = lefts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (lefts[mid] < c) lo = mid + 1 else hi = mid;
    }
    return lo;
}

test "firstSlotAtOrAfter finds the slot and handles edges" {
    const lefts = [_]f64{ 16.0, 116.0, 216.0 };
    try std.testing.expectEqual(@as(usize, 0), firstSlotAtOrAfter(&lefts, 10.0));
    try std.testing.expectEqual(@as(usize, 0), firstSlotAtOrAfter(&lefts, 16.0));
    try std.testing.expectEqual(@as(usize, 1), firstSlotAtOrAfter(&lefts, 16.0001));
    try std.testing.expectEqual(@as(usize, 1), firstSlotAtOrAfter(&lefts, 100.0));
    try std.testing.expectEqual(@as(usize, 3), firstSlotAtOrAfter(&lefts, 216.0));
    try std.testing.expectEqual(@as(usize, 3), firstSlotAtOrAfter(&lefts, 999.0));
    try std.testing.expectEqual(@as(usize, 0), firstSlotAtOrAfter(&[_]f64{}, 5.0));
}

/// Edge band check for one window: left edge first, then right (matches
/// the left-to-right scan order of the pre-binary-search walk).
fn edgeHit(context: *ServerContext, view: *View, bw: f64) ?ResizeEdge {
    const width = ViewManager.getViewWidth(view);
    // Tiled views render at view.x minus the viewport offset; floating
    // and fullscreen views are placed at absolute view.x.
    const vp: f64 = if (view.floating or view.fullscreen) 0 else @floatFromInt(context.viewport_x);
    const left = @as(f64, @floatFromInt(view.x)) - vp;
    const right = left + @as(f64, @floatFromInt(width));

    const c = context.cursor.x;
    if (c >= left - bw and c <= left + bw) return .left;
    if (c >= right - bw and c <= right + bw) return .right;
    return null;
}

/// Rebuild the cached slot-lefts of the tiled column and invalidate the
/// resize cache until the next layout pass.
fn rebuildResizeCache(context: *ServerContext) void {
    context.resize_seq = context.layout_seq;
    var slot_x: f64 = @floatFromInt(context.usable_area.x + context.gaps_out);
    context.resize_len = 0;
    for (context.views.items) |view| {
        if (!view.isMapped() or view.floating or view.fullscreen) continue;
        if (context.resize_len >= context.resize_views.len) break;
        context.resize_views[context.resize_len] = view;
        context.resize_lefts[context.resize_len] = slot_x;
        context.resize_len += 1;
        slot_x += @floatFromInt(ViewManager.getViewWidth(view) + context.gaps_in);
    }
}

/// The window and edge under the cursor, when the cursor sits on a
/// window's left/right edge (a resize grab point). The tiled column is
/// binary-searched on slot left edges; the few floating/fullscreen
/// windows are scanned linearly first.
fn resizeEdgeAt(context: *ServerContext) ?struct {
    view: *View,
    edge: ResizeEdge,
} {
    const bw: f64 = @floatFromInt(context.border_width + 2);

    for (context.views.items) |view| {
        if (!view.isMapped() or (!view.floating and !view.fullscreen)) continue;
        if (edgeHit(context, view, bw)) |edge| return .{ .view = view, .edge = edge };
    }

    if (context.resize_len == 0 or context.resize_seq != context.layout_seq) {
        rebuildResizeCache(context);
    }

    const vp: f64 = @floatFromInt(context.viewport_x);
    const c = context.cursor.x;
    const lo = firstSlotAtOrAfter(context.resize_lefts[0..context.resize_len], c + vp);

    // The cursor sorts before slot `lo`: prefer the previous slot's right
    // edge, then the next slot's left edge.
    if (lo > 0) {
        const prev = context.resize_views[lo - 1];
        const pr = context.resize_lefts[lo - 1] - vp +
            @as(f64, @floatFromInt(ViewManager.getViewWidth(prev)));
        if (c >= pr - bw and c <= pr + bw) return .{ .view = prev, .edge = .right };
    }
    if (lo < context.resize_len) {
        const next = context.resize_views[lo];
        const nl = context.resize_lefts[lo] - vp;
        if (c >= nl - bw and c <= nl + bw) return .{ .view = next, .edge = .left };
    }
    return null;
}

/// True when the cursor sits on a window's left/right edge.
fn cursorOnResizeEdge(context: *ServerContext) bool {
    return resizeEdgeAt(context) != null;
}

fn startResize(context: *ServerContext) void {
    const grab = resizeEdgeAt(context) orelse return;
    context.resize_active = true;
    context.resize_view = grab.view;
    context.resize_edge = grab.edge;
    context.resize_start_x = context.cursor.x;
    context.resize_start_width = ViewManager.getViewWidth(grab.view);
    updateCursorShape(context);
}

fn updateResize(context: *ServerContext) void {
    const view = context.resize_view orelse return;
    const min_w: i32 = 200;

    const delta = context.cursor.x - context.resize_start_x;
    var new_width: i32 = switch (context.resize_edge) {
        .right => context.resize_start_width + @as(i32, @intFromFloat(delta)),
        .left => context.resize_start_width - @as(i32, @intFromFloat(delta)),
    };
    if (new_width < min_w) new_width = min_w;

    view.custom_width = new_width;
    ViewManager.layoutViews(context);
    view.setSize(new_width, view.surface().current.height);
}

fn endResize(context: *ServerContext) void {
    context.resize_active = false;
    context.resize_view = null;
    updateCursorShape(context);
}

/// Reflect interaction state in the cursor image.
fn updateCursorShape(context: *ServerContext) void {
    const new_shape: @TypeOf(context.cursor_shape) =
        if (context.drag_active or cursorOnResizeEdge(context))
            .resize
        else
            .default;
    if (new_shape == context.cursor_shape) return;
    context.cursor_shape = new_shape;
    const name: [*:0]const u8 = if (new_shape == .resize) "col-resize" else "default";
    context.xcursor_manager.setXcursor(context.cursor, name);
}

pub fn onCursorButton(
    listener: *wl.Listener(*wlroots.Pointer.event.Button),
    event: *wlroots.Pointer.event.Button,
) void {
    const context: *ServerContext =
        @fieldParentPtr("cursor_button_listener", listener);

    std.log.debug(
        "MOUSE BUTTON: button={} state={}",
        .{ event.button, event.state },
    );

    if (context.idle) |idle| idle.notifyActivity();

    if (event.button == 272) { // BTN_LEFT
        if (event.state == .pressed) {
            FocusManager.focusAtCursor(context);
            if (resizeEdgeAt(context) != null and !superHeld(context)) {
                startResize(context);
            } else {
                startDrag(context, event);
            }
        } else {
            endDrag(context);
            endResize(context);
        }
    }

    _ = context.seat.pointerNotifyButton(
        event.time_msec,
        event.button,
        event.state,
    );
}
pub fn onCursorAxis(
    listener: *wl.Listener(*wlroots.Pointer.event.Axis),
    event: *wlroots.Pointer.event.Axis,
) void {
    const context: *ServerContext =
        @fieldParentPtr("cursor_axis_listener", listener);

    if (context.idle) |idle| idle.notifyActivity();

    context.seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
        event.relative_direction,
    );
}
pub fn onCursorFrame(
    listener: *wl.Listener(*wlroots.Cursor),
    _: *wlroots.Cursor,
) void {
    const context: *ServerContext =
        @fieldParentPtr("cursor_frame_listener", listener);

    cursor_frame_diag += 1;
    const n = cursor_frame_diag;
    if (n <= 20 or (n % 500 == 0 and n > 0)) {
        const over_xw = context.focused_view != null and
            context.focused_view.?.backend == .xwayland;
        std.log.warn("PTRF total={d} over_xw={}", .{ n, over_xw });
    }

    context.seat.pointerNotifyFrame();
}

var cursor_frame_diag: u64 = 0;
