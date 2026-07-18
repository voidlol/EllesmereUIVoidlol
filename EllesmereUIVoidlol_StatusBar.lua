-------------------------------------------------------------------------------
--  EllesmereUIVoidlol_StatusBar.lua
--  A small movable text bar: FPS+Latency / Durability / Clock, each an
--  independently toggleable, orderable block. Deliberately self-contained --
--  reads only vanilla Blizzard APIs, no reference to EllesmereUIDataBars --
--  because DataBars auto-updates and overwrites any direct edit to its own
--  files, so this is the only way custom coloring/behavior survives an
--  update. Positioned via Unlock Mode, same pattern as the Healer Mana
--  containers. Tooltip/click content for FPS+Latency and Clock is a
--  deliberate copy of EllesmereUIDataBars_Blocks.lua's fps/ms/clock blocks
--  (rebuilt against GameTooltip since ns.Tip_* is private to that addon).
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EVL = ns.EVL

local function DB()
    local d = EVL.DB and EVL.DB()
    return d and d.qol and d.qol.statusBar
end

local function GetFontPath(fontKey)
    if not fontKey or fontKey == "__global" then
        return (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
    end
    return (EllesmereUI.ResolveFontName and EllesmereUI.ResolveFontName(fontKey)) or "Fonts\\FRIZQT__.TTF"
end

local function LabelColor(cfg)
    return cfg.labelColorR or 0.6, cfg.labelColorG or 0.6, cfg.labelColorB or 0.6
end

local function ColorText(text, r, g, b)
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor((r or 1) * 255 + 0.5),
        math.floor((g or 1) * 255 + 0.5),
        math.floor((b or 1) * 255 + 0.5),
        text)
end

-------------------------------------------------------------------------------
--  Value coloring -- same tiers as the EllesmereUIDataBars FPS/MS patch,
--  extended to Durability. Only the VALUE gets this; labels use the
--  separate Label Color setting.
-------------------------------------------------------------------------------
local function FpsRGB(fps)
    if fps >= 100 then return 0.25, 1, 0.25
    elseif fps >= 60 then return 0.55, 1, 0.25
    elseif fps >= 30 then return 1, 1, 0.25 end
    return 1, 0.35, 0.25
end

local function MsRGB(ms)
    if ms < 75 then return 0.25, 1, 0.25
    elseif ms < 150 then return 1, 1, 0.25 end
    return 1, 0.35, 0.25
end

local function DurabilityRGB(pct)
    if pct >= 50 then return 0.25, 1, 0.25
    elseif pct >= 20 then return 1, 1, 0.25 end
    return 1, 0.35, 0.25
end

-------------------------------------------------------------------------------
--  Durability sampling -- per-slot, for the tooltip breakdown. Slot ids are
--  the fixed Blizzard equipment slot numbers; labels use Blizzard's own
--  localized INVTYPE_* globals where available so this reads correctly on
--  non-English clients too.
-------------------------------------------------------------------------------
local SLOT_ORDER = { 1, 3, 5, 6, 7, 8, 9, 10, 15, 16, 17 }
local SLOT_LABELS = {
    [1]  = INVTYPE_HEAD or "Head",
    [3]  = INVTYPE_SHOULDER or "Shoulder",
    [5]  = INVTYPE_CHEST or "Chest",
    [6]  = INVTYPE_WAIST or "Waist",
    [7]  = INVTYPE_LEGS or "Legs",
    [8]  = INVTYPE_FEET or "Feet",
    [9]  = INVTYPE_WRIST or "Wrist",
    [10] = INVTYPE_HAND or "Hands",
    [15] = INVTYPE_CLOAK or "Back",
    [16] = INVTYPE_WEAPONMAINHAND or "Main Hand",
    [17] = INVTYPE_WEAPONOFFHAND or "Off Hand",
}

-- Lowest %, for the block's own displayed value.
local function SampleDurability()
    local lowest = 100
    for _, slotId in ipairs(SLOT_ORDER) do
        local cur, maxDur = GetInventoryItemDurability(slotId)
        if cur and maxDur and maxDur > 0 then
            local pct = cur / maxDur * 100
            if pct < lowest then lowest = pct end
        end
    end
    return math.floor(lowest)
end

-------------------------------------------------------------------------------
--  Block text builders
-------------------------------------------------------------------------------
local function BuildFpsMsText(cfg)
    local lr, lg, lb = LabelColor(cfg)
    local fps = math.floor(GetFramerate())
    local fr, fg, fb = FpsRGB(fps)

    local bcfg = cfg.blocks.fps
    local _, _, home, world = GetNetStats()
    local ms = math.floor((bcfg and bcfg.useWorldLatency) and world or home)
    local mr, mg, mb = MsRGB(ms)

    return ColorText("FPS: ", lr, lg, lb) .. ColorText(tostring(fps), fr, fg, fb)
        .. ColorText("  MS: ", lr, lg, lb) .. ColorText(tostring(ms), mr, mg, mb)
end

local function BuildDurabilityText(cfg)
    local lr, lg, lb = LabelColor(cfg)
    local pct = SampleDurability()
    local dr, dg, db = DurabilityRGB(pct)
    return ColorText("Durability: ", lr, lg, lb) .. ColorText(pct .. "%", dr, dg, db)
end

local function BuildClockText(cfg)
    local lr, lg, lb = LabelColor(cfg)
    return ColorText(date("%H:%M"), lr, lg, lb)
end

local BUILDERS = {
    fps        = BuildFpsMsText,
    durability = BuildDurabilityText,
    clock      = BuildClockText,
}

-------------------------------------------------------------------------------
--  Tooltips (GameTooltip -- DataBars' ns.Tip_* is private to that addon) and
--  clicks. FPS+MS and Clock content/behavior are a deliberate copy of
--  EllesmereUIDataBars_Blocks.lua's fps/ms/clock blocks.
-------------------------------------------------------------------------------
local sysMemTable, sysLastMemScanTime = {}, 0

local function ShowFpsMsTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")

    -- Latency first, then FPS -- per spec, latency tooltip + fps tooltip.
    local _, _, home, world = GetNetStats()
    home, world = math.floor(home), math.floor(world)
    GameTooltip:AddDoubleLine("Home", home .. " ms", 0.6, 0.6, 0.6, MsRGB(home))
    GameTooltip:AddDoubleLine("World", world .. " ms", 0.6, 0.6, 0.6, MsRGB(world))

    local fps = math.floor(GetFramerate())
    GameTooltip:AddDoubleLine("FPS", tostring(fps), 0.6, 0.6, 0.6, FpsRGB(fps))

    local now = GetTime()
    if (now - sysLastMemScanTime) >= 30 then
        sysLastMemScanTime = now
        UpdateAddOnMemoryUsage()
        wipe(sysMemTable)
        for i = 1, C_AddOns.GetNumAddOns() do
            local _, name = C_AddOns.GetAddOnInfo(i)
            local mem = GetAddOnMemoryUsage(i)
            if mem and mem > 0 then
                sysMemTable[#sysMemTable + 1] = { name = name, mem = mem }
            end
        end
        table.sort(sysMemTable, function(a, b) return a.mem > b.mem end)
    end

    if #sysMemTable > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Memory Usage", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        for i = 1, math.min(10, #sysMemTable) do
            local m = sysMemTable[i]
            local memStr = m.mem > 1024 and string.format("%.2f MB", m.mem / 1024) or string.format("%.0f KB", m.mem)
            GameTooltip:AddDoubleLine(m.name, memStr, 1, 1, 1, 1, 1, 1)
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Shift + Left Click:", "Force garbage collection", 1, 1, 1, 1, 1, 1)
    GameTooltip:Show()
end

local function OnFpsMsClick(self, button)
    if button ~= "LeftButton" then return end
    if IsShiftKeyDown() then collectgarbage("collect") end
    local memKb = collectgarbage("count")
    local msg = memKb > 1024 and string.format("%.2f MB", memKb / 1024) or string.format("%.0f KB", memKb)
    print("|cff0cd29fVoidlol|r: Memory usage snapshot |cffffff00" .. msg .. "|r")
    if GameTooltip:IsOwned(self) then ShowFpsMsTooltip(self) end
end

local function ShowDurabilityTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:AddLine("Equipment Durability", 1, 1, 1)
    local any = false
    for _, slotId in ipairs(SLOT_ORDER) do
        local cur, maxDur = GetInventoryItemDurability(slotId)
        if cur and maxDur and maxDur > 0 then
            any = true
            local pct = math.floor(cur / maxDur * 100)
            GameTooltip:AddDoubleLine(SLOT_LABELS[slotId] or ("Slot " .. slotId), pct .. "%", 0.6, 0.6, 0.6, DurabilityRGB(pct))
        end
    end
    if not any then
        GameTooltip:AddLine("No equipped items with durability.", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

local function ShowClockTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:AddLine(date("%A %d %B %Y"), 1, 1, 1)
    local gh, gm = GetGameTime()
    GameTooltip:AddDoubleLine("Server time", string.format("%02d:%02d", math.floor(gh), math.floor(gm)), 0.6, 0.6, 0.6, 1, 1, 1)

    local numInstances = GetNumSavedInstances and GetNumSavedInstances() or 0
    if numInstances > 0 then
        local any = false
        for i = 1, numInstances do
            local name, _, reset, _, locked, extended = GetSavedInstanceInfo(i)
            if locked or extended then
                if not any then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Saved Raid(s)", 1, 0.82, 0)
                    any = true
                end
                GameTooltip:AddDoubleLine(name, SecondsToTime(reset), 1, 1, 1, 0.6, 0.6, 0.6)
            end
        end
    end

    GameTooltip:AddLine(" ")
    local dailyReset = GetQuestResetTime and GetQuestResetTime() or 0
    if dailyReset > 0 then
        GameTooltip:AddDoubleLine("Daily reset", SecondsToTime(dailyReset), 0.6, 0.6, 0.6, 1, 1, 1)
    end
    local weeklyReset = (C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset and C_DateAndTime.GetSecondsUntilWeeklyReset()) or 0
    if weeklyReset > 0 then
        GameTooltip:AddDoubleLine("Weekly reset", SecondsToTime(weeklyReset), 0.6, 0.6, 0.6, 1, 1, 1)
    end
    if HasNewMail() then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("You've Got Mail!", 1, 0.82, 0)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Left Click:", "Toggle Calendar", 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Right Click:", "Toggle Clock", 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Shift + Middle Click:", "Reload UI", 1, 1, 1, 1, 1, 1)
    GameTooltip:Show()
end

local function OnClockClick(self, button)
    if button == "LeftButton" then
        if ToggleCalendar then ToggleCalendar() end
    elseif button == "RightButton" then
        if ToggleTimeManager then ToggleTimeManager()
        elseif GameTimeFrame then GameTimeFrame:Click() end
    elseif button == "MiddleButton" and IsShiftKeyDown() then
        if InCombatLockdown() then return end
        ReloadUI()
    end
end

-------------------------------------------------------------------------------
--  Container + per-block frames
-------------------------------------------------------------------------------
local BLOCK_KEYS = { "fps", "durability", "clock" }

local container, bgTexture
local blockFrames, blockTexts = {}, {}

local function EnsureContainer()
    if container then return container end
    container = CreateFrame("Frame", "EllesmereUIVoidlol_StatusBar", UIParent)
    container:Hide()

    bgTexture = container:CreateTexture(nil, "BACKGROUND")
    bgTexture:SetAllPoints()
    bgTexture:Hide()

    for _, key in ipairs(BLOCK_KEYS) do
        local btn = CreateFrame("Button", nil, container)
        btn:EnableMouse(true)
        btn:RegisterForClicks("AnyUp")
        btn:Hide()

        local fs = btn:CreateFontString(nil, "OVERLAY")
        fs:SetPoint("CENTER")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:SetMaxLines(1)
        btn.text = fs

        blockFrames[key] = btn
        blockTexts[key] = fs
    end

    blockFrames.fps:SetScript("OnEnter", function(self) ShowFpsMsTooltip(self) end)
    blockFrames.fps:SetScript("OnLeave", function() GameTooltip:Hide() end)
    blockFrames.fps:SetScript("OnClick", OnFpsMsClick)

    blockFrames.durability:SetScript("OnEnter", function(self) ShowDurabilityTooltip(self) end)
    blockFrames.durability:SetScript("OnLeave", function() GameTooltip:Hide() end)

    blockFrames.clock:SetScript("OnEnter", function(self) ShowClockTooltip(self) end)
    blockFrames.clock:SetScript("OnLeave", function() GameTooltip:Hide() end)
    blockFrames.clock:SetScript("OnClick", OnClockClick)

    return container
end

local function ApplyPosition()
    local cfg = DB()
    if not cfg or not container then return end
    container:ClearAllPoints()
    local pos = cfg.pos
    if pos then
        container:SetPoint("CENTER", UIParent, "CENTER", pos.centerX, pos.centerY)
    else
        container:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
    end
end

-- Below the bar's natural (auto-fit) width: tight left-to-right pack, each
-- block sized to its own content, `spacing` px gaps -- the original layout.
-- At/above natural width: the configured Width wins, split into N equal
-- slots, with each block's text centered inside its slot (blockTexts[key]
-- is anchored "CENTER" of its button once, in EnsureContainer, so resizing
-- the button is enough -- no re-anchoring needed here).
local function RefreshStatusBar()
    local cfg = DB()
    if not (cfg and container) then return end

    local fontPath = GetFontPath(cfg.fontFace)
    local fontSize = cfg.fontSize or 13
    local outline = cfg.outline ~= false and "OUTLINE" or ""
    local spacing = cfg.spacing or 12
    local vPad = cfg.vPadding or 3

    local active = {}
    for _, key in ipairs(BLOCK_KEYS) do
        local bcfg = cfg.blocks and cfg.blocks[key]
        if bcfg and bcfg.enabled then
            active[#active + 1] = { key = key, order = bcfg.order or 99 }
        end
    end
    table.sort(active, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.key < b.key
    end)

    for _, key in ipairs(BLOCK_KEYS) do
        blockFrames[key]:Hide()
    end

    if #active == 0 then
        container:SetSize(20, math.max(16, fontSize + vPad * 2))
        bgTexture:Hide()
        return
    end

    -- Pass 1: text + natural (content-hugging) size per active block.
    local natural = {}
    local naturalTotal = 0
    local textH = 0
    for i, entry in ipairs(active) do
        local fs = blockTexts[entry.key]
        fs:SetFont(fontPath, fontSize, outline)
        fs:SetText(BUILDERS[entry.key](cfg))

        local w = math.max(4, fs:GetStringWidth() or 4)
        natural[i] = w
        naturalTotal = naturalTotal + w + (i > 1 and spacing or 0)
        local h = fs:GetStringHeight() or fontSize
        if h > textH then textH = h end
    end
    local blockH = textH + vPad * 2

    local finalWidth = math.max(cfg.width or 0, naturalTotal)

    if finalWidth <= naturalTotal + 0.5 then
        local x = 0
        for i, entry in ipairs(active) do
            local btn = blockFrames[entry.key]
            btn:SetSize(natural[i], blockH)
            btn:ClearAllPoints()
            btn:SetPoint("LEFT", container, "LEFT", x, 0)
            btn:Show()
            x = x + natural[i] + spacing
        end
    else
        local slotW = finalWidth / #active
        for i, entry in ipairs(active) do
            local btn = blockFrames[entry.key]
            btn:SetSize(slotW, blockH)
            btn:ClearAllPoints()
            btn:SetPoint("LEFT", container, "LEFT", (i - 1) * slotW, 0)
            btn:Show()
        end
    end

    container:SetSize(finalWidth, blockH)

    if cfg.bgEnabled then
        bgTexture:SetColorTexture(cfg.bgColorR or 0, cfg.bgColorG or 0, cfg.bgColorB or 0, (cfg.bgOpacity or 50) / 100)
        bgTexture:Show()
    else
        bgTexture:Hide()
    end
end

-------------------------------------------------------------------------------
--  Ticker
-------------------------------------------------------------------------------
local ticker

local function StartTicker()
    if ticker then return end
    ticker = C_Timer.NewTicker(1, RefreshStatusBar)
end

local function StopTicker()
    if ticker then ticker:Cancel(); ticker = nil end
end

-------------------------------------------------------------------------------
--  Unlock mode registration (mirrors EllesmereUIVoidlol_HealerMana.lua)
-------------------------------------------------------------------------------
local unlockRegistered = false

local function RegisterUnlock()
    if unlockRegistered then return end
    if not EllesmereUI or not EllesmereUI.RegisterUnlockElements or not EllesmereUI.MakeUnlockElement then return end
    local MK = EllesmereUI.MakeUnlockElement

    local element = MK({
        key            = "EVL_StatusBar",
        label          = "Status Bar",
        group          = "Voidlol",
        order          = 210,
        noResize       = true,
        noAnchorTarget = true, -- width changes with which blocks are enabled
        getFrame       = function() return EnsureContainer() end,
        getSize        = function()
            if container then return container:GetWidth(), container:GetHeight() end
            return 100, 20
        end,
        isHidden       = function()
            local cfg = DB()
            return not (cfg and cfg.enabled)
        end,
        savePos        = function()
            local cfg = DB()
            if not cfg or not container or not container:GetCenter() then return end
            local cx, cy = container:GetCenter()
            local upX, upY = UIParent:GetCenter()
            local fes = container:GetEffectiveScale() or 1
            local ues = UIParent:GetEffectiveScale() or 1
            local ratio = fes / ues
            cfg.pos = { centerX = cx * ratio - upX, centerY = cy * ratio - upY }
        end,
        loadPos        = function()
            local cfg = DB()
            return cfg and cfg.pos
        end,
        clearPos       = function()
            local cfg = DB()
            if cfg then cfg.pos = nil end
        end,
        applyPos       = function() ApplyPosition() end,
    })
    EllesmereUI:RegisterUnlockElements({ element }, "EllesmereUIVoidlol")
    unlockRegistered = true
end

-------------------------------------------------------------------------------
--  Hide while chatting. On this client the chat edit box API moved onto the
--  ChatFrameUtil table -- ChatFrameUtil.ActivateChat/DeactivateChat are what
--  actually fires on Enter-to-chat/slash-commands/whispers/etc; the old bare
--  globals ChatEdit_ActivateChat/DeactivateChat exist but nothing calls them
--  anymore, so hooking those silently never fires (confirmed against ElvUI's
--  own Chat.lua, which checks for ChatFrameUtil first and only falls back to
--  the bare globals when it's absent). Same story for GetActiveWindow.
-------------------------------------------------------------------------------
local function IsChatOpen()
    if _G.ChatFrameUtil and _G.ChatFrameUtil.GetActiveWindow then
        return _G.ChatFrameUtil.GetActiveWindow() ~= nil
    end
    return ChatEdit_GetActiveWindow ~= nil and ChatEdit_GetActiveWindow() ~= nil
end

local function ShouldShowForChat()
    local cfg = DB()
    if not (cfg and cfg.hideWhileChatting) then return true end
    return not IsChatOpen()
end

local function UpdateChatVisibility()
    local cfg = DB()
    if not container or not cfg or not cfg.enabled then return end
    container:SetShown(ShouldShowForChat())
end

local chatHookInstalled = false
local function EnsureChatHook()
    if chatHookInstalled then return end
    if _G.ChatFrameUtil and _G.ChatFrameUtil.ActivateChat then
        chatHookInstalled = true
        hooksecurefunc(_G.ChatFrameUtil, "ActivateChat", UpdateChatVisibility)
        hooksecurefunc(_G.ChatFrameUtil, "DeactivateChat", UpdateChatVisibility)
    elseif ChatEdit_ActivateChat and ChatEdit_DeactivateChat then
        chatHookInstalled = true
        hooksecurefunc("ChatEdit_ActivateChat", UpdateChatVisibility)
        hooksecurefunc("ChatEdit_DeactivateChat", UpdateChatVisibility)
    end
end

-------------------------------------------------------------------------------
--  Apply (called on settings change / login)
-------------------------------------------------------------------------------
function EVL.ApplyStatusBar()
    local cfg = DB()
    if not cfg or not cfg.enabled then
        StopTicker()
        if container then container:Hide() end
        return
    end

    EnsureContainer()
    ApplyPosition()
    RefreshStatusBar()
    container:SetShown(ShouldShowForChat())
    StartTicker()
    RegisterUnlock()
    EnsureChatHook()
end
