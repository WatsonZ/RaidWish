-- tools/sim/release_check.lua：检查打好的发布包能不能正常加载（tools/release.py 的输出）。
-- 用法（项目根目录）：uv run --no-project --with lupa python -I tools/lua51.py tools/sim/release_check.lua dist/release/RaidWish
local here = arg[0]:match("^(.*)[/\\]") or "."
local Sim = dofile(here .. "/wow.lua")
local ROOT = arg[1] or "dist/release/RaidWish"

local function exists(rel)
    local fh = io.open(ROOT .. "/" .. rel, "rb")
    if fh then fh:close() return true end
    return false
end

Sim.Check(exists("RaidWish.toc"), "有 RaidWish.toc")
Sim.Check(not exists("tests/run.lua") and not exists(".luacheckrc"), "不带测试和开发配置")
Sim.Check(exists("LICENSE.txt"), "带许可证")

local A = Sim.NewClient(ROOT, "甲 某某", { class = "WARRIOR" })
Sim.Join("甲 某某", "WARRIOR", 2)
Sim.Run(3)
Sim.Check(A.ns ~= nil and A.ns.VERSION ~= nil, "插件加载成功，版本 " .. tostring(A.ns and A.ns.VERSION))
A.slash("")
Sim.Check(A.env.RaidWishMainFrame and A.env.RaidWishMainFrame:IsShown(), "/xy 能打开主窗口")

local V = A.ns.Voice
A.ns.DB.options.auction.voice = true
if exists("voicepack/VoicePack.lua") then
    local pack = V:Pack()
    Sim.Check(pack ~= nil, "带真人语音：语音包已登记")
    Sim.Check(exists("voicepack/VOICE_LICENSE.txt"), "带语音授权说明")
    if pack then
        Sim.Check(pack.path == "Interface\\AddOns\\RaidWish\\voicepack\\", "语音包路径在插件自己的文件夹里")
        print("  语音包：" .. tostring(pack.name) .. "，录音：" .. tostring(pack.author))
        local n, total = 0, 0
        for _, k in ipairs({ "auction_start", "my_wish", "bid_1", "bid_2", "bid_3", "bid_4", "bid_9", "bid_5_auto", "bid_fail",
            "collapse", "countdown", "outbid", "roll_start", "outrolled", "won_bid", "won_roll", "auction_end", "all_sold" }) do
            total = total + 1
            if exists("voicepack/" .. k .. ".ogg") then n = n + 1 end
            Sim.Check(exists("voice/" .. k .. ".ogg"), "默认语音 " .. k .. " 还在（语音包缺句时兜底）")
        end
        print("  真人语音 " .. n .. " / " .. total .. " 句")
        A.sounds = {}
        Sim.Run(2); V:Play("won_bid")
        local want = exists("voicepack/won_bid.ogg") and "voicepack" or "\\voice\\"
        Sim.Check(A.sounds[1] and A.sounds[1]:find(want, 1, true) ~= nil, "播放 won_bid：" .. tostring(A.sounds[1]))
    end
else
    Sim.Check(V:Pack() == nil, "不带真人语音：用默认语音")
    A.sounds = {}
    Sim.Run(2); V:Play("won_bid")
    Sim.Check(A.sounds[1] and A.sounds[1]:find("\\voice\\won_bid", 1, true) ~= nil, "播放默认语音")
end

print(("\n合计：%d 项通过，%d 项失败"):format(Sim.pass, Sim.fail))
for _, e in ipairs(Sim.errors) do print("  报错：" .. e) end
os.exit((Sim.fail == 0 and #Sim.errors == 0) and 0 or 1)
