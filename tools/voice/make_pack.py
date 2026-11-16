# tools/voice/make_pack.py：把真人录音做成语音包。
#
# 两种用法：
#   1. 发布插件时把语音一起带上（常用）：见 tools/release.py，它会调用这里的函数，
#      把语音放进发布包的 RaidWish/voicepack/ 里，玩家只装一个插件。
#   2. 做成单独的语音包插件 RaidWish_Voice（私下发给个别人用）：
#        python -X utf8 tools/voice/make_pack.py --in recordings --name "某某的语音" --author "某某"
#
# 录音文件：一句一个文件，文件名用 docs/录音稿.txt 里的"文件名"（如 won_bid.m4a）；
#   同一句录了几遍就加编号（won_bid_1.m4a、won_bid_2.m4a），默认用编号最小的一遍，想换哪遍就把它改名成不带编号的。
#   格式随意（m4a、mp3、wav、ogg……），缺的句子游戏里自动用默认语音。
#   录音不进仓库：放在项目里的 recordings/（已被 .gitignore 忽略）或项目外。
#
# 处理方式（--mode）：
#   enhance（默认）  剪掉首尾静音；去掉人耳听不到的低频杂音；轻度压缩让声音更饱满、字与字之间更均匀；
#                    按"听感响度"把各句调到一样响，并防止爆音。不降噪、不变调、不加混响，音色不变。
#   basic            只剪掉首尾静音，把整体音量按最高点调齐。
#   raw              什么都不做，只转成游戏能播的格式。
import argparse, datetime, glob, io, os, re, shutil, subprocess, sys, tempfile, zipfile

KEYS = [
    ("auction_start", "拍卖开始"), ("my_wish", "你许愿的装备来了"), ("bid_1", "出一分"), ("bid_2", "出两分"),
    ("bid_3", "出三分"), ("bid_4", "出四分"), ("bid_9", "许愿出九分"), ("bid_5_auto", "许愿自动出五分"),
    ("bid_fail", "不行哦"), ("collapse", "已收起"), ("countdown", "倒计时三秒"), ("outbid", "有人出了更高的分"),
    ("roll_start", "同分了，开始掷点"), ("outrolled", "你的点数被超过了"), ("won_bid", "恭喜你，拍到了"),
    ("won_roll", "恭喜你，掷点赢了"), ("auction_end", "拍卖结束"), ("all_sold", "全部装备都拍完了"),
]
AUDIO = (".m4a", ".mp3", ".wav", ".ogg", ".aac", ".flac", ".wma", ".amr", ".opus", ".webm")
INTERFACE = "16001"
MODES = ("enhance", "basic", "raw")
TARGET_PEAK = -1.0          # basic：统一到的峰值音量（dB）
TARGET_MEAN = -15.0         # enhance：统一到的平均音量（dB，接近听感响度）
SILENCE = "-45dB"           # 低于这个音量算静音
LICENSE_FILE = "VOICE_LICENSE.txt"      # 文件名用英文，避免个别解压工具把中文文件名弄成乱码
OGG = ["-c:a", "libvorbis", "-q:a", "7"]


def find_ffmpeg(given=None):
    if given:
        return given
    f = shutil.which("ffmpeg")
    if f:
        return f
    hits = glob.glob(os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Packages\Gyan.FFmpeg*\*\bin\ffmpeg.exe"))
    if hits:
        return hits[0]
    sys.exit("找不到 ffmpeg，请用 --ffmpeg 指定 ffmpeg.exe 的路径")


def pick_takes(folder):
    """按录音稿的文件名挑出每句用哪个文件。返回 (选中的, 有多遍的, 对不上名字的)"""
    files = [f for f in os.listdir(folder) if f.lower().endswith(AUDIO)]

    def base(f):
        return os.path.splitext(f)[0].lower()

    chosen, extra = {}, {}
    for key, _ in KEYS:
        exact = [f for f in files if base(f) == key]
        numbered = sorted((int(m.group(1)), f) for f in files
                          for m in [re.fullmatch(key + r"_(\d+)", base(f))] if m)
        if exact:
            chosen[key] = exact[0]
        elif numbered:
            chosen[key] = numbered[0][1]
        takes = exact + [f for _, f in numbered]
        if len(takes) > 1:
            extra[key] = takes
    known = {k for k, _ in KEYS}
    unknown = [f for f in files if base(f) not in known and re.sub(r"_\d+$", "", base(f)) not in known]
    return chosen, extra, unknown


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        sys.exit("ffmpeg 出错：\n" + r.stderr[-1500:])
    return r


def measure(ffmpeg, path):
    """返回 (平均音量, 最高音量)，单位 dB"""
    out = run([ffmpeg, "-v", "info", "-i", path, "-af", "volumedetect", "-f", "null", "-"]).stderr
    mean = re.search(r"mean_volume:\s*(-?[\d.]+) dB", out)
    peak = re.search(r"max_volume:\s*(-?[\d.]+) dB", out)
    return (float(mean.group(1)) if mean else None, float(peak.group(1)) if peak else None)


def convert(ffmpeg, src, dst, mode, tmpdir):
    if mode == "raw":
        run([ffmpeg, "-y", "-v", "error", "-i", src, "-vn"] + OGG + [dst])
        return
    # 1. 剪掉首尾静音（前面留 0.08 秒、后面留 0.12 秒，人声部分不动）
    trim = ("silenceremove=start_periods=1:start_threshold={t}:start_silence=0.08,areverse,"
            "silenceremove=start_periods=1:start_threshold={t}:start_silence=0.12,areverse").format(t=SILENCE)
    mid = os.path.join(tmpdir, "trim.wav")
    run([ffmpeg, "-y", "-v", "error", "-i", src, "-vn", "-af", trim, "-c:a", "pcm_s24le", mid])

    if mode == "basic":
        _, peak = measure(ffmpeg, mid)
        gain = (TARGET_PEAK - peak) if peak is not None else 0.0
        run([ffmpeg, "-y", "-v", "error", "-i", mid, "-af", "volume=%.2fdB" % gain] + OGG + [dst])
        return

    # enhance
    # 2. 去掉 70Hz 以下的低频（人声没有这么低的成分，只有碰麦、空调之类的闷响）；
    #    轻度压缩（2:1）：响的地方稍微收一点，整句听起来更饱满、更稳
    shaped = os.path.join(tmpdir, "shaped.wav")
    run([ffmpeg, "-y", "-v", "error", "-i", mid, "-af",
         "highpass=f=70,acompressor=threshold=-20dB:ratio=2:attack=5:release=80:knee=6",
         "-c:a", "pcm_s24le", shaped])
    # 3. 按平均音量（接近听感响度）调到统一高度；限幅器保证不爆音；首尾几十毫秒淡入淡出，避免"咔"的一声
    mean, _ = measure(ffmpeg, shaped)
    gain = max(-12.0, min(12.0, TARGET_MEAN - mean)) if mean is not None else 0.0
    run([ffmpeg, "-y", "-v", "error", "-i", shaped, "-af",
         "volume=%.2fdB,alimiter=limit=0.89:attack=2:release=40:level=0,"
         "afade=t=in:d=0.008,areverse,afade=t=in:d=0.03,areverse" % gain] + OGG + [dst])


def build_voice(src, voice_dir, mode="enhance", ffmpeg=None, log=print):
    """把 src 里的录音处理后放进 voice_dir（文件名为 键名.ogg）。返回 (选中的, 有多遍的, 对不上名字的)"""
    ffmpeg = find_ffmpeg(ffmpeg)
    chosen, extra, unknown = pick_takes(src)
    if not chosen:
        sys.exit("文件夹里没有找到按录音稿命名的录音（例如 won_bid.m4a）：" + src)
    os.makedirs(voice_dir, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for key, line in KEYS:
            if key in chosen:
                convert(ffmpeg, os.path.join(src, chosen[key]), os.path.join(voice_dir, key + ".ogg"), mode, tmp)
                log("  ✓ %-13s %-10s ← %s" % (key, line, chosen[key]))
            else:
                log("  - %-13s %-10s （没有录音，游戏里用默认语音）" % (key, line))
    return chosen, extra, unknown


def report(extra, unknown, log=print):
    if extra:
        log("\n这些句子有多遍录音，用的是第一遍；想换就把要用的那遍改名成不带编号的再运行：")
        for k, v in extra.items():
            log("  %s：%s" % (k, "、".join(v)))
    if unknown:
        log("\n这些文件名对不上录音稿，没有用到：" + "、".join(unknown))


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def pack_lua(addon_path, name, author, version):
    """语音包登记用的 Lua 文件内容。addon_path 形如 Interface\\AddOns\\RaidWish\\voicepack\\"""
    return ("-- RaidWish 语音包：%s（录音：%s）。使用限制见同目录的 %s。\n"
            "RaidWishVoicePack = {\n    path = %s,\n    name = %s,\n    author = %s,\n    version = %s,\n"
            "    license = \"仅限配合 RaidWish 使用；禁止提取、修改、单独分发，禁止用于 AI 训练或声音克隆\",\n}\n"
            % (name, author, LICENSE_FILE, lua_str(addon_path), lua_str(name), lua_str(author), lua_str(version)))


def license_text(name, author, public):
    """public=True：随插件公开发布的版本；False：只私下分享的单独语音包"""
    scope = PUBLIC_SCOPE if public else PRIVATE_SCOPE
    return LICENSE.format(name=name, author=author, date=datetime.date.today().isoformat(),
                          forbid_share=scope[0], closing=scope[1])


def write_text(path, text, bom=False, crlf=False):
    io.open(path, "w", encoding="utf-8-sig" if bom else "utf-8", newline="\r\n" if crlf else "\n").write(text)


def zip_dir(root, zpath, top):
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for dirpath, _, files in os.walk(root):
            for f in sorted(files):
                p = os.path.join(dirpath, f)
                z.write(p, top + "/" + os.path.relpath(p, root).replace(os.sep, "/"))


def main():
    ap = argparse.ArgumentParser(description="把真人录音做成单独的语音包插件 RaidWish_Voice")
    ap.add_argument("--in", dest="src", required=True, help="录音所在文件夹")
    ap.add_argument("--name", required=True, help="语音包名称，例如 某某的语音")
    ap.add_argument("--author", required=True, help="录音者署名")
    ap.add_argument("--version", default=datetime.date.today().strftime("%Y.%m.%d"))
    ap.add_argument("--out", default="dist")
    ap.add_argument("--mode", choices=MODES, default="enhance", help="处理方式，见文件开头的说明")
    ap.add_argument("--public", action="store_true", help="授权说明按公开发布来写（默认按私下分享）")
    ap.add_argument("--ffmpeg")
    a = ap.parse_args()

    root = os.path.join(a.out, "voicepack", "RaidWish_Voice")
    if os.path.isdir(root):
        shutil.rmtree(root)
    chosen, extra, unknown = build_voice(a.src, os.path.join(root, "voice"), a.mode, a.ffmpeg)

    write_text(os.path.join(root, "RaidWish_Voice.toc"),
               "## Interface: %s\n## Title: |cff4aa3ffRaidWish|r 语音包：%s\n## Notes: RaidWish 许愿助手的可选语音包。"
               "仅限配合 RaidWish 使用，禁止提取、修改、单独分发及用于 AI 训练或声音克隆。\n## Author: %s\n## Version: %s\n\nVoicePack.lua\n"
               % (INTERFACE, a.name, a.author, a.version))
    write_text(os.path.join(root, "VoicePack.lua"),
               pack_lua("Interface\\AddOns\\RaidWish_Voice\\voice\\", a.name, a.author, a.version))
    write_text(os.path.join(root, LICENSE_FILE), license_text(a.name, a.author, a.public), bom=True, crlf=True)

    zpath = os.path.join(a.out, "RaidWish_Voice-%s.zip" % a.version)
    zip_dir(root, zpath, "RaidWish_Voice")
    print("\n语音包：%s  （%d / %d 句，处理方式 %s）" % (os.path.abspath(root), len(chosen), len(KEYS), a.mode))
    print("压缩包：%s" % os.path.abspath(zpath))
    report(extra, unknown)


PRIVATE_SCOPE = (
    "公开发布或转发本语音包（包括上传到网盘、插件网站、论坛、群文件等），除非得到录音者同意；",
    "本语音包仅私下分享给特定玩家。如果你从其他途径获得，请删除，并告知分享者。",
)
PUBLIC_SCOPE = (
    "把录音从 RaidWish 插件中拆出来单独发布、转发，或放进其他插件、软件、视频、直播素材中；",
    "本语音包随 RaidWish 许愿助手插件一起发布，只为配合该插件使用。连同插件原样转发给其他玩家是允许的。",
)

LICENSE = """RaidWish 语音包《{name}》授权说明
================================

录音：{author}
制作日期：{date}

本语音包中的全部录音，著作权及声音权益归录音者（{author}）所有。
RaidWish 插件的代码以 MIT 许可证开源，但本语音包**不在** MIT 许可证范围内，单独适用以下条款：

允许：
  · 将本语音包安装在自己的游戏中，配合 RaidWish 许愿助手插件使用。

禁止：
  · 从本语音包中提取、复制录音，用于 RaidWish 以外的任何用途；
  · 修改、剪辑、混音本语音包中的录音；
  · {forbid_share}
  · 将录音用于任何 AI 模型的训练、声音克隆、语音合成或类似用途；
  · 用本语音包中的声音冒充录音者，或用于商业目的。

{closing}
如有疑问，请联系插件作者：dean.addon.wow@proton.me
"""

if __name__ == "__main__":
    main()
