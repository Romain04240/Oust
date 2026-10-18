#!/usr/bin/env python3
"""Palette d'Oust! et vérification des contrastes WCAG 2.2.

Source de vérité des valeurs reportées dans IDENTITE.md.

La fenêtre principale n'a jamais de fond blanc : elle pose du verre (Liquid Glass) sur
un fond coloré propre à chaque section — le dégradé vif de la section en apparence
claire, un fond profond éclairé de halos en apparence sombre. Le texte y est blanc
dans les deux cas. Les fenêtres qui suivent le système (Réglages, alertes) gardent
les fonds de macOS.

Le script vérifie, pour chaque couple réellement utilisé :
- texte blanc sur le dégradé de section, tout du long, dans trois espaces
  d'interpolation (sRGB, sRGB linéaire, OKLab) ;
- texte blanc sur le verre posé sur ce dégradé, et sur le fond profond et ses halos ;
- segments de jauge (éléments graphiques, 3:1) sur leur piste de verre sombre ;
- classes de sécurité : texte « foncé » sur fonds clairs et pastilles teintées, texte
  blanc sur pastille pleine « foncé », texte « vif » sur fonds sombres et sur le verre
  des fonds profonds ;
- accent et couleur d'action (« Éclat »).

Modèle du verre (approximation : Liquid Glass s'adapte au contenu) : le fond reçoit un
voile noir, puis un reflet blanc. À confirmer dans l'app avec l'Inspecteur d'accessibilité.

Usage : python3 palette.py            → rapport en Markdown
        python3 palette.py --check    → code de sortie 1 si un seuil n'est pas tenu
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from icone import _gam, _lin, from_oklab, hex_to_rgb, rgb_to_hex, to_oklab  # noqa: E402

# ---------------------------------------------------------------------------
# Valeurs de référence
# ---------------------------------------------------------------------------

# Accent (AccentColor) : « clair » en apparence claire, « sombre » remplit les commandes
# en apparence sombre (libellé blanc), « texte sombre » sert au texte en apparence sombre.
# Une seule teinte ne peut pas tout faire : un libellé blanc à 4,5:1 exige une luminance
# ≤ 0,183, du texte à 4,5:1 sur fond sombre une luminance ≥ 0,292.
ACCENT = {"clair": "#CA006D", "sombre": "#E0157F", "texte sombre": "#FF6FB8"}

# Éclat : le jaune-orangé du segment chassé. Réservé à l'action de faire le vide
# (bouton principal, pulsation, compteur d'espace libéré). Texte posé dessus : ECLAT_TEXT.
ECLAT = ("#FFE45C", "#FFA51A", "#FF5A1F")
ECLAT_TEXT = "#1B0E52"

ICON_BACKGROUND = "#1B0E52"
ICON_RING = ("#FF3D8B", "#B23BFF", "#4F5BFF", "#1FD1FF")

# Section : départ, arrivée (dégradé vif, haut-gauche → bas-droite), lueur (décor et
# segments de jauge), profond (fond de l'apparence sombre).
SECTIONS = {
    "Vue d'ensemble":       ("#E0157F", "#6E3BF5", "#FF6FB8", "#1B0E52"),
    "Développement & IA":   ("#8E3CF7", "#2F5BF5", "#9E8CFF", "#0A1652"),
    "Explorateur":          ("#0A6BE0", "#007D8F", "#4FC3FF", "#002142"),
    "Doublons":             ("#00806C", "#14853A", "#3EE0A8", "#002917"),
    "Navigateurs":          ("#CC4A06", "#D3145E", "#FF8A4C", "#420018"),
    "Système":              ("#5148D6", "#334D73", "#8FA2FF", "#121E39"),
    "Historique":           ("#A35F00", "#B03F0B", "#FFB547", "#391100"),
}

# Classe de sécurité : foncé (texte sur fond clair, pastille pleine à libellé blanc),
# vif (texte et pictogramme sur fond sombre ou profond).
SAFETY = {
    "Sûr":             ("#006725", "#3DD68C"),
    "Se reconstruit":  ("#0057B3", "#5CB4FF"),
    "À examiner":      ("#963D00", "#FFB547"),
    "Protégé":         ("#563ECF", "#B3A3FF"),
    "Inaccessible":    ("#595961", "#AAAAB3"),
}

# Verre : voile noir puis reflet blanc
GLASS_VEIL, GLASS_SHEEN = 0.14, 0.06
# Halos du fond profond : départ et arrivée de la section, en mode « écran »
HALO_OPACITY = 0.45
# Piste de jauge : verre fumé (35 % de noir sur le fond, quel qu'il soit)
TRACK_SMOKE = 0.35
# Segment de jauge : de la lueur vers le départ de la section, arrêté à 15 %
GAUGE_MIX = 0.15

# Fonds de macOS 26 pour les fenêtres qui suivent le système
LIGHT_BGS = {"blanc": "#FFFFFF", "fenêtre": "#F5F5F7", "latéral": "#E8E8ED"}
DARK_BGS = {"noir": "#000000", "fenêtre": "#1E1E20", "latéral": "#2C2C30"}

AA_TEXT, AA_UI = 4.5, 3.0


# ---------------------------------------------------------------------------
# Calcul
# ---------------------------------------------------------------------------

def luminance(h: str) -> float:
    r, g, b = (_lin(v) for v in hex_to_rgb(h))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def over(fg: str, alpha: float, bg: str) -> str:
    """fg posé à l'opacité alpha sur bg (composition en sRGB, comme AppKit)."""
    f, b = hex_to_rgb(fg), hex_to_rgb(bg)
    return rgb_to_hex(tuple(x * alpha + y * (1 - alpha) for x, y in zip(f, b)))


def screen(fg: str, alpha: float, bg: str) -> str:
    """Mélange « écran » (halo lumineux) de fg à l'opacité alpha sur bg."""
    f, b = hex_to_rgb(fg), hex_to_rgb(bg)
    return rgb_to_hex(tuple(y + alpha * ((1 - (1 - x) * (1 - y)) - y) for x, y in zip(f, b)))


def glass(bg: str) -> str:
    return over("#FFFFFF", GLASS_SHEEN, over("#000000", GLASS_VEIL, bg))


def interpolate(a: str, b: str, t: float, space: str) -> str:
    ca, cb = hex_to_rgb(a), hex_to_rgb(b)
    if space == "sRGB":
        return rgb_to_hex(tuple(x + (y - x) * t for x, y in zip(ca, cb)))
    if space == "linéaire":
        la, lb = [tuple(_lin(v) for v in c) for c in (ca, cb)]
        return rgb_to_hex(tuple(_gam(x + (y - x) * t) for x, y in zip(la, lb)))
    oa, ob = to_oklab(ca), to_oklab(cb)
    return rgb_to_hex(from_oklab(tuple(x + (y - x) * t for x, y in zip(oa, ob))))


def gradient_points(a: str, b: str, steps: int = 40):
    for space in ("sRGB", "linéaire", "OKLab"):
        for i in range(steps + 1):
            yield interpolate(a, b, i / steps, space), f"{space}, t={i / steps:.2f}"


def worst_on_gradient(a: str, b: str, text: str = "#FFFFFF", surface=lambda c: c) -> tuple[float, str]:
    return min((contrast(text, surface(c)), f"{c} ({where})") for c, where in gradient_points(a, b))


def deep_points(section: str):
    """Points du fond profond : la base, puis le cœur de chaque halo."""
    start, end, _, deep = SECTIONS[section]
    return [deep, screen(start, HALO_OPACITY, deep), screen(end, HALO_OPACITY, deep)]


def gauge_colors(section: str) -> tuple[str, str]:
    start, _, glow, _ = SECTIONS[section]
    return glow, interpolate(glow, start, GAUGE_MIX, "OKLab")


def verdict(ratio: float, threshold: float = AA_TEXT) -> str:
    return "✅" if ratio >= threshold else "❌"


def fmt(r: float) -> str:
    return f"{r:.2f}".replace(".", ",")


def pct(v: float) -> str:
    return f"{v * 100:.0f} %"


# ---------------------------------------------------------------------------
# Rapport
# ---------------------------------------------------------------------------

def report() -> tuple[str, bool]:
    ok = True
    out = ["### Texte blanc sur les fonds de section", "",
           f"Verre : voile noir {pct(GLASS_VEIL)}, reflet blanc {pct(GLASS_SHEEN)}. "
           f"Halos du fond profond : départ et arrivée en mode écran à {pct(HALO_OPACITY)}.", "",
           "| Section | Dégradé vif (pire point) | Verre sur dégradé vif | Fond profond et halos "
           "| Verre sur fond profond | AA texte |",
           "|---|---:|---:|---:|---:|:---:|"]
    for name, (a, b, _, _) in SECTIONS.items():
        w1, _ = worst_on_gradient(a, b)
        w2, _ = worst_on_gradient(a, b, surface=glass)
        w3 = min(contrast("#FFFFFF", c) for c in deep_points(name))
        w4 = min(contrast("#FFFFFF", glass(c)) for c in deep_points(name))
        w = min(w1, w2, w3, w4)
        ok &= w >= AA_TEXT
        out.append(f"| {name} | {fmt(w1)} | {fmt(w2)} | {fmt(w3)} | {fmt(w4)} | {verdict(w)} |")

    out += ["", "### Segments de jauge sur leur piste (éléments graphiques, seuil 3:1)", "",
            f"Segment : dégradé de la lueur vers le départ de la section, arrêté à {pct(GAUGE_MIX)}. "
            f"Piste : {pct(TRACK_SMOKE)} de noir posé sur le verre, au pire point de chaque fond de l'app "
            "(dégradés vifs et fonds profonds avec leurs halos).", "",
            "| Section | Segment | Pire contraste avec une piste | AA graphique |", "|---|---|---:|:---:|"]
    surfaces = [glass(c) for s in SECTIONS for c in deep_points(s)]
    surfaces += [glass(c) for a, b, _, _ in SECTIONS.values() for c, _ in gradient_points(a, b, 10)]
    tracks = [over("#000000", TRACK_SMOKE, c) for c in surfaces]
    for name in SECTIONS:
        g0, g1 = gauge_colors(name)
        w = min(contrast(c, tr) for c in (g0, g1) for tr in tracks)
        ok &= w >= AA_UI
        out.append(f"| {name} | `{g0}` → `{g1}` | {fmt(w)} | {verdict(w, AA_UI)} |")

    out += ["", "### Classes de sécurité", "",
            "Fenêtre principale : pastille pleine (fond « foncé », texte et pictogramme blancs), "
            "lisible sur tous les fonds de section. Fenêtres qui suivent le système : pastille teintée "
            "(la couleur à 14 % sur le fond, texte de la même couleur), « foncé » en clair, « vif » en sombre. "
            "Le « vif » sert aussi de pictogramme seul sur le verre des fonds profonds (seuil graphique 3:1).", "",
            "| Classe | Foncé | Vif | Blanc sur pastille pleine | Foncé, fonds clairs et pastille "
            "| Vif, fonds sombres et pastille | Vif en pictogramme sur verre profond | Verdict |",
            "|---|---|---|---:|---:|---:|---:|:---:|"]
    deep_glass = [glass(c) for s in SECTIONS for c in deep_points(s)]
    for name, (dark_, vivid) in SAFETY.items():
        a = min(min(contrast(dark_, bg), contrast(dark_, over(dark_, .14, bg))) for bg in LIGHT_BGS.values())
        b = contrast("#FFFFFF", dark_)
        c = min(min(contrast(vivid, bg), contrast(vivid, over(vivid, .14, bg))) for bg in DARK_BGS.values())
        d = min(contrast(vivid, g) for g in deep_glass)
        good = min(a, b, c) >= AA_TEXT and d >= AA_UI
        ok &= good
        out.append(f"| {name} | `{dark_}` | `{vivid}` | {fmt(b)} | {fmt(a)} | {fmt(c)} | {fmt(d)} "
                   f"| {'✅' if good else '❌'} |")

    out += ["", "### Accent et Éclat", "", "| Usage | Couleurs | Rapport | Seuil | Verdict |",
            "|---|---|---:|---:|:---:|"]
    checks = [("Libellé blanc sur commande, apparence claire", "#FFFFFF", ACCENT["clair"], AA_TEXT),
              ("Libellé blanc sur commande, apparence sombre", "#FFFFFF", ACCENT["sombre"], AA_TEXT)]
    checks += [(f"Accent en texte, fond clair « {n} »", ACCENT["clair"], bg, AA_TEXT) for n, bg in LIGHT_BGS.items()]
    checks += [(f"Commande accent sur fond sombre « {n} »", ACCENT["sombre"], bg, AA_UI) for n, bg in DARK_BGS.items()]
    checks += [(f"Accent en texte, fond sombre « {n} »", ACCENT["texte sombre"], bg, AA_TEXT)
               for n, bg in DARK_BGS.items()]
    w_eclat = min(contrast(ECLAT_TEXT, c) for a, b in zip(ECLAT, ECLAT[1:]) for c, _ in gradient_points(a, b))
    checks.append(("Texte sur le bouton Éclat (pire point du dégradé)", ECLAT_TEXT, "Éclat", AA_TEXT, w_eclat))
    for check in checks:
        label, fg, bg, threshold = check[:4]
        r = check[4] if len(check) > 4 else contrast(fg, bg)
        ok &= r >= threshold
        bg_s = bg if bg.startswith("É") else f"`{bg}`"
        out.append(f"| {label} | `{fg}` sur {bg_s} | {fmt(r)} | {fmt(threshold).rstrip("0").rstrip(",")} | {verdict(r, threshold)} |")
    return "\n".join(out), ok


if __name__ == "__main__":
    text, ok = report()
    if "--check" in sys.argv:
        print("Tous les seuils AA sont tenus." if ok else "Au moins un seuil AA n'est pas tenu.")
        sys.exit(0 if ok else 1)
    print(text)
    print()
    print("Bilan :", "tous les seuils AA sont tenus." if ok else "AU MOINS UN SEUIL N'EST PAS TENU.")
