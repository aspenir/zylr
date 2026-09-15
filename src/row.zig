const std = @import("std");

const ServerContext = @import("server.zig");
const View = @import("view/view.zig");
const ViewManager = @import("view/view_manager.zig");
const Mirror = @import("mirror.zig");
const AnimationManager = @import("view/animation.zig");

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

    // A switch while a transition is still in flight: settle it first (its
    // outgoing row is still rendered) before sliding a new pair.
    settleTransition(context);

    const from_row = context.active_row;

    // Destroy the outgoing row's mirror trees (they'll be rebuilt on
    // reactivation). Its windows stay visible to slide out.
    Mirror.deactivateMirrors(context, from_row);

    // Stash the current working set into the outgoing row.
    std.debug.assert(context.rows[from_row] == null);
    context.rows[from_row] = .{
        .views = context.views,
        .animation_x = context.animation_x,
        .animation_w = context.animation_w,
        .animation_y = context.animation_y,
        .from_x = context.from_x,
        .from_w = context.from_w,
        .from_y = context.from_y,
        .vel_x = context.vel_x,
        .vel_w = context.vel_w,
        .vel_y = context.vel_y,
        .scroll_x = context.viewport_x,
        .target_x = context.viewport_target,
        .vp_vel = context.viewport_vel,
    };

    context.active_row = new_row;

    // Load the incoming row's set (or an empty row if never used).
    if (context.rows[new_row]) |loaded| {
        context.rows[new_row] = null;
        context.views = loaded.views;
        context.animation_x = loaded.animation_x;
        context.animation_w = loaded.animation_w;
        context.animation_y = loaded.animation_y;
        context.from_x = loaded.from_x;
        context.from_w = loaded.from_w;
        context.from_y = loaded.from_y;
        context.vel_x = loaded.vel_x;
        context.vel_w = loaded.vel_w;
        context.vel_y = loaded.vel_y;
        context.viewport_x = loaded.scroll_x;
        context.viewport_target = loaded.target_x;
        context.viewport_vel = loaded.vp_vel;
    } else {
        context.views = .empty;
        context.animation_x = .empty;
        context.animation_w = .empty;
        context.animation_y = .empty;
        context.from_x = .empty;
        context.from_w = .empty;
        context.from_y = .empty;
        context.vel_x = .empty;
        context.vel_w = .empty;
        context.vel_y = .empty;
        context.viewport_x = 0;
        context.viewport_target = 0;
        context.viewport_vel = 0;
    }

    setRowVisible(context, new_row, true);
    // Re-tile the incoming row so any geometry propagated to its peers
    // while it lay inactive (width/floating) takes effect on activation.
    if (context.views.items.len > 0) ViewManager.layoutViews(context);
    // Rebuild and position mirrors for the newly active row.
    Mirror.activateMirrors(context, new_row);
    context.animation_active = true;
    AnimationManager.wake(context);

    // Start the slide/fade. Frame 0: the incoming row is fully transparent
    // (content would flash at rest position before the slide begins) and its
    // borders dropped (a scene rect can't fade); the tick slides both rows
    // and fades the border in with the window.
    for (context.views.items) |view| {
        if (view.border) |*b| b.rect.node.setEnabled(false);
        AnimationManager.setTreeOpacity(&view.scene_tree.node, 0);
    }
    for (context.row_mirrors[context.active_row].items) |*m| {
        AnimationManager.setTreeOpacity(&m.tree.node, 0);
    }
    const slide: f32 = @floatFromInt(@max(1, context.usable_area.height));
    context.row_anim = .{
        .from_row = from_row,
        .dir = if (new_row > from_row) @as(i32, 1) else -1,
        .slide = slide,
        .started = context.nowMs(),
    };
}

/// End the current transition (completion, or pre-empted by the next
/// switch): un-render the outgoing row for good, restore full opacity, and
/// forget the state. Idempotent when no transition is in flight.
pub fn settleTransition(context: *ServerContext) void {
    const t = context.row_anim orelse return;
    resetRowOpacity(context, t.from_row);
    setRowVisible(context, t.from_row, false);
    resetRowOpacity(context, context.active_row);
    context.row_anim = null;
}

/// Restore full opacity on every window and mirror tree of `row` (only the
/// trees a transition may have faded).
fn resetRowOpacity(context: *ServerContext, row: usize) void {
    for (viewsOf(context, row)) |view| AnimationManager.setTreeOpacity(&view.scene_tree.node, 1.0);
    for (context.row_mirrors[row].items) |*m| AnimationManager.setTreeOpacity(&m.tree.node, 1.0);
}

/// The window list for `row` (working set if active, parked if not).
fn viewsOf(context: *ServerContext, row: usize) []const *View {
    if (row == context.active_row) return context.views.items;
    if (context.rows[row]) |parked| return parked.views.items;
    return &.{};
}

/// Enable or disable the scene trees (and borders) of every window in
/// `row`, so parked rows don't render stacked on top of the active one.
/// Mapped surface state is untouched: windows stay "mapped" to their
/// clients but are hidden from the output until their row is active.
fn setRowVisible(context: *ServerContext, row: usize, visible: bool) void {
    for (viewsOf(context, row)) |view| {
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
