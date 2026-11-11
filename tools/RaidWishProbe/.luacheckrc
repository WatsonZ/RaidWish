-- 探测插件的 luacheck 配置。在 tools/RaidWishProbe 目录下运行：luacheck .
-- 探测插件要尽量多地读取可能不存在的接口，所以只读全局放得较宽。
std = "lua51"
max_line_length = false
codes = true
ignore = { "211/ADDON", "212/ns", "211/ns" }

globals = { "RaidWishProbeDB", "SLASH_RAIDWISHPROBE1", "SlashCmdList", "UISpecialFrames" }

read_globals = {
    "CreateFrame", "DEFAULT_CHAT_FRAME", "UIParent", "date", "time", "tinsert", "debugprofilestop",
    "GetBuildInfo", "GetLocale", "UnitFullName", "UnitName", "UnitLevel", "UnitClass",
    "GetNormalizedRealmName", "GetRealmName", "GetExpansionLevel", "GetMaxLevelForPlayerExpansion",
    "IsInRaid", "IsInGroup", "InCombatLockdown", "IsEncounterInProgress",
    "C_ChatInfo", "C_PartyInfo", "C_Loot", "C_Timer", "C_XMLUtil", "C_EventUtils", "Enum", "Menu",
    "GetNumLootItems", "GetLootSlotLink", "GetLootSlotInfo", "GetLootSlotType", "GetMasterLootCandidate",
    "GameFontNormal", "GameFontHighlight", "ChatFontNormal",
}
