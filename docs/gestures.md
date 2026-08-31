# Gestures

No gestures are bound out of the box.
To bind a finger gesture to an [action](actions.md):

```ziggy
.gestures = .{
    .binds = [
        .{ .fingers = 3, .kind = .swipe, .dir = .left, .action = .focus_right },
        .{ .fingers = 2, .kind = .hold,   .action = .toggle_floating, .target = .under_gesture },
    ],
}
```

Bind fields:

```text
fingers  1..5
kind     swipe | pinch | hold
dir      left right up down (swipe) · in out (pinch) · omit = any direction
on       touch | trackpad | both   (default both)
target   focus (default) | under_gesture
args     for spawn
```


## Thresholds

```ziggy
.gestures = .{
    .touch = .{
        .hold_move_eps = 0.02,   # how far a finger may drift before a pending hold cancels
        .hold_ms       = 600,    # hold this long, ms
        .blip_ms       = 120,    # stray-tap cutoff, ms
        .flick_max_ms  = 250,    # 1-finger flick must finish within this, ms
        .swipe_min_px  = 40,     # minimum travel, px
        .pinch_ratio   = 1.15,   # span change vs start that counts as a pinch
    },
    .trackpad = .{
        .swipe_min_px = 25,
        .pinch_scale  = 0.15,    # cumulative scale change, 1 ± this
    },
}
```
