const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const ServerContext = @import("../server.zig");
const Mirror = @import("../mirror.zig");
const Border = @import("border.zig");
const Blur = @import("blur.zig");
const ViewManager = @import("view_manager.zig");
const View = @import("view.zig");
const NodeData = @import("utils/node_data.zig");

fn wlrClientPid(client: *wl.Client) i32 {
    return client.getCredentials().pid;
}

pub fn onNewXdgTopLevel(
    listener: *wl.Listener(*wlroots.XdgToplevel),
    xdg_toplevel: *wlroots.XdgToplevel,
) void {
    const context: *ServerContext =
        @fieldParentPtr("new_xdg_toplevel_listener", listener);

    std.log.info("NEW XDG TOPLEVEL", .{});
    {
        const pid = wlrClientPid(xdg_toplevel.base.client.client);
        const l = std.fmt.allocPrint(
            std.heap.c_allocator,
            "NEW XDG TOPLEVEL (client chose Wayland) pid={d}\n",
            .{pid},
        ) catch return;
        defer std.heap.c_allocator.free(l);
        const f = std.c.fopen("/tmp/zylr_xw.log", "a") orelse return;
        _ = std.c.fwrite(l.ptr, 1, l.len, f);
        _ = std.c.fclose(f);
    }

    const xdg_surface = xdg_toplevel.base;

    const view = std.heap.c_allocator.create(View) catch |err| {
        std.log.err("failed to allocate View: {}", .{err});
        return;
    };

    view.* = .{
        .scene_tree = context.views_tree.?.createSceneXdgSurface(xdg_surface) catch |err| {
            std.log.err("createSceneXdgSurface failed: {}", .{err});
            std.heap.c_allocator.destroy(view);
            return;
        },
        .backend = .{ .xdg = xdg_toplevel },
        .seat = context.seat,
        .context = context,
    };
    view.node_data = .{ .view = view };
    // Hidden until first map (onSurfaceMap enables the tree) so a
    // pre-configure toplevel can't render its border rect as a phantom.
    view.scene_tree.node.setEnabled(false);
    Border.createViewBorder(view);
    Blur.createForView(view, view.scene_tree);

    view.commit_listener =
        wl.Listener(*wlroots.Surface).init(View.onViewCommit);

    xdg_surface.surface.events.commit.add(&view.commit_listener);

    view.scene_tree.node.data = &view.node_data;
    // Open beside the focused window, not at the end of the row: slots
    // follow list order, so inserting after the focused window lands the
    // new tile directly to its right. Row end when nothing is focused.
    const ins = if (context.focused_view) |fv|
        (std.mem.indexOfScalar(*View, context.views.items, fv) orelse context.views.items.len) + 1
    else
        context.views.items.len;
    if (!ViewManager.insertView(context, view, ins)) {
        std.log.err("Failed to add view", .{});
        std.heap.c_allocator.destroy(view);
        return;
    }

    view.map_listener =
        wl.Listener(void).init(View.onSurfaceMap);
    view.unmap_listener =
        wl.Listener(void).init(View.onSurfaceUnmap);
    view.destroy_listener =
        wl.Listener(void).init(View.onSurfaceDestroy);

    xdg_surface.surface.events.map.add(&view.map_listener);
    xdg_surface.surface.events.unmap.add(&view.unmap_listener);
    xdg_toplevel.events.destroy.add(&view.destroy_listener);

    view.new_popup_listener = wl.Listener(*wlroots.XdgPopup).init(onNewXdgPopup);
    xdg_surface.events.new_popup.add(&view.new_popup_listener);
    view.has_new_popup_listener = true;

    view.request_fullscreen_listener = wl.Listener(void).init(View.onRequestFullscreen);
    xdg_toplevel.events.request_fullscreen.add(&view.request_fullscreen_listener);
    view.request_fullscreen_active = true;

    view.set_parent_listener = wl.Listener(void).init(View.onSetParent);
    xdg_toplevel.events.set_parent.add(&view.set_parent_listener);
    view.set_parent_active = true;

    // Foreign-toplevel handle for the xdg-desktop-portal (window pickers,
    // task bars). Created on map so title/app_id are available.
    const handle = wlroots.ForeignToplevelHandleV1.create(
        context.toplevel_manager,
    ) catch |err| {
        std.log.err("failed to create toplevel handle: {}", .{err});
        return;
    };
    view.toplevel_handle = handle;

    view.request_close_listener =
        wl.Listener(*wlroots.ForeignToplevelHandleV1).init(View.onRequestClose);
    handle.events.request_close.add(&view.request_close_listener);
    view.request_activate_listener =
        wl.Listener(*wlroots.ForeignToplevelHandleV1.event.Activated).init(View.onRequestActivate);
    view.request_activate_active = true;
    handle.events.request_activate.add(&view.request_activate_listener);
}

/// Per-decoration state. zylr draws its own tiling borders, so we
/// always serve server-side decorations: GTK/Qt clients then skip their
/// client-side titlebars and we don't get double titlebars.
const DecorationContext = struct {
    decoration: *wlroots.XdgToplevelDecorationV1,
    context: *ServerContext,

    request_mode_listener: wl.Listener(*wlroots.XdgToplevelDecorationV1) = undefined,
    destroy_listener: wl.Listener(*wlroots.XdgToplevelDecorationV1) = undefined,
    commit_listener: wl.Listener(*wlroots.Surface) = undefined,
    /// Whether the commit listener is currently attached. onCommit
    /// removes it and must not be read afterwards (the old `undefined`
    /// sentinel made onDestroy read uninitialized memory).
    commit_active: bool = false,

    /// setMode schedules a configure, which asserts the xdg surface is
    /// initialized. Clients (e.g. a nested wlroots wayland backend) can
    /// bind a decoration before the toplevel's first commit, so defer
    /// the mode until the base surface initializes.
    fn applyMode(self: *DecorationContext) void {
        if (!self.decoration.toplevel.base.initialized) return;
        _ = self.decoration.setMode(.server_side);
    }

    fn onRequestMode(
        listener: *wl.Listener(*wlroots.XdgToplevelDecorationV1),
        decoration: *wlroots.XdgToplevelDecorationV1,
    ) void {
        _ = decoration;
        const self: *DecorationContext =
            @fieldParentPtr("request_mode_listener", listener);
        self.applyMode();
    }

    fn onCommit(
        listener: *wl.Listener(*wlroots.Surface),
        surface: *wlroots.Surface,
    ) void {
        _ = surface;
        const self: *DecorationContext =
            @fieldParentPtr("commit_listener", listener);
        self.applyMode();
        self.commit_listener.link.remove();
        self.commit_active = false;
    }

    fn onDestroy(
        listener: *wl.Listener(*wlroots.XdgToplevelDecorationV1),
        decoration: *wlroots.XdgToplevelDecorationV1,
    ) void {
        _ = decoration;
        const self: *DecorationContext =
            @fieldParentPtr("destroy_listener", listener);

        self.request_mode_listener.link.remove();
        if (self.commit_active) self.commit_listener.link.remove();
        self.destroy_listener.link.remove();
        std.heap.c_allocator.destroy(self);
    }
};

pub fn onNewXdgDecoration(
    listener: *wl.Listener(*wlroots.XdgToplevelDecorationV1),
    decoration: *wlroots.XdgToplevelDecorationV1,
) void {
    const context: *ServerContext =
        @fieldParentPtr("new_decoration_listener", listener);

    const deco_ctx =
        std.heap.c_allocator.create(DecorationContext) catch |err| {
            std.log.err("Failed to allocate DecorationContext: {}", .{err});
            return;
        };
    deco_ctx.* = .{
        .decoration = decoration,
        .context = context,
    };

    deco_ctx.request_mode_listener =
        wl.Listener(*wlroots.XdgToplevelDecorationV1).init(DecorationContext.onRequestMode);
    deco_ctx.destroy_listener =
        wl.Listener(*wlroots.XdgToplevelDecorationV1).init(DecorationContext.onDestroy);
    deco_ctx.commit_listener =
        wl.Listener(*wlroots.Surface).init(DecorationContext.onCommit);

    decoration.events.request_mode.add(&deco_ctx.request_mode_listener);
    decoration.events.destroy.add(&deco_ctx.destroy_listener);

    if (decoration.toplevel.base.initialized) {
        std.log.debug("xdg-decoration: serving server_side (already init)", .{});
        _ = decoration.setMode(.server_side);
    } else {
        std.log.debug("xdg-decoration: deferring server_side until init", .{});
        decoration.toplevel.base.surface.events.commit.add(&deco_ctx.commit_listener);
        deco_ctx.commit_active = true;
    }
}

/// Tracks a live xdg popup so its parent chain can be walked by pointer
/// lookup (never dereferencing a parent surface that may have been freed
/// during teardown). Removes itself from the registry on destroy.
pub const PopupNode = struct {
    popup: *wlroots.XdgPopup,
    context: *ServerContext,
    /// The toplevel view the popup hangs off; its x/y anchor the unconstrain box.
    view: *View,
    destroy_listener: wl.Listener(void) = undefined,
    /// Deferred unconstrain: wlroots' wlr_xdg_popup_unconstrain_from_box ends in
    /// wlr_xdg_surface_schedule_configure, which asserts the surface is
    /// initialized. That only flips on the popup's first commit, but new_popup
    /// fires before any commit, so unconstraining there aborts the compositor.
    /// Instead wait for the popup's first commit (same trick as DecorationContext).
    commit_listener: wl.Listener(*wlroots.Surface) = undefined,
    commit_active: bool = false,
    unconstrain_done: bool = false,
    configure_listener: wl.Listener(*wlroots.XdgSurface.Configure) = undefined,
    configure_active: bool = false,
    ack_listener: wl.Listener(*wlroots.XdgSurface.Configure) = undefined,
    ack_active: bool = false,
    /// True once the client acks a configure; logged on destroy to tell
    /// "client saw the configure but never acked" from a never-sent ack.
    ack_received: bool = false,
    /// Lets nested popups (submenus, flyouts) reach zylr: firefox menus are
    /// often popups of popups, and the view only listens on the toplevel.
    new_popup_listener: wl.Listener(*wlroots.XdgPopup) = undefined,
    new_popup_active: bool = false,
    /// Attached to the popup's scene tree node so pointer hit-tests
    /// resolve the popup surface instead of the toplevel beneath it.
    node_data: NodeData.NodeData = undefined,

    fn unconstrain(self: *PopupNode) void {
        if (!self.popup.base.initialized) return;
        if (self.context.output) |output| {
            var box: wlroots.Box = undefined;
            self.context.output_layout.getBox(output, &box);
            // Popup geometry is in the toplevel scene-tree frame, so the
            // constraint box must be too. view.x/y are layout coordinates
            // (tiling math on pixel-width surfaces); the scene node position
            // is what actually lands on screen -- on scaled/inset layouts the
            // two differ and the wrong offset repositions popups off-target.
            box.x -= self.view.scene_tree.node.x;
            box.y -= self.view.scene_tree.node.y;
            self.popup.unconstrainFromBox(&box);
        }
        self.view.scene_tree.node.raiseToTop();
    }

    /// Hand keyboard focus back to the owning toplevel when the popup
    /// closes, so the seat never keeps pointing at a destroyed surface.
    fn restoreKeyboardFocus(self: *PopupNode) void {
        const surface = self.view.surfaceOrNull() orelse return;
        if (self.context.keyboards.items.len == 0) return;
        const keyboard = self.context.keyboards.items[0].keyboard;
        self.context.seat.keyboardNotifyEnter(
            surface,
            keyboard.keycodes[0..keyboard.num_keycodes],
            &keyboard.modifiers,
        );
    }

    fn onCommit(listener: *wl.Listener(*wlroots.Surface), surface: *wlroots.Surface) void {
        _ = surface;
        const node: *PopupNode = @fieldParentPtr("commit_listener", listener);
        if (!node.unconstrain_done) {
            if (!node.popup.base.initialized) {
                std.log.debug("xdg: popup commit before init, deferring unconstrain", .{});
                return;
            }
            if (!popupChainIntact(node.context, node.popup)) {
                std.log.debug("xdg: skipping deferred unconstrain, parent chain broken", .{});
                return;
            }
            node.unconstrain();
            node.unconstrain_done = true;
        }
        std.log.debug("xdg: popup commit init={} buf={} fcb={} entered={} geom=({},{},{},{})", .{
            node.popup.base.initialized,
            node.popup.base.surface.current.buffer != null,
            !node.popup.base.surface.current.frame_callback_list.empty(),
            node.popup.base.surface.current_outputs.length(),
            node.popup.current.geometry.x,
            node.popup.current.geometry.y,
            node.popup.current.geometry.width,
            node.popup.current.geometry.height,
        });
        Mirror.updateMirrors(node.view);
        if (node.context.output) |out| out.scheduleFrame();
    }

    fn onConfigure(listener: *wl.Listener(*wlroots.XdgSurface.Configure), configure: *wlroots.XdgSurface.Configure) void {
        _ = listener;
        const geom = configure.role.popup;
        std.log.debug("xdg: popup configure serial={} geom=({},{},{},{})", .{
            configure.serial,
            geom.geometry.x,
            geom.geometry.y,
            geom.geometry.width,
            geom.geometry.height,
        });
    }

    /// The client says it accepted the configure. A stalemate here means the
    /// draw never happened client-side, not that the compositor held the
    /// frame; combined with the commit trace this tells ack-from-paint apart.
    fn onAckConfigure(listener: *wl.Listener(*wlroots.XdgSurface.Configure), configure: *wlroots.XdgSurface.Configure) void {
        const node: *PopupNode = @fieldParentPtr("ack_listener", listener);
        node.ack_received = true;
        std.log.debug("xdg: popup ACK serial={}", .{configure.serial});
    }

    fn onDestroy(listener: *wl.Listener(void)) void {
        const node: *PopupNode = @fieldParentPtr("destroy_listener", listener);
        std.log.debug("xdg: popup destroyed buf={} ack_done={}", .{
            node.popup.base.surface.current.buffer != null,
            node.ack_received,
        });
        node.destroy_listener.link.remove();
        if (node.commit_active) node.commit_listener.link.remove();
        if (node.configure_active) node.configure_listener.link.remove();
        if (node.new_popup_active) node.new_popup_listener.link.remove();
        if (node.ack_active) node.ack_listener.link.remove();
        if (node.context.seat.keyboard_state.focused_surface == node.popup.base.surface) {
            node.restoreKeyboardFocus();
        }
        const list = &node.context.popups;
        if (std.mem.indexOfScalar(*PopupNode, list.items, node)) |i| {
            _ = list.swapRemove(i);
        }
        // Reconcile mirrors now that the popup left the live list, so the
        // copy node is dropped before the popup surface is freed.
        Mirror.updateMirrors(node.view);
        std.heap.c_allocator.destroy(node);
    }
};

/// True if `surface` is the inner surface of a View still tracked as live.
/// Pointer comparison only; never dereferences `surface`.
fn isViewSurface(context: *ServerContext, surface: *wlroots.Surface) bool {
    for (context.views.items) |v| {
        const s = v.surfaceOrNull() orelse continue;
        if (s == surface) return true;
    }
    return false;
}

/// Returns the live PopupNode whose surface equals `surface`, or null.
/// Pointer comparison only.
fn popupNodeFor(context: *ServerContext, surface: *wlroots.Surface) ?*PopupNode {
    for (context.popups.items) |node| {
        if (node.popup.base.surface == surface) return node;
    }
    return null;
}

/// wlroots' unconstrain_from_box walks the parent chain and asserts the
/// chain terminates in a non-null parent. A nested popup created while its
/// toplevel/parent is being torn down (e.g. an on-screen keyboard hiding
/// on focus-out) has an ancestor with a null parent, which trips that
/// assert. Worse, the parent surface pointer can be freed, so dereferencing
/// it (as wlroots and earlier guards did) is a use-after-free crash. This
/// checks the chain by pointer lookup against only surfaces zylr still
/// owns as live (views + registered popups), so it never reads freed
/// memory. Returns false (skip unconstrain) for any unknown/dangling link.
fn popupChainIntact(context: *ServerContext, popup: *wlroots.XdgPopup) bool {
    var parent: ?*wlroots.Surface = popup.parent;
    while (parent) |surf| {
        // A live toplevel view is a healthy chain endpoint.
        if (isViewSurface(context, surf)) return true;
        // A live popup: keep walking through its parent.
        const parent_node = popupNodeFor(context, surf) orelse return false;
        if (parent_node.popup.parent == null) return false;
        parent = parent_node.popup.parent;
    }
    return false;
}

fn createPopupNode(context: *ServerContext, view: *View, popup: *wlroots.XdgPopup) ?*PopupNode {
    std.log.debug("xdg: new popup initialized={} parent={} view_pos=({},{})", .{
        popup.base.initialized,
        popup.parent != null,
        view.x,
        view.y,
    });
    {
        var req: wlroots.Box = undefined;
        const r = &popup.scheduled.rules;
        r.getGeometry(&req);
        std.log.debug("xdg: pos anchor=({},{},{},{}) anchor={} grav={} adj={x} reactive={} off=({},{}) req=({},{},{},{})", .{
            r.anchor_rect.x,
            r.anchor_rect.y,
            r.anchor_rect.width,
            r.anchor_rect.height,
            @intFromEnum(r.anchor),
            @intFromEnum(r.gravity),
            @as(u32, @bitCast(r.constraint_adjustment)),
            r.reactive,
            r.offset.x,
            r.offset.y,
            req.x,
            req.y,
            req.width,
            req.height,
        });
    }
    if (popup.base.initialized) {
        std.log.debug("xdg: popup geometry=({},{},{},{}) reactive={} adjust={x}", .{
            popup.current.geometry.x,
            popup.current.geometry.y,
            popup.current.geometry.width,
            popup.current.geometry.height,
            popup.current.reactive,
            @as(u32, @bitCast(popup.scheduled.rules.constraint_adjustment)),
        });
    }

    const node = std.heap.c_allocator.create(PopupNode) catch {
        std.log.warn("xdg: failed to allocate popup node", .{});
        return null;
    };
    node.* = .{ .popup = popup, .context = context, .view = view };
    node.destroy_listener = wl.Listener(void).init(PopupNode.onDestroy);
    popup.events.destroy.add(&node.destroy_listener);
    context.popups.append(std.heap.c_allocator, node) catch {
        std.log.warn("xdg: failed to register popup", .{});
        std.heap.c_allocator.destroy(node);
        return null;
    };

    // wlroots' scene helper does NOT add xdg popups automatically: the
    // compositor must create a scene node for them or they never render.
    // Parent it under the parent surface's scene tree (a toplevel, or the
    // outer popup for nested menus) so it draws with the view; the helper
    // positions it from popup->current.geometry on each commit and
    // destroys itself with the surface.
    const parent_tree: *wlroots.SceneTree = if (popup.parent) |parent| blk: {
        if (parent.data) |d| {
            break :blk @as(*wlroots.SceneTree, @ptrCast(@alignCast(d)));
        }
        break :blk view.scene_tree;
    } else view.scene_tree;
    const popup_tree = parent_tree.createSceneXdgSurface(popup.base) catch |err| {
        std.log.err("createSceneXdgSurface(popup) failed: {}", .{err});
        return null;
    };
    popup.base.data = popup_tree;
    node.node_data = .{ .popup = popup };
    popup_tree.node.data = &node.node_data;
    std.log.debug("xdg: popup scene node created enabled={} node.data={}", .{
        popup_tree.node.enabled,
        popup_tree.node.data != null,
    });

    // GDK throttles the popup's first real paint until the compositor hands
    // over a frame: it stages the buffer at show, then waits for the frame
    // pipeline. A popup that fits the output unadjusted damages nothing, so
    // zylr renders no frame and GDK's buffer never commits -- the popup
    // never appears. Kick a frame on popup activity regardless of damage,
    // like every stock compositor does implicitly while opening a menu.
    if (context.output) |out| out.scheduleFrame();

    // wlr_scene only emits wl_surface.enter once a surface's node has a
    // visible region, but gecko commits its popups empty and waits before
    // painting -- a bufferless surface (0x0) never intersects, so it never
    // enters, and gecko's menu stays blank forever. Emit enter up front for
    // the view's output; this also registers current_outputs so wlr's frame
    // pacing works for the bufferless case.
    if (context.output) |out| popup.base.surface.sendEnter(out);

    // Nested popups (submenus, flyouts) are parented to a popup; listen on
    // this popup's base too so the whole chain reaches zylr.
    node.new_popup_listener = wl.Listener(*wlroots.XdgPopup).init(onNewPopupForNode);
    popup.base.events.new_popup.add(&node.new_popup_listener);
    node.new_popup_active = true;

    view.scene_tree.node.raiseToTop();
    dumpSceneStructure(view, popup_tree, node);
    if (!popupChainIntact(context, popup)) {
        std.log.debug("xdg: skipping unconstrain for popup with broken parent chain", .{});
        return node;
    }
    if (popup.base.initialized) {
        std.log.debug("xdg: popup already initialized, unconstraining now", .{});
        node.unconstrain();
    } else {
        node.commit_listener = wl.Listener(*wlroots.Surface).init(PopupNode.onCommit);
        popup.base.surface.events.commit.add(&node.commit_listener);
        node.commit_active = true;
    }
    node.configure_listener = wl.Listener(*wlroots.XdgSurface.Configure).init(PopupNode.onConfigure);
    popup.base.events.configure.add(&node.configure_listener);
    node.configure_active = true;
    node.ack_listener = wl.Listener(*wlroots.XdgSurface.Configure).init(PopupNode.onAckConfigure);
    popup.base.events.ack_configure.add(&node.ack_listener);
    node.ack_active = true;
    return node;
}

fn dumpSceneStructure(view: *View, popup_tree: *wlroots.SceneTree, popup_node: *PopupNode) void {
    var layout_box: wlroots.Box = undefined;
    if (view.context.output) |out| view.context.output_layout.getBox(out, &layout_box);
    std.log.debug("xdg: view.x={} view.y={} scene_node_pos=({},{}) layout=({},{},{},{})", .{
        view.x,
        view.y,
        view.scene_tree.node.x,
        view.scene_tree.node.y,
        layout_box.x,
        layout_box.y,
        layout_box.width,
        layout_box.height,
    });
    std.log.debug("xdg: scene tree children in paint order:", .{});
    var it = view.scene_tree.children.iterator(.forward);
    while (it.next()) |n| {
        const tag: []const u8 = if (n.data == @as(?*anyopaque, @ptrCast(&popup_node.node_data))) "POPUP" else "?";
        std.log.debug("xdg:   scene child type={} enabled={} pos=({},{}) data={s}", .{
            @intFromEnum(n.type),
            n.enabled,
            n.x,
            n.y,
            tag,
        });
    }
    std.log.debug("xdg:   newest popup_tree node type={} enabled={} pos=({},{})", .{
        @intFromEnum(popup_tree.node.type),
        popup_tree.node.enabled,
        popup_tree.node.x,
        popup_tree.node.y,
    });
}

fn onNewXdgPopup(listener: *wl.Listener(*wlroots.XdgPopup), popup: *wlroots.XdgPopup) void {
    const view: *View = @fieldParentPtr("new_popup_listener", listener);
    _ = createPopupNode(view.context, view, popup);
    Mirror.updateMirrors(view);
}

fn onNewPopupForNode(listener: *wl.Listener(*wlroots.XdgPopup), popup: *wlroots.XdgPopup) void {
    const node: *PopupNode = @fieldParentPtr("new_popup_listener", listener);
    _ = createPopupNode(node.context, node.view, popup);
    Mirror.updateMirrors(node.view);
}

pub fn commitToplevel(
    view: *View,
    xdg_toplevel: *wlroots.XdgToplevel,
    surface: *wlroots.Surface,
) void {
    const context = view.context;
    const output = context.output orelse {
        std.log.err("No output for initial configure", .{});
        return;
    };

    var ew: c_int = 0;
    var eh: c_int = 0;
    output.effectiveResolution(&ew, &eh);

    // Inset by gaps_out on all sides so borders (and the background)
    // are visible instead of the window covering the whole screen.
    ew -= @as(c_int, @intCast(context.gaps_out * 2));
    eh -= @as(c_int, @intCast(context.gaps_out * 2));

    // Shrink to the area left after layer-shell exclusive zones
    // (e.g. a bar at the top edge).
    if (context.usable_area.width > 0) {
        const left = context.usable_area.x;
        const right = ew - (context.usable_area.x + context.usable_area.width);
        ew -= left + right;
        // Both side gaps stay visible even at ratio 1.0: the tile spans
        // usable.width - 2*gaps, and its left edge sits at usable.x + gaps.
        ew -= @as(c_int, @intCast(context.gaps_out * 2));
        eh = context.usable_area.height - @as(c_int, @intCast(context.gaps_out * 2));
    }

    // A window resized by edge-drag keeps its width across commits.
    // New windows default to a fraction of the usable width (post-waybar):
    // ratio 1.0 fills the area next to the bar, never under it.
    if (view.pile_width) |pw| {
        ew = pw;
    } else if (view.custom_width) |w| {
        ew = w;
    } else {
        view.custom_width = @as(i32, @intFromFloat(
            @as(f32, @floatFromInt(ew)) * context.view_width_ratio,
        ));
        ew = view.custom_width.?;
    }

    // The lone tiled window fills the workspace (width ratio 1); it
    // shrinks back to its custom width when a second window joins the row.
    if (!view.floating and !view.fullscreen and ViewManager.activeTiledCount(context) == 1) {
        ew = context.usable_area.width - @as(c_int, @intCast(context.gaps_out * 2));
    }

    // The slot the border ring must fill exactly: the ring is sized from
    // this, never from the client's buffer, so a buffer carrying
    // client-side shadow margins can't overflow into the neighbour.
    // Floating views keep their own geometry: set the slot from the
    // actual surface size so the border draws correctly, but don't
    // force them into a tile slot (except on the first commit, which
    // must send a configure or the client never maps).
    if (view.floating or view.fullscreen) {
        if (view.floating) {
            const ws = view.borderWidths();
            // Size the ring from the client's real content box (the XDG
            // geometry), not the buffer, which can carry CSD shadow margins.
            // Using the buffer makes the right/bottom border band side+margin
            // instead of side (the "border too big on right/bottom" bug).
            // Fall back to the buffer before the first commit announces a
            // geometry.
            const g = xdg_toplevel.base.geometry;
            const new_w = if (g.width > 0 and g.height > 0)
                g.width + ws.horizontal()
            else
                @max(1, surface.current.width + ws.horizontal());
            const new_h = if (g.width > 0 and g.height > 0)
                g.height + ws.vertical()
            else
                @max(1, surface.current.height + ws.vertical());
            // A freshly-mapped float was centered from its first (often
            // still empty) buffer; once the client commits its real
            // geometry, re-center so the window doesn't stay anchored at
            // the small-box center and spill off to the bottom/right.
            // Never fight an in-flight drag or resize.
            if (context.drag_view != view and context.resize_view != view and
                (new_w != view.slot_w or new_h != view.slot_h))
            {
                ViewManager.centerFloating(context, view, .{ new_w, new_h });
            } else {
                view.slot_w = new_w;
                view.slot_h = new_h;
            }
            // A float rule can run before the toplevel's first commit, so
            // the initial configure must still be sent or the client
            // never maps. Size 0 = "choose your own natural size",
            // the standard way to float a window.
            if (xdg_toplevel.base.initial_commit) {
                _ = xdg_toplevel.setSize(0, 0);
            }
        }
        return;
    }

    view.slot_w = ew;
    // A pile member's commit must keep its stacked slot height, not snap
    // back to the full viewport height (that would overlap its pile mates).
    if (ViewManager.pileSlot(context, view)) |ps| eh = ps.height;
    view.slot_h = eh;

    // the toplevel's content box is the slot inset by the
    // border widths. The scene surface sits at +(left,top) inside the slot, so a
    // slot-sized ring can wrap it without spilling into neighbours.
    const ws = view.borderWidths();
    const content_w = @max(1, ew - ws.horizontal());
    const content_h = @max(1, eh - ws.vertical());

    // Send a new configure only when the target geometry actually changed
    // from the last one sent. Comparing against the client's committed size
    // (the old gate) is wrong for tiled windows whose content box differs
    // from the surface size by the client's own chrome — the client always
    // "differs", so the identical configure was re-sent every commit and
    // every ack spawned another commit: a self-sustaining 9k/s ping-pong on
    // the wire (the Electron idle storm). Track what we announced instead.
    const size_changed = content_w != view.last_sent_w or content_h != view.last_sent_h;

    if (xdg_toplevel.base.initial_commit or size_changed) {
        view.last_sent_w = content_w;
        view.last_sent_h = content_h;
        _ = xdg_toplevel.setBounds(content_w, content_h);
        _ = xdg_toplevel.setSize(content_w, content_h);
        _ = xdg_toplevel.setWmCapabilities(.{
            .window_menu = true,
            .maximize = true,
            .fullscreen = true,
            .minimize = true,
        });
        _ = xdg_toplevel.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
        // A resized window keeps its own width; everything else tiles
        // to the full output width.
        if (view.custom_width == null and !xdg_toplevel.current.maximized) {
            _ = xdg_toplevel.setMaximized(true);
        }
        _ = xdg_toplevel.setActivated(context.focused_view == view);
    }
}
