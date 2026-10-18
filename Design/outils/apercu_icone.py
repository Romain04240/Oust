#!/usr/bin/env python3
"""Planche des variantes de Oust.icon (macOS 26) : couleur, teintée et transparente, en
apparence claire et sombre.

Les rendus viennent d'ictool, l'outil en ligne de commande d'Icon Composer : c'est le
même moteur que le système, verre, reflets et ombres compris. Ils sortent en Display P3
et sont ramenés en sRGB avant l'assemblage, comme les autres planches.

Usage : python3 apercu_icone.py [sortie.png]   (défaut : Design/planche-icone-variantes.png)
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).parent))
from planche_palette import INK, MUTED, K, font, rgb  # noqa: E402

DESIGN = Path(__file__).parent.parent
ICON = DESIGN / "Oust.icon"
SRGB = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"

COLUMNS = (("Couleur", "Default", "Dark"), ("Teintée", "TintedLight", "TintedDark"),
           ("Transparente", "ClearLight", "ClearDark"))
ROWS = (("Apparence claire", ("#ECEFF6", "#D2D8E6"), INK, MUTED),
        ("Apparence sombre", ("#26272F", "#141519"), (245, 245, 247), (160, 160, 170)))
SIZE = 300           # icône, en points de la planche
TILE_W, TILE_H, GAP = 448, 404, 24


def ictool() -> Path:
    developer = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True, check=True).stdout.strip()
    tool = Path(developer).parent / "Applications/Icon Composer.app/Contents/Executables/ictool"
    if not tool.exists():
        sys.exit(f"ictool introuvable : {tool} (Xcode 26 ou plus récent requis)")
    return tool


def render(tool: Path, rendition: str, work: Path) -> Image.Image:
    raw, srgb = work / f"{rendition}-p3.png", work / f"{rendition}.png"
    subprocess.run([str(tool), str(ICON), "--export-image", "--output-file", str(raw), "--platform", "macOS",
                    "--rendition", rendition, "--width", str(SIZE), "--height", str(SIZE), "--scale", str(K)],
                   check=True, capture_output=True)
    subprocess.run(["sips", "-m", SRGB, str(raw), "--out", str(srgb)], check=True, capture_output=True)
    return Image.open(srgb).convert("RGBA")


def tile(colors: tuple[str, str]) -> Image.Image:
    """Fond de vignette : dégradé vertical doux, coins arrondis."""
    w, h = TILE_W * K, TILE_H * K
    top, bottom = rgb(colors[0]), rgb(colors[1])
    img = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=28 * K, fill=255)
    img.putalpha(mask)
    return img


def with_shadow(icon: Image.Image) -> Image.Image:
    """Ombre portée douce, comme celle du Dock : le rendu d'ictool n'en a pas."""
    pad = 40 * K
    out = Image.new("RGBA", (icon.width + 2 * pad, icon.height + 2 * pad), (0, 0, 0, 0))
    shadow = Image.new("RGBA", out.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 92), (pad, pad + 10 * K), icon.getchannel("A"))
    out = Image.alpha_composite(out, shadow.filter(ImageFilter.GaussianBlur(14 * K)))
    out.alpha_composite(icon, (pad, pad))
    return out


def main(out: Path) -> None:
    tool = ictool()
    W = 2 * 44 + 3 * TILE_W + 2 * GAP
    H = 120 + 2 * (40 + TILE_H) + 30 + 40
    board = Image.new("RGBA", (W * K, H * K), (255, 255, 255, 255))
    d = ImageDraw.Draw(board)
    d.text((44 * K, 30 * K), "Oust! — icône macOS 26", font=font(28, 700), fill=INK)
    d.text((44 * K, 74 * K), "Oust.icon rendu par Icon Composer (ictool) : le système pose le verre, les reflets "
           "et l'ombre. Les variantes transparentes suivent les réglages « teinté ».", font=font(14), fill=MUTED)

    with tempfile.TemporaryDirectory(prefix="oust-apercu-") as tmp:
        y = 120
        for r, (row_title, colors, ink, muted) in enumerate(ROWS):
            d.text((44 * K, y * K), row_title, font=font(17, 700), fill=INK)
            y += 40
            for c, (label, *renditions) in enumerate(COLUMNS):
                x = 44 + c * (TILE_W + GAP)
                board.alpha_composite(tile(colors), (x * K, y * K))
                icon = with_shadow(render(tool, renditions[r], Path(tmp)))
                ix = (x + (TILE_W - SIZE) / 2) * K - 40 * K
                board.alpha_composite(icon, (round(ix), round((y + 26) * K - 40 * K)))
                f = font(15, 650)
                tw = d.textlength(label, font=f) / K
                d.text(((x + (TILE_W - tw) / 2) * K, (y + TILE_H - 56) * K), label, font=f, fill=ink)
                sub = renditions[r]
                fs = font(12, 500)
                sw = d.textlength(sub, font=fs) / K
                d.text(((x + (TILE_W - sw) / 2) * K, (y + TILE_H - 32) * K), sub, font=fs, fill=muted)
            y += TILE_H + 30

    board.convert("RGB").save(out, optimize=True)
    print(f"✓ {out.name} ({board.width}×{board.height} px)")


if __name__ == "__main__":
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else DESIGN / "planche-icone-variantes.png")
