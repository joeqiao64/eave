#!/bin/zsh
# Build Eave.app and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

# PERCH_DEBUG=1 ./build.sh  → includes the perch-ctl debug hooks (snapshots, simulated screenshots…)
if [[ "${PERCH_DEBUG:-0}" == "1" ]]; then
  swift build -c release -Xswiftc -DPERCH_DEBUG
else
  swift build -c release
fi

APP=build/Eave.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Eave "$APP/Contents/MacOS/Eave"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with the stable local identity so macOS privacy permissions (Screen Recording,
# Automation) survive rebuilds. Falls back to ad-hoc if the certificate is missing.
if security find-identity -p codesigning | grep -q "Perch Local Signing"; then
  codesign --force --sign "Perch Local Signing" --identifier com.local.perch "$APP"
else
  echo "warning: 'Perch Local Signing' certificate not found, using ad-hoc signature"
  codesign --force --sign - --identifier com.local.perch "$APP"
fi

mkdir -p ~/Applications
pkill -x Perch 2>/dev/null || true
pkill -x Eave 2>/dev/null || true
rm -rf ~/Applications/Perch.app ~/Applications/Eave.app   # Perch was the old name
cp -R "$APP" ~/Applications/Eave.app
echo "Installed ~/Applications/Eave.app"
