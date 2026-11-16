# tools/icon/design_icons.py：许愿助手图标设计稿（游戏图标风格：厚涂质感、立体光影、暗角）。
# 用法（项目根目录）：uv run --no-project --with pillow --with numpy python -I tools/icon/design_icons.py
# 输出：dist/图标设计/ 下每个方案的 64x64 TGA（游戏用）、512 大图，以及一张对比预览图（含小地图实际大小）。
import math, os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 512                     # 绘制尺寸
OUT = os.path.join("dist", "图标设计")
os.makedirs(OUT, exist_ok=True)
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
C = S / 2.0


# ---------------- 基础工具 ----------------
def blur(a, r):
    im = Image.fromarray(np.clip(a * 255, 0, 255).astype(np.uint8))
    return np.asarray(im.filter(ImageFilter.GaussianBlur(r))).astype(np.float32) / 255.0


def poly_mask(pts, ss=4):
    im = Image.new("L", (S * ss, S * ss), 0)
    ImageDraw.Draw(im).polygon([(x * ss, y * ss) for x, y in pts], fill=255)
    return np.asarray(im.resize((S, S), Image.LANCZOS)).astype(np.float32) / 255.0


def disc(cx, cy, r, soft=1.5):
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    return np.clip((r - d) / soft + 0.5, 0, 1)


def star_pts(cx, cy, r1, r2, n=4, rot=-math.pi / 2):
    return [(cx + (r1 if i % 2 == 0 else r2) * math.cos(rot + i * math.pi / n),
             cy + (r1 if i % 2 == 0 else r2) * math.sin(rot + i * math.pi / n)) for i in range(n * 2)]


def lit(height, strength=6.0, light=(-0.55, -0.65, 0.52)):
    """由高度图算光照：返回 (漫反射, 高光)"""
    gy, gx = np.gradient(height * strength)
    nx, ny, nz = -gx, -gy, np.ones_like(gx)
    ln = np.sqrt(nx ** 2 + ny ** 2 + nz ** 2)
    nx, ny, nz = nx / ln, ny / ln, nz / ln
    L = np.array(light, np.float32); L /= np.linalg.norm(L)
    diff = np.clip(nx * L[0] + ny * L[1] + nz * L[2], 0, 1)
    H = L + np.array([0, 0, 1], np.float32); H /= np.linalg.norm(H)
    spec = np.clip(nx * H[0] + ny * H[1] + nz * H[2], 0, 1) ** 40
    return diff, spec


def ramp(t, stops):
    """t∈[0,1] 按色标插值，stops=[(位置,(r,g,b)),...]"""
    t = np.clip(t, 0, 1)
    out = np.zeros(t.shape + (3,), np.float32)
    for (p0, c0), (p1, c1) in zip(stops[:-1], stops[1:]):
        m = (t >= p0) & (t <= p1)
        k = ((t - p0) / max(p1 - p0, 1e-6))[..., None]
        out[m] = (np.array(c0) * (1 - k) + np.array(c1) * k)[m]
    return out / 255.0


def over(base, color, alpha):
    a = np.clip(alpha, 0, 1)[..., None]
    return base * (1 - a) + color * a


def add(base, color, amount):
    return np.clip(base + color * np.clip(amount, 0, None)[..., None], 0, 1)


def noise(scale, seed):
    rng = np.random.default_rng(seed)
    n = rng.random((S // scale + 2, S // scale + 2)).astype(np.float32)
    im = Image.fromarray((n * 255).astype(np.uint8)).resize((S, S), Image.BICUBIC)
    return np.asarray(im).astype(np.float32) / 255.0


def vignette(img, k=0.75):
    d = np.sqrt((xx - C) ** 2 + (yy - C) ** 2) / (S * 0.72)
    return img * (1 - k * np.clip(d, 0, 1) ** 2.2)[..., None]


def frame(img):
    """游戏图标常见的细暗边 + 内侧高光线"""
    e = np.minimum(np.minimum(xx, yy), np.minimum(S - 1 - xx, S - 1 - yy))
    img = img * (0.35 + 0.65 * np.clip(e / 10.0, 0, 1))[..., None]
    rim = np.exp(-((e - 12) ** 2) / 8.0) * 0.10
    return add(img, np.array([1.0, 0.9, 0.7]), rim)


def gold(diff, spec, base_t):
    """金属金：按光照取色，带一点环境反光"""
    col = ramp(diff * 0.85 + base_t * 0.15,
               [(0, (60, 30, 6)), (0.35, (150, 92, 20)), (0.62, (226, 168, 58)), (0.82, (255, 222, 130)), (1, (255, 246, 210))])
    return add(col, np.array([1.0, 0.98, 0.9]), spec * 1.2)


# ---------------- 方案 A：星纹金币 ----------------
def design_coin():
    R = S * 0.40
    d = np.sqrt((xx - C) ** 2 + (yy - C) ** 2)
    coin = disc(C, C, R)
    # 背景：暗红棕，带笔触噪声
    bg = ramp(1 - d / (S * 0.75), [(0, (14, 6, 4)), (0.55, (58, 22, 12)), (1, (120, 48, 20))])
    bg = add(bg * (0.85 + 0.3 * noise(16, 1))[..., None], np.zeros(3), 0)
    glow = np.exp(-((d - R) ** 2) / (2 * (S * 0.07) ** 2)) * (d > R * 0.9)
    bg = add(bg, np.array([1.0, 0.6, 0.15]), glow * 0.55)
    # 高度：外圈凸起的边、内圈平面、凸起的四芒星、细小的斜纹
    rim = np.clip((d - R * 0.80) / (R * 0.05), 0, 1) * np.clip((R - d) / (R * 0.06), 0, 1)
    star = poly_mask(star_pts(C, C, R * 0.74, R * 0.20))
    star_h = blur(star, 6) * 0.9 + blur(star, 2) * 0.3
    dots = sum(disc(C + R * 0.88 * math.cos(a), C + R * 0.88 * math.sin(a), R * 0.025) for a in np.linspace(0, 2 * math.pi, 28, endpoint=False))
    h = blur(coin, 3) * 0.25 + blur(rim, 3) * 0.7 + star_h * 0.9 + blur(dots * (d > R * 0.82), 1.5) * 0.3
    diff, spec = lit(h, 9.0)
    body = gold(diff, spec, 1 - d / R)
    # 币面（星星以外、边以内）压暗一些，星星周围加一圈暗边，星星本身提亮：缩小后星形依然清楚
    field = np.clip((R * 0.80 - d) / 3, 0, 1) * (1 - star)
    body = body * (1 - 0.38 * field)[..., None]
    edge = np.clip(blur(star, 5) - star, 0, 1)
    body = body * (1 - 0.6 * edge)[..., None]
    body = add(body, np.array([1.0, 0.9, 0.6]), star * 0.18)
    img = over(bg, body, coin)
    # 硬币投影
    img = img * (1 - 0.5 * blur(disc(C + 10, C + 14, R), 14) * (1 - coin))[..., None]
    # 闪光
    for (sx, sy, sr) in [(C - R * 0.42, C - R * 0.52, R * 0.30), (C + R * 0.62, C + R * 0.48, R * 0.14)]:
        sp = poly_mask(star_pts(sx, sy, sr, sr * 0.12))
        img = add(img, np.array([1, 1, 0.92]), blur(sp, 1.5) * 0.95 + blur(sp, 10) * 0.5)
    return frame(vignette(img, 0.5))


# ---------------- 方案 B：许愿宝珠 ----------------
def design_orb():
    R = S * 0.33
    d = np.sqrt((xx - C) ** 2 + (yy - C) ** 2)
    bg = ramp(1 - d / (S * 0.75), [(0, (6, 4, 18)), (0.6, (28, 14, 58)), (1, (60, 30, 110))])
    bg = bg * (0.85 + 0.3 * noise(20, 2))[..., None]
    # 宝珠：球体明暗 + 内部星云
    orb = disc(C, C - S * 0.03, R)
    oy = C - S * 0.03
    z = np.sqrt(np.clip(1 - ((xx - C) ** 2 + (yy - oy) ** 2) / R ** 2, 0, 1))
    shade = np.clip(z * 0.8 + 0.2 - ((xx - C) + (yy - oy)) / (R * 4), 0, 1)
    neb = blur(noise(10, 3), 6) * 0.6 + blur(noise(5, 4), 3) * 0.4
    inner = ramp(shade * 0.62 + neb * 0.30, [(0, (20, 10, 70)), (0.45, (70, 50, 190)), (0.75, (140, 120, 255)), (1, (220, 210, 255))])
    st = poly_mask(star_pts(C, oy, R * 0.74, R * 0.16))
    st_h = blur(st, 4)
    sd, ss = lit(st_h, 7.0)
    inner = add(inner, np.array([1.0, 0.85, 0.45]), blur(st, 18) * 0.9)
    inner = over(inner, gold(sd, ss, sd), st)
    hl = np.exp(-(((xx - (C - R * 0.38)) ** 2) / (2 * (R * 0.22) ** 2) + ((yy - (oy - R * 0.42)) ** 2) / (2 * (R * 0.14) ** 2)))
    inner = add(inner, np.ones(3), hl * 0.45)
    img = over(bg, inner, orb)
    # 金色底座：托住宝珠的爪
    base = np.zeros((S, S), np.float32)
    base += poly_mask([(C - R * 0.95, C + R * 0.55), (C + R * 0.95, C + R * 0.55), (C + R * 0.55, C + R * 1.30),
                       (C - R * 0.55, C + R * 1.30)]) * (1 - orb)
    for sgn in (-1, 1):
        base += poly_mask([(C + sgn * R * 0.70, C + R * 0.20), (C + sgn * R * 1.05, C + R * 0.70),
                           (C + sgn * R * 0.55, C + R * 0.95)]) * (1 - orb * 0.6)
    base = np.clip(base, 0, 1)
    bh = blur(base, 4) + blur(base, 12) * 0.5
    bd, bs = lit(bh, 14.0)
    vert = np.clip((yy - (C + R * 0.2)) / (R * 1.1), 0, 1)
    img = over(img, gold(bd * (1 - 0.55 * vert), bs, 0.3 - 0.3 * vert), base)
    rimglow = np.exp(-((d - R) ** 2) / (2 * (S * 0.05) ** 2))
    img = add(img, np.array([0.55, 0.45, 1.0]), rimglow * 0.35 * (1 - orb))
    for (sx, sy, sr) in [(C + R * 0.95, C - R * 0.95, R * 0.18), (C - R * 1.05, C - R * 0.6, R * 0.10)]:
        sp = poly_mask(star_pts(sx, sy, sr, sr * 0.12))
        img = add(img, np.array([1, 0.95, 0.8]), blur(sp, 1.2) + blur(sp, 8) * 0.5)
    return frame(vignette(img, 0.55))


# ---------------- 方案 C：流星许愿 ----------------
def design_meteor():
    sky_t = (yy + xx) / (2 * S)
    img = ramp(sky_t, [(0, (40, 30, 90)), (0.5, (16, 22, 60)), (1, (4, 6, 18))])
    img = img * (0.9 + 0.2 * noise(24, 5))[..., None]
    # 星点
    rng = np.random.default_rng(7)
    for _ in range(40):
        x, y, r = rng.random() * S, rng.random() * S, rng.random() * 2.2 + 0.6
        img = add(img, np.array([0.9, 0.9, 1.0]), disc(x, y, r) * rng.random() * 0.8)
    # 拖尾：从左下到右上的光带
    hx, hy = S * 0.58, S * 0.42
    ang = math.atan2(-(S * 0.82 - hy), -(S * 0.18 - hx))
    ux, uy = math.cos(ang), math.sin(ang)
    along = (xx - hx) * ux + (yy - hy) * uy
    across = -(xx - hx) * uy + (yy - hy) * ux
    L = S * 0.62
    t = np.clip(along / L, 0, 1)
    width = S * 0.11 * (1 - t) + 1
    tail = np.exp(-(across ** 2) / (2 * width ** 2)) * (along > 0) * (1 - t) ** 1.4
    img = add(img, np.array([1.0, 0.75, 0.3]), tail * 1.1)
    img = add(img, np.array([1.0, 0.95, 0.8]), np.exp(-(across ** 2) / (2 * (width * 0.35) ** 2)) * (along > 0) * (1 - t) ** 2 * 0.9)
    # 星头：立体金星 + 大光晕
    st = poly_mask(star_pts(hx, hy, S * 0.27, S * 0.07))
    st2 = poly_mask(star_pts(hx, hy, S * 0.15, S * 0.04, rot=-math.pi / 4))
    sh = blur(st, 5) + blur(st2, 3) * 0.5
    sd, ss = lit(sh, 8.0)
    halo = np.exp(-((xx - hx) ** 2 + (yy - hy) ** 2) / (2 * (S * 0.17) ** 2))
    img = add(img, np.array([1.0, 0.75, 0.35]), halo * 1.0)
    img = over(img, gold(sd, ss, sd), np.clip(st + st2, 0, 1))
    img = add(img, np.ones(3), disc(hx, hy, S * 0.025) * 0.9 + blur(disc(hx, hy, S * 0.03), 6) * 0.5)
    return frame(vignette(img, 0.45))


def to_image(a):
    return Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8), "RGB")


def minimap_mock(icon64, scale=4):
    """模拟游戏小地图按钮：21 像素圆形图标 + 金色圆框，再放大 scale 倍方便看"""
    n = 32
    canvas = Image.new("RGBA", (n, n), (70, 60, 48, 255))
    ic = icon64.convert("RGBA").resize((21, 21), Image.LANCZOS)
    m = Image.new("L", (21 * 4, 21 * 4), 0)
    ImageDraw.Draw(m).ellipse([0, 0, 21 * 4 - 1, 21 * 4 - 1], fill=255)
    ic.putalpha(m.resize((21, 21), Image.LANCZOS))
    canvas.alpha_composite(ic, (5, 5))
    big = canvas.resize((n * 8, n * 8), Image.LANCZOS)
    ImageDraw.Draw(big).ellipse([2 * 8, 2 * 8, 30 * 8, 30 * 8], outline=(214, 172, 80, 255), width=20)
    ImageDraw.Draw(big).ellipse([2 * 8 + 18, 2 * 8 + 18, 30 * 8 - 18, 30 * 8 - 18], outline=(90, 60, 20, 255), width=5)
    return big.resize((n * scale, n * scale), Image.LANCZOS)


def main():
    designs = [("A_星纹金币", design_coin()), ("B_许愿宝珠", design_orb()), ("C_流星许愿", design_meteor())]
    W, H = 3 * 300 + 40, 470
    sheet = Image.new("RGB", (W, H), (28, 28, 32))
    dr = ImageDraw.Draw(sheet)
    try:
        from PIL import ImageFont
        font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 18)
        small = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 13)
    except Exception:
        font = small = None
    for i, (name, arr) in enumerate(designs):
        img = to_image(arr)
        img.save(os.path.join(OUT, name + "_512.png"))
        ic64 = img.resize((64, 64), Image.LANCZOS)
        ic64.save(os.path.join(OUT, name + ".tga"))
        x = 20 + i * 300
        sheet.paste(img.resize((256, 256), Image.LANCZOS), (x + 12, 20))
        dr.text((x + 12, 284), name.replace("_", "  "), fill=(235, 235, 235), font=font)
        sheet.paste(minimap_mock(ic64, 4), (x + 12, 318))
        sheet.paste(ic64.resize((21, 21), Image.LANCZOS), (x + 160, 360))
        dr.text((x + 150, 392), "实际 21 像素", fill=(160, 160, 160), font=small)
        dr.text((x + 12, 450), "↑ 小地图按钮（放大 4 倍）", fill=(160, 160, 160), font=small)
    sheet.save(os.path.join(OUT, "预览.png"))
    print("ok", os.path.abspath(os.path.join(OUT, "预览.png")))


if __name__ == "__main__":
    main()
