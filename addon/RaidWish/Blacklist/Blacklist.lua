-- Blacklist/Blacklist.lua：黑名单与进组通报
-- 存档 RaidWishBlacklistDB（账号级）：{ enabled, joinText, players = { [名字] = { name, reason, addedBy, timestamp } } }
--
-- 新版只在黑名单玩家进组时通报一次：新出现在队伍里的人，以及自己刚进组时队伍里已有的人。
local ADDON, ns = ...

local BL = {}
ns.Blacklist = BL

local Util = ns.Util
local function DB() return ns.DB.blacklist end

------------------------------------------------------------------------
-- 数据
------------------------------------------------------------------------

function BL:Players() return DB().players end

function BL:IsListed(name) return DB().players[Util.NormName(name)] ~= nil end

function BL:Add(name, reason, addedBy)
    name = Util.NormName(name)
    if name == "" then
        ns.Print("错误：玩家名称不能为空")
        return false
    end
    DB().players[name] = {
        name = name,
        reason = (reason and reason ~= "") and reason or "未指定原因",
        addedBy = (addedBy and addedBy ~= "") and addedBy or ns.Roster:Self(),
        timestamp = time(),
    }
    ns.Print("已添加玩家 " .. name .. " 到黑名单")
    ns.Events:Fire("RW_BLACKLIST_CHANGED")
    return true
end

function BL:Remove(name)
    name = Util.NormName(name)
    if not DB().players[name] then
        ns.Print("玩家 " .. name .. " 不在黑名单中")
        return false
    end
    DB().players[name] = nil
    ns.Print("已从黑名单移除玩家 " .. name)
    ns.Events:Fire("RW_BLACKLIST_CHANGED")
    return true
end

-- 排序后的列表（按名字），序号与 /xyb list 一致
function BL:Sorted()
    local out = {}
    for _, info in pairs(DB().players) do out[#out + 1] = info end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function BL:RemoveByIndex(index)
    local list = self:Sorted()
    local info = list[tonumber(index) or 0]
    if not info then
        ns.Print("序号 " .. tostring(index) .. " 超出黑名单范围")
        return false
    end
    return self:Remove(info.name)
end

function BL:SetEnabled(on)
    DB().enabled = on and true or false
    ns.Print("黑名单功能已" .. (on and "启用" or "禁用"))
end

function BL:SetText(text)
    if not text or text == "" then return false end
    DB().joinText = text
    ns.Print("已更新黑名单播报文字")
    return true
end

------------------------------------------------------------------------
-- 进组通报
------------------------------------------------------------------------

-- 通报文字（纯函数）：{player} 替换为名字，后面括号里写原因
function BL.Message(template, name, reason)
    local msg = tostring(template or ns.DB.DEFAULT_BLACKLIST_TEXT):gsub("{player}", function() return name end)
    return msg .. "（原因：" .. (reason or "未写") .. "）"
end

local seen = {}

local function GroupMembers()
    local out = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name = GetRaidRosterInfo(i)
            if name and not ns.Compat.IsSecret(name) then out[#out + 1] = Util.NormName(name) end
        end
    elseif IsInGroup() then
        for i = 1, GetNumGroupMembers() - 1 do
            local name = Util.UnitFullName("party" .. i)
            if name then out[#out + 1] = name end
        end
    end
    return out
end

local function Announce(name)
    local info = DB().players[name]
    if not info then return end
    local msg = BL.Message(DB().joinText, name, info.reason)
    ns.Chat:Send(msg, IsInRaid() and "RAID" or "PARTY")
    ns.Print(msg)
    ns.Print("详细信息：原因：" .. (info.reason or "未知") .. " | 添加者：" .. (info.addedBy or "未知"))
end

function BL:Check()
    if not IsInGroup() then
        seen = {}
        return
    end
    local now = {}
    for _, name in ipairs(GroupMembers()) do
        now[name] = true
        if not seen[name] and DB().enabled and DB().players[name] then Announce(name) end
    end
    seen = now
end

local check = ns.Debounce(function() BL:Check() end)
ns.Events:On("GROUP_ROSTER_UPDATE", check)
ns.Events:On("RW_LOGIN", function() ns.After(3, function() BL:Check() end) end)
ns.Events:On("GROUP_LEFT", function() seen = {} end)

------------------------------------------------------------------------
-- /xyb：不带参数时打开设置页的黑名单分类
------------------------------------------------------------------------

local function Help()
    ns.Print("黑名单命令：")
    ns.Print("  /xyb  打开黑名单设置")
    ns.Print("  /xyb add 名 姓 [原因] [添加者]  添加玩家到黑名单（名字两段都要写）")
    ns.Print("  /xyb remove 名 姓|序号  从黑名单移除玩家")
    ns.Print("  /xyb list  显示黑名单列表")
    ns.Print("  /xyb enable | disable  启用或禁用黑名单功能")
    ns.Print("  /xyb settext 文字  设置播报文字（可用 {player} 占位）")
end

SLASH_RAIDWISHBL1 = "/xyb"
SlashCmdList["RAIDWISHBL"] = function(msg)
    local parts = {}
    for p in (msg or ""):gmatch("%S+") do parts[#parts + 1] = p end
    local cmd = (parts[1] or ""):lower()
    if cmd == "" or cmd == "config" or cmd == "gui" then
        ns.Main:Show("set")
        ns.Settings:Select("blacklist")
    elseif cmd == "add" then
        local name, i = Util.TakeName(parts, 2)
        if name then BL:Add(name, parts[i], parts[i + 1]) else ns.Print("用法：/xyb add 名 姓 [原因] [添加者]") end
    elseif cmd == "remove" then
        if not parts[2] then ns.Print("用法：/xyb remove 玩家名|序号")
        elseif tonumber(parts[2]) then BL:RemoveByIndex(parts[2])
        else BL:Remove((Util.TakeName(parts, 2))) end
    elseif cmd == "list" then
        local list = BL:Sorted()
        for i, info in ipairs(list) do
            ns.Print(("%d. %s（原因：%s，添加人：%s）"):format(i, info.name, info.reason or "未知", info.addedBy or "未知"))
        end
        ns.Print(#list == 0 and "黑名单为空" or ("共 " .. #list .. " 名玩家在黑名单中"))
    elseif cmd == "enable" then
        BL:SetEnabled(true)
    elseif cmd == "disable" then
        BL:SetEnabled(false)
    elseif cmd == "settext" then
        local text = (msg or ""):match("^%s*%S+%s+(.+)$")
        if not BL:SetText(text) then ns.Print("用法：/xyb settext 播报文字（可使用{player}占位符）") end
    else
        Help()
    end
end

------------------------------------------------------------------------
-- 设置页：黑名单
------------------------------------------------------------------------

-- 本文件在界面文件之前加载，等全部文件加载完再登记设置分类
ns.Events:On("RW_LOADED", function() ns.Settings:AddCategory("blacklist", "黑名单", 70, function(container, L)
    local W = ns.Widgets
    L:Check("启用黑名单进组通报", function() return DB().enabled end, function(v) DB().enabled = v end)
    L:InputRow("播报文字", 250, function() return DB().joinText end, function(text, e)
        if not BL:SetText(text) then e:SetText(DB().joinText) end
    end, "保存")
    L:Hint("{player} 会替换为玩家名字，后面括号里自动加上原因。")

    -- 添加
    local nameBox = W.Input(container, 110, 24, "角色名")
    nameBox:SetPoint("TOPLEFT", container, "TOPLEFT", L.x, L.y)
    local reasonBox = W.Input(container, 180, 24, "原因")
    reasonBox:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)
    local add = W.Button(container, "添加", "normal", 56, 24, function()
        if BL:Add(nameBox:GetText(), reasonBox:GetText()) then
            nameBox:SetText("")
            reasonBox:SetText("")
        end
    end)
    add:SetPoint("LEFT", reasonBox, "RIGHT", 8, 0)
    L:Space(34)

    -- 列表：角色、原因、添加人、时间，每行带删除按钮
    local list = W.List(container, {
        rowHeight = 26,
        createRow = function(row)
            row.name = W.Text(row, "text", 12)
            row.name:SetPoint("LEFT", 4, 0)
            row.name:SetWidth(90)
            row.reason = W.Text(row, "dim", 12)
            row.reason:SetPoint("LEFT", 98, 0)
            row.reason:SetWidth(130)
            row.by = W.Text(row, "dim", 12)
            row.by:SetPoint("LEFT", 232, 0)
            row.by:SetWidth(60)
            row.del = W.Button(row, "删除", "ghost", 44, 20)
            row.del:SetPoint("RIGHT", -12, 0)
        end,
        updateRow = function(row, info)
            row.name:SetText(info.name)
            row.reason:SetText(info.reason or "")
            row.by:SetText((info.addedBy or "") .. " " .. (info.timestamp and date("%m-%d", info.timestamp) or ""))
            row.del:SetScript("OnClick", function() BL:Remove(info.name) end)
        end,
    })
    list:SetPoint("TOPLEFT", container, "TOPLEFT", L.x, L.y)
    list:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -14, 10)
    local function refresh() list:SetData(BL:Sorted()) end
    refresh()
    ns.Events:On("RW_BLACKLIST_CHANGED", refresh)
    L.refreshers[#L.refreshers + 1] = { Refresh = refresh }
end) end)
