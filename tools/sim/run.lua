-- tools/sim/run.lua：在模拟的多客户端团队里跑一遍各阶段的"游戏内验收"流程。
-- 用法（在项目根目录）：
--   uv run --no-project --with lupa python -I tools/lua51.py tools/sim/run.lua
-- 全部通过时退出码为 0。
local here = arg[0]:match("^(.*)[/\\]") or "."
package.path = here .. "/?.lua;" .. package.path
local Sim = dofile(here .. "/wow.lua")
local ROOT = arg[1] or (here .. "/../../addon/RaidWish")

local L1 = "|cnIQ4:|Hitem:19364::::::::60:::::::::|h[碧空之歌]|h|r"
local L2 = "|cnIQ4:|Hitem:212395::::::::60:::::::::|h[迅击戒指]|h|r"
local L3 = "|cnIQ5:|Hitem:19019::::::::60:::::::::|h[雷霆之怒，逐风者的祝福之剑]|h|r"
Sim.items = {
    [19364] = { name = "碧空之歌", link = L1, quality = 4, icon = 135000 },
    [212395] = { name = "迅击戒指", link = L2, quality = 4, icon = 135001 },
    [19019] = { name = "雷霆之怒，逐风者的祝福之剑", link = L3, quality = 5, icon = 135002 },
}

local function section(t) print("== " .. t) end

local A = Sim.NewClient(ROOT, "甲", { class = "WARRIOR" })
local B = Sim.NewClient(ROOT, "乙", { class = "MAGE" })
local C = Sim.NewClient(ROOT, "丙", { class = "PRIEST" })
Sim.Join("甲", "WARRIOR", 2); Sim.Join("乙", "MAGE", 0); Sim.Join("丙", "PRIEST", 0)
Sim.Run(5)

local function leaderOf(c) return c.ns.DB.main.leader.name end

------------------------------------------------------------------------
-- 许愿核心
------------------------------------------------------------------------

section("开始许愿、录入、同步")
A.slash("debug start"); Sim.Run(3)
Sim.Check(leaderOf(A) == "甲" and leaderOf(B) == "甲" and leaderOf(C) == "甲", "三端都认定 甲 为许愿团长")
Sim.Check(B.ns.Wish:InProgress(), "团员端显示许愿进行中")
B.say("xy " .. L1); Sim.Run(3)
Sim.Check(A.ns.Wish.model:Get("乙").wish ~= nil, "团长端录入了 乙 的许愿")
Sim.Same(A, B, "甲、乙 许愿表一致")
Sim.Same(A, C, "甲、丙 许愿表一致")
Sim.Check(Sim.Printed(B, "你的许愿已记录"), "乙 收到录入反馈")

section("改许愿、重复警报、非法内容")
B.say("xy " .. L1 .. L2); Sim.Run(2)
local rec = A.ns.Wish.model:Get("乙")
Sim.Check(#rec.wish.items == 1 and rec.wish.items[1].id == 19364, "默认每人最多 1 件：两件只记第一件")
A.ns.DB.options.maxWishItems = 0              -- 后面的场景需要多件许愿
B.say("xy " .. L2 .. "[手打物品]"); Sim.Run(2)
C.say("XY" .. L2); Sim.Run(2)
B.say("xy 我要这个 " .. L1); Sim.Run(2)
Sim.Same(A, B, "改许愿后两端一致")
Sim.Same(A, C, "丙 一致")
Sim.Check(Sim.ChatHas("注意：迅击戒指 已有 2 人许愿"), "重复许愿警报")
Sim.Check(A.ns.Wish.model:Get("乙").wish.items[1].id == 212395, "非法内容不改原许愿")
C.say("xy 墓碑"); Sim.Run(2)
local dw = A.ns.Wish.model:Get("丙").wish
Sim.Check(dw and dw.items[1].name == "墓碑" and dw.items[1].text == true, "不带括号的文字（简称）也能许愿，标为人工处理")
Sim.Check(B.ns.Wish.model:Get("丙").wish.items[1].text == true, "简称许愿同步给团员时保留标记")
C.say("XY" .. L2); Sim.Run(2)                     -- 恢复 丙 原来的许愿，后面的场景要用
Sim.Check(Sim.ChatHas("「迅击戒指」有 2 人许愿："), "许愿团长发自动查询")
Sim.Check(not Sim.ChatHas("我已许愿"), "团员端不发\"我已许愿\"")

section("加减分、代许愿、标记完成")
A.ns.WishChat:AddDkp("乙", 2); A.ns.WishChat:MinusDkp("丙", 1)
A.say("txy 丙 [地板]"); Sim.Run(2)
A.ns.WishChat:MarkDone("乙"); Sim.Run(2)
Sim.Same(A, B, "加减分与完成标记同步")
Sim.Same(A, C, "丙 一致")
Sim.Check(Sim.ChatHas("乙 加 2 分，现有 6 分"), "加分通报文案")

section("退团重进")
Sim.Leave("丙"); Sim.Run(3)
C.ns.Wish.model:ClearAll()
Sim.Join("丙", "PRIEST", 0); Sim.Run(12)
Sim.Same(A, C, "重进后 丙 拿到完整许愿表")

------------------------------------------------------------------------
-- 主界面
------------------------------------------------------------------------

section("团长端主窗口")
A.slash("")
local mf = A.env.RaidWishMainFrame
Sim.Check(mf ~= nil and mf:IsShown(), "/xy 打开主窗口")
Sim.Check(A.env.UISpecialFrames[1] == "RaidWishMainFrame", "主窗口加入 UISpecialFrames（Esc 关闭）")
local stopBtn = Sim.FindButton(mf, "停止许愿")
Sim.Check(stopBtn ~= nil, "许愿进行中，主按钮为\"停止许愿\"")
Sim.Check(Sim.FindButton(mf, "更多") == nil, "没有\"更多\"菜单了")
for _, t in ipairs({ "开团公告", "宣言", "通报未许愿", "播报全部" }) do
    Sim.Check(Sim.FindButton(mf, t) ~= nil, "工具栏有\"" .. t .. "\"")
end
local unwishedBtn = Sim.FindButton(mf, "通报未许愿")
Sim.Click(unwishedBtn); Sim.Run(1)
Sim.Check(Sim.ChatHas("全员都已许愿") or Sim.ChatHas("还没许愿的有"), "通报未许愿名单")
Sim.Check(not unwishedBtn:IsEnabled(), "通报后 2 秒内置灰")
Sim.Run(1.5)
Sim.Check(unwishedBtn:IsEnabled(), "2 秒后恢复")
Sim.Check(mf.yield:IsShown(), "许愿团长的名字后面有\"让出\"")
local clearBtn = Sim.FindButton(mf, "清空许愿表")
Sim.Check(clearBtn and clearBtn:IsVisible(), "许愿页底部有\"清空许愿表\"")
Sim.Click(clearBtn)
Sim.Check(A.ns.Widgets.lastDialog == "RAIDWISH_RESET", "清空前要确认")
Sim.Check(A.ns.Wish:InProgress() and A.env.RaidWishDialog.ok._fs._text == "停止许愿并清空", "许愿进行中时清空：确定按钮是\"停止许愿并清空\"")
Sim.Click(A.env.RaidWishDialog.cancel)
Sim.Check(A.ns.Wish:InProgress(), "点取消：许愿照常进行、不清空")
Sim.Check(B.ns.WishChat:ConfirmClear() == false, "非许愿团长在许愿期间不能清空")
Sim.Click(mf.yield)
Sim.Check(A.ns.Widgets.lastDialog == "RAIDWISH_RELINQUISH" and A.env.RaidWishDialog:IsShown(), "让出前要确认（插件自己的弹窗）")
Sim.Click(A.env.RaidWishDialog.cancel)
Sim.Check(not A.env.RaidWishDialog:IsShown() and A.ns.Wish:IsLeader(), "点取消不让出")
Sim.Check(Sim.FindButton(mf, "保存") == nil, "去掉了\"立即保存\"")
Sim.Click(Sim.FindButton(mf, "播报全部")); Sim.Run(4)
Sim.Check(Sim.ChatHas("许愿播报完毕。"), "播报全部许愿")
Sim.Check(Sim.ChatHas("【许愿】乙（法师）"), "播报行格式")
Sim.Run(3)
Sim.Click(Sim.FindButton(mf, "宣言")); Sim.Run(3)
local i1, i2, i3
for i, l in ipairs(Sim.chatLog) do
    if l:find("1. 装备按许愿", 1, true) then i1 = i end
    if l:find("2. 中途无故离团", 1, true) then i2 = i end
    if l:find("3. 其他事宜", 1, true) then i3 = i end
end
Sim.Check(i1 and i2 and i3 and i1 < i2 and i2 < i3, "宣言逐行按顺序发出")
-- 数据类操作在 设置 → 数据
A.ns.Main:Show("set"); A.ns.Settings:Select("data")
local setPage
for _, c in ipairs(A.ns.Settings.cats) do if c.key == "data" then setPage = c.frame end end
for _, t in ipairs({ "设置", "导出", "导入", "恢复", "查看", "清空" }) do
    Sim.Check(Sim.FindButton(setPage, t) ~= nil, "设置 → 数据 有\"" .. t .. "\"")
end
Sim.Click(Sim.FindButton(setPage, "导出"))
Sim.Check(A.env.RaidWishTextDialog and A.env.RaidWishTextDialog:IsShown(), "导出窗口")
Sim.Click(Sim.FindButton(setPage, "设置"))
Sim.Check(A.ns.Widgets.lastDialog == "RAIDWISH_INIT_DKP", "初始分数输入框")
Sim.Click(A.env.RaidWishDialog.ok)   -- 默认值 4
Sim.Run(3)
Sim.Check(Sim.ChatHas("全团分数已重置为每人 4 分"), "初始化分数通报")
Sim.Same(A, B, "初始化分数后同步")
A.slash("about")
local aboutPage
for _, c in ipairs(A.ns.Settings.cats) do if c.key == "about" then aboutPage = c.frame end end
Sim.Check(aboutPage and aboutPage:IsShown(), "/xy about 打开 设置 → 关于")
Sim.Check(Sim.Find(aboutPage, function(w) return w._kind == "EditBox" and w._text == "dean.addon.wow@proton.me" end) ~= nil, "关于页显示联系邮箱")
Sim.Check(Sim.Find(aboutPage, function(w) return w._text and tostring(w._text):find("语音使用声明", 1, true) end) == nil, "没有真人语音时不显示语音声明")
Sim.Click(Sim.FindButton(aboutPage, "查看出错信息"))
Sim.Check(A.env.RaidWishTextDialog:IsShown(), "关于页可查看出错信息")
A.ns.Main:Show("wish")

-- 列表行
local ns = A.ns
local function findRow(name)
    return Sim.Find(mf, function(w) return w._kind == "Button" and w.data and w.data.name == name and w:IsShown() end)
end
local rowB = findRow("乙")
Sim.Check(rowB ~= nil, "列表里有 乙 的行")
rowB._mouseOver = true
rowB._scripts.OnEnter(rowB)
Sim.Check(rowB.plus:IsShown() and rowB.minus:IsShown(), "团长端悬停出现加减号")
Sim.Click(rowB.plus); Sim.Run(2)
Sim.Check(ns.Wish.model:Get("乙").dkp == 5, "点加号加 1 分")
rowB._mouseOver = false
rowB._scripts.OnLeave(rowB)
Sim.Check(not rowB.plus:IsShown(), "移开后加减号隐藏")
rowB = findRow("乙")
Sim.Click(rowB, "RightButton")
Sim.Check(Sim.MenuTexts(A) == "<乙>,通报此人许愿,增加分数,扣除分数,撤销完成,--,清除此人许愿", "行右键菜单：" .. Sim.MenuTexts(A))
Sim.ClickMenu(A, "扣除分数", "扣除2分"); Sim.Run(2)
Sim.Check(ns.Wish.model:Get("乙").dkp == 3, "右键扣 2 分")
Sim.Check(Sim.ChatHas("乙 扣 2 分，现有 3 分"), "扣分通报")

-- 底部计数与筛选
local function Chip(prefix)
    return Sim.Find(mf, function(w)
        return w._kind == "Button" and w._fs and w._fs._text and w._fs._text:sub(1, #prefix) == prefix and w:IsVisible()
    end)
end
local unwishedChip = Chip("未许愿 ")
Sim.Check(unwishedChip ~= nil, "底部有\"未许愿\"筛选标签：" .. tostring(unwishedChip and unwishedChip._fs._text))
Sim.Check(Chip("全部 ") and Chip("已许愿 ") and Chip("重复 ") and true, "底部有 全部 / 已许愿 / 重复 标签")
Sim.Click(unwishedChip)
Sim.Check(ns.WishTab.filter == "unwished", "点\"未许愿\"筛选")
Sim.Click(Chip("已许愿 "))
Sim.Check(ns.WishTab.filter == "wished", "点\"已许愿\"筛选")
Sim.Click(Chip("全部 "))
Sim.Check(ns.WishTab.filter == nil, "点\"全部\"恢复")
local before = #Sim.chatLog
Sim.Click(unwishedChip, "RightButton"); Sim.Run(1)
Sim.Check(#Sim.chatLog > before and ns.WishTab.filter == nil, "右键\"未许愿\"通报名单、不改变筛选")

-- 标签页
Sim.Click(Sim.FindButton(mf, "设置"))
for _, cat in ipairs({ "许愿规则", "开团公告与宣言", "数据", "界面" }) do
    local b = Sim.Find(mf, function(w) return w._kind == "Button" and w.fs and w.fs._text == cat and w:IsVisible() end)
    Sim.Check(b ~= nil, "设置分类：" .. cat)
    if b then Sim.Click(b) end
end
local chk = Sim.FindButton(mf, "显示小地图按钮")
Sim.Check(chk ~= nil, "界面分类：显示小地图按钮")
if chk then
    Sim.Click(chk)
    Sim.Check(ns.DB.options.ui.showMinimap == false, "勾选框写入设置")
    Sim.Click(chk)
end
local rules = Sim.Find(mf, function(w) return w._kind == "Button" and w.fs and w.fs._text == "许愿规则" end)
Sim.Click(rules)
local xyOnly = Sim.FindButton(mf, "仅xy模式")
Sim.Click(xyOnly)
Sim.Check(ns.DB.options.xyOnly == true, "仅xy模式写入设置")
Sim.Click(xyOnly)
Sim.Click(Sim.FindButton(mf, "掉落与拍卖"))
Sim.Click(Sim.FindButton(mf, "许愿"))
Sim.Check(Sim.FindButton(mf, "停止许愿") ~= nil, "切回许愿页")

section("团员端主窗口")
B.slash("")
local mfB = B.env.RaidWishMainFrame
Sim.Check(Sim.FindButton(mfB, "开始许愿") == nil and Sim.FindButton(mfB, "停止许愿") == nil, "团员端没有主按钮")
Sim.Check(Sim.FindButton(mfB, "开团公告") == nil or not Sim.FindButton(mfB, "开团公告"):IsVisible(), "团员端没有通报按钮")
Sim.Check(not mfB.yield:IsShown(), "团员看不到\"让出\"")
Sim.Check(not Sim.FindButton(mfB, "清空许愿表") or not Sim.FindButton(mfB, "清空许愿表"):IsVisible(), "团员看不到\"清空许愿表\"")
local hint = Sim.Find(mfB, function(w) return w._kind == "FontString" and w._text == "你的许愿" and w:IsVisible() end)
Sim.Check(hint ~= nil, "团员端提示\"你的许愿\"")
local rowBB = Sim.Find(mfB, function(w) return w._kind == "Button" and w.data and w.data.name == "乙" and w:IsShown() end)
rowBB._mouseOver = true
rowBB._scripts.OnEnter(rowBB)
Sim.Check(not rowBB.plus:IsShown(), "团员端永远不出现加减号")
local menusBefore = #B.menus
Sim.Click(rowBB, "RightButton")
Sim.Check(#B.menus == menusBefore, "团员端行右键没有菜单")

section("停止与放弃")
Sim.Click(Sim.FindButton(mf, "停止许愿")); Sim.Run(2)
Sim.Check(not B.ns.Wish:InProgress(), "点停止后团员端显示已停止")
Sim.Check(Sim.FindButton(mf, "开始许愿") ~= nil, "主按钮变回\"开始许愿\"")
Sim.Click(Sim.FindButton(mf, "开始许愿")); Sim.Run(3)
Sim.Check(B.ns.Wish:InProgress(), "再次开始")

------------------------------------------------------------------------
-- 掉落记录
------------------------------------------------------------------------

section("掉落记录、许愿完成、自动扣分、同步")
local L4 = "|cnIQ3:|Hitem:30000::::::::60:::::::::|h[蓝色小物]|h|r"
Sim.items[30000] = { name = "蓝色小物", link = L4, quality = 3, icon = 1 }
C.say("xy " .. L3); Sim.Run(2)
local dkpBefore = A.ns.Wish.model:Get("丙").dkp
C.say("3"); Sim.Run(1)
Sim.Loot("丙", L1); Sim.Run(3)
Sim.Check(A.ns.Wish.model:Get("丙").dkp == dkpBefore - 3, "出 3 分后拾取紫装：扣 3 分")
Sim.Check(Sim.ChatHas("丙 扣 3 分，还剩 " .. (dkpBefore - 3) .. " 分"), "扣分通报")
Sim.Loot("丙", L3); Sim.Run(3)
Sim.Check(ns.WishModel.IsFullyDone(A.ns.Wish.model:Get("丙")) or A.ns.Wish.model:Get("丙").wish.items[1].done, "拾取许愿物品后标记完成")
Sim.Check(Sim.ChatHas("丙 拿到了许愿的装备"), "完成通报")
Sim.Loot("乙", L4); Sim.Run(3)
local snapA = Sim.LootSnapshot(A)
Sim.Check(snapA == "19019>丙:0w 19364>丙:3", "团长端掉落列表（蓝装不记录）：" .. snapA)
Sim.Check(Sim.LootSnapshot(B) == snapA, "乙 掉落列表一致")
Sim.Check(Sim.LootSnapshot(C) == snapA, "丙 掉落列表一致")
Sim.Same(A, B, "扣分与完成同步到团员")
Sim.Loot("丙", L1); Sim.Run(1)
Sim.Check(Sim.LootSnapshot(A) == snapA, "10 秒内同一人同一物品只记一次")
local D = Sim.NewClient(ROOT, "丁", { class = "ROGUE" })
Sim.Join("丁", "ROGUE", 0); Sim.Run(12)
Sim.Check(Sim.LootSnapshot(D) == snapA, "后入团的团员拿到完整掉落列表")
Sim.Same(A, D, "后入团的团员拿到完整许愿表")
A.ns.Main:Show("loot")
local lrow = Sim.Find(A.env.RaidWishMainFrame, function(w) return w._kind == "Button" and w.data and w.data.uid and w:IsShown() end)
Sim.Check(lrow ~= nil, "掉落页有记录行")
Sim.Click(lrow, "RightButton")
Sim.Check(Sim.MenuTexts(A):find("从列表移除", 1, true) ~= nil, "团长端右键菜单：" .. Sim.MenuTexts(A))
Sim.ClickMenu(A, "从列表移除"); Sim.Run(2)
Sim.Check(#B.ns.LootLog:Entries() == 1, "移除同步到团员")
Sim.Click(Sim.FindButton(A.env.RaidWishMainFrame, "许愿"))

------------------------------------------------------------------------
-- 拍卖
------------------------------------------------------------------------

section("拍卖：开拍、许愿者自动出分、出分按钮校验、结算")
-- 打开语音：各节点播放的语音文件都必须存在（模拟器会检查）
for _, c in ipairs({ A, B, C, D }) do c.ns.DB.options.auction.voice = true end
B.say("xy " .. L1); Sim.Run(2)                      -- 乙 许愿 碧空之歌
B.say("看看 " .. L1); Sim.Run(1)                    -- 团队频道贴链接 → 进入待拍
local pend = A.ns.Auction:Pending()
Sim.Check(#pend >= 1 and pend[1].id == 19364, "团队频道的链接进入待拍")
local pillA = A.env.RaidWishPendingButton
Sim.Check(pillA:IsShown(), "团长端显示\"待拍\"按钮")
Sim.Check(not B.env.RaidWishPendingButton:IsShown(), "团员端不显示\"待拍\"按钮")
Sim.Click(pillA)
Sim.Check(Sim.MenuTexts(A):find("碧空之歌", 1, true) ~= nil, "待拍菜单列出物品：" .. Sim.MenuTexts(A))
Sim.Check(A.ns.Wish:InProgress(), "（前提）许愿还没截止")
Sim.ClickMenu(A, "碧空之歌"); Sim.Run(0.3)
Sim.Check(not A.ns.Auction.model:InProgress() and A.ns.Widgets.lastDialog == "RAIDWISH_WISH_OPEN", "许愿没截止时不能直接开拍，先问是否截止")
Sim.Check(not B.ns.Auction:StartItem(19364), "非许愿团长不能在许愿期间开拍")
Sim.Click(A.env.RaidWishDialog.ok); Sim.Run(1)
Sim.Check(not A.ns.Wish:InProgress(), "选\"截止许愿并开拍\"：许愿已截止")
Sim.Check(Sim.ChatHas("开拍：" .. L1 .. "，请在团队频道出分"), "开拍通报")
for _, c in ipairs({ A, B, C, D }) do
    Sim.Check(c.env.RaidWishAuctionPopup:IsShown(), c.name .. " 弹出拍卖窗口")
end
Sim.Check(Sim.FindButton(A.env.RaidWishAuctionPopup, "数秒") ~= nil, "团长端有主持按钮")
Sim.Check(Sim.FindButton(B.env.RaidWishAuctionPopup, "数秒") == nil, "团员端没有主持按钮")
Sim.Check(Sim.FindButton(B.env.RaidWishAuctionPopup, "不要这件") ~= nil, "团员端有\"不要这件\"")
Sim.Run(1.5)
Sim.Check(Sim.ChatHas("[乙][RAID] 5"), "许愿者 1 秒后自动出 5 分")
Sim.Run(0.5)
Sim.Check(A.ns.Auction.model.bids["乙"] == 5, "拍卖方记录 乙 出 5 分")
Sim.Check(D.ns.Auction.model.bids["乙"] == 5, "出分表同步到团员")
-- 许愿加分 6~9 分：只有许愿了这件装备的人看得到第二排按钮
local function WishRow(c)
    local n = 0
    for _, t in ipairs({ "6 分", "7 分", "8 分", "9 分" }) do
        local b = Sim.FindButton(c.env.RaidWishAuctionPopup, t)
        if b and b:IsVisible() then n = n + 1 end
    end
    return n
end
Sim.Check(WishRow(B) == 4, "许愿了这件的人有 6~9 分按钮")
Sim.Check(WishRow(D) == 0, "没许愿的人没有 6~9 分按钮")
local dkpB = B.ns.Wish.model:Get("乙").dkp
Sim.Check(B.ns.Auction:CheckOwnBid(dkpB + 5) == nil, "许愿的人最多可出 现有分数 + 5（" .. (dkpB + 5) .. " 分）")
Sim.Check(B.ns.Auction:CheckOwnBid(dkpB + 6) == "分数不够", "超过 现有分数 + 5 提示分数不够")
Sim.Check(D.ns.Auction:CheckOwnBid(7) == "没出成：7 分只能出给自己许愿的装备。", "没许愿的人出 7 分被拒绝")
Sim.Click(Sim.FindButton(D.env.RaidWishAuctionPopup, "2 分")); Sim.Run(0.5)
Sim.Check(not Sim.ChatHas("[丁][RAID] 2"), "已有更高出分时按钮不发分")
Sim.Check(D.env.RaidWishAuctionPopup.err._text == "没出成：已经有人出了更高的分。", "按钮提示：" .. tostring(D.env.RaidWishAuctionPopup.err._text))
C.say("9"); Sim.Run(0.5)
Sim.Check(Sim.ChatHas("注意：丙 没有许愿这件装备，出的 9 分不算"), "非许愿装备出 9 分被警告")
Sim.Run(12)
Sim.Check(Sim.ChatHas("乙 以五分拍得 " .. L1 .. "，拾取时自动扣分"), "结算通报")
for _, c in ipairs({ A, B, D }) do
    local ok = false
    for _, x in ipairs(c.ns.DB.main.auction.captured) do if x.id == 19364 and x.sold then ok = true end end
    Sim.Check(ok, c.name .. " 标记已拍")
end
Sim.Check(#A.ns.DB.main.auction.results == 1 and A.ns.DB.main.auction.results[1].winner == "乙", "结算结果写入记录")
-- 许愿列表：乙 有没拿到的许愿，分数旁显示 +5
A.ns.Main:Show("wish")
local function BonusShown(name)
    for _, row in ipairs(A.ns.WishTab.list and A.ns.WishTab.list.rows or {}) do
        if row:IsShown() and row.data and row.data.name == name then return row.bonus:IsShown() end
    end
end
Sim.Check(BonusShown("乙") == true, "还有许愿的人分数旁显示 +5")
-- 赢家过了很久才拾取：按拍卖结果扣分（出 5 分拍许愿装备：不扣分，许愿完成）
local dkpB2 = A.ns.Wish.model:Get("乙").dkp
Sim.Run(90)                                          -- 超过团队频道出分的 60 秒窗口
Sim.Loot("乙", L1); Sim.Run(3)
Sim.Check(Sim.ChatHas("拍卖结算：乙 拿到了许愿的装备（出 5 分，不扣分）"), "拾取拍得的装备：按拍卖结果处理")
Sim.Check(A.ns.Wish.model:Get("乙").dkp == dkpB2, "出 5 分拍许愿装备不扣分")
Sim.Check(A.ns.DB.main.auction.results[1].charged == true, "拍卖结果标记为已扣")
Sim.Check(BonusShown("乙") == false, "许愿全部拿到后不再显示 +5")
Sim.Run(4)
Sim.Check(not B.env.RaidWishAuctionPopup:IsShown(), "结算后弹窗关闭")

section("同分 Roll")
C.say("看 " .. L2); Sim.Run(1)
A.ns.Auction:StartItem(212395); Sim.Run(0.5)
B.say("2"); D.say("2"); Sim.Run(12)
-- 两人的出分在同一时刻到达，名单顺序取决于到达顺序
Sim.Check(Sim.ChatHas("同分，请 乙、丁 /roll 决定归属") or Sim.ChatHas("同分，请 丁、乙 /roll 决定归属"), "同分进入 Roll")
local rollB = Sim.FindButton(B.env.RaidWishAuctionPopup, "Roll")
Sim.Check(rollB ~= nil, "同分者看到 Roll 按钮")
Sim.Check(Sim.FindButton(C.env.RaidWishAuctionPopup, "Roll") == nil, "其他人没有 Roll 按钮")
Sim.nextRoll = { ["乙"] = 40, ["丁"] = 70 }
Sim.Click(rollB)
Sim.Click(Sim.FindButton(D.env.RaidWishAuctionPopup, "Roll"))
Sim.Run(0.5)
Sim.Click(rollB); Sim.Run(0.2)
Sim.Check(B.env.RaidWishAuctionPopup.err._text == "你已经 Roll 过了", "重复点 Roll 有提示")
Sim.Check(A.ns.Auction.model.rolls["丁"] == 70, "拍卖方记录 Roll 点")
Sim.Run(12)
Sim.Check(Sim.ChatHas("丁 以 Roll 点 70 拿到 " .. L2 .. "，出价二分，拾取时自动扣分"), "Roll 结算通报")
local dkpD = A.ns.Wish.model:Get("丁").dkp
Sim.Run(90)
Sim.Loot("丁", L2); Sim.Run(3)
Sim.Check(A.ns.Wish.model:Get("丁").dkp == dkpD - 2, "Roll 赢家拾取后按出价扣 2 分（" .. tostring(dkpD) .. " → " .. tostring(A.ns.Wish.model:Get("丁").dkp) .. "）")
Sim.Run(4)

section("取消、P 标记、直接 Roll、/xypm")
B.say("这个 " .. L4); Sim.Run(1)
A.ns.Auction:StartItem(30000); Sim.Run(0.5)
Sim.Click(Sim.FindButton(C.env.RaidWishAuctionPopup, "不要这件"))
Sim.Check(not C.env.RaidWishAuctionPopup:IsShown() and C.env.RaidWishAuctionBar:IsShown(), "\"不要这件\"收起为小条")
Sim.Click(Sim.FindButton(A.env.RaidWishAuctionPopup, "取消拍卖")); Sim.Run(0.5)
Sim.Check(not B.ns.Auction.model:Active() and not C.env.RaidWishAuctionBar:IsShown(), "取消后各端关闭")
Sim.Check(Sim.ChatHas("本次拍卖已取消："), "取消通报")
A.slash("")   -- 关掉主窗口
A.env.SlashCmdList.RAIDWISHPM(""); Sim.Run(0.5)
Sim.Check(A.ns.Auction.model.item == 30000, "/xypm 拍第一件待拍")
Sim.Check(not C.env.RaidWishAuctionPopup:IsShown() and C.env.RaidWishAuctionBar:IsShown(), "P 标记过的物品再次开拍时默认收起")
C.say("1"); Sim.Run(0.5)
Sim.Check(C.env.RaidWishAuctionPopup:IsShown(), "自己出分后清除 P 标记并展开")
Sim.Click(Sim.FindButton(A.env.RaidWishAuctionPopup, "直接 Roll")); Sim.Run(0.5)
Sim.Check(Sim.ChatHas("全团 Roll：" .. L4), "出分阶段改为直接全团 Roll")
Sim.Check(Sim.FindButton(B.env.RaidWishAuctionPopup, "Roll") ~= nil, "全团都能 Roll")
Sim.nextRoll = { ["丙"] = 88 }
C.ns.Auction:RollButton(); Sim.Run(12)
Sim.Check(Sim.ChatHas("丙 以 Roll 点 88 拿到 " .. L4), "直接 Roll 结算")
Sim.Run(4)
A.ns.Main:Show("loot")
local soldRow = Sim.Find(A.env.RaidWishMainFrame, function(w) return w._kind == "Button" and w.data and w.data.id == 19364 and w:IsShown() end)
Sim.Check(soldRow == nil or (soldRow.res._text == "乙"), "掉落页结果列显示赢家")
Sim.Check(#A.ns.Auction:Pending() == 0, "全部拍完后待拍为 0")

------------------------------------------------------------------------
-- 外围功能
------------------------------------------------------------------------

section("右键菜单")
local function openUnitMenu(c, tag, name)
    local hook = c.menuHooks and c.menuHooks[tag]
    if not hook then return nil end
    local root = { items = {} }
    local function node()
        local n = { items = {} }
        function n.CreateButton(self, text, fn) local ch = node(); ch.text, ch.fn = text, fn; self.items[#self.items + 1] = ch; return ch end
        function n.CreateTitle(self, text) self.items[#self.items + 1] = { title = text, items = {} } end
        function n.CreateDivider(self) self.items[#self.items + 1] = { divider = true, items = {} } end
        return n
    end
    root = node()
    hook(nil, root, { name = name .. "-无限", unit = "raid2" })
    c.lastMenu = root
    return Sim.MenuTexts(c)
end
local leaderNow = leaderOf(A)
local L = Sim.clients[leaderNow]
local other = (leaderNow == "甲") and B or A
Sim.Check(openUnitMenu(L, "MENU_UNIT_RAID_PLAYER", "丙") == "--,<许愿助手>,查询许愿,增加分数,扣除分数", "许愿团长的右键菜单：" .. tostring(Sim.MenuTexts(L)))
local before = L.ns.Wish.model:Get("丙").dkp
Sim.ClickMenu(L, "增加分数", "增加3分"); Sim.Run(2)
Sim.Check(L.ns.Wish.model:Get("丙").dkp == before + 3, "右键加 3 分")
Sim.Check(Sim.ChatHas("丙 加 3 分"), "右键加分通报")
Sim.Check(openUnitMenu(other, "MENU_UNIT_RAID_PLAYER", "丙") == "--,<许愿助手>,查询许愿", "非许愿团长看不到加减分")
Sim.Check(openUnitMenu(L, "MENU_UNIT_RAID_PLAYER", "外人") == "", "不在团里的人不加菜单项")
Sim.ClickMenu(other, "查询许愿")

A.ns.WishChat:Start(); Sim.Run(3)                  -- 拍卖前截止了许愿，这里重新开始
section("两段名字（名 姓）")
local E = Sim.NewClient(ROOT, "坏人 某某", { class = "WARLOCK" })
Sim.Join("坏人 某某", "WARLOCK", 0); Sim.Run(2)
Sim.Check(A.env.SlashCmdList.RAIDWISHBL == nil, "没有黑名单命令 /xyb")

-- 两段名字（名 姓）：本人许愿、代许愿、只写名时的代许愿、识别自己
E.say("xy " .. L1); Sim.Run(2)
local er = A.ns.Wish.model:Get("坏人 某某")
Sim.Check(er and er.wish and er.wish.items[1].id == 19364, "两段名字的人自己许愿能录入")
Sim.Check(E.ns.Roster:Self() == "坏人 某某", "UnitName 分两段返回时也能认出自己")
A.say("txy 坏人 某某 [手打物品]"); Sim.Run(2)
er = A.ns.Wish.model:Get("坏人 某某")
Sim.Check(er.wish.items[1].name == "手打物品", "txy 名 姓 [物品] 代许愿")
A.say("txy 坏人 地板"); Sim.Run(2)
er = A.ns.Wish.model:Get("坏人 某某")
Sim.Check(er.wish.items[1].floor, "txy 只写名（团里唯一）也能代许愿")

section("小地图按钮、皮肤切换")
local mm = A.env.RaidWishMinimapButton
Sim.Check(mm ~= nil and mm:IsShown(), "小地图按钮")
Sim.Check(mm.icon._tex and mm.icon._tex:find("MinimapButton", 1, true) ~= nil, "默认图标：许愿星")
A.ns.Main:Show("set"); A.ns.Settings:Select("ui")
local uiPage
for _, c in ipairs(A.ns.Settings.cats) do if c.key == "ui" then uiPage = c.frame end end
local starRadio = Sim.Find(uiPage, function(w) return w._label and w._label._text and w._label._text:find("许愿星", 1, true) end)
    or Sim.Find(uiPage, function(w) return w._fs and w._fs._text and w._fs._text:find("许愿星", 1, true) end)
Sim.Check(starRadio ~= nil, "设置 → 界面 有图标选项")
A.ns.DB.options.ui.icon = "dice"; A.ns.Events:Fire("RW_ICON_CHANGED")
Sim.Check(mm.icon._tex:find("INV_Misc_Dice_01", 1, true) ~= nil, "换成骰子后小地图按钮跟着变")
A.ns.DB.options.ui.icon = "star"; A.ns.Events:Fire("RW_ICON_CHANGED")
Sim.Check(mm.icon._tex:find("Images", 1, true) ~= nil, "换回插件自带的许愿星")
A.ns.DB.options.ui.icon = "star"; A.ns.Events:Fire("RW_ICON_CHANGED")
local wasShown = A.ns.Main:IsShown()
mm._scripts.OnClick(mm, "LeftButton")
Sim.Check(A.ns.Main:IsShown() ~= wasShown, "左键开关主窗口")
mm._scripts.OnClick(mm, "RightButton")
Sim.Check(Sim.MenuTexts(A):find("掉落与拍卖", 1, true) ~= nil, "右键菜单：" .. Sim.MenuTexts(A))
A.ns.DB.options.ui.showMinimap = false
A.ns.Events:Fire("RW_MINIMAP_OPTION")
Sim.Check(not mm:IsShown(), "关闭\"显示小地图按钮\"后隐藏")
A.ns.DB.options.ui.showMinimap = true
A.ns.Events:Fire("RW_MINIMAP_OPTION")
A.ns.Main:Show("wish")
A.ns.Auction:StartItem(19364); Sim.Run(0.5)
local errBefore = #Sim.errors
for _ = 1, 3 do
    A.ns.Skin:Set("blizz"); Sim.Run(0.2)
    A.ns.Main:Show("loot"); A.ns.Main:Show("set"); A.ns.Main:Show("wish")
    A.ns.Skin:Set("flat"); Sim.Run(0.2)
end
Sim.Check(#Sim.errors == errBefore, "两个窗口都打开时来回切换皮肤没有报错")
A.ns.Main:Show("set")
A.ns.Settings:Select("ui")
local radio = Sim.FindButton(A.env.RaidWishMainFrame, "暴雪原生")
Sim.Check(radio ~= nil, "设置页有\"暴雪原生\"选项")
Sim.Click(radio)
Sim.Check(A.ns.Skin.current == "blizz" and A.ns.DB.options.ui.skin == "blizz", "选中后立即切换并保存")
Sim.Click(Sim.FindButton(A.env.RaidWishMainFrame, "扁平暗色"))
A.ns.Auction:Cancel(); Sim.Run(1)

------------------------------------------------------------------------
-- 数据安全
------------------------------------------------------------------------

section("从团员恢复（模拟团长崩溃重登）")
local lead = Sim.clients[leaderOf(A)]
local full = Sim.Snapshot(B)
for name, rec in pairs(lead.ns.Wish.model.store) do rec.wish = nil end       -- 崩溃后本地只剩空行
lead.ns.Wish.model:ReplaceAll(lead.ns.Wish.model.store)
Sim.Check(lead.ns.Restore.WishedCount(lead.ns.Wish.model.store) == 0, "团长本地没有任何许愿")
local chatBefore = #Sim.chatLog
lead.ns.Widgets.lastDialog = nil
lead.ns.WishChat:Start(); Sim.Run(0.5)
local nStart = 0
for i = chatBefore + 1, #Sim.chatLog do if Sim.chatLog[i]:find("本次活动采用许愿分配", 1, true) then nStart = nStart + 1 end end
Sim.Check(nStart == 0, "拿回数据之前不会开始许愿（不会把空表同步给全团）")
Sim.Run(4)
Sim.Check(lead.ns.Widgets.lastDialog == nil, "同一个团里继续：不弹窗，悄悄从团员那里拿回数据")
Sim.Same(lead, B, "拿回后团长的许愿表与团员一致")
Sim.Check(Sim.Snapshot(B) == full, "团员的数据没有被空表覆盖")
Sim.Check(lead.ns.Wish:InProgress(), "恢复后继续开始许愿")

section("快照")
Sim.Check(lead.ns.Restore:Snapshot() ~= nil, "数据变化后自动保存快照")
local snapCount = lead.ns.Restore:Snapshot().count
lead.ns.Wish.model:ClearAll()                                    -- 意外清空（不是通过"清空许愿表"）
lead.ns.Restore:ShowSnapshot()
Sim.Check(lead.ns.Widgets.lastDialog == "RAIDWISH_RESTORE_SNAPSHOT", "查看快照并确认恢复")
Sim.Click(lead.env.RaidWishDialog.ok); Sim.Run(3)
local n = 0
for _ in pairs(lead.ns.Wish.model.store) do n = n + 1 end
Sim.Check(n == snapCount, "从快照恢复了 " .. n .. " 条")
Sim.Same(lead, B, "快照恢复后同步给团员")
-- 导出备份码 → 清空 → 粘贴导入
local beforeExport = Sim.Snapshot(lead)
local lootBefore = Sim.LootSnapshot(lead)
local exported = lead.ns.Restore:ExportText()
Sim.Check(exported:find("RWB2:", 1, true) ~= nil and exported:find(":END", 1, true) ~= nil, "导出内容里带备份码")
lead.ns.Wish.model:ClearAll()
lead.ns.LootLog:Clear()
lead.ns.Restore:ShowImport()
local dlg = lead.env.RaidWishTextDialog
dlg.ml.edit:SetText(exported)
Sim.Click(dlg.action)
Sim.Check(lead.ns.Widgets.lastDialog == "RAIDWISH_IMPORT", "导入前确认")
Sim.Click(lead.env.RaidWishDialog.ok); Sim.Run(4)
Sim.Check(Sim.Snapshot(lead) == beforeExport, "导入后许愿表恢复原样")
Sim.Check(Sim.LootSnapshot(lead) == lootBefore, "导入后掉落列表恢复原样")
Sim.Same(lead, B, "导入后同步给团员")
lead.slash("backup")
Sim.Check(Sim.Printed(lead, "已保存许愿快照"), "/xy backup 手动保存快照")
lead.slash("rl")
Sim.Check(Sim.Printed(lead, "所有窗口和小地图按钮位置已重置"), "/xy rl 重置窗口位置")

section("新团第一次开始：继续还是清空")
local function NewRaid(oldOnMembers)
    for _, c in pairs(Sim.clients) do
        local l = c.ns.DB.main.leader
        l.name, l.term, l.active, l.rev = nil, 0, false, 0      -- 相当于离开旧团、进了新团
        c.ns.Main:RequestRefresh()
    end
    lead.ns.Wish.model:ClearAll()
    for _, c in pairs(Sim.clients) do
        if c ~= lead and oldOnMembers then
            local st = c.ns.Wish.model.store
            for k in pairs(st) do st[k] = nil end
            st["路人甲 某某"] = { class = "MAGE", dkp = 7, ts = 1800000000 - 8 * 3600, wish = { items = { { id = 19364 } } } }
        end
    end
    lead.ns.Widgets.lastDialog = nil
end
local function Started(from)
    for i = from + 1, #Sim.chatLog do if Sim.chatLog[i]:find("本次活动采用许愿分配", 1, true) then return true end end
    return false
end

-- 1. 团员手里有上一个团的旧许愿 → 问；选"清空"
NewRaid(true)
local c0 = #Sim.chatLog
lead.ns.WishChat:Start(); Sim.Run(3)
Sim.Check(lead.ns.Widgets.lastDialog == "RAIDWISH_OLD_DATA", "有旧数据：问\"继续\"还是\"清空\"")
local dlgText = lead.env.RaidWishDialog.text._text
Sim.Check(dlgText:find("1 人许愿", 1, true) and dlgText:find("最后更新于", 1, true) and true, "弹窗写明人数和最后更新时间：" .. dlgText)
Sim.Check(not Started(c0), "选之前不开始")
Sim.Click(lead.env.RaidWishDialog.cancel); Sim.Run(4)                 -- 清空，重新开始
Sim.Check(Started(c0) and lead.ns.Wish:InProgress(), "清空后开始许愿")
Sim.Check(B.ns.Wish.model:Get("路人甲 某某") == nil, "团员手里的旧许愿被替换掉")
Sim.Same(lead, B, "清空后全团一致")

-- 2. 团员手里有数据 → 选"继续"：用团员的
NewRaid(true)
lead.ns.WishChat:Start(); Sim.Run(3)
Sim.Check(lead.ns.Widgets.lastDialog == "RAIDWISH_OLD_DATA", "再开一次仍然问")
Sim.Click(lead.env.RaidWishDialog.ok); Sim.Run(5)                     -- 继续上次的许愿
local kept = lead.ns.Wish.model:Get("路人甲 某某")
Sim.Check(kept and kept.dkp == 7, "选\"继续\"：拿回团员手里的数据")

-- 3. 谁手里都没有许愿 → 不问，直接开始
NewRaid(false)
for _, c in pairs(Sim.clients) do c.ns.Wish.model:ClearAll() end
local c3 = #Sim.chatLog
lead.ns.WishChat:Start(); Sim.Run(3)
Sim.Check(lead.ns.Widgets.lastDialog == nil and Started(c3), "没有旧数据：不弹窗，直接开始")

-- 4. 同一个团里停止后再开始 → 不问
lead.ns.WishChat:Stop(); Sim.Run(1)
lead.ns.Widgets.lastDialog = nil
lead.ns.WishChat:Start(); Sim.Run(3)
Sim.Check(lead.ns.Widgets.lastDialog == nil and lead.ns.Wish:InProgress(), "停止后再开始：直接继续，不弹窗")

local played = {}
for _, c in pairs(Sim.clients) do for _, p in ipairs(c.sounds or {}) do played[p:match("([%w_]+)%.ogg$") or p] = true end end
local names = {}
for k in pairs(played) do names[#names + 1] = k end
table.sort(names)
Sim.Check(#names >= 10, "拍卖过程中播放过的语音：" .. table.concat(names, ", "))

section("清空许愿表时一起清空拍卖数据")
B.say("看看 " .. L2); Sim.Run(1)
local wl = Sim.clients[leaderOf(A)]
Sim.Check(#wl.ns.Auction:Pending() > 0, "（前提）有待拍物品")
B.ns.DB.main.auction.results[#B.ns.DB.main.auction.results + 1] = { winner = "乙", id = 1, score = 1, ts = 1800000000 }
wl.ns.WishChat:ClearAll(); Sim.Run(3)
Sim.Check(#wl.ns.Auction:Pending() == 0, "清空后待拍列表为空")
Sim.Check(#wl.ns.DB.main.auction.results == 0 and #wl.ns.DB.main.loot == 0, "清空后拍卖结果和掉落记录为空")
Sim.Check(#B.ns.DB.main.auction.results == 0, "团员那边的拍卖结果也一起清空")
Sim.Check(not wl.env.RaidWishPendingButton:IsShown(), "清空后\"待拍\"按钮消失")

section("可选语音包")
local V = lead.ns.Voice
lead.ns.DB.options.auction.voice = true
Sim.Check(V:Pack() == nil and not V:UsingPack(), "没装语音包时用默认语音")
lead.env.RaidWishVoicePack = { path = "Interface\\AddOns\\RaidWish_Voice\\voice\\", name = "测试语音", author = "某人" }
Sim.packFiles = { won_bid = true }                    -- 语音包里只有一句
lead.sounds = {}
Sim.Run(2); V:Play("won_bid")
Sim.Check(lead.sounds[1] and lead.sounds[1]:find("RaidWish_Voice", 1, true) ~= nil, "装了语音包：播语音包里的")
Sim.Run(2); V:Play("all_sold")
Sim.Check(lead.sounds[2] and lead.sounds[2]:find("\\RaidWish\\voice\\all_sold", 1, true) ~= nil, "语音包里没有的句子用默认语音")
lead.ns.DB.options.auction.voicePack = false
Sim.Run(2); V:Play("won_bid")
Sim.Check(lead.sounds[3] and lead.sounds[3]:find("\\RaidWish\\voice\\won_bid", 1, true) ~= nil, "关掉\"使用语音包\"后用默认语音")
lead.ns.DB.options.auction.voicePack = true
lead.ns.Main:Show("set"); lead.ns.Settings:Select("auction")
local auctionPage
for _, c in ipairs(lead.ns.Settings.cats) do if c.key == "auction" then auctionPage = c.frame end end
Sim.Check(Sim.Find(auctionPage, function(w) return w._fs and w._fs._text and w._fs._text:find("测试语音", 1, true) end) ~= nil
    or Sim.Find(auctionPage, function(w) return w._text and tostring(w._text):find("测试语音", 1, true) end) ~= nil, "设置页显示语音包名称")
lead.sounds = {}
for _, k in ipairs({ "bid_6", "bid_7", "bid_8" }) do Sim.Run(2); V:Play(k) end
Sim.Check(#lead.sounds == 3, "6、7、8 分有默认语音")
lead.env.RaidWishVoicePack = nil
Sim.packFiles = nil

------------------------------------------------------------------------
-- 报告
------------------------------------------------------------------------

print(("\n合计：%d 项通过，%d 项失败"):format(Sim.pass, Sim.fail))
if #Sim.errors > 0 then
    print("运行中的报错：")
    for _, e in ipairs(Sim.errors) do print("  " .. e) end
end
os.exit((Sim.fail == 0 and #Sim.errors == 0) and 0 or 1)
