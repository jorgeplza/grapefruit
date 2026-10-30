#!/bin/zsh
# Builds "build/Grapefruit.app" and (with --run) relaunches it.
#   scripts/build.sh            release build
#   scripts/build.sh --debug    debug build
#   scripts/build.sh --run      build, install to /Applications, relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
RUN=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --run) RUN=1 ;;
  esac
done

APP="build/Grapefruit.app"
EXE=Grapefruit

swift build -c "$CONFIG" --product "$EXE" 2>&1 | grep -vE "^\[[0-9]+/[0-9]+\] (Compiling|Emitting|Write|Planning)" || true
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)
[[ -x "$BIN_DIR/$EXE" ]] || { echo "build failed"; exit 1; }

# Make the icon once (or when the generator changes).
if [[ ! -f Support/AppIcon.icns || scripts/make-icon.swift -nt Support/AppIcon.icns ]]; then
  swift scripts/make-icon.swift Support/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXE" "$APP/Contents/MacOS/$EXE"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps macOS permission grants across rebuilds.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --timestamp=none --sign "${IDENTITY:--}" "$APP" >/dev/null
echo "built: $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ $RUN == 1 ]]; then
  # Installs into /Applications so Spotlight finds it, and drops the build
  # copy so Spotlight shows only one Grapefruit.
  INSTALLED="/Applications/Grapefruit.app"
  pkill -x "$EXE" 2>/dev/null || true
  sleep 0.4
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  rm -rf "$APP"
  open "$INSTALLED"
  echo "installed and launched: $INSTALLED"
fi
