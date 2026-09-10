const wlroots = @import("wlroots");
const std = @import("std");

const NodeData = @import("utils/node_data.zig");
const View = @import("view.zig");
const LayerView = @import("layer.zig");
const ServerContext = @import("../server.zig");
const BorderManager = @import("border.zig");
const InputRelay = @import("../input/input_relay.zig");
const ViewManager = @import("view_manager.zig");
const Mirror = @import("../mirror.zig");
const FocusTarget = union(enum) {
    none,
    view: struct {
        view: *View,
        /// Surface under the cursor (may be an XWayland subsurface). Null
        /// falls back to the view's top-level surface in setFocus.
        surface: ?*wlroots.Surface,
        sx: f64,
        sy: f64,
    },
    layer: struct {
        layer: *LayerView,
        sx: f64,
        sy: f64,
    },
};

pub fn focusAtCursor(context: *ServerContext) void {
    var sx: f64 = 0;
    var sy: f64 = 0;

    const node = context.scene.tree.node.at(
        context.cursor.x,
        context.cursor.y,
        &sx,
        &sy,
    ) orelse {
        // Clicking empty desktop: clear keyboard focus. This fires
        // notifyFocus(null) -> sendDeactivate, hiding the on-screen
        // keyboard (squeekboard) whose text input was left active.
        setFocus(context, .none);
        return;
    };

    var current: ?*wlroots.SceneNode = node;

    while (current) |n| {
        if (n.data) |data_ptr| {
            const data: *NodeData.NodeData =
                @ptrCast(@alignCast(data_ptr));

            switch (data.*) {
                .view => |view| {
                    const view_ptr: *View = @ptrCast(@alignCast(view));
                    // Mirrors are plain scene buffers: resolveAt resolved to
                    // the source view with node-local coords, so translate
                    // into the source surface before focusing (mirror nodes
                    // have no surface of their own).
                    const target = Mirror.mirrorInputTarget(context, view_ptr, node, sx, sy);
                    setFocus(context, .{
                        .view = .{
                            .view = view_ptr,
                            .surface = if (target) |t| t.surface else NodeData.hitSurface(node),
                            .sx = if (target) |t| t.sx else sx,
                            .sy = if (target) |t| t.sy else sy,
                        },
                    });
                    // Clicking a window hanging off-screen brings it in.
                    // Popups are unmanaged; never scroll for them. Mirrors
                    // are tiles of their own: anchor the ring on the clicked
                    // mirror and scroll the row to it, like keyboard cycling
                    // does - scrolling to the source's home slot would yank
                    // the row away from the copy.
                    if (target) |t| {
                        const m = t.mirror;
                        context.kbd_cycle_view = view_ptr;
                        context.kbd_cycle_slot = m.slot_x;
                        context.kbd_anchor_row = t.row;
                        context.kbd_anchor_slot_x = m.slot_x;
                        Mirror.refreshMirrorFocus(context);
                        if (t.row == context.active_row) {
                            ViewManager.scrollToX(context, m.slot_x, m.slot_w);
                        }
                        return;
                    }
                    if (!view_ptr.isOrWindow()) {
                        ViewManager.scrollIntoView(context, view_ptr);
                    }
                    return;
                },

                .layer => |layer| {
                    const layer_ptr: *LayerView = @ptrCast(@alignCast(layer));
                    setFocus(context, .{
                        .layer = .{
                            .layer = layer_ptr,
                            .sx = sx,
                            .sy = sy,
                        },
                    });
                    return;
                },

                // On-screen keyboard popup: don't take keyboard focus;
                // continue walking to the surface/primitive above.
                else => {},

                // xdg popup (menu/tooltip): route the click's pointer
                // focus to the popup surface only; the popup keeps its
                // toplevel's keyboard focus (the wlroots popup grab
                // delivers buttons and dismisses on outside clicks).
                .popup => |popup_raw| {
                    const popup: *wlroots.XdgPopup = @ptrCast(@alignCast(popup_raw));
                    const surface = popup.base.surface;
                    if (context.focused_surface != surface) {
                        context.seat.pointerNotifyEnter(surface, sx, sy);
                        context.focused_surface = surface;
                    }
                    return;
                },
            }
        }

        current = if (n.parent) |parent|
            &parent.node
        else
            null;
    }
}

/// Pop the MRU history and focus the last still-alive view.
/// Called when the focused view is closed. If history is empty,
/// focuses nothing (per the request: "when the queue is empty it
/// just doesnt focus anything").
pub fn restoreFocus(context: *ServerContext) void {
    // Drop any stale entries pointing at dead views first.
    while (context.focus_history.items.len > 0) {
        const candidate = context.focus_history.items[context.focus_history.items.len - 1];

        var alive = false;
        for (context.views.items) |view| {
            if (view == candidate) {
                alive = true;
                break;
            }
        }

        if (!alive or !candidate.isMapped()) {
            _ = context.focus_history.pop();
            continue;
        }

        setFocus(context, .{
            .view = .{
                .view = candidate,
                .surface = candidate.surface(),
                .sx = 0,
                .sy = 0,
            },
        });
        ViewManager.scrollToView(context, candidate);
        return;
    }

    setFocus(context, .none);
}

/// After a row switch: focus the most-recent window on the now-active row
/// without popping other rows' history. Mirrors restoreFocus but only
/// considers views in the active row's working set.
pub fn focusActiveRow(context: *ServerContext) void {
    var i = context.focus_history.items.len;
    while (i > 0) {
        i -= 1;
        const candidate = context.focus_history.items[i];
        if (!candidate.isMapped()) continue;
        var on_row = false;
        for (context.views.items) |view| {
            if (view == candidate) {
                on_row = true;
                break;
            }
        }
        if (on_row) {
            setFocus(context, .{
                .view = .{ .view = candidate, .surface = candidate.surface(), .sx = 0, .sy = 0 },
            });
            ViewManager.scrollToView(context, candidate);
            return;
        }
    }
    setFocus(context, .none);
}
pub fn setFocus(context: *ServerContext, target: FocusTarget) void {
    switch (target) {
        .none => {
            context.seat.pointerClearFocus();
            context.seat.keyboardNotifyClearFocus();

            context.focused_surface = null;
            context.previous_focused_view = context.focused_view;
            if (context.focused_view) |prev| prev.setActivated(false);
            context.focused_view = null;
            context.focused_layer = null;
            BorderManager.updateBorders(context);
            Mirror.layoutMirrorsAll(context);
            Mirror.refreshMirrorFocus(context);
            InputRelay.notifyFocus(null);
        },

        .view => |target_view| {
            const view = target_view.view;

            // Zombies (eagerly created XWayland/XDG views whose client
            // never mapped or withdrew again) must not take focus.
            if (!view.isMapped()) return;

            const surface = target_view.surface orelse view.surface();
            if (context.focused_surface != surface) {
                context.seat.pointerNotifyEnter(
                    surface,
                    target_view.sx,
                    target_view.sy,
                );
                context.focused_surface = surface;
            }

            // Override-redirect windows (Steam menus) are unmanaged: the
            // pointer reaches their surface, but they never take keyboard
            // focus, enter the MRU history, or change activation — yanking
            // X input focus across Steam's window stack mid-menu closes it.
            if (view.isOrWindow()) return;

            context.previous_focused_view = context.focused_view;
            context.focused_view = view;
            context.focused_layer = null;

            // MRU focus history: push the newly focused view, deduped.
            // If the focused view is closed, we pop back to the last one.
            for (context.focus_history.items, 0..) |candidate, i| {
                if (candidate == view) {
                    _ = context.focus_history.orderedRemove(i);
                    break;
                }
            }
            context.focus_history.append(
                std.heap.c_allocator,
                view,
            ) catch {};

            // Deactivate the previously focused view (X11 WM_STATE +
            // foreign-toplevel handle).
            if (context.previous_focused_view) |prev| {
                prev.setActivated(false);
                if (prev.toplevel_handle) |handle| {
                    handle.setActivated(false);
                }
            }

            if (context.keyboards.items.len > 0) {
                const keyboard = context.keyboards.items[0].keyboard;

                context.seat.keyboardNotifyEnter(
                    surface,
                    keyboard.keycodes[0..keyboard.num_keycodes],
                    &keyboard.modifiers,
                );
            }

            view.setActivated(true);
            if (view.toplevel_handle) |handle| {
                handle.setActivated(true);
            }

            // Offer focus (WM_TAKE_FOCUS) to XWayland clients using the
            // Globally Active ICCCM input model (Steam, Java apps). These
            // only accept keyboard input after receiving the offer.
            if (view.backend == .xwayland) {
                view.backend.xwayland.offerFocus();
            }

            // Only floating views need raised z-order; tiled views
            // don't overlap, and raising them pushes floating views down.
            if (view.floating) view.scene_tree.node.raiseToTop();

            BorderManager.updateBorders(context);
            Mirror.layoutMirrorsAll(context);
            Mirror.refreshMirrorFocus(context);
            InputRelay.notifyFocus(context.focused_surface);

            std.log.info("FOCUS VIEW view={*} surf={*}", .{ view, surface });
        },

        .layer => |target_layer| {
            const layer = target_layer.layer;
            const surface = layer.layer_surface.surface;

            if (context.focused_surface != surface) {
                context.seat.pointerNotifyEnter(
                    surface,
                    target_layer.sx,
                    target_layer.sy,
                );
                context.focused_surface = surface;
            }

            if (layer.layer_surface.current.keyboard_interactive == .none) {
                return;
            }

            if (context.focused_layer == layer and
                context.focused_view == null)
            {
                return;
            }

            if (context.focused_view) |view| {
                view.setActivated(false);
                context.previous_focused_view = view;
            }

            context.focused_view = null;
            context.focused_layer = layer;

            if (context.keyboards.items.len > 0) {
                const keyboard = context.keyboards.items[0].keyboard;

                context.seat.keyboardNotifyEnter(
                    surface,
                    keyboard.keycodes[0..keyboard.num_keycodes],
                    &keyboard.modifiers,
                );
            }

            BorderManager.updateBorders(context);
            Mirror.layoutMirrorsAll(context);
            Mirror.refreshMirrorFocus(context);
            InputRelay.notifyFocus(surface);

            std.log.info("FOCUS LAYER layer={*}", .{layer});
        },
    }
}

/// A focusable tile on the active row: a window at its own slot, or a
/// mirror copy rendered as a tile. Cycling steps through tiles in
/// column order, so a mirror copy is reachable by keyboard exactly like a
/// window. Selecting a tile focuses its source window (the mirror's memory).
pub const FocusTile = struct {
    x: f64,
    w: f64,
    view: *View,
    /// When true this tile is a mirror copy; its slot_x is the copy's
    /// own column (scroll there instead of the source's home slot).
    mirror_slot_x: f64,
    /// The mirror-copy Mirror object, null for window home tiles. Lets swap
    /// re-dock the copy instead of just swapping view pointers.
    mirror: ?*ServerContext.Mirror = null,
};

/// The active row as an x-sorted tile list: every tiled window's home slot
/// plus every placed mirror-copy tile. Shared by focus cycling and swap so
/// they agree on what a "tile" is.
pub fn buildRowTiles(context: *ServerContext, tiles: *[128]FocusTile) usize {
    var n: usize = 0;

    // Windows of the active row (their home slots).
    for (context.views.items) |v| {
        if (!v.isMapped() or v.floating or v.fullscreen) continue;
        if (n < 128) {
            tiles[n] = .{ .x = @floatFromInt(v.x), .w = @floatFromInt(ViewManager.getViewWidth(v)), .view = v, .mirror_slot_x = -1 };
            n += 1;
        }
    }
    // Mirror-created copies laid out as tiles on the active row.
    for (context.row_mirrors[context.active_row].items) |*m| {
        if (!m.active or m.is_self or m.slot_x == std.math.minInt(i32)) continue;
        if (n < 128) {
            tiles[n] = .{ .x = @floatFromInt(m.slot_x), .w = @floatFromInt(m.slot_w), .view = m.view, .mirror_slot_x = @floatFromInt(m.slot_x), .mirror = m };
            n += 1;
        }
    }

    std.mem.sort(FocusTile, tiles[0..n], {}, struct {
        fn lt(_: void, a: FocusTile, b: FocusTile) bool {
            if (a.x == b.x) return a.mirror_slot_x > b.mirror_slot_x; // window first on ties
            return a.x < b.x;
        }
    }.lt);
    return n;
}

fn tileCycle(context: *ServerContext, dir: i2) ?FocusTile {
    var tiles: [128]FocusTile = undefined;
    const n = buildRowTiles(context, &tiles);
    if (n == 0) return null;

    // Anchor on the EXACT tile the last cycle press landed on (which may be
    // a copy mirror, not the view's home), falling back to the focused
    // view's home slot. This lets cycling step past copies: from A's copy,
    // the next step is B, not A's copy again.
    const current = context.kbd_cycle_view orelse context.focused_view;
    var idx: usize = 0;
    if (current) |cv| {
        var found = false;
        for (tiles[0..n], 0..) |t, i| {
            if (t.view == cv and @as(i32, @intFromFloat(t.mirror_slot_x)) == context.kbd_cycle_slot) {
                idx = i;
                found = true;
                break;
            }
        }
        if (!found) {
            for (tiles[0..n], 0..) |t, i| {
                if (t.view == cv) {
                    idx = i;
                    break;
                }
            }
        }
    }
    // One keypress = exactly one tile, NO wrapping: at the row edges the
    // press keeps the current tile (stays put) instead of jumping to the far
    // side. A window's copy sits right after its home slot, so Step+L from a
    // window lands on its own copy tile first, then the next window.
    const step: i64 = if (dir > 0) 1 else -1;
    const next: i64 = @as(i64, @intCast(idx)) + step;
    if (next < 0 or next >= n) return tiles[idx];
    return tiles[@intCast(next)];
}

fn focusFirst(context: *ServerContext) void {
    for (context.views.items) |view| {
        if (!view.isMapped()) continue;

        setFocus(context, .{
            .view = .{ .view = view, .surface = view.surface(), .sx = 0, .sy = 0 },
        });
        ViewManager.scrollToView(context, view);
        return;
    }
}

fn focusTile(context: *ServerContext, t: FocusTile) void {
    // Anchor the ring plus the next cycle step on exactly the chosen tile,
    // so keyboard focus visibly lands everywhere and can keep moving.
    context.kbd_cycle_view = t.view;
    context.kbd_cycle_slot = @intFromFloat(t.mirror_slot_x);
    if (t.mirror_slot_x >= 0) {
        context.kbd_anchor_row = context.active_row;
        context.kbd_anchor_slot_x = @intFromFloat(t.mirror_slot_x);
    } else {
        context.kbd_anchor_slot_x = -1;
    }
    setFocus(context, .{
        .view = .{ .view = t.view, .surface = t.view.surface(), .sx = 0, .sy = 0 },
    });
    if (t.mirror_slot_x >= 0) {
        ViewManager.scrollToX(context, @intFromFloat(t.mirror_slot_x), @intFromFloat(t.w));
    } else {
        ViewManager.scrollToView(context, t.view);
    }
}

fn cycleStep(context: *ServerContext, dir: i2) void {
    if (context.focused_view == null) {
        focusFirst(context);
        return;
    }
    const t = tileCycle(context, dir) orelse {
        focusFirst(context);
        return;
    };
    std.log.warn("CYCLE dir={} n=2 tile_x={d:.0} mirror={} view={*}", .{ dir, t.x, t.mirror_slot_x >= 0, t.view });
    focusTile(context, t);
}

pub fn focusColumnLeft(context: *ServerContext) void {
    cycleStep(context, -1);
}

pub fn focusColumnRight(context: *ServerContext) void {
    cycleStep(context, @as(i2, 1));
}
