-- Core/Roster.lua：团队花名册（名字已规范化）。许愿、拍卖共用。
-- GROUP_ROSTER_UPDATE 时刷新；成员有进有出时触发内部事件 RW_ROSTER_CHANGED。
-- （ 未列出此文件；把花名册集中在一处，避免各模块各自遍历 GetRaidRosterInfo。）
local ADDON, ns = ...

local Roster = { list = {}, set = {}, dirty = true }
ns.Roster = Roster

function Roster:Refresh()
    local list, set = {}, {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name, rank, _, _, _, fileName, _, online = GetRaidRosterInfo(i)
            if ns.Compat.IsSecret(name) then return false end      -- 不可读时保留旧名单
            if UNKNOWNOBJECT and name == UNKNOWNOBJECT then -- 成员信息还没加载好，稍后再刷新
                Roster.retry = true
            elseif name then
                local n = ns.Util.NormName(name)
                local e = { name = n, class = fileName, rank = tonumber(rank) or 0, online = online and true or false }
                list[#list + 1] = e
                set[n] = e
            end
        end
    end
    self.list, self.set, self.dirty = list, set, false
    return true
end

-- 返回 list（{ name, class, rank, online } 数组）与 set（名字 → 条目）
function Roster:Get()
    if self.dirty then self:Refresh() end
    return self.list, self.set
end

function Roster:Has(name)
    local _, set = self:Get()
    return set[name] ~= nil
end

function Roster:Rank(name)
    local _, set = self:Get()
    return set[name] and set[name].rank or nil
end

-- 团长（rank 2）
function Roster:IsRaidLeader(name)
    return self:Rank(name) == 2
end

-- 团长或助理
function Roster:IsOfficer(name)
    local r = self:Rank(name)
    return r ~= nil and r >= 1
end

function Roster:Self()
    return ns.Util.UnitFullName("player") or ""
end

-- 把输入的名字对应到团员：完全一致优先；只写了第一段（名）且团里只有一个人叫这个名时，也认。
function Roster:Resolve(name)
    name = ns.Util.NormName(name)
    local list, set = self:Get()
    if set[name] then return name end
    if name == "" or name:find(" ", 1, true) then return nil end
    local found
    for _, e in ipairs(list) do
        if e.name:match("^(%S+)") == name then
            if found then return nil end
            found = e.name
        end
    end
    return found
end

-- 自己是否有团长或助理权限（直接查询，不依赖缓存）
function Roster:SelfIsOfficer()
    return IsInRaid() and (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) and true or false
end

local OnRosterUpdate
local function RetryLater()
    if Roster.retry and not Roster.retryPending then
        Roster.retryPending = true
        ns.After(2, function() Roster.retryPending = false; OnRosterUpdate() end)
    end
end

function OnRosterUpdate()
    local _, old = Roster.list, Roster.set
    Roster.retry = false
    local ok = Roster:Refresh()
    RetryLater()
    if not ok then
        Roster.dirty = true
        return
    end
    local changed = false
    for n in pairs(old) do
        if not Roster.set[n] then changed = true break end
    end
    if not changed then
        for n in pairs(Roster.set) do
            if not old[n] then changed = true break end
        end
    end
    ns.Events:Fire("RW_ROSTER_UPDATE")
    if changed then ns.Events:Fire("RW_ROSTER_CHANGED") end
end

ns.Events:On("GROUP_ROSTER_UPDATE", OnRosterUpdate)
ns.Events:On("GROUP_LEFT", function()
    Roster.list, Roster.set, Roster.dirty = {}, {}, false
end)
