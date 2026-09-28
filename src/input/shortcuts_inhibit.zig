const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlroots = @import("wlroots");
const std = @import("std");

const ServerContext = @import("../server.zig");

/// keyboard-shortcuts-inhibit-v1: a focused client (games, media) can ask
/// the compositor to stop eating keys. The wlroots manager owns the
/// inhibitor list, so we only sync activate/deactivate on the compositor's
/// key path and answer whether the compositor must stay out of it.
pub const ShortcutsInhibit = @This();

var self_: ?*ShortcutsInhibit = null;

manager: *wlroots.KeyboardShortcutsInhibitManagerV1,

pub fn init(context: *ServerContext) !*ShortcutsInhibit {
    const s = try std.heap.c_allocator.create(ShortcutsInhibit);
    s.* = .{ .manager = try wlroots.KeyboardShortcutsInhibitManagerV1.create(context.server) };
    self_ = s;
    return s;
}

/// Activate the inhibitor belonging to the focused surface (so the client
/// sees `active` before it starts swallowing keys), deactivate everyone
/// else's, and report whether the compositor must stay out of the key path.
pub fn isInhibited(context: *ServerContext) bool {
    const s = self_ orelse return false;
    const surface = context.seat.keyboard_state.focused_surface;
    var focused: ?*wlroots.KeyboardShortcutsInhibitorV1 = null;
    var it = s.manager.inhibitors.iterator(.forward);
    while (it.next()) |inhibitor| {
        if (surface != null and inhibitor.surface == surface.?) {
            if (!inhibitor.active) inhibitor.activate();
            focused = inhibitor;
        } else if (inhibitor.active) {
            inhibitor.deactivate();
        }
    }
    return focused != null;
}
