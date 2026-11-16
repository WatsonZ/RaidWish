-- Core/Items.lua：物品链接解析、物品匹配、物品信息异步获取与缓存
-- 以物品 ID 为准。解析只依赖 "|Hitem:<id>" 和 "|h[名字]|h"，不依赖颜色段格式。
-- 解析与匹配是纯逻辑；Get / GetCached 通过 ns.Compat 和 ns.Events 访问游戏（调用时才取，便于测试注入）。
local ADDON, ns = ...

local Items = {}
ns.Items = Items

------------------------------------------------------------------------
-- 名字清理
------------------------------------------------------------------------

-- 名字比较用的规范形式：
-- 去掉图标标记 |A...|a、颜色码、全部空白、外层中括号，转小写。
function Items.CleanName(name)
    if type(name) ~= "string" then return "" end
    name = name:gsub("|A.-|a", "")
    name = ns.Util.CleanString(name)
    name = name:gsub("%[([^%]]*)%]", "%1")
    return name
end

-- 显示用的名字：去掉图标标记、颜色码和外层中括号，保留空格与大小写
local function DisplayName(text)
    text = text:gsub("|A.-|a", "")
    text = ns.Util.StripColor(text)
    text = ns.Util.Trim(text)
    return ns.Util.Trim(text:match("^%[(.*)%]$") or text)
end

------------------------------------------------------------------------
-- 链接解析
------------------------------------------------------------------------

local LINK_PATTERN = "|Hitem:(%-?%d+)([^|]*)|h(.-)|h"

-- 返回文本里所有物品链接：{ id=数字, name=显示名, link=完整链接原文, s=起点, e=终点 }
-- link 向前包含颜色段（|cAARRGGBB 或 |cnXXX:），向后包含 |r。
function Items.ParseLinks(text)
    local result = {}
    if type(text) ~= "string" then return result end
    local pos = 1
    while true do
        local s, e, id, _, disp = text:find(LINK_PATTERN, pos)
        if not s then break end
        local ls, le = s, e
        local before = text:sub(1, s - 1)
        local cs = before:find("|c%x%x%x%x%x%x%x%x$") or before:find("|cn[^:|]*:$")
        if cs then ls = cs end
        if text:sub(e + 1, e + 2) == "|r" then le = e + 2 end
        result[#result + 1] = {
            id = tonumber(id),
            name = DisplayName(disp),
            link = text:sub(ls, le),
            s = ls,
            e = le,
        }
        pos = e + 1
    end
    return result
end

-- 第一条链接的物品 ID，没有链接时返回 nil
function Items.LinkID(text)
    if type(text) ~= "string" then return nil end
    local id = text:match("|Hitem:(%-?%d+)")
    return id and tonumber(id) or nil
end

-- 去掉文本里的物品链接（替换为一个空格），返回剩下的文本
function Items.StripLinks(text)
    if type(text) ~= "string" then return "" end
    local links = Items.ParseLinks(text)
    if #links == 0 then return text end
    local parts, pos = {}, 1
    for _, l in ipairs(links) do
        parts[#parts + 1] = text:sub(pos, l.s - 1)
        parts[#parts + 1] = " "
        pos = l.e + 1
    end
    parts[#parts + 1] = text:sub(pos)
    return table.concat(parts)
end

-- 提取不在链接内的 [物品名]，返回名字列表（去掉首尾空白，空名字忽略）
function Items.ParseBracketNames(text)
    if type(text) == "string" then
        text = text:gsub("【", "["):gsub("】", "]"):gsub("［", "["):gsub("］", "]")
    end
    local result = {}
    if type(text) ~= "string" then return result end
    local rest = Items.StripLinks(text)
    for inner in rest:gmatch("%[(.-)%]") do
        local name = ns.Util.Trim(inner)
        if name ~= "" then result[#result + 1] = name end
    end
    return result
end

-- 从链接的颜色段推断品质（物品信息未缓存时的兜底）
local HEX_QUALITY = {
    ff9d9d9d = 0, ffffffff = 1, ff1eff00 = 2, ff0070dd = 3, ffa335ee = 4, ffff8000 = 5, ffe6cc80 = 6,
}

function Items.LinkQuality(link)
    if type(link) ~= "string" then return nil end
    local q = link:match("|cnIQ(%d+):")
    if q then return tonumber(q) end
    local hex = link:match("|c(%x%x%x%x%x%x%x%x)|Hitem")
    if hex then return HEX_QUALITY[hex:lower()] end
    return nil
end

-- 鼠标提示用的超链接字符串
function Items.Hyperlink(id)
    return "item:" .. tostring(id)
end

------------------------------------------------------------------------
-- 物品匹配
-- a、b 可以是：物品 ID（数字）、含链接的文本、物品名、{ id=, name= } 表。
-- 两边都有 ID 时比 ID；否则比清理后的名字是否全等。不做子串包含匹配。
------------------------------------------------------------------------

local function ToRef(x)
    local t = type(x)
    if t == "number" then return { id = x } end
    if t == "table" then return x end
    if t == "string" then
        local links = Items.ParseLinks(x)
        if #links > 0 then return { id = links[1].id, name = links[1].name } end
        return { name = x }
    end
    return nil
end

local function RefName(ref)
    if ref.name and ref.name ~= "" then return ref.name end
    if ref.id then
        local info = Items.GetCached(ref.id)
        if info then return info.name end
    end
    return nil
end

function Items.SameItem(a, b)
    local ra, rb = ToRef(a), ToRef(b)
    if not ra or not rb then return false end
    if ra.id and rb.id then return ra.id == rb.id end
    local na, nb = Items.CleanName(RefName(ra)), Items.CleanName(RefName(rb))
    if na == "" or nb == "" then return false end
    return na == nb
end

------------------------------------------------------------------------
-- 物品信息缓存与异步获取
-- 信息表：{ id=, name=, link=, quality=, icon= }
------------------------------------------------------------------------

local cache = {}
local pending = {}       -- [id] = { 回调... }
local listening = false

local function Lookup(id)
    local name, link, quality, icon = ns.Compat.GetItemInfo(id)
    if not name then return nil end
    local info = { id = id, name = name, link = link, quality = quality, icon = icon }
    cache[id] = info
    return info
end

-- 已缓存则返回信息表，否则返回 nil（不发请求以外的副作用；GetItemInfo 本身会触发向服务器查询）
function Items.GetCached(id)
    id = tonumber(id)
    if not id then return nil end
    return cache[id] or Lookup(id)
end

local function OnItemInfo(itemID, success)
    local id = tonumber(itemID)
    local cbs = id and pending[id]
    if not cbs then return end
    local info = Lookup(id)
    if not info and success ~= false then return end   -- 还没到，继续等
    pending[id] = nil
    for _, cb in ipairs(cbs) do
        local ok, err = pcall(cb, info)
        if not ok then ns.Log(ns.LogLevel.ERROR, "物品回调出错：" .. tostring(err)) end
    end
    if next(pending) == nil and listening then
        ns.Events:Off("GET_ITEM_INFO_RECEIVED", OnItemInfo)
        listening = false
    end
end

-- 取物品信息：已缓存时立即回调；否则请求并在 GET_ITEM_INFO_RECEIVED 后回调。
-- 物品不存在时回调参数为 nil。
function Items.Get(id, callback)
    id = tonumber(id)
    if not id then
        callback(nil)
        return
    end
    local info = Items.GetCached(id)
    if info then
        callback(info)
        return
    end
    local list = pending[id]
    if not list then
        list = {}
        pending[id] = list
    end
    list[#list + 1] = callback
    if not listening then
        ns.Events:On("GET_ITEM_INFO_RECEIVED", OnItemInfo)
        listening = true
    end
    ns.Compat.RequestItem(id)
end

-- 测试用：某物品等待中的回调数
function Items._PendingCount(id) return pending[id] and #pending[id] or 0 end

-- 测试用：清空缓存
function Items._Reset()
    cache, pending, listening = {}, {}, false
end
