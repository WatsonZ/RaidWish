-- UI/AuctionPopup.lua：拍卖弹窗、"待拍"按钮、掉落页的拍卖部分
--
--   时机        团员                                   团长、助理
--   没有拍卖    不显示                                 "待拍 N"小按钮，点开列出未拍物品，点一件即开拍
--   出分阶段    物品、进度条、当前最高、五个出分按钮、"不要这件"   同左，下面多一排：数秒、直接 Roll、取消拍卖
--   Roll 阶段   需要 Roll 的人看到 Roll 按钮；其他人只读        同左，另有数秒、取消拍卖
--   结算        显示结果 3 秒后自动关闭                     同左
--
-- 标题栏右侧的按钮把弹窗收成一行小条（图标、名字、倒计时），再点展开。
-- "不要这件"收起弹窗并记 P 标记：这件装备下次开拍时默认收起（见 AuctionComm 的 P 标记）。
local ADDON, ns = ...

local W = ns.Widgets
local Popup = { collapsed = false }
ns.AuctionPopup = Popup

local WIDTH = 320
local popup, bar, pill
local LT = ns.LootTab
local now_          -- 掉落页"当前拍卖"区的控件（LT.OnCreate 里赋值）

local function A() return ns.Auction end
local function M() return ns.Auction.model end
local function Me() return ns.Roster:Self() end

local function ClassOf(name)
    local _, set = ns.Roster:Get()
    if set[name] then return set[name].class end
    local rec = ns.Wish.model and ns.Wish.model:Get(name)
    return rec and rec.class
end

local function ColorName(name)
    if not name then return "" end
    return ns.Util.ClassColoredName(name, ClassOf(name))
end

local function MyWish(id)
    local rec = ns.Wish.model and ns.Wish.model:Get(Me())
    return ns.WishModel.WantsItem(rec, { id = id })
end

-- 状态文字（弹窗与掉落页共用）
function Popup.StatusLine(now)
    local m = M()
    local remaining = m:Remaining(now)
    local secs = math.floor(remaining + 0.5)
    if m.state == "roll" then
        local max, who = m:HighestRoll()
        local lead = (#who > 0) and (ColorName(who[1]) .. " " .. max) or "暂无"
        return "当前最高 " .. lead .. " · 剩余 " .. secs .. " 秒"
    elseif m.state == "settle" then
        local r = m.result or {}
        if not r.winner then return "流拍" end
        return ColorName(r.winner) .. " 赢得 · " .. (r.score and (r.score .. " 分") or ("Roll " .. tostring(r.roll)))
    elseif m.state == "wait" then
        return "出分结束，等待结算"
    end
    local max, who = m:HighestBid()
    local lead = (#who == 1) and (ColorName(who[1]) .. " " .. max .. " 分")
        or ((#who > 1) and (#who .. " 人出 " .. max .. " 分") or "暂无")
    return "当前最高 " .. lead .. " · 剩余 " .. secs .. " 秒"
end

function Popup.PhaseText()
    local m = M()
    if m.state == "roll" then
        if m.rollers == "all" then return "全团 Roll" end
        local names = {}
        for n in pairs(m.rollers or {}) do names[#names + 1] = ColorName(n) end
        table.sort(names)
        return "同分 Roll · " .. table.concat(names, "、")
    elseif m.state == "settle" then
        return "结算"
    end
    return "出分中 · 已有 " .. m:BidCount() .. " 人出分"
end

------------------------------------------------------------------------
-- 弹窗
------------------------------------------------------------------------

-- 出错提示临时顶替状态行，2 秒后恢复
local function ShowError(text)
    popup.err:SetText(text)
    popup.err:Show()
    popup.status:Hide()
    if popup.errTimer then popup.errTimer:Cancel() end
    popup.errTimer = ns.After(2, function()
        popup.err:Hide()
        popup.status:Show()
    end)
end

local function Create()
    popup = W.Panel({ name = "RaidWishAuctionPopup", width = WIDTH, height = 206, title = "拍卖",
        closeKind = "collapse", saveKey = "auction", strata = "HIGH",
        defaultPoint = { "CENTER", UIParent, "CENTER", 0, 200 },
        onClose = function() Popup:SetCollapsed(true) ns.Voice:Play("collapse") end })
    popup:SetScale(ns.DB.char.auctionScale or 1)
    popup:Hide()

    -- 布局（body 内纵向坐标）：
    --   0     物品图标 36 × 36；右侧上行物品名，下行"你许愿了"或阶段说明
    --   -48   倒计时进度条
    --   -62   状态行（当前最高、剩余时间；出错提示临时顶替这一行）
    --   -84   出分按钮一排 / Roll 按钮
    --   -120  团员："不要这件"；团长、助理：分隔线 + 主持按钮
    local body = CreateFrame("Frame", nil, popup)
    body:SetPoint("TOPLEFT", popup.head, "BOTTOMLEFT", 14, -12)
    body:SetPoint("TOPRIGHT", popup.head, "BOTTOMRIGHT", -14, -12)
    body:SetHeight(160)
    local inner = WIDTH - 28

    popup.item = W.ItemCell(body, 36, 15)
    popup.item:SetPoint("TOPLEFT", 0, 0)
    popup.item.name:ClearAllPoints()
    popup.item.name:SetPoint("TOPLEFT", popup.item.icon, "TOPRIGHT", 10, -2)
    popup.item.name:SetWidth(inner - 46)
    popup.item.name:SetJustifyH("LEFT")
    popup.meta = W.Text(body, "dim", 12)
    popup.meta:SetPoint("BOTTOMLEFT", popup.item.icon, "BOTTOMRIGHT", 10, 2)
    popup.meta:SetWidth(inner - 46)
    popup.meta:SetJustifyH("LEFT")

    popup.prog = W.Progress(body, 6)
    popup.prog:SetPoint("TOPLEFT", 0, -48)
    popup.prog:SetPoint("TOPRIGHT", 0, -48)
    popup.status = W.Text(body, "dim", 12)
    popup.status:SetPoint("TOPLEFT", 0, -62)
    popup.status:SetWidth(inner)
    popup.status:SetJustifyH("LEFT")
    popup.err = W.Text(body, "bad", 12)
    popup.err:SetPoint("TOPLEFT", 0, -62)
    popup.err:Hide()

    popup.bids = {}
    local gap = 6
    local bw = (inner - gap * 4) / 5
    for i, n in ipairs({ 1, 2, 3, 4, 9 }) do
        local b = W.Button(body, n .. " 分", "normal", bw, 28, function()
            local ok, err = A():BidButton(n)
            if not ok then ShowError(err) end
        end)
        b:SetPoint("TOPLEFT", (i - 1) * (bw + gap), -84)
        popup.bids[i] = b
    end
    popup.roll = W.Button(body, "Roll", "normal", inner, 28, function()
        local ok, err = A():RollButton()
        if not ok then ShowError(err) end
    end)
    popup.roll:SetPoint("TOPLEFT", 0, -84)
    popup.pass = W.Button(body, "不要这件", "ghost", inner, 26, function()
        if M().item then A():SetPMark(M().item, true) end
        Popup:SetCollapsed(true)
        ns.Voice:Play("collapse")
    end)
    popup.pass:SetPoint("TOPLEFT", 0, -122)

    -- 团长、助理的主持按钮
    popup.ctl = CreateFrame("Frame", nil, body)
    popup.ctl:SetPoint("TOPLEFT", 0, -122)
    popup.ctl:SetSize(inner, 36)
    local line = W.Divider(popup.ctl)
    line:SetPoint("TOPLEFT")
    line:SetPoint("TOPRIGHT")
    local cw = (inner - gap * 2) / 3
    popup.early = W.Button(popup.ctl, "数秒", "normal", cw, 26, function() A():Early() end)
    popup.early:SetPoint("TOPLEFT", 0, -10)
    popup.direct = W.Button(popup.ctl, "直接 Roll", "normal", cw, 26, function() A():DirectRoll() end)
    popup.direct:SetPoint("LEFT", popup.early, "RIGHT", gap, 0)
    popup.cancel = W.Button(popup.ctl, "取消拍卖", "ghost", cw, 26, function() A():Cancel() end)
    popup.cancel:SetPoint("LEFT", popup.direct, "RIGHT", gap, 0)
    W.Tooltip(popup.early, "数秒", "立即开始 3 秒倒计时")
    W.Tooltip(popup.direct, "直接 Roll", "跳过出分，对这件装备全团 Roll")

    -- 收起后的小条
    bar = CreateFrame("Button", "RaidWishAuctionBar", UIParent)
    bar:SetSize(220, 30)
    bar:SetFrameStrata("HIGH")
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function(self) self:StartMoving() end)
    bar:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, bx, by = self:GetPoint(1)
        ns.DB.char.frames.auctionBar = { point = p, relPoint = rp, x = bx, y = by }
    end)
    ns.Skin:Apply(bar, "panel")
    bar._saveKey = "auctionBar"
    bar._defaultPoint = { "CENTER", UIParent, "CENTER", 0, 240 }
    W.RestorePosition(bar)
    bar.item = W.ItemCell(bar, 20, 12)
    bar.item:SetPoint("LEFT", 8, 0)
    bar.item._row = bar
    bar.time = W.Text(bar, "accent", 12)
    bar.time:SetPoint("RIGHT", -10, 0)
    bar:SetScript("OnClick", function() Popup:SetCollapsed(false) end)
    W.Tooltip(bar, "拍卖", "点一下展开")
    bar:Hide()
end

function Popup:SetCollapsed(on)
    self.collapsed = on and true or false
    self:Refresh()
end

local function IsOfficer() return A():IsOfficer() end

function Popup:Refresh()
    if not popup then return end
    local m = M()
    -- 结算结果已经在团队通知、语音和掉落页里，弹窗不再单独展示结算，直接关掉
    if not m:Active() or m.state == "settle" then
        popup:Hide()
        bar:Hide()
        return
    end
    local now = GetTime()
    if self.collapsed then
        popup:Hide()
        bar:Show()
        bar.item:SetItem({ id = m.item })
        bar.time:SetText(math.floor(m:Remaining(now) + 0.5) .. " 秒")
        return
    end
    bar:Hide()
    popup:Show()
    popup.item:SetItem({ id = m.item })
    if MyWish(m.item) and m.state ~= "settle" then
        popup.meta:SetText("★ 你许愿了这件装备")
        W.SetRole(popup.meta, "star")
    else
        popup.meta:SetText(Popup.PhaseText())
        W.SetRole(popup.meta, "dim")
    end
    local remaining, total = m:Remaining(now)
    popup.prog:SetValue(total > 0 and remaining / total or 0)
    popup.status:SetText(Popup.StatusLine(now))

    local bidding = m.state == "bid" or m.state == "count"
    local rolling = m.state == "roll"
    for _, b in ipairs(popup.bids) do b:SetShown(bidding) end
    popup.roll:SetShown(rolling and m:InRoll(Me()))
    local officer = IsOfficer()
    popup.pass:SetShown(bidding and not officer)
    popup.ctl:SetShown(officer and (bidding or rolling))
    popup.direct:SetShown(bidding)
    local host = A():IsAuctioneer()
    popup.early:SetEnabledState(host)
    popup.direct:SetEnabledState(host)
    popup.cancel:SetEnabledState(host)
    -- 高度 = 标题 34 + 上边距 12 + 内容 + 下边距 14
    local content = 78                                          -- 物品、进度条、状态行
    if officer and (bidding or rolling) then content = 158      -- 出分 / Roll + 主持按钮
    elseif bidding then content = 148                           -- 出分 + 不要这件
    elseif popup.roll:IsShown() then content = 112 end          -- 只有 Roll 按钮
    popup:SetHeight(34 + 12 + content + 14)
end

-- 只更新倒计时、进度条和状态文字（拍卖进行中每秒 10 次，不重建其他内容）
function Popup:UpdateTimer()
    if not popup then return end
    local m = M()
    if not m:Active() then return end
    local now = GetTime()
    if self.collapsed then
        if bar:IsShown() then bar.time:SetText(math.floor(m:Remaining(now) + 0.5) .. " 秒") end
    elseif popup:IsShown() then
        local remaining, total = m:Remaining(now)
        popup.prog:SetValue(total > 0 and remaining / total or 0)
        popup.status:SetText(Popup.StatusLine(now))
    end
    if now_ and LT.nowArea and LT.nowArea:IsShown() then
        local phase = (m.state == "roll") and "Roll 中" or ((m.state == "settle") and "结算" or "出分中")
        now_.text:SetText(phase .. " · " .. Popup.StatusLine(now))
        local remaining, total = m:Remaining(now)
        now_.prog:SetValue(total > 0 and remaining / total or 0)
    end
end

------------------------------------------------------------------------
-- "待拍"按钮（团长、助理，没有拍卖时）
------------------------------------------------------------------------

local function CreatePill()
    pill = CreateFrame("Button", "RaidWishPendingButton", UIParent)
    pill:SetSize(118, 36)
    pill:SetFrameStrata("MEDIUM")
    pill:SetClampedToScreen(true)
    pill:SetMovable(true)
    pill:RegisterForDrag("LeftButton")
    pill:SetScript("OnDragStart", function(self) self:StartMoving() end)
    pill:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, px, py = self:GetPoint(1)
        ns.DB.char.frames.pending = { point = p, relPoint = rp, x = px, y = py }
    end)
    ns.Skin:Apply(pill, "panel")
    pill._saveKey = "pending"
    pill._defaultPoint = { "TOP", UIParent, "TOP", 0, -120 }
    W.RestorePosition(pill)
    local stripe = W.Box(pill, "accentbar")
    stripe:SetPoint("TOPLEFT", 1, -1)
    stripe:SetPoint("BOTTOMLEFT", 1, 1)
    stripe:SetWidth(3)
    local t = W.Text(pill, "title", 15)
    t:SetPoint("LEFT", 16, 0)
    t:SetText("待拍")
    local badge = W.Box(pill, "accentbar")
    badge:SetSize(24, 18)
    badge:SetPoint("LEFT", t, "RIGHT", 10, 0)
    pill.count = W.Text(badge, "onAccent", 12)
    pill.count:SetPoint("CENTER", 0, 0)
    local arrow = W.Glyph(pill, "down", 11, "dim")
    arrow:SetPoint("RIGHT", -14, -1)
    pill:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    pill:SetScript("OnClick", function(self)
        local list = A():Pending()
        W.Menu(self, function(root)
            if #list == 0 then
                root:Title("暂无待拍物品")
                return
            end
            root:Title("点一件开拍")
            for _, p in ipairs(list) do
                local info = ns.Items.GetCached(p.id)
                root:Button((info and info.name) or ("物品 " .. p.id), function() A():StartItem(p.id) end)
            end
            root:Divider()
            local dr = root:Button("直接 Roll")
            for _, p in ipairs(list) do
                local info = ns.Items.GetCached(p.id)
                dr:Button((info and info.name) or ("物品 " .. p.id), function() A():DirectRoll(p.id) end)
            end
        end)
    end)
    pill:Hide()
end

function Popup:RefreshPill()
    if not pill then return end
    local show = IsInRaid() and IsOfficer() and ns.DB.options.auction.showPendingButton and not M():Active()
    local n = show and #A():Pending() or 0
    if show and n > 0 then
        pill.count:SetText(tostring(n))
        pill.count:GetParent():SetWidth(math.max(20, pill.count:GetStringWidth() + 12))
        pill:Show()
    else
        pill:Hide()
    end
end

------------------------------------------------------------------------
-- 掉落与拍卖页
------------------------------------------------------------------------



-- 结果列：拍卖中 / 未拍（团长、助理是"拍卖"按钮，团员是"待拍"）/ 已拍 / 许愿物品直接归属
local baseResult = LT.ResultFor
LT.ResultFor = function(e)
    if e.sold then
        if e.sold.manual then return { kind = "text", text = "已拍", role = "dim" } end
        if e.sold.none then return { kind = "text", text = "流拍", role = "dim" } end
        return baseResult(e)
    end
    local m = M()
    if m:InProgress() and m.item == e.id then return { kind = "text", text = "拍卖中", role = "accent" } end
    if e.wish then return baseResult(e) end          -- 许愿物品直接归许愿者，未经拍卖
    if IsOfficer() then
        return { kind = "button", text = "拍卖", onClick = function() A():StartItem(e.id) end }
    end
    return { kind = "text", text = "待拍", role = "dim" }
end

LT.ExtraMenu = function(root, e)
    if not e.sold then root:Button("标记为已拍", function() A():MarkSold(e.id) end) end
end

LT.Counts = function(total, _, _)
    local sold = 0
    for _, e in ipairs(ns.LootLog:Entries()) do if e.sold or e.wish then sold = sold + 1 end end
    return total, sold, #A():Pending()
end

local now
LT.OnCreate = function(page)
    local area = LT.nowArea
    now = {}
    now_ = now
    now.item = W.ItemCell(area, 22, 13)
    now.item:SetPoint("TOPLEFT", 12, -10)
    now.text = W.Text(area, "dim", 12)
    now.text:SetPoint("LEFT", now.item, "RIGHT", 10, 0)
    now.cancel = W.Button(area, "取消", "ghost", 44, 22, function() A():Cancel() end)
    now.cancel:SetPoint("TOPRIGHT", -12, -10)
    now.direct = W.Button(area, "直接 Roll", "normal", 70, 22, function() A():DirectRoll() end)
    now.direct:SetPoint("RIGHT", now.cancel, "LEFT", -6, 0)
    now.early = W.Button(area, "数秒", "normal", 44, 22, function() A():Early() end)
    now.early:SetPoint("RIGHT", now.direct, "LEFT", -6, 0)
    now.prog = W.Progress(area, 6)
    now.prog:SetPoint("BOTTOMLEFT", 12, 10)
    now.prog:SetPoint("BOTTOMRIGHT", -12, 10)

    -- 手动添加待拍物品：把物品拖到列表上
    local function receive()
        local kind, id = GetCursorInfo()
        if kind == "item" and id then
            if A():AddPending(id) then ns.Print("已加入待拍：" .. ns.Auction.LinkFor(id)) end
            ClearCursor()
        end
    end
    LT.list:EnableMouse(true)
    LT.list:SetScript("OnReceiveDrag", receive)
    LT.list:SetScript("OnMouseUp", function() if GetCursorInfo() then receive() end end)
    page:HookScript("OnShow", function() Popup:RefreshNow() end)
end

function Popup:RefreshNow()
    if not now or not LT.nowArea then return end
    local m = M()
    local area = LT.nowArea
    local wasShown = area:IsShown()
    if not m:InProgress() and m.state ~= "settle" then
        area:Hide()
        if wasShown then LT:Refresh() end
        return
    end
    area:Show()
    now.item:SetItem({ id = m.item })
    local t = GetTime()
    local phase = (m.state == "roll") and "Roll 中" or ((m.state == "settle") and "结算" or "出分中")
    now.text:SetText(phase .. " · " .. Popup.StatusLine(t))
    local remaining, total = m:Remaining(t)
    now.prog:SetValue(total > 0 and remaining / total or 0)
    local officer, host = IsOfficer(), A():IsAuctioneer()
    for _, b in ipairs({ now.early, now.direct, now.cancel }) do
        b:SetShown(officer and m:InProgress())
        b:SetEnabledState(host)
    end
    now.direct:SetShown(officer and m.state == "bid")
    if not wasShown then LT:Refresh() end
end

-- 对着聊天框里的物品链接 Shift 点击：掉落页打开时加入待拍（团长、助理）
local function OnModifiedClick(link)
    if not IsShiftKeyDown() or not IsOfficer() then return end
    if not (ns.Main:IsShown() and ns.Main.current == "loot") then return end
    local id = ns.Items.LinkID(link)
    if id and A():AddPending(id) then ns.Print("已加入待拍：" .. link) end
end

------------------------------------------------------------------------
-- 事件
------------------------------------------------------------------------

local refresh = ns.Debounce(function()
    Popup:Refresh()
    Popup:RefreshPill()
    Popup:RefreshNow()
    if ns.Main:IsShown() and ns.Main.current == "loot" then ns.Main:RequestRefresh() end
end)

ns.Events:On("RW_LOADED", function()
    Create()
    CreatePill()
    if HandleModifiedItemClick then hooksecurefunc("HandleModifiedItemClick", OnModifiedClick) end
end)

ns.Events:On("RW_AUCTION_STARTED", function(id)
    Popup.collapsed = A():IsPMarked(id)
    refresh()
end)
ns.Events:On("RW_AUCTION_EXPAND", function() Popup:SetCollapsed(false) end)
ns.Events:On("RW_AUCTION_TICK", function() Popup:UpdateTimer() end)
for _, ev in ipairs({ "RW_AUCTION_CHANGED", "RW_ROSTER_UPDATE", "RW_AUCTION_OPTION", "RW_LOOT_CHANGED",
    "GET_ITEM_INFO_RECEIVED", "RW_SKIN_CHANGED" }) do
    ns.Events:On(ev, refresh)
end
ns.Events:On("RW_RESET_POSITIONS", function()
    for _, f in ipairs({ popup, bar, pill }) do if f then W.RestorePosition(f) end end
end)

------------------------------------------------------------------------
-- 设置：拍卖
------------------------------------------------------------------------

ns.Settings:AddCategory("auction", "拍卖", 40, function(_, L)
    local o = ns.DB.options.auction
    L:Heading("播报")
    L:Check("语音播报", function() return o.voice end, function(v) o.voice = v end)
    local pack = ns.Voice:Pack()
    if pack then
        local who = (pack.author and pack.author ~= "") and ("，录音：" .. pack.author) or ""
        L:Check("使用语音包「" .. (pack.name or "语音包") .. "」" .. who, function() return o.voicePack ~= false end,
            function(v) o.voicePack = v end)
        L:Hint("语音包里没有的句子自动用默认语音。语音包的使用限制见语音包文件夹里的授权说明。")
    else
        L:Hint("想换成真人语音：另装语音包插件 RaidWish_Voice 即可，不装就用默认语音。")
    end
    L:Heading("待拍列表记录哪些品质")
    local labels = { [5] = "橙色", [4] = "紫色", [3] = "蓝色", [2] = "绿色", [1] = "白色" }
    for q = 5, 1, -1 do
        L:Check(labels[q], function() return o.quality[q] ~= false end, function(v)
            o.quality[q] = v
            ns.Events:Fire("RW_AUCTION_CHANGED")
        end)
    end
    L:Heading("拍卖弹窗")
    L:Slider("弹窗缩放", 80, 150, 5, function() return math.floor((ns.DB.char.auctionScale or 1) * 100 + 0.5) end,
        function(v)
            ns.DB.char.auctionScale = v / 100
            if popup then popup:SetScale(v / 100) end
        end, "%d%%")
end)
