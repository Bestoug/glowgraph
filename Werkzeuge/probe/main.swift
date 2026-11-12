import AppKit
// Prüflauf im Bau: übersetzt die Metal-Shader, legt einen erfundenen Graphen aus und rendert ein Standbild
// (probe.png), damit das Bild vor dem Mac geprüft werden kann. Keine echten Notizen.
if MTLCreateSystemDefaultDevice() == nil { print("SHADER: kein Metal-Gerät auf dem Bau-Rechner, nicht geprüft"); exit(0) }
guard let m = LaterneMetal(rahmen: NSRect(x: 0, y: 0, width: 64, height: 64)) else { print("SHADER: FEHLER"); exit(1) }
print("SHADER: OK")
var z = Zufall("probe")
let gruppen = [GraphDaten.wurzel, "Projekte", "Ideen", "Journal", "Lesen", "Archiv", "Vorlagen"]
let knoten = (0..<230).map { i in GraphDaten.Knoten(id: "n\(i).md", t: "Notiz \(i)", g: gruppen[i % gruppen.count]) }
    + (0..<12).map { i in GraphDaten.Knoten(id: "lose\(i).md", t: "Lose \(i)", g: "Journal") }   // Notizen ohne Verbindung (Kranz)
var links: [[String]] = []
for i in 1..<230 { links.append(["n\(i).md", "n\(Int(z.next() * Double(i))).md"]); if z.next() < 0.7 { links.append(["n\(i).md", "n\(Int(z.next() * 230)).md"]) } }
let t0 = Date()
var zg = Zufall("groessen")
let groessen = Dictionary(uniqueKeysWithValues: knoten.map { ($0.id, Int(300 * pow(200.0, zg.next()))) })
let (szene, _) = Auslegen.szene(GraphDaten(sha: "probe", nodes: knoten, links: links), groessen: groessen)
print("Auslegen 230 Knoten: \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
m.setze(szene)
_ = m.standbild(breite: 1512, hoehe: 982, dpr: 1)   // erstes Bild wärmt auf
let t1 = Date()
if let b = m.standbild(breite: 3024, hoehe: 1964, dpr: 2), let png = NSBitmapImageRep(cgImage: b).representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "probe.png"))
    print("Standbild 3024x1964: \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
} else { print("Standbild: FEHLER") }
// Neue Notizen (eine davon in neuem Ordner) → sanftes Aufleuchten nach 1,5 s am stärksten
var mehr = knoten; mehr += [GraphDaten.Knoten(id: "neu1.md", t: "Neu 1", g: "Ideen"), GraphDaten.Knoten(id: "neu2.md", t: "Neu 2", g: "Neuer Ordner")]
var mehrLinks = links; mehrLinks += [["neu1.md", "n5.md"], ["neu2.md", "n9.md"]]
let (sz2, _) = Auslegen.szene(GraphDaten(sha: "probe2", nodes: mehr, links: mehrLinks))
m.setze(sz2)
Thread.sleep(forTimeInterval: 1.6)
if let b = m.standbild(breite: 3024, hoehe: 1964, dpr: 2), let png = NSBitmapImageRep(cgImage: b).representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "probe-neu.png")); print("Standbild mit neuen Notizen: OK")
}
