import Foundation
import simd

/// Hält den Graphen des gewählten Vaults aktuell: alle 15 s ein günstiger Blick auf Dateinamen, Größen und Änderungszeiten,
/// nur bei einer Änderung werden die Notizen neu nach Links durchsucht (im Hintergrund). Kein Netz.
final class Quelle {
    static let ordner: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Glowgraph")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private(set) var vault: URL?
    private(set) var daten: GraphDaten?
    private(set) var szene: Szene?
    /// Vault fehlt oder ist nicht lesbar
    private(set) var problem = false
    var beiNeu: ((GraphDaten, Szene) -> Void)?
    var beiZustand: (() -> Void)?
    private var takt: Timer?
    private var laeuft = false
    private let arbeit = DispatchQueue(label: "glowgraph.vault", qos: .utility)

    init(vault: URL?) { self.vault = vault }

    /// Lage der Notizen je Vault merken (gleicher Vault → gleiche Skulptur nach einem Neustart)
    private var lageDatei: URL? {
        guard let v = vault else { return nil }
        var z = Zufall(v.path); let k = String(Int(z.next() * 1e9))
        return Quelle.ordner.appendingPathComponent("lage-\(k).json")
    }

    func starten() {
        pruefen()
        takt = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.pruefen() }
        takt?.tolerance = 3
    }

    func wechseln(zu v: URL) {
        vault = v; daten = nil; szene = nil; problem = false
        Protokoll.schreiben("Vault gewählt (\(v.lastPathComponent))")
        pruefen()
    }

    func pruefen() {
        guard let v = vault, !laeuft else { return }
        laeuft = true
        let alterStand = daten?.sha
        let lage = lageDatei
        arbeit.async { [weak self] in
            let liste = VaultLeser.dateien(v)
            var neu: (GraphDaten, Szene)?
            if let liste, VaultLeser.stand(liste) != alterStand {
                let g = VaultLeser.graph(v, liste)
                var alt: [String: SIMD3<Float>] = [:]
                if let lage, let d = try? Data(contentsOf: lage), let o = try? JSONDecoder().decode([String: [Float]].self, from: d) {
                    for (k, w) in o where w.count == 3 { alt[k] = SIMD3(w[0], w[1], w[2]) }
                }
                let groessen = Dictionary(uniqueKeysWithValues: liste.map { ($0.pfad, $0.groesse) })
                let (s, l) = Auslegen.szene(g, alt: alt, groessen: groessen)
                neu = (g, s)
                if let lage { try? JSONEncoder().encode(l.mapValues { [$0.x, $0.y, $0.z] }).write(to: lage, options: .atomic) }
            }
            let ergebnis = neu
            DispatchQueue.main.async {
                guard let self else { return }
                self.laeuft = false
                guard self.vault == v else { self.pruefen(); return }   // inzwischen anderer Vault gewählt
                let warProblem = self.problem
                self.problem = liste == nil
                if self.problem != warProblem {
                    Protokoll.schreiben(self.problem ? "Vault nicht lesbar" : "Vault wieder lesbar"); self.beiZustand?()
                }
                guard let e = ergebnis else { return }; let (g, s) = e
                Protokoll.schreiben("Neuer Stand \(g.sha ?? "?"): \(g.nodes.count) Notizen, \(g.links.count) Verbindungen")
                self.daten = g; self.szene = s
                self.beiNeu?(g, s); self.beiZustand?()
            }
        }
    }
}

/// Kleines Protokoll für die Fehlersuche (rollt bei 200 KB), nur Zeitpunkte und Zahlen, keine Notiznamen.
/// Liegt in ~/Library/Application Support/Glowgraph/protokoll.txt
enum Protokoll {
    static let datei = Quelle.ordner.appendingPathComponent("protokoll.txt")
    static func schreiben(_ s: String) {
        let zeile = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let a = try? FileManager.default.attributesOfItem(atPath: datei.path), (a[.size] as? Int ?? 0) > 200_000 {
            let alt = datei.deletingLastPathComponent().appendingPathComponent("protokoll-alt.txt")
            try? FileManager.default.removeItem(at: alt); try? FileManager.default.moveItem(at: datei, to: alt)
        }
        if let h = try? FileHandle(forWritingTo: datei) { h.seekToEndOfFile(); h.write(Data(zeile.utf8)); try? h.close() }
        else { try? zeile.write(to: datei, atomically: true, encoding: .utf8) }
    }
}
