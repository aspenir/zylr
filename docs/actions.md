# Actions

What a bind, gesture, or switch can do. Only `spawn` needs arguments.

| Action | What it does |
|--------|--------------|
| `spawn` | launch a program. The child gets `WAYLAND_DISPLAY`, `DISPLAY`, `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`, and a couple of Wayland hints (MOZ, Electron), so native apps just land in Wayland mode. |
| `close` | close the focused view |
| `quit` | exit the compositor |
| `focus_left` / `focus_right` | focus the neighbouring view and hop the viewport to it |
| `viewport_up` / `viewport_down` | scroll the viewport 100px |
| `grow` / `shrink` | widen/narrow the focused view by ×1.15 (floor 200px) |
| `reload_config` | re-read config.ziggy live: binds, gestures, thresholds, gaps, everything |
| `toggle_floating` | float/unfloat a view; floating centers and raises it, otherwise it rejoins the strip |
| `swap_left` / `swap_right` | swap with the nearest mapped neighbour |
| `undo` | walk back the last layout change |
| `toggle_fullscreen` | fill the output with the focused view |
| `center_window` | moves the viewport so that the window is in the center|
| `dpms_off` | cut the outputs now; any input wakes them |

On gestures, add `.target = .under_gesture` and the action hits the view
under your finger instead of the focused one ([gestures.md](gestures.md)).

## undo

Walks back the last resize, float, swap, scroll,
fullscreen, and focus-jump. It can't close windows, and a closed window
stays closed.

