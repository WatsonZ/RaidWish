-- Wish/WishSync.lua：团长选举、全量与增量同步
--
-- 消息：
--   HELLO  版本                         进团 / 登录时广播；许愿团长收到后重发 LEAD
--   LEAD   任期号、状态(1 进行中 / 0 已停止)  宣告或续任许愿团长
--   QUIT   任期号                       放弃权限
--   REQ    W / L / WL                   请求全量同步
--   WBEG   任期号、批次号、总条数、默认分   全量同步开始
--   W      批次号(增量为 0)、名字、职业、分数、物品列表
--   WEND   批次号                       全量同步结束
--   NEWER  任期号、修订号、团长名           团员发现团长的数据比自己的旧（例如团长游戏崩溃后用旧存档重登）
--
-- 修订号（rev）：许愿团长每改一次数据加 1，随 LEAD / WBEG / W 增量发出。团员只接受不比自己旧的全量，
-- 收到更旧的就回 NEWER；团长据此先向团员要回最新数据（弹窗确认），再继续同步，避免旧数据覆盖全团。
--
-- 与 的补充：LEAD 多带一个"状态"字段，团员端据此显示"许愿进行中 / 已停止"。
local ADDON, ns = ...

local Sync = {}
ns.WishSync = Sync

Sync.SYNC_TIMEOUT = 10      -- 全量同步超时（秒）
Sync.REQ_RETRY = 5          -- 进团后多久没收到全量就重新请求（秒）
Sync.MAX_RETRY = 3

------------------------------------------------------------------------
-- 纯逻辑：选举判定
------------------------------------------------------------------------

-- 是否接受 cand 的 LEAD（ 团长选举）。
-- current：{ name=, term= } 当前认定；cand：{ name=, term= }
-- ctx：{ inRaid(name), isOfficer(name), isRaidLeader(name) }
function Sync.AcceptLead(current, cand, ctx)
    if not cand or not cand.name or cand.name == "" then return false end
    local term = tonumber(cand.term)
    if not term then return false end
    if not ctx.inRaid(cand.name) or not ctx.isOfficer(cand.name) then return false end
    local curTerm = tonumber(current and current.term) or 0
    local curName = current and current.name
    if term < curTerm then return false end
    if term > curTerm then return true end
    -- 任期号相同
    if not curName or curName == "" or curName == cand.name then return true end
    -- 当前认定的人已不在团或不再是团长 / 助理：让给合法的候选人
    if not ctx.inRaid(curName) or not ctx.isOfficer(curName) then return true end
    -- 真实团长优先，其次名字字典序小者，全团结果一致
    local candLead, curLead = ctx.isRaidLeader(cand.name), ctx.isRaidLeader(curName)
    if candLead ~= curLead then return candLead end
    return cand.name < curName
end

------------------------------------------------------------------------
-- 纯逻辑：全量同步接收器（临时表 + 批次校验）
------------------------------------------------------------------------

local Receiver = {}
Receiver.__index = Receiver
Sync.Receiver = Receiver

function Receiver.New(timeout)
    return setmetatable({ timeout = timeout or Sync.SYNC_TIMEOUT, cur = nil }, Receiver)
end

function Receiver:Begin(batch, count, now)
    self.cur = { batch = tostring(batch), count = tonumber(count) or 0, rows = {}, n = 0, started = now, overrides = {} }
end

-- 同步进行中收到的增量（批次号 0）：不计入条数，结束时覆盖在全量数据之上
function Receiver:Override(name, row)
    if self.cur then self.cur.overrides[name] = row end
end

-- 收到一行。属于当前批次返回 true。
function Receiver:Row(batch, name, row)
    local c = self.cur
    if not c or c.batch ~= tostring(batch) then return false end
    if c.rows[name] == nil then c.n = c.n + 1 end
    c.rows[name] = row
    return true
end

-- 收到结束标记。批次与条数都对得上时返回完整的行表，否则返回 nil 和原因。
-- 条数不符时丢弃临时表；批次号不符（别的批次迟到的结束标记）时保留当前批次继续接收。
function Receiver:End(batch)
    local c = self.cur
    if not c then return nil, "nobegin" end
    if c.batch ~= tostring(batch) then return nil, "batch" end
    self.cur = nil
    if c.n ~= c.count then return nil, "count" end
    for name, row in pairs(c.overrides) do c.rows[name] = row end
    return c.rows
end

-- 超时则丢弃临时表并返回 true
function Receiver:Expire(now)
    if self.cur and now - self.cur.started > self.timeout then
        self.cur = nil
        return true
    end
    return false
end

function Receiver:Active() return self.cur ~= nil end

function Receiver:Progress()
    if not self.cur then return nil end
    return self.cur.n, self.cur.count
end

function Receiver:Reset() self.cur = nil end

------------------------------------------------------------------------
-- 运行时状态
------------------------------------------------------------------------

local Wish = {}             -- 对外的状态接口（ns.Wish）
ns.Wish = Wish

local receiver = Receiver.New()
local batchCounter = 0
local fullSyncPending = false
local leadResendPending = false
local syncedFrom = nil      -- 最近一次全量同步成功时的 { name, term }
local syncState = "none"    -- none / waiting / syncing / ok
local retries = 0
local retryTimer = nil

local function Comm() return ns.Comm end
local function Model() return Wish.model end
local function LeaderDB() return ns.DB.main.leader end

local function Ctx()
    return {
        inRaid = function(n) return ns.Roster:Has(n) end,
        isOfficer = function(n) return ns.Roster:IsOfficer(n) end,
        isRaidLeader = function(n) return ns.Roster:IsRaidLeader(n) end,
    }
end

local function SetSyncState(s)
    if syncState ~= s then
        syncState = s
    end
    ns.Events:Fire("RW_SYNC_STATE", s)
end

local function FireLeader()
    ns.Events:Fire("RW_LEADER_CHANGED")
end

function Wish:LeaderName() return LeaderDB().name end
function Wish:Term() return tonumber(LeaderDB().term) or 0 end
function Wish:Rev() return tonumber(LeaderDB().rev) or 0 end
function Wish:InProgress() return LeaderDB().active and LeaderDB().name ~= nil or false end

function Wish:IsLeader()
    local l = LeaderDB()
    return l.name ~= nil and l.name == ns.Roster:Self() and IsInRaid()
end

-- 同步状态：返回状态名，以及同步中时的已收 / 总数
--   ok 同步正常；syncing 正在同步；waiting 等待团长数据；none 无许愿团长
function Wish:SyncState()
    if self:IsLeader() then return "ok" end
    if receiver:Active() then
        local n, total = receiver:Progress()
        return "syncing", n, total
    end
    if not LeaderDB().name then return "none" end
    if syncedFrom and syncedFrom.name == LeaderDB().name then return "ok" end
    return "waiting"
end

------------------------------------------------------------------------
-- 发送
------------------------------------------------------------------------

local function RowFields(name, rec)
    local items = rec.wish and rec.wish.items or nil
    return name, rec.class or "", tonumber(rec.dkp) or 0, ns.WishModel.EncodeItems(items)
end

local recovering = false       -- 团长端：正在向团员要回较新的数据，期间不发全量

function Sync:Recovering() return recovering end

-- 团长端：数据每变一次，修订号加 1
function Sync:Bump()
    local l = LeaderDB()
    l.rev = (tonumber(l.rev) or 0) + 1
    return l.rev
end

-- 增量：同步一名玩家（团长端调用）
function Sync:SendRow(name)
    if not Wish:IsLeader() then return false end
    local rec = Model():Get(name)
    if not rec then return false end
    local name2, class, dkp, items = RowFields(name, rec)
    return Comm():Send("W", 0, name2, class, dkp, items, Sync:Bump())
end

-- 立即发送全量
function Sync:SendFull()
    if not Wish:IsLeader() or recovering then return false end
    batchCounter = batchCounter % 9999 + 1
    local batch = batchCounter
    local rows = Model():Sorted("name", true)
    Comm():Send("WBEG", Wish:Term(), batch, #rows, ns.DB.options.defaultDkp, Wish:Rev())
    for _, row in ipairs(rows) do
        Comm():Send("W", batch, RowFields(row.name, row.rec))
    end
    Comm():Send("WEND", batch)
    return true
end

-- 1 秒内的多次请求合并为一次全量
function Sync:ScheduleFull()
    if fullSyncPending then return end
    fullSyncPending = true
    ns.After(1, function()
        fullSyncPending = false
        Sync:SendFull()
    end)
end

local function SendLead()
    Comm():Send("LEAD", Wish:Term(), Wish:InProgress() and 1 or 0, Wish:Rev())
end

local function ScheduleLeadResend()
    if leadResendPending then return end
    leadResendPending = true
    ns.After(1, function()
        leadResendPending = false
        if Wish:IsLeader() then SendLead() end
    end)
end

local function CancelRetry()
    if retryTimer then
        retryTimer:Cancel()
        retryTimer = nil
    end
end

-- 请求全量；Sync.REQ_RETRY 秒内没有开始收到则重试，最多 MAX_RETRY 次
function Sync:Request(what)
    if Wish:IsLeader() or not IsInRaid() then return end
    Comm():Send("REQ", what or "W")
    if syncState ~= "syncing" then SetSyncState("waiting") end
    CancelRetry()
    retryTimer = ns.After(Sync.REQ_RETRY, function()
        retryTimer = nil
        if receiver:Active() or Wish:SyncState() == "ok" then
            retries = 0
            return
        end
        retries = retries + 1
        if retries < Sync.MAX_RETRY then Sync:Request(what) else retries = 0 end
    end)
end

------------------------------------------------------------------------
-- 团长动作（业务层的开始 / 停止 / 放弃在 WishChat 里调用这些）
------------------------------------------------------------------------

-- 成为许愿团长并开始许愿：任期号取已知最大值 + 1。返回新任期号。
function Sync:BecomeLeader()
    local l = LeaderDB()
    l.term = (tonumber(l.term) or 0) + 1
    l.name = ns.Roster:Self()
    l.active = true
    l.rev = (tonumber(l.rev) or 0) + 1
    receiver:Reset()
    CancelRetry()
    SendLead()
    Sync:SendFull()
    FireLeader()
    SetSyncState("ok")
    ns.Events:Fire("RW_BECAME_LEADER")
    return l.term
end

-- 停止许愿（仍是许愿团长）
function Sync:SetActive(active)
    if not Wish:IsLeader() then return false end
    LeaderDB().active = active and true or false
    SendLead()
    FireLeader()
    return true
end

-- 放弃权限
function Sync:Quit()
    if not Wish:IsLeader() then return false end
    local l = LeaderDB()
    Comm():Send("QUIT", l.term)
    l.name, l.active = nil, false
    FireLeader()
    SetSyncState("none")
    return true
end

------------------------------------------------------------------------
-- 接收
------------------------------------------------------------------------

-- 尝试接受 sender 为许愿团长。active 为 nil 时不改进行状态。返回是否接受。
local function TryAcceptLeader(sender, term, active)
    local l = LeaderDB()
    if l.name == sender and tonumber(term) == tonumber(l.term) then
        if active ~= nil and l.active ~= active then
            l.active = active
            FireLeader()
        end
        return true
    end
    if not Sync.AcceptLead({ name = l.name, term = l.term }, { name = sender, term = term }, Ctx()) then
        return false
    end
    local wasLeader = Wish:IsLeader()
    local prevName = l.name
    l.name, l.term = sender, tonumber(term)
    l.rev = 0                          -- 修订号只在同一位团长、同一任期内比较
    if active ~= nil then l.active = active end
    if wasLeader then
        ns.Print("许愿团长已由 " .. sender .. " 接任，你已转为团员模式")
    end
    FireLeader()
    if prevName ~= sender then
        syncedFrom = nil
        -- 新团长开始时会紧接着发全量；没等到就主动请求
        ns.After(Sync.REQ_RETRY, function()
            if not Wish:IsLeader() and LeaderDB().name == sender and not receiver:Active()
                and Wish:SyncState() ~= "ok" then
                Sync:Request("WL")
            end
        end)
        SetSyncState("waiting")
    end
    return true
end

------------------------------------------------------------------------
-- 团员发现团长的数据较旧时提醒（只让一个人提醒：随机延迟，看到别人提醒了就不再发）
------------------------------------------------------------------------

local newerTimer, lastNewer = nil, -100

local function ScheduleNewer()
    if Wish:IsLeader() or newerTimer or GetTime() - lastNewer < 20 then return end
    newerTimer = ns.After(0.3 + math.random() * 1.5, function()
        newerTimer = nil
        lastNewer = GetTime()
        Comm():Send("NEWER", Wish:Term(), Wish:Rev(), LeaderDB().name or "")
    end)
end

-- 被拒绝的宣告或全量：只有来自合法的团长 / 助理、且自己已认定了许愿团长时才提醒
local function NoteRejected(sender)
    if LeaderDB().name and ns.Roster:IsOfficer(sender) then ScheduleNewer() end
end

local function OnLead(sender, term, state, rev)
    if not TryAcceptLeader(sender, term, state == "1") then
        NoteRejected(sender)
        return
    end
    if Wish:IsLeader() then return end
    rev = tonumber(rev)
    if not rev then return end
    if rev < Wish:Rev() then ScheduleNewer() else LeaderDB().rev = rev end
end

-- 团长端：团员说自己的数据更新
local function OnNewer(_, term, rev, leaderName)
    term, rev = tonumber(term) or 0, tonumber(rev) or 0
    local l = LeaderDB()
    if not Wish:IsLeader() then
        -- 别人已经提醒过了，自己不用再发
        if newerTimer and term == Wish:Term() and rev >= Wish:Rev() then
            newerTimer:Cancel()
            newerTimer, lastNewer = nil, GetTime()
        end
        return
    end
    local me = ns.Roster:Self()
    local stale
    if leaderName == me then
        stale = term > Wish:Term() or (term == Wish:Term() and rev > Wish:Rev())
    else
        stale = term > Wish:Term()          -- 自己开始许愿时用的任期号比团里的旧
    end
    if not stale or recovering then return end
    l.term = (leaderName == me) and term or (term + 1)
    l.rev = math.max(Wish:Rev(), rev)
    recovering = true
    local function Done(accepted)
        recovering = false
        Sync:Bump()
        SendLead()
        if accepted ~= true then Sync:SendFull() end
        FireLeader()
    end
    ns.Widgets.Choice("STALE", "团员手里的许愿数据比你的新，可能是你的游戏崩溃过。\n\n用团员的数据恢复吗？",
        "用团员的数据恢复", "保留我的数据（会覆盖团员的）",
        function() ns.Restore:FromMembers(Done, { noConfirm = true }) end,
        function() Done(false) end)
end

local function OnQuit(sender, term)
    local l = LeaderDB()
    if l.name ~= sender then return end
    if (tonumber(term) or 0) < (tonumber(l.term) or 0) then return end
    l.name, l.active = nil, false
    receiver:Reset()
    FireLeader()
    SetSyncState("none")
end

local function OnReq(_, what)
    if Wish:IsLeader() and type(what) == "string" and what:find("W") then
        Sync:ScheduleFull()
    end
end

local function OnHello()
    if Wish:IsLeader() then ScheduleLeadResend() end
end

local pendingRev = nil

local function OnWBegin(sender, term, batch, count, _, rev)
    if not TryAcceptLeader(sender, term, nil) then
        NoteRejected(sender)
        return
    end
    if Wish:IsLeader() then return end
    rev = tonumber(rev)
    if rev and rev < Wish:Rev() then
        -- 比自己手里的旧：不接收，提醒团长
        ns.Debug("收到比本地旧的全量（修订号 " .. rev .. " < " .. Wish:Rev() .. "），已拒绝")
        ScheduleNewer()
        return
    end
    pendingRev = rev
    receiver:Begin(batch, count, GetTime())
    CancelRetry()
    SetSyncState("syncing")
    ns.After(Sync.SYNC_TIMEOUT + 0.5, function()
        if receiver:Expire(GetTime()) then
            ns.Debug("全量同步超时，重新请求")
            Sync:Request("W")
        end
    end)
end

local function DecodeRow(class, dkp, items)
    return { class = class ~= "" and class or nil, dkp = tonumber(dkp) or 0, items = ns.WishModel.DecodeItems(items) }
end

local function OnRow(sender, batch, name, class, dkp, items, rev)
    if sender ~= LeaderDB().name or Wish:IsLeader() then return end
    if not name or name == "" then return end
    local row = DecodeRow(class, dkp, items)
    if tostring(batch) == "0" then
        rev = tonumber(rev)
        if rev and rev > Wish:Rev() then LeaderDB().rev = rev end
        local changed = Model():ApplyRow(name, row.class or "", row.dkp, row.items)
        receiver:Override(name, row)
        if changed and name == ns.Roster:Self() then
            ns.Events:Fire("RW_MY_WISH_RECORDED", name)
        end
        return
    end
    if receiver:Row(batch, name, row) then SetSyncState("syncing") end
end

local function OnWEnd(sender, batch)
    if sender ~= LeaderDB().name or Wish:IsLeader() then return end
    local rows, err = receiver:End(batch)
    if not rows then
        if err == "count" then
            ns.Debug("全量同步不完整（" .. tostring(err) .. "），重新请求")
            Sync:Request("W")
        end
        return
    end
    local records = {}
    local now = time()
    for name, row in pairs(rows) do
        records[name] = {
            class = row.class, dkp = row.dkp, ts = now,
            wish = (#row.items > 0) and { items = row.items } or nil,
        }
    end
    Model():ReplaceAll(records)
    if pendingRev and pendingRev > Wish:Rev() then LeaderDB().rev = pendingRev end
    pendingRev = nil
    syncedFrom = { name = sender, term = LeaderDB().term }
    retries = 0
    CancelRetry()
    SetSyncState("ok")
end

------------------------------------------------------------------------
-- 团队变化
------------------------------------------------------------------------

local function OnRosterChanged()
    if not IsInRaid() then return end      -- 自己离队时花名册先变空，交给 GROUP_LEFT 处理
    local l = LeaderDB()
    if l.name and not ns.Roster:Has(l.name) then
        l.name, l.active = nil, false
        receiver:Reset()
        ns.Print("许愿团长已离队，可由团长或助理重新开始许愿")
        FireLeader()
        SetSyncState("none")
    end
    -- 团长端：为新成员建行并以增量发出（新成员自己会请求全量）
    if Wish:IsLeader() then
        local list = ns.Roster:Get()
        local before = {}
        for _, m in ipairs(list) do before[m.name] = Model():Get(m.name) ~= nil end
        Model():EnsureMembers(list, ns.DB.options.defaultDkp)
        for _, m in ipairs(list) do
            if not before[m.name] then Sync:SendRow(m.name) end
        end
    else
        Model():EnsureMembers(ns.Roster:Get(), ns.DB.options.defaultDkp)
    end
end

-- 进团或登录时已在团中：打招呼并请求全量
local function Greet()
    if not IsInRaid() then return end
    Comm():Send("HELLO", ns.VERSION)
    if Wish:IsLeader() then
        SendLead()
    else
        Sync:Request("WL")
    end
end

local function OnGroupLeft()
    local l = LeaderDB()
    l.name, l.term, l.active, l.rev = nil, 0, false, 0
    receiver:Reset()
    syncedFrom = nil
    CancelRetry()
    FireLeader()
    SetSyncState("none")
end

ns.Events:On("RW_LOADED", function()
    -- 早期版本会把还没加载好的成员（"未知目标"）记进许愿表，这里清掉
    if UNKNOWNOBJECT then ns.DB.main.wishes[UNKNOWNOBJECT] = nil end
    Wish.model = ns.WishModel.New(ns.DB.main.wishes,
        function(ev, name) ns.Events:Fire(ev, name) end, time)
    local C = Comm()
    C:On("LEAD", OnLead)
    C:On("QUIT", OnQuit)
    C:On("REQ", OnReq)
    C:On("HELLO", OnHello)
    C:On("WBEG", OnWBegin)
    C:On("W", OnRow)
    C:On("WEND", OnWEnd)
    C:On("NEWER", OnNewer)
end)

-- 每进入一个团队只打一次招呼（进团、小队转团、登录时已在团中都走这里）
local greeted = false
local function MaybeGreet()
    if not IsInRaid() then
        greeted = false
        return
    end
    if greeted then return end
    greeted = true
    ns.After(2, Greet)
end

ns.Events:On("RW_LOGIN", function()
    -- 登录后稍等花名册就绪；那时仍不在团里就清掉残留的团长认定
    ns.After(3, function()
        if IsInRaid() then MaybeGreet() else OnGroupLeft() end
    end)
end)

ns.Events:On("GROUP_JOINED", MaybeGreet)
ns.Events:On("RW_ROSTER_UPDATE", MaybeGreet)
ns.Events:On("GROUP_LEFT", function()
    greeted = false
    OnGroupLeft()
end)
ns.Events:On("RW_ROSTER_CHANGED", OnRosterChanged)
