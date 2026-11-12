// Laterne als Metal-Shader, nachgebaut aus der Graph-Seite (Canvas 2D, Stil „laterne“, Hintergrund-Modus).
// Alles in Punkten (wie CSS-Pixel), vormultipliziertes Alpha: Ausgabe-Alpha 0 = „lighter“ (addieren), sonst „source-over“.
let laterneShaderQuelle = #"""
#include <metal_stdlib>
using namespace metal;

struct Bild {
  float2 groesse;      // W, H in Punkten
  float dpr; float mitteY;
  float4 fleckPos[3];  // x, y, r (Punkte), alpha
  float4 fleckFarbe[3];
  float4 rauch[3];     // x, y, w, winkel
  float zeitKurz; float einblend; float2 frei;
};

constant float2 QUAD[6] = { float2(-1,-1), float2(1,-1), float2(1,1), float2(-1,-1), float2(1,1), float2(-1,1) };
constant float2 VOLL[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
float4 ndc(float2 p, constant Bild& b) { return float4(p.x / b.groesse.x * 2. - 1., 1. - p.y / b.groesse.y * 2., 0, 1); }
float h2(float2 p) { p = fract(p * float2(.1031, .1030)); p += dot(p, p.yx + 33.33); return fract((p.x + p.y) * p.x); }

// ---- Grund: Verlauf, gemalte Flecken, Rauch ----
struct VollOut { float4 pos [[position]]; float2 p; };
vertex VollOut vollV(uint vid [[vertex_id]], constant Bild& b [[buffer(0)]]) {
  VollOut o; float2 v = VOLL[vid]; o.pos = float4(v, 0, 1); o.p = float2((v.x * .5 + .5) * b.groesse.x, (.5 - v.y * .5) * b.groesse.y); return o; }
float3 grund(float t) {
  float3 a = float3(27,19,12)/255., m = float3(13,9,7)/255., e = float3(4,3,2)/255.;
  return t < .6 ? mix(a, m, t / .6) : mix(m, e, min(1., (t - .6) / .4)); }
fragment float4 grundF(VollOut in [[stage_in]], constant Bild& b [[buffer(0)]], array<texture2d<float>, 3> rauchT [[texture(0)]], sampler sm [[sampler(0)]]) {
  float W = b.groesse.x, H = b.groesse.y, M = max(W, H);
  float3 c = grund(length(in.p - float2(W * .5, H * b.mitteY)) / (M * .85));
  for (int k = 0; k < 3; k++) {
    float4 fp = b.fleckPos[k]; if (fp.z <= 0.) continue;
    float t = length(in.p - fp.xy) / fp.z;
    float a = t < .5 ? mix(fp.w, fp.w * .38, t / .5) : mix(fp.w * .38, 0., min(1., (t - .5) / .5));
    c = mix(c, b.fleckFarbe[k].rgb, a);
  }
  for (int k = 0; k < 3; k++) {
    float4 r = b.rauch[k]; if (r.z <= 0.) continue;
    float2 d = in.p - r.xy; float s = sin(-r.w), co = cos(-r.w);
    float2 l = float2(co * d.x - s * d.y, s * d.x + co * d.y);
    float2 uv = float2(l.x / r.z + .5, l.y / (r.z * .5) + .5);
    if (any(uv < 0.) || any(uv > 1.)) continue;
    float4 q = rauchT[k].sample(sm, uv);      // vormultipliziert
    float3 src = q.rgb * .16;
    c = src + c - src * c;                     // „screen“
  }
  return float4(c, 1);
}

// Zwischengespeicherter Grund (halbe Auflösung, zweimal je Sekunde neu) wird hier aufs Bild gezogen
fragment float4 grundKopieF(VollOut in [[stage_in]], constant Bild& b [[buffer(0)]], texture2d<float> t [[texture(0)]], sampler sm [[sampler(0)]]) {
  return float4(t.sample(sm, in.p / b.groesse).rgb, 1); }

// ---- Leuchtpunkte (Sprites wie in der Seite) und Sterne ----
struct Sprite { float4 a; float4 b; };   // a: x, y, r, alpha · b: rgb, art (0 Licht = addieren, 1 Quadrat = darüber malen)
struct SpriteOut { float4 pos [[position]]; float2 v; float4 farbe; float art; };
vertex SpriteOut spriteV(uint vid [[vertex_id]], uint iid [[instance_id]], const device Sprite* s [[buffer(1)]], constant Bild& b [[buffer(0)]]) {
  SpriteOut o; Sprite q = s[iid]; float2 c = QUAD[vid];
  float2 p = q.b.w < .5 ? q.a.xy + c * q.a.z : q.a.xy + (c * .5 + .5) * q.a.z;
  o.pos = ndc(p, b); o.v = c; o.farbe = float4(q.b.rgb, q.a.w); o.art = q.b.w; return o; }
fragment float4 spriteF(SpriteOut in [[stage_in]]) {
  if (in.art > .5) return float4(in.farbe.rgb * in.farbe.a, in.farbe.a);
  float r = length(in.v); if (r >= 1.) discard_fragment();
  float a = r < .12 ? mix(1., .55, r / .12) : r < .35 ? mix(.55, .14, (r - .12) / .23) : mix(.14, 0., (r - .35) / .65);
  return float4(in.farbe.rgb * a * in.farbe.a, 0.);   // addieren
}

// ---- Linien: leichte Bögen (quadratische Kurve wie in der Seite), 8 Stücke je Linie ----
struct Linie { float4 ab; float4 p; float4 farbe; };   // ab: Anfang, Ende · p: seite, breite, alpha, addieren
struct LinieOut { float4 pos [[position]]; float quer; float halb; float4 farbe; float addieren; };
vertex LinieOut linieV(uint vid [[vertex_id]], uint iid [[instance_id]], const device Linie* l [[buffer(1)]], constant Bild& b [[buffer(0)]]) {
  LinieOut o; Linie L = l[iid];
  float2 qa = L.ab.xy, qb = L.ab.zw; float seite = L.p.x, breite = L.p.y;
  uint seg = vid / 6, ecke = vid % 6;
  float2 d = qb - qa; float2 k = (qa + qb) * .5 + float2(-d.y, d.x) * .12 * seite;
  float t0 = float(seg) / 8., t1 = float(seg + 1) / 8.;
  float u0 = 1. - t0, u1 = 1. - t1;
  float2 p0 = u0*u0*qa + 2.*u0*t0*k + t0*t0*qb, p1 = u1*u1*qa + 2.*u1*t1*k + t1*t1*qb;
  float2 r = p1 - p0; float lr = length(r); r = lr > 1e-4 ? r / lr : float2(1, 0);
  float2 n = float2(-r.y, r.x);
  float halb = max(breite, 1. / b.dpr) * .5 + .75 / b.dpr;   // Kante für weiches Ende
  bool ende = (ecke == 1 || ecke == 2 || ecke == 4); float s = (ecke == 2 || ecke == 4 || ecke == 5) ? 1. : -1.;
  float2 p = (ende ? p1 : p0) + n * s * halb;
  o.pos = ndc(p, b); o.quer = s * halb; o.halb = max(breite, 1. / b.dpr) * .5; o.farbe = float4(L.farbe.rgb, L.p.z); o.addieren = L.p.w;
  return o; }
fragment float4 linieF(LinieOut in [[stage_in]], constant Bild& b [[buffer(0)]]) {
  float deckung = clamp((in.halb - abs(in.quer)) * b.dpr + .5, 0., 1.);
  float a = in.farbe.a * deckung;
  return float4(in.farbe.rgb * a, in.addieren > .5 ? 0. : a); }

// ---- Formen (Ring, Raute, Quadrat) und Feuer-Sechseck als 1-Punkt-Umriss ----
struct Form { float4 a; float4 b; float4 c; };  // a: x, y, r, alpha · b: rgb, art (0 keine, 1 Ring, 2 Raute, 3 Quadrat) · c: Funke rgb, feuer
struct FormOut { float4 pos [[position]]; float2 l; float r; float a; float3 farbe; float art; float feuer; float3 funke; };
vertex FormOut formV(uint vid [[vertex_id]], uint iid [[instance_id]], const device Form* f [[buffer(1)]], constant Bild& b [[buffer(0)]]) {
  FormOut o; Form q = f[iid]; float2 c = QUAD[vid]; float aus = q.a.z * 1.3 + 16.;
  o.l = c * aus; o.pos = ndc(q.a.xy + o.l, b); o.r = q.a.z; o.a = q.a.w; o.farbe = q.b.rgb; o.art = q.b.w; o.feuer = q.c.w; o.funke = q.c.rgb; return o; }
float sechseck(float2 p, float R) {   // Spitze oben/unten, Umkreis R
  float ri = R * .8660254; p = abs(p.yx);
  const float3 k = float3(-.8660254, .5, .5773503);
  p -= 2. * min(dot(k.xy, p), 0.) * k.xy; p -= float2(clamp(p.x, -k.z * ri, k.z * ri), ri);
  return length(p) * sign(p.y); }
float umriss(float d, float dpr) { return clamp((.5 - abs(d)) * dpr + .5, 0., 1.); }   // Linienbreite 1 Punkt
fragment float4 formF(FormOut in [[stage_in]], constant Bild& b [[buffer(0)]]) {
  float4 c = float4(0);
  float R = in.r * .7;
  if (in.art > .5) {
    float d = in.art < 1.5 ? length(in.l) - R
            : in.art < 2.5 ? (abs(in.l.x) + abs(in.l.y) - R * 1.3) * .7071068
            : max(abs(in.l.x), abs(in.l.y)) - R * .95;
    float a = umriss(d, b.dpr) * .8 * in.a; c = float4(in.farbe * a, a);
  }
  if (in.feuer > .05) {
    float d = sechseck(in.l, (in.r + 3. + (1. - in.feuer) * 10.) * 1.12);
    float a = umriss(d, b.dpr) * in.feuer * .5 * in.a;
    c = float4(in.funke * a, a) + c * (1. - a);
  }
  if (c.a <= 0.) discard_fragment();
  return c; }

// ---- Abschluss: Körnung (überlagern) und Rand, Einblenden beim Start ----
fragment float4 abschlussF(VollOut in [[stage_in]], constant Bild& b [[buffer(0)]], float4 ziel [[color(0)]]) {
  float W = b.groesse.x, H = b.groesse.y;
  float3 d = ziel.rgb;
  float n = h2(floor(fmod(in.p * b.dpr, 440.)));            // festes Rauschen, Kachel wie in der Seite
  float3 ov = select(1. - 2. * (1. - d) * (1. - n), 2. * d * n, d < .5);
  d = mix(d, ov, .05);
  float t = clamp((length(in.p - float2(W, H) * .5) - min(W, H) * .35) / (max(W, H) * .75 - min(W, H) * .35), 0., 1.);
  d *= 1. - .7 * t;
  return float4(d * b.einblend, 1); }
"""#
