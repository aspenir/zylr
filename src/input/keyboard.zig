const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const xkb = @import("xkbcommon");
const std = @import("std");

const ServerContext = @import("../server.zig");
const config = @import("../config.zig");
const Spawner = @import("../spawner.zig");
const FocusManager = @import("../view/focus.zig");
const ViewManager = @import("../view/view_manager.zig");
const View = @import("../view/view.zig");
const Blur = @import("../view/blur.zig");
const Border = @import("../view/border.zig");
const Config = @import("../config.zig");
const OutputContext = @import("../output/output.zig");
const InputRelay = @import("input_relay.zig");
const Idle = @import("../idle.zig");

const KeyboardContext = @This();

keyboard: *wlroots.Keyboard,
context: *ServerContext,

key_listener: wl.Listener(*wlroots.Keyboard.event.Key) = undefined,
modifiers_listener: wl.Listener(*wlroots.Keyboard) = undefined,
destroy_listener: wl.Listener(*wlroots.InputDevice) = undefined,
// Keybind repeat/cooldown state (see config.keybind_repeat).
bind_hold_sym: u32 = 0,
last_fire_ms: u64 = 0,
// xkb_keymap: ?*xkb.Keymap = null,
fn getKeySym(keyboard: *wlroots.Keyboard, keycode: u32) xkb.Keysym {
    const state = keyboard.xkb_state orelse {
        return @enumFromInt(0);
    };

    return state.*.keyGetOneSym(keycode + 8);
}

fn pushUndoEntry(context: *ServerContext, entry: ServerContext.UndoEntry) void {
    const idx = context.undo_count % context.undo_history.len;
    context.undo_history[idx] = entry;
    context.undo_count +|= 1;
}

/// Center a floating view on screen and raise it above tiled views.
fn centerFloating(context: *ServerContext, view: *View) void {
    const vw: f32 = @floatFromInt(@max(1, context.usable_area.width));
    const vh: f32 = @floatFromInt(@max(1, context.usable_area.height));
    view.x = context.usable_area.x + @as(i32, @intFromFloat((vw - @as(f32, @floatFromInt(view.slot_w))) / 2));
    view.y = context.usable_area.y + @as(i32, @intFromFloat((vh - @as(f32, @floatFromInt(view.slot_h))) / 2));
    view.scene_tree.node.setPosition(view.x, view.y);
    view.scene_tree.node.raiseToTop();
}

/// Relayout views from `start_idx` onward, sync the client size,
/// and scroll the viewport to the given view.
fn relayoutView(context: *ServerContext, view: *View, start_idx: usize) void {
    ViewManager.updateViewPositionsFrom(context, start_idx);
    const bw: i32 = @intCast(@max(0, context.border_width));
    const w = view.custom_width orelse ViewManager.getViewWidth(view);
    view.setSize(@max(1, w - 2 * bw), @max(1, view.slot_h - 2 * bw));
    ViewManager.scrollToViewNoLayout(context, view);
}

pub fn runAction(
    context: *ServerContext,
    action: Config.Action,
    args: ?[]const []const u8,
    target_view: ?*View,
) void {
    switch (action) {
        .viewport_up => {
            pushUndoEntry(context, .{ .viewport = .{ .prev_target = context.viewport_y } });
            context.viewport_y -|= 100;
            ViewManager.updateViewPositions(context);
        },
        .viewport_down => {
            pushUndoEntry(context, .{ .viewport = .{ .prev_target = context.viewport_y } });
            context.viewport_y += 100;
            ViewManager.updateViewPositions(context);
        },
        .grow, .shrink => {
            const view = context.focused_view orelse return;
            pushUndoEntry(context, .{ .resize = .{ .view = view, .prev_custom_width = view.custom_width, .prev_floating = view.floating } });
            const cur: f32 = @floatFromInt(ViewManager.getViewWidth(view));
            const factor: f32 = if (action == .grow) 1.15 else 1.0 / 1.15;
            view.custom_width = @max(200, @as(i32, @intFromFloat(cur * factor)));
            const idx = std.mem.indexOfScalar(*View, context.views.items, view) orelse 0;
            relayoutView(context, view, idx);
        },
        .reload_config => {
            // Free old heap-allocated config data before overwriting.
            const a = std.heap.c_allocator;
            a.free(context.keybinds);
            a.free(context.gestures);
            a.free(context.switches);
            if (context.xkb_names.rules) |p| a.free(std.mem.span(p));
            if (context.xkb_names.model) |p| a.free(std.mem.span(p));
            if (context.xkb_names.layout) |p| a.free(std.mem.span(p));
            if (context.xkb_names.variant) |p| a.free(std.mem.span(p));
            if (context.xkb_names.options) |p| a.free(std.mem.span(p));

            const loaded = Config.load(context.io, a, true);
            context.applyConfig(loaded);
            Blur.applyConfig(context);
            Border.applyConfig(context);
            OutputContext.applyScale(context);
            if (context.idle) |idle| idle.reloadTimers(context);
        },
        .spawn => {
            if (args) |a| {
                Spawner.launchProgram(context, context.environ_map, a);
            }
        },
        .close => {
            if (target_view orelse context.focused_view) |view| {
                view.sendClose();
            }
        },
        .quit => context.server.terminate(),
        .focus_left => {
            pushUndoEntry(context, .{ .focus = .{ .restore = context.focused_view } });
            FocusManager.focusColumnLeft(context);
        },
        .focus_right => {
            pushUndoEntry(context, .{ .focus = .{ .restore = context.focused_view } });
            FocusManager.focusColumnRight(context);
        },
        .toggle_floating => {
            const view = target_view orelse context.focused_view orelse return;
            pushUndoEntry(context, .{ .resize = .{ .view = view, .prev_custom_width = view.custom_width, .prev_floating = view.floating } });
            view.floating = !view.floating;
            if (view.floating) {
                centerFloating(context, view);
                const fidx = std.mem.indexOfScalar(*View, context.views.items, view) orelse 0;
                ViewManager.updateViewPositionsFrom(context, fidx);
            } else {
                var ow: c_int = 0;
                var oh: c_int = 0;
                context.output.?.effectiveResolution(&ow, &oh);
                var ew: c_int = ow - 2 * context.gaps_out;
                if (context.usable_area.width > 0) {
                    const left = context.usable_area.x;
                    const right = ow - (context.usable_area.x + context.usable_area.width);
                    ew -= left + right;
                }
                const tw: i32 = @intFromFloat(@as(f32, @floatFromInt(ew)) * context.view_width_ratio);
                view.custom_width = tw;
                view.slot_w = tw;
                view.slot_h = @max(1, context.usable_area.height - 2 * context.gaps_out);
                const ridx = std.mem.indexOfScalar(*View, context.views.items, view) orelse 0;
                ViewManager.updateViewPositionsFrom(context, ridx);
                // Snap animation so the view jumps to its tile position.
                if (tw > 0) {
                    context.animation_x.items[ridx] = @floatFromInt(view.x);
                    context.animation_w.items[ridx] = @floatFromInt(tw);
                }
                const bw: i32 = @intCast(@max(0, context.border_width));
                view.setSize(@max(1, tw - 2 * bw), @max(1, view.slot_h - 2 * bw));
                ViewManager.scrollToViewNoLayout(context, view);
            }
        },
        .swap_left => {
            const view = context.focused_view orelse return;
            var cur_idx: ?usize = null;
            for (context.views.items, 0..) |v, idx| {
                if (v == view) { cur_idx = idx; break; }
            }
            const cur = cur_idx orelse return;
            if (cur == 0) return;
            var j = cur - 1;
            while (j > 0 and !context.views.items[j].isMapped()) : (j -= 1) {}
            if (!context.views.items[j].isMapped()) return;
            pushUndoEntry(context, .{ .swap = .{ .a = cur, .b = j } });
            std.mem.swap(*View, &context.views.items[cur], &context.views.items[j]);
            ViewManager.updateViewPositionsFrom(context, @min(cur, j));
            ViewManager.scrollToViewNoLayout(context, view);
        },
        .swap_right => {
            const view = context.focused_view orelse return;
            var cur_idx: ?usize = null;
            for (context.views.items, 0..) |v, idx| {
                if (v == view) { cur_idx = idx; break; }
            }
            const cur = cur_idx orelse return;
            if (cur + 1 >= context.views.items.len) return;
            var j = cur + 1;
            while (j < context.views.items.len and !context.views.items[j].isMapped()) : (j += 1) {}
            if (j >= context.views.items.len or !context.views.items[j].isMapped()) return;
            pushUndoEntry(context, .{ .swap = .{ .a = cur, .b = j } });
            std.mem.swap(*View, &context.views.items[cur], &context.views.items[j]);
            ViewManager.updateViewPositionsFrom(context, @min(cur, j));
            ViewManager.scrollToViewNoLayout(context, view);
        },
        .undo => {
            if (context.undo_count == 0) return;
            context.undo_count -|= 1;
            const idx = context.undo_count % context.undo_history.len;
            switch (context.undo_history[idx]) {
                .none => {},
                .resize => |r| {
                    r.view.custom_width = r.prev_custom_width;
                    r.view.floating = r.prev_floating;
                    if (r.prev_floating) centerFloating(context, r.view);
                    const uidx = std.mem.indexOfScalar(*View, context.views.items, r.view) orelse 0;
                    relayoutView(context, r.view, uidx);
                },
                .swap => |s| {
                    if (s.a < context.views.items.len and s.b < context.views.items.len) {
                        std.mem.swap(*View, &context.views.items[s.a], &context.views.items[s.b]);
                        ViewManager.updateViewPositionsFrom(context, @min(s.a, s.b));
                        ViewManager.scrollToViewNoLayout(context, context.views.items[s.a]);
                    }
                },
                .viewport => |v| {
                    context.viewport_y = v.prev_target;
                    ViewManager.updateViewPositions(context);
                },
                .fullscreen => |f| {
                    if (f.view.isMapped()) {
                        f.view.fullscreen = f.prev_fullscreen;
                        ViewManager.applyFullscreen(context, f.view);
                        FocusManager.setFocus(context, .{ .view = .{ .view = f.view, .sx = 0, .sy = 0 } });
                    }
                },
                .focus => |f| {
                    if (f.restore) |view| {
                        if (view.isMapped()) {
                            FocusManager.setFocus(context, .{ .view = .{ .view = view, .sx = 0, .sy = 0 } });
                            ViewManager.scrollToView(context, view);
                        }
                    }
                },
            }
        },
        .toggle_fullscreen => {
            const view = context.focused_view orelse return;
            pushUndoEntry(context, .{ .fullscreen = .{ .view = view, .prev_fullscreen = view.fullscreen } });
            view.fullscreen = !view.fullscreen;
            ViewManager.applyFullscreen(context, view);
        },
        .center_window => {
            const view = context.focused_view orelse return;
            if (view.fullscreen) return;
            if (view.floating) {
                centerFloating(context, view);
            } else {
                ViewManager.scrollToView(context, view);
            }
        },
        .dpms_off => {
            Idle.setOutputsPower(context, false);
            // Mark so the next input wakes the outputs (idle semantics).
            if (context.idle) |idle| idle.outputs_off = true;
        },
    }
}

pub fn onKeyboardKey(
    listener: *wl.Listener(*wlroots.Keyboard.event.Key),
    event: *wlroots.Keyboard.event.Key,
) void {
    const keyboard_context: *KeyboardContext =
        @fieldParentPtr("key_listener", listener);

    const context = keyboard_context.context;
    const keyboard = keyboard_context.keyboard;

    if (context.idle) |idle| {
        if (event.state == .released) idle.notifyKeyRelease() else idle.notifyActivity();
    }

    // An active input-method keyboard grab (on-screen keyboard) claims
    // all physical key events first; the IM decides what to consume.
    if (InputRelay.handleKey(keyboard, event.time_msec, event.keycode, event.state)) return;

    // A released key clears its hold state so the next press is treated
    // as a fresh press, not auto-repeat.
    if (event.state == .released) {
        const rsym = getKeySym(keyboard, event.keycode);
        const rsym_int: u32 = @intFromEnum(rsym);
        const rnorm: u32 = if (rsym_int >= 'A' and rsym_int <= 'Z') rsym_int + 32 else rsym_int;
        if (keyboard_context.bind_hold_sym == rnorm) keyboard_context.bind_hold_sym = 0;
    }

    if (event.state == .pressed) {
        const sym = getKeySym(keyboard, event.keycode);
        const sym_int: u32 = @intFromEnum(sym);

        const depressed = keyboard.modifiers.depressed;

        // Normalize event keysym to lowercase so "Super+Shift+h"
        // (compiled as keysym=0x68) matches the shifted keysym (0x48).
        const norm_sym: u32 = if (sym_int >= 'A' and sym_int <= 'Z') sym_int + 32 else sym_int;
        for (context.keybinds) |bind| {
            if (bind.sym != norm_sym or bind.mods != depressed) continue;
            // Locked: only binds marked through_lock run here; anything
            // else falls through to the client below.
            if (context.locked and !bind.through_lock) continue;

            if (!context.locked) {
                const rep = context.keybind_repeat;
                const now = context.nowMs();
                const is_hold = keyboard_context.bind_hold_sym == norm_sym;
                const within_cooldown = rep.cooldown_ms > 0 and
                    (now - keyboard_context.last_fire_ms) < rep.cooldown_ms;
                // A held key only re-fires if repeats are enabled;
                // otherwise the first press is the only one.
                const suppressed = (!rep.enabled and is_hold) or within_cooldown;
                keyboard_context.bind_hold_sym = norm_sym;
                if (suppressed) return;
                keyboard_context.last_fire_ms = now;
            }
            runAction(context, bind.action, bind.args, null);
            return;
        }
    }

    // The seat broadcasts ONE keymap to all clients, so it must follow the
    // keyboard that is actually producing this event: clients decode raw
    // keycodes against the advertised map, and a virtual/on-screen
    // keyboard sends codes from its own uploaded layout. This is what
    // wlroots' TODO in
    // wlr_seat_set_keyboard prescribes ("call this on device key event").
    context.seat.setKeyboard(keyboard);

    context.seat.keyboardNotifyKey(
        event.time_msec,
        event.keycode,
        event.state,
    );
}
pub fn onKeyboardModifiers(
    listener: *wl.Listener(*wlroots.Keyboard),
    keyboard: *wlroots.Keyboard,
) void {
    const keyboard_context: *KeyboardContext =
        @fieldParentPtr("modifiers_listener", listener);

    const context = keyboard_context.context;

    context.seat.setKeyboard(keyboard);
    if (InputRelay.handleModifiers(keyboard, &keyboard.modifiers)) return;
    context.seat.keyboardNotifyModifiers(
        &keyboard.modifiers,
    );
}

/// wlroots asserts (`wl_list_empty(&kb->events.key.listener_list)`) when a
/// keyboard is destroyed with listeners still attached, so every wired
/// keyboard must detach its handlers here. Virtual keyboards are destroyed
/// whenever their OSK client exits; physical ones when unplugged.
pub fn onKeyboardDestroy(
    listener: *wl.Listener(*wlroots.InputDevice),
    device: *wlroots.InputDevice,
) void {
    _ = device;
    const keyboard_context: *KeyboardContext =
        @fieldParentPtr("destroy_listener", listener);

    const context = keyboard_context.context;

    keyboard_context.key_listener.link.remove();
    keyboard_context.modifiers_listener.link.remove();
    keyboard_context.destroy_listener.link.remove();

    for (context.keyboards.items, 0..) |candidate, i| {
        if (candidate == keyboard_context) {
            _ = context.keyboards.orderedRemove(i);
            break;
        }
    }

    std.heap.c_allocator.destroy(keyboard_context);
}
