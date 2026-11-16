-- Auction/Voice.lua：语音播报
-- 开关：设置 → 拍卖 → 语音播报（options.auction.voice）。
--
-- 可选语音包：另装的插件 RaidWish_Voice 在加载时登记全局表
--   RaidWishVoicePack = { path = "Interface\\AddOns\\RaidWish_Voice\\voice\\", name = 名称, author = 录音者, license = 授权说明 }
-- 装了语音包且"使用语音包"开着时优先播语音包里的同名文件；语音包里缺的句子自动用插件自带的默认语音。
local ADDON, ns = ...

local Voice = {}
ns.Voice = Voice

local PATH = "Interface\\AddOns\\" .. ADDON .. "\\voice\\"
local lastPlay = 0
local delayedPending = false
local lastDelayed = 0

local function Enabled() return ns.DB.options.auction.voice and true or false end

-- 已安装的语音包（没有则返回 nil）
function Voice:Pack()
    local p = RaidWishVoicePack
    if type(p) == "table" and type(p.path) == "string" and p.path ~= "" then return p end
    return nil
end

-- 当前是否在用语音包
function Voice:UsingPack()
    return self:Pack() ~= nil and ns.DB.options.auction.voicePack ~= false
end

local function Play(name)
    if Voice:UsingPack() then
        local ok, willPlay = pcall(PlaySoundFile, Voice:Pack().path .. name .. ".ogg", "Master")
        if ok and willPlay then return end
    end
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
