-- Core/Compat.lua：有差异或未经确认的接口集中在这里做存在性判断
-- 其他模块不直接调用这些接口。探测结果（docs/探测结果.md）出来后在这里收紧。
local ADDON, ns = ...

local Compat = {}
ns.Compat = Compat

local C_ChatInfo = C_ChatInfo
local C_Item = C_Item
local C_PartyInfo = C_PartyInfo

-- 能力表：调试和界面降级用
Compat.has = {
    issecretvalue = type(issecretvalue) == "function",
    chatLockdown = C_ChatInfo ~= nil and type(C_ChatInfo.InChatMessagingLockdown) == "function",
    sendChatNS = C_ChatInfo ~= nil and type(C_ChatInfo.SendChatMessage) == "function",
    sendChatGlobal = type(SendChatMessage) == "function",
    itemNS = C_Item ~= nil and type(C_Item.GetItemInfo) == "function",
    lootMethodNS = C_PartyInfo ~= nil and type(C_PartyInfo.GetLootMethod) == "function",
    lootMethodGlobal = type(GetLootMethod) == "function",
}

------------------------------------------------------------------------
-- 保密值
------------------------------------------------------------------------

local issecret = issecretvalue

-- issecretvalue 不存在时恒为 false；调用出错时保守地当作保密值
function Compat.IsSecret(v)
    if not issecret then return false end
    local ok, r = pcall(issecret, v)
    if not ok then return true end
    return r and true or false
end

-- 任意一个参数是保密值就返回 true
function Compat.AnySecret(...)
    if not issecret then return false end
    for i = 1, select("#", ...) do
        if Compat.IsSecret((select(i, ...))) then return true end
    end
    return false
end

-- 是否处于聊天锁定（V3）。接口不存在时返回 false。
function Compat.InChatLockdown()
    if not Compat.has.chatLockdown then return false end
    local ok, r = pcall(C_ChatInfo.InChatMessagingLockdown)
    if not ok or Compat.IsSecret(r) then return false end
    return r and true or false
end

------------------------------------------------------------------------
-- 聊天与插件消息
------------------------------------------------------------------------

local sendChatFn = (Compat.has.sendChatNS and C_ChatInfo.SendChatMessage) or SendChatMessage

-- 发送聊天（V9）。language 参数一律传 nil。返回是否调用成功、错误信息。
-- 锁定期排队和权限降级在 ns.Chat，这里只负责调用。
function Compat.SendChat(text, chatType, target)
    if not sendChatFn then return false, "no SendChatMessage" end
    local ok, err = pcall(sendChatFn, text, chatType, nil, target)
    return ok, err
end

-- SendAddonMessage 返回值的含义（不写死数字，按 Enum 名称判断）
local addonResultEnum = Enum and Enum.SendAddonMessageResult
local addonResultName = {}
if type(addonResultEnum) == "table" then
    for k, v in pairs(addonResultEnum) do addonResultName[v] = k end
end

function Compat.AddonResultName(r)
    if r == nil or r == true then return "Success" end
    if r == false then return "Failed" end
    return addonResultName[r] or tostring(r)
end

-- 发送插件消息。返回 success（布尔）、throttled（布尔）、原始返回值。
function Compat.SendAddon(prefix, text, chatType, target)
    local fn = C_ChatInfo and C_ChatInfo.SendAddonMessage
    if not fn then return false, false, "no SendAddonMessage" end
    local ok, r = pcall(fn, prefix, text, chatType, target)
    if not ok then return false, false, r end
    -- 老接口返回布尔或无返回值；新接口返回 Enum.SendAddonMessageResult
    if r == nil or r == true then return true, false, r end
    if r == false then return false, false, r end
    if addonResultEnum and r == addonResultEnum.Success then return true, false, r end
    local name = addonResultName[r] or ""
    return false, name:find("Throttle") ~= nil, r
end

function Compat.RegisterPrefix(prefix)
    local fn = C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix
    if not fn then return false end
    local ok, r = pcall(fn, prefix)
    if not ok then return false end
    if r == nil or r == true then return true end
    if r == false then return false end
    -- 新接口可能返回枚举：0 视为成功（以探测结果为准）
    return r == 0
end

------------------------------------------------------------------------
-- 物品信息
------------------------------------------------------------------------

local getItemInfoFn = (Compat.has.itemNS and C_Item.GetItemInfo) or GetItemInfo
local getIconFn = (C_Item and C_Item.GetItemIconByID) or GetItemIcon

-- 返回 name, link, quality, icon；物品未缓存时返回 nil（异步获取在 Items.lua）
function Compat.GetItemInfo(item)
    if not getItemInfoFn then return nil end
    local ok, name, link, quality, _, _, _, _, _, _, icon = pcall(getItemInfoFn, item)
    if not ok or not name then return nil end
    if not icon and getIconFn and type(item) == "number" then
        local ok2, ic = pcall(getIconFn, item)
        if ok2 then icon = ic end
    end
    return name, link, quality, icon
end

-- 请求服务器加载物品数据，到达后触发 GET_ITEM_INFO_RECEIVED
function Compat.RequestItem(id)
    local fn = C_Item and C_Item.RequestLoadItemDataByID
    if fn then
        pcall(fn, id)
    elseif getItemInfoFn then
        pcall(getItemInfoFn, id)   -- 旧接口：查询本身就会触发加载
    end
end

function Compat.GetItemIcon(id)
    if not getIconFn then return nil end
    local ok, ic = pcall(getIconFn, id)
    if ok then return ic end
    return nil
end

------------------------------------------------------------------------
-- 拾取方式（V2）
------------------------------------------------------------------------

-- 返回拾取方式的原始值（新接口为 Enum.LootMethod 数字，旧接口为字符串），无接口时返回 nil
function Compat.GetLootMethod()
    local fn = (Compat.has.lootMethodNS and C_PartyInfo.GetLootMethod) or GetLootMethod
    if not fn then return nil end
    local ok, method = pcall(fn)
    if not ok then return nil end
    return method
end


