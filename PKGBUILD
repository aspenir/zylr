# Maintainer: your name <you@example.com>
# A raw git clone includes every repo file (zylr.desktop, LICENSE) regardless
# of `paths` in build.zig.zon; the desktop file is not in `paths`, so it must
# not come from a `zig build --fetch` archive — which is why we source the git
# tree directly. `zig build --fetch` resolves the vendored zig-wlroots /
# zig-wayland / zig-pixman / zig-xkbcommon deps into the build cache.
pkgname=zylr
pkgver=0.1.0
pkgrel=1
pkgdesc="A minimalist Wayland compositor written in Zig"
arch=('x86_64')
url="https://github.com/aspenir/zylr"
license=('GPL-3.0-or-later')
# Runtime shared libraries the binary links against.
depends=('wayland' 'libxcb' 'libxkbcommon' 'libinput' 'pixman' 'wlroots' 'scenefx' 'systemd-libs' 'xcb-util-wm')
makedepends=('zig' 'wayland-protocols')
source=("$pkgname::git+https://github.com/aspenir/zylr.git#commit=6b96a37729c790fec7a0f1e19752802186910e53")
sha256sums=('SKIP')
options=('!lto')

build() {
    cd "$srcdir/$pkgname"
    zig build --fetch
    zig build -Doptimize=ReleaseSafe
}

check() {
    cd "$srcdir/$pkgname"
    zig build test
}

package() {
    cd "$srcdir/$pkgname"
    install -Dm755 zig-out/bin/zylr "$pkgdir/usr/bin/zylr"
    install -Dm644 zylr.desktop "$pkgdir/usr/share/wayland-sessions/zylr.desktop"
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
