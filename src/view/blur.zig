const wlroots = @import("wlroots");

const View = @import("view.zig");
const ServerContext = @import("../server.zig");

pub const SceneBlur = opaque {};

extern "c" fn wlr_scene_blur_create(parent: *wlroots.SceneTree, width: c_int, height: c_int) ?*SceneBlur;
extern "c" fn wlr_scene_blur_set_size(blur: *SceneBlur, width: c_int, height: c_int) void;
extern "c" fn wlr_scene_blur_set_corner_radius(blur: *SceneBlur, radius: c_int) void;

extern "c" fn wlr_scene_set_blur_num_passes(scene: *wlroots.Scene, num_passes: c_int) void;
extern "c" fn wlr_scene_set_blur_radius(scene: *wlroots.Scene, radius: c_int) void;
extern "c" fn wlr_scene_set_blur_noise(scene: *wlroots.Scene, noise: f32) void;
extern "c" fn wlr_scene_set_blur_brightness(scene: *wlroots.Scene, brightness: f32) void;
extern "c" fn wlr_scene_set_blur_contrast(scene: *wlroots.Scene, contrast: f32) void;
extern "c" fn wlr_scene_set_blur_saturation(scene: *wlroots.Scene, saturation: f32) void;

pub const BlurParams = struct {
    passes: i32,
    radius: i32,
    noise: f32,
    brightness: f32,
    contrast: f32,
    saturation: f32,
};

pub fn initGlobal(scene: *wlroots.Scene, p: BlurParams) void {
    wlr_scene_set_blur_num_passes(scene, p.passes);
    wlr_scene_set_blur_radius(scene, p.radius);
    wlr_scene_set_blur_noise(scene, p.noise);
    wlr_scene_set_blur_brightness(scene, p.brightness);
    wlr_scene_set_blur_contrast(scene, p.contrast);
    wlr_scene_set_blur_saturation(scene, p.saturation);
}

pub fn applyConfig(context: *ServerContext) void {
    const bc = context.cfg.decorations.blur;
    if (bc.enabled) {
        initGlobal(context.scene, .{
            .passes = bc.passes,
            .radius = bc.radius,
            .noise = bc.noise,
            .brightness = bc.brightness,
            .contrast = bc.contrast,
            .saturation = bc.saturation,
        });
    }
    for (context.views.items) |view| {
        updateForView(view);
    }
}

pub fn createForView(view: *View, tree: *wlroots.SceneTree) void {
    const blur = wlr_scene_blur_create(tree, 1, 1) orelse return;
    const bw: i32 = @intCast(@max(0, view.context.border_width));
    const content_w = @max(1, view.slot_w - 2 * bw);
    const content_h = @max(1, view.slot_h - 2 * bw);
    wlr_scene_blur_set_size(blur, content_w, content_h);
    blurUpdateRadius(view, blur);
    const node: *wlroots.SceneNode = @alignCast(@ptrCast(blur));
    node.setPosition(bw, bw);
    // The blur must sit below the client's content so it blurs what's
    // behind the transparent window, not the window's own pixels. The
    // border ring may not exist yet (XWayland especially), so ignore it.
    if (view.border) |b| {
        node.placeBelow(if (surfaceNode(view)) |sn| sn else &b.rect.node);
    }
    view.blur_node = blur;
}

fn surfaceNode(view: *View) ?*wlroots.SceneNode {
    return switch (view.backend) {
        .xdg => blk: {
            var it = view.scene_tree.children.iterator(.forward);
            while (it.next()) |node| {
                if (node.type == .tree) break :blk node;
            }
            break :blk null;
        },
        .xwayland => if (view.surface_tree) |t| &t.node else null,
    };
}

pub fn updateForView(view: *View) void {
    const blur = view.blur_node orelse return;
    const node: *wlroots.SceneNode = @alignCast(@ptrCast(blur));

    if (!view.context.cfg.decorations.blur.enabled) {
        node.setEnabled(false);
        return;
    }

    // Keep the blur enabled even for surfaces the client reports as
    // opaque: zylr rounds window corners, so the corners are transparent
    // and must show the blurred backdrop. Gating on opaque hid the blur
    // behind every opaque window, so "blur doesn't work when enabled."
    node.setEnabled(true);
    const bw: i32 = @intCast(@max(0, view.context.border_width));
    const content_w = @max(1, view.slot_w - 2 * bw);
    const content_h = @max(1, view.slot_h - 2 * bw);
    wlr_scene_blur_set_size(blur, content_w, content_h);
    blurUpdateRadius(view, blur);
    node.setPosition(bw, bw);
}

/// Match the content area's inner corners: r -| 1.
fn blurUpdateRadius(view: *View, blur: *SceneBlur) void {
    const r: u16 = @intCast(@max(0, view.context.corner_radius));
    const inner_r: u16 = if (r > 0) r -| 1 else 0;
    wlr_scene_blur_set_corner_radius(blur, @intCast(inner_r));
}

pub fn lowerToBottom(view: *View) void {
    const blur = view.blur_node orelse return;
    const node: *wlroots.SceneNode = @alignCast(@ptrCast(blur));
    node.lowerToBottom();
}

pub fn destroyForView(view: *View) void {
    if (view.blur_node) |blur| {
        const node: *wlroots.SceneNode = @alignCast(@ptrCast(blur));
        node.data = null;
        node.destroy();
        view.blur_node = null;
    }
}
