const wlroots = @import("wlroots");
pub const Handle = opaque {};

extern fn wlr_xcursor_manager_create(name: ?[*:0]const u8, size: u32) ?*Handle;
extern fn wlr_xcursor_manager_destroy(manager: *Handle) void;
extern fn wlr_xcursor_manager_load(manager: *Handle, scale: f32) bool;
extern fn wlr_cursor_set_xcursor(cursor: *wlroots.Cursor, manager: *Handle, name: [*:0]const u8) void;

handle: *Handle,

const Self = @This();

pub fn create(name: ?[*:0]const u8, size: u32) ?Self {
    // TODO: graceful error
    const ptr = wlr_xcursor_manager_create(name, size).?;
    return Self{ .handle = ptr };
}

pub fn destroy(self: Self) void {
    wlr_xcursor_manager_destroy(self.handle);
}

pub fn load(self: Self, scale: f32) bool {
    return wlr_xcursor_manager_load(self.handle, scale);
}

pub fn setXcursor(self: Self, cursor: *wlroots.Cursor, name: [*:0]const u8) void {
    wlr_cursor_set_xcursor(cursor, self.handle, name);
}
