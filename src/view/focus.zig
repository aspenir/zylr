const wlroots = @import("wlroots");
const std = @import("std");

const NodeData = @import("utils/node_data.zig").NodeData;
const View = @import("view.zig");
const LayerView = @import("layer.zig");
const ServerContext = @import("../server.zig");
const BorderManager = @import("border.zig");
const InputRelay = @import("../input/input_relay.zig");
const ViewManager = @import("view_manager.zig");
const FocusTarget = union(enum) {
    none,
    view: struct {
        view: *View,
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
            const data: *NodeData =
                @ptrCast(@alignCast(data_ptr));

            switch (data.*) {
                .view => |view| {
                    const view_ptr: *View = @ptrCast(@alignCast(view));
                    setFocus(context, .{
                        .view = .{
                            .view = view_ptr,
                            .sx = sx,
                            .sy = sy,
                        },
                    });
                    // Clicking a window hanging off-screen brings it in.
                    ViewManager.scrollIntoView(context, view_ptr);
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
                .sx = 0,
                .sy = 0,
            },
        });
        ViewManager.scrollToView(context, candidate);
        return;
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
            context.focused_view = null;
            context.focused_layer = null;
            BorderManager.updateBorders(context);
            InputRelay.notifyFocus(null);
        },

        .view => |target_view| {
            const view = target_view.view;

            // Zombies (eagerly created XWayland/XDG views whose client
            // never mapped or withdrew again) must not take focus.
            if (!view.isMapped()) return;

            const surface = view.surface();

            if (context.focused_surface != surface) {
                context.seat.pointerNotifyEnter(
                    surface,
                    target_view.sx,
                    target_view.sy,
                );
                context.focused_surface = surface;
            }

            if (context.focused_view == view and
                context.focused_layer == null)
            {
                return;
            }

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

            // Deactivate the previously focused view's handle.
            if (context.previous_focused_view) |prev| {
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

            if (view.toplevel_handle) |handle| {
                handle.setActivated(true);
            }

            // Only floating views need raised z-order; tiled views
            // don't overlap, and raising them pushes floating views down.
            if (view.floating) view.scene_tree.node.raiseToTop();

            BorderManager.updateBorders(context);
            InputRelay.notifyFocus(context.focused_surface);

            std.log.info("FOCUS VIEW", .{});
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
            InputRelay.notifyFocus(surface);

            std.log.info("FOCUS LAYER", .{});
        },
    }
}

/// Focus the leftmost mapped view (the items[0] fallback must skip
/// zombies, else Mod+H focuses the invisible phantom window).
fn focusFirst(context: *ServerContext) void {
    for (context.views.items) |view| {
        if (!view.isMapped()) continue;

        setFocus(context, .{
            .view = .{ .view = view, .sx = 0, .sy = 0 },
        });
        ViewManager.scrollToView(context, view);
        return;
    }
}

pub fn focusColumnLeft(context: *ServerContext) void {
    const current = context.focused_view orelse {
        focusFirst(context);
        return;
    };

    var i: ?usize = null;
    for (context.views.items, 0..) |view, idx| {
        if (view == current) {
            i = idx;
            break;
        }
    }

    const idx = i orelse {
        // focused_view is stale (not in views list) — reset and focus first.
        context.focused_view = null;
        focusFirst(context);
        return;
    };

    // Walk left past any unmapped zombies.
    var j = idx;
    while (j > 0) {
        j -= 1;
        const target = context.views.items[j];
        if (!target.isMapped()) continue;

        setFocus(context, .{
            .view = .{ .view = target, .sx = 0, .sy = 0 },
        });
        ViewManager.scrollToView(context, target);
        return;
    }
}
pub fn focusColumnRight(context: *ServerContext) void {
    const current = context.focused_view orelse {
        focusFirst(context);
        return;
    };

    var i: ?usize = null;
    for (context.views.items, 0..) |view, idx| {
        if (view == current) {
            i = idx;
            break;
        }
    }

    const idx = i orelse {
        context.focused_view = null;
        focusFirst(context);
        return;
    };

    var j = idx + 1;
    while (j < context.views.items.len) : (j += 1) {
        const target = context.views.items[j];
        if (!target.isMapped()) continue;

        setFocus(context, .{
            .view = .{ .view = target, .sx = 0, .sy = 0 },
        });
        ViewManager.scrollToView(context, target);
        return;
    }
}
