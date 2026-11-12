import Foundation

/// Liest einen Obsidian-Vault direkt von der Platte: Notizen (.md), oberster Ordner, [[Links]] dazwischen.
/// Nur lesen, nichts schreiben, kein Netz. Notizinhalte werden nur nach Links durchsucht und nicht gespeichert.
enum VaultLeser {
    struct Datei: Equatable { let pfad: String; let groesse: Int; let geaendert: Double }

    /// Höchstens so viele Notizen (sehr große Vaults bleiben flüssig)
    static let hoechstens = 20_000
    /// Größere Dateien werden nicht nach Links durchsucht (z. B. eingefügte Exporte)
    static let groesstePruefung = 2_000_000

    /// Alle Notizen im Vault, ohne versteckte Ordner (.obsidian, .trash, .git …). nil = Ordner nicht lesbar.
    static func dateien(_ wurzel: URL) -> [Datei]? {
        let w = wurzel.standardizedFileURL.resolvingSymlinksInPath()
        var istOrdner: ObjCBool = false
        guard FileManager.default.fileExists(atPath: w.path, isDirectory: &istOrdner), istOrdner.boolValue,
              FileManager.default.isReadableFile(atPath: w.path) else { return nil }
        let schluessel: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: w, includingPropertiesForKeys: schluessel,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let basis = w.path.hasSuffix("/") ? w.path : w.path + "/"
        var aus: [Datei] = []
        for case let u as URL in e {
            guard u.pathExtension.lowercased() == "md",
                  let r = try? u.resourceValues(forKeys: Set(schluessel)), r.isRegularFile == true else { continue }
            let voll = u.standardizedFileURL.resolvingSymlinksInPath().path
            guard voll.hasPrefix(basis) else { continue }   // Verknüpfungen nach außerhalb zählen nicht
            aus.append(Datei(pfad: String(voll.dropFirst(basis.count)), groesse: r.fileSize ?? 0,
                             geaendert: r.contentModificationDate?.timeIntervalSince1970 ?? 0))
            if aus.count >= hoechstens { break }
        }
        return aus.sorted { $0.pfad < $1.pfad }
    }

    /// Kurzer Fingerabdruck des Stands (Pfade, Größen, Änderungszeiten): ändert sich, sobald eine Notiz dazukommt oder sich ändert
    static func stand(_ d: [Datei]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for x in d { for b in "\(x.pfad)|\(x.groesse)|\(Int(x.geaendert))\n".utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 } }
        return String(format: "%012llx", h & 0xffffffffffff)
    }

    private static let linkMuster = try! NSRegularExpression(pattern: #"\[\[([^\]\|#\^\n]+)"#)
    private static let codeMuster = try! NSRegularExpression(pattern: "```[\\s\\S]*?```")

    /// Graph wie Obsidian ihn zeigt: [[Name]], [[Ordner/Name]], [[Name|Alias]], [[Name#Abschnitt]]; Links in Code-Blöcken zählen nicht.
    static func graph(_ wurzel: URL, _ dateien: [Datei]) -> GraphDaten {
        let w = wurzel.standardizedFileURL.resolvingSymlinksInPath()
        func ohneMd(_ s: String) -> String { s.lowercased().hasSuffix(".md") ? String(s.dropLast(3)) : s }
        var namen: [String: [String]] = [:]
        for d in dateien {
            let pfad = d.pfad
            namen[ohneMd((pfad as NSString).lastPathComponent).lowercased(), default: []].append(pfad)
            namen[ohneMd(pfad).lowercased(), default: []].append(pfad)
        }
        var gesehen = Set<String>()
        var links: [[String]] = []
        for d in dateien where d.groesse <= groesstePruefung {
            guard let text = try? String(contentsOf: w.appendingPathComponent(d.pfad), encoding: .utf8) else { continue }
            let ohneCode = codeMuster.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            let ns = ohneCode as NSString
            for m in linkMuster.matches(in: ohneCode, range: NSRange(location: 0, length: ns.length)) {
                let roh = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let k = ohneMd(roh).lowercased()
                let kurz = k.components(separatedBy: "/").last ?? k
                guard let ziel = (namen[k] ?? namen[kurz])?.first, ziel != d.pfad else { continue }
                let paar = d.pfad < ziel ? [d.pfad, ziel] : [ziel, d.pfad]
                if gesehen.insert(paar.joined(separator: "\u{0}")).inserted { links.append(paar) }
            }
        }
        let knoten = dateien.map { d -> GraphDaten.Knoten in
            let teile = d.pfad.components(separatedBy: "/")
            return .init(id: d.pfad, t: ohneMd(teile.last ?? d.pfad), g: teile.count > 1 ? teile[0] : GraphDaten.wurzel)
        }
        return GraphDaten(sha: stand(dateien), nodes: knoten, links: links.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) })
    }

    /// Vaults, die Obsidian selbst kennt (aus seiner Einstellungsdatei), der zuletzt geöffnete zuerst
    static func bekannteVaults() -> [URL] {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let d = try? Data(contentsOf: u), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let v = j["vaults"] as? [String: [String: Any]] else { return [] }
        return v.values
            .compactMap { e -> (URL, Bool, Double)? in
                guard let p = e["path"] as? String else { return nil }
                return (URL(fileURLWithPath: p), e["open"] as? Bool ?? false, (e["ts"] as? NSNumber)?.doubleValue ?? 0)
            }
            .sorted { ($0.1 ? 1 : 0, $0.2) > ($1.1 ? 1 : 0, $1.2) }
            .map(\.0)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
