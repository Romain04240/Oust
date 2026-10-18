#!/usr/bin/env python3
"""Générateur des SVG de l'icône Oust! — bibliothèque standard uniquement.

Les formes (squircle, arcs en gélule, dégradés coniques) sont calculées ici plutôt
que dessinées à la main : SVG n'a ni coin continu façon Apple ni dégradé conique,
et l'icône doit rester reproductible à l'identique.

Usage : python3 icone.py <dossier de sortie>
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

W = 1024                 # toile macOS
BODY = 824               # squircle de la grille macOS (100 px de marge)
BODY_XY = (W - BODY) / 2
BODY_RADIUS = 185.4      # rayon de la grille Apple pour 824 px


# ---------------------------------------------------------------------------
# Couleur : interpolation en OKLab, pour des transitions vives sans gris boueux
# ---------------------------------------------------------------------------

def hex_to_rgb(h: str) -> tuple[float, float, float]:
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))  # type: ignore[return-value]


def rgb_to_hex(c: tuple[float, float, float]) -> str:
    return "#" + "".join(f"{round(max(0, min(1, v)) * 255):02X}" for v in c)


def _lin(v: float) -> float:
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def _gam(v: float) -> float:
    return 12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055


def to_oklab(c):
    r, g, b = (_lin(v) for v in c)
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (math.copysign(abs(v) ** (1 / 3), v) for v in (l, m, s))
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def from_oklab(c):
    L, a, b = c
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return tuple(_gam(max(0.0, min(1.0, v))) for v in (r, g, bb))


def mix(stops: list[tuple[float, str]], t: float) -> str:
    """Couleur à la position t (0…1) d'une suite d'arrêts, interpolée en OKLab."""
    t = max(0.0, min(1.0, t))
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t <= t1:
            k = 0 if t1 == t0 else (t - t0) / (t1 - t0)
            a, b = to_oklab(hex_to_rgb(c0)), to_oklab(hex_to_rgb(c1))
            return rgb_to_hex(from_oklab(tuple(x + (y - x) * k for x, y in zip(a, b))))
    return stops[-1][1]


# ---------------------------------------------------------------------------
# Géométrie
# ---------------------------------------------------------------------------

def f(v: float) -> str:
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def squircle(x: float, y: float, size: float, r: float) -> str:
    """Rectangle à coins continus (courbure façon Apple), d'après la courbe d'iOS 7."""
    # Points d'un coin, en multiples de r, mesurés depuis l'angle vers l'intérieur :
    # (u le long du premier bord, v le long du second).
    seg = [
        ((1.08849323, 0), (0.86840689, 0), (0.63149399, 0.07491100)),
        ((0.37282392, 0.16905899), (0.16905899, 0.37282392), (0.07491100, 0.63149399)),
        ((0, 0.86840689), (0, 1.08849323), (0, 1.52866483)),
    ]
    k = 1.52866483
    x0, y0, x1, y1 = x, y, x + size, y + size

    def corner(cx, cy, du, dv):
        # du : direction le long du bord qu'on quitte ; dv : direction du bord suivant
        out = []
        for c1, c2, p in seg:
            pts = []
            for u, v in (c1, c2, p):
                pts.append((cx - du[0] * u * r + dv[0] * v * r, cy - du[1] * u * r + dv[1] * v * r))
            out.append("C" + " ".join(f"{f(a)} {f(b)}" for a, b in pts))
        return " ".join(out)

    d = [f"M{f(x0 + k * r)} {f(y0)}", f"L{f(x1 - k * r)} {f(y0)}",
         corner(x1, y0, (1, 0), (0, 1)), f"L{f(x1)} {f(y1 - k * r)}",
         corner(x1, y1, (0, 1), (-1, 0)), f"L{f(x0 + k * r)} {f(y1)}",
         corner(x0, y1, (-1, 0), (0, -1)), f"L{f(x0)} {f(y0 + k * r)}",
         corner(x0, y0, (0, -1), (1, 0)), "Z"]
    return " ".join(d)


def polar(cx: float, cy: float, r: float, deg: float) -> tuple[float, float]:
    """Angle en degrés, sens horaire depuis midi (convention d'une jauge)."""
    a = math.radians(deg)
    return cx + r * math.sin(a), cy - r * math.cos(a)


def capsule_arc(cx, cy, rm, t, a0, a1) -> str:
    """Arc épais de a0 à a1 (horaire) terminé par deux bouts ronds, en forme pleine."""
    ro, ri, rc = rm + t / 2, rm - t / 2, t / 2
    large = 1 if (a1 - a0) % 360 > 180 else 0
    p0o, p1o = polar(cx, cy, ro, a0), polar(cx, cy, ro, a1)
    p1i, p0i = polar(cx, cy, ri, a1), polar(cx, cy, ri, a0)
    return (f"M{f(p0o[0])} {f(p0o[1])} A{f(ro)} {f(ro)} 0 {large} 1 {f(p1o[0])} {f(p1o[1])} "
            f"A{f(rc)} {f(rc)} 0 0 1 {f(p1i[0])} {f(p1i[1])} "
            f"A{f(ri)} {f(ri)} 0 {large} 0 {f(p0i[0])} {f(p0i[1])} "
            f"A{f(rc)} {f(rc)} 0 0 1 {f(p0o[0])} {f(p0o[1])} Z")


def sector(cx, cy, r_in, r_out, a0, a1, rc, gap) -> str:
    """Secteur d'anneau à coins arrondis, séparé de ses voisins par un joint de largeur
    constante (et non un coin radial, qui s'élargirait vers l'extérieur)."""
    o = gap / 2

    def unit(deg):
        a = math.radians(deg)
        return math.sin(a), -math.cos(a)

    def corner(edge_deg, side, radius, outer):
        # side = +1 : bord de départ (l'intérieur du secteur est dans le sens horaire)
        d = radius - rc if outer else radius + rc
        delta = math.degrees(math.asin((rc + o) / d)) * side
        ux, uy = unit(edge_deg)
        nx, ny = -uy * side, ux * side                       # normale vers l'intérieur
        s = d * math.cos(math.radians(delta))
        on_edge = (cx + s * ux + o * nx, cy + s * uy + o * ny)
        on_arc = polar(cx, cy, radius, edge_deg + delta)
        return on_edge, on_arc

    s_out_e, s_out_a = corner(a0, +1, r_out, True)
    e_out_e, e_out_a = corner(a1, -1, r_out, True)
    e_in_e, e_in_a = corner(a1, -1, r_in, False)
    s_in_e, s_in_a = corner(a0, +1, r_in, False)
    large = 1 if (a1 - a0) > 180 else 0
    P = lambda p: f"{f(p[0])} {f(p[1])}"  # noqa: E731
    return (f"M{P(s_out_e)} A{f(rc)} {f(rc)} 0 0 1 {P(s_out_a)} "
            f"A{f(r_out)} {f(r_out)} 0 {large} 1 {P(e_out_a)} "
            f"A{f(rc)} {f(rc)} 0 0 1 {P(e_out_e)} L{P(e_in_e)} "
            f"A{f(rc)} {f(rc)} 0 0 1 {P(e_in_a)} "
            f"A{f(r_in)} {f(r_in)} 0 {large} 0 {P(s_in_a)} "
            f"A{f(rc)} {f(rc)} 0 0 1 {P(s_in_e)} Z")


def thin_arc(cx, cy, r, a0, a1) -> str:
    large = 1 if (a1 - a0) % 360 > 180 else 0
    p0, p1 = polar(cx, cy, r, a0), polar(cx, cy, r, a1)
    return f"M{f(p0[0])} {f(p0[1])} A{f(r)} {f(r)} 0 {large} 1 {f(p1[0])} {f(p1[1])}"


def conic(cx, cy, radius, a0, a1, stops, step=1.0) -> str:
    """Dégradé conique simulé par des coins fins qui se chevauchent d'un demi-degré."""
    parts = []
    span = a1 - a0
    n = max(1, math.ceil(span / step))
    for i in range(n):
        s = a0 + span * i / n
        e = a0 + span * (i + 1) / n + 0.6
        t = (i + 0.5) / n
        p0, p1 = polar(cx, cy, radius, s), polar(cx, cy, radius, e)
        parts.append(f'<path d="M{f(cx)} {f(cy)} L{f(p0[0])} {f(p0[1])} '
                     f'A{f(radius)} {f(radius)} 0 0 1 {f(p1[0])} {f(p1[1])} Z" fill="{mix(stops, t)}"/>')
    return "\n".join(parts)


def rounded_square(cx, cy, size, rot, rr=None) -> str:
    rr = size * 0.26 if rr is None else rr
    h = size / 2
    return (f'<rect x="{f(cx - h)}" y="{f(cy - h)}" width="{f(size)}" height="{f(size)}" '
            f'rx="{f(rr)}" transform="rotate({f(rot)} {f(cx)} {f(cy)})"')


def swoosh_outline(points, widths) -> str:
    """Contour plein d'un trait d'épaisseur variable (pinceau), bout de départ arrondi."""
    left, right = [], []
    n = len(points)
    for i, ((x, y), w) in enumerate(zip(points, widths)):
        xa, ya = points[max(0, i - 1)]
        xb, yb = points[min(n - 1, i + 1)]
        dx, dy = xb - xa, yb - ya
        L = math.hypot(dx, dy) or 1
        nx, ny = -dy / L, dx / L
        left.append((x + nx * w / 2, y + ny * w / 2))
        right.append((x - nx * w / 2, y - ny * w / 2))
    w0 = widths[0] / 2
    d = [f"M{f(right[0][0])} {f(right[0][1])}",
         f"A{f(w0)} {f(w0)} 0 0 1 {f(left[0][0])} {f(left[0][1])}"]
    d += [f"L{f(x)} {f(y)}" for x, y in left[1:]]
    we = max(widths[-1] / 2, 0.5)
    d.append(f"A{f(we)} {f(we)} 0 0 1 {f(right[-1][0])} {f(right[-1][1])}")
    d += [f"L{f(x)} {f(y)}" for x, y in reversed(right[:-1])]
    d.append("Z")
    return " ".join(d)


# ---------------------------------------------------------------------------
# Socle commun : squircle, ombre portée, liseré de verre
# ---------------------------------------------------------------------------

SQ = squircle(BODY_XY, BODY_XY, BODY, BODY_RADIUS)

COMMON_DEFS = f"""
<path id="forme" d="{SQ}"/>
<clipPath id="dans-forme"><use href="#forme"/></clipPath>
<filter id="ombre-icone" x="0" y="0" width="{W}" height="{W}" filterUnits="userSpaceOnUse">
  <feGaussianBlur stdDeviation="9"/>
</filter>
<linearGradient id="lisere" x1="200" y1="100" x2="824" y2="924" gradientUnits="userSpaceOnUse">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity=".62"/>
  <stop offset=".32" stop-color="#FFFFFF" stop-opacity=".10"/>
  <stop offset=".7" stop-color="#FFFFFF" stop-opacity=".04"/>
  <stop offset="1" stop-color="#FFFFFF" stop-opacity=".30"/>
</linearGradient>
<linearGradient id="voile-haut" x1="0" y1="100" x2="0" y2="560" gradientUnits="userSpaceOnUse">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity=".16"/>
  <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
"""


def blur(fid: str, sd: float) -> str:
    return (f'<filter id="{fid}" x="-200" y="-200" width="{W + 400}" height="{W + 400}" '
            f'filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">'
            f'<feGaussianBlur stdDeviation="{sd}"/></filter>')


def frame(defs: str, background: str, art: str, shadow=True) -> str:
    """Assemble l'icône : ombre, fond découpé, motif, voile et liseré de verre."""
    ombre = (f'<use href="#forme" fill="#000" opacity=".30" transform="translate(0 10)" '
             f'filter="url(#ombre-icone)"/>') if shadow else ""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {W}" width="{W}" height="{W}">
<defs>{COMMON_DEFS}{defs}</defs>
{ombre}
<g clip-path="url(#dans-forme)">
{background}
{art}
<use href="#forme" fill="url(#voile-haut)"/>
</g>
<use href="#forme" fill="none" stroke="url(#lisere)" stroke-width="5" clip-path="url(#dans-forme)"/>
</svg>
"""
