-- tools/sim/perf.lua：性能测量（40 人团，许愿表、掉落列表、拍卖进行中）。
-- 用法（项目根目录）：uv run --no-project --with lupa python -I tools/lua51.py tools/sim/perf.lua
-- 注意：这里测的是插件自己的 Lua 代码在本机解释器里的耗时，不含游戏绘制。数字只用来比较前后差异和找热点。
local here = arg[0]:match("^(.*)[/\\]") or "."
local Sim = dofile(here .. "/wow.lua")
local ROOT = arg[1] or (here .. "/../../addon/RaidWish")

local CLASSES = { "WARRIOR", "MAGE", "PRIEST", "ROGUE", "DRUID", "HUNTER", "SHAMAN", "WARLOCK", "PALADIN" }
Sim.items = {}
for i = 1, 60 do
    local id = 20000 + i
    Sim.items[id] = { name = "测试装备" .. i, link = "|cnIQ4:|Hitem:" .. id .. "::::::::60:::::::::|h[测试装备" .. i .. "]|h|r", quality = 4, icon = i }
end

local A = Sim.NewClient(ROOT, "甲", { class = "WARRIOR" })
Sim.Join("甲", "WARRIOR", 2)
for i = 2, 40 do
    Sim.raid[#Sim.raid + 1] = { name = "团员" .. i, class = CLASSES[i % #CLASSES + 1], rank = 0 }   -- 没装插件的团员
end
Sim.RosterUpdate(); Sim.Run(4)
A.ns.WishChat:Start(); Sim.Run(4)
local M = A.ns.Wish.model
for i = 2, 40 do
    local items = {}
    for k = 1, 3 do items[k] = { id = 20000 + ((i * k) % 60) + 1, name = "测试装备" } end
    M:SetWish("团员" .. i, items)
end
for i = 1, 30 do A.ns.LootLog:Add(20000 + i, "团员" .. (i + 1), 0, false) end
Sim.Run(2)

local function bench(label, n, fn)
    fn()
    local t0 = os.clock()
    for _ = 1, n do fn() end
    local ms = (os.clock() - t0) * 1000 / n
    print(("  %-36s %8.3f 毫秒 / 次"):format(label, ms))
    return ms
end

print("== 单次操作耗时（40 人、每人 3 件许愿、30 条掉落）")
A.ns.Main:Show("wish")
bench("许愿页刷新", 50, function() A.ns.WishTab:Refresh() end)
A.ns.Main:Show("loot")
bench("掉落页刷新", 50, function() A.ns.LootTab:Refresh() end)
bench("待拍列表计算", 200, function() A.ns.Auction:Pending() end)
bench("一条团队聊天（团长端全部处理）", 200, function() A.fire("CHAT_MSG_RAID", "大家好", "团员5-无限") end)
bench("一条带物品链接的团队聊天", 200, function() A.fire("CHAT_MSG_RAID", "看看 " .. Sim.items[20005].link, "团员5-无限") end)
bench("团队成员变化（GROUP_ROSTER_UPDATE）", 200, function() A.fire("GROUP_ROSTER_UPDATE") end)
bench("保存一次快照", 100, function() A.ns.Restore:SaveSnapshot(false) end)

Sim.Run(60)            -- 先把上面测量留下的聊天、同步等排队工作跑完，避免算进下面的时间

print("== 持续时间段的耗时")
local t1 = os.clock()
Sim.Run(10)
print(("  空闲 10 秒（许愿进行中、没有拍卖）合计 %.1f 毫秒"):format((os.clock() - t1) * 1000))
A.ns.Main:Show("loot")
A.ns.Auction:StartItem(20001)
local t0 = os.clock()
Sim.Run(10)
local total = (os.clock() - t0) * 1000
print(("  拍卖进行中、掉落页打开的 10 秒合计 %.1f 毫秒（约每秒 %.1f 毫秒）"):format(total, total / 10))

print("== 物品信息一直没到时，等待回调是否堆积")
local cnt = 0
A.ns.Items._Reset()
local realGet = A.env.C_Item.GetItemInfo
A.env.C_Item.GetItemInfo = function(id) if id == 29999 then return nil end return realGet(id) end
local cell = A.ns.Widgets.ItemCell(A.env.UIParent)
for _ = 1, 100 do cell:SetItem({ id = 29999 }) end
cnt = A.ns.Items._PendingCount and A.ns.Items._PendingCount(29999) or -1
print(("  同一个物品单元刷新 100 次后，等待中的回调数：%d"):format(cnt))
A.env.C_Item.GetItemInfo = realGet

for _, e in ipairs(Sim.errors) do print("  报错：" .. e) end
