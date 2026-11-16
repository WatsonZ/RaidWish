-- Wish/WishParser.lua 的离线测试
local T = ...
local seed = { Compat = { GetItemInfo = function() return nil end, RequestItem = function() end },
    Events = { On = function() end, Off = function() end }, Log = function() end, LogLevel = { ERROR = 0 } }
local ns = T.load({ "Core/Util.lua", "Core/Items.lua", "Wish/WishParser.lua" }, nil, seed)
local P = ns.WishParser

local L1 = "|cnIQ4:|Hitem:19364::::::::60:::::::::|h[碧空之歌]|h|r"
local L2 = "|cffa335ee|Hitem:212395:0:0:0|h[迅击戒指]|h|r"

local function ids(r)
    local out = {}
    for _, it in ipairs(r.items or {}) do out[#out + 1] = it.id or it.name end
    return table.concat(out, ",")
end

-- xy + 链接
local r = P.Parse("xy " .. L1)
T.eq(r.kind, "wish", "xy 链接")
T.eq(ids(r), "19364", "一件物品")
T.eq(r.items[1].name, "碧空之歌", "物品名")
T.eq(r.items[1].done, false, "未完成")

-- 大小写、无空格、多物品
r = P.Parse("XY" .. L1 .. L2)
T.eq(r.kind, "wish", "XY 大写且无空格")
T.eq(ids(r), "19364,212395", "两件物品")
r = P.Parse("  Xy  " .. L1 .. "  " .. L2 .. "  ")
T.eq(ids(r), "19364,212395", "前后和中间多余空白")

-- 去重
r = P.Parse("xy " .. L1 .. L1 .. "[碧空之歌]")
T.eq(ids(r), "19364", "同一物品链接与手打名字去重")

-- 手打 [物品名]
r = P.Parse("xy [手打物品]")
T.eq(r.kind, "wish", "手打名字")
T.eq(ids(r), "手打物品", "名字")
T.eq(r.items[1].id, nil, "手打名字没有 ID")
r = P.Parse("xy [甲][ 乙 ]" .. L2)
T.eq(ids(r), "212395,甲,乙", "链接在前，手打名字在后，名字去空白")
r = P.Parse("xy [甲][甲]")
T.eq(ids(r), "甲", "手打名字去重")

-- 地板
r = P.Parse("xy 地板")
T.eq(r.kind, "wish", "xy 地板")
T.ok(r.items[1].floor, "地板标记")
r = P.Parse("xy[地板]")
T.ok(r.items[1].floor, "xy [地板]")

-- 非法内容
T.eq(P.Parse("xy 我要 " .. L1).kind, "invalid", "夹杂其他文字")
T.eq(P.Parse("xy").kind, "invalid", "只有 xy")
T.eq(P.Parse("xy []").kind, "invalid", "空中括号")
T.eq(P.Parse("xyz 哈哈").kind, "invalid", "xy 开头的普通聊天判为无效（不改原许愿）")
T.eq(P.Parse("xy 碧空之歌").items[1].name, "碧空之歌", "不带括号的名字也算许愿")

-- txy 代许愿
r = P.Parse("txy 圣光老王 " .. L1)
T.eq(r.kind, "proxy", "txy")
T.eq(r.target, "圣光老王", "代许愿对象")
T.eq(ids(r), "19364", "代许愿物品")
r = P.Parse("TXY 某人 [手打][另一个]")
T.eq(r.kind, "proxy", "TXY 大写")
T.eq(ids(r), "手打,另一个", "代许愿多件")
r = P.Parse("txy 某人 要这个 " .. L1)
T.eq(r.target, "某人 要这个", "链接前面的文字都当作名字（团里没有这个人，录入时会被忽略）")
r = P.Parse("txy 某人 某某 要这个 " .. L1 .. " 哈")
T.eq(r.kind, "invalid", "txy 链接和文字混在一起：无效")
T.eq(r.target, "某人 某某 要这个", "无效时仍给出对象")
T.eq(P.Parse("txy 某人").kind, "none", "txy 缺物品：不是许愿消息（至少要有 3 个词）")

-- 非 xy 模式：直接贴链接
r = P.Parse(L1)
T.eq(r.kind, "wish", "直接贴链接视为许愿")
r = P.Parse(L1 .. " " .. L2)
T.eq(ids(r), "19364,212395", "直接贴多个链接")
T.eq(P.Parse("看看这个 " .. L1).kind, "invalid", "贴链接但夹杂文字：无效")
T.eq(P.Parse(L1, { xyOnly = true }).kind, "none", "仅 xy 模式下直接贴链接不算")
T.eq(P.Parse("xy " .. L1, { xyOnly = true }).kind, "wish", "仅 xy 模式下 xy 仍有效")

-- 普通聊天
T.eq(P.Parse("大家好").kind, "none", "普通聊天")
T.eq(P.Parse("[手打物品]").kind, "none", "只有手打名字、不带 xy：不是许愿")
T.eq(P.Parse("3").kind, "none", "出分数字")
T.eq(P.Parse(nil).kind, "none", "非字符串")

-- 每人最多许愿件数
local three = P.Parse("xy " .. L1 .. L2 .. "[手打物品]").items
local one, cut = P.Limit(three, 1)
T.eq(#one .. "/" .. cut, "1/2", "上限 1：保留 1 件，去掉 2 件")
T.eq(one[1].id, 19364, "保留第一件（物品链接在前）")
T.eq(#P.Limit(three, 2), 2, "上限 2")
T.eq(#P.Limit(three, 0), 3, "0 表示不限")
T.eq(#P.Limit(three, 5), 3, "上限大于件数时不变")
T.eq(#P.Limit(three, nil), 3, "未设置时不限")

-- txy 两段名字
local r1 = P.Parse("txy 张三 李四 " .. L1)
T.eq(r1.kind .. "/" .. r1.target, "proxy/张三 李四", "txy 名 姓 物品链接")
local r2 = P.Parse("txy 张三 李四 [手打物品]")
T.eq(r2.target .. "/" .. r2.items[1].name, "张三 李四/手打物品", "txy 名 姓 [手打]")
local r3 = P.Parse("txy 张三 李四 地板")
T.eq(r3.target .. "/" .. tostring(r3.items[1].floor), "张三 李四/true", "txy 名 姓 地板")
local r4 = P.Parse("txy 张三 " .. L1)
T.eq(r4.target, "张三", "txy 只写名")
T.eq(P.Parse("txy 张三 李四 墓碑节杖").target .. "/" .. P.Parse("txy 张三 李四 墓碑节杖").items[1].name, "张三 李四/墓碑节杖", "txy 名 姓 物品名（不带括号）")

-- 全角括号（中文输入法）
T.eq(P.Parse("xy【墓碑节杖】").items[1].name, "墓碑节杖", "【】当成 [ ]")
T.eq(P.Parse("xy ［墓碑节杖］").items[1].name, "墓碑节杖", "［］当成 [ ]")
T.eq(P.Parse("xy【地板】").items[1].floor, true, "【地板】")
T.eq(P.Parse("txy 张三 李四 【手打物品】").target, "张三 李四", "txy 名 姓 【物品】")
T.eq(P.Parse("xy 墓碑节杖").items[1].name, "墓碑节杖", "xy 物品名（不带括号）")
local multi = P.Parse("xy 墓碑节杖 碧空之歌、迅击戒指").items
T.eq(#multi .. "/" .. multi[3].name, "3/迅击戒指", "不带括号的多件：空格或、分隔")
T.eq(P.Parse("xy 我要这个 [墓碑节杖]").kind, "invalid", "文字和括号混在一起仍然无效")
T.eq(P.Parse("xyz 哈哈").kind, "invalid", "xy 后面没有空格的普通聊天不算")
T.eq(P.Parse("xy 地板").items[1].floor, true, "xy 地板 仍是地板")

-- 不带括号的文字（简称）：记成许愿，但标为 text
local ft = P.Parse("xy 墓碑").items[1]
T.eq(tostring(ft.text) .. "/" .. ft.name, "true/墓碑", "不带括号的文字标为 text")
T.eq(P.Parse("xy [墓碑节杖]").items[1].text, nil, "带括号的名字不是 text")

