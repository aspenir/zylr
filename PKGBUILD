# Maintainer: your name <you@example.com>
# A raw git clone includes every repo file (zylr.desktop, LICENSE) regardless
# of `paths` in build.zig.zon; the desktop file is not in `paths`, so it must
# not come from a `zig build --fetch` archive — which is why we source the git
# tree directly. `zig build --fetch` resolves the vendored zig-wlroots /
# zig-wayland / zig-pixman / zig-xkbcommon deps into the build cache.
pkgname=zylr-git
pkgver=0.1.0
pkgrel=1
pkgdesc="A minimalist Wayland compositor written in Zig"
arch=('x86_64')
url="https://github.com/aspenir/zylr"
license=('GPL-3.0-or-later')
# Runtime shared libraries the binary links against. The build links
# wlroots-0.20 / scenefx-0.5 (mango fork) headers and .so; on this distro the
# packages are versioned: wlroots0.20 (extra) and scenefx0.5.
depends=('wayland' 'libxcb' 'libxkbcommon' 'libinput' 'pixman' 'wlroots0.20' 'scenefx0.5' 'systemd-libs' 'xcb-util-wm')
makedepends=('zig' 'wayland-protocols' 'wlroots0.20' 'scenefx0.5')
source=("$pkgname::git+https://github.com/aspenir/zylr.git#branch=main")
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
