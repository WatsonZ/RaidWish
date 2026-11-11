-- RaidWishProbe：RaidWish 开发用的接口探测插件
-- 结果写入存档变量 RaidWishProbeDB，同时打印到聊天框。命令：/rwprobe
-- 原则：对保密值只记录"是保密值"，不做任何其他操作。
local ADDON, ns = ...

local PREFIX = "RWPROBE"
local MAX_LOG = 3000

local DB
local state = {
    inEncounter = false,
    encounter = nil,
    flood = nil,      -- 本机最近一次 flood 的发送记录
    menuHooked = false,
}

------------------------------------------------------------------------
-- 基础工具
------------------------------------------------------------------------

local function Print(msg)
    local cf = DEFAULT_CHAT_FRAME
    if cf then cf:AddMessage("|cff4aa3ff[RaidWishProbe]|r " .. tostring(msg)) end
end

local issecret = _G.issecretvalue
local canaccess = _G.canaccessvalue

-- 是否为保密值。issecretvalue 不存在时恒为 false；调用出错时保守地当作保密值。
local function IsSecret(v)
    if not issecret then return false end
    local ok, r = pcall(issecret, v)
    if not ok then return true end
    return r and true or false
end

local function Esc(s)
    return (s:gsub("|", "||"))
end

-- 把任意值格式化成一段可存档的字符串。skipEmpty 为 true 时空串 / 0 / false 返回 nil。
local function Fmt(v, skipEmpty)
    if IsSecret(v) then return "<secret>" end
    local t = type(v)
    if t == "string" then
        if skipEmpty and v == "" then return nil end
        return "s" .. #v .. ":" .. Esc(v)
    elseif t == "number" then
        if skipEmpty and v == 0 then return nil end
        return "n:" .. tostring(v)
    elseif t == "boolean" then
        if skipEmpty and v == false then return nil end
        return "b:" .. tostring(v)
    elseif t == "nil" then
        if skipEmpty then return nil end
        return "nil"
    end
    return t
end

-- 把多个返回值格式化成一行
local function FmtAll(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
        parts[#parts + 1] = Fmt((select(i, ...)))
    end
    if n == 0 then return "(无返回值)" end
    return table.concat(parts, ", ")
end

-- 保留尾部 nil 的打包
local function Pack(...)
    return select("#", ...), { ... }
end

-- 受保护地调用并格式化返回值（不含 pcall 自己的 true）
local function Call(f, ...)
    local n, r = Pack(pcall(f, ...))
    if not r[1] then return "err:" .. Esc(tostring(r[2])) end
    if n < 2 then return "(无返回值)" end
    return FmtAll(unpack(r, 2, n))
end

local function Now()
    return date("%H:%M:%S")
end

-- 按 "a.b.c" 取值
local function Resolve(path)
    local ok, v = pcall(function()
        local cur = _G
        for part in path:gmatch("[^%.]+") do
            if type(cur) ~= "table" then return nil end
            cur = cur[part]
        end
        return cur
    end)
    if ok then return v end
    return nil
end

local function SortKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta == "number" end
        if ta == "number" or ta == "string" then return a < b end
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function Push(list, entry)
    list[#list + 1] = entry
    while #list > MAX_LOG do table.remove(list, 1) end
end

local function LockdownState()
    local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
    if not f then return "n/a" end
    return Call(f)
end

local function EncounterState()
    local s = state.inEncounter and ("1(" .. tostring(state.encounter) .. ")") or "0"
    if IsEncounterInProgress then
        local ok, r = pcall(IsEncounterInProgress)
        s = s .. " iep=" .. (ok and Fmt(r) or "err")
    end
    return s
end

local function GroupChannel()
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    return nil
end

-- Enum.SendAddonMessageResult 的反查表，便于看懂返回值
local function AddonResultName(v)
    if IsSecret(v) then return "<secret>" end
    local e = Enum and Enum.SendAddonMessageResult
    if type(v) == "number" and type(e) == "table" then
        for k, n in pairs(e) do
            if n == v then return tostring(v) .. "(" .. k .. ")" end
        end
    end
    return Fmt(v)
end

------------------------------------------------------------------------
-- 存档
------------------------------------------------------------------------

local function InitDB()
    RaidWishProbeDB = RaidWishProbeDB or {}
    DB = RaidWishProbeDB
    DB.info = DB.info or {}
    DB.api = DB.api or {}
    DB.globalStrings = DB.globalStrings or {}
    DB.namespaces = DB.namespaces or {}
    DB.events = DB.events or {}
    DB.tpl = DB.tpl or {}
    DB.chatLog = DB.chatLog or {}
    DB.otherAddonPrefixes = DB.otherAddonPrefixes or {}
    DB.send = DB.send or {}
    DB.flood = DB.flood or {}
    DB.floodRecv = DB.floodRecv or {}
    DB.loot = DB.loot or {}
    DB.menu = DB.menu or {}
    DB.misc = DB.misc or {}
    if DB.chatOn == nil then DB.chatOn = false end
    if DB.menuOn == nil then DB.menuOn = false end
end

------------------------------------------------------------------------
-- /rwprobe info
------------------------------------------------------------------------

local function CmdInfo()
    local info = {}
    info.time = date("%Y-%m-%d %H:%M:%S")
    info.GetBuildInfo = FmtAll(GetBuildInfo())
    local _, _, _, toc = GetBuildInfo()
    info.tocversion = Fmt(toc)
    info.GetLocale = Fmt(GetLocale and GetLocale())
    if UnitFullName then info.UnitFullName = FmtAll(UnitFullName("player")) end
    if UnitName then info.UnitName = FmtAll(UnitName("player")) end
    if GetNormalizedRealmName then info.GetNormalizedRealmName = FmtAll(GetNormalizedRealmName()) end
    if GetRealmName then info.GetRealmName = FmtAll(GetRealmName()) end
    info.WOW_PROJECT_ID = Fmt(_G.WOW_PROJECT_ID)
    info.WOW_PROJECT_MAINLINE = Fmt(_G.WOW_PROJECT_MAINLINE)
    info.LE_EXPANSION_LEVEL_CURRENT = Fmt(_G.LE_EXPANSION_LEVEL_CURRENT)
    if GetExpansionLevel then info.GetExpansionLevel = Call(GetExpansionLevel) end
    if GetMaxLevelForPlayerExpansion then
        info.GetMaxLevelForPlayerExpansion = Call(GetMaxLevelForPlayerExpansion)
    end
    if UnitLevel then info.UnitLevel = Fmt(UnitLevel("player")) end
    if UnitClass then info.UnitClass = FmtAll(UnitClass("player")) end
    info.issecretvalue = type(issecret)
    info.canaccessvalue = type(canaccess)
    DB.info = info

    Print("GetBuildInfo: " .. info.GetBuildInfo)
    Print("Interface 号（TOC 应写）: " .. info.tocversion)
    Print("GetLocale: " .. info.GetLocale)
    Print("UnitFullName: " .. tostring(info.UnitFullName))
    Print("GetNormalizedRealmName: " .. tostring(info.GetNormalizedRealmName))
    Print("WOW_PROJECT_ID: " .. info.WOW_PROJECT_ID .. "  资料片: " .. tostring(info.GetExpansionLevel))
    Print("已写入 RaidWishProbeDB.info")
end

------------------------------------------------------------------------
-- /rwprobe api
------------------------------------------------------------------------

local API_NAMES = {
    "SendChatMessage", "C_ChatInfo.SendChatMessage", "C_ChatInfo.SendAddonMessage",
    "C_ChatInfo.RegisterAddonMessagePrefix", "C_ChatInfo.InChatMessagingLockdown",
    "issecretvalue", "canaccessvalue", "Menu.ModifyMenu", "MenuUtil.CreateContextMenu",
    "UIDropDownMenu_Initialize", "FauxScrollFrame_Update", "ScrollUtil", "C_Item.GetItemInfo",
    "C_Item.GetItemIconByID", "GetItemInfo", "GetLootMethod", "C_PartyInfo.GetLootMethod",
    "C_PartyInfo.SetLootMethod", "GiveMasterLoot", "GetMasterLootCandidate", "GetNumLootItems",
    "GetLootSlotLink", "GetLootSlotInfo", "MasterLooterFrame", "LootFrame", "GroupLootDropDown",
    "C_Timer.After", "C_AddOns.GetAddOnMetadata", "Ambiguate", "AddonCompartmentFrame",
    "UnitPopupButtons", "UnitPopupMenus",
    -- 额外：后续阶段会用到、顺便确认
    "Menu.PrintOpenMenuTags", "C_Timer.NewTicker", "C_XMLUtil.GetTemplateInfo",
    "C_EventUtils.IsEventValid", "IsEncounterInProgress", "issecrettable",
    "UnitIsGroupLeader", "UnitIsGroupAssistant", "GetRaidRosterInfo", "GetNumGroupMembers",
    "IsInRaid", "C_Item.RequestLoadItemDataByID", "C_Item.GetItemQualityByID",
    "C_Item.GetItemNameByID", "Item.CreateFromItemID", "GetLootSlotType", "LootSlot",
    "C_Loot.IsLegacyLootModeEnabled", "C_LootHistory.GetSortedDropsForEncounter",
    "PlaySoundFile", "StaticPopup_Show", "StaticPopupDialogs", "UISpecialFrames",
    "hooksecurefunc", "ReloadUI", "InCombatLockdown", "RAID_CLASS_COLORS",
    "C_ClassColor.GetClassColor", "Settings.RegisterCanvasLayoutCategory",
    "InterfaceOptions_AddCategory", "SetRaidTarget", "ChatFrame_AddMessageEventFilter",
    "ChatFrameUtil.AddMessageEventFilter", "GetItemQualityColor", "C_Item.GetItemQualityColor",
    "ITEM_QUALITY_COLORS", "Enum.SendAddonMessageResult", "Enum.ItemQuality",
}

local GLOBAL_STRINGS = {
    "RANDOM_ROLL_RESULT", "LOOT_ITEM", "LOOT_ITEM_SELF", "LOOT_ITEM_MULTIPLE",
    "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
    "LOOT_ITEM_PUSHED", "LOOT_ITEM_PUSHED_MULTIPLE", "ERR_RAID_YOU_JOINED", "ERR_RAID_YOU_LEFT",
    "ERR_PARTY_CONVERTED_TO_RAID",
}

-- 列出这些命名空间下的全部成员名，用于发现我们没想到的接口
local NAMESPACES = {
    "C_ChatInfo", "C_PartyInfo", "C_Loot", "C_LootHistory", "C_Item", "Menu", "MenuUtil",
    "C_Secrets", "C_RestrictedActions", "C_AddOns", "C_EncounterJournal", "C_XMLUtil",
}

-- 判断这些事件是否存在（不存在的事件 RegisterEvent 会报错）
local EVENT_NAMES = {
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING", "CHAT_MSG_WHISPER",
    "CHAT_MSG_LOOT", "CHAT_MSG_SYSTEM", "CHAT_MSG_ADDON", "CHAT_MSG_ADDON_LOGGED",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "ENCOUNTER_START", "ENCOUNTER_END",
    "GROUP_ROSTER_UPDATE", "GROUP_JOINED", "GROUP_LEFT", "PARTY_LEADER_CHANGED",
    "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT", "LOOT_OPENED", "LOOT_READY",
    "LOOT_CLOSED", "LOOT_SLOT_CLEARED", "OPEN_MASTER_LOOT_LIST", "UPDATE_MASTER_LOOT_LIST",
    "START_LOOT_ROLL", "CONFIRM_LOOT_SLOT", "LOOT_HISTORY_UPDATE_DROP",
    "LOOT_HISTORY_UPDATE_ENCOUNTER", "PARTY_LOOT_METHOD_CHANGED", "RAID_ROSTER_UPDATE",
    "PARTY_MEMBERS_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "ADDON_RESTRICTION_STATE_CHANGED", "CHAT_MESSAGING_LOCKDOWN_CHANGED",
}

local function EventExists(name)
    if C_EventUtils and C_EventUtils.IsEventValid then
        local ok, r = pcall(C_EventUtils.IsEventValid, name)
        if ok then return r and "yes" or "no" end
    end
    local f = CreateFrame("Frame")
    local ok = pcall(f.RegisterEvent, f, name)
    if ok then pcall(f.UnregisterEvent, f, name) end
    return ok and "yes(reg)" or "no(reg)"
end

local function CmdApi()
    local api, missing = {}, {}
    for _, name in ipairs(API_NAMES) do
        local v = Resolve(name)
        api[name] = type(v)
        if v == nil then missing[#missing + 1] = name end
    end
    DB.api = api

    local gs = {}
    for _, name in ipairs(GLOBAL_STRINGS) do
        gs[name] = Fmt(_G[name])
    end
    DB.globalStrings = gs

    local nsList = {}
    for _, nsName in ipairs(NAMESPACES) do
        local t = Resolve(nsName)
        if type(t) == "table" then
            local names = {}
            for _, k in ipairs(SortKeys(t)) do
                names[#names + 1] = tostring(k) .. ":" .. type(t[k])
            end
            nsList[nsName] = table.concat(names, " ")
        else
            nsList[nsName] = type(t)
        end
    end
    DB.namespaces = nsList

    local ev = {}
    for _, name in ipairs(EVENT_NAMES) do ev[name] = EventExists(name) end
    DB.events = ev

    for _, name in ipairs(API_NAMES) do
        local t = api[name]
        Print((t == "nil" and "|cffff5555缺失|r " or "|cff55ff55存在|r ") .. name .. " (" .. t .. ")")
    end
    for _, name in ipairs(GLOBAL_STRINGS) do Print(name .. " = " .. gs[name]) end
    local badEv = {}
    for _, name in ipairs(EVENT_NAMES) do
        if ev[name]:sub(1, 2) == "no" then badEv[#badEv + 1] = name end
    end
    Print("不存在的事件: " .. (#badEv > 0 and table.concat(badEv, ", ") or "无"))
    Print(("共 %d 项接口，缺失 %d 项。命名空间成员表、事件表已写入存档。"):format(#API_NAMES, #missing))
end

------------------------------------------------------------------------
-- /rwprobe tpl
------------------------------------------------------------------------

-- { 模板名, 优先尝试的框体类型... }
local TEMPLATES = {
    { "UIPanelButtonTemplate", "Button" },
    { "UIPanelCloseButton", "Button" },
    { "OptionsCheckButtonTemplate", "CheckButton" },
    { "OptionsButtonTemplate", "Button" },
    { "UICheckButtonTemplate", "CheckButton" },
    { "InputBoxTemplate", "EditBox" },
    { "FauxScrollFrameTemplate", "ScrollFrame" },
    { "BackdropTemplate", "Frame" },
    -- 面板
    { "ButtonFrameTemplate", "Frame" },
    { "PortraitFrameTemplate", "Frame" },
    { "DefaultPanelTemplate", "Frame" },
    { "DefaultPanelFlatTemplate", "Frame" },
    { "BasicFrameTemplateWithInset", "Frame" },
    -- 标签页
    { "PanelTabButtonTemplate", "Button" },
    { "PanelTopTabButtonTemplate", "Button" },
    -- 搜索框、多行编辑
    { "SearchBoxTemplate", "EditBox" },
    { "InputScrollFrameTemplate", "ScrollFrame", "Frame" },
    -- 列表与滚动条
    { "WowScrollBoxList", "Frame" },
    { "MinimalScrollBar", "EventFrame", "Frame" },
    { "WowTrimScrollBar", "EventFrame", "Frame" },
    -- 额外候选（设置页、第二套皮肤可能用到）
    { "UIPanelScrollFrameTemplate", "ScrollFrame" },
    { "ScrollFrameTemplate", "ScrollFrame" },
    { "ScrollingEditBoxTemplate", "Frame" },
    { "UIRadioButtonTemplate", "CheckButton" },
    { "UISliderTemplate", "Slider" },
    { "MinimalSliderWithSteppersTemplate", "Frame" },
    { "UIDropDownMenuTemplate", "Frame" },
    { "WowStyle1DropdownTemplate", "DropdownButton", "Button" },
    { "TooltipBackdropTemplate", "Frame" },
    { "UIPanelDialogTemplate", "Frame" },
    { "InsetFrameTemplate", "Frame" },
    { "SettingsCheckboxTemplate", "CheckButton", "Frame" },
}

local FALLBACK_TYPES = { "Frame", "Button", "CheckButton", "EditBox", "ScrollFrame", "EventFrame", "Slider" }

local TPL_GLOBALS = { "ScrollUtil", "CreateScrollBoxListLinearView", "CreateDataProvider", "PanelTemplates_SetNumTabs",
    "PanelTemplates_SetTab", "PanelTemplates_TabResize", "ScrollBoxConstants", "CreateScrollBoxLinearView" }

local function CheckTemplate(spec)
    local name = spec[1]
    local rec = {}
    -- 1) 官方模板信息查询（最可靠）
    local infoType
    if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
        local ok, info = pcall(C_XMLUtil.GetTemplateInfo, name)
        if ok and type(info) == "table" then
            infoType = info.type
            rec.xmlInfo = "type=" .. tostring(info.type) .. " w=" .. tostring(info.width) .. " h=" .. tostring(info.height)
        elseif ok then
            rec.xmlInfo = "nil(模板不存在)"
        else
            rec.xmlInfo = "err:" .. tostring(info)
        end
    else
        rec.xmlInfo = "n/a"
    end
    -- 2) 实际创建
    local tried, seen = {}, {}
    local order = {}
    if infoType then order[#order + 1] = infoType end
    for i = 2, #spec do order[#order + 1] = spec[i] end
    for _, t in ipairs(FALLBACK_TYPES) do order[#order + 1] = t end
    for _, ty in ipairs(order) do
        if not seen[ty] then
            seen[ty] = true
            local ok, f = pcall(CreateFrame, ty, nil, UIParent, name)
            if ok and f then
                pcall(f.Hide, f)
                rec.create = "ok:" .. ty
                break
            else
                tried[#tried + 1] = ty .. "→" .. tostring(f):sub(1, 120)
            end
            -- 第一次失败的类型之后只再试声明的类型，避免刷屏
            if #tried >= 3 then break end
        end
    end
    if not rec.create then rec.create = "fail" end
    if #tried > 0 then rec.errors = Esc(table.concat(tried, " | ")) end
    return rec
end

local function CmdTpl()
    local tpl = {}
    for _, spec in ipairs(TEMPLATES) do
        local rec = CheckTemplate(spec)
        tpl[spec[1]] = rec
        local good = rec.create ~= "fail"
        Print((good and "|cff55ff55OK|r " or "|cffff5555失败|r ") .. spec[1] .. "  创建=" .. rec.create .. "  模板信息=" .. rec.xmlInfo)
    end
    local g = {}
    for _, name in ipairs(TPL_GLOBALS) do
        g[name] = type(_G[name])
        Print("全局 " .. name .. ": " .. g[name])
    end
    tpl._globals = g
    DB.tpl = tpl
    Print("已写入 RaidWishProbeDB.tpl")
end

------------------------------------------------------------------------
-- 聊天记录 /rwprobe chat on|off
------------------------------------------------------------------------

local CHAT_EVENTS = {
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING", "CHAT_MSG_WHISPER",
    "CHAT_MSG_LOOT", "CHAT_MSG_SYSTEM", "CHAT_MSG_ADDON",
}
local CHAT_EVENT_SET = {}
for _, e in ipairs(CHAT_EVENTS) do CHAT_EVENT_SET[e] = true end

local function LogEvent(event, ...)
    local n = select("#", ...)
    local parts = {}
    local anySecret = false
    for i = 1, n do
        local v = select(i, ...)
        local s
        if IsSecret(v) then
            s = "<secret>"
            anySecret = true
        else
            -- 前 2 个参数（文本、发送者）总是记录，其余空值省略
            s = Fmt(v, i > 2)
        end
        if s then parts[#parts + 1] = i .. "=" .. s end
    end
    local line = ("%s %s enc=%s lock=%s secret=%s nargs=%d || %s"):format(
        Now(), event, EncounterState(), LockdownState(), anySecret and "Y" or "N", n, table.concat(parts, " || "))
    Push(DB.chatLog, line)
    return anySecret
end

-- 收到 flood 测试消息：统计，不写入聊天记录
local function OnFloodMessage(text, sender)
    local run, idx = text:match("^F\t(%d+)\t(%d+)")
    if not run then return false end
    idx = tonumber(idx)
    local key = sender .. "#" .. run
    local r = DB.floodRecv[key]
    if not r then
        r = { count = 0, last = 0, outOfOrder = 0, first = Now() }
        DB.floodRecv[key] = r
    end
    r.count = r.count + 1
    if idx <= r.last then r.outOfOrder = r.outOfOrder + 1 end
    r.last = idx
    r.lastTime = Now()
    if state.flood and tostring(state.flood.run) == run then
        state.flood.selfRecv = state.flood.selfRecv + 1
    end
    return true
end

local function OnAddonMessage(...)
    local prefix, text, channel, sender = ...
    if IsSecret(prefix) or IsSecret(text) or IsSecret(sender) or IsSecret(channel) then
        if DB.chatOn then LogEvent("CHAT_MSG_ADDON", ...) end
        return
    end
    if prefix ~= PREFIX then
        local k = tostring(prefix)
        DB.otherAddonPrefixes[k] = (DB.otherAddonPrefixes[k] or 0) + 1
        return
    end
    if type(text) == "string" and type(sender) == "string" and OnFloodMessage(text, sender) then
        return
    end
    if DB.chatOn then
        LogEvent("CHAT_MSG_ADDON", ...)
        Print("收到插件消息 来自 " .. Esc(tostring(sender)) .. " 频道 " .. tostring(channel) .. ": " .. Esc(tostring(text)))
    end
end

local function CmdChat(arg)
    if arg == "on" then
        DB.chatOn = true
        Print("聊天记录已开启（重载后保持）。记录：" .. table.concat(CHAT_EVENTS, ", "))
    elseif arg == "off" then
        DB.chatOn = false
        Print("聊天记录已关闭。当前共 " .. #DB.chatLog .. " 条记录。")
    else
        Print("用法：/rwprobe chat on|off  当前：" .. (DB.chatOn and "开" or "关") .. "，已记录 " .. #DB.chatLog .. " 条")
    end
end

------------------------------------------------------------------------
-- /rwprobe send
------------------------------------------------------------------------

local function TrySend(label, fn, ...)
    if not fn then return label .. ": 函数不存在" end
    local n, res = Pack(pcall(fn, ...))
    local ok = res[1]
    if not ok then
        return label .. ": |cffff5555报错|r " .. Esc(tostring(res[2]))
    end
    local parts = {}
    for i = 2, n do parts[#parts + 1] = AddonResultName(res[i]) end
    return label .. ": 成功调用，返回 " .. (#parts > 0 and table.concat(parts, ", ") or "(无)")
end

local function CmdSend()
    local rec = { time = Now(), enc = EncounterState(), lock = LockdownState() }
    rec.combat = InCombatLockdown and tostring(InCombatLockdown()) or "n/a"
    local ch = GroupChannel()
    rec.channel = tostring(ch)
    local text = "RaidWishProbe 测试 " .. Now()
    local lines = {}
    if ch then
        local cci = C_ChatInfo and C_ChatInfo.SendChatMessage
        lines[#lines + 1] = TrySend("C_ChatInfo.SendChatMessage", cci, text .. " (C_ChatInfo)", ch)
        local g = _G.SendChatMessage
        if g and g ~= cci then
            lines[#lines + 1] = TrySend("全局 SendChatMessage", g, text .. " (global)", ch)
        elseif g then
            lines[#lines + 1] = "全局 SendChatMessage: 与 C_ChatInfo 版本是同一个函数，未重复发送"
        else
            lines[#lines + 1] = "全局 SendChatMessage: 不存在"
        end
    else
        lines[#lines + 1] = "不在队伍或团队中，跳过聊天发送"
    end
    local addonCh, target = ch, nil
    if not addonCh then
        addonCh, target = "WHISPER", UnitName("player")
    end
    lines[#lines + 1] = TrySend("C_ChatInfo.SendAddonMessage(" .. addonCh .. ")",
        C_ChatInfo and C_ChatInfo.SendAddonMessage, PREFIX, "SEND\t" .. Now(), addonCh, target)
    rec.results = lines
    Push(DB.send, rec)
    Print("发送测试 首领战=" .. rec.enc .. " 锁定=" .. rec.lock .. " 战斗=" .. rec.combat)
    for _, l in ipairs(lines) do Print(l) end
end

------------------------------------------------------------------------
-- /rwprobe flood N
------------------------------------------------------------------------

local function CmdFlood(arg)
    local n = tonumber(arg) or 60
    if n < 1 then n = 1 end
    if n > 500 then n = 500 end
    local send = C_ChatInfo and C_ChatInfo.SendAddonMessage
    if not send then Print("C_ChatInfo.SendAddonMessage 不存在") return end
    local ch, target = GroupChannel(), nil
    if not ch then ch, target = "WHISPER", UnitName("player") end
    local run = time()
    local results, counts, errors = {}, {}, 0
    state.flood = { run = run, selfRecv = 0 }
    local t0 = debugprofilestop and debugprofilestop() or 0
    for i = 1, n do
        local ok, r = pcall(send, PREFIX, "F\t" .. run .. "\t" .. i, ch, target)
        local s = ok and AddonResultName(r) or ("err:" .. Esc(tostring(r)))
        if not ok then errors = errors + 1 end
        results[i] = s
        counts[s] = (counts[s] or 0) + 1
    end
    local elapsed = debugprofilestop and (debugprofilestop() - t0) or 0
    local rec = { time = Now(), run = run, n = n, channel = ch, enc = EncounterState(),
        lock = LockdownState(), elapsedMs = elapsed, counts = counts, results = table.concat(results, " ") }
    Push(DB.flood, rec)
    local summary = {}
    for k, v in pairs(counts) do summary[#summary + 1] = k .. " ×" .. v end
    Print(("已连发 %d 条（%s，%.0f 毫秒）。返回值统计：%s"):format(n, ch, elapsed, table.concat(summary, "；")))
    if C_Timer and C_Timer.After then
        for _, delay in ipairs({ 5, 20 }) do
            C_Timer.After(delay, function()
                local got = state.flood and state.flood.run == run and state.flood.selfRecv or 0
                rec["selfRecvAfter" .. delay .. "s"] = got
                Print(("flood %d：%d 秒后本机收到自己发的 %d / %d 条"):format(run, delay, got, n))
            end)
        end
    end
end

------------------------------------------------------------------------
-- /rwprobe loot 与 LOOT_OPENED 自动记录
------------------------------------------------------------------------

local function FrameKeys(f)
    if type(f) ~= "table" then return type(f) end
    local keys = {}
    for _, k in ipairs(SortKeys(f)) do
        if type(k) == "string" and k ~= "0" then keys[#keys + 1] = k .. ":" .. type(f[k]) end
        if #keys >= 80 then keys[#keys + 1] = "..." break end
    end
    local desc = {}
    if f.GetObjectType then
        local ok, ot = pcall(f.GetObjectType, f)
        desc[#desc + 1] = "type=" .. (ok and tostring(ot) or "?")
    end
    if f.IsShown then
        local ok, s = pcall(f.IsShown, f)
        desc[#desc + 1] = "shown=" .. (ok and tostring(s) or "?")
    end
    if f.IsProtected then
        local ok, p = pcall(f.IsProtected, f)
        desc[#desc + 1] = "protected=" .. (ok and tostring(p) or "?")
    end
    return table.concat(desc, " ") .. " keys=" .. table.concat(keys, " ")
end

local function RecordLoot(source, ...)
    local rec = { time = Now(), source = source, args = FmtAll(...), enc = EncounterState() }
    if C_PartyInfo and C_PartyInfo.GetLootMethod then
        rec.C_PartyInfo_GetLootMethod = Call(C_PartyInfo.GetLootMethod)
    end
    if _G.GetLootMethod then rec.GetLootMethod = Call(_G.GetLootMethod) end
    if Enum and type(Enum.LootMethod) == "table" then
        local parts = {}
        for _, k in ipairs(SortKeys(Enum.LootMethod)) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(Enum.LootMethod[k]) end
        rec.EnumLootMethod = table.concat(parts, " ")
    end
    if C_Loot and C_Loot.IsLegacyLootModeEnabled then
        rec.IsLegacyLootModeEnabled = Call(C_Loot.IsLegacyLootModeEnabled)
    end
    local num = 0
    if GetNumLootItems then
        local ok, r = pcall(GetNumLootItems)
        if ok and not IsSecret(r) and type(r) == "number" then num = r end
        rec.numItems = ok and Fmt(r) or "err"
    end
    local slots = {}
    for i = 1, num do
        local s = { }
        if GetLootSlotLink then s.link = Call(GetLootSlotLink, i) end
        if GetLootSlotInfo then s.info = Call(GetLootSlotInfo, i) end
        if GetLootSlotType then s.slotType = Call(GetLootSlotType, i) end
        if GetMasterLootCandidate then
            local cands = {}
            for j = 1, 40 do
                local ok, c = pcall(GetMasterLootCandidate, i, j)
                if not ok then cands[#cands + 1] = "err:" .. Esc(tostring(c)) break end
                if c ~= nil then cands[#cands + 1] = j .. "=" .. Fmt(c) end
            end
            s.candidates = #cands > 0 and table.concat(cands, " ") or "(无)"
        end
        slots[i] = s
    end
    rec.slots = slots
    rec.MasterLooterFrame = FrameKeys(_G.MasterLooterFrame)
    rec.LootFrame = FrameKeys(_G.LootFrame)
    rec.GroupLootDropDown = type(_G.GroupLootDropDown)
    Push(DB.loot, rec)
    return rec
end

local function CmdLoot()
    local rec = RecordLoot("command")
    Print("拾取方式: " .. tostring(rec.C_PartyInfo_GetLootMethod or rec.GetLootMethod or "接口不存在"))
    Print("拾取格子数: " .. tostring(rec.numItems))
    for i, s in ipairs(rec.slots) do
        Print(("格子 %d: %s  信息: %s"):format(i, tostring(s.link), tostring(s.info)))
        if s.candidates then Print("  候选人: " .. s.candidates) end
    end
    Print("MasterLooterFrame: " .. rec.MasterLooterFrame:sub(1, 120))
    Print("已写入 RaidWishProbeDB.loot（第 " .. #DB.loot .. " 条）")
end

------------------------------------------------------------------------
-- /rwprobe menu
------------------------------------------------------------------------

local MENU_TAGS = {
    "MENU_UNIT_SELF", "MENU_UNIT_PARTY", "MENU_UNIT_RAID", "MENU_UNIT_RAID_PLAYER",
    "MENU_UNIT_PLAYER", "MENU_UNIT_FRIEND", "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_TARGET",
    "MENU_UNIT_FOCUS", "MENU_UNIT_CHAT_ROSTER", "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
    "MENU_UNIT_GUILD", "MENU_UNIT_BN_FRIEND",
}

local function DescribeContext(ctx)
    if type(ctx) ~= "table" then return Fmt(ctx) end
    local parts = {}
    for _, k in ipairs(SortKeys(ctx)) do
        local v = ctx[k]
        local s = type(v) == "table" and "table" or Fmt(v)
        parts[#parts + 1] = tostring(k) .. "=" .. s
    end
    return table.concat(parts, " ")
end

local function HookMenus(silent)
    if state.menuHooked then
        if not silent then Print("菜单钩子已挂上。右键团队成员、队友、自己、聊天里的名字试试。") end
        return
    end
    if not (Menu and Menu.ModifyMenu) then
        if not silent then Print("|cffff5555Menu.ModifyMenu 不存在|r") end
        DB.menu.modifyMenu = "missing"
        return
    end
    local results = {}
    for _, tag in ipairs(MENU_TAGS) do
        local ok, err = pcall(Menu.ModifyMenu, tag, function(_, root, ctx)
            local line = Now() .. " tag=" .. tag .. " ctx: " .. DescribeContext(ctx)
            Push(DB.menu, line)
            Print("菜单触发 " .. tag)
            pcall(function()
                root:CreateDivider()
                root:CreateTitle("RaidWishProbe: " .. tag)
            end)
        end)
        results[#results + 1] = tag .. (ok and ":ok" or (":err " .. Esc(tostring(err))))
    end
    state.menuHooked = true
    DB.menuOn = true
    DB.menu.hookResults = table.concat(results, " ")
    if not silent then
        Print("已对 " .. #MENU_TAGS .. " 个候选 tag 挂钩（重载后自动保持）。右键团队成员、队友、自己、聊天里的名字，菜单底部会显示实际的 tag 名。")
        if Menu.PrintOpenMenuTags then Print("提示：菜单打开时也可以 /run Menu.PrintOpenMenuTags()") end
    end
end

------------------------------------------------------------------------
-- /rwprobe dump
------------------------------------------------------------------------

local function Serialize(v, ind, lines, key)
    local prefix = ind .. (key ~= nil and (tostring(key) .. " = ") or "")
    if type(v) ~= "table" then
        lines[#lines + 1] = prefix .. tostring(v)
        return
    end
    if next(v) == nil then
        lines[#lines + 1] = prefix .. "{}"
        return
    end
    lines[#lines + 1] = prefix .. "{"
    for _, k in ipairs(SortKeys(v)) do
        Serialize(v[k], ind .. "  ", lines, k)
    end
    lines[#lines + 1] = ind .. "}"
end

local dumpFrame

local function CreateDumpFrame()
    local f = CreateFrame("Frame", "RaidWishProbeDumpFrame", UIParent)
    f:SetSize(760, 520)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.07, 0.08, 0.95)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("RaidWishProbe 探测结果 · 按 Ctrl+A 全选、Ctrl+C 复制（文中 || 表示原文的 |）")

    local function MakeButton(text, x)
        local b = CreateFrame("Button", nil, f)
        b:SetSize(70, 22)
        b:SetPoint("TOPRIGHT", x, -6)
        local t = b:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints()
        t:SetColorTexture(0.2, 0.22, 0.26, 1)
        b:SetNormalFontObject(GameFontHighlight)
        b:SetText(text)
        return b
    end
    local close = MakeButton("关闭", -8)
    close:SetScript("OnClick", function() f:Hide() end)
    local selAll = MakeButton("全选", -84)

    local ok, sf = pcall(CreateFrame, "ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    local hasBar = ok and sf
    if not hasBar then sf = CreateFrame("ScrollFrame", nil, f) end
    sf:SetPoint("TOPLEFT", 12, -36)
    sf:SetPoint("BOTTOMRIGHT", hasBar and -32 or -12, 12)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetMaxLetters(0)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(700)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() f:Hide() end)
    eb:SetScript("OnTextChanged", function(self, userInput)
        if userInput and f.text then self:SetText(f.text) end
    end)
    sf:SetScrollChild(eb)

    if not hasBar then
        sf:EnableMouseWheel(true)
        sf:SetScript("OnMouseWheel", function(self, delta)
            local v = self:GetVerticalScroll() - delta * 60
            local max = self:GetVerticalScrollRange()
            if v < 0 then v = 0 elseif v > max then v = max end
            self:SetVerticalScroll(v)
        end)
    end

    selAll:SetScript("OnClick", function() eb:SetFocus() eb:HighlightText() end)
    f.edit = eb
    tinsert(UISpecialFrames, "RaidWishProbeDumpFrame")
    return f
end

local function CmdDump()
    local lines = { "-- RaidWishProbe dump " .. date("%Y-%m-%d %H:%M:%S") }
    Serialize(DB, "", lines, "RaidWishProbeDB")
    local text = table.concat(lines, "\n")
    dumpFrame = dumpFrame or CreateDumpFrame()
    dumpFrame.text = text
    dumpFrame.edit:SetText(text)
    dumpFrame.edit:SetCursorPosition(0)
    dumpFrame:Show()
    Print(("已打开结果窗口（%d 行，%d 字节）。也可以直接把存档文件 WTF/Account/<账号>/SavedVariables/RaidWishProbe.lua 发给开发者。"):format(#lines, #text))
end

------------------------------------------------------------------------
-- 事件
------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local registered = {}

local function Reg(event)
    local ok, err = pcall(frame.RegisterEvent, frame, event)
    registered[event] = ok and "ok" or ("err:" .. tostring(err))
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ADDON then return end
        InitDB()
        DB.misc.registeredEvents = registered
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            DB.misc.prefixRegister = Call(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
        else
            DB.misc.prefixRegister = "C_ChatInfo.RegisterAddonMessagePrefix 不存在"
        end
        return
    end
    if not DB then return end

    if event == "PLAYER_LOGIN" then
        if DB.menuOn then HookMenus(true) end
        Print("已加载。/rwprobe 查看命令。聊天记录：" .. (DB.chatOn and "开" or "关") .. "，前缀注册：" .. tostring(DB.misc.prefixRegister))
        return
    end

    if event == "ENCOUNTER_START" or event == "ENCOUNTER_END" then
        local id, name = ...
        if event == "ENCOUNTER_START" then
            state.inEncounter = true
            state.encounter = Fmt(id) .. "/" .. Fmt(name)
        else
            state.inEncounter = false
        end
        Push(DB.chatLog, Now() .. " " .. event .. " " .. FmtAll(...) .. " lock=" .. LockdownState())
        if DB.chatOn then Print(event .. " " .. FmtAll(...)) end
        return
    end

    if event == "LOOT_OPENED" or event == "OPEN_MASTER_LOOT_LIST" or event == "UPDATE_MASTER_LOOT_LIST" then
        local rec = RecordLoot(event, ...)
        Print(event .. "：已自动记录拾取信息（" .. tostring(rec.numItems) .. " 格），方式 " ..
            tostring(rec.C_PartyInfo_GetLootMethod or rec.GetLootMethod or "?"))
        return
    end

    if event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
        return
    end

    if CHAT_EVENT_SET[event] then
        if DB.chatOn then
            local secret = LogEvent(event, ...)
            if secret then Print(event .. "：参数含保密值（已记录）") end
        end
        return
    end
end)

Reg("ADDON_LOADED")
Reg("PLAYER_LOGIN")
Reg("ENCOUNTER_START")
Reg("ENCOUNTER_END")
Reg("LOOT_OPENED")
Reg("OPEN_MASTER_LOOT_LIST")
Reg("UPDATE_MASTER_LOOT_LIST")
for _, e in ipairs(CHAT_EVENTS) do Reg(e) end

------------------------------------------------------------------------
-- 斜杠命令
------------------------------------------------------------------------

local function Help()
    Print("命令：")
    Print("  /rwprobe info    客户端版本、Interface 号、角色名格式")
    Print("  /rwprobe api     接口、全局字符串、事件是否存在")
    Print("  /rwprobe tpl     界面模板是否可用")
    Print("  /rwprobe chat on|off   记录聊天事件（含保密值检测）")
    Print("  /rwprobe send    发一条团队聊天和一条插件消息（首领战中测试）")
    Print("  /rwprobe flood N 连发 N 条插件消息测限流（默认 60）")
    Print("  /rwprobe loot    记录拾取窗口（开尸体时也会自动记录）")
    Print("  /rwprobe menu    给右键菜单挂探测项，确认 tag 名")
    Print("  /rwprobe dump    打开可复制的结果窗口")
    Print("  /rwprobe status  当前状态   /rwprobe reset  清空全部记录")
end

local function CmdStatus()
    local n = 0
    for _ in pairs(DB.floodRecv) do n = n + 1 end
    Print(("聊天记录 %s（%d 条）；发送测试 %d 次；flood %d 次（收到 %d 组）；拾取记录 %d 条；菜单钩子 %s；首领战 %s"):format(
        DB.chatOn and "开" or "关", #DB.chatLog, #DB.send, #DB.flood, n, #DB.loot,
        state.menuHooked and "已挂" or "未挂", EncounterState()))
end

SLASH_RAIDWISHPROBE1 = "/rwprobe"
SlashCmdList["RAIDWISHPROBE"] = function(msg)
    if not DB then Print("存档尚未加载") return end
    msg = msg or ""
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "info" then CmdInfo()
    elseif cmd == "api" then CmdApi()
    elseif cmd == "tpl" then CmdTpl()
    elseif cmd == "chat" then CmdChat((rest or ""):lower())
    elseif cmd == "send" then CmdSend()
    elseif cmd == "flood" then CmdFlood(rest)
    elseif cmd == "loot" then CmdLoot()
    elseif cmd == "menu" then HookMenus(false)
    elseif cmd == "dump" then CmdDump()
    elseif cmd == "status" then CmdStatus()
    elseif cmd == "reset" then
        local chatOn, menuOn, misc = DB.chatOn, DB.menuOn, DB.misc
        RaidWishProbeDB = nil
        InitDB()
        DB.chatOn, DB.menuOn, DB.misc = chatOn, menuOn, misc
        Print("已清空全部记录（聊天记录开关和菜单钩子保持不变）")
    else
        Help()
    end
end
