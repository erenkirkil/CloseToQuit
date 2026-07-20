# CloseToQuit

Bir uygulamanın **son penceresi** kapandığında uygulamadan **nazikçe çıkar** (Cmd+Q
eşdeğeri). Böylece kırmızı kapatma düğmesi / Cmd+W ile pencereyi kapatınca uygulama
arka planda çalışmaya devam etmek yerine tamamen kapanır.

Menü-çubuğu uygulaması (Dock'ta ikonu yoktur). **Developer ID** ile imzalanır ve
notarize edilir; imza kimliği sabit kaldığından Erişilebilirlik izni her yeniden
derlemede korunur.

## Nasıl çalışır

- **Yöntem:** Accessibility API (`AXObserver`) ile her uygulamanın pencere aç/kapa
  olayları izlenir. CGEventTap (global fare-tıklama yakalama) **kullanılmaz** — o yöntem
  kırılgan, pil-yiyici ve risklidir.
- Bir uygulamanın gerçek pencere sayısı 0'a düştüğünde, kısa bir gecikme sonrası
  yeniden doğrulanır ve `NSRunningApplication.terminate()` (nazik çıkış) çağrılır.
- **Asla zorla öldürmez** — kaydedilmemiş değişiklik için "Kaydet?" penceresi normal
  görünür.

## Güvenlik / kapsam

- Yalnızca **Dock'ta ikonu olan** (`.regular`) uygulamalar izlenir — menü-çubuğu
  ajanları (penceresiz arka plan uygulamaları) hiç etkilenmez.
- **Sabit korumalı** (asla çıkış uygulanmaz): Finder, System Settings, Dock,
  SystemUIServer, Control Center, Spotlight, loginwindow, WindowManager.
- **Hariç tutma listesi:** Menüden istediğin uygulamayı "çalışır kalsın" olarak
  işaretleyebilirsin (ör. Müzik/Spotify çalmaya devam etsin, ya da Takvim/Notlar
  açık kalsın). Liste kalıcıdır.

## Menü

- **Etkin** — özelliği aç/kapat (duraklat).
- **Çıkış Gecikmesi** — 0.2 / 0.5 / 1 / 2 saniye. Son pencere kapandıktan sonra
  çıkmadan önce beklenen süre (pencere yeniden açan uygulamalar için güvenlik payı).
- **Hariç Tutulan Uygulamalar** — çalışan uygulamaları listeler; işaretli olanlar
  çıkıştan muaftır.
- **Girişte Otomatik Başlat** — login öğesi olarak ekler.
- **Erişilebilirlik Ayarlarını Aç** — izin paneline kısa yol.

## Kurulum (son kullanıcı)

1. [Releases](../../releases) sayfasından `CloseToQuit.dmg`'yi indir.
2. DMG'yi aç, `CloseToQuit.app`'i **Uygulamalar**'a sürükle.
3. Çalıştır. İlk açılışta **Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik**'te
   CloseToQuit'i aç.

DMG notarize + staple edildiği için Gatekeeper uyarı vermeden açılır.

## Derleme (geliştirici)

Gereksinim: bir **Developer ID Application** sertifikası (Xcode/Apple Developer hesabı)
ve notarization için bir kez oluşturulan notarytool keychain profili:

```bash
# Notarization kimlik bilgisi (yalnızca ilk seferde)
xcrun notarytool store-credentials "closetoquit-notary" \
  --apple-id "<apple-id>" --team-id "<team-id>"
```

Ardından:

```bash
# Yerel imzalı derleme (hardened runtime + timestamp), notarization YOK
./build.sh

# Dağıtıma hazır paket: notarize + .dmg + staple (.app ve .dmg)
./build.sh release

# Çalıştır
open ~/Applications/CloseToQuit.app
```

Not: `build.sh` içindeki `SIGN_ID` ve `NOTARY_PROFILE` değerlerini kendi
sertifikana/profiline göre ayarla. İmza kimliği sabit kaldığından, ilk seferden sonra
Erişilebilirlik iznini tekrar vermen gerekmez.

## Bilinen sınırlar

- Kırmızı düğme ile Cmd+W'yi ayırt edemez — ikisi de son pencereyi kapatır, ikisi
  de çıkışı tetikler (istenen davranış budur).
- Native olmayan uygulamalar (bazı Electron/Java/oyun uygulamaları) AX pencere
  bilgisini hatalı verebilir; gerekirse onları hariç tut.
- macOS güncellemelerinden sonra Erişilebilirlik izni nadiren sıfırlanabilir; menü
  çubuğundaki durum "izin gerekli" derse paneli açıp tekrar ver.
