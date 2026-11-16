-- luacheck 配置。在 addon/RaidWish 目录下运行：luacheck .
std = "lua51"
max_line_length = false
codes = true
-- 单例模块用冒号方法（如 ns.Wish:IsLeader()），隐式 self 不用时不告警
self = false

exclude_files = { "tests/run.lua" }

-- "local ADDON, ns = ..." 里的 ADDON 允许不使用
ignore = { "211/ADDON" }

-- 可写的全局：存档变量、斜杠命令、按键绑定显示名、TOC 声明的函数
globals = {
    "RaidWishDB", "RaidWishCharDB",
    "SLASH_RAIDWISH1", "SLASH_RAIDWISH2",
    "BINDING_HEADER_RAIDWISH", "BINDING_NAME_RAIDWISH_TOGGLE",
    "RaidWish_OnCompartmentClick",
    -- 暴雪的登记表：只往里加条目，不覆盖
    "SlashCmdList", "UISpecialFrames", "StaticPopupDialogs",
    "SLASH_RAIDWISHPM1", "SLASH_RAIDWISHPM2",
}

-- 只读的游戏全局（随着各阶段用到的接口逐步补充）
read_globals = {
    "CreateFrame", "DEFAULT_CHAT_FRAME", "UIParent", "geterrorhandler", "date", "debugstack", "UISpecialFrames",
    "C_Timer", "C_ChatInfo", "C_Item", "C_PartyInfo", "Enum",
    "issecretvalue", "SendChatMessage", "GetItemInfo", "GetItemIcon", "GetLootMethod",
    "RAID_CLASS_COLORS",
    "GetTime", "IsInRaid", "UnitName", "time", "UNKNOWNOBJECT",
    "GetNumGroupMembers", "GetRaidRosterInfo", "UnitIsGroupLeader", "UnitIsGroupAssistant",
    "IsEncounterInProgress", "StaticPopup_Show",
    "tinsert", "STANDARD_TEXT_FONT", "ITEM_QUALITY_COLORS", "GameTooltip", "MenuUtil",
    "IsShiftKeyDown", "ChatEdit_InsertLink", "GetCursorPosition", "InCombatLockdown", "ReloadUI",
    "CreateColor", "Menu", "Minimap", "UnitInRaid", "IsInGroup",
    "RandomRoll", "GetCursorInfo", "ClearCursor", "HandleModifiedItemClick", "hooksecurefunc", "PlaySoundFile", "RaidWishVoicePack",
}

-- 离线测试：在普通 Lua 5.1 下运行，加载模块时用 setfenv 注入假环境
files["tests/"] = {
    globals = {},
    read_globals = {},
}
