#!/usr/bin/env python3
"""Les trois directions d'icône proposées à Romain : A Jauge, B « O! », C Blocs."""

from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from icone import (W, blur, conic, f, frame, mix, polar, rounded_square,  # noqa: E402
                   sector, swoosh_outline, thin_arc)

SCREEN = 'style="mix-blend-mode:screen"'


# ---------------------------------------------------------------------------
# A — Jauge : le O est la jauge du disque ; un segment en est chassé
# ---------------------------------------------------------------------------

def direction_jauge() -> str:
    cx, cy = 488, 546
    r_in, r_out = 150, 276
    rm, t = (r_in + r_out) / 2, r_out - r_in
    gap, rc = 18, 26
    kick = 45                                   # le segment chassé part en haut à droite
    bounds = [kick - 30 + 60 * i for i in range(7)]
    segs = [sector(cx, cy, r_in, r_out, a, b, rc, gap) for a, b in zip(bounds, bounds[1:])]
    ejected, kept = segs[0], segs[1:]
    push, tilt = 104, 18
    ux, uy = math.sin(math.radians(kick)), -math.cos(math.radians(kick))
    pivot = polar(cx, cy, rm, kick)

    ring_stops = [(0, "#FF3D8B"), (.36, "#B23BFF"), (.7, "#4F5BFF"), (1, "#1FD1FF")]

    defs = f"""
    {blur("flou-halo", 30)}{blur("flou-fond", 95)}{blur("flou-reflet", 5)}{blur("flou-doux", 16)}{blur("flou-fantome", 7)}
    <clipPath id="clip-anneau">{"".join(f'<path d="{d}"/>' for d in kept)}</clipPath>
    <clipPath id="clip-seg"><path d="{ejected}"/></clipPath>
    <radialGradient id="fond-a" cx="470" cy="330" r="780" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#3A1C94"/><stop offset=".5" stop-color="#1B0E52"/>
      <stop offset="1" stop-color="#0A0622"/>
    </radialGradient>
    <radialGradient id="tube" cx="{cx}" cy="{cy}" r="{r_out}" gradientUnits="userSpaceOnUse">
      <stop offset="{r_in / r_out:.3f}" stop-color="#000" stop-opacity=".36"/>
      <stop offset="{(r_in + t * .3) / r_out:.3f}" stop-color="#000" stop-opacity="0"/>
      <stop offset="{(r_in + t * .72) / r_out:.3f}" stop-color="#FFF" stop-opacity=".12"/>
      <stop offset="1" stop-color="#000" stop-opacity=".20"/>
    </radialGradient>
    <linearGradient id="lumiere" x1="0" y1="{cy - r_out}" x2="0" y2="{cy + r_out}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFF" stop-opacity=".46"/><stop offset=".48" stop-color="#FFF" stop-opacity="0"/>
      <stop offset="1" stop-color="#000" stop-opacity=".16"/>
    </linearGradient>
    <linearGradient id="seg-corps" x1="0" y1="1" x2="1" y2="0">
      <stop offset="0" stop-color="#FFE45C"/><stop offset=".55" stop-color="#FFB21A"/><stop offset="1" stop-color="#FF6A1A"/>
    </linearGradient>
    <linearGradient id="trainee" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#FFF" stop-opacity=".85"/><stop offset="1" stop-color="#FFF" stop-opacity="0"/>
    </linearGradient>
    """

    background = f"""
    <rect width="{W}" height="{W}" fill="url(#fond-a)"/>
    <circle cx="230" cy="840" r="300" fill="#FF2E93" opacity=".42" filter="url(#flou-fond)" {SCREEN}/>
    <circle cx="800" cy="800" r="260" fill="#2F6BFF" opacity=".42" filter="url(#flou-fond)" {SCREEN}/>
    <circle cx="300" cy="200" r="240" fill="#8A3BFF" opacity=".35" filter="url(#flou-fond)" {SCREEN}/>
    """

    def moved(k: float) -> str:
        return (f"translate({f(ux * push * k)} {f(uy * push * k)}) "
                f"rotate({f(tilt * k)} {f(pivot[0])} {f(pivot[1])})")

    # Traînées : du bord intérieur du segment éjecté vers sa place d'origine
    trails = []
    nx, ny = -uy, ux
    for off, length, width, op in ((-38, 92, 9, .40), (4, 136, 11, .70), (44, 70, 8, .30)):
        sx = pivot[0] + ux * (push - t / 2 + 4) + nx * off
        sy = pivot[1] + uy * (push - t / 2 + 4) + ny * off
        trails.append(f'<rect x="{f(sx)}" y="{f(sy - width / 2)}" width="{length}" height="{width}" rx="{width / 2}" '
                      f'fill="url(#trainee)" opacity="{op}" transform="rotate({f(kick + 90)} {f(sx)} {f(sy)})"/>')

    hl = thin_arc(cx, cy, r_in + t * .76, 238, 352)
    hl_in = thin_arc(cx, cy, r_in + t * .14, 110, 200)

    art = f"""
    <!-- halo coloré sous l'anneau -->
    <g filter="url(#flou-halo)" opacity=".8" transform="translate(0 20)" {SCREEN}>
      <g clip-path="url(#clip-anneau)">{conic(cx, cy, r_out + 10, bounds[1], bounds[-1], ring_stops, 3)}</g>
    </g>
    <!-- anneau : cinq segments de verre coloré -->
    <g clip-path="url(#clip-anneau)">
      {conic(cx, cy, r_out + 10, bounds[1], bounds[-1], ring_stops, 1)}
      <rect width="{W}" height="{W}" fill="url(#tube)"/>
      <rect width="{W}" height="{W}" fill="url(#lumiere)"/>
      <path d="{hl}" fill="none" stroke="#FFF" stroke-width="15" stroke-linecap="round" opacity=".8" filter="url(#flou-reflet)"/>
      <path d="{hl_in}" fill="none" stroke="#FFF" stroke-width="7" stroke-linecap="round" opacity=".28" filter="url(#flou-reflet)"/>
      {"".join(f'<path d="{d}" fill="none" stroke="#FFF" stroke-opacity=".38" stroke-width="4"/>' for d in kept)}
    </g>
    <!-- segment chassé : traînées, fantômes, puis le segment -->
    <path d="{ejected}" fill="url(#seg-corps)" opacity=".14" transform="{moved(.3)}" filter="url(#flou-fantome)"/>
    <path d="{ejected}" fill="url(#seg-corps)" opacity=".28" transform="{moved(.64)}" filter="url(#flou-fantome)"/>
    {"".join(trails)}
    <g transform="{moved(1)}">
      <path d="{ejected}" fill="#FF8A1A" opacity=".75" filter="url(#flou-doux)" transform="translate(0 14)" {SCREEN}/>
      <g clip-path="url(#clip-seg)">
        <path d="{ejected}" fill="url(#seg-corps)"/>
        <rect width="{W}" height="{W}" fill="url(#tube)"/>
        <rect x="-200" y="-200" width="{W + 400}" height="{W + 400}" fill="url(#lumiere)"/>
        <path d="{thin_arc(cx, cy, r_in + t * .76, bounds[0] + 2, bounds[1] - 4)}" fill="none" stroke="#FFF" stroke-width="15"
          stroke-linecap="round" opacity=".85" filter="url(#flou-reflet)"/>
        <path d="{ejected}" fill="none" stroke="#FFF" stroke-opacity=".55" stroke-width="4"/>
      </g>
    </g>
    """
    return frame(defs, background, art)


# ---------------------------------------------------------------------------
# B — « O! » : le monogramme du nom, un O de verre givré et un point d'exclamation vif
# ---------------------------------------------------------------------------

def direction_bang() -> str:
    ocx, ocy, r_out, r_in = 410, 548, 236, 122
    ring = (f"M{ocx - r_out} {ocy} a{r_out} {r_out} 0 1 0 {2 * r_out} 0 a{r_out} {r_out} 0 1 0 {-2 * r_out} 0 Z "
            f"M{ocx - r_in} {ocy} a{r_in} {r_in} 0 1 1 {2 * r_in} 0 a{r_in} {r_in} 0 1 1 {-2 * r_in} 0 Z")
    bx, bw, b_top, b_bot = 752, 104, 326, 636
    dot_cy, dot_r = 730, 58
    lean = 7                                            # le « ! » penche, il a de l'élan
    bar = f'<rect x="{bx - bw / 2}" y="{b_top}" width="{bw}" height="{b_bot - b_top}" rx="{bw / 2}"/>'
    dot = f'<circle cx="{bx}" cy="{dot_cy}" r="{dot_r}"/>'
    bang_tf = f'rotate({lean} {bx} {dot_cy})'

    defs = f"""
    {blur("flou-fond-b", 80)}{blur("flou-ombre-b", 18)}{blur("flou-bord", 10)}{blur("flou-givre", 24)}{blur("flou-reflet-b", 6)}
    <linearGradient id="fond-b" x1="140" y1="90" x2="900" y2="960" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FF7A3D"/><stop offset=".38" stop-color="#FF2E7E"/>
      <stop offset=".76" stop-color="#9C2BFF"/><stop offset="1" stop-color="#5B1FE6"/>
    </linearGradient>
    <clipPath id="clip-o"><path d="{ring}" clip-rule="evenodd"/></clipPath>
    <clipPath id="clip-bang">{bar.replace("/>", f' transform="{bang_tf}"/>')}{dot.replace("/>", f' transform="{bang_tf}"/>')}</clipPath>
    <linearGradient id="verre-b" x1="200" y1="300" x2="640" y2="800" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFF" stop-opacity=".80"/><stop offset=".55" stop-color="#FFF" stop-opacity=".40"/>
      <stop offset="1" stop-color="#FFF" stop-opacity=".30"/>
    </linearGradient>
    <linearGradient id="rim-b" x1="180" y1="300" x2="660" y2="800" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFF"/><stop offset=".55" stop-color="#FFF" stop-opacity=".35"/>
      <stop offset="1" stop-color="#FFF" stop-opacity=".8"/>
    </linearGradient>
    <linearGradient id="bang-corps" x1="0" y1="{b_top}" x2="0" y2="{dot_cy + dot_r}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFF06B"/><stop offset=".5" stop-color="#FFC21A"/><stop offset="1" stop-color="#FF7A1A"/>
    </linearGradient>
    <linearGradient id="bang-lum" x1="{bx - bw / 2}" y1="0" x2="{bx + bw / 2}" y2="0" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFF" stop-opacity=".0"/><stop offset=".3" stop-color="#FFF" stop-opacity=".45"/>
      <stop offset=".55" stop-color="#FFF" stop-opacity="0"/><stop offset="1" stop-color="#B0400A" stop-opacity=".25"/>
    </linearGradient>
    """
    background = f"""
    <rect width="{W}" height="{W}" fill="url(#fond-b)"/>
    <circle cx="220" cy="180" r="250" fill="#FFC14D" opacity=".55" filter="url(#flou-fond-b)"/>
    <circle cx="850" cy="880" r="300" fill="#3A1CFF" opacity=".55" filter="url(#flou-fond-b)"/>
    """
    art = f"""
    <path d="{ring}" fill-rule="evenodd" fill="#4A0B7A" opacity=".36" filter="url(#flou-ombre-b)" transform="translate(0 22)"/>
    <g clip-path="url(#clip-o)">
      <rect width="{W}" height="{W}" fill="url(#fond-b)" filter="url(#flou-givre)"/>
      <path d="{ring}" fill-rule="evenodd" fill="url(#verre-b)"/>
      <path d="{ring}" fill="none" stroke="#FFF" stroke-width="40" opacity=".55" filter="url(#flou-bord)"/>
      <path d="{ring}" fill="none" stroke="url(#rim-b)" stroke-width="5"/>
      <path d="{thin_arc(ocx, ocy, (r_in + r_out) / 2 + 30, 250, 330)}" fill="none" stroke="#FFF" stroke-width="14"
        stroke-linecap="round" opacity=".7" filter="url(#flou-reflet-b)"/>
    </g>
    <g transform="{bang_tf}">
      <g transform="translate(0 20)" opacity=".7">{bar.replace("/>", ' fill="#FF6A1A" filter="url(#flou-ombre-b)"/>')}
        {dot.replace("/>", ' fill="#FF6A1A" filter="url(#flou-ombre-b)"/>')}</g>
    </g>
    <g clip-path="url(#clip-bang)">
      <g transform="{bang_tf}">
        <rect width="{W}" height="{W}" fill="url(#bang-corps)"/>
        <rect width="{W}" height="{W}" fill="url(#bang-lum)"/>
        <rect x="{bx - bw / 2 + 22}" y="{b_top + 26}" width="18" height="{b_bot - b_top - 70}" rx="9" fill="#FFF" opacity=".75"
          filter="url(#flou-reflet-b)"/>
        <circle cx="{bx - 18}" cy="{dot_cy - 22}" r="14" fill="#FFF" opacity=".7" filter="url(#flou-reflet-b)"/>
        {bar.replace("/>", ' fill="none" stroke="#FFF" stroke-opacity=".7" stroke-width="5"/>')}
        {dot.replace("/>", ' fill="none" stroke="#FFF" stroke-opacity=".7" stroke-width="5"/>')}
      </g>
    </g>
    """
    return frame(defs, background, art)


# ---------------------------------------------------------------------------
# C — Blocs : un O fait de blocs du disque ; un bloc est chassé
# ---------------------------------------------------------------------------

def rounded_rect(x, y, w, h, radii) -> str:
    """Rectangle aux quatre rayons indépendants (haut-gauche, haut-droit, bas-droit, bas-gauche)."""
    tl, tr, br, bl = radii
    return (f"M{f(x + tl)} {f(y)} H{f(x + w - tr)} A{f(tr)} {f(tr)} 0 0 1 {f(x + w)} {f(y + tr)} "
            f"V{f(y + h - br)} A{f(br)} {f(br)} 0 0 1 {f(x + w - br)} {f(y + h)} "
            f"H{f(x + bl)} A{f(bl)} {f(bl)} 0 0 1 {f(x)} {f(y + h - bl)} "
            f"V{f(y + tl)} A{f(tl)} {f(tl)} 0 0 1 {f(x + tl)} {f(y)} Z")


def direction_blocs() -> str:
    tile, gap, small, big = 124, 16, 24, 112
    span = 4 * tile + 3 * gap
    ox, oy = 512 - span / 2 - 22, 512 - span / 2 + 30
    corners = {(0, 0): 0, (3, 0): 1, (3, 3): 2, (0, 3): 3}
    cells = [(c, r) for r in range(4) for c in range(4) if c in (0, 3) or r in (0, 3)]
    kicked = (3, 0)

    def shape(c, r):
        radii = [small] * 4
        if (c, r) in corners:
            radii[corners[(c, r)]] = big
        return rounded_rect(ox + c * (tile + gap), oy + r * (tile + gap), tile, tile, radii)

    kept = [shape(c, r) for c, r in cells if (c, r) != kicked]
    kd = shape(*kicked)
    kx, ky = ox + kicked[0] * (tile + gap), oy + kicked[1] * (tile + gap)
    mx, my, rot = 96, -112, 16
    pc = (kx + tile / 2, ky + tile / 2)

    def moved(k):
        return f"translate({f(mx * k)} {f(my * k)}) rotate({f(rot * k)} {f(pc[0])} {f(pc[1])})"

    defs = f"""
    {blur("flou-fond-c", 90)}{blur("flou-tuile", 14)}{blur("flou-fantome-c", 6)}{blur("flou-reflet-c", 4)}
    {blur("flou-givre-c", 22)}{blur("flou-bord-c", 8)}
    <linearGradient id="fond-c" x1="160" y1="100" x2="880" y2="940" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#16E0C0"/><stop offset=".45" stop-color="#12A8FF"/>
      <stop offset="1" stop-color="#3F3BF0"/>
    </linearGradient>
    <clipPath id="clip-blocs">{"".join(f'<path d="{d}"/>' for d in kept)}</clipPath>
    <clipPath id="clip-chasse"><path d="{kd}"/></clipPath>
    <linearGradient id="verre-c" x1="0" y1="{oy}" x2="0" y2="{oy + span}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFF" stop-opacity=".82"/><stop offset=".55" stop-color="#FFF" stop-opacity=".46"/>
      <stop offset="1" stop-color="#FFF" stop-opacity=".34"/>
    </linearGradient>
    <linearGradient id="tuile-chassee" x1="0" y1="1" x2="1" y2="0">
      <stop offset="0" stop-color="#FFE45C"/><stop offset=".6" stop-color="#FFB21A"/><stop offset="1" stop-color="#FF6A1A"/>
    </linearGradient>
    <linearGradient id="tuile-lum" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFF" stop-opacity=".5"/><stop offset=".5" stop-color="#FFF" stop-opacity="0"/>
      <stop offset="1" stop-color="#9A3A00" stop-opacity=".18"/>
    </linearGradient>
    """
    gloss = " ".join(f"M{f(ox + c * (tile + gap) + 20)} {f(oy + r * (tile + gap) + 16)} h{tile - 40}"
                     for c, r in cells if (c, r) != kicked)
    art = f"""
    <g transform="translate(0 18)" opacity=".35">
      <g clip-path="url(#clip-blocs)" filter="url(#flou-tuile)"><rect width="{W}" height="{W}" fill="#1A1A8C"/></g>
    </g>
    <g clip-path="url(#clip-blocs)">
      <rect width="{W}" height="{W}" fill="url(#fond-c)" filter="url(#flou-givre-c)"/>
      <rect width="{W}" height="{W}" fill="url(#verre-c)"/>
      {"".join(f'<path d="{d}" fill="none" stroke="#FFF" stroke-width="30" opacity=".5" filter="url(#flou-bord-c)"/>' for d in kept)}
      <path d="{gloss}" stroke="#FFF" stroke-width="9" stroke-linecap="round" opacity=".7" filter="url(#flou-reflet-c)"/>
      {"".join(f'<path d="{d}" fill="none" stroke="#FFF" stroke-opacity=".85" stroke-width="4"/>' for d in kept)}
    </g>
    <path d="{kd}" fill="#FFE45C" opacity=".22" transform="{moved(.3)}" filter="url(#flou-fantome-c)"/>
    <path d="{kd}" fill="#FFC21A" opacity=".40" transform="{moved(.62)}" filter="url(#flou-fantome-c)"/>
    <g transform="{moved(1)}">
      <path d="{kd}" fill="#FF7A1A" opacity=".55" filter="url(#flou-tuile)" transform="translate(0 16)"/>
      <g clip-path="url(#clip-chasse)">
        <path d="{kd}" fill="url(#tuile-chassee)"/>
        <path d="{kd}" fill="url(#tuile-lum)"/>
        <path d="M{f(kx + 20)} {f(ky + 16)} h{tile - 40}" stroke="#FFF" stroke-width="10" stroke-linecap="round" opacity=".8"
          filter="url(#flou-reflet-c)"/>
        <path d="{kd}" fill="none" stroke="#FFF" stroke-opacity=".75" stroke-width="5"/>
      </g>
    </g>
    """
    background = f"""
    <rect width="{W}" height="{W}" fill="url(#fond-c)"/>
    <circle cx="200" cy="180" r="240" fill="#A8FFE8" opacity=".45" filter="url(#flou-fond-c)"/>
    <circle cx="860" cy="880" r="280" fill="#7A2BFF" opacity=".50" filter="url(#flou-fond-c)"/>
    """
    return frame(defs, background, art)


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in (("A-jauge", direction_jauge), ("B-bang", direction_bang), ("C-blocs", direction_blocs)):
        (out / f"oust-{name}.svg").write_text(fn(), encoding="utf-8")
        print(f"✓ oust-{name}.svg")
