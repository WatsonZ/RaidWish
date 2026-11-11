-- Wish/WishRestore.lua 纯逻辑部分的离线测试
local T = ...
local seed = { Events = { On = function() end, Off = function() end, Fire = function() end },
    Compat = { GetItemInfo = function() return nil end, RequestItem = function() end }, Log = function() end, LogLevel = { ERROR = 0 } }
local ns = T.load({ "Core/Util.lua", "Core/Items.lua", "Wish/WishModel.lua", "Loot/LootLog.lua", "Wish/WishRestore.lua" },
    { time = function() return 1800000000 end }, seed)
local R = ns.Restore
local officers = { ["乙"] = true, ["丁"] = true }
local function isOfficer(n) return officers[n] == true end

T.eq(R.PickResponder({ ["甲"] = 3, ["丙"] = 5 }, isOfficer), "丙", "没有助理时取名字字典序最小（UTF-8 字节序）")
T.eq(R.PickResponder({ ["甲"] = 30, ["乙"] = 1 }, isOfficer), "乙", "助理优先，不看条数")
T.eq(R.PickResponder({ ["乙"] = 2, ["丁"] = 2 }, isOfficer), "丁" < "乙" and "丁" or "乙", "多个助理取字典序最小")
T.eq(R.PickResponder({ ["乙"] = 0, ["甲"] = 1 }, isOfficer), "甲", "没有数据的不算")
T.eq(R.PickResponder({}, isOfficer), nil, "没人回应")

T.eq(R.WishedCount({ a = { wish = { items = { { id = 1 } } } }, b = {}, c = { wish = { items = {} } } }), 1, "只数有许愿的记录")

-- 备份码往返
local wishes = {
    ["甲"] = { class = "WARRIOR", dkp = 6, wish = { items = { { id = 19364, done = true }, { name = "手打^物品;名", done = false } } } },
    ["乙"] = { class = "MAGE", dkp = 4 },
    ["丙"] = { class = "PRIEST", dkp = 3, wish = { items = { { name = "地板", floor = true, done = false } } } },
}
local loot = {
    { uid = 1, id = 19364, player = "甲", points = 3, wish = true, ts = 1799990000, sold = { winner = "甲", score = 3 } },
    { uid = 2, id = 30000, player = "乙", points = 0, wish = false, ts = 1799990100 },
    { uid = 3, id = 30001, player = "丙", points = 0, wish = false, ts = 1799990200, removed = true },
}
local code = R.EncodeBackup(wishes, loot, 1800000000, "甲")
local text = "以下是可读的名单\n战士-甲-...\n\n" .. code .. "\n后面还有别的文字"
local b, err = R.DecodeBackup(text)
T.ok(b ~= nil, "能从混着其他文字的内容里解出备份码：" .. tostring(err))
T.eq(b.ts, 1800000000, "备份时间")
T.eq(b.leader, "甲", "备份时的团长")
T.eq(b.wishes["甲"].dkp, 6, "分数")
T.eq(b.wishes["甲"].wish.items[1].id, 19364, "物品编号")
T.eq(b.wishes["甲"].wish.items[1].done, true, "完成标记")
T.eq(b.wishes["甲"].wish.items[2].name, "手打＾物品；名", "手打名字里的 ^ 和 ; 换成全角，不破坏格式")
T.eq(b.wishes["乙"].wish, nil, "未许愿")
T.ok(b.wishes["丙"].wish.items[1].floor, "地板许愿")
T.eq(#b.loot, 2, "已移除的掉落不导出")
T.same(b.loot[1].sold, { winner = "甲", score = 3 }, "拍卖结果")
T.eq(b.loot[1].wish, true, "是否许愿物品")
T.eq(select(2, R.DecodeBackup("随便一段文字")), "没有找到备份码（应以 RWB2: 开头）", "没有备份码")
T.ok(select(2, R.DecodeBackup(code:gsub(":END", ""))):find("不完整", 1, true) ~= nil, "缺结尾时提示不完整")
T.ok(code:find("甲", 1, true) == nil and code:find("19364", 1, true) == nil, "备份码里看不出名字和物品编号")
T.ok(select(2, R.DecodeBackup(code:sub(1, 40) .. code:sub(46))) ~= nil, "删掉中间几个字符时导入失败")
-- 改动任意一个 Base64 字符都应校验失败
local bodyStart = #"RWB2:" + 2
local bad = 0
for i = bodyStart, bodyStart + 30 do
    local ch = code:sub(i, i)
    if ch:match("[A-Za-z0-9]") then
        local rep = (ch == "A") and "B" or "A"
        if not R.DecodeBackup(code:sub(1, i - 1) .. rep .. code:sub(i + 1)) then bad = bad + 1 end
    end
end
T.ok(bad >= 25, "改动任意一个字符都校验失败（" .. bad .. " 处）")
T.eq(R.Unseal(R.Seal("中文^混合\n第二行 ABC")), "中文^混合\n第二行 ABC", "封装往返")
for n = 0, 5 do T.eq(R.Unseal(R.Seal(("x"):rep(n))), ("x"):rep(n), "长度 " .. n .. " 往返（Base64 补位）") end
-- 旧的明文格式不再接受
T.ok(not R.DecodeBackup("==RaidWish 备份 v1==^1^甲\nW^甲^WARRIOR^99^\n==结束=="), "明文备份码不接受（防手改）")

local st = { ["甲"] = { ts = 5, wish = { items = { { id = 1 } } } }, ["乙"] = { ts = 9, wish = { items = { { id = 2 } } } },
    ["丙"] = { ts = 99 } }
local n, here, last = R.Summary(st, function(name) return name == "甲" end)
T.eq(n .. "/" .. here .. "/" .. last, "2/1/9", "摘要：有许愿 2 条、在团 1 人、最后改动时间只看有许愿的")

