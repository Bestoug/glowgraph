import Foundation
// Prüft das Lesen eines Vaults an einem erfundenen Beispiel-Vault im temporären Ordner. Ausgabe: VAULT: OK oder VAULT: FEHLER …
let wurzel = FileManager.default.temporaryDirectory.appendingPathComponent("glowgraph-probe-\(UUID().uuidString)")
func schreib(_ pfad: String, _ text: String) {
    let u = wurzel.appendingPathComponent(pfad)
    try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: u, atomically: true, encoding: .utf8)
}
schreib("Start.md", "Willkommen. Siehe [[Garten]] und [[Projekte/Teich|den Teich]] und [[Rezepte#Brot]].")
schreib("Projekte/Garten.md", "Beete, siehe [[Start]]. Doppelt: [[Start]].")
schreib("Projekte/Teich.md", "Fische")
schreib("Kochen/Rezepte.md", "```\n[[Garten]] im Code zählt nicht\n[Teich](../Projekte/Teich.md) auch nicht\n```\nNichts sonst.")
schreib("Kochen/Allein.md", "keine Links, [[Gibt es nicht]], [fehlt](Nirgends.md)")
// Markdown-Links: relativ, ab dem Vault, mit Anker, %20, <…>, Klammern im Namen; Web-Adressen, Anker und Bilder zählen nicht
schreib("Markdown/Quelle.md", "[Teich](../Projekte/Teich.md), [Garten](Projekte/Garten.md), [Brot](Rezepte.md#Brot), [Idee](Neue%20Idee.md), [Idee](<Neue Idee.md>), [Kopie](Notiz%20(1).md), [Web](https://example.com/Start.md), [Mail](mailto:hallo), [Oben](#Oben), ![Bild](foto.png)")
schreib("Markdown/Neue Idee.md", "Entwurf")
schreib("Markdown/Notiz (1).md", "Kopie")
schreib(".obsidian/workspace.md", "[[Start]] versteckt")
schreib(".trash/Alt.md", "[[Start]] im Papierkorb")
schreib("Bilder/foto.png", "kein Markdown")

var fehler: [String] = []
func pruefe(_ ok: Bool, _ was: String) { if !ok { fehler.append(was) } }
guard let liste = VaultLeser.dateien(wurzel) else { print("VAULT: FEHLER Ordner nicht lesbar"); exit(1) }
pruefe(liste.map(\.pfad) == ["Kochen/Allein.md", "Kochen/Rezepte.md", "Markdown/Neue Idee.md", "Markdown/Notiz (1).md", "Markdown/Quelle.md", "Projekte/Garten.md", "Projekte/Teich.md", "Start.md"], "Dateiliste \(liste.map(\.pfad))")
let g = VaultLeser.graph(wurzel, liste)
let paare = Set(g.links.map { $0.joined(separator: " – ") })
pruefe(paare == ["Projekte/Garten.md – Start.md", "Projekte/Teich.md – Start.md", "Kochen/Rezepte.md – Start.md",
                 "Markdown/Quelle.md – Projekte/Teich.md", "Markdown/Quelle.md – Projekte/Garten.md", "Kochen/Rezepte.md – Markdown/Quelle.md",
                 "Markdown/Neue Idee.md – Markdown/Quelle.md", "Markdown/Notiz (1).md – Markdown/Quelle.md"], "Links \(paare.sorted())")
pruefe(VaultLeser.normalisiert("a/../../b") == nil && VaultLeser.normalisiert("a/./b/../c.md") == "a/c.md", "Pfade normalisieren")
pruefe(VaultLeser.markdownZiel("https://example.com") == nil && VaultLeser.markdownZiel("<Neue Idee.md>") == "Neue Idee.md", "Markdown-Ziel")
pruefe(g.nodes.first { $0.id == "Start.md" }?.g == GraphDaten.wurzel, "oberster Ordner für Start.md")
pruefe(g.nodes.first { $0.id == "Projekte/Teich.md" }?.g == "Projekte", "Ordner für Teich")
pruefe(g.nodes.first { $0.id == "Projekte/Teich.md" }?.t == "Teich", "Titel für Teich")
let s1 = VaultLeser.stand(liste)
Thread.sleep(forTimeInterval: 1.1)
schreib("Neu.md", "[[Start]]")
let s2 = VaultLeser.stand(VaultLeser.dateien(wurzel)!)
pruefe(s1 != s2, "Stand ändert sich bei neuer Notiz")
pruefe(VaultLeser.dateien(wurzel.appendingPathComponent("gibt-es-nicht")) == nil, "fehlender Ordner → nil")
let (szene, _) = Auslegen.szene(g, groessen: Dictionary(uniqueKeysWithValues: liste.map { ($0.pfad, $0.groesse) }))
pruefe(szene.punkte.count == 8 && szene.links.count == 8, "Szene \(szene.punkte.count)/\(szene.links.count)")
try? FileManager.default.removeItem(at: wurzel)
print(fehler.isEmpty ? "VAULT: OK" : "VAULT: FEHLER " + fehler.joined(separator: "; "))
exit(fehler.isEmpty ? 0 : 1)
