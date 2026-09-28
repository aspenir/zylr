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


## rules

Per-window overrides, matched against app class (XDG `app_id` / XWayland class)
and title with `*` (any run) and `?` (one char) globs. Later rules win: last
matching rule's fields take effect. Apply on map and on `reload_config`.

```ziggy
.rules = [
    // Steam's login window: square, no border.
    .{ .class = "steam", .title = "*Login*", .rounding = 0, .border_width = 0 },
    // Float anything named "Calculator".
    .{ .title = "Calculator", .float = true },
    // Blur only terminals, rounded further, with a fat magenta border.
    .{ .class = "org.wez*", .blur = true, .rounding = 24,
       .border_width = 4, .border_color = "#ff00aa" },
    // A window only swallows when its process descends from the focused
    // one (a terminal running a program). Opt a spawned class out with
    // false if it shouldn't hide its parent.
    .{ .class = "org.chromium*", .swallow = false },
]
```

Fields: `class`, `title` (globs), `rounding` (i32), `border_width` (i32),
`border_color` (color string), `blur` (bool), `float` (bool), `swallow` (bool).
All optional — omit what you don't want to override. `float` only applies at
map time (reloads keep your manual toggle). Transient windows (dialogs,
splashes, tooltips, utility/menu/notification windows) float automatically
regardless of rules, like Sway. Swallow applies at map time only:
a new window whose process descends from the focused window's process (a
terminal running a program) hides the focused tiled window, takes its slot,
and hands it back when it closes; `swallow: false` opts a class out.

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

Keybind auto-repeat:

```ziggy
.keybind_repeat = .{ .cooldown_ms = 0, .delay_ms = 150 }   # cadence for repeatable keybinds
```

`cooldown_ms` (0 = none) floors the gap between firings. `delay_ms` (default
150) is how long a held bind waits before its first repeat: short enough for
a held grow/shrink to keep moving without the OS key-repeat stall, long
enough that a quick tap is still a single step. 0 uses the OS key-repeat
delay.

Auto-repeat is **per bind**: a keybind/gesture without `.repeat` fires
once (on press / on gesture completion); one labelled `.repeat = true`
keeps firing while the key is held or the gesture continues (a swipe every
`swipe_min_px`, a pinch every `pinch_scale`, a hold on a fixed interval).

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
.focus_follows_mouse_delay_ms = 120  # dwell before hover focus moves
```

Default `false` (click to focus). The delay defaults to `0`, which focuses
immediately; a few hundred ms stops a pointer sweep across the screen from
stealing focus window by window.

## animation

```ziggy
.animation = .{
    .enabled = false,   # land every transition in one frame, no slide/fade
}
```

Turning it off keeps the transitions (so the final state still gets
applied) but makes each complete immediately - cheaper on the GPU, and
kinder to panels that flicker under fast changes. Pair it with `.vrr =
false` for the other half of that problem.

## workspaces

```ziggy
.workspace_names = [ "web", "code", "mail" ]
```

Names for the rows as ext-workspace-v1 reports them. Empty (the default)
means `"1".."8"`; a short list is fine, the rest keep their numbers.

## system bell

`xdg-system-bell-v1`: when a client rings the bell (a terminal bell, say),
zylr runs the command below. There is no OSD and no sound of its own - the
command decides what a bell looks like.

```ziggy
.bell_command = [ "sh", "-c", "notify-send \"bell\" \"$ZYLR_BELL_APP_ID: $ZYLR_BELL_TITLE\"" ]
```

`$ZYLR_BELL_APP_ID` and `$ZYLR_BELL_TITLE` describe the window that rang,
when the client named one; both are empty otherwise. Empty (the default)
ignores bells.

## scroll

```ziggy
.natural_scroll = true    # wheel/trackpad scroll follows the finger
```

Default `false`. Applied to the axis events zylr forwards to clients, so
every app scrolls this way. The direction hint sent with each event is
flipped too, for clients that read the hint rather than the delta.

## gaps

```ziggy
.windows = .{
    .gaps_out = 4,          # all four sides
    .gaps_in = 4,
    .sides = .{ .top = 28 }, # a bigger top gap under a bar; unset sides
}                          # follow gaps_out
}
```

A side set to `0` is a real value, not "unset": it stays `0` while the other
three keep following `gaps_out`.
