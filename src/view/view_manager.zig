const std = @import("std");
const wlroots = @import("wlroots");

const ServerContext = @import("../server.zig");
const View = @import("view.zig");
const Border = @import("border.zig");
const Rounding = @import("rounding.zig");
const AnimationManager = @import("animation.zig");
const Mirror = @import("../mirror.zig");

const Row = @import("../row.zig");
const PileMath = @import("pile_math.zig");

pub fn removeView(
    context: *ServerContext,
    view: *View,
) void {
    // A closing window may live on an inactive row: each workspace row
    // parks its own window list, so remove it from whichever row owns it.
    const row = Row.rowOf(context, view) orelse {
        std.log.warn("Tried to remove View not in any row", .{});
        return;
    };
    // The hsplit arm dies with its target view.
    const arr = if (row == context.active_row) blk: {
        break :blk &context.views;
    } else blk: {
        // Guaranteed non-null for an inactive row that owns a view.
        break :blk &context.rows[row].?.views;
    };
    const i = std.mem.indexOfScalar(*View, arr.items, view) orelse return;

    // animation_x/w are appended in lockstep with views, but guard the
    // remove anyway: if its append failed (OOM) the lists diverge and
    // indexing it by the views index would read out of bounds.
    const ax = if (row == context.active_row) &context.animation_x else &context.rows[row].?.animation_x;
    const aw = if (row == context.active_row) &context.animation_w else &context.rows[row].?.animation_w;
    if (i < ax.items.len) _ = ax.orderedRemove(i);
    if (i < aw.items.len) _ = aw.orderedRemove(i);
    _ = arr.orderedRemove(i);

    // A pile that just lost a member must re-split its remaining height:
    // otherwise the shares no longer sum to 1 and the column leaves a gap.
    if (view.pile_id != 0) {
        if (i > 0 and arr.items[i - 1].pile_id == view.pile_id) {
            redividePile(context, arr.items[i - 1]);
        } else if (i < arr.items.len and arr.items[i].pile_id == view.pile_id) {
            redividePile(context, arr.items[i]);
        }
    }

    // The window whose mirror collapse opened `head_gap` is gone: release the
    // gap so the next layout pass flows remaining windows from the row start
    // (the animation retargets to the gap-free flow on its next tick).
    if (context.head_gap_owner == view) {
        context.head_gap = 0;
        context.head_gap_owner = null;
    }
}

/// Move `view` to the column slot whose x-range covers `x` (logical px).
/// Shared by mouse (Mod+drag) and touch (finger drag).
pub fn moveViewToSlot(
    context: *ServerContext,
    view: *View,
    x: f64,
) void {
    var slot_x: i32 = context.usable_area.x + context.gaps_out + Mirror.leadWidth(context);
    var target_index: ?usize = null;

    for (context.views.items, 0..) |candidate, i| {
        // Keep slot geometry in lockstep with updateViewPositions.
        if (!candidate.isMapped() or candidate.floating) continue;
        const width = tiledWidth(context, candidate);
        if (x >= slot_x and x < slot_x + width) {
            target_index = i;
            break;
        }
        if (advanceSlotAfter(context, candidate, i)) {
            slot_x += width + context.gaps_in;
        }
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

    // Leaving a pile must happen before reordering: pile members have to
    // stay consecutive, and the redivide only affects the members left.
    if (view.pile_id != 0) splitViewFromPile(context, view);

    // The drop column is a pile: capture it (pointer, the index shifts when
    // we move `view` out of the list below).
    const target_view = context.views.items[target];

    // Remove-then-insert keeps views + animation arrays in lockstep. After
    // removing `current`, the insertion index that lands on the original
    // target slot shifts left by one when the target came after the removal.
    const ax = &context.animation_x;
    const aw = &context.animation_w;
    const av = context.views.orderedRemove(current);
    const axv = ax.orderedRemove(current);
    const awv = aw.orderedRemove(current);
    const ins = if (target > current) target - 1 else target;
    context.views.insert(std.heap.c_allocator, ins, av) catch return;
    ax.insert(std.heap.c_allocator, ins, axv) catch return;
    aw.insert(std.heap.c_allocator, ins, awv) catch return;

    if (target_view.pile_id != 0) {
        joinPile(context, view, target_view);
    }

    updateViewPositions(context);
}

/// While Mod+dragging a tiled window: paint the drop preview for the column
/// under (x, y) — the pile over there pre-shrinks to make room for the phantom
/// and a ghost rect marks the slot — and remember it on `context.drag_preview`
/// so commitDragPreview can realize the drop on release.
pub fn updateDragPreview(context: *ServerContext, view: *View, x: f64, y: f64) void {
    var slot_x: i32 = context.usable_area.x + context.gaps_out + Mirror.leadWidth(context);
    var target_index: ?usize = null;
    var gutter_before: ?usize = null; // list index where a gutter starts
    for (context.views.items, 0..) |candidate, i| {
        if (!candidate.isMapped() or candidate.floating) continue;
        const width = tiledWidth(context, candidate);
        if (x >= @as(f64, @floatFromInt(slot_x)) and x < @as(f64, @floatFromInt(slot_x)) + @as(f64, @floatFromInt(width))) {
            target_index = i;
            break;
        }
        // Track gap before this column for gutter-drop: cursor falls in
        // the empty space between the previous column's right edge and
        // this column's left edge.
        if (x < @as(f64, @floatFromInt(slot_x))) {
            gutter_before = i;
            break;
        }
        if (advanceSlotAfter(context, candidate, i)) {
            slot_x += width + context.gaps_in;
        }
    }

    // Cursor is past the last column — gutter drop at end.
    if (target_index == null and gutter_before == null) {
        const n = activeTiledCount(context);
        if (n <= 1) {
            endDragPreview(context);
            return;
        }
        // insert as its own standalone column at the end
        const target = context.views.items.len;
        if (context.drag_preview) |dp| {
            if (dp.view == view and dp.gutter_index == target) return;
        }
        context.drag_preview = .{ .view = view, .anchor = view, .index = target, .gutter_index = target };
        positionGutterGhost(context, view, target);
        return;
    }

    // Gutter drop: cursor is in empty space before a column.
    if (gutter_before) |gb| {
        // The target list index is where the first member of the next
        // column sits. Drop a standalone column here.
        if (context.drag_preview) |dp| {
            if (dp.view == view and dp.gutter_index == gb) return;
        }
        context.drag_preview = .{ .view = view, .anchor = view, .index = gb, .gutter_index = gb };
        positionGutterGhost(context, view, gb);
        return;
    }

    // Pile-join drop: cursor is inside an existing column.
    const target = target_index.?;
    const anchor = context.views.items[target];
    if (anchor == view or (view.pile_id != 0 and anchor.pile_id == view.pile_id)) {
        endDragPreview(context);
        return;
    }

    var index: usize = 0;
    if (anchor.pile_id == 0) {
        const top_mid = @as(f64, @floatFromInt(context.usable_area.y)) +
            @as(f64, @floatFromInt(context.usable_area.height)) / 2.0;
        index = if (y < top_mid) 0 else 1;
    } else {
        for (context.views.items) |member| {
            if (member.pile_id != anchor.pile_id) continue;
            const ps = pileSlotRaw(context, member) orelse continue;
            const mid = @as(f64, @floatFromInt(ps.top)) + @as(f64, @floatFromInt(ps.height)) / 2.0;
            if (y < mid) break;
            index += 1;
        }
    }

    if (context.drag_preview) |dp| {
        if (dp.view == view and dp.anchor == anchor and dp.index == index) return;
    }

    context.drag_preview = .{ .view = view, .anchor = anchor, .index = index };
    positionDragGhost(context, anchor);
    updateViewPositions(context);
}

/// Create/position the ghost rect painting the phantom slot of a hovered
/// column. A lone column's phantom is the empty half; a pile's is the box at
/// `index` inside the (count+1)-split. The layout pass (updateViewPositions
/// via pileSlotAt) has already pre-shrunk the real members into place; this
/// rect just outlines the hole they opened.
fn positionDragGhost(context: *ServerContext, anchor: *View) void {
    const dp = context.drag_preview orelse return;
    const ghost = context.drag_ghost orelse blk: {
        const top = context.top_tree orelse return;
        const rect = top.createSceneRect(0, 0, &[4]f32{ 1, 1, 1, 1 }) catch return;
        context.drag_ghost = rect;
        break :blk rect;
    };

    // Column x of the ghost slot == the anchor's slot x.
    var slot_x: i32 = context.usable_area.x + context.gaps_out + Mirror.leadWidth(context);
    var found = false;
    for (context.views.items, 0..) |candidate, i| {
        if (!candidate.isMapped() or candidate.floating) continue;
        const width = tiledWidth(context, candidate);
        if (candidate == anchor) {
            found = true;
            break;
        }
        if (advanceSlotAfter(context, candidate, i)) {
            slot_x += width + context.gaps_in;
        }
    }
    if (!found) return;

    const inner_h = context.usable_area.height - @as(c_int, @intCast(context.gaps_out * 2));
    const col_top = context.usable_area.y + @as(c_int, @intCast(context.gaps_out));
    const gap: i32 = @intCast(context.gaps_in);

    var top: i32 = col_top;
    var height: i32 = 1;
    if (anchor.pile_id == 0) {
        const avail_h: i32 = @max(1, inner_h - gap);
        const half: i32 = @max(1, @divFloor(avail_h, 2));
        top = col_top + gap * @as(i32, @intCast(dp.index)) + half * @as(i32, @intCast(dp.index));
        height = half;
    } else {
        var count: usize = 0;
        for (context.views.items) |member| {
            if (member.pile_id == anchor.pile_id) count += 1;
        }
        const avail_h: i32 = @max(1, inner_h - gap * @as(i32, @intCast(@max(0, @as(i32, @intCast(count + 1)) - 1))));
        const sh: i32 = @max(1, @divFloor(avail_h, @as(i32, @intCast(count + 1))));
        top = col_top + gap * @as(i32, @intCast(dp.index)) + sh * @as(i32, @intCast(dp.index));
        height = sh;
    }

    // Paint the ghost as the exact slot the window would occupy: same
    // bounds as a landed view (border ring included), tinted with the
    // focused border color and rounded like a real window.
    const w = @max(1, tiledWidth(context, anchor));
    const h = @max(1, height);
    ghost.node.setPosition(slot_x, top);
    ghost.setSize(w, h);
    const col = context.focused_border_color.sample(0.5);
    ghost.setColor(&.{ col[0], col[1], col[2], 0.35 });
    Rounding.setRectCorners(ghost, @intCast(@max(0, context.corner_radius)));
    ghost.node.setEnabled(true);
    ghost.node.raiseToTop();
}

/// Gutter-drop preview: the view re-inserts into the list as its own
/// standalone column at `target` (a list position). Ghost x = the column
/// start it will land at (widths of columns before it, skipping the dragged
/// view's own column since it vacates its slot), height = full column.
fn positionGutterGhost(context: *ServerContext, view: *View, target: usize) void {
    _ = context.drag_preview orelse return;
    const ghost = context.drag_ghost orelse blk: {
        const top = context.top_tree orelse return;
        const rect = top.createSceneRect(0, 0, &[4]f32{ 1, 1, 1, 1 }) catch return;
        context.drag_ghost = rect;
        break :blk rect;
    };

    var x: i32 = context.usable_area.x + context.gaps_out + Mirror.leadWidth(context);
    for (context.views.items, 0..) |candidate, i| {
        if (i >= target) break;
        if (candidate == view or !candidate.isMapped() or candidate.floating) continue;
        if (advanceSlotAfter(context, candidate, i)) {
            x += tiledWidth(context, candidate) + context.gaps_in;
        }
    }

    const inner_h = context.usable_area.height - @as(c_int, @intCast(context.gaps_out * 2));
    const col_top = context.usable_area.y + @as(c_int, @intCast(context.gaps_out));
    const w = tiledWidth(context, view);

    ghost.node.setPosition(x, col_top);
    ghost.setSize(@max(1, w), @max(1, inner_h));
    const col = context.focused_border_color.sample(0.5);
    ghost.setColor(&.{ col[0], col[1], col[2], 0.35 });
    Rounding.setRectCorners(ghost, @intCast(@max(0, context.corner_radius)));
    ghost.node.setEnabled(true);
    ghost.node.raiseToTop();
}

/// Drag ended over a previewed column: commit the drop — actually join `view`
/// into the hovered column at `dp.index` — then clear all preview state.
/// Reorder `view` to become its own standalone column at list position
/// `target` (a raw views index, as computed by the gutter scan). Same
/// remove-then-insert dance as moveViewToSlot; the view does NOT join a
/// pile — gutter drops always produce a lone column.
fn moveToIndex(context: *ServerContext, view: *View, target: usize) void {
    if (view.pile_id != 0) splitViewFromPile(context, view);
    const current = std.mem.indexOfScalar(*View, context.views.items, view) orelse return;
    if (current == target) return;

    const ax = &context.animation_x;
    const aw = &context.animation_w;
    const av = context.views.orderedRemove(current);
    const axv = ax.orderedRemove(current);
    const awv = aw.orderedRemove(current);
    const ins = if (target > current) target - 1 else target;
    context.views.insert(std.heap.c_allocator, ins, av) catch return;
    ax.insert(std.heap.c_allocator, ins, axv) catch return;
    aw.insert(std.heap.c_allocator, ins, awv) catch return;

    updateViewPositions(context);
}

pub fn commitDragPreview(context: *ServerContext) void {
    const dp = context.drag_preview orelse {
        endDragPreview(context);
        return;
    };
    if (dp.gutter_index) |target| {
        moveToIndex(context, dp.view, target);
        endDragPreview(context);
        scrollToView(context, dp.view);
        return;
    }
    if (dp.view.pile_id != 0) splitViewFromPile(context, dp.view);
    joinPileNear(context, dp.view, dp.anchor);
    // joinPileNear places the view right below the anchor; reposition it to
    // the ghost index so the drop lands exactly where the preview showed.
    // The pile's members are consecutive in the list, so rank = position
    // among same-pile views; bubble the view there with lockstep animation
    // swaps (mirroring joinPileNear's swap dance).
    // Bubble `view` to the ghost's rank within its pile run. The pile is
    // consecutive after joinPileNear, so the run has a real list span; the
    // swap must walk REAL indices, not ranks, or the view lands in a foreign
    // column and the pile fragments into separate tiled columns.
    if (dp.index < max_pile_members) {
        const ax = &context.animation_x;
        const aw = &context.animation_w;
        const ay = &context.animation_y;
        var vi: usize = 0;
        for (context.views.items, 0..) |member, i| {
            if (member == dp.view) {
                vi = i;
                break;
            }
        }
        var start = vi;
        while (start > 0 and context.views.items[start - 1].pile_id == dp.view.pile_id) start -= 1;
        var rank = vi - start;
        while (rank > dp.index) : (rank -= 1) {
            std.mem.swap(*View, &context.views.items[vi], &context.views.items[vi - 1]);
            std.mem.swap(f32, &ax.items[vi], &ax.items[vi - 1]);
            if (vi < aw.items.len) std.mem.swap(f32, &aw.items[vi], &aw.items[vi - 1]);
            if (vi < ay.items.len) std.mem.swap(f32, &ay.items[vi], &ay.items[vi - 1]);
            vi -= 1;
        }
        while (rank < dp.index) : (rank += 1) {
            std.mem.swap(*View, &context.views.items[vi], &context.views.items[vi + 1]);
            std.mem.swap(f32, &ax.items[vi], &ax.items[vi + 1]);
            if (vi + 1 < aw.items.len) std.mem.swap(f32, &aw.items[vi], &aw.items[vi + 1]);
            if (vi + 1 < ay.items.len) std.mem.swap(f32, &ay.items[vi], &ay.items[vi + 1]);
            vi += 1;
        }
    }
    endDragPreview(context);
    scrollToView(context, dp.view);
}

/// Clear the drag preview (ghost + phantom layout) without committing.
pub fn endDragPreview(context: *ServerContext) void {
    if (context.drag_preview == null and context.drag_ghost == null) return;
    context.drag_preview = null;
    if (context.drag_ghost) |g| g.node.setEnabled(false);
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
        Border.clearAllBufferCorners(view);
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
    // Pile members all share the column's width, so edge-hit, drag-snap,
    // scroll and the animation see one uniform column width.
    if (view.pile_width) |w| return w;
    if (view.custom_width) |w| return w;
    // XWayland surfaces can be dissociated (surface nulled) before the
    // view is removed from the tiling list; don't crash re-laying out.
    return if (view.surfaceOrNull()) |s| s.current.width - 100 else 0;
}

/// Tiled width for the tile layout path: the lone tiled window on the row
/// fills the workspace (width ratio 1) and drops back to its regular width
/// the moment a second tiled window appears. Mirror copies laid out on
/// OTHER rows keep `getViewWidth` so a single window here doesn't stretch
/// its copies over their neighbours there.
pub fn tiledWidth(context: *ServerContext, view: *View) i32 {
    if (!view.floating and !view.fullscreen and activeTiledCount(context) == 1) {
        return context.usable_area.width - @as(c_int, @intCast(context.gaps_out * 2));
    }
    return getViewWidth(view);
}

/// Number of tiled (mapped, non-floating, non-fullscreen) windows on the
/// active row.
pub fn activeTiledCount(context: *ServerContext) usize {
    var n: usize = 0;
    for (context.views.items) |v| {
        if (!v.isMapped() or v.floating or v.fullscreen) continue;
        n += 1;
    }
    return n;
}

/// Vertical position and slot height of `view` inside an hsplit pile, or
/// null when the view is a single-column tile (takes the full usable
/// height at the row's top edge).
pub const PileSlot = struct {
    top: i32,
    height: i32,
};

pub fn pileSlot(context: *ServerContext, view: *View) ?PileSlot {
    return pileSlotAt(context, view, true);
}

/// `pileSlot` ignoring the drag-preview phantom: the slot the view occupies
/// when no drop preview is active. The drop-point scan (updateDragPreview)
/// must measure REAL geometry or the phantom drifts the mapping.
pub fn pileSlotRaw(context: *ServerContext, view: *View) ?PileSlot {
    return pileSlotAt(context, view, false);
}

fn pileSlotAt(context: *ServerContext, view: *View, with_preview: bool) ?PileSlot {
    const inner_h = context.usable_area.height - @as(c_int, @intCast(context.gaps_out * 2));
    const col_top = context.usable_area.y + @as(c_int, @intCast(context.gaps_out));
    const gap: i32 = @intCast(context.gaps_in);

    // Drag-preview phantom for a LONE column: not a pile, but while a tiled
    // drag hovers it the lone window pre-splits into two equal halves (the
    // phantom takes one, the real window keeps the other) so the drop site is
    // visible before release. dp.index 0 = ghost on top, 1 = ghost below.
    if (view.pile_id == 0) {
        if (with_preview) {
            if (context.drag_preview) |dp| {
                if (dp.anchor == view and dp.anchor.pile_id == 0) {
                    const phantom = [2]f32{ 0.5, 0.5 };
                    const self_at: usize = if (dp.index == 0) 1 else 0;
                    const off = PileMath.pileMemberOffsets(&phantom, self_at);
                    const avail_h: i32 = @max(1, inner_h - gap);
                    const share_h = @as(f32, @floatFromInt(avail_h));
                    return .{
                        .top = col_top + gap * @as(i32, @intCast(self_at)) +
                            @as(i32, @intFromFloat(off.top_frac * share_h)),
                        .height = @max(1, @as(i32, @intFromFloat(off.share_frac * share_h))),
                    };
                }
            }
        }
        return null;
    }

    const idx = std.mem.indexOfScalar(*View, context.views.items, view) orelse return null;

    // Collect this pile's shares in list order (the run is consecutive).
    var shares: [max_pile_members]f32 = undefined;
    var count: usize = 0;
    var j = idx;
    while (j > 0 and context.views.items[j - 1].pile_id == view.pile_id) {
        if (count >= shares.len) return null; // over max_pile_members
        j -= 1;
        shares[count] = context.views.items[j].pile_share;
        count += 1;
    }
    shares[count] = view.pile_share;
    const self_off = count;
    count += 1;
    var k = idx + 1;
    while (k < context.views.items.len and context.views.items[k].pile_id == view.pile_id) : (k += 1) {
        if (count >= shares.len) break;
        shares[count] = context.views.items[k].pile_share;
        count += 1;
    }

    // Drag-preview phantom for a PILE: while a tiled drag hovers this column
    // the pile lays out as if a ghost member with an equal share had just
    // joined at `dp.index` (0..count; count = below the last member). Real
    // members keep their shares, but the (count+1)-split shifts each member at
    // or above dp.index down one slot, so they all visibly pre-shrink to admit
    // the drop. The dragged window itself keeps its own column.
    if (with_preview) {
        if (context.drag_preview) |dp| {
            if (view.pile_id == dp.anchor.pile_id) {
                const ph = 1.0 / @as(f32, @floatFromInt(count + 1));
                var phantom: [max_pile_members + 1]f32 = undefined;
                for (0..count + 1) |i| phantom[i] = ph;
                var self_at = self_off;
                if (self_off >= dp.index) self_at += 1;
                const off2 = PileMath.pileMemberOffsets(phantom[0 .. count + 1], self_at);
                const avail_h: i32 = @max(1, inner_h - gap * @as(i32, @intCast(@max(0, @as(i32, @intCast(count + 1)) - 1))));
                const share_h = @as(f32, @floatFromInt(avail_h));
                return .{
                    .top = col_top + gap * @as(i32, @intCast(self_at)) +
                        @as(i32, @intFromFloat(off2.top_frac * share_h)),
                    .height = @max(1, @as(i32, @intFromFloat(off2.share_frac * share_h))),
                };
            }
        }
    }

    // Normal geometry (no preview): the view's real role in its pile.
    const off = PileMath.pileMemberOffsets(shares[0..count], self_off);
    // Stacked members honor gaps_in like columns do: the pile's inner
    // height is split between the members and their inter-member gaps.
    const avail_h: i32 = @max(1, inner_h - gap * @as(i32, @intCast(@max(0, @as(i32, @intCast(count)) - 1))));
    const share_h = @as(f32, @floatFromInt(avail_h));
    return .{
        .top = col_top + gap * @as(i32, @intCast(self_off)) +
            @as(i32, @intFromFloat(off.top_frac * share_h)),
        .height = @max(1, @as(i32, @intFromFloat(off.share_frac * share_h))),
    };
}

/// True when the tile flow must advance past `view`'s column: always for
/// single-column views, and for a pile member only after its last member.
pub fn advanceSlotAfter(context: *ServerContext, view: *View, idx: usize) bool {
    if (view.pile_id == 0) return true;
    const next_idx = idx + 1;
    if (next_idx >= context.views.items.len) return true;
    return context.views.items[next_idx].pile_id != view.pile_id;
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
    const eh = context.usable_area.height - @as(c_int, @intCast(context.gaps_out * 2));
    var now: std.c.timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &now);

    for (context.views.items) |view| {
        if (!view.isMapped() or view.floating or view.fullscreen) continue;
        if (pileSlot(context, view)) |ps| {
            view.slot_h = ps.height;
        } else {
            view.slot_h = eh;
        }
        const ws = view.borderWidths();
        view.setSize(@max(1, view.slot_w - ws.horizontal()), @max(1, view.slot_h - ws.vertical()));
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
    // Row-lead copies (dock_view == null) push the first window right.
    var x: i32 = context.usable_area.x + context.gaps_out + Mirror.leadWidth(context);

    // Fast-forward x past the unchanged prefix.
    for (0..start_idx) |i| {
        const view = context.views.items[i];
        if (!view.isMapped() or view.floating or view.fullscreen) continue;
        if (advanceSlotAfter(context, view, i)) {
            x += tiledWidth(context, view) + context.gaps_in + Mirror.extraTilesWidth(context, view);
        }
    }

    for (context.views.items[start_idx..], start_idx..) |view, i| {
        if (!view.isMapped() or view.floating or view.fullscreen) continue;

        const width = tiledWidth(context, view);

        view.x = x;
        view.slot_w = width;
        if (pileSlot(context, view)) |ps| {
            view.y = ps.top;
            view.slot_h = ps.height;
        } else {
            view.y = context.usable_area.y + context.gaps_out;
            view.slot_h = context.usable_area.height - @as(c_int, @intCast(context.gaps_out * 2));
        }

        Border.updateViewBorder(view, @floatFromInt(view.x), null);

        if (advanceSlotAfter(context, view, i)) {
            x += width + context.gaps_in + Mirror.extraTilesWidth(context, view);
        }
    }
    Mirror.layoutMirrorsAll(context);
    context.animation_active = true;
    AnimationManager.wake(context);
    context.layout_seq +|= 1;
}

/// Place windows at their targets immediately, skipping the position
/// lerp. Used while interactively resizing so the layout tracks the
/// cursor instead of rubber-banding behind it.
pub fn layoutViews(context: *ServerContext) void {
    var x: i32 = context.usable_area.x + context.gaps_out + Mirror.leadWidth(context);

    for (context.views.items, 0..) |view, i| {
        if (!view.isMapped() or view.floating or view.fullscreen) continue;

        const width = tiledWidth(context, view);

        view.x = x;
        if (pileSlot(context, view)) |ps| {
            view.y = ps.top;
            view.slot_h = ps.height;
        } else {
            view.y = context.usable_area.y + context.gaps_out;
        }

        view.scene_tree.node.setPosition(
            view.x - context.viewport_x,
            view.y - context.viewport_y,
        );
        context.animation_x.items[i] = @floatFromInt(view.x);
        if (i < context.animation_y.items.len) context.animation_y.items[i] = @floatFromInt(view.y);
        Border.updateViewBorder(view, @floatFromInt(view.x), null);

        // Same-row mirror copies are real tiles: advance past them too so the
        // following windows shift right instead of overlapping the copy.
        if (advanceSlotAfter(context, view, i)) {
            x += width + context.gaps_in + Mirror.extraTilesWidth(context, view);
        }
    }
    Mirror.layoutMirrorsAll(context);
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
    const view_right = view.x + tiledWidth(context, view);

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

/// Center a floating view in the usable area and raise it to the top.
/// Mirror copies are re-raised so a just-docked mirror stays above the
/// window (they'd otherwise paint over each other).
pub fn centerFloating(
    context: *ServerContext,
    view: *View,
    force_size: ?[2]i32,
) void {
    // The xdg map event fires during commit processing, before zylr's
    // commit listener sizes the slot, so a freshly-mapped floating view
    // still carries its empty initial slot (~border width) here. Center
    // the box the client actually committed, or the top-left corner lands
    // at screen center and the window spills into the bottom-right.
    if (force_size) |fs| {
        view.slot_w = fs[0];
        view.slot_h = fs[1];
    } else if (view.surfaceOrNull()) |surf| {
        if (surf.current.width > 0 and surf.current.height > 0) {
            const ws = view.borderWidths();
            view.slot_w = surf.current.width + ws.horizontal();
            view.slot_h = surf.current.height + ws.vertical();
        }
    }
    const vw: f32 = @floatFromInt(@max(1, context.usable_area.width));
    const vh: f32 = @floatFromInt(@max(1, context.usable_area.height));
    view.x = context.usable_area.x + @as(i32, @intFromFloat((vw - @as(f32, @floatFromInt(view.slot_w))) / 2));
    view.y = context.usable_area.y + @as(i32, @intFromFloat((vh - @as(f32, @floatFromInt(view.slot_h))) / 2));
    view.scene_tree.node.setPosition(view.x, view.y);
    view.scene_tree.node.raiseToTop();
    Mirror.raiseActiveRow(context);
}

/// Center the viewport on an arbitrary tile (e.g. a mirrored copy mirror tile
/// that isn't a window's home slot): the tile's center lands on the screen
/// center, matching scrollToView's behaviour for windows. Clamped to 0.
pub fn scrollToX(context: *ServerContext, x: i32, tile_w: i32) void {
    const output = context.output orelse return;
    var out_w: c_int = 0;
    var out_h: c_int = 0;
    output.effectiveResolution(&out_w, &out_h);
    context.viewport_target = @max(0, x + @divTrunc(tile_w, 2) - @divTrunc(out_w, 2));
    context.viewport_anim = @floatFromInt(context.viewport_x);
    context.animation_active = true;
    AnimationManager.wake(context);
}

/// Set the viewport target to center `view` without recomputing
/// layout.  Call after updateViewPositions when you already know
/// view.x is current.
pub fn scrollToViewNoLayout(
    context: *ServerContext,
    view: *View,
) void {
    const output = context.output orelse return;

    // A row-switch slide owns the viewport for its duration; the animation
    // tick recentres on the focused window once the transition settles.
    if (context.row_anim != null) return;

    var out_w: c_int = 0;
    var out_h: c_int = 0;
    output.effectiveResolution(&out_w, &out_h);

    const view_width = tiledWidth(context, view);
    const target = view.x + @divTrunc(view_width, 2) - @divTrunc(out_w, 2);

    // Clamp the centered viewport so the tile's left edge never slides
    // under a reserved layer-shell strip (e.g. waybar on the left): a
    // full-width tile would otherwise self-center its left edge off
    // screen, underneath the bar. At the limit the tile sits flush at
    // the usable left edge instead.
    const max_vp = view.x - context.usable_area.x - @as(i32, @intCast(context.gaps_out));

    context.viewport_target = @max(0, @min(target, max_vp));
}

/// hsplit piles cap at this many members stacked in one column.
pub const max_pile_members = 16;

/// First view still sharing `pile_id`, or null if the pile is gone.
fn firstPileMember(context: *ServerContext, pile_id: u64) ?*View {
    for (context.views.items) |v| {
        if (v.pile_id == pile_id) return v;
    }
    return null;
}

/// Reset `view`'s pile state back to a lone single-column tile, keeping its
/// column width as a custom_width so the column doesn't reshape.
fn quitPile(view: *View) void {
    if (view.pile_width) |w| view.custom_width = w;
    view.pile_id = 0;
    view.pile_share = 1;
    view.pile_width = null;
}

/// Equalize the height shares of every view in `anchor`'s pile (shares must
/// sum to 1). A pile that shrank to a single member collapses to a lone column.
fn redividePile(context: *ServerContext, anchor: *View) void {
    const pid = anchor.pile_id;
    if (pid == 0) return;
    var members: [max_pile_members]*View = undefined;
    var count: usize = 0;
    for (context.views.items) |v| {
        if (v.pile_id != pid) continue;
        if (count >= members.len) break;
        members[count] = v;
        count += 1;
    }
    if (count == 0) return;
    if (count == 1) {
        quitPile(members[0]);
        return;
    }
    const share = 1.0 / @as(f32, @floatFromInt(count));
    for (members[0..count]) |m| m.pile_share = share;
}

/// Remove `view` from its pile: it becomes a lone column, the pile re-splits
/// its remaining height evenly.
pub fn splitViewFromPile(context: *ServerContext, view: *View) void {
    const pid = view.pile_id;
    if (pid == 0) return;
    quitPile(view);
    if (firstPileMember(context, pid)) |anchor| {
        redividePile(context, anchor);
    }
}

/// Join `view` into the pile anchored by `anchor`. Callers must have moved
/// `view` adjacent to the pile first (pile members must stay consecutive).
pub fn joinPile(context: *ServerContext, view: *View, anchor: *View) void {
    if (view.pile_id != 0) splitViewFromPile(context, view);
    if (anchor.pile_id == 0) return; // anchor was a lone column too
    view.pile_id = anchor.pile_id;
    view.pile_width = anchor.pile_width;
    redividePile(context, anchor);
}

/// Move `view` next to the pile anchored by `anchor` (in list order) and join
/// it. Used by the hsplit bind and the map-time armed join.
pub fn joinPileNear(context: *ServerContext, view: *View, anchor: *View) void {
    if (view.pile_id != 0) splitViewFromPile(context, view);
    const vidx = std.mem.indexOfScalar(*View, context.views.items, view) orelse return;
    const anchor_idx = std.mem.indexOfScalar(*View, context.views.items, anchor) orelse return;

    // After the split above `view.pile_id` is always 0; the old guard
    // `view.pile_id == anchor.pile_id` fired when BOTH were lone columns
    // (0 == 0), silently aborting every consume into a column.
    if (anchor.pile_id == 0) {
        // Anchor is a lone column: promote it to pile leader, carrying its
        // current width as the shared column width.
        anchor.pile_id = nextPileId(context);
        anchor.pile_share = 1;
        anchor.pile_width = tiledWidth(context, anchor);
    }
    view.pile_id = anchor.pile_id;
    view.pile_width = anchor.pile_width;
    view.pile_share = 1;

    // Bubble `view` to sit right after `anchor` (below it), so the pile stays
    // consecutive; animation arrays move in lockstep.
    const ax = &context.animation_x;
    const aw = &context.animation_w;
    const ay = &context.animation_y;
    var i = vidx;
    if (anchor_idx > vidx) {
        while (i < anchor_idx) : (i += 1) {
            std.mem.swap(*View, &context.views.items[i], &context.views.items[i + 1]);
            std.mem.swap(f32, &ax.items[i], &ax.items[i + 1]);
            std.mem.swap(f32, &aw.items[i], &aw.items[i + 1]);
            std.mem.swap(f32, &ay.items[i], &ay.items[i + 1]);
        }
    } else {
        while (i > anchor_idx + 1) : (i -= 1) {
            std.mem.swap(*View, &context.views.items[i], &context.views.items[i - 1]);
            std.mem.swap(f32, &ax.items[i], &ax.items[i - 1]);
            std.mem.swap(f32, &aw.items[i], &aw.items[i - 1]);
            std.mem.swap(f32, &ay.items[i], &ay.items[i - 1]);
        }
    }

    redividePile(context, anchor);
}

/// A pile id no view carries yet.
fn nextPileId(context: *ServerContext) u64 {
    var id: u64 = 1;
    while (true) : (id += 1) {
        var taken = false;
        for (context.views.items) |v| {
            if (v.pile_id == id) {
                taken = true;
                break;
            }
        }
        if (!taken) return id;
    }
}

/// Hsplit "undo": turn every member of `anchor`'s pile back into its own
/// Set `view`'s vertical share to `share` (fraction), clamped to .1..0.9,
/// keeping the pile's shares summing to 1 by redistributing the remainder
/// to its siblings. Shared by the share binds and the divider drag.
pub fn setPileShare(context: *ServerContext, view: *View, share: f32) void {
    if (view.pile_id == 0) return;
    var members: [max_pile_members]*View = undefined;
    var count: usize = 0;
    for (context.views.items) |v| {
        if (v.pile_id != view.pile_id) continue;
        if (count >= members.len) break;
        members[count] = v;
        count += 1;
    }
    if (count < 2) return;
    view.pile_share = @min(@max(0.1, share), 0.9);
    const remainder = 1.0 - view.pile_share;
    const others = count - 1;
    for (members[0..count]) |m| {
        if (m != view) {
            m.pile_share = remainder / @as(f32, @floatFromInt(others));
        }
    }
}

/// Adjust `view`'s vertical share by `delta` (fraction).
pub fn adjustPileShare(context: *ServerContext, view: *View, delta: f32) void {
    if (view.pile_id == 0) return;
    setPileShare(context, view, view.pile_share + delta);
}

/// Re-send the configured size of every member of `view`'s pile, then relayout.
/// The keyboard grow/shrink path calls this after adjustPileShare.
pub fn syncPile(context: *ServerContext, anchor: *View) void {
    updateViewPositions(context);
    if (anchor.pile_id != 0) {
        for (context.views.items) |v| {
            if (v.pile_id != anchor.pile_id) continue;
            const slot = pileSlot(context, v) orelse continue;
            v.slot_h = slot.height;
            const ws = v.borderWidths();
            v.setSize(@max(1, v.slot_w - ws.horizontal()), @max(1, slot.height - ws.vertical()));
        }
    }
    for (context.views.items) |v| {
        if (v.pile_id != anchor.pile_id) continue;
        scrollToViewNoLayout(context, v);
    }
}
