-- UI/MinimapButton.lua：小地图按钮
-- 全插件只有一个小地图按钮：左键开关主窗口，右键弹出菜单，左键拖动沿小地图边缘移动。
-- 位置存为角度（RaidWishCharDB.minimap.angle），默认在右上方。
local ADDON, ns = ...

local W = ns.Widgets
local Btn = {}
ns.MinimapButton = Btn

local DEFAULT_ANGLE = 45
local button

local function Angle() return (ns.DB.char.minimap and ns.DB.char.minimap.angle) or DEFAULT_ANGLE end

local function Place()
    local a = math.rad(Angle())
    local r = (Minimap:GetWidth() / 2) + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    local deg = math.deg(math.atan2(cy - my, cx - mx))
    ns.DB.char.minimap = ns.DB.char.minimap or {}
    ns.DB.char.minimap.angle = deg % 360
    Place()
end

local function ShowMenu()
    W.Menu(button, function(root)
        root:Title(ns.TITLE)
        root:Button("许愿", function() ns.Main:Show("wish") end)
        root:Button("掉落与拍卖", function() ns.Main:Show("loot") end)
        root:Button("设置", function() ns.Main:Show("set") end)
        root:Divider()
        local o = ns.DB.options.auction
        root:Button(o.showPendingButton and "隐藏\"待拍\"按钮" or "显示\"待拍\"按钮", function()
            o.showPendingButton = not o.showPendingButton
            ns.Events:Fire("RW_AUCTION_OPTION")
        end)
    end)
end

local function Create()
    button = CreateFrame("Button", "RaidWishMinimapButton", Minimap)
    button:SetSize(32, 32)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(21, 21)
    icon:SetPoint("CENTER", 0, 1)
    -- 圆形遮罩：游戏图标是方的，裁成圆形才能和小地图按钮的圆框贴合
    pcall(function()
        local mask = button:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(icon)
        icon:AddMaskTexture(mask)
    end)
    W.ApplyIcon(icon)
    button.icon = icon
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT")
    border:SetTexture(W.Textures.minimapBorder)
    button:SetHighlightTexture(W.Textures.minimapHighlight)
    button:SetScript("OnClick", function(_, b)
        if b == "RightButton" then ShowMenu() else ns.Main:Toggle() end
    end)
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", OnDragUpdate) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(self)
        W.ShowTip(self, ns.SHORT_TITLE, "左键：显示 / 隐藏许愿窗口\n右键：打开菜单\n拖动：沿小地图移动")
    end)
    button:SetScript("OnLeave", W.HideTip)
    Place()
end

function Btn:Refresh()
    if not button then return end
    button:SetShown(ns.DB.options.ui.showMinimap and true or false)
    Place()
end

ns.Events:On("RW_LOADED", function()
    if not Minimap then return end
    Create()
    Btn:Refresh()
end)
ns.Events:On("RW_MINIMAP_OPTION", function() Btn:Refresh() end)
ns.Events:On("RW_RESET_POSITIONS", function() Btn:Refresh() end)

ns.Events:On("RW_ICON_CHANGED", function()
    if button and button.icon then W.ApplyIcon(button.icon) end
end)
