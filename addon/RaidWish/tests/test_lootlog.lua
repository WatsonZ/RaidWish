-- Loot/LootLog.lua 纯逻辑部分的离线测试
local T = ...
local seed = {
    Compat = { GetItemInfo = function() return nil end, RequestItem = function() end },
    Events = { On = function() end, Off = function() end, Fire = function() end },
    Log = function() end, LogLevel = { ERROR = 0 },
}
local ns = T.load({ "Core/Util.lua", "Core/Items.lua", "Loot/LootLog.lua" }, nil, seed)
local L = ns.LootLog

local link = "|cnIQ4:|Hitem:19364::::::::60:::::::::|h[碧空之歌]|h|r"
local zh = {
    { "%s获得了物品：%sx%d。", false }, { "你获得了物品：%sx%d。", true },
    { "你获得了物品：%s。", true }, { "%s获得了物品：%s。", false },
}
local en = {
    { "You receive loot: %sx%d.", true }, { "%s receives loot: %sx%d.", false },
    { "You receive loot: %s.", true }, { "%s receives loot: %s.", false },
}

-- 解析
local who, l = L.ParseLootMessage("铁壁阿牛-无限获得了物品：" .. link .. "。", "我", zh)
T.eq(who, "铁壁阿牛", "别人拾取：获得者（去服务器后缀）")
T.eq(l, link, "物品链接")
who, l = L.ParseLootMessage("你获得了物品：" .. link .. "。", "我", zh)
T.eq(who, "我", "自己拾取")
T.eq(l, link, "自己拾取的链接")
who, l = L.ParseLootMessage("乙获得了物品：" .. link .. "x2。", "我", zh)
T.eq(who, "乙", "多件：获得者")
T.eq(l, link, "多件：链接不带数量")
who = L.ParseLootMessage("Bob receives loot: " .. link .. ".", "Me", en)
T.eq(who, "Bob", "英文客户端")
who = L.ParseLootMessage("You receive loot: " .. link .. "x3.", "Me", en)
T.eq(who, "Me", "英文客户端：自己多件")
T.eq(L.ParseLootMessage("乙获得了物品：[没有链接]。", "我", zh), nil, "没有物品链接不算")
T.eq(L.ParseLootMessage("乙获得了 5 金币。", "我", zh), nil, "不是物品拾取")
T.eq(L.ParseLootMessage(nil, "我", zh), nil, "非字符串")

-- 品质筛选
local filters = { [5] = true, [4] = true, [3] = false, [2] = false, [1] = true, [0] = true }
T.ok(L.QualityRecorded(4, filters), "紫色记录")
T.ok(not L.QualityRecorded(3, filters), "蓝色不记录")
T.ok(L.QualityRecorded(0, filters), "灰色跟随白色")
T.ok(not L.QualityRecorded(nil, filters), "品质未知不记录")

-- 自动扣分适用的品质
local opts = { purpleMode = true, blueMode = false, greenMode = true }
T.ok(L.DeductQuality(4, opts), "紫色扣分")
T.ok(not L.DeductQuality(3, opts), "蓝色未勾选不扣")
T.ok(L.DeductQuality(2, opts), "绿色扣分")
T.ok(not L.DeductQuality(5, opts), "橙色不参与自动扣分")

-- 扣分规则
local r = L.DeductRule(3, true, true, false)
T.eq(r.deduct, 3, "已整体完成：直接扣出分")
T.eq(r.msg:format("乙", 1), "乙 扣 3 分，还剩 1 分", "已完成时的文案")
T.eq(L.DeductRule(3, false, false, false), nil, "未许愿：不处理")
r = L.DeductRule(0, false, true, true)
T.ok(r.deduct == 0 and r.complete, "出 0 分且命中：完成不扣")
T.eq(r.msg:format("乙", 4), "乙 拿到了许愿的装备，还剩 4 分", "出 0 分命中文案")
r = L.DeductRule(0, false, true, false)
T.ok(r.deduct == 0 and not r.complete, "出 0 分未命中：不扣不完成")
T.eq(r.msg:format("乙", 4), "乙 出 0 分，不扣分，还剩 4 分", "出 0 分未命中文案")
r = L.DeductRule(4, false, true, true)
T.ok(r.deduct == 4 and not r.complete, "出 1~4 分：直接扣，完成由后续的许愿判定处理")
r = L.DeductRule(5, false, true, true)
T.ok(r.deduct == 0 and r.complete, "出 5 分命中：免扣并完成")
T.eq(r.msg:format("乙", 4), "乙 拿到了许愿的装备（出 5 分，不扣分），还剩 4 分", "出 5 分命中文案")
r = L.DeductRule(5, false, true, false)
T.ok(r.deduct == 5 and not r.complete, "出 5 分不符：扣 5")
T.eq(r.msg:format("乙", 0), "乙 出了 5 分但这件不是许愿的装备，扣 5 分，还剩 0 分", "出 5 分不符文案")
r = L.DeductRule(9, false, true, true)
T.ok(r.deduct == 4 and r.complete, "出 9 分：完成并扣 4")
T.eq(r.msg:format("乙", 0), "乙 拿到了许愿的装备，另扣 4 分，还剩 0 分", "出 9 分文案")
r = L.DeductRule(7, false, true, false)
T.ok(r.deduct == 2 and not r.complete, "出 7 分不符：扣 2，不完成")

-- 拍卖结果编码
T.same(L.DecodeSold("乙:3"), { winner = "乙", score = 3 }, "解码出分结果")
T.same(L.DecodeSold("乙:r92"), { winner = "乙", roll = 92 }, "解码 Roll 结果")
T.eq(L.DecodeSold(""), nil, "空串")
T.same(L.DecodeSold("!m"), { manual = true }, "手动标记已拍")
T.same(L.DecodeSold("!n"), { none = true }, "流拍")
