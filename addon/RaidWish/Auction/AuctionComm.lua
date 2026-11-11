-- Auction/AuctionComm.lua：拍卖运行层
-- 负责：执行状态机产生的动作、A* 消息收发、团队频道出分与系统消息 Roll 点的接入、
--       待拍列表（掉落记录 + 团队频道出现过的物品链接）、P 标记、结算记录、许愿者自动出分。
--
-- 消息（物品一律传编号）：
--   ASTART 物品 / ARESET 出分表 / AEARLY / AEND 物品 / AROLL 最高分、名单 / ARDIRECT 物品
--   ASETTLED 物品、赢家、类型(s 出分 / r Roll)、数值 / ACANCEL 物品 / ASOLD 物品（手动标记已拍）
-- 名单里的中文名直接传 UTF-8。
local ADDON, ns = ...

local Auction = {}
ns.Auction = Auction

local AM = ns.AuctionModel
local Util = ns.Util

Auction.CAPTURE_MAX = 20        -- 团队频道链接最多保留 20 条、10 分钟
Auction.CAPTURE_EXPIRE = 600

local model = AM.New()
Auction.model = model
local ticker
local ownRoll = nil
local rollBeatPlayed = false
local myLastBid, bidBeatPlayed = nil, false
local autoBidTimer

local function Me() return ns.Roster:Self() end
local function Now() return GetTime() end
local function O() return ns.DB.options.auction end
local function Data() return ns.DB.main.auction end
local function Changed() ns.Events:Fire("RW_AUCTION_CHANGED") end
local function Voice(name, delay)
    if delay then ns.Voice:PlayDelayed(name, delay) else ns.Voice:Play(name) end
end

function Auction:IsOfficer() return ns.Roster:SelfIsOfficer() end
function Auction:IsAuctioneer() return model.isAuctioneer and model:Active() end

-- 物品链接：有缓存用真实链接，否则用 [名字] 或 [物品编号]
function Auction.LinkFor(id)
    local info = ns.Items.GetCached(id)
    if info and info.link then return info.link end
    if info and info.name then return "[" .. info.name .. "]" end
    return "[物品" .. tostring(id) .. "]"
end

------------------------------------------------------------------------
-- 待拍列表
------------------------------------------------------------------------

-- 待拍物品：掉落记录里未拍的（许愿物品直接归许愿者，不进待拍），加上团队频道出现过的未拍链接。
-- 按物品编号去重，新的在前。
function Auction:Pending()
    local out, seen = {}, {}
    local now = time()
    local filters = O().quality
    local function add(id, ts, source)
        if not id or seen[id] then return end
        local info = ns.Items.GetCached(id)
        local q = info and info.quality
        if q and q == 0 then q = 1 end
        if q and filters[q] == false then return end
        seen[id] = true
        out[#out + 1] = { id = id, ts = ts or 0, source = source }
    end
    for _, e in ipairs(ns.LootLog:Entries()) do
        if not e.sold and not e.wish then add(e.id, e.ts, "loot") end
    end
    for _, c in ipairs(Data().captured) do
        if not c.sold and now - (c.ts or 0) <= Auction.CAPTURE_EXPIRE then add(c.id, c.ts, "chat") end
    end
    table.sort(out, function(a, b) return a.ts > b.ts end)
    return out
end

-- 手动加入待拍（拖到列表上，或 Shift 点击聊天框里的链接）
function Auction:AddPending(id, sender)
    id = tonumber(id)
    if not id then return false end
    local list = Data().captured
    for i = #list, 1, -1 do if list[i].id == id then table.remove(list, i) end end
    table.insert(list, 1, { id = id, ts = time(), sender = sender or Me(), sold = false })
    while #list > Auction.CAPTURE_MAX do table.remove(list) end
    Changed()
    return true
end

-- 标记已拍：团队频道的链接和最近一条未拍的同名掉落记录
local function MarkSold(id, sold)
    for _, c in ipairs(Data().captured) do if c.id == id then c.sold = true end end
    local entries = ns.LootLog:Entries()
    for _, e in ipairs(entries) do
        if e.id == id and not e.sold then
            ns.LootLog:SetSold(e.uid, sold)
            break
        end
    end
    Changed()
end

-- 团长端右键"标记为已拍"
function Auction:MarkSold(id)
    if not self:IsOfficer() then return false end
    MarkSold(id, { manual = true })
    ns.Comm:Send("ASOLD", id)
    return true
end

------------------------------------------------------------------------
-- P 标记（"不要这件"）
-- 新版对应为"默认收起"：标记过的物品开拍时弹窗是收起状态；进入 Roll 阶段或自己出分时清除并展开。
------------------------------------------------------------------------

function Auction:IsPMarked(id) return Data().pMarked[id] == true end

function Auction:SetPMark(id, on)
    Data().pMarked[id] = on and true or nil
end

local function ClearPMark()
    if model.item and Auction:IsPMarked(model.item) then
        Auction:SetPMark(model.item, false)
        ns.Events:Fire("RW_AUCTION_EXPAND")
    end
end

------------------------------------------------------------------------
-- 执行动作
------------------------------------------------------------------------

local function IsMine(name) return name and name == Me() end

local function RecordResult(r)
    local list = Data().results
    list[#list + 1] = { winner = r.winner, id = r.item, score = r.score, roll = r.roll, ts = time() }
    while #list > AM.MAX_RESULTS do table.remove(list, 1) end
end

-- 所有人在结算时都执行（拍卖方由动作触发，其他人由 ASETTLED 触发）
local function OnResult(r)
    local sold
    if not r.winner then sold = { none = true }
    elseif r.roll and not r.score then sold = { winner = r.winner, roll = r.roll }
    else sold = { winner = r.winner, score = r.score, roll = r.roll } end
    if r.item then MarkSold(r.item, sold) end
    if r.winner then RecordResult(r) end
    if IsMine(r.winner) then Voice(r.roll and "won_roll" or "won_bid") else Voice("auction_end") end
    -- 最后一件：结算后 3 秒播放
    if model.isAuctioneer and #Auction:Pending() == 0 then Voice("all_sold", 3) end
    ns.Events:Fire("RW_AUCTION_RESULT", r)
end

local CHAT_TTL = { ["三"] = 2, ["二"] = 2, ["一"] = 2 }

local function Execute(acts)
    for _, a in ipairs(acts) do
        if a.type == "chat" then
            ns.Chat:Send(a.text, a.channel, { ttl = CHAT_TTL[a.text] or 30 })
        elseif a.type == "send" then
            ns.Comm:Send(a.cmd, unpack(a.args))
        elseif a.type == "voice" then
            Voice(a.name, a.delay)
        elseif a.type == "result" then
            OnResult(a)
        end
    end
end

local function StopTicker()
    if ticker then ticker:Cancel() ticker = nil end
end

local function OnTick()
    if not model:Active() then
        StopTicker()
        Changed()
        return
    end
    local before = model.state
    local acts = model:Tick(Now())
    Execute(acts)
    -- 状态或数据变了才整体刷新；平时只更新倒计时和进度条（每秒 10 次）
    if #acts > 0 or model.state ~= before then
        Changed()
    else
        ns.Events:Fire("RW_AUCTION_TICK")
    end
end

local function StartTicker()
    if not ticker then ticker = ns.Ticker(0.1, OnTick) end
end

-- 开拍后各端都做的事：重置自己的出分 / Roll 记录、语音、许愿者自动出分
local function OnStarted(id)
    ownRoll, rollBeatPlayed, myLastBid, bidBeatPlayed = nil, false, nil, false
    local rec = ns.Wish.model and ns.Wish.model:Get(Me())
    local mine = ns.WishModel.WantsItem(rec, { id = id })
    Voice(mine and "my_wish" or "auction_start")
    if autoBidTimer then autoBidTimer:Cancel() end
    autoBidTimer = ns.After(1, function()
        autoBidTimer = nil
        if model:InProgress() and model.item == id and (model.state == "bid" or model.state == "count") then
            local r2 = ns.Wish.model:Get(Me())
            if ns.WishModel.WantsItem(r2, { id = id }) then
                ns.Chat:Send("5", "RAID", { ttl = 3 })
                ns.After(1, function() Voice("bid_5_auto") end)
            end
        end
    end)
    ns.Events:Fire("RW_AUCTION_STARTED", id)
    StartTicker()
    Changed()
end

------------------------------------------------------------------------
-- 拍卖方的操作
------------------------------------------------------------------------

local function CanHost()
    if not IsInRaid() then
        ns.Print("需要在团队中才能操作。")
        return false
    end
    if not Auction:IsOfficer() then
        ns.Print("只有团长或助理可以操作")
        return false
    end
    if model:InProgress() then
        ns.Print("还有一场拍卖没结束，结束后再开下一场。")
        return false
    end
    return true
end

function Auction:StartItem(id)
    id = tonumber(id)
    if not id or not CanHost() then return false end
    if model.state == "settle" then model:Reset() end
    Execute(model:Start(id, Auction.LinkFor(id), Me(), Now()))
    OnStarted(id)
    return true
end

-- 直接全团 Roll；id 为 nil 时取第一件待拍
function Auction:DirectRoll(id)
    if model:InProgress() and self:IsAuctioneer() and model.state == "bid" then
        -- 出分阶段改为直接 Roll：先取消本次出分（不通报），再对同一件发起全团 Roll
        id = model.item
        model:Reset()
    elseif not CanHost() then
        return false
    end
    if not id then
        local p = self:Pending()
        id = p[#p] and p[#p].id
    end
    if not id then
        ns.Print("没有待拍的装备，无法直接 Roll。")
        return false
    end
    Execute(model:DirectRoll(id, Auction.LinkFor(id), Me(), Now()))
    ownRoll, rollBeatPlayed = nil, false
    StartTicker()
    Changed()
    return true
end

local function RequireAuctioneer(what)
    if Auction:IsAuctioneer() then return true end
    ns.Print("只有拍卖发起者可以" .. what .. "。")
    return false
end

function Auction:Early()
    if not RequireAuctioneer("提前结束拍卖") then return false end
    Execute(model:Early(Now()))
    Changed()
    return true
end

function Auction:Cancel()
    if not RequireAuctioneer("取消拍卖") then return false end
    Execute(model:Cancel())
    Changed()
    return true
end

-- /xypm：拍第一件（最早的）未拍物品
function Auction:QuickAuction()
    local p = self:Pending()
    if #p == 0 then
        if CanHost() then ns.Print("没有待拍的装备。") end
        return false
    end
    return self:StartItem(p[#p].id)
end

------------------------------------------------------------------------
-- 出分按钮：在团队频道发数字
------------------------------------------------------------------------

-- 返回 nil 表示可以出分，否则返回错误文字
function Auction:CheckOwnBid(score)
    if model.state ~= "bid" and model.state ~= "count" then return "当前不是出分阶段" end
    local max = model:HighestBid()
    if max > score then return "没出成：已经有人出了更高的分。" end
    local rec = ns.Wish.model:Get(Me())
    local dkp = rec and tonumber(rec.dkp) or 0
    if score == 9 then
        if dkp < 4 then return "分数不够" end
        if not ns.WishModel.WantsItem(rec, { id = model.item }) then return "没出成：9 分只能出给自己许愿的装备。" end
    elseif dkp < score then
        return "分数不够"
    end
    return nil
end

function Auction:BidButton(score)
    local err = self:CheckOwnBid(score)
    if err then
        Voice("bid_fail")
        return false, err
    end
    ns.Chat:Send(tostring(score), "RAID", { ttl = 3 })
    Voice("bid_" .. score)
    return true
end

function Auction:RollButton()
    if model.state ~= "roll" then return false, "当前非roll点阶段！" end
    if ownRoll then
        Voice("bid_fail")
        return false, "你已经 Roll 过了"
    end
    ownRoll = -1     -- 标记已点过，真实点数等系统消息
    RandomRoll(1, 100)
    return true
end

function Auction:MyRoll() return (ownRoll and ownRoll > 0) and ownRoll or nil end

------------------------------------------------------------------------
-- 团队频道：出分与链接捕获
------------------------------------------------------------------------

-- 出分有效性
local function CheckBid(name, score)
    local rec = ns.Wish.model and ns.Wish.model:Get(name)
    local dkp = rec and tonumber(rec.dkp) or 0
    if score >= 5 then
        if not ns.WishModel.WantsItem(rec, { id = model.item }) then
            return "注意：" .. name .. " 没有许愿这件装备，出的 " .. score .. " 分不算"
        end
        if score > dkp + 5 then
            return "注意：" .. name .. " 只有 " .. dkp .. " 分，加上许愿的 5 分最多出 " .. (dkp + 5) .. " 分，不够出 " .. score .. " 分"
        end
    elseif score > dkp then
        return "注意：" .. name .. " 只剩 " .. dkp .. " 分，不够出 " .. score .. " 分"
    end
    return nil
end

-- 插件自己发的通报里也有物品链接，不当作新的待拍物品
local OWN_PATTERNS = {
    "^开拍：", "^全团 Roll：", "分拍得 ", " 以 Roll 点 ", " 没人出分，流拍$", " 没人 Roll，流拍$",
    "^本次拍卖已取消：", "^【许愿】", "^「", "^注意：", "的许愿：", "^还没许愿", "^开始播报许愿",
}

local function IsOwnAnnouncement(text)
    for _, p in ipairs(OWN_PATTERNS) do if text:find(p) then return true end end
    return false
end

local function CaptureLinks(text, sender)
    local trimmed = Util.Trim(text)
    if trimmed:sub(1, 2):lower() == "xy" or trimmed:sub(1, 3):lower() == "txy" then return end
    if IsOwnAnnouncement(trimmed) then return end
    for _, l in ipairs(ns.Items.ParseLinks(text)) do Auction:AddPending(l.id, sender) end
end

local function WatchOwnBid()
    local mine = model.bids[Me()]
    if not mine then
        myLastBid = nil
        return
    end
    if mine ~= myLastBid then
        myLastBid, bidBeatPlayed = mine, false
        return
    end
    if bidBeatPlayed or mine <= 0 then return end
    for name, s in pairs(model.bids) do
        if name ~= Me() and s > mine then
            Voice("outbid")
            bidBeatPlayed = true
            return
        end
    end
end

local function OnRaidChat(text, sender)
    if ns.Compat.AnySecret(text, sender) then return end
    if type(text) ~= "string" or type(sender) ~= "string" then return end
    local name = Util.NormName(sender)
    local t = Util.Trim(text)
    if model:InProgress() then
        local n = t:match("^(%d)$")
        if t == "P" or t == "p" or t == "0" then
            Execute(model:Pass(name, Now()))
        elseif n and tonumber(n) >= 1 then
            local before = model.bids[name]
            Execute(model:Bid(name, tonumber(n), Now(), CheckBid))
            if IsMine(name) then ClearPMark() end
            if model.isAuctioneer and model.bids[name] ~= before then WatchOwnBid() end
        end
        Changed()
    end
    CaptureLinks(text, name)
end

------------------------------------------------------------------------
-- 系统消息：Roll 点（用 RANDOM_ROLL_RESULT 生成模式，不写死"掷出"）
------------------------------------------------------------------------

local function OnSystem(text)
    if ns.Compat.AnySecret(text) or type(text) ~= "string" then return end
    if not model:Active() then return end
    local fmt = _G.RANDOM_ROLL_RESULT
    if type(fmt) ~= "string" then return end
    local who, roll, lo, hi = Util.MatchFormat(text, fmt)
    if not who then return end
    who = Util.NormName(who)
    local _, recorded = model:Roll(who, roll, lo, hi, Now())
    if not recorded then return end
    roll = tonumber(roll)
    if IsMine(who) then
        ownRoll = roll
        if not rollBeatPlayed then
            for n, r in pairs(model.rolls) do
                if n ~= who and r > roll then
                    Voice("outrolled")
                    rollBeatPlayed = true
                    break
                end
            end
        end
    elseif ownRoll and ownRoll > 0 and roll > ownRoll and not rollBeatPlayed then
        Voice("outrolled")
        rollBeatPlayed = true
    end
    Changed()
end

------------------------------------------------------------------------
-- 消息接收（其他人镜像拍卖方的状态）
------------------------------------------------------------------------

local function FromHost(sender)
    return ns.Roster:IsOfficer(sender)
end

local function FromCurrent(sender)
    return FromHost(sender) and model.auctioneer == sender
end

local handlers = {
    ASTART = function(sender, item)
        if not FromHost(sender) then return end
        item = tonumber(item)
        if not item then return end
        model:OnStart(item, sender, Now())
        OnStarted(item)
    end,
    ARESET = function(sender, encoded)
        if not FromCurrent(sender) then return end
        model:OnReset(encoded, Now())
        WatchOwnBid()
        Changed()
    end,
    AEARLY = function(sender)
        if not FromCurrent(sender) then return end
        model:OnEarly(Now())
        Voice("countdown")
        Changed()
    end,
    AEND = function(sender)
        if not FromCurrent(sender) then return end
        model:OnEnd()
        Changed()
    end,
    AROLL = function(sender, _, names)
        if not FromCurrent(sender) then return end
        model:OnRoll(names, Now())
        ownRoll, rollBeatPlayed = nil, false
        ClearPMark()
        Voice("roll_start")
        if model:InRoll(Me()) then ns.Events:Fire("RW_AUCTION_EXPAND") end
        Changed()
    end,
    ARDIRECT = function(sender, item)
        if not FromHost(sender) then return end
        model:OnDirect(tonumber(item), sender, Now())
        ownRoll, rollBeatPlayed = nil, false
        ClearPMark()
        Voice("roll_start")
        ns.Events:Fire("RW_AUCTION_STARTED", model.item)
        StartTicker()
        Changed()
    end,
    ASETTLED = function(sender, item, winner, kind, value)
        if not FromHost(sender) then return end
        model:OnSettled(tonumber(item), winner, kind, value, Now())
        OnResult({ item = tonumber(item), winner = model.result.winner, score = model.result.score, roll = model.result.roll })
        StartTicker()
        Changed()
    end,
    ACANCEL = function(sender)
        if not FromCurrent(sender) then return end
        model:OnCancel()
        Changed()
    end,
    ASOLD = function(sender, item)
        if not FromHost(sender) then return end
        MarkSold(tonumber(item), { manual = true })
    end,
}

ns.Events:On("RW_LOADED", function()
    for cmd, fn in pairs(handlers) do ns.Comm:On(cmd, fn) end
end)

ns.Events:On("CHAT_MSG_RAID", OnRaidChat)
ns.Events:On("CHAT_MSG_RAID_LEADER", OnRaidChat)
ns.Events:On("CHAT_MSG_RAID_WARNING", function(text, sender)
    if ns.Compat.AnySecret(text, sender) or type(text) ~= "string" then return end
    CaptureLinks(text, Util.NormName(sender or ""))
end)
ns.Events:On("CHAT_MSG_SYSTEM", OnSystem)
ns.Events:On("GROUP_LEFT", function()
    model:Reset()
    StopTicker()
    Changed()
end)

-- 掉落记录变化会影响待拍数
ns.Events:On("RW_LOOT_CHANGED", Changed)

------------------------------------------------------------------------
-- /xypm
------------------------------------------------------------------------

-- 斜杠命令不分大小写，/XYPM 也能用
SLASH_RAIDWISHPM1 = "/xypm"
SLASH_RAIDWISHPM2 = "/拍装备"
SlashCmdList["RAIDWISHPM"] = function(msg)
    if Util.Trim(msg or "") == "reset" then
        ns.DB.char.frames = {}
        ns.Events:Fire("RW_RESET_POSITIONS")
        ns.Print("拍卖相关窗口位置已重置")
        return
    end
    Auction:QuickAuction()
end
