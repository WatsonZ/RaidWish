-- UI/Skin.lua：皮肤定义与切换
-- 每套皮肤提供同一组绘制函数。控件创建时由 Widgets 调用 Skin:Apply 登记并绘制；
-- 切换皮肤时对登记表里的每个控件重新绘制，位置、尺寸、内容、事件处理不变。
-- 颜色取自 docs/界面效果图.html 里 [data-skin=flat] 的 CSS 变量。
local ADDON, ns = ...

local Skin = {
    registry = setmetatable({}, { __mode = "k" }),   -- 控件 → { kind, args }
    skins = {},
    order = {},
    current = "flat",
}
ns.Skin = Skin

------------------------------------------------------------------------
-- 颜色工具
------------------------------------------------------------------------

local function Hex(h, a)
    return {
        tonumber(h:sub(1, 2), 16) / 255,
        tonumber(h:sub(3, 4), 16) / 255,
        tonumber(h:sub(5, 6), 16) / 255,
        a or 1,
    }
end
Skin.Hex = Hex

local function SetTex(tex, c)
    tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    -- 清掉上一套皮肤可能留下的渐变
    if tex.SetGradient and CreateColor then
        pcall(tex.SetGradient, tex, "VERTICAL", CreateColor(1, 1, 1, 1), CreateColor(1, 1, 1, 1))
    end
end

-- 竖向渐变（顶部 top、底部 bottom）；客户端不支持时退回纯色 top
local function SetGradientTex(tex, top, bottom)
    tex:SetColorTexture(1, 1, 1, 1)
    local ok = tex.SetGradient and CreateColor and pcall(tex.SetGradient, tex, "VERTICAL",
        CreateColor(bottom[1], bottom[2], bottom[3], bottom[4] or 1), CreateColor(top[1], top[2], top[3], top[4] or 1))
    if not ok then tex:SetColorTexture(top[1], top[2], top[3], top[4] or 1) end
end

-- 在控件上按 key 取或建一个纹理（每个控件每个 key 只建一次，换皮肤时复用）
local function Tex(w, key, layer, sub)
    w._skinTex = w._skinTex or {}
    local t = w._skinTex[key]
    if not t then
        t = w:CreateTexture(nil, layer or "BACKGROUND", nil, sub or 0)
        w._skinTex[key] = t
    end
    t:Show()
    return t
end
Skin.Tex = Tex

-- 1 像素边框：四条边。inset 为向内的偏移。
local function Border(w, key, c, inset, layer)
    inset = inset or 0
    local edges = {
        { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
        { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false },
    }
    for i, e in ipairs(edges) do
        local t = Tex(w, key .. i, layer or "BORDER")
        t:ClearAllPoints()
        local dx1 = (e[1]:find("LEFT") and inset) or -inset
        local dx2 = (e[2]:find("LEFT") and inset) or -inset
        local dy1 = (e[1]:find("TOP") and -inset) or inset
        local dy2 = (e[2]:find("TOP") and -inset) or inset
        t:SetPoint(e[1], w, e[1], dx1, dy1)
        t:SetPoint(e[2], w, e[2], dx2, dy2)
        if e[3] then t:SetHeight(1) else t:SetWidth(1) end
        SetTex(t, c)
    end
end
Skin.Border = Border

-- 窗口描边画在一个盖在所有子控件上面的透明层上，否则会被标题栏、状态栏等色块盖住
local function Overlay(w)
    local o = w._skinOverlay
    if not o then
        o = CreateFrame("Frame", nil, w)
        o:SetAllPoints(w)
        o:EnableMouse(false)
        w._skinOverlay = o
    end
    o:SetFrameLevel(math.min(w:GetFrameLevel() + 40, 9000))
    return o
end

local function HideTex(w, prefix)
    if not w._skinTex then return end
    for k, t in pairs(w._skinTex) do
        if not prefix or k:sub(1, #prefix) == prefix then t:Hide() end
    end
end
Skin.HideTex = HideTex

------------------------------------------------------------------------
-- 扁平暗色
------------------------------------------------------------------------

local flat = { name = "flat", label = "扁平暗色" }

-- 当前绘制用的调色板：Draw 在调用绘制函数前设为该皮肤的颜色表，
-- 这样第二套皮肤可以复用扁平暗色的绘制函数、只换颜色
local C
flat.c = {
    bg = Hex("16181c"), bg2 = Hex("1d2025"), alt = { 1, 1, 1, 0.025 }, hover = Hex("262b33"),
    line = Hex("2a2e36"), text = Hex("e8e8e8"), dim = Hex("858c96"), title = Hex("ffffff"),
    accent = Hex("4aa3ff"), btn = Hex("272c34"), btnh = Hex("323843"), btnb = Hex("3a404a"),
    btnt = Hex("e8e8e8"), hd = Hex("1d2025"), inp = Hex("0f1114"), inpb = Hex("2c3038"),
    outer = Hex("000000"), inner = Hex("2c3038"),
    ok = Hex("3ddc68"), warn = Hex("ffd100"), off = Hex("858c96"), bad = Hex("ff5555"),
    dup = Hex("ffb020"), dupText = Hex("111111"), star = Hex("ffd100"), flash = { 0.29, 0.64, 1, 0.25 },
    onAccent = Hex("ffffff"), accentDeep = Hex("2a74c9"), accentSoft = { 0.29, 0.64, 1, 0.16 },
}

local function TextColor(fs, c)
    if fs and fs.SetTextColor then fs:SetTextColor(c[1], c[2], c[3], c[4] or 1) end
end

local function HoverOn(w, normal, hover)
    w._skinHover = function(on) SetTex(Tex(w, "bg"), on and hover or normal) end
    w._skinHover(w._hovered)
end

flat.draw = {
    panel = function(w)
        local c = C
        local bg = Tex(w, "bg", "BACKGROUND", -8)
        bg:SetAllPoints()
        SetTex(bg, c.bg)
        local o = Overlay(w)
        Border(o, "outer", c.outer, 0)
        Border(o, "inner", c.inner, 1)
    end,
    header = function(w)
        local c = C
        local bg = Tex(w, "bg", "BACKGROUND", -7)
        bg:SetAllPoints()
        SetTex(bg, c.hd)
        local l = Tex(w, "line", "BORDER")
        l:ClearAllPoints()
        l:SetPoint("BOTTOMLEFT")
        l:SetPoint("BOTTOMRIGHT")
        l:SetHeight(1)
        SetTex(l, c.line)
    end,
    -- 区块：底色 bg2 + 1 像素边框（"当前拍卖"区、分数方块）
    box = function(w)
        local c = C
        local bg = Tex(w, "bg", "BACKGROUND", -6)
        bg:SetAllPoints()
        SetTex(bg, c.bg2)
        Border(w, "b", c.line)
    end,
    -- 次级底色区域（列头、设置页左侧分类栏）
    band = function(w)
        local bg = Tex(w, "bg", "BACKGROUND", -6)
        bg:SetAllPoints()
        SetTex(bg, C.bg2)
    end,
    -- 选中项底色（设置页左侧分类）
    selected = function(w)
        local bg = Tex(w, "bg", "BACKGROUND")
        bg:SetAllPoints()
        SetTex(bg, C.hover)
    end,
    divider = function(w)
        local t = Tex(w, "line", "ARTWORK")
        t:SetAllPoints()
        SetTex(t, C.line)
    end,
    button = function(w, variant)
        local c = C
        local bg = Tex(w, "bg", "BACKGROUND")
        bg:SetAllPoints()
        if variant == "item" then                       -- 菜单项：无边框，悬停高亮
            HoverOn(w, { 0, 0, 0, 0 }, c.hover)
            TextColor(w:GetFontString(), c.text)
        elseif variant == "danger" then                 -- 危险操作：红字红框
            Border(w, "b", c.bad)
            HoverOn(w, { 0, 0, 0, 0 }, c.hover)
            TextColor(w:GetFontString(), c.bad)
        elseif variant == "primary" then                -- 主按钮：强调色实心
            Border(w, "b", c.accentDeep)
            HoverOn(w, c.accentDeep, c.accent)
            TextColor(w:GetFontString(), c.onAccent)
        elseif variant == "chip" then                   -- 筛选标签（未选中）
            Border(w, "b", c.line)
            HoverOn(w, { 0, 0, 0, 0 }, c.hover)
            TextColor(w:GetFontString(), c.dim)
        elseif variant == "chipOn" then                 -- 筛选标签（选中）
            Border(w, "b", c.accent)
            HoverOn(w, c.accentSoft, c.accentSoft)
            TextColor(w:GetFontString(), c.accent)
        elseif variant == "ghost" then
            Border(w, "b", c.line)
            HoverOn(w, { 0, 0, 0, 0 }, c.hover)
            TextColor(w:GetFontString(), c.dim)
        else
            Border(w, "b", c.btnb)
            HoverOn(w, c.btn, c.btnh)
            TextColor(w:GetFontString(), c.btnt)
        end
        w._skinDisabledAlpha = 0.45
    end,
    tab = function(w, selected)
        local c = C
        local bg = Tex(w, "bg", "BACKGROUND")
        bg:SetAllPoints()
        if selected then
            SetTex(bg, c.bg2)
            for i, e in ipairs({ "TOPLEFT", "TOPLEFT", "TOPRIGHT" }) do
                local t = Tex(w, "edge" .. i, "BORDER")
                t:ClearAllPoints()
                if i == 1 then
                    t:SetPoint("TOPLEFT"); t:SetPoint("TOPRIGHT"); t:SetHeight(1)
                elseif i == 2 then
                    t:SetPoint(e); t:SetPoint("BOTTOMLEFT", 0, -1); t:SetWidth(1)
                else
                    t:SetPoint(e); t:SetPoint("BOTTOMRIGHT", 0, -1); t:SetWidth(1)
                end
                SetTex(t, c.line)
            end
            local cover = Tex(w, "cover", "BORDER")
            cover:ClearAllPoints()
            cover:SetPoint("BOTTOMLEFT", 1, -1)
            cover:SetPoint("BOTTOMRIGHT", -1, -1)
            cover:SetHeight(1)
            SetTex(cover, c.bg2)
            TextColor(w:GetFontString(), c.title)
            w._skinHover = nil
        else
            SetTex(bg, { 0, 0, 0, 0 })
            HideTex(w, "edge")
            HideTex(w, "cover")
            TextColor(w:GetFontString(), c.dim)
            w._skinHover = function(on) TextColor(w:GetFontString(), on and c.text or c.dim) end
        end
    end,
    input = function(w)
        local c = C
        local bg = Tex(w, "bg", "BACKGROUND")
        bg:SetAllPoints()
        SetTex(bg, c.inp)
        Border(w, "b", c.inpb)
        w:SetTextColor(c.text[1], c.text[2], c.text[3])
        if w._placeholder then TextColor(w._placeholder, c.dim) end
    end,
    -- 勾选框与单选：w._box 是 16x16 的小框，w._mark 是选中标记，w._label 是文字
    check = function(w, round)
        local c = C
        local box = w._box
        local bg = Tex(box, "bg", "BACKGROUND")
        bg:SetAllPoints()
        SetTex(bg, c.inp)
        Border(box, "b", c.btnb)
        local m = Tex(box, "mark", "ARTWORK")
        m:ClearAllPoints()
        m:SetPoint("TOPLEFT", round and 4 or 3, round and -4 or -3)
        m:SetPoint("BOTTOMRIGHT", round and -4 or -3, round and 4 or 3)
        SetTex(m, c.accent)
        w._mark = m
        if w._label then TextColor(w._label, c.text) end
        if w._refresh then w._refresh() end
    end,
    slider = function(w)
        local c = C
        local track = Tex(w, "track", "BACKGROUND")
        track:ClearAllPoints()
        track:SetPoint("LEFT")
        track:SetPoint("RIGHT")
        track:SetHeight(4)
        SetTex(track, c.inp)
        local thumb = w:GetThumbTexture()
        if thumb then
            thumb:SetColorTexture(c.btnb[1], c.btnb[2], c.btnb[3], 1)
            thumb:SetSize(10, 14)
        end
        if w._label then TextColor(w._label, c.text) end
        if w._valueText then TextColor(w._valueText, c.dim) end
    end,
    progress = function(w)
        local c = C
        local bg = Tex(w, "bg", "BACKGROUND")
        bg:SetAllPoints()
        SetTex(bg, c.inp)
        Border(w, "b", c.inpb)
        SetTex(w._fill, c.accent)
    end,
    row = function(w, even)
        local c = C
        local bg = Tex(w, "bg", "BACKGROUND")
        bg:SetAllPoints()
        local normal = even and c.alt or { 0, 0, 0, 0 }
        HoverOn(w, normal, c.hover)
        local fl = Tex(w, "flash", "BACKGROUND", 1)
        fl:SetAllPoints()
        SetTex(fl, c.flash)
        if not w._flashing then fl:Hide() end
    end,
    scrollbar = function(w)
        local t = Tex(w._thumb, "bg", "ARTWORK")
        t:SetAllPoints()
        SetTex(t, C.btnb)
    end,
    badge = function(w)
        local c = C
        local bg = Tex(w, "bg", "BACKGROUND")
        bg:SetAllPoints()
        SetTex(bg, c.dup)
        TextColor(w._text, c.dupText)
    end,
    -- 状态圆点：state = ok / warn / off
    dot = function(w, state)
        local c = C
        local t = Tex(w, "dot", "ARTWORK")
        t:SetAllPoints()
        SetTex(t, c[state] or c.off)
    end,
    text = function(fs, role)
        TextColor(fs, C[role] or C.text)
    end,
    -- 强调色色块（待拍按钮的色条、数字徽标）
    accentbar = function(w)
        local t = Tex(w, "bg", "BACKGROUND")
        t:SetAllPoints()
        SetTex(t, C.accent)
    end,
    -- 线条画的符号（关闭、下拉、加减），颜色同文字
    glyph = function(w, role)
        for _, t in ipairs(w._lines or {}) do SetTex(t, C[role] or C.text) end
    end,
}

Skin.skins.flat = flat
Skin.order[1] = "flat"

------------------------------------------------------------------------
-- 暴雪原生
-- 颜色取自效果图 [data-skin=blizz]：金色边框与标题、红色按钮、深棕底。
-- 绘制只用纯色与渐变，不依赖客户端模板和贴图名（探测结果出来前最稳妥）；
-- 没有单独定义的控件沿用扁平暗色的绘制函数、换成本套颜色。
------------------------------------------------------------------------

local blizz = { name = "blizz", label = "暴雪原生" }
blizz.c = {
    bg = Hex("17120d"), bg2 = Hex("221a12"), alt = { 1, 1, 1, 0.035 }, hover = { 1, 0.82, 0, 0.09 },
    line = Hex("3b2f20"), text = Hex("ffffff"), dim = Hex("b5a688"), title = Hex("ffd100"),
    accent = Hex("ffd100"), btn = Hex("8f1d12"), btnBottom = Hex("5a0e08"), btnh = Hex("b12a1c"),
    btnhBottom = Hex("74140c"), btnb = Hex("b8943f"), btnt = Hex("ffd100"), hd = Hex("3b2d1c"),
    hdBottom = Hex("211810"), inp = Hex("0d0a07"), inpb = Hex("5b4829"), outer = Hex("000000"),
    inner = Hex("8a6d3b"), ok = Hex("3ddc68"), warn = Hex("ffd100"), off = Hex("858c96"), bad = Hex("ff5555"),
    dup = Hex("ffb020"), dupText = Hex("111111"), star = Hex("ffd100"), flash = { 1, 0.82, 0, 0.22 },
    panelTop = Hex("1d160f"), panelBottom = Hex("130f0a"), onAccent = Hex("1a1208"),
}

blizz.draw = setmetatable({
    panel = function(w)
        local c = C
        SetGradientTex(Tex(w, "bg", "BACKGROUND", -8), c.panelTop, c.panelBottom)
        w._skinTex.bg:SetAllPoints()
        local o = Overlay(w)
        Border(o, "outer", c.outer, 0)
        Border(o, "inner", c.inner, 1)
        Border(o, "inner2", c.inner, 2)
    end,
    header = function(w)
        local c = C
        local bg = Tex(w, "bg", "BACKGROUND", -7)
        bg:SetAllPoints()
        SetGradientTex(bg, c.hd, c.hdBottom)
        local l = Tex(w, "line", "BORDER")
        l:ClearAllPoints()
        l:SetPoint("BOTTOMLEFT")
        l:SetPoint("BOTTOMRIGHT")
        l:SetHeight(1)
        SetTex(l, c.line)
    end,
    button = function(w, variant)
        local c = C
        local bg = Tex(w, "bg", "BACKGROUND")
        bg:SetAllPoints()
        local fs = w:GetFontString()
        if variant == "item" then
            w._skinHover = function(on) SetTex(bg, on and c.hover or { 0, 0, 0, 0 }) end
            if fs then fs:SetTextColor(c.text[1], c.text[2], c.text[3]) end
        elseif variant == "danger" then
            Border(w, "b", c.bad)
            w._skinHover = function(on) SetTex(bg, on and c.hover or { 0, 0, 0, 0 }) end
            if fs then fs:SetTextColor(c.bad[1], c.bad[2], c.bad[3]) end
        elseif variant == "chip" or variant == "chipOn" then
            local on = variant == "chipOn"
            Border(w, "b", on and c.btnb or c.line)
            w._skinHover = function(h) SetTex(bg, (on or h) and c.hover or { 0, 0, 0, 0 }) end
            local tc = on and c.title or c.dim
            if fs then fs:SetTextColor(tc[1], tc[2], tc[3]) end
        elseif variant == "ghost" then
            Border(w, "b", c.line)
            w._skinHover = function(on) SetTex(bg, on and c.hover or { 0, 0, 0, 0 }) end
            if fs then fs:SetTextColor(c.dim[1], c.dim[2], c.dim[3]) end
        else
            Border(w, "b", c.btnb)
            w._skinHover = function(on)
                if on then SetGradientTex(bg, c.btnh, c.btnhBottom) else SetGradientTex(bg, c.btn, c.btnBottom) end
            end
            if fs then
                fs:SetTextColor(c.btnt[1], c.btnt[2], c.btnt[3])
                if fs.SetShadowOffset then fs:SetShadowOffset(1, -1) end
            end
        end
        w._skinHover(w._hovered)
        w._skinDisabledAlpha = 0.45
    end,
    tab = function(w, selected)
        flat.draw.tab(w, selected)
        if selected then SetGradientTex(w._skinTex.bg, C.hd, C.bg) end
    end,
}, { __index = flat.draw })

-- 从暴雪原生切回扁平暗色时，隐藏暴雪原生独有的纹理
flat.reset = function(w)
    for _, f in ipairs({ w, w._skinOverlay }) do
        if f and f._skinTex and f._skinTex.inner21 then
            for i = 1, 4 do if f._skinTex["inner2" .. i] then f._skinTex["inner2" .. i]:Hide() end end
        end
    end
    local fs = w.GetFontString and w:GetFontString()
    if fs and fs.SetShadowOffset then fs:SetShadowOffset(0, 0) end
end

blizz.draw.glyph = flat.draw.glyph
Skin.skins.blizz = blizz
Skin.order[2] = "blizz"

------------------------------------------------------------------------
-- 登记、绘制、切换
------------------------------------------------------------------------

function Skin:Get()
    return self.skins[self.current] or flat
end

function Skin:Color(role)
    local c = self:Get().c[role] or flat.c[role] or flat.c.text
    return c[1], c[2], c[3], c[4] or 1
end

local function Draw(skin, w, kind, args)
    local fn = skin.draw[kind]
    C = skin.c
    if fn then
        local ok, err = pcall(fn, w, unpack(args, 1, args.n))
        if ok then return end
        -- 兜底：该皮肤画不出来时退回扁平暗色
        ns.Debug("皮肤 " .. skin.name .. " 绘制 " .. kind .. " 失败，退回扁平暗色：" .. tostring(err))
    end
    if skin ~= flat and flat.draw[kind] then
        C = flat.c
        pcall(flat.draw[kind], w, unpack(args, 1, args.n))
    end
end

-- 登记并按当前皮肤绘制。同一控件再次调用会更新参数（例如标签页选中状态变化）。
function Skin:Apply(w, kind, ...)
    local args = { n = select("#", ...), ... }
    self.registry[w] = { kind = kind, args = args }
    Draw(self:Get(), w, kind, args)
end

function Skin:Set(name)
    if not self.skins[name] then name = "flat" end
    self.current = name
    local skin = self:Get()
    for w, info in pairs(self.registry) do
        if skin.reset then pcall(skin.reset, w, info.kind) end
        Draw(skin, w, info.kind, info.args)
    end
    ns.Events:Fire("RW_SKIN_CHANGED", name)
end

function Skin:Available()
    local out = {}
    for _, k in ipairs(self.order) do out[#out + 1] = { key = k, label = self.skins[k].label } end
    return out
end

ns.Events:On("RW_LOADED", function()
    Skin.current = Skin.skins[ns.DB.options.ui.skin] and ns.DB.options.ui.skin or "flat"
end)
