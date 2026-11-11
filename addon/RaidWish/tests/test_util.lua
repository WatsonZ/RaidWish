-- Core/Util.lua 的离线测试
local T = ...
local ns = T.load({ "Core/Util.lua" })
local U = ns.Util

-- Trim / StripColor / CleanString
T.eq(U.Trim("  a b  "), "a b", "Trim 两端空白")
T.eq(U.Trim(nil), "", "Trim 非字符串")
T.eq(U.StripColor("|cffa335ee[碧空之歌]|r"), "[碧空之歌]", "去掉 |cAARRGGBB")
T.eq(U.StripColor("|cnIQ4:[碧空之歌]|r"), "[碧空之歌]", "去掉 |cnIQ4: 形式")
T.eq(U.CleanString(" |cffa335ee[碧空 之歌]|r "), "[碧空之歌]", "CleanString 去颜色和空白")
T.eq(U.CleanString("ABC d"), "abcd", "CleanString 转小写")
T.eq(U.CleanString(nil), "", "CleanString 非字符串")

-- Pad2 / FormatTime
T.eq(U.Pad2(5), "05", "Pad2 补零")
T.eq(U.Pad2(12), "12", "Pad2 两位")
local ts = os.time({ year = 2026, month = 11, day = 10, hour = 9, min = 7, sec = 0 })
T.eq(U.FormatTime(ts), "09:07", "FormatTime 数字时间戳")
T.ok(U.FormatTime():match("^%d%d:%d%d$"), "FormatTime 无参数取当前时间")

-- NormName
T.eq(U.NormName("圣光老王-无限"), "圣光老王", "去掉服务器后缀")
T.eq(U.NormName("圣光老王"), "圣光老王", "无后缀保持不变")
T.eq(U.NormName("|cffF48CBA圣光老王|r"), "圣光老王", "去掉颜色码")
T.eq(U.NormName(" Bob-Realm "), "Bob", "英文名去空白和后缀")
T.eq(U.NormName(nil), "", "非字符串")
U.keepRealm = true
T.eq(U.NormName("圣光老王-无限"), "圣光老王-无限", "keepRealm 时保留后缀")
U.keepRealm = false
T.eq(U.ShortName("圣光老王-无限"), "圣光老王", "ShortName")

-- 职业
T.eq(U.NormClass("WARRIOR"), "WARRIOR", "英文标识")
T.eq(U.NormClass("Warlock"), "WARLOCK", "英文显示名")
T.eq(U.NormClass("萨满祭司"), "SHAMAN", "中文显示名")
T.eq(U.NormClass("潜行者"), "ROGUE", "正式服中文名")
T.eq(U.NormClass("mage"), "MAGE", "小写英文")
T.eq(U.NormClass("未知"), nil, "认不出返回 nil")
T.eq(U.ClassColorHex("PALADIN"), "F48CBA", "兜底职业色")
T.eq(U.ClassColorHex("???"), "999999", "未知职业为灰色")
local ns2 = T.load({ "Core/Util.lua" }, { RAID_CLASS_COLORS = { MAGE = { r = 1, g = 0, b = 0 } } })
T.eq(ns2.Util.ClassColorHex("法师"), "FF0000", "优先使用 RAID_CLASS_COLORS")
T.eq(U.ClassColoredName("冰霜小法", "MAGE"), "|cff3FC7EB冰霜小法|r", "带色名字")

-- FormatToPattern / MatchFormat
local p = U.FormatToPattern("%s获得了物品：%s。")
T.eq(p, "^(.-)获得了物品：(.-)。$", "LOOT_ITEM 中文模式")
local who, item = U.MatchFormat("铁壁阿牛获得了物品：|cffa335ee|Hitem:19364::|h[碧空之歌]|h|r。", "%s获得了物品：%s。")
T.eq(who, "铁壁阿牛", "解析获得者")
T.eq(item, "|cffa335ee|Hitem:19364::|h[碧空之歌]|h|r", "解析物品链接")

local n, r, lo, hi = U.MatchFormat("Bob rolls 87 (1-100)", "%s rolls %d (%d-%d)")
T.eq(n, "Bob", "RANDOM_ROLL_RESULT 英文：名字")
T.eq(r, "87", "点数")
T.eq(lo .. "-" .. hi, "1-100", "范围")
n, r = U.MatchFormat("冰霜小法掷出92（1-100）", "%s掷出%d（%d-%d）")
T.eq(n, "冰霜小法", "RANDOM_ROLL_RESULT 中文：名字")
T.eq(r, "92", "中文：点数")

-- 带位置的参数：按格式串参数顺序返回
local a, b = U.MatchFormat("物品X 给了 Bob", "%2$s 给了 %1$s")
T.eq(a, "Bob", "位置参数 1")
T.eq(b, "物品X", "位置参数 2")

local who2, item2, cnt = U.MatchFormat("Bob receives loot: [X]x3.", "%s receives loot: %sx%d.")
T.eq(who2 .. "|" .. item2 .. "|" .. cnt, "Bob|[X]|3", "LOOT_ITEM_MULTIPLE")
T.eq(U.MatchFormat("完全不相关", "%s获得了物品：%s。"), nil, "不匹配返回 nil")
T.eq(U.FormatToPattern("100%% (a+b)"), "^100%% %(a%+b%)$", "字面百分号和特殊字符转义")

-- 两段名字参数
T.eq(select(1, U.TakeName({ "add", "张三", "李四", "原因" }, 2)), "张三 李四", "名 姓 合成完整名字")
T.eq(select(2, U.TakeName({ "add", "张三", "李四", "原因" }, 2)), 4, "下一个参数是原因")
T.eq(select(1, U.TakeName({ "add", "张三" }, 2)), "张三", "只有一段时用这一段")
T.eq(U.TakeName({ "add" }, 2), nil, "没有名字")
T.eq(U.NormName("张三 李四"), "张三 李四", "名字中间的空格保留")
