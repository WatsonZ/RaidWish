-- UI/LootTab.lua：掉落与拍卖页（拍卖部分由 AuctionPopup 接入）
-- 上方"当前拍卖"区由 AuctionPopup 填充（有拍卖时才显示），下方是掉落列表：时间、物品、结果。
local ADDON, ns = ...

local W = ns.Widgets

local Tab = {}
ns.LootTab = Tab

local PAD, TIME_W, GAP = 14, 54, 10
local QUALITY_LABEL = { [5] = "橙", [4] = "紫", [3] = "蓝", [2] = "绿", [1] = "白" }

local page, list, foot, nowArea, headY

local function IsOfficerView() return ns.Wish:IsLeader() or ns.Roster:SelfIsOfficer() end

------------------------------------------------------------------------
-- 结果列（拍卖模块通过 Tab.ResultFor 覆盖：拍卖中 / 未拍按钮 / 已拍结果）
------------------------------------------------------------------------

-- 返回 { kind = "text" | "button", text =, role =, class =, onClick = }
function Tab.ResultFor(e)
    if e.sold then
        local v = e.sold.roll and ("Roll " .. e.sold.roll) or ((e.sold.score or 0) .. " 分")
        return { kind = "text", text = e.sold.winner, class = Tab.ClassOf(e.sold.winner), suffix = " · " .. v }
    end
    return { kind = "text", text = e.player, class = Tab.ClassOf(e.player) }
end

function Tab.ClassOf(name)
    local _, set = ns.Roster:Get()
    if set[name] then return set[name].class end
    local rec = ns.Wish.model and ns.Wish.model:Get(name)
    return rec and rec.class
end

------------------------------------------------------------------------
-- 行
------------------------------------------------------------------------

local function ShowRowMenu(row)
    if not ns.Wish:IsLeader() or not row.data then return end
    local e = row.data
    W.Menu(row, function(root)
        if Tab.ExtraMenu then Tab.ExtraMenu(root, e) end
        root:Button("从列表移除", function() ns.LootLog:Remove(e.uid) end)
        root:Divider()
        root:Button("清除掉落列表", function()
            W.Confirm("CLEAR_LOOT", "确定要清除掉落列表吗？", function() ns.LootLog:Clear() end)
        end)
    end)
end

local function CreateRow(row)
    row.time = W.Text(row, "dim", 12)
    row.time:SetPoint("LEFT", PAD, 0)
    row.item = W.ItemCell(row, 22, 13)
    row.item:SetPoint("LEFT", PAD + TIME_W + GAP, 0)
    row.item._row = row
    row.res = W.Text(row, "dim", 13)
    row.res:SetPoint("RIGHT", -PAD, 0)
    row.res:SetJustifyH("RIGHT")
    row.resSuffix = W.Text(row, "dim", 13)
    row.resSuffix:SetPoint("RIGHT", -PAD, 0)
    row.btn = W.Button(row, "拍卖", "normal", 52, 22)
    row.btn:SetPoint("RIGHT", -PAD, 0)
    row.btn:Hide()
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then ShowRowMenu(self) end
    end)
end

local function UpdateRow(row, e)
    row.time:SetText(ns.Util.FormatTime(e.ts))
    row.item:SetItem({ id = e.id })
    local r = Tab.ResultFor(e)
    row.btn:Hide()
    row.res:Show()
    row.resSuffix:Hide()
    if r.kind == "button" then
        row.res:Hide()
        row.btn:SetText(r.text)
        W.FitButton(row.btn, 52)
        row.btn:SetScript("OnClick", r.onClick)
        row.btn:Show()
        return
    end
    if r.suffix then
        row.resSuffix:SetText(r.suffix)
        row.resSuffix:Show()
        row.res:ClearAllPoints()
        row.res:SetPoint("RIGHT", row.resSuffix, "LEFT", 0, 0)
    else
        row.res:ClearAllPoints()
        row.res:SetPoint("RIGHT", -PAD, 0)
    end
    row.res:SetText(r.text or "")
    if r.class then W.SetClassColor(row.res, r.class) else W.SetRole(row.res, r.role or "dim") end
end

------------------------------------------------------------------------
-- 页面
------------------------------------------------------------------------

local function QualityLabel()
    local parts = {}
    for q = 5, 1, -1 do
        if ns.DB.options.qualityFilters[q] then parts[#parts + 1] = QUALITY_LABEL[q] end
    end
    if #parts == 0 then return "不记录任何品质" end
    return "只记录 " .. table.concat(parts, "、")
end

function Tab:Refresh()
    if not page or not page:IsShown() then return end
    -- "当前拍卖"区：有拍卖时显示并把列表下移
    local nowH = (nowArea and nowArea:IsShown()) and (nowArea:GetHeight() + 24) or 0
    headY:ClearAllPoints()
    headY:SetPoint("TOPLEFT", 0, -nowH)
    headY:SetPoint("TOPRIGHT", 0, -nowH)
    list:SetData(ns.LootLog:Entries())
    local total, sold, pending = ns.LootLog:Counts()
    if Tab.Counts then total, sold, pending = Tab.Counts(total, sold, pending) end
    foot.total:SetText("本次掉落 " .. total .. " 件")
    foot.sold:SetText("已拍 " .. sold)
    foot.pending:SetText("待拍 " .. pending)
    foot.quality:SetText(QualityLabel())
    if Tab.OnRefresh then Tab.OnRefresh(IsOfficerView()) end
end

local function Create(content, footLeft)
    page = CreateFrame("Frame", nil, content)

    -- "当前拍卖"区的容器（由 AuctionPopup 填充；默认隐藏）
    nowArea = W.Box(page, "box")
    nowArea:SetPoint("TOPLEFT", PAD, -12)
    nowArea:SetPoint("TOPRIGHT", -PAD, -12)
    nowArea:SetHeight(58)
    nowArea:Hide()
    Tab.nowArea = nowArea

    headY = W.Box(page, "band")
    headY:SetHeight(26)
    local line = W.Divider(headY)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    local h1 = W.Text(headY, "dim", 12)
    h1:SetPoint("LEFT", PAD, 0)
    h1:SetText("时间")
    local h2 = W.Text(headY, "dim", 12)
    h2:SetPoint("LEFT", PAD + TIME_W + GAP, 0)
    h2:SetText("物品")
    local h3 = W.Text(headY, "dim", 12)
    h3:SetPoint("RIGHT", -PAD, 0)
    h3:SetText("结果")

    list = W.List(page, { rowHeight = 36, createRow = CreateRow, updateRow = UpdateRow })
    list:SetPoint("TOPLEFT", headY, "BOTTOMLEFT", 0, 0)
    list:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    Tab.list = list

    foot = {}
    foot.total = W.Text(footLeft, "dim", 12)
    foot.total:SetPoint("LEFT", 0, 0)
    foot.sold = W.Text(footLeft, "dim", 12)
    foot.sold:SetPoint("LEFT", foot.total, "RIGHT", 14, 0)
    foot.pending = W.Text(footLeft, "dim", 12)
    foot.pending:SetPoint("LEFT", foot.sold, "RIGHT", 14, 0)
    foot.quality = W.Text(footLeft, "dim", 12)
    foot.quality:SetPoint("RIGHT", 0, 0)
    foot.quality:SetJustifyH("RIGHT")

    page:SetScript("OnShow", function() Tab:Refresh() end)
    if Tab.OnCreate then Tab.OnCreate(page) end
    return page
end

ns.Main:RegisterPage("loot", { create = Create, refresh = function() Tab:Refresh() end })

ns.Events:On("RW_LOOT_CHANGED", function() ns.Main:RequestRefresh() end)

------------------------------------------------------------------------
-- 设置：掉落记录
------------------------------------------------------------------------

ns.Settings:AddCategory("loot", "掉落记录", 50, function(_, L)
    L:Heading("记录哪些品质")
    local labels = { [5] = "橙色", [4] = "紫色", [3] = "蓝色", [2] = "绿色", [1] = "白色（含灰色）" }
    for q = 5, 1, -1 do
        L:Check(labels[q], function() return ns.DB.options.qualityFilters[q] end, function(v)
            ns.DB.options.qualityFilters[q] = v
            if q == 1 then ns.DB.options.qualityFilters[0] = v end
            ns.Events:Fire("RW_LOOT_CHANGED")
        end)
    end
    L:Hint("只影响以后的记录；已记录的物品不会被删掉。")
    L:Heading("掉落列表")
    L:Button("清除掉落列表", function()
        W.Confirm("CLEAR_LOOT", "确定要清除掉落列表吗？", function() ns.LootLog:Clear() end)
    end)
end)
