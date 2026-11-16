-- Core/DB.lua：存档结构、默认值、版本升级
-- 所有模块通过 ns.DB 访问存档，不直接碰全局存档变量。
-- 默认值填充用 "== nil" 判断，不用 "x = x or true" 这种写法
-- 会让 false 永远变回 true）。
local ADDON, ns = ...

local DB = {}
ns.DB = DB

DB.SCHEMA = 1

-- 默认开团公告与默认宣言（用户可在 设置 → 开团公告与宣言 里改写）
DB.DEFAULT_START_TEXT = "本次活动采用许愿分配：在团队频道输入 xy 加物品链接即可许愿。\n"
    .. "装备优先给许愿的人；同一件多人许愿时，按出分和 Roll 点决定。\n"
    .. "分数和许愿记录以团长的许愿助手为准，有疑问请密语团长。"
DB.DEFAULT_DECLARATION = "参加本次活动即表示同意以下约定：\n"
    .. "1. 装备按许愿和拍卖结果分配。\n"
    .. "2. 中途无故离团的，以后的活动不再邀请。\n"
    .. "3. 其他事宜由团长决定。"


------------------------------------------------------------------------
-- 默认值
------------------------------------------------------------------------

DB.defaults = {
    schema = DB.SCHEMA,
    options = {
        -- 许愿与掉落
        qualityFilters = { [5] = true, [4] = true, [3] = false, [2] = false, [1] = false, [0] = false },
        declaration = nil,          -- nil 表示使用 DEFAULT_DECLARATION
        startText = nil,            -- nil 表示使用 DEFAULT_START_TEXT
        autoAnnounce = true,        -- 许愿重复警报及自动查询
        greenMode = false,          -- 仅绿模式
        blueMode = false,           -- 仅蓝模式
        purpleMode = true,          -- 仅紫模式
        xyOnly = false,             -- 仅 xy 模式
        maxWishItems = 1,           -- 每人最多许愿件数，0 表示不限
        autoDeduct = true,          -- 自动扣分
        clearOnLeaveMode = "ask",   -- 退团清空：ask 弹窗询问 / clear 直接清空
        autoBackup = true,          -- 自动快照，默认开
        defaultDkp = 4,             -- 原全局 DefaultDKP

        -- 拾取分配
        lootAssign = {
            enabled = true,
            postRandom = true,
            ask = false,
            quickloot = "",         -- 指定拾取人
            showRolls = 5,
            rollTimeout = 60,
            rollMin = 1,
            rollMax = 100,
            bidBodSupport = false,
        },

        -- 拍卖
        auction = {
            quality = { [0] = false, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true },
            showSold = true,
            sameScore = false,      -- 同分 Roll（暂未使用：同分一律 Roll）
            voice = false,          -- 语音播报
            voicePack = true,       -- 装了语音包时用语音包
            showPendingButton = true, -- 没有拍卖时显示"待拍"按钮
        },

        -- 新界面
        ui = {
            skin = "flat",
            showMinimap = true,
            icon = "starcoin",      -- 小地图按钮图标（见 UI/Widgets.lua 的 W.ICONS）
        },
    },
    wishes = {},        -- [规范化名字] = { class=, dkp=, wish=, ts= }
    loot = {},          -- 掉落记录（数组）
    snapshot = {},      -- 许愿表与掉落记录的快照
    leader = { name = nil, term = 0 },
    auction = {
        results = {},   -- 拍卖结算记录（最多 20 条）
        captured = {},  -- 团队频道出现过的待拍物品
        pMarked = {},   -- "不要这件"标记过的物品
    },
}


DB.charDefaults = {
    frames = {},        -- [框体键] = { point=, relPoint=, x=, y= }
    mainScale = 1,
    auctionScale = 1,
    auctionCollapsed = false,
    minimap = {},       -- 小地图按钮位置
}

------------------------------------------------------------------------
-- 纯函数
------------------------------------------------------------------------

function DB.DeepCopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = DB.DeepCopy(x) end
    return t
end

-- 把 defaults 里缺失（== nil）的项填进 t；已有的值（包括 false）保持不变。
-- 类型不符时（例如旧数据里该是表的地方是字符串）用默认值覆盖。
function DB.Fill(t, defaults)
    for k, dv in pairs(defaults) do
        local v = t[k]
        if v == nil then
            t[k] = DB.DeepCopy(dv)
        elseif type(dv) == "table" then
            if type(v) ~= "table" then
                t[k] = DB.DeepCopy(dv)
            else
                DB.Fill(v, dv)
            end
        end
    end
    return t
end

-- 版本升级：migrations[n] 把 schema n-1 的数据升级到 n
DB.migrations = {}

function DB.Upgrade(t)
    local from = tonumber(t.schema) or DB.SCHEMA
    if from > DB.SCHEMA then
        -- 存档来自更新的版本：不降级，保持原样
        return t, from
    end
    for v = from + 1, DB.SCHEMA do
        local m = DB.migrations[v]
        if m then m(t) end
        t.schema = v
    end
    t.schema = math.max(from, DB.SCHEMA)
    return t, from
end

-- 对一组存档表做升级和填充（不读写全局，便于测试）
function DB.Prepare(main, char)
    main = type(main) == "table" and main or {}
    char = type(char) == "table" and char or {}
    if main.schema == nil then main.schema = DB.SCHEMA end
    DB.Upgrade(main)
    -- 1.0.0 测试版的字段改了名：沿用旧值
    local o = main.options
    if type(o) == "table" and o.autoMinDkp ~= nil then
        if o.autoDeduct == nil then o.autoDeduct = o.autoMinDkp end
        o.autoMinDkp = nil
    end
    DB.Fill(main, DB.defaults)
    DB.Fill(char, DB.charDefaults)
    return main, char
end

------------------------------------------------------------------------
-- 运行时
------------------------------------------------------------------------

-- ADDON_LOADED 时由 Init.lua 调用
function DB:Init()
    RaidWishDB, RaidWishCharDB = DB.Prepare(RaidWishDB, RaidWishCharDB)
    self.main = RaidWishDB
    self.options = RaidWishDB.options
    self.char = RaidWishCharDB
    self.ready = true
end

function DB:GetStartText()
    local t = self.options and self.options.startText
    if type(t) == "string" and t ~= "" then return t end
    return DB.DEFAULT_START_TEXT
end

function DB:GetDeclaration()
    local t = self.options and self.options.declaration
    if type(t) == "string" and t ~= "" then return t end
    return DB.DEFAULT_DECLARATION
end
