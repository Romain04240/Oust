#!/usr/bin/env python3
"""Planche comparative des directions : grande taille, puis 128 à 16 px sur fond clair et sombre.

Usage : python3 planche.py sortie.png dossier_des_rendus "Titre|Sous-titre|prefixe" […]
Les rendus attendus s'appellent <prefixe>-<taille>.png (tailles 1024, 128, 64, 32, 16).
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

K = 2                                   # planche en @2x
FONT = "/System/Library/Fonts/SFNS.ttf"
LIGHT, DARK = (245, 245, 247), (30, 30, 34)
INK, MUTED = (29, 29, 31), (110, 110, 118)


def font(size: int, weight: int = 400) -> ImageFont.FreeTypeFont:
    ft = ImageFont.truetype(FONT, size * K)
    try:
        # Axes de SF Pro : largeur, taille optique, grade, graisse
        ft.set_variation_by_axes([100, min(96, max(17, size)), 400, weight])
    except Exception:  # police non variable : on garde la graisse par défaut
        pass
    return ft


def main() -> None:
    out, folder, *specs = sys.argv[1:]
    folder = Path(folder)
    col_w, big, pad = 440, 360, 40
    width = pad + len(specs) * (col_w + pad)
    height = 900
    board = Image.new("RGBA", (width * K, height * K), (255, 255, 255, 255))
    d = ImageDraw.Draw(board)

    for i, spec in enumerate(specs):
        title, subtitle, prefix = spec.split("|")
        x0 = pad + i * (col_w + pad)
        d.text((x0 * K, 34 * K), title, font=font(26, 700), fill=INK)
        y = 74
        for line in subtitle.split("\\n"):
            d.text((x0 * K, y * K), line, font=font(14), fill=MUTED)
            y += 20
        # grande taille sur fond clair
        panel_y = 140
        d.rounded_rectangle((x0 * K, panel_y * K, (x0 + col_w) * K, (panel_y + 400) * K), radius=18 * K, fill=LIGHT)
        im = Image.open(folder / f"{prefix}-1024.png").resize((big * K, big * K), Image.LANCZOS)
        board.alpha_composite(im, ((x0 + (col_w - big) // 2) * K, (panel_y + 20) * K))
        # petites tailles, fond clair puis sombre
        for j, bg in enumerate((LIGHT, DARK)):
            py = panel_y + 420 + j * 170
            d.rounded_rectangle((x0 * K, py * K, (x0 + col_w) * K, (py + 150) * K), radius=18 * K, fill=bg)
            cx = x0 + 22
            for size in (128, 64, 32, 16):
                im = Image.open(folder / f"{prefix}-{size}.png")
                # chaque taille est montrée à sa vraie résolution (@1x), agrandie sans lissage en @2x
                im = im.resize((size * K, size * K), Image.NEAREST)
                board.alpha_composite(im, (cx * K, (py + 75 - size // 2) * K))
                d.text((cx * K, (py + 132) * K), f"{size}", font=font(11), fill=MUTED if j == 0 else (170, 170, 178))
                cx += size + 34
    board.convert("RGB").save(out)
    print(f"✓ {out}")


if __name__ == "__main__":
    main()
