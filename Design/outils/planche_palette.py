#!/usr/bin/env python3
"""Planche de la palette : dégradés de section avec texte blanc, pastilles de sécurité
sur fond clair et sombre, accent. Usage : python3 planche_palette.py sortie.png"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
from icone import hex_to_rgb  # noqa: E402
from palette import (ACCENT, DARK_BGS, ECLAT, ECLAT_TEXT, LIGHT_BGS, SAFETY, SECTIONS, fmt, gauge_colors,  # noqa: E402
                     glass, over, worst_on_gradient)

K = 2
FONT = "/System/Library/Fonts/SFNS.ttf"
INK, MUTED = (29, 29, 31), (110, 110, 118)


def font(size, weight=400):
    ft = ImageFont.truetype(FONT, size * K)
    ft.set_variation_by_axes([100, min(96, max(17, size)), 400, weight])
    return ft


def rgb(h):
    return tuple(round(v * 255) for v in hex_to_rgb(h))


def gradient(w, h, a, b, radius):
    """Dégradé diagonal (haut-gauche → bas-droite) interpolé en sRGB, comme SwiftUI."""
    ca, cb = rgb(a), rgb(b)
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = (x / w + y / h) / 2
            px[x, y] = tuple(round(ca[i] + (cb[i] - ca[i]) * t) for i in range(3)) + (255,)
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=radius, fill=255)
    img.putalpha(mask)
    return img


def chip(d, x, y, name, fill, text, size=15):
    f = font(size, 640)
    tw = d.textlength(name, font=f) / K
    d.rounded_rectangle((x * K, y * K, (x + tw + 48) * K, (y + 36) * K), radius=18 * K, fill=rgb(fill))
    d.ellipse(((x + 14) * K, (y + 12) * K, (x + 26) * K, (y + 24) * K), fill=rgb(text))
    d.text(((x + 34) * K, (y + 8) * K), name, font=f, fill=rgb(text))
    return tw + 48


def main(out):
    W, H = 1480, 900
    board = Image.new("RGBA", (W * K, H * K), (255, 255, 255, 255))
    d = ImageDraw.Draw(board)
    d.text((40 * K, 30 * K), "Oust! — palette", font=font(28, 700), fill=INK)
    d.text((40 * K, 70 * K), "Pas de fond blanc : chaque section pose son verre sur un dégradé vif (apparence claire) "
           "ou sur un fond profond (apparence sombre). Texte blanc ≥ 4,5:1 partout.", font=font(14), fill=MUTED)

    # Sections : dégradé vif, bandeau du fond profond, nuancier
    cw, ch, gap = 336, 150, 24
    for i, (name, (a, b, glow, deep)) in enumerate(SECTIONS.items()):
        col, row = i % 4, i // 4
        x, y = 40 + col * (cw + gap), 110 + row * (ch + 118)
        board.alpha_composite(gradient(cw * K, ch * K, a, b, 22 * K), (x * K, y * K))
        d.text(((x + 20) * K, (y + 16) * K), name, font=font(17, 640), fill="white")
        d.text(((x + 20) * K, (y + 54) * K), "128,4 Go", font=font(44, 760), fill="white")
        d.text(((x + 20) * K, (y + 114) * K), "libérables maintenant", font=font(13, 500), fill="white")
        # fond profond avec ses deux halos, et un segment de jauge en lueur
        strip = gradient(cw * K, 44 * K, deep, deep, 12 * K)
        sd = ImageDraw.Draw(strip)
        g0, g1 = gauge_colors(name)
        sd.rounded_rectangle((16 * K, 15 * K, 150 * K, 29 * K), radius=7 * K, fill=rgb(g0))
        sd.text((166 * K, 13 * K), "fond profond", font=font(12, 600), fill="white")
        board.alpha_composite(strip, (x * K, (y + ch + 8) * K))
        w = min(worst_on_gradient(a, b)[0], worst_on_gradient(a, b, surface=glass)[0])
        d.text((x * K, (y + ch + 60) * K), f"{a} → {b}", font=font(13, 600), fill=INK)
        d.text((x * K, (y + ch + 80) * K), f"profond {deep} · lueur {glow} · blanc ≥ {fmt(w)}",
               font=font(12), fill=MUTED)

    # Accent et Éclat
    ax, ay = 40 + 3 * (cw + gap), 110 + (ch + 118)
    d.text((ax * K, ay * K), "Accent et Éclat", font=font(17, 700), fill=INK)
    y0 = ay + 32
    d.rounded_rectangle((ax * K, y0 * K, (ax + cw) * K, (y0 + 150) * K), radius=14 * K,
                        fill=rgb(SECTIONS["Vue d'ensemble"][3]))
    eclat = gradient(150 * K, 40 * K, ECLAT[0], ECLAT[2], 20 * K)
    board.alpha_composite(eclat, ((ax + 16) * K, (y0 + 16) * K))
    d.text(((ax + 44) * K, (y0 + 25) * K), "Faire le vide", font=font(15, 700), fill=rgb(ECLAT_TEXT))
    d.text(((ax + 180) * K, (y0 + 18) * K), "Éclat : l'action\nde faire le vide", font=font(12, 500), fill="white")
    d.rounded_rectangle(((ax + 16) * K, (y0 + 72) * K, (ax + 132) * K, (y0 + 104) * K), radius=9 * K,
                        fill=rgb(ACCENT["sombre"]))
    d.text(((ax + 34) * K, (y0 + 79) * K), "Analyser", font=font(14, 650), fill="white")
    d.text(((ax + 146) * K, (y0 + 79) * K), "lien en accent", font=font(14, 500), fill=rgb(ACCENT["texte sombre"]))
    d.text(((ax + 16) * K, (y0 + 118) * K), f"Accent {ACCENT['clair']} · {ACCENT['sombre']} · {ACCENT['texte sombre']}",
           font=font(11), fill=(190, 186, 214))

    # Classes de sécurité
    sy = 110 + 2 * (ch + 118) + 6
    d.text((40 * K, sy * K), "Classes de sécurité", font=font(17, 700), fill=INK)
    rows = [("Fenêtre principale — pastille pleine", None, 0), ("Réglages, apparence claire", LIGHT_BGS["fenêtre"], 0),
            ("Réglages, apparence sombre", DARK_BGS["fenêtre"], 1)]
    for j, (label, bg_hex, idx) in enumerate(rows):
        py = sy + 32 + j * 66
        if bg_hex is None:
            a, b = SECTIONS["Développement & IA"][:2]
            board.alpha_composite(gradient((W - 80) * K, 58 * K, a, b, 16 * K), (40 * K, py * K))
            label_fill = "white"
        else:
            d.rounded_rectangle((40 * K, py * K, (W - 40) * K, (py + 58) * K), radius=16 * K, fill=rgb(bg_hex))
            label_fill = MUTED if idx == 0 else (170, 170, 178)
        d.text((60 * K, (py + 20) * K), label, font=font(13, 600), fill=label_fill)
        x = 330
        for name, pair in SAFETY.items():
            if bg_hex is None:
                x += chip(d, x, py + 11, name, pair[0], "#FFFFFF") + 22
            else:
                x += chip(d, x, py + 11, name, over(pair[idx], .14, bg_hex), pair[idx]) + 22
    board.convert("RGB").save(out)
    print(f"✓ {out}")


if __name__ == "__main__":
    main(sys.argv[1])
