-- Core/Util.lua：字符串清理、名字规范化、时间、职业、格式串转模式
-- 纯逻辑：只读取可选的 RAID_CLASS_COLORS 和 date，不调用其他游戏接口，可离线测试。
local ADDON, ns = ...

local Util = {}
ns.Util = Util

local dateFn = date or os.date

------------------------------------------------------------------------
-- 字符串
------------------------------------------------------------------------

function Util.Trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- 去掉颜色码：|cAARRGGBB、正式服的 |cnXXX: 形式、|r
function Util.StripColor(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|cn[^:|]*:", "")
    s = s:gsub("|r", "")
    return s
end

-- 名字比较前的清理：去颜色码、去全部空白、转小写
function Util.CleanString(s)
    if type(s) ~= "string" then return "" end
    s = Util.StripColor(s)
    s = s:gsub("%s+", "")
    return s:lower()
end

-- 补足两位，统一返回字符串
function Util.Pad2(n)
    n = tonumber(n) or 0
    if n < 10 and n >= 0 then return "0" .. n end
    return tostring(n)
end

------------------------------------------------------------------------
-- 时间
-- 时间戳统一为数字（秒）；nil 时用当前本地时间。
------------------------------------------------------------------------

function Util.FormatTime(ts)
    local t = dateFn("*t", type(ts) == "number" and ts or nil)
    return Util.Pad2(t.hour or 0) .. ":" .. Util.Pad2(t.min or 0)
end

------------------------------------------------------------------------
-- 玩家名规范化
-- keepRealm 待 V5 探测确定；默认去掉 "-服务器" 后缀。
------------------------------------------------------------------------

Util.keepRealm = false

function Util.NormName(name)
    if type(name) ~= "string" then return "" end
    name = Util.Trim(Util.StripColor(name))
    if not Util.keepRealm then
        name = name:match("^([^%-]+)") or name
    end
    return name
end

-- "无限"的角色名分两段（名 + 姓，每段最多 6 个字），完整名字是"名 姓"，中间一个空格。
-- 聊天发言者、花名册、系统消息里都是完整名字；UnitName 却把两段分开返回，这里拼回去。
function Util.UnitFullName(unit)
    local n, s = UnitName(unit)
    local IsSecret = ns.Compat and ns.Compat.IsSecret
    if IsSecret and (IsSecret(n) or IsSecret(s)) then return nil end
    if type(n) ~= "string" or n == "" then return nil end
    if type(s) == "string" and s ~= "" then n = n .. " " .. s end
    return Util.NormName(n)
end

-- 从按空白切开的参数里取一个名字：第 i 段和第 i+1 段合成"名 姓"。
-- 只有一段时就用这一段。返回名字和下一个参数的序号。
function Util.TakeName(parts, i)
    local a, b = parts[i], parts[i + 1]
    if not a then return nil, i end
    if b then return a .. " " .. b, i + 2 end
    return a, i + 1
end

-- 只用于显示：去掉服务器后缀
function Util.ShortName(name)
    if type(name) ~= "string" then return "" end
    return (Util.StripColor(name):match("^([^%-]+)")) or name
end

------------------------------------------------------------------------
-- 职业
-- 内部一律使用 UnitClass 第二个返回值那样的英文标识（WARRIOR 等）。
------------------------------------------------------------------------

local CLASS_ALIASES = {
    -- 英文标识
    WARRIOR = "WARRIOR", PALADIN = "PALADIN", HUNTER = "HUNTER", ROGUE = "ROGUE",
    PRIEST = "PRIEST", SHAMAN = "SHAMAN", MAGE = "MAGE", WARLOCK = "WARLOCK",
    DRUID = "DRUID", DEATHKNIGHT = "DEATHKNIGHT", MONK = "MONK", DEMONHUNTER = "DEMONHUNTER",
    EVOKER = "EVOKER",
    -- 英文显示名
    Warrior = "WARRIOR", Paladin = "PALADIN", Hunter = "HUNTER", Rogue = "ROGUE",
    Priest = "PRIEST", Shaman = "SHAMAN", Mage = "MAGE", Warlock = "WARLOCK", Druid = "DRUID",
    ["Death Knight"] = "DEATHKNIGHT", Monk = "MONK", ["Demon Hunter"] = "DEMONHUNTER", Evoker = "EVOKER",
    -- 中文显示名（含常见的其他写法）
    ["战士"] = "WARRIOR", ["圣骑士"] = "PALADIN", ["猎人"] = "HUNTER", ["盗贼"] = "ROGUE",
    ["潜行者"] = "ROGUE", ["牧师"] = "PRIEST", ["萨满祭司"] = "SHAMAN", ["萨满"] = "SHAMAN",
    ["法师"] = "MAGE", ["术士"] = "WARLOCK", ["德鲁伊"] = "DRUID", ["死亡骑士"] = "DEATHKNIGHT",
    ["武僧"] = "MONK", ["恶魔猎手"] = "DEMONHUNTER", ["唤魔师"] = "EVOKER",
}

-- 中文显示名（通报文案用）
Util.CLASS_NAME_ZH = {
    WARRIOR = "战士", PALADIN = "圣骑士", HUNTER = "猎人", ROGUE = "盗贼", PRIEST = "牧师",
    SHAMAN = "萨满祭司", MAGE = "法师", WARLOCK = "术士", DRUID = "德鲁伊",
    DEATHKNIGHT = "死亡骑士", MONK = "武僧", DEMONHUNTER = "恶魔猎手", EVOKER = "唤魔师",
}

-- 职业圆标上的单字（效果图 .cls）
Util.CLASS_SHORT_ZH = {
    WARRIOR = "战", PALADIN = "骑", HUNTER = "猎", ROGUE = "贼", PRIEST = "牧",
    SHAMAN = "萨", MAGE = "法", WARLOCK = "术", DRUID = "德",
    DEATHKNIGHT = "死", MONK = "僧", DEMONHUNTER = "恶", EVOKER = "唤",
}

-- RAID_CLASS_COLORS 不可用时的兜底（正式服标准职业色）
local FALLBACK_CLASS_COLORS = {
    WARRIOR = "C69B6D", PALADIN = "F48CBA", HUNTER = "AAD372", ROGUE = "FFF468",
    PRIEST = "FFFFFF", SHAMAN = "0070DD", MAGE = "3FC7EB", WARLOCK = "8788EE",
    DRUID = "FF7C0A", DEATHKNIGHT = "C41E3A", MONK = "00FF98", DEMONHUNTER = "A330C9",
    EVOKER = "33937F",
}

-- 任意写法 → 英文标识；认不出返回 nil
function Util.NormClass(class)
    if type(class) ~= "string" then return nil end
    return CLASS_ALIASES[class] or CLASS_ALIASES[class:upper()]
end

-- 返回 r, g, b（0~1）；未知职业返回灰色
function Util.ClassColor(class)
    local token = Util.NormClass(class)
    local rcc = RAID_CLASS_COLORS
    if token and type(rcc) == "table" and rcc[token] then
        local c = rcc[token]
        return c.r, c.g, c.b
    end
    local hex = token and FALLBACK_CLASS_COLORS[token]
    if not hex then return 0.6, 0.6, 0.6 end
    return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- 返回 "RRGGBB"
function Util.ClassColorHex(class)
    local r, g, b = Util.ClassColor(class)
    return ("%02X%02X%02X"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- 带职业色的名字，用于聊天框
function Util.ClassColoredName(name, class)
    return "|cff" .. Util.ClassColorHex(class) .. tostring(name) .. "|r"
end

------------------------------------------------------------------------
-- 格式串 → 匹配模式
-- 支持 %s、%d、%1$s / %2$d 这类带位置的写法，%% 为字面百分号。
-- 返回 pattern 与 order：order[i] 是第 i 个捕获对应格式串里的第几个参数。
------------------------------------------------------------------------

local MAGIC = "([%^%$%(%)%%%.%[%]%*%+%-%?])"

local function EscapeLiteral(s)
    return (s:gsub(MAGIC, "%%%1"))
end

local patternCache = {}

function Util.FormatToPattern(fmt)
    local cached = patternCache[fmt]
    if cached then return cached.pattern, cached.order end
    local out, order = { "^" }, {}
    local literal = {}
    local auto = 0
    local i, n = 1, #fmt
    local function flush()
        if #literal > 0 then
            out[#out + 1] = EscapeLiteral(table.concat(literal))
            literal = {}
        end
    end
    while i <= n do
        local c = fmt:sub(i, i)
        if c == "%" then
            local pos, conv, stop = fmt:match("^(%d+)%$([sd])()", i + 1)
            if not conv then
                conv, stop = fmt:match("^([sd])()", i + 1)
            end
            if conv then
                flush()
                auto = auto + 1
                order[#order + 1] = tonumber(pos) or auto
                out[#out + 1] = (conv == "d") and "(%-?%d+)" or "(.-)"
                i = stop
            elseif fmt:sub(i + 1, i + 1) == "%" then
                literal[#literal + 1] = "%"
                i = i + 2
            else
                literal[#literal + 1] = c
                i = i + 1
            end
        else
            literal[#literal + 1] = c
            i = i + 1
        end
    end
    flush()
    out[#out + 1] = "$"
    local pattern = table.concat(out)
    patternCache[fmt] = { pattern = pattern, order = order }
    return pattern, order
end

-- 用格式串匹配文本，按格式串里的参数顺序返回捕获；不匹配返回 nil
function Util.MatchFormat(text, fmt)
    if type(text) ~= "string" or type(fmt) ~= "string" then return nil end
    local pattern, order = Util.FormatToPattern(fmt)
    local caps = { text:match(pattern) }
    if #caps == 0 then return nil end
    local result = {}
    for idx, argPos in ipairs(order) do result[argPos] = caps[idx] end
    return unpack(result, 1, #order)
end
