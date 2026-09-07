const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const ServerContext = @import("server.zig");

pub const DrmLease = struct {
    manager: *wlr.DrmLeaseManagerV1,
    request_listener: wl.Listener(*wlr.DrmLeaseRequestV1) = undefined,

    pub fn init(context: *ServerContext) void {
        const manager = wlr.DrmLeaseManagerV1.create(context.server, context.backend) orelse {
            std.log.err("drm-lease manager create failed", .{});
            return;
        };
        const self = std.heap.c_allocator.create(DrmLease) catch {
            std.log.err("drm-lease alloc failed", .{});
            return;
        };
        self.* = .{ .manager = manager };
        self.request_listener = wl.Listener(*wlr.DrmLeaseRequestV1).init(onRequest);
        manager.events.request.add(&self.request_listener);
        context.drm_lease = manager;
    }

    /// zwlr_drm_lease_v1: hand a connector directly to a client (Waydroid,
    /// VR, Vulkan) for zero-copy head rendering. Auto-grant: a personal
    /// compositor has no reason to refuse a lease.
    fn onRequest(listener: *wl.Listener(*wlr.DrmLeaseRequestV1), request: *wlr.DrmLeaseRequestV1) void {
        _ = listener;
        _ = request.grant();
    }
};
