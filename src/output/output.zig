const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const AnimationManager = @import("../view/animation.zig");
const Mirror = @import("../mirror.zig");
const Osd = @import("../osd.zig");
const ServerContext = @import("../server.zig");
const Config = @import("../config.zig");
const ViewManager = @import("../view/view_manager.zig");
const OutputContext = @This();

scene_output: *wlroots.SceneOutput,
frame_listener: wl.Listener(*wlroots.Output) = undefined,
destroy_listener: wl.Listener(*wlroots.Output) = undefined,
/// Set once the output died (mid-session): its listeners are detached
/// then, so the shutdown path must not remove them a second time.
destroyed: bool = false,
context: *ServerContext,
last_frame_ns: u64 = 0,
last_way_commits: u64 = 0,

pub fn onNewOutput(
    listener: *wl.Listener(*wlroots.Output),
    output: *wlroots.Output,
) void {
    const context: *ServerContext =
        @fieldParentPtr("new_output_listener", listener);

    std.log.info("NEW OUTPUT: {s}", .{
        std.mem.span(output.name),
    });

    if (!output.initRender(context.allocator, context.renderer)) {
        std.log.err("output.initRender() failed", .{});
        return;
    }

    var state = wlroots.Output.State.init();
    defer state.finish();

    state.setEnabled(true);

    if (output.preferredMode()) |mode| {
        std.log.info("Using preferred output mode", .{});
        state.setMode(mode);
    } else {
        std.log.warn("No preferred output mode", .{});
    }

    state.setScale(if (context.view_scale > 0) context.view_scale else defaultScale(output));
    state.setTransform(toWlrTransform(context.cfg.transform));

    if (output.adaptive_sync_supported and context.cfg.vrr) {
        state.setAdaptiveSyncEnabled(true);
        std.log.info("VRR: adaptive sync supported, enabled", .{});
    }

    if (!output.commitState(&state)) {
        std.log.err("output.commitState() failed", .{});
        return;
    }

    _ = context.output_layout.addAuto(output) catch {
        std.log.err("output_layout.addAuto() failed", .{});
        return;
    };
    std.log.info("Output added to output layout", .{});

    // Make this connector leaseable (zwlr_drm_lease_v1): a client like
    // Waydroid/VR can drive it directly with zero compositor copies.
    if (context.drm_lease) |lease| {
        _ = lease.offerOutput(output);
    }

    const scene_output =
        context.scene.createSceneOutput(output) catch {
            std.log.err("createSceneOutput() failed", .{});
            return;
        };

    var layout_box: wlroots.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    context.output_layout.getBox(output, &layout_box);
    scene_output.setPosition(layout_box.x, layout_box.y);

    const output_ctx =
        std.heap.c_allocator.create(OutputContext) catch {
            std.log.err("Failed to allocate OutputContext", .{});
            return;
        };

    output_ctx.* = .{
        .scene_output = scene_output,
        .context = context,
    };

    // Track it for cleanup
    context.output_contexts.append(std.heap.c_allocator, output_ctx) catch {};

    output_ctx.frame_listener =
        wl.Listener(*wlroots.Output).init(onOutputFrame);

    output.events.frame.add(&output_ctx.frame_listener);
    output_ctx.destroy_listener =
        wl.Listener(*wlroots.Output).init(onOutputDestroy);
    output.events.destroy.add(&output_ctx.destroy_listener);
    if (!context.xcursor_manager.load(output.scale)) {
        std.log.err("failed to load cursor theme", .{});
        return;
    }
    context.xcursor_manager.setXcursor(
        context.cursor,
        "default",
    );

    std.log.info("Output initialized; scheduling frame", .{});
    std.log.info("OUTPUT: {d}x{d} scale={d} effective={d}x{d}", .{ output.width, output.height, output.scale, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(output.width)) / output.scale)), @as(c_int, @intFromFloat(@as(f32, @floatFromInt(output.height)) / output.scale)) });
    context.output = output;

    sendConfig(context);
    output.scheduleFrame();
}

fn defaultScale(output: *wlroots.Output) f32 {
    const mode = output.preferredMode() orelse return 1;
    const phys_w = @as(f32, @floatFromInt(output.phys_width));
    const phys_h = @as(f32, @floatFromInt(output.phys_height));
    if (phys_w <= 0 or phys_h <= 0) return 1;

    const w: f32 = @floatFromInt(mode.width);
    const h: f32 = @floatFromInt(mode.height);
    const diag_px = @sqrt(w * w + h * h);
    const diag_in = @sqrt(phys_w * phys_w + phys_h * phys_h) / 25.4;
    const ppi = diag_px / diag_in;

    if (ppi > 200) return 2;
    return 1;
}

/// Re-apply the scale factor to the live output (called on config reload).
pub fn applyScale(context: *ServerContext) void {
    const output = context.output orelse return;
    var state = wlroots.Output.State.init();
    defer state.finish();
    state.setScale(if (context.view_scale > 0) context.view_scale else defaultScale(output));
    _ = output.commitState(&state);
    output.scheduleFrame();
}

/// Re-apply the output transform (screen rotation) from config. Called on
/// config reload: committing the transform where the reload also changed.
pub fn applyTransform(context: *ServerContext) void {
    const output = context.output orelse return;
    const t = toWlrTransform(context.cfg.transform);
    if (output.transform == t) return;
    var state = wlroots.Output.State.init();
    defer state.finish();
    state.setTransform(t);
    if (!output.commitState(&state)) {
        std.log.err("applyTransform: commitState failed", .{});
        return;
    }
    // Rotation swaps the output's logical width/height, so every tiled
    // slot and floating anchor derived from the old size is stale. Rebuild
    // the usable area from the new effective resolution and re-tile.
    reconfigureAndRetile(context);
    // Nothing was damaged by the commit, so the panel would keep showing the
    // old-orientation framebuffer until some unrelated repaint. Request one
    // now so the transition is immediate.
    output.scheduleFrame();
}

fn reconfigureAndRetile(context: *ServerContext) void {
    const output = context.output orelse return;
    // Effective (transformed+scaled) resolution: a rotated output swaps its
    // box here, so retiling lands on the portrait dimensions.
    var ow: c_int = 0;
    var oh: c_int = 0;
    output.effectiveResolution(&ow, &oh);
    const full_area = wlroots.Box{
        .x = 0,
        .y = 0,
        .width = @max(0, @as(c_int, ow)),
        .height = @max(0, @as(c_int, oh)),
    };
    var usable = full_area;
    // Re-derive the usable area the same way layer.zig does (bars reserve
    // their exclusive zones), then retile every view and re-center the
    // viewport so the focused window stays in view after the size swap.
    for (context.layers.items) |layer| {
        const ls = layer.layer_surface;
        if (!ls.initialized) continue;
        const st = ls.current;
        if (st.exclusive_zone < 0) continue;
        const ez = st.exclusive_zone;
        if (st.anchor.top and !st.anchor.bottom) {
            usable.y += ez + st.margin.top;
            usable.height -= ez + st.margin.top;
        }
        if (st.anchor.bottom and !st.anchor.top) {
            usable.height -= ez + st.margin.bottom;
        }
        if (st.anchor.left and !st.anchor.right) {
            usable.x += ez + st.margin.left;
            usable.width -= ez + st.margin.left;
        }
        if (st.anchor.right and !st.anchor.left) {
            usable.width -= ez + st.margin.right;
        }
    }
    if (usable.width < 0) usable.width = 0;
    if (usable.height < 0) usable.height = 0;
    context.usable_area = usable;

    // Bars and overlays keep their old-orientation geometry otherwise:
    // wlroots reconfigures layer surfaces only when they commit, not when
    // the output rotation changes. Force each live one onto the new boxes.
    //
    // Each configure call positions the layer INSIDE the bounds box and then
    // narrows it by that layer's exclusive zone, so feed a fresh full-area
    // starting point per pass. Passing the pre-narrowed `usable` here would
    // offset every bar by its own ezed zone (its own height/width).
    var layer_bounds = full_area;
    for (context.layers.items) |layer| {
        const ls = layer.layer_surface;
        if (!ls.initialized) continue;
        layer.scene_layer.configure(&full_area, &layer_bounds);
    }

    ViewManager.refreshTiledSizes(context);
    ViewManager.updateViewPositions(context);
}

fn toWlrTransform(t: Config.Transform) wl.Output.Transform {
    return switch (t) {
        .normal => .normal,
        .@"90" => .@"90",
        .@"180" => .@"180",
        .@"270" => .@"270",
    };
}

/// The output is going away (hotplug, modeset loss, shutdown). Detach
/// our listeners so wlr_output_finish's leftover-listener asserts pass;
/// without this the compositor aborts the moment any output dies.
pub fn onOutputDestroy(listener: *wl.Listener(*wlroots.Output), output: *wlroots.Output) void {
    const output_ctx: *OutputContext = @fieldParentPtr("destroy_listener", listener);
    const context = output_ctx.context;
    if (context.output == output) context.output = null;
    output_ctx.destroyed = true;
    output_ctx.frame_listener.link.remove();
    output_ctx.destroy_listener.link.remove();
}

pub fn onOutputFrame(listener: *wl.Listener(*wlroots.Output), output: *wlroots.Output) void {
    _ = output;
    const output_ctx: *OutputContext = @fieldParentPtr("frame_listener", listener);
    const context = output_ctx.context;

    AnimationManager.tick(context);

    // Stock present path: wlr_scene_output_commit() -> wlr_output_commit_state
    // -> drm_connector_commit, which REFUSES to queue a page flip while one is
    // still pending (single-flip pacing — the behavior of every compositor).
    // The former device-wide path (wlr_backend_commit -> commit_drm_device)
    // queued back-to-back flips with no such gate; that unrestricted pacing was
    // the one present-path behavior unique to zylr among the WMs that do not
    // flash. Tearing cannot go through this path, but it was dead anyway: the
    // device path rejected tearing_page_flip outright and no client requests
    // async tearing.
    if (!output_ctx.scene_output.commit(null)) {
        std.log.err("Failed to commit scene output", .{});
        return;
    }

    var now: std.c.timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &now);
    output_ctx.scene_output.sendFrameDone(@ptrCast(&now));
    // Pace mirror kicks off the REAL output frame (once per vsync), never
    // off client commits: an unvsync'd kick loop hung the GPU pipeline.
    Mirror.onOutputFrame(context, &now);
    Osd.onFrame(context);
}
extern fn clock_gettime(clk_id: c_int, tp: *anyopaque) c_int;
const CLOCK_MONOTONIC: c_int = 1;

pub fn onManagerTest(listener: *wl.Listener(*wlroots.OutputConfigurationV1), config: *wlroots.OutputConfigurationV1) void {
    defer config.destroy();
    const context: *ServerContext = @fieldParentPtr("manager_test_listener", listener);

    const states = config.buildState() catch {
        config.sendFailed();
        return;
    };
    defer std.c.free(states.ptr);
    defer for (states) |*state| state.base.finish();

    var swapchain_manager: wlroots.OutputSwapchainManager = undefined;
    swapchain_manager.init(context.backend);
    defer swapchain_manager.finish();

    if (swapchain_manager.prepare(states)) {
        config.sendSucceeded();
    } else {
        config.sendFailed();
    }
}

pub fn onManagerApply(listener: *wl.Listener(*wlroots.OutputConfigurationV1), config: *wlroots.OutputConfigurationV1) void {
    defer config.destroy();
    const context: *ServerContext = @fieldParentPtr("manager_apply_listener", listener);

    const states = config.buildState() catch {
        config.sendFailed();
        return;
    };
    defer std.c.free(states.ptr);
    defer for (states) |*state| state.base.finish();

    var swapchain_manager: wlroots.OutputSwapchainManager = undefined;
    swapchain_manager.init(context.backend);
    defer swapchain_manager.finish();

    if (!swapchain_manager.prepare(states)) {
        std.log.err("failed to prepare output configuration", .{});
        config.sendFailed();
        return;
    }

    for (states) |*state| {
        if (context.scene.getSceneOutput(state.output)) |scene_output| {
            _ = scene_output.buildState(&state.base, &.{
                .swapchain = swapchain_manager.getSwapchain(state.output),
            });
        }
    }

    if (!context.backend.commit(states)) {
        std.log.err("failed to commit output configuration", .{});
        config.sendFailed();
        return;
    }
    swapchain_manager.apply();

    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        if (head.state.enabled) {
            _ = context.output_layout.add(head.state.output, head.state.x, head.state.y) catch {};
            _ = context.xcursor_manager.load(head.state.scale);
        } else {
            context.output_layout.remove(head.state.output);
        }
    }

    // A transform/scale change came through the output-management protocol
    // (wlr-randr, accelerometer-driven rotation) rather than a config reload.
    // The state is committed above but nothing re-derives the usable area or
    // retiles, so a rotated output keeps its old layout. Recompute now.
    if (context.output) |output| {
        reconfigureAndRetile(context);
        output.scheduleFrame();
    }
    config.sendSucceeded();
    sendConfig(context);
}

fn sendConfig(context: *ServerContext) void {
    const config = wlroots.OutputConfigurationV1.create() catch return;
    // config is owned by wlroots after setConfiguration(), do not destroy

    for (context.output_contexts.items) |output_ctx| {
        const output = output_ctx.scene_output.output;
        const head = wlroots.OutputConfigurationV1.Head.create(config, output) catch return;
        head.state.enabled = output.enabled;
        head.state.scale = output.scale;
        head.state.transform = output.transform;
        var box: wlroots.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        context.output_layout.getBox(output, &box);
        head.state.x = box.x;
        head.state.y = box.y;
    }

    context.output_manager.setConfiguration(config);
}
