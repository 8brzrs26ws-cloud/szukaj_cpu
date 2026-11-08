#!/usr/bin/env bash
# Buduje pakiet dist/szukaj-cpu_<wersja>_all.deb (wymaga tylko dpkg-deb).
#   bash packaging/build-deb.sh
# Opcjonalnie dołącza statyczny ffmpeg/ffprobe (tools/build_ffmpeg.sh), jeśli podasz katalog:
#   FFMPEG_DIR=./ffmpeg-szukaj bash packaging/build-deb.sh   # pakiet staje się amd64
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
ARCH=all
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
chmod 755 "$STAGE"
OPT="$STAGE/opt/szukaj_cpu"

install -d "$OPT/tools" "$OPT/ntfy" "$STAGE/usr/bin" "$STAGE/usr/lib/systemd/system" \
           "$STAGE/usr/share/doc/szukaj-cpu" "$STAGE/DEBIAN"

install -m 755 "$ROOT/src/szukaj_cpu.py"            "$OPT/szukaj_cpu.py"
install -m 644 "$ROOT/config/szukaj_cpu.toml"       "$OPT/szukaj_cpu.toml.example"
install -m 644 "$ROOT/requirements.txt"             "$OPT/requirements.txt"
install -m 755 "$ROOT/tools/build_ffmpeg.sh"        "$OPT/tools/"
install -m 755 "$ROOT/tools/test_przerwy.py"        "$OPT/tools/"
install -m 644 "$ROOT/ntfy/server.yml.in"           "$OPT/ntfy/"
install -m 644 "$ROOT/ntfy/docker-compose.yml"      "$OPT/ntfy/"
install -m 755 "$ROOT/ntfy/setup-ntfy.sh"           "$OPT/ntfy/"
install -m 755 "$ROOT/uninstall.sh"                 "$OPT/uninstall.sh"
install -m 755 "$ROOT/bin/szukaj-cpu"               "$STAGE/usr/bin/"
install -m 755 "$ROOT/bin/szukaj-cpu-export-tools"  "$STAGE/usr/bin/"
install -m 644 "$ROOT/systemd/szukaj_cpu@.service"  "$STAGE/usr/lib/systemd/system/"
install -m 644 "$ROOT/README.md"                    "$STAGE/usr/share/doc/szukaj-cpu/"

if [ -n "${FFMPEG_DIR:-}" ]; then
    install -m 755 "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe" "$OPT/"
    [ -f "$FFMPEG_DIR/BUILDINFO.txt" ] && install -m 644 "$FFMPEG_DIR/BUILDINFO.txt" "$OPT/FFMPEG_BUILDINFO.txt"
    ARCH=amd64
fi

for f in postinst prerm postrm; do
    install -m 755 "$ROOT/packaging/debian/$f" "$STAGE/DEBIAN/$f"
done
SIZE="$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SIZE@/$SIZE/" -e "s/^Architecture: .*/Architecture: $ARCH/" \
    "$ROOT/packaging/debian/control.in" > "$STAGE/DEBIAN/control"
if [ "$ARCH" = amd64 ]; then
    sed -i 's/^Recommends: ffmpeg, /Recommends: /' "$STAGE/DEBIAN/control"
fi

mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/szukaj-cpu_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT" >/dev/null
echo "Zbudowano: $OUT"
