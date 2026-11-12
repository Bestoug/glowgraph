import AppKit
import Metal
import MetalKit
import QuartzCore
import simd

/// Gleiche Anordnung wie `struct Bild` im Shader.
struct BildDaten {
    var groesse = SIMD2<Float>(), dpr: Float = 2, mitteY: Float = 0.46
    var f0 = SIMD4<Float>(), f1 = SIMD4<Float>(), f2 = SIMD4<Float>()
    var c0 = SIMD4<Float>(), c1 = SIMD4<Float>(), c2 = SIMD4<Float>()
    var r0 = SIMD4<Float>(), r1 = SIMD4<Float>(), r2 = SIMD4<Float>()
    var zeitKurz: Float = 0, einblend: Float = 0, frei = SIMD2<Float>()
}
struct SpriteI { var a: SIMD4<Float>; var b: SIMD4<Float> }
struct LinieI { var ab: SIMD4<Float>; var p: SIMD4<Float>; var farbe: SIMD4<Float> }
struct FormI { var a: SIMD4<Float>; var b: SIMD4<Float>; var c: SIMD4<Float> }

/// Laterne nativ: 30 Bilder/s, ruhige Drehung (eine Runde in ca. 3,5 Min.), Ströme und Kaskaden wie in der Graph-Seite.
/// Die CPU projiziert nur die gut 200 Notizen je Bild; Verläufe, Rauch, Linien und Licht rechnet die Grafikkarte.
final class LaterneMetal: NSObject, MTKViewDelegate {
    static let bilderJeSekunde = 30
    let ansicht: MTKView
    private let geraet: MTLDevice, schlange: MTLCommandQueue
    private var grundP, grundKopieP, spriteP, linieP, formP, abschlussP: MTLRenderPipelineState!
    private let probe: MTLSamplerState
    private var rauch: [MTLTexture] = []
    private let start = CACurrentMediaTime()
    private var letzt = CACurrentMediaTime()
    /// Zeit in ms wie in der Seite (Date.now() % 1e9), läuft mit der Uhr → kein Springen nach Pause oder Neustart
    private var zeit: Double { (Date().timeIntervalSince1970 * 1000).truncatingRemainder(dividingBy: 1e9) }

    // Stil „laterne“
    /// Farbe je oberstem Ordner: Notizen direkt im Vault warmweiß, sonst fest aus einer ruhigen Palette (gleicher Ordner → gleiche Farbe)
    static let palette: [SIMD3<Float>] = [[255, 170, 70], [110, 230, 205], [240, 214, 170], [130, 160, 200], [190, 128, 74], [214, 160, 190], [150, 200, 120], [120, 96, 72]]
    static func farbe(_ gruppe: String) -> SIMD3<Float> {
        if gruppe == GraphDaten.wurzel { return [255, 236, 200] }
        var z = Zufall(gruppe); return palette[Int(z.next() * Double(palette.count)) % palette.count]
    }
    static let andere: SIMD3<Float> = [150, 144, 135]
    static let funke: SIMD3<Float> = [110, 230, 205], weiss: SIMD3<Float> = [220, 255, 245], messing: SIMD3<Float> = [190, 128, 74]
    static let flecken: [(SIMD3<Float>, Float)] = [([150, 86, 32], 0.26), ([110, 46, 24], 0.18), ([24, 70, 70], 0.16)]

    // Zustand
    private struct Knoten { var id: String; var b: SIMD3<Double>; var r: Double; var ph: Double; var farbe: SIMD3<Float>; var form: Float
        var nb: [Int] = []; var feuer: Double = 0; var p = SIMD4<Double>()
        var neuAb: Double = -1; var neuGross: Double = 0; var gruppe = ""; var inhalt: Double = 0.5 }   // sanftes Aufleuchten neuer Notizen (Zeitpunkt in s, Stärke)   // p: x, y, s, z (Projektion)
    private struct Kante { var a: Int; var b: Int; var seite: Float; var feuer: Double = 0 }
    private struct Puls { var von: Int; var nach: Int; var l: Int; var t: Double; var v: Double; var hell: Double }
    private struct Kaskade { var front: [Int]; var besucht: Set<Int>; var tiefe: Int; var warte: Double }
    private var knoten: [Knoten] = [], kanten: [Kante] = [], kanteVon: [Int: Int] = [:]
    private var pulse: [Puls] = [], kaskaden: [Kaskade] = [], verzoegert: [(Double, Int, Double)] = []
    private var radius: Double = 300, massstab: Double = 1, naechsteKaskade: Double = 2500
    private var sterne: [(SIMD3<Double>, Float, Float, Float)] = []
    private var zufall = SystemRandomNumberGenerator()
    // Puffer für die Instanzen, dreifach (die GPU darf noch am vorigen Bild lesen)
    private let imFlug = DispatchSemaphore(value: 3)
    private var puffer: [[MTLBuffer?]] = Array(repeating: [nil, nil, nil, nil], count: 3)
    private var bildNr = 0
    // Grund (Verlauf, Lichtflecken, Rauch) bewegt sich in Minuten kaum: halbe Auflösung, nur zweimal je Sekunde neu
    private var grundTex: [MTLTexture] = []
    private var grundZeit: CFTimeInterval = -1, grundAktiv = 0
    var beiBild: ((CFTimeInterval) -> Void)?
    var gpuDauer: ((Double) -> Void)?

    init?(rahmen: NSRect) {
        guard let g = MTLCreateSystemDefaultDevice(), let q = g.makeCommandQueue() else { return nil }
        geraet = g; schlange = q
        ansicht = MTKView(frame: rahmen, device: g)
        ansicht.colorPixelFormat = .bgra8Unorm
        ansicht.framebufferOnly = false               // Abschluss liest das Bild (Körnung „überlagern“)
        ansicht.preferredFramesPerSecond = Self.bilderJeSekunde
        ansicht.clearColor = MTLClearColorMake(0, 0, 0, 1)
        let sd = MTLSamplerDescriptor(); sd.minFilter = .linear; sd.magFilter = .linear; sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        probe = g.makeSamplerState(descriptor: sd)!
        super.init()
        do { try pipelines() } catch { NSLog("Laterne-Shader: \(error)"); return nil }
        rauch = (0..<3).compactMap { Self.rauchBild($0, g) }
        ansicht.delegate = self
    }

    private func pipelines() throws {
        let lib = try geraet.makeLibrary(source: laterneShaderQuelle, options: nil)
        func p(_ v: String, _ f: String, mischen: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v); d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            if mischen { let c = d.colorAttachments[0]!; c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha }
            return try geraet.makeRenderPipelineState(descriptor: d)
        }
        grundP = try p("vollV", "grundF", mischen: false)
        grundKopieP = try p("vollV", "grundKopieF", mischen: false)
        spriteP = try p("spriteV", "spriteF", mischen: true)
        linieP = try p("linieV", "linieF", mischen: true)
        formP = try p("formV", "formF", mischen: true)
        abschlussP = try p("vollV", "abschlussF", mischen: false)
    }

    /// Rauchschwaden wie in der Seite: 70 weiche Kreise auf 512×512, einmal vorberechnet
    private static func rauchBild(_ i: Int, _ g: MTLDevice) -> MTLTexture? {
        let n = 512
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var z = Zufall("rauch-\(i)")
        let farben = [CGColor(red: 1, green: 220 / 255, blue: 180 / 255, alpha: 0.10), CGColor(red: 1, green: 220 / 255, blue: 180 / 255, alpha: 0)] as CFArray
        let verlauf = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: farben, locations: [0, 1])!
        for _ in 0..<70 {
            let x = 256 + (z.next() - 0.5) * 330, y = 256 + (z.next() - 0.5) * 160, r = 40 + z.next() * 90
            ctx.drawRadialGradient(verlauf, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
        }
        guard let daten = ctx.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: n, height: n, mipmapped: false)
        d.usage = .shaderRead
        let t = g.makeTexture(descriptor: d)
        t?.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: daten, bytesPerRow: n * 4)
        return t
    }

    // MARK: Daten
    func setze(_ s: Szene) {
        let alt = Dictionary(knoten.map { ($0.id, ($0.feuer, $0.neuAb, $0.neuGross)) }, uniquingKeysWith: { a, _ in a })
        let warSchon = !knoten.isEmpty
        let alteGruppen = Set(knoten.map(\.gruppe))
        let jetztS = CACurrentMediaTime() - start
        var neuZaehler = 0
        massstab = Double(s.massstab); radius = 300
        var nbZahl = Array(repeating: 0, count: s.punkte.count)
        for (a, b) in s.links { nbZahl[a] += 1; nbZahl[b] += 1 }
        knoten = s.punkte.enumerated().map { i, p in
            let rOrig = 2.0 + 2.2 * Double(p.inhalt)   // Größe nach Inhalt, nicht nach Verbindungen
            var k = Knoten(id: p.id, b: SIMD3(Double(p.p.x), Double(p.p.y), Double(p.p.z)), r: rOrig * massstab, ph: Double(p.ph),
                           farbe: Self.farbe(p.g) / 255, form: 0)
            k.gruppe = p.g; k.inhalt = Double(p.inhalt)
            if let a = alt[p.id] { k.feuer = a.0; k.neuAb = a.1; k.neuGross = a.2 }
            else if warSchon {
                // neue Notiz: sanft aufleuchten, mehrere nacheinander (je 0,7 s versetzt); neuer Ordner etwas größer
                k.neuAb = jetztS + Double(neuZaehler) * 0.7; neuZaehler += 1
                k.neuGross = alteGruppen.contains(p.g) ? 1 : 1.6
            }
            return k
        }
        kanten = s.links.enumerated().map { k, l in Kante(a: l.0, b: l.1, seite: k % 2 == 1 ? 1 : -1) }
        kanteVon = [:]
        for (k, l) in kanten.enumerated() { knoten[l.a].nb.append(l.b); knoten[l.b].nb.append(l.a); kanteVon[l.a * 100_000 + l.b] = k; kanteVon[l.b * 100_000 + l.a] = k }
        pulse = []; kaskaden = []; verzoegert = []
        if sterne.isEmpty {
            var z = Zufall("vault-graph")
            sterne = (0..<180).map { _ in
                let u = z.next() * 2 - 1, t = z.next() * 6.283, r = (1 - u * u).squareRoot()
                return (SIMD3(r * cos(t), u, r * sin(t)) * 5, Float(z.next() * 0.35 + 0.06), Float(z.next() * 1.1 + 0.3), Float(z.next() * 6))
            }
        }
    }

    // MARK: Kamera wie in der Seite (Hintergrund-Modus)
    private var rotY = 0.6, rotX = -0.2, zoom = 1.38, atmen = 1.0, W = 1.0, H = 1.0
    private var mitteY = 0.46, mitteX = 0.5
    private var zentriert = false
    /// Vom System belegte Ränder (Menüleiste, Dock) in Punkten – die Mitte zielt auf den freien Teil, gleitet bei Änderung langsam nach
    var rand = NSEdgeInsets(top: 24, left: 0, bottom: 0, right: 0)
    private func proj(_ v: SIMD3<Double>) -> SIMD4<Double> {
        let cy = cos(rotY), sy = sin(rotY), cx = cos(rotX), sx = sin(rotX)
        let x1 = v.x * cy - v.z * sy, z1 = v.x * sy + v.z * cy, y1 = v.y * cx - z1 * sx, z2 = v.y * sx + z1 * cx
        let dist = radius * 3.4, tiefe = dist + z2
        let s = min(W, H) * 0.34 * zoom * atmen / radius * dist / tiefe
        return SIMD4(W * mitteX + x1 * s, H * mitteY + y1 * s, s, z2)
    }
    private func kp(_ a: SIMD4<Double>, _ b: SIMD4<Double>, _ seite: Float) -> SIMD2<Double> {
        let dx = b.x - a.x, dy = b.y - a.y
        return SIMD2((a.x + b.x) / 2 - dy * 0.12 * Double(seite), (a.y + b.y) / 2 + dx * 0.12 * Double(seite))
    }
    private func aufLinie(_ a: SIMD4<Double>, _ b: SIMD4<Double>, _ seite: Float, _ t: Double) -> SIMD2<Double> {
        let c = kp(a, b, seite), u = 1 - t
        return SIMD2(u * u * a.x + 2 * u * t * c.x + t * t * b.x, u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    // MARK: Ströme und Kaskaden
    private func puls(_ von: Int, _ nach: Int, _ l: Int, _ v: Double, _ hell: Double) { pulse.append(Puls(von: von, nach: nach, l: l, t: 0, v: v, hell: hell)) }
    private func schritt(_ dt: Double, _ jetzt: Double) {
        for i in knoten.indices { knoten[i].feuer = max(0, knoten[i].feuer - dt * 0.0005) }
        for i in kanten.indices { kanten[i].feuer = max(0, kanten[i].feuer - dt * 0.0006) }
        if !kanten.isEmpty && Double.random(in: 0..<1, using: &zufall) < dt * 0.006 {
            let k = Int.random(in: 0..<kanten.count, using: &zufall), r = Bool.random(using: &zufall)
            puls(r ? kanten[k].b : kanten[k].a, r ? kanten[k].a : kanten[k].b, k, 0.003 + Double.random(in: 0..<0.003, using: &zufall), 0.6)
        }
        naechsteKaskade -= dt
        if naechsteKaskade < 0 {
            let kand = knoten.indices.filter { knoten[$0].nb.count >= 3 }
            if let s = kand.randomElement(using: &zufall) { knoten[s].feuer = 1; kaskaden.append(Kaskade(front: [s], besucht: [s], tiefe: 0, warte: 0)) }
            naechsteKaskade = 12000 + Double.random(in: 0..<6000, using: &zufall)
        }
        for k in kaskaden.indices.reversed() {
            kaskaden[k].warte -= dt
            if kaskaden[k].warte > 0 { continue }
            if kaskaden[k].tiefe >= 2 || kaskaden[k].front.isEmpty { kaskaden.remove(at: k); continue }
            var neu: [Int] = []
            for n in kaskaden[k].front {
                let nb = knoten[n].nb.filter { !kaskaden[k].besucht.contains($0) }.shuffled(using: &zufall).prefix(kaskaden[k].tiefe == 0 ? 6 : 2)
                for m in nb {
                    kaskaden[k].besucht.insert(m); neu.append(m)
                    if let l = kanteVon[n * 100_000 + m] { kanten[l].feuer = 1; puls(n, m, l, 0.012 + Double.random(in: 0..<0.006, using: &zufall), 1.15) }
                    verzoegert.append((jetzt + 1100, m, 0.7 - Double(kaskaden[k].tiefe) * 0.25))
                }
            }
            kaskaden[k].front = neu; kaskaden[k].tiefe += 1; kaskaden[k].warte = 1100
        }
        verzoegert.removeAll { e in if e.0 <= jetzt { if e.1 < knoten.count { knoten[e.1].feuer = max(knoten[e.1].feuer, e.2) }; return true }; return false }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let jetzt = CACurrentMediaTime()
        beiBild?(jetzt)
        let dt = min(50, (jetzt - letzt) * 1000); letzt = jetzt
        imFlug.wait()
        guard let cb = schlange.makeCommandBuffer(), let rp = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { imFlug.signal(); return }
        cb.addCompletedHandler { [imFlug] _ in imFlug.signal() }
        let dpr = Double(view.window?.backingScaleFactor ?? 2)
        kodieren(cb, rp, punkte: SIMD2(Double(view.drawableSize.width) / dpr, Double(view.drawableSize.height) / dpr), dpr: dpr, dt: dt, laufzeit: jetzt - start)
        if let g = gpuDauer { cb.addCompletedHandler { c in if c.gpuEndTime > c.gpuStartTime { g(c.gpuEndTime - c.gpuStartTime) } } }
        cb.present(drawable)
        cb.commit()
    }

    private func kodieren(_ cb: MTLCommandBuffer, _ rp: MTLRenderPassDescriptor, punkte: SIMD2<Double>, dpr: Double, dt: Double, laufzeit: Double) {
        W = max(1, punkte.x); H = max(1, punkte.y)
        let z = zeit
        rotY = 0.6 + z * 0.00003; rotX = -0.2 + sin(z * 0.00006) * 0.08; atmen = 1 + sin(z * 0.00011) * 0.02
        zoom = W / H > 1.4 ? 1.38 : 1.15
        schritt(dt, laufzeit * 1000)
        let wackel = 1.2 * massstab
        for i in knoten.indices {
            let w = z * 0.0004 + knoten[i].ph, b = knoten[i].b
            knoten[i].p = proj(SIMD3(b.x + sin(w) * wackel, b.y + cos(w * 1.13) * wackel, b.z + sin(w * 0.87) * wackel))
        }
        // Netz mittig halten: Schwerpunkt der Notizen auf die Mitte des sichtbaren Bereichs ziehen, langsam (kein Wackeln)
        if !knoten.isEmpty {
            // Gewichteter Median: Mitte des sichtbaren Lichts (große, helle Notizen zählen mehr), Ausreißer ohne Verbindung verschieben nichts
            func wMedian(_ werte: [(Double, Double)]) -> Double {
                let w = werte.sorted { $0.0 < $1.0 }, halb = w.reduce(0) { $0 + $1.1 } / 2
                var summe = 0.0
                for e in w { summe += e.1; if summe >= halb { return e.0 } }
                return w.last?.0 ?? 0
            }
            let gewichte = knoten.map { n -> Double in
                let r = max(1.1, n.r * n.p.z * 0.85), al = max(0.28, min(1, 0.95 - n.p.w / (radius * 2.4)))
                return r * r * al }
            let sx = wMedian(zip(knoten.map(\.p.x), gewichte).map { ($0, $1) })
            let sy = wMedian(zip(knoten.map(\.p.y), gewichte).map { ($0, $1) })
            let zielX = (Double(rand.left) + W - Double(rand.right)) / 2, zielY = (Double(rand.top) + H - Double(rand.bottom)) / 2
            let k = zentriert ? min(1, dt / 6000) : 1      // erstes Bild sofort, danach ganz ruhig über einige Sekunden
            mitteX += (zielX - sx) / W * k; mitteY += (zielY - sy) / H * k
            mitteX = min(0.6, max(0.4, mitteX)); mitteY = min(0.65, max(0.35, mitteY))
            if !zentriert {   // nach dem Sprung einmal neu projizieren
                zentriert = true
                for i in knoten.indices {
                    let w = z * 0.0004 + knoten[i].ph, b = knoten[i].b
                    knoten[i].p = proj(SIMD3(b.x + sin(w) * wackel, b.y + cos(w * 1.13) * wackel, b.z + sin(w * 0.87) * wackel))
                }
            }
        }
        // Rahmendaten
        var bd = BildDaten()
        bd.groesse = SIMD2(Float(W), Float(H)); bd.dpr = Float(dpr); bd.mitteY = Float(mitteY)
        let M = max(W, H)
        let fx: [Double] = [0.28, 0.74, 0.62], fy: [Double] = [0.32, 0.70, 0.22], fr: [Double] = [0.62, 0.5, 0.55]
        var fp: [SIMD4<Float>] = [], fc: [SIMD4<Float>] = []
        for (k, f) in Self.flecken.enumerated() {
            let v = 0.00003 + Double(k) * 0.00001, ph = Double(k) * 1.7
            fp.append(SIMD4(Float(W * (fx[k] + sin(z * v + ph) * 0.05)), Float(H * (fy[k] + cos(z * v * 1.3 + ph) * 0.05)), Float(M * fr[k]), f.1))
            fc.append(SIMD4(f.0 / 255, 1))
        }
        bd.f0 = fp[0]; bd.f1 = fp[1]; bd.f2 = fp[2]; bd.c0 = fc[0]; bd.c1 = fc[1]; bd.c2 = fc[2]
        var rr: [SIMD4<Float>] = []
        for i in 0..<3 {
            let di = Double(i)
            let x = W * (0.5 + sin(z * 0.00002 * (di + 1) + di * 2) * 0.35), y = H * (0.35 + di * 0.22 + cos(z * 0.000025 * (di + 1)) * 0.06)
            rr.append(SIMD4(Float(x), Float(y), Float(M * (0.9 + di * 0.2)), Float(sin(z * 0.00001 + di) * 0.3)))
        }
        bd.r0 = rr[0]; bd.r1 = rr[1]; bd.r2 = rr[2]
        bd.zeitKurz = Float(laufzeit); bd.einblend = Float(min(1, laufzeit / 1.6))
        // Sterne (kleine Quadrate) und Leuchtpunkte
        var hinten: [SpriteI] = [], licht: [SpriteI] = [], formen: [FormI] = []
        // (keine Hintergrund-Sterne: leuchten sollen nur die Notizen)
        // Linien: Grund (Messing, darüber gemalt) und Feuer (Funke, addiert)
        var linien: [LinieI] = []; linien.reserveCapacity(kanten.count + 32)
        for l in kanten {
            let a = knoten[l.a].p, b = knoten[l.b].p
            linien.append(LinieI(ab: SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(b.y)), p: SIMD4(l.seite, 0.7, 0.16, 0), farbe: SIMD4(Self.messing / 255, 1)))
        }
        for l in kanten where l.feuer * 0.45 >= 0.02 {
            let a = knoten[l.a].p, b = knoten[l.b].p
            linien.append(LinieI(ab: SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(b.y)), p: SIMD4(l.seite, 1.1, Float(l.feuer * 0.45), 1), farbe: SIMD4(Self.funke / 255, 1)))
        }
        // Ströme
        let funke = Self.funke / 255, weiss = Self.weiss / 255
        for k in pulse.indices.reversed() {
            pulse[k].t += pulse[k].v * dt / 16
            if pulse[k].t >= 1 { pulse.remove(at: k); continue }
            let u = pulse[k], l = kanten[u.l], a = knoten[u.von].p, b = knoten[u.nach].p
            let vorwaerts = l.a == u.von, A = vorwaerts ? a : b, B = vorwaerts ? b : a
            let pos = { (tt: Double) in self.aufLinie(A, B, l.seite, vorwaerts ? tt : 1 - tt) }
            let sch = sin(u.t * .pi), basis = (2 + 1.8 * min(1.5, knoten[u.von].p.z * massstab * 1.2)) * u.hell
            for s2 in 0..<4 {
                let tt = u.t - Double(s2) * 0.018; if tt < 0 { break }
                let q = pos(tt), sz = basis * (1 - Double(s2) / 4) * 2
                licht.append(SpriteI(a: SIMD4(Float(q.x), Float(q.y), Float(sz), Float(sch * (1 - Double(s2) / 4) * 0.55)), b: SIMD4(funke, 0)))
            }
            let q = pos(u.t)
            licht.append(SpriteI(a: SIMD4(Float(q.x), Float(q.y), Float(basis * 0.7), Float(sch * 0.9)), b: SIMD4(weiss, 0)))
        }
        // Neue Notizen: warmes, weiches Licht – 1,5 s anschwellen, dann über etwa 10 s ausklingen
        let warm = SIMD3<Float>(255, 236, 200) / 255
        let tS = laufzeit
        for i in knoten.indices where knoten[i].neuAb >= 0 {
            let t = tS - knoten[i].neuAb
            if t < 0 { continue }
            if t > 14 { knoten[i].neuAb = -1; continue }
            let kurve = t < 1.5 ? (1 - cos(t / 1.5 * .pi)) / 2 : exp(-(t - 1.5) / 3.5)
            let p = knoten[i].p, r = max(1.1, knoten[i].r * p.z * 0.85)
            let groesse = r * (9 + 5 * knoten[i].neuGross) * (0.85 + 0.15 * kurve)
            licht.append(SpriteI(a: SIMD4(Float(p.x), Float(p.y), Float(groesse), Float(0.42 * kurve * knoten[i].neuGross.squareRoot())), b: SIMD4(warm, 0)))
        }
        // Notizen: nur Licht, ohne Umriss. Mehr Inhalt = etwas größer und heller, gedeckelt (gediegen statt grell)
        for n in knoten {
            let p = n.p, t = n.inhalt
            let r = max(1.1, n.r * p.z * 0.85)
            let al = max(0.28, min(1, 0.95 - p.w / (radius * 2.4)))
            let hell = 0.45 + 0.55 * t
            let glanz = (0.25 + 0.2 * t) + n.feuer * 0.9
            let farbe = n.feuer > 0.3 ? funke : n.farbe
            let sz = r * (4 + 1.5 * t + n.feuer * 4)
            licht.append(SpriteI(a: SIMD4(Float(p.x), Float(p.y), Float(sz), Float(min(1, al * glanz))), b: SIMD4(farbe, 0)))
            licht.append(SpriteI(a: SIMD4(Float(p.x), Float(p.y), Float(r * 1.6), Float(al * hell)), b: SIMD4(n.farbe, 0)))
            licht.append(SpriteI(a: SIMD4(Float(p.x), Float(p.y), Float(r * 0.5), Float(al * (0.25 + 0.75 * t))), b: SIMD4(weiss, 0)))
        }

        let bg = MemoryLayout<BildDaten>.stride
        let gw = max(1, Int(W * dpr) / 2), gh = max(1, Int(H * dpr) / 2)
        if grundTex.first?.width != gw || grundTex.first?.height != gh {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: gw, height: gh, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            grundTex = (0..<2).compactMap { _ in geraet.makeTexture(descriptor: d) }; grundZeit = -1
        }
        // zwei Puffer im Wechsel, damit nie in einen gelesenen geschrieben wird
        if grundTex.count == 2 && (grundZeit < 0 || laufzeit - grundZeit >= 0.5 || dt == 0) {
            let ziel = grundTex[1 - grundAktiv]
            let gp = MTLRenderPassDescriptor()
            gp.colorAttachments[0].texture = ziel; gp.colorAttachments[0].loadAction = .dontCare; gp.colorAttachments[0].storeAction = .store
            if let ge = cb.makeRenderCommandEncoder(descriptor: gp) {
                ge.setRenderPipelineState(grundP)
                ge.setVertexBytes(&bd, length: bg, index: 0); ge.setFragmentBytes(&bd, length: bg, index: 0)
                ge.setFragmentSamplerState(probe, index: 0)
                for (i, t) in rauch.enumerated() { ge.setFragmentTexture(t, index: i) }
                ge.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); ge.endEncoding()
                grundAktiv = 1 - grundAktiv; grundZeit = laufzeit
            }
        }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setVertexBytes(&bd, length: bg, index: 0); enc.setFragmentBytes(&bd, length: bg, index: 0)
        enc.setFragmentSamplerState(probe, index: 0)
        if grundTex.count == 2 { enc.setRenderPipelineState(grundKopieP); enc.setFragmentTexture(grundTex[grundAktiv], index: 0) }
        else { enc.setRenderPipelineState(grundP); for (i, t) in rauch.enumerated() { enc.setFragmentTexture(t, index: i) } }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        let fach = bildNr % 3; bildNr &+= 1
        func instanzen<T>(_ a: [T], _ pso: MTLRenderPipelineState, ecken: Int, platz: Int) {
            guard !a.isEmpty else { return }
            enc.setRenderPipelineState(pso)
            let laenge = a.count * MemoryLayout<T>.stride
            if laenge < 4096 { a.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: laenge, index: 1) } }
            else {
                if (puffer[fach][platz]?.length ?? 0) < laenge { puffer[fach][platz] = geraet.makeBuffer(length: laenge * 2, options: .storageModeShared) }
                guard let b = puffer[fach][platz] else { return }
                a.withUnsafeBytes { b.contents().copyMemory(from: $0.baseAddress!, byteCount: laenge) }
                enc.setVertexBuffer(b, offset: 0, index: 1)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: ecken, instanceCount: a.count)
        }
        instanzen(hinten, spriteP, ecken: 6, platz: 0)
        instanzen(linien, linieP, ecken: 48, platz: 1)
        instanzen(licht, spriteP, ecken: 6, platz: 2)
        instanzen(formen, formP, ecken: 6, platz: 3)
        enc.setRenderPipelineState(abschlussP)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Standbild in voller Bildschirmgröße (für Sperrbildschirm/Schreibtischbild)
    func standbild(breite w: Int, hoehe h: Int, dpr: Double) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        imFlug.wait(); defer { imFlug.signal() }
        guard let ziel = geraet.makeTexture(descriptor: d), let cb = schlange.makeCommandBuffer() else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = ziel; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        kodieren(cb, rp, punkte: SIMD2(Double(w) / dpr, Double(h) / dpr), dpr: dpr, dt: 0, laufzeit: max(2, CACurrentMediaTime() - start))
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ziel.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let prov = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: info, provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
