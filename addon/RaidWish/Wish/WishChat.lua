-- Wish/WishChat.lua：聊天接入、通报、许愿业务动作，以及统一的聊天发送 ns.Chat
-- 通报文案与规则见 docs/需求说明.md。
local ADDON, ns = ...

------------------------------------------------------------------------
-- ns.Chat：聊天发送
--   · 锁定期入队，结束后补发；补发时丢弃过期消息（ttl）
--   · 团队通知频道需要团长或助理权限，无权限时降级到团队频道
--   · 超过 255 字节自动拆成多条，不切断物品链接和中文字符
--   · 换行符换成空格（正式服的聊天消息不能带换行）
------------------------------------------------------------------------

local Chat = { MAX = 255, DEFAULT_TTL = 60 }
ns.Chat = Chat

local queue = {}
local flushTicker = nil

-- 把文本拆成不超过 max 字节的若干段（纯函数）。
-- 物品链接整体作为一个单位；尽量在 "、" "，" "," 空格之后断开。
function Chat.SplitText(text, max)
    max = max or Chat.MAX
    if #text <= max then return { text } end
    -- 切成原子：物品链接整体一个，其余每个 UTF-8 字符一个
    local atoms = {}
    local links = ns.Items.ParseLinks(text)
    local li, pos, len = 1, 1, #text
    while pos <= len do
        local l = links[li]
        if l and l.s == pos then
            atoms[#atoms + 1] = text:sub(l.s, l.e)
            pos = l.e + 1
            li = li + 1
        else
            local b = text:byte(pos)
            local n = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
            atoms[#atoms + 1] = text:sub(pos, pos + n - 1)
            pos = pos + n
        end
    end
    local SEP = { ["、"] = true, ["，"] = true, [","] = true, [" "] = true }
    local out, cur, curLen, lastSep = {}, {}, 0, nil
    local function flush(upto)
        upto = upto or #cur
        local piece = table.concat(cur, "", 1, upto)
        piece = piece:gsub("^%s+", ""):gsub("%s+$", "")
        if piece ~= "" then out[#out + 1] = piece end
        local rest = {}
        for i = upto + 1, #cur do rest[#rest + 1] = cur[i] end
        cur, curLen, lastSep = rest, 0, nil
        for i, a in ipairs(cur) do
            curLen = curLen + #a
            if SEP[a] then lastSep = i end
        end
    end
    for _, a in ipairs(atoms) do
        if curLen + #a > max and #cur > 0 then
            -- 断点在最后一个分隔符之后（如果它不太靠前），否则直接在这里断
            if lastSep and lastSep > #cur / 2 then flush(lastSep) else flush() end
        end
        cur[#cur + 1] = a
        curLen = curLen + #a
        if SEP[a] then lastSep = #cur end
    end
    flush()
    return out
end

local function Now() return GetTime() end

-- 插件自己最近发出的聊天（文字 → 发出时间）。自己的公告里带了物品链接时，
-- 不应再触发"★物品★共N人许愿"之类的自动通报
local sentRecently = {}
local function RememberSent(text)
    local now = Now()
    for k, t in pairs(sentRecently) do if now - t > 30 then sentRecently[k] = nil end end
    sentRecently[text] = now
end

function Chat.WasMine(_, text)
    local t = sentRecently[text]
    return t ~= nil and Now() - t <= 30
end

-- 相邻两条聊天至少隔 Chat.INTERVAL 秒：一口气连发多行（宣言、播报）时，服务器可能把顺序打乱
Chat.INTERVAL = 0.3
local lastSent = -math.huge

local function Flush()
    while queue[1] do
        if ns.Compat.InChatLockdown() then return end
        if Now() - lastSent < Chat.INTERVAL then return end
        local item = table.remove(queue, 1)
        if Now() <= item.expires then
            RememberSent(item.text)
            lastSent = Now()
            local ok, err = ns.Compat.SendChat(item.text, item.channel, item.target)
            if not ok then ns.Log(ns.LogLevel.WARN, "聊天发送失败：" .. tostring(err)) end
        end
    end
    if flushTicker then
        flushTicker:Cancel()
        flushTicker = nil
    end
end

-- 发送聊天。channel 默认 RAID；opts.ttl 为锁定期排队的最长保留时间（秒）；opts.target 用于 WHISPER。
-- 返回是否已发出或已入队。
function Chat.Send(_, text, channel, opts)
    opts = opts or {}
    channel = channel or "RAID"
    if type(text) ~= "string" or text == "" then return false end
    if channel == "RAID_WARNING" and not ns.Roster:SelfIsOfficer() then channel = "RAID" end
    if (channel == "RAID" or channel == "RAID_WARNING") and not IsInRaid() then return false end
    text = text:gsub("[\r\n]+", " ")
    local expires = Now() + (opts.ttl or Chat.DEFAULT_TTL)
    for _, piece in ipairs(Chat.SplitText(text, Chat.MAX)) do
        queue[#queue + 1] = { text = piece, channel = channel, target = opts.target, expires = expires }
    end
    Flush()
    if queue[1] and not flushTicker then
        flushTicker = ns.Ticker(0.1, Flush)     -- 还有没发完的（间隔未到，或聊天锁定中）：每 0.1 秒再试
    end
    return true
end

-- 多行文本逐行发送（开团公告、宣言）。prefix 只加在第一行前面。
function Chat.SendLines(_, text, channel, prefix)
    local first = true
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        line = ns.Util.Trim(line)
        if line ~= "" then
            Chat:Send((first and prefix or "") .. line, channel)
            first = false
        end
    end
end

------------------------------------------------------------------------
-- WishChat
------------------------------------------------------------------------

local WC = {}
ns.WishChat = WC

local Util = ns.Util

-- 团员在团队频道发的 0~9 数字，自动扣分用
WC.bids = {}

local function Opts() return ns.DB.options end
local function M() return ns.Wish.model end
local function Roster() return (ns.Roster:Get()) end

local function LinkFor(id)
    local info = ns.Items.GetCached(id)
    return info and info.link or nil
end

function WC.WishText(rec)
    return ns.WishModel.WishText(rec, LinkFor)
end

local function Say(text, channel, opts) return Chat:Send(text, channel or "RAID", opts) end

local function RequireLeader()
    if ns.Wish:IsLeader() then return true end
    ns.Print("只有许愿团长可以这样操作")
    return false
end

------------------------------------------------------------------------
-- 查询与加减分
------------------------------------------------------------------------

-- 通报某人的许愿或分数变化。delta 不为 0 时通报加减分。
function WC:Query(name, delta)
    local rec = M():Get(name)
    if not rec then return false end
    local dkp = tostring(tonumber(rec.dkp) or 0)
    delta = tonumber(delta)
    if delta and delta ~= 0 then
        if delta > 0 then
            return Say(name .. " 加 " .. delta .. " 分，现有 " .. dkp .. " 分")
        end
        return Say(name .. " 扣 " .. (0 - delta) .. " 分，现有 " .. dkp .. " 分")
    end
    local text = ns.WishModel.HasWish(rec) and WC.WishText(rec) or "（未许愿）"
    return Say(name .. " 的许愿：" .. text .. "，现有 " .. dkp .. " 分")
end

function WC:AddDkp(name, n)
    if not RequireLeader() then return false end
    n = tonumber(n)
    if not n or not M():AddDkp(name, n) then return false end
    WC:Query(name, n)
    ns.WishSync:SendRow(name)
    return true
end

function WC:MinusDkp(name, n)
    if not RequireLeader() then return false end
    n = tonumber(n)
    if not n or not M():AddDkp(name, -n) then return false end
    WC:Query(name, -n)
    ns.WishSync:SendRow(name)
    return true
end

------------------------------------------------------------------------
-- 完成标记
------------------------------------------------------------------------

function WC:MarkDone(name)
    if not RequireLeader() then return false end
    local rec = M():Get(name)
    if not rec then
        ns.Print("找不到 " .. name .. " 的许愿记录")
        return false
    end
    if ns.WishModel.IsFullyDone(rec) then
        ns.Print(name .. " 的许愿已经标记为完成")
        return false
    end
    if not M():MarkAllDone(name) then
        ns.Print(name .. " 还没有许愿")
        return false
    end
    ns.WishSync:SendRow(name)
    ns.Print("已将 " .. name .. " 的许愿标记为已完成")
    Say(name .. " 的许愿标记为完成（手动），现有 " .. tostring(rec.dkp) .. " 分")
    return true
end

function WC:UndoDone(name)
    if not RequireLeader() then return false end
    if not M():Get(name) then
        ns.Print("找不到 " .. name .. " 的许愿记录")
        return false
    end
    if not M():UndoDone(name) then
        ns.Print(name .. " 没有可以撤销的完成标记")
        return false
    end
    ns.WishSync:SendRow(name)
    ns.Print("已撤销 " .. name .. " 的已完成标记")
    Say("已撤销 " .. name .. " 的完成标记，许愿恢复为：" .. WC.WishText(M():Get(name)))
    return true
end

function WC:ToggleDone(name)
    if ns.WishModel.IsFullyDone(M():Get(name)) then return WC:UndoDone(name) end
    return WC:MarkDone(name)
end

-- 清除此人许愿（新界面的行右键菜单项）
function WC:ClearWish(name)
    if not RequireLeader() then return false end
    if not M():ClearWish(name) then return false end
    ns.WishSync:SendRow(name)
    return true
end

------------------------------------------------------------------------
-- 开始 / 停止 / 放弃
------------------------------------------------------------------------

-- skipRestore：已经问过团员（或用户选择不恢复）时为真
function WC:Start(skipRestore)
    if not IsInRaid() then
        ns.Print("|cffff0000你不在一个团队中，无法开始|r")
        return false
    end
    if not ns.Roster:SelfIsOfficer() then
        ns.Print("只有团长或助理可以开始许愿")
        return false
    end
    if IsEncounterInProgress and IsEncounterInProgress() then
        ns.Print("|cffffff00战斗中可能无法录入许愿|r")
    end
    if not skipRestore and ns.Restore then
        local ln = ns.Wish:LeaderName()
        if ln == nil or (ln ~= ns.Roster:Self() and not ns.Roster:Has(ln)) then
            -- 这个团里还没人开过许愿（记着的许愿团长也不在团里）：有旧数据时问"继续"还是"清空"，没有就直接开始
            WC:AskAboutOldData()
            return true
        end
        -- 同一个团里继续（停止后再开始、换人接手、重载或崩溃后重登）：默认继续。
        -- 本地是空的（例如崩溃丢了数据）就悄悄从团员那里拿回来，避免把空表同步给全团
        if ns.Restore.WishedCount(M().store) == 0 then
            ns.Restore:FromMembers(function() WC:Start(true) end, { silent = true, noConfirm = true })
            return true
        end
    end
    Chat:SendLines(ns.DB:GetStartText(), "RAID")
    M():EnsureMembers(Roster(), Opts().defaultDkp)
    ns.WishSync:BecomeLeader()
    return true
end

-- 新团第一次开始许愿：本地或团员手里有许愿数据时，让团长选"继续上次的许愿"或"清空，重新开始"
function WC:AskAboutOldData()
    local R = ns.Restore
    local inRaid = function(name) return ns.Roster:Has(name) end
    local myN, _, myTs = R.Summary(M().store, inRaid)
    R:Survey(function(offers)
        local best, bestName
        for name, o in pairs(offers) do
            if o.n > 0 and (not best or o.ts > best.ts) then best, bestName = o, name end
        end
        if myN == 0 and not best then
            WC:Start(true)
            return
        end
        local lines = { "发现已有许愿数据：" }
        if myN > 0 then
            lines[#lines + 1] = ("· 你本地：%d 人许愿，最后更新于 %s"):format(myN, date("%m-%d %H:%M", myTs))
        end
        if best then
            lines[#lines + 1] = ("· 团员 %s：%d 人许愿（%d 人在本团），最后更新于 %s"):format(
                bestName, best.n, best.here, date("%m-%d %H:%M", best.ts))
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "上次没打完就选\"继续\"；新开一个团就选\"清空\"（全团的许愿和分数归零）。"
        ns.Widgets.Choice("OLD_DATA", table.concat(lines, "\n"), "继续上次的许愿", "清空，重新开始",
            function()
                -- 团员的比自己的新（例如自己崩溃过）：用团员的
                if best and (myN == 0 or best.ts > myTs) then
                    R:FromMembers(function() WC:Start(true) end, { silent = true, noConfirm = true })
                else
                    WC:Start(true)
                end
            end,
            function()
                M():ClearAll()
                ns.Events:Fire("RW_CLEAR_ALL")
                WC:Start(true)                 -- 新的任期：团员会接受这份空表，旧数据被替换
            end,
            { secondDanger = true })
    end)
end

function WC:Stop()
    if not RequireLeader() then return false end
    Say("许愿已截止，之后的许愿不再记录")
    ns.WishSync:SetActive(false)
    return true
end

-- 让出许愿团长。界面层负责先弹出确认框。
function WC:Relinquish()
    if not RequireLeader() then return false end
    ns.WishSync:Quit()
    Say("许愿团长已让出，团长或助理点\"开始许愿\"即可接手")
    return true
end

------------------------------------------------------------------------
-- 通报类
------------------------------------------------------------------------

function WC:AnnounceUnwished()
    local list = M():Unwished(Roster())
    if #list == 0 then
        return Say("全员都已许愿")
    end
    return Say("还没许愿的有：" .. table.concat(list, "、") .. "，请尽快许愿")
end

local SORT_TEXT = { name = "角色名", class = "职业", wish = "许愿", dkp = "分数" }
local broadcastTicker = nil

-- 按排序逐条播报全部许愿，每 0.5 秒一条。field / asc 与列表当前排序一致。
function WC:BroadcastAll(field, asc)
    if not IsInRaid() then
        ns.Print("需要在团队中才能播报许愿。")
        return false
    end
    if broadcastTicker then broadcastTicker:Cancel() end
    field = field or "name"
    local _, set = ns.Roster:Get()
    local rows = M():Sorted(field, asc ~= false, set)
    -- 正式服聊天不允许颜色码，标题用纯文字
    Say("开始播报许愿（按" .. (SORT_TEXT[field] or "角色名") .. ((asc == false) and "从高到低" or "从低到高") .. "）：")
    local i = 0
    broadcastTicker = ns.Ticker(0.5, function()
        while true do
            i = i + 1
            local row = rows[i]
            if not row then
                Say("许愿播报完毕。")
                broadcastTicker:Cancel()
                broadcastTicker = nil
                return
            end
            if ns.WishModel.HasWish(row.rec) then
                local cls = Util.CLASS_NAME_ZH[row.rec.class or ""] or tostring(row.rec.class or "")
                Say(("【许愿】%s（%s）：%s，%s 分"):format(row.name, cls, WC.WishText(row.rec), tostring(row.rec.dkp)))
                return
            end
        end
    end)
    return true
end

-- 发开团公告（多行逐行发送）
function WC:SendStartText()
    if not IsInRaid() then return false end
    Chat:SendLines(ns.DB:GetStartText(), "RAID")
    return true
end

-- 发团队宣言：团队通知频道，第一行加"【宣言】"
function WC:AnnounceDeclaration()
    if not IsInRaid() then return false end
    Chat:SendLines(ns.DB:GetDeclaration(), "RAID_WARNING", "【宣言】")
    return true
end

-- 导出许愿表为可复制的文本：在团时只导出在团成员，否则导出全部。
-- 每行格式："名字（职业）：许愿，剩余 N 分"
function WC:ExportText()
    local set = nil
    if IsInRaid() then set = select(2, ns.Roster:Get()) end
    local rows = M():Sorted("name", true, set)
    if #rows == 0 then rows = M():Sorted("name", true) end
    local lines = {}
    for _, row in ipairs(rows) do
        local rec = row.rec
        local cls = Util.CLASS_NAME_ZH[rec.class or ""] or tostring(rec.class or "")
        -- 导出用纯文本 [物品名]，不带链接代码；同步来的物品只有编号，名字从物品缓存取
        local wish = ns.WishModel.HasWish(rec) and ns.WishModel.WishText(rec, function(id)
            local info = ns.Items.GetCached(id)
            return info and ("[" .. info.name .. "]") or ("[物品" .. id .. "]")
        end) or "（未许愿）"
        lines[#lines + 1] = row.name .. "（" .. cls .. "）：" .. wish .. "，剩余 " .. tostring(rec.dkp) .. " 分"
    end
    return table.concat(lines, "\n")
end

-- 设置全团初始分数
function WC:InitScores(dkp)
    if not RequireLeader() then return false end
    dkp = tonumber(dkp)
    if not dkp then return false end
    Opts().defaultDkp = dkp
    M():InitScores(Roster(), dkp)
    Say("全团分数已重置为每人 " .. dkp .. " 分")
    ns.WishSync:SendFull()
    return true
end

-- 清空许愿表
-- 界面上的"清空许愿表"：先确认。许愿还在进行中时要先停止许愿（许愿团长在确认框里一起停止；其他人提示去找许愿团长）
function WC:ConfirmClear()
    local what = "会清空所有人的许愿和分数、掉落记录、待拍列表和拍卖结果，并同步给全团。"
    if ns.Wish:InProgress() then
        if not ns.Wish:IsLeader() then
            ns.Print("许愿还在进行中，请许愿团长 " .. tostring(ns.Wish:LeaderName()) .. " 先点\"停止许愿\"再清空。")
            return false
        end
        ns.Widgets.Confirm("RESET", "许愿还在进行中，清空前要先停止许愿。\n" .. what .. "\n\n停止许愿并清空吗？", function()
            WC:Stop()
            WC:ClearAll()
        end, { danger = true, okText = "停止许愿并清空" })
        return true
    end
    ns.Widgets.Confirm("RESET", "确定要清空吗？\n" .. what, function() WC:ClearAll() end, { danger = true, okText = "清空" })
    return true
end

function WC:ClearAll()
    M():ClearAll()
    ns.Events:Fire("RW_CLEAR_ALL")
    if ns.Wish:IsLeader() then ns.WishSync:SendFull() end
    return true
end

------------------------------------------------------------------------
-- 聊天接入
------------------------------------------------------------------------

-- 团长端录入许愿
local function HandleWish(text, sender)
    local r = ns.WishParser.Parse(text, { xyOnly = Opts().xyOnly })
    if r.kind ~= "wish" and r.kind ~= "proxy" then return end
    local target = sender
    if r.kind == "proxy" then target = ns.Roster:Resolve(r.target) end
    local _, set = ns.Roster:Get()
    local member = target and set[target]
    if not member then return end                        -- 只给在团成员录入
    M():Ensure(target, member.class, Opts().defaultDkp)
    local items = ns.WishParser.Limit(r.items, Opts().maxWishItems)
    r.items = items
    if not M():SetWish(target, items, r.raw) then return end
    ns.WishSync:SendRow(target)
    ns.Events:Fire("RW_WISH_RECORDED", target)
    -- 重复许愿警报：同一物品 2 人及以上（只算在团成员）
    if Opts().autoAnnounce then
        for _, it in ipairs(r.items) do
            if not it.floor then
                local count = M():CountWishers({ id = it.id, name = it.name }, set)
                if count >= 2 then
                    Say("注意：" .. Util.CleanString(it.name) .. " 已有 " .. count .. " 人许愿")
                end
            end
        end
    end
end

-- 团队频道出现物品链接时自动通报许愿情况。
-- 不限"许愿阶段"，停止许愿后照常播报。
-- 只由许愿团长通报；团员端不发"我已许愿"，避免一条链接引出一串通报
local function AnnounceFor(ref, clean)
    if clean == "" or not ns.Wish:IsLeader() then return end
    local _, set = ns.Roster:Get()
    local players = M():WishPlayers(ref, set)
    if #players == 0 then return end
    local parts = {}
    for _, p in ipairs(players) do parts[#parts + 1] = p.name .. "（" .. p.dkp .. "分）" end
    Say("「" .. clean .. "」有 " .. #players .. " 人许愿：" .. table.concat(parts, "、"))
end

function WC.CheckItemAndAnnounce(msg)
    if not Opts().autoAnnounce then return end
    if msg:find("【许愿】", 1, true) then return end
    local links = ns.Items.ParseLinks(msg)
    if #links > 0 then
        for _, l in ipairs(links) do
            AnnounceFor({ id = l.id, name = l.name }, Util.CleanString(l.name))
        end
    else
        AnnounceFor({ name = msg }, Util.CleanString(msg))
    end
end

local function OnRaidChat(text, sender, isWarning)
    local name = Util.NormName(sender)
    -- 插件自己发的公告（开拍、赢得、播报等）不再当作许愿或查询处理
    if name == ns.Roster:Self() and Chat:WasMine(text) then return end
    -- 出分数字
    if not isWarning then
        local number = tonumber(text)
        if number and number >= 0 and number <= 9 and text:match("^%s*%d%s*$") then
            WC.bids[name] = { value = number, time = GetTime() }
        end
        if ns.Wish:IsLeader() and ns.Wish:InProgress() then HandleWish(text, name) end
    end
    WC.CheckItemAndAnnounce(text)
end

local function RaidHandler(isWarning)
    return function(text, sender)
        -- 保密值检查必须是第一步
        if ns.Compat.AnySecret(text, sender) then return end
        if type(text) ~= "string" or type(sender) ~= "string" then return end
        OnRaidChat(text, sender, isWarning)
    end
end

ns.Events:On("CHAT_MSG_RAID", RaidHandler(false))
ns.Events:On("CHAT_MSG_RAID_LEADER", RaidHandler(false))
ns.Events:On("CHAT_MSG_RAID_WARNING", RaidHandler(true))

-- 密语 cxxy 查询
ns.Events:On("CHAT_MSG_WHISPER", function(text, sender)
    if ns.Compat.AnySecret(text, sender) then return end
    if type(text) ~= "string" or type(sender) ~= "string" then return end
    if Util.Trim(text) == "cxxy" then WC:Query(Util.NormName(sender)) end
end)

------------------------------------------------------------------------
-- 录入反馈与退团清空
------------------------------------------------------------------------

ns.Events:On("RW_MY_WISH_RECORDED", function(name)
    local rec = M():Get(name)
    if ns.WishModel.HasWish(rec) then
        ns.Print("你的许愿已记录：" .. WC.WishText(rec))
    end
end)

-- 退团时按设置清空：ask 弹窗询问，clear 直接清空。
-- 只在离开团队时处理；GROUP_LEFT 离开五人小队也会触发，所以记一下之前是否在团队里。
local wasInRaid = false
-- 只在这里置真、只在 GROUP_LEFT 里清零：离队时 GROUP_ROSTER_UPDATE 可能先于 GROUP_LEFT 到达
local function NoteRaid() if IsInRaid() then wasInRaid = true end end
ns.Events:On("RW_ROSTER_UPDATE", NoteRaid)
ns.Events:On("RW_LOGIN", NoteRaid)

ns.Events:On("GROUP_LEFT", function()
    local leftRaid = wasInRaid
    wasInRaid = false
    if not leftRaid or next(M().store) == nil then return end
    if Opts().clearOnLeaveMode == "clear" then
        WC:ClearAll()
    else
        ns.Widgets.Confirm("CONFIRM_RESET", "你已离开团队。要清空许愿表吗？\n（许愿、分数、掉落记录、待拍列表和拍卖结果都会清空）", function() WC:ClearAll() end,
            { danger = true, okText = "清空" })
    end
end)
