const std = @import("std");
const wlroots = @import("wlroots");

const ServerContext = @import("../server.zig");
const View = @import("view.zig");
const border_mod = @import("border.zig");
const AnimationManager = @import("animation.zig");

pub fn removeView(
    context: *ServerContext,
    view: *View,
) void {
    const i = std.mem.indexOfScalar(*View, context.views.items, view) orelse {
        std.log.warn(
            "Tried to remove View that was not in context.views",
            .{},
        );
        return;
    };
    // animation_x is appended in lockstep with views, but guard the
    // remove anyway: if its append failed (OOM) the lists diverge and
    // indexing it by the views index would read out of bounds.
    if (i < context.animation_x.items.len) {
        _ = context.animation_x.orderedRemove(i);
    }
    if (i < context.animation_w.items.len) {
        _ = context.animation_w.orderedRemove(i);
    }
    _ = context.views.orderedRemove(i);
}

/// Move `view` to the column slot whose x-range covers `x` (logical px).
/// Shared by mouse (Mod+drag) and touch (finger drag).
pub fn moveViewToSlot(
    context: *ServerContext,
    view: *View,
    x: f64,
) void {
    var slot_x: i32 = context.usable_area.x + context.gaps_out;
    var target_index: ?usize = null;

    for (context.views.items, 0..) |candidate, i| {
        // Keep slot geometry in lockstep with updateViewPositions.
        if (!candidate.isMapped() or candidate.floating) continue;
        const width = getViewWidth(candidate);
        if (x >= slot_x and x < slot_x + width) {
            target_index = i;
            break;
        }
        slot_x += width + context.gaps_in;
    }

    const target = target_index orelse return;

    var current_index: ?usize = null;
    for (context.views.items, 0..) |candidate, i| {
        if (candidate == view) {
            current_index = i;
            break;
        }
    }

    const current = current_index orelse return;
    if (current == target) return;

    const arr = &context.views;
    if (target > current) {
        for (current..target) |i| {
            std.mem.swap(*View, &arr.items[i], &arr.items[i + 1]);
        }
    } else {
        var i = current;
        while (i > target) : (i -= 1) {
            std.mem.swap(*View, &arr.items[i], &arr.items[i - 1]);
        }
    }

    updateViewPositions(context);
}

pub fn applyFullscreen(context: *ServerContext, view: *View) void {
    if (view.fullscreen) {
        // Reparent above all layers (bars, launchers) so the
        // fullscreen view covers everything.
        if (context.fullscreen_tree) |ft| {
            view.scene_tree.node.reparent(ft);
        }
        view.scene_tree.node.setPosition(0, 0);
        view.scene_tree.node.raiseToTop();
        if (view.border) |*b| b.rect.node.setEnabled(false);
        // Clear rounded corners — scenefx clips them otherwise.
        border_mod.clearAllBufferCorners(view);
        // Clear any clips from the tiled layout so the surface fills
        // the entire output.
        if (view.surface_tree) |st| {
            st.node.subsurfaceTreeSetClip(null);
            st.node.setPosition(0, 0);
        } else {
            // XDG: find the surface tree child and clear its clip.
            var cit = view.scene_tree.children.iterator(.forward);
            while (cit.next()) |node| {
                if (node.type == .tree) {
                    wlroots.SceneTree.fromNode(node).node.subsurfaceTreeSetClip(null);
                    break;
                }
            }
        }
        const output = context.output.?;
        var ow: c_int = 0;
        var oh: c_int = 0;
        output.effectiveResolution(&ow, &oh);
        view.setSize(@intCast(ow), @intCast(oh));
        view.setActivated(true);
        switch (view.backend) {
            .xdg => |t| _ = t.setFullscreen(true),
            .xwayland => |x| x.setFullscreen(true),
        }
    } else {
        if (view.border) |*b| b.rect.node.setEnabled(true);
        switch (view.backend) {
            .xdg => |t| _ = t.setFullscreen(false),
            .xwayland => |x| x.setFullscreen(false),
        }
        // Reparent back into the views tree.
        if (context.views_tree) |vt| {
            view.scene_tree.node.reparent(vt);
        }
        // Floating views re-center; tiled views rejoin the layout.
        if (view.floating) {
            const vw: f32 = @floatFromInt(@max(1, context.usable_area.width));
            const vh: f32 = @floatFromInt(@max(1, context.usable_area.height));
            view.x = context.usable_area.x + @as(i32, @intFromFloat((vw - @as(f32, @floatFromInt(view.slot_w))) / 2));
            view.y = context.usable_area.y + @as(i32, @intFromFloat((vh - @as(f32, @floatFromInt(view.slot_h))) / 2));
            view.scene_tree.node.setPosition(view.x, view.y);
            view.scene_tree.node.raiseToTop();
            const idx = std.mem.indexOfScalar(*View, context.views.items, view) orelse 0;
            updateViewPositionsFrom(context, idx);
        } else {
            const idx = std.mem.indexOfScalar(*View, context.views.items, view) orelse 0;
            updateViewPositionsFrom(context, idx);
            scrollToViewNoLayout(context, view);
        }
    }
}

pub fn getViewWidth(view: *View) i32 {
    if (view.custom_width) |w| return w;
    // XWayland surfaces can be dissociated (surface nulled) before the
    // view is removed from the tiling list; don't crash re-laying out.
    return if (view.surfaceOrNull()) |s| s.current.width - 100 else 0;
}

pub fn updateViewPositions(context: *ServerContext) void {
    updateViewPositionsFrom(context, 0);
}

/// Force every tiled (mapped, non-floating, non-fullscreen) view to resize
/// to the current usable area. Runs on any usable-area change (the OSK
/// appearing or hiding) so ALL windows — focused or not — re-tile, instead of
/// only the window that happens to redraw on its own.
///
/// setSize alone isn't enough: a view that is scrolled off-screen is never
/// rendered, so it receives no frame callback and its client never applies the
/// pending configure. Send each surface an explicit frame-done so idle clients
/// repaint at the new size too.
pub fn refreshTiledSizes(context: *ServerContext) void {
    const bw: i32 = @intCast(context.border_width);
    const eh = context.usable_area.height - @as(c_int, @intCast(context.gaps_out * 2));
    const content_h = @max(1, eh - 2 * bw);

    var now: std.c.timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &now);

    for (context.views.items) |view| {
        if (!view.isMapped() or view.floating or view.fullscreen) continue;
        view.slot_h = eh;
        view.setSize(@max(1, view.slot_w - 2 * bw), content_h);
        if (view.surfaceOrNull()) |surf| {
            surf.sendFrameDone(&now);
        }
    }
    updateViewPositions(context);
}

extern fn clock_gettime(clk_id: c_int, tp: *anyopaque) c_int;
const CLOCK_MONOTONIC: c_int = 1;

/// Recompute tile positions and borders starting from `start_idx`.
/// Views before `start_idx` are only walked for the x-prefix sum —
/// their borders are NOT touched, saving the dominant per-call cost
/// (scene-graph mutations) for views that didn't move.
pub fn updateViewPositionsFrom(context: *ServerContext, start_idx: usize) void {
    var x: i32 = context.usable_area.x + context.gaps_out;

    // Fast-forward x past the unchanged prefix.
    for (context.views.items[0..start_idx]) |view| {
        if (!view.isMapped() or view.floating or view.fullscreen) continue;
        x += getViewWidth(view) + context.gaps_in;
    }

    for (context.views.items[start_idx..]) |view| {
        if (!view.isMapped() or view.floating or view.fullscreen) continue;

        const width = getViewWidth(view);

        view.x = x;
        view.y = context.usable_area.y + context.gaps_out;

        border_mod.updateViewBorder(view, @floatFromInt(view.x), null);

        x += width + context.gaps_in;
    }
    context.animation_active = true;
    AnimationManager.wake(context);
    context.layout_seq +|= 1;
}


/// Place windows at their targets immediately, skipping the position
/// lerp. Used while interactively resizing so the layout tracks the
/// cursor instead of rubber-banding behind it.
pub fn layoutViews(context: *ServerContext) void {
    var x: i32 = context.usable_area.x + context.gaps_out;

    for (context.views.items, 0..) |view, i| {
        if (!view.isMapped() or view.floating or view.fullscreen) continue;

        const width = getViewWidth(view);

        view.x = x;
        view.y = context.usable_area.y + context.gaps_out;

        view.scene_tree.node.setPosition(
            view.x - context.viewport_x,
            view.y - context.viewport_y,
        );
        context.animation_x.items[i] = @floatFromInt(view.x);
        border_mod.updateViewBorder(view, @floatFromInt(view.x), null);

        x += width + context.gaps_in;
    }
    context.layout_seq +|= 1;
}

/// Scroll only when `view` is not fully on screen (click/touch focus):
/// centering on every click would yank the viewport around for no gain.
pub fn scrollIntoView(
    context: *ServerContext,
    view: *View,
) void {
    if (view.floating or view.fullscreen) return;
    const output = context.output orelse return;

    var out_w: c_int = 0;
    var out_h: c_int = 0;
    output.effectiveResolution(&out_w, &out_h);

    const left = context.viewport_x;
    const right = left + out_w;
    const view_right = view.x + getViewWidth(view);

    if (view.x >= left and view_right <= right) return;

    scrollToView(context, view);
}

pub fn scrollToView(
    context: *ServerContext,
    view: *View,
) void {
    // Recompute layout first so view.x reflects the current set of
    // mapped windows (e.g. after a sibling was unmapped).
    updateViewPositions(context);
    scrollToViewNoLayout(context, view);
}

/// Set the viewport target to center `view` without recomputing
/// layout.  Call after updateViewPositions when you already know
/// view.x is current.
pub fn scrollToViewNoLayout(
    context: *ServerContext,
    view: *View,
) void {
    const output = context.output orelse return;

    var out_w: c_int = 0;
    var out_h: c_int = 0;
    output.effectiveResolution(&out_w, &out_h);

    const view_width = getViewWidth(view);
    const target = view.x + @divTrunc(view_width, 2) - @divTrunc(out_w, 2);

    context.viewport_target = @max(0, target);
}
