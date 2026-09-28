const wayland = @import("wayland");
const wl = wayland.server.wl;
const xdg = wayland.server.xdg;
const std = @import("std");

const ServerContext = @import("server.zig");
const Spawner = @import("spawner.zig");

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// xdg-system-bell-v1: a client asks for the system bell (terminal bell,
/// notification sound). zylr has no opinion about bells, so it runs whatever
/// the config names and otherwise ignores them - no OSD, no sound of its own.
fn onBind(
    client: *wl.Client,
    context: *ServerContext,
    version: u32,
    id: u32,
) void {
    const bell = xdg.SystemBellV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    bell.setHandler(*ServerContext, onRequest, null, context);
}

fn onRequest(
    _: *xdg.SystemBellV1,
    request: xdg.SystemBellV1.Request,
    context: *ServerContext,
) void {
    switch (request) {
        .destroy => {},
        .ring => |ring| ringBell(context, ring.surface),
    }
}

fn ringBell(context: *ServerContext, surface: ?*wl.Surface) void {
    const command = context.cfg.bell_command;
    if (command.len == 0) {
        std.log.debug("bell: no bell_command configured, ignoring", .{});
        return;
    }

    // The protocol lets the client name the surface it associates the bell
    // with. A wayland object id means nothing to a script, so hand over the
    // window's identity instead - a notification script can then say which
    // window rang.
    var app_id: [*:0]const u8 = "";
    var title: [*:0]const u8 = "";
    if (surface) |s| {
        const ring_id = s.getId();
        for (context.views.items) |view| {
            // The protocol hands us a wl.Surface resource; compare ids to
            // match it against a view's wlr_surface.
            if (view.surface().resource.getId() == ring_id) {
                app_id = view.appId();
                title = view.title();
                break;
            }
        }
    }
    _ = setenv("ZYLR_BELL_APP_ID", app_id, 1);
    _ = setenv("ZYLR_BELL_TITLE", title, 1);

    std.log.info("bell: running '{s}'", .{command[0]});
    Spawner.launchProgram(context, context.environ_map, command);
}

pub fn init(context: *ServerContext) !void {
    _ = try wl.Global.create(context.server, xdg.SystemBellV1, 1, *ServerContext, context, onBind);
}
