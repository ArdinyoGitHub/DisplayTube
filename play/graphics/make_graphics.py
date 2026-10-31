"""Play Store grafiklerini uretir: 512x512 uygulama simgesi ve 1024x500 one cikan grafik.

Kullanim: python3 play/graphics/make_graphics.py   (Pillow gerekir)
Simge, android/res/mipmap-*/ic_launcher.png ile ayni cizimdir (mavi zemin, beyaz ekran, nokta);
Play kendi maskesini uyguladigi icin simge tam kare cizilir.
"""
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
BLUE = (0, 150, 255)
WHITE = (255, 255, 255)
SS = 4  # kenar yumusatma icin buyuk cizip kucult


def draw_screen(d, cx, cy, unit):
    """192 px'lik orijinal simgedeki ekran cizimi; unit = 1 orijinal piksel."""
    w, h, stroke, r, dot = 119 * unit, 71 * unit, 11 * unit, 18 * unit, 12 * unit
    d.rounded_rectangle([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], radius=r, outline=WHITE, width=round(stroke))
    d.ellipse([cx - dot, cy - dot, cx + dot, cy + dot], fill=WHITE)


def icon():
    size = 512 * SS
    im = Image.new("RGB", (size, size), BLUE)
    draw_screen(ImageDraw.Draw(im), size / 2, size / 2, size / 192)
    im.resize((512, 512), Image.LANCZOS).save(os.path.join(HERE, "icon-512.png"))


def font(bold, px):
    for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
              "C:/Windows/Fonts/segoeuib.ttf" if bold else "C:/Windows/Fonts/segoeui.ttf"):
        if os.path.exists(p):
            return ImageFont.truetype(p, px)
    return ImageFont.load_default()


def feature(lang, subtitle, line2):
    W, H = 1024 * SS, 500 * SS
    im = Image.new("RGB", (W, H), BLUE)
    d = ImageDraw.Draw(im)
    draw_screen(d, 230 * SS, 250 * SS, 2.6 * SS)
    x = 420 * SS
    d.text((x, 150 * SS), "DisplayTube", font=font(True, 76 * SS), fill=WHITE)
    d.text((x, 265 * SS), subtitle, font=font(False, 36 * SS), fill=WHITE)
    d.text((x, 315 * SS), line2, font=font(False, 36 * SS), fill=(220, 240, 255))
    im.resize((1024, 500), Image.LANCZOS).save(os.path.join(HERE, f"feature-graphic-{lang}.png"))


if __name__ == "__main__":
    icon()
    feature("tr", "Telefonunuz, USB ile", "bilgisayarın ikinci ekranı")
    feature("en", "Your phone as a second", "PC display, over USB")
    print("Hazir:", HERE)
