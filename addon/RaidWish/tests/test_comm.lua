-- Core/Comm.lua 的离线测试（以及收发层在假环境下的行为）
local T = ...

------------------------------------------------------------------------
-- 假环境
------------------------------------------------------------------------

local clock = 100
local inRaid = true
local lockdown = false
local sendResults = {}      -- 依次返回的发送结果：{ ok, throttled }；空时默认成功
local sent = {}
local printed = {}
local events = {}
local tickerFn

local seed = {
    PROTOCOL = 2,
    VERSION = "3.0.0",
    Compat = {
        AnySecret = function(...)
            for i = 1, select("#", ...) do if select(i, ...) == "SECRET" then return true end end
            return false
        end,
        RegisterPrefix = function() return true end,
        InChatLockdown = function() return lockdown end,
        SendAddon = function(prefix, text, channel)
            local r = table.remove(sendResults, 1) or { true, false }
            if r[1] then sent[#sent + 1] = { prefix = prefix, text = text, channel = channel } end
            return r[1], r[2], r[3]
        end,
        AddonResultName = function(r) return tostring(r) end,
    },
    Events = {
        On = function(_, ev, fn) events[ev] = fn end,
        Off = function() end,
        Fire = function() return 0 end,
    },
    Slash = { Register = function() end, RegisterDebug = function() end },
    Ticker = function(_, fn)
        tickerFn = fn
        return { Cancel = function() tickerFn = nil end }
    end,
    After = function() return { Cancel = function() end } end,
    Print = function(m) printed[#printed + 1] = m end,
    Log = function() end,
    Debug = function() end,
    LogLevel = { ERROR = 0, WARN = 1 },
}
local globals = {
    GetTime = function() return clock end,
    IsInRaid = function() return inRaid end,
    UnitName = function() return "自己" end,
}
local ns = T.load({ "Core/Util.lua", "Core/Comm.lua" }, globals, seed)
local C = ns.Comm

local function tick(n)
    for _ = 1, n or 1 do
        if tickerFn then tickerFn() end
    end
end

local function drain()
    for _ = 1, 1000 do
        if not tickerFn then return end
        tickerFn()
    end
end

------------------------------------------------------------------------
-- 编码与解码
------------------------------------------------------------------------

local enc = C.Encode("W", 0, "甲", "WARRIOR", 4, "19364:0;n:某物品名:1")
T.eq(enc, "2\tW\t0\t甲\tWARRIOR\t4\t19364:0;n:某物品名:1", "Encode 格式")
local ver, cmd, f = C.Decode(enc)
T.eq(ver, 2, "Decode 版本")
T.eq(cmd, "W", "Decode 命令")
T.same(f, { "0", "甲", "WARRIOR", "4", "19364:0;n:某物品名:1" }, "往返一致")

local _, _, f2 = C.Decode(C.Encode("X", "a\tb", nil, true, false, "", "c"))
T.same(f2, { "a b", "", "1", "0", "", "c" }, "制表符换成空格、nil 为空串、布尔为 1/0、保留空字段")
local _, cmd2, f3 = C.Decode(C.Encode("REQ"))
T.eq(cmd2, "REQ", "无字段命令")
T.same(f3, {}, "无字段")
T.eq(C.Decode(""), nil, "空串")
T.eq(C.Decode("abc"), nil, "无版本号")
T.eq(C.Decode("2\t"), nil, "无命令")
T.eq(C.Decode(nil), nil, "非字符串")

------------------------------------------------------------------------
-- 分片与重组
------------------------------------------------------------------------

local zh = string.rep("许愿", 50)                    -- 300 字节，每字 3 字节
local pieces = C.Split(zh, 10)
for i, p in ipairs(pieces) do
    T.ok(#p <= 10, "片段不超长 " .. i)
    T.eq(#p % 3, 0, "不切断中文字符 " .. i)
end
T.eq(table.concat(pieces), zh, "Split 拼回原文")
T.same(C.Split("abcdefg", 4), { "abcd", "efg" }, "ASCII 按字节切")

local long = C.Encode("DBGBIG", 600, 1, string.rep("许愿助手ABC\t", 40))
local packed = C.Pack(long, 7)
T.ok(#packed > 1, "超长消息被分片")
for i, p in ipairs(packed) do T.ok(#p <= 255, "分片后每条不超过 255 字节 " .. i) end
T.same(C.Pack("2\tHELLO\t3.0.0", 1), { "2\tHELLO\t3.0.0" }, "不超长原样返回")

local r = C.Reassembler.New(5)
local full
for i, p in ipairs(packed) do
    local id, idx, tot, piece = C.ParsePart(p)
    T.eq(id, "7", "ParsePart 消息号")
    T.eq(idx, i, "ParsePart 序号")
    full = r:Add("甲", id, idx, tot, piece, 0)
    if i < #packed then T.eq(full, nil, "未收齐时返回 nil") end
end
T.eq(full, long, "按序重组，片段里的制表符保留")

-- 乱序
r = C.Reassembler.New(5)
full = nil
for i = #packed, 1, -1 do
    local id, idx, tot, piece = C.ParsePart(packed[i])
    full = r:Add("甲", id, idx, tot, piece, 0) or full
end
T.eq(full, long, "乱序也能重组")

-- 重复片段不计数
r = C.Reassembler.New(5)
local id1, i1, t1, p1 = C.ParsePart(packed[1])
r:Add("甲", id1, i1, t1, p1, 0)
T.eq(r:Add("甲", id1, i1, t1, p1, 0), nil, "重复片段不会凑齐")

-- 不同发送者互不干扰
r = C.Reassembler.New(5)
for i = 1, #packed - 1 do
    local id, idx, tot, piece = C.ParsePart(packed[i])
    r:Add("甲", id, idx, tot, piece, 0)
end
local idL, idxL, totL, pL = C.ParsePart(packed[#packed])
T.eq(r:Add("乙", idL, idxL, totL, pL, 0), nil, "别人的最后一片不能补齐")
T.eq(r:Add("甲", idL, idxL, totL, pL, 1), long, "自己的最后一片补齐")

-- 缺片超时
r = C.Reassembler.New(5)
r:Add("甲", id1, i1, t1, p1, 0)
T.eq(r:Purge(3), 0, "未超时不丢弃")
T.eq(r:Purge(6), 1, "超时丢弃")
T.eq(next(r.buffers), nil, "缓冲区已清空")

-- 非法序号
T.eq(r:Add("甲", 1, 0, 3, "x", 0), nil, "序号 0 无效")
T.eq(r:Add("甲", 1, 4, 3, "x", 0), nil, "序号超过总数无效")
T.eq(C.ParsePart("2\tW\t0"), nil, "非 PART 消息")

------------------------------------------------------------------------
-- 收发
------------------------------------------------------------------------

events.RW_LOADED()
local onAddon = events.CHAT_MSG_ADDON
T.ok(onAddon ~= nil, "加载后订阅 CHAT_MSG_ADDON")

-- 发送：入队并按节拍出队
T.eq(C:Send("HELLO", "3.0.0"), true, "在团队中可以发送")
T.eq(#sent, 0, "Send 只入队，不立即发出")
tick()
T.eq(#sent, 1, "第一拍发出一条")
T.eq(sent[1].prefix, "RaidWish", "前缀 RaidWish")
T.eq(sent[1].channel, "RAID", "团队频道")
T.eq(sent[1].text, "2\tHELLO\t3.0.0", "正文")
tick()
T.eq(tickerFn, nil, "队列空了停止定时器")

-- 顺序
sent = {}
for i = 1, 5 do C:Send("DBGF", i, 5) end
drain()
T.eq(#sent, 5, "全部发出")
local inOrder = true
for i, s in ipairs(sent) do if not s.text:find("\t" .. i .. "\t5$") then inOrder = false end end
T.ok(inOrder, "按入队顺序发出")

-- 不在团队
inRaid = false
T.eq(C:Send("HELLO"), false, "不在团队时 Send 返回 false")
inRaid = true

-- 限流退避
sent = {}
sendResults = { { false, true }, { false, true } }
C:Send("HELLO", "x")
tick()
T.eq(#sent, 0, "被限流：未发出")
tick()
T.eq(#sent, 0, "退避期内不重发")
clock = clock + 1.1
tick()
T.eq(#sent, 0, "第二次仍被限流")
clock = clock + 1.5
tick()
T.eq(#sent, 0, "退避时间翻倍（2 秒）未到")
clock = clock + 1
tick()
T.eq(#sent, 1, "退避结束后发出")
T.ok(C.stats.throttled >= 2, "统计限流次数")

-- 非限流失败：最多尝试 3 次后放弃
sent = {}
sendResults = { { false, false }, { false, false }, { false, false } }
local failedBefore = C.stats.failed
C:Send("HELLO", "y")
for _ = 1, 3 do tick(); clock = clock + 1.1 end
T.eq(C.stats.failed, failedBefore + 1, "三次失败后放弃")
T.eq(C:QueueLength(), 0, "放弃后移出队列")

-- 锁定期暂停与恢复
sent = {}
lockdown = true
C:Send("HELLO", "z")
tick(5)
T.eq(#sent, 0, "锁定期不发送")
T.eq(C:QueueLength(), 1, "消息留在队列里")
lockdown = false
tick()
T.eq(#sent, 1, "锁定结束后继续发送")

-- 离开团队时丢弃队列
C:Send("HELLO", "a")
C:Send("HELLO", "b")
inRaid = false
tick()
T.eq(C:QueueLength(), 0, "离队后队列清空")
inRaid = true

-- 分片发送：每条都不超过 255 字节
sent = {}
C:Send("DBGBIG", 1, 2, string.rep("测", 300))
drain()
T.ok(#sent > 1, "长消息分成多条发出")
local allShort = true
for _, s in ipairs(sent) do if #s.text > 255 then allShort = false end end
T.ok(allShort, "每条不超过 255 字节")

-- 接收分发
local got = {}
C:On("TEST", function(sender, a, b) got[#got + 1] = { sender, a, b } end)
onAddon("RaidWish", "2\tTEST\t1\t2", "RAID", "甲-无限")
T.same(got[1], { "甲", "1", "2" }, "发送者去掉服务器后缀，字段按顺序传入")
onAddon("RaidWish", "2\tTEST\t1\t2", "RAID", "自己-无限")
T.eq(#got, 1, "过滤自己发的消息")
onAddon("OTHER", "2\tTEST\t1", "RAID", "甲")
T.eq(#got, 1, "忽略其他前缀")
onAddon("RaidWish", "SECRET", "RAID", "甲")
onAddon("RaidWish", "2\tTEST", "RAID", "SECRET")
T.eq(#got, 1, "保密值直接忽略")
onAddon("RaidWish", "1\tTEST\tx", "RAID", "甲")
T.eq(#got, 1, "低版本协议的消息忽略")
onAddon("RaidWish", "3\tTEST\tx", "RAID", "甲")
onAddon("RaidWish", "3\tTEST\ty", "RAID", "乙")
T.eq(#got, 1, "高版本消息忽略")
local notices = 0
for _, m in ipairs(printed) do if m:find("更新版本") then notices = notices + 1 end end
T.eq(notices, 1, "高版本只提示一次")

-- 处理函数出错不影响其他处理函数
local second = 0
C:On("ERR", function() error("boom") end)
C:On("ERR", function() second = second + 1 end)
onAddon("RaidWish", "2\tERR", "RAID", "甲")
T.eq(second, 1, "一个处理函数出错，其余照常执行")

-- 接收分片消息
local bigGot
C:On("BIG", function(_, payload) bigGot = payload end)
local payload = string.rep("许愿助手测试", 30)
local parts = C.Pack(C.Encode("BIG", payload), 42)
for i = #parts, 1, -1 do onAddon("RaidWish", parts[i], "RAID", "甲") end
T.eq(bigGot, payload, "乱序到达的分片消息被重组并分发")

-- 分片超时后丢弃
bigGot = nil
onAddon("RaidWish", parts[1], "RAID", "乙")
clock = clock + 6
onAddon("RaidWish", "2\tTEST\t3\t4", "RAID", "甲")   -- 任何新消息都会触发清理
for i = 2, #parts do onAddon("RaidWish", parts[i], "RAID", "乙") end
T.eq(bigGot, nil, "超时后旧分片被丢弃，后来的分片凑不齐")
