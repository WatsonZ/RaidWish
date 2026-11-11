-- UI/UnitMenu.lua：团队成员右键菜单
-- 用正式服的 Menu.ModifyMenu 扩展点，不改 UnitPopup 表、不覆盖函数。
-- 探测确认：自己头像为 MENU_UNIT_SELF，聊天框里的名字为 MENU_UNIT_FRIEND；其余候选标签挂上无害。只对在团成员显示。
local ADDON, ns = ...

local UnitMenu = {}
ns.UnitMenu = UnitMenu

-- 候选标签（探测确认的：头像 MENU_UNIT_SELF、团队框体 MENU_UNIT_RAID_PLAYER、聊天名字 MENU_UNIT_FRIEND）
UnitMenu.TAGS = {
    "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_RAID", "MENU_UNIT_PARTY", "MENU_UNIT_PLAYER",
    "MENU_UNIT_SELF", "MENU_UNIT_FRIEND", "MENU_UNIT_CHAT_ROSTER",
}

-- 菜单上下文里的名字：头像菜单是 name + surname 分开给，聊天名字菜单是完整的"名 姓"。
local function TargetName(owner, ctx)
    local IsSecret = ns.Compat.IsSecret
    local name = ctx and ctx.name
    if IsSecret(name) then return nil end
    local surname = ctx and ctx.surname
    if type(name) == "string" and name ~= "" and type(surname) == "string" and surname ~= ""
        and not IsSecret(surname) and not name:find(" ", 1, true) then
        name = name .. " " .. surname
    end
    if (not name or name == "") and ctx and ctx.unit then name = ns.Util.UnitFullName(ctx.unit) end
    if (not name or name == "") and owner and owner.unit then name = ns.Util.UnitFullName(owner.unit) end
    if not name then return nil end
    return ns.Util.NormName(name)
end

-- 生成菜单项（root 为 MenuUtil 的根描述）
function UnitMenu.Build(owner, root, ctx)
    local name = TargetName(owner, ctx)
    if not name or not ns.Roster:Has(name) then return end
    local WC = ns.WishChat
    root:CreateDivider()
    root:CreateTitle(ns.SHORT_TITLE)
    root:CreateButton("查询许愿", function() WC:Query(name) end)
    if ns.Wish:IsLeader() then
        local add = root:CreateButton("增加分数")
        for n = 1, 4 do add:CreateButton("增加" .. n .. "分", function() WC:AddDkp(name, n) end) end
        local minus = root:CreateButton("扣除分数")
        for n = 1, 4 do minus:CreateButton("扣除" .. n .. "分", function() WC:MinusDkp(name, n) end) end
    end
end

ns.Events:On("RW_LOADED", function()
    if not (Menu and Menu.ModifyMenu) then
        ns.Log(ns.LogLevel.WARN, "Menu.ModifyMenu 不可用，右键菜单功能未启用")
        return
    end
    for _, tag in ipairs(UnitMenu.TAGS) do
        local ok, err = pcall(Menu.ModifyMenu, tag, function(owner, root, ctx)
            local ok2, err2 = pcall(UnitMenu.Build, owner, root, ctx)
            if not ok2 then ns.Log(ns.LogLevel.ERROR, "右键菜单出错：" .. tostring(err2)) end
        end)
        if not ok then ns.Debug("挂接菜单 " .. tag .. " 失败：" .. tostring(err)) end
    end
end)
