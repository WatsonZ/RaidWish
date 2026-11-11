# tools/icon/make_icon.py：生成小地图按钮图标 addon/RaidWish/Images/MinimapButton.tga（64x64，32 位）。
# 用法（项目根目录）：uv run --no-project --with pillow python -I tools/icon/make_icon.py
# 图案："许愿星"——宝蓝到深紫的圆底，中间一颗大号金色四芒星，右上一颗小星点，顶部玻璃高光。
# 想换成自己的图标：直接用 64x64 的 32 位 TGA 覆盖同名文件即可（文件名不变，代码不用改）。
import math
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

SIZE, SS = 64, 8                     # 先按 8 倍画再缩小，边缘更平滑
S = SIZE * SS
C = S / 2
OUT = sys.argv[1] if len(sys.argv) > 1 else "addon/RaidWish/Images/MinimapButton.tga"


def radial(inner, outer, cx, cy, r):
    """径向渐变底"""
    img = Image.new("RGBA", (S, S))
    px = img.load()
    for y in range(0, S):
        for x in range(0, S):
            t = min(1.0, math.hypot(x - cx, y - cy) / r)
            t = t ** 1.3
            px[x, y] = tuple(int(inner[i] + (outer[i] - inner[i]) * t) for i in range(3)) + (255,)
    return img


def star_points(cx, cy, r_long, r_short, n=4, rot=-math.pi / 2):
    """n 芒星的多边形顶点（长芒、短腰交替）"""
    pts = []
    for i in range(n * 2):
        a = rot + i * math.pi / n
        r = r_long if i % 2 == 0 else r_short
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


# 1. 明亮的宝蓝到深紫径向渐变（缩到 20 像素也要看得清，底色不能太暗）
base = radial((70, 140, 255), (40, 18, 110), C - S * 0.10, C - S * 0.14, S * 0.70)

# 2. 星光光晕
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
for rad, alpha in [(0.40, 60), (0.28, 110)]:
    r = S * rad
    gd.ellipse([C - r, C - r, C + r, C + r], fill=(255, 210, 90, alpha))
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.07))
base = Image.alpha_composite(base, glow)

# 3. 大号金色四芒星：深色描边保证对比，亮金主体，浅金高光
star = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(star)
sd.polygon(star_points(C, C, S * 0.47, S * 0.16), fill=(90, 45, 0, 255))
sd.polygon(star_points(C, C, S * 0.43, S * 0.13), fill=(255, 190, 40, 255))
sd.polygon(star_points(C, C, S * 0.30, S * 0.08), fill=(255, 228, 120, 255))
sd.polygon(star_points(C, C, S * 0.15, S * 0.04), fill=(255, 250, 220, 255))
star = star.filter(ImageFilter.GaussianBlur(SS * 0.3))
base = Image.alpha_composite(base, star)

# 4. 右上一颗小星点
small = Image.new("RGBA", (S, S), (0, 0, 0, 0))
md = ImageDraw.Draw(small)
md.polygon(star_points(S * 0.77, S * 0.24, S * 0.11, S * 0.03), fill=(255, 245, 200, 255))
small = small.filter(ImageFilter.GaussianBlur(SS * 0.3))
base = Image.alpha_composite(base, small)

# 5. 顶部玻璃高光，和其他按钮的质感一致
gloss = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(gloss).ellipse([S * 0.14, S * 0.04, S * 0.86, S * 0.50], fill=(255, 255, 255, 46))
gloss = gloss.filter(ImageFilter.GaussianBlur(SS * 2))
base = Image.alpha_composite(base, gloss)

# 圆形裁切
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).ellipse([0, 0, S - 1, S - 1], fill=255)
base.putalpha(ImageChops.multiply(base.getchannel("A"), mask))

img = base.resize((SIZE, SIZE), Image.LANCZOS)
img.save(OUT, format="TGA", compression=None)
img.resize((256, 256), Image.LANCZOS).save("tools/icon/preview.png")
small20 = img.resize((20, 20), Image.LANCZOS)
small20.resize((120, 120), Image.NEAREST).save("tools/icon/preview20.png")   # 小地图上实际大小的放大图
print("saved", OUT)
