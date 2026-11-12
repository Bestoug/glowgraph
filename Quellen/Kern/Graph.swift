import Foundation
import simd

/// Knoten mit Pfad, Titel und oberstem Ordner (`g`, „/“ = Notiz liegt direkt im Vault); ungerichtete Links.
struct GraphDaten: Codable, Equatable {
    struct Knoten: Codable, Equatable { let id: String; let t: String; let g: String }
    let sha: String?
    let nodes: [Knoten]
    let links: [[String]]
    static let wurzel = "/"
}

/// Ausgelegter Graph: feste Lage je Notiz (gleiche Notiz → gleiche Lage), Maßstab so, dass 90 % im Radius 300 liegen.
struct Szene {
    struct Punkt { var id: String; var p: SIMD3<Float>; var g: String; var ph: Float; var inhalt: Float }   // inhalt: 0 kurz … 1 lang
    var punkte: [Punkt]
    var links: [(Int, Int)]
    /// Faktor von Original-Einheiten (wie in der Graph-Seite) auf Szenen-Einheiten
    var massstab: Float
}

/// Stabiler Zufall (FNV-1a + Xorshift), damit dieselbe Notiz immer gleich aussieht.
struct Zufall {
    private var h: UInt32
    init(_ text: String) {
        var h: UInt32 = 2166136261
        for c in text.utf16 { h ^= UInt32(c); h = h &* 16777619 }
        self.h = h == 0 ? 1 : h
    }
    mutating func next() -> Double {
        h ^= h << 13; h ^= h >> 17; h ^= h << 5
        return Double(h % 1000003) / 1000003
    }
}

enum Auslegen {
    /// Kraft-Auslegung (Abstoßung, Federn, Zug zur Mitte). `alt`: gemerkte Lagen.
    static func szene(_ d: GraphDaten, alt: [String: SIMD3<Float>] = [:], groessen: [String: Int] = [:]) -> (Szene, [String: SIMD3<Float>]) {
        let ids = d.nodes.map(\.id)
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let gruppen = d.nodes.map(\.g)
        var paare: [(Int, Int)] = []
        var gesehen = Set<String>()
        for l in d.links where l.count == 2 {
            guard let a = index[l[0]], let b = index[l[1]], a != b else { continue }
            let k = a < b ? "\(a)-\(b)" : "\(b)-\(a)"
            if gesehen.insert(k).inserted { paare.append((a, b)) }
        }
        let N = ids.count
        var nb = Array(repeating: [Int](), count: N)
        for (a, b) in paare { nb[a].append(b); nb[b].append(a) }
        var x = Array(repeating: SIMD3<Double>(0, 0, 0), count: N)
        var v = x
        // Startlage je Ordner: größte Ordner zuerst, Notizen im obersten Ordner (Gruppe „/“) in der Mitte
        var zahl: [String: Int] = [:]; for g in gruppen { zahl[g, default: 0] += 1 }
        let reihen = [GraphDaten.wurzel] + zahl.keys.filter { $0 != GraphDaten.wurzel }.sorted { (zahl[$0]!, $1) > (zahl[$1]!, $0) }
        let bekannt = ids.filter { alt[$0] != nil }.count
        var beweglich = Set<Int>()
        func startLage(_ i: Int, _ platziert: Set<Int>) {
            var z = Zufall(ids[i])
            let nah = nb[i].filter { platziert.contains($0) }
            if !nah.isEmpty {
                let m = nah.reduce(SIMD3<Double>(0, 0, 0)) { $0 + x[$1] } / Double(nah.count)
                x[i] = m + SIMD3((z.next() - 0.5) * 30, (z.next() - 0.5) * 30, (z.next() - 0.5) * 30)
                return
            }
            let gi = Double(max(0, reihen.firstIndex(of: gruppen[i]) ?? 0))
            let phi = acos(1 - 2 * (gi + 0.5) / Double(reihen.count)), th = Double.pi * (1 + sqrt(5)) * gi
            let R = gruppen[i] == GraphDaten.wurzel ? 0.0 : 120.0
            x[i] = SIMD3(R * sin(phi) * cos(th) + (z.next() - 0.5) * 50, R * cos(phi) + (z.next() - 0.5) * 50,
                         R * sin(phi) * sin(th) + (z.next() - 0.5) * 50)
        }
        func schritt(_ alpha: Double) {
            for i in 0..<N { for j in (i + 1)..<max(i + 1, N) {
                var dd = x[i] - x[j]; let d2 = simd_length_squared(dd) + 0.01
                if d2 > 250000 { continue }
                dd *= alpha * 250 / d2; v[i] += dd; v[j] -= dd
            } }
            for (a, b) in paare {
                var dd = x[b] - x[a]; let d = simd_length(dd) + 0.01
                let soll = gruppen[a] == gruppen[b] ? 36.0 : 58.0
                dd *= alpha * (d - soll) / d * 0.5
                v[a] += dd / Double(nb[a].count); v[b] -= dd / Double(nb[b].count)
            }
            for i in 0..<N {
                if !beweglich.isEmpty && !beweglich.contains(i) { v[i] = .zero; continue }
                v[i] -= x[i] * alpha * (nb[i].isEmpty ? 0.06 : 0.005)
                let l = simd_length(v[i]); if l > 12 { v[i] *= 12 / l }
                x[i] += v[i]; v[i] *= 0.6
            }
        }
        if Double(bekannt) >= Double(N) * 0.5 {
            var platziert = Set<Int>()
            for i in 0..<N where !nb[i].isEmpty { if let p = alt[ids[i]] { x[i] = SIMD3(Double(p.x), Double(p.y), Double(p.z)); platziert.insert(i) } }
            let frisch = (0..<N).filter { !platziert.contains($0) }
            for i in frisch { startLage(i, platziert); platziert.insert(i) }
            if !frisch.isEmpty { beweglich = Set(frisch); for k in 0..<160 { schritt(0.6 * (1 - Double(k) / 200)) } }
        } else if N > 0 {
            for i in 0..<N { startLage(i, []) }
            for k in 0..<340 { schritt(1 - Double(k) / 380) }
            let m = x.reduce(.zero, +) / Double(N)
            for i in 0..<N { x[i] -= m }
        }
        // Maßstab und Mitte nur aus verbundenen Notizen (die Skulptur), 90 % liegen im Radius 300
        let verbunden = (0..<N).filter { !nb[$0].isEmpty }
        let basis = verbunden.isEmpty ? Array(0..<N) : verbunden
        let mitte = basis.isEmpty ? .zero : basis.reduce(SIMD3<Double>.zero) { $0 + x[$1] } / Double(basis.count)
        let radien = basis.map { simd_length(x[$0] - mitte) }.sorted()
        let r90 = radien.isEmpty ? 100 : max(1, radien[min(radien.count - 1, Int(Double(radien.count) * 0.9))])
        let s = Float(235 / r90)   // mit 300 ragte die Skulptur fast an den oberen Rand (73 % der Höhe), mit 235 sind es etwa 58 %
        // Notizen ohne Verbindung: lockerer Kranz rund um die Skulptur (Richtung und Abstand fest je Notiz, gleichmäßig verteilt)
        for i in 0..<N where nb[i].isEmpty && !verbunden.isEmpty {
            var z = Zufall(ids[i] + "#kranz")
            let u = z.next() * 2 - 1, t = z.next() * 2 * Double.pi, r = (1 - u * u).squareRoot()
            let abstand = r90 * (1.08 + 0.3 * z.next())
            x[i] = mitte + SIMD3(r * cos(t), u * 0.75, r * sin(t)) * abstand   // etwas flacher, damit nichts oben/unten aus dem Bild ragt
        }
        // gemerkt werden nur verbundene Notizen – bekommt eine lose Notiz einen Link, findet sie neu ihren Platz im Netz
        var lage: [String: SIMD3<Float>] = [:]
        for i in verbunden { lage[ids[i]] = SIMD3<Float>(Float(x[i].x), Float(x[i].y), Float(x[i].z)) }
        let m3 = SIMD3<Float>(Float(mitte.x), Float(mitte.y), Float(mitte.z))
        // Inhaltsmenge: Dateigröße logarithmisch zwischen 10. und 95. Perzentil auf 0…1 (eine Riesennotiz überstrahlt nicht)
        let logs = ids.compactMap { groessen[$0] }.filter { $0 > 0 }.map { log(Double($0)) }.sorted()
        func pz(_ q: Double) -> Double { logs.isEmpty ? 0 : logs[min(logs.count - 1, Int(q * Double(logs.count - 1)))] }
        let lo = pz(0.10), hi = max(pz(0.95), lo + 0.1)
        var punkte: [Szene.Punkt] = []
        for i in 0..<N {
            var z = Zufall(ids[i] + "#ph")
            let inhalt = groessen[ids[i]].map { Float(min(1, max(0, (log(Double(max(1, $0))) - lo) / (hi - lo)))) } ?? 0.5
            punkte.append(.init(id: ids[i], p: (SIMD3<Float>(Float(x[i].x), Float(x[i].y), Float(x[i].z)) - m3) * s, g: gruppen[i], ph: Float(z.next() * 6.28), inhalt: inhalt))
        }
        return (Szene(punkte: punkte, links: paare, massstab: s), lage)
    }
}
