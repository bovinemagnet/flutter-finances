#!/usr/bin/env bash
# Packages the Flutter Linux release bundle as a .tar.gz and a .deb.
#
# Run `flutter build linux --release` in apps/finance_app first. The tarball
# is always produced. The .deb needs dpkg-deb (Debian and Ubuntu, and the
# ubuntu-latest CI runner); without it the script warns and stops after the
# tarball unless --require-deb is given, which turns that into an error.
#
# Usage:
#   tool/packaging/linux/build-deb.sh [--version X.Y.Z] [--arch amd64|arm64]
#       [--bundle DIR] [--out DIR] [--tarball-only] [--require-deb]
#
# Defaults: version from apps/finance_app/pubspec.yaml, architecture of the
# build machine, bundle from build/linux/<x64|arm64>/release/bundle, output
# in dist/linux at the repository root.
#
# Environment:
#   SOURCE_DATE_EPOCH       timestamp used for file times and the metainfo
#                           release date (default: the last commit)
#   FINANCE_DEB_MAINTAINER  Maintainer field of the .deb
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
APP="$ROOT/apps/finance_app"
APP_ID="com.paulsnow.finance.app"
PACKAGE="finance-app"
BINARY="finance_app"
ICON_DIR="$APP/macos/Runner/Assets.xcassets/AppIcon.appiconset"

log() { printf '[package] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

VERSION=""
ARCH=""
BUNDLE=""
OUT="$ROOT/dist/linux"
TARBALL_ONLY=0
REQUIRE_DEB=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION=$2; shift 2 ;;
    --arch) ARCH=$2; shift 2 ;;
    --bundle) BUNDLE=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --tarball-only) TARBALL_ONLY=1; shift ;;
    --require-deb) REQUIRE_DEB=1; shift ;;
    -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  VERSION=$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' "$APP/pubspec.yaml")
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([~.+-][0-9A-Za-z.~+-]*)?$ ]] \
  || die "version '$VERSION' is not of the form X.Y.Z"

if [[ -z "$ARCH" ]]; then
  case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "unsupported machine $(uname -m); pass --arch" ;;
  esac
fi
case "$ARCH" in
  amd64) FLUTTER_ARCH=x64 ;;
  arm64) FLUTTER_ARCH=arm64 ;;
  *) die "unsupported architecture $ARCH (amd64 or arm64)" ;;
esac
BUNDLE="${BUNDLE:-$APP/build/linux/$FLUTTER_ARCH/release/bundle}"
[[ -x "$BUNDLE/$BINARY" ]] \
  || die "no release bundle at $BUNDLE; run 'flutter build linux --release' in apps/finance_app"

if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH=$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date +%s)
fi
export SOURCE_DATE_EPOCH
RELEASE_DATE=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%d)
MAINTAINER="${FINANCE_DEB_MAINTAINER:-Paul Snow <bovinemagnet@gmail.com>}"

WORK="$(mktemp -d -t finance-package.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# Shared desktop integration files, laid out under share/ as for /usr/share.
stage_share() {
  local share=$1
  install -Dm644 "$HERE/$APP_ID.desktop" "$share/applications/$APP_ID.desktop"
  sed -e "s/@VERSION@/$VERSION/" -e "s/@DATE@/$RELEASE_DATE/" \
    "$HERE/$APP_ID.metainfo.xml" >"$WORK/$APP_ID.metainfo.xml"
  install -Dm644 "$WORK/$APP_ID.metainfo.xml" "$share/metainfo/$APP_ID.metainfo.xml"
  local size
  for size in 128 256 512; do
    install -Dm644 "$ICON_DIR/app_icon_$size.png" \
      "$share/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
  done
}

validate_share() {
  local share=$1
  if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$share/applications/$APP_ID.desktop"
  else
    log "desktop-file-validate not installed; skipping desktop file check"
  fi
  if command -v appstreamcli >/dev/null 2>&1; then
    appstreamcli validate --no-net --explain "$share/metainfo/$APP_ID.metainfo.xml"
  else
    log "appstreamcli not installed; skipping metainfo check"
  fi
}

# Deterministic archive: sorted names, fixed owner and timestamps.
make_tarball() {
  local src_parent=$1 name=$2 target=$3
  tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@$SOURCE_DATE_EPOCH" -C "$src_parent" -cf - "$name" \
    | gzip -n -9 >"$target"
}

# 1. Tarball: the bundle plus share/ with the desktop file, icons and metainfo.
TAR_NAME="$PACKAGE-$VERSION-linux-$ARCH"
TAR_ROOT="$WORK/tar/$TAR_NAME"
mkdir -p "$TAR_ROOT"
cp -a "$BUNDLE/." "$TAR_ROOT/"
stage_share "$TAR_ROOT/share"
validate_share "$TAR_ROOT/share"
make_tarball "$WORK/tar" "$TAR_NAME" "$OUT/$TAR_NAME.tar.gz"
log "wrote $OUT/$TAR_NAME.tar.gz"

if [[ $TARBALL_ONLY == 1 ]]; then
  exit 0
fi
if ! command -v dpkg-deb >/dev/null 2>&1; then
  if [[ $REQUIRE_DEB == 1 ]]; then
    die "dpkg-deb is not installed and --require-deb was given"
  fi
  log "dpkg-deb not installed; skipping the .deb (it is built in CI on Ubuntu)"
  exit 0
fi

# 2. Debian package: bundle in /opt/finance-app, launcher in /usr/bin.
DEB_ROOT="$WORK/deb"
mkdir -p "$DEB_ROOT/opt/$PACKAGE" "$DEB_ROOT/usr/bin" "$DEB_ROOT/DEBIAN"
cp -a "$BUNDLE/." "$DEB_ROOT/opt/$PACKAGE/"
ln -s "/opt/$PACKAGE/$BINARY" "$DEB_ROOT/usr/bin/$PACKAGE"
stage_share "$DEB_ROOT/usr/share"
chmod -R u=rwX,go=rX "$DEB_ROOT"
INSTALLED_SIZE=$(du -sk --exclude=DEBIAN "$DEB_ROOT" | cut -f1)

# Runtime libraries for the GTK embedder and the Linux plugins
# (flutter_secure_storage needs libsecret, desktop_webview_window needs
# WebKitGTK 4.1 and libsoup 3). Package names follow Ubuntu 24.04 LTS, the
# baseline; the alternatives keep 22.04 installable.
cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $VERSION
Architecture: $ARCH
Maintainer: $MAINTAINER
Installed-Size: $INSTALLED_SIZE
Section: misc
Priority: optional
Homepage: https://github.com/bovinemagnet/flutter-finances
Depends: libc6, libstdc++6, libgtk-3-0t64 | libgtk-3-0, libsecret-1-0, libwebkit2gtk-4.1-0, libsoup-3.0-0
Recommends: gnome-keyring | kwalletmanager
Description: Personal finance with budgeting, planning and receipt capture
 Records spending across bank, card and cash accounts, plans budgets around
 pay cycles, forecasts bills and keeps receipts with their transactions.
 Data is stored in an encrypted local database and works offline; the
 platform secret service holds the database key.
EOF

find "$DEB_ROOT" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
DEB="$OUT/${PACKAGE}_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group -Zxz --build "$DEB_ROOT" "$DEB" >/dev/null
dpkg-deb --info "$DEB" >/dev/null
log "wrote $DEB"
