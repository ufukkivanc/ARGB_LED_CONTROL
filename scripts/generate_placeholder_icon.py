#!/usr/bin/env python
"""GEÇİCİ (placeholder) uygulama ikonu üretir: koyu yuvarlatılmış kare, gradyan halka ve beş renkli LED.

Özel bir ikon hazır olunca bu betik gerekmez: `argb_controller_app/windows/runner/resources/app_icon.ico`
dosyasını (çok boyutlu .ico: 16–256 px) kendi ikonunuzla değiştirmeniz yeterlidir.

Kullanım:  python scripts/generate_placeholder_icon.py            (varsayılan çıktı: app_icon.ico)
Gereksinim: pip install pillow
"""
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "argb_controller_app", "windows", "runner", "resources", "app_icon.ico")
S = 1024  # süper örnekleme boyutu


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size, c1, c2, vertical=True):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (y if vertical else x) / (size - 1)
            px[x, y] = lerp(c1, c2, t)
    return img


def rounded_mask(size, radius, inset=0):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([inset, inset, size - 1 - inset, size - 1 - inset], radius=radius, fill=255)
    return m


def build():
    base = gradient(S, (34, 37, 66), (10, 14, 33)).convert("RGBA")   # #222542 -> #0a0e21
    bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bg.paste(base, (0, 0), rounded_mask(S, int(S * 0.22)))
    d = ImageDraw.Draw(bg)
    d.rounded_rectangle([6, 6, S - 7, S - 7], radius=int(S * 0.22), outline=(255, 255, 255, 40), width=6)

    # Güç halkası (mor -> camgöbeği gradyan)
    ring = Image.new("L", (S, S), 0)
    rd = ImageDraw.Draw(ring)
    cx, cy, r = S // 2, int(S * 0.40), int(S * 0.24)
    rd.ellipse([cx - r, cy - r, cx + r, cy + r], outline=255, width=int(S * 0.055))
    rd.rectangle([cx - int(S * 0.04), cy - r - int(S * 0.04), cx + int(S * 0.04), cy - int(S * 0.02)], fill=0)   # üstte boşluk
    rd.rounded_rectangle([cx - int(S * 0.027), cy - r - int(S * 0.02), cx + int(S * 0.027), cy - int(S * 0.03)],
                         radius=int(S * 0.02), fill=255)
    col = gradient(S, (108, 99, 255), (0, 210, 255), vertical=False).convert("RGBA")
    glow = ring.filter(ImageFilter.GaussianBlur(S * 0.02))
    bg.alpha_composite(Image.merge("RGBA", (*col.split()[:3], glow.point(lambda v: int(v * 0.6)))))
    bg.paste(col, (0, 0), ring)

    # Beş LED
    leds = [(255, 82, 82), (255, 171, 64), (0, 230, 118), (0, 210, 255), (108, 99, 255)]
    y = int(S * 0.76)
    gap = int(S * 0.15)
    x0 = S // 2 - 2 * gap
    for i, c in enumerate(leds):
        x = x0 + i * gap
        halo = Image.new("L", (S, S), 0)
        ImageDraw.Draw(halo).ellipse([x - 60, y - 60, x + 60, y + 60], fill=170)
        halo = halo.filter(ImageFilter.GaussianBlur(S * 0.03))
        bg.alpha_composite(Image.merge("RGBA", (Image.new("L", (S, S), c[0]), Image.new("L", (S, S), c[1]),
                                                Image.new("L", (S, S), c[2]), halo)))
        ImageDraw.Draw(bg).ellipse([x - int(S * 0.045), y - int(S * 0.045), x + int(S * 0.045), y + int(S * 0.045)], fill=c + (255,))
    return bg


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = os.path.abspath(args[0] if args else DEFAULT_OUT)
    big = build()
    sizes = [(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)]
    big.resize((256, 256), Image.LANCZOS).save(out, format="ICO", sizes=sizes)
    print("yazıldı:", out)
    if "--preview" in sys.argv:   # isteğe bağlı: yanına PNG önizleme yazar (depoya eklemeyin)
        preview = os.path.splitext(out)[0] + "_preview.png"
        big.resize((256, 256), Image.LANCZOS).save(preview)
        print("önizleme:", preview)


if __name__ == "__main__":
    main()
