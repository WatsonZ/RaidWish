-- Auction/AuctionModel.lua 的离线测试
local T = ...
local ns = T.load({ "Auction/AuctionModel.lua" })
local AM = ns.AuctionModel
local LINK = "[碧空之歌]"

-- 把动作列表转成便于断言的文字
local function chats(acts)
    local out = {}
    for _, a in ipairs(acts) do if a.type == "chat" then out[#out + 1] = a.channel .. ":" .. a.text end end
    return table.concat(out, " | ")
end
local function sends(acts)
    local out = {}
    for _, a in ipairs(acts) do
        if a.type == "send" then
            local args = {}
            for i, v in ipairs(a.args) do args[i] = tostring(v) end
            out[#out + 1] = a.cmd .. (#args > 0 and ("(" .. table.concat(args, ";") .. ")") or "")
        end
    end
    return table.concat(out, " | ")
end
local function has(acts, typ, field, value)
    for _, a in ipairs(acts) do if a.type == typ and a[field] == value then return a end end
end

-- 推进时间，收集全部动作
local function run(m, from, to, step)
    local all = {}
    local t = from
    while t <= to + 1e-9 do
        for _, a in ipairs(m:Tick(t)) do all[#all + 1] = a end
        t = t + (step or 0.1)
    end
    return all
end

T.eq(AM.ChineseNumeral(3), "三", "中文数字 3")
T.eq(AM.ChineseNumeral(12), "十二", "中文数字 12")
T.eq(AM.ChineseNumeral(40), "四十", "中文数字 40")

------------------------------------------------------------------------
-- 单人出分胜出
------------------------------------------------------------------------
local m = AM.New()
local acts = m:Start(19364, LINK, "甲", 0)
T.eq(m.state, "bid", "开拍进入出分阶段")
T.eq(chats(acts), "RAID_WARNING:开拍：" .. LINK .. "，请在团队频道出分", "开拍通报")
T.eq(sends(acts), "ASTART(19364)", "开拍消息")

acts = m:Bid("乙", 3, 2, function() return nil end)
T.eq(sends(acts), "ARESET(乙:3)", "出分后广播出分表并重新计时")
T.eq(m.phaseStart, 2, "出分重置计时")
T.eq(#run(m, 2, 8.9), 0, "出分后 7 秒内没有动作")
local all = run(m, 9, 13)
T.eq(chats(all), "RAID:3… | RAID:2… | RAID:1… | RAID_WARNING:出分截止！ | RAID_WARNING:乙 以三分拍得 " .. LINK .. "，拾取时自动扣分",
    "倒数与结算文案")
T.ok(has(all, "voice", "name", "countdown"), "倒数语音")
local r = has(all, "result", "winner", "乙")
T.ok(r and r.score == 3, "结算结果：乙 3 分")
T.ok(sends(all):find("AEND(19364)", 1, true) and sends(all):find("ASETTLED(19364;乙;s;3)", 1, true), "结束与结算消息")
T.eq(m.state, "settle", "结算展示")
run(m, 13, 16.5)
T.eq(m.state, "idle", "3 秒后回到空闲")

------------------------------------------------------------------------
-- 倒数中有人出分：回到出分阶段
------------------------------------------------------------------------
m = AM.New()
m:Start(1, LINK, "甲", 0)
run(m, 0, 7.5)
T.eq(m.state, "count", "第 7 秒开始倒数")
m:Bid("丙", 2, 8, nil)
T.eq(m.state, "bid", "倒数中出分回到出分阶段")
T.eq(m.phaseStart, 8, "重新计时")

------------------------------------------------------------------------
-- 同分进入 Roll
------------------------------------------------------------------------
m = AM.New()
m:Start(1, LINK, "甲", 0)
m:Bid("乙", 3, 1, nil)
m:Bid("丙", 3, 1.5, nil)
m:Bid("丁", 1, 1.6, nil)
m:Roll("丙", 50, 1, 100, 2)          -- 出分阶段提前 Roll：预收集
all = run(m, 2, 12)       -- 最后出分在 1.6 秒：第 8.6 秒开始倒数，约 11.6 秒结算
T.ok(chats(all):find("同分，请 乙、丙 /roll 决定归属", 1, true), "同分进入 Roll：通报名单")
T.ok(sends(all):find("AROLL(3;乙,丙)", 1, true), "Roll 名单消息")
T.eq(m.state, "roll", "进入 Roll 阶段")
T.ok(m:InRoll("乙") and not m:InRoll("丁"), "只有同分者在名单内")
T.eq(m.rolls["丙"], 50, "采纳出分阶段提前的 Roll")
local _, rec = m:Roll("丁", 99, 1, 100, 11.5)
T.ok(not rec, "名单外的 Roll 不算")
_, rec = m:Roll("乙", 30, 1, 50, 11.5)
T.ok(not rec, "范围不是 1-100 不算")
_, rec = m:Roll("乙", 80, 1, 100, 12)
T.ok(rec, "名单内的 Roll 记录")
T.eq(m.deadline, 12, "同分的人都掷完了：提前结束，不再等满 10 秒")
_, rec = m:Roll("乙", 100, 1, 100, 13)
T.ok(not rec, "每人只认第一次 Roll")
all = run(m, 12, 23)
T.ok(chats(all):find("乙 以 Roll 点 80 拿到 " .. LINK .. "，出价三分，拾取时自动扣分", 1, true), "Roll 结算文案")
r = has(all, "result", "winner", "乙")
T.ok(r and r.roll == 80 and r.score == 3, "结算结果含 Roll 点与出分")

-- Roll 再次同点：下一轮
m = AM.New()
m:Start(1, LINK, "甲", 0)
m:Bid("乙", 2, 0.5, nil); m:Bid("丙", 2, 0.6, nil)
run(m, 1, 11)
m:Roll("乙", 66, 1, 100, 11); m:Roll("丙", 66, 1, 100, 11)
all = run(m, 11, 15)
T.ok(chats(all):find("Roll 点相同，请 乙、丙 再 /roll 一次", 1, true), "同点进入下一轮")
T.eq(m.state, "roll", "仍在 Roll 阶段")
all = run(m, 15, 26)
T.ok(chats(all):find(LINK .. " 没人 Roll，流拍", 1, true), "下一轮没人 Roll：流拍")

------------------------------------------------------------------------
-- 无人出分：流拍
------------------------------------------------------------------------
m = AM.New()
m:Start(1, LINK, "甲", 0)
all = run(m, 0, 11)
T.ok(chats(all):find(LINK .. " 没人出分，流拍", 1, true), "无人出分流拍")
r = has(all, "result", "type", "result")
T.ok(r and r.winner == nil, "流拍结果没有赢家")

------------------------------------------------------------------------
-- 放弃、提前结束、取消、直接 Roll、出分校验
------------------------------------------------------------------------
m = AM.New()
m:Start(1, LINK, "甲", 0)
m:Bid("乙", 4, 1, nil)
acts = m:Pass("乙", 2)
T.eq(sends(acts), "ARESET()", "放弃后广播空出分表")
T.eq(m:BidCount(), 0, "出分记录移除")
acts = m:Early(3)
T.eq(m.state, "count", "数秒：直接进入倒数")
T.eq(chats(acts), "RAID:3…", "数秒立即发\"3…\"")
T.eq(sends(acts), "AEARLY", "数秒消息")
all = run(m, 3, 6.2)
local cs = chats(all)
T.ok(cs:find("出分截止！", 1, true), "数秒后出分结束")
T.ok(cs:find("RAID:1…", 1, true) < cs:find("出分截止！", 1, true), "\"一\"一定在\"出分截止！\"之前（隔开 1 秒发）")

m = AM.New()
m:Start(1, LINK, "甲", 0)
acts = m:Cancel()
T.eq(m.state, "idle", "取消回到空闲")
T.ok(sends(acts):find("ACANCEL", 1, true), "取消消息")

m = AM.New()
acts = m:DirectRoll(1, LINK, "甲", 0)
T.eq(chats(acts), "RAID_WARNING:全团 Roll：" .. LINK .. "，需要的请 /roll", "直接 Roll 通报")
T.ok(m:InRoll("任何人"), "直接 Roll：全团都在名单内")
m:Roll("戊", 77, 1, 100, 1)
all = run(m, 1, 12)
T.ok(chats(all):find("戊 以 Roll 点 77 拿到 " .. LINK, 1, true), "直接 Roll 结算不播报消费分数")

m = AM.New()
m:Start(1, LINK, "甲", 0)
acts = m:Bid("乙", 9, 1, function(_, s) return s >= 5 and "注意：乙 没有许愿这件装备，出的 9 分不算" or nil end)
T.eq(chats(acts), "RAID:注意：乙 没有许愿这件装备，出的 9 分不算", "无效出分发警告")
T.eq(m:BidCount(), 0, "无效出分不记录")

------------------------------------------------------------------------
-- 其他人的镜像
------------------------------------------------------------------------
local v = AM.New()
v:OnStart(1, "甲", 0)
T.eq(v.state, "bid", "镜像：开拍")
T.eq(#v:Tick(9), 0, "镜像不产生动作")
v:OnReset("乙:3,丙:2", 3)
local max, who = v:HighestBid()
T.eq(max .. ":" .. who[1], "3:乙", "镜像：同步出分表")
v:OnEarly(4)
T.eq(v.state, "count", "镜像：数秒")
v:OnEnd()
T.eq(v.state, "wait", "镜像：出分结束")
v:OnRoll("乙,丙", 6)
T.ok(v:InRoll("丙") and not v:InRoll("丁"), "镜像：Roll 名单")
v:OnEnd()
T.eq(v.state, "roll", "Roll 阶段忽略迟到的 AEND")
v:OnSettled(1, "乙", "r", "88", 20)
T.eq(v.result.roll, 88, "镜像：结算结果")
v:OnRoll("乙", 21)
T.eq(v.state, "settle", "结算阶段忽略迟到的 Roll 广播")
v:Tick(23.1)
T.eq(v.state, "idle", "镜像：3 秒后关闭")
v:OnStart(1, "甲", 30)
v:OnCancel()
T.eq(v.state, "idle", "镜像：取消")
local b, o = AM.DecodeBids("")
T.ok(next(b) == nil and #o == 0, "空出分表")

-- 比最高分低的出分不打断倒数
do
    local m2 = AM.New()
    m2:Start(19364, LINK, "甲", 0)
    m2:Bid("乙", 5, 1)
    run(m2, 1, 8.2)                                 -- 第 7 秒开始倒数
    T.eq(m2.state, "count", "最高分 5 分后进入倒数")
    local a2 = m2:Bid("丙", 2, 8.3)
    T.eq(m2.state, "count", "出 2 分（比 5 分低）不打断倒数")
    T.eq(m2.bids["丙"], 2, "低分照样记下")
    T.ok(not chats(a2):find("3…", 1, true), "低分不会重新喊 3")
    m2:Bid("丁", 5, 8.5)
    T.eq(m2.state, "bid", "追平最高分：重新计时（之后进 Roll）")
    run(m2, 8.5, 16.2)
    T.eq(m2.state, "count", "重新进入倒数")
    m2:Pass("丙", 16.3)
    T.eq(m2.state, "count", "非最高分的人放弃不打断倒数")
    m2:Pass("丁", 16.4)
    T.eq(m2.state, "bid", "最高分之一放弃：重新计时")
end

-- Roll 不重新计时：有人在倒数时 Roll，不会再倒数一遍
do
    local m3 = AM.New()
    m3:Start(1, LINK, "甲", 0)
    m3:Bid("乙", 2, 0.5, nil); m3:Bid("丙", 2, 0.6, nil)
    run(m3, 1, 11)
    T.eq(m3.state, "roll", "（前提）进入 Roll")
    local deadline = m3.deadline
    local a1 = run(m3, 11, deadline - 2.5)
    m3:Roll("乙", 40, 1, 100, deadline - 2.4)         -- 倒数开始后才 Roll
    T.eq(m3.deadline, deadline, "Roll 不重新计时")
    local a2 = run(m3, deadline - 2.4, deadline + 1)
    local cs3 = chats(a1) .. " | " .. chats(a2)
    local n3 = select(2, cs3:gsub("3…", ""))
    T.eq(n3, 1, "只倒数一次")
    T.ok(chats(a2):find("乙 以 Roll 点 40 拿到", 1, true), "时间到了按已有的 Roll 结算")
end

-- 全团 Roll：谁 Roll 都不重新计时，时间到才结算
do
    local m4 = AM.New()
    m4:DirectRoll(1, LINK, "甲", 0)
    m4:Roll("乙", 10, 1, 100, 5); m4:Roll("丙", 20, 1, 100, 9)
    T.eq(m4.deadline, AM.ROLL_TIME, "全团 Roll 不提前结束、不重新计时")
end

