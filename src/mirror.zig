const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlroots = @import("wlroots");
const pixman = @import("pixman");

const ServerContext = @import("server.zig");
const View = @import("view/view.zig");
const ViewManager = @import("view/view_manager.zig");
const Rounding = @import("view/rounding.zig");
const Border = @import("view/border.zig");
const FocusManager = @import("view/focus.zig");

const allocator = std.heap.c_allocator;

var last_mirror_kick_ns: i128 = -999999999999;

// The mirrored source's real tree is disabled, so wlroots never sends it
// frame-done and the client stops drawing - the mirror copy would freeze on
// its last committed buffer even though it's the live face of that window.
// Kicks are now paced off the real output frame (see onOutputFrame) so the
// client produces exactly one frame per vsync, never an unvsync'd hot loop.
const kick_hidden_source = true;

const log = std.log.scoped(.mirror);

/// Create a mirror of `view` on `target_row`. For the active row we
/// immediately create the scene trees; for inactive rows we only record
/// the intent in `row_sources`, and lazily create the scene tree on row
/// activation
pub fn mirrorToRow(context: *ServerContext, view: *View, target_row: usize) void {
    if (target_row >= ServerContext.max_rows) return;
    if (findMirrors(context, view, target_row)) |_| return;

    // Record the mirrored copy on the target row.
    context.row_sources[target_row].append(allocator, view) catch return;

    // Hide the source and rebuild mirrors
    refreshSourceVisibility(context, view);
}

/// Delete the mirror of `view` on `target_row` (the single source entry for
/// that row). Returns true when a mirror was actually removed.
pub fn deleteMirrorFromRow(context: *ServerContext, view: *View, target_row: usize) bool {
    if (target_row >= ServerContext.max_rows) return false;
    const idx = findMirrors(context, view, target_row) orelse return false;
    _ = context.row_sources[target_row].orderedRemove(idx);
    refreshSourceVisibility(context, view);
    return true;
}

/// super+q on a mirror: remove exactly the focused tile. On a COPY (a docked
/// mirror from `row_sources`) that tile is removed and the source survives; on
/// the SELF mirror (the source's home tile shown as its own mirror) just that
/// tile is removed too - the slot goes blank, the source stays hidden and any
/// copies remain. When removing the tile leaves exactly one mirror behind, the
/// source dissolves into a real window in the survivor's place (no window
/// resurrecting on a later close). Returns true when a mirror tile (self or
/// copy) was handled; false when the focused view is an ordinary window
/// (caller closes it).
pub fn closeFocusedMirrorCopy(context: *ServerContext) bool {
    const view = context.focused_view orelse return false;

    // Resolve which tile is focused: the keyboard-anchored slot first, else
    // the tile under the pointer. The anchor is matched by nearest slot, not
    // exactly: layout passes re-place mirrors and drift slot_x away from the
    // anchor, so an exact match goes stale and mis-identifies the ring's tile
    // (closing the self mirror used to silently delete the copy instead).
    const kbd_row: usize = if (context.kbd_anchor_slot_x >= 0) context.kbd_anchor_row else ServerContext.max_rows;
    var row: usize = kbd_row;
    var is_self = false;
    var pinned = false;
    if (kbd_row < ServerContext.max_rows) {
        if (closestMirrorAt(context, view, kbd_row, context.kbd_anchor_slot_x)) |m| {
            pinned = true;
            is_self = m.is_self;
        }
    }
    if (!pinned) {
        // Ring on a home slot never pins a keyboard anchor (home tiles carry
        // mirror_slot_x=-1 in tileCycle), yet the surface there is the SELF
        // mirror. Prefer closing that ringed tile over whatever the cursor
        // happens to sit on - otherwise Super+q over a stray pointer on the
        // neighbouring copy removes the copy, not the ringed self mirror.
        var self_on_row = false;
        for (context.row_mirrors[context.active_row].items) |*m| {
            if (m.view == view and m.active and m.is_self) {
                self_on_row = true;
                break;
            }
        }
        if (self_on_row) {
            pinned = true;
            is_self = true;
        } else {
            var sx: f64 = 0;
            var sy: f64 = 0;
            const node = context.scene.tree.node.at(context.cursor.x, context.cursor.y, &sx, &sy);
            if (node) |n| {
                if (mirrorInputTarget(context, view, n, sx, sy)) |t| {
                    row = t.row;
                    is_self = t.mirror.is_self;
                    pinned = true;
                }
            }
        }
    }

    if (pinned and is_self) {
        // Self-mirror (source's home slot rendered as a mirror): remove just
        // this tile. The source stays hidden because its copies still exist.
        view.self_mirror_suppressed = true;
        refreshSourceVisibility(context, view);
        context.kbd_anchor_slot_x = -1;
        context.kbd_cycle_slot = -1;
        return dissolveCollapse(context, view);
    }
    if (pinned) {
        // Concrete copy tile.
        if (deleteMirrorFromRow(context, view, row)) {
            context.kbd_anchor_slot_x = -1;
            context.kbd_cycle_slot = -1;
            killIfLastCopyOnHiddenRow(context, view);
            return dissolveCollapse(context, view);
        }
    }

    // Nothing anchored to a visible tile (focus ring is on the home slot,
    // whose surface is hidden behind the self mirror). Remove just that tile.
    if (hasAnyMirrors(context, view)) {
        view.self_mirror_suppressed = true;
        refreshSourceVisibility(context, view);
        context.kbd_anchor_slot_x = -1;
        context.kbd_cycle_slot = -1;
        return dissolveCollapse(context, view);
    }
    return false;
}

/// The tile of `view` on `row` nearest the given anchor slot, or null when the
/// view has no (placed) mirror there. Used instead of an exact slot match so a
/// stale keyboard anchor still resolves to the ring's actual tile.

fn closestMirrorAt(context: *ServerContext, view: *View, row: usize, slot_x: i32) ?*ServerContext.Mirror {
    if (row >= ServerContext.max_rows) return null;
    var best: ?*ServerContext.Mirror = null;
    var best_d: u64 = std.math.maxInt(u64);
    for (context.row_mirrors[row].items) |*m| {
        if (m.view != view or !m.active or m.slot_x == std.math.minInt(i32)) continue;
        const d = @abs(@as(i64, @intCast(m.slot_x)) - @as(i64, @intCast(slot_x)));
        if (d < best_d) {
            best_d = d;
            best = m;
        }
    }
    return best;
}

/// Remove all mirrors for `view` (called on view destroy).
pub fn destroyAllMirrors(context: *ServerContext, view: *View) void {
    for (0..ServerContext.max_rows) |r| {
        // Mirrored list.
        var pi: usize = context.row_sources[r].items.len;
        while (pi > 0) {
            pi -= 1;
            if (context.row_sources[r].items[pi] == view)
                _ = context.row_sources[r].orderedRemove(pi);
        }
        // Mirror trees.
        var mi: usize = context.row_mirrors[r].items.len;
        while (mi > 0) {
            mi -= 1;
            if (context.row_mirrors[r].items[mi].view == view) {
                tearDownMirror(&context.row_mirrors[r].items[mi]);
                context.row_mirrors[r].items[mi].tree.node.destroy();
                _ = context.row_mirrors[r].orderedRemove(mi);
            }
        }
    }
    view.scene_tree.node.setEnabled(true);
}

/// Unlink and free a single mirror's SubCopy nodes without clearing the
/// list (checked by `destroyAllMirrors` which removes the mirror entry
/// itself). The mirror's scene tree is NOT destroyed here - caller owns it.
fn tearDownMirror(m: *ServerContext.Mirror) void {
    for (m.sub_copies.items) |sc| {
        unlinkCopy(sc);
        sc.node.node.destroy();
        allocator.destroy(sc);
    }
    m.sub_copies.deinit(allocator);
}

/// Hide the source's real surface whenever it has a mirror anywhere, and make
/// sure its home row carries a self-mirror so it stays visible as a mirror.
/// Re-shows the real surface and drops the self-mirror once it has no mirrors.
fn refreshSourceVisibility(context: *ServerContext, view: *View) void {
    // Self-mirrors are NOT stored in `row_sources`; they are derived at build
    // time from "is this window of the row mirrored anywhere?". So here we only
    // hide/show the real surface and rebuild the mirrors of any row this
    // window both lives on and renders right now.
    if (hasAnyMirrors(context, view)) {
        view.scene_tree.node.setEnabled(false);
    } else {
        view.self_mirror_suppressed = false;
        view.scene_tree.node.setEnabled(true);
    }
    // Rebuild the visible row's mirrors: a change can add/remove a copy
    // on the active row and/or the source's self-mirror, no matter which row
    // the source lives on.
    activateMirrors(context, context.active_row);
    // The mirror change alters the flow (a new copy tile needs room, a removed
    // one frees it), so reflow the windows - layoutRow alone would leave the
    // tiles correctly sized but stacked over stale neighbour slots until the
    // next interactive resize/focus switch woke the layout pass.
    ViewManager.updateViewPositionsFrom(context, 0);
}

/// True when `view`'s real surface is hidden because it was replaced with a mirror
pub fn isHiddenSource(context: *ServerContext, view: *View) bool {
    return hasAnyMirrors(context, view);
}

fn hasAnyMirrors(context: *ServerContext, view: *View) bool {
    for (0..ServerContext.max_rows) |r| {
        if (findMirrors(context, view, r) != null) return true;
    }
    return false;
}

/// Total number of mirror tiles currently standing for `view`: one per row
/// that holds a copy, plus the self-mirror rendered at home (unless the user
/// suppressed it).
fn countMirrors(context: *ServerContext, view: *View) usize {
    var n: usize = 0;
    for (0..ServerContext.max_rows) |r| {
        if (findMirrors(context, view, r) != null) n += 1;
    }
    if (n > 0 and !view.self_mirror_suppressed) n += 1;
    return n;
}

const SurvivingCopy = struct { row: usize, x: i32 };

/// The one copy tile that would survive once the self-mirror is gone (the
/// last row still holding this view). Returns the row and its tile x.
fn survivingCopy(context: *ServerContext, view: *View) ?SurvivingCopy {
    var out: ?SurvivingCopy = null;
    for (0..ServerContext.max_rows) |r| {
        if (findMirrors(context, view, r) == null) continue;
        for (context.row_mirrors[r].items) |m| {
            if (m.view != view or m.is_self) continue;
            out = .{ .row = r, .x = m.slot_x };
        }
    }
    return out;
}

/// Collapse rule: after a mirror tile was removed, when only ONE mirror tile
/// remains, dissolve the whole mirror set and turn the source back into a real
/// window in the survivor's slot - the mirrored window keeps existing instead
/// of a phantom copy later resurrecting it. `killIfLastCopyOnHiddenRow`
/// already ran, so a survivor can only be on the active row or an active-row
/// copy; a lone surviving self-mirror therefore means the source simply flows
/// at its home slot. Re-focuses the active row so keyboard focus leaves the
/// removed tile.
fn dissolveCollapse(context: *ServerContext, view: *View) bool {
    if (countMirrors(context, view) != 1) {
        FocusManager.focusActiveRow(context);
        return true;
    }
    const survivor = survivingCopy(context, view);
    for (0..ServerContext.max_rows) |r| context.row_sources[r].clearRetainingCapacity();
    view.self_mirror_suppressed = false;
    destroyAllMirrors(context, view);
    refreshSourceVisibility(context, view);
    if (survivor) |s| {
        if (s.row == context.active_row and std.mem.indexOfScalar(*View, context.views.items, view) != null) {
            // The collapse reflow just placed the source at its home slot.
            const home_x = view.x;
            ViewManager.moveViewToSlot(context, view, @as(f64, @floatFromInt(s.x)));
            // moveViewToSlot only reorders between existing window slots; a
            // lone window has no slot at the survivor's x, so it no-ops and
            // the source would snap home. Surface it at the survivor position
            // instead and hold the vacated home slot open as head_gap.
            if (view.x == home_x and s.x > home_x) {
                context.head_gap = s.x - home_x;
                context.head_gap_owner = view;
                ViewManager.updateViewPositionsFrom(context, 0);
                // Snap the surface straight to the survivor position (the
                // reflow woke the animation; with the gap applied its target
                // is exactly there, so marking animation_x prevents a slide).
                const idx = std.mem.indexOfScalar(*View, context.views.items, view) orelse 0;
                if (idx < context.animation_x.items.len) {
                    context.animation_x.items[idx] = @floatFromInt(s.x);
                }
            }
        }
    }
    FocusManager.focusActiveRow(context);
    return true;
}

/// After deleting a copy: when the source no longer has ANY mirrors and it
/// lives on a hidden (parked) row, its real surface would be re-enabled off-
/// screen — a zombie. Kill it so closing the last copy does close the source.
/// A source that lives on the active row survives: it reverts to a normal
/// window (its real surface re-enables in place).
fn killIfLastCopyOnHiddenRow(context: *ServerContext, view: *View) void {
    if (hasAnyMirrors(context, view)) return;
    const home = homeRowOf(context, view) orelse return;
    if (home != context.active_row) view.sendClose();
}

/// The row this window lives on (active working set or a parked row).
fn homeRowOf(context: *ServerContext, view: *View) ?usize {
    if (std.mem.indexOfScalar(*View, context.views.items, view) != null) return context.active_row;
    for (context.rows, 0..) |maybe_row, i| {
        if (maybe_row) |r| {
            if (std.mem.indexOfScalar(*View, r.views.items, view) != null) return i;
        }
    }
    return null;
}

/// One scene buffer of the source's real (hidden) scene tree, with its
/// accumulated offset inside that tree.
const SceneItem = struct {
    src: *wlroots.SceneBuffer,
    x: i32,
    y: i32,
};

/// Walk `tree` - wlroots' actual scene layout of the mirrored source - and
/// collect every scene buffer node with its position, in render order. The
/// toplevel surface's own buffer is the anchor (subsurfaces_below hang off
/// it, so it is visited mid-walk): it maps to the mirror's buf_node, so it
/// is recorded but not collected. Reading the scene instead of hand-rolling
/// subsurface/popup math makes the mirror reproduce wlroots' composition
/// exactly: positions, CSD geometry clips, crops, z-order, popups.
fn collectSceneItems(
    tree: *wlroots.SceneTree,
    ax: i32,
    ay: i32,
    below: *std.ArrayListUnmanaged(SceneItem),
    above: *std.ArrayListUnmanaged(SceneItem),
    top_surf: *wlroots.Surface,
    out_anchor: *?*wlroots.SceneBuffer,
    out_ax: *i32,
    out_ay: *i32,
) void {
    // Depth cap: if a stale tree's recycled memory keeps looking like a
    // `tree` node, do not recurse forever on corrupt links.
    const depth: usize = 0;
    collectSceneItemsDepth(tree, ax, ay, below, above, top_surf, out_anchor, out_ax, out_ay, depth);
}

fn collectSceneItemsDepth(
    tree: *wlroots.SceneTree,
    ax: i32,
    ay: i32,
    below: *std.ArrayListUnmanaged(SceneItem),
    above: *std.ArrayListUnmanaged(SceneItem),
    top_surf: *wlroots.Surface,
    out_anchor: *?*wlroots.SceneBuffer,
    out_ax: *i32,
    out_ay: *i32,
    depth: usize,
) void {
    if (depth >= 24) return;
    var it = tree.children.iterator(.forward);
    while (it.next()) |node| {
        const cax = ax + node.x;
        const cay = ay + node.y;
        // Zig panics on an out-of-range enum tag even when a `switch` has an
        // `else` prong. The source tree is wlroots-owned memory that can hold
        // junk once a view's protocol surface has died, so branch on the tag
        // as a raw int (no safety check) rather than on the enum itself.
        switch (@intFromEnum(node.type)) {
            @intFromEnum(wlroots.SceneNode.Type.tree) => collectSceneItemsDepth(wlroots.SceneTree.fromNode(node), cax, cay, below, above, top_surf, out_anchor, out_ax, out_ay, depth + 1),
            @intFromEnum(wlroots.SceneNode.Type.buffer) => {
                const buf = wlroots.SceneBuffer.fromNode(node);
                if (wlroots.SceneSurface.tryFromBuffer(buf)) |ss| {
                    if (ss.surface == top_surf) {
                        out_anchor.* = buf;
                        out_ax.* = cax;
                        out_ay.* = cay;
                        continue;
                    }
                }
                const list = if (out_anchor.* == null) below else above;
                list.append(allocator, .{ .src = buf, .x = cax, .y = cay }) catch {};
            },
            // Corrupt tag: the source tree is no longer trustworthy, so stop
            // mirroring it entirely rather than collecting garbage buffers.
            else => return,
        }
    }
}

/// Clone a source scene buffer's full state onto a mirror copy node:
/// committed buffer, dest size, source crop (which carries the CSD geometry
/// clip), transform. Opacity forced below 1.0 so the renderer can't cull a
/// copy as covered by opaque content.
fn findSubCopy(m: *ServerContext.Mirror, src: *wlroots.Surface) ?*ServerContext.SubCopy {
    for (m.sub_copies.items) |sc| {
        if (sc.src == src) return sc;
    }
    return null;
}

/// Reconcile and feed every sub-surface of `surf` (and recursively of each
/// sub-surface) into per-surface copy nodes. Sub positions come from the
/// surface-side placeholders (ps.x/ps.y), accumulated relative to the
/// toplevel; copies are placed inside the tile at (bw + x, bw + y).
/// Firefox/Chrome render their real content on subsurfaces, so feeding only
/// the toplevel buffer leaves the tile transparent. Every appended surface
/// pointer is also recorded in `live` so callers can cull stale copies.
const MirrorFeed = struct {
    m: *ServerContext.Mirror,
    bw: i32,
    gx: i32,
    gy: i32,
    live: *std.ArrayListUnmanaged(*wlroots.Surface),
};

/// wlroots xdg-walk callback: yields the toplevel surface and every
/// subsurface and xdg popup (recursively) with positions in toplevel-surface
/// coordinates - note popups come BEFORE the toplevel. The toplevel is fed as
/// the main node (matched by pointer, never by position); the rest get
/// per-surface copy nodes. Only popup copies bind commit/destroy listeners:
/// subs already ride the toplevel commit path, and the toplevel must never
/// become a copy (bind listeners on it self-recursed and GP'd).
fn mirrorSurfaceIter(s: *wlroots.Surface, sx: c_int, sy: c_int, ctx: *MirrorFeed) void {
    const m = ctx.m;
    if (s == m.surf) return;
    if (std.mem.indexOfScalar(*wlroots.Surface, ctx.live.items, s) == null) ctx.live.append(allocator, s) catch {};
    const scn: *wlroots.SceneBuffer = if (findSubCopy(m, s)) |sc|
        sc.node
    else blk: {
        const node = m.tree.createSceneBuffer(null) catch return;
        const sc = allocator.create(ServerContext.SubCopy) catch {
            node.node.destroy();
            return;
        };
        sc.* = .{ .src = s, .node = node, .owner = m };
        // Every non-toplevel copy (subsurface AND popup) binds commit/destroy
        // listeners: those surfaces commit on their own, out of sync with the
        // toplevel, so without a listener their mirror copy would freeze on
        // the first-walked buffer. The toplevel is excluded (s == m.surf) -
        // binding a commit listener on it self-recursed and GP'd earlier.
        sc.commit = wl.Listener(*wlroots.Surface).init(onCopySurfaceCommit);
        sc.destroy = wl.Listener(*wlroots.Surface).init(onCopySurfaceDestroy);
        s.events.commit.add(&sc.commit);
        s.events.destroy.add(&sc.destroy);
        m.sub_copies.append(allocator, sc) catch {
            sc.commit.link.remove();
            sc.destroy.link.remove();
            node.node.destroy();
            allocator.destroy(sc);
            return;
        };
        break :blk node;
    };
    feedCopy(m, scn, s, ctx.bw, ctx.gx, ctx.gy, @as(i32, sx), @as(i32, sy));
}

/// A mirror copy's source surface (subsurface or popup) committed content:
/// re-feed its mirror so the copy follows even without a toplevel commit.
fn onCopySurfaceCommit(listener: *wl.Listener(*wlroots.Surface), _: *wlroots.Surface) void {
    const sc: *ServerContext.SubCopy = @fieldParentPtr("commit", listener);
    feedMirrorTree(sc.owner);
}

/// The copy's source surface was destroyed (popup closed etc): unlink our
/// listeners now, while the dying surface's memory is still valid, then drop
/// the copy node.
fn onCopySurfaceDestroy(listener: *wl.Listener(*wlroots.Surface), _: *wlroots.Surface) void {
    const sc: *ServerContext.SubCopy = @fieldParentPtr("destroy", listener);
    const owner = sc.owner;
    if (sc.linked) {
        sc.commit.link.remove();
        sc.linked = false;
    }
    sc.destroy.link.remove();
    sc.node.node.destroy();
    for (owner.sub_copies.items, 0..) |c, i| {
        if (c == sc) {
            _ = owner.sub_copies.swapRemove(i);
            allocator.destroy(sc);
            break;
        }
    }
}

fn unlinkCopy(sc: *ServerContext.SubCopy) void {
    if (sc.linked) {
        sc.commit.link.remove();
        sc.destroy.link.remove();
        sc.linked = false;
    }
}

fn feedCopy(m: *ServerContext.Mirror, scn: *wlroots.SceneBuffer, s: *wlroots.Surface, bw: i32, gx: i32, gy: i32, sx: i32, sy: i32) void {
    scn.node.data = &m.view.node_data;
    if (s.buffer) |cb| {
        var damage: pixman.Region32 = undefined;
        damage.initRect(0, 0, @intCast(cb.base.width), @intCast(cb.base.height));
        defer damage.deinit();
        scn.setBufferWithDamage(&cb.base, &damage);
        scn.setDestSize(s.current.width, s.current.height);
    } else {
        scn.setBuffer(null);
    }
    scn.node.setPosition(bw + sx - gx, bw + sy - gy);
    if (m.view.context.corner_radius > 0) {
        Rounding.setBufferCorners(scn, @intCast(@max(0, m.view.context.corner_radius - 1)));
    }
}

/// Cull copy nodes whose source surface is no longer part of the tree.
fn cullSubCopies(m: *ServerContext.Mirror, live: []const *wlroots.Surface) void {
    var i: usize = 0;
    while (i < m.sub_copies.items.len) {
        const sc = m.sub_copies.items[i];
        if (std.mem.indexOfScalar(*wlroots.Surface, live, sc.src) == null) {
            unlinkCopy(sc);
            sc.node.node.destroy();
            _ = m.sub_copies.swapRemove(i);
            allocator.destroy(sc);
        } else {
            i += 1;
        }
    }
}

/// Push the source's WHOLE scene tree into the mirror's copy nodes by
/// cloning each buffer node of the real (hidden) scene at its exact
/// position - toplevel content, subsurfaces, xdg popups, everything wlroots
/// laid out for the live window. Chrome/Firefox render content on
/// subsurfaces and menus on xdg popups, which a surface-only feed drops;
/// cloning the scene tree reproduces the full composition, aligned with the
/// border exactly like the real tile. Called on every source commit AND once
/// at creation.
fn feedMirrorTree(m: *ServerContext.Mirror) void {
    if (m.feed_in_progress) return;
    m.feed_in_progress = true;
    defer m.feed_in_progress = false;
    const bn = m.buf_node orelse {
        return;
    };
    const surf = m.surf orelse {
        return;
    };
    if (!m.view.isMapped()) {
        return;
    }
    const context = m.view.context;
    const bw: i32 = context.border_width;

    // Feed the mirror from the source surface's own committed client buffer
    // plus a full-buffer damage region in buffer coordinates (a
    // surface-sized region misses most of a scaled buffer and the output
    // never repaints). This is the path proven to render; the scene-tree
    // walk was abandoned after it produced no anchor for any window.
    var damage: pixman.Region32 = undefined;
    if (surf.buffer) |cb| {
        // Damage must be bounded to the REAL buffer size: a maxInt region
        // into the scene damage tracking can blow up the GPU pipeline and
        // hard-hang the whole machine.
        damage.initRect(0, 0, @intCast(cb.base.width), @intCast(cb.base.height));
        defer damage.deinit();
        bn.setBufferWithDamage(&cb.base, &damage);
    } else {
        damage.initRect(0, 0, std.math.maxInt(c_int), std.math.maxInt(c_int));
        defer damage.deinit();
        bn.setBuffer(null);
        return;
    }
    // The source-box crop is in BUFFER coordinates while xdg geometry is in
    // SURFACE coordinates; apps can render at 2x with scale=1 (Firefox does:
    // buffer is buffer/surface = 2x), so derive the crop ratio from the real
    // buffer size, never from the surface scale. Removing this crop scaled
    // the 2x buffer into the dest with the CSD shadow margins included - the
    // "scaled double / bigger cropped" bug.
    const cw = m.slot_w - 2 * bw;
    const ch = m.slot_h - 2 * bw;
    if (cw > 0 and ch > 0) {
        bn.setDestSize(cw, ch);
    } else {
        bn.setDestSize(surf.current.width, surf.current.height);
    }
    if (m.view.backend == .xdg) {
        const g = m.view.backend.xdg.base.geometry;
        if (g.width > 0 and g.height > 0) {
            const buf_w = if (surf.buffer) |cb| @as(f32, @floatFromInt(cb.base.width)) else @as(f32, @floatFromInt(surf.current.width));
            const ratio: f32 = buf_w / @as(f32, @floatFromInt(@max(1, surf.current.width)));
            var src_box: wlroots.FBox = .{ .x = @as(f32, @floatFromInt(g.x)) * ratio, .y = @as(f32, @floatFromInt(g.y)) * ratio, .width = @as(f32, @floatFromInt(g.width)) * ratio, .height = @as(f32, @floatFromInt(g.height)) * ratio };
            if (src_box.width > 0 and src_box.height > 0) bn.setSourceBox(&src_box);
        }
    }
    bn.node.setPosition(bw, bw);
    var live: std.ArrayListUnmanaged(*wlroots.Surface) = .empty;
    defer live.deinit(allocator);
    const gx: i32 = switch (m.view.backend) {
        .xdg => |t| @intCast(@max(0, t.base.geometry.x)),
        .xwayland => 0,
    };
    const gy: i32 = switch (m.view.backend) {
        .xdg => |t| @intCast(@max(0, t.base.geometry.y)),
        .xwayland => 0,
    };
    switch (m.view.backend) {
        .xdg => |t| blk: {
            var ctx = MirrorFeed{ .m = m, .bw = bw, .gx = gx, .gy = gy, .live = &live };
            t.base.forEachSurface(*MirrorFeed, mirrorSurfaceIter, &ctx);
            break :blk;
        },
        .xwayland => {},
    }
    cullSubCopies(m, live.items);
}

pub fn updateMirrors(view: *View) void {
    const context = view.context;
    const bw: i32 = context.border_width;
    for (0..ServerContext.max_rows) |r| {
        var i: usize = 0;
        while (i < context.row_mirrors[r].items.len) {
            const m = &context.row_mirrors[r].items[i];
            if (m.view == view) {
                if (m.border_rect) |br| {
                    const br_enabled = m.view == context.focused_view;
                    Border.updateBorderRect(context, br, @max(1, m.slot_w - 2 * bw), @max(1, m.slot_h - 2 * bw), m.slot_w, m.slot_h, br_enabled, @intCast(@max(0, context.corner_radius - 1)));
                }
                m.pushed +|= 1;
                // Re-place on a surface size change: placeMirror bakes the
                // surface size into slot_w at placement time, and a commit
                // arriving later (first buffer on a new mirror, or a resize)
                // must recompute the tile or it stays stale until the next
                // layout pass (focus switch).
                if (m.surf) |msurf| {
                    const live_w: i32 = msurf.current.width;
                    const live_h: i32 = msurf.current.height;
                    if (live_w != m.surf_w or live_h != m.surf_h) {
                        placeMirror(context, m, m.slot_x, m.slot_y, m.slot_w, m.slot_h);
                    }
                }
                // Every mirror is a copy: feed it the surface's OWN client
                // buffer plus its damage region - the exact formula wlroots'
                // scene-surface reconfigure uses for a window. Kept alive by
                // the scene buffer, so the texture stays in sync with the
                // source (which lives in memory, its real surface hidden).
                feedMirrorTree(m);
            }
            i += 1;
        }
    }
}

/// Vsync-paced frame-done kicks for every hidden mirrored source. Called once
/// per committed output frame; throttled so multiple outputs stay bounded.
pub fn onOutputFrame(context: *ServerContext, now: *const std.posix.timespec) void {
    if (!kick_hidden_source) return;
    const now_ns: i128 = @as(i128, now.sec) * std.time.ns_per_s + now.nsec;
    if (now_ns - last_mirror_kick_ns < std.time.ns_per_ms * 7) return;
    last_mirror_kick_ns = now_ns;
    for (context.views.items) |view| {
        if (!isHiddenSource(context, view)) continue;
        const surf = view.surfaceOrNull() orelse continue;
        surf.sendFrameDone(now);
        var kick: std.ArrayListUnmanaged(*wlroots.Surface) = .empty;
        defer kick.deinit(allocator);
        collectKickSurfaces(&kick, surf);
        for (context.popups.items) |pn| {
            if (pn.view != view) continue;
            collectKickSurfaces(&kick, pn.popup.base.surface);
        }
        for (kick.items) |kf| {
            if (kf != surf) kf.sendFrameDone(now);
        }
    }
}

/// Append `surf` and every surface in its subsurface tree (for frame-done
/// kicks to keep hidden-source clients producing).
const KickCtx = struct {
    out: *std.ArrayListUnmanaged(*wlroots.Surface),
};

fn kickSurf(s: *wlroots.Surface, _: c_int, _: c_int, ctx: *KickCtx) void {
    if (std.mem.indexOfScalar(*wlroots.Surface, ctx.out.items, s) == null) ctx.out.append(allocator, s) catch {};
}

fn collectKickSurfaces(out: *std.ArrayListUnmanaged(*wlroots.Surface), surf: *wlroots.Surface) void {
    if (std.mem.indexOfScalar(*wlroots.Surface, out.items, surf) == null) out.append(allocator, surf) catch {};
    var it = surf.current.subsurfaces_below.iterator(.forward);
    while (it.next()) |ps| {
        const sub: *wlroots.Subsurface = @fieldParentPtr("current", ps);
        collectKickSurfaces(out, sub.surface);
    }
    var it2 = surf.current.subsurfaces_above.iterator(.forward);
    while (it2.next()) |ps| {
        const sub: *wlroots.Subsurface = @fieldParentPtr("current", ps);
        collectKickSurfaces(out, sub.surface);
    }
    if (wlroots.XdgSurface.tryFromWlrSurface(surf)) |xdg| {
        var ctx = KickCtx{ .out = out };
        xdg.forEachSurface(*KickCtx, kickSurf, &ctx);
    }
}

extern fn clock_gettime(clk_id: c_int, tp: *anyopaque) c_int;
const CLOCK_MONOTONIC: c_int = 1;

/// Position every mirror of `view` on the ACTIVE row as part of the tiled
/// flow, called every animation frame. The self-mirror rides the window's
/// own animated tile; any same-row copies flow as adjacent tiles right after
/// it. All positions are in row coordinates and get the viewport offset, so
/// mirrors scroll with the row exactly like windows - genuinely tiled, never
/// floating.
pub fn syncActiveTile(view: *View, cur_x_row: f32, cur_w: f32) void {
    const context = view.context;
    const vp: f32 = @floatFromInt(context.viewport_x);
    const scene_y: i32 = view.y - context.viewport_y;
    const mirrors = &context.row_mirrors[context.active_row];
    // Self-mirrors ride their own window's tile.
    for (mirrors.items) |*m| {
        if (!m.active or !m.is_self or m.view != view) continue;
        m.tree.node.setPosition(@intFromFloat(cur_x_row - vp), scene_y);
    }
    // Copies docked after this window flow as tiles right after it, in
    // dock_order (a copy's width is its own source's, not the dock window's).
    var idxs: [64]usize = undefined;
    const cnt = sortedDocked(context, mirrors, view, &idxs);
    var cy: f32 = cur_x_row + cur_w + @as(f32, @floatFromInt(context.gaps_in));
    for (idxs[0..cnt]) |i| {
        const m = &mirrors.items[i];
        m.tree.node.setPosition(@intFromFloat(cy - vp), scene_y);
        cy += @as(f32, @floatFromInt(renderedWidth(context, m.view) + context.gaps_in));
    }
}

/// Animate the active row's lead copies (docked to no window) at the row
/// start each frame, so they scroll with the viewport like real tiles.
pub fn syncLeadTiles(context: *ServerContext) void {
    if (context.active_row >= ServerContext.max_rows) return;
    const vp: i32 = context.viewport_x;
    const y: i32 = context.usable_area.y + context.gaps_out - context.viewport_y;
    const mirrors = &context.row_mirrors[context.active_row];
    var idxs: [64]usize = undefined;
    const cnt = sortedDocked(context, mirrors, null, &idxs);
    var x: i32 = context.usable_area.x + context.gaps_out;
    for (idxs[0..cnt]) |i| {
        const m = &mirrors.items[i];
        m.tree.node.setPosition(x - vp, y);
        x += renderedWidth(context, m.view) + context.gaps_in;
    }
}

/// Non-self active copies of `mirrors` docked to `dock` (null = row lead),
/// sorted by dock_order. Returns the count, indices in `out` (max 64).
fn sortedDocked(
    _: *ServerContext,
    mirrors: *std.ArrayListUnmanaged(ServerContext.Mirror),
    dock: ?*View,
    out: *[64]usize,
) usize {
    var cnt: usize = 0;
    for (mirrors.items, 0..) |*m, i| {
        if (!m.active or m.is_self) continue;
        if (m.dock_view != dock) continue;
        if (cnt < 64) {
            out[cnt] = i;
            cnt += 1;
        }
    }
    std.mem.sort(usize, out[0..cnt], mirrors.items.ptr, struct {
        fn lt(ptr: [*]ServerContext.Mirror, a: usize, b: usize) bool {
            return ptr[a].dock_order < ptr[b].dock_order;
        }
    }.lt);
    return cnt;
}

/// Destroy all mirror trees for `row_idx`, then recreate them from
/// `row_sources` (the mirrored copies) plus derived self-mirrors (windows of
/// this row that are mirroed anywhere). Called by `row.switchTo` after the
/// row becomes active, and by `refreshSourceVisibility` on mirror changes.
pub fn activateMirrors(context: *ServerContext, row_idx: usize) void {
    destroyMirrorTrees(context, row_idx);
    // Pre-reserve so the ArrayList never reallocates mid-loop: SubCopy
    // nodes created during feedMirrorTree store a raw pointer to the
    // Mirror struct (sc.owner), which would become a dangling pointer if
    // a later append moved the array.  Firefox is the only client with
    // subsurfaces (and thus SubCopies), making this the crash path.
    context.row_mirrors[row_idx].ensureTotalCapacity(allocator, context.row_sources[row_idx].items.len + context.views.items.len + 4) catch {};
    // SELF mirrors: a window of this row that is mirrored anywhere renders as
    // a mirror at its own slot (the source's real surface is hidden). A
    // scene surface is the ONLY representation proven to render Firefox.
    for (rowViews(context, row_idx)) |view| {
        if (!isTiledCandidate(view)) continue;
        if (!hasAnyMirrors(context, view)) continue;
        if (view.self_mirror_suppressed) continue;
        _ = activateMirror(context, view, row_idx, true);
    }
    // COPY mirrors: explicit mirrors on this row (from row_sources), rendered as
    // manual scene buffers fed each commit.
    for (context.row_sources[row_idx].items) |view| {
        _ = activateMirror(context, view, row_idx, false);
    }
    layoutMirrors(context, row_idx);
}

/// The window list of `row_idx` (active views, or a parked row's views).
fn rowViews(context: *ServerContext, row_idx: usize) []const *View {
    if (row_idx == context.active_row) return context.views.items;
    if (context.rows[row_idx]) |parked| return parked.views.items;
    return &.{};
}

/// True if `view` takes a tiled slot (mapped, non-floating, non-fullscreen).
fn isTiledCandidate(view: *View) bool {
    return view.isMapped() and !view.floating and !view.fullscreen;
}

/// Destroy all mirror trees for `row_idx` (called before deactivation).
pub fn deactivateMirrors(context: *ServerContext, row_idx: usize) void {
    destroyMirrorTrees(context, row_idx);
}

/// Position mirrors in a single row.
///   * Self-mirrors (a window of this row that is mirrored anywhere) sit at the
///     source's own slot; any extra copy of that same window (a same-row mirror)
///     is placed as an adjacent tile right after it - two side-by-side tiles.
///   * Cross-row mirrors (source lives on another row) are appended after the
///     row's windows.
fn layoutRow(context: *ServerContext, target_row: usize) void {
    if (target_row >= ServerContext.max_rows) return;
    const mirrors = &context.row_mirrors[target_row];
    if (mirrors.items.len == 0) return;

    const y: i32 = context.usable_area.y + context.gaps_out;
    const views = rowViews(context, target_row);
    var x: i32 = context.usable_area.x + context.gaps_out;

    // Re-place every mirror from its dock each layout so slot_x/slot_w match
    // the live flow (syncActiveTile animates node positions per frame, but
    // tile ordering, focus anchors, and swaps read slot_x - it must never go
    // stale, or neighbour math picks the wrong tile).
    for (mirrors.items) |*m| {
        if (m.active) m.slot_x = std.math.minInt(i32);
    }

    // Lead copies (docked to no window) sit before the first window.
    var lead_idx: [64]usize = undefined;
    const lead_cnt = sortedDocked(context, mirrors, null, &lead_idx);
    for (lead_idx[0..lead_cnt]) |i| {
        const m = &mirrors.items[i];
        const w = renderedWidth(context, m.view);
        const h: i32 = if (m.view.slot_h > 0) m.view.slot_h else context.usable_area.height - @as(c_int, @intCast(context.gaps_out * 2));
        placeMirror(context, m, x, y, w, h);
        x += w + context.gaps_in;
    }

    // Pass 1: place each window's self-mirror at its slot, then every copy
    // docked to that window as tiles right after it, in dock_order.
    for (views) |view| {
        if (!isTiledCandidate(view)) continue;
        placeWindowCluster(context, mirrors, view);
    }

    // Pass 2: append anything still unplaced (its dock window is not tiled
    // on this row) after the row's true rendered end - the rightmost edge of
    // every placed tile, windows and copies alike.
    var row_end: i32 = context.usable_area.x + context.gaps_out;
    for (views) |view| {
        if (!isTiledCandidate(view)) continue;
        row_end = @max(row_end, view.x + renderedWidth(context, view));
    }
    for (mirrors.items) |*m| {
        if (!m.active or m.is_self or m.slot_x == std.math.minInt(i32)) continue;
        row_end = @max(row_end, m.slot_x + m.slot_w);
    }
    x = row_end + @as(i32, @intCast(context.gaps_in));
    for (mirrors.items) |*m| {
        if (!m.active or m.is_self) continue;
        if (m.slot_x != std.math.minInt(i32)) continue;
        const w = renderedWidth(context, m.view);
        const h: i32 = if (m.view.slot_h > 0) m.view.slot_h else context.usable_area.height - @as(c_int, @intCast(context.gaps_out * 2));
        placeMirror(context, m, x, y, w, h);
        x += w + context.gaps_in;
    }
}

/// Place the self-mirror of `view` at its slot, then every non-self copy
/// docked to `view` (in dock_order) as tiles immediately after it. Unplaced
/// mirrors only, so repeated calls are idempotent.
fn placeWindowCluster(context: *ServerContext, mirrors: *std.ArrayListUnmanaged(ServerContext.Mirror), view: *View) void {
    for (mirrors.items) |*m| {
        if (!m.active or m.slot_x != std.math.minInt(i32)) continue;
        if (m.is_self) {
            // self-mirror: reuse the source's exact tiled slot box.
            placeMirror(context, m, view.x, view.y, view.slot_w, view.slot_h);
            continue;
        }
    }
    var idx: [64]usize = undefined;
    const cnt = sortedDocked(context, mirrors, view, &idx);
    var x: i32 = view.x + ViewManager.getViewWidth(view);
    for (idx[0..cnt]) |i| {
        const m = &mirrors.items[i];
        if (m.slot_x != std.math.minInt(i32)) continue;
        const w = renderedWidth(context, m.view);
        placeMirror(context, m, x, context.usable_area.y + context.gaps_out, w, view.slot_h);
        x += w + context.gaps_in;
    }
}

fn mirrorWidth(context: *ServerContext, src: *View) i32 {
    const vw = ViewManager.getViewWidth(src);
    if (vw > 0) return vw;
    // The ratio scales the usable width (post-waybar), minus both side gaps
    // so ratio 1.0 keeps a gap on either edge.
    const bw_usable = @max(1, context.usable_area.width - @as(i32, @intCast(context.gaps_out * 2)));
    return @as(i32, @intFromFloat(@as(f32, @floatFromInt(bw_usable)) * context.view_width_ratio)) + 2 * @as(i32, @intCast(context.border_width));
}

/// True if `view` is one of the windows of `row`.
fn isViewOfRow(context: *ServerContext, view: *View, row: usize) bool {
    if (row == context.active_row) {
        return std.mem.indexOfScalar(*View, context.views.items, view) != null;
    }
    if (context.rows[row]) |parked| {
        return std.mem.indexOfScalar(*View, parked.views.items, view) != null;
    }
    return false;
}

/// Place a mirror tile at `(x,y)` with a box that sits flush with its
/// neighbours:
///   * self-mirror: rides the source's own slot box (callers pass the view
///     slot). The scene surface renders at natural size and is cropped to the
///     slot's content box, so an oversized/pending-resize surface clips
///     instead of painting over the next window.
///   * copy: box = surface natural size + both borders, the exact footprint
///     the content occupies. No scaling (scene surfaces own their size).
fn placeMirror(context: *ServerContext, m: *ServerContext.Mirror, x: i32, y: i32, slot_w: i32, slot_h: i32) void {
    const src = m.view;
    const bw: i32 = context.border_width;
    // Tile the mirror to the source's CONTENT box (xdg geometry = the CSD
    // cropped surface, e.g. 1090x924 inside a 1130x964 surface). Sizing from
    // current.width gave a tile 20px too big on both axes.
    // Tile to the source surface's OWN size (what the client actually
    // renders into its buffer). xdg geometry can report margins wider than
    // the surface (pre-map), so it is NOT a reliable tile size.
    // Content box = the client's real, non-CSD area. For xdg windows that is
    // the geometry, which for Firefox sits inside a larger surface carrying
    // transparent shadow margins (1130x964 surface, 1090x924 geometry) - sizing
    // from current.width would make the tile ~20px too big on each side. But
    // geometry can report MORE than the surface pre-map, so clamp to the
    // surface: content = min(surface, geometry). Other backends = surface.
    const sw, const sh = xdg: {
        const ss = src.surfaceOrNull() orelse break :xdg .{ 0, 0 };
        if (src.backend == .xdg) {
            const g = src.backend.xdg.base.geometry;
            break :xdg .{ @min(ss.current.width, @max(0, g.width)), @min(ss.current.height, @max(0, g.height)) };
        }
        break :xdg .{ ss.current.width, ss.current.height };
    };
    var box_w: i32 = undefined;
    var box_h: i32 = undefined;
    var content_w: i32 = undefined;
    var content_h: i32 = undefined;
    if (m.is_self) {
        // Self-mirror: ride the source's exact tiled slot.  The source's
        // scene is hidden; the mirror must occupy the SAME box so
        // raiseActiveRow + flow math never paint over a neighbour.
        box_w = slot_w;
        box_h = slot_h;
        content_w = @max(1, slot_w - 2 * bw);
        content_h = @max(1, slot_h - 2 * bw);
    } else {
        // Copy mirror: content-based box (min(surface, geometry) for xdg).
        content_w = if (sw > 0) sw else @max(1, slot_w - 2 * bw);
        content_h = if (sh > 0) sh else @max(1, slot_h - 2 * bw);
        box_w = content_w + 2 * bw;
        box_h = content_h + 2 * bw;
    }
    const first_place = m.slot_x == std.math.minInt(i32);
    m.slot_x = x;
    m.slot_y = y;
    m.slot_w = box_w;
    m.slot_h = box_h;
    m.natural_w = sw;
    m.natural_h = sh;
    const ss2 = src.surfaceOrNull();
    m.surf_w = if (ss2) |ss| ss.current.width else sw;
    m.surf_h = if (ss2) |ss| ss.current.height else sh;
    // Offset by the row's scroll viewport exactly like real windows.
    m.tree.node.setPosition(x - context.viewport_x, y - context.viewport_y);
    if (first_place) {
        var tx: c_int = 0;
        var ty: c_int = 0;
        _ = m.tree.node.coords(&tx, &ty);
    }
    m.tree.node.setEnabled(true);
    // Inset the surface by the border like a real window; crop self-mirrors
    // to the slot content box.
    if (m.buf_node) |bn| {
        bn.node.setPosition(bw, bw);
    }
    // Border ring via the shared view-border renderer, framed on the tile.
    if (m.border_rect) |br| {
        const br_enabled = m.view == context.focused_view;
        Border.updateBorderRect(context, br, content_w, content_h, box_w, box_h, br_enabled, @intCast(@max(0, context.corner_radius - 1)));
    }
}

/// Re-paint every mirror's border ring to match the current focus without
/// repositioning anything. Mirror rings otherwise only update when a mirror is
/// (re)placed or its source commits, so the focused ring would never appear on
/// a focus switch. Called from focus changes alongside layoutMirrorsAll.
pub fn refreshMirrorFocus(context: *ServerContext) void {
    const bw: i32 = context.border_width;
    const anchored = context.kbd_anchor_slot_x >= 0;
    for (0..ServerContext.max_rows) |r| {
        for (context.row_mirrors[r].items) |*m| {
            const br = m.border_rect orelse continue;
            const is_target = m.view == context.focused_view;
            const on_anchor = anchored and
                r == context.kbd_anchor_row and
                m.slot_x == context.kbd_anchor_slot_x;
            const enabled = if (anchored) on_anchor else is_target;
            Border.updateBorderRect(context, br, @max(1, m.slot_w - 2 * bw), @max(1, m.slot_h - 2 * bw), m.slot_w, m.slot_h, enabled, @intCast(@max(0, context.corner_radius - 1)));
        }
    }
}

/// Public per-row entry: layout just `target_row`'s mirrors.
pub fn layoutMirrors(context: *ServerContext, target_row: usize) void {
    layoutRow(context, target_row);
}

/// Layout every row that has mirrors, so mirrors track source-window resizes and
/// layout changes no matter which row is active.
pub fn layoutMirrorsAll(context: *ServerContext) void {
    for (0..ServerContext.max_rows) |row| layoutRow(context, row);
}

/// A mirror hit translated back into source-surface space, plus the mirror
/// that was hit (for scroll/anchor feedback) and its row.
pub const InputTarget = struct {
    surface: *wlroots.Surface,
    sx: f64,
    sy: f64,
    mirror: *ServerContext.Mirror,
    row: usize,
};

/// Translate a pointer/touch hit on one of `view`'s mirrors back into source
/// coordinates. Mirror nodes are plain scene buffers (no wl_surface): resolveAt
/// returns the source view with node-local coords, which callers would feed to
/// the source surface as-is. A hit on a SubCopy node maps 1:1 to that copy's
/// own surface; a hit on the mirror's main buffer maps through the geometry
/// crop into the source surface. Returns null when `node` is not part of any
/// of `view`'s mirrors.
pub fn mirrorInputTarget(
    context: *ServerContext,
    view: *View,
    node: *wlroots.SceneNode,
    sx: f64,
    sy: f64,
) ?InputTarget {
    const bw: i32 = context.border_width;
    for (0..ServerContext.max_rows) |r| {
        for (context.row_mirrors[r].items) |*m| {
            if (!m.active or m.view != view) continue;
            // SubCopy nodes are drawn at their copied surface's own size, so
            // node-local coords are already the surface's coords.
            for (m.sub_copies.items) |sc| {
                if (node == &sc.node.node) {
                    return .{ .surface = sc.src, .sx = sx, .sy = sy, .mirror = m, .row = r };
                }
            }
            var cur: ?*wlroots.SceneNode = node;
            var inside = false;
            while (cur) |n| {
                if (n == &m.tree.node) {
                    inside = true;
                    break;
                }
                cur = if (n.parent) |p| &p.node else null;
            }
            if (!inside) continue;
            // Cursor in tree-local coords, then through the geometry crop.
            var nx: c_int = 0;
            var ny: c_int = 0;
            _ = node.coords(&nx, &ny);
            var tx: c_int = 0;
            var ty: c_int = 0;
            _ = m.tree.node.coords(&tx, &ty);
            const tree_x: f64 = @as(f64, @floatFromInt(nx)) + sx - @as(f64, @floatFromInt(tx));
            const tree_y: f64 = @as(f64, @floatFromInt(ny)) + sy - @as(f64, @floatFromInt(ty));
            const cw: f64 = @floatFromInt(@max(1, m.slot_w - 2 * bw));
            const ch: f64 = @floatFromInt(@max(1, m.slot_h - 2 * bw));
            const surf = m.surf orelse continue;
            const g = switch (view.backend) {
                .xdg => |t| t.base.geometry,
                .xwayland => wlroots.Box{ .x = 0, .y = 0, .width = surf.current.width, .height = surf.current.height },
            };
            if (g.width <= 0 or g.height <= 0 or cw <= 0 or ch <= 0) {
                return .{ .surface = surf, .sx = sx, .sy = sy, .mirror = m, .row = r };
            }
            const bx: f64 = @floatFromInt(bw);
            return .{
                .surface = surf,
                .sx = @as(f64, @floatFromInt(g.x)) + @as(f64, @floatFromInt(g.width)) * (tree_x - bx) / cw,
                .sy = @as(f64, @floatFromInt(g.y)) + @as(f64, @floatFromInt(g.height)) * (tree_y - bx) / ch,
                .mirror = m,
                .row = r,
            };
        }
    }
    return null;
}

// internal helpers -----------------------------------------------------

fn activateMirror(context: *ServerContext, view: *View, row_idx: usize, is_self: bool) ?*ServerContext.Mirror {
    // EVERY mirror is a COPY: a manual scene buffer fed on each commit with
    // the surface's own client buffer + its damage region (the formula
    // wlroots' scene-surface reconfigure uses). The source view's real
    // surface lives in memory (hidden); every tile is an independent fed
    // copy. `is_self` only affects LAYOUT (the self rides the window's own
    // slot, copies flow after) - never the representation.
    const tree = context.views_tree.?.createSceneTree() catch {
        return null;
    };
    const surf = view.surfaceOrNull() orelse {
        tree.node.destroy();
        return null;
    };
    const buf_node = tree.createSceneBuffer(null) catch {
        tree.node.destroy();
        return null;
    };
    buf_node.setDestSize(surf.current.width, surf.current.height);
    buf_node.setTransform(surf.current.transform);
    // Window-style border rect below the buffer, rendered by the same
    // shared `updateBorderRect` that views use.
    const border_rect = tree.createSceneRect(0, 0, &context.focused_border_color) catch null;
    if (border_rect) |br| br.node.placeBelow(&buf_node.node);
    // Route input like the source window: every node in the mirror chain
    // carries the source's NodeData{.view}, so a hit on the buffer node
    // resolves directly to the view - structurally identical to a real
    // window's scene-surface node (which hit-tests as the view with no
    // ancestor walk). The source surface itself lives in memory (hidden).
    tree.node.data = &view.node_data;
    buf_node.node.data = &view.node_data;
    if (border_rect) |br| br.node.data = &view.node_data;

    context.row_mirrors[row_idx].append(allocator, .{
        .view = view,
        .surf = surf,
        .tree = tree,
        .buf_node = buf_node,
        .border_rect = border_rect,
        .active = true,
        .is_self = is_self,
        .slot_x = std.math.minInt(i32),
    }) catch {
        tree.node.destroy();
        return null;
    };
    const appended = &context.row_mirrors[row_idx].items[context.row_mirrors[row_idx].items.len - 1];
    // Feed the copy immediately: the buffer starts NULL, and if the source
    // never commits again after the mirror, the tile would stay blank forever
    // (only a later commit would have pushed a first buffer). The source's
    // current committed buffer is the tile's first frame.
    feedMirrorTree(appended);
    // Default dock: a same-row mirror copy rides right after its own source;
    // a cross-row mirror copy appends after the row's last tiled window
    // (Pass-2 behaviour); lead (null) only when the row has no window.
    if (!is_self) {
        const idx = context.row_mirrors[row_idx].items.len - 1;
        const mr = &context.row_mirrors[row_idx].items[idx];
        var dock: ?*View = null;
        if (isViewOfRow(context, view, row_idx)) {
            dock = view;
        } else {
            for (rowViews(context, row_idx)) |v| {
                if (isTiledCandidate(v)) dock = v;
            }
        }
        mr.dock_view = dock;
        var n: u32 = 0;
        for (context.row_mirrors[row_idx].items[0..idx]) |*o| {
            if (!o.active or o.is_self) continue;
            if (o.dock_view == dock) n += 1;
        }
        mr.dock_order = n;
    }
    // Round the mirrored buffer's corners to match the window.
    if (context.corner_radius > 0) {
        Rounding.setBufferCorners(buf_node, @intCast(@max(0, context.corner_radius - 1)));
    }
    std.log.warn("MIRROR CREATE view={*} row={} self={} surface={*}", .{ view, row_idx, is_self, surf });
    return appended;
}

/// The rendered box width (content + both borders) of `src`'s surface - the
/// actual pixel width its tile must occupy. Single authority for copy-mirror
/// placement and flow so mirrored tiles can never leak over neighbours.
fn renderedWidth(context: *ServerContext, src: *View) i32 {
    const bw: i32 = context.border_width;
    if (src.surfaceOrNull()) |ss| {
        if (ss.current.width > 0) {
            const w = if (src.backend == .xdg)
                @min(ss.current.width, @max(0, src.backend.xdg.base.geometry.width))
            else
                ss.current.width;
            return @as(i32, @intCast(@max(1, w))) + 2 * bw;
        }
    }
    return mirrorWidth(context, src);
}

/// The total extra width a window's same-row mirror COPY tiles add to the row
/// flow, so the tiler shifts following windows right to make room (the
/// self-mirror rides the window's own slot, so it adds nothing).
pub fn extraTilesWidth(context: *ServerContext, view: *View) i32 {
    var w: i32 = 0;
    if (context.active_row >= ServerContext.max_rows) return w;
    for (context.row_mirrors[context.active_row].items) |*m| {
        if (!m.active or m.is_self) continue; // self-mirror rides the slot
        if (m.dock_view != view) continue; // only copies docked after this window
        w += renderedWidth(context, m.view) + context.gaps_in;
    }
    return w;
}

/// Total width lead copies (docked to no window) push the active row's first
/// window right by.
///
/// Also includes the active row's `head_gap`: a mirror collapse that surfaced
/// the real window at its last mirror tile's position left the source's home
/// slot open, and this is every slot flow's single choke point (positions,
/// drag reordering, animation), so the gap is honored everywhere for free.
pub fn leadWidth(context: *ServerContext) i32 {
    var w: i32 = 0;
    if (context.active_row >= ServerContext.max_rows) return w;
    for (context.row_mirrors[context.active_row].items) |*m| {
        if (!m.active or m.is_self) continue;
        if (m.dock_view == null) w += renderedWidth(context, m.view) + context.gaps_in;
    }
    return w + context.head_gap;
}

/// Re-dock copy `m` to the head of window `w`'s cluster (immediately after
/// the window), renumbering the cluster to make room. Swapped in by the
/// tile-swap "copy | window" case.
pub fn dockCopyAsHead(context: *ServerContext, row_idx: usize, m: *ServerContext.Mirror, w: *View) void {
    for (context.row_mirrors[row_idx].items) |*o| {
        if (o != m and o.active and !o.is_self and o.dock_view == w) o.dock_order += 1;
    }
    m.dock_view = w;
    m.dock_order = 0;
}

/// Re-dock copy `m` to the tail of `dock`'s cluster (docked immediately
/// before the next tile), or the row lead when `dock` is null. Swapped in by
/// the tile-swap "window | copy" case.
pub fn dockCopyAsTail(context: *ServerContext, row_idx: usize, m: *ServerContext.Mirror, dock: ?*View) void {
    var n: u32 = 0;
    for (context.row_mirrors[row_idx].items) |*o| {
        if (o == m or !o.active or o.is_self) continue;
        if (o.dock_view == dock) n += 1;
    }
    m.dock_view = dock;
    m.dock_order = n;
}

/// Exact dock exchange for two adjacent copies: each takes the other's
/// (dock, order) pair, which is precisely a position exchange.
pub fn swapCopyDocks(a: *ServerContext.Mirror, b: *ServerContext.Mirror) void {
    std.mem.swap(?*View, &a.dock_view, &b.dock_view);
    std.mem.swap(u32, &a.dock_order, &b.dock_order);
}

/// Raise every mirror on the ACTIVE row to the top of the views tree, so
/// windows (which get re-raised on focus) can't paint over the mirrors.
pub fn raiseActiveRow(context: *ServerContext) void {
    const mirrors = &context.row_mirrors[context.active_row];
    for (mirrors.items) |*m| {
        if (m.active) m.tree.node.raiseToTop();
    }
}

fn destroyMirrorTrees(context: *ServerContext, row_idx: usize) void {
    for (context.row_mirrors[row_idx].items) |*m| {
        tearDownMirror(m);
        m.tree.node.destroy();
    }
    context.row_mirrors[row_idx].clearRetainingCapacity();
}

fn findMirrors(context: *ServerContext, view: *View, row: usize) ?usize {
    if (row >= ServerContext.max_rows) return null;
    for (context.row_sources[row].items, 0..) |v, i| {
        if (v == view) return i;
    }
    return null;
}

fn findMirror(context: *ServerContext, view: *View, row: usize) ?usize {
    if (row >= ServerContext.max_rows) return null;
    for (context.row_mirrors[row].items, 0..) |m, i| {
        if (m.view == view) return i;
    }
    return null;
}
