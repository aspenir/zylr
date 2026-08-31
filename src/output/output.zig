const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const AnimationManager = @import("../view/animation.zig");
const ServerContext = @import("../server.zig");
const OutputContext = @This();

scene_output: *wlroots.SceneOutput,
frame_listener: wl.Listener(*wlroots.Output) = undefined,
destroy_listener: wl.Listener(*wlroots.Output) = undefined,
/// Set once the output died (mid-session): its listeners are detached
/// then, so the shutdown path must not remove them a second time.
destroyed: bool = false,
context: *ServerContext,


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

    if (output.adaptive_sync_supported) {
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

    AnimationManager.tick(output_ctx.context);

    if (!output_ctx.scene_output.commit(null)) {
        std.log.err("Failed to commit scene output", .{});
        return;
    }

    var now: std.c.timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &now);
    output_ctx.scene_output.sendFrameDone(@ptrCast(&now));
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
