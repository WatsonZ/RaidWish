-- Auction/Voice.lua：语音播报
-- 开关：设置 → 拍卖 → 语音播报（options.auction.voice）。
local ADDON, ns = ...

local Voice = {}
ns.Voice = Voice

local PATH = "Interface\\AddOns\\" .. ADDON .. "\\voice\\"
local lastPlay = 0
local delayedPending = false
local lastDelayed = 0

local function Enabled() return ns.DB.options.auction.voice and true or false end

local function Play(name)
    PlaySoundFile(PATH .. name .. ".ogg", "Master")
end

-- 1 秒内最多播一个（防止多个触发点叠在一起）
function Voice:Play(name)
    if not Enabled() then return end
    local t = GetTime()
    if t - lastPlay < 1 then return end
    lastPlay = t
    Play(name)
end

-- 延迟播放，不受 1 秒节流限制；同一时刻只允许一个待播放，且与上次实际播放间隔 3 秒以上（防回声）
function Voice:PlayDelayed(name, delay)
    if not Enabled() then return end
    if delayedPending then return end
    if GetTime() - lastDelayed < 3 then return end
    delayedPending = true
    ns.After(delay or 0, function()
        delayedPending = false
        lastDelayed = GetTime()
        Play(name)
    end)
end
