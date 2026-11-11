-- tools/sim/crash.lua：游戏崩溃后的数据安全场景（许愿团长崩溃、用旧存档重登）。
-- 用法（项目根目录）：uv run --no-project --with lupa python -I tools/lua51.py tools/sim/crash.lua
local here = arg[0]:match("^(.*)[/\\]") or "."
local Sim = dofile(here .. "/wow.lua")
local ROOT = arg[1] or (here .. "/../../addon/RaidWish")
local L1 = "|cnIQ4:|Hitem:19364::::::::60:::::::::|h[碧空之歌]|h|r"
local L2 = "|cnIQ4:|Hitem:212395::::::::60:::::::::|h[迅击戒指]|h|r"
Sim.items = {
    [19364] = { name = "碧空之歌", link = L1, quality = 4, icon = 1 },
    [212395] = { name = "迅击戒指", link = L2, quality = 4, icon = 2 },
}

local A = Sim.NewClient(ROOT, "甲", { class = "WARRIOR" })
local B = Sim.NewClient(ROOT, "乙", { class = "MAGE" })
local C = Sim.NewClient(ROOT, "丙", { class = "PRIEST" })
Sim.Join("甲", "WARRIOR", 2); Sim.Join("乙", "MAGE", 0); Sim.Join("丙", "PRIEST", 0)
Sim.Run(5)

-- 崩溃前的关键数据：丙 许愿了迅击戒指，乙 有 7 分并许愿了碧空之歌
local function intact(c)
    local s = Sim.Snapshot(c)
    return s:find("丙:4:212395", 1, true) ~= nil and s:find("乙:7:19364", 1, true) ~= nil
end

print("== 情况 1：许愿团长崩溃，上次写盘的存档里只有一部分许愿（例如中途 /reload 过一次）")
A.ns.WishChat:Start(); Sim.Run(4)
B.say("xy " .. L1); Sim.Run(2)
local savedA = Sim.Saved(A)                 -- 这一刻写过盘
C.say("xy " .. L2); Sim.Run(2)
A.ns.WishChat:AddDkp("乙", 3); Sim.Run(2)
Sim.Check(intact(A) and intact(B) and intact(C), "崩溃前三端一致：" .. Sim.Snapshot(B))

A = Sim.CrashAndRelog(ROOT, "甲", savedA, { class = "WARRIOR" }); Sim.Run(6)
Sim.Check(not intact(A), "重登后团长本地是旧数据（缺 丙 的许愿和 乙 后来加的分）")
Sim.Check(A.ns.Widgets.lastDialog == "RAIDWISH_STALE", "团员提醒团长数据较旧，团长端只弹一次\"用团员的数据恢复吗\"")
Sim.Check(A.ns.WishSync:Recovering(), "确认之前团长不会发全量")

-- 团长还没点确认，就有新人进团请求全量：团员的数据不能被旧数据覆盖
local D = Sim.NewClient(ROOT, "丁", { class = "ROGUE" })
Sim.Join("丁", "ROGUE", 0); Sim.Run(8)
Sim.Check(intact(B), "团员 乙 的数据没被旧数据覆盖")
Sim.Check(intact(C), "团员 丙 的数据没被旧数据覆盖")

Sim.Click(A.env.RaidWishDialog.ok); Sim.Run(8)
Sim.Check(A.ns.Widgets.lastDialog == "RAIDWISH_STALE", "选了恢复后不再弹第二个确认框")
Sim.Check(Sim.ChatHas("许愿数据已从团员处恢复，请大家输入 /xy 打开许愿助手核对自己的许愿和分数"), "恢复后在团队频道请大家核对")
Sim.Check(intact(A), "团长采用后拿回了完整数据")
Sim.Same(A, B, "团长与 乙 一致")
Sim.Same(A, D, "后进团的 丁 也拿到完整数据")
C.say("xy [新许愿]"); Sim.Run(3)
Sim.Check(Sim.Snapshot(B):find("丙:4:n:新许愿", 1, true) ~= nil, "恢复后团长继续正常录入并同步")

print("== 情况 2：许愿团长崩溃，存档里还没有这次的团长身份；重登后直接点开始许愿")
local full = Sim.Snapshot(B)
local savedOld = Sim.Saved(A)
savedOld.RaidWishDB.leader = { term = 0, rev = 0 }       -- 上次写盘时还没开始许愿
savedOld.RaidWishDB.wishes["丙"].wish = nil              -- 并且缺一条许愿
A = Sim.CrashAndRelog(ROOT, "甲", savedOld, { class = "WARRIOR" }); Sim.Run(6)
A.ns.WishChat:Start(true); Sim.Run(5)                    -- 本地还有别的许愿，所以不会先问团员
Sim.Check(A.ns.Widgets.lastDialog == "RAIDWISH_STALE", "任期号落后：团员提醒，团长端弹窗")
Sim.Check(Sim.Snapshot(B) == full, "确认之前团员的数据没变")
Sim.Click(A.env.RaidWishDialog.ok); Sim.Run(8)
Sim.Check(B.ns.Wish:LeaderName() == "甲" and C.ns.Wish:LeaderName() == "甲", "团员认定 甲 为许愿团长")
Sim.Check(A.ns.Wish:IsLeader() and A.ns.Wish:InProgress(), "甲 是许愿团长、许愿进行中")
Sim.Same(A, B, "数据一致")
Sim.Check(Sim.Snapshot(B) == full, "没有丢数据")

print("== 情况 3：团员崩溃重登，旧存档不影响别人")
local savedC = Sim.Saved(C)
B.say("xy " .. L2); Sim.Run(2)
C = Sim.CrashAndRelog(ROOT, "丙", savedC, { class = "PRIEST" }); Sim.Run(12)
Sim.Same(A, C, "团员重登后自动拿到最新数据")
Sim.Same(A, B, "其他人不受影响")

print(("\n合计：%d 项通过，%d 项失败"):format(Sim.pass, Sim.fail))
for _, e in ipairs(Sim.errors) do print("  报错：" .. e) end
os.exit((Sim.fail == 0 and #Sim.errors == 0) and 0 or 1)
