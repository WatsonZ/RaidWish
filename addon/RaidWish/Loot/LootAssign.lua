-- Loot/LootAssign.lua：拾取分配
-- 本文件目前只有"决定给谁"（纯函数，与客户端无关）。
-- "怎么给出去"要等团本里的拾取探测确定做法（A 队长分配 / B 分配助手面板 / C 只高亮候选人）后再写。
local ADDON, ns = ...

local LootAssign = {}
ns.LootAssign = LootAssign

------------------------------------------------------------------------
-- 候选人（纯函数）
-- ctx：{
--   item     = 物品编号,
--   me       = 自己的名字,
--   quickloot = 指定拾取人（options.lootAssign.quickloot）,
--   roster   = { { name=, class= }... } 当前可分配的人（拾取候选人或团队名单）,
--   model    = WishModel 实例,
--   results  = 拍卖结算记录 { { winner=, id=, ts= }... }（按时间先后）,
--   random   = function(n) 返回 1~n 的随机数（测试时注入）,
-- }
------------------------------------------------------------------------

local function InRoster(roster, name)
    for _, m in ipairs(roster or {}) do if m.name == name then return m end end
end

function LootAssign.Self(ctx)
    return InRoster(ctx.roster, ctx.me) and ctx.me or nil
end

-- 指定拾取人（不在候选人里时返回 nil）
function LootAssign.Designated(ctx)
    local q = ctx.quickloot
    if not q or q == "" then return nil end
    q = ns.Util.NormName(q)
    return InRoster(ctx.roster, q) and q or nil
end

function LootAssign.Random(ctx)
    local n = #(ctx.roster or {})
    if n == 0 then return nil end
    local i = (ctx.random or math.random)(n)
    return ctx.roster[i] and ctx.roster[i].name or nil
end

-- 许愿了该物品的人（只算候选人里的、未完成的许愿），按名字排序：{ { name=, dkp= }... }
function LootAssign.Wishers(ctx)
    if not ctx.model then return {} end
    return ctx.model:WishPlayers({ id = ctx.item }, ctx.roster)
end

-- 许愿"地板"的人
function LootAssign.FloorWishers(ctx)
    if not ctx.model then return {} end
    return ctx.model:FloorPlayers(ctx.roster)
end

-- 该物品的拍卖赢家（最早一次结算在前，赢家必须在候选人里）：{ { name=, index= }... }
-- index 是记录在 results 里的下标，分配成功后用 ConsumeResult 移除，避免同一件被重复分配。
function LootAssign.AuctionWinners(ctx)
    local out = {}
    for i, r in ipairs(ctx.results or {}) do
        if r.winner and r.id == ctx.item and InRoster(ctx.roster, r.winner) then
            out[#out + 1] = { name = r.winner, index = i }
        end
    end
    return out
end

function LootAssign.ConsumeResult(results, index)
    if results and results[index] then table.remove(results, index) return true end
    return false
end

-- 按职业分组：{ { class = "WARRIOR", names = { ... } }... }，职业按中文名排序，组内按名字排序
function LootAssign.ByClass(ctx)
    local groups = {}
    for _, m in ipairs(ctx.roster or {}) do
        local token = ns.Util.NormClass(m.class) or "UNKNOWN"
        groups[token] = groups[token] or {}
        table.insert(groups[token], m.name)
    end
    local out = {}
    for token, names in pairs(groups) do
        table.sort(names)
        out[#out + 1] = { class = token, label = ns.Util.CLASS_NAME_ZH[token] or "未知", names = names }
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

-- 分配前是否需要二次确认：设置了"总是询问"，或物品为紫色及以上
function LootAssign.NeedConfirm(quality, ask)
    if ask then return true end
    return (tonumber(quality) or 0) >= 4
end
