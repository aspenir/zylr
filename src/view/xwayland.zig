const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");
const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

const ServerContext = @import("../server.zig");
const Border = @import("border.zig");
const Blur = @import("blur.zig");
const ViewManager = @import("view_manager.zig");
const View = @import("view.zig");

/// Append a line to /tmp/zylr_xw.log (the diagnostic that survives the
/// desktop-file launch) so window-creation events can be correlated
/// with user tests.
fn logToFile(msg: []const u8) void {
    const f = std.c.fopen("/tmp/zylr_xw.log", "a") orelse return;
    _ = std.c.fwrite(msg.ptr, 1, msg.len, f);
    _ = std.c.fclose(f);
}

pub fn onNewXwaylandSurface(
    listener: *wl.Listener(*wlroots.XwaylandSurface),
    xw_surface: *wlroots.XwaylandSurface,
) void {
    const context: *ServerContext =
        @fieldParentPtr("new_xwayland_surface_listener", listener);

    std.log.info("NEW XWAYLAND SURFACE", .{});
    {
        const line = std.fmt.allocPrint(
            std.heap.c_allocator,
            "NEW XWAYLAND SURFACE (client chose X11) pid={d} class={s} title={s}\n",
            .{ xw_surface.pid, xw_surface.class orelse "?", xw_surface.title orelse "?" },
        ) catch return;
        defer std.heap.c_allocator.free(line);
        logToFile(line);
    }

    const view = std.heap.c_allocator.create(View) catch |err| {
        std.log.err("failed to allocate View: {}", .{err});
        return;
    };

    view.* = .{
        .backend = .{ .xwayland = xw_surface },
        .scene_tree = context.views_tree.?.createSceneTree() catch |err| {
            std.log.err("createSceneTree failed: {}", .{err});
            std.heap.c_allocator.destroy(view);
            return;
        },
        .seat = context.seat,
        .context = context,
    };
    view.node_data = .{ .view = view };

    // Hidden until the client's first map (onSurfaceMap enables the
    // tree): an eagerly-created view would otherwise render its border
    // rect as a phantom window at the origin.
    view.scene_tree.node.setEnabled(false);

    Border.createViewBorder(view);
    Blur.createForView(view, view.scene_tree);

    // The inner wlr_surface only exists after the X client commits
    // (associate event). The scene surface lives in our wrapper tree
    // so tiling code can position/enable it like a native view.
    view.commit_listener =
        wl.Listener(*wlroots.Surface).init(View.onViewCommit);
    view.associate_listener =
        wl.Listener(void).init(onAssociate);
    view.map_request_listener =
        wl.Listener(void).init(onMapRequest);
    view.set_decorations_listener =
        wl.Listener(void).init(onSetDecorations);
    view.destroy_listener =
        wl.Listener(void).init(View.onSurfaceDestroy);

    xw_surface.events.associate.add(&view.associate_listener);
    xw_surface.events.map_request.add(&view.map_request_listener);
    xw_surface.events.set_decorations.add(&view.set_decorations_listener);
    xw_surface.events.destroy.add(&view.destroy_listener);

    // Foreign-toplevel handle (portal window pickers, bars).
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

    xw_surface.data = view;
}

/// wlr_surface became available: attach it to the scene tree, wire
/// commit/map/unmap, and only then make the view part of the column.
fn onAssociate(listener: *wl.Listener(void)) void {
    const view: *View =
        @fieldParentPtr("associate_listener", listener);

    const xw_surface = view.backend.xwayland;
    const surface = xw_surface.surface orelse return;

    // The content lives in its own subtree so commitSurface can inset
    // it to (bw,bw) inside the border slot AND crop it to the content
    // box - a client that ignores or lags its configure then cannot
    // spill over the ring band or the neighbouring slot. This must be
    // a subsurface tree, not plain tree + scene surface: only it has
    // the addon wlr_scene_subsurface_tree_set_clip asserts on, and it
    // tracks XWayland subsurfaces into the scene.
    const wrap = view.scene_tree.createSceneSubsurfaceTree(surface) catch |err| {
        std.log.err("createSceneSubsurfaceTree failed: {}", .{err});
        return;
    };

    view.surface_tree = wrap;
    var buf_it = wrap.children.iterator(.forward);
    while (buf_it.next()) |child| {
        if (child.type == .buffer) {
            view.scene_buffer_node = child;
            break;
        }
    }

    view.scene_tree.node.data = &view.node_data;

    view.map_listener = wl.Listener(void).init(View.onSurfaceMap);
    view.unmap_listener = wl.Listener(void).init(View.onSurfaceUnmap);
    surface.events.map.add(&view.map_listener);
    surface.events.unmap.add(&view.unmap_listener);
    surface.events.commit.add(&view.commit_listener);
    view.inner_destroy_listener =
        wl.Listener(*wlroots.Surface).init(View.onInnerSurfaceDestroy);
    surface.events.destroy.add(&view.inner_destroy_listener);
    view.associated = true;

    view.request_fullscreen_listener = wl.Listener(void).init(View.onRequestFullscreen);
    xw_surface.events.request_fullscreen.add(&view.request_fullscreen_listener);
    view.request_fullscreen_active = true;

    view.context.views.append(
        std.heap.c_allocator,
        view,
    ) catch |err| {
        std.log.err("Failed to add view: {}", .{err});
        return;
    };
    view.context.animation_x.append(
        std.heap.c_allocator,
        @floatFromInt(view.x),
    ) catch |err| {
        std.log.err("Failed to add animation_x: {}", .{err});
        _ = view.context.views.orderedRemove(view.context.views.items.len - 1);
        return;
    };
    view.context.animation_w.append(
        std.heap.c_allocator,
        @floatFromInt(ViewManager.getViewWidth(view)),
    ) catch |err| {
        std.log.err("Failed to add animation_w: {}", .{err});
        _ = view.context.animation_x.orderedRemove(view.context.animation_x.items.len - 1);
        _ = view.context.views.orderedRemove(view.context.views.items.len - 1);
        return;
    };
}

/// Client wants to map: honor it (XWayland surfaces stay withdrawn
/// until the compositor allows the map).
/// The client changed its _MOTIF_WM_HINTS decorations. Firefox maps
/// and commits BEFORE setting them (no_border arrives after the first
/// frame), so zylr draws its SSD ring around a CSD window — Firefox's
/// shadow margins render on top of the ring. Re-run the commit logic so
/// the ring is dropped and the client is reconfigured to the full slot.
fn onSetDecorations(listener: *wl.Listener(void)) void {
    const view: *View =
        @fieldParentPtr("set_decorations_listener", listener);
    const xw_surface = view.backend.xwayland;
    if (view.surfaceOrNull()) |surface| {
        commitSurface(view, xw_surface, surface);
        Border.updateViewBorder(view, @floatFromInt(view.x), null);
    }
}

fn onMapRequest(listener: *wl.Listener(void)) void {
    const view: *View =
        @fieldParentPtr("map_request_listener", listener);
    std.log.info("MAP REQUEST", .{});
    view.backend.xwayland.setWithdrawn(false);
}

pub fn commitSurface(
    view: *View,
    xw_surface: *wlroots.XwaylandSurface,
    surface: *wlroots.Surface,
) void {
    const context = view.context;
    const output = context.output orelse {
        std.log.err("No output for xwayland configure", .{});
        return;
    };

    var ew: c_int = 0;
    var eh: c_int = 0;
    output.effectiveResolution(&ew, &eh);

    ew -= @as(c_int, @intCast(context.gaps_out * 2));
    eh -= @as(c_int, @intCast(context.gaps_out * 2));

    if (context.usable_area.width > 0) {
        const left = context.usable_area.x;
        const right = ew - (context.usable_area.x + context.usable_area.width);
        ew -= left + right;
        eh = context.usable_area.height - @as(c_int, @intCast(context.gaps_out * 2));
    }

    if (view.custom_width) |w| {
        ew = w;
    } else {
        view.custom_width = @as(i32, @intFromFloat(
            @as(f32, @floatFromInt(ew)) * context.view_width_ratio,
        ));
        ew = view.custom_width.?;
    }

    // Floating views keep their own geometry.
    if (view.floating or view.fullscreen) {
        if (view.floating) {
            const bw: c_int = @intCast(context.border_width);
            view.slot_w = @max(1, surface.current.width + 2 * bw);
            view.slot_h = @max(1, surface.current.height + 2 * bw);
            if (view.surface_tree) |wrap| {
                wrap.node.setPosition(bw, bw);
            }
        }
        return;
    }

    // The slot the border ring must fill exactly (see border.zig).
    view.slot_w = ew;
    view.slot_h = eh;

    // Mango-exact geometry for EVERY client, CSD or not: configure the
    // content box to slot-2bw at slot+(bw,bw), and inset + crop the
    // content subtree to that box so shadow margins or a stale buffer
    // can never cover the ring band.
    const bw: c_int = @intCast(context.border_width);
    const target_w: c_int = @max(1, ew - 2 * bw);
    const target_h: c_int = @max(1, eh - 2 * bw);

    if (view.surface_tree) |wrap| {
        wrap.node.setPosition(bw, bw);
        const crop: wlroots.Box = .{
            .x = 0,
            .y = 0,
            .width = target_w,
            .height = target_h,
        };
        wrap.node.subsurfaceTreeSetClip(&crop);
    }

    const wrong_size = surface.current.width != target_w or
        surface.current.height != target_h;

    if (wrong_size) {
        _ = xw_surface.configure(
            @intCast(view.x + bw),
            @intCast(view.y + bw),
            @intCast(target_w),
            @intCast(target_h),
        );
        xw_surface.activate(context.focused_view == view);
    }

}
