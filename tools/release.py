# tools/release.py：打发布包。输出一个压缩包，里面只有一个文件夹 RaidWish（上传插件平台、发给别人都用它）。
#
# 用法（项目根目录）：
#   python -X utf8 tools/release.py                                  不带真人语音（只有自带的合成语音）
#   python -X utf8 tools/release.py --voice recordings --voice-name "某某语音" --voice-author "某某"
#                                                                    把真人语音一起打进去
#
# 带语音时，发布包的结构：
#   RaidWish/
#     ...插件本体（MIT 许可证，见 LICENSE.txt）
#     voice/                     自带的合成语音（语音包里缺哪句就用哪句）
#     voicepack/                 真人语音，单独授权，不适用 MIT
#       xxx.ogg
#       VoicePack.lua            登记语音包（发布包的 TOC 里会多一行加载它）
#       VOICE_LICENSE.txt        语音授权说明
#
# 录音和语音包都不进仓库：仓库里的 addon/RaidWish 没有 voicepack/，只有打发布包时才加进去。
# 录音的命名和处理方式见 tools/voice/make_pack.py。
import argparse, io, os, re, shutil, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "voice"))
import make_pack as mp  # noqa: E402

SRC = os.path.join("addon", "RaidWish")
SKIP_DIRS = {"tests", "voicepack"}
SKIP_FILES = {".luacheckrc"}


def read_version():
    toc = io.open(os.path.join(SRC, "RaidWish.toc"), encoding="utf-8").read()
    m = re.search(r"^## Version:\s*(\S+)", toc, re.M)
    return m.group(1) if m else "0.0.0"


def main():
    ap = argparse.ArgumentParser(description="打 RaidWish 发布包")
    ap.add_argument("--voice", help="真人录音所在文件夹（不给就不带真人语音）")
    ap.add_argument("--voice-name", help="语音包名称")
    ap.add_argument("--voice-author", help="配音署名")
    ap.add_argument("--mode", choices=mp.MODES, default="enhance", help="录音处理方式，见 tools/voice/make_pack.py")
    ap.add_argument("--out", default="dist")
    ap.add_argument("--ffmpeg")
    a = ap.parse_args()
    if a.voice and not (a.voice_name and a.voice_author):
        sys.exit("带语音时需要 --voice-name 和 --voice-author")

    version = read_version()
    stage_top = os.path.join(a.out, "release")
    root = os.path.join(stage_top, "RaidWish")
    if os.path.isdir(stage_top):
        shutil.rmtree(stage_top)

    # 1. 插件本体（不带测试和开发配置）
    def ignore(d, names):
        rel = os.path.relpath(d, SRC)
        out = [n for n in names if n in SKIP_FILES]
        if rel == ".":
            out += [n for n in names if n in SKIP_DIRS]
        return out
    shutil.copytree(SRC, root, ignore=ignore)
    license_text = io.open("LICENSE", encoding="utf-8").read().rstrip("\n") + "\n"

    # 2. 真人语音
    n_voice = 0
    if a.voice:
        pack = os.path.join(root, "voicepack")
        print("处理录音（%s）：" % a.mode)
        chosen, extra, unknown = mp.build_voice(a.voice, pack, a.mode, a.ffmpeg)
        n_voice = len(chosen)
        mp.write_text(os.path.join(pack, "VoicePack.lua"),
                      mp.pack_lua("Interface\\AddOns\\RaidWish\\voicepack\\", a.voice_name, a.voice_author, version))
        mp.write_text(os.path.join(pack, mp.LICENSE_FILE),
                      mp.license_text(a.voice_name, a.voice_author, public=True), bom=True, crlf=True)
        toc_path = os.path.join(root, "RaidWish.toc")
        toc = io.open(toc_path, encoding="utf-8").read().rstrip("\n")
        toc = re.sub(r"^(## Author: .*)$", lambda m: m.group(1) + "；配音：" + a.voice_author, toc, count=1, flags=re.M)
        mp.write_text(toc_path, toc + "\n\n# 真人语音包（单独授权，见 voicepack\\" + mp.LICENSE_FILE + "）\nvoicepack\\VoicePack.lua\n")
        license_text += ("\n\n----\nvoicepack 文件夹里的录音不适用以上 MIT 许可证，使用限制见 voicepack/%s。\n"
                         "The recordings in the voicepack folder are NOT covered by the MIT License above; see voicepack/%s.\n"
                         % (mp.LICENSE_FILE, mp.LICENSE_FILE))
        mp.report(extra, unknown)
    mp.write_text(os.path.join(root, "LICENSE.txt"), license_text)

    # 3. 压缩包：只有一个顶层文件夹 RaidWish
    zpath = os.path.join(a.out, "RaidWish-%s.zip" % version)
    mp.zip_dir(root, zpath, "RaidWish")
    files = sum(len(f) for _, _, f in os.walk(root))
    print("\n发布包：%s" % os.path.abspath(zpath))
    print("内容：RaidWish %s，%d 个文件，%.0f KB；%s" % (
        version, files, os.path.getsize(zpath) / 1024,
        ("真人语音 %d / %d 句（%s，配音：%s）" % (n_voice, len(mp.KEYS), a.voice_name, a.voice_author)) if a.voice else "不带真人语音"))
    print("解压后的文件夹：%s" % os.path.abspath(root))
    print("检查：uv run --no-project --with lupa python -I tools/lua51.py tools/sim/release_check.lua \"%s\"" % root.replace(os.sep, "/"))


if __name__ == "__main__":
    main()
