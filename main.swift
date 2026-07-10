import Cocoa
import ApplicationServices
import ServiceManagement

// CloseToQuit — bir uygulamanın SON penceresi kapandığında uygulamadan nazikçe çıkar.
// Yaklaşım: CGEventTap (kırmızı düğme tıklamasını yakalama) DEĞİL — bu kırılgan ve risklidir.
// Bunun yerine her uygulamanın penceresi Accessibility (AXObserver) ile izlenir; son
// pencere yok olunca NSRunningApplication.terminate() (Cmd+Q eşdeğeri, nazik) çağrılır.
//
// Güvenlik ilkeleri:
//  - Asla zorla öldürme (forceTerminate/kill yok) -> "Kaydet?" penceresi normal görünür.
//  - Sadece .regular (Dock'ta ikonu olan) uygulamalar izlenir -> menü-çubuğu ajanları korunur.
//  - Finder ve sistem süreçleri sabit korumalı (asla çıkış uygulanmaz).
//  - Kullanıcının "çalışır kalsın" (hariç tutma) listesi.
//  - count==0 yalnızca AX sorgusu BAŞARILIYSA çıkışı tetikler; başarısız/zaman aşımı -> çıkma.
//  - Pencere yeniden açan uygulamalar için debounce (gecikme + yeniden sayım).

// MARK: - Sabit ayar anahtarları
let kEnabledKey  = "enabled"
let kExcludedKey = "excludedBundleIDs"
let kNamesKey    = "excludedNames"
let kDelayKey    = "quitDelaySeconds"

// MARK: - AX sabitleri (literal — framework sabit-içe-aktarımına bağlı kalmamak için)
let axNoteWindowCreated   = "AXWindowCreated"        // == kAXWindowCreatedNotification
let axNoteElemDestroyed   = "AXUIElementDestroyed"   // == kAXUIElementDestroyedNotification
let axRoleWindow          = "AXWindow"               // == kAXWindowRole
let axSubStandard         = "AXStandardWindow"
let axSubDialog           = "AXDialog"
let axSubFloating         = "AXFloatingWindow"

// MARK: - Sabit korumalı uygulamalar (kullanıcı kaldıramaz, asla çıkış uygulanmaz)
let hardProtectedBundleIDs: Set<String> = [
    "com.apple.finder",
    "com.apple.systempreferences",   // System Settings / Sistem Ayarları
    "com.apple.dock",
    "com.apple.systemuiserver",
    "com.apple.controlcenter",
    "com.apple.Spotlight",
    "com.apple.loginwindow",
    "com.apple.WindowManager",
]

// MARK: - İzlenen uygulama (AXObserver bağlamı)
final class WatchedApp {
    let pid: pid_t
    let bundleID: String?
    let runningApp: NSRunningApplication    // sabit süreç kimliği (pid yeniden kullanımına dayanıklı)
    let appElement: AXUIElement
    var observer: AXObserver?
    var windowGeneration = 0                // her yeni pencerede artar (geçiş/yeniden-açılma tespiti)
    unowned let controller: AppController

    init(app: NSRunningApplication, controller: AppController) {
        self.pid = app.processIdentifier
        self.bundleID = app.bundleIdentifier
        self.runningApp = app
        self.appElement = AXUIElementCreateApplication(app.processIdentifier)
        self.controller = controller
        // Takılan uygulama callback'i (ve dolayısıyla tüm UI'yi) dondurmasın.
        AXUIElementSetMessagingTimeout(appElement, 0.25)
    }
}

// MARK: - Global AXObserver callback'i (ana iş parçacığında, run loop'tan çağrılır)
func axObserverCallback(_ observer: AXObserver,
                        _ element: AXUIElement,
                        _ notification: CFString,
                        _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let watched = Unmanaged<WatchedApp>.fromOpaque(refcon).takeUnretainedValue()
    switch notification as String {
    case axNoteWindowCreated:
        watched.controller.handleWindowCreated(watched, window: element)
    case axNoteElemDestroyed:
        watched.controller.handleWindowDestroyed(watched, window: element)
    default:
        break
    }
}

// MARK: - Uygulama denetleyicisi
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var healthTimer: Timer?
    var observing = false
    var watched: [pid_t: WatchedApp] = [:]
    // Bloklayan AX enümerasyonu/sayımı ana iş parçacığından ayır (gözlemci mutasyonları main'de kalır).
    let axQueue = DispatchQueue(label: "com.erenkirkil.closetoquit.ax", qos: .utility)

    // Ayarlar
    var isEnabled = true
    var excludedBundleIDs: Set<String> = []
    var excludedNames: [String: String] = [:]
    var quitDelay: Double = 0.5

    // Menü öğeleri
    let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let pauseMenuItem  = NSMenuItem(title: "Etkin", action: #selector(togglePause), keyEquivalent: "")
    let loginMenuItem  = NSMenuItem(title: "Girişte Otomatik Başlat", action: #selector(toggleLogin), keyEquivalent: "")
    let excludedParent = NSMenuItem(title: "Hariç Tutulan Uygulamalar", action: nil, keyEquivalent: "")
    let delayParent    = NSMenuItem(title: "Çıkış Gecikmesi", action: nil, keyEquivalent: "")

    // MARK: Yaşam döngüsü
    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSettings()
        buildStatusItem()

        // Erişilebilirlik promptu — sadece bir kez.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(appLaunched(_:)),
                         name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(appTerminated(_:)),
                         name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // AX izin değişimini olay-tetikli yakala; timer yalnızca seyrek yedek.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(axTrustMaybeChanged),
            name: NSNotification.Name("com.apple.accessibility.api"), object: nil)

        syncState()
        // Yedek sağlık kontrolü: seyrek aralık + tolerans -> çekirdek uyandırmaları birleştirebilsin.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.syncState()
        }
        healthTimer?.tolerance = 5.0
    }

    @objc func axTrustMaybeChanged() { DispatchQueue.main.async { [weak self] in self?.syncState() } }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        healthTimer = nil
        teardownAll()
    }

    // MARK: İzin + izleme durumu yönetimi
    func syncState() {
        let trusted = AXIsProcessTrusted()
        if trusted && !observing {
            observing = true
            attachAll()
        } else if !trusted && observing {
            observing = false
            teardownAll()
        }
        // pid yeniden kullanımına karşı: sonlanmış uygulamaların ölü gözlemcilerini topla
        // (terminate bildirimi kaçırılmış olabilir).
        if observing {
            for pid in Array(watched.keys) where watched[pid]?.runningApp.isTerminated == true {
                detach(pid: pid)
            }
        }
        updateUI(trusted: trusted)
    }

    func attachAll() {
        // Açılış patlamasını run-loop turlarına yay (tek senkron döngüde ana iş parçacığını tıkama).
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let a = app
            DispatchQueue.main.async { [weak self] in self?.attach(to: a) }
        }
    }

    func teardownAll() {
        for pid in Array(watched.keys) { detach(pid: pid) }
    }

    func attach(to app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        guard pid > 0, watched[pid] == nil else { return }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }   // kendimizi izleme

        let w = WatchedApp(app: app, controller: self)
        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let observer = obs else { return }
        w.observer = observer
        let refcon = Unmanaged.passUnretained(w).toOpaque()

        // Uygulama elemanına windowCreated (ana iş parçacığında — gözlemci mutasyonu).
        AXObserverAddNotification(observer, w.appElement, axNoteWindowCreated as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        watched[pid] = w

        // Mevcut pencerelerin enümerasyonu bloklayan AX'tir -> arka planda; kayıt yine ana iş parçacığında.
        let elem = w.appElement
        axQueue.async { [weak self, weak w] in
            let windows = self?.allWindows(elem) ?? []
            DispatchQueue.main.async {
                guard let self = self, let w = w,
                      self.watched[pid] === w, let observer = w.observer else { return }
                let refcon = Unmanaged.passUnretained(w).toOpaque()
                for win in windows {
                    AXObserverAddNotification(observer, win, axNoteElemDestroyed as CFString, refcon)
                }
            }
        }
    }

    func detach(pid: pid_t) {
        guard let w = watched[pid] else { return }
        if let observer = w.observer {
            // Gelecekteki refactor'lara karşı: kaynak + uygulama-düzeyi bildirimini açıkça kaldır
            // (kalan pencere kayıtları gözlemci serbest kalınca zaten yok olur).
            AXObserverRemoveNotification(observer, w.appElement, axNoteWindowCreated as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        watched.removeValue(forKey: pid)   // WatchedApp serbest kalır; observer da
    }

    // MARK: Pencere olayları
    func handleWindowCreated(_ w: WatchedApp, window: AXUIElement) {
        w.windowGeneration &+= 1   // yeni pencere -> bekleyen çıkış kontrollerini geçersiz kıl
        guard let observer = w.observer else { return }
        let refcon = Unmanaged.passUnretained(w).toOpaque()
        AXObserverAddNotification(observer, window, axNoteElemDestroyed as CFString, refcon)
    }

    func handleWindowDestroyed(_ w: WatchedApp, window: AXUIElement) {
        // Bu pencerenin destroyed kaydını kaldır (uzun oturumlarda sınırsız kayıt birikmesini önler).
        if let observer = w.observer {
            AXObserverRemoveNotification(observer, window, axNoteElemDestroyed as CFString)
        }
        guard isEnabled, !isProtected(w.bundleID) else { return }
        let gen = w.windowGeneration
        // Pencere sayımı (bloklayan AX) arka planda; karar/kuşak kontrolü ana iş parçacığında.
        countWindowsAsync(w) { [weak self, weak w] count in
            guard let self = self, let w = w,
                  self.watched[w.pid] === w, self.isEnabled, !self.isProtected(w.bundleID),
                  w.windowGeneration == gen, count == 0 else { return }
            // Debounce + kararlılık: yeni pencere açılmadığını (kuşak değişmedi) ve sayının 0
            // kaldığını ayrı örneklerle doğrula -> tam-ekran/Space geçişlerindeki geçici 0'ları ele.
            self.scheduleQuitCheck(w, gen: gen, delay: self.quitDelay, confirmsLeft: 1)
        }
    }

    // Gerçek pencere sayısını ARKA PLANDA hesapla; sonucu ana iş parçacığına döndür.
    func countWindowsAsync(_ w: WatchedApp, _ completion: @escaping (Int?) -> Void) {
        let elem = w.appElement
        axQueue.async { [weak self] in
            let count: Int? = self?.realWindowCount(elem) ?? nil
            DispatchQueue.main.async { completion(count) }
        }
    }

    func scheduleQuitCheck(_ w: WatchedApp, gen: Int, delay: Double, confirmsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak w] in
            guard let self = self, let w = w,
                  self.watched[w.pid] === w,          // pid yeniden kullanıldıysa farklı örnek -> iptal
                  self.isEnabled, !self.isProtected(w.bundleID),
                  w.windowGeneration == gen else { return }  // bu arada yeni pencere açıldıysa -> iptal
            self.countWindowsAsync(w) { [weak self, weak w] count in
                guard let self = self, let w = w,
                      self.watched[w.pid] === w, self.isEnabled, !self.isProtected(w.bundleID),
                      w.windowGeneration == gen, count == 0 else { return }
                if confirmsLeft > 0 {
                    self.scheduleQuitCheck(w, gen: gen, delay: 0.35, confirmsLeft: confirmsLeft - 1)
                } else {
                    guard !w.runningApp.isTerminated else { return }
                    w.runningApp.terminate()   // nazik çıkış — "Kaydet?" penceresi normal görünür
                }
            }
        }
    }

    func isProtected(_ bundleID: String?) -> Bool {
        guard let bid = bundleID else { return false }
        return hardProtectedBundleIDs.contains(bid) || excludedBundleIDs.contains(bid)
    }

    // MARK: AX pencere yardımcıları
    func allWindows(_ appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    // Pencere sınıflandırması: gerçek / gerçek değil / belirlenemedi.
    enum WindowKind { case real, notReal, unknown }

    // Gerçek (uygulamayı ayakta tutan) pencere sayısı.
    // nil = güvenilir biçimde belirlenemedi (sorgu başarısız/zaman aşımı) -> ASLA çıkma.
    func realWindowCount(_ appElement: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard err == .success else { return nil }
        guard let windows = value as? [AXUIElement] else { return 0 }   // başarılı ama dizi yok = 0 pencere
        var count = 0
        for win in windows {
            switch windowKind(win) {
            case .real:    count += 1
            case .notReal: continue
            case .unknown: return nil   // tek bir pencere bile belirlenemedi -> sayım güvenilmez, çıkma
            }
        }
        return count
    }

    // Sheet/popover/AXUnknown sayılmaz; standart/dialog/floating sayılır.
    // Rol sorgusu BAŞARISIZ olursa .unknown -> zaman aşımı yüzünden açık pencereyi "yok"
    // sayıp meşgul uygulamayı erken kapatmamak için (fail-safe).
    func windowKind(_ win: AXUIElement) -> WindowKind {
        AXUIElementSetMessagingTimeout(win, 0.25)
        var roleRef: CFTypeRef?
        let roleErr = AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &roleRef)
        guard roleErr == .success else { return .unknown }    // sorgu başarısız/zaman aşımı -> bilinmiyor
        guard let role = roleRef as? String else { return .unknown }
        guard role == axRoleWindow else { return .notReal }   // rol okundu ama pencere değil (sheet/popover vb.)
        var subRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subRef) == .success,
           let subrole = subRef as? String {
            return (subrole == axSubStandard || subrole == axSubDialog || subrole == axSubFloating)
                ? .real : .notReal
        }
        return .real   // alt-rol yok ama rol AXWindow -> güvenli taraf: pencere say (erken çıkma)
    }

    // MARK: NSWorkspace bildirimleri
    @objc func appLaunched(_ note: Notification) {
        guard observing,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attach(to: app)
    }

    @objc func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        detach(pid: app.processIdentifier)
    }

    // MARK: Menü
    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "CloseToQuit") {
                button.image = img
            } else {
                button.title = "ⓧ"
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        pauseMenuItem.target = self
        menu.addItem(pauseMenuItem)

        delayParent.submenu = buildDelaySubmenu()
        menu.addItem(delayParent)

        excludedParent.submenu = buildExcludedSubmenu()
        menu.addItem(excludedParent)

        loginMenuItem.target = self
        menu.addItem(loginMenuItem)

        let axItem = NSMenuItem(title: "Erişilebilirlik Ayarlarını Aç",
                                action: #selector(openAccessibilitySettings), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Çıkış", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshMenuItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        syncState()
        delayParent.submenu = buildDelaySubmenu()
        excludedParent.submenu = buildExcludedSubmenu()
        refreshMenuItems()
    }

    func buildDelaySubmenu() -> NSMenu {
        let sub = NSMenu()
        let presets: [(String, Double)] = [("0.2 saniye", 0.2), ("0.5 saniye", 0.5),
                                           ("1 saniye", 1.0), ("2 saniye", 2.0)]
        for (label, value) in presets {
            let item = NSMenuItem(title: label, action: #selector(setDelay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(quitDelay - value) < 0.001 ? .on : .off
            sub.addItem(item)
        }
        return sub
    }

    func buildExcludedSubmenu() -> NSMenu {
        let sub = NSMenu()
        var entries: [(bid: String, name: String)] = []
        var seen = Set<String>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier,
                  bid != Bundle.main.bundleIdentifier,
                  !hardProtectedBundleIDs.contains(bid) else { continue }
            if seen.insert(bid).inserted {
                entries.append((bid, app.localizedName ?? bid))
            }
        }
        for bid in excludedBundleIDs where !seen.contains(bid) {
            entries.append((bid, excludedNames[bid] ?? bid))
            seen.insert(bid)
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let header = NSMenuItem(title: "İşaretli = çıkış kapalı (çalışır kalır)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        sub.addItem(header)
        sub.addItem(.separator())
        if entries.isEmpty {
            let none = NSMenuItem(title: "(uygulanabilir uygulama yok)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
            return sub
        }
        for e in entries {
            let item = NSMenuItem(title: e.name, action: #selector(toggleExclude(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = e.bid
            item.state = excludedBundleIDs.contains(e.bid) ? .on : .off
            sub.addItem(item)
        }
        return sub
    }

    func refreshMenuItems() {
        updateUI()
        pauseMenuItem.state = isEnabled ? .on : .off
        switch SMAppService.mainApp.status {
        case .enabled:
            loginMenuItem.title = "Girişte Otomatik Başlat"
            loginMenuItem.state = .on
        case .requiresApproval:
            loginMenuItem.title = "Girişte Otomatik Başlat (onay bekliyor)"
            loginMenuItem.state = .mixed
        default:
            loginMenuItem.title = "Girişte Otomatik Başlat"
            loginMenuItem.state = .off
        }
    }

    func updateUI(trusted: Bool = AXIsProcessTrusted()) {
        let statusText: String
        if !trusted { statusText = "Erişilebilirlik izni gerekli" }
        else if !isEnabled { statusText = "Duraklatıldı" }
        else { statusText = "Aktif ✓ (\(watched.count) uygulama)" }
        statusMenuItem.title = "CloseToQuit — \(statusText)"
        statusItem?.button?.appearsDisabled = !(trusted && isEnabled)
    }

    // MARK: Eylemler
    @objc func togglePause() {
        isEnabled.toggle()
        saveSettings()
        refreshMenuItems()
    }

    @objc func setDelay(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double {
            quitDelay = v
            saveSettings()
        }
    }

    @objc func toggleExclude(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        if excludedBundleIDs.contains(bid) {
            excludedBundleIDs.remove(bid)
            excludedNames.removeValue(forKey: bid)
        } else {
            excludedBundleIDs.insert(bid)
            excludedNames[bid] = sender.title
        }
        saveSettings()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    showAlert(title: "Onay Gerekli",
                              text: "Otomatik başlatmayı tamamlamak için Sistem Ayarları > Genel > Giriş Öğeleri'nde CloseToQuit'i açın.")
                }
            }
        } catch {
            showAlert(title: "Hata", text: "Giriş öğesi ayarlanamadı:\n\(error.localizedDescription)")
        }
        refreshMenuItems()
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: Ayar kalıcılığı
    func loadSettings() {
        let d = UserDefaults.standard
        if d.object(forKey: kEnabledKey) != nil { isEnabled = d.bool(forKey: kEnabledKey) }
        if let arr = d.array(forKey: kExcludedKey) as? [String] { excludedBundleIDs = Set(arr) }
        if let names = d.dictionary(forKey: kNamesKey) as? [String: String] { excludedNames = names }
        let delay = d.double(forKey: kDelayKey)
        quitDelay = delay > 0 ? delay : 0.5
    }

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(isEnabled, forKey: kEnabledKey)
        d.set(Array(excludedBundleIDs), forKey: kExcludedKey)
        d.set(excludedNames, forKey: kNamesKey)
        d.set(quitDelay, forKey: kDelayKey)
    }
}

// MARK: - Giriş noktası

// Tek örnek koruması: aynı bundle ID ile başka kopya çalışıyorsa sessizce çık.
if let bid = NSRunningApplication.current.bundleIdentifier {
    let mePID = NSRunningApplication.current.processIdentifier
    let dupes = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == bid && $0.processIdentifier != mePID
    }
    if !dupes.isEmpty { exit(0) }
}

ProcessInfo.processInfo.enableSuddenTermination()   // durumsuz ajan -> logout/restart'ı bekletme

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)   // Dock'ta ikon yok; sadece menü çubuğu
app.run()
