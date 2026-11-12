import AppKit
// Rendert eine kurze Bilderfolge aus einem erfundenen Graphen (für die Vorschau-Animation in der Anleitung).
// Aufruf: film <ordner> [sekunden] [bilder-je-sekunde]. Nach einem Drittel kommen zwei neue Notizen dazu (Aufleuchten).
let aus = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "film")
let sekunden = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 8 : 8
let fps = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 12 : 12
try? FileManager.default.createDirectory(at: aus, withIntermediateDirectories: true)
guard let m = LaterneMetal(rahmen: NSRect(x: 0, y: 0, width: 64, height: 64)) else { print("FILM: kein Metal"); exit(1) }
var z = Zufall("film")
let gruppen = [GraphDaten.wurzel, "Projekte", "Ideen", "Journal", "Lesen", "Archiv", "Vorlagen"]
var knoten = (0..<190).map { i in GraphDaten.Knoten(id: "n\(i).md", t: "Notiz \(i)", g: gruppen[i % gruppen.count]) }
    + (0..<10).map { i in GraphDaten.Knoten(id: "lose\(i).md", t: "Lose \(i)", g: "Journal") }
var links: [[String]] = []
for i in 1..<190 { links.append(["n\(i).md", "n\(Int(z.next() * Double(i))).md"]); if z.next() < 0.6 { links.append(["n\(i).md", "n\(Int(z.next() * 190)).md"]) } }
var zg = Zufall("groessen")
var groessen = Dictionary(uniqueKeysWithValues: knoten.map { ($0.id, Int(300 * pow(200.0, zg.next()))) })
m.setze(Auslegen.szene(GraphDaten(sha: "a", nodes: knoten, links: links), groessen: groessen).0)
_ = m.standbild(breite: 640, hoehe: 400, dpr: 1)
let n = Int(sekunden * fps)
let start = Date()
var neu = false
for i in 0..<n {
    let soll = start.addingTimeInterval(Double(i) / fps)
    if soll > Date() { Thread.sleep(until: soll) }
    if !neu && Double(i) >= Double(n) / 3 {
        neu = true
        knoten += [GraphDaten.Knoten(id: "neu1.md", t: "Neu 1", g: "Ideen"), GraphDaten.Knoten(id: "neu2.md", t: "Neu 2", g: "Projekte")]
        links += [["neu1.md", "n12.md"], ["neu2.md", "n40.md"]]
        groessen["neu1.md"] = 9000; groessen["neu2.md"] = 4000
        m.setze(Auslegen.szene(GraphDaten(sha: "b", nodes: knoten, links: links), groessen: groessen).0)
    }
    if let b = m.standbild(breite: 960, hoehe: 600, dpr: 1), let png = NSBitmapImageRep(cgImage: b).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
        try? png.write(to: aus.appendingPathComponent(String(format: "bild-%03d.jpg", i)))
    }
}
print("FILM: \(n) Bilder in \(Int(Date().timeIntervalSince(start))) s")
