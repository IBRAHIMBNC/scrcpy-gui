#!/usr/bin/env python3
"""Renders Resources/AppIcon.png (1024x1024) for Scrcpy GUI. Requires Pillow."""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

S = 4  # supersampling factor for smooth edges
SIZE = 1024 * S
OUT = Path(__file__).resolve().parent.parent / "Resources" / "AppIcon.png"


def px(v):
    return int(v * S)


def vertical_gradient(w, h, top, bottom):
    grad = Image.new("RGBA", (1, h))
    for y in range(h):
        t = y / (h - 1)
        grad.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return grad.resize((w, h))


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def shadow(size, box, radius, blur, offset, opacity):
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    x0, y0, x1, y1 = box
    ImageDraw.Draw(layer).rounded_rectangle(
        (x0, y0 + offset, x1, y1 + offset), radius=radius, fill=(0, 0, 0, opacity)
    )
    return layer.filter(ImageFilter.GaussianBlur(blur))


canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

# Base squircle following the macOS icon grid (824pt body inside 1024pt canvas).
body = (px(100), px(100), px(924), px(924))
body_radius = px(185)
canvas.alpha_composite(shadow(canvas.size, body, body_radius, px(14), px(10), 90))
bg = vertical_gradient(SIZE, SIZE, (38, 50, 64, 255), (14, 20, 28, 255))
canvas.paste(bg, (0, 0), rounded_mask(canvas.size, body, body_radius))

draw = ImageDraw.Draw(canvas)

# Monitor (the mirror target).
mon = (px(210), px(250), px(814), px(650))
canvas.alpha_composite(shadow(canvas.size, mon, px(36), px(18), px(12), 120))
draw.rounded_rectangle(mon, radius=px(36), fill=(222, 228, 235, 255))
screen = (px(236), px(276), px(788), px(624))
screen_img = vertical_gradient(screen[2] - screen[0], screen[3] - screen[1], (61, 220, 132, 255), (16, 140, 90, 255))
canvas.paste(screen_img, screen[:2], rounded_mask(canvas.size, screen, px(16)).crop(screen))
draw.polygon([(px(452), px(650)), (px(572), px(650)), (px(596), px(730)), (px(428), px(730))], fill=(170, 180, 190, 255))
draw.rounded_rectangle((px(372), px(718), px(652), px(748)), radius=px(15), fill=(200, 208, 216, 255))

# Mirrored phone content on the monitor screen (translucent, so composite a separate layer).
overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
odraw = ImageDraw.Draw(overlay)
odraw.rounded_rectangle((px(300), px(300), px(436), px(600)), radius=px(20), fill=(8, 50, 32, 110))
odraw.rounded_rectangle((px(312), px(314), px(424), px(586)), radius=px(12), fill=(255, 255, 255, 70))
canvas.alpha_composite(overlay)

# Physical phone in front, bottom-right.
phone = (px(612), px(470), px(812), px(846))
canvas.alpha_composite(shadow(canvas.size, phone, px(40), px(20), px(14), 150))
draw.rounded_rectangle(phone, radius=px(40), fill=(20, 26, 34, 255))
phone_screen = (px(628), px(488), px(796), px(828))
ps_img = vertical_gradient(phone_screen[2] - phone_screen[0], phone_screen[3] - phone_screen[1], (61, 220, 132, 255), (16, 140, 90, 255))
canvas.paste(ps_img, phone_screen[:2], rounded_mask(canvas.size, phone_screen, px(26)).crop(phone_screen))
draw.rounded_rectangle((px(684), px(500), px(740), px(512)), radius=px(6), fill=(20, 26, 34, 255))

# Cast waves from the phone toward the monitor.
wave_color = (255, 255, 255, 235)
cx, cy = px(598), px(470)
for r in (46, 92, 138):
    draw.arc((cx - px(r), cy - px(r), cx + px(r), cy + px(r)), start=190, end=260, fill=wave_color, width=px(20))
draw.ellipse((cx - px(14), cy - px(14), cx + px(14), cy + px(14)), fill=wave_color)

OUT.parent.mkdir(parents=True, exist_ok=True)
canvas.resize((1024, 1024), Image.LANCZOS).save(OUT)
print(f"Wrote {OUT}")
