-- Core/Items.lua 的离线测试
-- 链接样本：|cn 格式与"无限"客户端实测一致（见 docs/探测结果.md）。
local T = ...

-- 假的 Compat / Events：物品信息表由测试控制
local itemDB = {}
local requested = {}
local subs = {}
local seed = {
    Compat = {
        GetItemInfo = function(id)
            local i = itemDB[id]
            if i then return i.name, i.link, i.quality, i.icon end
        end,
        RequestItem = function(id) requested[#requested + 1] = id end,
    },
    Events = {
        On = function(_, ev, fn) subs[ev] = fn end,
        Off = function(_, ev) subs[ev] = nil end,
    },
    Log = function() end,
    LogLevel = { ERROR = 0 },
}
local ns = T.load({ "Core/Util.lua", "Core/Items.lua" }, nil, seed)
local I = ns.Items

-- 样本
local OLD = "|cffa335ee|Hitem:19364:0:0:0|h[碧空之歌]|h|r"                      -- |cAARRGGBB 颜色格式
local NEW = "|cnIQ4:|Hitem:19364::::::::60:::::::::|h[碧空之歌]|h|r"            -- 正式服 |cn 格式
local LONG = "|cnIQ4:|Hitem:212395::::::::80:268::13:3:10354:6652:1540:6:28:2876:29:36:30:49:38:8:40:1234:45:221123:::::|h[迅击戒指]|h|r"
local ATLAS = "|cnIQ3:|Hitem:191300::::::::70:::::::::|h[药水 |A:Professions-ChatIcon-Quality-Tier3:17:17::1|a]|h|r"

-- ParseLinks
local l = I.ParseLinks(OLD)
T.eq(#l, 1, "旧格式：一条")
T.eq(l[1].id, 19364, "旧格式：ID")
T.eq(l[1].name, "碧空之歌", "旧格式：名字不带中括号")
T.eq(l[1].link, OLD, "旧格式：完整链接含颜色段和 |r")

l = I.ParseLinks(NEW)
T.eq(l[1].id, 19364, "|cn 格式：ID")
T.eq(l[1].name, "碧空之歌", "|cn 格式：名字")
T.eq(l[1].link, NEW, "|cn 格式：完整链接")

l = I.ParseLinks(LONG)
T.eq(l[1].id, 212395, "长附加字段：ID")
T.eq(l[1].name, "迅击戒指", "长附加字段：名字")
T.eq(l[1].link, LONG, "长附加字段：完整链接")

l = I.ParseLinks(ATLAS)
T.eq(l[1].name, "药水", "名字里的品阶图标被去掉")

l = I.ParseLinks("xy " .. OLD .. NEW .. " 和 " .. LONG)
T.eq(#l, 3, "多条链接")
T.eq(l[3].id, 212395, "第三条 ID")
T.eq(l[1].s, 4, "起点位置")

l = I.ParseLinks("|Hitem:123:0|h[无色链接]|h")
T.eq(l[1].id, 123, "没有颜色段也能解析")
T.eq(#I.ParseLinks("没有链接 [手打]"), 0, "无链接")
T.eq(#I.ParseLinks(nil), 0, "非字符串")
T.eq(#I.ParseLinks("|Hspell:123|h[法术]|h"), 0, "非物品链接忽略")

-- LinkID / LinkQuality
T.eq(I.LinkID(NEW), 19364, "LinkID")
T.eq(I.LinkID("无"), nil, "LinkID 无链接")
T.eq(I.LinkQuality(NEW), 4, "|cnIQ4: 品质")
T.eq(I.LinkQuality(OLD), 4, "十六进制颜色品质")
T.eq(I.LinkQuality("|cff0070dd|Hitem:1|h[a]|h|r"), 3, "蓝色")
T.eq(I.LinkQuality("[a]"), nil, "无法判断")

-- ParseBracketNames / StripLinks
local b = I.ParseBracketNames("xy [手打物品] " .. OLD .. "[ 另一个 ][]")
T.same(b, { "手打物品", "另一个" }, "只取链接外的 [名字]")
T.same(I.ParseBracketNames(OLD .. NEW), {}, "链接里的名字不算")
T.eq(I.StripLinks("a" .. OLD .. "b"), "a b", "StripLinks")

-- CleanName
T.eq(I.CleanName("[碧空 之歌]"), "碧空之歌", "CleanName 去括号和空格")
T.eq(I.CleanName("|cffa335ee[Sky Song]|r"), "skysong", "CleanName 去颜色转小写")

-- SameItem
T.ok(I.SameItem(OLD, NEW), "ID 相同")
T.ok(I.SameItem(19364, NEW), "数字 ID 与链接")
T.ok(not I.SameItem(OLD, LONG), "ID 不同")
T.ok(I.SameItem("[碧空之歌]", "碧空之歌"), "名字相同（括号写法）")
T.ok(I.SameItem("碧空之歌", NEW), "手打名字与链接名字")
T.ok(not I.SameItem("[梦境碎片]", "[公式：永恒梦境碎片]"), "名字互为子串必须判为不同")
T.ok(not I.SameItem("公式：永恒梦境碎片", "梦境碎片"), "反向子串也不同")
T.ok(not I.SameItem("", ""), "空名字不相同")
T.ok(not I.SameItem(nil, OLD), "nil")
T.ok(I.SameItem({ id = 5, name = "甲" }, { id = 5, name = "乙" }), "都有 ID 时只比 ID")
T.ok(not I.SameItem({ id = 5, name = "甲" }, { id = 6, name = "甲" }), "ID 不同即使名字相同")
itemDB[777] = { name = "已缓存物品", link = "|cnIQ4:|Hitem:777|h[已缓存物品]|h|r", quality = 4, icon = 1 }
T.ok(I.SameItem(777, "已缓存物品"), "一边只有 ID 时用缓存里的名字比")
T.ok(not I.SameItem(888, "未缓存物品"), "ID 未缓存时无法判定为相同")

-- Get / GetCached
I._Reset()
local got
I.Get(777, function(info) got = info end)
T.eq(got and got.name, "已缓存物品", "已缓存时立即回调")
T.eq(I.GetCached(777).quality, 4, "GetCached")

got = "未回调"
local got2 = "未回调"
I.Get(999, function(info) got = info end)
I.Get(999, function(info) got2 = info end)
T.eq(got, "未回调", "未缓存时不立即回调")
T.eq(requested[#requested], 999, "发出加载请求")
T.ok(subs.GET_ITEM_INFO_RECEIVED ~= nil, "订阅 GET_ITEM_INFO_RECEIVED")
subs.GET_ITEM_INFO_RECEIVED(999, true)          -- 事件到了但信息仍取不到：继续等
T.eq(got, "未回调", "信息未就绪时继续等待")
itemDB[999] = { name = "迟到物品", link = "x", quality = 3, icon = 2 }
subs.GET_ITEM_INFO_RECEIVED(999, true)
T.eq(got and got.name, "迟到物品", "信息到达后回调")
T.eq(got2 and got2.name, "迟到物品", "同一物品的多个回调都执行")
T.eq(subs.GET_ITEM_INFO_RECEIVED, nil, "没有待取物品后取消订阅")

local failed = "未回调"
I.Get(4040, function(info) failed = info end)
subs.GET_ITEM_INFO_RECEIVED(4040, false)
T.eq(failed, nil, "物品不存在时回调 nil")
