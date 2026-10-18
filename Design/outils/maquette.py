#!/usr/bin/env python3
"""Maquette de la fenêtre principale : fond coloré, verre, jauge dynamique.

Sert de référence visuelle à OustDesignSystem, pas d'écran définitif. La fonction
`gauge` décrit l'algorithme de la jauge tel qu'il doit être reproduit en SwiftUI.

Usage : python3 maquette.py <dossier>   → maquette-app-claire.svg, maquette-app-sombre.svg
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from icone import blur, f, polar, sector  # noqa: E402
from palette import (ECLAT, ECLAT_TEXT, GLASS_SHEEN, GLASS_VEIL, HALO_OPACITY, SAFETY, SECTIONS,  # noqa: E402
                     TRACK_SMOKE, gauge_colors)

WW, WH = 1160, 740
FONT = "font-family=\"-apple-system, 'SF Pro Text', system-ui\" style=\"font-variant-numeric: tabular-nums\""


# ---------------------------------------------------------------------------
# Jauge — l'algorithme de référence
# ---------------------------------------------------------------------------

# Proportions tirées de l'icône (rayon extérieur R = 1)
GAUGE_THICKNESS = 0.46       # épaisseur de l'anneau
GAUGE_JOINT = 0.065          # joint constant entre deux segments
GAUGE_CORNER = 0.094         # rayon des coins, réduit pour les petits segments
GAUGE_KICK = 0.08            # la corbeille se détache vers l'extérieur de 8 % de R


def corner_for(r_in: float, span: float, rc: float, gap: float) -> float:
    """Plus grand rayon de coin qui tient dans le segment (les coins intérieurs sont les plus serrés)."""
    while rc > 1 and 2 * math.degrees(math.asin(min(1, (rc + gap / 2) / (r_in + rc)))) > span * 0.96:
        rc -= 0.5
    return rc


def min_span(r: float) -> float:
    """Angle minimal d'un segment dessinable ; en dessous, il rejoint « Autres »."""
    r_in, gap = r * (1 - GAUGE_THICKNESS), r * GAUGE_JOINT
    return 2 * math.degrees(math.asin((2 + gap / 2) / (r_in + 2))) / 0.96


def gauge(cx: float, cy: float, r: float, parts: list[tuple[float, str]], total: float):
    """parts : (valeur, clé) dans l'ordre horaire depuis midi ; le reste du total est l'espace libre.
    Renvoie [(clé, chemin, angle de départ, angle de fin)] ; la piste se dessine à part, en anneau plein."""
    r_in, gap, rc = r * (1 - GAUGE_THICKNESS), r * GAUGE_JOINT, r * GAUGE_CORNER
    out, a = [], 0.0
    for value, key in parts:
        span = 360 * value / total
        if span < min_span(r):
            raise ValueError(f"{key} : {span:.1f}° < {min_span(r):.1f}°, à regrouper dans « Autres »")
        out.append((key, sector(cx, cy, r_in, r, a, a + span, corner_for(r_in, span, rc, gap), gap), a, a + span))
        a += span
    return out


# ---------------------------------------------------------------------------
# Verre
# ---------------------------------------------------------------------------

def glass(pid: str, x, y, w, h, rx, shadow=True) -> tuple[str, str]:
    d = f'<clipPath id="c-{pid}"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}"/></clipPath>'
    sh = (f'<rect x="{x}" y="{y + 10}" width="{w}" height="{h}" rx="{rx}" fill="#000" opacity=".22" '
          f'filter="url(#flou-ombre)"/>') if shadow else ""
    m = f"""{sh}
    <g clip-path="url(#c-{pid})">
      <use href="#fond" filter="url(#flou-verre)"/>
      <rect x="{x}" y="{y}" width="{w}" height="{h}" fill="#000" opacity="{GLASS_VEIL}"/>
      <rect x="{x}" y="{y}" width="{w}" height="{h}" fill="#FFF" opacity="{GLASS_SHEEN}"/>
      <rect x="{x}" y="{y}" width="{w}" height="{min(h, 90)}" fill="url(#verre-haut)"/>
    </g>
    <rect x="{x + .75}" y="{y + .75}" width="{w - 1.5}" height="{h - 1.5}" rx="{rx}" fill="none" stroke="url(#verre-bord)"
      stroke-width="1.5"/>"""
    return d, m


def text(x, y, s, size=14, weight=500, anchor="start", fill="#FFF", extra=""):
    return (f'<text x="{f(x)}" y="{f(y)}" font-size="{size}" font-weight="{weight}" fill="{fill}" '
            f'text-anchor="{anchor}" {FONT} {extra}>{s}</text>')


def chip(x, y, label, fill):
    w = len(label) * 6.9 + 30
    return (f'<rect x="{f(x - w)}" y="{y}" width="{f(w)}" height="24" rx="12" fill="{fill}"/>'
            f'<rect x="{f(x - w + .5)}" y="{y + .5}" width="{f(w - 1)}" height="23" rx="11.5" fill="none" '
            f'stroke="#FFF" stroke-opacity=".25"/>'
            f'<circle cx="{f(x - w + 13)}" cy="{y + 12}" r="4" fill="#FFF"/>'
            + text(x - w + 22, y + 16.5, label, 12, 650))


def section_icon(x, y, name, size=22):
    a, b = SECTIONS[name][:2]
    gid = "ic-" + str(abs(hash(name)) % 10**8)
    return (f'<defs><linearGradient id="{gid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{a}"/>'
            f'<stop offset="1" stop-color="{b}"/></linearGradient></defs>'
            f'<rect x="{x}" y="{y}" width="{size}" height="{size}" rx="{size * .28}" fill="url(#{gid})"/>'
            f'<rect x="{x + .5}" y="{y + .5}" width="{size - 1}" height="{size - 1}" rx="{size * .28 - .5}" fill="none" '
            f'stroke="#FFF" stroke-opacity=".45"/>')


# ---------------------------------------------------------------------------
# Fenêtre
# ---------------------------------------------------------------------------

def window(appearance: str) -> str:
    start, end, glow, deep = SECTIONS["Vue d'ensemble"]
    defs = [blur("flou-verre", 22), blur("flou-halo", 120), blur("flou-ombre", 16), blur("flou-seg", 10)]
    defs.append(f"""
    <linearGradient id="vif" x1="0" y1="0" x2="{WW}" y2="{WH}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{start}"/><stop offset="1" stop-color="{end}"/></linearGradient>
    <linearGradient id="verre-haut" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFF" stop-opacity=".10"/><stop offset="1" stop-color="#FFF" stop-opacity="0"/></linearGradient>
    <linearGradient id="verre-bord" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#FFF" stop-opacity=".55"/><stop offset=".4" stop-color="#FFF" stop-opacity=".12"/>
      <stop offset="1" stop-color="#FFF" stop-opacity=".28"/></linearGradient>
    <linearGradient id="eclat" x1="0" y1="0" x2="1" y2="1">
      {"".join(f'<stop offset="{i / 2}" stop-color="{c}"/>' for i, c in enumerate(ECLAT))}</linearGradient>
    <clipPath id="c-fenetre"><rect width="{WW}" height="{WH}" rx="16"/></clipPath>""")
    if appearance == "claire":
        backdrop = f"""<rect width="{WW}" height="{WH}" fill="url(#vif)"/>
        <circle cx="120" cy="80" r="300" fill="{glow}" opacity=".35" filter="url(#flou-halo)" style="mix-blend-mode:screen"/>"""
    else:
        backdrop = f"""<rect width="{WW}" height="{WH}" fill="{deep}"/>
        <circle cx="200" cy="660" r="320" fill="{start}" opacity="{HALO_OPACITY}" filter="url(#flou-halo)" style="mix-blend-mode:screen"/>
        <circle cx="1020" cy="110" r="300" fill="{end}" opacity="{HALO_OPACITY}" filter="url(#flou-halo)" style="mix-blend-mode:screen"/>"""
    defs.append(f'<g id="fond">{backdrop}</g>')
    body = ['<use href="#fond"/>']

    # Barre latérale : verre flottant
    d, m = glass("side", 10, 10, 236, WH - 20, 18)
    defs.append(d)
    body.append(m)
    body += [f'<circle cx="{30 + 20 * i}" cy="32" r="6" fill="{c}"/>' for i, c in enumerate(("#FF5F57", "#FEBC2E", "#28C840"))]
    y = 72
    body.append(f'<rect x="18" y="{y - 4}" width="220" height="34" rx="10" fill="#FFF" opacity=".16"/>')
    for name in SECTIONS:
        body.append(section_icon(28, y + 2, name))
        body.append(text(60, y + 18, name.replace("&", "&amp;"), 14, 560))
        y += 38
    body.append(f'<rect x="28" y="{y + 4}" width="200" height="1" fill="#FFF" opacity=".18"/>')
    y += 20
    body.append(f'<rect x="28" y="{y + 2}" width="22" height="22" rx="6.2" fill="url(#eclat)"/>')
    body.append(text(60, y + 18, "Corbeille", 14, 560))
    body.append(f'<rect x="196" y="{y + 3}" width="30" height="20" rx="10" fill="url(#eclat)"/>')
    body.append(text(211, y + 17.5, "12", 12, 700, "middle", ECLAT_TEXT))
    body.append(text(28, WH - 46, "Macintosh HD", 13, 650))
    body.append(text(28, WH - 28, "1 To · APFS", 12, 500))

    # Titre
    body.append(text(276, 52, "Vue d'ensemble", 28, 750))
    body.append(text(276, 76, "Analysé il y a 2 minutes · 1,2 million de fichiers", 13, 500))

    # Carte de la jauge
    gx, gy, gw, gh = 266, 100, 430, 520
    d, m = glass("jauge", gx, gy, gw, gh, 24)
    defs.append(d)
    body.append(m)
    cx, cy, R = gx + gw / 2, gy + 228, 168
    r_in = R * (1 - GAUGE_THICKNESS)
    total = 1000
    parts = [(230, "Explorateur"), (180, "Système"), (64, "Développement & IA"), (95, "Autres"), (79.6, "Corbeille")]
    track = (f'<path d="M{f(cx - R)} {f(cy)} a{R} {R} 0 1 0 {2 * R} 0 a{R} {R} 0 1 0 {-2 * R} 0 Z '
             f'M{f(cx - r_in)} {f(cy)} a{f(r_in)} {f(r_in)} 0 1 1 {f(2 * r_in)} 0 a{f(r_in)} {f(r_in)} 0 1 1 {f(-2 * r_in)} 0 Z" '
             f'fill-rule="evenodd" fill="#000" opacity="{TRACK_SMOKE}"/>')
    body.append(track)
    for key, path, a0, a1 in gauge(cx, cy, R, parts, total):
        mid = (a0 + a1) / 2
        if key == "Corbeille":
            k = R * GAUGE_KICK
            tf = f' transform="translate({f(k * math.sin(math.radians(mid)))} {f(-k * math.cos(math.radians(mid)))})"'
            fill, glow_c = "url(#eclat)", ECLAT[1]
        elif key == "Autres":
            tf, fill, glow_c = "", "#D9D4EC", None
        else:
            g0, g1 = gauge_colors(key)
            p0, p1 = polar(cx, cy, R, a0), polar(cx, cy, R, a1)
            gid = "g-" + str(abs(hash(key)) % 10**8)
            defs.append(f'<linearGradient id="{gid}" x1="{f(p0[0])}" y1="{f(p0[1])}" x2="{f(p1[0])}" y2="{f(p1[1])}" '
                        f'gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{g0}"/>'
                        f'<stop offset="1" stop-color="{g1}"/></linearGradient>')
            tf, fill, glow_c = "", f"url(#{gid})", g0
        if glow_c:
            body.append(f'<path d="{path}" fill="{glow_c}" opacity=".55" filter="url(#flou-seg)"{tf} '
                        f'style="mix-blend-mode:screen"/>')
        body.append(f'<path d="{path}" fill="{fill}"{tf}/>')
        body.append(f'<path d="{path}" fill="none" stroke="#FFF" stroke-opacity=".35" stroke-width="1.5"{tf}/>')
    body.append(text(cx, cy - 10, "351 Go", 46, 780, "middle"))
    body.append(text(cx, cy + 16, "libres sur 1 To", 13, 560, "middle"))
    body.append(f'<circle cx="{f(cx - 38)}" cy="{f(cy + 39)}" r="4.5" fill="url(#eclat)"/>')
    body.append(text(cx + 6, cy + 44, "+79,6 Go", 14, 720, "middle"))
    body.append(text(cx, cy + 62, "après le vide", 12, 520, "middle"))
    # Légende
    ly = gy + gh - 108
    legend = [("Explorateur", gauge_colors("Explorateur")[0], "230 Go"), ("Système", gauge_colors("Système")[0], "180 Go"),
              ("Dév. &amp; IA", gauge_colors("Développement & IA")[0], "64 Go"), ("Autres", "#D9D4EC", "95 Go"),
              ("Corbeille", ECLAT[1], "79,6 Go"), ("Libre", None, "351 Go")]
    for i, (label, color, size) in enumerate(legend):
        lx, yy = gx + 30 + (i % 3) * 132, ly + (i // 3) * 40
        if color:
            body.append(f'<rect x="{lx}" y="{yy}" width="12" height="12" rx="3.5" fill="{color}"/>')
        else:
            body.append(f'<rect x="{lx + .75}" y="{yy + .75}" width="10.5" height="10.5" rx="3" fill="none" stroke="#FFF" '
                        f'stroke-opacity=".7" stroke-width="1.5"/>')
        body.append(text(lx + 20, yy + 11, label, 13, 600))
        body.append(text(lx + 20, yy + 28, size, 12, 500))

    # Liste : ce qui peut partir
    lx, lyy, lw, lh = 712, 100, 432, 520
    d, m = glass("liste", lx, lyy, lw, lh, 24)
    defs.append(d)
    body.append(m)
    body.append(text(lx + 22, lyy + 38, "Ce qui peut partir", 17, 700))
    rows = [("Système", "Snapshots Time Machine locaux", "180 Go", "À examiner"),
            ("Développement &amp; IA", "DerivedData, simulateurs, caches", "52,3 Go", "Se reconstruit"),
            ("Développement &amp; IA", "Modèles Ollama inutilisés", "11,7 Go", "À examiner"),
            ("Doublons", "214 groupes, copies identiques", "12,4 Go", "À examiner"),
            ("Navigateurs", "Caches de Safari, Arc et Chrome", "4,1 Go", "Sûr"),
            ("Développement &amp; IA", "worktree agent-7 · non commité", "1,8 Go", "Protégé"),
            ("Système", "Dossier sans droit de lecture", "—", "Inaccessible")]
    ry = lyy + 62
    for sec, detail, size, cls in rows:
        body.append(f'<rect x="{lx + 14}" y="{ry - 6}" width="{lw - 28}" height="58" rx="14" fill="#FFF" opacity=".06"/>')
        body.append(section_icon(lx + 26, ry + 8, sec.replace("&amp;", "&"), 24))
        body.append(text(lx + 62, ry + 16, sec, 14, 650))
        body.append(text(lx + 62, ry + 35, detail, 12.5, 500))
        body.append(text(lx + lw - 30, ry + 16, size, 15, 700, "end"))
        body.append(chip(lx + lw - 28, ry + 23, cls, SAFETY[cls][0]))
        ry += 64

    # Barre d'action
    bx, by = 266, WH - 98
    d, m = glass("action", bx, by, WW - bx - 16, 76, 22)
    defs.append(d)
    body.append(m)
    body.append(text(bx + 24, by + 34, "Corbeille : 12 éléments · 79,6 Go", 15, 700))
    body.append(text(bx + 24, by + 55, "Le personnel part à la corbeille du Mac, le régénérable est supprimé.", 12.5, 500))
    btn_w = 214
    body.append(f'<rect x="{WW - 16 - 20 - btn_w}" y="{by + 16}" width="{btn_w}" height="44" rx="22" fill="url(#eclat)"/>')
    body.append(f'<rect x="{WW - 16 - 20 - btn_w + .75}" y="{by + 16.75}" width="{btn_w - 1.5}" height="42.5" rx="21.25" '
                f'fill="none" stroke="#FFF" stroke-opacity=".6" stroke-width="1.5"/>')
    body.append(text(WW - 16 - 20 - btn_w / 2, by + 44, "Faire le vide", 16, 750, "middle", ECLAT_TEXT))
    sb_w = 170
    sx = WW - 16 - 20 - btn_w - 14 - sb_w
    body.append(f'<rect x="{sx}" y="{by + 16}" width="{sb_w}" height="44" rx="22" fill="#FFF" opacity=".14"/>')
    body.append(f'<rect x="{sx + .75}" y="{by + 16.75}" width="{sb_w - 1.5}" height="42.5" rx="21.25" fill="none" '
                f'stroke="#FFF" stroke-opacity=".35" stroke-width="1.5"/>')
    body.append(text(sx + sb_w / 2, by + 44, "Revoir la corbeille", 14, 650, "middle"))

    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WW} {WH}" width="{WW}" height="{WH}">\n'
            f'<defs>{"".join(defs)}</defs>\n<g clip-path="url(#c-fenetre)">\n' + "\n".join(body) + "\n</g>\n"
            f'<rect x=".5" y=".5" width="{WW - 1}" height="{WH - 1}" rx="15.5" fill="none" stroke="#FFF" stroke-opacity=".18"/>\n'
            "</svg>\n")


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    for appearance in ("claire", "sombre"):
        (out / f"maquette-app-{appearance}.svg").write_text(window(appearance), encoding="utf-8")
        print(f"✓ maquette-app-{appearance}.svg")
