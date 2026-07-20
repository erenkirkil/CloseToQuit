#!/bin/bash
# CloseToQuit'i derler, .app paketine koyar ve Developer ID ile imzalar.
#
# Kullanım:
#   ./build.sh            -> yerel imzalı derleme (hardened runtime + timestamp), notarization YOK
#   ./build.sh release    -> yukarıdakiler + .dmg üretimi + notarization + staple (dağıtıma hazır)
#
# Aynı Developer ID sertifikasıyla imza sabit kaldığı için Accessibility izni
# yeniden derlemelerde korunur (eski self-signed keychain hilesine gerek yok).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPDIR="$HOME/Applications"
APP="$APPDIR/CloseToQuit.app"

# İmza kimliği ve notary profili ortam değişkeninden okunur — kimlik repoya girmez.
# Kendi kimliğini bul:  security find-identity -v -p codesigning
# Örn:  export CTQ_SIGN_ID="Developer ID Application: ADIN SOYADIN (TEAMID)"
# Yerel geliştirme için ad-hoc imza da kullanılabilir:  export CTQ_SIGN_ID="-"
SIGN_ID="${CTQ_SIGN_ID:?CTQ_SIGN_ID tanımlı değil — 'security find-identity -v -p codesigning' ile kimliğini bul}"
NOTARY_PROFILE="${CTQ_NOTARY_PROFILE:-closetoquit-notary}"   # notarytool store-credentials ile oluşturulur

MODE="${1:-dev}"

echo "== Derleniyor =="
swiftc -O -swift-version 5 "$SRC/main.swift" -o "$SRC/CloseToQuit" \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement

echo "== .app paketi oluşturuluyor =="
mkdir -p "$APPDIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/CloseToQuit" "$APP/Contents/MacOS/CloseToQuit"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/CloseToQuit"

echo "== Developer ID ile imzalanıyor (hardened runtime + timestamp) =="
# --options runtime: notarization için zorunlu. --timestamp: güvenli zaman damgası (notarization zorunluluğu).
codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$APP"

echo "== İmza doğrulanıyor =="
codesign --verify --strict --verbose=2 "$APP"
# Yerel derlemede Gatekeeper henüz notarize edilmediği için "rejected" diyebilir; bu normaldir.
spctl --assess --type execute --verbose=4 "$APP" 2>&1 || true

if [ "$MODE" != "release" ]; then
  echo "OK (yerel imzalı derleme): $APP"
  echo "Dağıtıma hazır paket için:  ./build.sh release"
  exit 0
fi

# ---- release: notarization + dmg + staple ----
STAGE="$(mktemp -d)"
ZIP="$STAGE/CloseToQuit.zip"
DMG="$SRC/CloseToQuit.dmg"

echo "== Notarization için zip hazırlanıyor =="
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "== Notarization'a gönderiliyor (.app) — sonuç bekleniyor =="
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "== Ticket .app'e staple ediliyor =="
xcrun stapler staple "$APP"

echo "== .dmg oluşturuluyor =="
rm -f "$DMG"
/usr/bin/hdiutil create -volname "CloseToQuit" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "== .dmg notarize ediliyor — sonuç bekleniyor =="
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "== Ticket .dmg'ye staple ediliyor =="
xcrun stapler staple "$DMG"

echo "== Gatekeeper son doğrulama =="
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" 2>&1 || true
xcrun stapler validate "$DMG"

rm -rf "$STAGE"
echo "OK (dağıtıma hazır): $DMG"
