const std = @import("std");
const wlroots = @import("wlroots");
const View = @import("view.zig");
const ServerContext = @import("../server.zig");
const Rounding = @import("rounding.zig");
const Config = @import("../config.zig");

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

/// Solid strips used to fake a gradient ring (scenefx rects are
/// solid-only). Lazily created as children of view.scene_tree below the
/// surface; empty for solid rings. The scene nodes die with the tree;
/// the backing slice is freed in `deinit`.
strips: std.ArrayListUnmanaged(*wlroots.SceneRect) = .empty,

/// Slice a gradient ring into this many solid strips. More strips =
/// smoother gradients, more scene rects per view.
pub const num_strips: usize = 32;

pub fn deinit(self: *Border) void {
    self.strips.deinit(std.heap.c_allocator);
}

fn disableStrips(self: *Border) void {
    for (self.strips.items) |strip| strip.node.setEnabled(false);
}

fn disableAll(self: *Border) void {
    self.rect.node.setEnabled(false);
    self.disableStrips();
}

fn ensureStrips(self: *Border, view: *View, n: usize) void {
    if (self.strips.items.len >= n) return;
    const a = std.heap.c_allocator;
    self.strips.ensureTotalCapacity(a, n) catch return;
    while (self.strips.items.len < n) {
        const strip = view.scene_tree.createSceneRect(0, 0, &[4]f32{ 1, 1, 1, 1 }) catch {
            self.strips.clearAndFree(a);
            return;
        };
        strip.node.data = &view.node_data;
        strip.node.setEnabled(false);
        self.strips.appendAssumeCapacity(strip);
    }
}

pub fn createViewBorder(view: *View) void {
    const context = view.context; // The rect lives INSIDE the view tree, below the surface, so it
    // moves and scrolls with the window; sibling order keeps the client
    // and any popups/sub-surfaces above it (and above its input region).
    const color = view.borderColor(context.focused_view == view);
    const color_sample = color.sample(0.5);
    view.border_color_now = color_sample;
    view.border_color_from = color_sample;
    view.border_color_target = color_sample;
    switch (color) {
        .gradient => |g| {
            view.border_grad_from = g;
            view.border_grad_target = g;
        },
        else => {},
    }
    const rect = view.scene_tree.createSceneRect(0, 0, &color_sample) catch return;
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
        border.disableAll();
        return;
    }

    // Override-redirect windows (Steam menus) get no border ring.
    if (view.isOrWindow()) {
        border.disableAll();
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
        border.disableAll();
        return;
    }

    const width = surface.current.width;
    const height = surface.current.height;

    const widths = view.borderWidths();

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
                @as(c_int, @intCast(widths.left)) - xdg_geom.x,
                @as(c_int, @intCast(widths.top)) - xdg_geom.y,
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
    // Every mapped window draws a ring; focus only selects the color
    // (active vs inactive), so the ring survives focus switches.
    const enabled = view.slot_w > 0 and view.slot_h > 0;
    const ring_color = view.borderColor(context.focused_view == view);
    // Pulse breathes only the focused ring's brightness.
    const dim: f32 = if (context.pulse_enabled and context.focused_view == view) context.pulse_dim else 1.0;

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

    const inner_r: u16 = if (r > 0) r -| 1 else 0;
    switch (ring_color) {
        .solid => |c| {
            border.disableStrips();
            updateBorderRect(rect, content_w, content_h, ring_w, ring_h, enabled, inner_r, c, widths, dim);
        },
        .gradient => |g| updateGradientBorder(view, border, g, content_w, content_h, ring_w, ring_h, enabled, inner_r, widths, dim),
    }
}

/// Draw a gradient ring by slicing the slot into thin solid strips, each
/// clipped to the same ring shape (interior carved out) and colored by
/// sampling the gradient at the strip's center projected onto the
/// gradient axis. scenefx rects are solid-only, so a gradient is faked
/// from N solid quads.
fn updateGradientBorder(
    view: *View,
    border: *Border,
    g: Config.Gradient,
    content_w: i32,
    content_h: i32,
    slot_w: i32,
    slot_h: i32,
    enabled: bool,
    inner_r: u16,
    widths: Config.BorderWidths,
    dim: f32,
) void {
    border.rect.node.setEnabled(false);
    if (!enabled or slot_w <= 0 or slot_h <= 0) {
        border.disableStrips();
        return;
    }
    border.ensureStrips(view, Border.num_strips);
    if (border.strips.items.len == 0) return;
    const strips = border.strips.items;

    const rad = g.angle * std.math.pi / 180.0;
    const ca = @cos(rad);
    const sa = @sin(rad);
    // Slice perpendicular to the dominant gradient axis: horizontal-ish
    // (angle ~0/180) -> vertical columns; vertical-ish (angle ~90/270)
    // -> horizontal rows. Strip colors are then sampled correctly for
    // any angle by projecting onto the gradient axis.
    const columns = @abs(sa) <= @abs(ca);
    const span: i32 = if (columns) slot_w else slot_h;
    // Ceiling so the strips tile the whole span: floor(span / n) strips of
    // width floor(span / n) miss the remainder pixels at the far edge
    // (e.g. 32×3px = 96 vs a 100px slot), which showed as the ring
    // cutting off on the bottom/right.
    const step_i: i32 = @max(1, @divTrunc(span + @as(i32, @intCast(Border.num_strips)) - 1, @as(i32, @intCast(Border.num_strips))));
    const n_used: usize = @min(Border.num_strips, @as(usize, @intCast(@divTrunc(span + step_i - 1, step_i))));

    const r: u16 = @intCast(@max(0, inner_r));

    for (strips, 0..) |strip, i| {
        if (i >= n_used) {
            strip.node.setEnabled(false);
            continue;
        }
        const start: i32 = @as(i32, @intCast(i)) * step_i;
        const size: i32 = @min(step_i, span - start);
        if (columns) {
            strip.setSize(size, slot_h);
            strip.node.setPosition(start, 0);
        } else {
            strip.setSize(slot_w, size);
            strip.node.setPosition(0, start);
        }

        // Sample at the strip center, projected onto the gradient axis
        // and normalized over the slot's projection range.
        const ccx: f32 = if (columns)
            @as(f32, @floatFromInt(start)) + @as(f32, @floatFromInt(size)) / 2.0
        else
            @as(f32, @floatFromInt(slot_w)) / 2.0;
        const ccy: f32 = if (columns)
            @as(f32, @floatFromInt(slot_h)) / 2.0
        else
            @as(f32, @floatFromInt(start)) + @as(f32, @floatFromInt(size)) / 2.0;
        var col = g.sample(gradientT(g, ccx, ccy, slot_w, slot_h));
        if (dim < 1.0) {
            col[0] *= dim;
            col[1] *= dim;
            col[2] *= dim;
        }
        strip.setColor(&col);

        // Interior clip in strip-local coords: content sits at (bw,bw)
        // in slot coords, shifted by the strip start.
        var clip_box: wlroots.Box = if (columns)
            .{ .x = widths.left - start, .y = widths.top, .width = content_w, .height = content_h }
        else
            .{ .x = widths.left, .y = widths.top - start, .width = content_w, .height = content_h };
        if (clip_box.width <= 0 or clip_box.height <= 0) {
            clip_box = if (columns)
                .{ .x = widths.left - start, .y = widths.top, .width = slot_w - widths.horizontal(), .height = slot_h - widths.vertical() }
            else
                .{ .x = widths.left, .y = widths.top - start, .width = slot_w - widths.horizontal(), .height = slot_h - widths.vertical() };
        }

        // Outer corner radii live on the end strips (the strip that
        // touches each slot corner); inner clip radii on the strips that
        // contain each content-box corner.
        var outer = Rounding.CornerRadii{ .top_left = 0, .top_right = 0, .bottom_right = 0, .bottom_left = 0 };
        var inner = outer;
        const left_own = i == 0 and start == 0;
        const right_own = i == n_used - 1 and start + size >= span;
        if (columns) {
            if (left_own) {
                outer.top_left = cornerR(inner_r, widths.left, widths.top);
                outer.bottom_left = cornerR(inner_r, widths.left, widths.bottom);
                if (widths.left >= start and widths.left < start + size) {
                    inner.top_left = r;
                    inner.bottom_left = r;
                }
            }
            if (right_own) {
                outer.top_right = cornerR(inner_r, widths.right, widths.top);
                outer.bottom_right = cornerR(inner_r, widths.right, widths.bottom);
                if (widths.left + content_w >= start and widths.left + content_w < start + size) {
                    inner.top_right = r;
                    inner.bottom_right = r;
                }
            }
        } else {
            if (left_own) {
                outer.top_left = cornerR(inner_r, widths.left, widths.top);
                outer.top_right = cornerR(inner_r, widths.right, widths.top);
                if (widths.top >= start and widths.top < start + size) {
                    inner.top_left = r;
                    inner.top_right = r;
                }
            }
            if (right_own) {
                outer.bottom_left = cornerR(inner_r, widths.left, widths.bottom);
                outer.bottom_right = cornerR(inner_r, widths.right, widths.bottom);
                if (widths.top + content_h >= start and widths.top + content_h < start + size) {
                    inner.bottom_left = r;
                    inner.bottom_right = r;
                }
            }
        }
        Rounding.setRectCornersRadii(strip, outer);
        if (clip_box.width > 0 and clip_box.height > 0) {
            Rounding.setRectClipRadii(strip, clip_box, inner);
        }
        // Re-place below the surface every update (the surface tree only
        // appears on the client's first commit).
        if (surfaceNode(view)) |node| strip.node.placeBelow(node);
        strip.node.setEnabled(true);
    }
}

/// Focus-switch chase for gradient rings: re-tint the EXISTING strips
/// (geometry already laid out by the last updateGradientBorder) so the
/// ring eases from `from` toward `to`. `e` is the chase progress in
/// [0,1]. Only colors change; strips keep their positions/sizes.
pub fn tintGradientChase(strips: []*wlroots.SceneRect, from: Config.Gradient, to: Config.Gradient, e: f32) void {
    if (from.colors.len < 2 or to.colors.len < 2) return;
    const n = @min(strips.len, Border.num_strips);
    // Re-sync each enabled strip to the lerped color. Half the strips
    // may be disabled (unused tail); leave them.
    for (strips, 0..) |strip, i| {
        if (i >= n) break;
        if (!strip.node.enabled) continue;
        // Sample both gradients at the strip's own center. Getting the
        // exact center would need the slot geometry again; sampling at
        // the strip's index across the gradient's stop range is close
        // enough for a 100-200ms color blend.
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(1, n - 1)));
        const fav: @Vector(4, f32) = from.sample(t);
        const tav: @Vector(4, f32) = to.sample(t);
        const col: [4]f32 = fav + (tav - fav) * @as(@Vector(4, f32), @splat(e));
        strip.setColor(&col);
    }
}

/// Normalized position t in [0,1] of point (cx,cy) along the gradient
/// direction, computed by projecting the slot's corner projections.
fn gradientT(g: Config.Gradient, cx: f32, cy: f32, slot_w: i32, slot_h: i32) f32 {
    const rad = g.angle * std.math.pi / 180.0;
    const ca = @cos(rad);
    const sa = @sin(rad);
    var pmin: f32 = std.math.floatMax(f32);
    var pmax: f32 = -std.math.floatMax(f32);
    const corners = [_][2]f32{
        .{ 0, 0 },
        .{ @floatFromInt(slot_w), 0 },
        .{ 0, @floatFromInt(slot_h) },
        .{ @floatFromInt(slot_w), @floatFromInt(slot_h) },
    };
    for (corners) |pt| {
        const p = pt[0] * ca + pt[1] * sa;
        pmin = @min(pmin, p);
        pmax = @max(pmax, p);
    }
    if (pmax <= pmin) return 0.5;
    const p = cx * ca + cy * sa;
    return (p - pmin) / (pmax - pmin);
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
    widths: Config.BorderWidths,
    dim: f32,
) void {
    if (!enabled or slot_w <= 0 or slot_h <= 0) {
        rect.node.setEnabled(false);
        return;
    }

    var tinted = color;
    if (dim < 1.0) {
        tinted[0] *= dim;
        tinted[1] *= dim;
        tinted[2] *= dim;
    }
    rect.setColor(&tinted);
    rect.setSize(slot_w, slot_h);
    rect.node.setPosition(0, 0);

    // Per-corner outer radii so an asymmetric ring rounds each corner by
    // its own side widths.
    Rounding.setRectCornersRadii(rect, .{
        .top_left = cornerR(inner_r, widths.left, widths.top),
        .top_right = cornerR(inner_r, widths.right, widths.top),
        .bottom_right = cornerR(inner_r, widths.right, widths.bottom),
        .bottom_left = cornerR(inner_r, widths.left, widths.bottom),
    });

    // Rect-local coords: content always sits at (left,top) by construction.
    var clip_box: wlroots.Box = .{ .x = widths.left, .y = widths.top, .width = content_w, .height = content_h };
    if (clip_box.width <= 0 or clip_box.height <= 0) {
        clip_box = .{ .x = widths.left, .y = widths.top, .width = slot_w - widths.horizontal(), .height = slot_h - widths.vertical() };
    }
    Rounding.setRectClip(rect, clip_box, inner_r);

    rect.node.setEnabled(true);
}

/// The outer ring radius at a corner: the inner clip radius plus the
/// border band where it rounds the corner (the larger of the two sides
/// meeting there).
fn cornerR(inner_r: u16, a: i32, b: i32) u16 {
    const r: u16 = @intCast(@max(0, inner_r));
    if (r == 0) return 0;
    const side: u16 = @intCast(@max(0, @max(a, b)));
    return (r -| 1) + side;
}
