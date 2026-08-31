//! Session configuration, loaded from $XDG_CONFIG_HOME/zylr/config.ziggy
//! (or ~/.config/...). A missing or malformed file falls back to the
//! defaults below, which reproduce the pre-config hardcoded behavior.

const std = @import("std");
const xkb = @import("xkbcommon");
const ziggy = @import("ziggy");

pub const Action = enum {
    spawn,
    close,
    quit,
    focus_left,
    focus_right,
    viewport_up,
    viewport_down,
    /// Multiply the focused window's width by 1.15 (or /1.15).
    grow,
    shrink,
    reload_config,
    toggle_floating,
    swap_left,
    swap_right,
    undo,
    toggle_fullscreen,
    /// Center the focused view on the output: floating views move to the
    /// output center, tiled views get the viewport scrolled to center them.
    center_window,
    dpms_off,
};

pub const Bind = struct {
    key: []const u8,
    action: Action,
    args: ?[]const []const u8 = null,
    through_lock: bool = false,
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

pub const DecorationsConfig = struct {
    /// Corner radius in px; 0 disables rounding.
    rounding: i32 = 16,
    border: struct {
        width: i32 = 8,
        color: []const u8 = "#4d99ff",
    } = .{},
    blur: BlurConfig = .{},
};

pub const WindowsConfig = struct {
    gaps_out: i32 = 16,
    gaps_in: i32 = 8,
};

pub const Config = struct {
    keyboard: KeyboardConfig = .{ .preset = "gb" },
    decorations: DecorationsConfig = .{},
    windows: WindowsConfig = .{},
    autostart: []const []const u8 = &.{},
    keybinds: []const Bind = &default_keybinds,
    gestures: GestureConfig = .{},
    switches: []const SwitchBind = &.{},
    idle: []const IdleTimer = &.{},
    /// Whether a keybind may re-fire on key auto-repeat, and how often.
    keybind_repeat: RepeatConfig = .{},
    /// Whether a gesture may re-fire while the gesture continues, and
    /// the minimum gap between consecutive gesture firings. Gestures
    /// default to firing once per gesture (old behavior).
    gesture_repeat: RepeatConfig = .{ .enabled = false },
    /// Give keyboard focus to the view under the pointer on hover
    /// (focus-follows-mouse) instead of only on click.
    focus_follows_mouse: bool = false,
    /// Run this command when the system is about to suspend (logind
    /// PrepareForSleep), typically a lock screen. Empty disables.
    lock_command: []const []const u8 = &.{},

    // New views take a fraction of the output width; zylr's tiling has no
    // absolute default width because it is output-relative.
    width_ratio: f32 = 0.6,
    /// Output scale factor override; 0 = use the display's preferred scale.
    scale: f32 = 0,
};

/// The bind set that used to be hardcoded in onKeyboardKey.
const default_keybinds = [_]Bind{
    .{ .key = "Super+h", .action = .focus_left },
    .{ .key = "Super+j", .action = .viewport_down },
    .{ .key = "Super+k", .action = .viewport_up },
    .{ .key = "Super+l", .action = .focus_right },
    .{ .key = "Super+space", .action = .spawn, .args = &.{"fuzzel"} },
    .{ .key = "Super+v", .action = .toggle_floating },
    .{ .key = "Super+Shift+h", .action = .swap_left },
    .{ .key = "Super+Shift+l", .action = .swap_right },
    .{ .key = "Super+z", .action = .undo },
    .{ .key = "Super+f", .action = .toggle_fullscreen },
    .{ .key = "Super+q", .action = .close },
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
pub fn parseKey(key: []const u8) !ParsedKey {
    var mods: u32 = 0;

    const last_plus = std.mem.lastIndexOfScalar(u8, key, '+');
    const mod_part = if (last_plus) |i| key[0..i] else "";
    const sym_name = if (last_plus) |i| key[i + 1 ..] else key;

    var it = std.mem.splitScalar(u8, mod_part, '+');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        mods |= modBit(tok) orelse return error.UnknownModifier;
    }

    var buf: [64]u8 = undefined;
    if (sym_name.len == 0 or sym_name.len >= buf.len) return error.UnknownKeysym;
    @memcpy(buf[0..sym_name.len], sym_name);
    buf[sym_name.len] = 0;

    const sym = xkb.Keysym.fromName(buf[0..sym_name.len :0], .case_insensitive);
    if (@intFromEnum(sym) == 0) return error.UnknownKeysym;

    return .{ .mods = mods, .sym = @intFromEnum(sym) };
}

/// "#rgb", "#rrggbb" or "#rrggbbaa" -> straight-alpha RGBA, channels / 255.
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

fn compileBinds(a: std.mem.Allocator, binds: []const Bind) ![]CompiledBind {
    const out = try a.alloc(CompiledBind, binds.len);
    for (binds, 0..) |b, i| {
        const pk = try parseKey(b.key);
        const args = b.args orelse &.{};
        if (b.action == .spawn and args.len == 0) return error.SpawnWithoutArgs;
        out[i] = .{ .mods = pk.mods, .sym = pk.sym, .action = b.action, .args = args, .through_lock = b.through_lock };
    }
    return out;
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
    border_color: [4]f32,
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
        .cfg = cfg,
        .binds = &.{},
        .gestures = &.{},
        .switches = &.{},
        .border_color = .{ 0.3, 0.6, 1.0, 1.0 },
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

    loaded.binds = compileBinds(a, cfg.keybinds) catch blk: {
        std.log.err("config: bad keybind, keeping default binds", .{});
        break :blk compileBinds(a, &default_keybinds) catch unreachable;
    };

    loaded.gestures = compileGestures(a, cfg.gestures.binds) catch blk: {
        std.log.err("config: bad gesture bind, disabling gestures", .{});
        break :blk &.{};
    };

    loaded.switches = compileSwitches(a, cfg.switches) catch blk: {
        std.log.err("config: bad switch bind, disabling switches", .{});
        break :blk &.{};
    };

    loaded.border_color = parseColor(cfg.decorations.border.color) catch blk: {
        std.log.err("config: bad border color '{s}', using default", .{cfg.decorations.border.color});
        break :blk .{ 0.3, 0.6, 1.0, 1.0 };
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
        \\    .decorations = .{ .rounding = 4, .border = .{ .width = 2, .color = "#ff0000" } },
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

    const binds = try compileBinds(a, cfg.keybinds);
    try std.testing.expectEqual(@as(usize, 2), binds.len);
    try std.testing.expectEqual(Action.spawn, binds[0].action);
    try std.testing.expectEqualStrings("alacritty", binds[0].args[0]);

    const color = try parseColor(cfg.decorations.border.color);
    try std.testing.expectEqual(@as(f32, 1), color[0]);

    const gestures = try compileGestures(a, cfg.gestures.binds);
    try std.testing.expectEqual(@as(usize, 0), gestures.len);
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