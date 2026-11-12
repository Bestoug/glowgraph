import AppKit
import IOKit.pwr_mgt
import ServiceManagement

// Glowgraph: zeigt das Netz eines Obsidian-Vaults live als Schreibtisch, als eigenen Bildschirmschoner bei Leerlauf
// und als Standbild (echtes Hintergrundbild → Sperrbildschirm). Liest nur den gewählten Ordner, kein Netz.

/// Deutsch, wenn das System Deutsch spricht, sonst Englisch
func T(_ de: String, _ en: String) -> String { (Locale.preferredLanguages.first ?? "en").hasPrefix("de") ? de : en }

final class Fenster: NSWindow { override var canBecomeKey: Bool { false } }
/// Schoner-Fenster nimmt Tastendrücke an (und verschluckt sie), damit nichts in die App darunter getippt wird
final class SchonerFenster: NSWindow { override var canBecomeKey: Bool { true } }
final class Schlucker: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {}
    override func mouseDown(with e: NSEvent) {}
}

final class Bildschirm {
    let schirm: NSScreen
    let fenster: Fenster
    var darstellung: LaterneMetal?
    init(_ s: NSScreen) {
        schirm = s
        fenster = Fenster(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
        fenster.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        fenster.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        fenster.ignoresMouseEvents = true; fenster.hasShadow = false; fenster.isOpaque = true
        fenster.backgroundColor = .black; fenster.isReleasedWhenClosed = false
        fenster.contentView = NSView(frame: NSRect(origin: .zero, size: s.frame.size))
        fenster.setFrame(s.frame, display: false)   // sichtbar erst mit Daten (sonst schwarzer Schreibtisch, solange kein Vault gewählt ist)
    }
}

final class Einstellungen {
    let d = UserDefaults.standard
    /// Minuten bis zum Bildschirmschoner, 0 = aus
    var schoner: Int { get { d.object(forKey: "schoner") as? Int ?? 10 } set { d.set(newValue, forKey: "schoner") } }
    var vault: URL? { get { d.string(forKey: "vault").map { URL(fileURLWithPath: $0) } } set { d.set(newValue?.path, forKey: "vault") } }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let einst = Einstellungen()
    var quelle: Quelle!
    var schirme: [Bildschirm] = []
    var statusItem: NSStatusItem!
    var gestartet = Date()
    // Bildschirmschoner
    var schonerFenster: [SchonerFenster] = []
    var schonerAn = false
    var leerlaufVorher: Double = 0
    var schonerTakt: Timer?
    var vorherAktiv: NSRunningApplication?
    var schlaeft = false
    var standbildSha: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        Protokoll.schreiben("Start \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
        if einst.vault == nil, let v = VaultLeser.bekannteVaults().first { einst.vault = v; Protokoll.schreiben("Vault aus Obsidian übernommen") }
        quelle = Quelle(vault: einst.vault)
        quelle.beiNeu = { [weak self] g, s in self?.neueDaten(g, s) }
        quelle.beiZustand = { [weak self] in self?.symbolAktualisieren() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menue = NSMenu(); menue.delegate = self; statusItem.menu = menue
        symbolAktualisieren()
        aufbauen()
        quelle.starten()
        if einst.vault == nil { DispatchQueue.main.async { self.ordnerWaehlen() } }
        let nc = NotificationCenter.default, wc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.bildschirmMeldung() }
        wc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.schlaf(true) }
        wc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.schlaf(false) }
        wc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.schlaf(true) }
        wc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.schlaf(false) }
        schonerTakt = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.leerlaufPruefen() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.symbolAktualisieren() }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.raenderAktualisieren() }
    }

    // MARK: Schreibtisch
    /// macOS meldet „Bildschirm geändert“ auch, wenn sich nur Dock oder Menüleiste bewegen (bis zu 18-mal je Sekunde, Protokoll 12.11.).
    /// Neu aufgebaut wird nur, wenn sich Anzahl, Größe oder Schärfe der Bildschirme wirklich ändern – und erst nach einer Sekunde Ruhe.
    var signatur = ""
    var meldungArbeit: DispatchWorkItem?
    var ueberhoerteMeldungen = 0, letzteMeldungsNotiz = Date.distantPast
    func bildschirmSignatur() -> String {
        NSScreen.screens.map { "\($0.frame.debugDescription)@\($0.backingScaleFactor)" }.joined(separator: "|")
    }
    /// Freie Fläche eines Bildschirms: Menüleiste oben, Dock unten/links/rechts (ändert sich, wenn das Dock den Bildschirm wechselt)
    static func rand(_ s: NSScreen) -> NSEdgeInsets {
        let f = s.frame, v = s.visibleFrame
        return NSEdgeInsets(top: max(0, f.maxY - v.maxY), left: max(0, v.minX - f.minX), bottom: max(0, v.minY - f.minY), right: max(0, f.maxX - v.maxX))
    }
    func raenderAktualisieren() {
        let nr = NSDeviceDescriptionKey("NSScreenNumber")
        for s in schirme {
            // aktuelles NSScreen-Objekt zum selben Bildschirm holen (alte Objekte können veraltete Werte liefern)
            let id = s.schirm.deviceDescription[nr] as? NSNumber
            let aktuell = NSScreen.screens.first { ($0.deviceDescription[nr] as? NSNumber) == id } ?? s.schirm
            s.darstellung?.rand = Self.rand(aktuell)
        }
    }
    func bildschirmMeldung() {
        raenderAktualisieren()   // Dock gewechselt: nur die Ziel-Mitte verschieben, das Netz gleitet langsam hin
        meldungArbeit?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.bildschirmSignatur() == self.signatur {
                self.ueberhoerteMeldungen += 1
                if Date().timeIntervalSince(self.letzteMeldungsNotiz) > 3600 {
                    Protokoll.schreiben("Bildschirm-Meldungen ohne echte Änderung übergangen: \(self.ueberhoerteMeldungen)"); self.letzteMeldungsNotiz = Date()
                }
                return
            }
            self.aufbauen()
        }
        meldungArbeit = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }
    var verdeckt: [NSObjectProtocol] = []
    func aufbauen() {
        signatur = bildschirmSignatur()
        for t in verdeckt { NotificationCenter.default.removeObserver(t) }; verdeckt = []
        schonerBeenden(sofort: true)
        for s in schirme { s.darstellung?.ansicht.isPaused = true; s.darstellung?.ansicht.removeFromSuperview(); s.fenster.orderOut(nil) }
        schirme = NSScreen.screens.map { Bildschirm($0) }
        for s in schirme {
            verdeckt.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: s.fenster, queue: .main) { [weak self] _ in self?.sichtbarkeit() })
        }
        if let g = quelle.daten, let sz = quelle.szene { for s in schirme { anzeigen(s, g, sz) }; standbildPlanen() }
        Protokoll.schreiben("Bildschirme: \(schirme.map { "\(Int($0.schirm.frame.width))x\(Int($0.schirm.frame.height))" }.joined(separator: ", "))")
    }
    func anzeigen(_ s: Bildschirm, _ g: GraphDaten, _ sz: Szene) {
        guard let d = LaterneMetal(rahmen: s.fenster.contentView!.bounds) else { Protokoll.schreiben("Metal nicht verfügbar"); return }
        d.ansicht.autoresizingMask = [.width, .height]
        d.rand = Self.rand(s.schirm)
        d.setze(sz)
        s.fenster.contentView!.addSubview(d.ansicht); s.darstellung = d
        s.fenster.orderBack(nil)
        sichtbarkeit()
    }

    func neueDaten(_ g: GraphDaten, _ sz: Szene) {
        for s in schirme { if let d = s.darstellung { d.setze(sz) } else { anzeigen(s, g, sz) } }
        standbildPlanen()
    }

    /// Nur drosseln, solange der Schreibtisch nicht zu sehen ist (verdeckt, Vollbild-App, Bildschirm aus)
    func sichtbarkeit() {
        for s in schirme {
            let zuSehen = !schlaeft && (schonerAn || s.fenster.occlusionState.contains(.visible))
            s.darstellung?.ansicht.isPaused = !zuSehen
        }
    }
    func schlaf(_ an: Bool) { schlaeft = an; Protokoll.schreiben(an ? "Bildschirm aus/gesperrt" : "Bildschirm wieder an"); if an { schonerBeenden(sofort: true) }; sichtbarkeit() }

    // MARK: Bildschirmschoner (eigenes Vollbild-Fenster bei Leerlauf, nicht Apples .saver)
    func leerlauf() -> Double { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }
    /// Spielt gerade ein Video o. Ä. (jemand verhindert das Abschalten des Bildschirms)? Dann keinen Schoner starten.
    func bildschirmGehalten() -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&dict) == kIOReturnSuccess, let d = dict?.takeRetainedValue() as? [String: Int] else { return false }
        return (d["PreventUserIdleDisplaySleep"] ?? 0) > 0
    }
    func leerlaufPruefen() {
        guard !schonerAn, einst.schoner > 0, !schlaeft, quelle.daten != nil else { return }
        if leerlauf() >= Double(einst.schoner * 60) && !bildschirmGehalten() { schonerStarten() }
    }
    @objc func schonerStarten() {
        guard !schonerAn, !schirme.isEmpty else { return }
        schonerAn = true
        vorherAktiv = NSWorkspace.shared.frontmostApplication
        Protokoll.schreiben("Bildschirmschoner an (Leerlauf \(Int(leerlauf())) s)")
        for s in schirme {
            let f = SchonerFenster(contentRect: s.schirm.frame, styleMask: .borderless, backing: .buffered, defer: false)
            f.level = .screenSaver; f.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            f.backgroundColor = .black; f.isOpaque = false; f.alphaValue = 0; f.hasShadow = false; f.isReleasedWhenClosed = false
            f.contentView = Schlucker(frame: NSRect(origin: .zero, size: s.schirm.frame.size))
            f.setFrame(s.schirm.frame, display: false)
            if let v = s.darstellung?.ansicht { v.removeFromSuperview(); v.frame = f.contentView!.bounds; f.contentView!.addSubview(v) }
            f.orderFrontRegardless()
            schonerFenster.append(f)
        }
        sichtbarkeit()
        NSApp.activate(ignoringOtherApps: true)
        if let f = schonerFenster.first { f.makeKey(); f.makeFirstResponder(f.contentView) }
        NSAnimationContext.runAnimationGroup { c in c.duration = 1.6; c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for f in schonerFenster { f.animator().alphaValue = 1 } }
        NSCursor.setHiddenUntilMouseMoves(true)
        leerlaufVorher = leerlauf()
        // Jede Eingabe beendet den Schoner: Leerlaufzeit springt zurück (keine Zusatzrechte nötig)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] t in
            guard let self, self.schonerAn else { t.invalidate(); return }
            let l = self.leerlauf()
            if l + 0.15 < self.leerlaufVorher { t.invalidate(); Protokoll.schreiben("Eingabe erkannt (Leerlauf \(String(format: "%.1f", self.leerlaufVorher)) → \(String(format: "%.1f", l)) s)"); self.schonerBeenden(sofort: false) } else { self.leerlaufVorher = l }
        }
    }
    func schonerBeenden(sofort: Bool) {
        guard schonerAn else { return }
        schonerAn = false
        Protokoll.schreiben("Bildschirmschoner aus")
        let fenster = schonerFenster; schonerFenster = []
        let zurueck = { [self] in
            for (i, s) in schirme.enumerated() where i < fenster.count {
                if let v = s.darstellung?.ansicht { v.removeFromSuperview(); v.frame = s.fenster.contentView!.bounds; s.fenster.contentView!.addSubview(v) }
            }
            for f in fenster { f.orderOut(nil) }
            sichtbarkeit()
            vorherAktiv?.activate(); vorherAktiv = nil
        }
        if sofort { zurueck(); return }
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.5; for f in fenster { f.animator().alphaValue = 0 } }, completionHandler: zurueck)
    }

    // MARK: Standbild → echtes Hintergrundbild (zeigt auch der Sperrbildschirm), alte Bilder aufräumen
    /// Standbilder liegen in ~/Bilder/Glowgraph (üblicher Ort für Hintergrundbilder, auch für den Sperrbildschirm lesbar)
    static let bilderOrdner: URL = {
        let u = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Glowgraph")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    var letztesStandbild = Date.distantPast
    var standbildArbeit: DispatchWorkItem?
    func standbildPlanen() {
        standbildArbeit?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.standbildMachen() }
        standbildArbeit = w
        // höchstens alle 10 Minuten ein neues Bild (der Vault ändert sich oft mehrmals pro Viertelstunde)
        let warte = max(8, 600 - Date().timeIntervalSince(letztesStandbild))
        DispatchQueue.main.asyncAfter(deadline: .now() + warte, execute: w)
    }
    func standbildMachen() {
        let sha = (quelle.daten?.sha).flatMap { $0 } ?? "ohne"
        guard sha != standbildSha, let s = schirme.first(where: { $0.schirm == NSScreen.main }) ?? schirme.first,
              let d = s.darstellung else { return }
        let px = s.schirm.convertRectToBacking(s.schirm.frame).size
        do {
            guard let bild = d.standbild(breite: Int(px.width), hoehe: Int(px.height), dpr: Double(s.schirm.backingScaleFactor)) else { Protokoll.schreiben("Standbild: kein Bild"); return }
            let name = "standbild-\(sha.prefix(12))-\(Int(Date().timeIntervalSince1970)).png"
            let u = Self.bilderOrdner.appendingPathComponent(name)
            let rep = NSBitmapImageRep(cgImage: bild)
            guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: u, options: .atomic)) != nil else { return }
            for sc in NSScreen.screens {
                do { try NSWorkspace.shared.setDesktopImageURL(u, for: sc, options: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]) }
                catch { Protokoll.schreiben("Hintergrundbild setzen: \(error.localizedDescription)") }
            }
            self.standbildSha = sha; self.letztesStandbild = Date()
            // nur das aktuelle und ein Ersatzbild behalten
            let alle = ((try? FileManager.default.contentsOfDirectory(at: Self.bilderOrdner, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("standbild-") }
                .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast >
                          (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
            for alt in alle.dropFirst(2) { try? FileManager.default.removeItem(at: alt) }
            Protokoll.schreiben("Standbild \(name) gesetzt (\(bild.width)×\(bild.height), Ordner Bilder/Glowgraph)")
        }
    }

    // MARK: Menüleiste (Hinweis über die Form des Symbols, wenn der Vault fehlt)
    func symbolAktualisieren() {
        let fehlt = quelle.vault == nil || quelle.problem
        let eigen = Bundle.main.url(forResource: "Menue", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        eigen?.size = NSSize(width: 18, height: 18)
        let b = fehlt ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: T("Glowgraph: Vault nicht gefunden", "Glowgraph: vault not found"))
                      : (eigen ?? NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Glowgraph"))
        b?.isTemplate = true
        statusItem?.button?.image = b
        statusItem?.button?.toolTip = fehlt ? T("Vault nicht gefunden – im Menü einen Ordner wählen", "Vault not found – choose a folder in the menu") : "Glowgraph"
    }
    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        if let v = quelle.vault {
            m.addItem(withTitle: quelle.problem ? T("„\(v.lastPathComponent)“ nicht lesbar", "“\(v.lastPathComponent)” not readable")
                                                : "\(v.lastPathComponent): \(quelle.daten?.nodes.count ?? 0) \(T("Notizen", "notes"))", action: nil, keyEquivalent: "")
        } else { m.addItem(withTitle: T("Kein Vault gewählt", "No vault selected"), action: nil, keyEquivalent: "") }
        let vm = NSMenuItem(title: T("Vault", "Vault"), action: nil, keyEquivalent: ""); let vs = NSMenu()
        for u in VaultLeser.bekannteVaults() {
            let i = NSMenuItem(title: u.lastPathComponent, action: #selector(vaultWaehlen(_:)), keyEquivalent: "")
            i.representedObject = u; i.target = self; i.state = u.path == quelle.vault?.path ? .on : .off; i.toolTip = u.path; vs.addItem(i)
        }
        if !vs.items.isEmpty { vs.addItem(.separator()) }
        let anderer = NSMenuItem(title: T("Ordner wählen …", "Choose folder …"), action: #selector(ordnerWaehlen), keyEquivalent: ""); anderer.target = self; vs.addItem(anderer)
        vm.submenu = vs; m.addItem(vm)
        m.addItem(.separator())
        let sch = NSMenuItem(title: T("Bildschirmschoner", "Screen saver"), action: nil, keyEquivalent: ""); let scm = NSMenu()
        for mins in [0, 2, 5, 10, 15, 30] {
            let i = NSMenuItem(title: mins == 0 ? T("Aus", "Off") : T("nach \(mins) Minuten", "after \(mins) minutes"), action: #selector(schonerWaehlen(_:)), keyEquivalent: "")
            i.tag = mins; i.state = mins == einst.schoner ? .on : .off; i.target = self; scm.addItem(i)
        }
        scm.addItem(.separator())
        let jetzt = NSMenuItem(title: T("Jetzt starten", "Start now"), action: #selector(schonerStarten), keyEquivalent: ""); jetzt.target = self; scm.addItem(jetzt)
        sch.submenu = scm; m.addItem(sch)
        let bild = NSMenuItem(title: T("Standbild neu setzen", "Refresh still image"), action: #selector(standbildJetzt), keyEquivalent: ""); bild.target = self; m.addItem(bild)
        m.addItem(.separator())
        let login = NSMenuItem(title: T("Beim Anmelden starten", "Open at login"), action: #selector(anmeldungUmschalten), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off; login.target = self; m.addItem(login)
        let ueber = NSMenuItem(title: T("Über Glowgraph", "About Glowgraph"), action: #selector(ueberZeigen), keyEquivalent: ""); ueber.target = self; m.addItem(ueber)
        m.addItem(withTitle: T("Glowgraph beenden", "Quit Glowgraph"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    @objc func ueberZeigen() { NSApp.activate(ignoringOtherApps: true); NSApp.orderFrontStandardAboutPanel(nil) }
    @objc func vaultWaehlen(_ i: NSMenuItem) { if let u = i.representedObject as? URL { vaultSetzen(u) } }
    @objc func ordnerWaehlen() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.message = T("Wähle den Ordner deines Obsidian-Vaults", "Choose your Obsidian vault folder")
        p.prompt = T("Auswählen", "Choose")
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { vaultSetzen(u) }
    }
    func vaultSetzen(_ u: URL) {
        einst.vault = u; standbildSha = nil
        // neuer Vault: Darstellung frisch aufbauen (sonst leuchten alle Notizen als „neu“ auf)
        for s in schirme { s.darstellung?.ansicht.isPaused = true; s.darstellung?.ansicht.removeFromSuperview(); s.darstellung = nil; s.fenster.orderOut(nil) }
        quelle.wechseln(zu: u); symbolAktualisieren()
    }
    @objc func schonerWaehlen(_ i: NSMenuItem) { einst.schoner = i.tag }
    @objc func standbildJetzt() { standbildSha = nil; standbildMachen() }
    @objc func anmeldungUmschalten() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
        catch { Protokoll.schreiben("Anmeldestart: \(error.localizedDescription)") }
    }
}

let app = NSApplication.shared
let glowgraph = App()
app.delegate = glowgraph
app.setActivationPolicy(.accessory)   // kein Dock-Symbol, nur Menüleiste
app.run()
