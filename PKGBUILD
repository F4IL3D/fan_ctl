pkgname=fan_ctl
pkgver=1
pkgrel=1
pkgdesc="IPMI fan controller script with PID logic for a Supermicro X10DRi"
arch=('x86_64')
url="https://github.com/F4IL3D/fan_ctl"
license=('custom')
depends=('ipmitool')
source=("$pkgname.sh"
        "$pkgname.service")
sha256sums=('SKIP'
            'SKIP')

package() {
  mkdir -p "$pkgdir/usr/local/bin"
  install -Dm751 fan_ctl.sh "$pkgdir"/usr/local/bin/
  mkdir -p "$pkgdir/usr/lib/systemd/system"
  install -Dm644 fan_ctl.service "$pkgdir"/usr/lib/systemd/system/
}
