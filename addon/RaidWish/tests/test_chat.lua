-- ns.Chat.SplitText（Wish/WishChat.lua）的离线测试
local T = ...
local seed = {
    Compat = { GetItemInfo = function() return nil end, RequestItem = function() end },
    Events = { On = function() end, Off = function() end, Fire = function() end },
    Slash = { Register = function() end, RegisterDebug = function() end },
    Log = function() end, LogLevel = { ERROR = 0 },
}
local ns = T.load({ "Core/Util.lua", "Core/Items.lua", "Wish/WishChat.lua" }, nil, seed)
local Split = ns.Chat.SplitText

T.same(Split("短消息", 255), { "短消息" }, "不超长原样返回")

-- 未许愿名单：40 个中文名，按空格断开
local names = {}
for i = 1, 40 do names[i] = "玩家名字" .. i end
local text = "还没许愿的有：" .. table.concat(names, " ")
local parts = Split(text, 255)
T.ok(#parts >= 2, "长名单拆成多条")
local joined = {}
for i, p in ipairs(parts) do
    T.ok(#p <= 255, "每条不超过 255 字节 " .. i)
    T.ok(not p:find("^%s") and not p:find("%s$"), "首尾无空白 " .. i)
    joined[#joined + 1] = p
end
T.eq(table.concat(joined, " "), text, "按空格断开，拼回原文")

-- 不切断中文字符
local zh = string.rep("许", 200)
for i, p in ipairs(Split(zh, 255)) do T.eq(#p % 3, 0, "中文不被切断 " .. i) end

-- 不切断物品链接
local link = "|cnIQ4:|Hitem:19364::::::::60:::::::::|h[碧空之歌]|h|r"
local many = {}
for i = 1, 8 do many[i] = link end
local lp = Split("「碧空之歌」有 8 人许愿：" .. table.concat(many, "、"), 255)
local total = 0
for _, p in ipairs(lp) do
    T.ok(#p <= 255, "含链接时每条不超长")
    local _, n = p:gsub("|Hitem:", "")
    local _, m = p:gsub("|h|r", "")
    T.eq(n, m, "链接完整（开头与结尾数量相等）")
    total = total + n
end
T.eq(total, 8, "8 个链接一个不少")

-- 在"、"之后断开
local enumer = {}
for i = 1, 30 do enumer[i] = "某某某某" .. i .. "（4分）" end
local ep = Split(table.concat(enumer, "、"), 255)
T.ok(ep[1]:sub(-3) == "、" or ep[1]:find("分）$"), "在分隔符处断开")
