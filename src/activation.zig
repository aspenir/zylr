const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const ServerContext = @import("server.zig");
const FocusManager = @import("view/focus.zig");
const ViewManager = @import("view/view_manager.zig");
const View = @import("view/view.zig");

/// xdg-activation-v1: lets launchers/terminals hand the compositor an
/// activation token so the app they started can claim focus. wlroots
/// validates and expires tokens; we only decide what "granted" means:
/// focus the requesting window and scroll it into view, deduped through
/// the normal focus path. Requests aimed at a not-yet-mapped surface are
/// dropped — zylr auto-focuses windows on map anyway.
pub const Activation = @This();

context: *ServerContext,
manager: *wlr.XdgActivationV1,

request_activate_listener: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) = undefined,

pub fn init(context: *ServerContext) !void {
    const self = try std.heap.c_allocator.create(Activation);
    self.* = .{
        .context = context,
        .manager = try wlr.XdgActivationV1.create(context.server),
    };
    self.request_activate_listener = wl.Listener(*wlr.XdgActivationV1.event.RequestActivate).init(onRequestActivate);
    self.manager.events.request_activate.add(&self.request_activate_listener);

    context.activation = self;
}

pub fn deinit(self: *Activation) void {
    self.request_activate_listener.link.remove();
    std.heap.c_allocator.destroy(self);
}

fn onRequestActivate(
    listener: *wl.Listener(*wlr.XdgActivationV1.event.RequestActivate),
    event: *wlr.XdgActivationV1.event.RequestActivate,
) void {
    const self: *Activation = @fieldParentPtr("request_activate_listener", listener);

    // The request often names a popup or subsurface of a toplevel.
    const root = event.surface.getRootSurface();

    for (self.context.views.items) |v| {
        if (!v.isMapped()) continue;
        const surf = v.surfaceOrNull() orelse continue;
        if (surf != root) continue;
        FocusManager.setFocus(self.context, .{
            .view = .{ .view = v, .surface = null, .sx = 0, .sy = 0 },
        });
        ViewManager.scrollToView(self.context, v);
        return;
    }
}
