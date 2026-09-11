const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const xkb = @import("xkbcommon");
const std = @import("std");

const ServerContext = @import("../server.zig");
const Spawner = @import("../spawner.zig");
const FocusManager = @import("../view/focus.zig");
const ViewManager = @import("../view/view_manager.zig");
const Row = @import("../row.zig");
const Mirror = @import("../mirror.zig");
const Osd = @import("../osd.zig");
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

/// Swap the focused tile with its row neighbour in the given direction.
/// Tiles are windows and mirrorred-copy mirrors alike: window<->window keeps
/// the existing views-array swap (undoable); window<->copy re-docks the
/// copy to the window's cluster (or to the row lead); copy<->copy exchanges
/// docks exactly.
fn swapTiles(context: *ServerContext, dir: i32) void {
    const view = context.focused_view orelse return;
    var tiles: [128]FocusManager.FocusTile = undefined;
    const n = FocusManager.buildRowTiles(context, &tiles);
    if (n < 2) return;

    // Anchor on the exact tile the keyboard ring is on: the anchored copy
    // mirror, else the focused window's home tile.
    var cur: usize = 0;
    var found = false;
    if (context.kbd_anchor_row == context.active_row and context.kbd_anchor_slot_x >= 0) {
        for (tiles[0..n], 0..) |t, i| {
            if (t.mirror_slot_x >= 0 and @as(i32, @intFromFloat(t.mirror_slot_x)) == context.kbd_anchor_slot_x) {
                cur = i;
                found = true;
                break;
            }
        }
    }
    if (!found) {
        for (tiles[0..n], 0..) |t, i| {
            if (t.view == view and t.mirror_slot_x < 0) {
                cur = i;
                found = true;
                break;
            }
        }
    }
    if (!found) return;

    const j: i64 = @as(i64, @intCast(cur)) + dir;
    if (j < 0 or j >= n) return;

    // The pair being exchanged is (left, right) in row order regardless of
    // which of the two is focused, so both directions give the same swap.
    const l = @min(cur, @as(usize, @intCast(j)));
    const r = @max(cur, @as(usize, @intCast(j)));
    const left = tiles[l];
    const right = tiles[r];
    const left_copy = left.mirror;
    const right_copy = right.mirror;
    const focused_copy = tiles[cur].mirror;

    if (left_copy == null and right_copy == null) {
        // window <-> window: existing views-array swap.
        const ia = std.mem.indexOfScalar(*View, context.views.items, left.view) orelse return;
        const ib = std.mem.indexOfScalar(*View, context.views.items, right.view) orelse return;
        if (ia == ib) return;
        pushUndoEntry(context, .{ .swap = .{ .a = ia, .b = ib } });
        std.mem.swap(*View, &context.views.items[ia], &context.views.items[ib]);
        ViewManager.updateViewPositionsFrom(context, @min(ia, ib));
        ViewManager.scrollToViewNoLayout(context, view);
        return;
    }
    if (left_copy == null and right_copy != null) {
        // [window, copy]: the copy takes the window's place, i.e. moves to
        // the tail of the cluster ending right before the window (or to the
        // row lead when the window is the first tile), however the pair was
        // reached.
        var dock: ?*View = null;
        if (l > 0) {
            const before = tiles[l - 1];
            dock = if (before.mirror) |bm| bm.dock_view else before.view;
        }
        Mirror.dockCopyAsTail(context, context.active_row, right_copy orelse unreachable, dock);
    } else if (left_copy != null and right_copy == null) {
        // [copy, window]: the copy takes the window's place, i.e. becomes
        // the head of the window's cluster.
        Mirror.dockCopyAsHead(context, context.active_row, left_copy orelse unreachable, right.view);
    } else {
        // copy <-> copy: exact dock exchange.
        Mirror.swapCopyDocks(left_copy orelse unreachable, right_copy orelse unreachable);
    }

    ViewManager.updateViewPositionsFrom(context, 0);
    Mirror.refreshMirrorFocus(context);

    // Keep the keyboard ring anchored on the focused tile (copy anchors by
    // slot, window anchors to its home and keeps the viewport put).
    if (focused_copy) |c| {
        context.kbd_cycle_view = c.view;
        context.kbd_cycle_slot = c.slot_x;
        context.kbd_anchor_row = context.active_row;
        context.kbd_anchor_slot_x = c.slot_x;
    } else {
        context.kbd_cycle_slot = -1;
        context.kbd_anchor_slot_x = -1;
        ViewManager.scrollToViewNoLayout(context, view);
    }
    std.log.warn("SWAP dir={} l={} r={} lcopy={} rcopy={} anchor_slot={} focused_copy_slot={}", .{ dir, l, r, left_copy != null, right_copy != null, context.kbd_anchor_slot_x, if (focused_copy) |c| c.slot_x else @as(i32, -1) });
}

/// Center a floating view on screen and raise it above tiled views.
fn centerFloating(context: *ServerContext, view: *View) void {
    ViewManager.centerFloating(context, view);
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
        .row_up, .row_down => {
            const dir: i32 = if (action == .row_up) -1 else 1;
            // Compute in signed space first: casting a negative i32 to a
            // usize traps on row_up from the top row.
            const target_signed: i32 = @as(i32, @intCast(context.active_row)) + dir;
            if (target_signed < 0 or target_signed >= ServerContext.max_rows) return;
            const target: usize = @intCast(target_signed);
            pushUndoEntry(context, .{ .row_switch = .{ .prev_row = context.active_row } });
            Row.switchTo(context, target);
            ViewManager.updateViewPositions(context);
            FocusManager.focusActiveRow(context);
        },
        .mirror => {
            const view = context.focused_view orelse return;
            const row_idx: usize = blk: {
                if (args) |a| {
                    if (a.len > 0) {
                        break :blk std.fmt.parseInt(usize, a[0], 10) catch return;
                    }
                }
                break :blk context.active_row;
            };
            if (row_idx >= ServerContext.max_rows) return;
            Mirror.mirrorToRow(context, view, row_idx);
        },
        .submap => {
            // Enter the named mode; its binds match first from the next
            // press until an action or an unmatched key leaves it.
            if (args) |a| {
                if (a.len > 0) context.active_submap = a[0];
            }
        },
        .grow, .shrink => {
            const view = context.focused_view orelse return;
            pushUndoEntry(context, .{ .resize = .{ .view = view, .prev_custom_width = view.custom_width, .prev_floating = view.floating } });
            const base: f32 = @floatFromInt(@max(1, context.usable_area.width - @as(c_int, @intCast(context.gaps_out * 2))));
            const step: f32 = base * 0.05;
            const cur: f32 = @floatFromInt(ViewManager.getViewWidth(view));
            const new_w: f32 = if (action == .grow) cur + step else cur - step;
            view.custom_width = @max(200, @as(i32, @intFromFloat(new_w)));
            const idx = std.mem.indexOfScalar(*View, context.views.items, view) orelse 0;
            relayoutView(context, view, idx);
        },
        .reload_config => {
            // Free old heap-allocated config data before overwriting.
            const a = std.heap.c_allocator;
            a.free(context.keybinds);
            a.free(context.gestures);
            a.free(context.switches);
            a.free(context.submaps);
            a.free(context.rules);
            // A reloaded config may rename/remove submaps; leave the mode.
            context.active_submap = null;
            if (context.xkb_names.rules) |p| a.free(std.mem.span(p));
            if (context.xkb_names.model) |p| a.free(std.mem.span(p));
            if (context.xkb_names.layout) |p| a.free(std.mem.span(p));
            if (context.xkb_names.variant) |p| a.free(std.mem.span(p));
            if (context.xkb_names.options) |p| a.free(std.mem.span(p));

            const loaded = Config.load(context.io, a, true);
            context.applyConfig(loaded);
            for (context.views.items) |view| view.rulesApplyToLive(false);
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
                // On a mirror copy tile (pointer-hovered or keyboard-ringed),
                // close deletes only that copy. The source stays alive; its
                // real surface / self-mirror resumes once no copies remain.
                if (Mirror.closeFocusedMirrorCopy(context)) return;
                view.sendClose();
            }
        },
        .quit => {
            context.server.terminate();
        },
        .inspect => {
            Osd.inspect(context);
        },
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
                // width_ratio scales the usable width (post-waybar): ratio
                // 1.0 fills the area next to the bar.
                var ew: c_int = ow - 2 * context.gaps_out;
                if (context.usable_area.width > 0) {
                    const left = context.usable_area.x;
                    const right = ow - (context.usable_area.x + context.usable_area.width);
                    ew -= left + right;
                    // Both side gaps stay visible even at ratio 1.0.
                    ew -= 2 * context.gaps_out;
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
        .swap_left => swapTiles(context, -1),
        .swap_right => swapTiles(context, 1),
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
                        FocusManager.setFocus(context, .{ .view = .{ .view = f.view, .surface = f.view.surface(), .sx = 0, .sy = 0 } });
                    }
                },
                .focus => |f| {
                    if (f.restore) |view| {
                        if (view.isMapped()) {
                            FocusManager.setFocus(context, .{ .view = .{ .view = view, .surface = view.surface(), .sx = 0, .sy = 0 } });
                            ViewManager.scrollToView(context, view);
                        }
                    }
                },
                .row_switch => |r| {
                    Row.switchTo(context, r.prev_row);
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

fn submapBinds(context: *ServerContext, name: []const u8) ?[]const Config.CompiledBind {
    for (context.submaps) |s| {
        if (std.mem.eql(u8, s.name, name)) return s.binds;
    }
    return null;
}

/// Match `norm_sym` (+ mods) against `binds` with the same gating as the
/// root bind set (locked passthrough, hold-repeat, cooldown). A hit runs the
/// action and returns to the root binds (helix-style: the mode is a prefix,
/// not a sticky layer), or enters the named submap and stays in it.
/// Returns true when the keypress belonged to `binds` (fired or held).
fn dispatchKey(
    keyboard_context: *KeyboardContext,
    context: *ServerContext,
    binds: []const Config.CompiledBind,
    norm_sym: u32,
    depressed: u32,
) bool {
    for (binds) |bind| {
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
            if (suppressed) return true; // consumed; keep any active submap
            keyboard_context.last_fire_ms = now;
        }

        const entering = bind.action == .submap;
        runAction(context, bind.action, bind.args, null);
        // Entering a mode keeps it; any other action ends the mode.
        if (!entering) context.active_submap = null;
        return true;
    }
    return false;
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

        // Submap (mode) active: its binds match first. A key that matches
        // nothing leaves the mode so the next key is back to the root binds.
        if (context.active_submap) |name| {
            if (submapBinds(context, name)) |sbinds| {
                if (dispatchKey(keyboard_context, context, sbinds, norm_sym, depressed)) return;
            }
            context.active_submap = null;
        }
        if (dispatchKey(keyboard_context, context, context.keybinds, norm_sym, depressed)) return;
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
