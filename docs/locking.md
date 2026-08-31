# Power, idle, and locking

## idle

```ziggy
.idle = [ .{ .timeout = 120, .command = "swaylock" } ]
```

Runs the command after `timeout` many seconds with no input. Any key, mouse
motion or button, touch, or pen resets it. Commands go through `sh -c`,
one shared 1s tick walks all the timers, and each re-arms after firing so
it keeps working on every later idle period.

## lock on suspend

```ziggy
.lock_command = [ "swaylock" ]
```

If it's set, zylr runs it when logind announces the system is about to
suspend (`PrepareForSleep` over sd-bus), so a lock screen is already up
when the machine wakes. Needs the system bus; if that's unreachable at
startup zylr logs it and disables itself. Leave empty to turn off.

## the session lock

swaylock (and squeekboard) lock through the ext-session-lock protocol.
While locked, input only reaches the lock surface, and binds without
`.through_lock` stay silent, so the volume/brightness keys in the default
set carry that flag. Heads up: gesture and switch binds have no lock
gating yet, they keep firing.

## reading the logs

Everything the compositor says lands in the session log (`/tmp/zylr_xw.log`).
If a config change looks dead, the parse error — with the line number —
is in there.
