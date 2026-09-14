const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlroots = @import("wlroots");
const std = @import("std");

const ServerContext = @import("../server.zig");
const NodeData = @import("../view/utils/node_data.zig");
const FocusManager = @import("../view/focus.zig");
const Border = @import("../view/border.zig");
const ViewManager = @import("../view/view_manager.zig");
const LayerView = @import("../view/layer.zig");
const View = @import("../view/view.zig");
const ResizeEdge = @import("../server.zig").ResizeEdge;
const PointerConstraints = @import("pointer_constraints.zig");
const Mirror = @import("../mirror.zig");
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

    context.pile_divider_y = context.cursor.y;
    if (context.pile_divider_active) {
        updatePileDivider(context);
    } else if (context.resize_active) {
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

    context.pile_divider_y = context.cursor.y;
    if (context.pile_divider_active) {
        updatePileDivider(context);
    } else if (context.resize_active) {
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
/// Diag helper: printable node type name.
fn _nodeTypeName(t: anytype) []const u8 {
    return switch (t) {
        .tree => "tree",
        .buffer => "buffer",
        .rect => "rect",
    };
}
fn onPointerHit(context: *ServerContext, time_msec: u32) void {
    const hit = NodeData.resolveAt(&context.scene.tree, context.cursor.x, context.cursor.y) orelse {
        context.seat.pointerClearFocus();
        context.focused_surface = null;
        PointerConstraints.onPointerFocus(context, null);
        setHoveredView(context, null);
        return;
    };

    switch (hit.data.*) {
        .view => |view| {
            const view_ptr: *View = @ptrCast(@alignCast(view));
            setHoveredView(context, view_ptr);
            // Pointer focus is position-explicit: drop any keyboard-cycle
            // anchor(s) so the ring follows the pointed tile again and the
            // next cycle re-anchors on the focused view's home.
            context.kbd_anchor_slot_x = -1;
            context.kbd_cycle_view = null;
            context.kbd_cycle_slot = -1;
            if (view_ptr.backend == .xwayland) {
                const xw = view_ptr.backend.xwayland;
                std.log.warn("PTR xwl win=0x{x} ored={} cl={?s} in={?s} tt={?s} hit={?*} sx={d:.0} sy={d:.0} cur=({d:.0},{d:.0})", .{ xw.window_id, xw.override_redirect, xw.class, xw.instance, xw.title, hit.surface, hit.sx, hit.sy, context.cursor.x, context.cursor.y });
            }
            // Mirrors are plain scene buffers: resolveAt returns the source
            // view with node-local coords, so route them through the mirror
            // back into the source surface space or clicks land off-target.
            const target = Mirror.mirrorInputTarget(context, view_ptr, hit.node, hit.sx, hit.sy);
            const surface = if (target) |t| t.surface else (hit.surface orelse view_ptr.surface());
            const ix = if (target) |t| t.sx else hit.sx;
            const iy = if (target) |t| t.sy else hit.sy;

            const first_enter = context.focused_surface != surface;
            if (first_enter) {
                context.seat.pointerNotifyEnter(surface, ix, iy);
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
                    .view = .{ .view = view_ptr, .surface = surface, .sx = ix, .sy = iy },
                });
            }
            if (context.cfg.focus_follows_mouse) {
                if (target) |t| {
                    if (!t.mirror.is_self) {
                        // Hovered a mirror copy tile: pin the ring to it so a
                        // later Super+q (or cycle) targets this copy even if
                        // the pointer moved away in between.
                        context.kbd_anchor_row = t.row;
                        context.kbd_anchor_slot_x = t.mirror.slot_x;
                    }
                }
            }

            context.seat.pointerNotifyMotion(time_msec, ix, iy);
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
            const surface = layer_ptr.layer_surface.surface;
            setHoveredView(context, null);
            if (context.focused_surface != surface) {
                context.seat.pointerNotifyEnter(
                    surface,
                    hit.sx,
                    hit.sy,
                );
                context.focused_surface = surface;
            }
            // Layer shell surfaces get pointer focus on hover but not
            // keyboard focus — that only changes on initial commit or
            // explicit click.  Skipping setFocus here avoids expensive
            // updateBorders / layoutMirrorsAll scene mutations when the
            // cursor briefly exits and re-enters the layer at speed.
            context.seat.pointerNotifyMotion(time_msec, hit.sx, hit.sy);
        },
        .im_popup => |popup_raw| {
            setHoveredView(context, null);
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
            setHoveredView(context, null);
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
/// Track which view the pointer sits over for the hover ring. Repaints the
/// affected borders so the ring follows the pointer without a full relayout,
/// and skipping unchanged views keeps pointer motion cheap.
fn setHoveredView(context: *ServerContext, view: ?*View) void {
    if (context.hovered_view == view) return;
    if (context.hover_border_color == null) {
        context.hovered_view = view;
        return;
    }
    const old = context.hovered_view;
    context.hovered_view = view;
    if (old) |v| Border.updateViewBorder(v, @floatFromInt(v.x), null);
    if (view) |v| Border.updateViewBorder(v, @floatFromInt(v.x), null);
}

fn superHeld(context: *ServerContext) bool {
    // Mod key on ANY keyboard: keyboards[0] can be a non-input ACPI device
    // (Video Bus) whose modifiers never update.
    for (context.keyboards.items) |kb| {
        if ((kb.keyboard.modifiers.depressed & (1 << 6)) != 0) return true;
    }
    return false;
}

fn startDrag(context: *ServerContext, _: *wlroots.Pointer.event.Button) void {
    const view = context.focused_view orelse return;
    // Floating windows are grabbed with a bare left-drag (rice-style);
    // tiled reordering keeps the mod+drag convention.
    if (!superHeld(context) and !view.floating) return;
    ViewManager.endDragPreview(context);

    context.drag_active = true;
    context.drag_view = view;
    if (view.floating) {
        const cx: i32 = @intFromFloat(context.cursor.x);
        const cy: i32 = @intFromFloat(context.cursor.y);
        context.drag_off_x = view.x - cx;
        context.drag_off_y = view.y - cy;
    }
    updateCursorShape(context);
}

fn updateDrag(context: *ServerContext) void {
    std.log.debug("UPDATEDRAG drag_active={} cursor=({d:.0},{d:.0})", .{ context.drag_active, context.cursor.x, context.cursor.y });
    const view = context.drag_view orelse return;
    // Floating windows move freely with the cursor; tiled ones snap to slots.
    if (view.floating) {
        view.x = @as(i32, @intFromFloat(context.cursor.x)) + context.drag_off_x;
        view.y = @as(i32, @intFromFloat(context.cursor.y)) + context.drag_off_y;
        view.scene_tree.node.setPosition(view.x, view.y);
        return;
    }
    ViewManager.updateDragPreview(context, view, context.cursor.x, context.cursor.y);
}

fn endDrag(context: *ServerContext) void {
    ViewManager.commitDragPreview(context);
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
    const width = ViewManager.tiledWidth(context, view);
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
    for (context.views.items, 0..) |view, i| {
        if (!view.isMapped() or view.floating or view.fullscreen) continue;
        if (context.resize_len >= context.resize_views.len) break;
        // One resize slot per column: stacked pile members share it.
        if (!ViewManager.advanceSlotAfter(context, view, i)) continue;
        context.resize_views[context.resize_len] = view;
        context.resize_lefts[context.resize_len] = slot_x;
        context.resize_len += 1;
        slot_x += @floatFromInt(ViewManager.tiledWidth(context, view) + context.gaps_in);
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

    // Floating/fullscreen views: a wider grab band than tiled slot
    // edges, so a plain-button move-grab doesn't win when the user aims
    // for the edge to resize it.
    const float_bw: f64 = @floatFromInt(context.border_width + 12);
    for (context.views.items) |view| {
        if (!view.isMapped() or (!view.floating and !view.fullscreen)) continue;
        if (edgeHit(context, view, float_bw)) |edge| return .{ .view = view, .edge = edge };
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
            @as(f64, @floatFromInt(ViewManager.tiledWidth(context, prev)));
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

/// The pile member whose bottom edge is a divider at `(x, y)` — the
/// horizontal boundary between it and the member below it. Only members
/// that HAVE a member below qualify. Dragging it resizes its share.
pub fn pileDividerAtPoint(context: *ServerContext, x: f64, y: f64, band: f64) ?*View {
    const vp: f64 = @floatFromInt(context.viewport_x);
    for (context.views.items, 0..) |view, i| {
        if (!view.isMapped() or view.floating or view.fullscreen) continue;
        if (view.pile_id == 0) continue;
        if (i + 1 >= context.views.items.len) continue;
        if (context.views.items[i + 1].pile_id != view.pile_id) continue;
        const slot = ViewManager.pileSlot(context, view) orelse continue;
        const left: f64 = @as(f64, @floatFromInt(view.x)) - vp;
        const w: f64 = @as(f64, @floatFromInt(ViewManager.tiledWidth(context, view)));
        if (x < left - band or x > left + w + band) continue;
        const bottom: f64 = @floatFromInt(slot.top + slot.height);
        if (@abs(y - bottom) <= band) return view;
    }
    return null;
}

fn cursorPileDivider(context: *ServerContext) ?*View {
    const band: f64 = @floatFromInt(context.border_width + 2);
    return pileDividerAtPoint(context, context.cursor.x, context.cursor.y, band);
}

fn startPileDivider(context: *ServerContext, view: *View) void {
    context.pile_divider_active = true;
    context.pile_divider_view = view;
    context.pile_divider_y = context.cursor.y;
    updatePileDivider(context);
}

/// Follow the current drag position: the divider sits between the drag
/// member and the one below, so its share is the fraction of the column's
/// inner height above the cursor. Snap via layoutViews so the layout
/// tracks the drag instead of rubber-banding behind it.
pub fn updatePileDivider(context: *ServerContext) void {
    const view = context.pile_divider_view orelse return;
    const inner_h: f64 = @as(f64, @floatFromInt(context.usable_area.height)) -
        @as(f64, @floatFromInt(context.gaps_out * 2));
    const col_top: f64 = @as(f64, @floatFromInt(context.usable_area.y + context.gaps_out));
    var frac: f64 = (context.pile_divider_y - col_top) / inner_h;
    frac = @max(0.1, @min(0.9, frac));
    ViewManager.setPileShare(context, view, @floatCast(frac));
    ViewManager.layoutViews(context);
    ViewManager.syncPile(context, view);
}

fn endPileDivider(context: *ServerContext) void {
    context.pile_divider_active = false;
    context.pile_divider_view = null;
}

fn startResize(context: *ServerContext) void {
    const grab = resizeEdgeAt(context) orelse return;
    context.resize_active = true;
    context.resize_view = grab.view;
    context.resize_edge = grab.edge;
    context.resize_start_x = context.cursor.x;
    context.resize_start_view_x = grab.view.x;
    // Floating views have no tile ratio: anchor on the ring slot, whose
    // width is what updateFloatingResize actually changes.
    context.resize_start_width = if (grab.view.floating) grab.view.slot_w else ViewManager.tiledWidth(context, grab.view);
    updateCursorShape(context);
}

fn updateResize(context: *ServerContext) void {
    const view = context.resize_view orelse return;
    // Floating windows resize independently of the tiled layout; tiled
    // resize still re-computes the column widths.
    if (view.floating) {
        updateFloatingResize(context, view);
        return;
    }
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

/// Drag a floating window's left/right edge: width follows the cursor,
/// the opposite edge stays anchored, and the result sticks for the next
/// float epoch.
fn updateFloatingResize(context: *ServerContext, view: *View) void {
    const bw: i32 = @intCast(@max(0, context.border_width));
    const min_w: i32 = 200 + 2 * bw;
    const delta = @as(i32, @intFromFloat(context.cursor.x)) -
        @as(i32, @intFromFloat(context.resize_start_x));
    var new_w: i32 = switch (context.resize_edge) {
        .right => context.resize_start_width + delta,
        .left => context.resize_start_width - delta,
    };
    if (new_w < min_w) new_w = min_w;

    if (context.resize_edge == .left) {
        // Absolute from the captured start, never `+=`: the adjustment
        // is already cumulative per drag, so += would re-add it every
        // motion event and fling the window off-screen.
        view.x = context.resize_start_view_x + (context.resize_start_width - new_w);
    }
    view.slot_w = new_w;
    view.scene_tree.node.setPosition(view.x, view.y);
    view.setSize(@max(1, new_w - 2 * bw), @max(1, view.slot_h - 2 * bw));
}

fn endResize(context: *ServerContext) void {
    const view = context.resize_view orelse return;
    // Remember the size the user settled on, so the next float re-uses it.
    if (view.floating) {
        const bw: i32 = @intCast(@max(0, context.border_width));
        view.float_size = .{ @max(1, view.slot_w - 2 * bw), @max(1, view.slot_h - 2 * bw) };
    }
    context.resize_active = false;
    context.resize_view = null;
    updateCursorShape(context);
}

/// Reflect interaction state in the cursor image.
fn updateCursorShape(context: *ServerContext) void {
    const dragging_float = context.drag_active and if (context.drag_view) |dv| dv.floating else false;
    const new_shape: @TypeOf(context.cursor_shape) =
        if (context.resize_active) .resize else if (dragging_float) .grab else .default;
    if (new_shape == context.cursor_shape) return;
    context.cursor_shape = new_shape;
    const name: [*:0]const u8 = switch (new_shape) {
        .resize => "col-resize",
        .grab => "grabbing",
        else => "default",
    };
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
            std.log.debug("PRESS super={} resize={?} divider={?}", .{
                superHeld(context),
                resizeEdgeAt(context),
                cursorPileDivider(context) orelse null,
            });
            if (resizeEdgeAt(context) != null and !superHeld(context)) {
                startResize(context);
            } else if (cursorPileDivider(context)) |divider_view| {
                startPileDivider(context, divider_view);
            } else {
                startDrag(context, event);
            }
        } else {
            endPileDivider(context);
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
