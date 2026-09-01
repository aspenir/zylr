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

const Hit = struct {
    data: *NodeData,
    /// Surface actually under the cursor. For XWayland/Steam this is
    /// usually a *subsurface*, not the view's top-level surface, so
    /// pointer/touch must be routed here with node-local coords or X11
    /// registration gets a wrong position and clicks miss.
    /// Null when the hit node is not backed by a wl_surface (e.g. a plain
    /// scene buffer); callers then fall back to the view's top-level
    /// surface rather than feeding garbage to wl_seat (which segfaults).
    surface: ?*wlroots.Surface,
    sx: f64,
    sy: f64,
};

/// The `wlr_surface` owning the given scene node (a buffer node, or the
/// nearest ancestor that is a surface). Returns null if no ancestor is a
/// scene surface (never fabricates a pointer — casting a node to a surface
/// makes wl_seat_pointer_enter crash).
pub fn hitSurface(node: *wlroots.SceneNode) ?*wlroots.Surface {
    var current: ?*wlroots.SceneNode = node;
    while (current) |n| {
        if (n.type == .buffer) {
            const sb = wlroots.SceneBuffer.fromNode(n);
            if (wlroots.SceneSurface.tryFromBuffer(sb)) |ss| return ss.surface;
        }
        current = if (n.parent) |parent| &parent.node else null;
    }
    return null;
}

pub fn resolveAt(tree: *wlroots.SceneTree, x: f64, y: f64) ?Hit {
    var sx: f64 = 0;
    var sy: f64 = 0;
    const node = tree.node.at(x, y, &sx, &sy) orelse return null;
    var current: ?*wlroots.SceneNode = node;
    while (current) |n| {
        if (n.data) |data_ptr| {
            return .{ .data = @ptrCast(@alignCast(data_ptr)), .surface = hitSurface(node), .sx = sx, .sy = sy };
        }
        current = if (n.parent) |parent| &parent.node else null;
    }
    return null;
}
