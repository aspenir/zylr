const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");
const std = @import("std");

const ColorManagement = @import("color_management.zig");
const SecurityContext = @import("security_context.zig");
const TransientSeat = @import("input/transient_seat.zig");

/// Every global zylr advertises, created the way zylr creates it, on a bare
/// display. wlroots guards its preconditions with assert(), so a wrong
/// version, capability bit or enum (as color management did twice) aborts
/// the process - here, at build time, instead of at session start.
///
/// Protocols that need a renderer or backend are covered only when this
/// build can produce a headless one; the rest need a real session.
fn displayOnlyGlobalsCreate(server: *wl.Server) !void {
    _ = try wlr.Subcompositor.create(server);
    _ = try wlr.DataDeviceManager.create(server);
    _ = try wlr.PrimarySelectionDeviceManagerV1.create(server);
    _ = try wlr.DataControlManagerV1.create(server);
    _ = try wlr.XdgShell.create(server, 6);
    _ = try wlr.LayerShellV1.create(server, 5);
    _ = try wlr.Viewporter.create(server);
    _ = try wlr.FractionalScaleManagerV1.create(server, 1);
    _ = try wlr.SinglePixelBufferManagerV1.create(server);
    _ = try wlr.ContentTypeManagerV1.create(server, 1);
    _ = try wlr.TearingControlManagerV1.create(server, 1);
    _ = try wlr.GammaControlManagerV1.create(server);
    _ = try wlr.OutputLayout.create(server);
    _ = try wlr.OutputManagerV1.create(server);
    _ = try wlr.TabletManagerV2.create(server);
    _ = try wlr.PointerGesturesV1.create(server);
    _ = try wlr.ScreencopyManagerV1.create(server);
    _ = try wlr.ForeignToplevelManagerV1.create(server);
    _ = try wlr.SessionLockManagerV1.create(server);
    _ = try wlr.IdleNotifierV1.create(server);
    _ = try wlr.IdleInhibitManagerV1.create(server);
    _ = try wlr.KeyboardShortcutsInhibitManagerV1.create(server);
    _ = try wlr.AlphaModifierV1.create(server);
    _ = try wlr.CursorShapeManagerV1.create(server, 1);

    const xdg_foreign_registry = try wlr.XdgForeignRegistry.create(server);
    _ = try wlr.XdgForeignV2.create(server, xdg_foreign_registry);
}

// The globals added for the protocol batch, split out because these are the
// ones that regressed: color management twice (protocol version above what
// this wlroots allows, then an sRGB transfer function it forbids).
test "color management creates with zylr's options" {
    const server = try wl.Server.create();
    defer server.destroy();

    // The check is that this returns without wlroots asserting (wrong
    // version, forbidden transfer function, bad capability bit) - the
    // create call itself fails loudly if wlroots hands back nothing.
    _ = try ColorManagement.createOn(server);
}

test "the optional protocol managers create" {
    const server = try wl.Server.create();
    defer server.destroy();

    const transient_seat = try TransientSeat.create(server);
    transient_seat.create_listener.link.remove();

    _ = try SecurityContext.create(server);
    _ = try wlr.ExtWorkspaceManagerV1.create(server, 1);
}

test "display-only globals create without asserting" {
    const server = try wl.Server.create();
    defer server.destroy();

    try displayOnlyGlobalsCreate(server);
}
