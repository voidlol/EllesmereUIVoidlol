-------------------------------------------------------------------------------
--  EllesmereUIVoidlol_CombatText.lua
--  Incoming Damage / Incoming Heal combat text frames. Movable via EllesmereUI
--  Unlock Mode, with runtime text display adapted from MidnightBattleText's
--  incoming-only non-stacking flow.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EVL = ns.EVL

local frames = {}           -- key -> anchor frame
local framePools = {}       -- key -> pooled row frames
local activeRows = {}       -- key -> visible row frames
local noneRows = { incomingDamage = {}, incomingHeal = {} }
local runtimeFrame
local EnsureRuntime
local RegisterUnlock
local TryHookUnlockFrame
local unlockHooksInstalled = false
local unlockRegistered = false
local hasUnitCombat = false
-- Declared here (not next to the rest of the test-button code below) so
-- DisplayIncomingText can see it as an upvalue instead of resolving the
-- forward reference to a global.
local testActive = false

local ROW_POOL_MAX = 24

local FRAME_DEFS = {
    {
        -- Bare number: any leading sign comes entirely from cfg.prefix (both
        -- default to ""), so this never double-signs alongside a "-"/"+" prefix.
        key         = "incomingDamage",
        unlockKey   = "EVL_IncomingDamage",
        label       = "Incoming Damage",
        previewText = "12345",
        previewR = 1, previewG = 0.25, previewB = 0.25,
    },
    {
        key         = "incomingHeal",
        unlockKey   = "EVL_IncomingHeal",
        label       = "Incoming Heal",
        previewText = "12345",
        previewR = 0.25, previewG = 1, previewB = 0.35,
    },
}

local DEFAULT_WIDTH, DEFAULT_HEIGHT = 160, 40

local FRAME_DEF_BY_KEY = {}
for _, def in ipairs(FRAME_DEFS) do FRAME_DEF_BY_KEY[def.key] = def end

local CT_DAMAGE = {
    DAMAGE = true, DAMAGE_CRIT = true,
    SPELL_DAMAGE = true, SPELL_DAMAGE_CRIT = true,
    DAMAGE_SHIELD = true,
    SPELL_PERIODIC_DAMAGE = true, SPELL_PERIODIC_DAMAGE_CRIT = true,
}
local CT_DAMAGE_CRIT = {
    DAMAGE_CRIT = true, SPELL_DAMAGE_CRIT = true,
    SPELL_PERIODIC_DAMAGE_CRIT = true,
}
local CT_HEAL = {
    HEAL = true, HEAL_CRIT = true,
    PERIODIC_HEAL = true, PERIODIC_HEAL_CRIT = true,
    SPELL_HEAL = true, SPELL_HEAL_CRIT = true,
}
local CT_HEAL_CRIT = {
    HEAL_CRIT = true, PERIODIC_HEAL_CRIT = true, SPELL_HEAL_CRIT = true,
}

-------------------------------------------------------------------------------
--  DB helpers
-------------------------------------------------------------------------------
local function DB(key)
    local d = EVL.DB and EVL.DB()
    local ct = d and d.combatText
    return ct and ct[key]
end

local function IsUnlockActive()
    return EllesmereUI and EllesmereUI.IsUnlockModeActive and EllesmereUI.IsUnlockModeActive()
end

-- True while this frame is anchor-linked to another element via Unlock Mode.
-- Keyed by the element's unlockKey (the key the anchor DB is stored under),
-- not our internal frame key.
local function IsUnlockAnchored(key)
    local def = FRAME_DEF_BY_KEY[key]
    return def ~= nil and EllesmereUI and EllesmereUI.IsUnlockAnchored
        and EllesmereUI.IsUnlockAnchored(def.unlockKey) or false
end

-- Master switch, separate from the per-frame (Incoming Damage / Incoming Heal)
-- enabled flags -- both gates must pass for a frame to show.
local function IsModuleEnabled()
    local d = EVL.DB and EVL.DB()
    local ct = d and d.combatText
    return ct and ct.enabled ~= false
end

local function AbbreviateNumber(amount)
    if type(amount) ~= "number" then return amount end
    if amount >= 1000000 then
        return string.format("%.1fM", amount / 1000000)
    elseif amount >= 1000 then
        return string.format("%.1fk", amount / 1000)
    end
    return tostring(amount)
end

local function GetFontPath(fontKey)
    if fontKey == "__global" then
        return (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
    end
    return (EllesmereUI.ResolveFontName and EllesmereUI.ResolveFontName(fontKey)) or "Fonts\\FRIZQT__.TTF"
end

-------------------------------------------------------------------------------
--  Runtime row frames
-------------------------------------------------------------------------------
local function ReleaseRow(row)
    if not row then return end
    row.animGroup:Stop()
    row:Hide()
    row:ClearAllPoints()
    row:SetAlpha(1)
    row.text:SetText("")
    row._fading = nil

    local key = row._ctKey
    if key and activeRows[key] then
        for i = #activeRows[key], 1, -1 do
            if activeRows[key][i] == row then
                table.remove(activeRows[key], i)
                break
            end
        end
    end

    local pool = key and framePools[key]
    if pool and #pool < ROW_POOL_MAX then
        table.insert(pool, row)
    end

    if key and noneRows[key] then
        for i = #noneRows[key], 1, -1 do
            if noneRows[key][i] == row then
                table.remove(noneRows[key], i)
                break
            end
        end
    end
end

local function CreateRowFrame(anchorFrame, key)
    local row = CreateFrame("Frame", nil, UIParent)
    row:SetSize(math.max(anchorFrame:GetWidth(), 120), 48)
    row:SetFrameStrata("HIGH")
    row._ctKey = key

    local text = row:CreateFontString(nil, "OVERLAY")
    text:SetPoint("LEFT", row, "LEFT", 0, 0)
    text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    text:SetJustifyH("CENTER")
    row.text = text

    local ag = row:CreateAnimationGroup()
    row.animGroup = ag

    local translate = ag:CreateAnimation("Translation")
    translate:SetSmoothing("OUT")
    row.translateAnim = translate

    local fade = ag:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    row.fadeAnim = fade

    ag:SetScript("OnFinished", function()
        ReleaseRow(row)
    end)

    return row
end

local function AcquireRow(key)
    local anchorFrame = frames[key]
    if not anchorFrame then return nil end

    framePools[key] = framePools[key] or {}
    activeRows[key] = activeRows[key] or {}

    local pool = framePools[key]
    local row = table.remove(pool)
    if not row then
        row = CreateRowFrame(anchorFrame, key)
    end

    row:SetParent(UIParent)
    row:SetSize(math.max(anchorFrame:GetWidth(), 120), math.max(anchorFrame:GetHeight(), 40))
    table.insert(activeRows[key], row)
    return row
end

local function ApplyRowStyle(row, key, amount, isCrit, schoolMask, specialText)
    local cfg = DB(key)
    local def = FRAME_DEF_BY_KEY[key]
    if not row or not cfg or not def then return end

    local fontPath = GetFontPath(cfg.font or "__global")
    row.text:SetFont(fontPath, cfg.fontSize or 22, cfg.outline ~= false and "OUTLINE" or "")
    row.text:SetJustifyH(cfg.align or "CENTER")
    row.text:SetAlpha(1)
    if cfg.align == "LEFT" then
        row.text:ClearAllPoints()
        row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    elseif cfg.align == "RIGHT" then
        row.text:ClearAllPoints()
        row.text:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    else
        row.text:ClearAllPoints()
        row.text:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    end

    -- Prefix only ever applies to an actual formatted number -- never to a
    -- special outcome (Absorb, or a test-only Dodge/Parry/etc via
    -- specialText), so a "-" prefix reads as "-55k" but "Absorb" stays
    -- "Absorb", not "-Absorb".
    local displayAmount
    if specialText then
        displayAmount = specialText
    elseif amount == 0 and key == "incomingDamage" then
        displayAmount = "ABSORB"
    elseif type(amount) ~= "number" then
        displayAmount = amount
    else
        displayAmount = (cfg.prefix or "") .. AbbreviateNumber(amount)
    end
    row.text:SetText(displayAmount)

    if key == "incomingDamage" then
        if cfg.colorByType and schoolMask and schoolMask ~= 1 then
            row.text:SetTextColor(0.79, 0.3, 0.85, 1)
        else
            row.text:SetTextColor(def.previewR, def.previewG, def.previewB, 1)
        end
    else
        row.text:SetTextColor(cfg.textR or def.previewR, cfg.textG or def.previewG, cfg.textB or def.previewB, 1)
    end

    row:SetScale(1)
end

local function EnforceNoneRows(key)
    local cfg = DB(key)
    if not cfg then return end

    local maxRows = math.max(1, math.floor(cfg.rowsLimit or 5))
    local liveRows = {}

    for _, row in ipairs(noneRows[key]) do
        if row:IsShown() and not row._fading then
            liveRows[#liveRows + 1] = row
        end
    end

    while #liveRows > maxRows do
        local row = table.remove(liveRows, 1)
        row._fading = true
        row.animGroup:Stop()
        row.fadeAnim:SetStartDelay(0)
        row.fadeAnim:SetDuration(math.max(0.1, cfg.fadeDuration or 0.5))
        row.animGroup:Play()
    end
end

local function DisplayIncomingText(key, amount, isCrit, schoolMask, specialText)
    local cfg = DB(key)
    local anchorFrame = frames[key]
    if not cfg or not anchorFrame then return end
    -- Start Test bypasses both Enabled gates so it always previews, even
    -- before you've turned the feature on -- same reasoning as the preview
    -- groups elsewhere in this addon (e.g. Healer Mana's options-page
    -- preview). Real combat events still respect them normally.
    if not testActive and (cfg.enabled == false or not IsModuleEnabled()) then return end
    if IsUnlockActive() then return end

    local row = AcquireRow(key)
    if not row then return end

    ApplyRowStyle(row, key, amount, isCrit, schoolMask, specialText)

    local fadeDuration = math.max(0.1, cfg.fadeDuration or 0.5)
    local stepY = (cfg.fontSize or 22) + 6

    for _, existing in ipairs(noneRows[key]) do
        if existing:IsShown() and not existing._fading then
            local _, _, _, x, y = existing:GetPoint()
            existing:ClearAllPoints()
            existing:SetPoint("CENTER", anchorFrame, "CENTER", x, y + stepY)
        end
    end

    row:ClearAllPoints()
    row:SetPoint("CENTER", anchorFrame, "CENTER", 0, 0)
    row:SetAlpha(1)
    row._fading = false
    row:Show()
    row.translateAnim:SetOffset(0, 0)
    row.translateAnim:SetDuration(0)
    row.animGroup:Stop()
    row.fadeAnim:SetStartDelay(math.max(0, cfg.fadeStart or 1.0))
    row.fadeAnim:SetDuration(fadeDuration)
    row.animGroup:Play()
    noneRows[key][#noneRows[key] + 1] = row
    EnforceNoneRows(key)
end

-------------------------------------------------------------------------------
--  Anchor frame creation / styling
-------------------------------------------------------------------------------
local function CreateCTFrame(def)
    local f = CreateFrame("Frame", "EllesmereUIVoidlol_" .. def.unlockKey, UIParent, "BackdropTemplate")
    f:SetSize(DEFAULT_WIDTH, DEFAULT_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetClampedToScreen(true)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.06, 0.35)
    f._bg = bg

    if EllesmereUI.MakeBorder then
        f._border = EllesmereUI.MakeBorder(f, 1, 1, 1, 0.12, EllesmereUI.PP)
    end

    local fs = f:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("CENTER")
    fs:SetFont(GetFontPath("__global"), 22, "OUTLINE")
    fs:SetTextColor(def.previewR, def.previewG, def.previewB, 1)
    fs:SetText(def.previewText)
    f._text = fs

    f:Hide()
    frames[def.key] = f
    framePools[def.key] = framePools[def.key] or {}
    activeRows[def.key] = activeRows[def.key] or {}
    return f
end

local function GetFrame(key)
    local def = FRAME_DEF_BY_KEY[key]
    if not def then return nil end
    return frames[key] or CreateCTFrame(def)
end

local function ApplyPosition(key)
    local cfg = DB(key)
    local f = GetFrame(key)
    if not f or not cfg then return end
    -- When this frame is anchor-linked to another element in Unlock Mode, the
    -- unlock anchor system owns its position and repositions it live as the
    -- target moves. Re-applying our own UIParent-relative position here would
    -- snap it off the anchor on every refresh (unlock open/close via ApplyAll,
    -- options change), so leave it alone -- mirrors EllesmereUI's own modules
    -- (e.g. Mythic+ Timer) which skip their absolute apply while anchored.
    if IsUnlockAnchored(key) then return end
    f:ClearAllPoints()
    if cfg.pos then
        f:SetPoint("CENTER", UIParent, "CENTER", cfg.pos.centerX, cfg.pos.centerY)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

local function ApplyFrameStyle(key)
    local cfg = DB(key)
    local f = GetFrame(key)
    local def = FRAME_DEF_BY_KEY[key]
    if not f or not cfg or not def then return end

    local fontPath = GetFontPath(cfg.font or "__global")
    f._text:SetFont(fontPath, cfg.fontSize or 22, cfg.outline ~= false and "OUTLINE" or "")
    if key == "incomingHeal" then
        f._text:SetTextColor(cfg.textR or def.previewR, cfg.textG or def.previewG, cfg.textB or def.previewB, 1)
    else
        f._text:SetTextColor(def.previewR, def.previewG, def.previewB, 1)
    end
    f._text:SetText((cfg.prefix or "") .. def.previewText)
    f._text:SetJustifyH(cfg.align or "CENTER")

    for _, row in ipairs(activeRows[key] or {}) do
        if row:IsShown() then
            local txt = row.text:GetText()
            if txt and txt ~= "" then
                row.text:SetFont(fontPath, cfg.fontSize or 22, cfg.outline ~= false and "OUTLINE" or "")
                row.text:SetJustifyH(cfg.align or "CENTER")
            end
        end
    end
end

local function ApplyFrame(key)
    local cfg = DB(key)
    local f = GetFrame(key)
    if not f or not cfg then return end
    ApplyPosition(key)
    ApplyFrameStyle(key)
    f:SetShown(IsModuleEnabled() and cfg.enabled ~= false and IsUnlockActive())
end

local function ApplyAll()
    local damageCfg = DB("incomingDamage")
    local healCfg = DB("incomingHeal")
    local enabled = IsModuleEnabled() and ((damageCfg and damageCfg.enabled ~= false) or (healCfg and healCfg.enabled ~= false))

    if enabled then
        EnsureRuntime()
        if not unlockRegistered then
            RegisterUnlock()
        end
    end

    for _, def in ipairs(FRAME_DEFS) do
        ApplyFrame(def.key)
    end
    if runtimeFrame then
        if enabled then
            runtimeFrame:RegisterUnitEvent("UNIT_COMBAT", "player")
            runtimeFrame:RegisterEvent("COMBAT_TEXT_UPDATE")
        else
            runtimeFrame:UnregisterEvent("UNIT_COMBAT")
            runtimeFrame:UnregisterEvent("COMBAT_TEXT_UPDATE")
        end
    end
    TryHookUnlockFrame()
end
EVL.ApplyCombatText = ApplyAll

-------------------------------------------------------------------------------
--  Incoming event handling
-------------------------------------------------------------------------------
local function OnUnitCombat(unit, action, flagText, amount, schoolMask)
    if unit ~= "player" then return end
    hasUnitCombat = true

    if action == "WOUND" and type(amount) == "number" then
        DisplayIncomingText("incomingDamage", amount, flagText == "CRITICAL", schoolMask)
    elseif action == "HEAL" and type(amount) == "number" then
        DisplayIncomingText("incomingHeal", amount, flagText == "CRITICAL")
    else
        DisplayIncomingText("incomingDamage", action, false, schoolMask)
    end
end

local function OnCombatTextUpdate(textType)
    if hasUnitCombat then return end

    if CT_DAMAGE[textType] then
        local amount = GetCurrentCombatTextEventInfo()
        if type(amount) == "number" then
            DisplayIncomingText("incomingDamage", amount, CT_DAMAGE_CRIT[textType] or false)
        end
    elseif CT_HEAL[textType] then
        local _, amount = GetCurrentCombatTextEventInfo()
        if type(amount) == "number" then
            DisplayIncomingText("incomingHeal", amount, CT_HEAL_CRIT[textType] or false)
        end
    end
end

EnsureRuntime = function()
    if runtimeFrame then return runtimeFrame end
    runtimeFrame = CreateFrame("Frame")
    runtimeFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "UNIT_COMBAT" then
            OnUnitCombat(...)
        elseif event == "COMBAT_TEXT_UPDATE" then
            OnCombatTextUpdate(...)
        end
    end)
    return runtimeFrame
end

-------------------------------------------------------------------------------
--  Unlock mode registration
-------------------------------------------------------------------------------
TryHookUnlockFrame = function()
    if unlockHooksInstalled then return end

    local unlockFrame = _G.EllesmereUnlockMode
    if not unlockFrame then return end

    unlockHooksInstalled = true
    unlockFrame:HookScript("OnShow", ApplyAll)
    unlockFrame:HookScript("OnHide", ApplyAll)
end

RegisterUnlock = function()
    if unlockRegistered then return end
    if not EllesmereUI or not EllesmereUI.RegisterUnlockElements or not EllesmereUI.MakeUnlockElement then return end
    local MK = EllesmereUI.MakeUnlockElement

    local elements = {}
    for i, def in ipairs(FRAME_DEFS) do
        elements[#elements + 1] = MK({
            key      = def.unlockKey,
            label    = def.label,
            group    = "Voidlol",
            order    = 100 + i,
            noResize = true,
            getFrame = function() return GetFrame(def.key) end,
            getSize  = function()
                local f = frames[def.key]
                if f then return f:GetWidth(), f:GetHeight() end
                return DEFAULT_WIDTH, DEFAULT_HEIGHT
            end,
            isHidden = function()
                local cfg = DB(def.key)
                return not cfg or cfg.enabled == false
            end,
            savePos = function()
                local cfg = DB(def.key)
                local f = frames[def.key]
                if not cfg or not f or not f:GetCenter() then return end
                local cx, cy = f:GetCenter()
                local upX, upY = UIParent:GetCenter()
                local fes = f:GetEffectiveScale() or 1
                local ues = UIParent:GetEffectiveScale() or 1
                local ratio = fes / ues
                cfg.pos = { centerX = cx * ratio - upX, centerY = cy * ratio - upY }
            end,
            loadPos = function()
                local cfg = DB(def.key)
                return cfg and cfg.pos
            end,
            clearPos = function()
                local cfg = DB(def.key)
                if cfg then cfg.pos = nil end
            end,
            applyPos = function() ApplyPosition(def.key) end,
        })
    end
    EllesmereUI:RegisterUnlockElements(elements, "EllesmereUIVoidlol")
    unlockRegistered = true
    TryHookUnlockFrame()
end
EVL.RegisterCombatTextUnlock = RegisterUnlock

-------------------------------------------------------------------------------
--  Manual test: fakes one incoming-damage and one incoming-heal event every
--  0.5s through the SAME DisplayIncomingText path real combat uses, so
--  what you see while testing is exactly what real combat will look like
--  (same fonts/colors/animation/rows-limit/fade settings) -- not a separate
--  mock display. Bypasses the Enabled toggles (see DisplayIncomingText)
--  so it always previews, even before the feature is turned on.
-------------------------------------------------------------------------------
local testTicker

-- Physical, Holy, Fire, Nature, Frost, Shadow, Arcane (real WoW school-mask bits).
local TEST_SCHOOL_MASKS = { 1, 2, 4, 8, 16, 32, 64 }

-- Melee-avoidance outcomes: physical only, you can't miss/dodge/parry/block a spell.
local TEST_PHYSICAL_SPECIALS = { "MISS", "DODGE", "PARRY", "BLOCK" }

local function GenerateTestEvent()
    local roll = math.random()
    if roll < 0.12 then
        DisplayIncomingText("incomingDamage", 0, false, TEST_SCHOOL_MASKS[math.random(1, #TEST_SCHOOL_MASKS)]) -- Absorb (amount == 0), any school
    elseif roll < 0.40 then
        local special = TEST_PHYSICAL_SPECIALS[math.random(1, #TEST_PHYSICAL_SPECIALS)]
        DisplayIncomingText("incomingDamage", 0, false, 1, special)
    else
        DisplayIncomingText("incomingDamage", math.random(1000, 60000), math.random() < 0.2, TEST_SCHOOL_MASKS[math.random(1, #TEST_SCHOOL_MASKS)])
    end
    DisplayIncomingText("incomingHeal", math.random(500, 40000), math.random() < 0.2)
end

function EVL.CombatText_IsTestActive()
    return testActive
end

-- Returns the new active state so the options-page button can update its own label.
function EVL.CombatText_ToggleTest()
    if testActive then
        if testTicker then
            testTicker:Cancel()
            testTicker = nil
        end
        testActive = false
    else
        testActive = true
        GenerateTestEvent() -- show one immediately instead of waiting for the first tick
        testTicker = C_Timer.NewTicker(0.5, GenerateTestEvent)
    end
    return testActive
end

function EVL.InitCombatText()
    EnsureRuntime()
    ApplyAll()
end
