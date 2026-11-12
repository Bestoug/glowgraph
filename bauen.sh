#!/bin/bash
# Baut Glowgraph ohne Xcode-Projekt (nur swiftc, Kommandozeilenwerkzeuge reichen) und signiert ad hoc.
# Aufruf: ./bauen.sh [ziel-ordner]   → <ziel-ordner>/Glowgraph.app
set -euo pipefail
cd "$(dirname "$0")"
AUS="${1:-build}"; mkdir -p "$AUS"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
A="$AUS/Glowgraph.app"; rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
xcrun swiftc -O -wmo -target "$(uname -m)-apple-macos14.0" -sdk "$SDK" Quellen/Kern/*.swift Quellen/App/*.swift -o "$A/Contents/MacOS/Glowgraph"
cp Info/App-Info.plist "$A/Contents/Info.plist"
cp Ressourcen/Menue.png "$A/Contents/Resources/"
S="$AUS/AppIcon.iconset"; rm -rf "$S"; mkdir -p "$S"
for g in 16 32 128 256 512; do
  sips -z $g $g Ressourcen/AppIcon.png --out "$S/icon_${g}x${g}.png" >/dev/null
  sips -z $((g*2)) $((g*2)) Ressourcen/AppIcon.png --out "$S/icon_${g}x${g}@2x.png" >/dev/null
done
iconutil -c icns "$S" -o "$A/Contents/Resources/AppIcon.icns"; rm -rf "$S"
codesign --force --deep --sign - --timestamp=none "$A"
codesign --verify --verbose=2 "$A"
echo "Fertig: $A"
