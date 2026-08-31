const std = @import("std");

const ServerContext = @import("../server.zig");
const Border = @import("border.zig");
const ViewManager = @import("view_manager.zig");

pub fn wake(context: *ServerContext) void {
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
    if (!context.animation_active) return;

    var still_animating = false;

    // Animate the viewport scroll offset.
    const target_vp: f32 = @floatFromInt(context.viewport_target);
    var vcur = context.viewport_anim;
    if (@abs(target_vp - vcur) < 0.5) {
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
            @floatFromInt(ViewManager.getViewWidth(view))
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

    var slot_x: f32 = @floatFromInt(context.usable_area.x + context.gaps_out);
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
        const scene_y: c_int = view.y - context.viewport_y;
        view.scene_tree.node.setPosition(scene_x, scene_y);

        // Views past the 64-wide target buffer have no w_moving entry.
        if (x_moving or (i < w_moving.len and w_moving[i])) {
            Border.updateViewBorder(view, current, w_items[i]);
        }

        slot_x += w_items[i] + @as(f32, @floatFromInt(context.gaps_in));
    }

    context.animation_active = still_animating;
}
