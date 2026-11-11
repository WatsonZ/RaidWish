-- UI/MainFrame.lua：主窗口外壳
-- 标题栏、状态行、三个标签页、内容区、底部状态栏。各标签页通过 Main:RegisterPage 接入。
local ADDON, ns = ...

local W = ns.Widgets

local Main = { pages = {}, order = { "wish", "loot", "set" } }
ns.Main = Main

local WIDTH, CONTENT_H = 600, 402
local TAB_TEXT = { wish = "许愿", loot = "掉落与拍卖", set = "设置" }

-- page：{ create = function(content, footLeft) 返回页面框体, refresh = function(), onShow = function() }
function Main:RegisterPage(key, page)
    self.pages[key] = page
end

local frame

local function LeaderColoredName(name)
    if not name then return nil end
    local rec = ns.Wish.model and ns.Wish.model:Get(name)
    local _, set = ns.Roster:Get()
    return (set[name] and set[name].class) or (rec and rec.class)
end

local function RefreshStatus()
    local Wish = ns.Wish
    local leader = Wish:LeaderName()
    local dot, text
    if leader and Wish:InProgress() then
        dot, text = "ok", "许愿进行中"
    elseif leader then
        dot, text = "warn", "已停止"
    else
        dot, text = "off", "未开始"
    end
    frame.dot:SetState(dot)
    frame.stateText:SetText(text)
    local isLeader = Wish:IsLeader()
    frame.yield:SetShown(isLeader)
    if leader then
        frame.leaderName:SetText(leader)
        W.SetClassColor(frame.leaderName, LeaderColoredName(leader))
    else
        frame.leaderName:SetText("无")
        W.SetRole(frame.leaderName, "dim")
    end
    -- 右下角同步状态（发现可恢复的快照时改成恢复提示）
    local footRight = Main.footRightOverride and Main.footRightOverride()
    if footRight then
        frame.syncText:SetText(footRight)
        return
    end
    local state, n, total = Wish:SyncState()
    if state == "ok" then
        frame.syncText:SetText("同步正常")
    elseif state == "syncing" then
        frame.syncText:SetText(("正在同步 %d/%d"):format(n or 0, total or 0))
    elseif state == "waiting" then
        frame.syncText:SetText("等待团长数据")
    else
        frame.syncText:SetText("")
    end
end

function Main:Refresh()
    if not frame or not frame:IsShown() then return end
    RefreshStatus()
    local p = self.pages[self.current]
    if p and p.refresh then p.refresh() end
end

local requestRefresh = ns.Debounce(function() Main:Refresh() end)
function Main:RequestRefresh() requestRefresh() end

function Main:Select(key)
    self.current = key
    for k, p in pairs(self.pages) do
        if p.frame then p.frame:SetShown(k == key) end
        if p.foot then p.foot:SetShown(k == key) end
    end
    local p = self.pages[key]
    if p and not p.frame and p.create then
        p.foot = CreateFrame("Frame", nil, frame.footer)
        p.foot:SetPoint("TOPLEFT", 14, 0)
        p.foot:SetPoint("BOTTOMRIGHT", -180, 0)
        p.frame = ns.SafeCall("创建页面 " .. key, p.create, frame.content, p.foot)
        if p.frame then p.frame:SetAllPoints(frame.content) end
    end
    if p and p.onShow then p.onShow() end
    self:Refresh()
end

local function Create()
    frame = W.Panel({
        name = "RaidWishMainFrame", width = WIDTH, height = 34 + 30 + 31 + CONTENT_H + 30 + 2,
        title = ns.SHORT_TITLE, closeKind = "close", saveKey = "main",
    })
    frame:SetScale(ns.DB.char.mainScale or 1)
    tinsert(UISpecialFrames, "RaidWishMainFrame")

    -- 状态行
    local status = CreateFrame("Frame", nil, frame)
    status:SetPoint("TOPLEFT", frame.head, "BOTTOMLEFT", 0, 0)
    status:SetPoint("TOPRIGHT", frame.head, "BOTTOMRIGHT", 0, 0)
    status:SetHeight(30)
    local sline = W.Divider(status)
    sline:SetPoint("BOTTOMLEFT")
    sline:SetPoint("BOTTOMRIGHT")
    frame.dot = W.Dot(status, 8)
    frame.dot:SetPoint("LEFT", 14, 0)
    frame.stateText = W.Text(status, "text", 12)
    frame.stateText:SetPoint("LEFT", frame.dot, "RIGHT", 8, 0)
    local sep = W.Text(status, "dim", 12)
    sep:SetPoint("LEFT", frame.stateText, "RIGHT", 8, 0)
    sep:SetText("·")
    local lt = W.Text(status, "dim", 12)
    lt:SetPoint("LEFT", sep, "RIGHT", 8, 0)
    lt:SetText("许愿团长")
    frame.leaderName = W.Text(status, "text", 12)
    frame.leaderName:SetPoint("LEFT", lt, "RIGHT", 6, 0)
    -- 许愿团长自己：名字后面一个小标签按钮"让出"，点后在确认框里再点红色的"让出"
    local yield = W.Button(status, "让出", "chip", 44, 18, function()
        W.Confirm("RELINQUISH", "确定要让出许愿团长吗？\n让出后由团长或助理重新点\"开始许愿\"接手。",
            function() ns.WishChat:Relinquish() end, { danger = true, okText = "让出" })
    end)
    yield:SetPoint("LEFT", frame.leaderName, "RIGHT", 10, 0)
    W.Tooltip(yield, "让出许愿团长", "放弃许愿团长的权限（需要再次确认）")
    yield:Hide()
    frame.yield = yield

    -- 标签页
    local items = {}
    for _, k in ipairs(Main.order) do items[#items + 1] = { key = k, text = TAB_TEXT[k] } end
    local tabs = W.Tabs(frame, items, function(key) Main:Select(key) end)
    tabs:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, 0)
    tabs:SetPoint("TOPRIGHT", status, "BOTTOMRIGHT", 0, 0)
    local tline = W.Divider(tabs)
    tline:SetPoint("BOTTOMLEFT")
    tline:SetPoint("BOTTOMRIGHT")
    frame.tabs = tabs

    -- 内容区
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", tabs, "BOTTOMLEFT", 0, 0)
    content:SetPoint("TOPRIGHT", tabs, "BOTTOMRIGHT", 0, 0)
    content:SetHeight(CONTENT_H)
    frame.content = content

    -- 底部状态栏：左边由当前页提供，右边是同步状态
    local footer = CreateFrame("Button", nil, frame)
    footer:SetPoint("TOPLEFT", content, "BOTTOMLEFT", 0, 0)
    footer:SetPoint("TOPRIGHT", content, "BOTTOMRIGHT", 0, 0)
    footer:SetHeight(30)
    local fline = W.Divider(footer)
    fline:SetPoint("TOPLEFT")
    fline:SetPoint("TOPRIGHT")
    frame.syncText = W.Text(footer, "dim", 12)
    frame.syncText:SetPoint("RIGHT", -14, 0)
    frame.syncText:SetJustifyH("RIGHT")
    footer:SetScript("OnClick", function()
        if Main.footRightClick then Main.footRightClick() end
    end)
    frame.footer = footer

    frame:SetScript("OnShow", function() Main:Refresh() end)
    tabs:Select(Main.current or "wish")
end

function Main:Show(tab)
    if not frame then Create() end
    frame:Show()
    if tab and tab ~= self.current then frame.tabs:Select(tab) end
    self:Refresh()
end

function Main:Toggle()
    if frame and frame:IsShown() then frame:Hide() else self:Show() end
end

function Main:IsShown() return frame ~= nil and frame:IsShown() end

function Main:SetScale(s)
    ns.DB.char.mainScale = s
    if frame then frame:SetScale(s) end
end

function Main:ResetPosition()
    if frame then W.RestorePosition(frame) end
end

ns.Events:On("RW_TOGGLE_MAIN", function() Main:Toggle() end)
for _, ev in ipairs({ "RW_LEADER_CHANGED", "RW_WISH_CHANGED", "RW_SYNC_STATE", "RW_ROSTER_UPDATE",
    "RW_SKIN_CHANGED", "GET_ITEM_INFO_RECEIVED" }) do
    ns.Events:On(ev, function() Main:RequestRefresh() end)
end
