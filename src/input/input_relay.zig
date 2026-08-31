const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");

const ServerContext = @import("../server.zig");
const nd = @import("../view/utils/node_data.zig");

const Relay = @This();

seat: *wlroots.Seat,
server_context: *ServerContext,
input_method_manager: *wlroots.InputMethodManagerV2,
text_input_manager: *wlroots.TextInputManagerV3,

current_input_method: ?*wlroots.InputMethodV2 = null,
active_surface: ?*wlroots.Surface = null,
active_grab: ?*wlroots.InputMethodV2.KeyboardGrab = null,

new_input_method_listener: wl.Listener(*wlroots.InputMethodV2) = undefined,
new_text_input_listener: wl.Listener(*wlroots.TextInputV3) = undefined,

input_method_commit_listener: wl.Listener(void) = undefined,
input_method_grab_listener: wl.Listener(*wlroots.InputMethodV2.KeyboardGrab) = undefined,
input_method_destroy_listener: wl.Listener(void) = undefined,
input_method_new_popup_listener: wl.Listener(*wlroots.InputPopupSurfaceV2) = undefined,

grab_destroy_listener: wl.Listener(void) = undefined,

// Per-text-input relays to handle multiple clients (e.g. Firefox has many)
const TextInputRelay = struct {
    relay: *Relay,
    text_input: *wlroots.TextInputV3,
    enable_listener: wl.Listener(void) = undefined,
    commit_listener: wl.Listener(void) = undefined,
    disable_listener: wl.Listener(void) = undefined,
    destroy_listener: wl.Listener(void) = undefined,
};

const PopupContext = struct {
    popup: *wlroots.InputPopupSurfaceV2,
    destroy_listener: wl.Listener(void) = undefined,
    context: *ServerContext,
};

var relay_ptr: ?*Relay = null;

pub fn init(server: *wl.Server, seat: *wlroots.Seat, ctx: *ServerContext) !*Relay {
    const self = try std.heap.c_allocator.create(Relay);
    self.* = .{
        .seat = seat,
        .server_context = ctx,
        .input_method_manager = try wlroots.InputMethodManagerV2.create(server),
        .text_input_manager = try wlroots.TextInputManagerV3.create(server),
    };
    self.new_input_method_listener = wl.Listener(*wlroots.InputMethodV2).init(onNewInputMethod);
    self.new_text_input_listener = wl.Listener(*wlroots.TextInputV3).init(onNewTextInput);
    self.input_method_manager.events.new_input_method.add(&self.new_input_method_listener);
    self.text_input_manager.events.new_text_input.add(&self.new_text_input_listener);
    relay_ptr = self;
    return self;
}

/// Client that owns a wlr_surface (via its protocol resource).
fn surfaceClient(s: *wlroots.Surface) *wl.Client {
    return s.resource.getClient();
}

pub fn updateFocus(self: *Relay, surface: ?*wlroots.Surface) void {
    std.log.debug("updateFocus surface={?*}", .{surface});
    const old = self.active_surface;
    self.active_surface = surface;
    // Inform text_inputs of focus change - wlroots requires explicit enter/leave.
    // wlr_text_input_v3_send_enter asserts the TI's client matches the new
    // surface's client and that focused_surface is null. Guard both so a layer
    // surface committing (waybar/awww-daemon) while another app owns the TI
    // doesn't abort the compositor in wlroots.
    var it = self.text_input_manager.text_inputs.iterator(.forward);
    while (it.next()) |ti| {
        if (ti.seat != self.seat) continue;
        if (ti.focused_surface == old and old != null) ti.sendLeave();
        if (surface) |s| {
            if (ti.focused_surface == null and
                surfaceClient(s) == ti.resource.getClient())
            {
                ti.sendEnter(s);
            }
        }
    }
    relayToInputMethod(self);
}

fn findActiveTextInput(self: *Relay) ?*wlroots.TextInputV3 {
    var it = self.text_input_manager.text_inputs.iterator(.forward);
    while (it.next()) |ti| {
        if (ti.current_enabled and ti.focused_surface == self.active_surface) return ti;
    }
    return null;
}

fn relayToInputMethod(self: *Relay) void {
    const im = self.current_input_method orelse return;
    const surface = self.active_surface;
    const ti = findActiveTextInput(self);
    std.log.debug("relayToInputMethod: surface={?*} ti={?*} active={} should={}", .{ surface, ti, im.active, ti != null and surface != null });
    const should_active = ti != null and surface != null;

    if (should_active and !im.active) {
        std.log.info("IM activate for surface {*}, TI {s}", .{ surface.?, if (ti) |tt| if (tt.current.surrounding.text) |tx| std.mem.span(tx) else "(no text)" else "" });
        im.sendActivate();
    } else if (!should_active and im.active) {
        std.log.info("IM deactivate", .{});
        im.sendDeactivate();
        // send_done after deactivate so wlroots flips client_active to
        // false; otherwise the OSK input-method popup is never unmapped
        // and squeekboard stays on screen after the text box loses focus.
        im.sendDone();
    }

    if (should_active) {
        if (ti) |txt| {
            if (txt.current.surrounding.text) |text| {
                im.sendSurroundingText(text, txt.current.surrounding.cursor, txt.current.surrounding.anchor);
            }
            im.sendContentType(txt.current.content_type.hint, txt.current.content_type.purpose);
            im.sendTextChangeCause(txt.current.text_change_cause);
            var it = im.popup_surfaces.iterator(.forward);
            while (it.next()) |popup| {
                popup.sendTextInputRectangle(&txt.current.cursor_rectangle);
            }
        }
        im.sendDone();
    }
}

fn relayToTextInput(self: *Relay, im: *wlroots.InputMethodV2) void {
    // On the commit event wlroots has already copied pending -> current
    // and zeroed pending, so the committed state lives in `current`.
    if (findActiveTextInput(self)) |ti| {
        if (im.current.commit_text) |text| {
            ti.sendCommitString(text);
        }
        if (im.current.preedit.text) |text| {
            ti.sendPreeditString(text, im.current.preedit.cursor_begin, im.current.preedit.cursor_end);
        }
        if (im.current.delete.before_length > 0 or im.current.delete.after_length > 0) {
            ti.sendDeleteSurroundingText(im.current.delete.before_length, im.current.delete.after_length);
        }
        ti.sendDone();
    }
    // Ack the input-method client with its own done event; without it a
    // client doing a synchronous wl_display_roundtrip (squeekboard blocks
    // on one during SIGTERM cleanup) never gets a reply and hangs, so
    // `pkill squeekboard` leaves the process alive.
    im.sendDone();
}

fn onNewInputMethod(listener: *wl.Listener(*wlroots.InputMethodV2), input_method: *wlroots.InputMethodV2) void {
    const self: *Relay = @fieldParentPtr("new_input_method_listener", listener);
    std.log.info("new input method {x}", .{@intFromPtr(input_method)});
    self.current_input_method = input_method;

    self.input_method_commit_listener = wl.Listener(void).init(onInputMethodCommit);
    self.input_method_grab_listener = wl.Listener(*wlroots.InputMethodV2.KeyboardGrab).init(onInputMethodGrabKeyboard);
    self.input_method_destroy_listener = wl.Listener(void).init(onInputMethodDestroy);
    self.input_method_new_popup_listener = wl.Listener(*wlroots.InputPopupSurfaceV2).init(onNewPopup);

    input_method.events.commit.add(&self.input_method_commit_listener);
    input_method.events.grab_keyboard.add(&self.input_method_grab_listener);
    input_method.events.destroy.add(&self.input_method_destroy_listener);
    input_method.events.new_popup_surface.add(&self.input_method_new_popup_listener);

    relayToInputMethod(self);
}

fn onInputMethodCommit(listener: *wl.Listener(void)) void {
    const self: *Relay = @fieldParentPtr("input_method_commit_listener", listener);
    const im = self.current_input_method orelse return;
    std.log.debug("IM commit text {?s} preedit {?s}", .{ if (im.current.commit_text) |st| std.mem.span(st) else null, if (im.current.preedit.text) |st| std.mem.span(st) else null });
    relayToTextInput(self, im);
}

fn onInputMethodGrabKeyboard(listener: *wl.Listener(*wlroots.InputMethodV2.KeyboardGrab), grab: *wlroots.InputMethodV2.KeyboardGrab) void {
    const self: *Relay = @fieldParentPtr("input_method_grab_listener", listener);
    self.active_grab = grab;
    self.grab_destroy_listener = wl.Listener(void).init(onGrabDestroy);
    grab.events.destroy.add(&self.grab_destroy_listener);
    if (self.server_context.keyboards.items.len > 0) {
        const kb = self.server_context.keyboards.items[0].keyboard;
        grab.setKeyboard(kb);
    }
}

fn onGrabDestroy(listener: *wl.Listener(void)) void {
    const self: *Relay = @fieldParentPtr("grab_destroy_listener", listener);
    self.grab_destroy_listener.link.remove();
    self.active_grab = null;
}

fn onInputMethodDestroy(listener: *wl.Listener(void)) void {
    const self: *Relay = @fieldParentPtr("input_method_destroy_listener", listener);
    self.input_method_commit_listener.link.remove();
    self.input_method_grab_listener.link.remove();
    self.input_method_destroy_listener.link.remove();
    self.input_method_new_popup_listener.link.remove();
    if (self.active_grab) |_| {
        self.grab_destroy_listener.link.remove();
        self.active_grab = null;
    }
    self.current_input_method = null;
}

fn onNewPopup(listener: *wl.Listener(*wlroots.InputPopupSurfaceV2), popup: *wlroots.InputPopupSurfaceV2) void {
    const self: *Relay = @fieldParentPtr("input_method_new_popup_listener", listener);
    if (findActiveTextInput(self)) |ti| {
        popup.sendTextInputRectangle(&ti.current.cursor_rectangle);
    }
    const scene_tree = self.server_context.overlay_tree orelse self.server_context.top_tree orelse return;
    const node = scene_tree.createSceneSubsurfaceTree(popup.surface) catch {
        std.log.warn("failed to create popup subsurface tree", .{});
        return;
    };
    // Tag the OSK subtree so pointer/touch resolution routes taps to its
    // surface; without this the on-screen keyboard never receives input.
    const node_data = std.heap.c_allocator.create(nd.NodeData) catch return;
    node_data.* = .{ .im_popup = popup };
    node.node.data = node_data;
    popup.data = node_data;
    node.node.raiseToTop();

    // When the popup surface is torn down (e.g. pkill squeekboard), free
    // our NodeData and kick a repaint so the OSK image doesn't linger.
    const pc = std.heap.c_allocator.create(PopupContext) catch return;
    pc.* = .{ .popup = popup, .context = self.server_context };
    pc.destroy_listener = wl.Listener(void).init(onPopupDestroy);
    popup.events.destroy.add(&pc.destroy_listener);
}

fn onPopupDestroy(listener: *wl.Listener(void)) void {
    const pc: *PopupContext = @fieldParentPtr("destroy_listener", listener);
    pc.destroy_listener.link.remove();
    // The scene subsurface tree was auto-destroyed by wlroots when the
    // wl_surface was torn down; we only need to free our metadata tag.
    if (pc.popup.data) |data_ptr| {
        const nd_data: *nd.NodeData = @ptrCast(@alignCast(data_ptr));
        std.heap.c_allocator.destroy(nd_data);
        pc.popup.data = null;
    }
    if (pc.context.output) |out| out.scheduleFrame();
    std.heap.c_allocator.destroy(pc);
}

fn onNewTextInput(listener: *wl.Listener(*wlroots.TextInputV3), text_input: *wlroots.TextInputV3) void {
    const self: *Relay = @fieldParentPtr("new_text_input_listener", listener);
    std.log.info("new text input {x} seat {s} surface {*}", .{ @intFromPtr(text_input), text_input.seat.name, text_input.focused_surface });
    if (self.active_surface) |s| {
        if (text_input.seat == self.seat and
            text_input.focused_surface == null and
            surfaceClient(s) == text_input.resource.getClient())
        {
            text_input.sendEnter(s);
        }
    }
    const relay = std.heap.c_allocator.create(TextInputRelay) catch return;
    relay.* = .{
        .relay = self,
        .text_input = text_input,
    };
    relay.enable_listener = wl.Listener(void).init(onTextInputEnable);
    relay.commit_listener = wl.Listener(void).init(onTextInputCommit);
    relay.disable_listener = wl.Listener(void).init(onTextInputDisable);
    relay.destroy_listener = wl.Listener(void).init(onTextInputDestroy);
    // Store relay pointer in text_input.data for cleanup
    text_input.events.enable.add(&relay.enable_listener);
    text_input.events.commit.add(&relay.commit_listener);
    text_input.events.disable.add(&relay.disable_listener);
    text_input.events.destroy.add(&relay.destroy_listener);
}

fn onTextInputEnable(listener: *wl.Listener(void)) void {
    // A client enables its text_input only after receiving focus/click, so
    // re-evaluate the input-method activation here. Without this the IM
    // stays inactive (no OSK, no IME) until some later event re-triggers the
    // relay, which reads as "need a second click to focus the text box".
    const relay: *TextInputRelay = @fieldParentPtr("enable_listener", listener);
    relayToInputMethod(relay.relay);
}

fn onTextInputCommit(listener: *wl.Listener(void)) void {
    const relay: *TextInputRelay = @fieldParentPtr("commit_listener", listener);
    relayToInputMethod(relay.relay);
}

fn onTextInputDisable(listener: *wl.Listener(void)) void {
    const relay: *TextInputRelay = @fieldParentPtr("disable_listener", listener);
    relayToInputMethod(relay.relay);
}

fn onTextInputDestroy(listener: *wl.Listener(void)) void {
    const relay: *TextInputRelay = @fieldParentPtr("destroy_listener", listener);
    const self = relay.relay;
    relay.enable_listener.link.remove();
    relay.commit_listener.link.remove();
    relay.disable_listener.link.remove();
    relay.destroy_listener.link.remove();
    std.heap.c_allocator.destroy(relay);
    relayToInputMethod(self);
}

pub fn deinit(self: *Relay) void {
    self.new_input_method_listener.link.remove();
    self.new_text_input_listener.link.remove();
    relay_ptr = null;
    std.heap.c_allocator.destroy(self);
}

/// Called from focus path when keyboard focus changes.
pub fn notifyFocus(surface: ?*wlroots.Surface) void {
    if (relay_ptr) |r| r.updateFocus(surface);
}

/// Check if an input-method keyboard grab is active and handle the key.
/// Returns true if the key was consumed by the IM (caller should not forward to seat).
pub fn handleKey(keyboard: *wlroots.Keyboard, time_msec: u32, key: u32, state: wl.Keyboard.KeyState) bool {
    const self = relay_ptr orelse return false;
    const grab = self.active_grab orelse return false;
    if (grab.keyboard != keyboard) return false;
    grab.sendKey(time_msec, key, state);
    return true;
}

pub fn handleModifiers(keyboard: *wlroots.Keyboard, modifiers: *const wlroots.Keyboard.Modifiers) bool {
    const self = relay_ptr orelse return false;
    const grab = self.active_grab orelse return false;
    if (grab.keyboard != keyboard) return false;
    grab.sendModifiers(modifiers);
    return true;
}
