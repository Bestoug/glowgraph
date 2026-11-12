#!/usr/bin/env python3
"""BestougStudio – Markensystem v2. Zeichen: geometrisches B mit einem Lichtfunken im unteren Bauch.
Schrift Poppins (SIL OFL) als Pfade. Aufruf: python3 marke.py <ausgabe-ordner>"""
import sys, os
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

F = "/usr/share/fonts/truetype/google-fonts/"
MED, REG, LIGHT = F + "Poppins-Medium.ttf", F + "Poppins-Regular.ttf", F + "Poppins-Light.ttf"
TINTE, CREME, ROSE, SENF, PETROL, NACHT = "#2E2426", "#F5EBDD", "#E9B8B3", "#D6A23E", "#2F5D62", "#16110F"
_fonts = {}

def schrift(datei, s, groesse, x, grundlinie, sperrung=0.0, farbe=TINTE, anker="mitte"):
    if datei not in _fonts: _fonts[datei] = TTFont(datei)
    f = _fonts[datei]; gs = f.getGlyphSet(); cmap = f.getBestCmap(); k = groesse / f["head"].unitsPerEm
    breiten = [gs[cmap[ord(c)]].width * k for c in s]
    gesamt = sum(breiten) + sperrung * groesse * (len(s) - 1)
    x0 = x - gesamt / 2 if anker == "mitte" else x
    teile = []
    for c, b in zip(s, breiten):
        pen = SVGPathPen(gs); gs[cmap[ord(c)]].draw(TransformPen(pen, (k, 0, 0, -k, x0, grundlinie)))
        if pen.getCommands(): teile.append(pen.getCommands())
        x0 += b + sperrung * groesse
    return f'<path fill="{farbe}" d="{" ".join(teile)}"/>', gesamt

def breite(datei, s, groesse, sperrung=0.0):
    return schrift(datei, s, groesse, 0, 0, sperrung)[1]

def funke(cx, cy, r, farbe):
    i = r * 0.2
    p = [(cx, cy - r), (cx + i, cy - i), (cx + r, cy), (cx + i, cy + i), (cx, cy + r), (cx - i, cy + i), (cx - r, cy), (cx - i, cy - i)]
    return f'<path fill="{farbe}" d="M' + " L".join(f"{a:.2f},{b:.2f}" for a, b in p) + 'Z"/>'

def zeichen(cx, oben, w, farbe=TINTE, linie=None, licht=SENF):
    """Monogramm: geometrisches B aus Stamm und zwei Halbkreis-Bäuchen (Linienstärke 18 von 104), im unteren Bauch der Lichtfunke.
    Höhe = 1,25 × Breite. `linie` bleibt für alte Aufrufe ungenutzt."""
    k = w / 104.0; x0 = cx - w / 2
    def P(x, y): return f"{x0 + x * k:.2f},{oben + y * k:.2f}"
    sw = 15 * k
    d = (f"M{P(9, 1.5)} L{P(9, 128.5)} "
         f"M{P(9, 9)} L{P(62, 9)} A{27 * k:.2f},{27 * k:.2f} 0 0 1 {P(62, 63)} L{P(9, 63)} "
         f"M{P(9, 63)} L{P(66, 63)} A{29 * k:.2f},{29 * k:.2f} 0 0 1 {P(66, 121)} L{P(9, 121)}")
    g = f'<path fill="none" stroke="{farbe}" stroke-width="{sw:.2f}" stroke-linejoin="miter" stroke-linecap="butt" d="{d}"/>'
    g += funke(x0 + 52 * k, oben + 92 * k, 13 * k, licht)
    return g, 130 * k

def svg(w, h, inhalt, hintergrund=None):
    bg = f'<rect width="{w}" height="{h}" fill="{hintergrund}"/>' if hintergrund else ""
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">{bg}{inhalt}</svg>'

def quer(dunkel=False, einfarbig=False):
    t = CREME if dunkel else TINTE
    bogen, linie, licht, nebenfarbe = (ROSE, NACHT, SENF, ROSE) if dunkel else (TINTE, CREME, SENF, PETROL)
    if einfarbig: bogen, linie, licht, nebenfarbe, t = TINTE, CREME, CREME, TINTE, TINTE
    z, zh = zeichen(0, 0, 100, bogen, linie, licht)
    gr, sp = 74, 0.14
    b1 = breite(MED, "BESTOUG", gr, sp)
    b2 = breite(LIGHT, "STUDIO", gr, sp)
    abstand, luecke = 48, 0.36 * gr
    W = int(40 + 100 + abstand + b1 + luecke + b2 + 40); H = int(zh + 80)
    x = 40 + 100 + abstand
    t1, _ = schrift(MED, "BESTOUG", gr, x, 40 + zh * 0.5 + gr * 0.36, sp, t, "links")
    t2, _ = schrift(LIGHT, "STUDIO", gr, x + b1 + luecke, 40 + zh * 0.5 + gr * 0.36, sp, nebenfarbe, "links")
    return svg(W, H, f'<g transform="translate(90,40)">{z}</g>' + t1 + t2, NACHT if dunkel else None)

def gestapelt(dunkel=False):
    t = CREME if dunkel else TINTE
    bogen, linie, nebenfarbe = (ROSE, NACHT, ROSE) if dunkel else (TINTE, CREME, PETROL)
    W, H = 1000, 1000
    z, zh = zeichen(500, 150, 300, bogen, linie, SENF)
    t1, b1 = schrift(MED, "BESTOUG", 110, 500, 700, 0.16, t)
    t2, b2 = schrift(LIGHT, "STUDIO", 52, 500, 790, 0.62, nebenfarbe)
    rules = "".join(f'<line x1="{500 + s * (b2 / 2 + 30):.1f}" y1="772" x2="{500 + s * (b1 / 2):.1f}" y2="772" stroke="{SENF}" stroke-width="3"/>' for s in (-1, 1))
    return svg(W, H, z + t1 + t2 + rules, NACHT if dunkel else CREME)

def profilbild():
    W = 1024
    z, zh = zeichen(512 + 6, 512 - 300 * 1.25 / 2, 300, CREME, None, SENF)
    return svg(W, W, f'<rect width="{W}" height="{W}" fill="{ROSE}"/>' + f'<circle cx="512" cy="512" r="400" fill="{TINTE}"/>' + z)

def markenblatt(ordner):
    """Übersicht als SVG: Lockups, Zeichen in Größen, Farben, Schutzraum."""
    W, H = 2000, 1300
    g = [f'<rect width="{W}" height="{H}" fill="#FBF6EE"/>']
    t, _ = schrift(MED, "BESTOUG STUDIO", 30, 80, 90, 0.3, TINTE, "links"); g.append(t)
    t, _ = schrift(REG, "MARKENBLATT  ·  V3  ·  2026", 22, 80, 130, 0.3, PETROL, "links"); g.append(t)
    # Felder
    g.append(f'<rect x="80" y="180" width="1100" height="500" fill="{CREME}"/>')
    g.append(f'<rect x="1220" y="180" width="700" height="500" fill="{NACHT}"/>')
    gr = 66; b1 = breite(MED, "BESTOUG", gr, 0.14); b2 = breite(LIGHT, "STUDIO", gr, 0.14)
    gesamt = 120 + 44 + b1 + 0.36 * gr + b2; x0 = 80 + (1100 - gesamt) / 2
    z, zh = zeichen(x0 + 60, 430 - 150 / 2, 120); g.append(z)
    t, _ = schrift(MED, "BESTOUG", gr, x0 + 164, 430 + gr * 0.36, 0.14, TINTE, "links"); g.append(t)
    t, _ = schrift(LIGHT, "STUDIO", gr, x0 + 164 + b1 + 0.36 * gr, 430 + gr * 0.36, 0.14, PETROL, "links"); g.append(t)
    z, _ = zeichen(1570, 230, 120, ROSE, NACHT, SENF); g.append(z)
    t, _ = schrift(MED, "BESTOUG", 60, 1570, 470, 0.16, CREME); g.append(t)
    t, _ = schrift(LIGHT, "STUDIO", 30, 1570, 530, 0.62, ROSE); g.append(t)
    # Größen
    x = 80
    for w in (160, 80, 40, 20):
        z, h = zeichen(x + w / 2, 760 + (208 - w * 1.25), w); g.append(z); x += w + 60
    t, _ = schrift(REG, "ZEICHEN BIS 16 PX LESBAR", 20, 80, 1010, 0.3, PETROL, "links"); g.append(t)
    # Farben (mit Namen und Helligkeit, nicht nur Farbe)
    x = 700
    for name, hexw, txt in (("TINTE", TINTE, CREME), ("CREME", CREME, TINTE), ("ROSÉ", ROSE, TINTE), ("SENF", SENF, TINTE), ("PETROL", PETROL, CREME), ("NACHT", NACHT, CREME)):
        g.append(f'<rect x="{x}" y="760" width="190" height="190" fill="{hexw}" stroke="#d8cdbd" stroke-width="2"/>')
        t, _ = schrift(MED, name, 20, x + 16, 900, 0.2, txt, "links"); g.append(t)
        t, _ = schrift(REG, hexw.upper(), 18, x + 16, 930, 0.15, txt, "links"); g.append(t)
        x += 205
    # Schutzraum: halbe Zeichenbreite rundum
    zw = 90; rand = zw / 2; gr = 44; b1 = breite(MED, "BESTOUG", gr, 0.14); b2 = breite(LIGHT, "STUDIO", gr, 0.14)
    innen_w = zw + 36 + b1 + 0.36 * gr + b2; innen_h = zw * 1.25
    g.append(f'<rect x="80" y="1060" width="{innen_w + 2 * rand:.0f}" height="{innen_h + 2 * rand:.0f}" fill="none" stroke="{SENF}" stroke-dasharray="8 8" stroke-width="2"/>')
    z, _ = zeichen(80 + rand + zw / 2, 1060 + rand, zw); g.append(z)
    gl = 1060 + rand + innen_h / 2 + gr * 0.36
    t, _ = schrift(MED, "BESTOUG", gr, 80 + rand + zw + 36, gl, 0.14, TINTE, "links"); g.append(t)
    t, _ = schrift(LIGHT, "STUDIO", gr, 80 + rand + zw + 36 + b1 + 0.36 * gr, gl, 0.14, PETROL, "links"); g.append(t)
    t, _ = schrift(REG, "SCHUTZRAUM = HALBE ZEICHENBREITE", 20, 900, 1140, 0.25, PETROL, "links"); g.append(t)
    t, _ = schrift(REG, "SCHRIFT POPPINS (SIL OPEN FONT LICENSE)", 20, 900, 1180, 0.25, PETROL, "links"); g.append(t)
    open(os.path.join(ordner, "markenblatt.svg"), "w").write(svg(W, H, "".join(g)))

if __name__ == "__main__":
    aus = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(aus, exist_ok=True)
    z, h = zeichen(150, 40, 220)
    teile = {
        "bestougstudio-zeichen.svg": svg(300, int(h + 80), z),
        "bestougstudio-quer.svg": quer(),
        "bestougstudio-quer-dunkel.svg": quer(dunkel=True),
        "bestougstudio-quer-einfarbig.svg": quer(einfarbig=True),
        "bestougstudio-gestapelt.svg": gestapelt(),
        "bestougstudio-gestapelt-dunkel.svg": gestapelt(dunkel=True),
        "bestougstudio-profilbild.svg": profilbild(),
    }
    for n, s in teile.items(): open(os.path.join(aus, n), "w").write(s)
    markenblatt(aus)
    print("ok")
