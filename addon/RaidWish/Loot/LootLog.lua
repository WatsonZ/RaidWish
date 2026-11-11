-- Loot/LootLog.lua：掉落记录、去重、许愿完成判定、自动扣分、掉落同步
--
-- 记录结构（RaidWishDB.loot，数组，按时间先后）：
--   { uid = 序号, id = 物品编号, player = 获得者, points = 扣除的分数, wish = 是否许愿物品, ts = 时间戳,
--     sold = nil | { winner = 名字, score = 出分 } | { winner = 名字, roll = 点数 }, removed = nil }
--
-- 分工：许愿团长是唯一的权威。
--   · 许愿团长看到掉落：判定许愿完成、自动扣分、记录，并以增量同步给全团。
--   · 团员看到掉落：用 LUP 报给许愿团长（团长可能不在拾取消息范围内）。
--   · 团里没有许愿团长时：各自只做本地记录。
--   团员拾取自己许愿的物品时不改本地许愿、不通报，避免重复通报和数据不一致。
--
-- 消息：LBEG 任期号、批次号、条数 / L 批次号、uid、物品编号、获得者、分数、是否许愿、时间戳、拍卖结果 / LEND 批次号
--       LDEL uid（移除一条）/ LUP 物品编号、获得者（团员上报）
local ADDON, ns = ...

local LootLog = {}
ns.LootLog = LootLog

LootLog.DUP_WINDOW = 10      -- 同一人同一物品 10 秒内只记一次
LootLog.BID_WINDOW = 60      -- 自动扣分：拾取前 60 秒内在团队频道出过分

local Util = ns.Util

local function Store() return ns.DB.main.loot end
local function O() return ns.DB.options end
local function M() return ns.Wish.model end

local function Changed() ns.Events:Fire("RW_LOOT_CHANGED") end

------------------------------------------------------------------------
-- 纯逻辑：拾取消息解析、品质筛选、自动扣分规则
------------------------------------------------------------------------

-- 用客户端全局字符串生成的匹配顺序：先试"多件"，再试单件
local function LootFormats()
    return {
        { _G.LOOT_ITEM_SELF_MULTIPLE, true }, { _G.LOOT_ITEM_PUSHED_SELF_MULTIPLE, true },
        { _G.LOOT_ITEM_MULTIPLE, false }, { _G.LOOT_ITEM_SELF, true }, { _G.LOOT_ITEM_PUSHED_SELF, true },
        { _G.LOOT_ITEM, false },
    }
end

-- 解析一条拾取消息。返回 获得者（自己时为 selfName）、物品链接；不是物品拾取返回 nil。
function LootLog.ParseLootMessage(text, selfName, formats)
    if type(text) ~= "string" then return nil end
    for _, f in ipairs(formats or LootFormats()) do
        local fmt, isSelf = f[1], f[2]
        if type(fmt) == "string" then
            local a, b = Util.MatchFormat(text, fmt)
            if a then
                local who, link
                if isSelf then who, link = selfName, a else who, link = a, b end
                if link and ns.Items.LinkID(link) then
                    return Util.NormName(who), link
                end
            end
        end
    end
    return nil
end

-- 品质是否需要记录（白色包含灰色）
function LootLog.QualityRecorded(q, filters)
    q = tonumber(q)
    if not q then return false end
    if q == 0 then q = 1 end
    return filters[q] and true or false
end

-- 自动扣分只对勾选了"仅紫 / 仅蓝 / 仅绿"的品质生效
function LootLog.DeductQuality(q, opts)
    q = tonumber(q)
    return (q == 4 and opts.purpleMode) or (q == 3 and opts.blueMode) or (q == 2 and opts.greenMode) or false
end

-- 自动扣分规则。
-- 输入：出分 number、是否已整体完成 fullyDone、是否有许愿 hasWish、物品是否命中许愿 matches
-- 输出：{ deduct = 扣分, complete = 是否标记该物品完成, msg = 文案模板（%s 名字、%d 剩余分数）}；不处理时返回 nil
function LootLog.DeductRule(number, fullyDone, hasWish, matches)
    if fullyDone then
        return { deduct = number, complete = false, msg = "%s 扣 " .. number .. " 分，还剩 %d 分" }
    end
    if not hasWish then return nil end
    if number == 0 then
        if matches then return { deduct = 0, complete = true, msg = "%s 拿到了许愿的装备，还剩 %d 分" } end
        return { deduct = 0, complete = false, msg = "%s 出 0 分，不扣分，还剩 %d 分" }
    elseif number <= 4 then
        return { deduct = number, complete = false, msg = "%s 扣 " .. number .. " 分，还剩 %d 分" }
    elseif number == 5 then
        if matches then return { deduct = 0, complete = true, msg = "%s 拿到了许愿的装备（出 5 分，不扣分），还剩 %d 分" } end
        return { deduct = 5, complete = false, msg = "%s 出了 5 分但这件不是许愿的装备，扣 5 分，还剩 %d 分" }
    end
    local k = number - 5
    return { deduct = k, complete = matches, msg = "%s 拿到了许愿的装备，另扣 " .. k .. " 分，还剩 %d 分" }
end

------------------------------------------------------------------------
-- 数据
------------------------------------------------------------------------

local function NextUid()
    local main = ns.DB.main
    main.lootSeq = (tonumber(main.lootSeq) or 0) + 1
    return main.lootSeq
end

function LootLog:All() return Store() end

function LootLog:Find(uid)
    for i, e in ipairs(Store()) do if e.uid == uid then return e, i end end
end

-- 显示用：未移除的记录，按时间从新到旧
function LootLog:Entries()
    local out = {}
    for _, e in ipairs(Store()) do if not e.removed then out[#out + 1] = e end end
    table.sort(out, function(a, b)
        if (a.ts or 0) ~= (b.ts or 0) then return (a.ts or 0) > (b.ts or 0) end
        return (a.uid or 0) > (b.uid or 0)
    end)
    return out
end

function LootLog.EncodeSold(sold)
    if not sold then return "" end
    if sold.manual then return "!m" end
    if sold.none then return "!n" end
    return (sold.winner or "") .. ":" .. (sold.roll and ("r" .. sold.roll) or tostring(sold.score or 0))
end

local function RowFields(e)
    return e.uid, e.id, e.player or "", tonumber(e.points) or 0, e.wish and 1 or 0, tonumber(e.ts) or 0,
        LootLog.EncodeSold(e.sold)
end

-- 拍卖结果：{ winner=, score= } 出分胜出 / { winner=, roll= } Roll 胜出 / { none = true } 流拍 / { manual = true } 手动标记已拍
local function DecodeSold(s)
    if type(s) ~= "string" or s == "" then return nil end
    if s == "!m" then return { manual = true } end
    if s == "!n" then return { none = true } end
    local winner, v = s:match("^(.*):(r?%-?%d+)$")
    if not winner or winner == "" then return nil end
    if v:sub(1, 1) == "r" then return { winner = winner, roll = tonumber(v:sub(2)) } end
    return { winner = winner, score = tonumber(v) }
end
LootLog.DecodeSold = DecodeSold

local function IsLeader() return ns.Wish:IsLeader() end

function LootLog:SendEntry(e)
    if IsLeader() then
        ns.WishSync:Bump()
        ns.Comm:Send("L", 0, RowFields(e))
    end
end

function LootLog:SendFull()
    if not IsLeader() or ns.WishSync:Recovering() then return end
    LootLog.batch = (LootLog.batch or 0) % 9999 + 1
    local b = LootLog.batch
    local rows = {}
    for _, e in ipairs(Store()) do if not e.removed then rows[#rows + 1] = e end end
    ns.Comm:Send("LBEG", ns.Wish:Term(), b, #rows, ns.Wish:Rev())
    for _, e in ipairs(rows) do ns.Comm:Send("L", b, RowFields(e)) end
    ns.Comm:Send("LEND", b)
end

-- 新增一条记录（团长端或无团长时本地）
function LootLog:Add(id, player, points, wish)
    local e = { uid = NextUid(), id = id, player = player, points = points or 0, wish = wish and true or false, ts = time() }
    local s = Store()
    s[#s + 1] = e
    self:SendEntry(e)
    Changed()
    return e
end

function LootLog:Remove(uid)
    local e = self:Find(uid)
    if not e then return false end
    e.removed = true
    if IsLeader() then
        ns.WishSync:Bump()
        ns.Comm:Send("LDEL", uid)
    end
    Changed()
    return true
end

-- 写入拍卖结果（拍卖结算时调用）
function LootLog:SetSold(uid, sold)
    local e = self:Find(uid)
    if not e then return false end
    e.sold = sold
    self:SendEntry(e)
    Changed()
    return true
end

function LootLog:Clear()
    local s = Store()
    for i = #s, 1, -1 do s[i] = nil end
    Changed()
    if IsLeader() then self:SendFull() end
end

-- 统计：件数、已拍、待拍
function LootLog:Counts()
    local total, sold = 0, 0
    for _, e in ipairs(Store()) do
        if not e.removed then
            total = total + 1
            if e.sold then sold = sold + 1 end
        end
    end
    return total, sold, total - sold
end

------------------------------------------------------------------------
-- 处理一次拾取
------------------------------------------------------------------------

local recent = {}      -- [获得者#物品编号] = 时间

local function IsDuplicate(player, id)
    local now = GetTime()
    for k, t in pairs(recent) do if now - t > LootLog.DUP_WINDOW then recent[k] = nil end end
    local key = player .. "#" .. id
    if recent[key] then return true end
    recent[key] = now
    return false
end

local function Say(text) ns.Chat:Send(text, "RAID") end

-- 许愿相关的处理（只在许愿团长端执行）。返回扣除的分数、是否许愿物品。
local function ApplyWish(player, id, quality)
    local rec = M():Get(player)
    if not rec then return 0, false end
    local WM = ns.WishModel
    local ref = { id = id }
    local wanted = WM.WantsItem(rec, ref)           -- 拾取前是否许愿了这件
    local points, changed = 0, false

    -- 自动扣分
    local bid = ns.WishChat.bids[player]
    if O().autoDeduct and bid and (GetTime() - bid.time) <= LootLog.BID_WINDOW and LootLog.DeductQuality(quality, O()) then
        local rule = LootLog.DeductRule(bid.value, WM.IsFullyDone(rec), WM.HasWish(rec), wanted)
        if rule then
            if rule.complete then M():MarkItemDone(player, ref) end
            if rule.deduct ~= 0 then M():AddDkp(player, -rule.deduct) end
            points = rule.deduct
            changed = true
            Say(rule.msg:format(player, tonumber(rec.dkp) or 0))
        end
        ns.WishChat.bids[player] = nil
    end

    -- 许愿物品：无论是否出分都标记完成
    if wanted and M():MarkItemDone(player, ref) then
        changed = true
        if O().autoAnnounce then
            Say(player .. " 拿到了许愿的装备，还剩 " .. tostring(rec.dkp) .. " 分")
        end
    end
    if changed then ns.WishSync:SendRow(player) end
    return points, wanted
end

-- 品质未知时先等物品信息到达再决定是否记录
local function WithQuality(id, link, fn)
    local q = ns.Items.LinkQuality(link or "")
    if q then return fn(q) end
    local info = ns.Items.GetCached(id)
    if info and info.quality then return fn(info.quality) end
    ns.Items.Get(id, function(i) fn(i and i.quality or nil) end)
end

-- 处理一次掉落：player 已规范化，id 物品编号，link 可为 nil
function LootLog:Process(player, id, link)
    if not player or player == "" or not id then return end
    if IsDuplicate(player, id) then return end
    WithQuality(id, link, function(q)
        local points, wish = 0, false
        if IsLeader() then points, wish = ApplyWish(player, id, q) end
        if LootLog.QualityRecorded(q, O().qualityFilters) then
            self:Add(id, player, points, wish)
        end
        ns.Events:Fire("RW_LOOT_SEEN", id, link, player, q)
    end)
end

------------------------------------------------------------------------
-- 事件
------------------------------------------------------------------------

local function OnLootMessage(text)
    if ns.Compat.AnySecret(text) then return end
    local player, link = LootLog.ParseLootMessage(text, ns.Roster:Self())
    if not player then return end
    local id = ns.Items.LinkID(link)
    if IsLeader() or not ns.Wish:LeaderName() then
        LootLog:Process(player, id, link)
    else
        -- 只上报自己拾取的物品：获得者自己一定看得到这条消息，避免全团每人都报一次
        if player == ns.Roster:Self() then ns.Comm:Send("LUP", id, player) end
        ns.Events:Fire("RW_LOOT_SEEN", id, link, player, ns.Items.LinkQuality(link))
    end
end

------------------------------------------------------------------------
-- 同步：接收
------------------------------------------------------------------------

local receiver

local function FromRow(uid, id, player, points, wish, ts, sold)
    return { uid = tonumber(uid), id = tonumber(id), player = player, points = tonumber(points) or 0,
        wish = wish == "1", ts = tonumber(ts) or 0, sold = DecodeSold(sold) }
end

local function FromLeader(sender) return sender == ns.Wish:LeaderName() and not IsLeader() end

local function OnL(sender, batch, ...)
    if not FromLeader(sender) then return end
    local e = FromRow(...)
    if not e.uid or not e.id then return end
    if tostring(batch) == "0" then
        local cur, idx = LootLog:Find(e.uid)
        local s = Store()
        if cur then s[idx] = e else s[#s + 1] = e end
        receiver:Override(tostring(e.uid), e)
        Changed()
        return
    end
    receiver:Row(batch, tostring(e.uid), e)
end

local function OnLBeg(sender, _, batch, count, rev)
    if not FromLeader(sender) then return end
    -- 比自己手里的旧（团长用旧存档重登）：不接收，由 WishSync 提醒团长
    if tonumber(rev) and tonumber(rev) < ns.Wish:Rev() then return end
    receiver:Begin(batch, count, GetTime())
end

local function OnLEnd(sender, batch)
    if not FromLeader(sender) then return end
    local rows = receiver:End(batch)
    if not rows then return end
    local list = {}
    for _, e in pairs(rows) do list[#list + 1] = e end
    table.sort(list, function(a, b) return a.uid < b.uid end)
    local s = Store()
    for i = #s, 1, -1 do s[i] = nil end
    for i, e in ipairs(list) do s[i] = e end
    Changed()
end

local function OnLDel(sender, uid)
    if not FromLeader(sender) then return end
    local e = LootLog:Find(tonumber(uid))
    if e then
        e.removed = true
        Changed()
    end
end

local function OnLUp(sender, id, player)
    if not IsLeader() then return end
    id = tonumber(id)
    if not id or not ns.Roster:Has(sender) then return end
    LootLog:Process(Util.NormName(player), id, nil)
end

local function OnReq(_, what)
    if IsLeader() and type(what) == "string" and what:find("L") then
        if LootLog.pending then return end
        LootLog.pending = true
        ns.After(1.5, function()
            LootLog.pending = false
            LootLog:SendFull()
        end)
    end
end

ns.Events:On("RW_LOADED", function()
    receiver = ns.WishSync.Receiver.New()
    local C = ns.Comm
    C:On("L", OnL)
    C:On("LBEG", OnLBeg)
    C:On("LEND", OnLEnd)
    C:On("LDEL", OnLDel)
    C:On("LUP", OnLUp)
    C:On("REQ", OnReq)
end)

ns.Events:On("CHAT_MSG_LOOT", OnLootMessage)
ns.Events:On("RW_BECAME_LEADER", function() LootLog:SendFull() end)
-- 清空许愿表时一并清空掉落列表
ns.Events:On("RW_CLEAR_ALL", function() LootLog:Clear() end)
