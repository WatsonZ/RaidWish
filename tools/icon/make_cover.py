# tools/icon/make_cover.py：插件平台用的封面图（1:1，1024x1024），用插件图标"许愿星"加名称。
# 用法（项目根目录）：uv run --no-project --with pillow python -I tools/icon/make_cover.py
# 输出：dist/发布素材/封面.png
import math, os, random, runpy, sys, tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT_DIR = os.path.join("dist", "发布素材")
os.makedirs(OUT_DIR, exist_ok=True)
W = 1024
FONT_B = "C:/Windows/Fonts/msyhbd.ttc"
FONT_R = "C:/Windows/Fonts/msyh.ttc"

# 1. 借用 make_icon.py 画好的 512x512 图标（圆形，带透明）
tmp = os.path.join(tempfile.gettempdir(), "raidwish_icon_tmp.tga")
argv = sys.argv
sys.argv = [argv[0], tmp]
icon = runpy.run_path(os.path.join("tools", "icon", "make_icon.py"))["base"]
sys.argv = argv

# 2. 背景：深夜蓝径向渐变 + 稀疏星点
bg = Image.new("RGB", (W, W))
px = bg.load()
cx, cy = W / 2, W * 0.40
for y in range(W):
    for x in range(W):
        t = min(1.0, math.hypot(x - cx, y - cy) / (W * 0.75)) ** 1.2
        px[x, y] = (int(34 + (8 - 34) * t), int(30 + (10 - 30) * t), int(84 + (28 - 84) * t))
d = ImageDraw.Draw(bg)
random.seed(3)
for _ in range(90):
    x, y, r = random.random() * W, random.random() * W, random.random() * 1.8 + 0.4
    a = int(120 + random.random() * 135)
    d.ellipse([x - r, y - r, x + r, y + r], fill=(a, a, min(255, a + 20)))
bg = bg.convert("RGBA")

# 3. 图标后面的光晕 + 图标
glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse([cx - 330, cy - 330, cx + 330, cy + 330], fill=(110, 150, 255, 90))
bg = Image.alpha_composite(bg, glow.filter(ImageFilter.GaussianBlur(60)))
size = 470
ic = icon.resize((size, size), Image.LANCZOS)
shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(shadow).ellipse([cx - size / 2 + 10, cy - size / 2 + 22, cx + size / 2 + 10, cy + size / 2 + 22], fill=(0, 0, 0, 150))
bg = Image.alpha_composite(bg, shadow.filter(ImageFilter.GaussianBlur(18)))
bg.alpha_composite(ic, (int(cx - size / 2), int(cy - size / 2)))

# 4. 文字
d = ImageDraw.Draw(bg)


def center_text(text, y, font, fill, shadow_fill=(0, 0, 0, 160)):
    box = d.textbbox((0, 0), text, font=font)
    x = (W - (box[2] - box[0])) / 2 - box[0]
    d.text((x + 3, y + 4), text, font=font, fill=shadow_fill)
    d.text((x, y), text, font=font, fill=fill)


center_text("许愿助手", 690, ImageFont.truetype(FONT_B, 120), (255, 255, 255, 255))
center_text("RaidWish", 838, ImageFont.truetype(FONT_B, 54), (255, 214, 110, 255))
center_text("许愿 · 分数 · 拍卖 · 语音播报", 920, ImageFont.truetype(FONT_R, 38), (200, 210, 240, 255))

out = os.path.join(OUT_DIR, "封面.png")
bg.convert("RGB").save(out)
print("saved", os.path.abspath(out))
