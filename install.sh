#!/bin/sh
# Install zylr from source. Verifies deps first; errors if anything is missing.
set -e

repo="https://github.com/aspenir/zylr"
prefix="${PREFIX:-/usr}"

need() { # need <pkg-config module>
    pkg-config --exists "$1" 2>/dev/null || echo "  missing: $1"
}
bin() { command -v "$1" >/dev/null 2>&1 || echo "  missing: $1"; }

echo "==> checking dependencies"
missing="$(mktemp)"
{
    need scenefx-0.5
    need wlroots-0.20
    need wayland-server
    need libinput
    need xkbcommon
    need pixman-1
    need xcb
    need libsystemd
    bin zig
} >"$missing" || true
if [ -s "$missing" ]; then
    echo "error: missing dependencies:" >&2
    cat "$missing" >&2
    rm -f "$missing"
    exit 1
fi
rm -f "$missing"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> cloning zylr"
git clone -q --depth 1 "$repo" "$tmp/zylr"
cd "$tmp/zylr"

echo "==> building"
zig build --fetch
zig build -Doptimize=ReleaseSafe
zig build test

echo "==> installing to $prefix"
install -Dm755 zig-out/bin/zylr "$prefix/bin/zylr"
install -Dm644 zylr.desktop "$prefix/share/wayland-sessions/zylr.desktop"
install -Dm644 LICENSE "$prefix/share/licenses/zylr/LICENSE"

echo "done. zylr installed to $prefix (deps scenefx-0.5/wlroots-0.20 must be present; scenefx0.5 comes from your distro's repo or manual build)."
