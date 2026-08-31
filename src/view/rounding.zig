const wlroots = @import("wlroots");

/// scenefx-0.5 (a wlroots 0.20 scene-graph fork, linked ahead of
/// wlroots-0.20 like mango does) adds rounded corners to scene rects
/// and buffers. The renderer is scenefx's fx renderer; these externs
/// bind to libscenefx. Radius 0 means square (skip the call entirely).
pub const CornerRadii = extern struct {
    top_left: u16,
    top_right: u16,
    bottom_right: u16,
    bottom_left: u16,
};

/// Mango-style border: a full-box rect whose interior (the window
/// area) is clipped out, so the rect renders as a pure ring that can
/// never tint the window, whatever the client's transparency or the
/// scene z-order. Node-relative box.
pub const ClippedRegion = extern struct {
    area: wlroots.Box,
    corners: CornerRadii,
};

extern fn wlr_scene_rect_set_corner_radii(rect: *wlroots.SceneRect, corners: CornerRadii) void;
extern fn wlr_scene_buffer_set_corner_radii(buffer: *wlroots.SceneBuffer, corners: CornerRadii) void;
extern fn wlr_scene_rect_set_clipped_region(rect: *wlroots.SceneRect, region: ClippedRegion) void;

pub fn setRectCorners(rect: *wlroots.SceneRect, radius: u16) void {
    if (radius == 0) return;
    wlr_scene_rect_set_corner_radii(rect, all(radius));
}

pub fn setBufferCorners(buffer: *wlroots.SceneBuffer, radius: u16) void {
    if (radius == 0) return;
    wlr_scene_buffer_set_corner_radii(buffer, all(radius));
}

pub fn setRectClip(rect: *wlroots.SceneRect, box: wlroots.Box, radius: u16) void {
    if (radius == 0) return;
    // A zero/negative area box produces an empty pixman region and can
    // trip assertions in the clipped-region render path (CSD clients
    // commit geometry 0x0 during unfloat/quit transitions).
    if (box.width <= 0 or box.height <= 0) return;
    wlr_scene_rect_set_clipped_region(rect, .{
        .area = box,
        .corners = all(radius),
    });
}

pub fn clearBufferCorners(buffer: *wlroots.SceneBuffer) void {
    wlr_scene_buffer_set_corner_radii(buffer, zero());
}

pub fn clearRectCorners(rect: *wlroots.SceneRect) void {
    wlr_scene_rect_set_corner_radii(rect, zero());
}

fn zero() CornerRadii {
    return .{ .top_left = 0, .top_right = 0, .bottom_right = 0, .bottom_left = 0 };
}

fn all(radius: u16) CornerRadii {
    return .{
        .top_left = radius,
        .top_right = radius,
        .bottom_right = radius,
        .bottom_left = radius,
    };
}
