#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged}"
ARCH_DEB="${ARCH_DEB:-$(dpkg --print-architecture 2>/dev/null || echo aarch64)}"
MAINTAINER="${MAINTAINER:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"

command -v dpkg-deb >/dev/null 2>&1 || { echo "Error: dpkg-deb not found"; exit 1; }
[[ -x "$STAGED_PREFIX/bin/freebuff" ]] || { echo "Error: missing staged launcher"; exit 1; }

: "${VERSION:=0.0.0}"
DEB_ROOT="$ROOT_DIR/packing/dpkg/work"
OUT_DIR="$ROOT_DIR/packing/dpkg"
OUT_FILE="$OUT_DIR/freebuff_${VERSION}_${ARCH_DEB}.deb"

rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX" "$OUT_DIR"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"
cp -a "$STAGED_PREFIX/." "$DEB_ROOT$PREFIX/"

cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: freebuff
Version: $VERSION
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Section: utils
Priority: optional
Description: Freebuff AI coding assistant for Termux
Depends: bash, glibc, openssl-glibc
EOF

INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"

cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "Freebuff for Termux installed"
echo "Run: freebuff --version"
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"

cat >"$DEB_ROOT/DEBIAN/prerm" <<'PRERM'
#!/data/data/com.termux/files/usr/bin/bash
set -e
exit 0
PRERM
chmod 755 "$DEB_ROOT/DEBIAN/prerm"

dpkg-deb --build "$DEB_ROOT" "$OUT_FILE"
echo "DEB package created: $OUT_FILE"
