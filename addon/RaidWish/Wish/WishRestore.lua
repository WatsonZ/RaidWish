-- Wish/WishRestore.lua：数据安全
--   1. 存档快照：许愿表或分数变化后写入 RaidWishDB.snapshot；登录时许愿表为空而快照可用则询问是否恢复。
--   2. 从团员恢复：本地表为空时开始许愿会先问团员；只让一个人回全量（优先助理，其次名字字典序最小），
--      团长端弹窗确认后才采用，防止被恶意数据覆盖。
--   3. 导出与导入备份：在"设置 → 数据"页（SettingsTab）。
--
-- 消息：RREQ（询问谁有数据）/ RHAVE 条数 / RPICK 被选中的人 / RBEG 条数 / R 名字、职业、分数、物品 / REND
local ADDON, ns = ...

local Restore = {}
ns.Restore = Restore

Restore.SNAPSHOT_MIN = 3              -- 快照至少 3 条才提示
Restore.SNAPSHOT_WINDOW = 12 * 3600   -- 12 小时内的快照才提示
Restore.CLEANUP_AGE = 24 * 3600       -- 登录时清理 24 小时前的数据
Restore.COLLECT_TIME = 1.5            -- 等团员回应的时间

local WM = ns.WishModel

local function M() return ns.Wish.model end
local function Main() return ns.DB.main end
local function Count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
local function DeepCopy(v) return ns.DB.DeepCopy(v) end

-- 有许愿的记录数（在团成员会自动建行，所以"空表"指没有任何人许愿）
local function WishedCount(store)
    local n = 0
    for _, rec in pairs(store or {}) do if WM.HasWish(rec) then n = n + 1 end end
    return n
end
Restore.WishedCount = WishedCount

-- 团员手里的数据摘要（纯函数）：有许愿的条数、其中现在在团里的人数、最后一次改动的时间
function Restore.Summary(store, inRaid)
    local n, here, last = 0, 0, 0
    for name, rec in pairs(store or {}) do
        if WM.HasWish(rec) then
            n = n + 1
            if inRaid(name) then here = here + 1 end
            last = math.max(last, tonumber(rec.ts) or 0)
        end
    end
    return n, here, last
end

------------------------------------------------------------------------
-- 1. 快照
------------------------------------------------------------------------

-- 团队成员指纹：排序后的名字拼起来
local function Fingerprint()
    local names = {}
    for _, m in ipairs((ns.Roster:Get())) do names[#names + 1] = m.name end
    table.sort(names)
    return table.concat(names, ",")
end

-- 保存快照。force 为真时不看"自动快照"开关并打印结果。许愿表为空时不覆盖已有快照。
function Restore:SaveSnapshot(force)
    if not force and not ns.DB.options.autoBackup then return false end
    local n = Count(M().store)
    if n == 0 then
        if force then ns.Print("当前许愿表为空，未保存快照") end
        return false
    end
    Main().snapshot = {
        ts = time(),
        fingerprint = Fingerprint(),
        wishes = DeepCopy(M().store),
        loot = DeepCopy(Main().loot),
        count = n,
    }
    if force then ns.Print("已保存许愿快照（" .. n .. " 条）") end
    return true
end

function Restore:Snapshot()
    local s = Main().snapshot
    if type(s) ~= "table" or type(s.wishes) ~= "table" then return nil end
    return s
end

-- 是否值得提示恢复：许愿表为空、快照足够新且不少于 3 条，或者快照比正式数据新
function Restore:SnapshotUsable()
    local s = self:Snapshot()
    if not s then return false end
    local n = Count(s.wishes)
    if n < Restore.SNAPSHOT_MIN or time() - (s.ts or 0) > Restore.SNAPSHOT_WINDOW then return false end
    -- 快照之后用户主动清空过许愿表：不再提示
    if (tonumber(Main().clearedAt) or 0) >= (s.ts or 0) then return false end
    if WishedCount(M().store) == 0 and WishedCount(s.wishes) > 0 then return true end
    local newest = 0
    for _, rec in pairs(M().store) do newest = math.max(newest, tonumber(rec.ts) or 0) end
    return (s.ts or 0) > newest + 60 and n > Count(M().store)
end

function Restore:ApplySnapshot()
    local s = self:Snapshot()
    if not s then return false end
    M():ReplaceAll(DeepCopy(s.wishes))
    if type(s.loot) == "table" and #Main().loot == 0 then
        for i, e in ipairs(DeepCopy(s.loot)) do Main().loot[i] = e end
        ns.Events:Fire("RW_LOOT_CHANGED")
    end
    ns.Main.footRightOverride = nil
    ns.Print("已从快照恢复 " .. Count(s.wishes) .. " 条许愿记录")
    if ns.Wish:IsLeader() then
        ns.WishSync:Bump()
        ns.WishSync:SendFull()
        ns.LootLog:SendFull()
    end
    ns.Main:RequestRefresh()
    return true
end

-- "查看并恢复快照"
function Restore:ShowSnapshot()
    local s = self:Snapshot()
    if not s then
        ns.Print("没有可用的快照")
        return
    end
    local lines = { ("快照时间 %s，共 %d 条"):format(date("%m-%d %H:%M", s.ts or 0), Count(s.wishes)) }
    local tmp = WM.New(DeepCopy(s.wishes), nil, time)
    for _, row in ipairs(tmp:Sorted("name", true)) do
        lines[#lines + 1] = row.name .. "  " .. tostring(row.rec.dkp) .. "分  "
            .. (WM.HasWish(row.rec) and ns.WishChat.WishText(row.rec) or "未许愿")
    end
    ns.Widgets.TextDialog("许愿快照", table.concat(lines, "\n"))
    ns.Widgets.Confirm("RESTORE_SNAPSHOT", ("用 %s 的快照（%d 条）替换当前许愿表吗？"):format(
        date("%H:%M", s.ts or 0), Count(s.wishes)), function() Restore:ApplySnapshot() end)
end

-- 数据变化后 2 秒内只存一次
local pendingSave
local function ScheduleSave()
    if pendingSave then return end
    pendingSave = ns.After(2, function()
        pendingSave = nil
        Restore:SaveSnapshot(false)
    end)
end

-- 登录时：清理过期数据，再检查是否需要提示恢复
local function OnLogin()
    local now = time()
    local removed = 0
    for name, rec in pairs(M().store) do
        if rec.ts and now - rec.ts >= Restore.CLEANUP_AGE then
            M().store[name] = nil
            removed = removed + 1
        end
    end
    local loot = Main().loot
    for i = #loot, 1, -1 do
        if type(loot[i].ts) ~= "number" or now - loot[i].ts >= Restore.CLEANUP_AGE then table.remove(loot, i) end
    end
    if removed > 0 then ns.Events:Fire("RW_WISH_CHANGED") end
    if Restore:SnapshotUsable() then
        ns.Main.footRightOverride = function() return "发现未恢复的数据 · 恢复" end
        ns.Main.footRightClick = function() Restore:ShowSnapshot() end
        ns.Print("检测到许愿列表为空，但存在可用快照。点主窗口右下角\"恢复\"或输入 /xy restore 恢复")
        ns.Widgets.Confirm("RESTORE_LOGIN", "发现 " .. date("%H:%M", Restore:Snapshot().ts or 0)
            .. " 保存的许愿快照（" .. Count(Restore:Snapshot().wishes) .. " 条），是否恢复？",
            function() Restore:ApplySnapshot() end)
        ns.Main:RequestRefresh()
    end
end

------------------------------------------------------------------------
-- 2. 从团员恢复
------------------------------------------------------------------------

-- 选应答方（纯函数）：offers = { [名字] = 条数 }，isOfficer(名字)。助理优先，其次名字字典序最小。
function Restore.PickResponder(offers, isOfficer)
    local best
    for name, n in pairs(offers) do
        if (tonumber(n) or 0) > 0 then
            if not best then
                best = name
            else
                local bo, no = isOfficer(best), isOfficer(name)
                if (no and not bo) or (no == bo and name < best) then best = name end
            end
        end
    end
    return best
end

local collecting = nil      -- { offers = {}, done = function } 请求方的收集状态
local picked = nil          -- 请求方：选中的应答方
local receiving = nil       -- 请求方：正在接收的数据 { count, rows }

-- accepted：true 采用了团员的数据 / false 用户选择不采用 / nil 没有可用的数据
local function Finish(cb, accepted)
    collecting, picked, receiving = nil, nil, nil
    if cb then cb(accepted) end
end

-- 向团员要数据。done(accepted) 在恢复完成、被拒绝或没人回应后调用。
-- opts.noConfirm：收到后直接采用（调用方已经问过用户）
-- opts.noConfirm：直接采用，不再确认；opts.silent：不提示"正在询问""没有数据"（开始许愿时的自动检查用）
function Restore:FromMembers(done, opts)
    opts = opts or {}
    if not IsInRaid() then
        ns.Print("不在团队中，无法从团员恢复")
        if done then done() end
        return
    end
    collecting = { offers = {}, done = done }
    ns.Comm:Send("RREQ")
    if not opts.silent then ns.Print("正在询问团员的许愿数据…") end
    ns.After(Restore.COLLECT_TIME, function()
        if not collecting then return end
        local counts = {}
        for name, o in pairs(collecting.offers) do counts[name] = o.n end
        local who = Restore.PickResponder(counts, function(n) return ns.Roster:IsOfficer(n) end)
        if not who then
            if not opts.silent then ns.Print("没有团员持有许愿数据") end
            Finish(collecting.done)
            return
        end
        picked = who
        local cb = collecting.done
        local offer = collecting.offers[who]
        collecting = nil
        receiving = { rows = {}, done = cb, noConfirm = opts.noConfirm, offer = offer }
        ns.Comm:Send("RPICK", who)
        -- 10 秒内没收齐则放弃
        ns.After(10, function()
            if receiving and receiving.rows and not receiving.finished then
                ns.Print("从团员恢复超时")
                Finish(receiving.done)
            end
        end)
    end)
end

-- 团员端：有人询问时报上自己的条数
local function OnReq(sender)
    if not ns.Roster:Has(sender) then return end
    local n, here, last = Restore.Summary(M().store, function(name) return ns.Roster:Has(name) end)
    if n > 0 then ns.Comm:Send("RHAVE", n, here, last) end
end

local surveying = nil       -- 摸底：{ offers = {}, done = function }

local function OnHave(sender, n, here, ts)
    local o = { n = tonumber(n) or 0, here = tonumber(here) or 0, ts = tonumber(ts) or 0 }
    if collecting then collecting.offers[sender] = o end
    if surveying then surveying.offers[sender] = o end
end

-- 问一下团员手里有没有许愿数据（只要条数、在团人数、最后更新时间，不要数据本身）。
-- done(offers) 在 COLLECT_TIME 秒后调用，offers = { [名字] = { n, here, ts } }
function Restore:Survey(done)
    if not IsInRaid() then done({}) return end
    surveying = { offers = {}, done = done }
    ns.Comm:Send("RREQ")
    ns.After(Restore.COLLECT_TIME, function()
        local sv = surveying
        surveying = nil
        if sv then sv.done(sv.offers) end
    end)
end

-- 被选中：把自己的许愿表发出去
local function OnPick(_, who)
    if who ~= ns.Roster:Self() then return end
    local rows = M():Sorted("name", true)
    ns.Comm:Send("RBEG", #rows)
    for _, row in ipairs(rows) do
        local rec = row.rec
        ns.Comm:Send("R", row.name, rec.class or "", tonumber(rec.dkp) or 0,
            WM.EncodeItems(rec.wish and rec.wish.items or nil))
    end
    ns.Comm:Send("REND")
end

local function OnBeg(sender, count)
    if not receiving or sender ~= picked then return end
    receiving.count = tonumber(count) or 0
end

local function OnRow(sender, name, class, dkp, items)
    if not receiving or sender ~= picked or not name or name == "" then return end
    local list = WM.DecodeItems(items)
    receiving.rows[name] = { class = class ~= "" and class or nil, dkp = tonumber(dkp) or 0, ts = time(),
        wish = (#list > 0) and { items = list } or nil }
end

local function OnEnd(sender)
    if not receiving or sender ~= picked then return end
    receiving.finished = true
    local rows, n = receiving.rows, Count(receiving.rows)
    local cb = receiving.done
    if n == 0 or (receiving.count and n ~= receiving.count) then
        ns.Print("收到的数据不完整，已放弃")
        Finish(cb)
        return
    end
    local function Apply()
        M():ReplaceAll(rows)
        ns.Print("已采用 " .. sender .. " 的 " .. n .. " 条许愿记录")
        Finish(cb, true)
        if ns.Wish:IsLeader() then ns.WishSync:SendFull() end
        -- 请大家自己核对一下
        ns.Chat:Send("许愿数据已从团员处恢复，请大家输入 /xy 打开许愿助手核对自己的许愿和分数，有出入请密语团长", "RAID")
    end
    if receiving.noConfirm then
        Apply()
        return
    end
    -- 选"取消"时也继续后面的流程（例如继续开始许愿）
    local o = receiving.offer or {}
    local detail = o.ts and o.ts > 0 and ("\n其中 %d 人在本团，最后更新于 %s。"):format(o.here or 0, date("%m-%d %H:%M", o.ts)) or ""
    ns.Widgets.Confirm("RESTORE_MEMBER", ("团员 %s 手里有 %d 条许愿记录。%s\n要采用吗？"):format(sender, n, detail), Apply,
        { onCancel = function() Finish(cb, false) end, okText = "采用" })
end

------------------------------------------------------------------------
-- 4. 备份码：把许愿表和掉落列表变成一段文字，复制到游戏外保存，需要时粘贴回来恢复
-- 明文（内部格式，每行一条，字段用 ^ 分隔）：
--   ==RaidWish 备份 v1==^时间戳^团长
--   W^名字^职业^分数^物品编码
--   L^物品编号^获得者^分数^是否许愿^时间戳^拍卖结果
--   ==结束==
-- 导出时把明文打乱并转成 Base64，再附上校验值，得到"封装码"：
--   RWB2:<Base64，每 60 个字符换一行>:<校验值 16 位十六进制>:END
-- 改动任何一个字符，或复制不完整，导入时都会校验失败。
-- 注意：这是防手改，不是真正的加密——插件代码公开，懂行的人照样能解开。
------------------------------------------------------------------------

local SEP = "^"
local HEADER = "==RaidWish 备份 v1=="
local FOOTER = "==结束=="

local function Clean(v) return (tostring(v or ""):gsub("%^", "＾"):gsub("[\r\n]", " ")) end

-- 纯函数：wishes 为名字 → 记录，loot 为掉落数组
function Restore.EncodeBackup(wishes, loot, ts, leader)
    local lines = { HEADER .. SEP .. tostring(ts or 0) .. SEP .. Clean(leader) }
    local names = {}
    for name in pairs(wishes or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local rec = wishes[name]
        lines[#lines + 1] = table.concat({ "W", Clean(name), Clean(rec.class), tostring(tonumber(rec.dkp) or 0),
            Clean(WM.EncodeItems(rec.wish and rec.wish.items or nil)) }, SEP)
    end
    for _, e in ipairs(loot or {}) do
        if not e.removed then
            lines[#lines + 1] = table.concat({ "L", tostring(e.id), Clean(e.player), tostring(tonumber(e.points) or 0),
                e.wish and "1" or "0", tostring(tonumber(e.ts) or 0), Clean(ns.LootLog.EncodeSold(e.sold)) }, SEP)
        end
    end
    lines[#lines + 1] = FOOTER
    return Restore.Seal(table.concat(lines, "\n"))
end

------------------------------------------------------------------------
-- 封装：打乱 + Base64 + 校验值（只用算术，不依赖 bit 库）
------------------------------------------------------------------------

local SEAL_HEAD, SEAL_TAIL = "RWB2:", ":END"
local SALT = "RaidWish/迪恩温彻斯特/备份"
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64IDX = {}
for i = 1, 64 do B64IDX[B64:sub(i, i)] = i - 1 end

-- 两个独立的多项式哈希（模两个素数），合起来 16 位十六进制
local function Hash(s)
    local h1, h2 = 7, 13
    local data = SALT .. s .. SALT
    for i = 1, #data do
        local c = data:byte(i)
        h1 = (h1 * 131 + c) % 2147483629
        h2 = (h2 * 257 + c + i) % 2147483587
    end
    return ("%08x%08x"):format(h1, h2)
end

local function KeyAt(i)
    return (SALT:byte((i - 1) % #SALT + 1) + i * 29) % 256
end

local function Scramble(s, dir)
    local out = {}
    for i = 1, #s do out[i] = string.char((s:byte(i) + dir * KeyAt(i)) % 256) end
    return table.concat(out)
end

local function ToB64(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64
        local c3, c4 = math.floor(n / 64) % 64, n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

local function FromB64(s)
    if #s % 4 ~= 0 then return nil end
    local out = {}
    for i = 1, #s, 4 do
        local q = { s:byte(i, i + 3) }
        local v, pad = 0, 0
        for k = 1, 4 do
            local ch = string.char(q[k])
            local d = B64IDX[ch]
            if ch == "=" then d, pad = 0, pad + 1 elseif not d then return nil end
            v = v * 64 + d
        end
        local a, b, c = math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256
        out[#out + 1] = string.char(a)
        if pad < 2 then out[#out + 1] = string.char(b) end
        if pad < 1 then out[#out + 1] = string.char(c) end
    end
    return table.concat(out)
end

-- 明文 → 封装码
function Restore.Seal(plain)
    local b = ToB64(Scramble(plain, 1))
    local lines = {}
    for i = 1, #b, 60 do lines[#lines + 1] = b:sub(i, i + 59) end
    return SEAL_HEAD .. "\n" .. table.concat(lines, "\n") .. "\n:" .. Hash(plain) .. SEAL_TAIL
end

-- 封装码（可以夹在其他文字中间）→ 明文；失败返回 nil 和原因
function Restore.Unseal(text)
    local s = text:find(SEAL_HEAD, 1, true)
    if not s then return nil, "没有找到备份码（应以 " .. SEAL_HEAD .. " 开头）" end
    local e = text:find(SEAL_TAIL, s + #SEAL_HEAD, true)
    if not e then return nil, "备份码不完整（缺少结尾的 " .. SEAL_TAIL .. "），请确认复制了全部内容" end
    local body = text:sub(s + #SEAL_HEAD, e - 1):gsub("%s", "")
    local b64, sum = body:match("^([A-Za-z0-9+/=]*):(%x+)$")
    if not b64 then return nil, "备份码格式不对，可能被修改过或复制不完整" end
    local scrambled = FromB64(b64)
    if not scrambled then return nil, "备份码格式不对，可能被修改过或复制不完整" end
    local plain = Scramble(scrambled, -1)
    if Hash(plain) ~= sum:lower() then return nil, "备份码校验失败：内容被修改过，或复制不完整" end
    return plain
end

local function Split(line)
    local out, pos = {}, 1
    while true do
        local i = line:find(SEP, pos, true)
        if not i then out[#out + 1] = line:sub(pos) break end
        out[#out + 1] = line:sub(pos, i - 1)
        pos = i + 1
    end
    return out
end

-- 纯函数：返回 { wishes =, loot =, ts =, leader = }；找不到备份码返回 nil 和原因
function Restore.DecodeBackup(text)
    if type(text) ~= "string" then return nil, "没有内容" end
    local plain, why = Restore.Unseal(text)
    if not plain then return nil, why end
    text = plain
    local result, inside, ended = nil, false, false
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if line:sub(1, #HEADER) == HEADER then
            local f = Split(line)
            result = { wishes = {}, loot = {}, ts = tonumber(f[2]) or 0, leader = f[3] or "" }
            inside, ended = true, false
        elseif inside and line == FOOTER then
            inside, ended = false, true
        elseif inside then
            local f = Split(line)
            if f[1] == "W" and f[2] and f[2] ~= "" then
                local items = WM.DecodeItems(f[5] or "")
                result.wishes[f[2]] = { class = (f[3] ~= "" and f[3]) or nil, dkp = tonumber(f[4]) or 0,
                    ts = time(), wish = (#items > 0) and { items = items } or nil }
            elseif f[1] == "L" and tonumber(f[2]) then
                result.loot[#result.loot + 1] = { uid = #result.loot + 1, id = tonumber(f[2]), player = f[3],
                    points = tonumber(f[4]) or 0, wish = f[5] == "1", ts = tonumber(f[6]) or 0,
                    sold = ns.LootLog.DecodeSold(f[7]) }
            end
        end
    end
    if not result then return nil, "没有找到备份码（应以 " .. HEADER .. " 开头）" end
    if not ended then return nil, "备份码不完整（缺少 " .. FOOTER .. "），请确认复制了全部内容" end
    return result
end

-- 导出：可读的名单 + 备份码
function Restore:ExportText()
    local backup = Restore.EncodeBackup(M().store, Main().loot, time(), ns.Wish:LeaderName() or ns.Roster:Self())
    return ns.WishChat:ExportText() .. "\n\n—— 备份码（复制保存到游戏外，需要时用\"导入备份\"恢复）——\n" .. backup
end

function Restore:ShowExport()
    ns.Widgets.TextDialog("导出许愿表", self:ExportText(), nil, nil,
        "点\"复制\"后按 Ctrl+C；也可以按游戏的截图键保存成图片")
end

function Restore:ApplyBackup(b)
    M():ReplaceAll(b.wishes)
    local loot = Main().loot
    for i = #loot, 1, -1 do loot[i] = nil end
    for i, e in ipairs(b.loot) do loot[i] = e end
    Main().lootSeq = #loot
    ns.Events:Fire("RW_LOOT_CHANGED")
    if ns.Wish:IsLeader() then
        ns.WishSync:Bump()
        ns.WishSync:SendFull()
        ns.LootLog:SendFull()
    end
    ns.Main:RequestRefresh()
end

-- 导入：粘贴备份码（连同可读文字一起粘贴也可以）
function Restore:ShowImport()
    ns.Widgets.TextDialog("导入备份", "", "导入", function(text)
        local b, err = Restore.DecodeBackup(text)
        if not b then
            ns.Print("导入失败：" .. err)
            return
        end
        local nw, nl = Count(b.wishes), #b.loot
        ns.Widgets.Confirm("IMPORT", ("导入 %s 的备份：%d 条许愿记录、%d 条掉落记录。\n替换当前的数据吗？"):format(
            date("%m-%d %H:%M", b.ts), nw, nl), function()
            Restore:ApplyBackup(b)
            ns.Print(("已导入备份：%d 条许愿记录、%d 条掉落记录"):format(nw, nl))
        end)
    end, "按 Ctrl+V 把备份码粘贴到上面，然后点\"导入\"")
end

------------------------------------------------------------------------
-- 事件
------------------------------------------------------------------------

ns.Events:On("RW_LOADED", function()
    local C = ns.Comm
    C:On("RREQ", OnReq)
    C:On("RHAVE", OnHave)
    C:On("RPICK", OnPick)
    C:On("RBEG", OnBeg)
    C:On("R", OnRow)
    C:On("REND", OnEnd)
end)

ns.Events:On("RW_LOGIN", function() ns.After(3, OnLogin) end)
ns.Events:On("RW_WISH_CHANGED", ScheduleSave)
ns.Events:On("RW_CLEAR_ALL", function() Main().clearedAt = time() end)
-- 正常退出时也存一次
ns.Events:On("PLAYER_LOGOUT", function() Restore:SaveSnapshot(false) end)
