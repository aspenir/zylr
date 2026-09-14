const std = @import("std");
const ServerContext = @import("../server.zig");
const Border = @import("border.zig");
const ViewManager = @import("view_manager.zig");
const Row = @import("../row.zig");
const Mirror = @import("../mirror.zig");
const wlroots = @import("wlroots");

/// Length of a row-switch slide/fade in ms.
const row_transition_ms: u64 = 220;

/// Length of a window's open fade-in / close fade-out in ms.
const fade_duration_ms: u64 = 180;

/// Set the opacity of every scene buffer under `node` (a window's or mirror
/// tree) to `opacity` (0..1). Borders are scene rects, not buffers, and are
/// deliberately left alone.
pub fn setTreeOpacity(node: *wlroots.SceneNode, opacity: f32) void {
    var value: f32 = opacity;
    node.forEachBuffer(*f32, setBufferOpacity, &value);
}

fn setBufferOpacity(buffer: *wlroots.SceneBuffer, sx: c_int, sy: c_int, data: *f32) void {
    _ = sx;
    _ = sy;
    buffer.setOpacity(data.*);
}

pub fn wake(context: *ServerContext) void {
    // A wake means an animation was just (re)armed: force the tick out of
    // its early return, or a fade started against a stable layout never
    // runs and the close request it ends with never fires.
    context.animation_active = true;
    if (context.animation_timer) |timer| {
        timer.timerUpdate(16) catch {};
    }
}

pub fn onTimerTick(context: *ServerContext) c_int {
    tick(context);

    if (context.output) |output| output.scheduleFrame();

    if (context.animation_active) {
        if (context.animation_timer) |timer| {
            timer.timerUpdate(16) catch {};
        }
    }
    return 1;
}

pub fn tick(context: *ServerContext) void {
    // Pulse keeps the timer alive on its own: when nothing else animates,
    // allow the idle tick through so the focused ring still breathes.
    if (!context.pulse_enabled and !context.animation_active) return;
    if (context.pulse_enabled) context.animation_active = true;

    var still_animating = false;

    // Window open fade-in / close fade-out. Runs before the row block so
    // an active slide keeps its own opacity.
    const now = context.nowMs();
    for (context.views.items) |view| {
        if (view.fading_in) {
            const elapsed = now - view.fade_started;
            if (elapsed >= fade_duration_ms) {
                view.fading_in = false;
                setTreeOpacity(&view.scene_tree.node, 1.0);
            } else {
                const p = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(fade_duration_ms));
                const smooth = p * p * (3.0 - 2.0 * p); // smoothstep
                setTreeOpacity(&view.scene_tree.node, smooth);
                still_animating = true;
            }
        } else if (view.fading_out) {
            const elapsed = now - view.fade_out_started;
            if (elapsed >= fade_duration_ms) {
                view.fading_out = false;
                view.doClose();
            } else {
                const p = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(fade_duration_ms));
                const smooth = p * p * (3.0 - 2.0 * p); // smoothstep
                setTreeOpacity(&view.scene_tree.node, 1.0 - smooth);
                still_animating = true;
            }
        }
    }

    // Row-switch slide: the outgoing row (parked but still rendered) slides
    // out and fades while the incoming row slides in over it.
    var slide_off: f32 = 0; // incoming y offset from the slide
    var fade: f32 = 1; // incoming opacity
    if (context.row_anim) |t| {
        const elapsed = context.nowMs() - t.started;
        if (elapsed >= row_transition_ms) {
            // Slide complete: retire the outgoing row, restore full
            // opacity, then centre the viewport on the focused window.
            Row.settleTransition(context);
            if (context.focused_view) |fv| ViewManager.scrollToView(context, fv);
        } else {
            const p = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(row_transition_ms));
            const smooth = p * p * (3.0 - 2.0 * p); // smoothstep
            const dir: f32 = @floatFromInt(t.dir);
            // Both rows translate the same way (a rigid scroll): the
            // incoming row enters from the switch direction while the
            // outgoing one exits past the opposite edge.
            const outgoing_off: c_int = @intFromFloat(@round(-t.slide * smooth * dir));
            if (context.rows[t.from_row]) |parked| {
                for (parked.views.items) |v| {
                    v.scene_tree.node.setPosition(
                        v.x - parked.scroll_x,
                        v.y - context.viewport_y + outgoing_off,
                    );
                    setTreeOpacity(&v.scene_tree.node, 1.0 - smooth);
                }
            }
            slide_off = t.slide * (1.0 - smooth) * dir;
            fade = smooth;
            still_animating = true;
        }
    }

    // Animate the viewport scroll offset.
    const target_vp: f32 = @floatFromInt(context.viewport_target);
    var vcur = context.viewport_anim;
    if (@abs(target_vp - vcur) < 0.5) {
        if (context.viewport_x != context.viewport_target and context.viewport_target > 0)
            std.log.warn("SCROLL SETTLED vp={} target={}", .{ context.viewport_target, context.viewport_target });
        vcur = target_vp;
        context.viewport_x = context.viewport_target;
    } else {
        vcur += (target_vp - vcur) * 0.20;
        context.viewport_x = @intFromFloat(@round(vcur));
        still_animating = true;
    }
    context.viewport_anim = vcur;

    const n = @min(@min(context.views.items.len, context.animation_w.items.len), 64);
    const w_items = context.animation_w.items;
    var targets: [64]f32 = undefined;
    for (context.views.items, 0..) |view, i| {
        if (i >= 64) break;
        // Unmapped/floating/fullscreen views don't take a slot; pin their
        // target to the current width so they can't spin the animation.
        targets[i] = if (view.isMapped() and !view.floating and !view.fullscreen)
            @floatFromInt(ViewManager.tiledWidth(context, view))
        else
            w_items[i];
    }

    const VecLen = std.simd.suggestVectorLength(f32) orelse 4;
    const Vec = @Vector(VecLen, f32);
    var w_moving: [64]bool = undefined;
    var wi: usize = 0;

    while (wi + VecLen <= n) : (wi += VecLen) {
        const cur: Vec = w_items[wi..][0..VecLen].*;
        const tgt: Vec = targets[wi..][0..VecLen].*;
        const diff = tgt - cur;
        const close: @Vector(VecLen, bool) = @abs(diff) < @as(Vec, @splat(0.5));
        const lerped = cur + diff * @as(Vec, @splat(0.20));
        w_items[wi..][0..VecLen].* = @select(f32, close, tgt, lerped);
        if (!@reduce(.And, close)) still_animating = true;
        comptime var j: usize = 0;
        inline while (j < VecLen) : (j += 1) {
            w_moving[wi + j] = !close[j];
        }
    }
    // Scalar tail for remaining elements.
    while (wi < n) : (wi += 1) {
        const target_w = targets[wi];
        var cur_w = w_items[wi];
        if (@abs(target_w - cur_w) < 0.5) {
            cur_w = target_w;
            w_moving[wi] = false;
        } else {
            cur_w += (target_w - cur_w) * 0.20;
            still_animating = true;
            w_moving[wi] = true;
        }
        w_items[wi] = cur_w;
    }

    // Animate the vertical offset: pile share changes slide members to
    // their new slot tops instead of jumping. Floating/fullscreen views
    // set their own y; pin them so the array can't lag their direct moves.
    for (context.views.items, 0..) |view, i| {
        if (i >= context.animation_y.items.len) break;
        const target_y: f32 = @floatFromInt(view.y);
        if (view.isMapped() and !view.floating and !view.fullscreen) {
            const cur_y = context.animation_y.items[i];
            if (@abs(target_y - cur_y) < 0.5) {
                context.animation_y.items[i] = target_y;
            } else {
                context.animation_y.items[i] = cur_y + (target_y - cur_y) * 0.20;
                still_animating = true;
            }
        } else {
            context.animation_y.items[i] = target_y;
        }
    }

    var slot_x: f32 = @floatFromInt(context.usable_area.x + context.gaps_out);
    // Lead copies (docked to no window) ride at the row start.
    Mirror.syncLeadTiles(context);
    slot_x += @floatFromInt(Mirror.leadWidth(context));
    for (context.views.items, 0..) |view, i| {
        if (!view.isMapped() or view.floating or view.fullscreen) continue;

        const target_x = slot_x;
        var current = context.animation_x.items[i];

        const difference = target_x - current;
        const x_moving = @abs(difference) >= 0.5;
        if (x_moving) {
            current += difference * 0.20;
            still_animating = true;
        } else {
            current = target_x;
        }
        context.animation_x.items[i] = current;

        const viewport_x: f32 = @floatFromInt(context.viewport_x);
        const scene_x: c_int = @intFromFloat(current - viewport_x);
        const anim_y: f32 = if (i < context.animation_y.items.len)
            context.animation_y.items[i]
        else
            @floatFromInt(view.y);
        var scene_y: c_int = @as(c_int, @intFromFloat(@round(anim_y))) - context.viewport_y;
        if (fade < 1.0) scene_y += @intFromFloat(@round(slide_off));
        view.scene_tree.node.setPosition(scene_x, scene_y);
        if (fade < 1.0) {
            setTreeOpacity(&view.scene_tree.node, fade);
            // Windows fade in at the incoming offset; the border is a scene
            // rect (no opacity), so bring it back once more than a sliver
            // of the window is visible.
            if (view.border) |*b| b.rect.node.setEnabled(fade > 0.02);
        }

        // Lay this view's mirrors (self-mirror + same-row copies) into the
        // active tiled flow so they scroll and animate like real tiles.
        Mirror.syncActiveTile(view, current, w_items[i]);

        // Views past the 64-wide target buffer have no w_moving entry.
        if (x_moving or (i < w_moving.len and w_moving[i])) {
            Border.updateViewBorder(view, current, w_items[i]);
        }

        // Pile members share one column: only the last member advances the
        // flow (mirrors track their window's column in syncActiveTile).
        if (ViewManager.advanceSlotAfter(context, view, i)) {
            slot_x += w_items[i] + @as(f32, @floatFromInt(context.gaps_in));
            // Same-row mirror copies extend the tile flow after their window.
            slot_x += @floatFromInt(Mirror.extraTilesWidth(context, view));
        }
    }

    // Fade the incoming row's mirrors in step with their windows.
    if (fade < 1.0) {
        for (context.row_mirrors[context.active_row].items) |*m| setTreeOpacity(&m.tree.node, fade);
    }

    // Focused-ring pulse: breathe brightness on a ~2s sine. Repaint the
    // focused window's ring so it dims even while the layout is idle.
    if (context.pulse_enabled) {
        const breathe = 0.75 + 0.25 * @sin(@as(f32, @floatFromInt(now)) * 2.0 * std.math.pi / 2000.0);
        context.pulse_dim = breathe;
        if (context.focused_view) |fv| {
            if (fv.isMapped() and fv.border != null) {
                Border.updateViewBorder(fv, @floatFromInt(fv.x), null);
                still_animating = true;
            }
        }
    }

    context.animation_active = still_animating;
}
