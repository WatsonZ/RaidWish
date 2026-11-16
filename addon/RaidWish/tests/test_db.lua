-- Core/DB.lua 纯函数部分的离线测试
local T = ...
local ns = T.load({ "Core/DB.lua" })
local DB = ns.DB

-- 新存档：全部填默认值
local main, char = DB.Prepare(nil, nil)
T.eq(main.schema, DB.SCHEMA, "新存档 schema")
T.eq(main.options.defaultDkp, 4, "默认分 4")
T.eq(main.options.purpleMode, true, "仅紫模式默认开")
T.eq(main.options.xyOnly, false, "仅 xy 模式默认关")
T.eq(main.options.maxWishItems, 1, "每人最多许愿 1 件")
T.eq(DB.Prepare({ options = { maxWishItems = 0 } }).options.maxWishItems, 0, "设为 0（不限）后保持")
T.eq(main.options.clearOnLeaveMode, "ask", "退团清空默认询问")
T.eq(main.options.qualityFilters[4], true, "默认记录紫装")
T.eq(main.options.qualityFilters[3], false, "默认不记录蓝装")
T.eq(main.options.lootAssign.rollMax, 100, "Roll 上限")
T.eq(main.options.lootAssign.enabled, true, "增强拾取默认开")
T.eq(main.options.auction.voice, false, "语音默认关")
T.eq(main.options.ui.skin, "flat", "默认扁平暗色")
T.eq(char.mainScale, 1, "角色级缩放")

-- false 不会被默认值 true 覆盖
local m2 = DB.Prepare({ options = { autoAnnounce = false, lootAssign = { enabled = false },
    qualityFilters = { [4] = false } } })
T.eq(m2.options.autoAnnounce, false, "false 保持")
T.eq(m2.options.lootAssign.enabled, false, "嵌套 false 保持")
T.eq(m2.options.qualityFilters[4], false, "品质 false 保持")
T.eq(m2.options.qualityFilters[5], true, "缺失的品质补默认")
T.eq(m2.options.lootAssign.rollMin, 1, "嵌套缺失项补默认")

-- 类型不符时用默认值
local m3 = DB.Prepare({ options = { ui = "坏数据" } })
T.eq(m3.options.ui.skin, "flat", "类型不符时覆盖为默认")

-- 默认值是深拷贝，修改不会污染 defaults
main.options.qualityFilters[3] = true
local fresh = DB.Prepare(nil)
T.eq(fresh.options.qualityFilters[3], false, "默认表未被修改")

-- 已有数据保留
local m4 = DB.Prepare({ wishes = { ["甲"] = { dkp = 2 } } })
T.eq(m4.wishes["甲"].dkp, 2, "已有许愿数据保留")

-- 升级
DB.migrations[DB.SCHEMA + 1] = nil
local future = DB.Prepare({ schema = DB.SCHEMA + 5 })
T.eq(future.schema, DB.SCHEMA + 5, "来自更新版本的存档不降级")

local called = 0
local savedSchema = DB.SCHEMA
DB.SCHEMA = savedSchema + 1
DB.migrations[DB.SCHEMA] = function(t) called = called + 1; t.migrated = true end
local up = DB.Prepare({ schema = savedSchema })
T.eq(called, 1, "执行一次升级")
T.eq(up.migrated, true, "升级函数生效")
T.eq(up.schema, DB.SCHEMA, "升级后 schema")
DB.migrations[DB.SCHEMA] = nil
DB.SCHEMA = savedSchema

-- 公告与宣言取值
DB.options = { startText = nil, declaration = "" }
T.eq(DB:GetStartText(), DB.DEFAULT_START_TEXT, "公告为空用默认")
T.eq(DB:GetDeclaration(), DB.DEFAULT_DECLARATION, "宣言为空串用默认")
DB.options.startText = "自定义"
T.eq(DB:GetStartText(), "自定义", "自定义公告")

-- 改名字段的兼容
local mOld = DB.Prepare({ options = { autoMinDkp = false } })
T.eq(mOld.options.autoDeduct, false, "旧字段 autoMinDkp 的值沿用到 autoDeduct")
T.eq(mOld.options.autoMinDkp, nil, "旧字段删除")

-- 迁移 2：图标统一改回许愿星
T.eq(DB.Prepare({ schema = 1, options = { ui = { icon = "coin" } } }).options.ui.icon, "star", "旧存档的图标改回许愿星")
T.eq(DB.Prepare({ schema = 2, options = { ui = { icon = "dice" } } }).options.ui.icon, "dice", "新存档里自己选的图标保留")

