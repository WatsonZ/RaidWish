-- Loot/LootAssign.lua（候选人计算）的离线测试
local T = ...
local seed = { Compat = { GetItemInfo = function() return nil end, RequestItem = function() end },
    Events = { On = function() end, Off = function() end, Fire = function() end }, Log = function() end, LogLevel = { ERROR = 0 } }
local ns = T.load({ "Core/Util.lua", "Core/Items.lua", "Wish/WishModel.lua", "Loot/LootAssign.lua" }, nil, seed)
local LA = ns.LootAssign

local store = {}
local m = ns.WishModel.New(store, nil, function() return 0 end)
local roster = {
    { name = "甲", class = "WARRIOR" }, { name = "乙", class = "MAGE" },
    { name = "丙", class = "PRIEST" }, { name = "丁", class = "WARRIOR" },
}
m:EnsureMembers(roster, 4)
m:Ensure("离队者", "ROGUE", 4)
m:SetWish("乙", { { id = 100, name = "甲物" } })
m:SetWish("丁", { { id = 100, name = "甲物" } })
m:SetWish("离队者", { { id = 100, name = "甲物" } })
m:SetWish("丙", { { name = "地板", floor = true } })

local ctx = {
    item = 100, me = "甲", quickloot = "丙-无限", roster = roster, model = m,
    results = { { winner = "丁", id = 100 }, { winner = "外人", id = 100 }, { winner = "乙", id = 200 }, { winner = "乙", id = 100 } },
    random = function(n) return n end,
}

T.eq(LA.Self(ctx), "甲", "自己")
T.eq(LA.Designated(ctx), "丙", "指定拾取人（去服务器后缀）")
T.eq(LA.Designated({ quickloot = "外人", roster = roster }), nil, "指定的人不在候选人里")
T.eq(LA.Designated({ quickloot = "", roster = roster }), nil, "未指定")
T.eq(LA.Random(ctx), "丁", "随机（注入的随机数）")
T.eq(LA.Random({ roster = {} }), nil, "没有候选人")

local w = LA.Wishers(ctx)
T.eq(#w, 2, "许愿人只算候选人")
T.eq(w[1].name .. w[2].name, "丁乙", "许愿人按名字排序")
T.eq(LA.FloorWishers(ctx)[1].name, "丙", "地板许愿")
m:MarkItemDone("乙", 100)
T.eq(#LA.Wishers(ctx), 1, "已完成的许愿不算")

local aw = LA.AuctionWinners(ctx)
T.eq(#aw, 2, "拍卖赢家：只算该物品、且在候选人里")
T.eq(aw[1].name, "丁", "最早一次结算在前")
T.eq(aw[2].index, 4, "记录下标")
T.ok(LA.ConsumeResult(ctx.results, aw[1].index), "分配后移除结算记录")
T.eq(#ctx.results, 3, "移除一条")
T.eq(LA.AuctionWinners(ctx)[1].name, "乙", "下一次匹配到下一条")

local g = LA.ByClass(ctx)
T.eq(#g, 3, "三个职业")
local warrior
for _, x in ipairs(g) do if x.class == "WARRIOR" then warrior = x end end
T.same(warrior.names, { "丁", "甲" }, "同职业组内按名字排序")

T.ok(LA.NeedConfirm(4, false), "紫装需要确认")
T.ok(not LA.NeedConfirm(3, false), "蓝装不需要")
T.ok(LA.NeedConfirm(2, true), "设置了总是询问")
