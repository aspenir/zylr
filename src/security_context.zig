const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const ServerContext = @import("server.zig");

/// security-context-v1: sandboxed clients (portal helpers, flatpak) declare
/// which sandbox engine runs them, so a compositor can treat them
/// differently. wlroots owns the protocol traffic - it answers a commit the
/// compositor cannot honour with `stopped` - so the compositor side is just
/// this manager, plus an optional global filter that consults
/// `lookupClient` later.
///
/// zylr enforces no sandboxes, so nothing is filtered on the strength of a
/// declared engine: the manager exists so clients can declare themselves and
/// the interface is there for a future filter.
pub fn create(server: *wl.Server) !*wlr.SecurityContextManagerV1 {
    return wlr.SecurityContextManagerV1.create(server);
}

pub fn init(context: *ServerContext) !*wlr.SecurityContextManagerV1 {
    return create(context.server);
}

test "manager can be created on a bare display" {
    const server = try wl.Server.create();
    defer server.destroy();

    _ = try wlr.SecurityContextManagerV1.create(server);
}
