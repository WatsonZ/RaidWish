-- Wish/WishModel.lua：许愿表数据与规则（纯逻辑）
-- 不调用游戏接口。存储表、时钟、变更通知都由调用方传入。
--
-- 记录结构（存档 RaidWishDB.wishes[规范化名字]）：
--   { class = "WARRIOR", dkp = 4, ts = 时间戳, wish = nil | { raw = 原文, items = { 物品... } } }
-- 物品：{ id = 数字或 nil, name = 名字, done = 布尔, floor = 布尔（"地板"许愿） }
local ADDON, ns = ...

local WishModel = {}
WishModel.__index = WishModel
ns.WishModel = WishModel

WishModel.FLOOR_NAME = "地板"

-- store：名字 → 记录 的表；fire(事件名, 名字或 nil)；now() 返回秒数
function WishModel.New(store, fire, now)
    return setmetatable({
        store = store or {},
        fire = fire or function() end,
        now = now or time,   -- 游戏里没有 os 表，用全局 time
        backups = {},        -- 手动标记完成前的 done 状态，供撤销（只在本次登录内有效，不存档）
    }, WishModel)
end

local function Changed(self, name)
    self.fire("RW_WISH_CHANGED", name)
end

------------------------------------------------------------------------
-- 物品与许愿的辅助函数
------------------------------------------------------------------------

local function CopyItems(items)
    local out = {}
    for i, it in ipairs(items or {}) do
        out[i] = { id = it.id, name = it.name, done = it.done and true or false, floor = it.floor and true or nil }
    end
    return out
end

-- 物品是否与 ref 匹配（ref：{ id=, name= } 或物品 ID 或名字）；地板许愿不与任何具体物品匹配
local function ItemMatches(it, ref)
    if it.floor then return false end
    return ns.Items.SameItem({ id = it.id, name = it.name }, ref)
end

function WishModel.HasWish(rec)
    return rec ~= nil and rec.wish ~= nil and rec.wish.items ~= nil and #rec.wish.items > 0
end

-- 许愿是否已整体完成（全部物品 done）
function WishModel.IsFullyDone(rec)
    if not WishModel.HasWish(rec) then return false end
    for _, it in ipairs(rec.wish.items) do
        if not it.done then return false end
    end
    return true
end

-- 许愿里是否有未完成的地板许愿
function WishModel.IsFloor(rec)
    if not WishModel.HasWish(rec) then return false end
    for _, it in ipairs(rec.wish.items) do
        if it.floor and not it.done then return true end
    end
    return false
end

-- 该记录是否许愿了 ref（只看未完成的物品）
function WishModel.WantsItem(rec, ref)
    if not WishModel.HasWish(rec) then return false end
    for _, it in ipairs(rec.wish.items) do
        if not it.done and ItemMatches(it, ref) then return true end
    end
    return false
end

-- 用于聊天通报的许愿文字。linkFor(id) 返回物品链接或 nil（不可用时用 [名字]）。
-- 全部完成时为"许愿已全部拿到"；部分完成的物品后面加"（已完成）"。
function WishModel.WishText(rec, linkFor)
    if not WishModel.HasWish(rec) then return "" end
    if WishModel.IsFullyDone(rec) then return "许愿已全部拿到" end
    local parts = {}
    for _, it in ipairs(rec.wish.items) do
        local s
        if it.floor then
            s = WishModel.FLOOR_NAME
        else
            s = (it.id and linkFor and linkFor(it.id))
                or ("[" .. tostring(it.name or (it.id and ("物品" .. it.id)) or "?") .. "]")
        end
        if it.done then s = s .. "（已完成）" end
        parts[#parts + 1] = s
    end
    return table.concat(parts, " ")
end

------------------------------------------------------------------------
-- 同步用的物品列表编码（："id:完成标记" 用 ";" 连接，手打名字用 "n:" 前缀）
------------------------------------------------------------------------

function WishModel.EncodeItems(items)
    local parts = {}
    for _, it in ipairs(items or {}) do
        local d = it.done and "1" or "0"
        if it.floor then
            parts[#parts + 1] = "f:" .. d
        elseif it.id then
            parts[#parts + 1] = tostring(it.id) .. ":" .. d
        else
            local name = tostring(it.name or ""):gsub(";", "；"):gsub("\t", " ")
            parts[#parts + 1] = "n:" .. name .. ":" .. d
        end
    end
    return table.concat(parts, ";")
end

function WishModel.DecodeItems(s)
    local items = {}
    if type(s) ~= "string" or s == "" then return items end
    for part in (s .. ";"):gmatch("([^;]*);") do
        local id, d = part:match("^(%-?%d+):([01])$")
        if id then
            items[#items + 1] = { id = tonumber(id), done = d == "1" }
        else
            local fd = part:match("^f:([01])$")
            if fd then
                items[#items + 1] = { name = WishModel.FLOOR_NAME, floor = true, done = fd == "1" }
            else
                local name, nd = part:match("^n:(.*):([01])$")
                if name and name ~= "" then
                    items[#items + 1] = { name = name, done = nd == "1" }
                end
            end
        end
    end
    return items
end

------------------------------------------------------------------------
-- 记录
------------------------------------------------------------------------

function WishModel:Get(name)
    return self.store[name]
end

-- 取或建玩家记录。新记录分数为 defaultDkp，未许愿。
function WishModel:Ensure(name, class, defaultDkp)
    if not name or name == "" then return nil end
    local rec = self.store[name]
    if not rec then
        rec = { class = class, dkp = tonumber(defaultDkp) or 0, ts = self.now() }
        self.store[name] = rec
        Changed(self, name)
    else
        if class and rec.class ~= class then rec.class = class end
        rec.dkp = tonumber(rec.dkp) or tonumber(defaultDkp) or 0
    end
    return rec
end

-- 为在团成员补建记录，返回新建个数
function WishModel:EnsureMembers(roster, defaultDkp)
    local created = 0
    for _, m in ipairs(roster or {}) do
        if not self.store[m.name] then
            self.store[m.name] = { class = m.class, dkp = tonumber(defaultDkp) or 0, ts = self.now() }
            created = created + 1
        elseif m.class and not self.store[m.name].class then
            self.store[m.name].class = m.class
        end
    end
    if created > 0 then Changed(self, nil) end
    return created
end

-- 设置许愿（覆盖原许愿）。items 为空时视为无效，原许愿保持不变，返回 false。
function WishModel:SetWish(name, items, raw)
    local rec = self.store[name]
    if not rec or not items or #items == 0 then return false end
    rec.wish = { raw = raw, items = CopyItems(items) }
    rec.ts = self.now()
    self.backups[name] = nil
    Changed(self, name)
    return true
end

function WishModel:ClearWish(name)
    local rec = self.store[name]
    if not rec then return false end
    rec.wish = nil
    rec.ts = self.now()
    self.backups[name] = nil
    Changed(self, name)
    return true
end

-- 加减分，返回新分数；没有该玩家返回 nil
function WishModel:AddDkp(name, delta)
    local rec = self.store[name]
    if not rec then return nil end
    rec.dkp = (tonumber(rec.dkp) or 0) + (tonumber(delta) or 0)
    rec.ts = self.now()
    Changed(self, name)
    return rec.dkp
end

function WishModel:SetDkp(name, value)
    local rec = self.store[name]
    if not rec then return nil end
    rec.dkp = tonumber(value) or 0
    rec.ts = self.now()
    Changed(self, name)
    return rec.dkp
end

-- 初始化全团分数：只改当前在团成员
function WishModel:InitScores(roster, dkp)
    dkp = tonumber(dkp) or 0
    for _, m in ipairs(roster or {}) do
        local rec = self.store[m.name]
        if not rec then
            rec = { class = m.class, ts = self.now() }
            self.store[m.name] = rec
        end
        rec.dkp = dkp
    end
    Changed(self, nil)
end

------------------------------------------------------------------------
-- 完成标记
------------------------------------------------------------------------

-- 手动标记整条许愿为已完成。已是完成状态或没有许愿返回 false。
function WishModel:MarkAllDone(name)
    local rec = self.store[name]
    if not WishModel.HasWish(rec) or WishModel.IsFullyDone(rec) then return false end
    local backup = {}
    for i, it in ipairs(rec.wish.items) do
        backup[i] = it.done and true or false
        it.done = true
    end
    self.backups[name] = backup
    rec.ts = self.now()
    Changed(self, name)
    return true
end

-- 撤销手动标记。没有可撤销的记录返回 false。
function WishModel:UndoDone(name)
    local rec = self.store[name]
    local backup = self.backups[name]
    if not backup or not WishModel.HasWish(rec) then return false end
    for i, it in ipairs(rec.wish.items) do
        if backup[i] ~= nil then it.done = backup[i] end
    end
    self.backups[name] = nil
    rec.ts = self.now()
    Changed(self, name)
    return true
end

function WishModel:CanUndo(name)
    return self.backups[name] ~= nil
end

-- 把许愿里与 ref 匹配的第一件未完成物品标为完成（掉落命中许愿时用）。匹配到返回 true。
function WishModel:MarkItemDone(name, ref)
    local rec = self.store[name]
    if not WishModel.HasWish(rec) then return false end
    for _, it in ipairs(rec.wish.items) do
        if not it.done and ItemMatches(it, ref) then
            it.done = true
            rec.ts = self.now()
            Changed(self, name)
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
-- 查询
------------------------------------------------------------------------

local function MemberSet(members)
    if not members then return nil end
    local set = {}
    for k, v in pairs(members) do
        if type(k) == "number" then
            set[type(v) == "table" and v.name or v] = true
        else
            set[k] = v and true or nil
        end
    end
    return set
end

-- 许愿了 ref 的在团玩家：{ { name=, dkp= }... }，按名字排序
-- members 可以是名字数组、{ name= } 数组或名字集合；nil 表示不过滤
function WishModel:WishPlayers(ref, members)
    local set = MemberSet(members)
    local out = {}
    for name, rec in pairs(self.store) do
        if (not set or set[name]) and WishModel.WantsItem(rec, ref) then
            out[#out + 1] = { name = name, dkp = tonumber(rec.dkp) or 0 }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- 许愿"地板"的在团玩家
function WishModel:FloorPlayers(members)
    local set = MemberSet(members)
    local out = {}
    for name, rec in pairs(self.store) do
        if (not set or set[name]) and WishModel.IsFloor(rec) then
            out[#out + 1] = { name = name, dkp = tonumber(rec.dkp) or 0 }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- 许愿了 ref 的在团人数（重复许愿通报用，只算在团成员）
function WishModel:CountWishers(ref, members)
    return #self:WishPlayers(ref, members)
end

-- 未许愿名单，按 roster 的顺序（roster 为 { name= } 数组或名字数组）
function WishModel:Unwished(roster)
    local out = {}
    for _, m in ipairs(roster or {}) do
        local name = type(m) == "table" and m.name or m
        if not WishModel.HasWish(self.store[name]) then out[#out + 1] = name end
    end
    return out
end

-- 统计：已许愿人数、未许愿人数、重复件数（同一物品 2 人及以上），只算 members
function WishModel:Counts(members)
    local set = MemberSet(members)
    local wished, unwished = 0, 0
    local perItem = {}
    for name, rec in pairs(self.store) do
        if not set or set[name] then
            if WishModel.HasWish(rec) then
                wished = wished + 1
                for _, it in ipairs(rec.wish.items) do
                    if not it.done and not it.floor then
                        local key = it.id and ("#" .. it.id) or ("n:" .. ns.Items.CleanName(it.name))
                        perItem[key] = (perItem[key] or 0) + 1
                    end
                end
            else
                unwished = unwished + 1
            end
        end
    end
    local dup = 0
    for _, n in pairs(perItem) do if n >= 2 then dup = dup + 1 end end
    return wished, unwished, dup
end

-- 排序视图。field：name / class / wish / dkp；asc 为真时升序。
-- 返回 { { name=, rec= }... }；members 不为 nil 时只含在团成员。
function WishModel:Sorted(field, asc, members)
    local set = MemberSet(members)
    local rows = {}
    for name, rec in pairs(self.store) do
        if not set or set[name] then rows[#rows + 1] = { name = name, rec = rec } end
    end
    local function key(row)
        local rec = row.rec
        if field == "dkp" then return tonumber(rec.dkp) or 0 end
        if field == "class" then return tostring(rec.class or "") end
        if field == "wish" then
            if not WishModel.HasWish(rec) then return "" end
            return tostring(rec.wish.items[1].name or rec.wish.items[1].id or "")
        end
        return row.name
    end
    table.sort(rows, function(a, b)
        local ka, kb = key(a), key(b)
        if ka == kb then return a.name < b.name end
        if asc then return ka < kb end
        return ka > kb
    end)
    return rows
end

------------------------------------------------------------------------
-- 整表操作
------------------------------------------------------------------------

-- 清空许愿表
function WishModel:ClearAll()
    for k in pairs(self.store) do self.store[k] = nil end
    self.backups = {}
    Changed(self, nil)
end

-- 用同步来的完整数据替换整张表（就地替换，保持存档表的引用不变）
function WishModel:ReplaceAll(records)
    for k in pairs(self.store) do self.store[k] = nil end
    for name, rec in pairs(records or {}) do self.store[name] = rec end
    self.backups = {}
    Changed(self, nil)
end

-- 写入一行同步数据（增量同步）。返回该行的物品列表编码是否变化。
function WishModel:ApplyRow(name, class, dkp, items)
    local rec = self.store[name]
    local before = rec and rec.wish and WishModel.EncodeItems(rec.wish.items) or ""
    if not rec then
        rec = {}
        self.store[name] = rec
    end
    rec.class = class ~= "" and class or rec.class
    rec.dkp = tonumber(dkp) or 0
    rec.ts = self.now()
    if items and #items > 0 then
        rec.wish = { items = CopyItems(items) }
    else
        rec.wish = nil
    end
    Changed(self, name)
    local after = rec.wish and WishModel.EncodeItems(rec.wish.items) or ""
    return before ~= after
end
