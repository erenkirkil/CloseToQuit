#!/bin/bash
# CloseToQuit'i derler, .app paketine koyar ve SABİT sertifikayla imzalar.
# Sabit imza sayesinde Erişilebilirlik izni her yeniden derlemede korunur.
set -e

SRC="$HOME/CloseToQuit-src"
APPDIR="$HOME/Applications"
APP="$APPDIR/CloseToQuit.app"
KC="$HOME/Library/Keychains/closetoquit-signing.keychain-db"
CERT="CloseToQuit Self-Signed"

echo "== Derleniyor =="
swiftc -O -swift-version 5 "$SRC/main.swift" -o "$SRC/CloseToQuit" \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement

echo "== .app paketi oluşturuluyor =="
mkdir -p "$APPDIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/CloseToQuit" "$APP/Contents/MacOS/CloseToQuit"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/CloseToQuit"

echo "== Sabit sertifikayla imzalanıyor =="
# Özel keychain arama listesinde değilse, mevcutleri koruyarak ekle (codesign'ın kimliği bulması için)
EXISTING=$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')
if ! echo "$EXISTING" | grep -q "closetoquit-signing"; then
  security list-keychains -d user -s "$KC" $EXISTING
fi
security unlock-keychain -p closetoquit "$KC" >/dev/null 2>&1 || true
codesign --force --deep --sign "$CERT" "$APP"

echo "== Designated requirement (cdhash yerine sertifika kimliği olmalı) =="
codesign -d -r- "$APP" 2>&1 | tail -3
echo "OK: $APP"
