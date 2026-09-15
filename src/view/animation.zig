const std = @import("std");
const ServerContext = @import("../server.zig");
const Border = @import("border.zig");
const Blur = @import("blur.zig");
const View = @import("view.zig");
const ViewManager = @import("view_manager.zig");
const Row = @import("../row.zig");
const Mirror = @import("../mirror.zig");
const wlroots = @import("wlroots");

/// The configured easing, sampled at normalized progress in [0,1].
/// Opacity callers clamp; offset callers keep the raw value so a spring
/// can overshoot and bounce.
/// Sample the configured easing for one animation at progress p in [0,1].
fn ease(spec: @import("../config.zig").AnimationSpec, p: f32) f32 {
    return spec.easing.sample(p);
}

/// Chase-factor for position/viewport tweens: sample the spec's easing at
/// elapsed/ms since the animation was armed. Springs may exceed 1 to
/// overshoot the target and bounce; the 2.0 clamp bounds runaway gains.
fn chaseFactor(spec: @import("../config.zig").AnimationSpec, elapsed: u64) f32 {
    const ms = @max(spec.ms, 1);
    if (elapsed >= ms) return 1;
    const p = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(ms));
    return std.math.clamp(spec.easing.sample(p), 0, 2);
}

/// True when the gradient's angle or stop colors differ from what's
/// currently painted on the ring (focus switch or config reload).
fn gradientChanged(a: @import("../config.zig").Gradient, b: @import("../config.zig").Gradient) bool {
    if (a.colors.len != b.colors.len) return true;
    for (a.colors, b.colors) |ca, cb| {
        if (!std.mem.eql(f32, &ca, &cb)) return true;
    }
    return a.angle != b.angle;
}

/// One step of a damped spring toward `target` (semi-implicit Euler, stable
/// for dt*w < 2 with w = sqrt(stiffness)). Returns the new position and
/// updates the velocity in place. Near-settled springs snap to target so
/// the bounce decays instead of idling in a tiny oscillation forever.
/// `tol_pos`/`tol_vel` are the settle thresholds in the spring's own units:
/// pixel springs use ~0.5px, a normalized 0..1 progress spring must use a
/// much smaller tolerance (a 0.5 threshold there is *half a screen* and
/// would snap at the very first velocity null, killing the bounce).
fn springStep(x: f32, v: *f32, stiffness: f32, damping: f32, dt: f32, target: f32, tol_pos: f32, tol_vel: f32) f32 {
    if (stiffness <= 0) {
        v.* = 0;
        return target;
    }
    v.* += (stiffness * (target - x) - damping * v.*) * dt;
    const nx = x + v.* * dt;
    if (@abs(target - nx) < tol_pos and @abs(v.*) < tol_vel) {
        v.* = 0;
        return target;
    }
    return nx;
}

/// Whether a spring on `x` (with velocity `v`) is still "moving" toward a
/// target: not yet settled per springStep's snap condition.
fn springMoving(x: f32, v: f32, target: f32, tol_pos: f32, tol_vel: f32) bool {
    return !(@abs(target - x) < tol_pos and @abs(v) < tol_vel);
}

test "springStep integrates, overshoots and settles" {
    // Under-damped spring must cross the target and come back (bounce),
    // then decay into a settled snap instead of micro-oscillating forever.
    var v: f32 = 0;
    var x: f32 = 0;
    var overshoot = false;
    const dt: f32 = 1.0 / 60.0;
    for (0..3000) |_| {
        x = springStep(x, &v, 180, 6, dt, 100, 0.5, 0.1);
        if (x > 100.5) overshoot = true;
    }
    try std.testing.expect(overshoot);
    // Settled: position at target, velocity dead.
    try std.testing.expectApproxEqAbs(@as(f32, 100), x, 0.6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v, 0.02);
}

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
    if (!context.animation_active) return;

    var still_animating = false;

    // Window open fade-in / close fade-out. Runs before the row block so
    // an active slide keeps its own opacity.
    const now = context.nowMs();
    // Real frame time for the spring integrator (stale when idle is fine:
    // oversized dt is clamped to a safe 50ms step).
    const dt_ms = now -| context.last_tick_ms;
    context.last_tick_ms = now;
    const spring_dt: f32 = @min(@as(f32, @floatFromInt(dt_ms)) / 1000.0, 0.05);
    for (context.views.items) |view| {
        if (view.fading_in) {
            const elapsed = now - view.fade_started;
            const spec = context.cfg.animation.open;
            const style = context.cfg.animation.open_style;
            if (elapsed >= spec.ms) {
                view.fading_in = false;
                view.fade_slide_off = 0;
                setTreeOpacity(&view.scene_tree.node, 1.0);
                view.scene_tree.node.setPosition(
                    @as(c_int, @intFromFloat(@as(f32, @floatFromInt(view.x)))),
                    @as(c_int, @intFromFloat(@as(f32, @floatFromInt(view.y)))),
                );
            } else {
                const p = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(spec.ms));
                const v = std.math.clamp(ease(spec, p), 0, 1);
                setTreeOpacity(&view.scene_tree.node, v);
                // Open style layers over the fade: slide enters from a
                // vertical offset; pop/fade stay in place at slot. (No
                // scene-scale API exists, so a scale-based pop is dropped.)
                switch (style) {
                    .slide => {
                        view.fade_slide_off = @intFromFloat((1.0 - v) * @as(f32, @floatFromInt(context.usable_area.height)) * 0.6);
                    },
                    .pop, .fade => {
                        view.fade_slide_off = 0;
                    },
                }
                view.scene_tree.node.setPosition(
                    @as(c_int, @intFromFloat(@as(f32, @floatFromInt(view.x)))),
                    @as(c_int, @intFromFloat(@as(f32, @floatFromInt(view.y)) + @as(f32, @floatFromInt(view.fade_slide_off)))),
                );
                still_animating = true;
            }
        } else if (view.fading_out) {
            const elapsed = now - view.fade_out_started;
            const spec2 = context.cfg.animation.close;
            if (elapsed >= spec2.ms) {
                view.fading_out = false;
                view.doClose();
            } else {
                const p = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(spec2.ms));
                const v = std.math.clamp(1 - ease(spec2, p), 0, 1);
                setTreeOpacity(&view.scene_tree.node, v);
                // Close style layers over the fade-out too: slide drifts
                // away from the slot as it fades; pop/fade stay in place
                // (no scene-scale API, so pop is folded into the fade).
                switch (context.cfg.animation.close_style) {
                    .slide => {
                        view.fade_slide_off = -@as(i32, @intFromFloat((1.0 - v) * @as(f32, @floatFromInt(context.usable_area.height)) * 0.6));
                    },
                    .pop, .fade => {
                        view.fade_slide_off = 0;
                    },
                }
                view.scene_tree.node.setPosition(
                    @as(c_int, @intFromFloat(@as(f32, @floatFromInt(view.x)))),
                    @as(c_int, @intFromFloat(@as(f32, @floatFromInt(view.y)) + @as(f32, @floatFromInt(view.fade_slide_off)))),
                );
                still_animating = true;
            }
        }
    }

    // Fullscreen enter/exit tween: runs for ALL views here (the row fold
    // below skips fullscreen views, so this is the fold that f() the
    // tween that `applyFullscreen` armed).
    for (context.views.items) |view| {
        if (view.fs_tween) |*tw| {
            const t_ms: u64 = now -| tw.started;
            const a = if (tw.entering) context.cfg.animation.open else context.cfg.animation.close;
            const dur: f32 = @floatFromInt(a.ms);
            const p = std.math.clamp(@as(f32, @floatFromInt(t_ms)) / dur, 0, 1);
            const e = ease(a, p);
            const vx: f32 = tw.from[0] + (tw.to[0] - tw.from[0]) * e;
            const vy: f32 = tw.from[1] + (tw.to[1] - tw.from[1]) * e;
            const vw: f32 = tw.from[2] + (tw.to[2] - tw.from[2]) * e;
            const vh: f32 = tw.from[3] + (tw.to[3] - tw.from[3]) * e;
            view.setSize(@intFromFloat(vw), @intFromFloat(vh));
            view.scene_tree.node.setPosition(@intFromFloat(vx), @intFromFloat(vy));
            if (p >= 1) {
                if (tw.entering) {
                    if (context.fullscreen_tree) |ft| {
                        view.scene_tree.node.reparent(ft);
                    }
                    view.scene_tree.node.setPosition(0, 0);
                    view.scene_tree.node.raiseToTop();
                    switch (view.backend) {
                        .xdg => |t| _ = t.setFullscreen(true),
                        .xwayland => |x| x.setFullscreen(true),
                    }
                } else {
                    if (view.border) |*b| b.rect.node.setEnabled(true);
                    if (context.views_tree) |vt| {
                        view.scene_tree.node.reparent(vt);
                    }
                    switch (view.backend) {
                        .xdg => |t| _ = t.setFullscreen(false),
                        .xwayland => |x| x.setFullscreen(false),
                    }
                    view.scene_tree.node.setPosition(@intFromFloat(tw.to[0]), @intFromFloat(tw.to[1]));
                    view.scene_tree.node.raiseToTop();
                    const idx = std.mem.indexOfScalar(*View, context.views.items, view) orelse 0;
                    if (view.floating) {
                        ViewManager.updateViewPositionsFrom(context, idx);
                    } else {
                        ViewManager.updateViewPositionsFrom(context, idx);
                        ViewManager.scrollToViewNoLayout(context, view);
                    }
                }
                view.fs_tween = null;
            }
            still_animating = true;
        }
    }

    // Row-switch slide: the outgoing row (parked but still rendered) slides
    // out and fades while the incoming row slides in over it.
    // Incoming rows translate by slide_off until the transition settles, even
    // across a spring overshoot (where curve>1 pushes fade to 1); gate the
    // position on the slide, and opacity on fade, separately.
    var slide_off: f32 = 0; // incoming y offset from the slide
    var row_sliding = false; // row transition in progress (not yet settled)
    var fade: f32 = 1; // incoming opacity
    if (context.row_anim) |*t| {
        const rspec = context.cfg.animation.row;
        // A spring easing drives real position (with velocity), ignoring
        // ms and settling when the spring lands; time-based easings
        // sample the curve against ms as before.
        var settled = false;
        var curve: f32 = undefined;
        // TODO: make settle tol_pos and tol_vel configurable?
        const tol_pos = 0.005;
        const tol_vel = 0.005;
        switch (rspec.easing) {
            .spring => |sp| {
                curve = springStep(t.progress, &t.vel, sp.stiffness, sp.damping, spring_dt, 1, tol_pos, tol_vel);
                t.progress = curve;
                if (!springMoving(curve, t.vel, 1, tol_pos, tol_vel)) {
                    settled = true;
                }
            },
            else => {
                const elapsed = context.nowMs() - t.started;
                if (elapsed >= rspec.ms) {
                    settled = true;
                } else {
                    const p = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(rspec.ms));
                    curve = ease(rspec, p);
                }
            },
        }
        if (settled) {
            // Slide complete: retire the outgoing row, restore full
            // opacity, then centre the viewport on the focused window.
            Row.settleTransition(context);
            if (context.focused_view) |fv| ViewManager.scrollToView(context, fv);
        } else {
            const clamped = std.math.clamp(curve, 0, 1);
            const dir: f32 = @floatFromInt(t.dir);
            // Both rows translate the same way (a rigid scroll): the
            // incoming row enters from the switch direction while the
            // outgoing one exits past the opposite edge. Use the raw curve
            // for offsets so a spring can overshoot on both rows and
            // bounce; clamp only the opacity (can't go past opaque).
            // Row bounce: the outgoing shelf also leads the switch with a
            // sinusoidal push, opening a visible gap between the shelves
            // mid-flight that compresses shut as the incoming row lands.
            const push = 0.35 * @sin(clamped * std.math.pi);
            const outgoing_off: c_int = @intFromFloat(@round(-t.slide * (curve + push) * dir));
            if (context.rows[t.from_row]) |parked| {
                for (parked.views.items) |v| {
                    v.scene_tree.node.setPosition(
                        v.x - parked.scroll_x,
                        v.y - context.viewport_y + outgoing_off,
                    );
                    setTreeOpacity(&v.scene_tree.node, 1.0 - clamped);
                }
            }
            slide_off = t.slide * (1.0 - curve) * dir;
            fade = clamped;
            row_sliding = true;
            still_animating = true;
        }
    }

    // Animate the viewport scroll offset. A spring easing integrates real
    // velocity and can overshoot/bounce; a bezier tween samples the curve
    // from the frozen origin.
    const target_vp: f32 = @floatFromInt(context.viewport_target);
    var vcur: f32 = undefined;
    switch (context.cfg.animation.focus.easing) {
        .spring => |sp| {
            vcur = springStep(context.viewport_anim, &context.viewport_vel, sp.stiffness, sp.damping, spring_dt, target_vp, 0.5, 0.1);
            if (springMoving(vcur, context.viewport_vel, target_vp, 0.5, 0.1)) {
                context.viewport_x = @intFromFloat(@round(vcur));
                still_animating = true;
            } else {
                context.viewport_x = context.viewport_target;
            }
        },
        else => {
            vcur = context.viewport_from + (target_vp - context.viewport_from) * chaseFactor(context.cfg.animation.focus, now -| context.viewport_anim_started);
            if (@abs(target_vp - vcur) < 0.5) {
                if (context.viewport_x != context.viewport_target and context.viewport_target > 0)
                    std.log.warn("SCROLL SETTLED vp={} target={}", .{ context.viewport_target, context.viewport_target });
                vcur = target_vp;
                context.viewport_x = context.viewport_target;
            } else {
                context.viewport_x = @intFromFloat(@round(vcur));
                still_animating = true;
            }
        },
    }
    context.viewport_anim = vcur;

    const wfactor = chaseFactor(context.cfg.animation.swap, now -| context.layout_anim_started);
    const n = @min(@min(context.views.items.len, context.animation_w.items.len), 64);
    const w_items = context.animation_w.items;
    const fw = context.from_w.items;
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

    var w_moving: [64]bool = undefined;
    var wi: usize = 0;
    switch (context.cfg.animation.swap.easing) {
        .spring => |sp| {
            const k = sp.stiffness;
            const c = sp.damping;
            for (0..n) |i| {
                const nx = springStep(w_items[i], &context.vel_w.items[i], k, c, spring_dt, targets[i], 0.5, 0.1);
                w_items[i] = nx;
                w_moving[i] = springMoving(nx, context.vel_w.items[i], targets[i], 0.5, 0.1);
                if (w_moving[i]) still_animating = true;
            }
            wi = n;
        },
        else => {
            const VecLen = std.simd.suggestVectorLength(f32) orelse 4;
            const Vec = @Vector(VecLen, f32);
            while (wi + VecLen <= n) : (wi += VecLen) {
                const from: Vec = fw[wi..][0..VecLen].*;
                const tgt: Vec = targets[wi..][0..VecLen].*;
                const lerped = from + (tgt - from) * @as(Vec, @splat(wfactor));
                const diff = tgt - lerped;
                const close: @Vector(VecLen, bool) = @abs(diff) < @as(Vec, @splat(0.5));
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
                const from_w = fw[wi];
                const lerped = from_w + (target_w - from_w) * wfactor;
                if (@abs(target_w - lerped) < 0.5) {
                    w_items[wi] = target_w;
                    w_moving[wi] = false;
                } else {
                    w_items[wi] = lerped;
                    still_animating = true;
                    w_moving[wi] = true;
                }
            }
        },
    }

    // Animate the vertical offset: pile share changes slide members to
    // their new slot tops instead of jumping. Floating/fullscreen views
    // set their own y; pin them so the array can't lag their direct moves.
    for (context.views.items, 0..) |view, i| {
        if (i >= context.animation_y.items.len) break;
        const target_y: f32 = @floatFromInt(view.y);
        if (view.isMapped() and !view.floating and !view.fullscreen) {
            switch (context.cfg.animation.swap.easing) {
                .spring => |sp| {
                    const ny = springStep(context.animation_y.items[i], &context.vel_y.items[i], sp.stiffness, sp.damping, spring_dt, target_y, 0.5, 0.1);
                    context.animation_y.items[i] = ny;
                    if (springMoving(ny, context.vel_y.items[i], target_y, 0.5, 0.1)) still_animating = true;
                },
                else => {
                    const from_y = if (i < context.from_y.items.len) context.from_y.items[i] else context.animation_y.items[i];
                    const cur_y = from_y + (target_y - from_y) * wfactor;
                    if (@abs(target_y - cur_y) < 0.5) {
                        context.animation_y.items[i] = target_y;
                    } else {
                        context.animation_y.items[i] = cur_y;
                        still_animating = true;
                    }
                },
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
        var current: f32 = undefined;
        var x_moving: bool = undefined;
        switch (context.cfg.animation.swap.easing) {
            .spring => |sp| {
                current = springStep(context.animation_x.items[i], &context.vel_x.items[i], sp.stiffness, sp.damping, spring_dt, target_x, 0.5, 0.1);
                x_moving = springMoving(current, context.vel_x.items[i], target_x, 0.5, 0.1);
            },
            else => {
                current = if (i < context.from_x.items.len)
                    context.from_x.items[i] + (target_x - context.from_x.items[i]) * wfactor
                else
                    context.animation_x.items[i];
                x_moving = @abs(target_x - current) >= 0.5;
                if (!x_moving) current = target_x;
            },
        }
        if (x_moving) {
            still_animating = true;
        }
        context.animation_x.items[i] = current;

        const viewport_x: f32 = @floatFromInt(context.viewport_x);
        const scene_x: c_int = @intFromFloat(current - viewport_x);
        const anim_y: f32 = if (i < context.animation_y.items.len)
            context.animation_y.items[i]
        else
            @floatFromInt(view.y);
        var scene_y: c_int = @as(c_int, @intFromFloat(@round(anim_y))) - context.viewport_y;
        if (row_sliding) scene_y += @intFromFloat(@round(slide_off));
        if (view.fading_in or view.fading_out) scene_y += view.fade_slide_off;
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

    // Focused-ring pulse: breathe brightness on a ~2s sine. Repaints are
    // threshold-gated (a 16ms step of the 2s sine moves brightness < 0.02)
    // and the pulse runs only on real output frames — it can't keep the
    // timer alive by itself, so an idle desktop schedules no frames and
    // the GPU parks.
    if (context.pulse_enabled) {
        const breathe = 0.75 + 0.25 * @sin(@as(f32, @floatFromInt(now)) * 2.0 * std.math.pi / 2000.0);
        context.pulse_dim = breathe;
        if (context.focused_view) |fv| {
            if (fv.isMapped() and fv.border != null) {
                // Threshold-gate the repaint: a 16ms step of the 2s sine
                // rarely moves brightness enough to see, so skip identical
                // frames.
                if (@abs(breathe - context.pulse_last_dim) > 0.02) {
                    context.pulse_last_dim = breathe;
                    Border.updateViewBorder(fv, @floatFromInt(fv.x), null);
                }
            }
        }
    }

    // Focus-ring colour chase: drive the ring's solid colour toward its
    // focused/inactive target on focus switches instead of snapping. Runs
    // after the pulse block so the lerped colour wins that frame.
    for (context.views.items) |view| {
        if (!view.isMapped() or view.border == null) continue;
        const b = view.border.?;
        const ring = view.borderColor(context.focused_view == view);
        switch (ring) {
            .solid => |tgt| {
                if (!std.mem.eql(f32, view.border_color_target[0..], tgt[0..])) {
                    view.border_color_from = view.border_color_now;
                    view.border_color_target = tgt;
                    view.border_color_started = now;
                }
                if (view.border_color_started == 0) continue;
                const spec = context.cfg.animation.border_color;
                const es = now -| view.border_color_started;
                if (es >= spec.ms) {
                    view.border_color_now = tgt;
                    view.border_color_started = 0;
                    continue;
                }
                const p = @min(@as(f32, @floatFromInt(es)) / @as(f32, @floatFromInt(spec.ms)), 1.0);
                const e = ease(spec, p);
                var col: [4]f32 = undefined;
                for (&col, 0..) |*c, i| c.* = view.border_color_from[i] + (tgt[i] - view.border_color_from[i]) * e;
                view.border_color_now = col;
                b.rect.setColor(&col);
                still_animating = true;
            },
            .gradient => |tgg| {
                // Delay the twist-free switch until the strip colors have
                // eased toward the new gradient's stops.
                if (view.border_grad_started == 0 or gradientChanged(view.border_grad_target, tgg)) {
                    view.border_grad_from = view.border_grad_target;
                    view.border_grad_target = tgg;
                    view.border_grad_started = now;
                }
                if (view.border_grad_started == 0) continue;
                const spec = context.cfg.animation.border_color;
                const es = now -| view.border_grad_started;
                if (es >= spec.ms) {
                    view.border_grad_started = 0;
                    continue;
                }
                const p = @min(@as(f32, @floatFromInt(es)) / @as(f32, @floatFromInt(spec.ms)), 1.0);
                Border.tintGradientChase(b.strips.items, view.border_grad_from, tgg, ease(spec, p));
                still_animating = true;
            },
        }
    }

    context.animation_active = still_animating;

    // With animations settled and the pulse frame-synced, nothing forces
    // output frames: relax the GPU (drop blur) and let the output sleep.
    Blur.setActive(context, context.animation_active);
}
