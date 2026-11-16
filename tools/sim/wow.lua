-- tools/sim/wow.lua：离线模拟的魔兽客户端（多个客户端同团）。
-- 用于在本机跑通"游戏内验收"的流程，不能代替真正进游戏：
--   · 界面构件只检查调用的方法名是否真实存在（未知方法直接报错），不模拟真实的排版和绘制。
--   · 团队聊天、插件消息在客户端之间投递，有 0.02 秒延迟；自己发的也会收到（与正式服一致）。
-- 用法见 tools/sim/run.lua。
local Sim = {}

------------------------------------------------------------------------
-- 时钟与定时器
------------------------------------------------------------------------

Sim.clock = 0
local timers = {}

function Sim.Schedule(delay, fn, every, n)
    local t = { at = Sim.clock + delay, fn = fn, every = every, n = n }
    function t.Cancel(self) self.cancelled = true end
    function t.IsCancelled(self) return self.cancelled end
    timers[#timers + 1] = t
    return t
end

function Sim.Run(seconds)
    local stop = Sim.clock + seconds
    while Sim.clock < stop do
        Sim.clock = Sim.clock + 0.05
        local due = {}
        for _, t in ipairs(timers) do if not t.cancelled and t.at <= Sim.clock then due[#due + 1] = t end end
        table.sort(due, function(a, b) return a.at < b.at end)
        for _, t in ipairs(due) do
            if t.every then
                t.at = t.at + t.every
                if t.n then t.n = t.n - 1; if t.n <= 0 then t.cancelled = true end end
            else
                t.cancelled = true
            end
            t.fn(t)
        end
        local keep = {}
        for _, t in ipairs(timers) do if not t.cancelled then keep[#keep + 1] = t end end
        timers = keep
    end
end

------------------------------------------------------------------------
-- 界面构件（只校验方法名）
------------------------------------------------------------------------

local REGION = {
    "SetPoint", "ClearAllPoints", "SetAllPoints", "GetPoint", "GetNumPoints", "SetSize", "SetWidth", "SetHeight",
    "GetWidth", "GetHeight", "GetSize", "Show", "Hide", "IsShown", "IsVisible", "SetShown", "SetAlpha", "GetAlpha",
    "GetParent", "SetParent", "GetName", "GetObjectType", "IsObjectType", "IsMouseOver", "SetScale", "GetScale",
    "GetEffectiveScale", "GetCenter", "GetLeft", "GetRight", "GetTop", "GetBottom", "SetIgnoreParentAlpha",
}
local FRAME = {
    "CreateTexture", "CreateFontString", "CreateMaskTexture", "SetScript", "GetScript", "HookScript", "HasScript",
    "RegisterEvent", "UnregisterEvent", "UnregisterAllEvents", "EnableMouse", "EnableMouseWheel", "SetMovable",
    "StartMoving", "StopMovingOrSizing", "RegisterForDrag", "SetClampedToScreen", "SetFrameStrata", "GetFrameStrata",
    "SetFrameLevel", "GetFrameLevel", "SetClipsChildren", "SetToplevel", "Raise", "Lower", "GetChildren",
    "CreateAnimationGroup", "SetHitRectInsets", "SetUserPlaced", "IsMovable", "SetResizable", "EnableKeyboard",
    "SetPropagateKeyboardInput", "IsMouseEnabled",
}
local BUTTON = {
    "SetText", "GetText", "SetFontString", "GetFontString", "RegisterForClicks", "Enable", "Disable", "IsEnabled",
    "SetEnabled", "SetNormalFontObject", "SetHighlightFontObject", "SetDisabledFontObject", "Click", "LockHighlight",
    "UnlockHighlight", "SetNormalTexture", "SetPushedTexture", "SetHighlightTexture", "GetNormalTexture",
    "GetHighlightTexture", "SetButtonState", "SetChecked", "GetChecked",
}
local EDITBOX = {
    "SetText", "GetText", "SetFont", "SetFontObject", "SetAutoFocus", "SetTextInsets", "SetMultiLine", "SetFocus",
    "ClearFocus", "HighlightText", "SetCursorPosition", "GetCursorPosition", "SetTextColor", "SetMaxLetters",
    "GetNumber", "HasFocus", "Insert", "SetNumeric", "SetJustifyH", "IsMultiLine", "Enable", "Disable",
}
local SCROLLFRAME = { "SetScrollChild", "GetScrollChild", "GetVerticalScroll", "SetVerticalScroll",
    "GetVerticalScrollRange", "UpdateScrollChildRect", "SetHorizontalScroll" }
local SLIDER = { "SetOrientation", "SetThumbTexture", "GetThumbTexture", "SetMinMaxValues", "GetMinMaxValues",
    "SetValueStep", "SetObeyStepOnDrag", "SetValue", "GetValue", "Enable", "Disable", "SetStepsPerPage" }
local TEXTURE = { "SetTexture", "SetColorTexture", "SetTexCoord", "SetVertexColor", "AddMaskTexture", "SetDrawLayer",
    "SetBlendMode", "SetDesaturated", "SetAtlas", "GetTexture", "SetGradient", "SetRotation", "SetSnapToPixelGrid",
    "SetTexelSnappingBias" }
local FONTSTRING = { "SetFont", "SetText", "GetText", "SetTextColor", "GetTextColor", "SetJustifyH", "SetJustifyV",
    "SetWordWrap", "GetStringWidth", "GetStringHeight", "SetFontObject", "GetFont", "SetNonSpaceWrap", "SetMaxLines",
    "SetShadowOffset", "SetShadowColor", "SetFormattedText", "GetUnboundedStringWidth", "SetDrawLayer" }
local ANIMGROUP = { "CreateAnimation", "Play", "Stop", "SetLooping", "IsPlaying", "SetScript" }

local function set(...)
    local s = {}
    for _, list in ipairs({ ... }) do for _, m in ipairs(list) do s[m] = true end end
    return s
end

local ALLOWED = {
    Frame = set(REGION, FRAME), EventFrame = set(REGION, FRAME),
    Button = set(REGION, FRAME, BUTTON), CheckButton = set(REGION, FRAME, BUTTON),
    EditBox = set(REGION, FRAME, EDITBOX), ScrollFrame = set(REGION, FRAME, SCROLLFRAME),
    Slider = set(REGION, FRAME, SLIDER), Texture = set(REGION, TEXTURE), MaskTexture = set(REGION, TEXTURE),
    FontString = set(REGION, FONTSTRING), GameTooltip = set(REGION, FRAME, { "SetOwner", "SetText", "AddLine",
        "AddDoubleLine", "SetHyperlink", "ClearLines", "NumLines" }),
    AnimationGroup = set(ANIMGROUP), Animation = set({ "SetFromAlpha", "SetToAlpha", "SetDuration", "SetStartDelay",
        "SetOrder", "SetScript" }),
}

local function utf8len(s)
    local _, n = tostring(s or ""):gsub("[^\128-\191]", "")
    return n
end

function Sim.NewWidget(kind, parent, name, env)
    local w = { _kind = kind, _parent = parent, _name = name, _shown = true, _scripts = {}, _points = {},
        _alpha = 1, _scale = 1, _children = {} }
    if parent and parent._children then parent._children[#parent._children + 1] = w end
    local impl = {}
    function impl.SetPoint(self, ...) self._points[#self._points + 1] = { ... } end
    function impl.ClearAllPoints(self) self._points = {} end
    function impl.SetAllPoints(self) self._points = { { "ALL" } } end
    function impl.GetPoint(self, i) local p = self._points[i or 1]; if p then return unpack(p) end end
    function impl.GetNumPoints(self) return #self._points end
    -- 和真实客户端一样：尺寸必须是数字
    local function num(v, what) assert(type(v) == "number", "bad argument to '" .. what .. "' (需要数字，得到 " .. type(v) .. ")") return v end
    function impl.SetSize(self, wd, h) self._w, self._h = num(wd, "SetSize"), num(h, "SetSize") end
    function impl.SetWidth(self, wd) self._w = num(wd, "SetWidth") end
    function impl.SetHeight(self, h) self._h = num(h, "SetHeight") end
    local function dim(self, key)
        if self[key] then return self[key] end
        if #self._points >= 2 or (self._points[1] and self._points[1][1] == "ALL") then
            return self._parent and dim(self._parent, key) or 600
        end
        return 0
    end
    function impl.GetWidth(self) return dim(self, "_w") end
    function impl.GetHeight(self) return dim(self, "_h") end
    function impl.GetSize(self) return dim(self, "_w"), dim(self, "_h") end
    function impl.Show(self)
        local was = self._shown
        self._shown = true
        if not was and self._scripts.OnShow then self._scripts.OnShow(self) end
    end
    function impl.Hide(self)
        local was = self._shown
        self._shown = false
        if was and self._scripts.OnHide then self._scripts.OnHide(self) end
    end
    function impl.IsShown(self) return self._shown end
    function impl.IsVisible(self)
        local p = self
        while p do if not p._shown then return false end p = p._parent end
        return true
    end
    function impl.SetShown(self, v) if v then self:Show() else self:Hide() end end
    function impl.SetAlpha(self, a) self._alpha = a end
    function impl.GetAlpha(self) return self._alpha end
    function impl.GetParent(self) return self._parent end
    function impl.SetParent(self, p) self._parent = p end
    function impl.GetName(self) return self._name end
    function impl.GetObjectType(self) return self._kind end
    function impl.IsObjectType(self, t) return self._kind == t end
    function impl.IsMouseOver(self) return self._mouseOver or false end
    function impl.SetScale(self, s) self._scale = s end
    function impl.GetScale(self) return self._scale end
    function impl.GetEffectiveScale(self) return self._scale end
    function impl.GetCenter() return 0, 0 end
    function impl.CreateTexture(self) return Sim.NewWidget("Texture", self, nil, env) end
    function impl.CreateMaskTexture(self) return Sim.NewWidget("MaskTexture", self, nil, env) end
    function impl.CreateFontString(self) return Sim.NewWidget("FontString", self, nil, env) end
    function impl.CreateAnimationGroup(self) return Sim.NewWidget("AnimationGroup", self, nil, env) end
    function impl.CreateAnimation(self) return Sim.NewWidget("Animation", self, nil, env) end
    function impl.SetScript(self, k, fn) self._scripts[k] = fn end
    function impl.GetScript(self, k) return self._scripts[k] end
    function impl.HasScript() return true end
    function impl.HookScript(self, k, fn)
        local old = self._scripts[k]
        self._scripts[k] = old and function(...) old(...) fn(...) end or fn
    end
    function impl.SetText(self, t)
        -- 按钮的文字写进它的 FontString（与真实客户端一致）
        if self._fs then self._fs._text = t else self._text = t end
    end
    function impl.GetText(self)
        if self._fs then return self._fs._text end
        return self._text
    end
    function impl.SetFontString(self, fs) self._fs = fs end
    function impl.GetFontString(self) return self._fs end
    function impl.GetStringWidth(self) return utf8len(self._text) * 7 end
    function impl.GetTextColor(self) return unpack(self._color or { 1, 1, 1, 1 }) end
    function impl.SetTextColor(self, r, g, b, a) self._color = { r, g, b, a or 1 } end
    function impl.Enable(self) self._enabled = true end
    function impl.Disable(self) self._enabled = false end
    function impl.IsEnabled(self) return self._enabled ~= false end
    function impl.SetEnabled(self, v) self._enabled = v and true or false end
    function impl.GetValue(self) return self._value or 0 end
    function impl.SetValue(self, v) self._value = v end
    function impl.GetThumbTexture(self) return self._thumb end
    function impl.SetThumbTexture(self, t) self._thumb = t end
    function impl.GetVerticalScroll() return 0 end
    function impl.GetVerticalScrollRange() return 0 end
    function impl.GetNumber(self) return tonumber(self._text) or 0 end
    function impl.HasFocus() return false end
    function impl.GetChecked(self) return self._checked end
    function impl.SetChecked(self, v) self._checked = v end
    function impl.IsPlaying() return false end
    function impl.GetFrameLevel() return 1 end
    function impl.NumLines() return 0 end
    function impl.GetCursorPosition() return 0 end

    local allowed = ALLOWED[kind]
    if not allowed then error("CreateFrame: unknown frame type " .. tostring(kind), 3) end
    return setmetatable(w, { __index = function(_, k)
        if type(k) ~= "string" or k:sub(1, 1) == "_" then return nil end
        if not k:match("^%u") then return nil end               -- 自定义字段（小写开头）
        if not allowed[k] then
            error(("界面方法不存在：%s:%s"):format(kind, k), 2)
        end
        return impl[k] or function() end
    end })
end

------------------------------------------------------------------------
-- 世界：团队成员、客户端
------------------------------------------------------------------------

Sim.raid = {}           -- { name=, class=, rank= }
Sim.clients = {}        -- 名字 → 客户端
Sim.chatLog = {}
Sim.errors = {}

function Sim.InRaid(name)
    for _, m in ipairs(Sim.raid) do if m.name == name then return m end end
end

function Sim.Broadcast(ev, ...)
    local args = { n = select("#", ...), ... }
    for _, m in ipairs(Sim.raid) do
        local c = Sim.clients[m.name]
        if c then c.fire(ev, unpack(args, 1, args.n)) end
    end
end

local function ReadToc(root)
    local files = {}
    for line in io.lines(root .. "/RaidWish.toc") do
        if not line:match("^#") and line:match("%.lua%s*$") then
            files[#files + 1] = (line:gsub("\\", "/"):gsub("%s+$", ""))
        end
    end
    return files
end

function Sim.NewClient(root, name, opts)
    opts = opts or {}
    local c = { name = name, out = {}, popups = {}, menus = {} }
    local eventFrames = {}
    local env
    env = {
        pairs = pairs, ipairs = ipairs, type = type, tostring = tostring, tonumber = tonumber, select = select,
        pcall = pcall, xpcall = xpcall, unpack = unpack, next = next, table = table, string = string, math = math, assert = assert,
        setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget, rawset = rawset, error = error,
        print = print, date = os.date, tinsert = table.insert, tremove = table.remove, strsplit = nil,
        time = function() return 1800000000 + math.floor(Sim.clock) end,
        GetTime = function() return Sim.clock end,
        geterrorhandler = function()
            return function(e)
                local msg = "ERROR in " .. name .. ": " .. tostring(e)
                c.out[#c.out + 1] = msg
                Sim.errors[#Sim.errors + 1] = msg
                print("!! " .. msg)
            end
        end,
        DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) c.out[#c.out + 1] = m end },
        SlashCmdList = {}, StaticPopupDialogs = {}, UISpecialFrames = {},
        StaticPopup_Show = function(which)
            c.popups[#c.popups + 1] = which
            local d = env.StaticPopupDialogs[which]
            if d and d.OnShow then
                local eb = Sim.NewWidget("EditBox", nil, nil, env)
                c.popupEdit = eb
                local dialog = { editBox = eb, GetEditBox = function() return eb end, Hide = function() end }
                c.popupDialog = dialog
                d.OnShow(dialog)
            end
        end,
        STANDARD_TEXT_FONT = "Fonts\\ARKai_T.ttf",
        IsInRaid = function() return Sim.InRaid(name) ~= nil end,
        IsInGroup = function() return Sim.InRaid(name) ~= nil end,
        UnitName = function(u)                  -- "无限"：两段名字分开返回
            if u == "player" then
                local a, b = name:match("^(%S+) (%S+)$")
                if a then return a, b end
                return name
            end
        end,
        UnitClass = function() return opts.class, opts.class end,
        UnitIsGroupLeader = function() local m = Sim.InRaid(name); return m and m.rank == 2 end,
        UnitIsGroupAssistant = function() local m = Sim.InRaid(name); return m and m.rank == 1 end,
        GetNumGroupMembers = function() return Sim.InRaid(name) and #Sim.raid or 0 end,
        GetRaidRosterInfo = function(i)
            local m = Sim.raid[i]
            if not m then return nil end
            return m.name .. "-无限", m.rank, 1, 60, m.class, m.class, "zone", true
        end,
        IsEncounterInProgress = function() return false end,
        InCombatLockdown = function() return false end,
        IsShiftKeyDown = function() return false end,
        GetCursorPosition = function() return 0, 0 end,
        ReloadUI = function() c.reloaded = true end,
        RandomRoll = function(lo, hi)
            local v = Sim.nextRoll and Sim.nextRoll[name] or math.random(lo, hi)
            Sim.Schedule(0.02, function()
                Sim.Broadcast("CHAT_MSG_SYSTEM", name .. "掷出" .. v .. "（" .. lo .. "-" .. hi .. "）")
            end)
        end,
        CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end,
        Menu = { ModifyMenu = function(tag, fn) c.menuHooks = c.menuHooks or {}; c.menuHooks[tag] = fn end },
        GetCursorInfo = function() return Sim.cursor and "item", Sim.cursor end,
        ClearCursor = function() Sim.cursor = nil end,
        ChatEdit_InsertLink = function() end,
        PlaySoundFile = function(path)
            -- 可选语音包：Sim.packFiles 里登记了的才算存在；不存在时和游戏一样返回 false，不算错误
            local packName = path:match("^Interface\\AddOns\\RaidWish_Voice\\voice\\([%w_]+)%.ogg$")
            if packName then
                if not (Sim.packFiles and Sim.packFiles[packName]) then return false end
                c.sounds = c.sounds or {}
                c.sounds[#c.sounds + 1] = path
                return true
            end
            c.sounds = c.sounds or {}
            c.sounds[#c.sounds + 1] = path
            -- 语音文件必须真的存在：Interface\AddOns\RaidWish\voice\x.ogg → 插件目录下的 voice/x.ogg
            local rel = path:gsub("^Interface\\AddOns\\RaidWish\\", ""):gsub("\\", "/")
            local fh = io.open(root .. "/" .. rel, "rb")
            if fh then fh:close() else Sim.errors[#Sim.errors + 1] = "语音文件不存在：" .. rel end
            return true
        end,
        hooksecurefunc = function() end,
        issecretvalue = opts.secret or function() return false end,
        Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3 } },
        RAID_CLASS_COLORS = nil,
        RANDOM_ROLL_RESULT = "%s掷出%d（%d-%d）",
        LOOT_ITEM = "%s获得了物品：%s。", LOOT_ITEM_SELF = "你获得了物品：%s。",
        LOOT_ITEM_MULTIPLE = "%s获得了物品：%sx%d。", LOOT_ITEM_SELF_MULTIPLE = "你获得了物品：%sx%d。",
        LOOT_ITEM_PUSHED_SELF = "你获得了物品：%s。", LOOT_ITEM_PUSHED_SELF_MULTIPLE = "你获得了物品：%sx%d。",
        C_Timer = {
            After = function(d, f) Sim.Schedule(d, f) end,
            NewTimer = function(d, f) return Sim.Schedule(d, f) end,
            NewTicker = function(d, f, n) return Sim.Schedule(d, f, d, n) end,
        },
        C_Item = {
            GetItemInfo = function(id)
                local i = Sim.items and Sim.items[tonumber(id)]
                if i then return i.name, i.link, i.quality, 60, 60, "", "", 1, "", i.icon end
            end,
            RequestLoadItemDataByID = function() end,
            GetItemIconByID = function(id) local i = Sim.items and Sim.items[id]; return i and i.icon end,
        },
        C_ChatInfo = {
            RegisterAddonMessagePrefix = function() return true end,
            InChatMessagingLockdown = function() return Sim.lockdown and true or false end,
            SendAddonMessage = function(prefix, text, channel)
                assert(#text <= 255, "插件消息超过 255 字节")
                if not Sim.InRaid(name) then return 5 end
                Sim.Schedule(0.02, function() Sim.Broadcast("CHAT_MSG_ADDON", prefix, text, channel, name .. "-无限") end)
                return 0
            end,
            SendChatMessage = function(text, channel)
                assert(#text <= 255, "聊天超过 255 字节：" .. #text)
                assert(not text:find("\n"), "聊天里有换行")
                if not Sim.InRaid(name) then error("not in raid") end
                local ev = (channel == "RAID_WARNING") and "CHAT_MSG_RAID_WARNING" or "CHAT_MSG_RAID"
                Sim.chatLog[#Sim.chatLog + 1] = "[" .. name .. "][" .. channel .. "] " .. text
                Sim.Schedule(0.02, function() Sim.Broadcast(ev, text, name .. "-无限") end)
            end,
        },
        MenuUtil = {
            CreateContextMenu = function(owner, gen)
                local function node()
                    local n = { items = {} }
                    function n.SetEnabled(self, v) self.disabled = not v end
                    function n.CreateButton(self, text, fn)
                        local child = node()
                        child.text, child.fn = text, fn
                        self.items[#self.items + 1] = child
                        return child
                    end
                    function n.CreateTitle(self, text) self.items[#self.items + 1] = { title = text, items = {} } end
                    function n.CreateDivider(self) self.items[#self.items + 1] = { divider = true, items = {} } end
                    return n
                end
                local root = node()
                gen(owner, root)
                c.menus[#c.menus + 1] = root
                c.lastMenu = root
            end,
        },
    }
    env.UIParent = Sim.NewWidget("Frame", nil, "UIParent", env)
    env.Minimap = Sim.NewWidget("Frame", nil, "Minimap", env)
    env.Minimap:SetSize(140, 140)
    env.GameTooltip = Sim.NewWidget("GameTooltip", nil, "GameTooltip", env)
    env.CreateFrame = function(kind, fname, parent)
        local f = Sim.NewWidget(kind, parent, fname, env)
        if fname then rawset(env, fname, f) end
        eventFrames[#eventFrames + 1] = f
        return f
    end
    env._G = env
    setmetatable(env, { __index = function(_, k)
        if opts.strictGlobals and type(k) == "string" and k:match("^[%u_]") then
            -- 不存在的全局：返回 nil（游戏里也是 nil），但记一笔方便排查
            c.missingGlobals = c.missingGlobals or {}
            c.missingGlobals[k] = true
        end
    end })
    local ns = {}
    for _, f in ipairs(ReadToc(root)) do
        local chunk = assert(loadfile(root .. "/" .. f))
        setfenv(chunk, env)
        chunk("RaidWish", ns)
    end
    -- 事件：投递给所有注册了 OnEvent 的框体（插件只有一个事件框体）
    c.fire = function(ev, ...)
        for _, f in ipairs(eventFrames) do
            local fn = f._scripts and f._scripts.OnEvent
            if fn then
                local ok, err = pcall(fn, f, ev, ...)
                if not ok then env.geterrorhandler()(err) end
            end
        end
    end
    c.slash = function(msg) env.SlashCmdList.RAIDWISH(msg) end
    c.say = function(text) env.C_ChatInfo.SendChatMessage(text, "RAID") end
    c.ns, c.env = ns, env
    Sim.clients[name] = c
    -- opts.saved：模拟"上次写盘时的存档"（重登、崩溃后重登）
    if opts.saved then
        for k, v in pairs(opts.saved) do rawset(env, k, Sim.DeepCopy(v)) end
    end
    c.fire("ADDON_LOADED", "RaidWish")
    c.fire("PLAYER_LOGIN")
    return c
end

function Sim.DeepCopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = Sim.DeepCopy(x) end
    return t
end

-- 当前存档（相当于正常退出时写盘的内容）
function Sim.Saved(c)
    return { RaidWishDB = Sim.DeepCopy(c.env.RaidWishDB), RaidWishCharDB = Sim.DeepCopy(c.env.RaidWishCharDB) }
end

-- 游戏崩溃后用 saved（上次写盘的存档）重新登录；人还在团里
function Sim.CrashAndRelog(root, name, saved, opts)
    local old = Sim.clients[name]
    if old then old.fire = function() end end          -- 旧进程不再收到任何事件
    opts = opts or {}
    opts.saved = saved
    local c = Sim.NewClient(root, name, opts)
    c.fire("GROUP_ROSTER_UPDATE")
    return c
end

function Sim.RosterUpdate() Sim.Broadcast("GROUP_ROSTER_UPDATE") end

-- 某人拾取了一件物品：每个客户端看到各自措辞的拾取消息
function Sim.Loot(player, link)
    for _, m in ipairs(Sim.raid) do
        local c = Sim.clients[m.name]
        if c then
            local text = (m.name == player) and ("你获得了物品：" .. link .. "。") or (player .. "获得了物品：" .. link .. "。")
            c.fire("CHAT_MSG_LOOT", text, player)
        end
    end
end

function Sim.LootSnapshot(c)
    local out = {}
    for _, e in ipairs(c.ns.LootLog:Entries()) do
        out[#out + 1] = e.id .. ">" .. tostring(e.player) .. ":" .. tostring(e.points) .. (e.wish and "w" or "")
            .. (e.sold and ("=" .. tostring(e.sold.winner)) or "")
    end
    table.sort(out)
    return table.concat(out, " ")
end

function Sim.Join(name, class, rank)
    Sim.raid[#Sim.raid + 1] = { name = name, class = class, rank = rank or 0 }
    Sim.clients[name].fire("GROUP_JOINED")
    Sim.RosterUpdate()
end

function Sim.Leave(name)
    for i, m in ipairs(Sim.raid) do if m.name == name then table.remove(Sim.raid, i) break end end
    Sim.clients[name].fire("GROUP_ROSTER_UPDATE")
    Sim.clients[name].fire("GROUP_LEFT")
    Sim.RosterUpdate()
end

function Sim.SetRank(name, rank)
    Sim.InRaid(name).rank = rank
    Sim.RosterUpdate()
end

------------------------------------------------------------------------
-- 检查
------------------------------------------------------------------------

Sim.pass, Sim.fail = 0, 0

function Sim.Check(cond, msg)
    if cond then
        Sim.pass = Sim.pass + 1
        print("  ok   " .. msg)
    else
        Sim.fail = Sim.fail + 1
        print("  FAIL " .. msg)
    end
end

function Sim.Snapshot(c)
    local M = c.ns.WishModel
    local rows = c.ns.Wish.model:Sorted("name", true)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = r.name .. ":" .. tostring(r.rec.dkp) .. ":" .. (r.rec.wish and M.EncodeItems(r.rec.wish.items) or "-")
    end
    return table.concat(out, " | ")
end

function Sim.Same(a, b, msg)
    local sa, sb = Sim.Snapshot(a), Sim.Snapshot(b)
    Sim.Check(sa == sb, msg .. (sa == sb and "" or ("\n        " .. a.name .. ": " .. sa .. "\n        " .. b.name .. ": " .. sb)))
end

function Sim.Printed(c, pat)
    for _, m in ipairs(c.out) do if m:find(pat, 1, true) then return true end end
    return false
end

function Sim.ChatHas(pat)
    for _, l in ipairs(Sim.chatLog) do if l:find(pat, 1, true) then return true end end
    return false
end

-- 在菜单树里按文字路径找到项并点击，例如 Sim.ClickMenu(c, "增加分数", "增加2分")
-- 扁平菜单（RaidWishMenu）显示中时，按行查找并点击真实按钮
local function FlatRows(c)
    local m = c.env.RaidWishMenu
    if not (m and m:IsShown()) then return nil end
    local out = {}
    for _, r in ipairs(m.rows) do if r:IsShown() and r.item then out[#out + 1] = r end end
    return out
end

function Sim.ClickMenu(c, ...)
    local rows = FlatRows(c)
    if rows then
        local path, i = { ... }, 1
        for _, r in ipairs(rows) do
            local it = r.item
            if it.text == path[i] and (it.depth or 0) == i - 1 then
                if i == #path then
                    if r.button:IsShown() and r.button:IsEnabled() then Sim.Click(r.button) return true end
                    return false
                end
                i = i + 1
            end
        end
        return false
    end
    local node = c.lastMenu
    for _, text in ipairs({ ... }) do
        local found
        for _, it in ipairs(node and node.items or {}) do if it.text == text then found = it break end end
        if not found then return false end
        node = found
    end
    if node.fn then node.fn() return true end
    return false
end

function Sim.MenuTexts(c)
    local out = {}
    local rows = FlatRows(c)
    if rows then
        for _, r in ipairs(rows) do
            local it = r.item
            if (it.depth or 0) == 0 then
                out[#out + 1] = it.text and (it.title and ("<" .. it.text .. ">") or it.text) or (it.divider and "--") or "?"
            end
        end
        return table.concat(out, ",")
    end
    for _, it in ipairs(c.lastMenu and c.lastMenu.items or {}) do
        out[#out + 1] = it.text or (it.title and ("<" .. it.title .. ">")) or (it.divider and "--") or "?"
    end
    return table.concat(out, ",")
end

-- 递归查找第一个满足条件的子构件
function Sim.Find(w, pred)
    if pred(w) then return w end
    for _, ch in ipairs(w._children or {}) do
        local r = Sim.Find(ch, pred)
        if r then return r end
    end
end

function Sim.FindButton(root, text)
    return Sim.Find(root, function(w)
        if w._kind ~= "Button" and w._kind ~= "CheckButton" then return false end
        local label = (w._fs and w._fs._text) or (rawget(w, "_label") and w._label._text)
        return label == text and w:IsVisible()
    end)
end

function Sim.Click(btn, button)
    assert(btn, "没找到按钮")
    local fn = btn._scripts.OnClick
    assert(fn, "按钮没有 OnClick")
    fn(btn, button or "LeftButton")
end

return Sim
