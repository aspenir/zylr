const std = @import("std");

const ServerContext = @import("server.zig");
const View = @import("view/view.zig");
const ViewManager = @import("view/view_manager.zig");
const Mirror = @import("mirror.zig");

/// Switch the active row to `new`. Ownership model:
///   - The ACTIVE row lives in the shared working set (context.views,
///     context.animation_x/w, context.viewport_x/target) and its slot in
///     `context.rows[]` is null.
///   - Every INACTIVE row parks its windows, animation arrays, and scroll
///     offset in `context.rows[i]`.
/// Switching stashes the current working set into the outgoing row and
/// loads the incoming row's set into the working slots, so all the
/// render/layout/animation/focus code operates on the active row with no
/// changes of its own.
pub fn switchTo(context: *ServerContext, new_row: usize) void {
    if (new_row == context.active_row) return;
    std.debug.assert(new_row < ServerContext.max_rows);

    // Destroy outgoing row's mirror trees (they'll be rebuilt on reactivation).
    Mirror.deactivateMirrors(context, context.active_row);
    // Hide the outgoing row's windows before they get parked.
    setRowVisible(context, context.active_row, false);

    // Stash the current working set into the outgoing row.
    std.debug.assert(context.rows[context.active_row] == null);
    context.rows[context.active_row] = .{
        .views = context.views,
        .animation_x = context.animation_x,
        .animation_w = context.animation_w,
        .scroll_x = context.viewport_x,
        .target_x = context.viewport_target,
    };

    context.active_row = new_row;

    // Load the incoming row's set (or an empty row if never used).
    if (context.rows[new_row]) |loaded| {
        context.rows[new_row] = null;
        context.views = loaded.views;
        context.animation_x = loaded.animation_x;
        context.animation_w = loaded.animation_w;
        context.viewport_x = loaded.scroll_x;
        context.viewport_target = loaded.target_x;
    } else {
        context.views = .empty;
        context.animation_x = .empty;
        context.animation_w = .empty;
        context.viewport_x = 0;
        context.viewport_target = 0;
    }

    setRowVisible(context, new_row, true);
    // Re-tile the incoming row so any geometry propagated to its peers
    // while it lay inactive (width/floating) takes effect on activation.
    if (context.views.items.len > 0) ViewManager.layoutViews(context);
    // Rebuild and position mirrors for the newly active row.
    Mirror.activateMirrors(context, new_row);
    context.animation_active = true;
}

/// Enable or disable the scene trees (and borders) of every window in
/// `row`, so parked rows don't render stacked on top of the active one.
/// Mapped surface state is untouched: windows stay "mapped" to their
/// clients but are hidden from the output until their row is active.
fn setRowVisible(context: *ServerContext, row: usize, visible: bool) void {
    const views = if (row == context.active_row)
        context.views.items
    else if (context.rows[row]) |parked|
        parked.views.items
    else
        &.{};
    for (views) |view| {
        // A mirrored source's real surface stays hidden even when its row is
        // shown - its representations are mirrors, not the real surface.
        if (visible and Mirror.isHiddenSource(context, view)) continue;
        view.scene_tree.node.setEnabled(visible);
        if (view.border) |*b| b.rect.node.setEnabled(visible);
    }
}

/// True when the given row holds no mapped windows.
pub fn isEmpty(context: *ServerContext, row: usize) bool {
    if (row == context.active_row) {
        return context.views.items.len == 0;
    }
    const parked = context.rows[row] orelse return true;
    return parked.views.items.len == 0;
}

/// Finder for which row (working set or parked) currently owns `view`.
/// Returns null if the view isn't in any row (shouldn't happen for a
/// mapped view). Used when a window closes while on an inactive row.
pub fn rowOf(context: *ServerContext, view: *View) ?usize {
    if (std.mem.indexOfScalar(*View, context.views.items, view) != null) {
        return context.active_row;
    }
    for (context.rows, 0..) |maybe_row, i| {
        const r = maybe_row orelse continue;
        if (std.mem.indexOfScalar(*View, r.views.items, view) != null) return i;
    }
    return null;
}
