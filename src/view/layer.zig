const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const ServerContext = @import("../server.zig");
const NodeData = @import("utils/node_data.zig").NodeData;
const FocusManager = @import("focus.zig");
const ViewManager = @import("view_manager.zig");
const Border = @import("border.zig");

const LayerView = @This();

scene_layer: *wlroots.SceneLayerSurfaceV1,
layer_surface: *wlroots.LayerSurfaceV1,
context: *ServerContext,
node_data: NodeData = undefined,

destroy_listener: wl.Listener(*wlroots.LayerSurfaceV1) = undefined,
commit_listener: wl.Listener(*wlroots.Surface) = undefined,

/// Sum the exclusive zones of all live layer surfaces and store the
/// resulting usable tiling area on the context. Call after any layer
/// surface commits (size/exclusive-zone change) or is destroyed.
fn recomputeUsableArea(context: *ServerContext) void {
    const output = context.output orelse return;
    const scale: i32 = @intFromFloat(@max(output.scale, 1.0));
    const full = wlroots.Box{
        .x = 0,
        .y = 0,
        .width = @divTrunc(output.width, scale),
        .height = @divTrunc(output.height, scale),
    };

    var usable = full;
    for (context.layers.items) |layer| {
        const ls = layer.layer_surface;
        if (!ls.initialized) continue;
        const st = ls.current;
        if (st.exclusive_zone < 0) continue;

        const ez = st.exclusive_zone;
        const top = st.anchor.top;
        const bottom = st.anchor.bottom;
        const left = st.anchor.left;
        const right = st.anchor.right;

        // Top bar: reserve from the top (unless it spans the full width,
        // in which case it also reserves nothing from the sides).
        if (top and !bottom) {
            usable.y += ez + st.margin.top;
            usable.height -= ez + st.margin.top;
        }
        if (bottom and !top) {
            usable.height -= ez + st.margin.bottom;
        }
        if (left and !right) {
            usable.x += ez + st.margin.left;
            usable.width -= ez + st.margin.left;
        }
        if (right and !left) {
            usable.width -= ez + st.margin.right;
        }
    }

    if (usable.width < 0) usable.width = 0;
    if (usable.height < 0) usable.height = 0;

    context.usable_area = usable;
}

/// Recompute the usable area and report whether it changed. Callers decide
/// what to re-derive: when the area changed (e.g. the OSK appeared/shrunk it,
/// or hid/expanded it) every tiled view's size and position must be
/// re-derived, because idle/unfocused windows otherwise keep a stale slot
/// until their own surface commits.
fn recomputeUsableAreaChanged(context: *ServerContext) bool {
    const prev = context.usable_area;
    recomputeUsableArea(context);
    const changed = prev.x != context.usable_area.x or
        prev.y != context.usable_area.y or
        prev.width != context.usable_area.width or
        prev.height != context.usable_area.height;
    return changed;
}

pub fn onLayerSurfaceDestroy(
    listener: *wl.Listener(*wlroots.LayerSurfaceV1),
    layer_surface: *wlroots.LayerSurfaceV1,
) void {
    _ = layer_surface;

    const layer: *LayerView =
        @fieldParentPtr("destroy_listener", listener);

    const context = layer.context;

    layer.commit_listener.link.remove();
    layer.destroy_listener.link.remove();

    for (context.layers.items, 0..) |candidate, i| {
        if (candidate == layer) {
            _ = context.layers.orderedRemove(i);
            break;
        }
    }
    if (recomputeUsableAreaChanged(context)) {
        ViewManager.refreshTiledSizes(context);
        ViewManager.updateViewPositions(context);
    }

    // The wallpaper is gone: corner masks fall back to the plain arc.
    if (layer.layer_surface.current.layer == .background or
        layer.layer_surface.current.layer == .bottom)
    {
        if (context.wallpaper) |old| {
            wlroots.Buffer.unlock(old.buffer);
            context.wallpaper = null;
        }
        Border.updateBorders(context);
    }

    if (context.focused_layer == layer) {
        if (context.previous_focused_view) |view| {
            context.previous_focused_view = null;

            if (view.surface().mapped) {
                FocusManager.setFocus(context, .{
                    .view = .{
                        .view = view,
                        .surface = view.surface(),
                        .sx = context.cursor.x - view.x,
                        .sy = context.cursor.y - view.y,
                    },
                });
            } else {
                FocusManager.setFocus(context, .none);
            }
        } else {
            FocusManager.setFocus(context, .none);
        }
    }

    // Kick a repaint so the removed layer region (e.g. the on-screen
    // keyboard) doesn't leave stale pixels in the framebuffer.
    if (context.output) |out| out.scheduleFrame();

    std.heap.c_allocator.destroy(layer);
}
pub fn onLayerSurfaceCommit(
    listener: *wl.Listener(*wlroots.Surface),
    surface: *wlroots.Surface,
) void {
    const layer: *LayerView =
        @fieldParentPtr("commit_listener", listener);

    const layer_surface = layer.layer_surface;

    if (!layer_surface.initialized) {
        return;
    }

    const output = layer_surface.output orelse {
        std.log.err(
            "Layer surface committed without an output",
            .{},
        );
        return;
    };

    // The scene graph works in the output's logical (pre-scale) coordinate
    // space, so feed it logical dimensions rather than the physical mode
    // size. Otherwise scaled outputs place layers at the wrong size/offset.
    const scale: i32 = @intFromFloat(@max(output.scale, 1.0));

    const full_area = wlroots.Box{
        .x = 0,
        .y = 0,
        .width = @divTrunc(output.width, scale),
        .height = @divTrunc(output.height, scale),
    };

    // Every commit — initial included — goes through the scene arranger:
    // it derives the box from anchors, margins and the client's desired
    // size, and only sends a configure when the size actually changes.
    // A real size, not 0x0: a wallpaper/background client sizes its
    // viewport destination from the configured size, and wlroots'
    // viewporter rejects a 0-sized destination.
    var usable_area = full_area;

    layer.scene_layer.configure(
        &full_area,
        &usable_area,
    );

    const context = layer.context;
    // Client-agnostic: focus any layer that asks for keyboard interactivity.
    if (layer_surface.current.keyboard_interactive != .none) {
        FocusManager.setFocus(layer.context, .{
            .layer = .{
                .layer = layer,
                .sx = context.cursor.x,
                .sy = context.cursor.y,
            },
        });
    }

    if (layer_surface.initial_commit) {
        std.log.info(
            "Initial layer commit; arranged {s}",
            .{std.mem.span(layer_surface.namespace)},
        );

        if (recomputeUsableAreaChanged(layer.context)) {
            ViewManager.refreshTiledSizes(layer.context);
        }
        ViewManager.updateViewPositions(layer.context);

        return;
    }

    if (layer_surface.current.keyboard_interactive != .none) {
        FocusManager.setFocus(layer.context, .{
            .layer = .{
                .layer = layer,
                .sx = context.cursor.x,
                .sy = context.cursor.y,
            },
        });
    }

    // Re-derive the usable area even on an empty (null-buffer) commit: a
    // layer can change its exclusive zone / anchors without attaching a
    // buffer (the OSK hides by clearing its zone), which must re-expand the
    // usable area and retile windows. updateViewPositions runs below on the
    // buffered path, and here whenever the area changed.
    const area_changed = recomputeUsableAreaChanged(layer.context);
    if (area_changed) {
        ViewManager.refreshTiledSizes(layer.context);
    }

    if (surface.current.buffer == null) {
        if (area_changed) {
            ViewManager.updateViewPositions(layer.context);
        }
        return;
    }

    // The background/bottom layer is the wallpaper: capture its buffer
    // and position so the corner masks can show it behind rounded
    // corners. The buffer is locked: daemons may release it after the
    // next commit (animations, reloads), and an unlocked pointer would
    // be a use-after-free on the next corner refresh.
    if (layer_surface.current.layer == .background or
        layer_surface.current.layer == .bottom)
    {
        // Only replace the wallpaper when this commit actually carries a
        // buffer: background clients also commit empty frames, and nulling
        // the capture on those loses the wallpaper.
        if (surface.current.buffer) |buffer| {
            if (context.wallpaper) |old| {
                wlroots.Buffer.unlock(old.buffer);
                context.wallpaper = null;
            }
            context.wallpaper = .{
                .buffer = buffer.lock(),
                .x = layer.scene_layer.tree.node.x,
                .y = layer.scene_layer.tree.node.y,
                .scale = @floatFromInt(@max(surface.current.scale, 1)),
                .width = buffer.width,
                .height = buffer.height,
            };
            Border.updateBorders(context);
        }
    }

    ViewManager.updateViewPositions(layer.context);
}
pub fn onNewLayerSurface(
    listener: *wl.Listener(*wlroots.LayerSurfaceV1),
    layer_surface: *wlroots.LayerSurfaceV1,
) void {
    const context: *ServerContext =
        @fieldParentPtr("new_layer_surface_listener", listener);

    std.log.info("NEW LAYER SURFACE: {s}", .{
        std.mem.span(layer_surface.namespace),
    });

    // Fuzzel doesn't necessarily specify an output.
    if (layer_surface.output == null) {
        layer_surface.output = context.output orelse {
            std.log.err("No output available for layer surface", .{});
            layer_surface.destroy();
            return;
        };
    }

    const output = layer_surface.output.?;

    std.log.info("Layer assigned to output: {s}", .{
        std.mem.span(output.name),
    });

    const layer_tree = switch (layer_surface.current.layer) {
        .background => context.background_tree,
        .bottom => context.bottom_tree,
        .top => context.top_tree,
        .overlay => context.overlay_tree,
        else => context.bottom_tree,
    } orelse {
        std.log.err("Layer tree not created", .{});
        layer_surface.destroy();
        return;
    };

    const scene_layer =
        layer_tree.createSceneLayerSurfaceV1(layer_surface) catch |err| {
            std.log.err(
                "createSceneLayerSurfaceV1 failed: {}",
                .{err},
            );
            layer_surface.destroy();
            return;
        };

    const layer = std.heap.c_allocator.create(LayerView) catch |err| {
        std.log.err(
            "Failed to allocate LayerView: {}",
            .{err},
        );
        scene_layer.tree.node.destroy();
        layer_surface.destroy();
        return;
    };

    layer.* = .{
        .scene_layer = scene_layer,
        .layer_surface = layer_surface,
        .context = context,
    };
    layer.node_data = .{ .layer = layer };
    layer.scene_layer.tree.node.data = &layer.node_data;

    layer_surface.data = layer;
    context.layers.append(std.heap.c_allocator, layer) catch {
        std.log.err("Failed to track layer surface", .{});
        layer.destroy_listener.link.remove();
        std.heap.c_allocator.destroy(layer);
        return;
    };

    layer.destroy_listener =
        wl.Listener(*wlroots.LayerSurfaceV1).init(onLayerSurfaceDestroy);

    layer_surface.events.destroy.add(
        &layer.destroy_listener,
    );
    layer.commit_listener =
        wl.Listener(*wlroots.Surface).init(onLayerSurfaceCommit);

    layer_surface.surface.events.commit.add(
        &layer.commit_listener,
    );
}
