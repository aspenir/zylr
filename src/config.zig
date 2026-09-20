//! Session configuration, loaded from $XDG_CONFIG_HOME/zylr/config.ziggy
//! (or ~/.config/...). A missing or malformed file falls back to the
//! defaults below, which reproduce the pre-config hardcoded behavior.

const std = @import("std");
const xkb = @import("xkbcommon");
const ziggy = @import("ziggy");

/// Output rotation: clockwise quarter turns of the primary display.
pub const Transform = enum {
    normal,
    /// Clockwise 90° (right edge becomes top).
    @"90",
    @"180",
    @"270",
};

pub const Action = enum {
    spawn,
    close,
    quit,
    /// Show an on-screen inspect toast for the focused window
    /// (app_id/WM_CLASS + title + rule verdict).
    inspect,
    focus_left,
    focus_right,
    /// Move focus to the pile member above/below the focused view.
    focus_up,
    focus_down,
    viewport_up,
    viewport_down,
    /// Multiply the focused window's width by 1.15 (or /1.15). On a pile
    /// member, widens/narrows the whole column (all members share it).
    grow,
    shrink,
    /// Adjust the focused pile member's vertical share inside its column.
    grow_share,
    shrink_share,
    /// Move the focused pile member one slot up/down inside its column.
    pile_up,
    pile_down,
    reload_config,
    toggle_floating,
    consume_left,
    consume_right,
    swap_left,
    swap_right,
    undo,
    toggle_fullscreen,
    /// Center the focused view on the output: floating views move to the
    /// output center, tiled views get the viewport scrolled to center them.
    center_window,
    dpms_off,
    /// Switch to the workspace row above/below.
    row_up,
    row_down,
    /// Mirror the focused view to the row given as the first arg ("mirror", "0").
    /// Creates a mirror showing the same live content on the target row.
    mirror,
    /// Enter the submap named by the first arg ("submap", "resize"); its
    /// binds then match first until an action or unmatched key leaves it.
    submap,
};

pub const Bind = struct {
    key: []const u8,
    action: Action,
    args: ?[]const []const u8 = null,
    through_lock: bool = false,
    /// The submap (mode) this bind belongs to; null = the always-active root
    /// bind set. Submaps are entered by an action=.submap bind (arg = name).
    submap: ?[]const u8 = null,
};

pub const GestureKind = enum { swipe, pinch, hold };

/// Direction resolved from accumulated motion at gesture end.
pub const GestureDir = enum { left, right, up, down, in, out };

pub const GestureDevice = enum { touch, trackpad, both };

pub const GestureBind = struct {
    fingers: u32,
    kind: GestureKind,
    /// swipe: left/right/up/down; pinch: in/out; hold: omit.
    dir: ?GestureDir = null,
    on: GestureDevice = .both,
    target: ?GestureTarget = null,
    action: Action,
    args: ?[]const []const u8 = null,
};

pub const GestureTarget = enum { focus, under_gesture };

pub const SwitchType = enum { lid, tablet_mode };
pub const SwitchState = enum { on, off };

pub const SwitchBind = struct {
    switch_type: SwitchType,
    state: SwitchState,
    action: Action,
    args: ?[]const []const u8 = null,
};

pub const IdleTimer = struct {
    timeout: u32 = 300,
    command: []const u8 = "",
};

/// Touchscreen gesture thresholds. Matched by touch.zig from raw
/// touch points; each knob is a live cfg read, so hot-reload applies.
pub const TouchGestureConfig = struct {
    /// Movement (normalized 0..1) that disqualifies a pending hold.
    hold_move_eps: f64 = 0.02,
    /// How long a still hold must last before it fires, ms.
    hold_ms: u32 = 600,
    /// A finger that lifts this fast while others stay down is a blip
    /// (palm/thumb brushing the screen), not a gesture finger. ms.
    blip_ms: u32 = 120,
    /// A 1-finger flick must finish within this to count, ms.
    flick_max_ms: u32 = 250,
    /// A swipe must travel at least this far to name a direction, px.
    swipe_min_px: f64 = 40,
    /// Pinch span change (relative to start) needed to fire, e.g. 1.15.
    pinch_ratio: f64 = 1.15,
};

/// Trackpad gesture thresholds (libinput pointer gestures).
pub const TrackpadGestureConfig = struct {
    /// A swipe must travel at least this far to name a direction.
    swipe_min_px: f64 = 25,
    /// Cumulative pinch scale change needed to fire (1 ± this).
    pinch_scale: f64 = 0.15,
};

pub const GestureConfig = struct {
    touch: TouchGestureConfig = .{},
    trackpad: TrackpadGestureConfig = .{},
    binds: []const GestureBind = &.{},
    /// Whether a gesture may re-fire while the gesture continues, and
    /// the minimum gap between consecutive gesture firings. Gestures
    /// default to firing once per gesture (old behavior).
    repeat: RepeatConfig = .{ .enabled = false },
};

/// Re-fire policy for binds and gestures.
pub const RepeatConfig = struct {
    /// Keybinds: re-run while the key is held (auto-repeat) and the
    /// gesture is still going. Default true preserves the old behavior.
    enabled: bool = true,
    /// Minimum gap between firings, ms. 0 = fire as fast as input allows.
    cooldown_ms: u32 = 0,
};

pub const KeyboardConfig = union(enum) {
    /// Bare layout name (e.g. "gb"); every other xkb rule stays default.
    preset: []const u8,
    custom: struct {
        rules: []const u8 = "",
        model: []const u8 = "",
        layout: []const u8 = "us",
        variant: []const u8 = "",
        options: []const u8 = "",
    },
};

pub const BlurConfig = struct {
    enabled: bool = false,
    passes: i32 = 2,
    radius: i32 = 6,
    noise: f32 = 0.002,
    brightness: f32 = 0.9,
    contrast: f32 = 1.1,
    saturation: f32 = 1.2,
};

/// A linear gradient between equal-spaced color stops.
pub const Gradient = struct {
    /// Angle in degrees; 0 sweeps left→right, 90 top→bottom.
    angle: f32 = 0,
    /// Stop colors, evenly spaced across the gradient (>= 2).
    colors: []const [4]f32,

    /// Sample the gradient at t in [0,1]. Skips gracefully for
    /// degenerate (0/1-stop) data.
    pub fn sample(self: Gradient, t: f32) [4]f32 {
        const n = self.colors.len;
        if (n == 0) return .{ 1, 0, 1, 1 };
        if (n == 1) return self.colors[0];
        const x = std.math.clamp(t, 0, 1) * @as(f32, @floatFromInt(n - 1));
        const i: usize = @intFromFloat(@floor(x));
        const f = x - @floor(x);
        const a = self.colors[i];
        const b = self.colors[@min(i + 1, n - 1)];
        const av: @Vector(4, f32) = a;
        const bv: @Vector(4, f32) = b;
        const out: @Vector(4, f32) = av + (bv - av) * @as(@Vector(4, f32), @splat(f));
        return out;
    }
};

/// A border color: either one flat color or a linear gradient.
pub const Color = union(enum) {
    solid: [4]f32,
    gradient: Gradient,

    /// The flat color at parameter t (solid ignores t). Mirrors and
    /// drag ghosts sample the midpoint to keep their single rects.
    pub fn sample(self: Color, t: f32) [4]f32 {
        return switch (self) {
            .solid => |c| c,
            .gradient => |g| g.sample(t),
        };
    }
};

/// Config-facing gradient spec (strings; compiled to floats in load()).
pub const GradientSpec = struct {
    angle: f32 = 0,
    colors: []const []const u8 = &.{},
};

/// Config-facing color spec, parsed from ziggy:
///   .color = .solid("#fd96a9")
///   .color = .gradient(.{ .angle = 90, .colors = ["#ff0000", "#00ff00"] })
pub const ColorSpec = union(enum) {
    solid: []const u8,
    gradient: GradientSpec,
};

/// Per-side border widths. `uniform(w)` builds an equal ring; the
/// renderers use `horizontal()`/`vertical()` for the content-box insets.
pub const BorderWidths = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,

    pub fn uniform(w: i32) BorderWidths {
        return .{ .top = w, .right = w, .bottom = w, .left = w };
    }

    pub fn horizontal(self: @This()) i32 {
        return self.left + self.right;
    }

    pub fn vertical(self: @This()) i32 {
        return self.top + self.bottom;
    }
};

pub const DecorationsConfig = struct {
    /// Corner radius in px; 0 disables rounding.
    rounding: i32 = 16,
    border: struct {
        /// Uniform width; each side falls back to it when `sides` is unset.
        width: i32 = 8,
        /// Per-side overrides on top of `width` (null side = use `width`).
        sides: struct {
            top: ?i32 = null,
            right: ?i32 = null,
            bottom: ?i32 = null,
            left: ?i32 = null,
        } = .{},
        color: ColorSpec = .{ .solid = "#4d99ff" },
        /// Border ring for unfocused windows. Defaults to a dimmed
        /// `color` when unset.
        inactive_color: ?ColorSpec = null,
        /// Border ring for unfocused floating windows. Defaults to the
        /// dimmed inactive ring when unset (floating looks like tiled
        /// until you pick a color).
        floating_color: ?ColorSpec = null,
        /// Border ring for a focused floating window. Defaults to `color`.
        active_floating_color: ?ColorSpec = null,
        /// Border ring while the pointer is over an unfocused window.
        /// Defaults to the normal unfocused ring when unset.
        hover_color: ?ColorSpec = null,
        /// Breathe the focused ring's brightness over ~2s (animation loop
        /// stays awake for the focused window).
        pulse: bool = false,
    } = .{},
    blur: BlurConfig = .{},
};

pub const WindowsConfig = struct {
    gaps_out: i32 = 16,
    gaps_in: i32 = 8,
};

pub const Rule = struct {
    class: ?[]const u8 = null,
    title: ?[]const u8 = null,
    rounding: ?i32 = null,
    border_width: ?i32 = null,
    border_color: ?ColorSpec = null,
    blur: ?bool = null,
    swallow: ?bool = null,
    float: ?bool = null,
};

pub const CompiledRule = struct {
    class: ?[]const u8,
    title: ?[]const u8,
    rounding: ?i32,
    border_width: ?i32,
    border_color: ?Color,
    blur: ?bool,
    swallow: ?bool,
    float: ?bool,
};

/// CSS-style cubic-bezier easing: control points (x1,y1) and (x2,y2), with
/// implicit anchors P0=(0,0) and P3=(1,1).
pub const Bezier = struct {
    x1: f32 = 0.33,
    y1: f32 = 0,
    x2: f32 = 0.67,
    y2: f32 = 1,

    fn at(p1: f32, p2: f32, t: f32) f32 {
        const u = 1 - t;
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t;
    }

    pub fn sample(self: Bezier, input: f32) f32 {
        const q = std.math.clamp(input, 0, 1);
        var t = q;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const x = at(self.x1, self.x2, t) - q;
            const d = 3 * (1 - t) * (1 - t) * self.x1 +
                6 * (1 - t) * t * (self.x2 - self.x1) +
                3 * t * t * (1 - self.x2);
            if (@abs(d) < 1e-6) break;
            const step = x / d;
            t = std.math.clamp(t - step, 0, 1);
            if (@abs(step) < 1e-5) break;
        }
        return at(self.y1, self.y2, t);
    }
};

/// Damped-spring easing: chases value 1 like a mass on a spring.
/// Underdamped springs overshoot and bounce; higher damping = less bounce.
pub const Spring = struct {
    stiffness: f32 = 180,
    damping: f32 = 26,

    pub fn sample(self: Spring, input: f32) f32 {
        const q = std.math.clamp(input, 0, 1);
        if (self.stiffness <= 0) return q;
        const w = @sqrt(self.stiffness);
        const z = self.damping / (2 * w);
        // Critical/overdamped settle by ~p=1; underdamped by when the
        // amplitude term has decayed ~50x.
        const settle = if (z < 1) @log(50 / @sqrt(1 - z * z)) / (z * w) else 6 / w;
        const t = q * settle;
        if (z < 1) {
            const wd = w * @sqrt(1 - z * z);
            const amp = 1 / @sqrt(1 - z * z);
            const e = @exp(-z * w * t);
            return 1 - e * (@cos(wd * t) + amp * @sin(wd * t));
        }
        const r1 = w * (z - @sqrt(z * z - 1));
        const r2 = w * (z + @sqrt(z * z - 1));
        return 1 - (r2 * @exp(-r1 * t) - r1 * @exp(-r2 * t)) / (r2 - r1);
    }
};

/// Named one-shot easing curves (unit step responses, 0 -> 1). `back` and
/// `elastic` overshoot past 1, so they only suit position/viewport tweens
/// (opacity callers clamp).
pub const EasingPreset = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
    back,
    expo,
    elastic,
    bounce,

    pub fn sample(self: EasingPreset, input: f32) f32 {
        const q = std.math.clamp(input, 0, 1);
        const u = 1 - q;
        switch (self) {
            .linear => return q,
            .ease_in => return q * q * q,
            .ease_out => return 1 - u * u * u,
            .ease_in_out => return if (q < 0.5) 4 * q * q * q else 1 - @as(f32, -2 * q + 2) * @as(f32, -2 * q + 2) * @as(f32, -2 * q + 2) / 2,
            .back => {
                // Overshoots ~10% past 1 then settles (easeOutBack).
                const c1: f32 = 1.70158;
                const c3 = c1 + 1;
                return 1 - c3 * u * u * u + c1 * u * u;
            },
            .expo => {
                if (q <= 0) return 0;
                if (q >= 1) return 1;
                return 1 - std.math.pow(f32, 2, -10 * q);
            },
            .elastic => {
                // easeOutElastic: several decaying overshoots.
                if (q <= 0) return 0;
                if (q >= 1) return 1;
                const c4: f32 = (2.0 * @as(f32, std.math.pi)) / 3.0;
                return std.math.pow(f32, 2, -10 * q) * @sin((q * 10 - 0.75) * c4) + 1;
            },
            .bounce => {
                // easeOutBounce: discrete floor-hit rebounds.
                const n1: f32 = 7.5625;
                const d1: f32 = 2.75;
                var x = q;
                if (x < 1 / d1) return n1 * x * x;
                if (x < 2 / d1) {
                    x -= 1.5 / d1;
                    return n1 * x * x + 0.75;
                }
                if (x < 2.5 / d1) {
                    x -= 2.25 / d1;
                    return n1 * x * x + 0.9375;
                }
                x -= 2.625 / d1;
                return n1 * x * x + 0.984375;
            },
        }
    }
};

/// How a window enters/leaves the screen, layered on top of the opacity
/// fade. `slide` also translates the surface vertically into/out of its
/// slot; `pop` scales the content gently over the first/last 20% of the
/// duration instead of fading the whole way.
pub const OpenCloseStyle = enum {
    fade,
    slide,
    pop,
};

pub const Easing = union(enum) {
    spring: Spring,
    bezier: Bezier,
    preset: EasingPreset,

    pub fn sample(self: Easing, p: f32) f32 {
        return switch (self) {
            .spring => |s| s.sample(p),
            .bezier => |b| b.sample(p),
            .preset => |e| e.sample(p),
        };
    }
};

/// One animation's timing: easing curve + duration in ms.
pub const AnimationSpec = struct {
    easing: Easing = .{ .bezier = .{} },
    /// Animation length in ms.
    ms: u64 = 200,
};

/// Per-animation timing. Each animation type has its own easing + duration.
pub const AnimationConfig = struct {
    /// Row-switch slide/fade.
    row: AnimationSpec = .{ .ms = 220 },
    /// Tile x/y/w slide when windows swap or the layout reflows.
    swap: AnimationSpec = .{ .ms = 200 },
    /// Viewport scroll when keyboard focus moves to a window.
    focus: AnimationSpec = .{ .ms = 200 },
    /// Window open fade-in.
    open: AnimationSpec = .{ .ms = 180 },
    /// Window close fade-out.
    close: AnimationSpec = .{ .ms = 180 },
    /// Window enter style (layered over the open fade).
    open_style: OpenCloseStyle = .fade,
    /// Window leave style (layered over the close fade).
    close_style: OpenCloseStyle = .fade,
    /// Focus-ring border colour transition on focus switches.
    border_color: AnimationSpec = .{ .ms = 150 },
};

pub const Config = struct {
    keyboard: KeyboardConfig = .{ .preset = "gb" },
    decorations: DecorationsConfig = .{},
    windows: WindowsConfig = .{},
    animation: AnimationConfig = .{},
    autostart: []const []const u8 = &.{},
    rules: []const Rule = &.{},
    keybinds: []const Bind = &default_keybinds,
    gestures: GestureConfig = .{},
    switches: []const SwitchBind = &.{},
    idle: []const IdleTimer = &.{},
    /// Whether a keybind may re-fire on key auto-repeat, and how often.
    keybind_repeat: RepeatConfig = .{},
    /// Give keyboard focus to the view under the pointer on hover
    /// (focus-follows-mouse) instead of only on click.
    focus_follows_mouse: bool = false,
    /// Run this command when the system is about to suspend (logind
    /// PrepareForSleep), typically a lock screen. Empty disables.
    lock_command: []const []const u8 = &.{},

    // New views take a fraction of the output width; zylr's tiling has no
    // absolute default width because it is output-relative.
    width_ratio: f32 = 0.6,
    /// Screen rotation for the primary output. `.normal`, `.90`, `.180`,
    /// `.270` are clockwise steps; reload applies the change live.
    transform: Transform = .normal,
    /// Output scale factor override; 0 = use the display's preferred scale.
    scale: f32 = 0,
    /// Adaptive sync (VRR/Freesync) on the main output. Some laptop panels
    /// flicker under the erratic frame rates caused by bursty pen/mouse
    /// input; set false to force the panel to its fixed refresh rate.
    vrr: bool = false,
};

/// The bind set that used to be hardcoded in onKeyboardKey.
const default_keybinds = [_]Bind{
    .{ .key = "Super+h", .action = .focus_left },
    .{ .key = "Super+j", .action = .row_down },
    .{ .key = "Super+k", .action = .row_up },
    .{ .key = "Super+l", .action = .focus_right },
    .{ .key = "Super+[", .action = .consume_left },
    .{ .key = "Super+]", .action = .consume_right },
    .{ .key = "Super+space", .action = .spawn, .args = &.{"fuzzel"} },
    .{ .key = "Super+v", .action = .toggle_floating },
    .{ .key = "Super+Shift+h", .action = .swap_left },
    .{ .key = "Super+Shift+l", .action = .swap_right },
    .{ .key = "Super+z", .action = .undo },
    .{ .key = "Super+f", .action = .toggle_fullscreen },
    .{ .key = "Super+q", .action = .close },
    .{ .key = "Super+i", .action = .inspect },
    .{ .key = "Super+minus", .action = .shrink },
    .{ .key = "Super+equal", .action = .grow },
    .{ .key = "Super+Escape", .action = .quit },
    .{ .key = "XF86AudioRaiseVolume", .action = .spawn, .args = &.{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%+" } },
    .{ .key = "XF86AudioLowerVolume", .action = .spawn, .args = &.{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%-" } },
    .{ .key = "XF86AudioMute", .action = .spawn, .args = &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" } },
    .{ .key = "XF86MonBrightnessUp", .action = .spawn, .args = &.{ "brightnessctl", "set", "5%+" } },
    .{ .key = "XF86MonBrightnessDown", .action = .spawn, .args = &.{ "brightnessctl", "set", "5%-" } },
};

/// A bind with its key string resolved once at load time, so the hot path
/// in onKeyboardKey is a plain integer comparison.
pub const CompiledBind = struct {
    mods: u32,
    sym: u32,
    action: Action,
    args: []const []const u8 = &.{},
    through_lock: bool = false,
};

/// A submap compiled the same way as the root binds, looked up by name when
/// `context.active_submap` is set.
pub const CompiledSubmap = struct {
    name: []const u8,
    binds: []const CompiledBind,
};

/// A gesture bind resolved against live gesture events; matched by
/// integer comparisons in gesture.zig.
pub const CompiledGesture = struct {
    fingers: u32,
    kind: GestureKind,
    dir: ?GestureDir,
    on: GestureDevice,
    target: ?GestureTarget = null,
    action: Action,
    args: []const []const u8 = &.{},
};

pub const CompiledSwitch = struct {
    switch_type: SwitchType,
    state: SwitchState,
    action: Action,
    args: []const []const u8 = &.{},
};

fn modBit(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "Super") or std.mem.eql(u8, name, "Mod4")) return 1 << 6;
    if (std.mem.eql(u8, name, "Ctrl") or std.mem.eql(u8, name, "Control")) return 1 << 2;
    if (std.mem.eql(u8, name, "Alt") or std.mem.eql(u8, name, "Mod1")) return 1 << 3;
    if (std.mem.eql(u8, name, "Shift")) return 1 << 0;
    return null;
}

pub const ParsedKey = struct { mods: u32, sym: u32 };

/// "Super+Ctrl+o" -> { mods mask, keysym }. Everything before the last '+'
/// must name a modifier; the last token is an xkb keysym name.
/// Single-character keys mapped to their canonical XKB keysym names
/// (xkb_keysym_from_name does not accept literal punctuation).
const char_keysyms = [_]struct { ch: u8, name: []const u8 }{
    .{ .ch = '[', .name = "bracketleft" },
    .{ .ch = ']', .name = "bracketright" },
    .{ .ch = '<', .name = "less" },
    .{ .ch = '>', .name = "greater" },
    .{ .ch = ',', .name = "comma" },
    .{ .ch = '.', .name = "period" },
    .{ .ch = ';', .name = "semicolon" },
    .{ .ch = '\'', .name = "apostrophe" },
    .{ .ch = '/', .name = "slash" },
    .{ .ch = '\\', .name = "backslash" },
    .{ .ch = '-', .name = "minus" },
    .{ .ch = '=', .name = "equal" },
};

/// Shifted counterparts for the keysyms most binds use with Shift. Only
/// pairs that are identical across layouts made the list (no digits,
/// apostrophe, backslash — those differ between us/gb).
const shift_pairs = [_]struct { base: []const u8, shifted: []const u8 }{
    .{ .base = "equal", .shifted = "plus" },
    .{ .base = "minus", .shifted = "underscore" },
    .{ .base = "bracketleft", .shifted = "braceleft" },
    .{ .base = "bracketright", .shifted = "braceright" },
    .{ .base = "comma", .shifted = "less" },
    .{ .base = "period", .shifted = "greater" },
    .{ .base = "semicolon", .shifted = "colon" },
    .{ .base = "slash", .shifted = "question" },
};

pub fn parseKey(key: []const u8) !ParsedKey {
    var mods: u32 = 0;

    const last_plus = std.mem.lastIndexOfScalar(u8, key, '+');
    const mod_part = if (last_plus) |i| key[0..i] else "";
    var sym_name = if (last_plus) |i| key[i + 1 ..] else key;

    var it = std.mem.splitScalar(u8, mod_part, '+');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        mods |= modBit(tok) orelse return error.UnknownModifier;
    }

    // Keysym names may arrive with any casing ("Equal", "BRACKETLEFT");
    // tables below are lowercase, so normalize a mutable copy up front.
    if (sym_name.len == 0) return error.UnknownKeysym;
    var buf: [64]u8 = undefined;
    if (sym_name.len >= buf.len) return error.UnknownKeysym;
    @memcpy(buf[0..sym_name.len], sym_name);
    for (buf[0..sym_name.len]) |*c| c.* = std.ascii.toLower(c.*);
    sym_name = buf[0..sym_name.len];

    // Literal punctuation isn't a valid XKB keysym name ("[" parses to
    // NoSymbol), so map the common ones to their canonical names.
    if (sym_name.len == 1) {
        for (char_keysyms) |m| {
            if (sym_name[0] == m.ch) {
                sym_name = m.name;
                break;
            }
        }
    }

    // A bind like "Shift+equal" must match what the keyboard ACTUALLY
    // produces while Shift is held: "=" becomes "+", "-" becomes "_",
    // etc. Remove the shift flag comment and resolve the shifted keysym.
    if ((mods & (1 << 0)) != 0) {
        for (shift_pairs) |m| {
            if (std.mem.eql(u8, sym_name, m.base)) {
                sym_name = m.shifted;
                break;
            }
        }
    }

    if (sym_name.len >= buf.len) return error.UnknownKeysym;
    // sym_name may already live inside buf (the lowercased copy), so an
    // aliasing @memcpy would panic; copyForwards permits overlap.
    std.mem.copyForwards(u8, buf[0..sym_name.len], sym_name);
    buf[sym_name.len] = 0;

    const sym = xkb.Keysym.fromName(buf[0..sym_name.len :0], .case_insensitive);
    if (@intFromEnum(sym) == 0) return error.UnknownKeysym;

    return .{ .mods = mods, .sym = @intFromEnum(sym) };
}

/// Simple glob matcher: `*` matches any run of characters, `?` matches one.
fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            mark = t;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            t = mark;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

pub fn matchRule(rule: CompiledRule, app_id: []const u8, title: []const u8) bool {
    if (rule.class) |c| if (!globMatch(c, app_id)) return false;
    if (rule.title) |t| if (!globMatch(t, title)) return false;
    return true;
}

pub fn compileRules(a: std.mem.Allocator, rules: []const Rule) ![]CompiledRule {
    var out: std.ArrayListUnmanaged(CompiledRule) = .empty;
    for (rules) |r| {
        const bc = if (r.border_color) |c| compileColor(a, c) catch null else null;
        try out.append(a, .{
            .class = r.class,
            .title = r.title,
            .rounding = r.rounding,
            .border_width = r.border_width,
            .border_color = bc,
            .blur = r.blur,
            .swallow = r.swallow,
            .float = r.float,
        });
    }
    return try out.toOwnedSlice(a);
}

/// Dim a border color for the inactive (unfocused) look: half
/// strength, slightly muted alpha. Gradients dim every stop.
fn dimColor(a: std.mem.Allocator, c: Color) !Color {
    return switch (c) {
        .solid => |c0| .{ .solid = .{ c0[0] * 0.5, c0[1] * 0.5, c0[2] * 0.5, c0[3] * 0.7 } },
        .gradient => |g| blk: {
            var colors: std.ArrayListUnmanaged([4]f32) = .empty;
            errdefer colors.deinit(a);
            for (g.colors) |c0| try colors.append(a, .{ c0[0] * 0.5, c0[1] * 0.5, c0[2] * 0.5, c0[3] * 0.7 });
            break :blk .{ .gradient = .{ .angle = g.angle, .colors = try colors.toOwnedSlice(a) } };
        },
    };
}

/// Compile a config color spec (string hex or gradient of hex strings)
/// into a runtime Color with float stops allocated from `a`.
fn compileColor(a: std.mem.Allocator, spec: ColorSpec) !Color {
    return switch (spec) {
        .solid => |hex| .{ .solid = try parseColor(hex) },
        .gradient => |g| blk: {
            if (g.colors.len < 2) return error.BadColor;
            var colors: std.ArrayListUnmanaged([4]f32) = .empty;
            errdefer colors.deinit(a);
            for (g.colors) |hex| try colors.append(a, try parseColor(hex));
            break :blk .{ .gradient = .{ .angle = g.angle, .colors = try colors.toOwnedSlice(a) } };
        },
    };
}

pub fn parseColor(s: []const u8) ![4]f32 {
    if (s.len < 4 or s[0] != '#') return error.BadColor;
    const hex = s[1..];
    if (hex.len != 3 and hex.len != 6 and hex.len != 8) return error.BadColor;

    var channels: [4]f32 = .{ 0, 0, 0, 1 };
    const step: usize = if (hex.len == 3) 1 else 2;
    var i: usize = 0;
    while (i < 4 and i * step < hex.len) : (i += 1) {
        const pair: []const u8 = if (step == 1) &.{ hex[i], hex[i] } else hex[i * 2 .. i * 2 + 2];
        const v = std.fmt.parseInt(u8, pair, 16) catch return error.BadColor;
        channels[i] = @as(f32, @floatFromInt(v)) / 255.0;
    }
    return channels;
}

fn dupeZ(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const buf = try a.allocSentinel(u8, s.len, 0);
    @memcpy(buf[0..s.len], s);
    return buf;
}

fn optDupeZ(a: std.mem.Allocator, s: []const u8) !?[*:0]const u8 {
    if (s.len == 0) return null;
    return (try dupeZ(a, s)).ptr;
}

fn compileBind(a: std.mem.Allocator, b: Bind) !CompiledBind {
    _ = a;
    const pk = try parseKey(b.key);
    const args = b.args orelse &.{};
    if (b.action == .spawn and args.len == 0) return error.SpawnWithoutArgs;
    if (b.action == .submap and args.len == 0) return error.SubmapWithoutName;
    return .{ .mods = pk.mods, .sym = pk.sym, .action = b.action, .args = args, .through_lock = b.through_lock };
}

/// Compiled root binds plus the submaps grouped out of the same flat list by
/// each bind's `submap` name (binds with a submap never fire from the root).
pub const CompiledKeybinds = struct {
    binds: []const CompiledBind,
    submaps: []const CompiledSubmap,
};

fn compileKeybinds(a: std.mem.Allocator, binds: []const Bind) !CompiledKeybinds {
    // Distinct submap names in first-seen order.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var n_root: usize = 0;
    for (binds) |b| {
        const name = b.submap orelse {
            n_root += 1;
            continue;
        };
        var seen = false;
        for (names.items) |n| {
            if (std.mem.eql(u8, n, name)) {
                seen = true;
                break;
            }
        }
        if (!seen) try names.append(a, name);
    }

    const submaps = try a.alloc(CompiledSubmap, names.items.len);
    for (names.items, 0..) |name, i| {
        var n: usize = 0;
        for (binds) |b| {
            if (b.submap) |s| {
                if (std.mem.eql(u8, s, name)) n += 1;
            }
        }
        const sbinds = try a.alloc(CompiledBind, n);
        var k: usize = 0;
        for (binds) |b| {
            if (b.submap) |s| {
                if (std.mem.eql(u8, s, name)) {
                    sbinds[k] = try compileBind(a, b);
                    k += 1;
                }
            }
        }
        submaps[i] = .{ .name = name, .binds = sbinds };
    }

    const root = try a.alloc(CompiledBind, n_root);
    var ri: usize = 0;
    for (binds) |b| {
        if (b.submap == null) {
            root[ri] = try compileBind(a, b);
            ri += 1;
        }
    }
    return .{ .binds = root, .submaps = submaps };
}

fn compileGestures(a: std.mem.Allocator, binds: []const GestureBind) ![]CompiledGesture {
    const out = try a.alloc(CompiledGesture, binds.len);
    for (binds, 0..) |b, i| {
        const args = b.args orelse &.{};
        if (b.action == .spawn and args.len == 0) return error.SpawnWithoutArgs;
        if (b.dir) |d| {
            const ok = switch (b.kind) {
                .swipe => d == .left or d == .right or d == .up or d == .down,
                .pinch => d == .in or d == .out,
                .hold => false, // holds have no direction
            };
            if (!ok) {
                a.free(out);
                return error.InvalidGestureDir;
            }
        }
        out[i] = .{
            .fingers = b.fingers,
            .kind = b.kind,
            .dir = b.dir,
            .on = b.on,
            .target = b.target,
            .action = b.action,
            .args = args,
        };
    }
    return out;
}

fn compileSwitches(a: std.mem.Allocator, binds: []const SwitchBind) ![]CompiledSwitch {
    const out = try a.alloc(CompiledSwitch, binds.len);
    for (binds, 0..) |b, i| {
        const args = b.args orelse &.{};
        if (b.action == .spawn and args.len == 0) return error.SpawnWithoutArgs;
        out[i] = .{
            .switch_type = b.switch_type,
            .state = b.state,
            .action = b.action,
            .args = args,
        };
    }
    return out;
}

pub const Loaded = struct {
    cfg: Config,
    binds: []const CompiledBind,
    gestures: []const CompiledGesture,
    switches: []const CompiledSwitch,
    submaps: []const CompiledSubmap,
    rules: []const CompiledRule,
    border_color: Color,
    inactive_border_color: Color,
    floating_border_color: Color,
    active_floating_border_color: ?Color,
    hover_border_color: ?Color,
    border_widths: BorderWidths,
    xkb_names: xkb.RuleNames,
};

/// Load and resolve the whole config. Never fails: missing file or any
/// parse/validation error logs and returns defaults instead. All returned
/// memory comes from `a`, which must outlive the session.
pub fn load(io: std.Io, a: std.mem.Allocator, log_missing: bool) Loaded {
    var cfg: Config = .{};

    if (readConfigFile(io, a)) |src| {
        defer a.free(src);
        var meta: ziggy.Deserializer.Meta = .init;
        if (ziggy.deserializeLeaky(Config, a, src, &meta, .{})) |parsed| {
            cfg = parsed;
        } else |err| {
            const off = @min(meta.error_loc.start, src.len);
            var line: usize = 1;
            for (src[0..off]) |c| {
                if (c == '\n') line += 1;
            }
            if (err == error.MissingField) {
                std.log.err("config: line {d}: missing field '{s}', using defaults", .{ line, meta.missing_field_name });
            } else if (err == error.UnknownField) {
                const s = @min(meta.error_loc.start, src.len);
                const e = @min(src.len, s + 20);
                std.log.err("config: line {d}: unknown field near '{s}', using defaults", .{ line, src[s..e] });
            } else {
                std.log.err("config: line {d}: {s}, using defaults", .{ line, @errorName(err) });
            }
        }
    } else if (log_missing) {
        std.log.info("config: no config.ziggy found, using defaults", .{});
    }

    var loaded: Loaded = .{
        .rules = &.{},

        .cfg = cfg,
        .binds = &.{},
        .gestures = &.{},
        .switches = &.{},
        .submaps = &.{},
        .border_color = .{ .solid = .{ 0.3, 0.6, 1.0, 1.0 } },
        .inactive_border_color = .{ .solid = .{ 0.3, 0.6, 1.0, 1.0 } },
        .floating_border_color = .{ .solid = .{ 0.3, 0.6, 1.0, 1.0 } },
        .active_floating_border_color = null,
        .hover_border_color = null,
        .border_widths = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
        .xkb_names = .{ .rules = null, .model = null, .layout = "gb", .variant = null, .options = null },
    };

    // DupeZ the default layout so it's heap-allocated and safe to
    // free on a subsequent reload_config.
    loaded.xkb_names.layout = (dupeZ(a, "gb") catch return fallback(loaded)).ptr;

    switch (cfg.keyboard) {
        .preset => |p| {
            loaded.xkb_names = .{
                .rules = null,
                .model = null,
                .layout = (dupeZ(a, p) catch return fallback(loaded)),
                .variant = null,
                .options = null,
            };
        },
        .custom => |c| {
            loaded.xkb_names = .{
                .rules = optDupeZ(a, c.rules) catch return fallback(loaded),
                .model = optDupeZ(a, c.model) catch return fallback(loaded),
                .layout = optDupeZ(a, c.layout) catch return fallback(loaded),
                .variant = optDupeZ(a, c.variant) catch return fallback(loaded),
                .options = optDupeZ(a, c.options) catch return fallback(loaded),
            };
        },
    }

    const kb = compileKeybinds(a, cfg.keybinds) catch blk: {
        std.log.err("config: bad keybind, keeping default binds", .{});
        break :blk compileKeybinds(a, &default_keybinds) catch unreachable;
    };
    loaded.binds = kb.binds;
    loaded.submaps = kb.submaps;

    loaded.gestures = compileGestures(a, cfg.gestures.binds) catch blk: {
        std.log.err("config: bad gesture bind, disabling gestures", .{});
        break :blk &.{};
    };

    loaded.switches = compileSwitches(a, cfg.switches) catch blk: {
        std.log.err("config: bad switch bind, disabling switches", .{});
        break :blk &.{};
    };

    loaded.border_color = compileColor(a, cfg.decorations.border.color) catch blk: {
        std.log.err("config: bad border color, using default", .{});
        break :blk .{ .solid = .{ 0.3, 0.6, 1.0, 1.0 } };
    };

    loaded.inactive_border_color = if (cfg.decorations.border.inactive_color) |c|
        compileColor(a, c) catch blk: {
            std.log.err("config: bad inactive border color, using dimmed default", .{});
            break :blk (dimColor(a, loaded.border_color) catch loaded.border_color);
        }
    else
        (dimColor(a, loaded.border_color) catch loaded.border_color);

    loaded.floating_border_color = if (cfg.decorations.border.floating_color) |c|
        compileColor(a, c) catch blk: {
            std.log.err("config: bad floating border color, using dimmed inactive", .{});
            break :blk loaded.inactive_border_color;
        }
    else
        loaded.inactive_border_color;

    loaded.active_floating_border_color = if (cfg.decorations.border.active_floating_color) |c|
        compileColor(a, c) catch null
    else
        null;

    loaded.hover_border_color = if (cfg.decorations.border.hover_color) |c|
        compileColor(a, c) catch null
    else
        null;

    const bw = cfg.decorations.border;
    loaded.border_widths = .{
        .top = bw.sides.top orelse bw.width,
        .right = bw.sides.right orelse bw.width,
        .bottom = bw.sides.bottom orelse bw.width,
        .left = bw.sides.left orelse bw.width,
    };

    loaded.rules = compileRules(a, cfg.rules) catch blk: {
        std.log.err("config: bad rule, ignoring all rules", .{});
        break :blk &.{};
    };

    return loaded;
}

fn fallback(loaded: Loaded) Loaded {
    return loaded;
}

fn readConfigFile(io: std.Io, a: std.mem.Allocator) ?[:0]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = blk: {
        if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| {
            break :blk std.fmt.bufPrint(&buf, "{s}/zylr/config.ziggy", .{std.mem.span(xdg)}) catch return null;
        }
        const home = std.c.getenv("HOME") orelse return null;
        break :blk std.fmt.bufPrint(&buf, "{s}/.config/zylr/config.ziggy", .{std.mem.span(home)}) catch return null;
    };
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch return null;
    defer a.free(raw);
    return dupeZ(a, raw) catch null;
}

test "parseKey resolves modifiers and named keysyms" {
    const b = try parseKey("Super+o");
    try std.testing.expectEqual(@as(u32, 1 << 6), b.mods);
    try std.testing.expectEqual(@as(u32, xkb.Keysym.o), b.sym);

    const m = try parseKey("XF86AudioMute");
    try std.testing.expectEqual(@as(u32, 0), m.mods);

    try std.testing.expectError(error.UnknownModifier, parseKey("Hyper+o"));
    try std.testing.expectError(error.UnknownKeysym, parseKey("NotAKeysymName"));

    // Literal punctuation maps to canonical keysym names (Super+[, Super+]).
    const lb = try parseKey("Super+[");
    try std.testing.expectEqual(@as(u32, xkb.Keysym.bracketleft), lb.sym);
    const rb = try parseKey("Super+]");
    try std.testing.expectEqual(@as(u32, xkb.Keysym.bracketright), rb.sym);

    // Shifted binds must resolve to what the key produces while Shift is
    // held ("=" -> plus 0x2b, "-" -> underscore 0x5f), not the base sym.
    const se = try parseKey("Super+Shift+Equal");
    try std.testing.expectEqual(@as(u32, 0x2b), se.sym);
    try std.testing.expectEqual(@as(u32, 0x41), se.mods);
    const sm = try parseKey("Super+Shift+Minus");
    try std.testing.expectEqual(@as(u32, 0x5f), sm.sym);
    const sb = try parseKey("Super+Shift+[");
    try std.testing.expectEqual(@as(u32, 0x7b), sb.sym);
}

test "dimColor halves rgb and scales alpha" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = (try dimColor(arena.allocator(), .{ .solid = .{ 1.0, 0.5, 0.25, 1.0 } })).solid;
    try std.testing.expectApproxEqAbs(0.5, c[0], 0.001);
    try std.testing.expectApproxEqAbs(0.25, c[1], 0.001);
    try std.testing.expectApproxEqAbs(0.125, c[2], 0.001);
    try std.testing.expectApproxEqAbs(0.7, c[3], 0.001);
}

test "Gradient.sample interpolates across stops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g: Gradient = .{ .angle = 0, .colors = try arena.allocator().dupe([4]f32, &.{ .{ 0, 0, 0, 1 }, .{ 1, 0, 0, 1 }, .{ 0, 1, 0, 1 } }) };
    const mid = g.sample(0.25);
    try std.testing.expectApproxEqAbs(0.5, mid[0], 0.001);
    try std.testing.expectApproxEqAbs(0, mid[1], 0.001);
    const end = g.sample(1.0);
    try std.testing.expectApproxEqAbs(0, end[0], 0.001);
    try std.testing.expectApproxEqAbs(1, end[1], 0.001);
}

test "parseColor accepts short, long and alpha forms" {
    const rgb3 = try parseColor("#f00");
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, rgb3);

    const rgb6 = try parseColor("#4d99ff");
    try std.testing.expectApproxEqAbs(@as(f32, 0x4d) / 255.0, rgb6[0], 0.001);

    const rgba8 = try parseColor("#4d99ff80");
    try std.testing.expectApproxEqAbs(@as(f32, 0x80) / 255.0, rgba8[3], 0.001);

    try std.testing.expectError(error.BadColor, parseColor("red"));
    try std.testing.expectError(error.BadColor, parseColor("#12345"));
}

test "ziggy document deserializes into Config" {
    const doc =
        \\.{
        \\    .keyboard = .custom(.{ .layout = "de", .variant = "nodeadkeys" }),
        \\    .transform = .90,
        \\    .decorations = .{ .rounding = 4, .border = .{ .width = 2, .sides = .{ .top = 4, .right = 6 }, .color = .solid("#ff0000"), .inactive_color = .solid("#884422aa"), .floating_color = .solid("#00ff00"), .active_floating_color = .solid("#ff00ff"), .hover_color = .solid("#00ffff"), .pulse = true } },
        \\    .windows = .{ .gaps_out = 4 },
        \\    .autostart = [],
        \\    .keybinds = [
        \\        .{ .key = "Super+Return", .action = .spawn, .args = [ "alacritty" ] },
        \\        .{ .key = "Super+q", .action = .close },
        \\    ]
        \\}
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var meta: ziggy.Deserializer.Meta = .init;
    const cfg = try ziggy.deserializeLeaky(Config, a, doc, &meta, .{});

    try std.testing.expectEqualStrings("de", cfg.keyboard.custom.layout);
    try std.testing.expectEqual(Transform.@"90", cfg.transform);

    const kb = try compileKeybinds(a, cfg.keybinds);
    try std.testing.expectEqual(@as(usize, 2), kb.binds.len);
    try std.testing.expectEqual(Action.spawn, kb.binds[0].action);
    try std.testing.expectEqualStrings("alacritty", kb.binds[0].args[0]);
    try std.testing.expectEqual(@as(usize, 0), kb.submaps.len);

    const color = switch (cfg.decorations.border.color) {
        .solid => |hex| try parseColor(hex),
        else => unreachable,
    };
    try std.testing.expectEqual(@as(f32, 1), color[0]);

    try std.testing.expectEqual(@as(i32, 4), cfg.decorations.border.sides.top.?);
    try std.testing.expectEqual(@as(i32, 6), cfg.decorations.border.sides.right.?);
    try std.testing.expectEqual(@as(i32, 0), cfg.decorations.border.sides.bottom orelse 0);
    try std.testing.expectEqual(@as(i32, 0), cfg.decorations.border.sides.left orelse 0);
    try std.testing.expect(cfg.decorations.border.pulse);

    const gestures = try compileGestures(a, cfg.gestures.binds);
    try std.testing.expectEqual(@as(usize, 0), gestures.len);
}

test "Easing.sample bounds and endpoints" {
    // Bezier and spring both start at 0 and reach ~1 by p=1.
    const b = Bezier{};
    try std.testing.expectApproxEqAbs(@as(f32, 0), b.sample(0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), b.sample(1), 1e-3);

    const sp = Spring{};
    try std.testing.expectApproxEqAbs(@as(f32, 0), sp.sample(0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), sp.sample(1), 3e-2);

    // Monotonic bezier in the middle.
    const mid = b.sample(0.5);
    try std.testing.expect(mid > 0 and mid < 1);
}

test "EasingPreset endpoints and overshoots" {
    // All presets start at 0 and end at 1.
    const presets = [_]EasingPreset{ .linear, .ease_in, .ease_out, .ease_in_out, .back, .expo, .elastic, .bounce };
    for (presets) |e| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), e.sample(0), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 1), e.sample(1), 1e-6);
    }
    // Overshooting presets exceed 1 in the middle; monotonic ones don't.
    try std.testing.expect(EasingPreset.back.sample(0.7) > 1);
    try std.testing.expect(EasingPreset.elastic.sample(0.5) > 1);
    try std.testing.expect(EasingPreset.bounce.sample(0.6) < 1 and EasingPreset.bounce.sample(0.6) > 0);
    const mid_linear = EasingPreset.linear.sample(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid_linear, 1e-6);
    try std.testing.expect(EasingPreset.ease_in.sample(0.3) < 0.3);
    try std.testing.expect(EasingPreset.ease_out.sample(0.3) > 0.3);
}

test "compileGestures rejects direction/kind mismatches" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try expectInvalid(a, &[_]GestureBind{.{ .fingers = 3, .kind = .swipe, .dir = .in, .action = .close }});
    try expectInvalid(a, &[_]GestureBind{.{ .fingers = 3, .kind = .swipe, .dir = .out, .action = .close }});
    try expectInvalid(a, &[_]GestureBind{.{ .fingers = 2, .kind = .pinch, .dir = .left, .action = .shrink }});
    try expectInvalid(a, &[_]GestureBind{.{ .fingers = 2, .kind = .pinch, .dir = .down, .action = .shrink }});
    try expectInvalid(a, &[_]GestureBind{.{ .fingers = 4, .kind = .hold, .dir = .left, .action = .quit }});

    // valid: swipe dirs, pinch in/out, hold with no dir
    _ = try compileGestures(a, &.{
        .{ .fingers = 3, .kind = .swipe, .action = .close },
        .{ .fingers = 2, .kind = .pinch, .action = .shrink },
        .{ .fingers = 4, .kind = .hold, .action = .quit },
    });
    _ = try compileGestures(a, &.{.{ .fingers = 1, .kind = .swipe, .dir = .right, .action = .focus_right }});
    _ = try compileGestures(a, &.{.{ .fingers = 2, .kind = .pinch, .dir = .in, .action = .grow }});
}

fn expectInvalid(a: std.mem.Allocator, binds: []const GestureBind) !void {
    try std.testing.expectError(error.InvalidGestureDir, compileGestures(a, binds));
}

test "globMatch basic patterns" {
    try std.testing.expect(globMatch("org.wez*", "org.wezfurlong.wezterm"));
    try std.testing.expect(globMatch("fire*fox", "firefox"));
    try std.testing.expect(!globMatch("fire*fox", "firefoxcx"));
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(!globMatch("*term", "termite"));
    try std.testing.expect(globMatch("?", "x"));
    try std.testing.expect(!globMatch("org.wez.*", "kitty"));
    try std.testing.expect(!globMatch("fire", "firefox"));
    try std.testing.expect(globMatch("", ""));
    try std.testing.expect(globMatch("*", ""));
    try std.testing.expect(!globMatch("x", ""));
}

test "matchRule checks class and title" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var meta: ziggy.Deserializer.Meta = .init;
    const cfg = try ziggy.deserializeLeaky(Config, a,
        \\.{ .rules = [ .{ .class = "firefox*", .rounding = 0 } ] }
    , &meta, .{});
    const rules = try compileRules(a, cfg.rules);
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expect(matchRule(rules[0], "firefox", "Title"));
    try std.testing.expect(matchRule(rules[0], "firefox-esr", ""));
    try std.testing.expect(!matchRule(rules[0], "chromium", ""));
}

test "submaps group out of the flat keybind list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const kb = try compileKeybinds(a, &.{
        // Root bind: enters the resize submap.
        .{ .key = "Super+r", .action = .submap, .args = &.{"resize"} },
        // resize submap binds (interleaved with root binds on purpose).
        .{ .key = "h", .action = .shrink, .submap = "resize" },
        .{ .key = "Super+q", .action = .close },
        // Nested: from resize, enter the other submap.
        .{ .key = "g", .action = .submap, .args = &.{"other"}, .submap = "resize" },
        .{ .key = "k", .action = .row_up, .submap = "other" },
    });

    // Root set: only binds without a submap.
    try std.testing.expectEqual(@as(usize, 2), kb.binds.len);
    try std.testing.expectEqual(Action.submap, kb.binds[0].action);
    try std.testing.expectEqual(Action.close, kb.binds[1].action);
    // Root binds never include submapped ones.
    for (kb.binds) |b| try std.testing.expect(b.action != .shrink);

    try std.testing.expectEqual(@as(usize, 2), kb.submaps.len);
    try std.testing.expectEqualStrings("resize", kb.submaps[0].name);
    try std.testing.expectEqual(@as(usize, 2), kb.submaps[0].binds.len);
    try std.testing.expectEqual(Action.shrink, kb.submaps[0].binds[0].action);
    try std.testing.expectEqualStrings("other", kb.submaps[0].binds[1].args[0]);
    try std.testing.expectEqualStrings("other", kb.submaps[1].name);
    try std.testing.expectEqual(Action.row_up, kb.submaps[1].binds[0].action);

    try std.testing.expectError(error.SubmapWithoutName, compileKeybinds(a, &.{
        .{ .key = "x", .action = .submap },
    }));
}
