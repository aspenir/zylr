const wlroots = @import("wlroots");

pub const NodeData = union(enum) {
    view: *anyopaque,
    layer: *anyopaque,
    /// Input-method popup surface (on-screen keyboard). Pointer/touch
    /// must be routed to its surface so taps reach the IM client.
    im_popup: *anyopaque,
    /// xdg popup (menu, tooltip). Pointer/touch/tablet must route to its
    /// surface so clicks reach the popup instead of falling through to
    /// the toplevel view underneath.
    popup: *anyopaque,
};

pub fn resolveAt(tree: *wlroots.SceneTree, x: f64, y: f64) ?struct { data: *NodeData, sx: f64, sy: f64 } {
    var sx: f64 = 0;
    var sy: f64 = 0;
    const node = tree.node.at(x, y, &sx, &sy) orelse return null;
    var current: ?*wlroots.SceneNode = node;
    while (current) |n| {
        if (n.data) |data_ptr| {
            return .{ .data = @ptrCast(@alignCast(data_ptr)), .sx = sx, .sy = sy };
        }
        current = if (n.parent) |parent| &parent.node else null;
    }
    return null;
}
