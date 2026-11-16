-- Core/Comm.lua：通讯层
-- 只注册一个前缀 RaidWish，正文格式：<协议版本>\t<命令>\t<字段1>\t<字段2>...
-- 超长消息分片：<版本>\tPART\t<消息号>\t<序号>/<总数>\t<片段>
--
-- 文件分两部分：
--   1. 编码、分片、重组：纯逻辑，时间由调用方传入，可离线测试。
--   2. 收发、节流、锁定期排队：用到游戏接口，只在 RW_LOADED 之后启动。
local ADDON, ns = ...

local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "RaidWish"
Comm.MAX_BYTES = 255
Comm.SEP = "\t"
Comm.PART_TIMEOUT = 5         -- 分片重组超时（秒）
Comm.interval = 0.1           -- 出队间隔（秒）
Comm.BACKOFF_START = 1        -- 被限流后的首次退避（秒）
Comm.BACKOFF_MAX = 8
Comm.MAX_TRIES = 3            -- 非限流类失败的最多尝试次数

local function Version() return ns.PROTOCOL or 2 end

------------------------------------------------------------------------
-- 1. 编码与解码
------------------------------------------------------------------------

-- 字段转字符串：nil → ""，布尔 → "1" / "0"；制表符替换为空格，去掉 \0
local function FieldText(v)
    if v == nil then return "" end
    if v == true then return "1" end
    if v == false then return "0" end
    local s = tostring(v)
    s = s:gsub("\t", " "):gsub("%z", "")
    return s
end

function Comm.Encode(cmd, ...)
    local parts = { tostring(Version()), FieldText(cmd) }
    local n = select("#", ...)
    for i = 1, n do
        parts[#parts + 1] = FieldText((select(i, ...)))
    end
    return table.concat(parts, Comm.SEP)
end

-- 按制表符拆分，保留空字段
function Comm.SplitFields(text)
    local fields = {}
    local pos = 1
    while true do
        local s = text:find(Comm.SEP, pos, true)
        if not s then
            fields[#fields + 1] = text:sub(pos)
            break
        end
        fields[#fields + 1] = text:sub(pos, s - 1)
        pos = s + 1
    end
    return fields
end

-- 返回 version（数字）、cmd、fields（命令之后的字段数组）；格式不对返回 nil
function Comm.Decode(text)
    if type(text) ~= "string" or text == "" then return nil end
    local f = Comm.SplitFields(text)
    local ver = tonumber(f[1])
    local cmd = f[2]
    if not ver or not cmd or cmd == "" then return nil end
    local fields = {}
    for i = 3, #f do fields[#fields + 1] = f[i] end
    return ver, cmd, fields
end

------------------------------------------------------------------------
-- 分片
------------------------------------------------------------------------

-- 按字节切成每段不超过 max 字节的片段，不切断 UTF-8 多字节字符
function Comm.Split(text, max)
    assert(max and max >= 4, "Split: max 至少为 4")
    local pieces = {}
    local pos, len = 1, #text
    while pos <= len do
        local stop = pos + max - 1
        if stop >= len then
            stop = len
        else
            -- 下一个字节是续字节（10xxxxxx）说明切在了字符中间，往回退
            while stop > pos do
                local b = text:byte(stop + 1)
                if b < 0x80 or b >= 0xC0 then break end
                stop = stop - 1
            end
        end
        pieces[#pieces + 1] = text:sub(pos, stop)
        pos = stop + 1
    end
    return pieces
end

-- 把一条已编码的消息变成要实际发送的若干条（不超长时原样返回一条）
function Comm.Pack(encoded, msgId, max)
    max = max or Comm.MAX_BYTES
    if #encoded <= max then return { encoded } end
    -- 头部按最长情况预留：序号和总数各 3 位
    local headerLen = #(Comm.Encode("PART", msgId, "999/999", ""))
    local pieces = Comm.Split(encoded, max - headerLen)
    local out = {}
    for i, p in ipairs(pieces) do
        -- 片段原样拼接，不能走 Encode：片段里的制表符是原消息的分隔符
        out[i] = Comm.Encode("PART", msgId, i .. "/" .. #pieces, "") .. p
    end
    return out
end

------------------------------------------------------------------------
-- 重组器：按"发送者 + 消息号"收集分片，超时丢弃
------------------------------------------------------------------------

local Reassembler = {}
Reassembler.__index = Reassembler
Comm.Reassembler = Reassembler

function Reassembler.New(timeout)
    return setmetatable({ timeout = timeout or Comm.PART_TIMEOUT, buffers = {} }, Reassembler)
end

-- 加入一片。全部到齐时返回重组后的完整文本，否则返回 nil。
-- piece 可能含制表符（原消息的分隔符），调用方应把 PART 头之后的部分原样传入。
function Reassembler:Add(sender, msgId, index, total, piece, now)
    index, total = tonumber(index), tonumber(total)
    if not index or not total or total < 1 or index < 1 or index > total or total > 999 then return nil end
    local key = tostring(sender) .. "#" .. tostring(msgId)
    local buf = self.buffers[key]
    if buf and buf.total ~= total then buf = nil end   -- 总数对不上：重新开始
    if not buf then
        buf = { total = total, count = 0, parts = {}, first = now }
        self.buffers[key] = buf
    end
    if buf.parts[index] == nil then
        buf.parts[index] = piece
        buf.count = buf.count + 1
    end
    if buf.count < total then return nil end
    self.buffers[key] = nil
    return table.concat(buf.parts, "", 1, total)
end

-- 丢弃超时未收齐的消息，返回丢弃条数
function Reassembler:Purge(now)
    local dropped = 0
    for key, buf in pairs(self.buffers) do
        if now - buf.first > self.timeout then
            self.buffers[key] = nil
            dropped = dropped + 1
        end
    end
    return dropped
end

-- 解析 PART 消息原文：返回 msgId、index、total、piece；不是 PART 返回 nil
-- 不能用 Decode：片段里可能含制表符。
function Comm.ParsePart(text)
    local ver, msgId, index, total, piece = text:match("^(%d+)\tPART\t([^\t]*)\t(%d+)/(%d+)\t(.*)$")
    if not ver then return nil end
    return msgId, tonumber(index), tonumber(total), piece, tonumber(ver)
end

------------------------------------------------------------------------
-- 2. 收发（游戏接口）
------------------------------------------------------------------------

local handlers = {}           -- [cmd] = { fn... }
local queue = {}              -- { text=, tries=, notBefore= }
local ticker = nil
local backoff = 0
local msgCounter = 0
local selfName = nil
local reassembler = Reassembler.New()
local warnedNewer = false

Comm.stats = { queued = 0, sent = 0, throttled = 0, failed = 0, dropped = 0, received = 0, parts = 0 }

local function Now() return GetTime() end

local function SelfName()
    if not selfName then selfName = ns.Util.UnitFullName("player") end
    return selfName
end

local function NextMsgId()
    msgCounter = msgCounter % 9999 + 1
    return msgCounter
end

local function StopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

local function ProcessQueue()
    local item = queue[1]
    if not item then
        StopTicker()
        ns.Events:Fire("RW_COMM_IDLE")
        return
    end
    if not IsInRaid() then
        -- 离开团队：未发出的消息全部作废
        Comm.stats.dropped = Comm.stats.dropped + #queue
        queue = {}
        StopTicker()
        return
    end
    if ns.Compat.InChatLockdown() then return end          -- 锁定期：留在队列里，结束后继续
    local now = Now()
    if item.notBefore and now < item.notBefore then return end
    local ok, throttled, raw = ns.Compat.SendAddon(Comm.PREFIX, item.text, "RAID")
    if ok then
        table.remove(queue, 1)
        Comm.stats.sent = Comm.stats.sent + 1
        backoff = 0
        return
    end
    if throttled then
        Comm.stats.throttled = Comm.stats.throttled + 1
        backoff = (backoff == 0) and Comm.BACKOFF_START or math.min(backoff * 2, Comm.BACKOFF_MAX)
        item.notBefore = now + backoff
        ns.Debug("插件消息被限流，" .. backoff .. " 秒后重发")
        return
    end
    item.tries = item.tries + 1
    if item.tries >= Comm.MAX_TRIES then
        table.remove(queue, 1)
        Comm.stats.failed = Comm.stats.failed + 1
        ns.Log(ns.LogLevel.WARN, "插件消息发送失败，已放弃：" .. ns.Compat.AddonResultName(raw))
    else
        item.notBefore = now + Comm.BACKOFF_START
    end
end

local function StartTicker()
    if not ticker then ticker = ns.Ticker(Comm.interval, ProcessQueue) end
end

-- 发送一条命令给全团。不在团队中时直接丢弃并返回 false。
function Comm.Send(_, cmd, ...)
    if not IsInRaid() then return false end
    local packed = Comm.Pack(Comm.Encode(cmd, ...), NextMsgId())
    for _, text in ipairs(packed) do
        queue[#queue + 1] = { text = text, tries = 0 }
    end
    Comm.stats.queued = Comm.stats.queued + #packed
    StartTicker()
    return true
end

function Comm.QueueLength(_) return #queue end

-- 订阅命令。handler(sender, field1, field2, ...)，sender 已经过 NormName。
function Comm.On(_, cmd, fn)
    local list = handlers[cmd]
    if not list then
        list = {}
        handlers[cmd] = list
    end
    list[#list + 1] = fn
end

function Comm.Off(_, cmd, fn)
    local list = handlers[cmd]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then table.remove(list, i) end
    end
end

local function Dispatch(sender, text)
    local ver, cmd, fields = Comm.Decode(text)
    if not ver then return end
    if ver > Version() then
        if not warnedNewer then
            warnedNewer = true
            ns.Print("团里有人使用了更新版本的许愿助手")
        end
        return
    end
    if ver < Version() then return end
    Comm.stats.received = Comm.stats.received + 1
    local list = handlers[cmd]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, sender, unpack(fields))
        if not ok then ns.Log(ns.LogLevel.ERROR, "处理插件消息 " .. cmd .. " 出错：" .. tostring(err)) end
    end
end

local function OnAddonMessage(prefix, text, channel, sender)
    -- 保密值检查必须是第一步
    if ns.Compat.AnySecret(prefix, text, channel, sender) then return end
    if prefix ~= Comm.PREFIX or type(text) ~= "string" or type(sender) ~= "string" then return end
    local name = ns.Util.NormName(sender)
    if name == "" or name == SelfName() then return end
    local now = Now()
    reassembler:Purge(now)
    local msgId, index, total, piece, ver = Comm.ParsePart(text)
    if msgId then
        if ver > Version() then return Dispatch(name, text) end   -- 交给版本检查给出提示
        Comm.stats.parts = Comm.stats.parts + 1
        local full = reassembler:Add(name, msgId, index, total, piece, now)
        if full then Dispatch(name, full) end
        return
    end
    Dispatch(name, text)
end

ns.Events:On("RW_LOADED", function()
    if not ns.Compat.RegisterPrefix(Comm.PREFIX) then
        ns.Log(ns.LogLevel.WARN, "插件消息前缀注册失败：" .. Comm.PREFIX)
    end
    ns.Events:On("CHAT_MSG_ADDON", OnAddonMessage)
end)

ns.Events:On("GROUP_LEFT", function()
    Comm.stats.dropped = Comm.stats.dropped + #queue
    queue = {}
    StopTicker()
end)

------------------------------------------------------------------------
-- 版本提示
------------------------------------------------------------------------

-- 版本号转成可比较的数字："1.2.3" → 10203
function Comm.VersionNumber(v)
    local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.?(%d*)")
    if not a then return nil end
    return tonumber(a) * 10000 + tonumber(b) * 100 + (tonumber(c) or 0)
end

-- 团员上线、进团时会互发 HELLO。平时不提示；对方版本和自己不一样时提示一次，方便提醒更新。
local versionNoted = {}
Comm:On("HELLO", function(sender, version)
    local mine, theirs = Comm.VersionNumber(ns.VERSION), Comm.VersionNumber(version)
    if not mine or not theirs or theirs == mine or versionNoted[sender] == version then return end
    versionNoted[sender] = version
    if theirs < mine then
        ns.Print(sender .. " 用的许愿助手是旧版本 " .. tostring(version) .. "（你的是 " .. ns.VERSION .. "），请提醒他更新")
    else
        ns.Print(sender .. " 用的许愿助手是新版本 " .. tostring(version) .. "（你的是 " .. ns.VERSION .. "），建议你也更新")
    end
end)
