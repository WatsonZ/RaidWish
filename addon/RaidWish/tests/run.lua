-- tests/run.lua：离线单元测试统一入口
-- 用法（在 addon/RaidWish 目录下）：lua5.1 tests/run.lua
-- 全部通过时退出码为 0，否则为 1。

local root = (arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]run%.lua$")) or "."
if root == "" then root = "." end

------------------------------------------------------------------------
-- 最小断言工具
------------------------------------------------------------------------

local T = { passed = 0, failed = 0, current = "" }

local function fmt(v)
    if type(v) == "string" then return ("%q"):format(v) end
    return tostring(v)
end

function T.eq(actual, expected, msg)
    if actual == expected then
        T.passed = T.passed + 1
    else
        T.failed = T.failed + 1
        print(("  失败 [%s] %s：期望 %s，实际 %s"):format(T.current, msg or "", fmt(expected), fmt(actual)))
    end
end

function T.ok(cond, msg) T.eq(not not cond, true, msg) end

-- 深比较两个表
function T.same(actual, expected, msg)
    local function deep(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for k, v in pairs(a) do if not deep(v, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end
    T.eq(deep(actual, expected), true, msg)
end

------------------------------------------------------------------------
-- 加载纯逻辑模块：用假的 ns 和最少的游戏全局
------------------------------------------------------------------------

-- 纯逻辑模块允许读取的游戏全局（测试里按需给出）
local fakeGlobals = {
    date = os.date,
    unpack = unpack,
}

-- 新建一个假 ns，并按顺序加载模块文件（相对插件根目录）。
-- extraGlobals：注入的游戏全局；seed：预先放进 ns 的假模块（如 Compat、Events）
function T.load(files, extraGlobals, seed)
    local ns = {}
    if seed then for k, v in pairs(seed) do ns[k] = v end end
    local env = setmetatable({}, { __index = function(_, k)
        if extraGlobals and extraGlobals[k] ~= nil then return extraGlobals[k] end
        if fakeGlobals[k] ~= nil then return fakeGlobals[k] end
        return _G[k]
    end })
    for _, f in ipairs(files) do
        local chunk, err = loadfile(root .. "/" .. f)
        if not chunk then error("无法加载 " .. f .. "：" .. tostring(err)) end
        setfenv(chunk, env)
        chunk("RaidWish", ns)
    end
    return ns, env
end

------------------------------------------------------------------------
-- 运行
------------------------------------------------------------------------

local SUITES = {
    "test_util",
    "test_db",
    "test_items",
    "test_comm",
    "test_wishmodel",
    "test_wishparser",
    "test_wishsync",
    "test_chat",
    "test_lootlog",
    "test_auction",
    "test_lootassign",
    "test_restore",
}

for _, name in ipairs(SUITES) do
    T.current = name
    local chunk, err = loadfile(root .. "/tests/" .. name .. ".lua")
    if not chunk then
        T.failed = T.failed + 1
        print("  无法加载 " .. name .. "：" .. tostring(err))
    else
        local before = T.failed
        local ok, e = pcall(chunk, T)
        if not ok then
            T.failed = T.failed + 1
            print(("  出错 [%s]：%s"):format(name, tostring(e)))
        end
        print(("%s %s"):format(T.failed == before and "通过" or "失败", name))
    end
end

print(("合计：通过 %d，失败 %d"):format(T.passed, T.failed))
if os.exit then os.exit(T.failed == 0 and 0 or 1) end
return T.failed == 0
