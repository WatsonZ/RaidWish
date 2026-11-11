-- UI/WishTab.lua：许愿页
local ADDON, ns = ...

local W = ns.Widgets
local Util = ns.Util

local Tab = { sortField = "name", sortAsc = true, filter = nil, search = "" }
ns.WishTab = Tab

local PAD, WHO_W, SCORE_W, GAP = 14, 150, 96, 10
local ROW_W = 598
local WISH_W = ROW_W - PAD * 2 - WHO_W - SCORE_W - GAP * 2
local MAX_CELLS = 6

local page, list, headBtns, foot
local leaderBar, memberBar, mainBtn, search, searchM, mine

local function M() return ns.Wish.model end
local function IsLeader() return ns.Wish:IsLeader() end

-- 团长端界面：自己是许愿团长、或有团长 / 助理权限、或不在团队中（便于整理数据）
local function LeaderView()
    return IsLeader() or ns.Roster:SelfIsOfficer() or not IsInRaid()
end

------------------------------------------------------------------------
-- 数据
------------------------------------------------------------------------

local function ItemKey(it)
    if it.id then return "#" .. it.id end
    return "n:" .. ns.Items.CleanName(it.name)
end

local function Matches(row, q)
    if q == "" then return true end
    if row.name:lower():find(q, 1, true) then return true end
    local rec = row.rec
    if ns.WishModel.HasWish(rec) then
        for _, it in ipairs(rec.wish.items) do
            local name = it.name
            if not name and it.id then
                local info = ns.Items.GetCached(it.id)
                name = info and info.name
            end
            if name and ns.Items.CleanName(name):find(ns.Items.CleanName(q), 1, true) then return true end
        end
    end
    return false
end

-- 当前显示的行：在团时只显示在团成员
local function BuildRows()
    local set = nil
    if IsInRaid() then set = select(2, ns.Roster:Get()) end
    local rows = M():Sorted(Tab.sortField, Tab.sortAsc, set)
    -- 每件物品的许愿人数（只算显示的成员、未完成的物品）
    local counts = {}
    for _, r in ipairs(rows) do
        if ns.WishModel.HasWish(r.rec) then
            for _, it in ipairs(r.rec.wish.items) do
                if not it.done and not it.floor then
                    local k = ItemKey(it)
                    counts[k] = (counts[k] or 0) + 1
                end
            end
        end
    end
    local wished, unwished, dupItems = 0, 0, 0
    for _, n in pairs(counts) do if n >= 2 then dupItems = dupItems + 1 end end
    local out = {}
    local q = Util.Trim(Tab.search or ""):lower()
    for _, r in ipairs(rows) do
        local has = ns.WishModel.HasWish(r.rec)
        if has then wished = wished + 1 else unwished = unwished + 1 end
        local isDup = false
        if has then
            for _, it in ipairs(r.rec.wish.items) do
                if not it.done and not it.floor and (counts[ItemKey(it)] or 0) >= 2 then isDup = true end
            end
        end
        local keep = Matches(r, q)
        if Tab.filter == "unwished" and has then keep = false end
        if Tab.filter == "wished" and not has then keep = false end
        if Tab.filter == "dup" and not isDup then keep = false end
        if keep then
            r.counts = counts
            out[#out + 1] = r
        end
    end
    return out, wished, unwished, dupItems
end

------------------------------------------------------------------------
-- 行
------------------------------------------------------------------------

local function UpdatePM(row)
    local show = IsLeader() and row:IsShown() and row:IsMouseOver()
    row.minus:SetShown(show and true or false)
    row.plus:SetShown(show and true or false)
end

local function ShowRowMenu(row)
    if not IsLeader() or not row.data then return end
    local name = row.data.name
    local WC = ns.WishChat
    W.Menu(row, function(root)
        root:Title(name)
        root:Button("通报此人许愿", function() WC:Query(name) end)
        local add = root:Button("增加分数")
        for n = 1, 4 do add:Button("增加" .. n .. "分", function() WC:AddDkp(name, n) end) end
        local minus = root:Button("扣除分数")
        for n = 1, 4 do minus:Button("扣除" .. n .. "分", function() WC:MinusDkp(name, n) end) end
        if ns.WishModel.IsFullyDone(M():Get(name)) then
            root:Button("撤销完成", function() WC:UndoDone(name) end)
        else
            root:Button("标记完成", function() WC:MarkDone(name) end)
        end
        root:Divider()
        root:Button("清除此人许愿", function()
            W.Confirm("CLEAR_ONE", "确定要清除 " .. name .. " 的许愿吗？", function() WC:ClearWish(name) end)
        end)
    end)
end

local function WishTooltip(row)
    if not row.truncated or not row.data then return end
    local lines = {}
    for _, it in ipairs(row.data.rec.wish.items) do
        local name = it.name
        local info = it.id and ns.Items.GetCached(it.id)
        if info then name = info.name end
        local r, g, b = W.QualityColor(info and info.quality or 1)
        lines[#lines + 1] = ("|cff%02x%02x%02x%s|r%s"):format(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255),
            name or "?", it.done and "（已完成）" or "")
    end
    W.ShowTip(row, row.data.name, table.concat(lines, "\n"))
end

local function CreateRow(row)
    row.badge = W.ClassBadge(row)
    row.badge:SetPoint("LEFT", PAD, 0)
    row.nameText = W.Text(row, "text", 13)
    row.nameText:SetPoint("LEFT", row.badge, "RIGHT", 8, 0)
    row.nameText:SetWidth(WHO_W - 30)

    row.wishArea = CreateFrame("Frame", nil, row)
    row.wishArea:SetPoint("LEFT", PAD + WHO_W + GAP, 0)
    row.wishArea:SetSize(WISH_W, 24)
    row.wishArea:SetClipsChildren(true)
    row.cells = {}
    for i = 1, MAX_CELLS do
        local c = W.ItemCell(row.wishArea, 22, 13)
        c._row = row
        row.cells[i] = c
    end
    row.none = W.Text(row.wishArea, "dim", 13)
    row.none:SetPoint("LEFT")
    row.none:SetText("未许愿")
    row.more = W.Text(row.wishArea, "dim", 13)
    row.more:SetText("…")

    -- 分数方块与加减号
    row.scoreBox = W.Box(row, "box")
    row.scoreBox:SetSize(28, 20)
    row.scoreBox:SetPoint("RIGHT", -(PAD + 24), 0)
    row.score = W.Text(row.scoreBox, "text", 13)
    row.score:SetPoint("CENTER")
    row.minus = W.GlyphButton(row, "minus", 18, 18, function()
        ns.WishChat:MinusDkp(row.data.name, 1)
    end)
    row.minus:SetPoint("RIGHT", row.scoreBox, "LEFT", -6, 0)
    row.plus = W.GlyphButton(row, "plus", 18, 18, function()
        ns.WishChat:AddDkp(row.data.name, 1)
    end)
    row.plus:SetPoint("LEFT", row.scoreBox, "RIGHT", 6, 0)
    W.Tooltip(row.minus, "扣 1 分", "并在团队频道通报")
    W.Tooltip(row.plus, "加 1 分", "并在团队频道通报")
    for _, b in ipairs({ row.minus, row.plus }) do
        b:HookScript("OnLeave", function() UpdatePM(row) end)
    end
    row.minus:Hide()
    row.plus:Hide()

    row:HookScript("OnEnter", function(self)
        UpdatePM(self)
        WishTooltip(self)
    end)
    row:HookScript("OnLeave", function(self)
        if self:IsMouseOver() then return end
        UpdatePM(self)
        W.HideTip()
    end)
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then ShowRowMenu(self) end
    end)
end

local function UpdateRow(row, data)
    local rec = data.rec
    local _, set = ns.Roster:Get()
    local class = (set[data.name] and set[data.name].class) or rec.class
    row.badge:SetClass(class)
    row.nameText:SetText(data.name)
    W.SetClassColor(row.nameText, class)

    for _, c in ipairs(row.cells) do c:Hide() end
    row.more:Hide()
    row.truncated = false
    if ns.WishModel.HasWish(rec) then
        row.none:Hide()
        local x = 0
        for i, it in ipairs(rec.wish.items) do
            local c = row.cells[i]
            if not c then
                row.truncated = true
                break
            end
            local dup = (not it.done and not it.floor) and data.counts[ItemKey(it)] or nil
            c:SetItem(it, dup)
            c:ClearAllPoints()
            c:SetPoint("LEFT", x, 0)
            if x + c:GetWidth() > WISH_W then
                row.truncated = true
                if i == 1 then c:Show() end      -- 第一件总是显示（被裁剪）
                break
            end
            c:Show()
            x = x + c:GetWidth() + 12
        end
        if row.truncated then
            row.more:ClearAllPoints()
            row.more:SetPoint("RIGHT", row.wishArea, "RIGHT", 0, 0)
            row.more:Show()
        end
    else
        row.none:Show()
    end
    row.score:SetText(tostring(tonumber(rec.dkp) or 0))
    UpdatePM(row)
end

------------------------------------------------------------------------
-- 工具栏
------------------------------------------------------------------------

-- 通报类按钮：点一下发到团队频道，之后 2 秒内置灰，防止连点刷屏
local COOLDOWN = 2
local function AnnounceButton(parent, text, tip, fn)
    local btn
    btn = W.Button(parent, text, "ghost", "auto", 26, function()
        fn()
        btn:SetEnabledState(false)
        ns.After(COOLDOWN, function() btn:SetEnabledState(true) end)
    end)
    W.Tooltip(btn, text, tip)
    return btn
end

local function CreateBars(p)
    -- 团长端
    leaderBar = CreateFrame("Frame", nil, p)
    leaderBar:SetPoint("TOPLEFT", 0, 0)
    leaderBar:SetPoint("TOPRIGHT", 0, 0)
    leaderBar:SetHeight(46)
    mainBtn = W.Button(leaderBar, "开始许愿", "primary", 92, 26, function()
        if IsLeader() and ns.Wish:InProgress() then ns.WishChat:Stop() else ns.WishChat:Start() end
    end)
    mainBtn:SetPoint("LEFT", PAD, 0)
    -- 打团中常用的通报，直接摆在工具栏上
    local WC = ns.WishChat
    local defs = {
        { "开团公告", "在团队频道发开团公告（设置 → 开团公告与宣言 可修改）", function() WC:SendStartText() end },
        { "宣言", "在团队频道逐行发团队宣言", function() WC:AnnounceDeclaration() end },
        { "通报未许愿", "在团队频道通报还没许愿的人", function() WC:AnnounceUnwished() end },
        { "播报全部", "按当前排序，在团队频道逐条播报所有人的许愿", function() WC:BroadcastAll(Tab.sortField, Tab.sortAsc) end },
    }
    local prev = mainBtn
    for _, d in ipairs(defs) do
        local b = AnnounceButton(leaderBar, d[1], d[2], d[3])
        b:SetWidth(b:GetFontString():GetStringWidth() + 24)
        -- 连成一组：相邻按钮左移 1 像素，边线重合
        b:SetPoint("LEFT", prev, "RIGHT", prev == mainBtn and 12 or -1, 0)
        prev = b
    end
    search = W.Input(leaderBar, 124, 26, "搜索角色或物品")
    search:SetPoint("RIGHT", -PAD, 0)

    -- 团员端
    memberBar = CreateFrame("Frame", nil, p)
    memberBar:SetAllPoints(leaderBar)
    searchM = W.Input(memberBar, 170, 26, "搜索角色或物品")
    searchM:SetPoint("RIGHT", -PAD, 0)
    mine = {}
    mine.label = W.Text(memberBar, "dim", 13)
    mine.label:SetPoint("LEFT", PAD, 0)
    mine.cells = {}
    for i = 1, 3 do
        mine.cells[i] = W.ItemCell(memberBar, 22, 13)
    end
    mine.ok = W.Text(memberBar, "ok", 13)

    for _, s in ipairs({ search, searchM }) do
        s:HookScript("OnTextChanged", function(self)
            Tab.search = self:GetText()
            Tab:Refresh()
        end)
    end
end

local function UpdateMemberHint()
    for _, c in ipairs(mine.cells) do c:Hide() end
    mine.ok:Hide()
    local me = ns.Roster:Self()
    local rec = M():Get(me)
    if not ns.Wish:LeaderName() and not ns.WishModel.HasWish(rec) then
        mine.label:SetText("许愿尚未开始")
        return
    end
    if not ns.WishModel.HasWish(rec) then
        mine.label:SetText("你还没有许愿，在团队频道输入 xy 加物品链接")
        return
    end
    mine.label:SetText("你的许愿")
    local anchor, x = mine.label, 8
    for i, it in ipairs(rec.wish.items) do
        local c = mine.cells[i]
        if not c then break end
        c:SetItem(it)
        c:ClearAllPoints()
        c:SetPoint("LEFT", anchor, "RIGHT", x, 0)
        c:Show()
        anchor, x = c, 10
    end
    mine.ok:ClearAllPoints()
    mine.ok:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
    mine.ok:SetText("（团长已记录）")
    mine.ok:Show()
end

------------------------------------------------------------------------
-- 列头与底部
------------------------------------------------------------------------

local function SortLabel(field, text)
    if Tab.sortField ~= field then return text end
    return text .. (Tab.sortAsc and " ▲" or " ▼")
end

local function CreateHead(p)
    local head = W.Box(p, "band")
    head:SetPoint("TOPLEFT", 0, -46)
    head:SetPoint("TOPRIGHT", 0, -46)
    head:SetHeight(26)
    local line = W.Divider(head)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    headBtns = {}
    local defs = {
        { "name", "角色", "LEFT", PAD },
        { "wish", "许愿", "LEFT", PAD + WHO_W + GAP },
        { "dkp", "分数", "RIGHT", -PAD },
    }
    for _, d in ipairs(defs) do
        local b = CreateFrame("Button", nil, head)
        b:SetSize(80, 26)
        b:SetPoint(d[3], d[4], 0)
        local fs = W.Text(b, "dim", 12)
        fs:SetPoint(d[3], 0, 0)
        b.fs = fs
        b:SetScript("OnClick", function()
            if Tab.sortField == d[1] then Tab.sortAsc = not Tab.sortAsc
            else Tab.sortField, Tab.sortAsc = d[1], d[1] ~= "dkp" end
            Tab:Refresh()
        end)
        headBtns[d[1]] = { btn = b, text = d[2] }
    end
end

local lastUnwishedAnnounce = 0

-- 底部筛选标签：全部 / 已许愿 / 未许愿 / 重复。选中的一个高亮；"未许愿"右键在团队频道通报
local CHIPS = {
    { key = nil, label = "全部", tip = "显示所有人" },
    { key = "wished", label = "已许愿", tip = "只显示已经许愿的人" },
    { key = "unwished", label = "未许愿", tip = "只显示还没许愿的人\n右键：在团队频道通报未许愿名单" },
    { key = "dup", label = "重复", tip = "只显示许愿和别人重复的人" },
}

local function CreateFoot(footLeft)
    foot = { chips = {} }
    local prev
    for i, def in ipairs(CHIPS) do
        local b = W.Button(footLeft, def.label, "chip", 60, 20, function(_, button)
            if button == "RightButton" then
                if def.key ~= "unwished" or not LeaderView() then return end
                if GetTime() - lastUnwishedAnnounce < COOLDOWN then return end
                lastUnwishedAnnounce = GetTime()
                ns.WishChat:AnnounceUnwished()
                return
            end
            Tab.filter = def.key
            Tab:Refresh()
        end)
        b.def = def
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 6, 0) else b:SetPoint("LEFT", 0, 0) end
        W.Tooltip(b, def.label, def.tip)
        foot.chips[i] = b
        prev = b
    end
    -- 清空入口（团长端）：底部右侧的红色小按钮，点后确认
    foot.clear = W.Button(footLeft, "清空许愿表", "danger", "auto", 20, function()
        W.Confirm("RESET", "确定要清空所有人的许愿和分数吗？此操作会同步给全团。",
            function() ns.WishChat:ClearAll() end, { danger = true, okText = "清空" })
    end)
    foot.clear:SetPoint("RIGHT", footLeft, "RIGHT", 0, 0)
    W.Tooltip(foot.clear, "清空许愿表", "清空所有人的许愿和分数并同步全团（需要再次确认）。\n清空前建议先在 设置 → 数据 导出备份。")
end

------------------------------------------------------------------------
-- 刷新
------------------------------------------------------------------------

function Tab:Refresh()
    if not page or not page:IsShown() then return end
    local leaderView = LeaderView()
    leaderBar:SetShown(leaderView)
    memberBar:SetShown(not leaderView)
    if leaderView then
        mainBtn:SetText((IsLeader() and ns.Wish:InProgress()) and "停止许愿" or "开始许愿")
    else
        UpdateMemberHint()
    end
    for f, h in pairs(headBtns) do h.btn.fs:SetText(SortLabel(f, h.text)) end

    local rows, wished, unwished, dup = BuildRows()
    list:SetData(rows)
    foot.clear:SetShown(LeaderView())
    local nums = { [0] = wished + unwished, wished = wished, unwished = unwished, dup = dup }
    for _, b in ipairs(foot.chips) do
        local key = b.def.key
        b:SetText(b.def.label .. " " .. nums[key or 0])
        b:SetWidth(b:GetFontString():GetStringWidth() + 18)
        local on = Tab.filter == key
        if b._on ~= on then
            b._on = on
            ns.Skin:Apply(b, "button", on and "chipOn" or "chip")
        end
    end
end

local function Create(content, footLeft)
    page = CreateFrame("Frame", nil, content)
    CreateBars(page)
    CreateHead(page)
    list = W.List(page, { rowHeight = 36, createRow = CreateRow, updateRow = UpdateRow })
    list:SetPoint("TOPLEFT", 0, -72)
    list:SetPoint("BOTTOMRIGHT", 0, 0)
    CreateFoot(footLeft)
    page:SetScript("OnShow", function() Tab:Refresh() end)
    return page
end

ns.Main:RegisterPage("wish", {
    create = Create,
    refresh = function() Tab:Refresh() end,
})

-- 团长端新录入的行高亮闪一下
ns.Events:On("RW_WISH_RECORDED", function(name)
    if not list then return end
    ns.After(0.05, function()
        for _, row in ipairs(list.rows) do
            if row:IsShown() and row.data and row.data.name == name then W.Flash(row) end
        end
    end)
end)
