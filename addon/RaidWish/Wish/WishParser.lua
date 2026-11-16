-- Wish/WishParser.lua：聊天文本 → 许愿条目（纯逻辑）
--
-- 所有许愿消息都要通过同一套内容校验；"地板"是唯一允许的非物品关键字。
local ADDON, ns = ...

local Parser = {}
ns.WishParser = Parser

Parser.FLOOR_NAME = "地板"

-- 中文输入法打出的全角括号【】［］当成 [ ] 处理（物品链接里的 [ ] 本来就是半角，不受影响）
function Parser.NormalizeBrackets(text)
    return (text:gsub("【", "["):gsub("】", "]"):gsub("［", "["):gsub("］", "]"))
end

-- 校验许愿内容并提取物品。
-- 只允许物品链接和 [物品名]，可以用空白分隔；至少要有一件；夹杂其他文字则无效。
-- 返回物品数组，无效时返回 nil。
function Parser.ExtractItems(content)
    if type(content) ~= "string" then return nil end
    local trimmed = ns.Util.Trim(Parser.NormalizeBrackets(content))
    if trimmed == "" then return nil end

    -- "地板"许愿：xy 地板 或 xy [地板]
    local bare = trimmed:match("^%[%s*(.-)%s*%]$") or trimmed
    if bare == Parser.FLOOR_NAME then
        return { { name = Parser.FLOOR_NAME, floor = true, done = false } }
    end

    local links = ns.Items.ParseLinks(trimmed)
    local rest = ns.Items.StripLinks(trimmed)
    local names = {}
    rest = rest:gsub("%[(.-)%]", function(inner)
        names[#names + 1] = inner
        return " "
    end)
    if rest:find("%S") then return nil end              -- 夹杂其他文字

    local items, seenId, seenName = {}, {}, {}
    -- 先放物品链接，再放手打名字，各自去重
    for _, l in ipairs(links) do
        if l.id and not seenId[l.id] then
            seenId[l.id] = true
            seenName[ns.Items.CleanName(l.name)] = true
            items[#items + 1] = { id = l.id, name = l.name, done = false }
        end
    end
    for _, raw in ipairs(names) do
        local name = ns.Util.Trim(raw)
        local key = ns.Items.CleanName(name)
        if key ~= "" and not seenName[key] then
            seenName[key] = true
            items[#items + 1] = { name = name, done = false }
        end
    end
    if #items == 0 then return nil end
    return items
end

-- 每人最多许愿 max 件：只保留前 max 件（顺序为先物品链接、后手打名字；"地板"也算一件）。
-- max 为 0 或空表示不限。返回新数组和被去掉的件数。
function Parser.Limit(items, max)
    max = tonumber(max) or 0
    if max <= 0 or #items <= max then return items, 0 end
    local out = {}
    for i = 1, max do out[i] = items[i] end
    return out, #items - max
end

-- 解析一条团队聊天。opts.xyOnly 为真时只认 xy / txy 开头的消息。
-- 返回 { kind = "wish" | "proxy" | "invalid" | "none", target = 代许愿对象, items = 物品数组, raw = 原文 }
--   wish：发言者本人许愿；proxy：txy 代别人许愿；
--   invalid：是许愿指令但内容不合法（调用方保持原许愿不变）；none：不是许愿消息。
function Parser.Parse(text, opts)
    opts = opts or {}
    if type(text) ~= "string" then return { kind = "none" } end
    local msg = ns.Util.Trim(Parser.NormalizeBrackets(text))

    -- txy 名 姓 物品：代许愿。名字可能有空格，物品从第一个链接、[ 或"地板"开始。
    local target, content
    local rest = msg:match("^[Tt][Xx][Yy]%s+(.+)$")
    if rest then
        local at = rest:find("[|%[]")
        if at and at > 1 then
            target, content = rest:sub(1, at - 1), rest:sub(at)
        else
            target = rest:match("^(.-)%s*" .. Parser.FLOOR_NAME .. "$")
            if target then content = Parser.FLOOR_NAME
            else target, content = rest:match("^(%S+)%s+(.+)$") end
        end
        target = target and ns.Util.Trim(target)
        if target == "" then target = nil end
    end
    if target and content then
        local items = Parser.ExtractItems(content)
        if not items then return { kind = "invalid", raw = msg, target = target } end
        return { kind = "proxy", target = target, items = items, raw = msg }
    end

    -- xy 开头（不分大小写，后面可以没有空格）
    if msg:sub(1, 2):lower() == "xy" then
        local items = Parser.ExtractItems(msg:sub(3))
        if not items then return { kind = "invalid", raw = msg } end
        return { kind = "wish", items = items, raw = msg }
    end

    -- 非"仅 xy 模式"下，消息里含物品链接即视为许愿（仍要通过同样的校验）
    if not opts.xyOnly and msg:find("|Hitem:") then
        local items = Parser.ExtractItems(msg)
        if not items then return { kind = "invalid", raw = msg } end
        return { kind = "wish", items = items, raw = msg }
    end

    return { kind = "none" }
end
