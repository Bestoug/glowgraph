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
    /// Markdown-Links [Text](Ziel.md) und [Text](<Ziel mit Leerzeichen.md>), auch als Einbettung ![…](…);
    /// Klammern im Dateinamen dürfen paarweise vorkommen („Notiz%20(1).md“)
    private static let mdMuster = try! NSRegularExpression(pattern: #"\[[^\]\n]*\]\(\s*(<[^>\n]+>|(?:[^()\s]|\([^()\s]*\))+)"#)
    /// Adressen mit Schema (https:, mailto:, obsidian: …) sind keine Notizen im Vault
    private static let schemaMuster = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#)
    private static let codeMuster = try! NSRegularExpression(pattern: "```[\\s\\S]*?```")

    /// Ziel eines Markdown-Links als Pfad (ohne Anker, %-Kodierung aufgelöst); nil bei Web-Adressen, reinen Ankern und Leerem
    static func markdownZiel(_ roh: String) -> String? {
        var p = roh.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("<"), p.hasSuffix(">") { p = String(p.dropFirst().dropLast()) }
        if let anker = p.firstIndex(of: "#") { p = String(p[..<anker]) }
        p = (p.removingPercentEncoding ?? p).trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty,
              schemaMuster.firstMatch(in: p, range: NSRange(location: 0, length: (p as NSString).length)) == nil else { return nil }
        return p
    }

    /// Pfad mit „.“ und „..“ auflösen; nil, wenn er leer ist oder aus dem Vault hinausführt
    static func normalisiert(_ pfad: String) -> String? {
        var teile: [String] = []
        for t in pfad.split(separator: "/", omittingEmptySubsequences: true) {
            if t == "." { continue }
            if t == ".." { if teile.isEmpty { return nil }; teile.removeLast(); continue }
            teile.append(String(t))
        }
        return teile.isEmpty ? nil : teile.joined(separator: "/")
    }

    /// Graph wie Obsidian ihn zeigt: [[Name]], [[Ordner/Name]], [[Name|Alias]], [[Name#Abschnitt]] und Markdown-Links
    /// [Text](Name.md), relativ zur Notiz oder ab dem Vault; Links in Code-Blöcken zählen nicht.
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
        func verbinde(_ von: String, _ ziel: String?) {
            guard let ziel, ziel != von else { return }
            let paar = von < ziel ? [von, ziel] : [ziel, von]
            if gesehen.insert(paar.joined(separator: "\u{0}")).inserted { links.append(paar) }
        }
        /// Ganzer Pfad im Vault oder nur der Name (wie bisher bei [[Links]])
        func nachName(_ k: String) -> String? {
            let kurz = k.components(separatedBy: "/").last ?? k
            return (namen[k] ?? namen[kurz])?.first
        }
        func nachPfad(_ p: String) -> String? { normalisiert(p).flatMap { namen[ohneMd($0).lowercased()]?.first } }
        for d in dateien where d.groesse <= groesstePruefung {
            guard let text = try? String(contentsOf: w.appendingPathComponent(d.pfad), encoding: .utf8) else { continue }
            let ohneCode = codeMuster.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            let ns = ohneCode as NSString
            let alles = NSRange(location: 0, length: ns.length)
            for m in linkMuster.matches(in: ohneCode, range: alles) {
                let roh = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                verbinde(d.pfad, nachName(ohneMd(roh).lowercased()))
            }
            // Markdown-Links: zuerst relativ zur Notiz, dann ab dem Vault, zuletzt nur nach dem Namen
            let ordner = (d.pfad as NSString).deletingLastPathComponent
            for m in mdMuster.matches(in: ohneCode, range: alles) {
                guard let p = markdownZiel(ns.substring(with: m.range(at: 1))) else { continue }
                let relativ = p.hasPrefix("/") ? nil : nachPfad(ordner.isEmpty ? p : ordner + "/" + p)
                verbinde(d.pfad, relativ ?? nachPfad(p) ?? nachName(ohneMd(p).lowercased()))
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
