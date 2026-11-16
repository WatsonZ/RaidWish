# tools/voice/make_voices.ps1：用 Windows 自带的中文语音（Microsoft Huihui）生成拍卖语音提示。
# 用法（PowerShell，在项目根目录）：powershell -ExecutionPolicy Bypass -File tools\voice\make_voices.ps1
# 本文件必须以带 BOM 的 UTF-8 保存（Windows PowerShell 5.1 否则会读错中文）。
# 需要：Windows 中文语音包、ffmpeg（在 PATH 里，带 libvorbis）。
# 想换成自己录的声音：直接用同名 .ogg 覆盖 addon\RaidWish\voice\ 下的文件即可，不用改代码。
param(
    [string]$OutDir = "addon\RaidWish\voice",
    [int]$Rate = 1,
    [string[]]$Only = @()      # 只生成这几句（文件名，不含扩展名）；不给就全部重新生成
)

# 文件名（不含扩展名）→ 播报内容。触发时机见 Auction\AuctionComm.lua 与 UI\AuctionPopup.lua。
$lines = [ordered]@{
    "auction_start" = "拍卖开始"                 # 开拍
    "my_wish"     = "你许愿的装备来了"          # 开拍，且是自己许愿的装备
    "bid_1"       = "出一分"                   # 点出分按钮
    "bid_2"       = "出两分"
    "bid_3"       = "出三分"
    "bid_4"       = "出四分"
    "bid_6"       = "许愿出六分"               # 许愿加分 6~9
    "bid_7"       = "许愿出七分"
    "bid_8"       = "许愿出八分"
    "bid_9"       = "许愿出九分"
    "bid_5_auto"  = "许愿自动出五分"            # 许愿者自动出分
    "bid_fail"    = "不行哦"                   # 出分失败、重复 Roll
    "collapse"    = "已收起"                   # 收起弹窗、不要这件
    "countdown"   = "倒计时三秒"               # 开始倒数
    "outbid"      = "有人出了更高的分"          # 自己的出分被超过
    "roll_start"  = "同分了，开始掷点"          # 进入 Roll 阶段
    "outrolled"   = "你的点数被超过了"          # 自己的 Roll 被超过
    "won_bid"     = "恭喜你，拍到了"            # 自己出分胜出
    "won_roll"    = "恭喜你，掷点赢了"          # 自己 Roll 胜出
    "auction_end" = "拍卖结束"                 # 别人胜出或流拍
    "all_sold"    = "全部装备都拍完了"          # 最后一件拍完
}

# 从命令行用 -File 运行时，"a,b,c" 会当成一个字符串传进来，这里拆开
$Only = @($Only | ForEach-Object { $_ -split "," } | Where-Object { $_ })

Add-Type -AssemblyName System.Speech
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$voice = $synth.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -eq "zh-CN" } | Select-Object -First 1
if (-not $voice) { throw "没有找到中文语音（zh-CN），请在 Windows 设置里安装中文语音包" }
$synth.SelectVoice($voice.VoiceInfo.Name)
$synth.Rate = $Rate

$tmp = Join-Path $env:TEMP "raidwish_voice"
New-Item -ItemType Directory -Force $tmp | Out-Null
New-Item -ItemType Directory -Force $OutDir | Out-Null

foreach ($name in $lines.Keys) {
    if ($Only.Count -gt 0 -and $Only -notcontains $name) { continue }
    $wav = Join-Path $tmp "$name.wav"
    $ogg = Join-Path $OutDir "$name.ogg"
    $synth.SetOutputToWaveFile($wav)
    $synth.Speak($lines[$name])
    $synth.SetOutputToNull()
    & ffmpeg -hide_banner -loglevel error -y -i $wav -ac 1 -ar 44100 -c:a libvorbis -q:a 5 $ogg
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg 转换失败：$name" }
    Write-Output ("{0,-10} {1}" -f $name, $lines[$name])
}
$synth.Dispose()
Remove-Item -Recurse -Force $tmp
