-- Wish/WishSync.lua 纯逻辑部分的离线测试
local T = ...
local seed = { Events = { On = function() end, Off = function() end, Fire = function() end } }
local ns = T.load({ "Wish/WishSync.lua" }, nil, seed)
local S = ns.WishSync

------------------------------------------------------------------------
-- 团长选举
------------------------------------------------------------------------

-- 团队：团长 甲(rank 2)，助理 乙、丙(rank 1)，普通成员 丁(rank 0)
local ranks = { ["甲"] = 2, ["乙"] = 1, ["丙"] = 1, ["丁"] = 0 }
local ctx = {
    inRaid = function(n) return ranks[n] ~= nil end,
    isOfficer = function(n) return (ranks[n] or 0) >= 1 end,
    isRaidLeader = function(n) return ranks[n] == 2 end,
}
local A = S.AcceptLead

T.ok(A({}, { name = "乙", term = 1 }, ctx), "无团长时接受助理")
T.ok(not A({}, { name = "丁", term = 1 }, ctx), "普通成员的 LEAD 被拒")
T.ok(not A({}, { name = "外人", term = 9 }, ctx), "不在团内的 LEAD 被拒")
T.ok(not A({}, { name = "乙" }, ctx), "缺任期号被拒")
T.ok(not A({ name = "乙", term = 5 }, { name = "丙", term = 4 }, ctx), "任期号更小被拒")
T.ok(A({ name = "乙", term = 5 }, { name = "丙", term = 6 }, ctx), "任期号更大接受")
T.ok(A({ name = "乙", term = 5 }, { name = "乙", term = 5 }, ctx), "同一人续任")
-- 同任期不同人：真实团长优先
T.ok(A({ name = "乙", term = 5 }, { name = "甲", term = 5 }, ctx), "同任期：真实团长胜")
T.ok(not A({ name = "甲", term = 5 }, { name = "乙", term = 5 }, ctx), "同任期：助理不能顶替团长")
-- 同任期都是助理：名字字典序小者胜，两端结果一致
local winBC = A({ name = "乙", term = 5 }, { name = "丙", term = 5 }, ctx)
local winCB = A({ name = "丙", term = 5 }, { name = "乙", term = 5 }, ctx)
T.ok(winBC ~= winCB, "同任期双助理：两种到达顺序结果互补")
T.eq(winBC, "丙" < "乙", "字典序小者胜")
-- 当前认定的人已离队或被降级
T.ok(A({ name = "离队者", term = 5 }, { name = "乙", term = 5 }, ctx), "当前团长已离队：同任期可接任")
ranks["丙"] = 0
T.ok(A({ name = "丙", term = 5 }, { name = "乙", term = 5 }, ctx), "当前团长被降级：同任期可接任")
T.ok(not A({ name = "乙", term = 5 }, { name = "丙", term = 6 }, ctx), "被降级的人任期号再大也被拒")
ranks["丙"] = 1

-- 模拟"两人同时点开始"：两个团员以不同顺序收到两条 LEAD，最终认定一致
local function converge(order)
    local cur = { term = 4 }
    for _, cand in ipairs(order) do
        if A(cur, cand, ctx) then cur = { name = cand.name, term = cand.term } end
    end
    return cur.name
end
local L1, L2 = { name = "乙", term = 5 }, { name = "丙", term = 5 }
T.eq(converge({ L1, L2 }), converge({ L2, L1 }), "同时开始：不同到达顺序结论一致")
local L3 = { name = "甲", term = 5 }
T.eq(converge({ L1, L3, L2 }), "甲", "三人同时开始：团长胜出")
T.eq(converge({ L3, L2, L1 }), "甲", "三人同时开始：任意顺序团长胜出")

------------------------------------------------------------------------
-- 全量同步接收器
------------------------------------------------------------------------

local R = S.Receiver.New(10)
T.ok(not R:Active(), "初始未在同步")
R:Begin(7, 2, 0)
T.ok(R:Active(), "Begin 后在同步")
T.ok(R:Row(7, "甲", { dkp = 4 }), "收一行")
T.ok(not R:Row(8, "乙", { dkp = 4 }), "别的批次的行不收")
local n, total = R:Progress()
T.eq(n .. "/" .. total, "1/2", "进度")
T.ok(R:Row("7", "甲", { dkp = 5 }), "同一人重复：覆盖，不重复计数")
n = R:Progress()
T.eq(n, 1, "重复行不计数")
T.ok(R:Row(7, "乙", { dkp = 3 }), "第二行")
local rows = R:End(7)
T.ok(rows ~= nil, "条数相符：返回完整数据")
T.eq(rows["甲"].dkp, 5, "取最后一次的值")
T.ok(not R:Active(), "结束后不在同步")

-- 缺行：条数不符，丢弃
R:Begin(9, 3, 0)
R:Row(9, "甲", {})
R:Row(9, "乙", {})
local r2, why = R:End(9)
T.eq(r2, nil, "条数不符返回 nil")
T.eq(why, "count", "原因：条数")
T.ok(not R:Active(), "条数不符后丢弃临时表")

-- 批次号不符：丢弃
R:Begin(10, 1, 0)
R:Row(10, "甲", {})
r2, why = R:End(11)
T.eq(r2, nil, "批次不符返回 nil")
T.eq(why, "batch", "原因：批次")
T.ok(R:Active(), "别的批次的结束标记不影响当前批次")
T.ok(R:End(10) ~= nil, "当前批次照常完成")

-- 没有 Begin 的 End
why = select(2, S.Receiver.New():End(1))
T.eq(why, "nobegin", "没有开始标记")

-- 超时
R:Begin(12, 2, 100)
R:Row(12, "甲", {})
T.ok(not R:Expire(105), "未超时")
T.ok(R:Expire(111), "超时丢弃")
T.ok(not R:Active(), "超时后不在同步")

-- 同步进行中的增量：不计数，结束时覆盖
R:Begin(13, 2, 0)
R:Row(13, "甲", { dkp = 4 })
R:Override("甲", { dkp = 1 })
R:Override("丙", { dkp = 9 })
R:Row(13, "乙", { dkp = 2 })
rows = R:End(13)
T.ok(rows ~= nil, "增量不影响条数校验")
T.eq(rows["甲"].dkp, 1, "增量覆盖全量里较早的行")
T.eq(rows["丙"].dkp, 9, "增量里的新成员也保留")
