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

const Config = @import("config.zig");
const LayerView = @import("view/layer.zig");
const View = @import("view/view.zig");
const XCursorManager = @import("view/xcursor.zig");
const OutputContext = @import("output/output.zig");
const KeyboardContext = @import("input/keyboard.zig");
const GestureContext = @import("input/gesture.zig");
const Activation = @import("activation.zig");
pub const ResizeEdge = enum { left, right };

/// Mod+drag drop-preview state: while non-null the hovered column's pile
/// lays out as if a phantom equal-share member had joined at `index` (the
/// dragged window does NOT move until release), and `drag_ghost` paints the
/// slot the drop would land in. Cleared on release.
pub const DragPreview = struct {
    view: *View,
    /// Pile mode: anchor/index = the column + phantom slot to join.
    /// Gutter mode (gutter_index != null): index = target list position after
    /// removal — the view drops as its own standalone column there.
    anchor: *View,
    index: usize,
    gutter_index: ?usize = null,
};

pub const UndoEntry = union(enum) {
    none,
    resize: struct { view: *View, prev_custom_width: ?i32, prev_pile_width: ?i32, prev_floating: bool },
    swap: struct { a: usize, b: usize },
    swap_layout: struct { start: usize, len_a: usize, len_b: usize },
    viewport: struct { prev_target: i32 },
    fullscreen: struct { view: *View, prev_fullscreen: bool },
    focus: struct { restore: ?*View },
    row_switch: struct { prev_row: usize },
};

/// One copy node inside a mirror tree: clones a scene buffer of the source's
/// real (hidden) scene tree - a subsurface or an xdg popup - at its exact
/// scene position, so the mirror reproduces wlroots' own composition.
pub const SubCopy = struct {
    /// Source surface: the sub-surface's wl_surface (identified by pointer).
    src: *wlroots.Surface,
    node: *wlroots.SceneBuffer,
    /// Mirror owning the copy, for re-feeding on the source's commits.
    owner: *Mirror,
    /// Commit listener on `src` so popup/subsurface content feeds live.
    commit: wl.Listener(*wlroots.Surface) = undefined,
    /// Destroy listener on `src` so dead surfaces can't dangle in the
    /// signal list (their freed memory would crash the next remove).
    destroy: wl.Listener(*wlroots.Surface) = undefined,
    /// True while the commit/destroy listeners are still linked.
    linked: bool = true,
};

pub const max_rows = 8;

/// One workspace "row": a horizontal stack of windows with its own
/// horizontal scroll. The compositor swaps the shared working set
/// (context.views + anim arrays + viewport_x) in and out of these on
/// row switches so the render/layout/animation code stays row-agnostic:
/// at any moment `context.views` IS the active row's window list.
pub const Row = struct {
    views: std.ArrayListUnmanaged(*View) = .empty,
    animation_x: std.ArrayListUnmanaged(f32) = .empty,
    animation_w: std.ArrayListUnmanaged(f32) = .empty,
    animation_y: std.ArrayListUnmanaged(f32) = .empty,
    /// Tween origins: where each view was when the swap was armed.
    from_x: std.ArrayListUnmanaged(f32) = .empty,
    from_w: std.ArrayListUnmanaged(f32) = .empty,
    from_y: std.ArrayListUnmanaged(f32) = .empty,
    /// Spring velocities for the swap physics path.
    vel_x: std.ArrayListUnmanaged(f32) = .empty,
    vel_w: std.ArrayListUnmanaged(f32) = .empty,
    vel_y: std.ArrayListUnmanaged(f32) = .empty,
    scroll_x: i32 = 0,
    target_x: i32 = 0,
    vp_vel: f32 = 0,
};
/// A row-switch slide/fade in flight. The outgoing row's windows stay
/// rendered (parked in `rows[]`) while the incoming row slides in over
/// them; the animation tick animates both rows and settles when done.
pub const RowAnim = struct {
    /// Row being switched away FROM; its windows slide out.
    from_row: usize,
    /// +1 for a downward switch (incoming slides in from below),
    /// -1 for an upward switch (incoming from above).
    dir: i32,
    /// Distance (px) both rows travel: the active row's vertical extent.
    slide: f32,
    /// Monotonic ms at which the transition started.
    started: u64,
    /// Spring progress (0 = start, 1 = landed) + velocity, for the
    /// physics-based row spring. Re-armed to 0 on every switch.
    progress: f32 = 0,
    vel: f32 = 0,
};

pub const Mirror = struct {
    view: *View,
    /// Source surface for manually-fed copies (non-self mirrors are plain
    /// scene buffers fed from surface.current per commit, not scene
    /// surfaces). Null for self-mirrors, which ride the surface itself.
    surf: ?*wlroots.Surface = null,
    tree: *wlroots.SceneTree,
    buf_node: ?*wlroots.SceneBuffer = null,
    /// Copy nodes for every subsurface in the source's surface tree,
    /// mirroring wlroots' unmirrored per-surface composition (Firefox renders
    /// content on subsurfaces; feeding only the toplevel leaves it blank).
    // Pointers, never values: these structs carry wl_listeners linked into
    // wlroots signal lists, so moving their bytes (swapRemove) would corrupt
    // the commit/destroy lists and GP or infinitely loop.
    sub_copies: std.ArrayListUnmanaged(*SubCopy) = .empty,
    /// Rounded full-box border rect under the buffer, like a window's.
    border_rect: ?*wlroots.SceneRect = null,

    active: bool = false,
    /// True for the derived self-mirror (renders at the source's own slot
    /// and rides the window); false for mirrored copies (independent tiles).
    is_self: bool = false,
    slot_x: i32 = 0,
    slot_y: i32 = 0,
    slot_w: i32 = 0,
    slot_h: i32 = 0,
    natural_w: i32 = 0,
    natural_h: i32 = 0,
    /// Raw source surface size at last placement, for resize detection (the
    /// re-place check matches live surface size against THIS, since
    /// natural_w/h are the geometry-clamped CONTENT box - for xdg windows
    /// with CSD margins the two differ and comparing bases caused a re-place
    /// on every commit).
    surf_w: i32 = 0,
    surf_h: i32 = 0,
    diag_buf: ?*wlroots.Buffer = null,
    /// Commit counter (diagnostics only).
    pushed: u32 = 0,
    feed_in_progress: bool = false,
    /// Row-flow docking for mirrored-copy tiles: the copy rides right after
    /// `dock_view` (its dock cluster), at `dock_order`. null = row lead
    /// (before the first window). Defaults: same-row mirror docks to its own
    /// source; cross-row mirror docks after the row's last tiled window.
    dock_view: ?*View = null,
    dock_order: u32 = 0,
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
tearing: ?*wlroots.TearingControlManagerV1 = null,
drm_lease: ?*wlroots.DrmLeaseManagerV1 = null,
wayland_socket: []const u8,
focused_layer: ?*LayerView = null,
focused_surface: ?*wlroots.Surface = null,
focused_view: ?*View = null,
previous_focused_view: ?*View = null,
/// When keyboard cycling lands on a mirrored copy, the slot_x of
/// exactly that tile. The focus ring then lights ONLY that copy instead
/// of every mirror of the focused view, so the active tile is obvious.
/// -1 = no anchor (all mirrors of the focused view are lit).
kbd_anchor_row: usize = 0,
kbd_anchor_slot_x: i32 = -1,
/// The exact tile the last keyboard-cycle press landed on: its view plus
/// the mirror slot_x (-1 = the view's home slot). Cycling anchors on this
/// tile, not the view's home, so a copy between A and B can be cycled PAST
/// (otherwise repeated Step+L spins on the copy forever).
kbd_cycle_view: ?*View = null,
kbd_cycle_slot: i32 = -1,
focus_history: std.ArrayListUnmanaged(*View) = .empty,
output: ?*wlroots.Output = null,
session: ?*wlroots.Session = null,
// child spawning info
io: std.Io,
environ_map: *std.process.Environ.Map,
// animation
animation_x: std.ArrayListUnmanaged(f32) = .empty,
animation_w: std.ArrayListUnmanaged(f32) = .empty,
animation_y: std.ArrayListUnmanaged(f32) = .empty,
/// Tween origins for the active row (snapshotted when re-armed).
from_x: std.ArrayListUnmanaged(f32) = .empty,
from_w: std.ArrayListUnmanaged(f32) = .empty,
from_y: std.ArrayListUnmanaged(f32) = .empty,
/// Spring velocities for the swap physics path.
vel_x: std.ArrayListUnmanaged(f32) = .empty,
vel_w: std.ArrayListUnmanaged(f32) = .empty,
vel_y: std.ArrayListUnmanaged(f32) = .empty,
animation_active: bool = false,
/// Monotonic ms of the last input-activity wake (idle.zig notifyActivity);
/// the frame loop uses it to keep presenting briefly around interaction.
last_input_ms: u64 = 0,
/// Number of client wl_buffer attaches since boot — a real-content-change
/// probe: damage can be spurious (a client re-commits stale damage with no
/// new buffer), but a buffer attach is never fake.
buffer_pixel_commits: u64 = 0,
/// Monotonic ms when the layout tween (swap) was last re-armed.
layout_anim_started: u64 = 0,
/// Monotonic ms when the viewport tween (focus) was last re-armed.
viewport_anim_started: u64 = 0,
/// Viewport scroll at viewport_anim_started (tween origin).
viewport_from: f32 = 0,
/// Viewport velocity for the spring (focus) path.
viewport_vel: f32 = 0,
/// Monotonic ms of the previous tick, for the spring integrator's dt.
last_tick_ms: u64 = 0,
/// Row-switch slide/fade in flight; null when no switch is animating.
row_anim: ?RowAnim = null,
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
/// Per-side border widths (resolved from config `width` + `sides`).
border_widths: Config.BorderWidths = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
// Outer gap: inset between the screen edge and the outermost windows.
gaps_out: i32 = 16,
// Inner gap: spacing between adjacent windows in the column.
gaps_in: i32 = 8,
view_scale: f32 = 0,
focused_border_color: Config.Color = .{ .solid = .{ 0.3, 0.6, 1.0, 1.0 } },
/// Dimmed focused color; ring for unfocused windows.
inactive_border_color: Config.Color = .{ .solid = .{ 0.3, 0.6, 1.0, 1.0 } },
/// Ring color for unfocused floating windows (falls back to inactive).
floating_border_color: Config.Color = .{ .solid = .{ 0.3, 0.6, 1.0, 1.0 } },
/// Ring color for a focused floating window (falls back to focused).
active_floating_border_color: ?Config.Color = null,
/// Ring color while the pointer hovers an unfocused window.
hover_border_color: ?Config.Color = null,
/// Breathe the focused ring's brightness over ~2s.
pulse_enabled: bool = false,
/// 0..1 brightness multiplier written each animation tick while pulsing.
pulse_dim: f32 = 1.0,
/// Last breathes that actually repainted the ring: pulse repaints are
/// threshold-gated so an idle desktop (ticking for the breathe alone)
/// skips identical frames.
pulse_last_dim: f32 = 1.0,
/// Blur is currently active (not relaxed): idle-relax drops the global
/// blur passes/radius to 0 and restores them when animation resumes.
blur_active: bool = true,
/// View currently under the cursor (drives the hover ring).
hovered_view: ?*View = null,
/// Corner radius (logical px) for rounded window corners; 0 disables.
corner_radius: i32 = 16,
/// Compiled keybind table (see config.zig); matched on every keypress.
keybinds: []const Config.CompiledBind = &.{},
/// Compiled submap bind sets (see config `submaps`).
submaps: []const Config.CompiledSubmap = &.{},
/// Compiled window rules (see config `rules`); matched per-view at map/reload.
rules: []const Config.CompiledRule = &.{},
/// Name of the currently active submap (mode); null = root bind set.
active_submap: ?[]const u8 = null,
/// Compiled gesture table; matched at swipe/pinch/hold end.
gestures: []const Config.CompiledGesture = &.{},
/// Compiled switch table; matched on lid/tablet-mode toggle.
switches: []const Config.CompiledSwitch = &.{},
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
/// On-screen inspect toast (super+i): a self-drawn text card over the
/// scene root. Above every layer tree; below the cursor.
osd_tree: ?*wlroots.SceneTree = null,
osd_buffer: ?*wlroots.Buffer = null,
osd_node: ?*wlroots.SceneBuffer = null,
osd_expiry: u64 = 0,

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
/// Lead gap held at the row head after a mirror collapse: when the last
/// mirror tile stood to the right of the source's home slot (a same-row
/// copy), the real window takes that tile's position and the vacated home
/// slot stays open via this width. `head_gap_owner` is the window whose
/// collapse opened it; cleared when that window closes.
head_gap: i32 = 0,
head_gap_owner: ?*View = null,

// Workspace rows. `views`/animation arrays/viewport_x above are the
// ACTIVE row's working set; the rest of the rows park their windows,
// animation arrays, and scroll offset in `rows[].` Switch with row.zig.
rows: [max_rows]?Row = [_]?Row{null} ** max_rows,
active_row: usize = 0,
/// Mirrors per row, independent of Row optional (active row's Row is null
/// but its mirrors must remain accessible).
row_mirrors: [max_rows]std.ArrayListUnmanaged(Mirror) = [_]std.ArrayListUnmanaged(Mirror){.empty} ** max_rows,
/// Mirror view pointers per row — survives row switches. Mirror trees are
/// destroyed on deactivation and recreated from this list on activation.
row_sources: [max_rows]std.ArrayListUnmanaged(*View) = [_]std.ArrayListUnmanaged(*View){.empty} ** max_rows,

// Mod+drag state for moving (reordering) the focused view in the column.
drag_active: bool = false,
drag_view: ?*View = null,
/// Cursor→window-top-left offset captured at drag start, so a floating
/// window follows the cursor without jumping to the grab point.
drag_off_x: i32 = 0,
drag_off_y: i32 = 0,
/// Active drag-preview state (see DragPreview).
drag_preview: ?DragPreview = null,
/// Ghost rect painted at the phantom slot during `drag_preview`.
drag_ghost: ?*wlroots.SceneRect = null,

// Edge-drag state for resizing a window's width.
resize_active: bool = false,
resize_view: ?*View = null,
resize_edge: ResizeEdge = .right,
resize_start_x: f64 = 0,
resize_start_width: i32 = 0,
resize_start_view_x: i32 = 0,
cursor_shape: enum { default, resize, grab } = .default,

// Pile divider drag: resize a member's vertical share by dragging the
// horizontal boundary between it and the member below. Driven by both
// the pointer and touch; pile_divider_y tracks the drag position.
pile_divider_active: bool = false,
pile_divider_view: ?*View = null,
pile_divider_y: f64 = 0,

tiled_count: usize = 0,
dpms_off: bool = false,
/// Session lock state. When locked, only lock surfaces receive input.
locked: bool = false,
/// Idle management: inhibit, notifier, DPMS, and idle timer.
idle: ?*@import("idle.zig").Idle = null,
activation: ?*Activation = null,
/// Session lock protocol handler.
session_lock: ?*@import("session_lock.zig").SessionLock = null,
/// Raw config (kept for idle timers and reload).
cfg: @import("config.zig").Config = .{},
keybind_repeat: Config.RepeatConfig = .{},
gesture_repeat: Config.RepeatConfig = .{},
/// Monotonic-ms stamp of the last gesture firing, for cooldowns.
last_gesture_fire_ms: u64 = 0,

seat: *wlroots.Seat,

keyboards: std.ArrayListUnmanaged(*KeyboardContext) = .{
    .items = &.{},
    .capacity = 0,
},
gesture_contexts: std.ArrayListUnmanaged(*GestureContext) = .{
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
pub fn applyConfig(self: *@This(), loaded: Config.Loaded) void {
    self.cfg = loaded.cfg;
    self.keybinds = loaded.binds;
    self.gestures = loaded.gestures;
    self.switches = loaded.switches;
    self.submaps = loaded.submaps;
    self.rules = loaded.rules;
    self.xkb_names = loaded.xkb_names;
    self.corner_radius = loaded.cfg.decorations.rounding;
    self.border_width = loaded.cfg.decorations.border.width;
    self.border_widths = loaded.border_widths;
    self.focused_border_color = loaded.border_color;
    self.inactive_border_color = loaded.inactive_border_color;
    self.floating_border_color = loaded.floating_border_color;
    self.active_floating_border_color = loaded.active_floating_border_color;
    self.hover_border_color = loaded.hover_border_color;
    self.pulse_enabled = loaded.cfg.decorations.border.pulse;
    self.gaps_out = loaded.cfg.windows.gaps_out;
    self.gaps_in = loaded.cfg.windows.gaps_in;
    self.view_width_ratio = loaded.cfg.width_ratio;
    self.view_scale = loaded.cfg.scale;
    self.keybind_repeat = loaded.cfg.keybind_repeat;
    self.gesture_repeat = loaded.cfg.gestures.repeat;
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

/// A client attached a fresh wl_buffer somewhere — the only authoritative
/// "the screen content will change" signal. Called from the surface commit
/// paths; the frame loop compares it against the last-presented count to
/// skip presents for damage-only commit storms.
pub fn markPixelChange(self: *@This()) void {
    for (self.output_contexts.items) |o| o.buffer_pixel_commits +|= 1;
}

/// Monotonic milliseconds, for bind/gesture repeat cooldowns.
pub fn nowMs(self: *@This()) u64 {
    const ts = std.Io.Timestamp.now(self.io, .awake);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}
