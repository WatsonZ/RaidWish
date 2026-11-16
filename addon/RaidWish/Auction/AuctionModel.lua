-- Auction/AuctionModel.lua：拍卖状态机（纯逻辑）
-- 不调用游戏接口：时间由调用方传入；每个输入返回一组"动作"，由运行层执行：
--   { type = "chat", text =, channel = }        发团队聊天 / 团队通知
--   { type = "send", cmd =, args = {...} }      发插件消息
--   { type = "voice", name =, delay = }         语音（delay 为延迟秒数）
--   { type = "result", item =, winner =, score =, roll = }  结算结果（winner 为 nil 表示流拍）
--
-- 状态：
--   idle 0 空闲 / bid 1 出分 / count 2 倒数"三二一" / wait 3 等待结算 / roll 4 Roll 点 / settle 5 结算展示
--
-- 两种角色：拍卖方（auctioneer = true）推进状态并产生聊天和消息；
-- 其他人（auctioneer = false）只按收到的消息镜像状态，用于显示。
local ADDON, ns = ...

local AM = {}
AM.__index = AM
ns.AuctionModel = AM

AM.BID_TIME = 10        -- 出分阶段总时长（有人出分后重新计时）
AM.COUNT_AT = 7         -- 出分阶段第 7 秒开始倒数
AM.WAIT_TIME = 1        -- 出分结束后等 1 秒再结算（wait 状态）
AM.ROLL_TIME = 10       -- Roll 阶段时长（固定，不因有人 Roll 而重新计时；同分 Roll 全部掷完就提前结束）
AM.SETTLE_TIME = 3      -- 结算展示时长
AM.MAX_RESULTS = 20

-- 倒数用阿拉伯数字。后面带"…"：只发一个数字的话，会被当成在团队频道出分
AM.COUNT_TEXT = { [3] = "3…", [2] = "2…", [1] = "1…" }
local CN = AM.COUNT_TEXT

-- 数字转中文（0~99）
function AM.ChineseNumeral(num)
    num = tonumber(num) or 0
    if num == 0 then return "零" end
    local cn = { "", "一", "二", "三", "四", "五", "六", "七", "八", "九" }
    local s = ""
    local tens, ones = math.floor(num / 10), num % 10
    if tens > 0 then s = s .. (tens == 1 and "十" or (cn[tens + 1] .. "十")) end
    if ones > 0 then s = s .. cn[ones + 1] end
    return s
end

function AM.New(opts)
    local self = setmetatable({}, AM)
    self:Reset()
    self.opts = opts or {}
    return self
end

function AM:Reset()
    self.state = "idle"
    self.item, self.link, self.auctioneer, self.isAuctioneer = nil, nil, nil, false
    self.bids, self.bidOrder = {}, {}
    self.rollers, self.rolls, self.rollOrder, self.preRolls = nil, {}, {}, {}
    self.direct = false
    self.phaseStart, self.deadline, self.lastShout, self.countLeft = 0, 0, 0, 0
    self.result = nil
end

------------------------------------------------------------------------
-- 查询
------------------------------------------------------------------------

function AM:Active() return self.state ~= "idle" end
function AM:InProgress() return self.state == "bid" or self.state == "count" or self.state == "wait" or self.state == "roll" end

-- 最高出分与出最高分的人（按出分先后）
function AM:HighestBid()
    local max, who = 0, {}
    for _, name in ipairs(self.bidOrder) do
        local s = self.bids[name]
        if s then
            if s > max then max, who = s, { name } elseif s == max and s > 0 then who[#who + 1] = name end
        end
    end
    return max, who
end

function AM:BidCount()
    local n = 0
    for _ in pairs(self.bids) do n = n + 1 end
    return n
end

function AM:HighestRoll()
    local max, who = 0, {}
    for _, name in ipairs(self.rollOrder) do
        local r = self.rolls[name]
        if r > max then max, who = r, { name } elseif r == max then who[#who + 1] = name end
    end
    return max, who
end

-- 同分 Roll 名单里的人是否都掷过了（全团 Roll 不提前结束）
function AM:AllRolled()
    if self.state ~= "roll" or self.rollers == "all" or not self.rollers then return false end
    for n in pairs(self.rollers) do if self.rolls[n] == nil then return false end end
    return true
end

function AM:InRoll(name)
    if self.state ~= "roll" then return false end
    if self.rollers == "all" then return true end
    return self.rollers ~= nil and self.rollers[name] == true
end

-- 剩余秒数与总秒数（进度条用）
function AM:Remaining(now)
    if self.state == "bid" then
        return math.max(0, AM.BID_TIME - (now - self.phaseStart)), AM.BID_TIME
    elseif self.state == "count" then
        return math.max(0, 3 - (now - self.phaseStart)), AM.BID_TIME
    elseif self.state == "roll" then
        return math.max(0, self.deadline - now), AM.ROLL_TIME
    elseif self.state == "settle" then
        return math.max(0, self.deadline - now), AM.SETTLE_TIME
    end
    return 0, AM.BID_TIME
end

function AM:EncodeBids()
    local parts = {}
    for _, name in ipairs(self.bidOrder) do
        if self.bids[name] then parts[#parts + 1] = name .. ":" .. self.bids[name] end
    end
    return table.concat(parts, ",")
end

function AM.DecodeBids(s)
    local bids, order = {}, {}
    for part in tostring(s or ""):gmatch("[^,]+") do
        local name, score = part:match("^(.*):(%d+)$")
        if name and name ~= "" then
            bids[name] = tonumber(score)
            order[#order + 1] = name
        end
    end
    return bids, order
end

------------------------------------------------------------------------
-- 内部
------------------------------------------------------------------------

local function Push(acts, a) acts[#acts + 1] = a return acts end
local function Chat(acts, text, channel) return Push(acts, { type = "chat", text = text, channel = channel or "RAID" }) end
local function Send(acts, cmd, ...) return Push(acts, { type = "send", cmd = cmd, args = { ... } }) end
local function Voice(acts, name, delay) return Push(acts, { type = "voice", name = name, delay = delay }) end

local function SetBid(self, name, score)
    if self.bids[name] == nil then self.bidOrder[#self.bidOrder + 1] = name end
    self.bids[name] = score
end

local function RemoveBid(self, name)
    if self.bids[name] == nil then return false end
    self.bids[name] = nil
    for i = #self.bidOrder, 1, -1 do if self.bidOrder[i] == name then table.remove(self.bidOrder, i) end end
    return true
end

-- 进入 Roll 阶段（names 为名字数组，或 "all" 表示全团）
local function EnterRoll(self, names, now)
    self.state = "roll"
    self.deadline = now + AM.ROLL_TIME
    self.lastShout = now
    self.rolls, self.rollOrder = {}, {}
    if names == "all" then
        self.rollers = "all"
    else
        self.rollers = {}
        for _, n in ipairs(names) do self.rollers[n] = true end
    end
    -- 采纳出分阶段提前 Roll 的记录（只认名单内、每人第一次）
    for _, p in ipairs(self.preRolls) do
        if self:InRoll(p.name) and self.rolls[p.name] == nil then
            self.rolls[p.name] = p.roll
            self.rollOrder[#self.rollOrder + 1] = p.name
        end
    end
    if self:AllRolled() then self.deadline = now end     -- 提前 Roll 过的已经齐了
    self.preRolls = {}
end

local function Settle(self, acts, now, winner, score, roll)
    self.state = "settle"
    self.deadline = now + AM.SETTLE_TIME
    self.result = { item = self.item, winner = winner, score = score, roll = roll }
    Push(acts, { type = "result", item = self.item, winner = winner, score = score, roll = roll })
    if self.isAuctioneer then
        local kind, value = "", ""
        if winner then
            if roll then kind, value = "r", roll else kind, value = "s", score end
        end
        Send(acts, "ASETTLED", self.item, winner or "", kind, value)
    end
    return acts
end

------------------------------------------------------------------------
-- 拍卖方的输入
------------------------------------------------------------------------

-- 开拍
function AM:Start(item, link, me, now)
    self:Reset()
    self.state = "bid"
    self.item, self.link, self.auctioneer, self.isAuctioneer = item, link, me, true
    self.phaseStart = now
    local acts = {}
    Chat(acts, "开拍：" .. link .. "，请在团队频道出分", "RAID_WARNING")
    Send(acts, "ASTART", item)
    return acts
end

-- 直接全团 Roll
function AM:DirectRoll(item, link, me, now)
    self:Reset()
    self.item, self.link, self.auctioneer, self.isAuctioneer = item, link, me, true
    self.direct = true
    EnterRoll(self, "all", now)
    local acts = {}
    Chat(acts, "全团 Roll：" .. link .. "，需要的请 /roll", "RAID_WARNING")
    Voice(acts, "roll_start")
    Send(acts, "ARDIRECT", item)
    return acts
end

-- 出分（团队频道的 1~9）。check(name, score) 由运行层提供，返回 nil 表示有效、否则返回警告文字。
-- 只有拍卖方维护出分表，其他人靠 ARESET 同步。
function AM:Bid(name, score, now, check)
    local acts = {}
    if not self.isAuctioneer then return acts end
    if self.state ~= "bid" and self.state ~= "count" and self.state ~= "wait" then return acts end
    local warn = check and check(name, score)
    if warn then return Chat(acts, warn, "RAID") end
    -- 只有能改变结果的出分（不低于当前最高分：追平会进 Roll、更高会领先）才重新计时；
    -- 比最高分低的出分照样记下，但不打断倒数
    local changesResult = score >= self:HighestBid()
    SetBid(self, name, score)
    if not changesResult then
        Send(acts, "ARESET", self:EncodeBids())
        return acts
    end
    if self.state == "bid" or self.state == "count" then
        self.state = "bid"
        self.phaseStart = now
        Send(acts, "ARESET", self:EncodeBids())
    end
    return acts
end

-- 放弃（团队频道发 P / p / 0）
function AM:Pass(name, now)
    local acts = {}
    if not self.isAuctioneer then return acts end
    local was = self.bids[name]
    local top = self:HighestBid()
    if not RemoveBid(self, name) then return acts end
    -- 放弃的不是最高分的人：结果不变，只同步出分表，不重新计时
    if was < top then
        Send(acts, "ARESET", self:EncodeBids())
        return acts
    end
    if self.state == "bid" or self.state == "count" then
        self.state = "bid"
        self.phaseStart = now
        Send(acts, "ARESET", self:EncodeBids())
    end
    return acts
end

-- 数秒
function AM:Early(now)
    local acts = {}
    if not self.isAuctioneer then return acts end
    if self.state == "bid" then
        self.state = "count"
        self.phaseStart = now
        self.countLeft = 2
        self.lastShout = now
        Chat(acts, CN[3], "RAID")
        Voice(acts, "countdown")
        Send(acts, "AEARLY")
    elseif self.state == "roll" then
        self.deadline = now + 3
        self.lastShout = now
        Chat(acts, CN[3], "RAID")
        Voice(acts, "countdown")
        Send(acts, "AEARLY")
    end
    return acts
end

function AM:Cancel()
    local acts = {}
    if not self.isAuctioneer or not self:InProgress() then return acts end
    Chat(acts, "本次拍卖已取消：" .. tostring(self.link), "RAID_WARNING")
    Send(acts, "ACANCEL", self.item)
    self:Reset()
    return acts
end

------------------------------------------------------------------------
-- 所有人：Roll 点（系统消息）
------------------------------------------------------------------------

-- 记录一次 Roll。只认 1~100、名单内、每人第一次（类 LootHog）。出分阶段的 Roll 先预收集。
-- 返回 actions 与是否被记录。
function AM:Roll(name, value, lo, hi, now)
    local acts = {}
    value, lo, hi = tonumber(value), tonumber(lo), tonumber(hi)
    if not value or lo ~= 1 or hi ~= 100 or value < 1 or value > 100 then return acts, false end
    if self.state == "bid" or self.state == "count" then
        for _, p in ipairs(self.preRolls) do if p.name == name then return acts, false end end
        self.preRolls[#self.preRolls + 1] = { name = name, roll = value }
        return acts, false
    end
    if self.state ~= "roll" or not self:InRoll(name) or self.rolls[name] ~= nil then return acts, false end
    self.rolls[name] = value
    self.rollOrder[#self.rollOrder + 1] = name
    -- 不重新计时（否则有人在倒数时 Roll 又会重新倒数一遍）；同分 Roll 的人都掷完了就提前结束
    if self:AllRolled() then self.deadline = now end
    return acts, true
end

------------------------------------------------------------------------
-- 时间推进（拍卖方产生聊天与消息；其他人只做显示用的状态转换）
------------------------------------------------------------------------

local function EvaluateBids(self, acts, now)
    local max, who = self:HighestBid()
    if #who >= 2 then
        EnterRoll(self, who, now)
        Chat(acts, "同分，请 " .. table.concat(who, "、") .. " /roll 决定归属", "RAID_WARNING")
        Voice(acts, "roll_start")
        Send(acts, "AROLL", max, table.concat(who, ","))
        return
    end
    if max > 0 and #who == 1 then
        Chat(acts, who[1] .. " 以" .. AM.ChineseNumeral(max) .. "分拍得 " .. self.link .. "，拾取时自动扣分", "RAID_WARNING")
        Settle(self, acts, now, who[1], max, nil)
        return
    end
    Chat(acts, self.link .. " 没人出分，流拍", "RAID_WARNING")
    Settle(self, acts, now, nil, nil, nil)
end

local function EvaluateRolls(self, acts, now)
    local max, who = self:HighestRoll()
    if #who == 1 then
        local winner = who[1]
        if self.direct then
            Chat(acts, winner .. " 以 Roll 点 " .. max .. " 拿到 " .. self.link, "RAID_WARNING")
            Settle(self, acts, now, winner, nil, max)
        else
            local score = self.bids[winner] or 1
            Chat(acts, winner .. " 以 Roll 点 " .. max .. " 拿到 " .. self.link .. "，出价"
                .. AM.ChineseNumeral(score) .. "分，拾取时自动扣分", "RAID_WARNING")
            Settle(self, acts, now, winner, score, max)
        end
        return
    end
    if #who >= 2 then
        EnterRoll(self, who, now)
        Chat(acts, "Roll 点相同，请 " .. table.concat(who, "、") .. " 再 /roll 一次", "RAID_WARNING")
        Voice(acts, "roll_start")
        Send(acts, "AROLL", self:HighestBid(), table.concat(who, ","))
        return
    end
    Chat(acts, self.link .. " 没人 Roll，流拍", "RAID_WARNING")
    Settle(self, acts, now, nil, nil, nil)
end

function AM:Tick(now)
    local acts = {}
    local s = self.state
    if s == "settle" then
        if now >= self.deadline then self:Reset() end
        return acts
    end
    if not self.isAuctioneer then return acts end

    if s == "bid" then
        if now - self.phaseStart >= AM.COUNT_AT then
            self.state = "count"
            self.phaseStart = now
            self.countLeft = 2
            self.lastShout = now
            Voice(acts, "countdown")
            Chat(acts, CN[3], "RAID")
        end
    elseif s == "count" then
        if self.countLeft > 0 then
            if now - self.lastShout >= 1 then
                self.lastShout = now
                Chat(acts, CN[self.countLeft], "RAID")
                self.countLeft = self.countLeft - 1
                if self.countLeft == 0 then
                    -- "出分截止！"留到 wait 结束时再发：和"一"同一刻发出时，两个频道到达顺序不固定
                    Send(acts, "AEND", self.item)
                    self.state = "wait"
                    self.phaseStart = now
                end
            end
        end
    elseif s == "wait" then
        if now - self.phaseStart >= AM.WAIT_TIME then
            Chat(acts, "出分截止！", "RAID_WARNING")
            EvaluateBids(self, acts, now)
        end
    elseif s == "roll" then
        local remaining = self.deadline - now
        if remaining <= 0 then
            EvaluateRolls(self, acts, now)
        elseif remaining <= 3 and now - self.lastShout >= 1 then
            self.lastShout = now
            local n = math.ceil(remaining)
            if CN[n] then Chat(acts, CN[n], "RAID") end
        end
    end
    return acts
end

------------------------------------------------------------------------
-- 其他人：按收到的消息镜像状态
------------------------------------------------------------------------

function AM:OnStart(item, auctioneer, now)
    self:Reset()
    self.state = "bid"
    self.item, self.auctioneer = item, auctioneer
    self.phaseStart = now
end

function AM:OnReset(encoded, now)
    if self.state ~= "bid" and self.state ~= "count" then return end
    self.bids, self.bidOrder = AM.DecodeBids(encoded)
    self.state = "bid"
    self.phaseStart = now
end

function AM:OnEarly(now)
    if self.state == "bid" or self.state == "count" then
        self.state = "count"
        self.phaseStart = now
    elseif self.state == "roll" then
        self.deadline = now + 3
    end
end

-- Roll 阶段忽略迟到的 AEND（网络延迟可能让它晚到）
function AM:OnEnd()
    if self.state == "bid" or self.state == "count" then
        self.state = "wait"
    end
end

function AM:OnRoll(names, now)
    if self.state == "settle" then return end      -- 结算阶段忽略迟到的 Roll 广播
    local list = {}
    for n in tostring(names or ""):gmatch("[^,]+") do list[#list + 1] = n end
    EnterRoll(self, list, now)
end

function AM:OnDirect(item, auctioneer, now)
    if self.state == "settle" then return end
    self:Reset()
    self.item, self.auctioneer, self.direct = item, auctioneer, true
    EnterRoll(self, "all", now)
end

function AM:OnSettled(item, winner, kind, value, now)
    if winner == "" then winner = nil end
    local score, roll
    if kind == "r" then roll = tonumber(value) elseif kind == "s" then score = tonumber(value) end
    self.item = item or self.item
    self.state = "settle"
    self.deadline = now + AM.SETTLE_TIME
    self.result = { item = self.item, winner = winner, score = score, roll = roll }
end

function AM:OnCancel()
    self:Reset()
end
