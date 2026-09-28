const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");
const std = @import("std");

const ServerContext = @import("../server.zig");

/// ext-transient-seat-v1: a client can ask for a short-lived seat for its
/// own transient surfaces (launchers, menus) so they do not fight over the
/// compositor's main seat. zylr runs a single seat, so every request is
/// granted that one - the same answer sway gives.
pub const TransientSeat = @This();

var self_: ?*TransientSeat = null;

context: *ServerContext,
manager: *wlr.TransientSeatManagerV1,
create_listener: wl.Listener(*wlr.TransientSeatV1) = undefined,

pub fn create(server: *wl.Server) !*TransientSeat {
    const self = try std.heap.c_allocator.create(TransientSeat);
    self.* = .{
        .context = undefined,
        .manager = try wlr.TransientSeatManagerV1.create(server),
        .create_listener = undefined,
    };
    self.create_listener = wl.Listener(*wlr.TransientSeatV1).init(onCreateSeat);
    self.manager.events.create_seat.add(&self.create_listener);
    self_ = self;
    return self;
}

pub fn init(context: *ServerContext) !*TransientSeat {
    const self = try create(context.server);
    self.context = context;
    return self;
}

fn onCreateSeat(
    listener: *wl.Listener(*wlr.TransientSeatV1),
    seat: *wlr.TransientSeatV1,
) void {
    const self: *TransientSeat = @fieldParentPtr("create_listener", listener);
    seat.ready(self.context.seat);
}

test "manager can be created on a bare display" {
    const server = try wl.Server.create();
    defer server.destroy();

    // The value here is that wlroots builds the manager without asserting on
    // a bare display; detach the listener so teardown stays clean.
    const self = try create(server);
    self.create_listener.link.remove();
}
