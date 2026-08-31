const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const NodeData = @import("utils/node_data.zig").NodeData;
const ServerContext = @import("../server.zig");
const Border = @import("border.zig");
const Blur = @import("blur.zig");
const FocusManager = @import("focus.zig");
const ViewManager = @import("view_manager.zig");

const View = @This();

/// Which protocol produced this toplevel. Everything below (tiling,
/// focus, borders, drag/resize) is backend-agnostic and only touches
/// the shared fields + these accessors.
pub const Backend = union(enum) {
    xdg: *wlroots.XdgToplevel,
    xwayland: *wlroots.XwaylandSurface,
};

scene_tree: *wlroots.SceneTree,
seat: *wlroots.Seat,
node_data: NodeData = undefined,
context: *ServerContext,
border: ?Border = null,
blur_node: ?*Blur.SceneBlur = null,

x: i32 = 0,
y: i32 = 0,

/// Width set by an interactive resize, overriding the full-width tiling.
custom_width: ?i32 = null,
/// When true the view floats above the tiling layout: it keeps its
/// current position and is excluded from tile calculations.
floating: bool = false,
fullscreen: bool = false,

/// The tiling slot this view occupies (set by the backend commit
/// handlers). The border ring fills it exactly, so the ring can never
/// spill into the neighbouring slot even when the client's buffer
/// carries shadow margins and overflows the configured content size.
slot_w: i32 = 0,
slot_h: i32 = 0,

/// XWayland-only: subtree holding the window content, inset to
/// (bw,bw) and clipped to the content box by commitSurface so a client
/// that ignores/lags its configure cannot spill over the ring band.
surface_tree: ?*wlroots.SceneTree = null,
scene_buffer_node: ?*wlroots.SceneNode = null,

animated_x: f32 = 0,
animated_y: f32 = 0,

map_listener: wl.Listener(void) = undefined,
unmap_listener: wl.Listener(void) = undefined,
destroy_listener: wl.Listener(void) = undefined,
commit_listener: wl.Listener(*wlroots.Surface) = undefined,
new_popup_listener: wl.Listener(*wlroots.XdgPopup) = undefined,
has_new_popup_listener: bool = false,
toplevel_handle: ?*wlroots.ForeignToplevelHandleV1 = null,
request_close_listener: wl.Listener(*wlroots.ForeignToplevelHandleV1) = undefined,
/// Fires when a bar/taskbar (waybar) asks to focus this window
/// (foreign-toplevel request_activate).
request_activate_listener: wl.Listener(*wlroots.ForeignToplevelHandleV1.event.Activated) = undefined,
request_activate_active: bool = false,
associate_listener: wl.Listener(void) = undefined,
map_request_listener: wl.Listener(void) = undefined,
/// Fires when the client changes its _MOTIF_WM_HINTS decorations
/// (XWayland only). Firefox maps and commits BEFORE setting them, so
/// the ring must be re-evaluated when the hint finally arrives.
set_decorations_listener: wl.Listener(void) = undefined,
/// True once onAssociate wired commit/map/unmap listeners (XWayland
/// only; destroys before associate fire with those links unregistered).
associated: bool = false,
/// Fires on the inner wlr_surface's destroy, which happens BEFORE
/// xw_surface.events.destroy. Detaches the surface listeners so wlroots
/// can free the surface without asserting on leftover listeners.
inner_destroy_listener: wl.Listener(*wlroots.Surface) = undefined,
request_fullscreen_listener: wl.Listener(void) = undefined,
request_fullscreen_active: bool = false,

backend: Backend,

/// True only while the client surface is currently mapped. Eagerly
/// created views (every XWayland surface, XDG toplevels pre-configure)
/// and clients that withdrew after a brief map must not take a tiling
/// slot, or they leave phantom gaps in the layout.
pub fn isMapped(view: *View) bool {
    const s = view.surfaceOrNull() orelse return false;
    return s.mapped;
}

pub fn surface(self: *View) *wlroots.Surface {
    return self.surfaceOrNull() orelse unreachable;
}

/// Nullable variant for the destroy path: XWayland nulls its inner
/// wlr_surface (dissociate) before the surface destroy signal fires.
pub fn surfaceOrNull(self: *View) ?*wlroots.Surface {
    return switch (self.backend) {
        .xdg => |t| t.base.surface,
        .xwayland => |x| x.surface,
    };
}

pub fn sendClose(self: *View) void {
    switch (self.backend) {
        .xdg => |t| t.sendClose(),
        .xwayland => |x| x.close(),
    }
}

pub fn setSize(self: *View, w: i32, h: i32) void {
    switch (self.backend) {
        .xdg => |t| _ = t.setSize(w, h),
        .xwayland => |x| x.configure(
            x.x,
            x.y,
            @intCast(w),
            @intCast(h),
        ),
    }
}

pub fn setActivated(self: *View, on: bool) void {
    switch (self.backend) {
        .xdg => |t| _ = t.setActivated(on),
        .xwayland => |x| x.activate(on),
    }
}

pub fn onRequestClose(
    listener: *wl.Listener(*wlroots.ForeignToplevelHandleV1),
    _: *wlroots.ForeignToplevelHandleV1,
) void {
    const view: *View =
        @fieldParentPtr("request_close_listener", listener);

    view.sendClose();
}

pub fn onRequestActivate(
    listener: *wl.Listener(*wlroots.ForeignToplevelHandleV1.event.Activated),
    _: *wlroots.ForeignToplevelHandleV1.event.Activated,
) void {
    const view: *View =
        @fieldParentPtr("request_activate_listener", listener);

    if (!view.isMapped()) return;

    // Don't scroll the viewport away from wherever the user is looking
    // unless the window is actually off-screen.
    ViewManager.scrollIntoView(view.context, view);
    FocusManager.setFocus(view.context, .{
        .view = .{
            .view = view,
            .sx = 0,
            .sy = 0,
        },
    });
}

pub fn onRequestFullscreen(listener: *wl.Listener(void)) void {
    const view: *View = @fieldParentPtr("request_fullscreen_listener", listener);
    // Read the client's requested state instead of toggling: the
    // signal fires when the client REQUESTS fullscreen, not as a toggle.
    view.fullscreen = switch (view.backend) {
        .xdg => |t| t.requested.fullscreen,
        .xwayland => |x| x.fullscreen,
    };
    ViewManager.applyFullscreen(view.context, view);
}

pub fn onSurfaceMap(listener: *wl.Listener(void)) void {
    const view: *View =
        @fieldParentPtr("map_listener", listener);

    const context = view.context;

    std.log.info("SURFACE MAPPED", .{});

    if (view.toplevel_handle) |handle| {
        handle.setTitle(view.title());
        handle.setAppId(view.appId());
        handle.setActivated(context.focused_view == view);
        // Waybar's taskbar is output-scoped: without this the handle has
        // no output association and the taskbar never lists the window.
        if (context.output) |out| handle.outputEnter(out);
    }

    view.scene_tree.node.setEnabled(true);

    FocusManager.setFocus(context, .{
        .view = .{
            .view = view,
            .sx = context.cursor.x - view.x,
            .sy = context.cursor.y - view.y,
        },
    });

    ViewManager.scrollToView(context, view);
}

pub fn onSurfaceUnmap(listener: *wl.Listener(void)) void {
    const view: *View =
        @fieldParentPtr("unmap_listener", listener);

    std.log.info("SURFACE UNMAPPED", .{});

    view.scene_tree.node.setEnabled(false);

    if (view.toplevel_handle) |handle| {
        if (view.context.output) |out| handle.outputLeave(out);
    }

    // Drop this view from the focus history so restoreFocus won't
    // re-focus a window that's no longer visible.
    for (view.context.focus_history.items, 0..) |candidate, i| {
        if (candidate == view) {
            _ = view.context.focus_history.orderedRemove(i);
            break;
        }
    }

    if (view.context.focused_view == view) {
        FocusManager.restoreFocus(view.context);
    }
}

/// Inner wlr_surface is being destroyed (XWayland fires this before
/// xw_surface.events.destroy). Detach the surface listeners so wlroots
/// can free the surface without asserting on leftover listeners.
pub fn onInnerSurfaceDestroy(
    listener: *wl.Listener(*wlroots.Surface),
    wlr_surface: *wlroots.Surface,
) void {
    _ = wlr_surface;
    const view: *View =
        @fieldParentPtr("inner_destroy_listener", listener);

    view.inner_destroy_listener.link.remove();
    if (view.associated) {
        view.commit_listener.link.remove();
        view.map_listener.link.remove();
        view.unmap_listener.link.remove();
        view.associated = false;
    }

    // The wlr_surface is gone for good (dissociate); drop the view from
    // the tiling list now so layout code can't touch its nulled surface
    // before xw_surface.destroy fires. onSurfaceDestroy's later
    // removeView is a no-op.
    ViewManager.removeView(view.context, view);
}

pub fn onSurfaceDestroy(listener: *wl.Listener(void)) void {
    const view: *View =
        @fieldParentPtr("destroy_listener", listener);

    const context = view.context;

    std.log.info("SURFACE DESTROYED", .{});

    // Stop any future callbacks from referring to this View.
    // XDG views always register these in onNewXdgToplevel. XWayland
    // registers them in onAssociate (guarded by `associated`), and the
    // inner surface may die first — whichever destroy fires first
    // removes them and clears the flag.
    // XDG registers commit/map/unmap always; XWayland only after
    // associate. inner_destroy_listener is XWayland-only.
    if (view.backend == .xdg) {
        view.commit_listener.link.remove();
        view.map_listener.link.remove();
        view.unmap_listener.link.remove();
        if (view.has_new_popup_listener) {
            view.new_popup_listener.link.remove();
            view.has_new_popup_listener = false;
        }
    }
    if (view.request_fullscreen_active) {
        view.request_fullscreen_listener.link.remove();
        view.request_fullscreen_active = false;
    }
    if (view.associated) {
        view.commit_listener.link.remove();
        view.map_listener.link.remove();
        view.unmap_listener.link.remove();
        view.inner_destroy_listener.link.remove();
        view.associated = false;
    }
    view.destroy_listener.link.remove();

    // The associate/map_request/set_decorations listeners are only
    // registered for XWayland views; removing an unregistered link is UB.
    if (view.backend == .xwayland) {
        view.associate_listener.link.remove();
        view.map_request_listener.link.remove();
        view.set_decorations_listener.link.remove();
    }

    if (view.toplevel_handle) |handle| {
        view.request_close_listener.link.remove();
        view.request_activate_listener.link.remove();
        view.request_activate_active = false;
        handle.destroy();
        view.toplevel_handle = null;
    }

    // Drop this view from the focus history.
    for (context.focus_history.items, 0..) |candidate, i| {
        if (candidate == view) {
            _ = context.focus_history.orderedRemove(i);
            break;
        }
    }

    // Clear focus if this was the focused view, restoring the last
    // focused app when possible.
    if (context.focused_view == view) {
        FocusManager.restoreFocus(context);
    } else if (view.surfaceOrNull()) |surf| {
        if (context.focused_surface == surf) {
            context.seat.pointerClearFocus();
            context.focused_surface = null;
        }
    }

    // A dangling previous_focused_view would crash updateBorders
    // on the next frame.
    if (context.previous_focused_view == view) {
        context.previous_focused_view = null;
    }

    // Remove it from the WM's live view list BEFORE freeing it.
    ViewManager.removeView(context, view);

    // Re-pack the remaining windows.
    ViewManager.updateViewPositions(context);

    // Null out node_data pointers so scene graph lookups don't
    // dereference freed memory.
    //
    // XDG: createSceneXdgSurface registers an internal destroy listener
    // that fires BEFORE ours, so scene_tree + border rect are already
    // freed by wlroots — skip them to avoid use-after-free.
    //
    // XWayland: the scene tree is manually created (createSceneTree) and
    // persists until explicit cleanup, so null its data.
    view.node_data = .{ .layer = undefined };
    if (view.backend == .xwayland) {
        view.scene_tree.node.data = null;
        if (view.border) |*b| b.rect.node.data = null;
    }

    // Free the blur node. For XDG the scene tree (and blender) is freed
    // by wlroots before ours; XWayland's tree persists, so destroy it.
    if (view.backend == .xwayland) Blur.destroyForView(view);

    // Clear drag/resize state that may reference this view.
    if (context.drag_view == view) context.drag_view = null;
    if (context.resize_view == view) context.resize_view = null;
    if (context.focused_surface == view.surfaceOrNull())
        context.focused_surface = null;

    // Undo snapshots still hold this View; drop them so undo can't touch
    // freed memory after we destroy it.
    context.discardUndoFor(view);

    std.heap.c_allocator.destroy(view);
}

fn title(self: *View) [*:0]const u8 {
    return switch (self.backend) {
        .xdg => |t| t.title orelse "",
        .xwayland => |x| if (x.title) |t| t else "",
    };
}

fn appId(self: *View) [*:0]const u8 {
    return switch (self.backend) {
        .xdg => |t| t.app_id orelse "",
        .xwayland => |x| if (x.class) |c| c else "",
    };
}

pub fn onViewCommit(
    listener: *wl.Listener(*wlroots.Surface),
    wlr_surface: *wlroots.Surface,
) void {
    const view: *View =
        @fieldParentPtr("commit_listener", listener);

    switch (view.backend) {
        .xdg => |t| xdg_mod.commitToplevel(view, t, wlr_surface),
        .xwayland => |x| xw_mod.commitSurface(view, x, wlr_surface),
    }

    // Re-sync the border/rounding now that surface.current.width/height
    // have caught up with the client's buffer, so the ring matches the
    // window immediately on resize instead of on the next animation tick.
    Border.updateViewBorder(view, @floatFromInt(view.x), null);
    Blur.updateForView(view);
}

const xdg_mod = @import("xdg.zig");
const xw_mod = @import("xwayland.zig");
