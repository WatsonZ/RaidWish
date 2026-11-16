-- Core/Init.lua：命名空间、版本、事件总线、定时、输出、斜杠命令入口
local ADDON, ns = ...

ns.ADDON = ADDON
ns.VERSION = "1.0.2"          -- 与 TOC 的 Version 保持一致
ns.TITLE = "RaidWish 许愿助手"
ns.SHORT_TITLE = "许愿助手"
ns.PROTOCOL = 2               -- 通讯协议版本

------------------------------------------------------------------------
-- 输出
------------------------------------------------------------------------

ns.LogLevel = { ERROR = 0, WARN = 1, INFO = 2, DEBUG = 3 }
ns.logLevel = ns.LogLevel.ERROR   -- 默认只显示错误

local LEVEL_TEXT = {
    [0] = "|cffff5555出错：|r",
    [1] = "|cffffcc00注意：|r",
    [2] = "|cff66ff66提示：|r",
    [3] = "|cff808080调试：|r",
}

local PREFIX = "|cff4aa3ff[" .. ns.SHORT_TITLE .. "]|r "

-- 面向用户的提示，总是显示
function ns.Print(msg)
    local cf = DEFAULT_CHAT_FRAME
    if cf then cf:AddMessage(PREFIX .. tostring(msg)) end
end

-- 分级调试输出，按 ns.logLevel 过滤
function ns.Log(level, msg)
    if level > ns.logLevel then return end
    local cf = DEFAULT_CHAT_FRAME
    if cf then cf:AddMessage(PREFIX .. (LEVEL_TEXT[level] or "") .. " " .. tostring(msg)) end
end

function ns.Debug(msg) ns.Log(ns.LogLevel.DEBUG, msg) end

-- 插件自己的报错：聊天框提示一次（同一条只提示一次），并记进存档 RaidWishDB.errors（最近 20 条），
-- 这样即使没开 scriptErrors 也能看到、能从存档里查。
local reported = {}
function ns.ReportError(err, where)
    local msg = tostring(err)
    local stack = debugstack and debugstack(3, 6, 0) or ""
    if not reported[msg] then
        reported[msg] = true
        ns.Print("|cffff5555出错|r" .. (where and ("（" .. where .. "）") or "") .. "：" .. msg)
    end
    local db = type(RaidWishDB) == "table" and RaidWishDB or nil
    if db then
        db.errors = type(db.errors) == "table" and db.errors or {}
        local list = db.errors
        list[#list + 1] = date("%m-%d %H:%M:%S") .. " " .. (where or "") .. " " .. msg .. "\n" .. stack
        while #list > 20 do table.remove(list, 1) end
    end
end

-- 调用 fn，出错时 ReportError 并返回 nil
function ns.SafeCall(where, fn, ...)
    local args = { n = select("#", ...), ... }
    local res
    local ok = xpcall(function() res = { fn(unpack(args, 1, args.n)) } end,
        function(e)
            ns.ReportError(e, where)
            local h = geterrorhandler and geterrorhandler()
            if h then pcall(h, e) end                -- 同时交给游戏的报错窗口（开了 scriptErrors 时显示）
        end)
    if ok then return unpack(res) end
end

------------------------------------------------------------------------
-- 事件总线
-- 游戏事件与内部事件同一套接口。内部事件一律以 "RW_" 开头，不注册到框体；
-- 其余视为游戏事件，有订阅者时才注册到唯一的事件框体。
-- 处理函数收到的是事件参数（不含事件名）。
------------------------------------------------------------------------

local Events = { handlers = {} }
ns.Events = Events

local eventFrame = CreateFrame("Frame")

local function IsInternal(event)
    return event:sub(1, 3) == "RW_"
end

local function Dispatch(event, ...)
    local list = Events.handlers[event]
    if not list or #list == 0 then return 0 end
    -- 复制一份再遍历，允许处理函数在回调中 On / Off
    local snapshot = {}
    for i = 1, #list do snapshot[i] = list[i] end
    local errHandler = geterrorhandler and geterrorhandler() or print
    for i = 1, #snapshot do
        local h = snapshot[i]
        if not h.removed then
            local ok, err = pcall(h.fn, ...)
            if not ok then
                ns.ReportError(err, event)
                errHandler(err)
            end
        end
    end
    return #snapshot
end

function Events:On(event, fn)
    assert(type(event) == "string" and type(fn) == "function", "Events:On(event, fn)")
    local list = self.handlers[event]
    if not list then
        list = {}
        self.handlers[event] = list
    end
    for i = 1, #list do
        if list[i].fn == fn then return fn end
    end
    list[#list + 1] = { fn = fn }
    if #list == 1 and not IsInternal(event) then
        local ok, err = pcall(eventFrame.RegisterEvent, eventFrame, event)
        if not ok then ns.Log(ns.LogLevel.WARN, "无法注册事件 " .. event .. "：" .. tostring(err)) end
    end
    return fn
end

function Events:Off(event, fn)
    local list = self.handlers[event]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i].fn == fn then
            list[i].removed = true
            table.remove(list, i)
        end
    end
    if #list == 0 then
        self.handlers[event] = nil
        if not IsInternal(event) then pcall(eventFrame.UnregisterEvent, eventFrame, event) end
    end
end

-- 只触发一次的订阅
function Events:Once(event, fn)
    local wrapper
    wrapper = function(...)
        self:Off(event, wrapper)
        fn(...)
    end
    return self:On(event, wrapper)
end

-- 触发内部事件，返回收到事件的处理函数个数
function Events.Fire(_, event, ...)
    return Dispatch(event, ...)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    Dispatch(event, ...)
end)

------------------------------------------------------------------------
-- 定时
------------------------------------------------------------------------

-- 延迟执行，返回可 :Cancel() 的句柄
function ns.After(sec, fn)
    if C_Timer.NewTimer then
        return C_Timer.NewTimer(sec, fn)
    end
    local handle = { cancelled = false }
    function handle:Cancel() self.cancelled = true end
    function handle:IsCancelled() return self.cancelled end
    C_Timer.After(sec, function()
        if not handle.cancelled then fn() end
    end)
    return handle
end

-- 周期执行，iterations 为 nil 时无限次，返回可 :Cancel() 的句柄
function ns.Ticker(sec, fn, iterations)
    return C_Timer.NewTicker(sec, fn, iterations)
end

-- 同一帧内多次调用只在下一帧执行一次（界面"脏标记"刷新用）
function ns.Debounce(fn)
    local pending = false
    return function()
        if pending then return end
        pending = true
        C_Timer.After(0, function()
            pending = false
            fn()
        end)
    end
end

------------------------------------------------------------------------
-- 斜杠命令
-- /xy、/xyt：不带参数开关主窗口；子命令见 /xy help。
------------------------------------------------------------------------

local Slash = { commands = {}, order = {} }
ns.Slash = Slash

-- 注册 /xy 的子命令。handler(rest) 收到子命令之后的参数文本。
function Slash:Register(name, handler, help)
    name = name:lower()
    if not self.commands[name] then self.order[#self.order + 1] = name end
    self.commands[name] = { fn = handler, help = help }
end

function ns.PrintVersion()
    ns.Print(ns.TITLE .. " v" .. ns.VERSION .. "（通讯协议 v" .. ns.PROTOCOL .. "）")
end

local function SplitCmd(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    return (cmd or ""):lower(), rest or ""
end

local function Help()
    ns.PrintVersion()
    ns.Print("  /xy  开关许愿窗口")
    for _, name in ipairs(Slash.order) do
        local h = Slash.commands[name].help
        if h then ns.Print("  /xy " .. name .. "  " .. h) end
    end
end

local function OnSlash(msg)
    local cmd, rest = SplitCmd(msg)
    if cmd == "" then
        if Events:Fire("RW_TOGGLE_MAIN") == 0 then ns.PrintVersion() end
        return
    end
    local c = Slash.commands[cmd]
    if c then
        c.fn(rest)
        return
    end
    if cmd ~= "help" then ns.Print("未知命令：" .. cmd) end
    Help()
end

SLASH_RAIDWISH1 = "/xy"
SLASH_RAIDWISH2 = "/xyt"
SlashCmdList["RAIDWISH"] = OnSlash

Slash:Register("version", ns.PrintVersion, "显示版本")
Slash:Register("about", function()
    ns.Main:Show("set")
    ns.Settings:Select("about")
end, "关于：版本、开源声明、联系作者")

-- 以下命令调用的模块在后面的文件里，执行时才取
Slash:Register("export", function() ns.Restore:ShowExport() end, "导出许愿表（含备份码）")
Slash:Register("import", function() ns.Restore:ShowImport() end, "导入备份码")

Slash:Register("rl", function()
    ns.DB.char.frames = {}
    ns.DB.char.minimap = {}
    Events:Fire("RW_RESET_POSITIONS")
    ns.Print("所有窗口和小地图按钮位置已重置")
end, "重置所有窗口和小地图按钮的位置")

Slash:Register("backup", function()
    if ns.Restore then ns.Restore:SaveSnapshot(true) end
end, "立即保存一份许愿快照")

Slash:Register("restore", function()
    if ns.Restore then ns.Restore:ShowSnapshot() end
end, "查看并恢复许愿快照")

Slash:Register("autobackup", function(rest)
    local mode = rest:lower()
    if mode == "on" or mode == "off" then
        ns.DB.options.autoBackup = (mode == "on")
        ns.Print("许愿数据自动快照：" .. mode)
    else
        ns.Print("用法：/xy autobackup on|off（当前：" .. (ns.DB.options.autoBackup and "on" or "off") .. "）")
    end
end, "开关自动快照 on|off")

------------------------------------------------------------------------
-- 按键绑定显示名、插件收纳入口
------------------------------------------------------------------------

BINDING_HEADER_RAIDWISH = ns.TITLE
BINDING_NAME_RAIDWISH_TOGGLE = "打开 / 关闭许愿助手"

-- TOC 的 AddonCompartmentFunc；Bindings.xml 也调用它
function RaidWish_OnCompartmentClick(_, button)
    if Events:Fire("RW_TOGGLE_MAIN", button) == 0 then
        ns.PrintVersion()
    end
end

------------------------------------------------------------------------
-- 生命周期：ADDON_LOADED 后初始化存档，再广播内部事件
------------------------------------------------------------------------

local function OnAddonLoaded(name)
    if name ~= ADDON then return end
    Events:Off("ADDON_LOADED", OnAddonLoaded)
    ns.DB:Init()
    Events:Fire("RW_LOADED")
end
Events:On("ADDON_LOADED", OnAddonLoaded)

Events:Once("PLAYER_LOGIN", function()
    Events:Fire("RW_LOGIN")
end)
