# zylr
![enbyware](https://pride-badges.pony.workers.dev/static/v1?label=enbyware&labelColor=%23555&stripeWidth=8&stripeColors=FCF434%2CFFFFFF%2C9C59D1%2C2C2C2C)


A minimalist wayland compositor made in zig <3

## install

```sh
curl -fsSL https://github.com/aspenir/zylr/releases/latest/download/install.sh | sudo sh
```

depends on zig 0.16, wlroots 0.20, scenefx 0.5, libinput, xkbcommon, wayland,
pixman, xcb and libsystemd (system development packages).

## run

```sh
exec zylr
```

if `WAYLAND_DISPLAY` set, zylr runs nested. Config: `~/.config/zylr/config.ziggy`
(built-in defaults apply when missing or malformed).

```sh
zig build test
zylr --version
```

## defaults

| super + key | action |
|-----|--------|
| h / l | focus left / right |
| j / k | viewport down / up |
| space | spawn fuzzel |
| v | float |
| shift+h / shift+l | swap |
| z | undo |
| f | fullscreen |
| q | close |
| minus / equal | shrink / grow |
| escape | quit |


## docs

[config](docs/config.md) · [actions](docs/actions.md) ·
[gestures](docs/gestures.md) ·
[locking](docs/locking.md)
