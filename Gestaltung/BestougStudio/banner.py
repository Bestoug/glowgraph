#!/usr/bin/env python3
"""Banner für die Anleitung (1600×520) und Vorschaubild für GitHub (1280×640): links Titel, rechts das Netz.
Aufruf: python3 banner.py <netzbild.jpg|png> <ausgabe-ordner>"""
import sys, os, base64, io
from PIL import Image
sys.path.insert(0, os.path.dirname(__file__))
from marke import schrift, zeichen, svg, MED, REG, LIGHT, CREME, ROSE, SENF, NACHT, breite

def bild_b64(pfad, w, h):
    im = Image.open(pfad).convert("RGB")
    s = max(w / im.width, h / im.height); im = im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS)
    l = (im.width - w) // 2; o = (im.height - h) // 2; im = im.crop((l, o, l + w, o + h))
    b = io.BytesIO(); im.save(b, "JPEG", quality=90)
    return "data:image/jpeg;base64," + base64.b64encode(b.getvalue()).decode()

def banner(netz, W, H, titel_gr):
    g = [f'<rect width="{W}" height="{H}" fill="{NACHT}"/>']
    bw = int(W * 0.62)
    g.append(f'<image x="{W - bw}" y="0" width="{bw}" height="{H}" href="{bild_b64(netz, bw, H)}"/>')
    g.append(f'<defs><linearGradient id="v" x1="0" x2="1"><stop offset="0" stop-color="{NACHT}" stop-opacity="1"/>'
             f'<stop offset="1" stop-color="{NACHT}" stop-opacity="0"/></linearGradient></defs>')
    g.append(f'<rect x="{W - bw}" y="0" width="{bw * 0.45:.0f}" height="{H}" fill="url(#v)"/>')
    x = int(W * 0.07); mitte = H / 2
    t, _ = schrift(MED, "Glowgraph", titel_gr, x, mitte + titel_gr * 0.05, 0.01, CREME, "links"); g.append(t)
    t, _ = schrift(LIGHT, "Your Obsidian vault as a living desktop", titel_gr * 0.27, x + 4, mitte + titel_gr * 0.55, 0.02, ROSE, "links"); g.append(t)
    # Absender klein: Zeichen + BESTOUG STUDIO
    zh = titel_gr * 0.32; z, _ = zeichen(x + zh * 0.8 / 2 * 1.04 / 1.0, mitte - titel_gr * 1.2, zh * 0.8, CREME, None, SENF); g.append(z)
    t, _ = schrift(REG, "BESTOUG STUDIO", titel_gr * 0.13, x + zh * 0.8 + 18, mitte - titel_gr * 1.2 + zh * 0.8 * 1.25 / 2 + titel_gr * 0.045, 0.32, CREME, "links"); g.append(t)
    return svg(W, H, "".join(g))

if __name__ == "__main__":
    netz, aus = sys.argv[1], sys.argv[2]
    os.makedirs(aus, exist_ok=True)
    open(os.path.join(aus, "banner.svg"), "w").write(banner(netz, 1600, 520, 124))
    open(os.path.join(aus, "social-preview.svg"), "w").write(banner(netz, 1280, 640, 118))
    print("ok")
