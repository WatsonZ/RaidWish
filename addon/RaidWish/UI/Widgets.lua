-- UI/Widgets.lua：公共构件。外观一律通过 ns.Skin 绘制。
-- 除本文件和 Skin.lua 外，界面文件里不出现模板名、贴图路径或颜色值。
local ADDON, ns = ...

local W = {}
ns.Widgets = W

local Skin = ns.Skin

local FONT = STANDARD_TEXT_FONT or "Fonts\\ARKai_T.ttf"
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

W.Debounce = ns.Debounce

-- 插件图标"许愿星"（小地图按钮、关于页）
function W.ApplyIcon(tex)
    tex:SetTexture(W.Textures.minimapIcon)
    tex:SetTexCoord(0, 1, 0, 1)
end

-- 其他界面文件用到的贴图集中在这里
W.Textures = {
    minimapIcon = "Interface\\AddOns\\" .. ADDON .. "\\Images\\MinimapButton",   -- 插件自带的"许愿星"
    minimapBorder = "Interface\\Minimap\\MiniMap-TrackingBorder",
    minimapHighlight = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight",
}

------------------------------------------------------------------------
-- 文字
------------------------------------------------------------------------

-- 带角色色的文字。role：text / dim / title / accent / ok / warn / bad / star
function W.Text(parent, role, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(FONT, size or 13, "")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    Skin:Apply(fs, "text", role or "text")
    return fs
end

-- 改文字的角色色（会登记，换皮肤时保持）
function W.SetRole(fs, role)
    Skin:Apply(fs, "text", role)
end

-- 职业色、品质色不属于皮肤
function W.SetClassColor(fs, class)
    local r, g, b = ns.Util.ClassColor(class)
    Skin.registry[fs] = nil
    fs:SetTextColor(r, g, b)
end

local FALLBACK_QUALITY = {
    [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 },
    [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 }, [6] = { 0.9, 0.8, 0.5 },
}

function W.QualityColor(q)
    q = tonumber(q)
    if q and C_Item and C_Item.GetItemQualityColor then
        local ok, r, g, b = pcall(C_Item.GetItemQualityColor, q)
        if ok and r then return r, g, b end
    end
    if q and type(ITEM_QUALITY_COLORS) == "table" and ITEM_QUALITY_COLORS[q] then
        local c = ITEM_QUALITY_COLORS[q]
        return c.r, c.g, c.b
    end
    local c = FALLBACK_QUALITY[q or 1] or FALLBACK_QUALITY[1]
    return c[1], c[2], c[3]
end

function W.SetQualityColor(fs, q)
    Skin.registry[fs] = nil
    fs:SetTextColor(W.QualityColor(q))
end

------------------------------------------------------------------------
-- 鼠标悬停（皮肤提供 _skinHover）
------------------------------------------------------------------------

local function HookHover(w)
    w:HookScript("OnEnter", function(self)
        self._hovered = true
        if self._skinHover then self._skinHover(true) end
    end)
    w:HookScript("OnLeave", function(self)
        self._hovered = false
        if self._skinHover then self._skinHover(false) end
    end)
end

-- 简单的文字提示：用插件自己的皮肤画（和窗口风格一致）；物品提示仍用游戏的 GameTooltip
local tip
local function EnsureTip()
    if tip then return tip end
    tip = CreateFrame("Frame", "RaidWishTooltip", UIParent)
    tip:SetFrameStrata("TOOLTIP")
    tip:SetClampedToScreen(true)
    tip:EnableMouse(false)
    Skin:Apply(tip, "panel")
    tip.title = W.Text(tip, "title", 13)
    tip.title:SetPoint("TOPLEFT", 10, -9)
    tip.title:SetJustifyH("LEFT")
    tip.body = W.Text(tip, "dim", 12)
    tip.body:SetPoint("TOPLEFT", tip.title, "BOTTOMLEFT", 0, -5)
    tip.body:SetJustifyH("LEFT")
    tip.body:SetWordWrap(true)
    tip:Hide()
    return tip
end

function W.ShowTip(owner, title, text)
    local t = EnsureTip()
    t.title:SetText(title or "")
    t.body:SetText(text or "")
    t.body:SetShown(text ~= nil and text ~= "")
    t.body:SetWidth(240)
    local w = math.max(t.title:GetStringWidth(), text and math.min(240, t.body:GetStringWidth()) or 0)
    t.body:SetWidth(math.max(w, 40))
    local h = 18 + (t.title:GetStringHeight() or 14)
    if text and text ~= "" then h = h + 5 + (t.body:GetStringHeight() or 14) end
    t:SetSize(w + 20, h)
    t:ClearAllPoints()
    t:SetPoint("BOTTOMLEFT", owner, "TOPRIGHT", 4, 2)
    t:Show()
end

function W.HideTip() if tip then tip:Hide() end end

function W.Tooltip(w, title, text)
    w:HookScript("OnEnter", function(self) W.ShowTip(self, title, text) end)
    w:HookScript("OnLeave", W.HideTip)
end

------------------------------------------------------------------------
-- 面板（标题栏、关闭按钮、拖动、位置保存、限制在屏幕内、缩放）
------------------------------------------------------------------------

local function SavePosition(f)
    if not f._saveKey or not ns.DB.char then return end
    local point, _, relPoint, x, y = f:GetPoint(1)
    ns.DB.char.frames[f._saveKey] = { point = point, relPoint = relPoint, x = x, y = y }
end

function W.RestorePosition(f)
    f:ClearAllPoints()
    local p = f._saveKey and ns.DB.char and ns.DB.char.frames[f._saveKey]
    if p and p.point then
        f:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
    else
        f:SetPoint(unpack(f._defaultPoint or { "CENTER" }))
    end
end

-- opts：name（全局名，主窗口需要以支持 Esc）、width、height、title、saveKey、defaultPoint、
--       closeKind（"close" 关闭 / "collapse" 收起 / nil 无）、onClose、strata
function W.Panel(opts)
    local f = CreateFrame("Frame", opts.name, UIParent)
    f:SetSize(opts.width or 300, opts.height or 200)
    f:SetFrameStrata(opts.strata or "MEDIUM")
    -- 置顶：点击或打开时整体抬到同层其他窗口之上，避免和别的插件窗口互相穿插
    f:SetToplevel(true)
    f:HookScript("OnShow", function(self) self:Raise() end)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f._saveKey = opts.saveKey
    f._defaultPoint = opts.defaultPoint
    Skin:Apply(f, "panel")

    local head = CreateFrame("Frame", nil, f)
    head:SetPoint("TOPLEFT", 1, -1)
    head:SetPoint("TOPRIGHT", -1, -1)
    head:SetHeight(opts.headerHeight or 34)
    head:EnableMouse(true)
    head:RegisterForDrag("LeftButton")
    head:SetScript("OnDragStart", function() f:StartMoving() end)
    head:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        SavePosition(f)
    end)
    Skin:Apply(head, "header")
    f.head = head

    local title = W.Text(head, "title", 14)
    title:SetPoint("LEFT", 12, 0)
    title:SetText(opts.title or "")
    f.title = title

    if opts.closeKind then
        local close = W.GlyphButton(head, opts.closeKind == "collapse" and "minus" or "close", 20, 20, function()
            if opts.onClose then opts.onClose(f) else f:Hide() end
        end)
        close:SetPoint("RIGHT", -8, 0)
        f.close = close
    end

    W.RestorePosition(f)
    return f
end

------------------------------------------------------------------------
-- 线条符号：界面字体缺 × ▼ − 等字符（显示成方框），改用贴图线条画
-- kind：close（×）/ minus / plus / down（∨）；size 为边长
------------------------------------------------------------------------

function W.Glyph(parent, kind, size, role)
    size = size or 10
    local g = CreateFrame("Frame", nil, parent)
    g:SetSize(size, size)
    g:EnableMouse(false)
    g._lines = {}
    local function Line(len, x, y, deg)
        local t = g:CreateTexture(nil, "OVERLAY")
        t:SetSize(len, 1.5)
        t:SetPoint("CENTER", g, "CENTER", x, y)
        if deg ~= 0 then t:SetRotation(math.rad(deg)) end
        g._lines[#g._lines + 1] = t
    end
    if kind == "close" then
        Line(size * 1.2, 0, 0, 45); Line(size * 1.2, 0, 0, -45)
    elseif kind == "minus" then
        Line(size, 0, 0, 0)
    elseif kind == "plus" then
        Line(size, 0, 0, 0); Line(size, 0, 0, 90)
    elseif kind == "down" then
        local arm = size * 0.6
        local d = arm * 0.35
        Line(arm, -d, 0, -45); Line(arm, d, 0, 45)
    end
    Skin:Apply(g, "glyph", role or "text")
    return g
end

-- 按钮上放一个线条符号（按钮文字留空）
function W.GlyphButton(parent, kind, width, height, onClick, variant)
    local b = W.Button(parent, "", variant or "normal", width, height, onClick)
    b.glyph = W.Glyph(b, kind, math.floor(math.min(width, height) * 0.45))
    b.glyph:SetPoint("CENTER")
    return b
end

------------------------------------------------------------------------
-- 按钮
------------------------------------------------------------------------

-- variant：normal / ghost；size：nil 为 26 高，"sm" 为 22 高
function W.Button(parent, text, variant, width, height, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(type(width) == "number" and width or 80, height or 26)    -- "auto" 在下面按文字算
    local fs = b:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, (height and height <= 22) and 12 or 13, "")
    fs:SetPoint("CENTER")
    b:SetFontString(fs)
    b:SetText(text or "")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    HookHover(b)
    Skin:Apply(b, "button", variant or "normal")
    if onClick then b:SetScript("OnClick", onClick) end
    -- 宽度随文字：width 为 "auto" 时
    if width == "auto" then b:SetWidth(math.max(40, fs:GetStringWidth() + 28)) end
    function b:SetEnabledState(on)
        if on then self:Enable() else self:Disable() end
        self:SetAlpha(on and 1 or (self._skinDisabledAlpha or 0.5))
    end
    return b
end

-- 按文字重新计算宽度
function W.FitButton(b, minWidth)
    b:SetWidth(math.max(minWidth or 40, b:GetFontString():GetStringWidth() + 28))
end

------------------------------------------------------------------------
-- 分隔线、区块
------------------------------------------------------------------------

function W.Divider(parent, vertical)
    local d = CreateFrame("Frame", nil, parent)
    if vertical then d:SetWidth(1) else d:SetHeight(1) end
    Skin:Apply(d, "divider")
    return d
end

-- kind：box（底色 + 边框）/ band（只有底色）
function W.Box(parent, kind)
    local b = CreateFrame("Frame", nil, parent)
    Skin:Apply(b, kind or "box")
    return b
end

-- 状态圆点
function W.Dot(parent, size)
    local d = CreateFrame("Frame", nil, parent)
    d:SetSize(size or 8, size or 8)
    -- state：ok 绿 / warn 黄 / off 灰
    function d:SetState(state) Skin:Apply(self, "dot", state) end
    d:SetState("off")
    return d
end

------------------------------------------------------------------------
-- 标签页
------------------------------------------------------------------------

-- items：{ { key=, text= }... }；onSelect(key)
function W.Tabs(parent, items, onSelect)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(31)
    bar.tabs = {}
    local x = 12
    for _, it in ipairs(items) do
        local t = CreateFrame("Button", nil, bar)
        local fs = t:CreateFontString(nil, "OVERLAY")
        fs:SetFont(FONT, 13, "")
        fs:SetPoint("CENTER")
        t:SetFontString(fs)
        t:SetText(it.text)
        t:SetSize(fs:GetStringWidth() + 32, 30)
        t:SetPoint("BOTTOMLEFT", x, 0)
        x = x + t:GetWidth() + 2
        t.key = it.key
        HookHover(t)
        t:SetScript("OnClick", function() bar:Select(it.key) end)
        bar.tabs[#bar.tabs + 1] = t
        Skin:Apply(t, "tab", false)
    end
    function bar:Select(key)
        self.selected = key
        for _, t in ipairs(self.tabs) do Skin:Apply(t, "tab", t.key == key) end
        if onSelect then onSelect(key) end
    end
    return bar
end

------------------------------------------------------------------------
-- 输入框
------------------------------------------------------------------------

function W.Input(parent, width, height, placeholder)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetSize(width or 170, height or 26)
    e:SetFont(FONT, 13, "")
    e:SetAutoFocus(false)
    e:SetTextInsets(8, 8, 0, 0)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    if placeholder then
        local ph = e:CreateFontString(nil, "OVERLAY")
        ph:SetFont(FONT, 13, "")
        ph:SetPoint("LEFT", 8, 0)
        ph:SetText(placeholder)
        e._placeholder = ph
        e:HookScript("OnTextChanged", function(self) ph:SetShown(self:GetText() == "") end)
        e:HookScript("OnEditFocusGained", function() ph:Hide() end)
        e:HookScript("OnEditFocusLost", function(self) ph:SetShown(self:GetText() == "") end)
    end
    Skin:Apply(e, "input")
    return e
end

-- 多行编辑框：返回外框；外框.edit 是编辑框
function W.MultiLine(parent, width, height)
    local box = CreateFrame("Frame", nil, parent)
    box:SetSize(width, height)
    local sf = CreateFrame("ScrollFrame", nil, box)
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -6, 6)
    local e = CreateFrame("EditBox", nil, sf)
    e:SetMultiLine(true)
    e:SetAutoFocus(false)
    e:SetMaxLetters(0)          -- 不限长度（备份码可能很长）
    e:SetFont(FONT, 13, "")
    e:SetWidth(width - 12)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    e:SetScript("OnCursorChanged", function(_, _, y, _, h)
        local top = sf:GetVerticalScroll()
        local bottom = top + sf:GetHeight()
        if -y < top then sf:SetVerticalScroll(-y) elseif -y + h > bottom then sf:SetVerticalScroll(-y + h - sf:GetHeight()) end
    end)
    sf:SetScrollChild(e)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, d)
        local v = math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - d * 40))
        self:SetVerticalScroll(v)
    end)
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() e:SetFocus() end)
    box.edit = e
    -- 外框画成输入框的样子
    Skin.registry[box] = nil
    box.SetTextColor = function(_, r, g, b) e:SetTextColor(r, g, b) end
    Skin:Apply(box, "input")
    return box
end

------------------------------------------------------------------------
-- 勾选框、单选
------------------------------------------------------------------------

local function MakeToggle(parent, label, round, get, set)
    local w = CreateFrame("Button", nil, parent)
    w:SetHeight(24)
    local box = CreateFrame("Frame", nil, w)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", 0, 0)
    w._box = box
    local fs = W.Text(w, "text", 13)
    fs:SetPoint("LEFT", box, "RIGHT", 8, 0)
    fs:SetText(label)
    w._label = fs
    w:SetWidth(fs:GetStringWidth() + 28)
    w._refresh = function()
        if w._mark then w._mark:SetShown(get() and true or false) end
    end
    w:SetScript("OnClick", function()
        set(not get())
        w._refresh()
    end)
    Skin:Apply(w, "check", round)
    w._refresh()
    function w:Refresh() self._refresh() end
    function w:SetEnabledState(on)
        if on then self:Enable() else self:Disable() end
        self:SetAlpha(on and 1 or 0.45)
    end
    return w
end

-- get() 返回当前值；set(v) 写入
function W.Check(parent, label, get, set)
    return MakeToggle(parent, label, false, get, set)
end

-- 单选：get() 返回当前选中的值；set(value)
function W.Radio(parent, label, value, get, set)
    return MakeToggle(parent, label, true, function() return get() == value end, function() set(value) end)
end

------------------------------------------------------------------------
-- 滑块
------------------------------------------------------------------------

function W.Slider(parent, label, minV, maxV, step, get, set, fmt)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(320, 24)
    local fs = W.Text(holder, "text", 13)
    fs:SetPoint("LEFT")
    fs:SetText(label)
    local s = CreateFrame("Slider", nil, holder)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(140, 16)
    s:SetPoint("LEFT", fs, "RIGHT", 12, 0)
    s:SetThumbTexture(s:CreateTexture(nil, "OVERLAY"))
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step or 1)
    s:SetObeyStepOnDrag(true)
    local val = W.Text(holder, "dim", 12)
    val:SetPoint("LEFT", s, "RIGHT", 10, 0)
    s._label, s._valueText = fs, val
    local function show(v) val:SetText((fmt or "%d"):format(v)) end
    s:SetValue(get())
    show(get())
    s:SetScript("OnValueChanged", function(_, v, user)
        show(v)
        if user then set(v) end
    end)
    Skin:Apply(s, "slider")
    holder.slider = s
    function holder:Refresh()
        s:SetValue(get())
        show(get())
    end
    return holder
end

------------------------------------------------------------------------
-- 进度条
------------------------------------------------------------------------

function W.Progress(parent, height)
    local p = CreateFrame("Frame", nil, parent)
    p:SetHeight(height or 6)
    local fill = p:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", 1, 1)
    fill:SetWidth(1)
    p._fill = fill
    p._value = 0
    function p:SetValue(v)
        v = math.max(0, math.min(1, tonumber(v) or 0))
        self._value = v
        local w = (self:GetWidth() - 2) * v
        if w < 1 then fill:Hide() else fill:Show(); fill:SetWidth(w) end
    end
    p:SetScript("OnSizeChanged", function(self) self:SetValue(self._value) end)
    Skin:Apply(p, "progress")
    return p
end

------------------------------------------------------------------------
-- 下拉 / 右键菜单（MenuUtil；不可用时用简易菜单）
-- build(root)：root:Button(text, fn) → 子菜单节点；root:Title(text)；root:Divider()
------------------------------------------------------------------------

local function WrapDesc(desc)
    local node = {}
    -- 置灰（例如战斗中的"保存"）
    function node.Disable(_) if desc.SetEnabled then desc:SetEnabled(false) end end
    function node.Button(_, text, fn)
        local b = desc:CreateButton(text, fn and function() fn() end or nil)
        return WrapDesc(b)
    end
    function node.Title(_, text) desc:CreateTitle(text) end
    function node.Divider(_) desc:CreateDivider() end
    return node
end

-- 扁平风格菜单：和窗口同一套皮肤。子菜单展开成缩进的一组（父项作为小标题）。
-- 点菜单外任意处、按 Esc 或选中一项后关闭。
local flatMenu, menuCatcher
local MENU_ROW, MENU_PAD = 24, 6

local function EnsureFlatMenu()
    if flatMenu then return flatMenu end
    -- 全屏透明层：点菜单以外的地方关闭菜单
    menuCatcher = CreateFrame("Button", nil, UIParent)
    menuCatcher:SetAllPoints(UIParent)
    menuCatcher:SetFrameStrata("FULLSCREEN")
    menuCatcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    menuCatcher:Hide()

    flatMenu = CreateFrame("Frame", "RaidWishMenu", UIParent)
    flatMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    flatMenu:SetClampedToScreen(true)
    flatMenu:EnableMouse(true)
    flatMenu.rows = {}
    Skin:Apply(flatMenu, "panel")
    flatMenu:SetScript("OnHide", function() menuCatcher:Hide() end)
    menuCatcher:SetScript("OnClick", function() flatMenu:Hide() end)
    if UISpecialFrames then table.insert(UISpecialFrames, "RaidWishMenu") end   -- Esc 关闭
    return flatMenu
end

local function MenuRow(m, i)
    local r = m.rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, m)
    r:SetHeight(MENU_ROW)
    r.button = W.Button(r, "", "item", 160, MENU_ROW)
    r.button:SetAllPoints()
    local fs = r.button:GetFontString()
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", 10, 0)
    r.title = W.Text(r, "dim", 12)
    r.title:SetPoint("LEFT", 10, 0)
    r.line = W.Divider(r)
    r.line:SetPoint("LEFT", 4, 0)
    r.line:SetPoint("RIGHT", -4, 0)
    m.rows[i] = r
    return r
end

local function FlatMenu(owner, build)
    local items = {}
    local function collect(depth)
        local node = {}
        function node.Button(_, text, fn)
            local it = { text = text, fn = fn, depth = depth }
            items[#items + 1] = it
            local child = collect(depth + 1)
            child._parent = it
            function child.Disable(_) it.disabled = true end
            return child
        end
        function node.Title(_, text) items[#items + 1] = { text = text, title = true, depth = depth } end
        function node.Divider(_) items[#items + 1] = { divider = true, depth = depth } end
        return node
    end
    build(collect(0))
    -- 有子项的按钮当作小标题显示
    for i, it in ipairs(items) do
        local nxt = items[i + 1]
        if not it.title and not it.divider and nxt and nxt.depth > it.depth then it.header = true end
    end

    local m = EnsureFlatMenu()
    for _, r in ipairs(m.rows) do r:Hide() end
    local y, width = -MENU_PAD, 140
    for i, it in ipairs(items) do
        local r = MenuRow(m, i)
        r.item = it
        local indent = (it.depth or 0) * 14
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", MENU_PAD, y)
        r:SetPoint("RIGHT", m, "RIGHT", -MENU_PAD, 0)
        r.button:SetShown(not it.divider and not it.title and not it.header)
        r.title:SetShown(it.title or it.header or false)
        r.line:SetShown(it.divider or false)
        local h = MENU_ROW
        if it.divider then
            h = 9
        elseif it.title or it.header then
            r.title:SetText(it.text)
            r.title:SetPoint("LEFT", 10 + indent, 0)
            width = math.max(width, r.title:GetStringWidth() + 24 + indent)
        else
            r.button:SetText(it.text)
            r.button:GetFontString():SetPoint("LEFT", 10 + indent, 0)
            local enabled = it.fn ~= nil and not it.disabled
            r.button:SetEnabledState(enabled)
            r.button:SetScript("OnClick", function()
                m:Hide()
                if enabled then it.fn() end
            end)
            width = math.max(width, r.button:GetFontString():GetStringWidth() + 28 + indent)
        end
        r:SetHeight(h)
        r:Show()
        y = y - h
    end
    m:SetSize(width + MENU_PAD * 2, -y + MENU_PAD)
    m:ClearAllPoints()
    -- 按钮在屏幕右半边时右对齐，避免菜单伸出窗口
    local cx = owner.GetCenter and owner:GetCenter()
    local sw = UIParent.GetWidth and UIParent:GetWidth()
    if cx and sw and cx > sw / 2 then
        m:SetPoint("TOPRIGHT", owner, "BOTTOMRIGHT", 0, -2)
    else
        m:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    end
    menuCatcher:Show()
    m:Show()
    m:Raise()
end

-- 暴雪原生皮肤用游戏自带菜单（MenuUtil）；扁平暗色或 MenuUtil 不可用时用扁平菜单
function W.Menu(owner, build)
    if ns.Skin.current == "blizz" and MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(owner, function(_, root) build(WrapDesc(root)) end)
    else
        FlatMenu(owner, build)
    end
end

------------------------------------------------------------------------
-- 职业圆标、物品单元、角标
------------------------------------------------------------------------

function W.ClassBadge(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(22, 22)
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetAllPoints()
    local okMask = pcall(function()
        local mask = f:CreateMaskTexture()
        mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints()
        t:AddMaskTexture(mask)
    end)
    if not okMask then ns.Debug("圆形遮罩不可用，职业标显示为方形") end
    local fs = f:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, 11, "")
    fs:SetPoint("CENTER", 0, 0)
    fs:SetTextColor(0.07, 0.07, 0.07)
    function f:SetClass(class)
        local token = ns.Util.NormClass(class)
        local r, g, b = ns.Util.ClassColor(token)
        t:SetColorTexture(r, g, b, 1)
        fs:SetText(token and ns.Util.CLASS_SHORT_ZH[token] or "?")
    end
    return f
end

function W.Badge(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(18, 15)
    local fs = f:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, 11, "")
    fs:SetPoint("CENTER")
    f._text = fs
    function f:SetValue(n)
        fs:SetText(tostring(n))
        self:SetWidth(math.max(18, fs:GetStringWidth() + 10))
    end
    Skin:Apply(f, "badge")
    return f
end

-- 物品单元：图标 + 品质色名字（不带中括号），完成时变淡并加删除线，可带重复人数角标。
-- 有物品编号时悬停显示装备提示；只有名字时显示问号图标与白色名字。
function W.ItemCell(parent, iconSize, fontSize)
    local f = CreateFrame("Button", nil, parent)
    iconSize = iconSize or 22
    f:SetHeight(iconSize)
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(iconSize, iconSize)
    icon:SetPoint("LEFT")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local name = f:CreateFontString(nil, "OVERLAY")
    name:SetFont(FONT, fontSize or 13, "")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetWordWrap(false)
    local strike = f:CreateTexture(nil, "OVERLAY", nil, 2)
    strike:SetHeight(1)
    strike:SetPoint("LEFT", name, "LEFT", 0, 0)
    strike:SetPoint("RIGHT", name, "RIGHT", 0, 0)
    local badge = W.Badge(f)
    badge:SetPoint("LEFT", name, "RIGHT", 4, 0)
    f.icon, f.name, f.badge = icon, name, badge

    local function Layout()
        local w = iconSize + 6 + name:GetStringWidth()
        if badge:IsShown() then w = w + 4 + badge:GetWidth() end
        f:SetWidth(w)
    end

    function f:SetItem(item, dupCount)
        self.item = item
        local q
        if item.floor then
            icon:SetTexture(QUESTION_ICON)
            name:SetText(item.name or "地板")
        elseif item.id then
            local info = ns.Items.GetCached(item.id)
            icon:SetTexture((info and info.icon) or ns.Compat.GetItemIcon(item.id) or QUESTION_ICON)
            name:SetText((info and info.name) or item.name or ("物品 " .. item.id))
            q = info and info.quality
            if not info and self._waitId ~= item.id then
                -- 名字后到时刷新；同一件物品只登记一次，避免反复刷新时回调越积越多
                self._waitId = item.id
                ns.Items.Get(item.id, function(i)
                    if self._waitId == item.id then self._waitId = nil end
                    if i and self.item and self.item.id == item.id then self:SetItem(self.item, dupCount) end
                end)
            end
        else
            icon:SetTexture(QUESTION_ICON)
            name:SetText(item.name or "?")
        end
        if q then name:SetTextColor(W.QualityColor(q)) else name:SetTextColor(1, 1, 1) end
        local r, g, b = name:GetTextColor()
        strike:SetColorTexture(r, g, b, 0.9)
        strike:SetShown(item.done and true or false)
        self:SetAlpha(item.done and 0.4 or 1)
        if dupCount and dupCount >= 2 then
            badge:SetValue(dupCount)
            badge:Show()
        else
            badge:Hide()
        end
        Layout()
    end

    f:SetScript("OnEnter", function(self)
        local it = self.item
        if not it then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if it.id then
            GameTooltip:SetHyperlink(ns.Items.Hyperlink(it.id))
        else
            GameTooltip:SetText(it.name or "?", 1, 1, 1)
            if not it.floor then GameTooltip:AddLine("手打的物品名，没有物品链接", 0.6, 0.6, 0.6) end
        end
        GameTooltip:Show()
        if self:GetParent() and self:GetParent()._skinHover then self:GetParent()._skinHover(true) end
    end)
    f:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if self:GetParent() and self:GetParent()._skinHover then self:GetParent()._skinHover(false) end
    end)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:SetScript("OnClick", function(self, button)
        -- 点击物品时把点击交给所在的行（右键菜单），Shift 点击插入聊天链接
        if IsShiftKeyDown() and self.item and self.item.id then
            local info = ns.Items.GetCached(self.item.id)
            if info and info.link and ChatEdit_InsertLink then ChatEdit_InsertLink(info.link) end
            return
        end
        local row = self._row
        if row and row:GetScript("OnClick") then row:GetScript("OnClick")(row, button) end
    end)
    return f
end

------------------------------------------------------------------------
-- 列表（虚拟滚动：只建可见行数的行，数据不限条数）
-- opts：rowHeight、createRow(row)、updateRow(row, data, index)
------------------------------------------------------------------------

function W.List(parent, opts)
    local list = CreateFrame("Frame", nil, parent)
    list:SetClipsChildren(true)
    local rh = opts.rowHeight or 36
    list.rows, list.data, list.offset = {}, {}, 0

    local bar = CreateFrame("Frame", nil, list)
    bar:SetWidth(8)
    bar:SetPoint("TOPRIGHT", -2, -2)
    bar:SetPoint("BOTTOMRIGHT", -2, 2)
    local thumb = CreateFrame("Frame", nil, bar)
    thumb:SetWidth(8)
    thumb:EnableMouse(true)
    bar._thumb = thumb
    Skin:Apply(bar, "scrollbar")

    local function Visible() return math.max(1, math.floor(list:GetHeight() / rh)) end
    local function MaxOffset() return math.max(0, #list.data - Visible()) end

    local function UpdateBar()
        local total, vis = #list.data, Visible()
        if total <= vis then bar:Hide() return end
        bar:Show()
        local h = bar:GetHeight()
        local th = math.max(20, h * vis / total)
        thumb:SetHeight(th)
        local maxOff = MaxOffset()
        local y = (maxOff > 0) and ((h - th) * list.offset / maxOff) or 0
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", bar, "TOP", 0, -y)
    end

    local function EnsureRows()
        local need = Visible() + 1
        for i = #list.rows + 1, need do
            local row = CreateFrame("Button", nil, list)
            row:SetHeight(rh)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * rh)
            row:SetPoint("TOPRIGHT", 0, -(i - 1) * rh)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            HookHover(row)
            opts.createRow(row)
            list.rows[i] = row
        end
    end

    function list:Refresh()
        EnsureRows()
        self.offset = math.max(0, math.min(self.offset, MaxOffset()))
        for i, row in ipairs(self.rows) do
            local idx = self.offset + i
            local d = self.data[idx]
            if d then
                Skin:Apply(row, "row", idx % 2 == 0)
                row.data, row.index = d, idx
                opts.updateRow(row, d, idx)
                row:Show()
            else
                row.data = nil
                row:Hide()
            end
        end
        UpdateBar()
    end

    function list:SetData(data)
        self.data = data or {}
        self:Refresh()
    end

    function list:Scroll(delta)
        self.offset = self.offset - delta
        self:Refresh()
    end

    function list:RowFor(data)
        for _, row in ipairs(self.rows) do if row:IsShown() and row.data == data then return row end end
    end

    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, d) self:Scroll(d * 3) end)
    list:SetScript("OnSizeChanged", function(self) self:Refresh() end)

    -- 拖动滑块
    thumb:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        local _, startY = GetCursorPosition()
        local startOff = list.offset
        local scale = list:GetEffectiveScale()
        thumb:SetScript("OnUpdate", function()
            local _, y = GetCursorPosition()
            local dy = (startY - y) / scale
            local h = bar:GetHeight() - thumb:GetHeight()
            if h > 0 then
                list.offset = math.floor(startOff + dy / h * MaxOffset() + 0.5)
                list:Refresh()
            end
        end)
    end)
    thumb:SetScript("OnMouseUp", function() thumb:SetScript("OnUpdate", nil) end)

    return list
end

-- 行高亮闪一下（新录入的许愿）
function W.Flash(row, seconds)
    local fl = row._skinTex and row._skinTex.flash
    if not fl then return end
    row._flashing = true
    fl:Show()
    ns.After(seconds or 1.2, function()
        row._flashing = false
        fl:Hide()
    end)
end

------------------------------------------------------------------------
-- 可复制文本窗口（导出）
------------------------------------------------------------------------

local textDialog

-- actionText / onAction(当前文本)：可选的操作按钮（例如"导入"）；hint：底部说明文字
-- 文本窗口。actionText 不为空时是"输入"模式（例如导入）：隐藏"复制"，自动聚焦等待粘贴
function W.TextDialog(title, text, actionText, onAction, hint)
    if not textDialog then
        textDialog = W.Panel({ name = "RaidWishTextDialog", width = 520, height = 380, title = title,
            closeKind = "close", strata = "DIALOG", saveKey = "textDialog" })
        local ml = W.MultiLine(textDialog, 496, 290)
        ml:SetPoint("TOPLEFT", 12, -44)
        textDialog.ml = ml
        -- 插件无法直接写入剪贴板（游戏限制），"复制"会全选文字，再按一下 Ctrl+C 即可
        local sel = W.Button(textDialog, "复制", "primary", 80, 26, function()
            ml.edit:SetFocus()
            ml.edit:HighlightText()
            textDialog.hint:SetText("已全选，请按 Ctrl+C 完成复制")
            W.SetRole(textDialog.hint, "ok")
        end)
        sel:SetPoint("BOTTOMRIGHT", -12, 10)
        textDialog.copy = sel
        local hintText = W.Text(textDialog, "dim", 12)
        hintText:SetPoint("BOTTOMLEFT", 12, 16)
        textDialog.hint = hintText
        local action = W.Button(textDialog, "", "normal", 80, 26)
        action:SetPoint("RIGHT", sel, "LEFT", -8, 0)
        textDialog.action = action
        tinsert(UISpecialFrames, "RaidWishTextDialog")
    end
    textDialog.hint:SetText(hint or "点\"复制\"后按 Ctrl+C")
    W.SetRole(textDialog.hint, "dim")
    if actionText then
        textDialog.action:SetText(actionText)
        textDialog.action:SetScript("OnClick", function() onAction(textDialog.ml.edit:GetText()) end)
        textDialog.action:ClearAllPoints()
        textDialog.action:SetPoint("BOTTOMRIGHT", -12, 10)
        Skin:Apply(textDialog.action, "button", "primary")
        textDialog.action:Show()
        textDialog.copy:Hide()
    else
        textDialog.action:Hide()
        textDialog.copy:Show()
    end
    textDialog.title:SetText(title)
    textDialog.ml.edit:SetText(text or "")
    textDialog.ml.edit:SetCursorPosition(0)
    textDialog:Show()
    textDialog:Raise()
    if actionText then textDialog.ml.edit:SetFocus() end
    return textDialog
end

------------------------------------------------------------------------
-- 确认与输入弹窗：插件自己画（和窗口同一套皮肤），同一时间只显示一个
-- key 用于区分是哪个弹窗（W.lastDialog 记录最近一次的 "RAIDWISH_" .. key）
------------------------------------------------------------------------

local dialog
W.lastDialog = nil

local function SetEscClose(on)
    for i = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[i] == "RaidWishDialog" then table.remove(UISpecialFrames, i) end
    end
    if on then table.insert(UISpecialFrames, "RaidWishDialog") end
end

local function EnsureDialog()
    if dialog then return dialog end
    dialog = W.Panel({ name = "RaidWishDialog", width = 360, height = 150, title = ns.SHORT_TITLE or "许愿助手",
        closeKind = nil, strata = "FULLSCREEN_DIALOG", defaultPoint = { "CENTER", UIParent, "CENTER", 0, 180 } })
    dialog.text = W.Text(dialog, "text", 13)
    dialog.text:SetPoint("TOPLEFT", dialog.head, "BOTTOMLEFT", 18, -16)
    dialog.text:SetWidth(324)
    dialog.text:SetJustifyH("LEFT")
    dialog.text:SetWordWrap(true)
    dialog.edit = W.Input(dialog, 324, 26)
    dialog.edit:SetPoint("TOPLEFT", dialog.text, "BOTTOMLEFT", 0, -10)
    dialog.ok = W.Button(dialog, "确定", "primary", 96, 26)
    dialog.ok:SetPoint("BOTTOMRIGHT", -16, 14)
    dialog.cancel = W.Button(dialog, "取消", "normal", 96, 26)
    dialog.cancel:SetPoint("RIGHT", dialog.ok, "LEFT", -8, 0)
    dialog:SetScript("OnHide", function(self)
        if self._onDismiss then
            local f = self._onDismiss
            self._onDismiss = nil
            f()
        end
    end)
    dialog:Hide()
    return dialog
end

-- opts：okText、cancelText、onOk、onCancel、edit（默认值，有则显示输入框）、danger（确定按钮标红）、
--       noEsc（不能按 Esc 关掉，必须点一个按钮）
local function ShowDialog(key, text, opts)
    local d = EnsureDialog()
    d._onDismiss = nil
    d:Hide()
    W.lastDialog = "RAIDWISH_" .. key
    d.text:SetText(text or "")
    d.ok:SetText(opts.okText or "确定")
    d.cancel:SetText(opts.cancelText or "取消")
    W.FitButton(d.ok, 96)
    W.FitButton(d.cancel, 96)
    Skin:Apply(d.ok, "button", opts.danger and "danger" or "primary")
    Skin:Apply(d.cancel, "button", opts.cancelDanger and "danger" or "normal")
    local hasEdit = opts.edit ~= nil
    d.edit:SetShown(hasEdit)
    local h = 34 + 16 + (d.text:GetStringHeight() or 16) + (hasEdit and 36 or 0) + 18 + 26 + 14
    d:SetHeight(math.max(130, h))
    local function finish(fn, ...)
        d._onDismiss = nil
        d:Hide()
        if fn then fn(...) end
    end
    d.ok:SetScript("OnClick", function()
        if hasEdit then finish(opts.onOk, d.edit:GetText()) else finish(opts.onOk) end
    end)
    d.cancel:SetScript("OnClick", function() finish(opts.onCancel) end)
    if hasEdit then
        d.edit:SetText(tostring(opts.edit))
        d.edit:SetScript("OnEnterPressed", function() d.ok:Click() end)
        d.edit:SetScript("OnEscapePressed", function() d.cancel:Click() end)
    end
    SetEscClose(not opts.noEsc)
    d._onDismiss = (not opts.noEsc) and opts.onCancel or nil        -- 按 Esc 关掉等同"取消"
    d:Show()
    d:Raise()
    if hasEdit then
        d.edit:SetFocus()
        d.edit:HighlightText()
    end
    return d
end

-- 确认框：text 为提示，onAccept 为确定后的回调；opts.danger 为真时确定按钮标红，opts.onCancel 为取消回调
function W.Confirm(key, text, onAccept, opts)
    opts = opts or {}
    return ShowDialog(key, text, { onOk = onAccept, onCancel = opts.onCancel, danger = opts.danger, okText = opts.okText })
end

-- 二选一：必须点一个按钮（不能按 Esc 关掉），onFirst / onSecond 分别对应两个按钮
-- opts.secondDanger：第二个按钮标红（例如"清空"）
function W.Choice(key, text, firstText, secondText, onFirst, onSecond, opts)
    return ShowDialog(key, text, { okText = firstText, cancelText = secondText,
        onOk = onFirst, onCancel = onSecond, noEsc = true, cancelDanger = opts and opts.secondDanger })
end

-- 输入框：onAccept(文本)
function W.Prompt(key, text, default, onAccept)
    return ShowDialog(key, text, { edit = default ~= nil and default or "", onOk = onAccept })
end
