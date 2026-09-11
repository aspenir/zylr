const std = @import("std");
const wlroots = @import("wlroots");
const View = @import("view.zig");
const ServerContext = @import("../server.zig");
const Rounding = @import("rounding.zig");

/// Border rendering; the window's own surface
/// is rounded (its corner pixels are transparent), and a single
/// full-box scene rect with matching rounded corners sits BELOW it,
/// tinted with the border color. Beyond the rect's outline the corners
/// are transparent too, so the wallpaper behind the views tree shows
/// through naturally. Nothing is baked, no corner textures, no state to
/// go stale.
const Border = @This();

/// The rounded full-box rect under the window surface (in view-local
/// coordinates: -bw..w+bw). Disabled when unfocused.
rect: *wlroots.SceneRect,

pub fn createViewBorder(view: *View) void {
    const context = view.context;    // The rect lives INSIDE the view tree, below the surface, so it
    // moves and scrolls with the window; sibling order keeps the client
    // and any popups/sub-surfaces above it (and above its input region).
    const color = view.borderColor();
    const rect = view.scene_tree.createSceneRect(0, 0, &color) catch return;
    rect.node.data = &view.node_data;

    const border: Border = .{ .rect = rect };
    if (surfaceNode(view)) |n| {
        border.rect.node.placeBelow(n);
    }
    rect.node.setEnabled(false);

    view.border = border;
    updateBorders(context);
}

/// The client's scene surface lives in a child "subsurface" tree node
/// (wlr_scene_surface_create nests the buffer inside one). Returns that
/// tree node - the direct sibling the border rect must sit below. Null
/// for XWayland views until the surface associates.
fn findSurfaceTree(view: *View) ?*wlroots.SceneTree {
    var it = view.scene_tree.children.iterator(.forward);
    while (it.next()) |node| {
        if (node.type == .tree) return wlroots.SceneTree.fromNode(node);
    }
    return null;
}

/// The scene node holding the client's content - the direct sibling
/// the border rect must sit below. Both backends keep the content in a
/// child tree of the view tree: XDG via wlr_scene_xdg_surface_create
/// (findSurfaceTree), XWayland via the wrapper tree created on
/// associate.
fn surfaceNode(view: *View) ?*wlroots.SceneNode {
    return switch (view.backend) {
        .xdg => if (findSurfaceTree(view)) |t| &t.node else null,
        .xwayland => if (view.surface_tree) |t| &t.node else null,
    };
}

/// round every buffer in the view tree
/// (wlr_scene_node_for_each_buffer). Covers both XDG, which nests the
/// buffer in the xdg scene tree, and XWayland, which attaches it
/// directly to the view tree. Re-run every update so a buffer that
/// appears (or re-attaches) later gets rounded too.
pub fn clearAllBufferCorners(view: *View) void {
    var dummy: u16 = 0;
    view.scene_tree.node.forEachBuffer(
        *u16,
        struct {
            fn cb(buffer: *wlroots.SceneBuffer, sx: c_int, sy: c_int, data: *u16) void {
                _ = sx;
                _ = sy;
                _ = data;
                Rounding.clearBufferCorners(buffer);
            }
        }.cb,
        &dummy,
    );
}

pub fn roundAllBuffers(view: *View, radius: u16) void {
    var r = radius;
    view.scene_tree.node.forEachBuffer(
        *u16,
        struct {
            fn cb(buffer: *wlroots.SceneBuffer, sx: c_int, sy: c_int, data: *u16) void {
                _ = sx;
                _ = sy;
                Rounding.setBufferCorners(buffer, data.*);
            }
        }.cb,
        &r,
    );
}

pub fn updateBorders(context: *ServerContext) void {
    // Only update the previously and newly focused views — the rest
    // don't change border color or position on a focus switch.
    if (context.previous_focused_view) |prev| {
        Border.updateViewBorder(prev, @floatFromInt(prev.x), null);
    }
    if (context.focused_view) |view| {
        Border.updateViewBorder(view, @floatFromInt(view.x), null);
    }
}

/// Re-apply border width, corner radius, and color to every mapped view.
/// Clears stale rounded corners first so lowering rounding to 0 takes full
/// effect; updateViewBorder re-rounds when rounding is back above 0.
pub fn applyConfig(context: *ServerContext) void {
    for (context.views.items) |view| {
        clearAllBufferCorners(view);
        updateViewBorder(view, @floatFromInt(view.x), null);
    }
}

pub fn updateViewBorder(view: *View, anim_x: f32, anim_w: ?f32) void {
    _ = anim_x;
    const border: *Border = if (view.border) |*b| b else return;
    const context = view.context;

    // Fullscreen views have no border.
    if (view.fullscreen) {
        border.rect.node.setEnabled(false);
        return;
    }

    // Override-redirect windows (Steam menus) get no border ring.
    if (view.isOrWindow()) {
        border.rect.node.setEnabled(false);
        return;
    }

    // A view can be mid-animation before its surface is mapped (XWayland
    // views in particular), in which case there's no size to draw around.
    const surface = view.surfaceOrNull() orelse return;

    // An unmapped window (or one with no buffer yet) must not touch the
    // scene: its surface tree may be gone — Steam destroys and recreates
    // its content window during the loading→main transition and MOTIF
    // decoration signals can fire while it is dying — and scenefx asserts
    // on re-parenting in that state (node != sibling).
    if (!view.isMapped() or surface.current.width <= 0 or surface.current.height <= 0) {
        border.rect.node.setEnabled(false);
        return;
    }

    const width = surface.current.width;
    const height = surface.current.height;

    const bw = view.borderWidth();

    // XDG: a non-zero geometry offset means the client renders its own
    // frame (GTK shadow margins) inside the buffer. wlroots pins the
    // buffer at +geometry inside the scene tree, so placing the tree at
    // (bw - g.x, bw - g.y) lands the visible content exactly at the
    // slot's inner edge; the shadow margins overflow and get cropped by
    // the subtree clip below. The ring is drawn for every client
    const xdg_geom = switch (view.backend) {
        .xdg => |t| t.base.geometry,
        else => wlroots.Box{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };

    // Corner radius applied unclamped (scenefx's
    // rounded-rect SDF handles tiny windows), the border's outer arc
    // carries the border width on top, and the surface edge is pulled
    // 1px inside the border so the two antialiased edges don't leave a
    // fringe between them. Rounding 0 leaves the border square.
    const r: u16 = @intCast(@max(0, view.cornerRadius()));

    if (r > 0) roundAllBuffers(view, r -| 1);
    // Re-do the sibling order here too: the surface tree only appears
    // on the client's first commit, so the rect must be pushed below it
    // each time we're (re)placing.
    if (surfaceNode(view)) |node| {
        // the surface sits inset by the border width inside
        // the slot, so the ring (above) can fill the slot instead of
        // spilling into the neighbour. Client-drawn frames keep the
        // wlroots -geometry pin so their content stays at the slot
        // origin (their ring is dropped entirely). XWayland's commitSurface
        // insets its buffer node.
        const pos: [2]c_int = switch (view.backend) {
            .xdg => .{
                @as(c_int, @intCast(bw)) - xdg_geom.x,
                @as(c_int, @intCast(bw)) - xdg_geom.y,
            },
            else => .{ 0, 0 },
        };
        switch (view.backend) {
            .xdg => {
                node.setPosition(pos[0], pos[1]);
                // Crop the client's shadow margins so the oversized
                // buffer cannot spill over the ring band or the
                // neighbouring slot. The clip is in tree-local coords,
                // where wlroots pins the buffer at +geometry.
                // Only clip while the view is mapped: subsurfaceTreeSetClip
                // ASSERTS if the node's subtree contains no subsurface tree,
                // which can transiently be the case for CSD clients churning
                // their surfaces on unfloat/quit. Mapped guarantees the
                // subsurface tree exists.
                if (view.isMapped() and xdg_geom.width > 0 and xdg_geom.height > 0) {
                    const crop: wlroots.Box = .{
                        .x = xdg_geom.x,
                        .y = xdg_geom.y,
                        .width = xdg_geom.width,
                        .height = xdg_geom.height,
                    };
                    node.subsurfaceTreeSetClip(&crop);
                }
            },
            else => {},
        }
        // The ring must stay BELOW the surface: a scene rect hit-tests
        // its whole box (the clip only shapes rendering), so a ring
        // above the window would swallow every pointer event aimed at
        // the client. CSD detection (above) drops the ring entirely for
        // clients whose own frame would cover it.
        border.rect.node.placeBelow(node);
    }

    const rect = border.rect;
    const enabled =
        context.focused_view == view and view.slot_w > 0 and view.slot_h > 0;

    // the ring is the slot the window content is inset into,
    // so the band is uniform on all four sides and can never cross into
    // the neighbouring window. Client-drawn frames returned above.
    // When an animated width is provided (grow/shrink), use it instead
    // of the committed slot width so the border tracks the layout.
    const ring_w: i32 = if (anim_w) |w| @intFromFloat(@round(w)) else view.slot_w;
    const ring_h: i32 = view.slot_h;

    // Pixel/geometry box of the actual content (the part the ring wraps
    // around once its interior is clipped out). XDG uses the client's
    // frame geometry; others use the surface box.
    const content_w: i32 = switch (view.backend) {
        .xdg => |t| t.base.geometry.width,
        else => width,
    };
    const content_h: i32 = switch (view.backend) {
        .xdg => |t| t.base.geometry.height,
        else => height,
    };

    updateBorderRect(rect, content_w, content_h, ring_w, ring_h, enabled, if (r > 0) r -| 1 else 0, view.borderColor(), view.borderWidth());
}

/// Draw the shared ring for a border rect: a full box with
/// its interior clipped out, leaving a uniform `border_width` band around
/// the content, with the window's rounded corners. Shared by real views
/// (`updateViewBorder`) and mirrors so both render identically.
///
///   slot_w × slot_h  — the full box the band occupies (0,0 origin).
///   content_w × content_h — the box the interior is clipped to (it sits
///                           inset by `border_width` in the rect's local
///                           coords).
pub fn updateBorderRect(
    rect: *wlroots.SceneRect,
    content_w: i32,
    content_h: i32,
    slot_w: i32,
    slot_h: i32,
    enabled: bool,
    inner_r: u16,
    color: [4]f32,
    bw: i32,
) void {
    if (!enabled or slot_w <= 0 or slot_h <= 0) {
        rect.node.setEnabled(false);
        return;
    }

    const r: u16 = @intCast(@max(0, inner_r));

    rect.setColor(&color);
    rect.setSize(slot_w, slot_h);
    rect.node.setPosition(0, 0);

    const outer_r: u16 = if (r > 0) (r -| 1) + @as(u16, @intCast(@max(0, bw))) else 0;
    Rounding.setRectCorners(rect, outer_r);

    // Rect-local coords: content always sits at (bw,bw) by construction.
    var clip_box: wlroots.Box = .{ .x = bw, .y = bw, .width = content_w, .height = content_h };
    if (clip_box.width <= 0 or clip_box.height <= 0) {
        clip_box = .{ .x = bw, .y = bw, .width = slot_w - 2 * bw, .height = slot_h - 2 * bw };
    }
    Rounding.setRectClip(rect, clip_box, inner_r);

    rect.node.setEnabled(true);
}
