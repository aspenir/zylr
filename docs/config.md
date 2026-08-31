# Options

Config is found in `~/.config/zylr/config.ziggy`

## keyboard

One form or the other:

```ziggy
.keyboard = .preset("gb")                    # default
.keyboard = .custom(.{ .layout = "us", .variant = "", .options = "",
    .model = "", .rules = "" })
```

## decorations

```ziggy
.decorations = .{
    .rounding = 16,                          # corner radius px, 0 = square
    .border = .{ .width = 8, .color = "#4d99ff" },
    .blur = .{ .enabled = false, .passes = 2, .radius = 6,
        .noise = 0.002, .brightness = 0.9,
        .contrast = 1.1, .saturation = 1.2 },
}
```

Colors take `#rgb`, `#rrggbb`, or `#rrggbbaa`.

## windows

```ziggy
.windows = .{ .gaps_out = 16, .gaps_in = 8 }
.width_ratio = 0.6         # new windows take this fraction of the screen
.scale = 0                 # output scale override; 0 = whatever the display wants
```

## autostart

```ziggy
.autostart = [ "awww-daemon", "waybar" ]
```

Runs at startup with the same env zylr gives `spawn` (see
[actions.md](actions.md)).

## keybinds

```ziggy
.keybinds = [
    .{ .key = "Super+Return", .action = .spawn, .args = [ "alacritty" ] },
    .{ .key = "Super+q",      .action = .close },
    .{ .key = "Super+Escape", .action = .quit, .through_lock = true },
]
```

`key` is modifiers joined by `+` and an xkb keysym at the end. Modifiers:
`Super`/`Mod4`, `Ctrl`/`Control`, `Alt`/`Mod1`, `Shift`. Keysyms are
xkb names (`Return`, `o`, `XF86AudioRaiseVolume`, ...). The shipped
default set is in the [README](../README.md); actions in
[actions.md](actions.md).

`spawn` needs non-empty `args` or the config refuses to load. A bind with
`.through_lock = true` still fires while the screen is locked, which is
how you keep volume and brightness keys alive.

Repeats control how often held binds/gestures re-fire:

```ziggy
.keybind_repeat = .{ .enabled = true, .cooldown_ms = 0 }   # key auto-repeat
.gesture_repeat = .{ .enabled = false, .cooldown_ms = 0 }  # fire once, on completion
```

`cooldown_ms` (0 = none) floors the gap between firings.

## gestures

```ziggy
.gestures = .{
    .touch = .{ .hold_ms = 300 },
    .binds = [ ... ],
}
```

Nothing's bound out of the box. Bind schema and thresholds live in
[gestures.md](gestures.md).

## switches

```ziggy
.switches = [
    .{ .switch_type = .lid,         .state = .on, .action = .spawn, .args = [ "swaylock" ] },
    .{ .switch_type = .tablet_mode, .state = .on, .action = .spawn, .args = [ "squeekboard" ] },
]
```

## idle and lock_command

```ziggy
.idle = [ .{ .timeout = 120, .command = "swaylock" } ]
.lock_command = [ "swaylock" ]
```

`idle` runs a command after that many seconds of inactivity; `lock_command`
runs before the system suspends. Both are explained in
[locking.md](locking.md).

## focus

```ziggy
.focus_follows_mouse = true    # hover gives focus; nothing ever scrolls on hover
```

Default `false` (click to focus).
