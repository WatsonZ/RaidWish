-- UI/SettingsTab.lua：设置页
-- 左侧分类，右侧内容。其他模块用 ns.Settings:AddCategory 补充自己的分类
-- （掉落记录、拍卖等）。
local ADDON, ns = ...

local W = ns.Widgets

local Settings = { cats = {}, current = nil }
ns.Settings = Settings

local CAT_W, H = 150, 392
local page, catBar, body
local Scroller

-- order：排序用的数字；build(container, L) 构建内容，L 为布局助手
function Settings:AddCategory(key, title, order, build)
    self.cats[#self.cats + 1] = { key = key, title = title, order = order, build = build }
    table.sort(self.cats, function(a, b) return a.order < b.order end)
    if catBar then self:BuildCategoryList() end
end

------------------------------------------------------------------------
-- 布局助手：自上而下排列
------------------------------------------------------------------------

local function Layout(container)
    local L = { y = -14, x = 18, refreshers = {} }
    local function place(w, h, dx)
        w:SetPoint("TOPLEFT", container, "TOPLEFT", L.x + (dx or 0), L.y)
        L.y = L.y - (h or w:GetHeight())
        return w
    end
    function L:Heading(text)
        local fs = W.Text(container, "title", 13)
        fs:SetText(text)
        self.y = self.y - (self.y < -14 and 8 or 0)
        place(fs, 22)
        return fs
    end
    local TEXT_W = 600 - 150 - 1 - 18 - 30          -- 内容区宽度减去左右留白和滚动条
    function L:Hint(text)
        local fs = W.Text(container, "dim", 12)
        fs:SetWidth(TEXT_W - 24)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        fs:SetText(text)
        local h = math.max(16, (fs:GetStringHeight() or 14) + 4)
        place(fs, h, 24)
        self.y = self.y - 8
        return fs
    end
    -- 一行操作：左边标题 + 一行说明，右边按钮。variant 为 "danger" 时按钮标红
    function L:Action(title, desc, buttonText, onClick, variant)
        local row = CreateFrame("Frame", nil, container)
        row:SetSize(TEXT_W, 46)
        row:SetPoint("TOPLEFT", container, "TOPLEFT", self.x, self.y)
        local line = W.Divider(row)
        line:SetPoint("BOTTOMLEFT")
        line:SetPoint("BOTTOMRIGHT")
        local b = W.Button(row, buttonText, variant or "normal", 76, 26, onClick)
        b:SetPoint("RIGHT", 0, 0)
        local t = W.Text(row, variant == "danger" and "bad" or "text", 13)
        t:SetPoint("TOPLEFT", 0, -6)
        t:SetText(title)
        local d = W.Text(row, "dim", 12)
        d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -4)
        d:SetPoint("RIGHT", b, "LEFT", -12, 0)
        d:SetJustifyH("LEFT")
        d:SetWordWrap(false)
        d:SetText(desc)
        W.Tooltip(b, title, desc)
        self.y = self.y - 46
        row.button = b
        return row
    end
    function L:Check(label, get, set)
        local c = W.Check(container, label, get, function(v) set(v) ns.Main:RequestRefresh() end)
        place(c, 26)
        self.refreshers[#self.refreshers + 1] = c
        return c
    end
    function L:Radio(label, value, get, set)
        local r
        r = W.Radio(container, label, value, get, function(v)
            set(v)
            for _, x in ipairs(self.refreshers) do x:Refresh() end
        end)
        place(r, 26)
        self.refreshers[#self.refreshers + 1] = r
        return r
    end
    function L:Slider(label, minV, maxV, step, get, set, fmt)
        local s = W.Slider(container, label, minV, maxV, step, get, set, fmt)
        place(s, 30)
        self.refreshers[#self.refreshers + 1] = s
        return s
    end
    function L:Button(text, onClick, width)
        local b = W.Button(container, text, "normal", width or "auto", 26, onClick)
        self.y = self.y - 6
        place(b, 32)
        return b
    end
    -- 一行：标签 + 输入框 + 可选按钮
    function L:InputRow(label, width, get, onCommit, buttonText)
        local fs = W.Text(container, "text", 13)
        fs:SetText(label)
        fs:SetPoint("TOPLEFT", container, "TOPLEFT", self.x, self.y - 6)
        local e = W.Input(container, width or 60, 24)
        e:SetPoint("LEFT", fs, "RIGHT", 10, 0)
        e:SetText(tostring(get() or ""))
        local function commit() onCommit(e:GetText(), e) end
        e:SetScript("OnEnterPressed", function(self2) commit() self2:ClearFocus() end)
        if buttonText then
            local b = W.Button(container, buttonText, "normal", "auto", 24, commit)
            b:SetPoint("LEFT", e, "RIGHT", 8, 0)
        else
            e:SetScript("OnEditFocusLost", commit)
        end
        self.y = self.y - 32
        self.refreshers[#self.refreshers + 1] = { Refresh = function() e:SetText(tostring(get() or "")) end }
        return e
    end
    function L:MultiLine(height)
        local ml = W.MultiLine(container, 400, height or 100)
        place(ml, (height or 100) + 6)
        return ml
    end
    -- 一行按钮
    function L:Buttons(defs)
        local prev
        for _, d in ipairs(defs) do
            local b = W.Button(container, d[1], d[3] or "normal", "auto", 26, d[2])
            if prev then b:SetPoint("LEFT", prev, "RIGHT", 8, 0)
            else b:SetPoint("TOPLEFT", container, "TOPLEFT", self.x, self.y) end
            prev = b
        end
        self.y = self.y - 34
    end
    function L:Space(h) self.y = self.y - (h or 8) end
    function L:Refresh() for _, x in ipairs(self.refreshers) do x:Refresh() end end
    return L
end

------------------------------------------------------------------------
-- 页面
------------------------------------------------------------------------

-- 每个分类放在一个可滚轮滚动的区域里；内容超出时右侧显示一条细滚动条
local BODY_W = 600 - CAT_W - 1
Scroller = function()
    local sf = CreateFrame("ScrollFrame", nil, body)
    sf:SetAllPoints(body)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(BODY_W, H)
    sf:SetScrollChild(child)
    local thumb = W.Box(sf, "accentbar")
    thumb:SetWidth(3)
    thumb:SetAlpha(0.6)
    thumb:Hide()
    local contentH = H
    local function viewH() return math.max(1, (sf:GetHeight() or 0) > 0 and sf:GetHeight() or H) end
    local function update()
        local range = math.max(0, contentH - viewH())
        local cur = math.min(math.max(sf:GetVerticalScroll() or 0, 0), range)
        sf:SetVerticalScroll(cur)
        if range <= 0 then thumb:Hide() return end
        local vh = viewH()
        local th = math.max(24, vh * vh / contentH)
        thumb:SetHeight(th)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", sf, "TOPRIGHT", -3, -((vh - th) * cur / range))
        thumb:Show()
    end
    function sf.SetContentHeight(_, h)
        contentH = math.max(h, H)            -- 至少一屏高
        child:SetHeight(contentH)
        update()
    end
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(_, delta)
        sf:SetVerticalScroll((sf:GetVerticalScroll() or 0) - delta * 40)
        update()
    end)
    sf:SetScript("OnSizeChanged", update)
    return sf, child
end

function Settings:Select(key)
    self.current = key
    for _, c in ipairs(self.cats) do
        if c.button then W.SetRole(c.button.fs, c.key == key and "title" or "dim") end
        if c.button then c.button.sel:SetShown(c.key == key) end
        if c.frame then c.frame:SetShown(c.key == key) end
    end
    for _, c in ipairs(self.cats) do
        if c.key == key then
            if not c.frame then
                c.frame, c.child = Scroller()
                c.layout = Layout(c.child)
                ns.SafeCall("设置分类 " .. c.title, c.build, c.child, c.layout)
                c.frame:SetContentHeight(-c.layout.y + 16)
            else
                c.layout:Refresh()
            end
            if c.onShow then c.onShow() end
        end
    end
end

function Settings:BuildCategoryList()
    for i, c in ipairs(self.cats) do
        if not c.button then
            local b = CreateFrame("Button", nil, catBar)
            b:SetSize(CAT_W, 32)
            local sel = W.Box(b, "selected")
            sel:SetAllPoints()
            b.sel = sel
            local holder = CreateFrame("Frame", nil, b)
            holder:SetAllPoints()
            holder:SetFrameLevel(sel:GetFrameLevel() + 1)
            local fs = W.Text(holder, "dim", 13)
            fs:SetPoint("LEFT", 14, 0)
            fs:SetText(c.title)
            b.fs = fs
            b:SetScript("OnClick", function() Settings:Select(c.key) end)
            c.button = b
        end
        c.button:ClearAllPoints()
        c.button:SetPoint("TOPLEFT", 0, -8 - (i - 1) * 32)
    end
    if self.current then self:Select(self.current) end
end

local function Create(content)
    page = CreateFrame("Frame", nil, content)
    catBar = W.Box(page, "band")
    catBar:SetPoint("TOPLEFT", 0, 0)
    catBar:SetSize(CAT_W, H + 10)
    local line = W.Divider(page, true)
    line:SetPoint("TOPLEFT", catBar, "TOPRIGHT", 0, 0)
    line:SetPoint("BOTTOMLEFT", catBar, "BOTTOMRIGHT", 0, 0)
    body = CreateFrame("Frame", nil, page)
    body:SetPoint("TOPLEFT", catBar, "TOPRIGHT", 1, 0)
    body:SetPoint("BOTTOMRIGHT", 0, 0)
    Settings:BuildCategoryList()
    Settings:Select(Settings.current or (Settings.cats[1] and Settings.cats[1].key))
    return page
end

ns.Main:RegisterPage("set", { create = Create })

------------------------------------------------------------------------
-- 分类：界面
------------------------------------------------------------------------

local function O() return ns.DB.options end

Settings:AddCategory("ui", "界面", 10, function(_, L)
    L:Heading("界面风格")
    for _, s in ipairs(ns.Skin:Available()) do
        L:Radio(s.label, s.key, function() return ns.Skin.current end, function(v)
            O().ui.skin = v
            ns.Skin:Set(v)
        end)
    end
    L:Hint("切换后立即生效，不需要重载界面。")
    L:Heading("显示")
    L:Check("显示小地图按钮", function() return O().ui.showMinimap end, function(v)
        O().ui.showMinimap = v
        ns.Events:Fire("RW_MINIMAP_OPTION")
    end)
    L:Check("没有拍卖时显示\"待拍\"按钮（团长、助理）", function() return O().auction.showPendingButton end, function(v)
        O().auction.showPendingButton = v
        ns.Events:Fire("RW_AUCTION_OPTION")
    end)
    L:Slider("窗口缩放", 80, 130, 5, function() return math.floor((ns.DB.char.mainScale or 1) * 100 + 0.5) end,
        function(v) ns.Main:SetScale(v / 100) end, "%d%%")
    L:Button("重置所有窗口位置", function()
        ns.DB.char.frames = {}
        ns.Events:Fire("RW_RESET_POSITIONS")
        ns.Print("所有窗口位置已重置")
    end)
end)

------------------------------------------------------------------------
-- 分类：许愿规则
------------------------------------------------------------------------

Settings:AddCategory("rules", "许愿规则", 20, function(_, L)
    L:Heading("录入")
    L:Check("仅xy模式", function() return O().xyOnly end, function(v) O().xyOnly = v end)
    L:Hint("开启后只认 xy 或 txy 开头的消息；关闭时直接贴物品链接也算许愿。")
    L:Check("有人贴装备、或许愿撞车时自动通报", function() return O().autoAnnounce end, function(v) O().autoAnnounce = v end)
    L:InputRow("默认分数", 60, function() return O().defaultDkp end, function(text, e)
        local n = tonumber(text)
        if n then O().defaultDkp = n else e:SetText(tostring(O().defaultDkp)) end
    end)
    L:InputRow("每人最多许愿件数", 60, function() return O().maxWishItems end, function(text, e)
        local n = tonumber(text)
        if n and n >= 0 and n == math.floor(n) then O().maxWishItems = n else e:SetText(tostring(O().maxWishItems)) end
    end)
    L:Hint("一条许愿里超过这个件数时，只记前几件。填 0 表示不限。")
    L:Heading("自动扣分")
    L:Check("自动扣分", function() return O().autoDeduct end, function(v) O().autoDeduct = v end)
    L:Check("紫色装备自动扣分", function() return O().purpleMode end, function(v) O().purpleMode = v end)
    L:Check("蓝色装备自动扣分", function() return O().blueMode end, function(v) O().blueMode = v end)
    L:Check("绿色装备自动扣分", function() return O().greenMode end, function(v) O().greenMode = v end)
    L:Hint("拾取前 60 秒内在团队频道出过分的人，拾取以上品质的装备时按出分自动扣分。")
    L:Heading("退团时清空")
    L:Radio("弹窗询问", "ask", function() return O().clearOnLeaveMode end, function(v) O().clearOnLeaveMode = v end)
    L:Radio("直接清空", "clear", function() return O().clearOnLeaveMode end, function(v) O().clearOnLeaveMode = v end)
end)

------------------------------------------------------------------------
-- 分类：开团公告与宣言
------------------------------------------------------------------------

Settings:AddCategory("texts", "开团公告与宣言", 30, function(_, L)
    local function editor(title, get, save, default)
        L:Heading(title)
        local ml = L:MultiLine(96)
        ml.edit:SetText(get())
        L:Buttons({
            { "保存", function()
                save(ml.edit:GetText())
                ns.Print(title .. "已保存")
            end },
            { "恢复默认", function()
                save(nil)
                ml.edit:SetText(default)
            end, "ghost" },
        })
        L.refreshers[#L.refreshers + 1] = { Refresh = function() ml.edit:SetText(get()) end }
    end
    editor("开团公告", function() return ns.DB:GetStartText() end,
        function(t) O().startText = (t and t ~= "") and t or nil end, ns.DB.DEFAULT_START_TEXT)
    editor("团队宣言", function() return ns.DB:GetDeclaration() end,
        function(t) O().declaration = (t and t ~= "") and t or nil end, ns.DB.DEFAULT_DECLARATION)
end)

------------------------------------------------------------------------
-- 分类：数据
------------------------------------------------------------------------

Settings:AddCategory("data", "数据", 80, function(_, L)
    local WC = ns.WishChat
    L:Heading("分数")
    L:Action("全团初始分数", "把团里每个人的分数设成同一个值，并在团队频道通报", "设置", function()
        if not ns.Wish:IsLeader() then ns.Print("只有许愿团长可以设置全团初始分数") return end
        W.Prompt("INIT_DKP", "设置全团初始分数：", O().defaultDkp, function(text)
            if not WC:InitScores(tonumber(text)) then ns.Print("请输入数字") end
        end)
    end)
    L:Space(12)

    L:Heading("备份与恢复")
    L:Action("导出许愿表", "生成名单和一段备份码，复制保存到游戏外", "导出", function() ns.Restore:ShowExport() end)
    L:Action("导入备份", "粘贴之前导出的备份码，恢复许愿表和掉落", "导入", function() ns.Restore:ShowImport() end)
    L:Action("从团员恢复", "向团员要回最新的许愿表（团长崩溃重登后用）", "恢复", function() ns.Restore:FromMembers() end)
    L:Action("快照", "查看最近一次自动快照，并可用它恢复", "查看", function()
        if ns.Restore and ns.Restore.ShowSnapshot then ns.Restore:ShowSnapshot() else ns.Print("快照功能尚未就绪") end
    end)
    L:Space(6)
    L:Check("自动快照（许愿表或分数变化后自动存一份）", function() return O().autoBackup end, function(v) O().autoBackup = v end)
    L:Space(12)

    L:Heading("危险操作")
    L:Action("清空许愿表", "清空所有人的许愿和分数并同步全团，建议先导出", "清空", function()
        W.Confirm("RESET", "确定要清空所有人的许愿和分数吗？此操作会同步给全团。", function() WC:ClearAll() end,
            { danger = true, okText = "清空" })
    end, "danger")
end)

------------------------------------------------------------------------
-- 分类：关于（版本、开源声明、联系作者）
------------------------------------------------------------------------

Settings.CONTACT = "dean.addon.wow@proton.me"

-- 只读、可全选复制的一行文字
local function CopyBox(container, L, text, width)
    local e = W.Input(container, width or 260, 26)
    e:SetPoint("TOPLEFT", container, "TOPLEFT", L.x + 24, L.y)
    e:SetText(text)
    e:HookScript("OnEditFocusGained", function(self) self:HighlightText() end)
    e:HookScript("OnMouseUp", function(self) self:SetFocus() self:HighlightText() end)
    e:HookScript("OnTextChanged", function(self, user) if user then self:SetText(text) self:HighlightText() end end)
    L.y = L.y - 32
    return e
end

Settings:AddCategory("about", "关于", 90, function(container, L)
    L:Heading("许愿助手 RaidWish")
    local pack = ns.Voice and ns.Voice:Pack()
    local voiceBy = (pack and pack.author and pack.author ~= "") and ("　·　配音 " .. pack.author) or ""
    L:Hint("版本 " .. ns.VERSION .. "　·　作者 迪恩温彻斯特、秋枫" .. voiceBy)
    L:Hint("团队许愿、分数、掉落记录与拍卖。团队频道输入 xy 加物品链接即可许愿。")
    L:Space(8)

    L:Heading("开源声明")
    L:Hint("本插件以 MIT 许可证开源，免费使用。你可以自由使用、复制、修改和分发，"
        .. "但须保留原作者署名和许可声明。")
    L:Hint("本插件按\"原样\"提供，不附带任何形式的担保；因使用本插件造成的任何损失，作者不承担责任。")
    L:Hint("本插件为玩家个人作品，与暴雪娱乐、网易公司无关。")
    L:Space(8)

    L:Heading("联系作者")
    L:Hint("发现问题或有建议，请发邮件给作者。最好附上截图、操作步骤，以及下面的\"出错信息\"。")
    CopyBox(container, L, Settings.CONTACT)
    L:Hint("点一下邮箱即可全选，按 Ctrl+C 复制。")
    L:Action("出错信息", "插件最近记录的出错信息，反馈问题时一起发给作者", "查看", function()
        local list = ns.DB.main.errors
        local text
        if type(list) ~= "table" or #list == 0 then
            text = "没有出错记录。"
        else
            text = "RaidWish " .. ns.VERSION .. "\n\n" .. table.concat(list, "\n\n")
        end
        W.TextDialog("出错信息", text, nil, nil, "点\"复制\"后按 Ctrl+C，粘贴到邮件里发给作者")
    end)
end)

