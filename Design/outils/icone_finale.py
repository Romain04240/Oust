#!/usr/bin/env python3
"""Icône finale d'Oust! (direction A « Jauge ») et monogrammes.

Produit dans le dossier Design :
- oust-icon.svg                : maître de l'icône (64 à 1024 px) ;
- oust-icon-petit.svg          : version simplifiée pour 16 et 32 px ;
- oust-monogramme.svg          : marque à plat, une seule couleur (image modèle) ;
- oust-monogramme-couleur.svg  : marque à plat, en couleurs, sans filtre ni masque ;
- Oust.icon                    : fichier Icon Composer (macOS 26), ses quatre couches et icon.json.

Les monogrammes et les couches n'utilisent que des tracés, des dégradés et des
transformations : c'est ce que CoreSVG, le moteur des catalogues d'assets de Xcode et
d'Icon Composer, sait rendre.

Usage : python3 icone_finale.py [dossier Design]
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from icone import BODY, BODY_XY, W, blur, conic, f, frame, mix, polar, sector, thin_arc  # noqa: E402

SCREEN = 'style="mix-blend-mode:screen"'

# Géométrie de la marque, partagée par l'icône, les monogrammes et la jauge de l'app
CX, CY = 488, 546
R_IN, R_OUT = 150, 276            # épaisseur = 46 % du rayon extérieur
KICK = 45                         # le segment chassé part à 45° (haut droite)
SEGMENTS = 6                      # 5 restent, 1 est chassé
PUSH, TILT = 104, 18              # éjection : distance et rotation

RING_STOPS = [(0, "#FF3D8B"), (.36, "#B23BFF"), (.7, "#4F5BFF"), (1, "#1FD1FF")]
EJECT_STOPS = [(0, "#FFE45C"), (.5, "#FFA51A"), (1, "#FF5A1F")]
ICON_BG = ("#3A1C94", "#1B0E52", "#0A0622")     # centre, milieu, bord du fond
# Halos du fond : centre, rayon, couleur et opacité, passés au flou de HALO_BLUR
BG_HALOS = ((230, 840, 300, "#FF2E93", .42), (800, 800, 260, "#2F6BFF", .42), (300, 200, 240, "#8A3BFF", .35))
HALO_BLUR = 95
# Traînées du segment chassé : décalage latéral, longueur, épaisseur, opacité
TRAILS = ((-42, 104, 13, .55), (2, 150, 17, .85), (46, 80, 11, .45))


def _op(v: float) -> str:
    return f"{v:g}".removeprefix("0")


def bounds() -> list[float]:
    step = 360 / SEGMENTS
    return [KICK - step / 2 + step * i for i in range(SEGMENTS + 1)]


def moved(k: float, push: float = PUSH, tilt: float = TILT) -> str:
    ux, uy = math.sin(math.radians(KICK)), -math.cos(math.radians(KICK))
    px, py = polar(CX, CY, (R_IN + R_OUT) / 2, KICK)
    return f"translate({f(ux * push * k)} {f(uy * push * k)}) rotate({f(tilt * k)} {f(px)} {f(py)})"


def _bg_gradient(gid: str) -> str:
    return (f'<radialGradient id="{gid}" cx="470" cy="330" r="780" gradientUnits="userSpaceOnUse">\n'
            f'      <stop offset="0" stop-color="{ICON_BG[0]}"/><stop offset=".5" stop-color="{ICON_BG[1]}"/>\n'
            f'      <stop offset="1" stop-color="{ICON_BG[2]}"/>\n    </radialGradient>')


def _trails(gid: str) -> str:
    """Les trois traînées, du bord intérieur du segment chassé vers sa place d'origine."""
    ux, uy = math.sin(math.radians(KICK)), -math.cos(math.radians(KICK))
    nx, ny = -uy, ux
    pivot, t = polar(CX, CY, (R_IN + R_OUT) / 2, KICK), R_OUT - R_IN
    out = ""
    for off, length, width, op in TRAILS:
        sx = pivot[0] + ux * (PUSH - t / 2 + 14) + nx * off
        sy = pivot[1] + uy * (PUSH - t / 2 + 14) + ny * off
        out += (f'<rect x="{f(sx)}" y="{f(sy - width / 2)}" width="{length}" height="{width}" rx="{width / 2}" '
                f'fill="url(#{gid})" opacity="{op}" transform="rotate({f(KICK + 90)} {f(sx)} {f(sy)})"/>')
    return out


# ---------------------------------------------------------------------------
# Icône
# ---------------------------------------------------------------------------

def icon(small: bool = False) -> str:
    """small : 16 et 32 px — joints élargis, segment plus écarté, ni traînée ni reflet fin."""
    gap, rc = (40, 30) if small else (18, 26)
    push = 128 if small else PUSH
    r_in, r_out = (R_IN - 12, R_OUT + 8) if small else (R_IN, R_OUT)
    t = r_out - r_in
    b = bounds()
    segs = [sector(CX, CY, r_in, r_out, a0, a1, rc, gap) for a0, a1 in zip(b, b[1:])]
    ejected, kept = segs[0], segs[1:]

    defs = f"""
    {blur("flou-halo", 30)}{blur("flou-fond", HALO_BLUR)}{blur("flou-reflet", 5)}{blur("flou-doux", 16)}{blur("flou-trainee", 2.5)}
    <clipPath id="clip-anneau">{"".join(f'<path d="{d}"/>' for d in kept)}</clipPath>
    <clipPath id="clip-seg"><path d="{ejected}"/></clipPath>
    {_bg_gradient("fond")}
    <radialGradient id="tube" cx="{CX}" cy="{CY}" r="{r_out}" gradientUnits="userSpaceOnUse">
      <stop offset="{r_in / r_out:.3f}" stop-color="#000" stop-opacity=".36"/>
      <stop offset="{(r_in + t * .3) / r_out:.3f}" stop-color="#000" stop-opacity="0"/>
      <stop offset="{(r_in + t * .72) / r_out:.3f}" stop-color="#FFF" stop-opacity=".12"/>
      <stop offset="1" stop-color="#000" stop-opacity=".20"/>
    </radialGradient>
    <linearGradient id="lumiere" x1="0" y1="{CY - r_out}" x2="0" y2="{CY + r_out}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFF" stop-opacity=".46"/><stop offset=".48" stop-color="#FFF" stop-opacity="0"/>
      <stop offset="1" stop-color="#000" stop-opacity=".16"/>
    </linearGradient>
    <linearGradient id="seg-corps" x1="0" y1="0" x2="1" y2="1">
      {"".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in EJECT_STOPS)}
    </linearGradient>
    <linearGradient id="seg-lumiere" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFF" stop-opacity=".38"/><stop offset=".45" stop-color="#FFF" stop-opacity="0"/>
      <stop offset="1" stop-color="#8A1F00" stop-opacity=".22"/>
    </linearGradient>
    <linearGradient id="trainee" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#FFE9A8" stop-opacity=".95"/><stop offset=".35" stop-color="#FFB547" stop-opacity=".55"/>
      <stop offset="1" stop-color="#FF7A1A" stop-opacity="0"/>
    </linearGradient>
    """

    halos = "".join(f'\n    <circle cx="{x}" cy="{y}" r="{r}" fill="{c}" opacity="{_op(op)}" filter="url(#flou-fond)" {SCREEN}/>'
                    for x, y, r, c, op in BG_HALOS)
    background = f"""
    <rect width="{W}" height="{W}" fill="url(#fond)"/>{halos}
    """

    trails = "" if small else f'<g filter="url(#flou-trainee)">{_trails("trainee")}</g>'

    hl = thin_arc(CX, CY, r_in + t * .76, 238, 352)
    hl_in = "" if small else (
        f'<path d="{thin_arc(CX, CY, r_in + t * .14, 110, 200)}" fill="none" stroke="#FFF" stroke-width="7" '
        f'stroke-linecap="round" opacity=".28" filter="url(#flou-reflet)"/>')
    rim = "" if small else "".join(
        f'<path d="{d}" fill="none" stroke="#FFF" stroke-opacity=".38" stroke-width="4"/>' for d in kept)
    tf = moved(1, push)

    art = f"""
    <!-- halo coloré sous l'anneau -->
    <g filter="url(#flou-halo)" opacity=".8" transform="translate(0 20)" {SCREEN}>
      <g clip-path="url(#clip-anneau)">{conic(CX, CY, r_out + 10, b[1], b[-1], RING_STOPS, 3)}</g>
    </g>
    <!-- anneau : cinq segments de verre coloré -->
    <g clip-path="url(#clip-anneau)">
      {conic(CX, CY, r_out + 10, b[1], b[-1], RING_STOPS, 1)}
      <rect width="{W}" height="{W}" fill="url(#tube)"/>
      <rect width="{W}" height="{W}" fill="url(#lumiere)"/>
      <path d="{hl}" fill="none" stroke="#FFF" stroke-width="{18 if small else 15}" stroke-linecap="round" opacity=".8"
        filter="url(#flou-reflet)"/>
      {hl_in}{rim}
    </g>
    <!-- segment chassé -->
    {trails}
    <g transform="{tf}">
      <path d="{ejected}" fill="#FF8A1A" opacity=".8" filter="url(#flou-doux)" transform="translate(0 14)" {SCREEN}/>
      <g clip-path="url(#clip-seg)">
        <path d="{ejected}" fill="url(#seg-corps)"/>
        <path d="{ejected}" fill="url(#seg-lumiere)"/>
        <rect width="{W}" height="{W}" fill="url(#tube)" opacity=".7"/>
        <path d="{thin_arc(CX, CY, r_in + t * .76, b[0] + 2, b[1] - 4)}" fill="none" stroke="#FFF"
          stroke-width="{18 if small else 15}" stroke-linecap="round" opacity=".9" filter="url(#flou-reflet)"/>
        {"" if small else f'<path d="{ejected}" fill="none" stroke="#FFF" stroke-opacity=".6" stroke-width="4"/>'}
      </g>
    </g>
    """
    return frame(defs, background, art)


# ---------------------------------------------------------------------------
# Monogrammes : la marque seule, à plat
# ---------------------------------------------------------------------------

def _mark_box(push: float) -> tuple[float, float, float]:
    """Carré englobant la marque (anneau + segment éjecté), avec 6 % de marge."""
    ux, uy = math.sin(math.radians(KICK)), -math.cos(math.radians(KICK))
    left, bottom = CX - R_OUT, CY + R_OUT
    right = CX + R_OUT * math.sin(math.radians(KICK)) + ux * push + 60
    top = CY - R_OUT * math.cos(math.radians(KICK)) + uy * push - 60
    right, top = max(right, CX + R_OUT), min(top, CY - R_OUT)
    size = max(right - left, bottom - top) * 1.12
    return (left + right) / 2 - size / 2, (top + bottom) / 2 - size / 2, size


def _ring_gradient(i: int, gid: str) -> str:
    """Dégradé linéaire du segment i (1 à 5) : sa portion du dégradé conique de l'icône,
    tendue entre ses deux extrémités. CoreSVG ne connaît pas le dégradé conique."""
    b = bounds()
    t0, t1 = (i - 1) / 5, i / 5
    p0, p1 = polar(CX, CY, (R_IN + R_OUT) / 2, b[i]), polar(CX, CY, (R_IN + R_OUT) / 2, b[i + 1])
    return (f'<linearGradient id="{gid}" x1="{f(p0[0])}" y1="{f(p0[1])}" x2="{f(p1[0])}" y2="{f(p1[1])}" '
            f'gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{mix(RING_STOPS, t0)}"/>'
            f'<stop offset="1" stop-color="{mix(RING_STOPS, t1)}"/></linearGradient>')


def _eject_gradient(gid: str) -> str:
    return (f'<linearGradient id="{gid}" x1="0" y1="0" x2="1" y2="1">'
            + "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in EJECT_STOPS) + "</linearGradient>")


def monogram(colored: bool) -> str:
    gap, rc = 22, 24
    b = bounds()
    segs = [sector(CX, CY, R_IN, R_OUT, a0, a1, rc, gap) for a0, a1 in zip(b, b[1:])]
    x, y, size = _mark_box(PUSH)
    grads, paths = "", ""
    for i, d in enumerate(segs):
        if not colored:
            fill = "#000000"
        elif i == 0:
            fill = "url(#m-eject)"
        else:
            grads += _ring_gradient(i, f"m{i}")
            fill = f"url(#m{i})"
        tf = f' transform="{moved(1)}"' if i == 0 else ""
        paths += f'<path d="{d}" fill="{fill}"{tf}/>\n'
    if colored:
        grads += _eject_gradient("m-eject")
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{f(x)} {f(y)} {f(size)} {f(size)}" '
            f'width="512" height="512">\n<defs>{grads}</defs>\n{paths}</svg>\n')


# ---------------------------------------------------------------------------
# Oust.icon : les couches d'Icon Composer (variantes claire, sombre, teintée, transparente)
# ---------------------------------------------------------------------------
#
# Icon Composer pose lui-même le verre, les reflets, l'ombre et le masque : une couche ne
# porte que ses formes et ses couleurs, sans filtre, sans masque, sans mode de fusion.
# Sa toile de 1024 px est la forme entière de l'icône, quand la grille classique loge le
# squircle dans 824 px : la marque y est agrandie de 1024 / 824 et garde sa place.

def _ic_layer(name: str, defs: str, body: str) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {W}" width="{W}" height="{W}">\n'
            f'<!-- Oust.icon, couche « {name} » : formes à plat, le verre est posé par Icon Composer -->\n'
            f'<defs>{defs}</defs>\n'
            f'<g transform="scale({W / BODY:.6f}) translate({f(-BODY_XY)} {f(-BODY_XY)})">\n{body}\n</g>\n</svg>\n')


def _halo(gid: str, cx: float, cy: float, r: float, color: str, opacity: float) -> tuple[str, str]:
    """Disque passé au flou gaussien, sans filtre : son profil (fonction d'erreur) devient
    les arrêts d'un dégradé radial. Le mode écran de l'icône classique devient un mélange
    normal, presque identique sur un fond aussi sombre."""
    sd = HALO_BLUR
    reach = r + 3 * sd
    stops = ""
    for d in (0, r - 2 * sd, r - sd, r - sd / 2, r, r + sd / 2, r + sd, r + 2 * sd, reach):
        if d < 0:
            continue
        a = 0.5 * (1 + math.erf((r - d) / (sd * math.sqrt(2))))
        stops += f'<stop offset="{d / reach:.3f}" stop-color="{color}" stop-opacity="{opacity * a:.3f}"/>'
    grad = (f'<radialGradient id="{gid}" cx="{cx}" cy="{cy}" r="{f(reach)}" gradientUnits="userSpaceOnUse">'
            f'{stops}</radialGradient>')
    return grad, f'<circle cx="{cx}" cy="{cy}" r="{f(reach)}" fill="url(#{gid})"/>'


def layer_background() -> str:
    """Le fond, ses halos et le voile clair du haut que `frame` pose sur l'icône classique :
    sans lui, le fond paraît plus sombre que celui validé."""
    halos = [_halo(f"halo{i}", x, y, r, c, op) for i, (x, y, r, c, op) in enumerate(BG_HALOS)]
    defs = (_bg_gradient("fond") + "".join(g for g, _ in halos)
            + '<linearGradient id="voile-haut" x1="0" y1="100" x2="0" y2="560" gradientUnits="userSpaceOnUse">'
              '<stop offset="0" stop-color="#FFFFFF" stop-opacity=".16"/>'
              '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>')
    body = (f'<rect width="{W}" height="{W}" fill="url(#fond)"/>\n' + "\n".join(c for _, c in halos)
            + f'\n<rect width="{W}" height="{W}" fill="url(#voile-haut)"/>')
    return _ic_layer("fond", defs, body)


def layer_ring() -> str:
    b = bounds()
    segs = [sector(CX, CY, R_IN, R_OUT, a0, a1, rc=26, gap=18) for a0, a1 in zip(b, b[1:])]
    defs = "".join(_ring_gradient(i, f"a{i}") for i in range(1, SEGMENTS))
    body = "\n".join(f'<path d="{d}" fill="url(#a{i})"/>' for i, d in enumerate(segs) if i > 0)
    return _ic_layer("anneau", defs, body)


def layer_segment() -> str:
    b = bounds()
    d = sector(CX, CY, R_IN, R_OUT, b[0], b[1], rc=26, gap=18)
    return _ic_layer("segment", _eject_gradient("eclat"), f'<path d="{d}" fill="url(#eclat)" transform="{moved(1)}"/>')


def layer_trails() -> str:
    """Les traînées ont leur propre couche, sans verre : passées au verre, elles
    deviendraient des baguettes grises au lieu de filets de lumière. Elles prennent les
    teintes de l'Éclat : sans le halo orangé de l'icône classique pour les réchauffer,
    leur jaune pâle d'origine vire au blanc."""
    defs = ('<linearGradient id="trainee" x1="0" y1="0" x2="1" y2="0">'
            f'<stop offset="0" stop-color="{EJECT_STOPS[0][1]}" stop-opacity=".95"/>'
            f'<stop offset=".4" stop-color="{EJECT_STOPS[1][1]}" stop-opacity=".6"/>'
            f'<stop offset="1" stop-color="{EJECT_STOPS[2][1]}" stop-opacity="0"/></linearGradient>')
    return _ic_layer("traînées", defs, _trails("trainee"))


def _srgb(hex_color: str) -> str:
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


# Réglages du document, au format d'Icon Composer : clés et valeurs relevées dans le modèle
# .icon de Xcode et dans IconComposerFoundation, puis passées à ictool, qui refuse une
# valeur inconnue (l'ombre colorée s'écrit « layer-color »). Les groupes vont du premier plan au
# fond ; l'apparence « tinted » sert aussi aux variantes transparentes du système. Noms en
# ASCII : actool les reprend dans Assets.car et y remplace « É » par « _ ».
ICON_JSON = {
    "fill": {"solid": _srgb(ICON_BG[2])},
    "groups": [
        {
            "name": "Segment",
            "layers": [
                {"name": "segment", "image-name": "couche-segment.svg", "glass": True},
                {"name": "trainees", "image-name": "couche-trainees.svg", "glass": False},
            ],
            "shadow": {"kind": "layer-color", "opacity": 0.8},
            "specular": True,
            "translucency": {"enabled": False, "value": 0.5},
        },
        {
            "name": "Anneau",
            "layers": [{
                "name": "anneau", "image-name": "couche-anneau.svg", "glass": True,
                "opacity-specializations": [{"appearance": "tinted", "value": 0.7}],
            }],
            "shadow": {"kind": "layer-color", "opacity": 0.7},
            "specular": True,
            "translucency": {"enabled": False, "value": 0.5},
        },
        {
            "name": "Fond",
            "layers": [{
                "name": "fond", "image-name": "couche-fond.svg", "glass": False,
                "hidden-specializations": [{"appearance": "tinted", "value": True}],
                "opacity-specializations": [{"appearance": "dark", "value": 0.35}],
            }],
            "shadow": {"kind": "none", "opacity": 0.5},
            "specular": False,
            "translucency": {"enabled": False, "value": 0.5},
        },
    ],
    "supported-platforms": {"squares": ["macOS"]},
}


def write_icon(package: Path) -> None:
    assets = package / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    layers = {"couche-fond.svg": layer_background(), "couche-anneau.svg": layer_ring(),
              "couche-segment.svg": layer_segment(), "couche-trainees.svg": layer_trails()}
    for name, svg in layers.items():
        (assets / name).write_text(svg, encoding="utf-8")
        print(f"✓ {package.name}/Assets/{name}")
    # Mise en forme des .icon d'Icon Composer : clés triées, « : » espacé.
    doc = json.dumps(ICON_JSON, indent=2, sort_keys=True, ensure_ascii=False, separators=(",", " : "))
    (package / "icon.json").write_text(doc + "\n", encoding="utf-8")
    print(f"✓ {package.name}/icon.json")


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent.parent)
    files = {"oust-icon.svg": icon(), "oust-icon-petit.svg": icon(small=True),
             "oust-monogramme.svg": monogram(colored=False), "oust-monogramme-couleur.svg": monogram(colored=True)}
    for name, svg in files.items():
        (out / name).write_text(svg, encoding="utf-8")
        print(f"✓ {name}")
    write_icon(out / "Oust.icon")
