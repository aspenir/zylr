const wlroots = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const std = @import("std");
const xkb = @import("xkbcommon");

/// A committed background-layer surface, captured for corner sampling:
/// the buffer plus its scene position, so the mask can pull the
/// wallpaper's pixels from behind a window's corners.
pub const Wallpaper = struct {
    buffer: *wlroots.Buffer,
    x: i32,
    y: i32,
    scale: f32,
    width: i32,
    height: i32,
};

const config = @import("config.zig");
const LayerView = @import("view/layer.zig");
const View = @import("view/view.zig");
const XCursorManager = @import("view/xcursor.zig");
const OutputContext = @import("output/output.zig");
const KeyboardContext = @import("input/keyboard.zig");
pub const ResizeEdge = enum { left, right };

pub const UndoEntry = union(enum) {
    none,
    resize: struct { view: *View, prev_custom_width: ?i32, prev_floating: bool },
    swap: struct { a: usize, b: usize },
    viewport: struct { prev_target: i32 },
    fullscreen: struct { view: *View, prev_fullscreen: bool },
    focus: struct { restore: ?*View },
};

// Ring buffer of undo snapshots (oldest overwritten first).
undo_history: [32]UndoEntry = [_]UndoEntry{.none} ** 32,
undo_count: u8 = 0,

scene: *wlroots.Scene,
output_layout: *wlroots.OutputLayout,
backend: *wlroots.Backend,
allocator: *wlroots.Allocator,
renderer: *wlroots.Renderer,
xdg_shell: *wlroots.XdgShell,
wayland_socket: []const u8,
focused_layer: ?*LayerView = null,
focused_surface: ?*wlroots.Surface = null,
focused_view: ?*View = null,
previous_focused_view: ?*View = null,
focus_history: std.ArrayListUnmanaged(*View) = .empty,
output: ?*wlroots.Output = null,
session: ?*wlroots.Session = null,
// child spawning info
io: std.Io,
environ_map: *std.process.Environ.Map,
// animation
animation_x: std.ArrayListUnmanaged(f32) = .empty,
animation_w: std.ArrayListUnmanaged(f32) = .empty,
animation_active: bool = false,
animation_timer: ?*wl.EventSource = null,
// Tiled-column slot lefts (absolute), cached for the cursor's
// resize-edge binary search. Rebuilt only when a layout pass bumps
// layout_seq; read only up to resize_len.
layout_seq: u32 = 0,
resize_views: [64]*View = undefined,
resize_lefts: [64]f64 = undefined,
resize_len: usize = 0,
resize_seq: u32 = 0,

// config
border_width: i32 = 8,
// Outer gap: inset between the screen edge and the outermost windows.
gaps_out: i32 = 16,
// Inner gap: spacing between adjacent windows in the column.
gaps_in: i32 = 8,
view_scale: f32 = 0,
focused_border_color: [4]f32 = .{ 0.3, 0.6, 1.0, 1.0 },
/// Corner radius (logical px) for rounded window corners; 0 disables.
corner_radius: i32 = 16,
/// Compiled keybind table (see config.zig); matched on every keypress.
keybinds: []const config.CompiledBind = &.{},
/// Compiled gesture table; matched at swipe/pinch/hold end.
gestures: []const config.CompiledGesture = &.{},
/// Compiled switch table; matched on lid/tablet-mode toggle.
switches: []const config.CompiledSwitch = &.{},
/// XKB rule names applied to physical keyboards; defaults to "gb",
/// overridden by the keyboard section of the config.
xkb_names: xkb.RuleNames = .{
    .rules = null,
    .model = null,
    .layout = "gb",
    .variant = null,
    .options = null,
},
/// Fraction of the output width used for a new window's custom width.
/// Full-width tiling is skipped while this is set.
view_width_ratio: f32 = 0.6,
wallpaper: ?Wallpaper = null,
/// Dedicated layer trees in fixed render order (background < bottom <
/// views < top < overlay), so layer surfaces and windows keep their
/// protocol-defined stacking regardless of launch order.
background_tree: ?*wlroots.SceneTree = null,
bottom_tree: ?*wlroots.SceneTree = null,
views_tree: ?*wlroots.SceneTree = null,
top_tree: ?*wlroots.SceneTree = null,
overlay_tree: ?*wlroots.SceneTree = null,
fullscreen_tree: ?*wlroots.SceneTree = null,

xcursor_manager: *XCursorManager,
server: *wl.Server,
output_contexts: std.ArrayListUnmanaged(*OutputContext) = .{
    .items = &.{},
    .capacity = 0,
},

views: std.ArrayListUnmanaged(*View) = .{
    .items = &.{},
    .capacity = 0,
},

/// Live xdg popups zylr has created, each with a destroy listener that
/// removes it. Used to walk popup parent chains by pointer lookup without
/// dereferencing parent surfaces that may already be freed during teardown.
popups: std.ArrayListUnmanaged(*@import("view/xdg.zig").PopupNode) = .{
    .items = &.{},
    .capacity = 0,
},

view_width: i32 = 800,
view_height: i32 = 600,

viewport_x: i32 = 0,
viewport_y: i32 = 0,
viewport_target: i32 = 0,
viewport_anim: f32 = 0,

// Mod+drag state for moving (reordering) the focused view in the column.
drag_active: bool = false,
drag_view: ?*View = null,

// Edge-drag state for resizing a window's width.
resize_active: bool = false,
resize_view: ?*View = null,
resize_edge: ResizeEdge = .right,
resize_start_x: f64 = 0,
resize_start_width: i32 = 0,
cursor_shape: enum { default, resize } = .default,
tiled_count: usize = 0,
dpms_off: bool = false,
/// Session lock state. When locked, only lock surfaces receive input.
locked: bool = false,
/// Idle management: inhibit, notifier, DPMS, and idle timer.
idle: ?*@import("idle.zig").Idle = null,
/// Session lock protocol handler.
session_lock: ?*@import("session_lock.zig").SessionLock = null,
/// Raw config (kept for idle timers and reload).
cfg: @import("config.zig").Config = .{},
keybind_repeat: config.RepeatConfig = .{},
gesture_repeat: config.RepeatConfig = .{},
/// Monotonic-ms stamp of the last gesture firing, for cooldowns.
last_gesture_fire_ms: u64 = 0,

seat: *wlroots.Seat,

keyboards: std.ArrayListUnmanaged(*KeyboardContext) = .{
    .items = &.{},
    .capacity = 0,
},
xkb_context: *xkb.Context,
layer_shell: *wlroots.LayerShellV1,
// All live layer-shell surfaces (bars etc.); used to compute the
// usable tiling area from exclusive zones.
layers: std.ArrayListUnmanaged(*LayerView) = .empty,
// Area left for tiled windows after subtracting layer exclusive zones.
usable_area: wlroots.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

cursor: *wlroots.Cursor,

cursor_motion_listener: wl.Listener(*wlroots.Pointer.event.Motion) = undefined,
cursor_motion_absolute_listener: wl.Listener(*wlroots.Pointer.event.MotionAbsolute) = undefined,
cursor_button_listener: wl.Listener(*wlroots.Pointer.event.Button) = undefined,
cursor_axis_listener: wl.Listener(*wlroots.Pointer.event.Axis) = undefined,
cursor_frame_listener: wl.Listener(*wlroots.Cursor) = undefined,

request_set_selection_listener: wl.Listener(*wlroots.Seat.event.RequestSetSelection) = undefined,
request_set_primary_selection_listener: wl.Listener(*wlroots.Seat.event.RequestSetPrimarySelection) = undefined,
new_input_listener: wl.Listener(*wlroots.InputDevice) = undefined,
new_virtual_keyboard_listener: wl.Listener(*wlroots.VirtualKeyboardV1) = undefined,
new_virtual_pointer_listener: wl.Listener(*wlroots.VirtualPointerManagerV1.event.NewPointer) = undefined,
new_output_listener: wl.Listener(*wlroots.Output) = undefined,
manager_apply_listener: wl.Listener(*wlroots.OutputConfigurationV1) = undefined,
manager_test_listener: wl.Listener(*wlroots.OutputConfigurationV1) = undefined,
output_manager: *wlroots.OutputManagerV1 = undefined,
tablet_manager: *wlroots.TabletManagerV2 = undefined,
pointer_gestures: *wlroots.PointerGesturesV1 = undefined,
screencopy_manager: *wlroots.ScreencopyManagerV1 = undefined,
toplevel_manager: *wlroots.ForeignToplevelManagerV1 = undefined,
new_xdg_toplevel_listener: wl.Listener(*wlroots.XdgToplevel) = undefined,
new_layer_surface_listener: wl.Listener(*wlroots.LayerSurfaceV1) = undefined,
xdg_decoration_manager: *wlroots.XdgDecorationManagerV1 = undefined,
new_decoration_listener: wl.Listener(*wlroots.XdgToplevelDecorationV1) = undefined,
xwayland: ?*wlroots.Xwayland = null,
new_xwayland_surface_listener: wl.Listener(*wlroots.XwaylandSurface) = undefined,

/// Clipboard: a client asked to own the selection. wlroots' data-device
/// manager handles the protocol side; the compositor must honor the
/// request by actually setting the seat selection.
pub fn onRequestSetSelection(
    listener: *wl.Listener(*wlroots.Seat.event.RequestSetSelection),
    event: *wlroots.Seat.event.RequestSetSelection,
) void {
    const context: *@This() =
        @fieldParentPtr("request_set_selection_listener", listener);
    context.seat.setSelection(event.source, event.serial);
}

/// Middle-click (primary selection) paste, X11-style.
pub fn onRequestSetPrimarySelection(
    listener: *wl.Listener(*wlroots.Seat.event.RequestSetPrimarySelection),
    event: *wlroots.Seat.event.RequestSetPrimarySelection,
) void {
    const context: *@This() =
        @fieldParentPtr("request_set_primary_selection_listener", listener);
    context.seat.setPrimarySelection(event.source, event.serial);
}

/// Apply a loaded config to the compositor context fields.
/// Called at startup and on config reload.
pub fn applyConfig(self: *@This(), loaded: config.Loaded) void {
    self.cfg = loaded.cfg;
    self.keybinds = loaded.binds;
    self.gestures = loaded.gestures;
    self.switches = loaded.switches;
    self.xkb_names = loaded.xkb_names;
    self.corner_radius = loaded.cfg.decorations.rounding;
    self.border_width = loaded.cfg.decorations.border.width;
    self.focused_border_color = loaded.border_color;
    self.gaps_out = loaded.cfg.windows.gaps_out;
    self.gaps_in = loaded.cfg.windows.gaps_in;
    self.view_width_ratio = loaded.cfg.width_ratio;
    self.view_scale = loaded.cfg.scale;
    self.keybind_repeat = loaded.cfg.keybind_repeat;
    self.gesture_repeat = loaded.cfg.gesture_repeat;
}

/// Drop undo snapshots referencing `view` before it is freed, so undo
/// can never touch a destroyed View.
pub fn discardUndoFor(self: *@This(), view: *View) void {
    for (&self.undo_history) |*entry| {
        switch (entry.*) {
            .resize => |r| if (r.view == view) {
                entry.* = .none;
            },
            .fullscreen => |f| if (f.view == view) {
                entry.* = .none;
            },
            .focus => |f| if (f.restore == view) {
                entry.* = .none;
            },
            else => {},
        }
    }
}

/// Monotonic milliseconds, for bind/gesture repeat cooldowns.
pub fn nowMs(self: *@This()) u64 {
    const ts = std.Io.Timestamp.now(self.io, .awake);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}
