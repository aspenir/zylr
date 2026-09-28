const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");
const std = @import("std");

const ServerContext = @import("server.zig");
const Row = @import("row.zig");

/// ext-workspace-v1 with one workspace per row: shells and tab bars
/// (waybar's wlr/workspaces module, gtk-layer-shell tabs) can enumerate and
/// switch rows over the wire instead of only through keybinds. Rows are a
/// fixed set, so there is no dynamic create/remove and exactly one is active.
pub const Workspace = @This();

/// v1 defines no workspace capabilities, so the C enum is always 0. The
/// zig-wlroots wrapper cannot be used here: its caps parameter is typed as
/// a capabilities enum that the v1 protocol never defines.
extern fn wlr_ext_workspace_handle_v1_create(
    manager: *wlr.ExtWorkspaceManagerV1,
    id: ?[*:0]const u8,
    capabilities: u32,
) ?*wlr.ExtWorkspaceHandleV1;

manager: *wlr.ExtWorkspaceManagerV1,
/// Rows live in one group covering the output. The protocol allows
/// group-less workspaces, but Quickshell models ext-workspace groups as
/// WindowsetProjections and only lists a projection's workspaces once they
/// are assigned to it - ungrouped rows show up as an empty taskbar.
group: *wlr.ExtWorkspaceGroupHandleV1,
handles: [ServerContext.max_rows]?*wlr.ExtWorkspaceHandleV1,
commit_listener: wl.Listener(*wlr.ExtWorkspaceManagerV1.event.Commit),
/// Set by init; a bare create() (tests) has no rows to switch.
context: ?*ServerContext = null,

pub fn create(server: *wl.Server) !*Workspace {
    const self = try std.heap.c_allocator.create(Workspace);
    self.* = .{
        .manager = try wlr.ExtWorkspaceManagerV1.create(server, 1),
        .group = undefined,
        .handles = [_]?*wlr.ExtWorkspaceHandleV1{null} ** ServerContext.max_rows,
        .commit_listener = undefined,
    };

    // No capabilities: rows are a fixed set, so clients may not create or
    // remove workspaces, only activate them.
    self.group = try self.manager.createGroup(.{});

    for (0..ServerContext.max_rows) |row| {
        var buf: [8]u8 = undefined;
        const name = try std.fmt.bufPrintZ(&buf, "{d}", .{row + 1});
        const handle = wlr_ext_workspace_handle_v1_create(self.manager, name.ptr, 0) orelse
            return error.OutOfMemory;
        handle.setName(name.ptr);
        handle.setGroup(self.group);
        self.handles[row] = handle;
    }

    self.commit_listener = wl.Listener(*wlr.ExtWorkspaceManagerV1.event.Commit).init(onCommit);
    self.manager.events.commit.add(&self.commit_listener);
    self.setActive(0);
    return self;
}

pub fn init(context: *ServerContext) !*Workspace {
    const self = try create(context.server);
    self.context = context;
    // Configured names replace the "1".."8" defaults; short or missing
    // entries keep the number, so a 3-name list is fine on 8 rows.
    const names = context.cfg.workspace_names;
    if (names.len > 0) {
        for (names, 0..) |name, row| {
            if (row >= ServerContext.max_rows) break;
            const handle = self.handles[row] orelse continue;
            const zname = std.heap.c_allocator.dupeZ(u8, name) catch continue;
            defer std.heap.c_allocator.free(zname);
            handle.setName(zname.ptr);
        }
    }
    self.setActive(context.active_row);
    return self;
}

/// wlroots asserts on display destroy with the commit listener attached.
pub fn detachListeners(self: *Workspace) void {
    self.commit_listener.link.remove();
}

pub fn rowOf(self: *Workspace, handle: *wlr.ExtWorkspaceHandleV1) ?usize {
    for (self.handles, 0..) |candidate, row| {
        if (candidate == handle) return row;
    }
    return null;
}

pub fn setActive(self: *Workspace, row: usize) void {
    for (self.handles, 0..) |maybe, i| {
        const handle = maybe orelse continue;
        const want = i == row;
        if (handle.state.active != want) handle.setActive(want);
    }
}

/// The group is announced before any output exists (outputs arrive from the
/// backend after the globals are created), and clients can only map a group
/// to a screen through output_enter - without it Quickshell's
/// WindowsetProjection stays empty.
pub fn onOutputAdded(context: *ServerContext, output: *wlr.Output) void {
    const self = context.workspace orelse return;
    self.group.outputEnter(output);
}

pub fn onOutputRemoved(context: *ServerContext, output: *wlr.Output) void {
    const self = context.workspace orelse return;
    self.group.outputLeave(output);
}

/// Called after a row switch from any source (keybind, gesture, taskbar) so
/// protocol clients see the same active workspace the compositor shows.
pub fn onRowActivated(context: *ServerContext, row: usize) void {
    const self = context.workspace orelse return;
    self.setActive(row);
}

fn onCommit(
    listener: *wl.Listener(*wlr.ExtWorkspaceManagerV1.event.Commit),
    event: *wlr.ExtWorkspaceManagerV1.event.Commit,
) void {
    const self: *Workspace = @fieldParentPtr("commit_listener", listener);
    const context = self.context orelse return;

    var it = event.requests.iterator(.forward);
    while (it.next()) |request| {
        switch (request.type) {
            .activate => {
                const handle = request.data.activate.workspace orelse continue;
                const row = self.rowOf(handle) orelse continue;
                // switchTo updates the protocol state through onRowActivated.
                Row.switchTo(context, row);
            },
            // One row is always active and the row set is fixed, so there is
            // nothing to do for the rest.
            .deactivate, .assign, .create_workspace, .remove => {},
        }
    }
}

test "workspaces map to rows and track the active row" {
    const server = try wl.Server.create();
    const self = try create(server);

    try std.testing.expectEqual(@as(usize, ServerContext.max_rows), self.handles.len);
    for (self.handles, 0..) |maybe, row| {
        const handle = maybe.?;
        try std.testing.expectEqual(@as(?usize, row), self.rowOf(handle));
    }

    try std.testing.expect(self.handles[0].?.state.active);
    try std.testing.expect(!self.handles[1].?.state.active);

    self.setActive(3);
    try std.testing.expect(!self.handles[0].?.state.active);
    try std.testing.expect(self.handles[3].?.state.active);
    try std.testing.expect(!self.handles[4].?.state.active);

    // The manager is torn down with the display and asserts that nothing is
    // still listening, so detach before dropping the server.
    self.detachListeners();
    for (self.handles) |maybe| {
        if (maybe) |handle| handle.destroy();
    }
    server.destroy();
}
