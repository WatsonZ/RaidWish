-- Wish/WishModel.lua 的离线测试
local T = ...
local seed = { Compat = { GetItemInfo = function() return nil end, RequestItem = function() end },
    Events = { On = function() end, Off = function() end }, Log = function() end, LogLevel = { ERROR = 0 } }
local ns = T.load({ "Core/Util.lua", "Core/Items.lua", "Wish/WishModel.lua" }, nil, seed)
local M = ns.WishModel

local fired = {}
local clock = 1000
local store = {}
local m = M.New(store, function(ev, name) fired[#fired + 1] = { ev, name } end, function() return clock end)

local roster = { { name = "甲", class = "WARRIOR" }, { name = "乙", class = "MAGE" }, { name = "丙", class = "PRIEST" } }

-- Ensure / EnsureMembers
local rec = m:Ensure("甲", "WARRIOR", 4)
T.eq(rec.dkp, 4, "新记录默认分")
T.eq(rec.class, "WARRIOR", "职业")
T.eq(rec.wish, nil, "新记录未许愿")
T.eq(fired[#fired][1], "RW_WISH_CHANGED", "触发变更事件")
T.eq(m:Ensure("甲", "WARRIOR", 9).dkp, 4, "已有记录不改分数")
store["甲"].dkp = "3"
T.eq(m:Ensure("甲", nil, 4).dkp, 3, "字符串分数转为数字")
T.eq(m:EnsureMembers(roster, 4), 2, "补建两名成员")
T.eq(m:EnsureMembers(roster, 4), 0, "已全部存在")
T.eq(m:Ensure("", nil, 4), nil, "空名字不建记录")

-- SetWish / HasWish / WishText
local A = { id = 19364, name = "碧空之歌", done = false }
local B = { id = 212395, name = "迅击戒指", done = false }
local N = { name = "手打物品", done = false }
T.ok(m:SetWish("甲", { A, B }, "xy ..."), "设置许愿")
T.ok(M.HasWish(store["甲"]), "HasWish")
T.ok(not m:SetWish("甲", {}, "xy"), "空物品列表无效")
T.eq(#store["甲"].wish.items, 2, "无效许愿不改原许愿")
T.ok(not m:SetWish("无此人", { A }), "无记录不能许愿")
A.done = true
T.eq(store["甲"].wish.items[1].done, false, "SetWish 复制物品，不共享引用")
A.done = false
T.eq(M.WishText(store["甲"], function(id) return id == 19364 and "<L19364>" or nil end), "<L19364> [迅击戒指]", "WishText")

-- 加减分
T.eq(m:AddDkp("甲", 2), 5, "加分")
T.eq(m:AddDkp("甲", -3), 2, "扣分")
T.eq(m:AddDkp("无此人", 1), nil, "无记录")
T.eq(m:SetDkp("乙", 7), 7, "设分")

-- 匹配与查询
m:SetWish("乙", { { id = 19364, name = "碧空之歌" } })
m:SetWish("丙", { N })
T.ok(M.WantsItem(store["甲"], 19364), "按 ID 匹配")
T.ok(M.WantsItem(store["丙"], "[手打物品]"), "手打名字匹配")
T.ok(not M.WantsItem(store["丙"], "物品"), "子串不匹配")
T.eq(m:CountWishers(19364, roster), 2, "两人许愿同一物品")
T.eq(m:CountWishers(19364, { "甲" }), 1, "只算在团成员")
local wp = m:WishPlayers(19364, roster)
T.eq(#wp, 2, "WishPlayers 人数")
T.eq(wp[1].name, "乙", "按名字排序（UTF-8 字节序）")
local w, u, d = m:Counts(roster)
T.eq(w .. "/" .. u .. "/" .. d, "3/0/1", "已许愿/未许愿/重复件数")
m:ClearWish("丙")
T.same(m:Unwished(roster), { "丙" }, "未许愿名单按团队顺序")
u = select(2, m:Counts(roster))
T.eq(u, 1, "清除后未许愿 1 人")

-- 完成标记
T.ok(not M.IsFullyDone(store["甲"]), "未完成")
T.ok(m:MarkItemDone("甲", 19364), "掉落命中，标记一件完成")
T.ok(not M.WantsItem(store["甲"], 19364), "已完成的物品不再算许愿")
T.ok(not m:MarkItemDone("甲", 19364), "同一物品不会重复标记")
T.ok(not M.IsFullyDone(store["甲"]), "部分完成不算整体完成")
T.eq(M.WishText(store["甲"]), "[碧空之歌]（已完成） [迅击戒指]", "部分完成的文字")
T.ok(m:MarkAllDone("甲"), "手动标记全部完成")
T.ok(M.IsFullyDone(store["甲"]), "整体完成")
T.eq(M.WishText(store["甲"]), "许愿已全部拿到", "完成后的文字")
T.ok(not m:MarkAllDone("甲"), "已是完成状态")
T.ok(m:CanUndo("甲"), "可以撤销")
T.ok(m:UndoDone("甲"), "撤销")
T.eq(store["甲"].wish.items[1].done, true, "撤销恢复到标记前：第一件仍是掉落完成")
T.eq(store["甲"].wish.items[2].done, false, "第二件恢复为未完成")
T.ok(not m:UndoDone("甲"), "没有可撤销的记录")
T.ok(not m:MarkAllDone("丙"), "没有许愿不能标记")

-- 地板
m:SetWish("丙", { { name = "地板", floor = true } })
T.ok(M.IsFloor(store["丙"]), "地板许愿")
T.eq(#m:FloorPlayers(roster), 1, "地板玩家")
T.ok(not M.WantsItem(store["丙"], "地板"), "地板不与具体物品匹配")
T.eq(M.WishText(store["丙"]), "地板", "地板文字")

-- 编码
local enc = M.EncodeItems({ { id = 19364, done = false }, { name = "某;物品:名", done = true }, { floor = true, name = "地板" } })
T.eq(enc, "19364:0;n:某；物品:名:1;f:0", "EncodeItems（名字里的 ; 换成全角）")
local dec = M.DecodeItems(enc)
T.eq(#dec, 3, "DecodeItems 条数")
T.eq(dec[1].id, 19364, "解码 ID")
T.eq(dec[2].name, "某；物品:名", "解码名字（名字里可以有冒号）")
T.eq(dec[2].done, true, "解码完成标记")
T.ok(dec[3].floor, "解码地板")
T.same(M.DecodeItems(""), {}, "空串")
T.same(M.DecodeItems("坏数据;;1:x"), {}, "坏数据忽略")

-- 排序
m:SetDkp("甲", 1); m:SetDkp("乙", 9); m:SetDkp("丙", 5)
local s = m:Sorted("dkp", false, roster)
T.eq(s[1].name .. s[2].name .. s[3].name, "乙丙甲", "按分数降序")
s = m:Sorted("dkp", true)
T.eq(s[1].name, "甲", "按分数升序")
m:SetDkp("丙", 1)
s = m:Sorted("dkp", true)
T.eq(s[1].name .. s[2].name, "丙甲", "同分按名字")
s = m:Sorted("class", true)
T.eq(s[1].rec.class, "MAGE", "按职业")

-- 初始化分数、增量写入、整表替换、清空
m:Ensure("离队者", "ROGUE", 4)
m:InitScores(roster, 6)
T.eq(store["甲"].dkp + store["乙"].dkp + store["丙"].dkp, 18, "在团成员分数都改为 6")
T.eq(store["离队者"].dkp, 4, "离队成员不改")
T.ok(m:ApplyRow("丁", "DRUID", "3", { { id = 1, done = false } }), "新行：许愿有变化")
T.eq(store["丁"].dkp, 3, "分数存为数字")
T.ok(not m:ApplyRow("丁", "DRUID", 2, { { id = 1, done = false } }), "只改分数：许愿未变")
T.ok(m:ApplyRow("丁", "", 2, {}), "清空许愿算变化")
T.eq(store["丁"].class, "DRUID", "空职业不覆盖")
local ref = store
m:ReplaceAll({ ["戊"] = { dkp = 1 } })
T.ok(m.store == ref and store["甲"] == nil and store["戊"].dkp == 1, "就地替换，保持存档表引用")
m:ClearAll()
T.eq(next(store), nil, "清空")
